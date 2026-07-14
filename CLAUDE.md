# CLAUDE.md (my-dotclaude)

Working rules for editing **this repo**. This is my version-controlled Claude Code
setup, packaged so a fresh machine — or another person — can install the same kit.
What the kit *is* and how to install it lives in [README.md](README.md) and
[AGENT_SETUP.md](AGENT_SETUP.md); this file is only the map and the rules for changing
the repo itself. The global working rules in `~/.claude/CLAUDE.md` still apply on top.

## Layout

- `global/CLAUDE.md` — developer machine-wide rules; `setup-dev.sh` installs to `~/.claude/CLAUDE.md`.
- `global/CLAUDE.simple.md` — plain-English variant of the above; `setup-simple.sh` installs it instead, for non-coders.
- `plugins/personal-tools/`, `plugins/workflow/` — my slash commands, subagents, hooks.
- `plugins/personal-tools/templates/` — starter CLAUDE.md + STYLEGUIDE.md the `init-*` skills fill into new projects.
- `setup/` — install scripts (`setup-dev.sh`, `setup-simple.sh`) + `setup/lib/` helpers.
- `scripts/` — repo-maintenance utilities (`sync-version.sh`, `check-version-consistency.sh`, `run-tests.sh`) + `scripts/tests/`.
- `.github/workflows/` — CI (`ci.yml`, gates PRs into `main`) and release (`release.yml`) automation.
- `.claude-plugin/` — plugin marketplace manifest.
- `docs/` — cross-cutting design notes (e.g. `anti-mock-drift.md`, the mock-drift guard woven through the `/to-prd`→`/to-issues`→`/orchestrate` flow).

## Payload vs. governing — read this

`global/CLAUDE.md`, `templates/**/CLAUDE.md`, and `plugins/**/templates/CLAUDE.md` are
**payload**: they ship to users and are NOT rules for working in this repo. The only
governing rules are *this* file plus `~/.claude/CLAUDE.md`. Don't apply payload content
to your own edits, and don't edit payload to change your behavior here.

## Release & versioning

**Branch model.** `main` is release-only — never commit straight to it. Do day-to-day
work on `dev` or on short feature branches, and land it on `main` via a PR (CI gates
every PR into `main`; see [Done-check](#done-check)). **Merging `dev` → `main` cuts a
release:** the Release workflow (`.github/workflows/release.yml`) runs on every push to
`main` and calls `scripts/release-if-bumped.sh`, which tags `vX.Y.Z` and runs
`gh release create --generate-notes` *only when* `VERSION` is ahead of the latest `v*`
tag. If `VERSION` is unchanged it's a no-op, so a merge that didn't bump the version
ships nothing — bump first when you intend to release.

**Version single-source.** The root `VERSION` file is the one source of truth. Never
hand-edit a version anywhere else. Bump it with:

```bash
bash scripts/sync-version.sh <x.y.z>
```

That writes `VERSION` and stamps the same `version` into both plugin manifests
(`plugins/personal-tools/.claude-plugin/plugin.json` and
`plugins/workflow/.claude-plugin/plugin.json`) so all three stay in lockstep.
`scripts/check-version-consistency.sh` enforces the lockstep — it fails if either
plugin.json drifts from `VERSION` — and CI (`.github/workflows/ci.yml`) runs it on
every PR into `main`, so a mismatched version blocks the merge.

How an updated kit reaches installed users (the notify hook → `/check-updates` →
`/update-kit` flow) is documented in [README.md](README.md#keeping-the-kit-updated).

## Done-check

Tests are standalone bash scripts — no runner. Run every one and confirm all pass
before declaring done:

```bash
for t in setup/tests/test_*.sh plugins/*/tests/test_*.sh scripts/tests/test_*.sh; do
  echo "== $t"; bash "$t" || echo "FAIL: $t"
done
```

Note: that loop always exits 0 (the `|| echo` guard swallows failures), so eyeball
the output for `FAIL:` lines. CI runs the same suite via `bash scripts/run-tests.sh`,
which drops the guard and exits non-zero on any failing test — use it when you need a
true pass/fail exit code. CI (`.github/workflows/ci.yml`) also runs shellcheck, JSON
+ manifest validation, and the version-consistency check on every PR into `main`.

Add or update a test alongside any change to `setup/lib/`, `scripts/`, or plugin
scripts.

**`node` is a soft dependency.** Nearly everything here is prose, so nearly every test is
a grep — and a grep can only prove a *string describing* the behavior is present. The one
executable artifact in the kit is the `js` scheduler block in
`plugins/workflow/skills/orchestrate/SKILL.md`, so it gets the one behavior test:
`plugins/workflow/tests/orchestrate-block.harness.js` extracts that block, compiles it as
the async function body the Workflow runtime runs it as, and drives it against a stubbed
`agent()` — killing each spawn in turn to assert the run **drains** instead of silently
degrading. `test_orchestrate-block-behavior.sh` wraps it (and `test_orchestrate-skill.sh`
syntax-checks the same block). Both **skip green when `node` is absent** — CI must not
need node. If you edit that block, run the harness: it tests behavior, not strings.

## Gotchas

- **Plugin reload.** Plugins load from this directory source. After editing a plugin
  (skill, hook, command), run `/reload-plugins` — a bare restart does not pick up the
  change.
