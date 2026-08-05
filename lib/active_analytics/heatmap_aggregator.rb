require "uri"

module ActiveAnalytics
  # Aggregates a single recording's captured events into per-page heatmap cells
  # (move/click density + scroll-depth) via HeatmapCell.bump!. Idempotent per
  # recording via Recording#heatmap_aggregated_at — running #aggregate! twice
  # only counts the recording once.
  class HeatmapAggregator
    X_BUCKETS = 50
    Y_BAND_PX = 25
    PAGEVIEW_FOLLOWUP_WINDOW_MS = 1000

    attr_reader :recording

    def initialize(recording)
      @recording = recording
    end

    def aggregate!
      return false if recording.heatmap_aggregated_at.present?

      reset_state!
      @cells = Hash.new(0)

      recording.events.each { |event| process_event(event) }
      flush_pageview!

      HeatmapCell.bump!(cell_rows)

      recording.page_paths = @visited_paths
      recording.heatmap_aggregated_at = Time.current
      recording.save!

      true
    end

    # URL normalization shared with the dashboard: path only, stripping
    # scheme/host/query/fragment. Falls back to the raw string up to the
    # first ?/# when the URL doesn't parse; empty result -> "/".
    def self.page_path(url)
      return "/" if url.nil?

      path =
        begin
          URI.parse(url).path
        rescue URI::Error
          url.to_s.split(/[?#]/, 2).first
        end

      path.to_s.empty? ? "/" : path
    end

    private

    def reset_state!
      @path = self.class.page_path(recording.first_url)
      @visited_paths = [ @path ]
      @device = recording.device.presence || "desktop"
      @vw = numeric(recording.viewport_width).to_i
      @vh = numeric(recording.viewport_height).to_i
      @scroll_x = 0
      @scroll_y = 0
      @max_depth = @vh
      @last_nav_t = nil
      @seen_first_snapshot = false
    end

    def process_event(event)
      d = event["d"] || {}
      t = event["t"].to_i

      case event["e"]
      when "snapshot" then process_snapshot(d, t)
      when "nav" then process_nav(d, t)
      when "scroll" then process_scroll(d)
      when "resize" then process_resize(d)
      when "move" then accumulate_point("move", d)
      when "click" then accumulate_point("click", d)
      end
    end

    # A snapshot updates the tracked viewport size unconditionally. It only
    # moves the pageview boundary when it carries a `url` and either there
    # was no preceding nav, or the preceding nav happened more than
    # PAGEVIEW_FOLLOWUP_WINDOW_MS ago (a nav is always immediately followed
    # by a fresh snapshot for the SAME pageview it just started).
    def process_snapshot(d, t)
      update_viewport(d["vw"], d["vh"])

      first_snapshot = !@seen_first_snapshot
      @seen_first_snapshot = true

      return if first_snapshot
      return if d["url"].blank?

      new_path = self.class.page_path(d["url"])

      if @last_nav_t && (t - @last_nav_t) <= PAGEVIEW_FOLLOWUP_WINDOW_MS
        @path = new_path
        visit!(new_path)
        @scroll_x = 0
        @scroll_y = 0
        @max_depth = @vh
      else
        transition_to(new_path)
        @last_nav_t = nil
      end
    end

    def process_nav(d, t)
      return if d["url"].blank?

      transition_to(self.class.page_path(d["url"]))
      @last_nav_t = t
    end

    def process_scroll(d)
      x = numeric(d["x"])
      y = numeric(d["y"])
      return unless x && y

      @scroll_x = x
      @scroll_y = y
      update_max_depth!
    end

    def process_resize(d)
      w = numeric(d["w"])
      h = numeric(d["h"])
      @vw = w if w
      @vh = h if h
      update_max_depth!
    end

    def accumulate_point(kind, d)
      x = numeric(d["x"])
      y = numeric(d["y"])
      return unless x && y
      return if @vw.to_i <= 0

      doc_y = y + @scroll_y
      x_bucket = ((x.to_f / @vw) * X_BUCKETS).floor.clamp(0, X_BUCKETS - 1)
      y_bucket = [ (doc_y.to_f / Y_BAND_PX).floor, 0 ].max

      bump_cell(kind, x_bucket, y_bucket)
    end

    def transition_to(new_path)
      flush_pageview!
      @path = new_path
      visit!(new_path)
      @scroll_x = 0
      @scroll_y = 0
      @max_depth = @vh
    end

    def visit!(path)
      @visited_paths << path unless @visited_paths.include?(path)
    end

    # Closes out the current pageview with a single scroll-depth cell bump.
    # Called on every pageview boundary and once more at end of stream.
    def flush_pageview!
      return if @vw.to_i <= 0

      y_bucket = [ (@max_depth.to_f / Y_BAND_PX).floor, 0 ].max
      bump_cell("scroll", 0, y_bucket)
    end

    def update_viewport(vw, vh)
      w = numeric(vw)
      h = numeric(vh)
      @vw = w if w
      @vh = h if h
    end

    def update_max_depth!
      candidate = [ @vh.to_i, @scroll_y.to_i + @vh.to_i ].max
      @max_depth = [ @max_depth.to_i, candidate ].max
    end

    def bump_cell(kind, x_bucket, y_bucket)
      key = [ @path, kind, x_bucket, y_bucket ]
      @cells[key] += 1
    end

    def cell_rows
      @cells.map do |(path, kind, x_bucket, y_bucket), count|
        { page_path: path, device: @device, kind: kind, x_bucket: x_bucket, y_bucket: y_bucket, count: count }
      end
    end

    def numeric(value)
      value.is_a?(Numeric) ? value : nil
    end
  end
end
