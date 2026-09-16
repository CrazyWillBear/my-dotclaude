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
#   * a CODEX worker — which is in no agent list at all — reports from its run dir's
#     pid/exit pair, in the same vocabulary
#   * every failure path is LOUD: claude absent, non-zero exit, junk output, a
#     JSON object instead of a list, and a missing runid
#   * zero matches is exit 0 but never silent
#
# Run: bash plugins/infra/tests/test_session-status.sh   (non-zero if any fail)

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

echo "test: both spellings of the same state normalize to one vocabulary"
stub_claude 0 '[{ "id": "ff66", "kind": "background", "name": "orch-r1-issue-6", "state": "working" },
                { "pid": 9, "kind": "interactive", "name": "orch-r1-issue-7", "status": "busy" }]'
out=$(run r1)
assert_contains "background 'working' -> busy" "$out" "orch-r1-issue-6 ff66 background busy"
assert_contains "interactive 'busy' stays busy" "$out" "orch-r1-issue-7 - interactive busy"

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
# --peers resolves a ROLE NAME to an id. A peer is named by its role with NO run
# prefix (docs/swarm-design.md § Rotation: the name is the stable address), so the
# runid filter above cannot see one at all. swarm.sh up needs this to know which
# roster peers are missing; down and attach need it because `claude stop` and
# `claude attach` take an id and reject a name.
#
# It is scoped to ONE PROJECT'S cwd, and that is not cosmetic: role names are
# generic, so two projects each running a `swe-manager` share a name. Without the
# cwd scope `swarm.sh down` in one project would stop the other project's peer.
echo "test: --peers resolves roster roles to ids, scoped to the project"
stub_claude 0 '[
  { "id": "p111", "cwd": "/proj", "kind": "background", "name": "swe-manager", "state": "idle" },
  { "id": "p222", "cwd": "/other", "kind": "background", "name": "performance-engineer", "state": "busy" },
  { "id": "p333", "cwd": "/proj", "kind": "background", "name": "orch-r1-issue-3", "state": "busy" }
]'
out=$(run --peers /proj swe-manager performance-engineer)
assert_contains "a peer in this project resolves to its id" "$out" "swe-manager p111 background idle"
assert_contains "the same role in ANOTHER project is gone, never stopped by mistake" "$out" "performance-engineer - - gone"
assert_not_contains "a worker is not a peer" "$out" "orch-r1-issue-3"
assert_equals "one line per requested role" "$(printf '%s\n' "$out" | wc -l)" "2"
assert_equals "in the order asked" "$(printf '%s\n' "$out" | head -1 | cut -d' ' -f1)" "swe-manager"
assert_contains "--all is passed here too" "$(cat "$WORK/argv")" "--all"

echo "test: --peers normalizes the cwd it is given"
assert_contains "a trailing slash still matches" "$(run --peers /proj/ swe-manager)" "swe-manager p111"
assert_contains "so does a dotted path" "$(run --peers /proj/. swe-manager)" "swe-manager p111"

echo "test: a peer entry with no cwd cannot be claimed by this project"
stub_claude 0 '[{ "id": "p444", "kind": "background", "name": "swe-manager", "state": "idle" }]'
assert_contains "unattributable -> gone" "$(run --peers /proj swe-manager)" "swe-manager - - gone"

# A rotation stops a peer and respawns it under the SAME name, so both the corpse and
# the successor are in the list. Answer with the live one or `down` stops nothing and
# `up` sees a peer that is really gone.
echo "test: on a duplicate name the LIVE session wins"
stub_claude 0 '[
  { "id": "old1", "cwd": "/proj", "kind": "background", "name": "swe-manager", "state": "stopped" },
  { "id": "new1", "cwd": "/proj", "kind": "background", "name": "swe-manager", "state": "idle" },
  { "id": "old2", "cwd": "/proj", "kind": "background", "name": "performance-engineer", "state": "idle" },
  { "id": "new2", "cwd": "/proj", "kind": "background", "name": "performance-engineer", "state": "stopped" }
]'
out=$(run --peers /proj swe-manager performance-engineer)
assert_equals "still one line per role" "$(printf '%s\n' "$out" | wc -l)" "2"
assert_contains "the live successor, not the corpse" "$out" "swe-manager new1 background idle"
assert_contains "whichever order they are listed in" "$out" "performance-engineer old2 background idle"

echo "test: --peers needs a project dir and at least one role"
run --peers >/dev/null; assert_equals "no project dir exits 1" "$?" "1"
assert_contains "prints usage" "$(err)" "usage:"
run --peers /proj >/dev/null; assert_equals "no roles exits 1" "$?" "1"
assert_contains "prints usage" "$(err)" "usage:"

# ---------------------------------------------------------------------------
# CODEX WORKERS. A codex worker is not a claude session and is not in `claude agents`
# at all — `codex exec` leaves a run dir behind instead, and the pid + exit files in it
# ARE its state (docs/swarm-design.md § Codex backend). spawn.sh writes that layout.
#
# The states normalize into the SAME vocabulary as a claude session, and that is
# load-bearing rather than tidy: /orchestrate's liveness loop waits on `$4 == "busy"`.
# A codex worker reporting a private spelling like `working` would read as finished the
# moment it started, and the run would merge branches nothing had built yet.
echo "test: a codex worker reports from its run dir, in the same vocabulary"
CODEX_ROOT="$WORK/codexruns"
mkcodex() {  # mkcodex <issue> <pid|-> <exit|->
    local d="$CODEX_ROOT/rc1/issue-$1"
    mkdir -p "$d"
    [ "$2" = - ] || printf '%s\n' "$2" >"$d/pid"
    [ "$3" = - ] || printf '%s\n' "$3" >"$d/exit"
}
rm -rf "$CODEX_ROOT"
sleep 300 & LIVE_PID=$!
# Real, reaped pids rather than made-up numbers: a guessed "surely nothing owns that
# number" is exactly the kind of assumption that fails on one machine and nowhere else.
dead() { sleep 0 & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }
D1=$(dead); D2=$(dead); D3=$(dead)
mkcodex 21 "$LIVE_PID" -          # still running
mkcodex 22 "$D1" 0                # exited clean
mkcodex 23 "$D2" 3                # exited non-zero
mkcodex 24 "$D3" -                # died without recording a code
stub_claude 0 '[]'
out=$(CODEX_RUN_ROOT="$CODEX_ROOT" bash "$STATUS" rc1 2>"$WORK/err")
assert_contains "a live pid is busy" "$out" "orch-rc1-issue-21 $LIVE_PID codex busy"
assert_contains "exit 0 is done" "$out" "orch-rc1-issue-22 $D1 codex done"
assert_contains "a non-zero exit is failed" "$out" "orch-rc1-issue-23 $D2 codex failed"
assert_contains "a dead pid with no exit code is failed, never silently fine" \
    "$out" "orch-rc1-issue-24 $D3 codex failed"
assert_equals "four lines" "$(printf '%s\n' "$out" | wc -l)" "4"
assert_equals "sorted with everything else" "$(printf '%s\n' "$out" | sort)" "$out"
kill "$LIVE_PID" 2>/dev/null

echo "test: an expected codex worker is not reported gone just because claude never heard of it"
out=$(CODEX_RUN_ROOT="$CODEX_ROOT" bash "$STATUS" rc1 22 77 2>"$WORK/err")
assert_contains "the codex worker reports its real state" "$out" "orch-rc1-issue-22 $D1 codex done"
assert_not_contains "and is not also gone" "$out" "issue-22 - - gone"
assert_contains "a genuinely absent one still is" "$out" "orch-rc1-issue-77 - - gone"

echo "test: codex workers and claude sessions share one report"
stub_claude 0 '[{ "id": "cc11", "kind": "background", "name": "orch-rc1-issue-30", "state": "busy" }]'
out=$(CODEX_RUN_ROOT="$CODEX_ROOT" bash "$STATUS" rc1 2>"$WORK/err")
assert_contains "the claude one" "$out" "orch-rc1-issue-30 cc11 background busy"
assert_contains "the codex one" "$out" "orch-rc1-issue-22 $D1 codex done"

echo "test: another run's codex workers are invisible"
mkdir -p "$CODEX_ROOT/rOTHER/issue-88"
printf '0\n' >"$CODEX_ROOT/rOTHER/issue-88/exit"
assert_not_contains "run prefix filters the run dir too" \
    "$(CODEX_RUN_ROOT="$CODEX_ROOT" bash "$STATUS" rc1 2>/dev/null)" "issue-88"

# The two scripts agree on the override above only because both read CODEX_RUN_ROOT.
# The DEFAULT is the half that silently rots: change it on one side and a live codex
# worker reports as nothing at all — which /orchestrate reads as "finished". So drive a
# real spawn with no override and make this script find what it wrote.
echo "test: spawn.sh's DEFAULT codex run dir is the one this script reads"
SPAWN="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/spawn.sh"
FAKE_HOME="$WORK/home"; mkdir -p "$FAKE_HOME"
cat >"$BIN/codex" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
STUB
chmod +x "$BIN/codex"
CFG="$WORK/cfg"; mkdir -p "$CFG"
cat >"$CFG/model-tiers.json" <<'JSON'
{
  "trivial":  { "planner": { "backend": "claude", "model": "haiku", "effort": "medium" },
                "implementer": { "backend": "codex", "model": "gpt-5.6-luna", "effort": "max" },
                "reviewer": { "backend": "codex", "model": "gpt-5.6-terra", "effort": "high" } },
  "standard": { "planner": { "backend": "claude", "model": "sonnet", "effort": "high" },
                "implementer": { "backend": "codex", "model": "gpt-5.6-terra", "effort": "max" },
                "reviewer": { "backend": "codex", "model": "gpt-5.6-terra", "effort": "high" } },
  "complex":  { "planner": { "backend": "codex", "model": "gpt-5.6-sol", "effort": "xhigh" },
                "implementer": { "backend": "codex", "model": "gpt-5.6-sol", "effort": "high" },
                "reviewer": { "backend": "codex", "model": "gpt-5.6-sol", "effort": "xhigh" } }
}
JSON
REPO="$WORK/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q 2>/dev/null
HOME="$FAKE_HOME" RESOLVE_TIER_ROOT="$CFG" \
    bash "$SPAWN" r7 31 standard "$REPO" base --orchestrator orch-main >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$FAKE_HOME/.claude/codex-runs/r7/issue-31/exit" ] && break; sleep 0.2
done
stub_claude 0 '[]'
assert_contains "no override on either side, and the worker is still visible" \
    "$(HOME="$FAKE_HOME" bash "$STATUS" r7 2>/dev/null)" "orch-r7-issue-31"

echo "test: no codex run dir at all is simply no codex workers"
stub_claude 0 '[]'
CODEX_RUN_ROOT="$WORK/nosuchroot" bash "$STATUS" rc1 >/dev/null 2>"$WORK/err"
assert_equals "exit 0" "$?" "0"
assert_contains "and still loud about the empty" "$(err)" "no sessions matching orch-rc1-"

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
