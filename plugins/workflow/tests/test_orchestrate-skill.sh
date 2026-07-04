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
assert_contains "names the orchestration worktree" "$content" "orchestration worktree"
assert_contains "result is left on the orchestration branch" "$content" "orchestration branch"
assert_contains "merger is handed the orchestration-worktree path" "$content" "orchestration-worktree"
assert_contains "primary checkout is never touched" "$content" "primary checkout is never touched"

# --- per-issue tier routing (issue #50) ------------------------------------
echo "test: frontmatter gains Skill + AskUserQuestion for the classify + batch confirm"
assert_contains "Skill tool allowed" "$content" "Skill"
assert_contains "AskUserQuestion tool allowed" "$content" "AskUserQuestion"

echo "test: --complexity escape hatch is documented in the argument-hint"
assert_contains "--complexity in argument-hint" "$content" "--complexity trivial|standard|complex"

echo "test: each ready issue is classified via the classify-task skill before fan-out"
assert_contains "classify-task skill invoked" "$content" "classify-task"
assert_contains "invoked in batch mode (no per-issue confirm)" "$content" "--no-confirm"

echo "test: tier table rows present verbatim (drift guard vs classify-task/pipeline)"
assert_contains "trivial row" "$content" "| trivial | sonnet | sonnet | opus |"
assert_contains "standard row" "$content" "| standard | opus | sonnet | opus |"
assert_contains "complex row" "$content" "| complex | fable | opus | fable |"

echo "test: only the implementer model is routed per issue (merger/reviewer are per-round)"
assert_contains "only implementer routed per issue" "$content" "only the implementer"

echo "test: exactly one batch confirmation per round — not one question per issue"
assert_contains "one summary table for the whole round" "$content" "ONE summary table for the whole round"
assert_contains "single AskUserQuestion, never per issue" "$content" "never one per issue"

echo "test: an accept-all / zero-override path exists"
assert_contains "accept-all path" "$content" "Accept all"

echo "test: row-level override swaps the whole tier row"
assert_contains "row-level override" "$content" "override"
assert_contains "override swaps the whole row (never mixed)" "$content" "whole"

echo "test: confirmed implementer model is passed explicitly on each implementer spawn"
assert_contains "explicit implementer model placeholder on spawn" "$content" 'model: "<implementer>"'

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
