# ActiveAnalytics — Page Heatmaps (moves, clicks, scroll depth)

Frozen spec, approved by Giovanni on 2026-08-03. Extends tasks/hotjar-alternative-spec.md
(the event contract there still applies unchanged). Executors follow this exactly.

## Overview

Per-page heatmaps aggregated across recordings, segmented by device (desktop/tablet/mobile):

- **move** — mouse movement + touch movement density
- **click** — click/tap density
- **scroll** — scroll-depth map: share of pageviews that reached each depth

Aggregation is incremental (during analysis), rendered in the dashboard over a backdrop
rebuilt from the newest DOM snapshot of that page.

## 1. Recorder changes (`app/assets/javascripts/active_analytics/recorder.js`)

- Add passive listeners `touchstart` and `touchmove` (window, capture). Both emit the
  existing `move` event `{x, y}` using the FIRST touch's clientX/clientY, sharing the same
  50ms throttle as mousemove. No new event types (taps already produce native `click`
  events). Ingestion/player/contract unchanged.

## 2. Coordinate model

- Recorded x/y are viewport-relative. The aggregator converts to document coordinates by
  tracking scroll state through the event stream: `doc_y = y + scroll_y`.
- Buckets: `x_bucket = clamp((x / vw * 50).floor, 0, 49)` (50 buckets = 2% of viewport
  width each; vw from the recording's viewport_width, updated by `resize` events and
  snapshot `d.vw`). `y_bucket = (doc_y / 25).floor` (25px bands), clamped >= 0.
- `page_path`: URL normalized to path only — strip scheme/host/query/fragment
  (`URI.parse(url).path` with fallback to the raw string up to `?`/`#`; empty → "/").

## 3. Data model

Migration `create_active_analytics_heatmap_cells`:

- `page_path` string, null: false
- `device` string, null: false
- `kind` string, null: false  — move | click | scroll
- `x_bucket` integer, null: false (always 0 for kind=scroll)
- `y_bucket` integer, null: false
- `count` integer, null: false, default 0
- unique index on [page_path, device, kind, x_bucket, y_bucket] (name it short, e.g.
  index_aa_heatmap_cells_unique), plus index on [page_path, device, kind]

Model `ActiveAnalytics::HeatmapCell` (validations for kind inclusion; class method
`HeatmapCell.bump!(rows)` doing a single `upsert_all` with
`on_duplicate: Arel.sql("count = count + excluded.count")`, unique_by the unique index).

Migration `add_heatmap_aggregated_at_to_recordings`: `heatmap_aggregated_at` datetime,
nullable, on `active_analytics_recordings`.

## 4. Aggregator (`lib/active_analytics/heatmap_aggregator.rb`)

`HeatmapAggregator.new(recording).aggregate!`:

- No-op (return false) if `recording.heatmap_aggregated_at` present (idempotency — analysis
  can re-run, aggregation must count each recording once).
- Walk `recording.events` in order, maintaining state:
  - `path` — starts from `page_path(recording.first_url)`; updated on `nav` events and on
    `snapshot` events carrying `d.url`.
  - `scroll_x/scroll_y` — from `scroll` events; reset to 0 on `nav`/`snapshot` (new page
    starts at top; a snapshot right after nav belongs to the same pageview — treat
    nav+snapshot pair as ONE pageview boundary: a snapshot within 1000ms after a nav does
    not start another pageview).
  - `vw/vh` — from recording viewport_width/height, updated by `resize` (`d.w/d.h`) and
    snapshot `d.vw/d.vh`.
  - Per-pageview `max_depth = max(vh, scroll_y + vh)` updated on every scroll/resize.
- Cell accumulation (in-memory Hash keyed [path, kind, x_bucket, y_bucket] → count):
  - `move` event → kind "move" at bucketed doc coords.
  - `click` event → kind "click" at bucketed doc coords.
  - On pageview end (next nav-boundary or end of stream) → kind "scroll", x_bucket 0,
    y_bucket = (max_depth / 25).floor, count += 1 (one row bump per pageview).
- Skip events with missing/non-numeric x/y. Skip everything when vw <= 0.
- Tracks the ordered unique list of paths visited during the walk (starting from
  `page_path(recording.first_url)`, appended on every pageview-boundary transition)
  independently of the vw <= 0 short-circuit, and persists it to `recording.page_paths`
  (`add_page_paths_to_recordings` migration, text column, `attribute :page_paths, :json`
  on the model) so the heatmaps controller can resolve a backdrop for interior pages.
- Flush once via `HeatmapCell.bump!`, set `heatmap_aggregated_at = Time.current` and
  `page_paths`, save.
- Wire into `AnalyzeRecordingJob#perform` after the analyzer (and in
  `RecordingsController#analyze`). Device comes from `recording.device` (fallback
  "desktop").

Scroll-depth semantics at render time: sessions reaching depth d = sum of scroll-cell
counts with y_bucket >= d/25 (cumulative from below); total pageviews = sum of all
scroll-cell counts for that page+device.

## 5. Routes & controller

```ruby
resources :heatmaps, only: [ :index ] do
  collection do
    get :show   # /heatmaps/show?path=/pricing&device=desktop&kind=move
    get :data   # JSON cells
  end
end
```

(`show` on collection because the identifier is a path in query params, not an id.)

`HeatmapsController` (inherits ApplicationController like RecordingsController):

- `index` — list of pages: `HeatmapCell.group(:page_path).sum(:count)` shaped into rows
  {path, per-device pageview counts (from kind=scroll sums), total move/click points};
  link each device cell to show.
- `show` — params: `path` (required), `device` (default "desktop"), `kind`
  (default "move", validated inclusion). Finds `@reference_recording` using
  `Recording#page_paths` (populated by the aggregator with every page path visited
  during the session — not just the entry point — so interior pages reached via
  in-session navigation resolve a backdrop too), in this order, each scanning
  `.order(started_at: :desc).limit(REFERENCE_SCAN_LIMIT)`:
  1. device-matching recordings whose `page_paths` contains the path (SQL `LIKE`
     prefilter on the JSON-quoted path, confirmed in Ruby with
     `recording.page_paths&.include?(@path)` to kill false positives);
  2. same without the device filter;
  3. `first_url` path == path, device-matching, then any device (fallback for
     recordings analyzed before the `page_paths` column existed);
  4. fallback nil (view shows "no snapshot available" and renders heatmap on blank
     backdrop).
  Renders view with selectors (kind: Movimenti/Click/Scroll; device) that reload via GET.
- `data` — JSON. For move/click: `{ kind, max: <max cell count>, cells: [[x_bucket,
  y_bucket, count], ...] }`. For scroll: `{ kind, total: <pageviews>, bands: [[y_bucket,
  reached], ...] }` where reached is the cumulative count (computed in Ruby).

## 6. UI

- Layout nav: add "Heatmaps" link next to "Recordings" in the engine top bar.
- `index.html.erb`: table page_path / desktop / tablet / mobile pageview counts / total
  points, each device count linking to show. Empty state.
- `show.html.erb`: header with path + selectors (link-based pills for kind and device),
  sessions/pageviews count, stage container `#aa-heatmap` + inline script setting
  `window.ActiveAnalyticsHeatmap = { dataUrl, eventsUrl (reference recording events or
  null), path, viewportWidth/Height (reference recording's or 1280x800) }` +
  `javascript_include_tag "active_analytics/heatmap", defer: true`.
- **Shared DOM builder**: extract the snapshot→DOM code from `player.js` into
  `app/assets/javascripts/active_analytics/dom_builder.js` exposing
  `window.AADomBuilder = { build(iframeDoc, snapshotNode) → idMap }` (pure, no player
  state). `player.js` uses it (include the new file before player/heatmap via
  `javascript_include_tag` in the relevant views). Behavior of the player must not change.
- `app/assets/javascripts/active_analytics/heatmap.js` (ES2019 IIFE, no deps):
  - Builds sandboxed iframe (`sandbox="allow-same-origin"`) at reference viewport size,
    scaled to fit container width (same technique as player). Renders the snapshot for
    `path`: fetch eventsUrl, pick the LAST `snapshot` event whose `d.url` path == path
    (fallback: first snapshot). Sets iframe height to rendered document height (or
    viewport height if unavailable).
  - move/click: `<canvas>` overlay (document-height tall) — per cell draw a radial
    gradient blob (radius ~28px in backdrop coordinates) with alpha ∝ count/max onto a
    grayscale intensity canvas, then colorize via palette ramp blue→cyan→lime→yellow→red
    (getImageData once, map intensity→RGBA, putImageData). Cell center x = (x_bucket +
    0.5)/50 * width, y = y_bucket * 25 + 12.5.
  - scroll: horizontal overlay bands every 25px colored by reached/total (red=100% at top
    fading to blue at low %), with marker lines + labels at 75%, 50%, 25% of pageviews
    ("75% degli utenti arriva qui" style labels — Italian labels are fine in the
    engine? NO: keep the UI in English like the rest of the dashboard: "75% of users
    reach this point").
  - Legend (gradient bar + min/max), and a note with total data points/pageviews.
- CSS: extend `application.css` with `aa-heatmap-*` classes (stage, overlay, pills,
  legend). No external assets.

## 7. Tests (minitest)

- `test/lib/heatmap_aggregator_test.rb`: bucketing math (known coords → expected cells);
  scroll tracking (move after scroll lands in doc coords); nav resets scroll and splits
  pageviews (2 scroll cells for 2 pages); touch-derived moves are just move events —
  nothing special; idempotency (second aggregate! is a no-op, counts unchanged);
  upsert accumulation across two recordings on the same cell; scroll-depth cumulative
  math via the controller data shape; URL normalization cases (query/fragment/host
  stripped, bad URL fallback, empty → "/").
- `test/models/heatmap_cell_test.rb`: bump! insert + increment paths, kind validation.
- `test/controllers/heatmaps_controller_test.rb`: index lists aggregated pages; show 200
  with/without reference recording; invalid kind → default or 422 (pick: fall back to
  "move"); data JSON shapes for move and scroll (cumulative reached verified).
- Existing suites must stay green; `bin/rubocop` clean; `node --check` on all three JS
  files (dom_builder, player, heatmap, recorder).

## Out of scope

Server-side screenshots, image export, per-element click ranking, heatmap purge/reset
tooling, live updating.
