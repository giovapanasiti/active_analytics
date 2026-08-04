# ActiveAnalytics — project instructions

Mountable Rails engine: self-hosted Hotjar alternative. Session recording with
client-side masking, replay dashboard, AI behavior analysis (heuristics + optional LLM
summaries), per-page heatmaps, and Plausible-style basic analytics. Zero runtime
dependencies beyond Rails; zero external assets; no JS build step.

## Architecture map

| Subsystem | Key files |
|---|---|
| Recorder (browser) | `app/assets/javascripts/active_analytics/recorder.js` |
| Ingestion | `app/controllers/active_analytics/{events,pageviews}_controller.rb` |
| Data model | `app/models/active_analytics/*` (Recording, EventBatch, Insight, HeatmapCell, *Day rollups) |
| Behavior analysis | `lib/active_analytics/behavior_analyzer.rb`, `summarizer.rb`, `anthropic_client.rb` |
| Heatmap aggregation | `lib/active_analytics/heatmap_aggregator.rb` |
| Basic analytics | `lib/active_analytics/stats_recorder.rb` |
| Dashboard | `app/controllers/active_analytics/{stats,recordings,heatmaps}_controller.rb` + views |
| Replay player | `app/assets/javascripts/active_analytics/{dom_builder,player,heatmap}.js` |
| Config | `lib/active_analytics/configuration.rb` |
| Jobs / rake | `app/jobs/active_analytics/analyze_recording_job.rb`, `lib/tasks/active_analytics_tasks.rake` |

Frozen specs (source of truth for contracts and semantics) live in `tasks/*.md`. The
**event contract** in `tasks/hotjar-alternative-spec.md` is shared by recorder,
ingestion, player, and analyzers — never change one side without the others.

## Hard rules

- **Masking is a privacy guarantee**: sensitive inputs (password/email/tel/cc) are
  masked in the browser and must stay unmaskable-proof (`data-aa-unmask` must never
  reveal them). Any recorder/serializer change requires re-verifying that masked values
  never reach the server (see the `verify-e2e` skill).
- LLM prompts (Summarizer) must only ever contain the behavioral digest — never raw
  recorded text or input values.
- No new gem dependencies, no external assets/CDNs, no JS build pipeline. JS files are
  plain ES2019 IIFEs checked with `node --check`.
- Dashboard UI text is English. Ruby style is rubocop-rails-omakase (`bin/rubocop`).
- `HeatmapAggregator.page_path` is the single source of truth for URL normalization.

## Verification (run before claiming anything works)

```bash
rm -f test/dummy/storage/test.sqlite3*   # clean-state check
bin/rails test                            # full suite must be green
bin/rubocop                               # must report no offenses
for f in recorder player dom_builder heatmap; do
  node --check app/assets/javascripts/active_analytics/$f.js
done
```

Use the `verify` skill for this checklist and the `verify-e2e` skill for the full
browser smoke test (record → mask check → replay → analyze → heatmaps → overview).

## Environment quirks (learned the hard way)

- The dummy app's `config.paths["db/migrate"]` includes the engine's `db/migrate`
  (see `test/dummy/config/application.rb`), so `cd test/dummy && bin/rails db:migrate`
  works in development. Because of that, `maintain_test_schema` is **disabled** in the
  test env and `test/test_helper.rb` migrates explicitly with deduped paths — re-enabling
  it causes "Duplicate migration" errors (engine-aware schema loader sees the engine
  migrations twice).
- `test/dummy/db/schema.rb` is generated; it's excluded in `.rubocop.yml` — don't lint
  or hand-edit it.
- Engine helpers reach the host app via the initializer in `lib/active_analytics/engine.rb`
  (the dummy app sets `include_all_helpers = false`, so removing it silently breaks
  `active_analytics_tag`).
- In `config/routes.rb`, the heatmaps `get "show", action: :show, as: :show` form is
  deliberate: a bare `get :show` collides with Rails canonical-action path collapsing
  and hijacks `GET /heatmaps`.
- Demo server: `cd test/dummy && bin/rails server`. Kill stray servers with
  `pkill -f "puma.*<port>"`.

## Docs to keep in sync

When behavior or config changes, update: `README.md` (English, public), `GUIDA.md`
(Italian user guide), and the relevant `tasks/*.md` spec if a frozen contract evolves.
