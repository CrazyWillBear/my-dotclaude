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

# --- per-issue in-workflow classify + launch-resolved ROSTER (issue #64, #53) --
# orchestrate no longer embeds the tier table: the main thread resolves each
# tier via resolve-tier.sh at launch and inlines the values into ONE ROSTER
# const (placeholder form in prose, no literal model/effort values), indexed as
# ROSTER[issue.tier].<role>.model / .effort. The old *_MODEL maps are gone.
echo "test: launch-resolved ROSTER const replaces the embedded tier table + *_MODEL maps"
assert_contains "resolve-tier helper invoked" "$content" 'resolve-tier.sh'
assert_contains "launch-time ROSTER const" "$content" "const ROSTER"
assert_contains "resolved values never hand-written" "$content" "never hand-write"
assert_contains "efforts routed too (ROSTER carries .effort)" "$content" ".effort"
# Assemble the forbidden literals from fragments so these guards don't themselves
# reintroduce the strings the repo-wide drift-sweep forbids (tier row + *_MODEL maps).
BAR='|'
MMAP='_MODEL'
assert_not_contains "embedded tier table gone" "$content" "$BAR trivial $BAR sonnet $BAR sonnet $BAR opus $BAR"
assert_not_contains "old planner-model map gone" "$content" "PLANNER${MMAP}"
assert_not_contains "old implementer-model map gone" "$content" "IMPLEMENTER${MMAP}"
assert_not_contains "old reviewer-model map gone" "$content" "REVIEWER${MMAP}"

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
assert_contains "implementer routed via ROSTER" "$content" "ROSTER[issue.tier].implementer"

# --- per-issue tier-routed plan stage (issue #65, #53) ---------------------
# A plan stage runs AFTER classify and BEFORE the implementer fan-out. The
# planner {model, effort} is routed by ROSTER[issue.tier].planner
# (trivial→minimal plan, standard/complex→workflow:planner mode=plan). The plan
# is handed to the implementer as its work order, and the run stays autonomous —
# no plan comment, no plan gate.
echo "test: a plan stage runs before the implementer/build stage"
assert_contains "plan step named in the round prose" "$content" "Plan each picked issue"
assert_contains "ROSTER routes the planner by tier" "$content" "ROSTER[issue.tier].planner"

echo "test: ROSTER routes the planner by tier (trivial minimal-plan, standard/complex mode: plan)"
assert_contains "trivial → cheap minimal plan" "$content" "minimal-plan"
assert_contains "standard/complex use workflow:planner in plan mode" "$content" "mode: plan"

echo "test: the plan is handed to the implementer as a work order"
assert_contains "implementer gets a work order" "$content" "work order"
assert_contains "plan replaces the implementer self-plan" "$content" "replaces the implementer's self-plan"

echo "test: the run stays autonomous — no plan comment, no plan-approval gate"
assert_contains "no plan comment posted to the issue" "$content" "no plan comment is posted to the issue"
assert_contains "no plan-approval gate fires" "$content" "no plan-approval gate fires"
assert_not_contains "plan is never posted as an issue comment" "$content" "gh issue comment"

# --- per-issue my-review + mock-drift audit; round reviewer removed (#66) ---
# Each built slice is reviewed by personal-tools:my-review at the tier's
# reviewer {model, effort} (ROSTER[issue.tier].reviewer), my-review runs the
# central-mechanism / mock-drift audit, /orchestrate hard-deps on the my-review
# agent (fail loud at launch), and the round-level workflow:reviewer agent is
# gone — no dangling references survive.
echo "test: a per-issue my-review stage reviews each built slice"
assert_contains "my-review agent spawned per issue" "$content" "personal-tools:my-review"
assert_contains "review runs on the issue's branch diff" "$content" "issue-<N>"
assert_contains "findings surface in the round report" "$content" "findings"

echo "test: ROSTER routes the reviewer by tier"
assert_contains "reviewer routed via ROSTER" "$content" "ROSTER[issue.tier].reviewer"

echo "test: /orchestrate hard-deps on the my-review agent (fail loud at launch)"
assert_contains "hard-dependency on the personal-tools plugin" "$content" "personal-tools"
assert_contains "fail loud when my-review unavailable" "$content" "fail loud"

echo "test: the central-mechanism / mock-drift audit runs via my-review"
assert_contains "mock-drift audit named" "$content" "mock-drift"
assert_contains "central-mechanism audit named" "$content" "central-mechanism"

echo "test: the round-level workflow:reviewer agent is gone (no dangling refs)"
assert_not_contains "no workflow:reviewer round agent" "$content" "workflow:reviewer"
assert_not_contains "no reference to the deleted reviewer.md" "$content" "reviewer.md"
assert_not_contains "no stale 'per-issue review lands later' prose" "$content" "lands in a later slice"

# --- severity-routed fix loop + finding filing + mock-debt (issue #67) ------
# The round now ACTS on findings via a per-issue severity-routed fix loop capped
# by --max-cycles (default 3), BEFORE the branch merges: critical→own cycle,
# high→collective replan, medium→triage, low→file. All-lows/clean passes;
# cap-exhausted-with-medium+ files those as review-fix follow-ups and merges
# anyway (autonomous — no cap gate). The workflow files lows + cap-remainder and
# re-blocks dependents; mock-debt filing stays my-review's job.
echo "test: --max-cycles caps the per-issue fix loop (default 3, initial review free)"
assert_contains "--max-cycles in argument-hint" "$content" "[--max-cycles K=3]"
assert_contains "--max-cycles named in the body" "$content" "--max-cycles K"
assert_contains "fix-loop cap default 3" "$content" "default **3**"
assert_contains "initial review is free" "$content" "initial review is free"
assert_contains "cap counts re-reviews" "$content" "counts re-reviews"

echo "test: findings route by severity (critical/high/medium/low)"
assert_contains "critical → own full cycle" "$content" "own full plan→implement→review cycle"
assert_contains "high → collective replan" "$content" "collective replan"
assert_contains "high/critical replan uses planner mode=replan" "$content" "mode=replan"
assert_contains "medium → triage" "$content" "mode=triage"
assert_contains "low → filed, never fixed in-run" "$content" "never fixed in-run"

echo "test: re-reviews cover only the fix delta; reviewer model held constant"
assert_contains "re-review scoped to the fix delta" "$content" "<pre-fix HEAD>..HEAD"
assert_contains "reviewer model held constant across re-reviews" "$content" "held constant"

echo "test: all-lows/clean passes; cap-exhausted-with-medium+ merges anyway (autonomous)"
assert_contains "all-lows passes the branch" "$content" "all-lows"
assert_contains "cap remainder merges the branch anyway" "$content" "merges anyway"
assert_contains "no interactive cap gate (autonomous)" "$content" "No cap gate"
assert_not_contains "no pipeline-style +1-cycle grant at the cap" "$content" "grant +1 cycle"

echo "test: workflow files lows + cap-remainder as review-fix + ready-for-agent"
assert_contains "review-fix label filed by the workflow" "$content" "--label review-fix"
assert_contains "ready-for-agent label filed by the workflow" "$content" "--label ready-for-agent"
assert_contains "cap-remainder is filed as a follow-up" "$content" "cap-remainder"

echo "test: workflow re-blocks dependents' ## Blocked by via gh issue edit"
assert_contains "dependent re-block uses gh issue edit" "$content" "gh issue edit"
assert_contains "re-block appends into the dependent's existing Blocked by" "$content" "into that dependent's existing"

echo "test: mock-debt filing stays my-review's job — the workflow does not re-file it"
assert_contains "mock-debt filing owned by my-review" "$content" "my-review OWNS"
assert_contains "workflow does not re-file mock-debt" "$content" "does not re-file mock-debt"

echo "test: round reorder — review + fix loop run BEFORE the merge"
assert_contains "fix loop acts before the branch merges" "$content" "before it merges"
assert_contains "merge runs after the fix loop" "$content" "After the fix loop"

echo "test: end-of-run still mirrors the mock-debt ledger + prints a summary"
assert_contains "ledger mirror still present" "$content" "## Mock-debt ledger"
assert_contains "ledger summary still printed" "$content" "mock-debt: N open"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
