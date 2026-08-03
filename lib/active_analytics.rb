require "active_analytics/version"
require "active_analytics/configuration"
require "active_analytics/engine"
require "active_analytics/behavior_analyzer"
require "active_analytics/anthropic_client"
require "active_analytics/summarizer"
require "active_analytics/heatmap_aggregator"
require "active_analytics/stats_recorder"

module ActiveAnalytics
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def reset_configuration!
      @config = Configuration.new
    end
  end
end
