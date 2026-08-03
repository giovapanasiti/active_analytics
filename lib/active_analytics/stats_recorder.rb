require "digest"
require "uri"

module ActiveAnalytics
  # Records a single pageview into the anonymous daily rollups (views,
  # referrers, browsers/devices, unique visitors) used by the Overview
  # dashboard. Called for EVERY visitor, not just sampled session-recording
  # visitors -- see tasks/base-analytics-spec.md "Aggregation" for the frozen
  # contract. Never raises: failures are logged and swallowed so a bad
  # payload can never break the beacon request.
  class StatsRecorder
    def self.record!(url:, referrer:, ip:, user_agent:, host: nil, at: Time.current)
      new(url: url, referrer: referrer, ip: ip, user_agent: user_agent, host: host, at: at).record!
    end

    # Naive UA family classifier, order-sensitive: Edge/Opera UAs also contain
    # "Chrome"/"Safari", so they must be matched first.
    def self.browser_family(user_agent)
      return "Other" if user_agent.blank?

      case user_agent
      when /Edg\// then "Edge"
      when /OPR\/|Opera/ then "Opera"
      when /Chrome/ then "Chrome"
      when /Safari/ then "Safari"
      when /Firefox/ then "Firefox"
      else "Other"
      end
    end

    def initialize(url:, referrer:, ip:, user_agent:, host:, at:)
      @url = url
      @referrer = referrer
      @ip = ip
      @user_agent = user_agent
      @host = host
      @at = at
    end

    def record!
      date = @at.to_date

      PageViewDay.bump!(date: date, page_path: HeatmapAggregator.page_path(@url))
      bump_referrer!(date)
      bump_browser!(date)
      VisitorDay.mark!(date: date, visitor_key: visitor_key(date))

      true
    rescue StandardError => e
      Rails.logger.warn("[ActiveAnalytics] StatsRecorder failed: #{e.class}: #{e.message}")
      false
    end

    private

    def bump_referrer!(date)
      referrer_host = normalize_host(@referrer)
      return if referrer_host.present? && referrer_host == visited_host

      ReferrerDay.bump!(date: date, referrer_host: referrer_host.presence || "direct")
    end

    def bump_browser!(date)
      BrowserDay.bump!(
        date: date,
        browser: self.class.browser_family(@user_agent),
        device: Recording.device_for(@user_agent)
      )
    end

    def visited_host
      @visited_host ||= @host.presence || normalize_host(@url)
    end

    def normalize_host(value)
      return nil if value.blank?

      host = URI.parse(value).host
      return nil if host.blank?

      host.downcase.sub(/\Awww\./, "")
    rescue URI::Error, TypeError
      nil
    end

    def visitor_key(date)
      if ActiveAnalytics.config.visitor_ip_storage == :raw
        @ip.to_s
      else
        Digest::SHA256.hexdigest("#{date.iso8601}:#{@ip}:#{@user_agent}")
      end
    end
  end
end
