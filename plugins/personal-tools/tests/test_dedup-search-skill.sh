#!/usr/bin/env bash
#
# Tests for the dedup-search skill (SKILL.md).
#
# The skill is prose — not executable code — so we validate its structure,
# required frontmatter fields, and the key content obligations the issue
# acceptance criteria demand:
#
#   1. File exists at the expected discovery path.
#   2. Frontmatter contains required fields (name, description).
#   3. The skill names the real helper path so agents call it correctly.
#   4. The skill documents term-extraction guidance.
#   5. The skill documents the reuse | extend | none triage method.
#   6. The skill requires an explicit "nothing reusable" statement rather than
#      silent empty output.
#   7. The helper invocation syntax (repo-path + terms) appears in the prose.
#
# Run: bash plugins/personal-tools/tests/test_dedup-search-skill.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/skills/dedup-search/SKILL.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
echo "test: skill file exists at the expected discovery path"
if [ -f "$SKILL_FILE" ]; then
    ok "SKILL.md present at skills/dedup-search/SKILL.md"
else
    no "SKILL.md missing at $SKILL_FILE"
fi

# Read the file once for all content checks.
content=""
if [ -f "$SKILL_FILE" ]; then
    content="$(cat "$SKILL_FILE")"
fi

# ---------------------------------------------------------------------------
echo "test: frontmatter contains 'name: dedup-search'"
assert_contains "name field present" "$content" "name: dedup-search"

# ---------------------------------------------------------------------------
echo "test: frontmatter contains a description field"
assert_contains "description field present" "$content" "description:"

# ---------------------------------------------------------------------------
echo "test: skill names the real helper path"
assert_contains "helper path mentioned" "$content" "plugins/personal-tools/scripts/dedup-search.sh"

# ---------------------------------------------------------------------------
echo "test: skill documents term-extraction guidance"
assert_contains "term extraction prose present" "$content" "search terms"

# ---------------------------------------------------------------------------
echo "test: skill documents the reuse triage verdict"
assert_contains "reuse verdict documented" "$content" "reuse"

# ---------------------------------------------------------------------------
echo "test: skill documents the extend triage verdict"
assert_contains "extend verdict documented" "$content" "extend"

# ---------------------------------------------------------------------------
echo "test: skill documents the none triage verdict"
assert_contains "none verdict documented" "$content" "none"

# ---------------------------------------------------------------------------
echo "test: skill requires explicit nothing-reusable statement"
# The exact phrase "nothing reusable" (or close enough) must appear so agents
# know to emit it rather than staying silent.
assert_contains "nothing reusable phrase present" "$content" "nothing reusable"

# ---------------------------------------------------------------------------
echo "test: skill documents the helper invocation syntax (repo-path argument)"
assert_contains "repo-path arg in invocation" "$content" "repo-root"

# ---------------------------------------------------------------------------
echo "test: skill documents the helper invocation syntax (term arguments)"
assert_contains "term args in invocation" "$content" "term"

# ---------------------------------------------------------------------------
echo "test: helper output format is described (angle / file:line / snippet)"
assert_contains "output angle column described" "$content" "angle"

# ---------------------------------------------------------------------------
echo "test: skill instructs agents to read matched code before triaging"
assert_contains "read before triaging" "$content" "Read"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
