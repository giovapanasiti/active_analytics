require "test_helper"

module ActiveAnalytics
  class RecordingsControllerTest < ActionDispatch::IntegrationTest
    teardown do
      ActiveAnalytics.reset_configuration!
    end

    def build_recording(uuid: SecureRandom.uuid, first_url: "http://example.com/checkout", errors_count: 0)
      recording = Recording.create!(
        uuid: uuid,
        started_at: Time.current,
        last_seen_at: Time.current,
        first_url: first_url,
        user_agent: "Mozilla/5.0",
        device: "desktop"
      )
      recording.update!(errors_count: errors_count) if errors_count.positive?
      recording
    end

    test "index responds 200 and lists a created recording" do
      build_recording(first_url: "http://example.com/pricing")

      get "/analytics/recordings"

      assert_response :success
      assert_includes response.body, "example.com/pricing"
    end

    test "index q filter only shows matching first_url" do
      build_recording(first_url: "http://example.com/pricing")
      build_recording(first_url: "http://example.com/about")

      get "/analytics/recordings", params: { q: "pricing" }

      assert_response :success
      assert_includes response.body, "example.com/pricing"
      assert_not_includes response.body, "example.com/about"
    end

    test "index errors filter only shows recordings with errors" do
      build_recording(first_url: "http://example.com/broken", errors_count: 2)
      build_recording(first_url: "http://example.com/fine")

      get "/analytics/recordings", params: { errors: "1" }

      assert_response :success
      assert_includes response.body, "example.com/broken"
      assert_not_includes response.body, "example.com/fine"
    end

    test "show responds 200 and displays metadata and insights" do
      recording = build_recording
      recording.insights.create!(kind: "rage_click", severity: "critical", ts_ms: 120, body: "Rage click detected")

      get "/analytics/recordings/#{recording.id}"

      assert_response :success
      assert_includes response.body, recording.uuid
      assert_includes response.body, "Rage click detected"
    end

    test "events returns the JSON payload shape for the player" do
      recording = build_recording
      recording.append_batch!(seq: 0, events: [
        { "t" => 0, "e" => "snapshot", "d" => { "url" => "http://example.com/", "vw" => 1280, "vh" => 800 } },
        { "t" => 50, "e" => "click", "d" => { "x" => 10, "y" => 20 } }
      ], byte_size: 42)

      get "/analytics/recordings/#{recording.id}/events"

      assert_response :success
      body = JSON.parse(response.body)

      assert_equal recording.uuid, body["recording"]["uuid"]
      assert_equal recording.duration_ms, body["recording"]["duration_ms"]
      assert body["recording"].key?("started_at")
      assert body["recording"].key?("viewport_width")
      assert body["recording"].key?("viewport_height")

      assert_equal 2, body["events"].size
      assert_equal [ "snapshot", "click" ], body["events"].map { |e| e["e"] }
    end

    test "destroy removes the recording and redirects to index" do
      recording = build_recording

      assert_difference("ActiveAnalytics::Recording.count", -1) do
        delete "/analytics/recordings/#{recording.id}"
      end

      assert_redirected_to "/analytics/recordings"
      assert_not Recording.exists?(recording.id)
    end

    test "analyze runs analysis and redirects back to show" do
      recording = build_recording
      recording.append_batch!(seq: 0, events: [
        { "t" => 0, "e" => "snapshot", "d" => {} },
        { "t" => 50, "e" => "click", "d" => { "x" => 10, "y" => 10 } }
      ], byte_size: 20)

      post "/analytics/recordings/#{recording.id}/analyze"

      assert_redirected_to "/analytics/recordings/#{recording.id}"
    end
  end
end
