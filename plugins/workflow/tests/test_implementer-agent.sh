#!/usr/bin/env bash
#
# Tests for agents/implementer.md — /orchestrate's implementer, both lanes.
#
# The agent is prose — not executable code — so we validate the two input shapes
# and, above all, that the obligations the run depends on are all still stated
# (this test is the structural regression lock for the issue contract):
#
#   1. File exists at the expected discovery path; model pins to sonnet and
#      effort stays max.
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
echo "test: frontmatter — name, model: sonnet pin, and max effort survive"
assert_contains "name field present" "$content" "name: implementer"
assert_contains "model pinned to sonnet" "$content" "model: sonnet"
assert_contains "effort stays max" "$content" "effort: max"

# ---------------------------------------------------------------------------
echo "test: issue input shape present (orchestrate contract)"
assert_contains "issue number + body input" "$content" "issue number"
assert_contains "acceptance criteria in body" "$content" "## Acceptance criteria"
assert_contains "issue branch naming" "$content" "issue-<N>"
assert_contains "absolute worktree path input" "$content" "absolute worktree path"

# ---------------------------------------------------------------------------
echo "test: work order input shape present"
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
assert_contains "no merge/rebase/branch switching" "$content" "not** merge, rebase"
assert_contains "never merge, PR, close or edit" "$content" "Never merge, never open a PR, never close or edit"
# push is DELIBERATELY allowed now — the worker pushes its own branch. Only the
# irreversible, outward-facing writes are the main thread's.
assert_not_contains "push is not forbidden" "$content" "Do **not** push"
assert_contains "stop and report on blockers" "$content" "stop and report"

echo "test: the issue thread is read BEFORE anything is planned"
assert_contains "reads the comments first" "$content" "gh issue view <N> --comments"
assert_contains "says why: rulings live in comments" "$content" "not** in the body"
assert_contains "posts the tackled line" "$content" "Tackled #<N> on branch issue-<N>"
assert_contains "brevity framed as correctness" "$content" "correctness property"

echo "test: the context map is a hint the implementer may ignore"
assert_contains "reads CONTEXT-MAP.md if present" "$content" "CONTEXT-MAP.md"
assert_contains "hint, not a contract" "$content" "hint, not a contract"
assert_contains "does not maintain it" "$content" "Do not try to repair or update it"

echo "test: commit-per-green-sub-step is framed as RECOVERY, not hygiene"
assert_contains "commits after every green sub-step" "$content" "Commit after every green sub-step"
assert_contains "names it the recovery mechanism" "$content" "recovery mechanism"
assert_contains "explains the resume-from-last-commit property" "$content" "resumes from your **last commit**"

echo "test: a session implementer is told its plain output is invisible"
assert_contains "says output is invisible" "$content" "invisible to the orchestrator"
assert_contains "reports with SendMessage" "$content" "SendMessage"
assert_contains "fixed-shape built line" "$content" "issue <N> built head="
assert_contains "fixed-shape failure line" "$content" "issue <N> failed"
assert_contains "escalation line" "$content" "issue <N> escalate"
assert_contains "and a subagent reports in its final text instead" "$content" "running as a subagent"

# ---------------------------------------------------------------------------
echo "test: done-check obligation intact"
assert_contains "run the project's done-check" "$content" "done-check"
assert_contains "honest failure reporting" "$content" "report the failure honestly"

# ---------------------------------------------------------------------------
# /orchestrate's scheduler reads this agent's result through BUILT_SCHEMA
# { n, branch, worktree, head, failed } and DRAINS THE RUN on `failed` — in two
# places (the build guard and the fix loop). `head` is the fix loop's delta base,
# and a Workflow cannot shell out to rev-parse it, so the sha must ride back here.
# None of that is in the Output contract below unless it is NAMED: the signal
# survives only by the structured-output layer inferring `failed` from
# "done-check: fail" prose. Name the fields so the contract and the schema agree.
echo "test: the Output contract names the fields the orchestrate schema reads"
assert_contains "issue number returned" "$content" "\`n\`"
assert_contains "worktree returned" "$content" "\`worktree\`"
assert_contains "branch returned" "$content" "\`branch\`"
assert_contains "post-build HEAD sha returned (the fix loop's delta base)" "$content" "\`head\`"
assert_contains "failed flag returned (it drains the run)" "$content" "\`failed\`"
assert_contains "a red done-check means failed: true" "$content" "failed"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
