module ActiveAnalytics
  class StatsController < ApplicationController
    DEFAULT_DAYS = 30
    MIN_DAYS = 1
    MAX_DAYS = 365
    TOP_LIMIT = 10

    def index
      @days = normalized_days
      @window = (Date.current - (@days - 1))..Date.current

      @total_views = PageViewDay.where(date: @window).sum(:views)
      @total_uniques = VisitorDay.where(date: @window).count
      @views_per_visitor = @total_uniques.positive? ? (@total_views.to_f / @total_uniques).round(1) : nil

      @series = build_series

      @top_pages = top(PageViewDay, :page_path)
      @top_referrers = top(ReferrerDay, :referrer_host)
      @browsers = grouped_desc(BrowserDay, :browser)
      @devices = grouped_desc(BrowserDay, :device)
    end

    private

    def normalized_days
      days = params[:days].to_i
      days = DEFAULT_DAYS if days <= 0
      days.clamp(MIN_DAYS, MAX_DAYS)
    end

    def build_series
      views_by_date = PageViewDay.where(date: @window).group(:date).sum(:views)
      uniques_by_date = VisitorDay.where(date: @window).group(:date).count

      @window.map do |date|
        { date: date, views: views_by_date[date].to_i, uniques: uniques_by_date[date].to_i }
      end
    end

    def top(model, column)
      grouped_desc(model, column).first(TOP_LIMIT)
    end

    def grouped_desc(model, column)
      model.where(date: @window).group(column).sum(:views).sort_by { |_, views| -views }
    end
  end
end
