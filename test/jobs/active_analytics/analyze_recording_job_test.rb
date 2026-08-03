require "test_helper"

module ActiveAnalytics
  class AnalyzeRecordingJobTest < ActiveSupport::TestCase
    teardown do
      ActiveAnalytics.reset_configuration!
    end

    def build_recording
      Recording.create!(
        uuid: SecureRandom.uuid,
        started_at: Time.current,
        last_seen_at: Time.current,
        first_url: "https://example.com",
        user_agent: "Mozilla/5.0"
      )
    end

    test "perform runs the behavior analyzer and the summarizer" do
      recording = build_recording
      recording.append_batch!(seq: 0, events: [
        { "t" => 0, "e" => "error", "d" => { "message" => "Boom", "source" => "app.js", "line" => 1 } }
      ], byte_size: 10)

      captured_prompt = nil
      ActiveAnalytics.configure do |config|
        config.ai_summarizer = lambda do |prompt|
          captured_prompt = prompt
          "Summary text"
        end
      end

      AnalyzeRecordingJob.perform_now(recording.id)
      recording.reload

      assert recording.analyzed_at.present?
      assert_equal 10, recording.frustration_score
      assert recording.insights.exists?(kind: "js_error")
      assert_equal "Summary text", recording.insights.find_by(kind: "summary").body
      assert_includes captured_prompt, "example.com"
    end

    test "perform is a no-op when the recording no longer exists" do
      assert_nothing_raised do
        AnalyzeRecordingJob.perform_now(-1)
      end
    end
  end
end
