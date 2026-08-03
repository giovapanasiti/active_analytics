require "net/http"
require "uri"
require "json"

module ActiveAnalytics
  # Zero-dependency client for the Anthropic Messages API. No SDK, just Net::HTTP, so the
  # engine never forces a dependency on host apps that don't use AI summaries.
  class AnthropicClient
    ENDPOINT = URI("https://api.anthropic.com/v1/messages")
    ANTHROPIC_VERSION = "2023-06-01"
    MAX_TOKENS = 1024
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 10

    # `http:` is a seam: a callable `(uri, request) -> Net::HTTPResponse`. Defaults to a real
    # Net::HTTP.start call. Tests inject a fake to avoid webmock / real network calls.
    def initialize(http: method(:perform_request))
      @http = http
    end

    def call(prompt)
      request = build_request(prompt)
      response = @http.call(ENDPOINT, request)

      return warn_nil("Anthropic API returned #{response.code}") unless response.code.to_i == 200

      body = JSON.parse(response.body)
      return warn_nil("Anthropic API refused the request") if body["stop_reason"] == "refusal"

      text_block = (body["content"] || []).find { |block| block["type"] == "text" }
      text_block&.dig("text")
    rescue StandardError => e
      warn_nil("Anthropic API request failed: #{e.class}: #{e.message}")
    end

    private

    def build_request(prompt)
      request = Net::HTTP::Post.new(ENDPOINT)
      request["x-api-key"] = ActiveAnalytics.config.anthropic_api_key
      request["anthropic-version"] = ANTHROPIC_VERSION
      request["content-type"] = "application/json"
      request.body = JSON.generate({
        model: ActiveAnalytics.config.anthropic_model,
        max_tokens: MAX_TOKENS,
        messages: [ { role: "user", content: prompt } ]
      })
      request
    end

    def perform_request(uri, request)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(request)
      end
    end

    def warn_nil(message)
      Rails.logger.warn("[ActiveAnalytics::AnthropicClient] #{message}")
      nil
    end
  end
end
