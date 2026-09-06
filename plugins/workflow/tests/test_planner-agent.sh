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
#   3. Its SCOPE is written down, because scope is the whole decision here: only
#      complex work plans, the measurement that settled it is quoted, there is no
#      fix-round mode, and the spawner is the agent that will build — never the
#      orchestrator, whose context must stay free of plan prose.
#   4. The output contract: ordered steps with file paths, a verbatim
#      '## Acceptance criteria' heading, the project done-check, risks.
#   5. The planner returns the plan as final text (spawner writes the file).
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
echo "test: the scope decision is written down"
assert_contains "complex-only scope" "$content" "tier:complex"
assert_contains "trivial and standard self-plan" "$content" "self-plan"
assert_contains "the measurement that settled it is quoted" "$content" "26% of all work"
assert_contains "reads the issue comments, not just the body" "$content" "comments"

# ---------------------------------------------------------------------------
echo "test: no fix-round mode — review findings are their own work order"
assert_contains "says so explicitly" "$content" "no fix-round mode"
assert_not_contains "no replan mode" "$content" "**replan**"
assert_not_contains "no triage mode" "$content" "**triage**"
assert_not_contains "no fix-list" "$content" "ordered fix-list"

# ---------------------------------------------------------------------------
echo "test: the spawner is the builder, never the orchestrator"
assert_contains "spawned by the agent that will build" "$content" "the agent that will build"
assert_contains "explains the context cost" "$content" "orchestrator reads is prose in the orchestrator"

# ---------------------------------------------------------------------------
echo "test: output contract"
assert_contains "steps with file paths" "$content" "file paths"
assert_contains "acceptance criteria heading verbatim" "$content" "## Acceptance criteria"
assert_contains "project done-check quoted" "$content" "done-check"
assert_contains "risks/unknowns section" "$content" "Risks / unknowns"

# ---------------------------------------------------------------------------
echo "test: planner returns plan as final text; spawner writes the file"
assert_contains "spawner writes the file" "$content" "the spawner writes the file"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
