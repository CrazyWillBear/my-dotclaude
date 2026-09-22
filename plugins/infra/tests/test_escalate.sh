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

# resolve-tier.sh fixture (round 11): escalate.sh now asks IT for the implementer's
# backend at --attempt, never a codex run dir's existence. Standard's chain mirrors the
# SHIPPED table's shape — codex, codex, then claude tops it at position 2 — so every
# existing --attempt 0 / --attempt 1 case below still exercises a codex-backed signal, and
# a dedicated position-2 case below exercises the claude-backed "never escalated" path.
CFG="$WORK/cfg"; mkdir -p "$CFG"
cat >"$CFG/model-tiers.json" <<'JSON'
{
  "trivial":  { "planner": { "backend": "claude", "model": "opus", "effort": "medium" },
                "implementer": { "backend": "codex", "model": "gpt-5.6-luna", "effort": "xhigh" },
                "reviewer": { "backend": "claude", "model": "opus", "effort": "low" } },
  "standard": { "planner": { "backend": "claude", "model": "opus", "effort": "medium" },
                "implementer": [ { "backend": "codex", "model": "gpt-5.6-luna",  "effort": "xhigh" },
                                 { "backend": "codex", "model": "gpt-5.6-terra", "effort": "xhigh" },
                                 { "backend": "claude", "model": "opus",         "effort": "medium" } ],
                "reviewer": { "backend": "claude", "model": "opus", "effort": "medium" } },
  "complex":  { "planner": { "backend": "claude", "model": "fable", "effort": "medium" },
                "implementer": { "backend": "claude", "model": "opus", "effort": "medium" },
                "reviewer": { "backend": "claude", "model": "opus", "effort": "high" } }
}
JSON
export RESOLVE_TIER_ROOT="$CFG"

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

# A real LINKED worktree (the only shape common-git-dir.sh --roots accepts — escalate.sh
# re-checks containment before touching it) with a base branch and two commits on top:
# the handoff lists them.
ORIGIN="$WORK/origin"; mkdir -p "$ORIGIN"
git -C "$ORIGIN" init -q; git -C "$ORIGIN" config user.email t@t.t; git -C "$ORIGIN" config user.name t
printf 'x\n' >"$ORIGIN/f"; git -C "$ORIGIN" add f; git -C "$ORIGIN" commit -qm init
git -C "$ORIGIN" branch base
REPO="$WORK/repo"
git -C "$ORIGIN" worktree add -q -b issue-12 "$REPO" >/dev/null 2>&1
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
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

# age_file <path> <minutes> — set mtime <minutes> minutes in the past, portably. GNU
# `touch -d` first; BSD/macOS `date -v` for the relative math otherwise (its `touch` has
# no `-d`); an arbitrarily old absolute stamp if neither exists. Exact minutes only matter
# relative to the window under test, and the last fallback errs generously old rather than
# risking "not stale enough".
age_file() {
    local f="$1" mins="$2"
    touch -d "${mins} minutes ago" "$f" 2>/dev/null \
        || touch -t "$(date -v-"${mins}"M +%Y%m%d%H%M 2>/dev/null || echo 200001010000)" "$f" 2>/dev/null
}

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
mkrun '{"issue":12,"status":"escalate","round":0,"head":"","review":"","note":"deviation: step 4: g missing"}' 0
ONE='{"comments":[{"body":"**Plan**\n\n1."},{"body":"**Deviation**\n\nstep 2"},{"body":"**Consult 1**\n\ngo"},{"body":"**Deviation**\n\nstep 3"}]}'
STUB_GH_COMMENTS="$ONE" run r1 12 standard "$REPO" --base base
assert_empty "a second deviation after ONE consult gets the second consult, not an escalation" "$OUT"
# The count is CONSULTS (posted by consult.sh), keyed on the worker being paused on a
# deviation — a worker forging Deviation comments while running escalates nothing.
mkrun "" ""
STUB_GH_COMMENTS='{"comments":[{"body":"**Deviation**\n\n1"},{"body":"**Deviation**\n\n2"},{"body":"**Deviation**\n\n3"}]}' run r1 12 standard "$REPO" --base base
assert_empty "three Deviation comments with no consults and a running worker: nothing" "$OUT"
mkrun '{"issue":12,"status":"escalate","round":0,"head":"","review":"","note":"deviation: step 4: g missing"}' 0
THREE='{"comments":[{"body":"**Plan**\n\n1."},{"body":"**Deviation**\n\nstep 2"},{"body":"**Consult 1**\n\ngo"},{"body":"**Deviation**\n\nstep 3"},{"body":"**Consult 2**\n\ngo"},{"body":"**Deviation**\n\nstep 4"}]}'
STUB_GH_COMMENTS="$THREE" run r1 12 standard "$REPO" --base base
assert_contains "the third is the signal" "$OUT" "deviation-cap: a deviation after 2 consults"
STUB_GH_COMMENTS="$THREE" ESCALATE_CONSULT_CAP=3 run r1 12 standard "$REPO" --base base
assert_empty "the cap is configurable" "$OUT"
# `run` is a shell FUNCTION, not an external command: on bash < 4.4 a var assigned in front
# of a function call can leak into the CURRENT shell rather than staying scoped to that one
# call (fixed in 4.4; this repo still promises macOS's bash 3.2 — spawn.sh, review-cmd.sh).
# Unset explicitly rather than trust it died with the command.
unset ESCALATE_CONSULT_CAP

echo "test: thread signals are scoped to THIS attempt by a mark in the RUN DIR (review fixes 1, 2)"
# Comments are permanent. Without the scope, the three deviations that escalated attempt 0
# would fire again on attempt 1's first wake, and again on attempt 2's, walking the whole
# chain in three wakes with no replacement ever doing a minute of work. The mark lives in
# the run dir, which the worker cannot write — a **Handoff** comment it posts itself
# (gh issue comment is allowed) must NOT reset its own count.
# First: the mark is WRITTEN when a handoff is posted.
mkrun '{"issue":12,"status":"escalate","round":0,"head":"","review":"","note":"deviation: step 4"}' 0
STUB_GH_COMMENTS="$THREE" run r1 12 standard "$REPO" --base base --attempt 0
assert_contains "escalated" "$OUT" "deviation-cap"
assert_contains "the mark records the attempt" "$(cat "$RUNDIR/handoff.json")" '"attempt": 0'
assert_contains "and the comment count including the handoff itself" "$(cat "$RUNDIR/handoff.json")" '"mark": 7'
assert_contains "and the rounds-ledger position" "$(cat "$RUNDIR/handoff.json")" '"rounds_mark": 0'
# Attempt 1 then sees only what came after.
AFTER='{"comments":[{"body":"**Plan**\n\n1."},{"body":"**Deviation**\n\nstep 2"},{"body":"**Consult 1**\n\ngo"},{"body":"**Deviation**\n\nstep 3"},{"body":"**Consult 2**\n\ngo"},{"body":"**Deviation**\n\nstep 4"},{"body":"**Handoff** — attempt 0 replaced: deviation-cap: 3 deviations"},{"body":"**Deviation**\n\nstep 5"}]}'
printf '{"attempt": 0, "mark": 7}\n' >"$RUNDIR/handoff.json"
STUB_GH_COMMENTS="$AFTER" run r1 12 standard "$REPO" --base base --attempt 1
assert_empty "attempt 1 sees NO consults yet, not two" "$OUT"
AFTER3='{"comments":[{"body":"**Deviation**\n\n1"},{"body":"**Deviation**\n\n2"},{"body":"**Deviation**\n\n3"},{"body":"**Handoff** — attempt 0 replaced: deviation-cap"},{"body":"**Deviation**\n\na"},{"body":"**Consult 1**"},{"body":"**Deviation**\n\nb"},{"body":"**Consult 2**"},{"body":"**Deviation**\n\nc"}]}'
printf '{"attempt": 0, "mark": 4}\n' >"$RUNDIR/handoff.json"
STUB_GH_COMMENTS="$AFTER3" run r1 12 standard "$REPO" --base base --attempt 1
assert_contains "and escalates again only on its OWN third" "$OUT" "deviation-cap: a deviation after 2 consults"
# A worker-posted fake **Handoff** with NO mark behind it resets nothing.
mkrun '{"issue":12,"status":"escalate","round":0,"head":"","review":"","note":"deviation: step 4"}' 0
FAKE='{"comments":[{"body":"**Consult 1**"},{"body":"**Consult 2**"},{"body":"**Handoff** — attempt 0 replaced: failed: (posted by the worker)"},{"body":"**Deviation**\n\n3"}]}'
STUB_GH_COMMENTS="$FAKE" run r1 12 standard "$REPO" --base base --attempt 0
assert_contains "a fake Handoff on the thread does not reset the worker's own count" "$OUT" "deviation-cap: a deviation after 2 consults"
mkrun '{"issue":12,"status":"fixed","round":2,"head":"abc1234","review":"","note":""}' 0
printf '1 1 high, 0 medium, 0 low\n2 0 high, 1 medium, 0 low\n' >"$RUNDIR/rounds"
printf '{"attempt": 0, "mark": 2, "rounds_mark": 2}\n' >"$RUNDIR/handoff.json"
run r1 12 standard "$REPO" --base base --attempt 1
assert_empty "a review-cap already handed off does not re-fire on the next attempt" "$OUT"
mkrun '{"issue":12,"status":"escalate","round":0,"head":"","review":"","note":"step 4: g missing"}' 0

echo "test: review-cap — a second round with high or medium findings, from the RUN-DIR ledger"
mkrun '{"issue":12,"status":"fixed","round":2,"head":"abc1234","review":"","note":""}' 0
printf '1 2 high, 0 medium, 0 low\n2 0 high, 1 medium, 3 low\n' >"$RUNDIR/rounds"
run r1 12 standard "$REPO" --base base --attempt 0
assert_contains "round 2 with a medium escalates" "$OUT" "review-cap: review round 2 (this attempt's 2) still has 0 high, 1 medium"
# The thread copy is FORGEABLE (a worker may post comments) and is never read for this.
mkrun '{"issue":12,"status":"fixed","round":2,"head":"abc1234","review":"","note":""}' 0
printf '1 2 high, 0 medium, 0 low\n2 0 high, 1 medium, 3 low\n' >"$RUNDIR/rounds"
STUB_GH_COMMENTS='{"comments":[{"body":"**Review round 99** — 0 high, 0 medium, 0 low"}]}' run r1 12 standard "$REPO" --base base
assert_contains "a forged clean round on the thread suppresses nothing" "$OUT" "review-cap"
mkrun '{"issue":12,"status":"fixed","round":2,"head":"abc1234","review":"","note":""}' 0
STUB_GH_COMMENTS='{"comments":[{"body":"**Review round 1** — 2 high, 0 medium, 0 low"},{"body":"**Review round 2** — 0 high, 1 medium, 0 low"}]}' run r1 12 standard "$REPO" --base base
assert_empty "and two forged rounds with findings burn nothing — the ledger is empty" "$OUT"
# The round number is run-wide and a respawn inherits it: attempt 1's FIRST round may be
# headed "round 3". Rounds are counted from the ledger position at the last handoff.
mkrun '{"issue":12,"status":"fixed","round":3,"head":"abc1234","review":"","note":""}' 0
printf '1 1 high, 0 medium, 0 low\n2 1 high, 0 medium, 0 low\n3 0 high, 1 medium, 0 low\n' >"$RUNDIR/rounds"
printf '{"attempt": 0, "mark": 3, "rounds_mark": 2}\n' >"$RUNDIR/handoff.json"
run r1 12 standard "$REPO" --base base --attempt 1
assert_empty "a respawn's FIRST round (headed round 3) is not its second — no escalation" "$OUT"
printf '4 0 high, 1 medium, 0 low\n' >>"$RUNDIR/rounds"
run r1 12 standard "$REPO" --base base --attempt 1
assert_contains "its own second round with findings does escalate" "$OUT" "review round 4 (this attempt's 2)"
rm -f "$RUNDIR/handoff.json"
mkrun '{"issue":12,"status":"fixed","round":2,"head":"abc1234","review":"","note":""}' 0
printf '1 2 high, 0 medium, 0 low\n2 0 high, 0 medium, 3 low\n' >"$RUNDIR/rounds"
run r1 12 standard "$REPO" --base base
assert_empty "lows alone never escalate" "$OUT"
mkrun '{"issue":12,"status":"fixed","round":1,"head":"abc1234","review":"","note":""}' 0
printf '1 2 high, 0 medium, 0 low\n' >"$RUNDIR/rounds"
run r1 12 standard "$REPO" --base base
assert_empty "a first round with findings is a fix round, not an escalation" "$OUT"
mkrun '{"issue":12,"status":"fixed","round":2,"head":"abc1234","review":"","note":""}' 0
printf '1 0 high, 0 medium, 0 low\n2 0 high, 1 medium, 0 low\n3 0 high, 0 medium, 0 low\n' >"$RUNDIR/rounds"
run r1 12 standard "$REPO" --base base
assert_empty "the NEWEST round decides, not the worst — a clean round 3 after a bad round 2" "$OUT"

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
unset ESCALATE_OCCUPANCY_TOKENS   # see the ESCALATE_CONSULT_CAP note above — same shape
mkrollout 300000
mkrun '{"issue":12,"status":"fixed","round":1,"head":"abc1234","review":"","note":""}' 0
STUB_GH_COMMENTS='{"comments":[{"body":"**Review round 1** — 1 high, 0 medium, 0 low"}]}' run r1 12 standard "$REPO" --base base
assert_empty "a FINISHED worker's last context is not a signal — the fix round is a fresh session" "$OUT"
mkrun '{"issue":12,"status":"escalate","round":0,"head":"","review":"","note":"deviation: step 3"}' 0
run r1 12 standard "$REPO" --base base
assert_contains "but a worker paused on a deviation at a full window IS — a resume would not fit" "$OUT" "occupancy"
mkrun "" ""
rm -rf "$SESSIONS"
run r1 12 standard "$REPO" --base base
assert_empty "no rollout found: no occupancy signal, no crash" "$OUT"

echo "test: stall — alive, unfinished, event log untouched for the window"
sleep 120 & SLEEPER=$!
mkrun "" "" "$SLEEPER"
age_file "$RUNDIR/events.jsonl" 30
run r1 12 standard "$REPO" --base base --attempt 1
assert_contains "escalates as a stall" "$OUT" "stall: no event-log activity for 30 minutes"
assert_contains "the handoff names attempt 1" "$(cat "$WORK/body")" "attempt 1 replaced: stall"
touch "$RUNDIR/events.jsonl"
run r1 12 standard "$REPO" --base base
assert_empty "a fresh event log is not a stall" "$OUT"
age_file "$RUNDIR/events.jsonl" 30
ESCALATE_STALL_MINUTES=45 run r1 12 standard "$REPO" --base base
assert_empty "the window is configurable" "$OUT"
unset ESCALATE_STALL_MINUTES   # see the ESCALATE_CONSULT_CAP note above — same shape; every
                               # assertion below this line assumes the DEFAULT 20-minute stall
: >"$RUNDIR/reviewing"
run r1 12 standard "$REPO" --base base
assert_empty "the post-worker REVIEW phase (reviewing marker, no exit yet) is not a stall" "$OUT"
age_file "$RUNDIR/reviewing" 30
run r1 12 standard "$REPO" --base base --attempt 1
assert_empty "but 30 minutes into review is still WITHIN the review's own (longer) budget" "$OUT"
# Same 30-minute-old marker: only a SHORTER configured budget can make this fire, so this
# is the one case that actually exercises ESC_REVIEW rather than just outliving the default.
ESCALATE_REVIEW_MINUTES=5 run r1 12 standard "$REPO" --base base --attempt 1
assert_contains "the review budget is configurable, independent of the stall window" "$OUT" "stall"
unset ESCALATE_REVIEW_MINUTES   # this next case is exactly what would go unmeasured if it leaked
age_file "$RUNDIR/reviewing" 50
run r1 12 standard "$REPO" --base base --attempt 1
assert_contains "past the DEFAULT review budget too, a hung reviewer is not invisible" "$OUT" "stall"
rm -f "$RUNDIR/reviewing"
printf '0\n' >"$RUNDIR/exit"
run r1 12 standard "$REPO" --base base
assert_empty "a FINISHED worker with an old log is not a stall" "$OUT"
kill "$SLEEPER" 2>/dev/null; SLEEPER=""

echo "test: comments from a PREVIOUS run do not leak into a fresh run's caps (review round 7/8)"
# No handoff.json yet (this attempt's very first evaluation) and a .started marker AFTER
# every comment's createdAt: everything on the thread belongs to a run that already ended.
mkrun '{"issue":12,"status":"escalate","round":0,"head":"","review":"","note":"deviation: step 2"}' 0
printf '9999999999\n' >"$RUNDIR/.started"
OLD='{"comments":[{"body":"**Consult 1**","createdAt":"2020-01-01T00:00:00Z"},{"body":"**Consult 2**","createdAt":"2020-01-01T00:00:01Z"}]}'
STUB_GH_COMMENTS="$OLD" run r1 12 standard "$REPO" --base base
assert_empty "consults from a stale prior run, all older than .started, do not count" "$OUT"
# The identical two comments, with a .started BEFORE their createdAt, count normally —
# proving the exclusion above is the timestamp comparison, not an empty ledger by accident.
printf '1\n' >"$RUNDIR/.started"
STUB_GH_COMMENTS="$OLD" run r1 12 standard "$REPO" --base base
assert_contains "but consults created during THIS run's window do" "$OUT" "deviation-cap"
# A comment with NO createdAt at all is treated as arbitrarily old — excluded, never
# trusted as fresh — so a malformed or stubbed thread fails toward under-counting.
printf '1\n' >"$RUNDIR/.started"
NOTS='{"comments":[{"body":"**Consult 1**"},{"body":"**Consult 2**","createdAt":"2020-01-01T00:00:01Z"}]}'
STUB_GH_COMMENTS="$NOTS" run r1 12 standard "$REPO" --base base
assert_empty "a comment missing createdAt is excluded rather than trusted as fresh" "$OUT"
# With NO .started at all (the fixtures' usual case, matching every other test in this
# file), the old behavior holds: everything on the thread counts.
mkrun '{"issue":12,"status":"escalate","round":0,"head":"","review":"","note":"deviation: step 2"}' 0
STUB_GH_COMMENTS="$OLD" run r1 12 standard "$REPO" --base base
assert_contains "with no .started marker at all, nothing new is excluded" "$OUT" "deviation-cap"
# Once a handoff HAS happened, the run-dir mark governs and .started is never consulted —
# even a far-future .started must not re-exclude comments the mark already includes.
mkrun '{"issue":12,"status":"escalate","round":0,"head":"","review":"","note":"deviation: step 2"}' 0
printf '9999999999\n' >"$RUNDIR/.started"
printf '{"attempt": 0, "mark": 0, "rounds_mark": 0}\n' >"$RUNDIR/handoff.json"
STUB_GH_COMMENTS="$OLD" run r1 12 standard "$REPO" --base base --attempt 1
assert_contains "a real mark of 0 is honored even past a far-future .started" "$OUT" "deviation-cap"
rm -f "$RUNDIR/handoff.json" "$RUNDIR/.started"

echo "test: the handoff is posted ONCE per attempt — this runs on every wake"
mkrun '{"issue":12,"status":"failed","round":0,"head":"","review":"","note":"x"}' 0
run r1 12 standard "$REPO" --base base --attempt 0
assert_equals "first wake posts" "$(posted)" "yes"
run r1 12 standard "$REPO" --base base --attempt 0
assert_contains "the reason is still reported on the next wake" "$OUT" "failed"
assert_equals "but not re-posted" "$(posted)" "no"
run r1 12 standard "$REPO" --base base --attempt 1
assert_equals "a different attempt's handoff does not block this one" "$(posted)" "yes"

echo "test: --dry-run reports, posts nothing, and leaves NO trace in the run dir"
mkrun '{"issue":12,"status":"failed","round":0,"head":"","review":"","note":"x"}' 0
run r1 12 standard "$REPO" --base base --dry-run
assert_contains "reason printed" "$OUT" "failed"
assert_equals "nothing posted" "$(posted)" "no"
for f in handoff-comment.md handoff.json escalate-stderr.log; do
    if [ -e "$RUNDIR/$f" ]; then no "dry run wrote $f"; else ok "dry run did not write $f"; fi
done

echo "test: a claude-backed attempt (chain position 2) is never escalated (review round 11)"
# The exact round-11 bug: a run dir left over from an earlier CODEX attempt of the SAME run
# survives (nothing deletes it) and must not make attempt 2 (this fixture's claude cell)
# read as codex-backed — the backend comes from resolve-tier.sh, never the filesystem.
mkrun '{"issue":12,"status":"failed","round":0,"head":"","review":"","note":"stale, from attempt 1"}' 3
run r1 12 standard "$REPO" --base base --attempt 2
assert_equals "exit 0" "$RC" "0"
assert_empty "nothing on stdout — a stale failed-looking run dir is not read at all" "$OUT"
assert_contains "and says why on stderr" "$ERR" "never escalated"
assert_equals "and nothing posted" "$(posted)" "no"
rm -rf "$RUNDIR"
run r1 12 standard "$REPO" --base base --attempt 2
assert_equals "exit 0 with truly no run dir either" "$RC" "0"
assert_empty "nothing on stdout" "$OUT"
assert_contains "and says why on stderr" "$ERR" "never escalated"

echo "test: the containment tripwire — a worktree --roots refuses is not read (review fix 3)"
mkrun '{"issue":12,"status":"failed","round":0,"head":"","review":"","note":"x"}' 0
PLAIN="$WORK/plain"; mkdir -p "$PLAIN"; git -C "$PLAIN" init -q
run r1 12 standard "$PLAIN" --base base
assert_equals "exit 1" "$RC" "1"
assert_empty "nothing on stdout" "$OUT"
assert_contains "says why" "$ERR" "containment check refused"
assert_equals "nothing posted" "$(posted)" "no"

echo "test: an unknown tier is refused, never resolved (review round 12)"
# resolve-tier.sh answers an unknown tier with its claude-only FALLBACK roster and exit 0,
# which would read here as "claude-backed, never escalated" — silently switching every
# signal off for that worker for the rest of the run. `tier:standard`, the LABEL form, is
# the typo that does it, and the note on stderr would look reassuring.
mkrun '{"issue":12,"status":"failed","round":0,"head":"","review":"","note":"x"}' 0
run r1 12 tier:standard "$REPO" --base base --attempt 0
assert_equals "the label form exits 1" "$RC" "1"
assert_contains "and names the tier" "$ERR" "unknown tier 'tier:standard'"
assert_not_contains "never reports it as claude-backed" "$ERR" "never escalated"
assert_equals "nothing posted" "$(posted)" "no"

echo "test: a codex attempt with a missing run dir says so (review round 12)"
# The [ -d "$RUNDIR" ] gate went with the run-dir backend test; without a replacement the
# stderr redirect into that dir fails and the operator gets a bare redirect error plus a
# cat of a log that was never created.
rm -rf "$RUNDIR"
run r1 12 standard "$REPO" --base base --attempt 0
assert_equals "exit 1" "$RC" "1"
assert_contains "names the missing run dir" "$ERR" "no codex run dir for issue 12"
assert_not_contains "no bare cat failure" "$ERR" "No such file or directory"

echo "test: usage errors fail loud"
run r1 12 standard "$REPO"; assert_equals "missing --base exits 1" "$RC" "1"
run r1 x standard "$REPO" --base base; assert_equals "bad issue exits 1" "$RC" "1"
run r1 12 standard "$WORK/nope" --base base; assert_equals "missing worktree exits 1" "$RC" "1"
run r1 12 standard "$REPO" --base base --attempt q; assert_equals "bad attempt exits 1" "$RC" "1"
run "../x" 12 standard "$REPO" --base base; assert_equals "traversal runid exits 1" "$RC" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
