#!/usr/bin/env bash
#
# Tests for scripts/session-status.sh — worker session state for one run.
#
# Driven against a STUBBED `claude` on PATH emitting the real observed shape:
# background entries carry `id` + `state` and NO `pid`; interactive ones carry
# `pid` + `status` and no `id`.
#
# Covers:
#   * the run prefix filter — another run's sessions are invisible
#   * background and interactive shapes both classify
#   * `blocked` (permission wedge) survives as itself
#   * an expected issue with no session reports `gone`
#   * a done/completed state normalizes to `done`
#   * every failure path is LOUD: claude absent, non-zero exit, junk output, a
#     JSON object instead of a list, and a missing runid
#   * zero matches is exit 0 but never silent
#
# Run: bash plugins/workflow/tests/test_session-status.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/session-status.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"
PATH="$BIN:$PATH"
export PATH

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in: $2)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

# stub_claude <exit-code> <stdout> — also records its argv for inspection
stub_claude() {
    cat >"$BIN/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$WORK/argv"
cat <<'JSON'
$2
JSON
exit $1
EOF
    chmod +x "$BIN/claude"
}

run() { bash "$STATUS" "$@" 2>"$WORK/err"; }
err() { cat "$WORK/err"; }

FIXTURE='[
  { "id": "aa11", "cwd": "/w/1", "kind": "background", "sessionId": "s1",
    "name": "orch-20260906-101500-issue-12", "state": "busy" },
  { "id": "bb22", "cwd": "/w/2", "kind": "background", "sessionId": "s2",
    "name": "orch-20260906-101500-issue-13", "state": "idle" },
  { "id": "cc33", "cwd": "/w/3", "kind": "background", "sessionId": "s3",
    "name": "orch-20260906-101500-issue-14", "state": "blocked" },
  { "id": "dd44", "cwd": "/w/4", "kind": "background", "sessionId": "s4",
    "name": "orch-19990101-000000-issue-99", "state": "busy" },
  { "pid": 4242, "cwd": "/w/5", "kind": "interactive", "sessionId": "s5",
    "name": "orch-20260906-101500-issue-15", "status": "idle" },
  { "pid": 4243, "cwd": "/w/6", "kind": "interactive", "sessionId": "s6",
    "name": "some-unrelated-session", "status": "busy" }
]'

# ---------------------------------------------------------------------------
echo "test: only this run's sessions are listed"
stub_claude 0 "$FIXTURE"
out=$(run 20260906-101500)
assert_contains "issue-12 busy" "$out" "orch-20260906-101500-issue-12 aa11 background busy"
assert_contains "issue-13 idle" "$out" "orch-20260906-101500-issue-13 bb22 background idle"
assert_not_contains "another run's session is invisible" "$out" "19990101"
assert_not_contains "an unrelated session is invisible" "$out" "some-unrelated-session"

echo "test: --all is passed — without it a FINISHED session is indistinguishable from one that never spawned"
assert_contains "argv carries --all" "$(cat "$WORK/argv")" "--all"

echo "test: a permission wedge stays visible as blocked"
assert_contains "issue-14 blocked" "$out" "orch-20260906-101500-issue-14 cc33 background blocked"

echo "test: an interactive session (attached, hand-restarted) still reports"
assert_contains "interactive shape, no id" "$out" "orch-20260906-101500-issue-15 - interactive idle"

echo "test: output is one line per session, sorted"
assert_equals "four lines" "$(printf '%s\n' "$out" | wc -l)" "4"
assert_equals "sorted by name" "$(printf '%s\n' "$out" | sort)" "$out"

echo "test: an expected issue with no session is reported gone"
out=$(run 20260906-101500 12 77)
assert_contains "issue-77 gone" "$out" "orch-20260906-101500-issue-77 - - gone"
assert_contains "expected-and-alive still reports its real state" "$out" "issue-12 aa11 background busy"
assert_contains "flags accept #N" "$(run 20260906-101500 '#77')" "issue-77 - - gone"

echo "test: a finished session normalizes to done"
stub_claude 0 '[{ "id": "ee55", "kind": "background", "name": "orch-r1-issue-5", "state": "completed" }]'
assert_contains "completed -> done" "$(run r1)" "orch-r1-issue-5 ee55 background done"

echo "test: zero matches exits 0 but says so"
stub_claude 0 '[]'
out=$(run r1); rc=$?
assert_equals "no stdout" "$out" ""
assert_equals "exit 0" "$rc" "0"
assert_contains "loud about the empty" "$(err)" "no sessions matching orch-r1-"

# ---------------------------------------------------------------------------
# --self resolves the ORCHESTRATOR'S ADDRESS. spawn.sh hard-depends on it: a worker
# that cannot name its orchestrator reports into the void.
echo "test: --self prints this session's own name"
stub_claude 0 '[{ "id": "aa11", "kind": "background", "sessionId": "sess-abc", "name": "my-orchestrator" },
                { "pid": 1, "kind": "interactive", "sessionId": "other", "name": "someone-else" }]'
out=$(CLAUDE_CODE_SESSION_ID=sess-abc bash "$STATUS" --self 2>"$WORK/err")
assert_equals "prints only the matching session's name" "$out" "my-orchestrator"

echo "test: --self fails loud rather than guessing"
CLAUDE_CODE_SESSION_ID= bash "$STATUS" --self >/dev/null 2>"$WORK/err"
assert_equals "unset session id exits 1" "$?" "1"
assert_contains "names the missing variable" "$(err)" "CLAUDE_CODE_SESSION_ID"
CLAUDE_CODE_SESSION_ID=not-listed bash "$STATUS" --self >/dev/null 2>"$WORK/err"
assert_equals "an unlisted session exits 1" "$?" "1"
assert_contains "tells you to pass the name" "$(err)" "pass the orchestrator name explicitly"
stub_claude 0 '[{ "id": "aa11", "kind": "background", "sessionId": "sess-abc" }]'
CLAUDE_CODE_SESSION_ID=sess-abc bash "$STATUS" --self >/dev/null 2>"$WORK/err"
assert_equals "a session with no name exits 1" "$?" "1"

# ---------------------------------------------------------------------------
echo "test: every failure path is loud, never a silent empty"
stub_claude 1 'boom'
run r1 >/dev/null; assert_equals "non-zero claude exits 1" "$?" "1"
assert_contains "names the failure" "$(err)" "exited 1"

stub_claude 0 'not json at all'
run r1 >/dev/null; assert_equals "junk exits 1" "$?" "1"
assert_contains "says it was not JSON" "$(err)" "did not return JSON"

stub_claude 0 '{"agents": []}'
run r1 >/dev/null; assert_equals "an object instead of a list exits 1" "$?" "1"
assert_contains "says it wanted a list" "$(err)" "expected a list"

rm -f "$BIN/claude"
PATH="$WORK/empty:/usr/bin:/bin"; export PATH
run r1 >/dev/null; assert_equals "missing claude exits 1" "$?" "1"
assert_contains "names the missing CLI" "$(err)" "claude CLI not found"

bash "$STATUS" >/dev/null 2>"$WORK/err"; assert_equals "missing runid exits 1" "$?" "1"
assert_contains "prints usage" "$(err)" "usage:"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
