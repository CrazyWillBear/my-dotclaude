#!/usr/bin/env bash
#
# Tests for agents/my-review.md — the my-review agent prose.
#
# The agent is prose — not executable code — so we validate its frontmatter and
# the content obligations the severity-routing contract depends on:
#
#   1. File exists at the expected discovery path.
#   2. Frontmatter pins model: opus and effort: xhigh. The Agent tool has no
#      effort parameter, so this pin GOVERNS every Agent-tool spawn — including
#      a caller's tier-routed one, which overrides model per call but cannot
#      touch effort. (Workflow agent() does take opts.effort, so /orchestrate
#      routes it per call.)
#   3. The 4-tier severity taxonomy (critical/high/medium/low) is present and
#      the old blocker/warning/nit vocabulary is gone.
#   4. The verdict line re-anchors APPROVE WITH NITS to only-low findings.
#   5. The machine-readable ```findings block spec is present (the caller
#      routes off this block), including the replan flag and empty-when-clean.
#   6. The ❓ unverified tag survives the migration.
#   7. (issue #66) my-review now folds in the central-mechanism / mock-drift
#      audit: it reads the issue's `## Central mechanism` line, confirms a
#      declared central mock and auto-converts an undeclared one, exempts
#      boundary mocks, and files a `mock-debt` follow-up (a narrow,
#      audit-scoped `gh issue create` — ordinary findings stay report-only),
#      not wired into dependents (the label query is the gate).
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
echo "test: frontmatter pins model: opus"
assert_contains "model pinned to opus" "$content" "model: opus"
assert_not_contains "model: fable is gone" "$content" "model: fable"
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
# Measured from real sessions: buggy-code was the single largest friction, and the
# shape was always the same — a plausible API that doesn't exist, a version-only
# feature that breaks CI, a test that passes with the impl stubbed, a README
# snippet that fails if you run it. A flat checklist misses all four because each
# one LOOKS correct on the page. These assertions pin the "verify, don't recall"
# obligation so it can't quietly rot back out.
echo "test: the reviewer verifies against what is installed rather than from memory"
assert_contains "checks APIs against the installed package" "$content" "installed"
assert_contains "names the from-memory failure explicitly" "$content" "never from memory"
assert_contains "checks version/runtime compatibility" "$content" "Version-compat"
assert_contains "checks for tests that assert nothing" "$content" "deleted or stubbed"
assert_contains "checks doc snippets actually run" "$content" "ran it verbatim"

# ---------------------------------------------------------------------------
echo "test: review attention is weighted by blast radius, not spread flat"
assert_contains "weighting section present" "$content" "Weight by blast radius"
assert_contains "names auth as high-blast-radius" "$content" "auth and session handling"
assert_contains "names money paths" "$content" "anything that"
assert_contains "names destructive/irreversible areas" "$content" "data deletion"

# ---------------------------------------------------------------------------
# Lows are fixed in-run now, never parked on a backlog. That makes every reported
# nit cost a real fix round, which is the only thing that keeps nit volume sane.
echo "test: lows are fixed in-run, and the reviewer is told its nits cost a round"
assert_contains "lows are not backlogged" "$content" "not** parked on a backlog"
assert_contains "every finding gets fixed before landing" "$content" "gets fixed"
assert_contains "states the bar for reporting" "$content" "would not spend a round on it"

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

# --- central-mechanism / mock-drift audit folded in (issue #66) ------------
echo "test: my-review performs the central-mechanism / mock-drift audit"
assert_contains "central-mechanism audit present" "$content" "Central-mechanism audit"
assert_contains "reads the issue's Central mechanism line" "$content" "## Central mechanism"

echo "test: declared central mock is confirmed, undeclared is auto-converted"
assert_contains "declared path present" "$content" "Declared"
assert_contains "auto-convert present" "$content" "auto-convert"

echo "test: boundary mocks are exempt from the audit"
assert_contains "boundary mocks exempt" "$content" "Boundary mocks"

echo "test: mock-debt follow-ups are filed with the mock-debt label"
assert_contains "mock-debt label on follow-up" "$content" "--label mock-debt"
assert_contains "audit-scoped gh issue create" "$content" "gh issue create"

echo "test: mock-debt is NOT wired into dependents (label query is the gate)"
assert_contains "no dependent wiring for mock-debt" "$content" "do **not** wire mock-debt into dependents"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
