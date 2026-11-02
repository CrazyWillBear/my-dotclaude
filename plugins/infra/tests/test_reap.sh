#!/usr/bin/env bash
#
# Tests for scripts/reap.sh — kills what a worker left running (a backgrounded build that
# outlived the worker). spawn.sh tags every worker's environment with ORCH_WORKER=<run>/<issue>;
# children inherit it even through setsid, so the tag finds them where the process group cannot.
#
# Run: bash plugins/infra/tests/test_reap.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAP="$(cd "$SCRIPT_DIR/../scripts" && pwd)/reap.sh"
WORK="$(mktemp -d)"
PIDS=()
cleanup() { kill -9 "${PIDS[@]}" 2>/dev/null; rm -rf "${WORK:?}"; }
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in '$2')" ;; esac; }

if [ ! -d /proc/self ]; then
    echo "SKIP: no /proc on this platform — reap.sh is a documented no-op here"
    bash "$REAP" r1/5; assert_equals "no-op exits 0" "$?" "0"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]; exit
fi

# start <tag> — a sleeper carrying the tag, detached from this shell's process group
start() { ORCH_WORKER="$1" setsid sleep 300 >/dev/null 2>&1 & PIDS+=("$!"); LAST="$!"; }
alive() { kill -0 "$1" 2>/dev/null; }
settle() { sleep 0.3; }

start r1/5;  A="$LAST"
start r1/6;  B="$LAST"
start r1/50; C="$LAST"
start r2/5;  D="$LAST"
sleep 0.3

echo "test: an issue tag kills that issue's processes only"
OUT="$(bash "$REAP" r1/5 2>&1)"; RC=$?
settle
assert_equals "exit 0" "$RC" "0"
alive "$A" && no "r1/5 survived" || ok "r1/5 reaped"
alive "$B" && ok "r1/6 untouched" || no "r1/6 was killed"
alive "$C" && ok "r1/50 untouched — exact match, not a prefix" || no "r1/50 was killed"
alive "$D" && ok "r2/5 untouched" || no "r2/5 was killed"
assert_contains "says how many" "$OUT" "reaped 1"

echo "test: a run tag (trailing slash) kills every issue of that run"
bash "$REAP" r1/ >/dev/null 2>&1
settle
alive "$B" && no "r1/6 survived" || ok "r1/6 reaped"
alive "$C" && no "r1/50 survived" || ok "r1/50 reaped"
alive "$D" && ok "another run untouched" || no "another run was killed"

echo "test: a process that ignores TERM is killed"
ORCH_WORKER=r3/1 setsid bash -c 'trap "" TERM; while :; do sleep 1; done' >/dev/null 2>&1 &
PIDS+=("$!"); T="$!"
sleep 0.3
bash "$REAP" r3/1 >/dev/null 2>&1
alive "$T" && no "TERM-proof process survived" || ok "TERM-proof process reaped"

echo "test: it never kills itself or its caller"
ORCH_WORKER=r4/1 bash -c 'bash "$1" r4/1; echo "survived rc=$?"' _ "$REAP" >"$WORK/self" 2>&1
assert_contains "the caller lived to see the exit code" "$(cat "$WORK/self")" "survived rc=0"

echo "test: a per-user shared daemon the worker started is left alone"
cp "$(command -v sleep)" "$WORK/sccache"
ORCH_WORKER=r5/1 setsid "$WORK/sccache" 300 >/dev/null 2>&1 &
PIDS+=("$!"); D="$!"
sleep 0.3
bash "$REAP" r5/1 >/dev/null 2>&1
alive "$D" && ok "sccache survived the reap" || no "a shared daemon was killed"

echo "test: nothing matching is not an error"
OUT="$(bash "$REAP" nope/1 2>&1)"; RC=$?
assert_equals "exit 0" "$RC" "0"
assert_contains "reports zero" "$OUT" "reaped 0"

echo "test: bad usage fails loud"
bash "$REAP" >/dev/null 2>&1;         assert_equals "no tag" "$?" "1"
bash "$REAP" notag >/dev/null 2>&1;   assert_equals "no slash" "$?" "1"
bash "$REAP" 'a b/1' >/dev/null 2>&1; assert_equals "odd characters" "$?" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
