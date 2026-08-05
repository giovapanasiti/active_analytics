# ActiveAnalytics

Self-hosted session recording and behavior analytics for Rails — an open-source
alternative to Hotjar. ActiveAnalytics is a mountable engine that:

- **Records user navigation** on your pages: DOM snapshots, mutations, mouse movement,
  clicks, scrolls, inputs, SPA navigations, and JavaScript errors — with a tiny
  dependency-free recorder script.
- **Replays every visit** in a built-in dashboard with a video-like player (timeline,
  seeking, speed control, skip-pauses) — no third party, your data never leaves your app.
- **Masks sensitive data at capture time**: passwords, emails, and form values are
  masked in the browser *before* anything is sent to your server.
- **Monitors behavior with AI**: rage clicks, dead clicks, cursor thrashing, navigation
  U-turns, form abandonment, and JS errors are detected automatically and rolled up into
  a per-visit frustration score — optionally summarized in plain language by Claude or
  any LLM callable you provide.
- **Per-page heatmaps**: mouse and touch movement density, click/tap density, and a
  scroll-depth map for every page, segmented by device (desktop/tablet/mobile) and
  rendered over the page's own DOM snapshot.
- **Basic web analytics for every visitor** (not just recorded sessions): daily page
  views, unique visitors, referrers, browsers and devices — Plausible-style rollups with
  an Overview dashboard, storing hashed visitor identifiers by default.


## Installation

Add the gem:

```ruby
# Gemfile
gem "active_analytics"

# ...or straight from GitHub:
gem "active_analytics", github: "giovapanasiti/active_analytics"
```

Install and migrate:

```bash
bundle install
bin/rails active_analytics:install:migrations
bin/rails db:migrate
```

Mount the engine and add the recorder tag:

```ruby
# config/routes.rb
mount ActiveAnalytics::Engine => "/analytics"
```

```erb
<%# app/views/layouts/application.html.erb, before </body> %>
<%= active_analytics_tag %>
```

That's it. Sessions are recorded to `POST /analytics/events`, pageview beacons go to
`POST /analytics/pageviews`, and the dashboard (Overview, Recordings, Heatmaps) lives at
`/analytics`.

## Protecting the dashboard

The dashboard has no built-in authentication. Restrict it in your routes, e.g. with
Devise:

```ruby
authenticate :user, ->(u) { u.admin? } do
  mount ActiveAnalytics::Engine => "/analytics"
end
```

or with HTTP basic auth via a constraint of your choice. The `/events` and `/pageviews`
ingestion endpoints are public by design (like any analytics beacon) and accept only
schema-validated JSON with size limits.

## Configuration

```ruby
# config/initializers/active_analytics.rb
ActiveAnalytics.configure do |config|
  config.enabled          = Rails.env.production?
  config.sample_rate      = 0.5          # record 50% of sessions
  config.mask_all_text    = false        # true = mask every text node
  config.ignored_paths    = ["/admin", %r{^/internal}]
  config.retention_days   = 30           # used by active_analytics:purge
  config.session_timeout  = 30 * 60      # seconds of inactivity that end a session
  config.max_batch_bytes  = 1_000_000    # reject bigger ingestion payloads
  config.auto_analyze     = true         # analyze finished sessions opportunistically
  config.visitor_ip_storage = :hashed    # :hashed (daily SHA-256 digest) or :raw

  # AI summaries (optional) — pick one:
  config.ai_summarizer = :anthropic                      # built-in zero-dependency client
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  config.anthropic_model   = "claude-opus-5"
  # ...or any callable receiving the prompt and returning a String:
  # config.ai_summarizer = ->(prompt) { MyLLM.complete(prompt) }
end
```

## Masking and privacy

Masking happens **in the visitor's browser** — masked values never reach your server.

- `input[type=password]`, `input[type=email]`, `input[type=tel]`, and credit-card
  autocomplete fields are always masked.
- Every other form field is masked by default; opt out per element with
  `data-aa-unmask`.
- Mask arbitrary content (names, addresses, account numbers) with `data-aa-mask`:

  ```html
  <div data-aa-mask>Giovanni Panasiti, Via Roma 1</div>
  ```

- Remove an element from recordings entirely (replaced by a sized placeholder) with
  `data-aa-block`.
- Set `config.mask_all_text = true` to mask every text node on the page.
- Visitors with `Do Not Track` enabled are never recorded.

LLM summaries are generated from a behavioral digest (URLs, timings, detected issues) —
never from recorded text or input values.

## AI behavior monitoring

When a session ends (or via **Run analysis** in the dashboard,
`bin/rails active_analytics:analyze`, or `ActiveAnalytics::AnalyzeRecordingJob`),
ActiveAnalytics detects:

| Insight | Meaning |
|---|---|
| `rage_click` | 3+ rapid clicks in the same spot — something looks clickable or is broken |
| `dead_click` | A click that changed nothing on the page |
| `thrash` | Erratic, frustrated cursor movement |
| `u_turn` | Navigated to a page and immediately went back |
| `form_abandon` | Started filling a form and left without submitting |
| `js_error` | JavaScript error in the visitor's browser |

Each visit gets a 0–100 **frustration score**, and with an `ai_summarizer` configured,
a short natural-language summary with an actionable suggestion.

## Basic analytics (Overview)

Every page load and SPA navigation sends a tiny beacon (independent of session-recording
sampling, still honoring Do Not Track), aggregated into daily rollups: page views per
path, unique visitors, referrers, browsers and devices. The **Overview** dashboard (the
engine's home page) shows totals, a daily chart, and top pages/referrers/browsers for a
7/30/90-day window.

Unique visitors are counted from a **daily rotating SHA-256 digest** of IP + user agent —
no raw IP is stored by default. If you need raw IPs (and have the legal basis to keep
them), opt in with:

```ruby
config.visitor_ip_storage = :raw   # default: :hashed
```

Rollups are anonymous aggregates and are kept forever; visitor rows (which may contain
raw IPs in `:raw` mode) are deleted by `active_analytics:purge` after `retention_days`.

## Heatmaps

The **Heatmaps** section of the dashboard aggregates every analyzed session into per-page
maps: movement density (mouse + touch), click/tap density, and scroll depth (the share of
pageviews reaching each point of the page). Maps are segmented by device, since desktop
and mobile layouts place content differently, and are drawn over the page's most recent
DOM snapshot. Aggregation happens when a session is analyzed (see Housekeeping below), is
incremental, and stores only anonymous counters — heatmap data survives recording purges.

## Housekeeping

```bash
bin/rails active_analytics:analyze   # analyze finished, unanalyzed sessions (insights + heatmaps)
bin/rails active_analytics:purge     # delete recordings and visitor rows older than retention_days
```

Run both on a schedule (cron / solid_queue recurring / whenever).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Blank replay / "No pages recorded" on older recordings | Caused by the 64KB `fetch keepalive` / `sendBeacon` body cap silently dropping the (large) initial DOM snapshot batch. Fixed by the recorder's flush-transport rules (plain `fetch` without keepalive for periodic flushes, snapshot flushed immediately, one retry on rejection). Recordings created before the fix that never received a snapshot cannot be repaired retroactively. |

## Development

```bash
bundle install
bin/rails test
bin/rubocop
cd test/dummy && bin/rails server   # demo app with the recorder installed
```

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
