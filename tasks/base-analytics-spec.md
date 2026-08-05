# ActiveAnalytics — Base analytics (page views, unique users, referrers, browsers)

Frozen spec (autonomous approval under /goal, 2026-08-03). Extends the engine built per
tasks/hotjar-alternative-spec.md and tasks/heatmaps-spec.md.

## Overview

Plausible-style aggregate analytics collected for EVERY visitor (not only sampled
session-recording visitors): daily page views per path, daily unique visitors (by IP),
referrers, browsers and devices — with an Overview dashboard as the engine's new root.

## Collection

- **Recorder beacon**: `recorder.js` sends `POST <mount>/pageviews` with JSON
  `{ "url": location.href, "referrer": document.referrer }` on initial load and on every
  SPA navigation (inside the existing history patch), BEFORE the sampling bail — every
  visitor is counted even when the session is not recorded. The existing DNT bail stays
  above it (DNT users are never counted). Fire-and-forget via
  `navigator.sendBeacon` (fallback `fetch keepalive`); failures are silently ignored.
- **Endpoint**: new `EventsController`-style `PageviewsController#create` (CSRF skipped,
  403 when `config.enabled` is false, 422 when url missing/not a String, body limit 8KB →
  413). Server-side data: `request.remote_ip`, `request.user_agent`. Responds 201 empty.
- Route: `post "pageviews", to: "pageviews#create"`.

## Aggregation (`lib/active_analytics/stats_recorder.rb`)

`StatsRecorder.record!(url:, referrer:, ip:, user_agent:, host: nil, at: Time.current)`:

- `page_path` via `HeatmapAggregator.page_path(url)` (single source of truth).
- `date = at.to_date`.
- **Views**: upsert-increment `PageViewDay` (date, page_path) += 1.
- **Referrer**: host of the referrer URL, downcased, `www.` stripped. Blank referrer →
  `"direct"`. Referrer host equal to the visited url's host → skipped (self-referral).
  Upsert-increment `ReferrerDay` (date, referrer_host) += 1.
- **Browser/device**: naive UA family — Edge (`Edg/`), Opera (`OPR/`|`Opera`), Chrome,
  Safari (only when not Chrome), Firefox, else "Other"; device via
  `Recording.device_for(user_agent)`. Upsert-increment `BrowserDay` (date, browser,
  device) += 1.
- **Unique visitors**: `visitor_key` =
  - `config.visitor_ip_storage == :raw` → the raw IP string;
  - default `:hashed` → `Digest::SHA256.hexdigest("#{date.iso8601}:#{ip}:#{user_agent}")`
    (rotates daily by construction; no raw IP at rest).
  Insert-ignore `VisitorDay` (date, visitor_key) — uniques/day = row count for the date.
- Whole method rescues StandardError → Rails.logger.warn, never raises into the request.

## Data model (migrations 20260803000006..9)

- `active_analytics_page_view_days`: date (null:false), page_path (null:false), views
  integer default 0 null:false; unique index [date, page_path] name
  `index_aa_page_view_days_unique`.
- `active_analytics_referrer_days`: date, referrer_host, views; unique [date,
  referrer_host] name `index_aa_referrer_days_unique`.
- `active_analytics_browser_days`: date, browser, device, views; unique [date, browser,
  device] name `index_aa_browser_days_unique`.
- `active_analytics_visitor_days`: date, visitor_key; unique [date, visitor_key] name
  `index_aa_visitor_days_unique`; plus index on date.

Models `PageViewDay`, `ReferrerDay`, `BrowserDay` share the upsert-increment pattern of
`HeatmapCell.bump!` (per-model `bump!(attrs)` incrementing `views`); `VisitorDay.mark!`
uses `insert_all(..., unique_by:)` ignore semantics. All under `ActiveAnalytics::`.

## Configuration

Add `config.visitor_ip_storage = :hashed` (allowed: `:hashed`, `:raw`) to Configuration.

## Dashboard — Overview

- Engine root becomes `stats#index` ("Overview"); recordings stay at `/recordings`
  (only the `root to:` line changes). Top bar nav: Overview | Recordings | Heatmaps.
- `StatsController#index`, params `days` (int, default 30, clamp 1..365). Loads for the
  window [today-(days-1), today]:
  - totals: page views (sum), unique visitors (VisitorDay count in range), pages/visit
    shown as views/uniques rounded 1 decimal (— when uniques 0);
  - daily series: views + uniques per day (fill missing days with 0);
  - top pages (path, views, desc, limit 10);
  - top referrers (host, views, desc, limit 10);
  - browsers (browser, views desc grouped summing devices) and devices (device, views)
    tables.
- **Chart**: server-rendered inline SVG (no JS, no deps) via
  `ActiveAnalytics::ApplicationHelper#stats_chart(series, width:, height:)` — grouped
  daily bars for views with an overlaid uniques line, y auto-scaled, date labels at
  sensible intervals (first/last + ~weekly). Testable as a helper.
- Range picker: link pills 7 / 30 / 90 days.
- CSS: `aa-stats-*` classes consistent with existing dashboard. English UI.

## Tests

- `test/lib/stats_recorder_test.rb`: view/referrer/browser/device rollups increment and
  accumulate; self-referral skipped; blank referrer → direct; www stripping; hashed
  visitor_key (no raw IP substring in any stored value) vs `:raw` mode storing the IP;
  same visitor same day counted once, different day counted again; bad url fallback;
  never raises (e.g. nil UA).
- `test/controllers/pageviews_controller_test.rb`: 201 + rollup rows created with
  request IP/UA; SPA double-post increments; 403 disabled; 422 bad payload; 413 oversize.
- `test/controllers/stats_controller_test.rb`: totals, series zero-fill, top lists,
  days clamp, root routes to overview.
- Helper test for `stats_chart` (SVG contains expected bar count).
- Recorder: `node --check`; beacon behavior covered by E2E verification.

## Retention

Rollups are anonymous aggregates and are NOT touched by `active_analytics:purge`
(document in README). VisitorDay rows ARE eligible: purge also deletes VisitorDay rows
older than retention_days (they contain the visitor_key which may be a raw IP when
configured) — add to the purge task.

## Out of scope

Funnels, goals/conversions, UTM parsing, geolocation, bot filtering beyond DNT,
real-time view.
