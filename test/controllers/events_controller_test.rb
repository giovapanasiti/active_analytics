require "test_helper"

module ActiveAnalytics
  class EventsControllerTest < ActionDispatch::IntegrationTest
    teardown do
      ActiveAnalytics.reset_configuration!
    end

    def post_events(payload)
      post "/analytics/events",
        params: payload.to_json,
        headers: { "Content-Type" => "application/json", "User-Agent" => "Mozilla/5.0 (Android Mobile)" }
    end

    test "first post creates a recording and batch with meta, device and counters" do
      uuid = SecureRandom.uuid

      post_events(
        uuid: uuid,
        seq: 0,
        meta: { url: "http://example.com/", referrer: "http://ref.example.com", vw: 1280, vh: 800 },
        events: [
          { t: 0, e: "snapshot", d: {} },
          { t: 50, e: "click", d: {} }
        ]
      )

      assert_response :created
      assert_equal({ "ok" => true }, JSON.parse(response.body))

      recording = Recording.find_by!(uuid: uuid)
      assert_equal "http://example.com/", recording.first_url
      assert_equal "http://ref.example.com", recording.referrer
      assert_equal 1280, recording.viewport_width
      assert_equal 800, recording.viewport_height
      assert_equal "mobile", recording.device
      assert_equal 2, recording.events_count
      assert_equal 1, recording.clicks_count
      assert_equal 1, recording.pages_count
      assert_equal 50, recording.duration_ms
      assert_equal 1, recording.event_batches.count
    end

    test "first delivered batch with a non-zero seq still creates the recording from its meta" do
      # Simulates a lost seq-0 batch (e.g. dropped by the pre-fix 64KB keepalive
      # cap): the server sees seq 3 first for this uuid and must still create
      # the Recording using that batch's meta, since the recorder now sends
      # meta on every batch (not only seq 0).
      uuid = SecureRandom.uuid

      post_events(
        uuid: uuid,
        seq: 3,
        meta: { url: "http://example.com/late", referrer: "http://ref.example.com", vw: 1024, vh: 768 },
        events: [ { t: 900, e: "click", d: {} } ]
      )

      assert_response :created

      recording = Recording.find_by!(uuid: uuid)
      assert_equal "http://example.com/late", recording.first_url
      assert_equal "http://ref.example.com", recording.referrer
      assert_equal 1024, recording.viewport_width
      assert_equal 768, recording.viewport_height
      assert_equal 1, recording.event_batches.count
      assert_equal 3, recording.event_batches.first.seq
    end

    test "second post appends a batch and updates counters, last_seen_at and duration_ms" do
      uuid = SecureRandom.uuid

      post_events(uuid: uuid, seq: 0, meta: { url: "/" }, events: [ { t: 0, e: "snapshot", d: {} } ])
      recording = Recording.find_by!(uuid: uuid)
      first_last_seen_at = recording.last_seen_at

      travel 1.second do
        post_events(uuid: uuid, seq: 1, events: [ { t: 300, e: "nav", d: {} } ])
      end

      assert_response :created
      recording.reload

      assert_equal 2, recording.events_count
      assert_equal 2, recording.pages_count
      assert_equal 300, recording.duration_ms
      assert_operator recording.last_seen_at, :>, first_last_seen_at
      assert_equal 2, recording.event_batches.count
    end

    test "duplicate seq is idempotent and returns 204" do
      uuid = SecureRandom.uuid

      post_events(uuid: uuid, seq: 0, meta: { url: "/" }, events: [ { t: 0, e: "snapshot", d: {} } ])
      post_events(uuid: uuid, seq: 0, events: [ { t: 0, e: "snapshot", d: {} } ])

      assert_response :no_content

      recording = Recording.find_by!(uuid: uuid)
      assert_equal 1, recording.event_batches.count
      assert_equal 1, recording.events_count
    end

    test "malformed payloads are rejected with 422" do
      post_events(uuid: "not-a-uuid", seq: 0, events: [])
      assert_response :unprocessable_entity

      post_events(uuid: SecureRandom.uuid, seq: -1, events: [])
      assert_response :unprocessable_entity

      post_events(uuid: SecureRandom.uuid, seq: 0, events: "nope")
      assert_response :unprocessable_entity
    end

    test "oversized payloads are rejected with 413" do
      ActiveAnalytics.configure { |c| c.max_batch_bytes = 10 }

      post_events(uuid: SecureRandom.uuid, seq: 0, events: [ { t: 0, e: "snapshot", d: {} } ])

      assert_response :content_too_large
    end

    test "returns 403 when recording is disabled" do
      ActiveAnalytics.configure { |c| c.enabled = false }

      post_events(uuid: SecureRandom.uuid, seq: 0, events: [])

      assert_response :forbidden
    end
  end
end
