#!/usr/bin/env bash
#
# Tests for scripts/escalate.sh — "should this codex worker be replaced, and why" (#104).
#
# Driven for REAL against FIXTURE run dirs in spawn.sh's layout (pid / exit /
# last-message.txt / events.jsonl), a FIXTURE rollout under a fake CODEX_SESSIONS_ROOT
# carrying real-format `token_count` events, a real git repo for the commit list, and a
# STUB `gh` that answers `issue view --json comments` with a canned listing and records
# every comment it is asked to post. Those three formats — the codex event log, the codex
# status JSON, and gh's comment listing — are the declared central mock (PRD #104
# § Testing); the pilot on real models closes it.
#
# Each signal is one case, plus the no-signal case, because the script's whole value is
# saying NOTHING when nothing is wrong: a false escalation burns a model tier for free.
#
# Run: bash plugins/infra/tests/test_escalate.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/escalate.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${SLEEPER:-}" ] && kill "$SLEEPER" 2>/dev/null' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in '$2')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }
assert_empty() { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected empty, got '$2')"; fi; }

BIN="$WORK/bin"; mkdir -p "$BIN"
cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"${STUB_GH_ARGV:-/dev/null}"
if [ "${1:-}" = issue ] && [ "${2:-}" = view ]; then
    [ -n "${STUB_GH_COMMENTS:-}" ] || STUB_GH_COMMENTS='{"comments":[]}'
    printf '%s' "$STUB_GH_COMMENTS"; exit 0
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = comment ]; then
    while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "${STUB_GH_BODY:-/dev/null}"; shift; done
fi
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# A real repo with a base branch and two commits on top: the handoff lists them.
REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q; git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
printf 'x\n' >"$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm init
git -C "$REPO" branch base
printf 'y\n' >"$REPO/f"; git -C "$REPO" commit -qam "step 1: add f"
printf 'z\n' >"$REPO/f"; git -C "$REPO" commit -qam "step 2: wire f"

CODEX_ROOT="$WORK/codexruns"; export CODEX_RUN_ROOT="$CODEX_ROOT"
SESSIONS="$WORK/sessions"; export CODEX_SESSIONS_ROOT="$SESSIONS"
RUNDIR="$CODEX_ROOT/r1/issue-12"
export STUB_GH_ARGV="$WORK/gh-argv" STUB_GH_BODY="$WORK/body"

# mkrun [status-json] [exit-code] — a terminal run dir. No exit arg = still running.
mkrun() {
    rm -rf "$RUNDIR"; mkdir -p "$RUNDIR"
    printf '{"type":"thread.started","thread_id":"thr-12-abc"}\n{"type":"turn.started"}\n' >"$RUNDIR/events.jsonl"
    printf '{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"/bin/sh -lc '"'"'pytest -q'"'"'","aggregated_output":"ok"}}\n' >>"$RUNDIR/events.jsonl"
    printf '{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"done with step 2"}}\n' >>"$RUNDIR/events.jsonl"
    printf '%s' "${1:-}" >"$RUNDIR/last-message.txt"
    [ -z "${2:-}" ] || printf '%s\n' "$2" >"$RUNDIR/exit"
    printf '%s\n' "${3:-$$}" >"$RUNDIR/pid"
}
# mkrollout <last-input-tokens> — a rollout joined to the run's thread id.
mkrollout() {
    mkdir -p "$SESSIONS/2026/09/22"
    {
        printf '{"timestamp":"t","type":"session_meta","payload":{"id":"thr-12-abc","cwd":"%s"}}\n' "$REPO"
        printf '{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9000000},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"cache_write_input_tokens":0},"model_context_window":258400}}}\n'
        printf '{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9000000},"last_token_usage":{"input_tokens":%s,"cached_input_tokens":100,"cache_write_input_tokens":0},"model_context_window":258400}}}\n' "$1"
    } >"$SESSIONS/2026/09/22/rollout-2026-09-22T00-00-00-thr-12-abc.jsonl"
}
run() { rm -f "$WORK/gh-argv" "$WORK/body"; OUT="$(bash "$SCRIPT" "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }
posted() { grep -qx comment "$WORK/gh-argv" 2>/dev/null && echo yes || echo no; }

BUILT='{"issue":12,"status":"built","round":0,"head":"abc1234","review":"","note":""}'

# ---------------------------------------------------------------------------
echo "test: a healthy running worker escalates NOTHING"
mkrun "" ""
run r1 12 standard "$REPO" --base base
assert_equals "exit 0" "$RC" "0"
assert_empty "nothing on stdout" "$OUT"
assert_equals "nothing posted" "$(posted)" "no"

echo "test: a clean built worker escalates NOTHING either"
mkrun "$BUILT" 0
STUB_GH_COMMENTS='{"comments":[{"body":"**Plan**\n\n1. x"},{"body":"**Review round 1** — 0 high, 0 medium, 2 low"}]}' \
    run r1 12 standard "$REPO" --base base
assert_empty "a first clean review is not a signal" "$OUT"

echo "test: failed — the worker's own report"
mkrun '{"issue":12,"status":"failed","round":0,"head":"","review":"","note":"done-check red: 3 tests"}' 0
run r1 12 standard "$REPO" --base base --attempt 0
assert_equals "exit 0 — a reason IS a result" "$RC" "0"
assert_contains "names the reason" "$OUT" "failed:"
assert_contains "quotes the worker's note" "$OUT" "done-check red"
assert_equals "the handoff was posted" "$(posted)" "yes"
BODY="$(cat "$WORK/body")"
assert_contains "handoff heading names the attempt" "$BODY" "**Handoff** — attempt 0 replaced: failed"
assert_contains "lists the commits since base" "$BODY" "step 2: wire f"
assert_contains "both of them" "$BODY" "step 1: add f"
assert_contains "and the last activity from the event log" "$BODY" "pytest -q"
assert_contains "including the last message" "$BODY" "done with step 2"

echo "test: failed — a non-zero exit with no report (a crash)"
mkrun "" 3
run r1 12 standard "$REPO" --base base
assert_contains "exit code is the reason" "$OUT" "failed: the worker exited 3"

echo "test: failed — a dead pid with no exit file (killed)"
mkrun "" "" 4194304   # a pid that cannot be alive (past pid_max on stock Linux)
run r1 12 standard "$REPO" --base base
assert_contains "a killed worker is failed, never quietly done" "$OUT" "failed: the worker died"

echo "test: deviation-cap — the third deviation escalates instead of a third consult"
mkrun '{"issue":12,"status":"escalate","round":0,"head":"","review":"","note":"step 4: g missing"}' 0
TWO='{"comments":[{"body":"**Plan**\n\n1."},{"body":"**Deviation**\n\nstep 2"},{"body":"**Consult 1**\n\ngo"},{"body":"**Deviation**\n\nstep 3"},{"body":"**Consult 2**\n\ngo"}]}'
STUB_GH_COMMENTS="$TWO" run r1 12 standard "$REPO" --base base
assert_empty "two deviations (at the cap) is a consult, not an escalation" "$OUT"
THREE='{"comments":[{"body":"**Plan**\n\n1."},{"body":"**Deviation**\n\nstep 2"},{"body":"**Consult 1**\n\ngo"},{"body":"**Deviation**\n\nstep 3"},{"body":"**Consult 2**\n\ngo"},{"body":"**Deviation**\n\nstep 4"}]}'
STUB_GH_COMMENTS="$THREE" run r1 12 standard "$REPO" --base base
assert_contains "the third is the signal" "$OUT" "deviation-cap: 3 deviations"
STUB_GH_COMMENTS="$THREE" ESCALATE_CONSULT_CAP=3 run r1 12 standard "$REPO" --base base
assert_empty "the cap is configurable" "$OUT"

echo "test: review-cap — a second round with high or medium findings"
mkrun '{"issue":12,"status":"fixed","round":2,"head":"abc1234","review":"","note":""}' 0
R2='{"comments":[{"body":"**Review round 1** — 2 high, 0 medium, 0 low\n\n- x"},{"body":"**Review round 2** — 0 high, 1 medium, 3 low\n\n- y"}]}'
STUB_GH_COMMENTS="$R2" run r1 12 standard "$REPO" --base base --attempt 0
assert_contains "round 2 with a medium escalates" "$OUT" "review-cap: review round 2 still has 0 high, 1 medium"
R2L='{"comments":[{"body":"**Review round 1** — 2 high, 0 medium, 0 low"},{"body":"**Review round 2** — 0 high, 0 medium, 3 low"}]}'
STUB_GH_COMMENTS="$R2L" run r1 12 standard "$REPO" --base base
assert_empty "lows alone never escalate" "$OUT"
R1='{"comments":[{"body":"**Review round 1** — 2 high, 0 medium, 0 low"}]}'
STUB_GH_COMMENTS="$R1" run r1 12 standard "$REPO" --base base
assert_empty "a first round with findings is a fix round, not an escalation" "$OUT"

echo "test: occupancy — read from the rollout's LAST per-request usage, not the turn total"
mkrun "" ""
mkrollout 300000
run r1 12 standard "$REPO" --base base
assert_contains "at 300K it escalates" "$OUT" "occupancy: context at 300000 tokens"
mkrollout 200000
run r1 12 standard "$REPO" --base base
assert_empty "at 200K it does not — the 9M turn total is NOT the occupancy" "$OUT"
ESCALATE_OCCUPANCY_TOKENS=150000 run r1 12 standard "$REPO" --base base
assert_contains "the threshold is configurable" "$OUT" "occupancy"
rm -rf "$SESSIONS"
run r1 12 standard "$REPO" --base base
assert_empty "no rollout found: no occupancy signal, no crash" "$OUT"

echo "test: stall — alive, unfinished, event log untouched for the window"
sleep 120 & SLEEPER=$!
mkrun "" "" "$SLEEPER"
touch -d '30 minutes ago' "$RUNDIR/events.jsonl"
run r1 12 standard "$REPO" --base base --attempt 1
assert_contains "escalates as a stall" "$OUT" "stall: no event-log activity for 30 minutes"
assert_contains "the handoff names attempt 1" "$(cat "$WORK/body")" "attempt 1 replaced: stall"
touch "$RUNDIR/events.jsonl"
run r1 12 standard "$REPO" --base base
assert_empty "a fresh event log is not a stall" "$OUT"
touch -d '30 minutes ago' "$RUNDIR/events.jsonl"
ESCALATE_STALL_MINUTES=45 run r1 12 standard "$REPO" --base base
assert_empty "the window is configurable" "$OUT"
printf '0\n' >"$RUNDIR/exit"
run r1 12 standard "$REPO" --base base
assert_empty "a FINISHED worker with an old log is not a stall" "$OUT"
kill "$SLEEPER" 2>/dev/null; SLEEPER=""

echo "test: the handoff is posted ONCE per attempt — this runs on every wake"
mkrun '{"issue":12,"status":"failed","round":0,"head":"","review":"","note":"x"}' 0
STUB_GH_COMMENTS='{"comments":[{"body":"**Handoff** — attempt 0 replaced: failed: x\n\nCommits"}]}' \
    run r1 12 standard "$REPO" --base base --attempt 0
assert_contains "the reason is still reported" "$OUT" "failed"
assert_equals "but not re-posted" "$(posted)" "no"
STUB_GH_COMMENTS='{"comments":[{"body":"**Handoff** — attempt 0 replaced: failed: x"}]}' \
    run r1 12 standard "$REPO" --base base --attempt 1
assert_equals "a different attempt's handoff does not block this one" "$(posted)" "yes"

echo "test: --dry-run reports and posts nothing"
mkrun '{"issue":12,"status":"failed","round":0,"head":"","review":"","note":"x"}' 0
run r1 12 standard "$REPO" --base base --dry-run
assert_contains "reason printed" "$OUT" "failed"
assert_equals "nothing posted" "$(posted)" "no"

echo "test: a claude worker (no run dir) is never escalated"
rm -rf "$RUNDIR"
run r1 12 standard "$REPO" --base base
assert_equals "exit 0" "$RC" "0"
assert_empty "nothing on stdout" "$OUT"
assert_contains "and says why on stderr" "$ERR" "never escalated"

echo "test: usage errors fail loud"
run r1 12 standard "$REPO"; assert_equals "missing --base exits 1" "$RC" "1"
run r1 x standard "$REPO" --base base; assert_equals "bad issue exits 1" "$RC" "1"
run r1 12 standard "$WORK/nope" --base base; assert_equals "missing worktree exits 1" "$RC" "1"
run r1 12 standard "$REPO" --base base --attempt q; assert_equals "bad attempt exits 1" "$RC" "1"
run "../x" 12 standard "$REPO" --base base; assert_equals "traversal runid exits 1" "$RC" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
