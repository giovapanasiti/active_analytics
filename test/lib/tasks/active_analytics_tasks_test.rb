require "test_helper"
require "rake"

module ActiveAnalytics
  class ActiveAnalyticsTasksTest < ActiveSupport::TestCase
    setup do
      Rails.application.load_tasks unless Rake::Task.task_defined?("active_analytics:purge")
      Rake::Task["active_analytics:purge"].reenable
      Rake::Task["active_analytics:analyze"].reenable
    end

    teardown do
      ActiveAnalytics.reset_configuration!
    end

    test "purge deletes VisitorDay rows older than retention_days but keeps recent ones" do
      ActiveAnalytics.configure { |c| c.retention_days = 30 }

      VisitorDay.insert_all([
        { date: 40.days.ago.to_date, visitor_key: "old" },
        { date: 5.days.ago.to_date, visitor_key: "recent" }
      ])

      out, = capture_io { Rake::Task["active_analytics:purge"].invoke }

      assert_equal 1, VisitorDay.count
      assert VisitorDay.exists?(visitor_key: "recent")
      assert_not VisitorDay.exists?(visitor_key: "old")
      assert_match(/Purged 1 visitor day\(s\)/, out)
    end

    test "analyze reports when there is nothing to do and explains still-active sessions" do
      Recording.create!(
        uuid: SecureRandom.uuid, started_at: Time.current, last_seen_at: Time.current
      )

      out, = capture_io { Rake::Task["active_analytics:analyze"].invoke }

      assert_match(/Nothing to analyze/, out)
      assert_match(/1 unanalyzed recording\(s\) are still active/, out)
    end

    test "analyze processes stale recordings and prints a line per recording" do
      recording = Recording.create!(
        uuid: SecureRandom.uuid, first_url: "http://example.com/checkout",
        started_at: 2.hours.ago, last_seen_at: 2.hours.ago
      )

      out, = capture_io { Rake::Task["active_analytics:analyze"].invoke }

      assert recording.reload.analyzed_at.present?
      assert_match(%r{Analyzed recording ##{recording.id} \(http://example.com/checkout\)}, out)
      assert_match(/Analyzed 1 recording\(s\)\./, out)
    end

    test "purge does not touch the anonymous rollups (PageViewDay/ReferrerDay/BrowserDay)" do
      ActiveAnalytics.configure { |c| c.retention_days = 30 }

      PageViewDay.bump!(date: 40.days.ago.to_date, page_path: "/old")
      ReferrerDay.bump!(date: 40.days.ago.to_date, referrer_host: "direct")
      BrowserDay.bump!(date: 40.days.ago.to_date, browser: "Chrome", device: "desktop")

      capture_io { Rake::Task["active_analytics:purge"].invoke }

      assert PageViewDay.exists?(page_path: "/old")
      assert ReferrerDay.exists?(referrer_host: "direct")
      assert BrowserDay.exists?(browser: "Chrome", device: "desktop")
    end
  end
end
