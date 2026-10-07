#!/usr/bin/env bash
#
# Tests for skills/to-prd/SKILL.md — the PRD skill's prose.
#
# The skill is prose, so we pin the content obligations its consumers depend on:
#
#   1. File exists with the required frontmatter.
#   2. The PRD is a decision record: a fixed core (Problem, Goals, Success, Solution,
#      Technical + Product Decisions, Out of Scope) and optional sections that are
#      omitted entirely when they do not apply (User Stories, Testing Decisions,
#      Open Questions).
#   3. Gaps are asked inline; rationale is recorded when known and asked for only on
#      big decisions.
#   4. The mock-drift guard survives: central mechanism, `prd` label, never
#      `ready-for-agent`.
#
# Run: bash plugins/workflow/tests/test_to-prd-skill.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/skills/to-prd/SKILL.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
echo "test: skill file exists with frontmatter"
content=""
if [ -f "$SKILL_FILE" ]; then
    ok "SKILL.md present at skills/to-prd/SKILL.md"
    content="$(cat "$SKILL_FILE")"
else
    no "SKILL.md missing at $SKILL_FILE"
fi
assert_contains "name field present"        "$content" "name: to-prd"
assert_contains "description field present" "$content" "description:"

# ---------------------------------------------------------------------------
echo "test: the PRD is a decision record with a fixed core"
for h in Problem Goals Success Solution "Technical Decisions" "Product Decisions" "Out of Scope"; do
    assert_contains "core heading: $h" "$content" "## $h"
done
assert_not_contains "old Implementation Decisions heading is gone" "$content" "## Implementation Decisions"
assert_not_contains "old Further Notes heading is gone"            "$content" "## Further Notes"

echo "test: optional sections are omitted entirely when not applicable"
for h in "User Stories" "Testing Decisions" "Open Questions"; do
    assert_contains "optional heading: $h" "$content" "## $h"
done
assert_contains "optional sections are omitted, not left empty" "$content" "omit"
assert_contains "Success is a checklist plus prose"             "$content" "checklist"

# ---------------------------------------------------------------------------
echo "test: any thorough discussion is a valid input, gaps are asked inline"
assert_contains "gaps asked via AskUserQuestion" "$content" "AskUserQuestion"
assert_not_contains "no longer bounces to /grill-me" "$content" "run \`/grill-me\` first"
assert_not_contains "no Shared understanding block dependency" "$content" "## Shared understanding"

echo "test: decisions keep rationale; big ones are asked about"
assert_contains "rationale recorded when known" "$content" "rationale"
assert_contains "big decisions without a reason are asked" "$content" "big decision"

echo "test: concrete names are kept, the file-path ban is gone"
assert_not_contains "no ban on file paths" "$content" "not file paths"

# ---------------------------------------------------------------------------
echo "test: the mock-drift guard and labels survive"
assert_contains "central mechanism named"        "$content" "central mechanism"
assert_contains "anti-mock-drift linked"         "$content" "anti-mock-drift"
assert_contains "prd label applied"              "$content" "--label prd"
assert_contains "never ready-for-agent"          "$content" "**Do not** label the PRD \`ready-for-agent\`"
assert_contains "/to-issues is the next step"    "$content" "/to-issues"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
