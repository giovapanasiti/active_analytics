require "test_helper"

class ActiveAnalyticsTagTest < ActionDispatch::IntegrationTest
  teardown do
    ActiveAnalytics.reset_configuration!
  end

  test "renders config and recorder script tag on the host page" do
    get "/"

    assert_response :success
    assert_match(/window\.ActiveAnalyticsConfig/, response.body)
    assert_match(/"endpoint":"\/analytics\/events"/, response.body)
    assert_match(/<script[^>]*active_analytics\/recorder/, response.body)
  end

  test "omits the tag when recording is disabled" do
    ActiveAnalytics.configure { |config| config.enabled = false }

    get "/"

    assert_response :success
    assert_no_match(/window\.ActiveAnalyticsConfig/, response.body)
  end

  test "omits the tag on ignored paths" do
    ActiveAnalytics.configure { |config| config.ignored_paths = [ "/" ] }

    get "/"

    assert_response :success
    assert_no_match(/window\.ActiveAnalyticsConfig/, response.body)
  end
end
