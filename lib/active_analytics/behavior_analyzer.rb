module ActiveAnalytics
  # Pure-Ruby heuristic analyzer over a recording's captured events. Detects a fixed set of
  # frustration signals (rage clicks, dead clicks, cursor thrash, navigation u-turns, form
  # abandonment, JS errors), persists them as Insight rows, and rolls them up into a single
  # 0..100 frustration_score stored on the recording.
  class BehaviorAnalyzer
    RAGE_CLICK_WINDOW_MS = 700
    RAGE_CLICK_RADIUS_PX = 30
    RAGE_CLICK_MIN_COUNT = 3

    DEAD_CLICK_WINDOW_MS = 1000
    DEAD_CLICK_FOLLOWUP_EVENTS = %w[mutation nav input].freeze

    THRASH_WINDOW_MS = 1500
    THRASH_MIN_CHANGES = 6
    THRASH_MIN_DISTANCE_PX = 800

    U_TURN_WINDOW_MS = 5000

    FORM_ABANDON_TRAILING_MS = 10_000
    FORM_ABANDON_SUBMIT_LABEL_REGEX = /submit|send|save|continue|confirm|checkout|sign\s?up|log\s?in|register/i

    JS_ERROR_CAP = 10

    FRUSTRATION_WEIGHTS = {
      "rage_click" => 15,
      "dead_click" => 5,
      "thrash" => 5,
      "u_turn" => 5,
      "form_abandon" => 10,
      "js_error" => 10
    }.freeze

    attr_reader :recording

    def initialize(recording)
      @recording = recording
    end

    def analyze!
      events = recording.events

      recording.insights.where.not(kind: "summary").delete_all

      clicks = events.select { |e| e["e"] == "click" }
      moves = events.select { |e| e["e"] == "move" }

      rage_bursts = detect_rage_bursts(clicks)
      rage_click_ids = rage_bursts.flat_map { |burst| burst[:clicks] }.map(&:object_id)

      insight_attrs = []
      insight_attrs.concat(rage_bursts.map { |burst| rage_click_insight_attrs(burst) })
      insight_attrs.concat(detect_dead_clicks(clicks, events, rage_click_ids))
      insight_attrs.concat(detect_thrash(moves))
      insight_attrs.concat(detect_u_turns(events))
      insight_attrs.concat(detect_form_abandon(events))
      insight_attrs.concat(detect_js_errors(events))

      insight_attrs.each { |attrs| recording.insights.create!(attrs) }

      recording.frustration_score = compute_frustration_score(insight_attrs)
      recording.analyzed_at = Time.current
      recording.save!
    end

    private

    # --- rage_click -----------------------------------------------------

    def detect_rage_bursts(clicks)
      bursts = []
      i = 0
      n = clicks.size

      while i < n
        anchor = clicks[i]
        burst = [ anchor ]
        j = i + 1

        while j < n && (clicks[j]["t"].to_i - anchor["t"].to_i) <= RAGE_CLICK_WINDOW_MS
          burst << clicks[j] if within_radius?(clicks[j], anchor)
          j += 1
        end

        if burst.size >= RAGE_CLICK_MIN_COUNT
          bursts << { clicks: burst }
          i = j
        else
          i += 1
        end
      end

      bursts
    end

    def within_radius?(click, anchor)
      dx = click.dig("d", "x").to_f - anchor.dig("d", "x").to_f
      dy = click.dig("d", "y").to_f - anchor.dig("d", "y").to_f
      Math.hypot(dx, dy) <= RAGE_CLICK_RADIUS_PX
    end

    def rage_click_insight_attrs(burst)
      first = burst[:clicks].first
      count = burst[:clicks].size
      x = first.dig("d", "x")
      y = first.dig("d", "y")

      {
        kind: "rage_click",
        severity: "critical",
        ts_ms: first["t"],
        details: { "count" => count, "x" => x, "y" => y },
        body: "Rage click: #{count} rapid clicks at (#{x}, #{y})"
      }
    end

    # --- dead_click -------------------------------------------------------

    def detect_dead_clicks(clicks, events, rage_click_ids)
      clicks.filter_map do |click|
        next if rage_click_ids.include?(click.object_id)

        window_end = click["t"].to_i + DEAD_CLICK_WINDOW_MS
        followed_up = events.any? do |e|
          DEAD_CLICK_FOLLOWUP_EVENTS.include?(e["e"]) &&
            e["t"].to_i > click["t"].to_i && e["t"].to_i <= window_end
        end

        next if followed_up

        dead_click_insight_attrs(click)
      end
    end

    def dead_click_insight_attrs(click)
      label = click.dig("d", "label")
      label = "an element" if label.nil? || label.empty?

      {
        kind: "dead_click",
        severity: "warning",
        ts_ms: click["t"],
        details: { "x" => click.dig("d", "x"), "y" => click.dig("d", "y"), "label" => click.dig("d", "label") },
        body: "Dead click: no reaction after clicking #{label}"
      }
    end

    # --- thrash -----------------------------------------------------------

    def detect_thrash(moves)
      insights = []
      i = 0
      n = moves.size

      while i < n - 1
        j = i
        changes = 0
        distance = 0.0
        last_dx = nil

        while j < n - 1 && (moves[j + 1]["t"].to_i - moves[i]["t"].to_i) <= THRASH_WINDOW_MS
          dx = moves[j + 1].dig("d", "x").to_f - moves[j].dig("d", "x").to_f
          dy = moves[j + 1].dig("d", "y").to_f - moves[j].dig("d", "y").to_f
          distance += Math.hypot(dx, dy)

          if last_dx && !last_dx.zero? && !dx.zero? && (dx <=> 0) != (last_dx <=> 0)
            changes += 1
          end
          last_dx = dx unless dx.zero?

          j += 1
        end

        if changes >= THRASH_MIN_CHANGES && distance > THRASH_MIN_DISTANCE_PX
          insights << thrash_insight_attrs(moves[i], moves[j], changes, distance)
          i = j + 1
        else
          i += 1
        end
      end

      insights
    end

    def thrash_insight_attrs(first_move, last_move, changes, distance)
      {
        kind: "thrash",
        severity: "warning",
        ts_ms: first_move["t"],
        details: {
          "changes" => changes,
          "span_ms" => last_move["t"].to_i - first_move["t"].to_i,
          "distance" => distance.round
        },
        body: "Erratic cursor movement: #{changes} direction changes across #{distance.round}px"
      }
    end

    # --- u_turn -------------------------------------------------------------

    def detect_u_turns(events)
      navs = events.select { |e| e["e"] == "nav" }
      return [] if navs.size < 2

      trail = [ recording.first_url ] + navs.map { |e| e.dig("d", "url") }
      insights = []

      navs.each_index do |i|
        next unless i + 1 < navs.size

        prev_url = trail[i]
        went_to = trail[i + 1]
        back_to = trail[i + 2]

        next unless back_to == prev_url && back_to != went_to
        next unless (navs[i + 1]["t"].to_i - navs[i]["t"].to_i) <= U_TURN_WINDOW_MS

        insights << u_turn_insight_attrs(navs[i], went_to, back_to)
      end

      insights
    end

    def u_turn_insight_attrs(first_nav, went_to, back_to)
      {
        kind: "u_turn",
        severity: "warning",
        ts_ms: first_nav["t"],
        details: { "url" => went_to, "back_to" => back_to },
        body: "U-turn: navigated to #{went_to} then back to #{back_to}"
      }
    end

    # --- form_abandon ---------------------------------------------------------

    def detect_form_abandon(events)
      inputs = events.select { |e| e["e"] == "input" }
      return [] if inputs.empty?

      last_input = inputs.max_by { |e| e["t"].to_i }

      nav_after_input = events.any? { |e| e["e"] == "nav" && e["t"].to_i > last_input["t"].to_i }
      return [] if nav_after_input

      last_t = (events.filter_map { |e| e["t"] }.max || last_input["t"]).to_i
      trailing_start = last_t - FORM_ABANDON_TRAILING_MS

      submitted = events.any? do |e|
        e["e"] == "click" && e["t"].to_i >= trailing_start &&
          FORM_ABANDON_SUBMIT_LABEL_REGEX.match?(e.dig("d", "label").to_s)
      end
      return [] if submitted

      [ form_abandon_insight_attrs(inputs, last_input) ]
    end

    def form_abandon_insight_attrs(inputs, last_input)
      {
        kind: "form_abandon",
        severity: "warning",
        ts_ms: last_input["t"],
        details: { "inputs_count" => inputs.size, "last_input_ts" => last_input["t"] },
        body: "Form abandoned: #{inputs.size} field(s) filled in without submitting"
      }
    end

    # --- js_error -----------------------------------------------------------

    def detect_js_errors(events)
      events.select { |e| e["e"] == "error" }.first(JS_ERROR_CAP).map do |e|
        {
          kind: "js_error",
          severity: "critical",
          ts_ms: e["t"],
          details: e["d"] || {},
          body: "JS error: #{e.dig("d", "message")}"
        }
      end
    end

    # --- frustration score ----------------------------------------------------

    def compute_frustration_score(insight_attrs)
      counts = Hash.new(0)
      insight_attrs.each { |attrs| counts[attrs[:kind]] += 1 }

      raw = FRUSTRATION_WEIGHTS.sum { |kind, weight| weight * counts[kind] }
      raw.clamp(0, 100)
    end
  end
end
