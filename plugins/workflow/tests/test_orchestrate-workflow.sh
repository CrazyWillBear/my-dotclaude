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
#   7. The build phase fans out workflow:implementer agents via parallel(), routing the
#      implementer model per the issue's classified tier.
#   8. The merge phase hands the completed branches to one workflow:merger, ascending.
#   9. The close phase closes merged issues (comment, not delete) then removes worktrees.
#  10. The loop stops on empty ready set / conflict-stop and returns a stopReason.
#  11. Per-issue tiering (#64): a classify phase routes each issue's implementer model by
#      tier, auto-accepted, with --complexity as a blanket escape hatch. The embedded tier
#      table is byte-identical to classify-task/pipeline (the drift guard).
#  12. Per-issue planning (#65): a plan phase runs between classify and build. Trivial issues
#      get a cheap sonnet minimal plan; standard/complex get a workflow:planner routed to the
#      tier's planner model. The plan is threaded to the implementer as its work order. No plan
#      comment is posted and no plan-approval gate fires (autonomous).
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
echo "test: per-issue tiering — classify phase + tier-routed implementer model (#64)"
# The classify phase runs between pick and build.
assert_contains "meta.phases includes classify" "$content" "'classify'"
# The three canonical tier rows are embedded VERBATIM — this is the byte-identical
# drift guard against classify-task/SKILL.md and pipeline/SKILL.md.
assert_contains "verbatim trivial tier row"  "$content" "| trivial | sonnet | sonnet | opus |"
assert_contains "verbatim standard tier row" "$content" "| standard | opus | sonnet | opus |"
assert_contains "verbatim complex tier row"  "$content" "| complex | fable | opus | fable |"
# The build stage routes the implementer model per tier — assert the exact routing
# expression (a bare "model:" would also match the classify agent's model: 'sonnet').
assert_contains "build routes model by tier"     "$content" "TIER_TABLE[tierOf[issue.number]].implementer"
assert_contains "still fans out implementers"    "$content" "agentType: 'workflow:implementer'"
# The blanket escape hatch pins every issue and skips classification.
assert_contains "--complexity escape hatch"      "$content" "args.complexity"
# Classification is auto-accepted — no interactive confirm inside the autonomous run.
assert_contains "classification is auto-accepted" "$content" "auto-accept"

# ---------------------------------------------------------------------------
echo "test: per-issue planning — plan phase + planner routed by tier + work order (#65)"
# The plan phase runs between classify and build — assert the exact ordered phase list
# (a bare 'plan' would also match phase: 'plan' in an agent call).
assert_contains "meta.phases lists plan in order" "$content" "'pick', 'classify', 'plan', 'build', 'merge', 'close'"
# Standard/complex issues get a workflow:planner routed to the tier's planner model —
# assert the exact routing expression (mirrors the build phase's implementer routing).
assert_contains "plan uses workflow:planner"        "$content" "agentType: 'workflow:planner'"
assert_contains "plan routes planner model by tier" "$content" "TIER_TABLE[tierOf[issue.number]].planner"
# Trivial issues get a cheap sonnet minimal plan (a leaf agent, no agentType) — assert
# the actual call site, not just the word "minimal" (which also appears in comments).
assert_contains "trivial routes to the minimal-plan agent" "$content" "minimalPlanPrompt(issue)"
assert_contains "minimal plan runs on sonnet"              "$content" "model: 'sonnet'"
# The plan is handed to the implementer as its work order — implementerPrompt takes the plan
# and the build call site threads the per-issue plan (planOf) into it.
assert_contains "implementerPrompt takes the plan"  "$content" "function implementerPrompt(issue, plan)"
assert_contains "build passes the plan work order"  "$content" "planOf[issue.number]"
# No plan comment is posted and no plan-approval gate fires — the run stays autonomous.
assert_not_contains "no plan issue comment"  "$content" "gh issue comment"
assert_not_contains "no plan-approval gate"  "$content" "AskUserQuestion"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
