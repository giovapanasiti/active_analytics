module ActiveAnalytics
  class HeatmapsController < ApplicationController
    DEVICES = %w[desktop tablet mobile].freeze

    def index
      grouped = HeatmapCell.group(:page_path, :device, :kind).sum(:count)

      rows = {}
      grouped.each do |(path, device, kind), sum|
        row = (rows[path] ||= { path: path, pageviews: Hash.new(0), points: 0 })
        if kind == "scroll"
          row[:pageviews][device] += sum
        else
          row[:points] += sum
        end
      end

      @pages = rows.values.sort_by { |row| row[:path] }
    end

    def show
      @path = required_path
      return redirect_to(heatmaps_path, alert: "A page path is required.") unless @path

      @device = normalized_device
      @kind = normalized_kind
      @reference_recording = find_reference_recording

      @total_pageviews = HeatmapCell.where(page_path: @path, device: @device, kind: "scroll").sum(:count)
      @total_points = HeatmapCell.where(page_path: @path, device: @device, kind: %w[move click]).sum(:count)
    end

    def data
      path = required_path
      return render(json: { error: "path is required" }, status: :unprocessable_entity) unless path

      device = normalized_device
      kind = normalized_kind

      cells = HeatmapCell.where(page_path: path, device: device, kind: kind)

      if kind == "scroll"
        render json: scroll_payload(cells)
      else
        render json: points_payload(kind, cells)
      end
    end

    private

    def points_payload(kind, cells)
      rows = cells.pluck(:x_bucket, :y_bucket, :count)
      max = rows.map { |_, _, count| count }.max || 0
      { kind: kind, max: max, cells: rows }
    end

    def scroll_payload(cells)
      buckets = cells.order(:y_bucket).pluck(:y_bucket, :count)
      total = buckets.sum { |_, count| count }

      bands = buckets.each_index.map do |i|
        y_bucket = buckets[i][0]
        reached = buckets[i..].sum { |_, count| count }
        [ y_bucket, reached ]
      end

      { kind: "scroll", total: total, bands: bands }
    end

    def required_path
      params[:path].presence
    end

    def normalized_device
      device = params[:device]
      DEVICES.include?(device) ? device : "desktop"
    end

    def normalized_kind
      kind = params[:kind]
      HeatmapCell::KINDS.include?(kind) ? kind : "move"
    end

    # Newest recordings only: with many stored sessions a full-table Ruby scan for a
    # path match gets expensive, and an old snapshot is a worse backdrop anyway.
    REFERENCE_SCAN_LIMIT = 200

    # A recording's page_paths (populated by HeatmapAggregator) lists every page
    # visited during the session, so interior pages reached via in-session
    # navigation (not just session entry points) can serve as the backdrop.
    # Recordings analyzed before the page_paths migration fall back to matching
    # first_url only.
    def find_reference_recording
      by_page_paths(device: @device) ||
        by_page_paths(device: nil) ||
        by_first_url(device: @device) ||
        by_first_url(device: nil)
    end

    def by_page_paths(device:)
      like_needle = ActiveRecord::Base.sanitize_sql_like(%("#{@path}"))

      scope = Recording.where("page_paths LIKE ?", "%#{like_needle}%")
      scope = scope.where(device: device) if device
      scope.order(started_at: :desc).limit(REFERENCE_SCAN_LIMIT)
        .find { |recording| recording.page_paths&.include?(@path) }
    end

    def by_first_url(device:)
      scope = Recording.all
      scope = scope.where(device: device) if device
      scope.order(started_at: :desc).limit(REFERENCE_SCAN_LIMIT)
        .find { |recording| HeatmapAggregator.page_path(recording.first_url) == @path }
    end
  end
end
