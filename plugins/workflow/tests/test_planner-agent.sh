#!/usr/bin/env bash
#
# Tests for agents/planner.md — the planner agent prose.
#
# The agent is prose — not executable code — so we validate its frontmatter and
# the content obligations the complex lane depends on:
#
#   1. File exists at the expected discovery path.
#   2. Frontmatter pins model: opus and effort: high, read-only tools. The Agent
#      tool has no effort parameter, so this pin GOVERNS every Agent-tool spawn:
#      a caller can override the model per call but cannot touch effort.
#   3. Its SCOPE is written down (#104): in the session lane standard AND complex
#      get a plan, written by consult.sh on the tier's planner cell and POSTED TO
#      THE ISSUE THREAD as the **Plan** comment before the build spawn; trivial
#      self-plans; there is no fix-round mode; the orchestrator never reads it.
#   4. The output contract: ordered steps with file paths, function signatures and
#      the test to write first, a verbatim '## Acceptance criteria' heading, the
#      project done-check, ASSUMPTIONS (the deviation rule reads them), risks.
#   5. The planner returns the plan as final text (the caller posts or writes it).
#
# Run: bash plugins/workflow/tests/test_planner-agent.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_FILE="$PLUGIN_ROOT/agents/planner.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
echo "test: agent file exists at the expected discovery path"
if [ -f "$AGENT_FILE" ]; then
    ok "planner.md present at agents/planner.md"
else
    no "planner.md missing at $AGENT_FILE"
fi

content=""
if [ -f "$AGENT_FILE" ]; then
    content="$(cat "$AGENT_FILE")"
fi

# ---------------------------------------------------------------------------
echo "test: frontmatter contains 'name: planner'"
assert_contains "name field present" "$content" "name: planner"

# ---------------------------------------------------------------------------
echo "test: frontmatter pins model: opus and effort: high"
assert_contains "model pinned to opus" "$content" "model: opus"
assert_not_contains "model: fable is gone" "$content" "model: fable"
assert_contains "effort pinned to high" "$content" "effort: high"

# ---------------------------------------------------------------------------
echo "test: tools are read-only (no Edit/Write; git-scoped Bash)"
assert_contains "read-only tool set" "$content" "tools: Read, Grep, Glob, Bash(git:*)"
assert_not_contains "no Edit tool" "$content" "tools: Read, Edit"

# ---------------------------------------------------------------------------
echo "test: the scope decision is written down (#104)"
assert_contains "standard and complex get a plan in the session lane" "$content" "standard and complex issues get a plan"
assert_contains "trivial self-plans" "$content" "Trivial issues self-plan"
assert_contains "the plan is posted to the thread by consult.sh" "$content" "consult.sh plan"
assert_contains "as the Plan comment" "$content" "**Plan**"
assert_contains "before the build worker is spawned" "$content" "before the build worker is spawned"
assert_contains "on the tier's planner cell" "$content" "planner cell"
assert_contains "the implementer is a cheaper model reading the thread" "$content" "reads the thread before"
assert_contains "reads the issue comments, not just the body" "$content" "comments"
assert_contains "and the linked PRD" "$content" "Part of #M"

# ---------------------------------------------------------------------------
echo "test: no fix-round mode — review findings are their own work order"
assert_contains "says so explicitly" "$content" "no fix-round mode"
assert_not_contains "no replan mode" "$content" "**replan**"
assert_not_contains "no triage mode" "$content" "**triage**"
assert_not_contains "no fix-list" "$content" "ordered fix-list"

# ---------------------------------------------------------------------------
echo "test: the orchestrator never reads the plan"
assert_contains "says so outright" "$content" "The orchestrator never reads the plan"
assert_contains "explains the context cost" "$content" "orchestrator reads is prose in the orchestrator"
assert_contains "the ad-hoc lane hands the plan to the agent that will build" "$content" "the agent that will build"

echo "test: a false assumption is a deviation, answered by the consult role"
assert_contains "names the Deviation comment" "$content" "**Deviation**"
assert_contains "and the consult role" "$content" "consult.sh consult"

# ---------------------------------------------------------------------------
echo "test: output contract"
assert_contains "steps with file paths" "$content" "file paths"
assert_contains "function signatures" "$content" "function signatures"
assert_contains "the test to write first" "$content" "test to write first"
assert_contains "acceptance criteria heading verbatim" "$content" "## Acceptance criteria"
assert_contains "project done-check quoted" "$content" "done-check"
assert_contains "assumptions section — what the deviation rule reads" "$content" "**Assumptions**"
assert_contains "risks/unknowns section" "$content" "Risks / unknowns"

# ---------------------------------------------------------------------------
echo "test: planner returns plan as final text; the caller posts or writes it"
assert_contains "final text" "$content" "final text"
assert_contains "the caller posts it" "$content" "posts or writes it"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
