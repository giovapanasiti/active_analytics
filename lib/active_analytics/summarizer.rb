module ActiveAnalytics
  # Builds a compact, PII-free digest of a recording (URLs, device, duration, page trail,
  # counters, and precomputed insight sentences — never raw event payloads such as input
  # values or click coordinates) and asks the configured AI backend for a short behavioral
  # summary + one actionable suggestion. A no-op when no backend is configured.
  class Summarizer
    MAX_SUMMARY_WORDS = 120

    attr_reader :recording

    def initialize(recording)
      @recording = recording
    end

    def call
      backend = resolve_backend
      return nil unless backend

      response = backend.call(build_prompt)
      return nil if response.nil?

      persist_summary(response)
      response
    end

    private

    def resolve_backend
      summarizer = ActiveAnalytics.config.ai_summarizer

      if summarizer.respond_to?(:call)
        summarizer
      elsif summarizer == :anthropic
        ->(prompt) { ActiveAnalytics::AnthropicClient.new.call(prompt) }
      end
    end

    def persist_summary(text)
      insight = recording.insights.find_or_initialize_by(kind: "summary")
      insight.severity = "info"
      insight.body = text
      insight.details = backend_details
      insight.save!
    end

    def backend_details
      if ActiveAnalytics.config.ai_summarizer == :anthropic
        { "backend" => "anthropic", "model" => ActiveAnalytics.config.anthropic_model }
      else
        { "backend" => "callable" }
      end
    end

    def build_prompt
      <<~PROMPT
        You are monitoring user behavior on a website from a recorded session. Based only on
        the digest below, write a behavioral summary of at most #{MAX_SUMMARY_WORDS} words plus
        one concrete, actionable suggestion for the team. Do not invent details that are not
        present in the digest.

        #{digest}
      PROMPT
    end

    def digest
      events = recording.events
      duration_seconds = (recording.duration_ms.to_i / 1000.0).round(1)
      page_trail = build_page_trail(events)
      insight_lines = recording.insights.where.not(kind: "summary").order(:ts_ms).map do |insight|
        format_insight_line(insight)
      end

      <<~DIGEST
        Recording digest:
        - first_url: #{recording.first_url}
        - device: #{recording.device}
        - duration: #{duration_seconds}s
        - pages visited: #{page_trail.join(" -> ")}
        - events: #{recording.events_count}, clicks: #{recording.clicks_count}, errors: #{recording.errors_count}
        - insights:
        #{insight_lines.map { |line| "  - #{line}" }.join("\n")}
      DIGEST
    end

    def build_page_trail(events)
      trail = [ recording.first_url ]
      events.each { |e| trail << e.dig("d", "url") if e["e"] == "nav" }
      trail.compact
    end

    def format_insight_line(insight)
      seconds = (insight.ts_ms.to_i / 1000.0).round(1)
      "at #{seconds}s [#{insight.kind}/#{insight.severity}] #{insight.body}"
    end
  end
end
