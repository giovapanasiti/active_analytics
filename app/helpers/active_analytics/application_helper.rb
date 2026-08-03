module ActiveAnalytics
  module ApplicationHelper
    def active_analytics_tag
      return if !ActiveAnalytics.config.enabled || active_analytics_ignored_path?(request.path)

      config = {
        endpoint: active_analytics_endpoint,
        sampleRate: ActiveAnalytics.config.sample_rate,
        maskAllText: ActiveAnalytics.config.mask_all_text
      }

      config_tag = content_tag(:script, "window.ActiveAnalyticsConfig = #{json_escape(config.to_json)};".html_safe)
      recorder_tag = javascript_include_tag("active_analytics/recorder", defer: true)

      safe_join([ config_tag, recorder_tag ], "\n")
    end

    # Server-rendered inline SVG chart for the Overview dashboard: no JS, no
    # external deps. `series` is an array of {date:, views:, uniques:} for
    # every day in the window (already zero-filled by the controller).
    def stats_chart(series, width: 720, height: 160)
      series = Array(series)
      width = width.to_i
      height = height.to_i

      return stats_chart_svg(width, height, stats_chart_empty_content(width, height)) if series.empty?

      pad_top = 18
      pad_bottom = 24
      chart_height = [ height - pad_top - pad_bottom, 1 ].max
      chart_bottom = pad_top + chart_height
      slot_width = width.to_f / series.length

      max_value = series.map { |day| [ day[:views].to_i, day[:uniques].to_i ].max }.max.to_i
      scale = max_value.positive? ? (chart_height.to_f / max_value) : 0

      content = safe_join(
        [
          stats_chart_baseline(max_value, width, chart_bottom),
          *stats_chart_bars(series, slot_width, chart_bottom, scale),
          stats_chart_line(series, slot_width, chart_bottom, scale),
          stats_chart_labels(series, slot_width, chart_bottom),
          stats_chart_max_label(max_value),
          stats_chart_no_data_text(max_value, width, pad_top, chart_height)
        ].compact
      )

      stats_chart_svg(width, height, content)
    end

    private

    def stats_chart_svg(width, height, content)
      content_tag(:svg, content,
        viewBox: "0 0 #{width} #{height}", width: width, height: height,
        class: "aa-stats-chart", role: "img",
        "aria-label": "Page views and visitors over time")
    end

    def stats_chart_empty_content(width, height)
      content_tag(:text, "No data", x: width / 2, y: height / 2,
        class: "aa-chart__no-data", "text-anchor": "middle")
    end

    def stats_chart_bars(series, slot_width, chart_bottom, scale)
      bar_width = [ slot_width - 2, 1 ].max

      series.each_with_index.map do |day, index|
        views = day[:views].to_i
        uniques = day[:uniques].to_i
        x = (index * slot_width).round(2)
        bar_height = (views * scale).round(2)
        y = (chart_bottom - bar_height).round(2)
        title = "#{day[:date].strftime('%b %-d')}: #{views} view#{'s' unless views == 1}, " \
          "#{uniques} visitor#{'s' unless uniques == 1}"

        content_tag(:rect, content_tag(:title, title),
          x: x, y: y, width: bar_width.round(2), height: bar_height, class: "aa-chart__bar")
      end
    end

    def stats_chart_line(series, slot_width, chart_bottom, scale)
      points = series.each_with_index.map do |day, index|
        x = (index * slot_width + slot_width / 2).round(2)
        y = (chart_bottom - (day[:uniques].to_i * scale)).round(2)
        "#{x},#{y}"
      end

      content_tag(:polyline, nil, points: points.join(" "), fill: "none", class: "aa-chart__line")
    end

    def stats_chart_labels(series, slot_width, chart_bottom)
      last_index = series.length - 1
      indices = (0..last_index).select { |i| i.zero? || i == last_index || (i % 7).zero? }.uniq

      safe_join(indices.map { |index|
        x = (index * slot_width + slot_width / 2).round(2)
        content_tag(:text, series[index][:date].strftime("%b %-d"), x: x, y: chart_bottom + 16,
          class: "aa-chart__label", "text-anchor": "middle")
      })
    end

    def stats_chart_max_label(max_value)
      return unless max_value.positive?

      content_tag(:text, "max #{max_value}", x: 4, y: 12, class: "aa-chart__max-label")
    end

    def stats_chart_baseline(max_value, width, chart_bottom)
      return unless max_value.zero?

      content_tag(:line, nil, x1: 0, y1: chart_bottom, x2: width, y2: chart_bottom, class: "aa-chart__baseline")
    end

    def stats_chart_no_data_text(max_value, width, pad_top, chart_height)
      return unless max_value.zero?

      content_tag(:text, "No data", x: width / 2, y: pad_top + (chart_height / 2),
        class: "aa-chart__no-data", "text-anchor": "middle")
    end

    def active_analytics_endpoint
      prefix = ActiveAnalytics::Engine.routes.find_script_name({}) || ""
      "#{prefix}/events"
    end

    def active_analytics_ignored_path?(path)
      Array(ActiveAnalytics.config.ignored_paths).any? do |pattern|
        pattern.is_a?(Regexp) ? pattern.match?(path) : path.start_with?(pattern.to_s)
      end
    end
  end
end
