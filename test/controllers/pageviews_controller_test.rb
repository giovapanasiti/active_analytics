require "test_helper"

module ActiveAnalytics
  class PageviewsControllerTest < ActionDispatch::IntegrationTest
    teardown do
      ActiveAnalytics.reset_configuration!
    end

    def post_pageview(payload)
      post "/analytics/pageviews",
        params: payload.to_json,
        headers: { "Content-Type" => "application/json", "User-Agent" => "Mozilla/5.0 Chrome/100.0" }
    end

    test "201 and rollup rows created with request IP/UA" do
      post_pageview(url: "https://example.com/pricing", referrer: "https://google.com/search")

      assert_response :created

      assert_equal 1, PageViewDay.find_by(page_path: "/pricing").views
      assert_equal 1, ReferrerDay.find_by(referrer_host: "google.com").views
      assert_equal 1, BrowserDay.find_by(browser: "Chrome", device: "desktop").views
      assert_equal 1, VisitorDay.where(date: Date.current).count
    end

    test "SPA double-post increments the same page_path" do
      post_pageview(url: "https://example.com/pricing", referrer: "")
      post_pageview(url: "https://example.com/pricing", referrer: "")

      assert_equal 2, PageViewDay.find_by(page_path: "/pricing").views
    end

    test "returns 403 when disabled" do
      ActiveAnalytics.configure { |c| c.enabled = false }

      post_pageview(url: "https://example.com/")

      assert_response :forbidden
    end

    test "returns 422 when url is missing or not a String" do
      post_pageview(referrer: "https://google.com")
      assert_response :unprocessable_entity

      post_pageview(url: 123)
      assert_response :unprocessable_entity

      post "/analytics/pageviews", params: "not json", headers: { "Content-Type" => "application/json" }
      assert_response :unprocessable_entity
    end

    test "returns 413 for oversized payloads" do
      post "/analytics/pageviews",
        params: { url: "https://example.com/#{"a" * 9_000}" }.to_json,
        headers: { "Content-Type" => "application/json" }

      assert_response :content_too_large
    end
  end
end
