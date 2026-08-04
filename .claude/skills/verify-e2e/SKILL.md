---
name: verify-e2e
description: End-to-end browser smoke test for ActiveAnalytics using the dummy app - record a real session, verify masking server-side, replay it, run analysis, and check heatmaps and the analytics overview. Use after changes to recorder.js, masking, the player, aggregators, or ingestion.
---

# End-to-end browser verification

Static tests cannot see real browser behavior (event capture, masking at the DOM level,
replay rendering). This procedure exercises the whole loop against the dummy app.

## Setup

```bash
cd test/dummy && bin/rails db:migrate && bin/rails server -p 3941 &
# wait for boot, then:
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3941/            # expect 200
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3941/analytics   # expect 200
```

When done: `pkill -f "puma.*3941"`.

## 1. Record a session (browser tools)

Open `http://127.0.0.1:3941/` in the browser and simulate a visit:

- Fill the form: name (this field is `data-aa-unmask`), email, **password with a known
  sentinel** (e.g. `SuperSecret123!`), textarea.
- Click "Add list item" a few times (produces mutations).
- Dispatch a rage-click burst (5 rapid clicks at one point on a paragraph) and throw a
  JS error — both via the JS console if needed.
- Wait ≥ 7s for a flush (batches flush every 5s; `pagehide` flushes via sendBeacon).

Caveat learned in practice: browser-extension "click element by ref" may not dispatch
real DOM clicks — verify a click actually happened (e.g. the list grew) before debugging
the recorder; use `element.click()` or dispatched MouseEvents from the console instead.

## 2. Verify masking server-side (the critical check)

```bash
cd test/dummy && bin/rails runner '
r = ActiveAnalytics::Recording.order(:updated_at).last
raw = r.event_batches.map { |b| b.events.to_json }.join
puts "password_leak=#{raw.include?("SuperSecret123")}"   # MUST be false
puts "mask_present=#{raw.include?("••••")}"  # MUST be true
puts r.events.map { |e| e["e"] }.tally.inspect            # snapshot/mutation/move/click/input expected
'
```

A password or email substring in the stored events is a release-blocking privacy bug.

## 3. Replay, analysis, heatmaps, overview

- Open `/analytics/recordings/<id>`: player renders the page in the iframe, Play
  advances the clock, seeking works, `data-aa-mask` content shows as asterisks.
- Click **Run analysis**: expect rage_click / js_error insights, a frustration score,
  and (kind/severity/timestamps) matching what you simulated.
- Open `/analytics/heatmaps` → the page appears; the click map shows blobs where you
  clicked; the scroll map renders bands.
- Open `/analytics` (Overview): page views incremented by your visits, 1 unique visitor,
  browser/device/referrer rows populated. Verify visitor privacy:

```bash
cd test/dummy && bin/rails runner '
vk = ActiveAnalytics::VisitorDay.pluck(:visitor_key)
puts "hashed=#{vk.all? { |k| k.match?(/\A[0-9a-f]{64}\z/) }}"   # true unless :raw configured
'
```

## Notes

- The dev server does not hot-reload files under `lib/` (loaded via require at boot) —
  restart it after changing analyzers/aggregators.
- Browser network inspection starts tracking only when first called: reload the page
  after arming it, or use the server log / DB as ground truth.
