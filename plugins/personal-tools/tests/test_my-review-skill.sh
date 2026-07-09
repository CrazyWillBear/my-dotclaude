#!/usr/bin/env bash
#
# Tests for skills/my-review/SKILL.md — the /my-review slash-command prose.
#
# The skill is prose — not executable code. It became a main-thread launcher:
# it asks whether to run on opus or fable, then spawns the my-review agent on
# that model. We validate:
#
#   1. File exists at the expected discovery path.
#   2. Frontmatter names the skill and drops the `agent:` executor (it now
#      spawns the agent explicitly via the Agent tool instead of running inside
#      it), declaring Agent + AskUserQuestion + git/gh Bash in allowed-tools.
#   3. The reviewer model is picked forward-or-judge: --complexity wins, else a
#      tier judged from a cheap diff peek; complex asks opus vs fable,
#      not-complex picks opus with no prompt (no blind ask). It stays
#      dependency-free of the workflow plugin (no classify-task / resolve-tier.sh).
#   4. The spawn uses subagent_type: personal-tools:my-review with a model
#      override.
#   5. $ARGUMENTS passes through to the agent as the target.
#
# Run: bash plugins/personal-tools/tests/test_my-review-skill.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/skills/my-review/SKILL.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
echo "test: skill file exists at the expected discovery path"
if [ -f "$SKILL_FILE" ]; then
    ok "SKILL.md present at skills/my-review/SKILL.md"
else
    no "SKILL.md missing at $SKILL_FILE"
fi

content=""
if [ -f "$SKILL_FILE" ]; then
    content="$(cat "$SKILL_FILE")"
fi

# ---------------------------------------------------------------------------
echo "test: frontmatter names the skill, drops the agent: executor"
assert_contains "name field present" "$content" "name: my-review"
assert_not_contains "agent: executor dropped" "$content" "agent: my-review"

# ---------------------------------------------------------------------------
echo "test: allowed-tools declares Agent + AskUserQuestion + git/gh Bash"
assert_contains "allowed-tools present" "$content" "allowed-tools:"
assert_contains "Agent tool allowed" "$content" "Agent"
assert_contains "AskUserQuestion tool allowed" "$content" "AskUserQuestion"
assert_contains "git Bash allowed for the diff peek" "$content" "Bash(git:*)"
assert_contains "gh Bash allowed for the PR diff peek" "$content" "Bash(gh:*)"

# ---------------------------------------------------------------------------
echo "test: forward-or-judge tier selection (--complexity wins, else a diff peek)"
assert_contains "--complexity flag honored" "$content" "--complexity"
assert_contains "forward-or-judge described" "$content" "forward-or-judge"
assert_contains "cheap diff peek to judge the tier" "$content" "diff peek"
assert_contains "complex offers opus" "$content" "opus"
assert_contains "complex offers fable" "$content" "fable"
assert_contains "not complex → no prompt" "$content" "no prompt"

# ---------------------------------------------------------------------------
echo "test: spawn literals — subagent_type + model override"
assert_contains "subagent_type named" "$content" "subagent_type: personal-tools:my-review"
assert_contains "model override on spawn" "$content" 'model: "<pick>"'

# ---------------------------------------------------------------------------
echo "test: \$ARGUMENTS passes through as the target"
assert_contains 'ARGUMENTS pass-through' "$content" '$ARGUMENTS'

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
