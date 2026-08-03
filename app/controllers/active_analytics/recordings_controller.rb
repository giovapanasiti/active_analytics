module ActiveAnalytics
  class RecordingsController < ApplicationController
    PER_PAGE = 25

    before_action :set_recording, only: [ :show, :destroy, :events, :analyze ]

    def index
      @recordings = filtered_recordings.order(started_at: :desc)

      page = params[:page].to_i
      @page = page >= 1 ? page : 1
      offset = (@page - 1) * PER_PAGE

      records = @recordings.offset(offset).limit(PER_PAGE + 1).to_a
      @has_next = records.size > PER_PAGE
      @recordings = records.first(PER_PAGE)
      @has_prev = @page > 1
    end

    def show
      @insights = @recording.insights.to_a.sort_by { |i| i.ts_ms.nil? ? Float::INFINITY : i.ts_ms }
      @summary = @insights.find { |i| i.kind == "summary" }

      @pages = [ @recording.first_url ].compact
      @recording.events.each do |event|
        @pages << event["d"]["url"] if event["e"] == "nav" && event.dig("d", "url").present?
      end
    end

    def destroy
      @recording.destroy
      redirect_to recordings_path, notice: "Recording deleted."
    end

    def events
      render json: {
        recording: {
          uuid: @recording.uuid,
          started_at: @recording.started_at,
          duration_ms: @recording.duration_ms,
          viewport_width: @recording.viewport_width,
          viewport_height: @recording.viewport_height
        },
        events: @recording.events
      }
    end

    def analyze
      ActiveAnalytics::BehaviorAnalyzer.new(@recording).analyze!
      ActiveAnalytics::Summarizer.new(@recording).call
      ActiveAnalytics::HeatmapAggregator.new(@recording).aggregate! if defined?(ActiveAnalytics::HeatmapAggregator)

      redirect_to recording_path(@recording), notice: "Analysis complete."
    end

    private

    def set_recording
      @recording = Recording.find(params[:id])
    end

    def filtered_recordings
      recordings = Recording.all
      recordings = recordings.where("first_url LIKE ?", "%#{Recording.sanitize_sql_like(params[:q])}%") if params[:q].present?
      recordings = recordings.where("errors_count > 0") if params[:errors] == "1"

      if params[:min_duration].present? && (min_seconds = params[:min_duration].to_i) > 0
        recordings = recordings.where("duration_ms >= ?", min_seconds * 1000)
      end

      if params[:from].present? && (from_date = safe_parse_date(params[:from]))
        recordings = recordings.where("started_at >= ?", from_date.beginning_of_day)
      end

      if params[:to].present? && (to_date = safe_parse_date(params[:to]))
        recordings = recordings.where("started_at <= ?", to_date.end_of_day)
      end

      recordings
    end

    def safe_parse_date(value)
      Date.parse(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
