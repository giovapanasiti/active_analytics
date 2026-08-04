---
name: verify
description: Full static verification for ActiveAnalytics - run before claiming any change works, before commits, and after merging executor output. Clean-state test suite, rubocop, and JS syntax checks.
---

# Verify ActiveAnalytics

Run every step from the repository root. All three gates must pass — a change is not
"done" until they do.

## 1. Clean-state test suite

```bash
rm -f test/dummy/storage/test.sqlite3*
bin/rails test
```

Expected: `0 failures, 0 errors, 0 skips`. Deleting the sqlite file first proves
migrations run correctly from scratch (the test_helper migrates explicitly with deduped
paths — see CLAUDE.md "Environment quirks" before touching that setup).

Run it **twice** when migrations changed (clean + warm state behave differently).

## 2. Lint

```bash
bin/rubocop
```

Expected: `no offenses detected`. `test/dummy/db/schema.rb` is generated and excluded in
`.rubocop.yml` — never hand-fix offenses there; regenerate instead.

## 3. JavaScript syntax

```bash
for f in recorder player dom_builder heatmap; do
  node --check app/assets/javascripts/active_analytics/$f.js || echo "FAIL: $f"
done
```

All four files are plain ES2019 IIFEs with no build step; `node --check` is the only
static gate they get, so treat any parse failure as blocking.

## When a step fails

- Test failures: fix the code, not the assertion, unless the spec in `tasks/*.md`
  changed first.
- "Duplicate migration" or "table already exists" errors: you broke the migration-path
  setup — re-read CLAUDE.md "Environment quirks" before changing test_helper or the
  dummy app config.
- If anything behavioral changed (recorder, masking, player, aggregators), follow up
  with the `verify-e2e` skill — the static gates cannot see browser behavior.
