#!/usr/bin/env bash
#
# Tests for scripts/admit.sh — worktree, detached plan (non-trivial) collected on the next
# pass, spawn at attempt 0, run-log `admitted`; --next fills MAX − busy slots from the REAL
# ready.sh and run-log.sh. Infra (consult.sh, spawn.sh) is a stub dir passed as ORCH_INFRA.
#
# Run: bash plugins/workflow/tests/test_admit.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIT="$(cd "$SCRIPT_DIR/../scripts" && pwd)/admit.sh"
RUNLOG="$(cd "$SCRIPT_DIR/../scripts" && pwd)/run-log.sh"
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
unset CLAUDE_PROJECT_DIR ORCH_LOCKED ORCH_DEADLINE
INFRA="$WORK/infra"; mkdir -p "$INFRA"; export ORCH_INFRA="$INFRA"
cat >"$INFRA/consult.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG.consult"
[ -z "${STUB_PLAN_SLEEP:-}" ] || sleep "$STUB_PLAN_SLEEP"
case " ${STUB_PLAN_FAIL:-} " in *" $3 "*) echo "error: planner refused" >&2; exit 1 ;; esac
echo "**Plan** posted on #$3"
STUB
# Like spawn.sh, it backgrounds a long-lived child — which must not inherit the run lock.
cat >"$INFRA/spawn.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG.spawn"
( sleep "${STUB_CHILD_SLEEP:-0}" ) >/dev/null 2>&1 &
echo "$!" >"$STUB_LOG.child"
echo /run/dir
STUB
export STUB_LOG="$WORK/log"

REPO="$WORK/repo"
git init -q -b dev "$REPO"
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
printf 'x\n' >"$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm init
git -C "$REPO" branch orchestrate-r1

# 10 trivial, 11 standard (needs-browser), 12 complex blocked by 11, 13 standard, 14 standard
GRAPH="$WORK/graph.json"
cat >"$GRAPH" <<'JSON'
{"issues":[
 {"n":10,"title":"a","state":"open","labels":["ready-for-agent"],"tier":"trivial","body":"","comments":"","blockedBy":[]},
 {"n":11,"title":"b","state":"open","labels":["ready-for-agent","needs-browser"],"tier":"standard","body":"","comments":"","blockedBy":[]},
 {"n":12,"title":"c","state":"open","labels":["ready-for-agent"],"tier":"complex","body":"","comments":"","blockedBy":[11]},
 {"n":13,"title":"d","state":"open","labels":["ready-for-agent"],"tier":"standard","body":"","comments":"","blockedBy":[]},
 {"n":14,"title":"e","state":"open","labels":["ready-for-agent"],"tier":"standard","body":"","comments":"","blockedBy":[]}
],"blockerStates":{"11":"open"},"mockDebtOpen":[]}
JSON
mkenv() {   # mkenv <runid> <max>
    mkdir -p "$CODEX_RUN_ROOT/$1"
    cat >"$CODEX_RUN_ROOT/$1/run.env" <<EOF2
RUNID=$1
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
BASE_BRANCH=dev
BASE_REPO=$REPO
ORCH_BRANCH=orchestrate-r1
ORCH_WT=$WORK/orchwt
GRAPH=$GRAPH
MAX=$2
PRD=
SKIP_UNKNOWN=
EOF2
}
mkenv r1 3
state() { (cd "$REPO" && bash "$RUNLOG" state "${1:-r1}"); }
run() { OUT="$(cd "$REPO" && bash "$ADMIT" "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }
# settle <runid> — wait for every started plan to finish (the stub is instant unless told to sleep)
settle() { for _ in $(seq 1 50); do ls "$CODEX_RUN_ROOT/$1/plans/"*.started >/dev/null 2>&1 || return 0
    [ -z "$(for s in "$CODEX_RUN_ROOT/$1/plans/"*.started; do [ -e "${s%.started}.rc" ] || echo x; done)" ] && return 0
    sleep 0.1; done; }

echo "test: --next fills MAX slots: trivial spawns now, standard starts a DETACHED plan"
run r1 --next
assert_equals "exit 0" "$RC" "0"
assert_contains "trivial admitted at once" "$OUT" "admitted #10 tier=trivial attempt=0"
assert_contains "standard is planning" "$OUT" "planning #11 tier=standard"
assert_contains "third slot planning too" "$OUT" "planning #13 tier=standard"
assert_not_contains "MAX=3 leaves #14 waiting" "$OUT" "#14"
assert_not_contains "#12 is blocked by #11" "$OUT" "#12"
assert_contains "the in-flight line names the plans" "$OUT" "in-flight: 10 planning: 11,13"
assert_not_contains "nothing is spawned onto an unplanned issue" "$(cat "$STUB_LOG.spawn")" " 11 "
assert_equals "the worktree is a real branch off orchestrate-r1" \
    "$(git -C "$REPO/.worktrees/r1/issue-11" rev-parse --abbrev-ref HEAD)" "issue-11"

echo "test: the next pass collects finished plans and spawns them"
settle r1
run r1 --next
assert_contains "#11 collected and admitted" "$OUT" "admitted #11 tier=standard attempt=0"
assert_contains "#13 too" "$OUT" "admitted #13 tier=standard attempt=0"
assert_contains "the plan ran on its worktree" "$(cat "$STUB_LOG.consult")" "plan r1 11 standard $REPO/.worktrees/r1/issue-11"
assert_contains "needs-browser rides along" "$(grep ' 11 ' "$STUB_LOG.spawn")" "--browser"
assert_not_contains "and only for that issue" "$(grep ' 13 ' "$STUB_LOG.spawn")" "--browser"
assert_contains "planned is logged" "$(state)" "planned=11,13"
assert_contains "in_flight from the log" "$(state)" "in_flight=10,11,13"
assert_contains "and the line after" "$OUT" "in-flight: 10,11,13"

echo "test: a full house admits nothing"
: >"$STUB_LOG.spawn"
run r1 --next
assert_equals "nothing spawned" "$(cat "$STUB_LOG.spawn")" ""
assert_equals "just the in-flight line" "$OUT" "in-flight: 10,11,13"

echo "test: a merge frees a slot and satisfies a blocker"
(cd "$REPO" && bash "$RUNLOG" append r1 merged '{"n":11,"sha":"abc"}')
run r1 --next
assert_contains "the freed slot takes the lowest ready: #12, now unblocked" "$OUT" "planning #12 tier=complex"
assert_not_contains "and only one slot was free" "$OUT" "#14"
settle r1; run r1 --next
assert_contains "collected" "$OUT" "admitted #12 tier=complex"

echo "test: a failed plan holds the issue and spawns nothing"
(cd "$REPO" && bash "$RUNLOG" append r1 merged '{"n":10,"sha":"abd"}')
: >"$STUB_LOG.spawn"
export STUB_PLAN_FAIL=14
run r1 --next; settle r1; run r1 --next
unset STUB_PLAN_FAIL
assert_contains "held, with the planner's reason" "$OUT" "held #14 plan failed: error: planner refused"
assert_equals "no worker on an issue with no plan" "$(cat "$STUB_LOG.spawn")" ""
assert_contains "held in the log" "$(state)" "held=14"

echo "test: nothing running and nothing admissible says why"
(cd "$REPO" && for n in 12 13; do bash "$RUNLOG" append r1 merged "{\"n\":$n,\"sha\":\"x\"}"; done)
run r1 --next
assert_equals "exit 0" "$RC" "0"
assert_contains "ready.sh's designed empty" "$OUT" "nothing-to-do:"

echo "test: only plans running reads as waiting, never as the end"
mkenv r5 1; git -C "$REPO" branch orchestrate-r5 2>/dev/null
sed -i 's/^ORCH_BRANCH=.*/ORCH_BRANCH=orchestrate-r5/' "$CODEX_RUN_ROOT/r5/run.env"
git -C "$REPO" worktree remove --force "$REPO/.worktrees/r1/issue-11" >/dev/null 2>&1
STUB_PLAN_SLEEP=2 run r5 11
assert_contains "planning" "$OUT" "planning #11"
assert_contains "waiting, not nothing-to-do" "$OUT" "waiting: planning #11"

echo "test: the run lock is never held by a spawned worker"
mkenv r6 3; git -C "$REPO" branch orchestrate-r6 2>/dev/null
sed -i 's/^ORCH_BRANCH=.*/ORCH_BRANCH=orchestrate-r6/' "$CODEX_RUN_ROOT/r6/run.env"
git -C "$REPO" worktree remove --force "$REPO/.worktrees/r1/issue-10" >/dev/null 2>&1; git -C "$REPO" branch -D issue-10 >/dev/null 2>&1
STUB_CHILD_SLEEP=20 run r6 10
assert_contains "admitted" "$OUT" "admitted #10"
OUT="$(cd "$REPO" && ORCH_LOCK_WAIT=2 bash "$ADMIT" r6 --next 2>/dev/null)"
assert_not_contains "the next call gets the lock while the worker lives" "$OUT" "still running"
kill "$(cat "$STUB_LOG.child")" 2>/dev/null

echo "test: a stale issue-N branch from an earlier run is held, never built on"
mkenv r7 3; git -C "$REPO" branch orchestrate-r7 2>/dev/null
sed -i 's/^ORCH_BRANCH=.*/ORCH_BRANCH=orchestrate-r7/' "$CODEX_RUN_ROOT/r7/run.env"
git -C "$REPO" worktree remove --force "$REPO/.worktrees/r1/issue-14" >/dev/null 2>&1
git -C "$REPO" checkout -q --orphan oldbase; git -C "$REPO" commit -qm old --allow-empty
git -C "$REPO" branch -f issue-14 oldbase
git -C "$REPO" checkout -q dev
run r7 14
assert_contains "held, naming the stale branch" "$OUT" "held #14 a stale issue-14 branch"

echo "test: refusals"
run r1 13; assert_equals "an admitted issue twice is refused" "$RC" "1"
run r1 99; assert_contains "an issue outside the graph is held, not spawned" "$OUT" "held #99"
run nope --next; assert_equals "an unlaunched run exits 1" "$RC" "1"
assert_contains "and says so" "$ERR" "no launched run"
run ../x --next; assert_equals "traversal runid exits 1" "$RC" "1"

# A second repo for the slot-accounting cases: the first one's branches and worktrees are spent.
REPO="$WORK/repo2"
git init -q -b dev "$REPO"
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
printf 'x\n' >"$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm init
git -C "$REPO" branch orchestrate-r8; git -C "$REPO" branch orchestrate-r9

echo "test: a pick that is HELD at admission does not use up a slot"
mkenv r8 2; sed -i 's/^ORCH_BRANCH=.*/ORCH_BRANCH=orchestrate-r8/' "$CODEX_RUN_ROOT/r8/run.env"
git -C "$REPO" checkout -q --orphan oldbase; git -C "$REPO" commit -qm old --allow-empty
git -C "$REPO" branch -f issue-10 oldbase; git -C "$REPO" checkout -q dev
run r8 13
run r8 --next
assert_contains "the stale pick is held" "$OUT" "held #10 a stale issue-10 branch"
assert_contains "and the next ready issue still gets the free slot in the SAME pass" "$OUT" "planning #11 tier=standard"

echo "test: a plan that finishes after --max was lowered waits for a slot instead of exceeding it"
mkenv r9 2; sed -i 's/^ORCH_BRANCH=.*/ORCH_BRANCH=orchestrate-r9/' "$CODEX_RUN_ROOT/r9/run.env"
git -C "$REPO" branch -D issue-10 >/dev/null 2>&1
for n in 11 13; do   # r8's worktrees would block r9 from checking the same branches out
    git -C "$REPO" worktree remove --force "$REPO/.worktrees/r8/issue-$n" >/dev/null 2>&1
    git -C "$REPO" branch -D "issue-$n" >/dev/null 2>&1
done
: >"$STUB_LOG.spawn"
run r9 --next
assert_contains "10 admitted and 11 planning under MAX=2" "$OUT" "in-flight: 10 planning: 11"
settle r9
sed -i 's/^MAX=.*/MAX=1/' "$CODEX_RUN_ROOT/r9/run.env"
: >"$STUB_LOG.spawn"
run r9 --next
assert_not_contains "11 is not admitted over the lowered cap" "$OUT" "admitted #11"
assert_equals "nothing spawned" "$(cat "$STUB_LOG.spawn")" ""
assert_contains "the finished plan is still counted, not re-planned" "$OUT" "planning: 11"
(cd "$REPO" && bash "$RUNLOG" append r9 merged '{"n":10,"sha":"abc"}')
run r9 --next
assert_contains "once a slot frees the plan is spawned" "$OUT" "admitted #11 tier=standard attempt=0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
