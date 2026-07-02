#!/usr/bin/env bash
#
# Tests for agents/my-review.md — the my-review agent prose.
#
# The agent is prose — not executable code — so we validate its frontmatter and
# the content obligations the /pipeline severity-routing contract depends on:
#
#   1. File exists at the expected discovery path.
#   2. Frontmatter pins model: fable and effort: xhigh (effort can't be set per
#      Agent call, so the pin must live here).
#   3. The 4-tier severity taxonomy (critical/high/medium/low) is present and
#      the old blocker/warning/nit vocabulary is gone.
#   4. The verdict line re-anchors APPROVE WITH NITS to only-low findings.
#   5. The machine-readable ```findings block spec is present (the pipeline
#      routes off this block), including the replan flag and empty-when-clean.
#   6. The ❓ unverified tag survives the migration.
#
# Run: bash plugins/personal-tools/tests/test_my-review-agent.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_FILE="$PLUGIN_ROOT/agents/my-review.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
echo "test: agent file exists at the expected discovery path"
if [ -f "$AGENT_FILE" ]; then
    ok "my-review.md present at agents/my-review.md"
else
    no "my-review.md missing at $AGENT_FILE"
fi

content=""
if [ -f "$AGENT_FILE" ]; then
    content="$(cat "$AGENT_FILE")"
fi

# ---------------------------------------------------------------------------
echo "test: frontmatter contains 'name: my-review'"
assert_contains "name field present" "$content" "name: my-review"

# ---------------------------------------------------------------------------
echo "test: frontmatter pins model: fable"
assert_contains "model pinned to fable" "$content" "model: fable"
assert_not_contains "model: inherit is gone" "$content" "model: inherit"

# ---------------------------------------------------------------------------
echo "test: frontmatter pins effort: xhigh"
assert_contains "effort pinned to xhigh" "$content" "effort: xhigh"
assert_not_contains "effort: max is gone" "$content" "effort: max"

# ---------------------------------------------------------------------------
echo "test: 4-tier severity taxonomy present"
assert_contains "critical tier present" "$content" "**critical**"
assert_contains "high tier present" "$content" "**high**"
assert_contains "medium tier present" "$content" "**medium**"
assert_contains "low tier present" "$content" "**low**"

# ---------------------------------------------------------------------------
echo "test: old blocker/warning/nit vocabulary is gone"
assert_not_contains "blocker severity absent" "$content" "blocker"

# ---------------------------------------------------------------------------
echo "test: verdict line re-anchors WITH NITS to only-low findings"
assert_contains "verdict line present" "$content" "APPROVE WITH NITS"
assert_contains "WITH NITS anchored to low" "$content" "only **low** findings"

# ---------------------------------------------------------------------------
echo "test: machine-readable findings block spec present"
assert_contains "findings fence named" "$content" '```findings'
assert_contains "findings line schema present" "$content" "severity=critical|high|medium|low"
assert_contains "replan flag present" "$content" "replan=yes|no"
assert_contains "empty block when clean" "$content" "empty"

# ---------------------------------------------------------------------------
echo "test: unverified tag survives"
assert_contains "unverified tag present" "$content" "❓ unverified"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
