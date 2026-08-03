require "test_helper"

class ActiveAnalyticsTest < ActiveSupport::TestCase
  test "it has a version number" do
    assert ActiveAnalytics::VERSION
  end

  test "config exposes the documented defaults" do
    ActiveAnalytics.reset_configuration!
    config = ActiveAnalytics.config

    assert_equal true, config.enabled
    assert_equal 1.0, config.sample_rate
    assert_equal false, config.mask_all_text
    assert_equal [], config.ignored_paths
    assert_equal 30, config.retention_days
    assert_equal 30 * 60, config.session_timeout
    assert_equal 1_000_000, config.max_batch_bytes
    assert_equal true, config.auto_analyze
    assert_equal :hashed, config.visitor_ip_storage
    assert_nil config.ai_summarizer
    assert_equal "claude-opus-5", config.anthropic_model
  end

  test "configure yields the memoized config and reset_configuration! restores defaults" do
    ActiveAnalytics.configure do |config|
      config.enabled = false
    end

    assert_equal false, ActiveAnalytics.config.enabled

    ActiveAnalytics.reset_configuration!

    assert_equal true, ActiveAnalytics.config.enabled
  end
end
