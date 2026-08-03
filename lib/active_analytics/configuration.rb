module ActiveAnalytics
  class Configuration
    attr_accessor :enabled, :sample_rate, :mask_all_text, :ignored_paths, :retention_days,
                  :session_timeout, :max_batch_bytes, :auto_analyze,
                  :ai_summarizer, :anthropic_api_key, :anthropic_model, :visitor_ip_storage

    def initialize
      @enabled = true
      @sample_rate = 1.0
      @mask_all_text = false
      @ignored_paths = []
      @retention_days = 30
      @session_timeout = 30 * 60
      @max_batch_bytes = 1_000_000
      @auto_analyze = true
      @ai_summarizer = nil
      @anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
      @anthropic_model = "claude-opus-5"
      @visitor_ip_storage = :hashed # :hashed (daily SHA256 digest) or :raw (store the IP)
    end
  end
end
