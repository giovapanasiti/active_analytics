require "test_helper"

module ActiveAnalytics
  class AnthropicClientTest < ActiveSupport::TestCase
    FakeResponse = Struct.new(:code, :body)

    teardown do
      ActiveAnalytics.reset_configuration!
    end

    test "returns the text content on a 200 response and builds a correctly-shaped request" do
      captured_request = nil
      http = lambda do |_uri, request|
        captured_request = request
        FakeResponse.new("200", JSON.generate({
          "stop_reason" => "end_turn",
          "content" => [ { "type" => "text", "text" => "Hello from Claude" } ]
        }))
      end

      ActiveAnalytics.configure do |config|
        config.anthropic_api_key = "sk-test-key"
        config.anthropic_model = "claude-opus-5"
      end

      result = AnthropicClient.new(http: http).call("Summarize this session")

      assert_equal "Hello from Claude", result
      assert_equal "sk-test-key", captured_request["x-api-key"]
      assert_equal "2023-06-01", captured_request["anthropic-version"]
      assert_equal "application/json", captured_request["content-type"]

      body = JSON.parse(captured_request.body)
      assert_equal "claude-opus-5", body["model"]
      assert_equal 1024, body["max_tokens"]
      assert_equal [ { "role" => "user", "content" => "Summarize this session" } ], body["messages"]
      assert_not body.key?("temperature")
      assert_not body.key?("top_p")
    end

    test "returns nil when stop_reason is refusal" do
      http = lambda do |_uri, _request|
        FakeResponse.new("200", JSON.generate({ "stop_reason" => "refusal", "content" => [] }))
      end

      assert_nil AnthropicClient.new(http: http).call("prompt")
    end

    test "returns nil on a non-200 response" do
      http = ->(_uri, _request) { FakeResponse.new("500", "Internal Server Error") }

      assert_nil AnthropicClient.new(http: http).call("prompt")
    end

    test "returns nil when the http seam raises" do
      http = ->(_uri, _request) { raise SocketError, "getaddrinfo failed" }

      assert_nil AnthropicClient.new(http: http).call("prompt")
    end
  end
end
