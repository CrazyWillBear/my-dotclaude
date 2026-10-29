#!/usr/bin/env bash
#
# Tests for skills/adhoc/SKILL.md — the ad-hoc lane: one explicit unit of work as a subagent
# chain on the main thread. Grep tests; each pins an instruction whose loss fails silently.
#
# Run: bash plugins/workflow/tests/test_adhoc-skill.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_FILE="$SCRIPT_DIR/../skills/adhoc/SKILL.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

[ -f "$SKILL_FILE" ] || { printf '  FAIL: SKILL.md missing at %s\n' "$SKILL_FILE"; exit 1; }
BODY="$(cat "$SKILL_FILE")"
FM="$(sed -n '/^---$/,/^---$/p' "$SKILL_FILE")"

echo "test: frontmatter"
assert_contains "name" "$FM" "name: adhoc"
assert_contains "spawns subagents" "$FM" "Agent"

echo "test: explicit or nothing"
for w in "**What**" "**Where**" "**Done**"; do assert_contains "names $w" "$BODY" "$w"; done
assert_contains "ambiguity builds nothing" "$BODY" "build nothing"

echo "test: claude only — a codex cell takes the chain's top cell"
assert_contains "the resolver" "$BODY" "bash ~/.claude/kit/infra/scripts/resolve-tier.sh <tier>"
assert_contains "the top-cell rule" "$BODY" 'resolve-tier.sh <tier> $((implementer_chain-1))'
assert_contains "codex/fable reviewer becomes opus" "$BODY" "becomes \`opus\`"

echo "test: the chain"
assert_contains "classify from the message, no Explore fan-out" "$BODY" "no Explore fan-out"
assert_contains "never prompts on the tier" "$BODY" "Never prompt to confirm it"
assert_contains "its own worktree" "$BODY" 'EnterWorktree(name: "adhoc-<slug>")'
assert_contains "planner for complex only" "$BODY" "**Plan (complex only)**"
assert_contains "the implementer subagent" "$BODY" "workflow:implementer"
assert_contains "my-review as a subagent" "$BODY" "personal-tools:my-review"
assert_contains "a fresh implementer per fix round" "$BODY" "a **fresh** \`workflow:implementer\` per round"
assert_contains "never the one that wrote it" "$BODY" "Never the implementer that wrote the code"
assert_contains "the merge preview" "$BODY" "merge-fold.sh\" --preview <target>"
assert_contains "offered, never taken" "$BODY" "Offered, never taken"
assert_not_contains "no sessions" "$BODY" "--bg"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
