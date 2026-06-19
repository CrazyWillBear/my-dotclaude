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
- `scripts/` — repo-maintenance utilities (`sync-version.sh`, `check-version-consistency.sh`) + `scripts/tests/`.
- `.claude-plugin/` — plugin marketplace manifest.

## Payload vs. governing — read this

`global/CLAUDE.md`, `templates/**/CLAUDE.md`, and `plugins/**/templates/CLAUDE.md` are
**payload**: they ship to users and are NOT rules for working in this repo. The only
governing rules are *this* file plus `~/.claude/CLAUDE.md`. Don't apply payload content
to your own edits, and don't edit payload to change your behavior here.

## Done-check

Tests are standalone bash scripts — no runner, no CI. Run every one and confirm all
pass before declaring done:

```bash
for t in setup/tests/test_*.sh plugins/*/tests/test_*.sh scripts/tests/test_*.sh; do
  echo "== $t"; bash "$t" || echo "FAIL: $t"
done
```

Add or update a test alongside any change to `setup/lib/` or plugin scripts.

## Gotchas

- **Plugin reload.** Plugins load from this directory source. After editing a plugin
  (skill, hook, command), run `/reload-plugins` — a bare restart does not pick up the
  change.
