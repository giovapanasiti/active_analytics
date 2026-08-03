require "test_helper"

module ActiveAnalytics
  class HeatmapsControllerTest < ActionDispatch::IntegrationTest
    teardown do
      ActiveAnalytics.reset_configuration!
    end

    def build_recording(uuid: SecureRandom.uuid, first_url: "http://example.com/pricing", device: "desktop", started_at: Time.current)
      Recording.create!(
        uuid: uuid,
        started_at: started_at,
        last_seen_at: started_at,
        first_url: first_url,
        user_agent: "Mozilla/5.0",
        device: device,
        viewport_width: 1024,
        viewport_height: 768
      )
    end

    def bump_scroll(path:, device:, y_bucket:, count:)
      HeatmapCell.bump!([
        { page_path: path, device: device, kind: "scroll", x_bucket: 0, y_bucket: y_bucket, count: count }
      ])
    end

    def bump_move(path:, device:, x_bucket:, y_bucket:, count:)
      HeatmapCell.bump!([
        { page_path: path, device: device, kind: "move", x_bucket: x_bucket, y_bucket: y_bucket, count: count }
      ])
    end

    test "index lists pages with per-device pageview counts and total points" do
      bump_scroll(path: "/pricing", device: "desktop", y_bucket: 10, count: 5)
      bump_scroll(path: "/pricing", device: "mobile", y_bucket: 4, count: 2)
      bump_move(path: "/pricing", device: "desktop", x_bucket: 1, y_bucket: 1, count: 20)
      HeatmapCell.bump!([
        { page_path: "/pricing", device: "desktop", kind: "click", x_bucket: 1, y_bucket: 1, count: 3 }
      ])

      get "/analytics/heatmaps"

      assert_response :success
      assert_includes response.body, "/pricing"
      # desktop pageviews (5) and total move+click points (23) both show up
      assert_includes response.body, ">5<"
      assert_includes response.body, "23"
      assert_includes response.body, ">2<"
    end

    test "index shows empty state when no heatmap data exists" do
      get "/analytics/heatmaps"

      assert_response :success
      assert_includes response.body, "No heatmap data"
    end

    test "show responds 200 with a matching reference recording" do
      recording = build_recording(first_url: "http://example.com/pricing", device: "desktop")
      bump_scroll(path: "/pricing", device: "desktop", y_bucket: 10, count: 3)

      get "/analytics/heatmaps/show", params: { path: "/pricing", device: "desktop", kind: "scroll" }

      assert_response :success
      assert_includes response.body, recording.uuid
      assert_includes response.body, "Move"
      assert_includes response.body, "Scroll"
    end

    test "show responds 200 without a reference recording" do
      bump_scroll(path: "/no-recording", device: "desktop", y_bucket: 2, count: 1)

      get "/analytics/heatmaps/show", params: { path: "/no-recording", device: "desktop" }

      assert_response :success
      assert_includes response.body, "No snapshot available"
    end

    test "show falls back to the newest recording of any device when the device has no match" do
      build_recording(uuid: SecureRandom.uuid, first_url: "http://example.com/older", device: "mobile", started_at: 2.days.ago)
      newest = build_recording(uuid: SecureRandom.uuid, first_url: "http://example.com/older", device: "tablet", started_at: 1.hour.ago)
      bump_scroll(path: "/older", device: "desktop", y_bucket: 1, count: 1)

      get "/analytics/heatmaps/show", params: { path: "/older", device: "desktop" }

      assert_response :success
      assert_includes response.body, newest.uuid
    end

    test "show falls back to move for an invalid kind" do
      bump_move(path: "/pricing", device: "desktop", x_bucket: 2, y_bucket: 2, count: 4)

      get "/analytics/heatmaps/show", params: { path: "/pricing", device: "desktop", kind: "bogus" }

      assert_response :success
      assert_includes response.body, "aa-heatmap__pill aa-heatmap__pill--active\" href=\"/analytics/heatmaps/show?device=desktop&amp;kind=move&amp;path=%2Fpricing\">Move"
    end

    test "data returns cells and max for move" do
      bump_move(path: "/pricing", device: "desktop", x_bucket: 1, y_bucket: 2, count: 5)
      bump_move(path: "/pricing", device: "desktop", x_bucket: 3, y_bucket: 4, count: 9)

      get "/analytics/heatmaps/data", params: { path: "/pricing", device: "desktop", kind: "move" }

      assert_response :success
      body = JSON.parse(response.body)

      assert_equal "move", body["kind"]
      assert_equal 9, body["max"]
      assert_includes body["cells"], [ 1, 2, 5 ]
      assert_includes body["cells"], [ 3, 4, 9 ]
    end

    test "data computes cumulative reached counts for scroll" do
      bump_scroll(path: "/pricing", device: "desktop", y_bucket: 0, count: 2) # reached top only
      bump_scroll(path: "/pricing", device: "desktop", y_bucket: 4, count: 5) # reached band 4+
      bump_scroll(path: "/pricing", device: "desktop", y_bucket: 8, count: 3) # reached band 8+ (deepest)

      get "/analytics/heatmaps/data", params: { path: "/pricing", device: "desktop", kind: "scroll" }

      assert_response :success
      body = JSON.parse(response.body)

      assert_equal "scroll", body["kind"]
      assert_equal 10, body["total"]

      bands = body["bands"].to_h
      assert_equal 10, bands[0] # everyone reached the top band
      assert_equal 8, bands[4]  # 5 + 3 reached band 4 or deeper
      assert_equal 3, bands[8]  # only the deepest 3 reached band 8
    end

    test "data defaults invalid kind to move" do
      bump_move(path: "/pricing", device: "desktop", x_bucket: 0, y_bucket: 0, count: 1)

      get "/analytics/heatmaps/data", params: { path: "/pricing", device: "desktop", kind: "nope" }

      assert_response :success
      assert_equal "move", JSON.parse(response.body)["kind"]
    end
  end
end
