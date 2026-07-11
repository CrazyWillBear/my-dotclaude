#!/usr/bin/env bash
#
# Tests for agents/merger.md — the /orchestrate merger agent prose.
#
# The agent is prose — not executable code — so we validate its frontmatter pins:
#
#   1. File exists at the expected discovery path.
#   2. Frontmatter pins name: merger, model: opus, and effort: xhigh.
#      orchestrate's merger spawn passes no explicit model or effort, so this
#      pin governs outright. The merger is never tier-routed: it runs once per
#      round, after the slices, and a bad conflict resolution corrupts the base
#      branch for every issue in the round — so it never gets a cheap model.
#
# Run: bash plugins/workflow/tests/test_merger-agent.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_FILE="$PLUGIN_ROOT/agents/merger.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
echo "test: agent file exists at the expected discovery path"
if [ -f "$AGENT_FILE" ]; then
    ok "merger.md present at agents/merger.md"
else
    no "merger.md missing at $AGENT_FILE"
fi

content=""
if [ -f "$AGENT_FILE" ]; then
    content="$(cat "$AGENT_FILE")"
fi

# ---------------------------------------------------------------------------
echo "test: frontmatter pins name: merger, model: opus, effort: xhigh"
assert_contains "name field present" "$content" "name: merger"
assert_contains "model pinned to opus" "$content" "model: opus"
assert_not_contains "cheap merger model is gone" "$content" "model: sonnet"
assert_not_contains "model: inherit is gone" "$content" "model: inherit"
assert_contains "effort pinned to xhigh" "$content" "effort: xhigh"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
