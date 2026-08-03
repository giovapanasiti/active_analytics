require "test_helper"

module ActiveAnalytics
  class StatsRecorderTest < ActiveSupport::TestCase
    teardown do
      ActiveAnalytics.reset_configuration!
    end

    def record!(url: "https://example.com/pricing", referrer: nil, ip: "1.2.3.4",
                user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0",
                host: nil, at: Time.current)
      StatsRecorder.record!(url: url, referrer: referrer, ip: ip, user_agent: user_agent, host: host, at: at)
    end

    test "records a page view, browser/device and unique visitor row" do
      record!(url: "https://example.com/pricing")

      pv = PageViewDay.find_by(page_path: "/pricing")
      assert_equal 1, pv.views

      bd = BrowserDay.find_by(browser: "Chrome", device: "desktop")
      assert_equal 1, bd.views

      assert_equal 1, VisitorDay.where(date: Date.current).count
    end

    test "repeated views accumulate the same page_path row" do
      record!(url: "https://example.com/pricing")
      record!(url: "https://example.com/pricing")

      pv = PageViewDay.find_by(page_path: "/pricing")
      assert_equal 2, pv.views
    end

    test "referrer host is downcased and www-stripped" do
      record!(url: "https://example.com/", referrer: "HTTPS://WWW.Google.com/search")

      assert_equal 1, ReferrerDay.find_by(referrer_host: "google.com").views
    end

    test "blank referrer counts as direct" do
      record!(url: "https://example.com/", referrer: nil)
      record!(url: "https://example.com/", referrer: "")

      assert_equal 2, ReferrerDay.find_by(referrer_host: "direct").views
    end

    test "self-referral (referrer host == visited host) is skipped" do
      record!(url: "https://example.com/pricing", referrer: "https://example.com/other")

      assert_nil ReferrerDay.find_by(referrer_host: "example.com")
      assert_equal 0, ReferrerDay.count
    end

    test "self-referral with www on either side is still detected" do
      record!(url: "https://www.example.com/pricing", referrer: "https://example.com/other")

      assert_equal 0, ReferrerDay.count
    end

    test "referrer accumulates across visits" do
      record!(url: "https://example.com/", referrer: "https://google.com/search")
      record!(url: "https://example.com/", referrer: "https://google.com/other")

      assert_equal 2, ReferrerDay.find_by(referrer_host: "google.com").views
    end

    test "browser family classification" do
      cases = {
        "Mozilla/5.0 (Windows) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0 Safari/537.36 Edg/100.0" => "Edge",
        "Mozilla/5.0 AppleWebKit/537.36 Chrome/100.0 Safari/537.36 OPR/86.0" => "Opera",
        "Mozilla/5.0 AppleWebKit/537.36 Chrome/100.0 Safari/537.36" => "Chrome",
        "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15" => "Safari",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/115.0" => "Firefox",
        "SomeBot/1.0" => "Other",
        "" => "Other",
        nil => "Other"
      }

      cases.each do |ua, expected|
        assert_equal expected, StatsRecorder.browser_family(ua), "expected #{ua.inspect} to be #{expected}"
      end
    end

    test "device is derived via Recording.device_for" do
      record!(user_agent: "Mozilla/5.0 (Linux; Android 10) Mobile Chrome/100.0")

      assert_equal 1, BrowserDay.find_by(browser: "Chrome", device: "mobile").views
    end

    test "hashed visitor_ip_storage (default) never stores the raw IP" do
      ActiveAnalytics.configure { |c| c.visitor_ip_storage = :hashed }

      record!(ip: "9.8.7.6", user_agent: "Mozilla/5.0 Chrome/100.0")

      VisitorDay.all.each do |row|
        assert_not row.visitor_key.include?("9.8.7.6")
      end
      assert_equal 1, VisitorDay.count
    end

    test "raw visitor_ip_storage stores the IP as the visitor_key" do
      ActiveAnalytics.configure { |c| c.visitor_ip_storage = :raw }

      record!(ip: "9.8.7.6")

      assert VisitorDay.exists?(visitor_key: "9.8.7.6")
    end

    test "same visitor counted once per day, again the next day" do
      travel_to Time.zone.parse("2026-01-01 10:00:00") do
        record!(ip: "5.5.5.5", user_agent: "UA")
        record!(ip: "5.5.5.5", user_agent: "UA")
      end

      assert_equal 1, VisitorDay.where(date: Date.parse("2026-01-01")).count

      travel_to Time.zone.parse("2026-01-02 10:00:00") do
        record!(ip: "5.5.5.5", user_agent: "UA")
      end

      assert_equal 1, VisitorDay.where(date: Date.parse("2026-01-02")).count
      assert_equal 2, VisitorDay.count
    end

    test "bad url falls back to / via HeatmapAggregator.page_path" do
      record!(url: "not a valid url ?? with spaces")

      assert PageViewDay.exists?(page_path: "not a valid url ")
    end

    test "blank url falls back to /" do
      record!(url: nil)

      assert PageViewDay.exists?(page_path: "/")
    end

    test "never raises even with a nil user agent" do
      assert_nothing_raised do
        record!(user_agent: nil)
      end

      assert_equal 1, BrowserDay.find_by(browser: "Other").views
    end

    test "an internal failure is swallowed and logged, not raised" do
      assert_nothing_raised do
        StatsRecorder.record!(url: "https://example.com/", referrer: nil, ip: "1.2.3.4", user_agent: "UA", at: nil)
      end

      assert_equal 0, PageViewDay.count
    end

    test "host: override determines self-referral when url has no host" do
      record!(url: "/pricing", referrer: "https://example.com/other", host: "example.com")

      assert_equal 0, ReferrerDay.count
    end
  end
end
