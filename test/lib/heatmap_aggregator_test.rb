require "test_helper"

module ActiveAnalytics
  class HeatmapAggregatorTest < ActiveSupport::TestCase
    def build_recording(uuid: SecureRandom.uuid, first_url: "https://example.com/pricing", device: "desktop",
                         viewport_width: 1000, viewport_height: 800)
      Recording.create!(
        uuid: uuid,
        started_at: Time.current,
        last_seen_at: Time.current,
        user_agent: "Mozilla/5.0",
        first_url: first_url,
        device: device,
        viewport_width: viewport_width,
        viewport_height: viewport_height
      )
    end

    def record_events(recording, events, seq: 0)
      recording.append_batch!(seq: seq, events: events, byte_size: 10)
    end

    def click(t, x:, y:)
      { "t" => t, "e" => "click", "d" => { "x" => x, "y" => y, "id" => nil, "label" => "" } }
    end

    def move(t, x:, y:)
      { "t" => t, "e" => "move", "d" => { "x" => x, "y" => y } }
    end

    def scroll(t, x: 0, y:)
      { "t" => t, "e" => "scroll", "d" => { "x" => x, "y" => y } }
    end

    def resize(t, w:, h:)
      { "t" => t, "e" => "resize", "d" => { "w" => w, "h" => h } }
    end

    def nav(t, url:)
      { "t" => t, "e" => "nav", "d" => { "url" => url, "title" => "" } }
    end

    def snapshot(t, url:, vw: nil, vh: nil)
      d = { "url" => url }
      d["vw"] = vw if vw
      d["vh"] = vh if vh
      { "t" => t, "e" => "snapshot", "d" => d }
    end

    def cell(page_path:, kind:, x_bucket:, y_bucket:, device: "desktop")
      HeatmapCell.find_by(page_path: page_path, device: device, kind: kind, x_bucket: x_bucket, y_bucket: y_bucket)
    end

    # --- bucket math ------------------------------------------------------

    test "buckets click/move coordinates against the recording viewport" do
      recording = build_recording
      record_events(recording, [ click(0, x: 210, y: 40), move(10, x: 210, y: 40) ])

      HeatmapAggregator.new(recording).aggregate!

      click_cell = cell(page_path: "/pricing", kind: "click", x_bucket: 10, y_bucket: 1)
      move_cell = cell(page_path: "/pricing", kind: "move", x_bucket: 10, y_bucket: 1)

      assert click_cell
      assert_equal 1, click_cell.count
      assert move_cell
      assert_equal 1, move_cell.count
    end

    test "scroll offset is applied to land moves in document coordinates" do
      recording = build_recording
      record_events(recording, [ scroll(0, y: 500), move(100, x: 100, y: 50) ])

      HeatmapAggregator.new(recording).aggregate!

      # doc_y = 50 (viewport y) + 500 (scroll_y) = 550 -> y_bucket 550/25 = 22
      moved = cell(page_path: "/pricing", kind: "move", x_bucket: 5, y_bucket: 22)
      assert moved
      assert_equal 1, moved.count
    end

    test "resize updates the tracked viewport width used for bucketing" do
      recording = build_recording(viewport_width: nil, viewport_height: nil)
      record_events(recording, [ resize(0, w: 2000, h: 1000), click(10, x: 1000, y: 0) ])

      HeatmapAggregator.new(recording).aggregate!

      clicked = cell(page_path: "/pricing", kind: "click", x_bucket: 25, y_bucket: 0)
      assert clicked
      assert_equal 1, clicked.count
    end

    # --- pageview boundaries ------------------------------------------------

    test "nav resets scroll and splits pageviews into separate scroll cells" do
      recording = build_recording(first_url: "https://example.com/pricing")
      record_events(recording, [
        scroll(0, y: 300),
        nav(1500, url: "https://example.com/other"),
        scroll(1600, y: 100)
      ])

      HeatmapAggregator.new(recording).aggregate!

      # pageview 1: max_depth = max(800, 300+800) = 1100 -> y_bucket 44
      first_page = cell(page_path: "/pricing", kind: "scroll", x_bucket: 0, y_bucket: 44)
      # pageview 2: max_depth = max(800, 100+800) = 900 -> y_bucket 36
      second_page = cell(page_path: "/other", kind: "scroll", x_bucket: 0, y_bucket: 36)

      assert first_page
      assert_equal 1, first_page.count
      assert second_page
      assert_equal 1, second_page.count
      assert_equal 2, HeatmapCell.where(kind: "scroll").count
    end

    test "a snapshot within 1000ms of a nav does not start a second pageview" do
      recording = build_recording(first_url: "https://example.com/pricing")
      record_events(recording, [
        snapshot(0, url: "https://example.com/pricing", vw: 1000, vh: 800),
        nav(1500, url: "https://example.com/other"),
        snapshot(1550, url: "https://example.com/other", vw: 1000, vh: 800)
      ])

      HeatmapAggregator.new(recording).aggregate!

      # Exactly 2 pageviews (pricing, other) -- the follow-up snapshot must
      # not add a spurious third scroll cell.
      assert_equal 2, HeatmapCell.where(kind: "scroll").count
      assert_equal 1, HeatmapCell.where(kind: "scroll", page_path: "/other").sum(:count)
    end

    # --- idempotency ---------------------------------------------------------

    test "aggregate! is a no-op the second time it runs on the same recording" do
      recording = build_recording
      record_events(recording, [ click(0, x: 210, y: 40) ])

      first_result = HeatmapAggregator.new(recording).aggregate!
      total_after_first = HeatmapCell.sum(:count)

      second_result = HeatmapAggregator.new(recording).aggregate!
      total_after_second = HeatmapCell.sum(:count)

      assert first_result
      assert_not second_result
      assert_equal total_after_first, total_after_second
      assert recording.heatmap_aggregated_at.present?
    end

    # --- cross-recording accumulation -----------------------------------------

    test "upserts accumulate counts across recordings on the same cell" do
      first_recording = build_recording
      record_events(first_recording, [ click(0, x: 210, y: 40) ])

      second_recording = build_recording
      record_events(second_recording, [ click(0, x: 210, y: 40) ])

      HeatmapAggregator.new(first_recording).aggregate!
      HeatmapAggregator.new(second_recording).aggregate!

      clicked = cell(page_path: "/pricing", kind: "click", x_bucket: 10, y_bucket: 1)
      assert_equal 2, clicked.count
      assert_equal 1, HeatmapCell.where(page_path: "/pricing", kind: "click", x_bucket: 10, y_bucket: 1).count
    end

    # --- skip invalid events --------------------------------------------------

    test "skips events with missing or non-numeric x/y" do
      recording = build_recording
      record_events(recording, [
        { "t" => 0, "e" => "click", "d" => {} },
        { "t" => 10, "e" => "move", "d" => { "x" => 5 } },
        { "t" => 20, "e" => "move", "d" => { "x" => "abc", "y" => 5 } }
      ])

      HeatmapAggregator.new(recording).aggregate!

      assert_equal 0, HeatmapCell.where(kind: "click").count
      assert_equal 0, HeatmapCell.where(kind: "move").count
    end

    # --- device fallback -------------------------------------------------------

    test "falls back to desktop when the recording has no device" do
      recording = build_recording(device: nil)
      record_events(recording, [ click(0, x: 210, y: 40) ])

      HeatmapAggregator.new(recording).aggregate!

      clicked = cell(page_path: "/pricing", kind: "click", x_bucket: 10, y_bucket: 1, device: "desktop")
      assert clicked
      assert_equal 1, clicked.count
    end

    # --- page_paths tracking ----------------------------------------------------

    test "aggregate! records the ordered unique list of visited paths on the recording" do
      recording = build_recording(first_url: "https://example.com/")
      record_events(recording, [
        nav(0, url: "https://example.com/dashboard"),
        snapshot(50, url: "https://example.com/dashboard", vw: 1000, vh: 800)
      ])

      HeatmapAggregator.new(recording).aggregate!

      assert_equal [ "/", "/dashboard" ], recording.reload.page_paths
    end

    # --- URL normalization -----------------------------------------------------

    test "page_path normalizes URLs to a path" do
      assert_equal "/pricing", HeatmapAggregator.page_path("https://example.com/pricing?utm=1#anchor")
      assert_equal "/", HeatmapAggregator.page_path("")
      assert_equal "/", HeatmapAggregator.page_path(nil)
      assert_equal "/", HeatmapAggregator.page_path("http://example.com")
      assert_equal "/plain/path", HeatmapAggregator.page_path("/plain/path")
      # Malformed URL (space): URI.parse raises, fallback strips at the first ?/#.
      assert_equal "/foo bar", HeatmapAggregator.page_path("/foo bar?x=1")
    end
  end
end
