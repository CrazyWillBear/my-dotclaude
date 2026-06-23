#!/usr/bin/env bash
#
# Tests for agents/reviewer.md — the reviewer agent prose.
#
# The agent is prose — not executable code — so we validate its structure and
# the content obligations of the anti-mock-drift guard (docs/anti-mock-drift.md):
#
#   1. File exists at the expected discovery path.
#   2. Frontmatter contains required fields (name, description).
#   3. The reviewer audits each slice's central mechanism for mock-drift.
#   4. A declared mock is confirmed and filed as mock-debt.
#   5. An undeclared central mock is auto-converted to mock-debt.
#   6. Boundary mocks are explicitly NOT flagged.
#   7. Mock-debt follow-ups carry the mock-debt label.
#   8. Mock-debt is NOT wired into dependents (label query is the gate) —
#      the one difference from review-fix.
#
# Run: bash plugins/workflow/tests/test_reviewer-agent.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_FILE="$PLUGIN_ROOT/agents/reviewer.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
echo "test: agent file exists at the expected discovery path"
if [ -f "$AGENT_FILE" ]; then
    ok "reviewer.md present at agents/reviewer.md"
else
    no "reviewer.md missing at $AGENT_FILE"
fi

content=""
if [ -f "$AGENT_FILE" ]; then
    content="$(cat "$AGENT_FILE")"
fi

# ---------------------------------------------------------------------------
echo "test: frontmatter contains 'name: reviewer'"
assert_contains "name field present" "$content" "name: reviewer"

echo "test: frontmatter contains a description field"
assert_contains "description field present" "$content" "description:"

# --- anti-mock-drift obligations -------------------------------------------
echo "test: reviewer performs a central-mechanism audit"
assert_contains "central-mechanism audit present" "$content" "Central-mechanism audit"
assert_contains "reads the slice's Central mechanism line" "$content" "## Central mechanism"

echo "test: declared mock is confirmed and filed"
assert_contains "declared path present" "$content" "Declared"

echo "test: undeclared central mock is auto-converted"
assert_contains "auto-convert present" "$content" "auto-convert"

echo "test: boundary mocks are explicitly NOT flagged"
assert_contains "boundary mocks allowed" "$content" "Boundary mocks"

echo "test: mock-debt follow-ups carry the mock-debt label"
assert_contains "mock-debt label on follow-up" "$content" "--label mock-debt"

echo "test: mock-debt is NOT wired into dependents (label query is the gate)"
assert_contains "no dependent wiring for mock-debt" "$content" "do **not** wire mock-debt into dependents"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
