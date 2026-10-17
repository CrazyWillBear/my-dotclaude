#!/usr/bin/env bash
#
# Tests for scripts/worker-cmd.sh (the one builder of a boxed claude worker's argv) and
# scripts/claude-report.sh (the stream -> last-message.txt extraction).
#
# Run: bash plugins/infra/tests/test_worker-cmd.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="$SCRIPT_DIR/../scripts/worker-cmd.sh"
REPORT="$SCRIPT_DIR/../scripts/claude-report.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
unset CLAUDE_BOX_ROOT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }
assert_arg() { if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else no "$1 (no arg line '$3')"; fi; }

# argv <args...> — one line per argument (NUL-delimited on the wire).
argv() { bash "$CMD" "$@" 2>"$WORK/err" | tr '\0' '\n'; }

echo "test: the worker argv"
out=$(argv sonnet high /wt '{"type":"object"}' -- "line one
line two")
assert_equals "starts with the box env" "$(printf '%s\n' "$out" | sed -n 1,4p | tr '\n' ' ')" \
    "env CLAUDE_CONFIG_DIR=$HOME/.claude/kit/boxes/implementer claude -p "
assert_arg "model" "$out" "sonnet"
assert_arg "effort" "$out" "high"
assert_arg "add-dir" "$out" "/wt"
assert_arg "schema passed inline" "$out" '{"type":"object"}'
assert_arg "stream-json" "$out" "stream-json"
assert_arg "no MCP servers" "$out" '{"mcpServers":{}}'
assert_arg "strict MCP" "$out" "--strict-mcp-config"
assert_not_contains "no resume by default" "$out" "--resume"
n=$(bash "$CMD" sonnet high /wt '{}' -- "a
b" | tr -cd '\0' | wc -c)
last=$(bash "$CMD" sonnet high /wt '{}' -- "a
b" | tr '\0' '\n' | tail -2 | tr '\n' '|')
assert_equals "the multi-line prompt is ONE trailing argument" "$last" "a|b|"
assert_equals "argument count" "$n" "34"

echo "test: --resume and --browser"
out=$(argv opus max /wt '{}' --browser --resume sess-1 -- p)
assert_equals "resume follows -p" "$(printf '%s\n' "$out" | sed -n 5,6p | tr '\n' ' ')" "--resume sess-1 "
assert_contains "browser adds playwright" "$out" '"playwright"'
out=$(CLAUDE_BOX_ROOT="$WORK/b" argv opus max /wt '{}' -- p)
assert_arg "CLAUDE_BOX_ROOT moves the box" "$out" "CLAUDE_CONFIG_DIR=$WORK/b/implementer"

echo "test: --deny prints just the shared denylist"
deny=$(argv --deny)
assert_arg "gh api denied" "$deny" "Bash(gh api:*)"
assert_equals "nine rules" "$(printf '%s\n' "$deny" | wc -l | tr -d ' ')" "9"

echo "test: bad input fails loud"
bash "$CMD" sonnet high /wt '{}' >/dev/null 2>&1; assert_equals "no prompt exits 1" "$?" "1"
bash "$CMD" sonnet high /wt '{}' -- "" >/dev/null 2>&1; assert_equals "empty prompt exits 1" "$?" "1"
bash "$CMD" sonnet high /wt "" -- p >/dev/null 2>&1; assert_equals "no schema exits 1" "$?" "1"
bash "$CMD" sonnet high /wt '{}' --bogus -- p >/dev/null 2>&1; assert_equals "unknown flag exits 1" "$?" "1"

echo "test: claude-report.sh writes the LAST result's structured_output"
R="$WORK/run"; mkdir -p "$R"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"s"}' 'not json' \
    '{"type":"result","structured_output":{"status":"escalate"}}' \
    '{"type":"result","structured_output":{"status":"built"}}' >"$R/events.jsonl"
bash "$REPORT" "$R"
assert_equals "the last turn's report" "$(cat "$R/last-message.txt")" '{"status":"built"}'
printf '%s\n' '{"type":"result","structured_output":{"status":"failed"}}' >"$R/events.jsonl"
bash "$REPORT" "$R"
assert_equals "an existing report is never overwritten" "$(cat "$R/last-message.txt")" '{"status":"built"}'
rm -f "$R/last-message.txt"
printf '%s\n' '{"type":"result","is_error":true}' >"$R/events.jsonl"
bash "$REPORT" "$R"
if [ -e "$R/last-message.txt" ]; then no "a result with no report invented one"; else ok "no structured_output, no file"; fi
bash "$REPORT" "$WORK/nowhere"; assert_equals "a missing run dir exits 0" "$?" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
