#!/usr/bin/env bash
#
# Tests for skills/orchestrate/SKILL.md — the orchestrate skill prose.
#
# The skill is prose — not executable code — so we validate its structure,
# required frontmatter fields, and the key content obligations the issue-18
# acceptance criteria demand:
#
#   1. File exists at the expected discovery path.
#   2. Frontmatter contains required fields (name, description).
#   3. The skill instructs the orchestrator to call prd-reap.sh at end-of-run
#      with the run's closed issue numbers.
#   4. The skill names the correct helper path so agents call it correctly.
#   5. The skill describes the 'ready' output line and its meaning.
#   6. The skill describes the 'blocked' output line and its meaning.
#   7. The skill offers (prompts, never auto-closes) for each ready PRD.
#   8. The skill instructs using gh issue close (not delete) for a yes answer.
#   9. A blocked PRD is reported, not offered for closing.
#  10. When nothing qualifies the final report is unchanged (no prompt).
#  11. The offer/note appears only end-of-run — mid-loop rounds are uninterrupted.
#  12. The skill never edits the PRD body.
#  13. (issue #63) The skill invokes the Workflow tool for the round loop — the
#      round no longer runs on the main thread, the Workflow permission dialog is
#      the single launch gate, the orchestration worktree is passed in as the
#      base and exited via ExitWorktree(keep), and the workflow runs
#      build (workflow:implementer, up to K) -> merge (workflow:merger) -> close,
#      stopping on an empty ready set / conflict-stop / red done-check /
#      implementer failure.
#
# Run: bash plugins/workflow/tests/test_orchestrate-skill.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/skills/orchestrate/SKILL.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
echo "test: skill file exists at the expected discovery path"
if [ -f "$SKILL_FILE" ]; then
    ok "SKILL.md present at skills/orchestrate/SKILL.md"
else
    no "SKILL.md missing at $SKILL_FILE"
fi

# Read the file once for all content checks.
content=""
if [ -f "$SKILL_FILE" ]; then
    content="$(cat "$SKILL_FILE")"
fi

# ---------------------------------------------------------------------------
echo "test: frontmatter contains 'name: orchestrate'"
assert_contains "name field present" "$content" "name: orchestrate"

# ---------------------------------------------------------------------------
echo "test: frontmatter contains a description field"
assert_contains "description field present" "$content" "description:"

# ---------------------------------------------------------------------------
echo "test: skill instructs calling prd-reap.sh at end-of-run"
assert_contains "prd-reap.sh invocation present" "$content" "prd-reap.sh"

# ---------------------------------------------------------------------------
echo "test: skill names the correct helper path (plugins/workflow/scripts/prd-reap.sh)"
assert_contains "correct helper path present" "$content" "plugins/workflow/scripts/prd-reap.sh"

# ---------------------------------------------------------------------------
echo "test: skill passes closed issue numbers to the helper"
# The invocation must show numbers (N1, N2, etc.) being passed as arguments.
assert_contains "closed issue numbers passed as arguments" "$content" "N1"

# ---------------------------------------------------------------------------
echo "test: skill describes the 'ready' output line"
assert_contains "ready output line described" "$content" "ready <prd_number>"

# ---------------------------------------------------------------------------
echo "test: skill describes the 'blocked' output line"
assert_contains "blocked output line described" "$content" "blocked <prd_number> hitl"

# ---------------------------------------------------------------------------
echo "test: skill prompts the user (never auto-closes) for a ready PRD"
assert_contains "offer prompt present (yes/no)" "$content" "yes/no"
assert_contains "never auto-close language present" "$content" "never auto-close"

# ---------------------------------------------------------------------------
echo "test: skill instructs gh issue close (not delete) on yes"
assert_contains "gh issue close present" "$content" "gh issue close"
assert_not_contains "gh issue delete must NOT appear" "$content" "gh issue delete"

# ---------------------------------------------------------------------------
echo "test: skill instructs adding a completion comment when closing"
assert_contains "completion comment present" "$content" "--comment"

# ---------------------------------------------------------------------------
echo "test: skill never edits the PRD spec content (ledger section carve-out aside)"
assert_contains "never edit PRD spec content stated" "$content" "Never edit the PRD's spec content"

# ---------------------------------------------------------------------------
echo "test: skill reports blocked PRDs without offering to close them"
assert_contains "blocked reported not offered" "$content" "without offering to close"

# ---------------------------------------------------------------------------
echo "test: skill specifies no-op when helper prints nothing (autonomous contract)"
assert_contains "no-op when nothing qualifies" "$content" "the final report is unchanged"

# ---------------------------------------------------------------------------
echo "test: prd-reap step is end-of-run only (after all rounds)"
assert_contains "end-of-run placement stated" "$content" "After **all rounds**"

# ---------------------------------------------------------------------------
echo "test: mid-loop rounds are uninterrupted"
assert_contains "mid-loop uninterrupted stated" "$content" "never interrupt mid-loop rounds"

# --- mock-debt gate (C7) ---------------------------------------------------
echo "test: ready-rule holds the e2e-gate while mock-debt is open"
assert_contains "e2e-gate referenced in ready-rule" "$content" "e2e-gate"
assert_contains "mock-debt gate tag present" "$content" "Mock-debt gate (C7)"
assert_contains "mock-debt label query is the gate" "$content" "--label mock-debt --state open"
assert_contains "gate holds while debt open" "$content" "not ready"

echo "test: orchestrator mirrors the ledger into the PRD body (visibility, not enforcement)"
assert_contains "ledger section named" "$content" "## Mock-debt ledger"
assert_contains "label query is authoritative for the gate" "$content" "authoritative"

echo "test: round report surfaces open mock-debt"
assert_contains "report mentions mock-debt" "$content" "mock-debt: N open"

# --- worktree isolation (step 0) -------------------------------------------
echo "test: step 0 runs the whole loop in one orchestration worktree"
assert_contains "step 0 enters an orchestration worktree via EnterWorktree" "$content" "EnterWorktree(name:"
assert_contains "base recorded before worktree entry" "$content" 'base=$(git rev-parse HEAD)'
assert_contains "worktree base drift guard resets to base" "$content" 'git reset --hard "$base"'
assert_contains "names the orchestration worktree" "$content" "orchestration worktree"
assert_contains "result is left on the orchestration branch" "$content" "orchestration branch"
assert_contains "merger is handed the orchestration-worktree path" "$content" "orchestration-worktree"
assert_contains "primary checkout is never touched" "$content" "primary checkout is never touched"

# --- Workflow-backed round (issue #63) -------------------------------------
echo "test: frontmatter allows the Workflow tool"
assert_contains "Workflow tool allowed" "$content" "Workflow"

echo "test: frontmatter retains Skill + AskUserQuestion (end-of-run PRD-close offer)"
assert_contains "Skill tool allowed" "$content" "Skill"
assert_contains "AskUserQuestion tool allowed" "$content" "AskUserQuestion"

echo "test: argument-hint parses N rounds and --max K"
assert_contains "N rounds + --max K in argument-hint" "$content" "[N rounds=1] [--max K=3]"

echo "test: the round loop runs inside the Workflow, not on the main thread"
assert_contains "skill invokes the Workflow tool" "$content" "Workflow tool"
assert_contains "round no longer runs on the main thread" "$content" "no longer runs the round on the main thread"
assert_contains "Workflow permission dialog is the single launch gate" "$content" "single launch gate"

echo "test: the orchestration worktree base is passed into the Workflow, exited with keep"
assert_contains "orchestration worktree passed into the workflow as base" "$content" "passes the orchestration worktree"
assert_contains "ExitWorktree(keep) on return" "$content" "ExitWorktree(keep)"

echo "test: the workflow builds up to K issues, one implementer each"
assert_contains "up to K issues per round" "$content" "up to **K**"
assert_contains "one workflow:implementer per picked issue" "$content" "workflow:implementer"

echo "test: completed branches go to the workflow:merger, merged issues are closed"
assert_contains "merger merges the completed branches" "$content" "workflow:merger"
assert_contains "merged issues are closed" "$content" "gh issue close"

echo "test: stop conditions — empty ready set / conflict-stop / red done-check / implementer failure"
assert_contains "empty ready set stops the loop" "$content" "empty ready set"
assert_contains "conflict-stop stops the loop" "$content" "conflict-stop"
assert_contains "red done-check stops the loop" "$content" "red done-check"
assert_contains "implementer failure stops the loop" "$content" "implementer failure"

# --- per-issue in-workflow classify + tier routing (issue #64) -------------
# orchestrate now carries the tier table, so it JOINS the drift-guard trio
# (classify-task + pipeline). The three rows must appear byte-identical.
echo "test: tier table present verbatim (drift guard vs classify-task + pipeline)"
assert_contains "tier table header" "$content" "| tier | planner | implementer | reviewer |"
assert_contains "tier table separator" "$content" "|---|---|---|---|"
assert_contains "trivial row" "$content" "| trivial | sonnet | sonnet | opus |"
assert_contains "standard row" "$content" "| standard | opus | sonnet | opus |"
assert_contains "complex row" "$content" "| complex | fable | opus | fable |"

echo "test: --complexity escape hatch pins every issue and skips classification"
assert_contains "--complexity in argument-hint" "$content" "[--complexity trivial|standard|complex]"
assert_contains "--complexity pins every issue" "$content" "pins every issue"
assert_contains "--complexity skips classification" "$content" "skips classification"

echo "test: each ready issue is classified in-workflow (explore->classify)"
assert_contains "in-workflow explore→classify stage" "$content" "explore→classify"
assert_contains "classify emits a real tier" "$content" "real tier"
assert_contains "classify runs inside the workflow leaf" "$content" "in-workflow"

echo "test: classification is auto-accepted with no interactive confirm"
assert_contains "tier auto-accepted" "$content" "auto-accepted"
assert_contains "no interactive confirm" "$content" "no interactive confirm"

echo "test: the implementer model is routed by the issue's tier"
assert_contains "implementer tier-routed" "$content" "tier-routes its implementer"
assert_contains "routed via the implementer column" "$content" "implementer column"

# --- per-issue tier-routed plan stage (issue #65) --------------------------
# A plan stage runs AFTER classify and BEFORE the implementer fan-out. The
# planner model is routed by the tier table's PLANNER column
# (trivial→sonnet minimal plan, standard→opus, complex→fable via
# workflow:planner mode=plan). The plan is handed to the implementer as its
# work order, and the run stays autonomous — no plan comment, no plan gate.
echo "test: a plan stage runs before the implementer/build stage"
assert_contains "plan step named in the round prose" "$content" "Plan each picked issue"
assert_contains "PLANNER_MODEL map present" "$content" "PLANNER_MODEL"

echo "test: PLANNER_MODEL routes the planner by tier (the tier table's planner column)"
assert_contains "trivial → cheap sonnet minimal plan" "$content" "minimal-plan"
assert_contains "standard → opus planner" "$content" 'standard: "opus"'
assert_contains "complex → fable planner" "$content" 'complex: "fable"'
assert_contains "standard/complex use workflow:planner in plan mode" "$content" "mode: plan"
assert_contains "planner column drives the plan stage" "$content" "planner column"

echo "test: the plan is handed to the implementer as a work order"
assert_contains "implementer gets a work order" "$content" "work order"
assert_contains "plan replaces the implementer self-plan" "$content" "replaces the implementer's self-plan"

echo "test: the run stays autonomous — no plan comment, no plan-approval gate"
assert_contains "no plan comment posted to the issue" "$content" "no plan comment is posted to the issue"
assert_contains "no plan-approval gate fires" "$content" "no plan-approval gate fires"
assert_not_contains "plan is never posted as an issue comment" "$content" "gh issue comment"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
