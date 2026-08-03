require "test_helper"

module ActiveAnalytics
  class BehaviorAnalyzerTest < ActiveSupport::TestCase
    teardown do
      ActiveAnalytics.reset_configuration!
    end

    def build_recording(uuid: SecureRandom.uuid, first_url: "https://example.com/start")
      Recording.create!(
        uuid: uuid,
        started_at: Time.current,
        last_seen_at: Time.current,
        user_agent: "Mozilla/5.0",
        first_url: first_url
      )
    end

    def record_events(recording, events, seq: 0)
      recording.append_batch!(seq: seq, events: events, byte_size: 10)
    end

    def click(t, x: 10, y: 10, id: 1, label: "Button")
      { "t" => t, "e" => "click", "d" => { "x" => x, "y" => y, "id" => id, "label" => label } }
    end

    def move(t, x:, y:)
      { "t" => t, "e" => "move", "d" => { "x" => x, "y" => y } }
    end

    def nav(t, url:)
      { "t" => t, "e" => "nav", "d" => { "url" => url, "title" => "" } }
    end

    def mutation(t)
      { "t" => t, "e" => "mutation", "d" => { "adds" => [] } }
    end

    def input(t, id: 1, value: "x")
      { "t" => t, "e" => "input", "d" => { "id" => id, "value" => value } }
    end

    def error_event(t, message: "Boom")
      { "t" => t, "e" => "error", "d" => { "message" => message, "source" => "app.js", "line" => 1 } }
    end

    # --- rage_click ---------------------------------------------------------

    test "rage_click fires for 3+ clicks within 700ms and 30px" do
      recording = build_recording
      record_events(recording, [
        click(0, x: 100, y: 100),
        click(200, x: 105, y: 102),
        click(400, x: 98, y: 99)
      ])

      BehaviorAnalyzer.new(recording).analyze!

      insight = recording.insights.find_by(kind: "rage_click")
      assert insight
      assert_equal "critical", insight.severity
      assert_equal 0, insight.ts_ms
      assert_equal 3, insight.details["count"]
      assert recording.analyzed_at.present?
    end

    test "rage_click does not fire below the minimum click count" do
      recording = build_recording
      record_events(recording, [
        click(0, x: 100, y: 100),
        click(200, x: 105, y: 102)
      ])

      BehaviorAnalyzer.new(recording).analyze!

      assert_nil recording.insights.find_by(kind: "rage_click")
    end

    test "rage_click does not fire when clicks are spatially spread beyond the radius" do
      recording = build_recording
      record_events(recording, [
        click(0, x: 0, y: 0),
        click(100, x: 200, y: 200),
        click(300, x: 400, y: 400)
      ])

      BehaviorAnalyzer.new(recording).analyze!

      assert_nil recording.insights.find_by(kind: "rage_click")
    end

    # --- dead_click -----------------------------------------------------------

    test "dead_click fires when no mutation/nav/input follows within 1000ms" do
      recording = build_recording
      record_events(recording, [ click(0), move(1500, x: 1, y: 1) ])

      BehaviorAnalyzer.new(recording).analyze!

      insight = recording.insights.find_by(kind: "dead_click")
      assert insight
      assert_equal "warning", insight.severity
      assert_equal 0, insight.ts_ms
    end

    test "dead_click does not fire when a mutation follows within the window" do
      recording = build_recording
      record_events(recording, [ click(0), mutation(200) ])

      BehaviorAnalyzer.new(recording).analyze!

      assert_nil recording.insights.find_by(kind: "dead_click")
    end

    test "dead_click skips clicks that are part of a rage burst" do
      recording = build_recording
      record_events(recording, [
        click(0, x: 100, y: 100),
        click(200, x: 102, y: 101),
        click(400, x: 99, y: 100)
      ])

      BehaviorAnalyzer.new(recording).analyze!

      assert recording.insights.exists?(kind: "rage_click")
      assert_not recording.insights.exists?(kind: "dead_click")
    end

    # --- thrash -----------------------------------------------------------------

    test "thrash fires on rapid direction changes over distance" do
      recording = build_recording
      xs = [ 0, 150, 0, 150, 0, 150, 0, 150 ]
      moves = xs.each_with_index.map { |x, i| move(i * 100, x: x, y: 0) }
      record_events(recording, moves)

      BehaviorAnalyzer.new(recording).analyze!

      insight = recording.insights.find_by(kind: "thrash")
      assert insight
      assert_equal "warning", insight.severity
      assert_operator insight.details["changes"], :>=, BehaviorAnalyzer::THRASH_MIN_CHANGES
      assert_operator insight.details["distance"], :>, BehaviorAnalyzer::THRASH_MIN_DISTANCE_PX
    end

    test "thrash does not fire for smooth, low-distance movement" do
      recording = build_recording
      moves = [ move(0, x: 0, y: 0), move(100, x: 50, y: 0), move(200, x: 100, y: 0) ]
      record_events(recording, moves)

      BehaviorAnalyzer.new(recording).analyze!

      assert_nil recording.insights.find_by(kind: "thrash")
    end

    # --- u_turn -----------------------------------------------------------------

    test "u_turn fires when navigating back to the previous url within 5000ms" do
      recording = build_recording(first_url: "https://example.com/a")
      record_events(recording, [
        nav(1000, url: "https://example.com/b"),
        nav(3000, url: "https://example.com/a")
      ])

      BehaviorAnalyzer.new(recording).analyze!

      insight = recording.insights.find_by(kind: "u_turn")
      assert insight
      assert_equal "warning", insight.severity
      assert_equal "https://example.com/b", insight.details["url"]
      assert_equal "https://example.com/a", insight.details["back_to"]
    end

    test "u_turn does not fire when the return exceeds the time window" do
      recording = build_recording(first_url: "https://example.com/a")
      record_events(recording, [
        nav(0, url: "https://example.com/b"),
        nav(6000, url: "https://example.com/a")
      ])

      BehaviorAnalyzer.new(recording).analyze!

      assert_nil recording.insights.find_by(kind: "u_turn")
    end

    # --- form_abandon ------------------------------------------------------------

    test "form_abandon fires when inputs are left without submission or navigation" do
      recording = build_recording
      record_events(recording, [
        input(0, value: "abandoned"),
        move(15_000, x: 1, y: 1),
        move(20_000, x: 2, y: 2)
      ])

      BehaviorAnalyzer.new(recording).analyze!

      insight = recording.insights.find_by(kind: "form_abandon")
      assert insight
      assert_equal "warning", insight.severity
      assert_equal 1, insight.details["inputs_count"]
    end

    test "form_abandon does not fire when a submit-like click follows in the trailing window" do
      recording = build_recording
      record_events(recording, [
        input(0, value: "ok"),
        move(15_000, x: 1, y: 1),
        click(19_000, label: "Submit")
      ])

      BehaviorAnalyzer.new(recording).analyze!

      assert_nil recording.insights.find_by(kind: "form_abandon")
    end

    test "form_abandon does not fire when navigation follows the last input" do
      recording = build_recording
      record_events(recording, [
        input(0, value: "ok"),
        nav(15_000, url: "https://example.com/next")
      ])

      BehaviorAnalyzer.new(recording).analyze!

      assert_nil recording.insights.find_by(kind: "form_abandon")
    end

    # --- js_error -----------------------------------------------------------------

    test "js_error creates one insight per error event" do
      recording = build_recording
      record_events(recording, [
        error_event(100, message: "TypeError: x is not a function"),
        error_event(200, message: "ReferenceError: y is not defined")
      ])

      BehaviorAnalyzer.new(recording).analyze!

      insights = recording.insights.where(kind: "js_error").order(:ts_ms)
      assert_equal 2, insights.size
      assert_equal "critical", insights.first.severity
      assert_equal "TypeError: x is not a function", insights.first.details["message"]
    end

    test "js_error does not fire when there are no error events" do
      recording = build_recording
      record_events(recording, [ move(0, x: 0, y: 0) ])

      BehaviorAnalyzer.new(recording).analyze!

      assert_nil recording.insights.find_by(kind: "js_error")
    end

    test "js_error caps at 10 insights" do
      recording = build_recording
      events = Array.new(15) { |i| error_event(i * 10, message: "err #{i}") }
      record_events(recording, events)

      BehaviorAnalyzer.new(recording).analyze!

      assert_equal 10, recording.insights.where(kind: "js_error").count
    end

    # --- frustration score -----------------------------------------------------------

    test "computes frustration_score from weighted insight counts" do
      recording = build_recording
      record_events(recording, [
        click(0, x: 100, y: 100),
        click(200, x: 102, y: 101),
        click(400, x: 99, y: 100),
        click(5_000, x: 500, y: 500),
        error_event(6_000),
        error_event(6_100)
      ])

      BehaviorAnalyzer.new(recording).analyze!

      assert_equal 1, recording.insights.where(kind: "rage_click").count
      assert_equal 1, recording.insights.where(kind: "dead_click").count
      assert_equal 2, recording.insights.where(kind: "js_error").count
      assert_equal 40, recording.frustration_score
    end

    # --- idempotency -----------------------------------------------------------------

    test "re-analyzing does not duplicate insights and preserves the summary insight" do
      recording = build_recording
      record_events(recording, [ error_event(100), error_event(200) ])
      summary = recording.insights.create!(kind: "summary", severity: "info", body: "Existing summary")

      analyzer = BehaviorAnalyzer.new(recording)
      analyzer.analyze!
      analyzer.analyze!

      assert_equal 2, recording.insights.where(kind: "js_error").count
      assert_equal 1, recording.insights.where(kind: "summary").count
      assert_equal summary.body, recording.insights.find_by(kind: "summary").body
    end
  end
end
