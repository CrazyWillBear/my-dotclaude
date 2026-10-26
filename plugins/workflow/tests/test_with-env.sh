#!/usr/bin/env bash
#
# Tests for scripts/with-env.sh — runs a command (the merger's done-check) with the env pairs
# a human provisioned for one or more issues (`handle-report.sh --resource`), so the merge
# gate sees the same test databases the workers did, without the pairs ever being printed.
#
# Run: bash plugins/workflow/tests/test_with-env.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WITH_ENV="$(cd "$SCRIPT_DIR/../scripts" && pwd)/with-env.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in '$2')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

export HOME="$WORK/home" CODEX_RUN_ROOT="$WORK/runs"
mkdir -p "$CODEX_RUN_ROOT/r1/issue-5" "$CODEX_RUN_ROOT/r1/issue-6" "$CODEX_RUN_ROOT/r1/issue-7"
printf 'RUNID=r1\n' >"$CODEX_RUN_ROOT/r1/run.env"
printf 'DATABASE_URL=postgres://five\0SHARED=from5\0' >"$CODEX_RUN_ROOT/r1/issue-5/env"
printf 'SHARED=from6\0' >"$CODEX_RUN_ROOT/r1/issue-6/env"
SHOW='printf "%s|%s|%s" "${DATABASE_URL:-}" "${SHARED:-}" "${OTHER:-}"'
run() { OUT="$(bash "$WITH_ENV" "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }

echo "test: the command sees the issue's pairs"
run r1 5 -- bash -c "$SHOW"
assert_equals "exit 0" "$RC" "0"
assert_equals "both pairs, in its environment" "$OUT" "postgres://five|from5|"

echo "test: several issues merge; a later one wins; an issue with no pairs is skipped"
run r1 5,6,7 -- bash -c "$SHOW"
assert_equals "the union, later wins" "$OUT" "postgres://five|from6|"

echo "test: the values never reach any argv"
run r1 5 -- bash -c 'tr "\0" " " </proc/$$/cmdline; echo; ps -o args= -p $PPID'
assert_not_contains "not in the command line" "$OUT" "postgres://five"

echo "test: no pairs at all just runs the command"
run r1 7 -- bash -c "$SHOW"
assert_equals "unchanged env" "$OUT" "||"

echo "test: the command's exit code and arguments pass through"
run r1 5 -- bash -c 'exit 3'
assert_equals "exit 3" "$RC" "3"
run r1 5 -- printf '%s,' a 'b c'
assert_equals "argv intact" "$OUT" "a,b c,"

echo "test: bad usage fails loud"
run r1 5 bash -c true;     assert_equals "no --" "$RC" "1"
run r1 5 --;               assert_equals "no command" "$RC" "1"
run r1 x -- true;          assert_equals "non-numeric issue" "$RC" "1"
run nope 5 -- true;        assert_equals "unlaunched run" "$RC" "1"
assert_contains "and says so" "$ERR" "no launched run"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
