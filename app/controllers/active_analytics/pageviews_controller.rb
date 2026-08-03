module ActiveAnalytics
  class PageviewsController < ApplicationController
    skip_forgery_protection

    MAX_BODY_BYTES = 8.kilobytes

    def create
      return head :forbidden unless ActiveAnalytics.config.enabled

      raw_body = request.body.read
      return head :content_too_large if raw_body.bytesize > MAX_BODY_BYTES

      payload = begin
        JSON.parse(raw_body)
      rescue JSON::ParserError
        nil
      end
      return head :unprocessable_content unless valid_payload?(payload)

      StatsRecorder.record!(
        url: payload["url"],
        referrer: payload["referrer"],
        ip: request.remote_ip,
        user_agent: request.user_agent
      )

      head :created
    end

    private

    def valid_payload?(payload)
      payload.is_a?(Hash) && payload["url"].is_a?(String)
    end
  end
end
