# ActiveAnalytics — Session Recording Engine (Hotjar alternative)

Frozen spec. Executors implement tasks referencing this file. Do not deviate from names,
routes, or the event contract without coordinator approval.

## Overview

ActiveAnalytics is a mountable Rails engine (Rails >= 8.1.3, Ruby 3.4, propshaft, sqlite3 in
dev/test) that records user navigation on the host app's pages, replays every visit in a
dashboard UI (masking sensitive data at capture time), and runs AI behavior monitoring
(heuristics + optional LLM summaries).

Repo layout is a standard `rails plugin new --mountable` skeleton. Namespace:
`ActiveAnalytics`, isolated (`isolate_namespace ActiveAnalytics`). Test framework: minitest
with the dummy app at `test/dummy`. `test/test_helper.rb` already appends the engine's
`db/migrate` to migration paths.

Host app usage (target DX):

```ruby
# Gemfile
gem "active_analytics"

# config/routes.rb
mount ActiveAnalytics::Engine => "/analytics"

# app/views/layouts/application.html.erb, before </body>
<%= active_analytics_tag %>
```

Then run `bin/rails active_analytics:install:migrations db:migrate`.
Dashboard lives at `/analytics`, ingestion endpoint at `/analytics/events`.

## Configuration

`lib/active_analytics.rb` exposes:

```ruby
ActiveAnalytics.configure do |config|
  config.enabled          = true                  # master switch for recording
  config.sample_rate      = 1.0                   # 0.0..1.0, decided once per session (client side)
  config.mask_all_text    = false                 # mask every text node, not just sensitive ones
  config.ignored_paths    = []                    # array of String prefixes or Regexp, no recording there
  config.retention_days   = 30                    # purge_expired! deletes older recordings
  config.session_timeout  = 30 * 60               # seconds; recording considered finished when stale
  config.max_batch_bytes  = 1_000_000             # ingestion rejects bigger payloads (413)
  config.parent_controller = "ActionController::Base" # dashboard controllers inherit from this
  config.auto_analyze     = true                  # enqueue AnalyzeRecordingJob when a recording goes stale
  config.ai_summarizer    = nil                   # nil | :anthropic | any callable(String) -> String
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  config.anthropic_model   = "claude-opus-5"
end
```

Implementation: `ActiveAnalytics::Configuration` class (plain attr_accessors, defaults in
initialize), `ActiveAnalytics.config` memoized, `ActiveAnalytics.configure` yields it.
`ActiveAnalytics.reset_configuration!` for tests.

## Data model

Migrations live in `db/migrate` (engine). Three tables:

### active_analytics_recordings — model `ActiveAnalytics::Recording`

- `uuid` string, null: false, unique index (client-generated, validated server side as UUID format)
- `started_at` datetime, null: false
- `last_seen_at` datetime, null: false, index
- `duration_ms` integer, default 0
- `first_url` string
- `referrer` string
- `user_agent` string
- `viewport_width` integer / `viewport_height` integer
- `device` string  ("desktop"/"mobile"/"tablet" — derived from user_agent, naive regex is fine)
- `pages_count` integer, default 1
- `events_count` integer, default 0
- `clicks_count` integer, default 0
- `errors_count` integer, default 0
- `frustration_score` integer (nullable until analyzed)
- `analyzed_at` datetime (nullable)
- timestamps

Associations: `has_many :event_batches, -> { order(:seq) }, dependent: :delete_all`,
`has_many :insights, dependent: :delete_all`.

Scopes/API:
- `Recording.stale` — `last_seen_at < config.session_timeout.seconds.ago`
- `Recording.unanalyzed` — `analyzed_at IS NULL`
- `Recording.purge_expired!` — destroys recordings with `last_seen_at < retention_days.days.ago`, returns count
- `#events` — all batches' events concatenated in seq order (parsed JSON, array of Hashes with string keys)
- `#finished?` — stale
- `#append_batch!(seq:, events:, byte_size:)` — creates EventBatch, increments counters
  (`events_count`, `clicks_count` counting events with `"e" == "click"`, `errors_count` for
  `"e" == "error"`, `pages_count` = 1 + count of `"e" == "nav"` events accumulated), updates
  `last_seen_at` and `duration_ms` (max event `t` seen so far).

### active_analytics_event_batches — model `ActiveAnalytics::EventBatch`

- `recording_id` FK (index), null: false
- `seq` integer, null: false — unique index on [recording_id, seq]; duplicate seq is silently ignored by ingestion (idempotent retries)
- `events` text — JSON array (use `serialize`-free manual JSON.parse/generate or `attribute :events, :json`; sqlite text column)
- `byte_size` integer, default 0
- `created_at` only (no updated_at needed; use `t.datetime :created_at, null: false`)

### active_analytics_insights — model `ActiveAnalytics::Insight`

- `recording_id` FK (index), null: false
- `kind` string, null: false — one of: rage_click, dead_click, thrash, u_turn, form_abandon, js_error, summary
- `severity` string, default "info" — info | warning | critical
- `ts_ms` integer (position in replay; nullable for summary)
- `details` text — JSON object
- `body` text — human-readable sentence (or the LLM summary for kind=summary)
- `created_at` only

## Routes (`config/routes.rb`)

```ruby
ActiveAnalytics::Engine.routes.draw do
  post "events", to: "events#create"

  resources :recordings, only: [:index, :show, :destroy] do
    member do
      get :events   # JSON payload for the player
      post :analyze # run analysis on demand
    end
  end

  root to: "recordings#index"
end
```

## Event contract (FROZEN — shared by recorder JS, ingestion, player, analyzer)

Ingestion request: `POST <mount>/events`, `Content-Type: application/json`:

```json
{
  "uuid": "<crypto.randomUUID from client>",
  "seq": 0,
  "meta": { "url": "...", "referrer": "...", "vw": 1280, "vh": 800 },
  "events": [ { "t": 0, "e": "snapshot", "d": { ... } }, ... ]
}
```

- `meta` may be present on any batch (the recorder attaches it to every flush, not only
  seq 0 — see "Flush transport" below). The server only *uses* it once, at the moment it
  creates the Recording for a never-before-seen uuid (whichever batch is delivered first
  for that uuid); it is ignored on batches appended to an already-existing recording.
  `user_agent` is read from the request header server side.
- `t` = integer milliseconds since recording start (client clock, monotonic performance.now based).
- Response: `{ "ok": true }` 201 on create/appended, 204 on duplicate seq, 403 when disabled,
  413 when body exceeds `max_batch_bytes`, 422 on malformed payload (bad uuid, seq, non-array events).
- CSRF skipped for this controller. No auth (public endpoint like any analytics beacon).

### Flush transport (recorder → ingestion)

Browsers cap `fetch(..., { keepalive: true })` and `navigator.sendBeacon` request bodies
at 64KB; larger bodies are rejected outright and never sent (sendBeacon returns `false`,
keepalive fetch rejects). The `snapshot` event (full DOM) routinely exceeds that on
real pages, so keepalive/beacon is only safe for small batches. Rules:

- **Interval/size-triggered flushes** (5s timer or 100-event buffer, not part of page
  unload): plain `fetch`, no `keepalive` — uncapped body size.
- **Snapshot flushes immediately**: right after a `snapshot` event is pushed (initial
  start, and after each SPA `nav` re-snapshot), the recorder flushes right away instead
  of waiting for the 5s timer, so the largest payloads travel the uncapped path as early
  as possible.
- **Unload-path flushes** (`pagehide`, `visibilitychange` → hidden): try
  `navigator.sendBeacon` first (best survives teardown). If it returns `false` or throws,
  fall back to plain `fetch` without `keepalive` when the serialized body is over 60,000
  characters; otherwise fetch with `keepalive` (small bodies benefit from keepalive
  surviving navigation; bodies near/over the cap would just be rejected).
- **One retry on rejection**: if a `fetch` call rejects (network error or a keepalive/
  beacon size-cap rejection), the recorder retries the same serialized payload exactly
  once, ~2s later, via plain `fetch`. The server dedups by `[uuid, seq]` (204 on repeat),
  so a duplicate delivery is safe. No retry loops beyond that one attempt.

Old recordings created before this fix that lost their seq-0 batch (and therefore have
no `snapshot` event at all) cannot be repaired retroactively — there is no snapshot to
recover. The player renders an explicit "no snapshot" notice for those instead of a
silently blank stage.

Event types (`e`) and payloads (`d`):

- `snapshot`  — `{ "url", "title", "vw", "vh", "doc": <Node> }` full serialized DOM. Emitted on
  start and after each SPA navigation / full page load within a session.
- `mutation`  — `{ "adds": [{"p": parentId, "i": index, "n": <Node>}], "removes": [ids],
  "attrs": [{"id", "name", "value"}], "texts": [{"id", "text"}] }` (keys optional when empty)
- `move`      — `{ "x", "y" }` (throttled >= 50ms)
- `click`     — `{ "x", "y", "id": nodeIdOrNull, "label": <short masked text of target, <= 40 chars> }`
- `scroll`    — `{ "x", "y" }` document scroll (throttled >= 100ms)
- `input`     — `{ "id": nodeId, "value": <MASKED string>, "checked": bool? }`
- `resize`    — `{ "w", "h" }`
- `nav`       — `{ "url", "title" }` (pushState/replaceState/popstate). Always followed by a fresh `snapshot`.
- `error`     — `{ "message", "source", "line" }` from window.onerror (message truncated to 200 chars)
- `visibility`— `{ "state": "hidden" | "visible" }`

Serialized Node format (`doc`, `n`):

```json
{ "id": 12, "tag": "div", "attrs": {"class": "x"}, "children": [ ... ] }
{ "id": 13, "text": "hello" }          // text node
```

- Every serialized node gets an integer id from a client-side counter; the recorder keeps a
  WeakMap DOM node -> id so mutations/inputs/clicks reference stable ids.
- Skipped entirely: `script`, `noscript`, `template`, comments. `iframe` and `canvas` and
  `video` are serialized as an empty placeholder element with their tag + attrs (no content).
- `link[rel=stylesheet]` and inline `style` are kept so the player looks right. Relative
  `href`/`src` attributes are rewritten to absolute URLs at serialize time.
- `[data-aa-block]` elements are replaced by `<div data-aa-blocked>` placeholder keeping
  width/height via inline style.

### Masking rules (applied at CAPTURE time in JS — masked data never leaves the browser)

- `input[type=password]`, `input[type=email]`, `input[type=tel]`, `input[autocomplete*=cc-]`:
  value always replaced by `"••••••••"` (8 dots, fixed length) in snapshots and input events.
- All other inputs/textareas/selects: value masked the same way UNLESS the element has
  `data-aa-unmask`.
- Any element (or ancestor) with `data-aa-mask`: every text node beneath it is replaced by
  `"*"` repeated to the same length (whitespace preserved).
- `config.mask_all_text` (injected into JS config): ALL text nodes masked as above except
  inside `data-aa-unmask` subtrees.
- `value`/`placeholder` attributes on masked elements are masked in serialization too.

## Recorder JS

File: `app/assets/javascripts/active_analytics/recorder.js` — plain ES2019+, IIFE, no deps,
no build step. Served by propshaft (`javascript_include_tag "active_analytics/recorder"`).

Behavior:

- Reads config from `window.ActiveAnalyticsConfig = { endpoint, sampleRate, maskAllText, uuid? }`
  (injected by the helper before the script tag).
- Sampling: on first load of a session, `Math.random() < sampleRate` decides; decision +
  uuid + start timestamp stored in `sessionStorage` (`aa_session` JSON) so multi-page visits
  continue the same recording. Do nothing if not sampled or `!window.MutationObserver` or DNT
  (`navigator.doNotTrack == "1"`).
- On start: take snapshot, install MutationObserver (childList, attributes, characterData,
  subtree), listeners for mousemove/click/scroll/resize/input+change/visibilitychange/onerror,
  monkey-patch `history.pushState`/`replaceState` + `popstate` -> `nav` event + new snapshot.
- Buffer events; flush every 5s, when buffer reaches 100 events, or immediately after a
  `snapshot` event is pushed. See "Flush transport" above for the exact transport rules
  (plain `fetch` off the unload path, `sendBeacon` → fallback on the unload path, one
  retry on rejection). Seq counter persisted in sessionStorage alongside uuid.
- All capture callbacks wrapped so an internal error never breaks the host page (try/catch,
  disable recorder on repeated failure).

Helper (`app/helpers/active_analytics/application_helper.rb` + made available to host):

```erb
<%= active_analytics_tag %>
```

renders (only when `ActiveAnalytics.config.enabled` and request path not in `ignored_paths`):

```html
<script>window.ActiveAnalyticsConfig = {"endpoint":"/analytics/events","sampleRate":1.0,"maskAllText":false};</script>
<script src="/assets/active_analytics/recorder-<digest>.js" defer></script>
```

Mount prefix discovery: `ActiveAnalytics::Engine.routes.find_script_name({})` (falls back to
`""`), endpoint = `"#{prefix}/events"`. Expose the helper to the host app via an initializer
in `engine.rb`: `ActiveSupport.on_load(:action_controller_base) { helper ActiveAnalytics::Engine.helpers }`.

## Dashboard UI

Controllers inherit from `ActiveAnalytics::ApplicationController`, which must inherit from
`ActiveAnalytics.config.parent_controller.constantize` (resolved lazily at boot via engine
config or `Class.new` trick — simplest: define `ApplicationController < ActionController::Base`
and have `RecordingsController` inherit from a `DashboardController` that is defined with
`Class.new(ActiveAnalytics.config.parent_controller.constantize)`... Keep it simple and
conventional: `ActiveAnalytics::ApplicationController.parent` stays ActionController::Base;
add README docs for protecting the mount with router constraints. Do NOT overengineer).

`RecordingsController`:
- `index` — filters via params: `q` (substring of first_url), `errors: "1"` (errors_count > 0),
  `min_duration` (seconds), `from`/`to` (dates on started_at). Order `started_at DESC`.
  Manual pagination: `page` param, 25 per page, `offset/limit`, simple prev/next links.
- `show` — recording metadata, insights list, page trail (nav events), player container.
- `events` — renders JSON `{ recording: {uuid, started_at, duration_ms, viewport_width, viewport_height}, events: [...] }`
  for the player (all batches concatenated).
- `destroy` — deletes recording, redirects to index.
- `analyze` — runs `ActiveAnalytics::BehaviorAnalyzer.new(recording).analyze!` inline (plus
  summarizer if configured), redirects back to show.

Views: `app/views/active_analytics/recordings/index.html.erb`, `show.html.erb`, layout
`app/views/layouts/active_analytics/application.html.erb`. Styling: single CSS file
`app/assets/stylesheets/active_analytics/application.css` — clean, dark-sidebar-free, simple
system-font admin look; no external fonts/CDNs. Frustration score shown as colored badge
(0-29 green, 30-59 amber, >=60 red). Insights listed with kind, severity color, ts link that
seeks the player.

Player JS: `app/assets/javascripts/active_analytics/player.js` (no deps). API:

- Reads `window.ActiveAnalyticsReplay = { eventsUrl }`, fetches JSON, builds player inside
  `#aa-player` container:
  - sandboxed `<iframe sandbox="allow-same-origin">` sized to recording viewport, scaled to
    fit container width (CSS transform scale).
  - Rebuild DOM from `snapshot` events (document.open/write/close on iframe or programmatic
    createElement from the node tree — programmatic build required so node ids map; keep an
    id -> element map per snapshot).
  - Apply `mutation`, `input` (set value/checked), `scroll` (iframe scrollTo), `resize`.
  - Virtual cursor: absolutely positioned div overlay following `move`; click ripple animation
    on `click` events.
  - Controls: play/pause button, seek bar (input range over duration), current/total time,
    speed toggle 1x/2x/4x, "skip pauses" checkbox (gaps > 4s replayed as 0.5s).
  - Timeline markers: nav events (page changes) and insights (passed via
    `window.ActiveAnalyticsReplay.markers = [{ts_ms, kind, severity}]`) rendered as dots on
    the seek bar; clicking a dot seeks there.
  - Seeking works by resetting to nearest previous snapshot and fast-forwarding events up to
    the target time (no rendering of moves while fast-forwarding).
- Player loop: `requestAnimationFrame` or `setInterval(30ms)` advancing a virtual clock by
  `elapsed * speed`.

## Behavior analysis (AI monitoring)

`lib/active_analytics/behavior_analyzer.rb` — pure Ruby, no Rails deps beyond models.

`BehaviorAnalyzer.new(recording).analyze!`:
- loads `recording.events`, deletes prior non-summary insights, runs detectors, creates
  Insights, computes `frustration_score`, sets `analyzed_at`, saves.

Detectors (tunable constants at top of class):

- **rage_click** (severity critical): >= 3 clicks within a 700ms rolling window and within
  30px radius. One insight per burst, ts_ms = first click, details `{count, x, y}`.
- **dead_click** (warning): click not followed within 1000ms by any `mutation`, `nav`, or
  `input` event. Skip clicks that are part of a rage burst. details `{x, y, label}`.
- **thrash** (warning): cursor direction (sign of dx) changes >= 6 times within 1500ms with
  total distance > 800px. details `{changes, ts span}`.
- **u_turn** (warning): `nav` to a URL then `nav` back to the previous URL within 5000ms.
  details `{url, back_to}`.
- **form_abandon** (warning): >= 1 `input` event and the recording's last 10s contain no
  `click` on a submit-like target and no `nav` after the last input. One per recording.
  details `{inputs_count, last_input_ts}`.
- **js_error** (critical): one insight per `error` event (cap 10). details = event d.

Frustration score = clamp(0, 100, 15*rage + 5*dead + 5*thrash + 5*u_turn + 10*form_abandon
+ 10*js_error_insights). Store on recording.

Each insight `body` is a human sentence, e.g. "Rage click: 5 rapid clicks at (312, 480)".

### LLM summary (optional)

`lib/active_analytics/summarizer.rb`:
- `Summarizer.new(recording).call` — builds a compact digest (first_url, device, duration,
  pages visited in order, counts, insight list with ts+kind+body — NEVER raw text/values from
  events) and a prompt asking for a <=120-word behavioral summary with one actionable
  suggestion; sends it to the resolved AI backend; creates/updates the kind="summary" Insight
  with the response text. No-op returning nil when no backend configured.
- Backend resolution: `config.ai_summarizer` — if callable, call it with the prompt string;
  if `:anthropic`, use `ActiveAnalytics::AnthropicClient`.

`lib/active_analytics/anthropic_client.rb` — zero-dependency Net::HTTP client:
- `POST https://api.anthropic.com/v1/messages`, headers `x-api-key: <config.anthropic_api_key>`,
  `anthropic-version: 2023-06-01`, `content-type: application/json`.
- Body: `{model: config.anthropic_model, max_tokens: 1024, messages: [{role: "user", content: prompt}]}`.
  Do NOT send temperature/top_p (rejected by current models).
- Parse response JSON; if `stop_reason == "refusal"` or non-200, return nil (log via
  Rails.logger.warn). Return the first text content block otherwise.
  (`body["content"].find { |b| b["type"] == "text" }&.dig("text")`)
- 10s open/read timeouts. Never raise into the caller — rescue StandardError, warn, nil.

`app/jobs/active_analytics/analyze_recording_job.rb` — `perform(recording_id)`: analyze! +
summarizer. Enqueued by ingestion when it notices stale unanalyzed recordings
(cheap opportunistic check: on each create, `Recording.stale.unanalyzed.limit(5)` enqueue —
guard with `config.auto_analyze`).

Rake tasks (`lib/tasks/active_analytics_tasks.rake`):
- `active_analytics:analyze` — analyze all stale unanalyzed recordings inline.
- `active_analytics:purge` — `Recording.purge_expired!`.

## Dummy app (for tests + manual demo)

- `test/dummy/config/routes.rb`: `mount ActiveAnalytics::Engine => "/analytics"`, root to a
  demo controller.
- Demo `HomeController#index` page with headline, paragraphs, a form (name/email/password/
  message textarea), a `data-aa-mask` block, buttons — and `<%= active_analytics_tag %>` in
  layout.
- Migrations: test_helper already handles engine migration paths; ensure
  `ActiveRecord::Migration.maintain_test_schema!` or explicit
  `ActiveRecord::MigrationContext` migrate runs so tables exist in test (verify `bin/rails test`
  works from clean checkout — add `ActiveRecord::Tasks::DatabaseTasks.migrate` in test_helper
  if needed).

## Tests (minitest)

- `test/models/recording_test.rb` — append_batch! counters, duplicate seq ignored via
  ingestion, stale scope, purge_expired!.
- `test/controllers/events_controller_test.rb` — creates recording + batch on first post
  (with meta), appends on second, 204 duplicate seq, 422 bad payloads, 413 oversized,
  403 when disabled, counters updated.
- `test/lib/behavior_analyzer_test.rb` — synthetic event streams per detector (helper to
  build events), frustration score, idempotent re-analyze.
- `test/lib/summarizer_test.rb` — with a lambda ai_summarizer capturing the prompt: asserts
  digest contains url/insight info and NOT raw input values; creates summary insight; no-op
  when unconfigured.
- `test/lib/anthropic_client_test.rb` — stub Net::HTTP (or webmock-free: inject response via
  small seam, e.g. client accepts an http performer lambda) for 200/refusal/500 paths.
- `test/controllers/recordings_controller_test.rb` — index with filters, show, events JSON
  shape, destroy, analyze.
- `test/helpers/` or integration — `active_analytics_tag` renders config + script tag in the
  dummy app, honors enabled=false and ignored_paths.
- JS sanity: rake/CI step `node --check` on recorder.js and player.js (there is a `bin/rubocop`;
  JS check can live in the executor verification, not CI).

Every executor must leave `bin/rails test` green and `bin/rubocop` clean (rubocop-rails-omakase).

## Non-goals (YAGNI)

- No heatmaps, funnels, or aggregate page-view analytics.
- No websocket/live viewing. No multi-tenant scoping. No auth beyond parent_controller +
  README constraint docs. No JS build pipeline. No external JS/CSS.

## Task breakdown

- **Task 1 — Foundation**: config, migrations, models, routes, EventsController, jobs +
  rake tasks skeleton (job can call analyzer stub if Task 3 not merged — define
  BehaviorAnalyzer & Summarizer as no-op-safe requires guarded), dummy app wiring, model +
  ingestion tests. Gemspec TODO cleanup (summary/description/homepage - use
  https://github.com/giovapanasiti/active_analytics placeholder, drop allowed_push_host block).
- **Task 2 — Recorder**: recorder.js, helper + engine helper exposure, dummy demo page,
  helper test. Verify JS with `node --check`.
- **Task 3 — Analysis**: BehaviorAnalyzer, Summarizer, AnthropicClient, AnalyzeRecordingJob
  body, rake task bodies, their tests.
- **Task 4 — Dashboard**: RecordingsController + views + CSS + player.js + controller tests.
- **Task 5 — Polish**: README rewrite, full suite + rubocop + node --check verification.
