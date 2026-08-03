require "test_helper"

module ActiveAnalytics
  class StatsChartTest < ActionView::TestCase
    include ActiveAnalytics::ApplicationHelper

    test "renders one bar per day and a title tooltip with views and visitors" do
      today = Date.current
      series = [
        { date: today - 1, views: 10, uniques: 4 },
        { date: today, views: 20, uniques: 8 }
      ]

      svg = stats_chart(series)

      assert svg.html_safe?
      assert_equal 2, svg.scan(/<rect\b/).size
      assert_includes svg, "#{today.strftime('%b %-d')}: 20 views, 8 visitors"
      assert_includes svg, "<polyline"
    end

    test "handles an empty series gracefully without raising" do
      svg = stats_chart([])

      assert svg.html_safe?
      assert_equal 0, svg.scan(/<rect\b/).size
      assert_includes svg, "No data"
    end

    test "handles an all-zero series with a flat baseline and no-data text" do
      today = Date.current
      series = (0..2).map { |offset| { date: today - offset, views: 0, uniques: 0 } }

      svg = stats_chart(series)

      assert_equal 3, svg.scan(/<rect\b/).size
      assert_includes svg, "<line"
      assert_includes svg, "No data"
    end
  end
end
