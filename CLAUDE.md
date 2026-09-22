# CLAUDE.md (my-dotclaude)

Working rules for editing **this repo**. This is my version-controlled Claude Code
setup, packaged so a fresh machine — or another person — can install the same kit.
What the kit *is* and how to install it lives in [README.md](README.md) and
[AGENT_SETUP.md](AGENT_SETUP.md); this file is only the map and the rules for changing
the repo itself. The global working rules in `~/.claude/CLAUDE.md` still apply on top.

## Layout

- `global/CLAUDE.md` — developer machine-wide rules; `setup-dev.sh` installs to `~/.claude/CLAUDE.md`.
- `global/CLAUDE.simple.md` — plain-English variant of the above; `setup-simple.sh` installs it instead, for non-coders.
- `plugins/context/` — context-window hooks (watchdog, resume, save-handoff, suggest-docs) + `/handoff`, `/handoff-plan`.
- `plugins/personal-tools/` — my slash commands, subagents, hooks.
- `plugins/workflow/` — the `/orchestrate` dispatcher, `/classify-task`, and the manager's front half `/to-prd` + `/to-issues`.
- `plugins/workflow/scripts/` — the deterministic half of `/orchestrate` (readiness, the one
  graph fetch, PRD scoping, run log, merge fold). Logic belongs here, not in skill prose: a
  script gets a real test, prose gets a grep.
- `plugins/infra/` — scripts-only shared layer (`spawn.sh`, `session-status.sh`,
  `check-inbound.sh`, `resolve-tier.sh` + `model-tiers.json`, `consult.sh` for the planner /
  consult comment, `escalate.sh` for the chain escalation decision). Its SessionStart hook runs
  `link-kit.sh`, which links `~/.claude/kit/infra`; other plugins call infra only through that
  path, never by relative path.
- `plugins/swarm/` — roster-driven multi-session teams (`/init-swarm`, `swarm.sh up|down|rotate|attach|brief`, `roster.sh` + `memory.sh`, briefs, charter).
- `plugins/personal-tools/templates/` — starter CLAUDE.md + STYLEGUIDE.md the `init-*` skills fill into new projects.
- `setup/` — install scripts (`setup-dev.sh`, `setup-simple.sh`) + `setup/lib/` helpers.
- `scripts/` — repo-maintenance utilities (`sync-version.sh`, `check-version-consistency.sh`, `run-tests.sh`) + `scripts/tests/`.
- `.github/workflows/` — CI (`ci.yml`, gates PRs into `main`) and release (`release.yml`) automation.
- `.claude-plugin/` — plugin marketplace manifest.
- `docs/` — cross-cutting design notes: `swarm-design.md` (the orchestrator → peers → workers kit and the plugin split) and `anti-mock-drift.md` (the mock-drift guard woven through the `/to-prd`→`/to-issues`→`/orchestrate` flow).

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

That writes `VERSION` and stamps the same `version` into every
`plugins/*/.claude-plugin/plugin.json` so all of them stay in lockstep.
`scripts/check-version-consistency.sh` enforces the lockstep — it fails if any
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

**Prose is grep-tested; behavior lives in scripts.** Nearly everything here is prose, and
a grep can only prove a *string describing* the behavior is present. So the deterministic
half of `/orchestrate` deliberately lives in `plugins/workflow/scripts/` (`ready.sh`,
`run-log.sh`, `merge-fold.sh`) and `plugins/infra/scripts/` (`spawn.sh`, `session-status.sh`,
`check-inbound.sh`, `resolve-tier.sh`, `consult.sh`, `escalate.sh`), where each one is driven
against real fixtures by its own `test_*.sh`. When you find yourself writing a rule into a
skill that a script could enforce, that is a signal to move it. (The old `js`-block-in-
markdown scheduler and its bespoke node harness are gone; `node` is no longer needed by
any test.)

## Gotchas

- **Plugin reload.** Plugins load from this directory source. After editing a plugin
  (skill, hook, command), run `/reload-plugins` — a bare restart does not pick up the
  change.
