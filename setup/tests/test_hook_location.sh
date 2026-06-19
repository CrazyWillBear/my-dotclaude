#!/usr/bin/env bash
#
# Tests that every bundled plugin wires its hooks at a location Claude Code
# actually auto-discovers.
#
# Claude Code only loads plugin hooks from:
#   * <plugin-root>/hooks/hooks.json, or
#   * an inline "hooks" field inside <plugin-root>/.claude-plugin/plugin.json
# A bare <plugin-root>/hooks.json at the plugin ROOT is neither, so it is
# silently ignored — the hook never fires. Issue #38: the personal-tools
# SessionStart notifier was committed at the plugin root and never ran.
#
# This guards against future misplacement: for every plugins/*/, if it wires
# hooks at all, they must live at a discoverable location, and a stray
# plugin-root hooks.json must FAIL the test. It also asserts the personal-tools
# SessionStart notifier specifically: root hooks.json absent, hooks/hooks.json
# present + valid JSON + carries a SessionStart entry.
#
# Run: bash setup/tests/test_hook_location.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGINS_DIR="$REPO_ROOT/plugins"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

# plugin_has_inline_hooks <plugin-dir> — true if plugin.json carries a non-null
# "hooks" field.
plugin_has_inline_hooks() {
  local manifest="$1/.claude-plugin/plugin.json"
  [ -f "$manifest" ] || return 1
  jq -e '.hooks != null' "$manifest" >/dev/null 2>&1
}

# ---- test: every plugin wires hooks at a discoverable location --------------
echo "test: every plugin's hooks live where Claude Code auto-discovers them"
for plugin in "$PLUGINS_DIR"/*/; do
  [ -d "$plugin" ] || continue
  name="$(basename "$plugin")"

  root_hooks="$plugin/hooks.json"
  discoverable_hooks="$plugin/hooks/hooks.json"

  # A bare plugin-root hooks.json is never discovered — always a failure.
  if [ -f "$root_hooks" ]; then
    no "$name: stray plugin-root hooks.json (never auto-discovered; move to hooks/hooks.json)"
  else
    ok "$name: no stray plugin-root hooks.json"
  fi

  # If this plugin wires hooks at all, they must be discoverable.
  if [ -f "$discoverable_hooks" ] || plugin_has_inline_hooks "$plugin"; then
    ok "$name: wires hooks at a discoverable location"
  elif [ -f "$root_hooks" ]; then
    # hooks exist but ONLY at the bad path — already flagged above; note it.
    no "$name: only hook wiring is the stray plugin-root hooks.json"
  fi
  # Plugins with no hooks at all are fine — nothing to assert.
done

# ---- test: personal-tools SessionStart notifier specifically ----------------
echo "test: personal-tools SessionStart notifier is wired discoverably"
PT="$PLUGINS_DIR/personal-tools"

if [ -f "$PT/hooks.json" ]; then
  no "personal-tools: plugin-root hooks.json must NOT exist"
else
  ok "personal-tools: no plugin-root hooks.json"
fi

if [ -f "$PT/hooks/hooks.json" ]; then
  ok "personal-tools: hooks/hooks.json exists"
  if jq empty "$PT/hooks/hooks.json" >/dev/null 2>&1; then
    ok "personal-tools: hooks/hooks.json is valid JSON"
  else
    no "personal-tools: hooks/hooks.json is NOT valid JSON"
  fi
  if jq -e '.hooks.SessionStart' "$PT/hooks/hooks.json" >/dev/null 2>&1; then
    ok "personal-tools: hooks/hooks.json has a SessionStart entry"
  else
    no "personal-tools: hooks/hooks.json missing a SessionStart entry"
  fi
else
  no "personal-tools: hooks/hooks.json is missing"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
