#!/usr/bin/env bash
#
# Tests for agents/implementer.md — the shared /orchestrate + /pipeline implementer.
#
# The agent is prose — not executable code — so we validate the two input shapes
# and, above all, that generalizing it for /pipeline did NOT drop any of the
# obligations /orchestrate depends on (this test is the structural regression
# lock for the issue contract):
#
#   1. File exists at the expected discovery path; effort stays xhigh.
#   2. Both input shapes are described: issue (number + body + worktree +
#      issue-<N> branch) and work order (plan text + worktree + branch +
#      commit-scope hint).
#   3. Orchestrate obligations intact: dedup-search step, TDD-first,
#      central-mechanism rule, mock-debt declaration, C5 commit rules
#      (conventional scope, add -u only, co-author trailer, heredoc),
#      worktree boundaries (never create worktrees, never push/merge).
#
# Run: bash plugins/workflow/tests/test_implementer-agent.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_FILE="$PLUGIN_ROOT/agents/implementer.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
echo "test: agent file exists at the expected discovery path"
if [ -f "$AGENT_FILE" ]; then
    ok "implementer.md present at agents/implementer.md"
else
    no "implementer.md missing at $AGENT_FILE"
fi

content=""
if [ -f "$AGENT_FILE" ]; then
    content="$(cat "$AGENT_FILE")"
fi

# ---------------------------------------------------------------------------
echo "test: frontmatter — name and xhigh effort survive"
assert_contains "name field present" "$content" "name: implementer"
assert_contains "effort stays xhigh" "$content" "effort: xhigh"

# ---------------------------------------------------------------------------
echo "test: issue input shape present (orchestrate contract)"
assert_contains "issue number + body input" "$content" "issue number"
assert_contains "acceptance criteria in body" "$content" "## Acceptance criteria"
assert_contains "issue branch naming" "$content" "issue-<N>"
assert_contains "absolute worktree path input" "$content" "absolute worktree path"

# ---------------------------------------------------------------------------
echo "test: work order input shape present (pipeline contract)"
assert_contains "work order shape named" "$content" "Work order"
assert_contains "plan text input" "$content" "plan text"
assert_contains "commit-scope hint input" "$content" "commit-scope hint"

# ---------------------------------------------------------------------------
echo "test: orchestrate obligations intact — dedup-search step"
assert_contains "dedup-search skill invoked" "$content" "dedup-search"
assert_contains "dedup fallback path present" "$content" "plugins/personal-tools/skills/dedup-search/SKILL.md"

# ---------------------------------------------------------------------------
echo "test: orchestrate obligations intact — TDD-first"
assert_contains "TDD-first step" "$content" "TDD-first"
assert_contains "failing test first" "$content" "failing"

# ---------------------------------------------------------------------------
echo "test: orchestrate obligations intact — central-mechanism rule"
assert_contains "central mechanism built real" "$content" "## Central mechanism"
assert_contains "boundary mocks allowed" "$content" "mocks (clock, third-party API"

# ---------------------------------------------------------------------------
echo "test: orchestrate obligations intact — mock-debt declaration"
assert_contains "mock-debt line format" "$content" "## Mock-debt"
assert_contains "mocked-what declaration" "$content" "Mocked: <what>"
assert_contains "deferred-to-integration escape" "$content" "deferred to integration"

# ---------------------------------------------------------------------------
echo "test: orchestrate obligations intact — C5 commit rules"
assert_contains "conventional commits with scope" "$content" "Conventional Commits with a scope"
assert_contains "add -u only" "$content" "add -u"
assert_not_contains "no git add -A instruction leak" "$content" "use git add -A"
assert_contains "co-author trailer" "$content" "Co-Authored-By: Claude"
assert_contains "heredoc commit" "$content" 'commit -F -'

# ---------------------------------------------------------------------------
echo "test: orchestrate obligations intact — worktree boundaries"
assert_contains "never create worktrees" "$content" "Never run \`git worktree add\`"
assert_contains "no push/merge/rebase" "$content" "not** push, merge, rebase"
assert_contains "stop and report on blockers" "$content" "stop and report"

# ---------------------------------------------------------------------------
echo "test: done-check obligation intact"
assert_contains "run the project's done-check" "$content" "done-check"
assert_contains "honest failure reporting" "$content" "report the failure honestly"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
