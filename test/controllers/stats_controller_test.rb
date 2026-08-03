require "test_helper"

module ActiveAnalytics
  class StatsControllerTest < ActionDispatch::IntegrationTest
    teardown do
      ActiveAnalytics.reset_configuration!
    end

    test "index totals sum views and count unique visitors within the window" do
      today = Date.current

      PageViewDay.bump!(date: today, page_path: "/pricing")
      PageViewDay.bump!(date: today, page_path: "/pricing")
      PageViewDay.bump!(date: today, page_path: "/about")
      VisitorDay.mark!(date: today, visitor_key: "visitor-a")
      VisitorDay.mark!(date: today, visitor_key: "visitor-b")

      get "/analytics/overview"

      assert_response :success
      values = response.body.scan(%r{<div class="aa-stats-card__value">\s*(.+?)\s*</div>}m).flatten
      assert_equal [ "3", "2", "1.5" ], values
    end

    test "index shows an em dash for views per visitor when there are no uniques" do
      PageViewDay.bump!(date: Date.current, page_path: "/pricing")

      get "/analytics/overview"

      assert_response :success
      assert_includes response.body, "—"
    end

    test "index zero-fills the daily series for days without data" do
      today = Date.current
      PageViewDay.bump!(date: today, page_path: "/pricing")
      VisitorDay.mark!(date: today, visitor_key: "visitor-a")

      get "/analytics/overview", params: { days: 3 }

      assert_response :success

      window = (today - 2)..today
      assert_equal 3, window.count

      # Every day of the window (including the two with no rollups) must
      # produce a chart bar — one <rect> per day, zero-filled.
      rect_count = response.body.scan(/<rect\b/).size
      assert_equal 3, rect_count
    end

    test "index orders top pages and top referrers descending by views" do
      today = Date.current
      PageViewDay.bump!(date: today, page_path: "/alpha")
      3.times { PageViewDay.bump!(date: today, page_path: "/beta") }
      ReferrerDay.bump!(date: today, referrer_host: "direct")
      3.times { ReferrerDay.bump!(date: today, referrer_host: "google.com") }

      get "/analytics/overview"

      assert_response :success
      body = response.body
      # /beta (3 views) should appear before /alpha (1 view) in the top pages table.
      assert_operator body.index("/beta"), :<, body.index("/alpha")
      assert_operator body.index("google.com"), :<, body.index("direct")
    end

    test "index reports browsers and devices grouped and summed across dates" do
      today = Date.current
      BrowserDay.bump!(date: today, browser: "Chrome", device: "desktop")
      BrowserDay.bump!(date: today, browser: "Chrome", device: "mobile")
      BrowserDay.bump!(date: today, browser: "Firefox", device: "desktop")

      get "/analytics/overview"

      assert_response :success
      assert_includes response.body, "Chrome"
      assert_includes response.body, "Firefox"
      assert_includes response.body, "desktop"
      assert_includes response.body, "mobile"
    end

    test "index clamps an out-of-range days param to the maximum of 365" do
      get "/analytics/overview", params: { days: 9999 }

      assert_response :success
      # None of the 7/30/90 pills match a 365-day window, and the chart
      # renders exactly one bar per day of the clamped window.
      assert_not_includes response.body, "aa-heatmap__pill--active"
      assert_equal 365, response.body.scan(/<rect\b/).size
    end

    test "index falls back to the default 30 days for a non-positive days param" do
      get "/analytics/overview", params: { days: 0 }

      assert_response :success
      assert_includes response.body, "aa-heatmap__pill--active\" href=\"/analytics/overview?days=30\">30 days"
      assert_equal 30, response.body.scan(/<rect\b/).size
    end

    test "engine root routes to the overview dashboard" do
      get "/analytics"

      assert_response :success
      assert_includes response.body, "Overview"
    end
  end
end
