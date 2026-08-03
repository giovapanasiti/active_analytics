require "test_helper"

module ActiveAnalytics
  class RecordingTest < ActiveSupport::TestCase
    teardown do
      ActiveAnalytics.reset_configuration!
    end

    def build_recording(uuid: SecureRandom.uuid)
      Recording.create!(
        uuid: uuid,
        started_at: Time.current,
        last_seen_at: Time.current,
        user_agent: "Mozilla/5.0"
      )
    end

    test "requires a well-formed uuid" do
      recording = Recording.new(uuid: "not-a-uuid", started_at: Time.current, last_seen_at: Time.current)

      assert_not recording.valid?
      assert_includes recording.errors[:uuid], "is invalid"
    end

    test "requires uuid uniqueness" do
      uuid = SecureRandom.uuid
      build_recording(uuid: uuid)
      dup = Recording.new(uuid: uuid, started_at: Time.current, last_seen_at: Time.current)

      assert_not dup.valid?
      assert_includes dup.errors[:uuid], "has already been taken"
    end

    test "device_for classifies user agents" do
      assert_equal "mobile", Recording.device_for("Mozilla/5.0 (Linux; Android 10; Mobile)")
      assert_equal "tablet", Recording.device_for("Mozilla/5.0 (iPad; CPU OS 14_0)")
      assert_equal "desktop", Recording.device_for("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15)")
      assert_equal "desktop", Recording.device_for(nil)
    end

    test "append_batch! updates counters, last_seen_at and duration_ms" do
      recording = build_recording

      recording.append_batch!(seq: 0, events: [
        { "t" => 0, "e" => "snapshot", "d" => {} },
        { "t" => 100, "e" => "click", "d" => {} }
      ], byte_size: 42)

      assert_equal 2, recording.events_count
      assert_equal 1, recording.clicks_count
      assert_equal 0, recording.errors_count
      assert_equal 1, recording.pages_count
      assert_equal 100, recording.duration_ms

      recording.append_batch!(seq: 1, events: [
        { "t" => 200, "e" => "nav", "d" => {} },
        { "t" => 250, "e" => "error", "d" => {} }
      ], byte_size: 12)

      assert_equal 4, recording.events_count
      assert_equal 1, recording.clicks_count
      assert_equal 1, recording.errors_count
      assert_equal 2, recording.pages_count
      assert_equal 250, recording.duration_ms
    end

    test "append_batch! does not regress duration_ms when a later batch has smaller t values" do
      recording = build_recording

      recording.append_batch!(seq: 0, events: [ { "t" => 500, "e" => "snapshot", "d" => {} } ], byte_size: 5)
      recording.append_batch!(seq: 1, events: [ { "t" => 10, "e" => "move", "d" => {} } ], byte_size: 5)

      assert_equal 500, recording.duration_ms
    end

    test "#events concatenates all batches in seq order" do
      recording = build_recording

      recording.append_batch!(seq: 1, events: [ { "t" => 10, "e" => "click", "d" => {} } ], byte_size: 5)
      recording.append_batch!(seq: 0, events: [ { "t" => 0, "e" => "snapshot", "d" => {} } ], byte_size: 5)

      assert_equal [ "snapshot", "click" ], recording.events.map { |e| e["e"] }
    end

    test "#finished? reflects staleness against session_timeout" do
      ActiveAnalytics.configure { |c| c.session_timeout = 60 }
      recording = build_recording
      recording.update!(last_seen_at: 2.minutes.ago)

      assert recording.finished?

      recording.update!(last_seen_at: Time.current)

      assert_not recording.finished?
    end

    test "stale scope returns recordings past session_timeout" do
      ActiveAnalytics.configure { |c| c.session_timeout = 60 }
      stale = build_recording
      stale.update!(last_seen_at: 2.minutes.ago)
      fresh = build_recording
      fresh.update!(last_seen_at: Time.current)

      assert_includes Recording.stale, stale
      assert_not_includes Recording.stale, fresh
    end

    test "unanalyzed scope returns recordings without analyzed_at" do
      analyzed = build_recording
      analyzed.update!(analyzed_at: Time.current)
      unanalyzed = build_recording

      assert_includes Recording.unanalyzed, unanalyzed
      assert_not_includes Recording.unanalyzed, analyzed
    end

    test "purge_expired! deletes recordings past retention_days and returns the count" do
      ActiveAnalytics.configure { |c| c.retention_days = 1 }
      expired = build_recording
      expired.update!(last_seen_at: 2.days.ago)
      kept = build_recording
      kept.update!(last_seen_at: Time.current)

      count = Recording.purge_expired!

      assert_equal 1, count
      assert Recording.exists?(kept.id)
      assert_not Recording.exists?(expired.id)
    end
  end
end
