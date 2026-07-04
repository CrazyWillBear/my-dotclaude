#!/usr/bin/env bash
#
# Tests for skills/pipeline/SKILL.md — the /pipeline skill prose.
#
# The skill is prose — not executable code — so we validate its structure,
# required frontmatter fields, and the content obligations the approved design
# demands:
#
#   1. File exists at the expected discovery path.
#   2. Frontmatter contains required fields (name, description) + --max-cycles.
#   3. Worktree entry via EnterWorktree (orchestrate step-0 pattern) and exit
#      via ExitWorktree(keep).
#   4. Grill-mode drift-check invokes the verify-plan skill.
#   5. Models are tier-routed: a Step-0 classify-task call sets a confirmed
#      roster (planner/implementer/reviewer placeholders), so no model is
#      hardcoded — the old model: "sonnet" implementer pin is gone.
#   6. The reviewer is personal-tools:my-review on the baseline..HEAD range.
#   7. Severity routes: lows filed as review-fix + ready-for-agent issues,
#      mediums triaged into one ordered fix-list, highs get ONE collective
#      replan, each critical gets its own full cycle.
#   8. Cap hit with open medium+ → AskUserQuestion (continue/stop/take over).
#   9. Never push; branch left for the user.
#  10. Resume state: .pending.json pointer with the workflow schema
#      (baseline_head et al.), state doc with the plan embedded, deleted on
#      clean finish.
#  11. Hard dependency on personal-tools fails loud.
#
# Run: bash plugins/workflow/tests/test_pipeline-skill.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/skills/pipeline/SKILL.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
echo "test: skill file exists at the expected discovery path"
if [ -f "$SKILL_FILE" ]; then
    ok "SKILL.md present at skills/pipeline/SKILL.md"
else
    no "SKILL.md missing at $SKILL_FILE"
fi

content=""
if [ -f "$SKILL_FILE" ]; then
    content="$(cat "$SKILL_FILE")"
fi

# ---------------------------------------------------------------------------
echo "test: frontmatter contains 'name: pipeline' and a description"
assert_contains "name field present" "$content" "name: pipeline"
assert_contains "description field present" "$content" "description:"

# ---------------------------------------------------------------------------
echo "test: --max-cycles argument (default 2)"
assert_contains "max-cycles arg present" "$content" "--max-cycles"

# ---------------------------------------------------------------------------
echo "test: worktree entry via EnterWorktree, exit via ExitWorktree(keep)"
assert_contains "EnterWorktree call present" "$content" "EnterWorktree(name:"
assert_contains "ExitWorktree keep present" "$content" "ExitWorktree(keep)"
assert_contains "git-dir vs common-dir check" "$content" "--git-common-dir"

# ---------------------------------------------------------------------------
echo "test: grill-mode drift check invokes verify-plan"
assert_contains "verify-plan skill invoked" "$content" "verify-plan"

# ---------------------------------------------------------------------------
echo "test: plan gate — main agent revises, user approves (grill/bare)"
assert_contains "plan gate present" "$content" "plan gate"
assert_contains "no planner round-trip on gate revisions" "$content" "no planner round-trip"

# ---------------------------------------------------------------------------
echo "test: implementer spawned on the tier-routed roster with a work order"
assert_not_contains "no hardcoded sonnet implementer" "$content" 'model: "sonnet"'
assert_contains "implementer roster placeholder" "$content" 'model: "<implementer>"'
assert_contains "work order handed over" "$content" "work order"
assert_contains "implementer agent named" "$content" "workflow:implementer"

# ---------------------------------------------------------------------------
echo "test: Step-0 tier routing via classify-task"
assert_contains "--complexity flag in argument-hint" "$content" "--complexity"
assert_contains "classify-task skill invoked" "$content" "classify-task"
assert_contains "invoked via the Skill tool" "$content" "Skill tool"
assert_contains "tier table row — trivial" "$content" "| trivial | sonnet | sonnet | opus |"
assert_contains "tier table row — standard" "$content" "| standard | opus | sonnet | opus |"
assert_contains "tier table row — complex" "$content" "| complex | fable | opus | fable |"
assert_contains "planner roster placeholder" "$content" 'model: "<planner>"'
assert_contains "reviewer roster placeholder" "$content" 'model: "<reviewer>"'
assert_contains "reviewer model held constant" "$content" "held constant"
assert_contains "issue-mode carve-out — one interactive stop" "$content" "one interactive stop"
assert_contains "tier rationale surfaced" "$content" "rationale"
assert_contains "confirmed roster persisted in state doc" "$content" "confirmed roster"

# ---------------------------------------------------------------------------
echo "test: reviewer is personal-tools:my-review on the branch range"
assert_contains "my-review agent named" "$content" "personal-tools:my-review"
assert_contains "baseline..HEAD range" "$content" "<baseline>..HEAD"
assert_contains "findings block parsed" "$content" '```findings'

# ---------------------------------------------------------------------------
echo "test: severity routes"
assert_contains "lows filed with review-fix label" "$content" "review-fix"
assert_contains "lows filed with ready-for-agent label" "$content" "ready-for-agent"
assert_contains "mediums triaged to one ordered fix-list" "$content" "ordered fix-list"
assert_contains "collective high replan" "$content" "all high findings together"
assert_contains "critical gets its own cycle" "$content" "own full plan"
assert_contains "mixed critical+high ordering specified" "$content" "per-critical cycles **first**"

# ---------------------------------------------------------------------------
echo "test: declared mock-debt is filed (no orchestrate reviewer on this path)"
assert_contains "mock-debt label filed" "$content" "gh label create mock-debt"
assert_contains "mock-debt filing rationale" "$content" "no orchestrate reviewer"

# ---------------------------------------------------------------------------
echo "test: scoped re-review of the fix delta only"
assert_contains "scoped re-review" "$content" "scoped re-review"
assert_contains "fix delta only" "$content" "fix delta"

# ---------------------------------------------------------------------------
echo "test: cap hit with open medium+ pauses via AskUserQuestion"
assert_contains "AskUserQuestion on cap" "$content" "AskUserQuestion"
assert_contains "continue option grants a cycle" "$content" "grant +1 cycle"
assert_contains "user takes over option" "$content" "takes over"
assert_contains "stop/take-over delete the resume state" "$content" "ended must not resurrect"

# ---------------------------------------------------------------------------
echo "test: never push; branch left for the user"
assert_contains "never push stated" "$content" "never push"
assert_contains "never merge stated" "$content" "never merge"
assert_not_contains "no git push command anywhere" "$content" "git push"

# ---------------------------------------------------------------------------
echo "test: resume state — pointer schema + state doc + cleanup"
assert_contains "pointer file named" "$content" ".pending.json"
assert_contains "baseline_head field present" "$content" "baseline_head"
assert_contains "keyed-dir algorithm present" "$content" "sha1sum | cut -c1-16"
assert_contains "state doc named" "$content" "-pipeline.md"
assert_contains "plan embedded in state doc" "$content" "plan text embedded"
assert_contains "deleted on clean finish" "$content" "must not resurrect"

# ---------------------------------------------------------------------------
echo "test: resume entry — continue from the recorded phase"
assert_contains "resume re-enters worktree" "$content" "EnterWorktree(path:"
assert_contains "continue from recorded phase" "$content" "recorded phase"

# ---------------------------------------------------------------------------
echo "test: hard dependency on personal-tools fails loud"
assert_contains "fail loud on missing dep" "$content" "naming the missing piece"
assert_contains "no substitute reviewer" "$content" "Do not substitute"

# ---------------------------------------------------------------------------
echo "test: issue mode guards"
assert_contains "refuses open blockers" "$content" "## Blocked by"
assert_contains "prd label refused" "$content" "prd"
assert_contains "hitl label refused" "$content" "hitl"
assert_contains "plan posted as issue comment" "$content" "gh issue comment"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
