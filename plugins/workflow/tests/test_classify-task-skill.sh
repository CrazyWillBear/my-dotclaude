#!/usr/bin/env bash
#
# Tests for skills/classify-task/SKILL.md — the /classify-task skill prose.
#
# The skill is prose — not executable code — so we validate its structure,
# required frontmatter fields, and the content obligations the approved design
# demands:
#
#   1. File exists at the expected discovery path.
#   2. Frontmatter contains required fields (name, description, argument-hint,
#      allowed-tools incl. Agent and AskUserQuestion).
#   3. Runs on the main thread (only it can spawn subagents).
#   4. The tier→roster mapping is NOT embedded here — the skill points callers at
#      the plugin's resolve-tier.sh, and the old verbatim tier table is gone.
#   5. Issue resolution via `gh issue view <N> --json title,body,labels`.
#   6. Grounding fan-out spawns Explore agents (model: "sonnet"), 1 vs 2–3 by
#      scope; never the word "explorer".
#   7. The rubric: size is not the signal; the trivial/standard/complex signals.
#   8. Four reasoning questions + an AskUserQuestion confirm/override.
#   9. The load-bearing output contract is now two lines — tier= + rationale= —
#      and the old planner=/implementer=/reviewer= lines are gone.
#
# Run: bash plugins/workflow/tests/test_classify-task-skill.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/skills/classify-task/SKILL.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
echo "test: skill file exists at the expected discovery path"
if [ -f "$SKILL_FILE" ]; then
    ok "SKILL.md present at skills/classify-task/SKILL.md"
else
    no "SKILL.md missing at $SKILL_FILE"
fi

content=""
if [ -f "$SKILL_FILE" ]; then
    content="$(cat "$SKILL_FILE")"
fi

# ---------------------------------------------------------------------------
echo "test: frontmatter required fields"
assert_contains "name field present" "$content" "name: classify-task"
assert_contains "description field present" "$content" "description:"
assert_contains "argument-hint present" "$content" "argument-hint:"
assert_contains "allowed-tools present" "$content" "allowed-tools:"
assert_contains "Agent tool allowed" "$content" "Agent"
assert_contains "AskUserQuestion tool allowed" "$content" "AskUserQuestion"

# ---------------------------------------------------------------------------
echo "test: runs on the main thread"
assert_contains "main thread statement" "$content" "main thread"

# ---------------------------------------------------------------------------
echo "test: tier→roster resolution delegated to resolve-tier.sh (no embedded table)"
assert_contains "resolve-tier helper invoked" "$content" 'resolve-tier.sh'
# Assemble the old tier row from a fragment so this guard does not itself
# reintroduce the literal the repo-wide drift-sweep forbids.
BAR='|'
assert_not_contains "embedded tier table gone" "$content" "$BAR trivial $BAR sonnet $BAR sonnet $BAR opus $BAR"

# ---------------------------------------------------------------------------
echo "test: issue resolution via gh issue view"
assert_contains "gh issue view named" "$content" "gh issue view"
assert_contains "json fields title,body,labels" "$content" "title,body,labels"

# ---------------------------------------------------------------------------
echo "test: grounding fan-out spawns Explore agents"
assert_contains "Explore agent named" "$content" "**Explore**"
assert_contains "Explore spawned on sonnet" "$content" 'model: "sonnet"'
assert_not_contains "never the word explorer" "$content" "explorer"

# ---------------------------------------------------------------------------
echo "test: fan-out count logic (1 vs 2-3 by scope)"
assert_contains "clearly-scoped single agent" "$content" "clearly scoped"
assert_contains "multiple distinct areas" "$content" "distinct"

# ---------------------------------------------------------------------------
echo "test: rubric — size is not the signal, tier signals"
assert_contains "size is not the signal" "$content" "Size is not the signal"
assert_contains "trivial signal" "$content" "no design decisions"
assert_contains "complex signal — seams move" "$content" "seams move"
assert_contains "complex signal — new infrastructure" "$content" "new infrastructure"
assert_contains "complex signal — downstream" "$content" "downstream consequences"

# ---------------------------------------------------------------------------
echo "test: four reasoning questions + confirm/override"
assert_contains "four reasoning questions" "$content" "four"
assert_contains "AskUserQuestion confirm" "$content" "AskUserQuestion"
assert_contains "override option" "$content" "override"
assert_contains "proceed option" "$content" "proceed"

# ---------------------------------------------------------------------------
echo "test: --no-confirm batch mode suppresses the per-issue confirm (for orchestrate)"
assert_contains "--no-confirm documented in argument-hint" "$content" "--no-confirm"
assert_contains "batch mode skips step 4 confirm" "$content" "skip this step"

# ---------------------------------------------------------------------------
echo "test: output contract is now two lines — tier= + rationale= (roster resolved downstream)"
assert_contains "tier= line" "$content" "tier="
assert_contains "rationale= line" "$content" "rationale="
assert_not_contains "planner= line gone" "$content" "planner="
assert_not_contains "implementer= line gone" "$content" "implementer="
assert_not_contains "reviewer= line gone" "$content" "reviewer="

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
