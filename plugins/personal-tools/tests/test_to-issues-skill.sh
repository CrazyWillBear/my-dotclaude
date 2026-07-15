#!/usr/bin/env bash
#
# Tests for skills/to-issues/SKILL.md — the slicing skill's prose.
#
# The skill is prose — not executable code — so we validate its structure and the
# content obligations its consumers depend on:
#
#   1. File exists at the expected discovery path, with the required frontmatter.
#   2. The slice body template is intact (What to build / Central mechanism /
#      Acceptance criteria / Blocked by) and slices publish in dependency order.
#   3. The agent-loop labels exist and every slice carries `ready-for-agent`.
#   4. (tier labels) Every slice is ALSO born with a complexity tier —
#      `tier:trivial|standard|complex` — assigned here, at slice time, by
#      classify-task's rubric, and persisted as a LABEL on `gh issue create`.
#
#      Why here: /orchestrate routes each issue's planner/implementer/reviewer
#      models by its tier. That tier used to be guessed at launch by a cheap haiku
#      leaf — ungrounded and thrown away after the run. This skill already explored
#      the repo (or read the PRD) to cut the slices, so it is the cheapest place in
#      the whole flow that can tier them for real. /orchestrate then just READS the
#      label (and backfills any issue that lacks one).
#
# Run: bash plugins/personal-tools/tests/test_to-issues-skill.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/skills/to-issues/SKILL.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
echo "test: skill file exists at the expected discovery path"
if [ -f "$SKILL_FILE" ]; then
    ok "SKILL.md present at skills/to-issues/SKILL.md"
else
    no "SKILL.md missing at $SKILL_FILE"
fi

content=""
if [ -f "$SKILL_FILE" ]; then
    content="$(cat "$SKILL_FILE")"
fi

# ---------------------------------------------------------------------------
echo "test: frontmatter carries the name + description"
assert_contains "name field present"        "$content" "name: to-issues"
assert_contains "description field present" "$content" "description:"

# ---------------------------------------------------------------------------
echo "test: the slice body template is intact"
assert_contains "What to build heading"        "$content" "## What to build"
assert_contains "Central mechanism heading"    "$content" "## Central mechanism"
assert_contains "Acceptance criteria heading"  "$content" "## Acceptance criteria"
assert_contains "Blocked by heading"           "$content" "## Blocked by"
assert_contains "slices publish in dependency order" "$content" "Publish in dependency order"

# ---------------------------------------------------------------------------
echo "test: the agent-loop labels are ensured and applied"
assert_contains "ready-for-agent label created" "$content" "gh label create ready-for-agent"
assert_contains "hitl label created"            "$content" "gh label create hitl"
assert_contains "e2e-gate label created"        "$content" "gh label create e2e-gate"
assert_contains "mock-debt label created"       "$content" "gh label create mock-debt"
assert_contains "every slice is ready-for-agent" "$content" "--label ready-for-agent"

# --- tier at slice time ----------------------------------------------------
echo "test: each slice is assigned a complexity tier at slice time"
assert_contains "tier step named"            "$content" "Give each slice a complexity tier"
assert_contains "classify-task rubric cited" "$content" "classify-task"
# Size is not the signal: a seam move or new infrastructure is complex, mechanical
# no-decision edits are trivial. Slice size correlates with neither.
assert_contains "the rubric's load-bearing rule is quoted" "$content" "Size is not the signal"
assert_contains "seam moves / new infrastructure are complex" "$content" "**new infrastructure**, **seams move**"
assert_contains "mechanical no-decision edits are trivial"    "$content" "mechanical, no design decisions"
assert_contains "the tier is grounded in the exploration already done" \
    "$content" "ground it in the exploration you have **already** done"

echo "test: the three tier labels are ensured before the slices are filed"
assert_contains "tier:trivial label created"  "$content" "gh label create tier:trivial"
assert_contains "tier:standard label created" "$content" "gh label create tier:standard"
assert_contains "tier:complex label created"  "$content" "gh label create tier:complex"

echo "test: every slice is created carrying its tier label"
assert_contains "gh issue create carries --label tier:" "$content" "--label tier:"

echo "test: the tier is shown in the approval quiz and the final report"
assert_contains "tier shown in the step-4 quiz table" "$content" "quiz table"
assert_contains "tier column in the report table"     "$content" "→ tier →"

echo "test: the tier is a routing hint for /orchestrate, not a slicing decision"
assert_contains "orchestrate named as the consumer" "$content" "/orchestrate"

# ---------------------------------------------------------------------------
echo "test: PRD mode never modifies the PRD"
assert_contains "PRD is read-only" "$content" "never modify it"
assert_not_contains "no gh issue edit against the PRD" "$content" "gh issue edit"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
