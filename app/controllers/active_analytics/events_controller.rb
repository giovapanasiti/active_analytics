module ActiveAnalytics
  class EventsController < ApplicationController
    skip_forgery_protection

    def create
      return head :forbidden unless ActiveAnalytics.config.enabled

      raw_body = request.body.read
      return head :content_too_large if raw_body.bytesize > ActiveAnalytics.config.max_batch_bytes

      payload = begin
        JSON.parse(raw_body)
      rescue JSON::ParserError
        nil
      end
      return head :unprocessable_content unless valid_payload?(payload)

      uuid = payload["uuid"]
      seq = payload["seq"]
      events = payload["events"]
      meta = payload["meta"] || {}

      recording = find_or_create_recording(uuid, meta)

      if recording.event_batches.exists?(seq: seq)
        return head :no_content
      end

      begin
        recording.append_batch!(seq: seq, events: events, byte_size: raw_body.bytesize)
      rescue ActiveRecord::RecordNotUnique
        return head :no_content
      end

      enqueue_stale_analysis(recording)

      render json: { ok: true }, status: :created
    end

    private

    def valid_payload?(payload)
      return false unless payload.is_a?(Hash)

      uuid = payload["uuid"]
      seq = payload["seq"]
      events = payload["events"]

      uuid.is_a?(String) && uuid.match?(Recording::UUID_REGEX) &&
        seq.is_a?(Integer) && seq >= 0 &&
        events.is_a?(Array)
    end

    def find_or_create_recording(uuid, meta)
      Recording.find_by(uuid: uuid) || Recording.create!(
        uuid: uuid,
        started_at: Time.current,
        last_seen_at: Time.current,
        first_url: meta["url"],
        referrer: meta["referrer"],
        user_agent: request.user_agent,
        viewport_width: meta["vw"],
        viewport_height: meta["vh"],
        device: Recording.device_for(request.user_agent)
      )
    end

    def enqueue_stale_analysis(recording)
      return unless ActiveAnalytics.config.auto_analyze

      Recording.stale.unanalyzed.where.not(id: recording.id).limit(5).pluck(:id).each do |id|
        ActiveAnalytics::AnalyzeRecordingJob.perform_later(id)
      end
    end
  end
end
