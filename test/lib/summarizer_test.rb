require "test_helper"

module ActiveAnalytics
  class SummarizerTest < ActiveSupport::TestCase
    teardown do
      ActiveAnalytics.reset_configuration!
    end

    def build_recording
      Recording.create!(
        uuid: SecureRandom.uuid,
        started_at: Time.current,
        last_seen_at: Time.current,
        first_url: "https://example.com/pricing",
        user_agent: "Mozilla/5.0",
        duration_ms: 45_000
      )
    end

    test "builds a digest without raw event values and returns the callable backend's summary" do
      recording = build_recording
      recording.append_batch!(seq: 0, events: [
        { "t" => 100, "e" => "input", "d" => { "id" => 1, "value" => "SENTINEL_RAW_VALUE" } },
        { "t" => 200, "e" => "error", "d" => { "message" => "Boom", "source" => "app.js", "line" => 1 } }
      ], byte_size: 10)
      BehaviorAnalyzer.new(recording).analyze!

      captured_prompt = nil
      ActiveAnalytics.configure do |config|
        config.ai_summarizer = lambda do |prompt|
          captured_prompt = prompt
          "Users seemed frustrated. Suggestion: fix the JS error."
        end
      end

      result = Summarizer.new(recording).call

      assert_equal "Users seemed frustrated. Suggestion: fix the JS error.", result
      assert_includes captured_prompt, "https://example.com/pricing"
      assert_includes captured_prompt, "JS error"
      assert_includes captured_prompt, "45.0s"
      assert_not_includes captured_prompt, "SENTINEL_RAW_VALUE"
    end

    test "creates the summary insight on first call and updates (not duplicates) on later calls" do
      recording = build_recording
      ActiveAnalytics.configure { |config| config.ai_summarizer = ->(_prompt) { "First summary" } }

      Summarizer.new(recording).call
      assert_equal 1, recording.insights.where(kind: "summary").count
      assert_equal "First summary", recording.insights.find_by(kind: "summary").body

      ActiveAnalytics.configure { |config| config.ai_summarizer = ->(_prompt) { "Second summary" } }

      Summarizer.new(recording).call
      assert_equal 1, recording.insights.where(kind: "summary").count
      assert_equal "Second summary", recording.insights.find_by(kind: "summary").body
    end

    test "is a no-op when no ai_summarizer is configured" do
      recording = build_recording

      result = Summarizer.new(recording).call

      assert_nil result
      assert_equal 0, recording.insights.count
    end
  end
end
