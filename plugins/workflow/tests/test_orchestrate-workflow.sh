#!/usr/bin/env bash
#
# Tests for skills/orchestrate/orchestrate.workflow.js — the committed Workflow
# script the orchestrate skill drives via the Workflow tool's scriptPath.
#
# The script is a JS DSL module (not run here), so we validate its structure and
# the content obligations the issue-#63 work order demands:
#
#   1. File exists at the expected discovery path.
#   2. First line declares `export const meta` (the Workflow tool reads it).
#   3. The four round phases are named: pick, build, merge, close.
#   4. It consumes the args the skill passes (rounds, max, base, baseBranch, doneCheck).
#   5. The pick phase computes the ready set (label/state filter, Blocked by refs,
#      skip hitl/prd) and holds the e2e-gate while mock-debt is open.
#   6. The pick phase creates per-issue worktrees deterministically.
#   7. The build phase fans out workflow:implementer agents via parallel() (no model).
#   8. The merge phase hands the completed branches to one workflow:merger, ascending.
#   9. The close phase closes merged issues (comment, not delete) then removes worktrees.
#  10. The loop stops on empty ready set / conflict-stop and returns a stopReason.
#  11. No tier routing / classify / model option leaks into #63's script.
#
# Run: bash plugins/workflow/tests/test_orchestrate-workflow.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WF_FILE="$PLUGIN_ROOT/skills/orchestrate/orchestrate.workflow.js"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
echo "test: workflow script exists at the expected discovery path"
if [ -f "$WF_FILE" ]; then
    ok "orchestrate.workflow.js present at skills/orchestrate/"
else
    no "orchestrate.workflow.js missing at $WF_FILE"
fi

# Read the file once for all content checks.
content=""
first_line=""
if [ -f "$WF_FILE" ]; then
    content="$(cat "$WF_FILE")"
    first_line="$(head -n1 "$WF_FILE")"
fi

# ---------------------------------------------------------------------------
echo "test: first line declares the Workflow meta export"
case "$first_line" in
    "export const meta"*) ok "first line starts with export const meta" ;;
    *) no "first line must start with 'export const meta' (got: $first_line)" ;;
esac

# ---------------------------------------------------------------------------
echo "test: meta names the four round phases"
assert_contains "pick phase named"  "$content" "'pick'"
assert_contains "build phase named" "$content" "'build'"
assert_contains "merge phase named" "$content" "'merge'"
assert_contains "close phase named" "$content" "'close'"

# ---------------------------------------------------------------------------
echo "test: consumes the args the skill passes"
assert_contains "reads args.rounds"     "$content" "args.rounds"
assert_contains "reads args.max"        "$content" "args.max"
assert_contains "reads args.base"       "$content" "args.base"
assert_contains "reads args.baseBranch" "$content" "args.baseBranch"
assert_contains "reads args.doneCheck"  "$content" "args.doneCheck"

# ---------------------------------------------------------------------------
echo "test: pick phase computes the ready set from gh"
assert_contains "ready-for-agent label + open state filter" "$content" "--label ready-for-agent --state open"
assert_contains "parses the Blocked by section"             "$content" "## Blocked by"
assert_contains "recognizes the no-blocker literal"         "$content" "None - can start immediately"
assert_contains "skips hitl issues"                         "$content" "hitl"
assert_contains "skips prd issues"                          "$content" "prd"

# ---------------------------------------------------------------------------
echo "test: pick phase holds the e2e-gate while mock-debt is open (C7)"
assert_contains "mock-debt gate tag present"        "$content" "Mock-debt gate (C7)"
assert_contains "open mock-debt label query"        "$content" "--label mock-debt --state open"
assert_contains "e2e-gate referenced"               "$content" "e2e-gate"
assert_contains "gate holds the issue as not ready" "$content" "not ready"

# ---------------------------------------------------------------------------
echo "test: pick phase creates per-issue worktrees deterministically"
assert_contains "deterministic worktree add path" "$content" "worktree add .worktrees/issue-"
assert_contains "deterministic issue branch"      "$content" "-b issue-"

# ---------------------------------------------------------------------------
echo "test: build phase fans out implementers via parallel()"
assert_contains "parallel fan-out"          "$content" "parallel("
assert_contains "workflow:implementer type" "$content" "agentType: 'workflow:implementer'"

# ---------------------------------------------------------------------------
echo "test: merge phase hands completed branches to one merger, ascending"
assert_contains "workflow:merger type"       "$content" "agentType: 'workflow:merger'"
assert_contains "ascending merge order"      "$content" "ascending"
assert_contains "done-check gates the merge" "$content" "done-check"

# ---------------------------------------------------------------------------
echo "test: close phase closes merged issues (comment, never delete) then removes worktrees"
assert_contains "gh issue close on merged"   "$content" "gh issue close"
assert_contains "closes with a comment"      "$content" "--comment"
assert_contains "removes the child worktree" "$content" "git worktree remove"
assert_contains "prunes worktrees after"     "$content" "git worktree prune"
assert_not_contains "never gh issue delete"  "$content" "gh issue delete"

# ---------------------------------------------------------------------------
echo "test: the loop stops and reports a stopReason"
assert_contains "empty ready set stop literal" "$content" "ready set is empty"
assert_contains "conflict-stop condition"      "$content" "conflict-stop"
assert_contains "returns a stopReason"         "$content" "stopReason"

# ---------------------------------------------------------------------------
echo "test: script obeys the ambient-body Workflow DSL (no ctx wrapper)"
# The Workflow tool runs the body directly after the meta export with args/agent/
# parallel/phase/log as ambient globals — a default export or run(ctx) wrapper means
# the loop never executes. Guard the exact regression the first cut shipped.
assert_not_contains "no default export"       "$content" "export default"
assert_not_contains "no run(ctx) wrapper"     "$content" "function run("
assert_not_contains "no ctx destructure"      "$content" "= ctx"
assert_contains     "reads the ambient args"  "$content" "args.rounds ?? 1"
assert_contains     "top-level result return" "$content" "return { roundsRun"

# ---------------------------------------------------------------------------
echo "test: agent schemas are real JSON Schema, not shorthand"
assert_contains     "JSON Schema object type" "$content" "type: 'object'"
assert_contains     "JSON Schema array type"  "$content" "type: 'array'"
assert_not_contains "no int shorthand type"   "$content" "number: 'int'"
assert_not_contains "no bool shorthand type"  "$content" "acceptanceMet: 'bool'"

# ---------------------------------------------------------------------------
echo "test: no tier routing / classify / model option leaks into #63's script"
assert_not_contains "no verbatim tier row" "$content" "| trivial | sonnet | sonnet | opus |"
assert_not_contains "no classify wiring"   "$content" "classify"
assert_not_contains "no model option"      "$content" "model:"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
