---
name: release
description: Prepare and cut a release of the active_analytics gem - version bump, changelog, verification gates, gem build, and tagging. Use when asked to release, publish, or bump the version.
---

# Releasing active_analytics

Releases are a coordinator responsibility: never delegate the version bump, tag, or
publish step to a subagent, and never push/publish without the user's explicit go-ahead.

## 1. Pre-flight gates (all mandatory)

1. Run the `verify` skill (clean-state tests, rubocop, JS checks) — all green.
2. If recorder/masking/player/aggregator code changed since the last release, run the
   `verify-e2e` skill too.
3. Docs in sync: `README.md`, `GUIDA.md` (Italian), and `tasks/*.md` specs reflect the
   released behavior. New config keys must appear in both README and GUIDA.
4. `git status` clean apart from the release changes.

## 2. Version bump

- Edit `lib/active_analytics/version.rb` following semver:
  - PATCH: fixes, doc updates, internal refactors.
  - MINOR: new features (new insight types, new dashboard sections, new config keys).
  - MAJOR: breaking changes to the event contract, config keys, or DB schema that
    require host-app action beyond `rails active_analytics:install:migrations`.
- New migrations are additive by convention — never edit a shipped migration; add a new
  one.

## 3. Changelog

Maintain `CHANGELOG.md` (create it on first release) with an entry per version:
Added / Changed / Fixed, in English, newest first. Mention any new migration explicitly
so host apps know to run `active_analytics:install:migrations`.

## 4. Build and tag

```bash
gem build active_analytics.gemspec        # sanity-check the package builds
git add -A && git commit -m "Release vX.Y.Z"
git tag vX.Y.Z
```

Ask the user before: pushing (`git push && git push --tags`) and publishing
(`gem push active_analytics-X.Y.Z.gem`) — publishing to RubyGems is irreversible.
If the gem is distributed via GitHub only (`gem "active_analytics", github: ...`),
pushing the tag is the release.
