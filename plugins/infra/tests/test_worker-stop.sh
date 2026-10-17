#!/usr/bin/env bash
#
# Tests for scripts/worker-stop.sh — stop a run's finished claude worker sessions.
#
# Driven against a STUBBED `claude` on PATH: `agents --json --all` prints $WORK/agents.json
# and `stop <id>` flips that session to `stopped` in it (STUB_NO_STOP=<id> makes one stop
# "acknowledge and not take", which README § Recovery observed for real). Covers:
#   * one issue: every live attempt/round of that issue is stopped, nothing else
#   * --all: every live session of the run, never another run's
#   * stopped/done rows, codex rows and interactive (id "-") rows are left alone
#   * nothing live -> exit 0, no `claude stop` call (safe to run twice)
#   * a stop that does not take -> exit 1 naming the id, after a bounded wait
#   * bad arguments fail loud
#
# Run: bash plugins/infra/tests/test_worker-stop.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOP="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/worker-stop.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"
PATH="$BIN:$PATH"
export PATH WORK
export CODEX_RUN_ROOT="$WORK/codex-runs"
export WORKER_STOP_WAIT=2

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in: $2)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    agents) cat "$WORK/agents.json" ;;
    stop)
        printf '%s\n' "$2" >>"$WORK/stopped-ids"
        [ "${STUB_NO_STOP:-}" = "$2" ] && { echo "stopped $2"; exit 0; }
        sed -i "/\"id\": \"$2\"/s/\"state\": \"[a-z]*\"/\"state\": \"stopped\"/" "$WORK/agents.json"
        echo "stopped $2" ;;
esac
STUB
chmod +x "$BIN/claude"

fixture() {
    : >"$WORK/stopped-ids"
    cat >"$WORK/agents.json" <<'JSON'
[
 { "id": "aa11", "kind": "background", "sessionId": "s1", "name": "orch-r1-issue-12-a0", "state": "idle" },
 { "id": "ab12", "kind": "background", "sessionId": "s2", "name": "orch-r1-issue-12-a1-r2", "state": "busy" },
 { "id": "ac13", "kind": "background", "sessionId": "s3", "name": "orch-r1-issue-12-a0-r1", "state": "stopped" },
 { "id": "bb22", "kind": "background", "sessionId": "s4", "name": "orch-r1-issue-13-a0", "state": "idle" },
 { "id": "cc33", "kind": "background", "sessionId": "s5", "name": "orch-r1-issue-14-a0", "state": "done" },
 { "id": "dd44", "kind": "background", "sessionId": "s6", "name": "orch-r2-issue-12-a0", "state": "idle" },
 { "id": "ee55", "kind": "background", "sessionId": "s7", "name": "orch-r1-issue-120-a0", "state": "idle" },
 { "id": "ff66", "kind": "background", "sessionId": "s8", "name": "orch-r1", "state": "idle" },
 { "pid": 99, "kind": "interactive", "sessionId": "s9", "name": "orch-r1-issue-15", "status": "idle" }
]
JSON
}
run() { bash "$STOP" "$@" 2>"$WORK/err"; }
err() { cat "$WORK/err"; }
stopped() { sort "$WORK/stopped-ids" | tr '\n' ' '; }

echo "test: one issue — every live session of that issue, and only that issue"
fixture
out=$(run r1 12); rc=$?
assert_equals "exit 0" "$rc" "0"
assert_equals "stops the idle and the busy attempt" "$(stopped)" "aa11 ab12 "
assert_contains "reports the name and id" "$out" "stopped orch-r1-issue-12-a0 aa11"
assert_contains "and the fix-round session" "$out" "stopped orch-r1-issue-12-a1-r2 ab12"
assert_not_contains "issue 120 is not issue 12" "$(stopped)" "ee55"
assert_not_contains "another run's issue 12 is untouched" "$(stopped)" "dd44"
assert_not_contains "the orchestrator itself is untouched" "$(stopped)" "ff66"

echo "test: '#12' is accepted"
fixture
run r1 '#13' >/dev/null
assert_equals "stops issue 13" "$(stopped)" "bb22 "

echo "test: --all — every live session of the run"
fixture
out=$(run r1 --all); rc=$?
assert_equals "exit 0" "$rc" "0"
assert_equals "all live r1 workers, none of r2, the orchestrator or the interactive row" \
    "$(stopped)" "aa11 ab12 bb22 ee55 "
assert_not_contains "a done row is not stopped" "$(stopped)" "cc33"
assert_not_contains "an already-stopped row is not stopped again" "$(stopped)" "ac13"

echo "test: nothing live -> exit 0 and no stop call (idempotent)"
run r1 --all >/dev/null
: >"$WORK/stopped-ids"
out=$(run r1 --all); rc=$?
assert_equals "exit 0 the second time" "$rc" "0"
assert_equals "no claude stop call" "$(stopped)" ""
assert_contains "says so" "$out" "nothing to stop"

echo "test: a codex row is left to exit on its own"
fixture
mkdir -p "$CODEX_RUN_ROOT/r1/issue-16"
echo 4242 >"$CODEX_RUN_ROOT/r1/issue-16/pid"
run r1 --all >/dev/null
assert_not_contains "no claude stop on the codex pid" "$(stopped)" "4242"

echo "test: a stop that does not take fails loud, naming the id"
fixture
out=$(STUB_NO_STOP=bb22 run r1 13); rc=$?
assert_equals "exit 1" "$rc" "1"
assert_contains "names the session that is still live" "$(err)" "bb22"

echo "test: bad arguments fail loud"
run >/dev/null; assert_equals "no args exits 1" "$?" "1"
run r1 >/dev/null; assert_equals "no target exits 1" "$?" "1"
run r1 twelve >/dev/null; assert_equals "non-numeric issue exits 1" "$?" "1"
run 'r1/../x' --all >/dev/null; assert_equals "a bad runid exits 1" "$?" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
