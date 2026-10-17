#!/usr/bin/env bash
#
# Tests for scripts/admit.sh — worktree, plan (non-trivial), spawn at attempt 0, run-log
# `admitted`; --next fills MAX − in-flight slots from the REAL ready.sh and run-log.sh.
# Infra (consult.sh, spawn.sh) is a stub dir passed as ORCH_INFRA.
#
# Run: bash plugins/workflow/tests/test_admit.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIT="$(cd "$SCRIPT_DIR/../scripts" && pwd)/admit.sh"
RUNLOG="$(cd "$SCRIPT_DIR/../scripts" && pwd)/run-log.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in '$2')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

export HOME="$WORK/home" CODEX_RUN_ROOT="$WORK/runs"
unset CLAUDE_PROJECT_DIR
INFRA="$WORK/infra"; mkdir -p "$INFRA"; export ORCH_INFRA="$INFRA"
cat >"$INFRA/consult.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG.consult"
case " ${STUB_PLAN_FAIL:-} " in *" $3 "*) echo "error: planner refused" >&2; exit 1 ;; esac
echo "**Plan** posted on #$3"
STUB
cat >"$INFRA/spawn.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG.spawn"
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
mkdir -p "$CODEX_RUN_ROOT/r1"
cat >"$CODEX_RUN_ROOT/r1/run.env" <<EOF2
RUNID=r1
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
BASE_BRANCH=dev
BASE_REPO=$REPO
ORCH_BRANCH=orchestrate-r1
ORCH_WT=$WORK/orchwt
GRAPH=$GRAPH
MAX=3
PRD=
SKIP_UNKNOWN=
EOF2
state() { (cd "$REPO" && bash "$RUNLOG" state r1); }
run() { OUT="$(cd "$REPO" && bash "$ADMIT" "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }

echo "test: --next fills MAX slots with the lowest ready issues, planning all but trivial"
run r1 --next
assert_equals "exit 0" "$RC" "0"
assert_contains "trivial admitted" "$OUT" "admitted #10 tier=trivial attempt=0"
assert_contains "standard admitted" "$OUT" "admitted #11 tier=standard attempt=0"
assert_contains "third slot" "$OUT" "admitted #13 tier=standard attempt=0"
assert_not_contains "MAX=3 leaves #14 waiting" "$OUT" "#14"
assert_not_contains "#12 is blocked by #11" "$OUT" "#12"
assert_contains "ends with the in-flight set" "$OUT" "in-flight: 10,11,13"
assert_not_contains "trivial is never planned" "$(cat "$STUB_LOG.consult")" "r1 10 "
assert_contains "standard is planned on its worktree" "$(cat "$STUB_LOG.consult")" "plan r1 11 standard $REPO/.worktrees/r1/issue-11"
S="$(cat "$STUB_LOG.spawn")"
assert_contains "spawned at attempt 0 off the orchestration branch" "$S" "r1 10 trivial $REPO/.worktrees/r1/issue-10 orchestrate-r1 --role build --round 1 --attempt 0"
assert_contains "needs-browser rides along" "$(grep ' 11 ' "$STUB_LOG.spawn")" "--browser"
assert_not_contains "and only for that issue" "$(grep ' 13 ' "$STUB_LOG.spawn")" "--browser"
assert_equals "the worktree is a real branch off orchestrate-r1" \
    "$(git -C "$REPO/.worktrees/r1/issue-11" rev-parse --abbrev-ref HEAD)" "issue-11"
assert_contains "admitted and planned are logged" "$(state)" "planned=11,13"
assert_contains "in_flight from the log" "$(state)" "in_flight=10,11,13"

echo "test: a full house admits nothing"
: >"$STUB_LOG.spawn"
run r1 --next
assert_equals "nothing spawned" "$(cat "$STUB_LOG.spawn")" ""
assert_equals "just the in-flight line" "$OUT" "in-flight: 10,11,13"

echo "test: a merge frees a slot and satisfies a blocker"
(cd "$REPO" && bash "$RUNLOG" append r1 merged '{"n":11,"sha":"abc"}')
run r1 --next
assert_contains "the freed slot takes the lowest ready: #12, now unblocked" "$OUT" "admitted #12 tier=complex"
assert_not_contains "and only one slot was free" "$OUT" "#14"

echo "test: a failed plan holds the issue and spawns nothing"
(cd "$REPO" && bash "$RUNLOG" append r1 merged '{"n":10,"sha":"abd"}')
: >"$STUB_LOG.spawn"
STUB_PLAN_FAIL=14 run r1 --next
assert_contains "held, with the planner's reason" "$OUT" "held #14 plan failed: error: planner refused"
assert_equals "no worker on an issue with no plan" "$(cat "$STUB_LOG.spawn")" ""
assert_contains "held in the log" "$(state)" "held=14"

echo "test: nothing running and nothing admissible says why"
(cd "$REPO" && for n in 12 13; do bash "$RUNLOG" append r1 merged "{\"n\":$n,\"sha\":\"x\"}"; done)
run r1 --next
assert_equals "exit 0" "$RC" "0"
assert_contains "ready.sh's designed empty" "$OUT" "nothing-to-do:"

echo "test: a recorded drain stops admission"
mkdir -p "$CODEX_RUN_ROOT/r2"; sed 's/^RUNID=r1/RUNID=r2/' "$CODEX_RUN_ROOT/r1/run.env" >"$CODEX_RUN_ROOT/r2/run.env"
git -C "$REPO" branch orchestrate-r2 2>/dev/null
(cd "$REPO" && bash "$RUNLOG" append r2 decision '{"what":"drain: #10 failed at the top of its chain"}')
: >"$STUB_LOG.spawn"
OUT="$(cd "$REPO" && bash "$ADMIT" r2 --next 2>/dev/null)"
assert_contains "says drained" "$OUT" "nothing-to-do: drained (drain: #10"
assert_equals "spawns nothing" "$(cat "$STUB_LOG.spawn")" ""

echo "test: a single admission, and refusals"
mkdir -p "$CODEX_RUN_ROOT/r3"; sed 's/^RUNID=r1/RUNID=r3/; s/^ORCH_BRANCH=orchestrate-r1/ORCH_BRANCH=orchestrate-r1/' "$CODEX_RUN_ROOT/r1/run.env" >"$CODEX_RUN_ROOT/r3/run.env"
git -C "$REPO" worktree remove --force "$REPO/.worktrees/r1/issue-10" >/dev/null 2>&1; git -C "$REPO" branch -D issue-10 >/dev/null 2>&1
run r3 10
assert_contains "admits it" "$OUT" "admitted #10 tier=trivial"
run r3 10
assert_equals "twice is refused" "$RC" "1"
run r3 99
assert_contains "an issue outside the graph is held, not spawned" "$OUT" "held #99"
run nope --next; assert_equals "an unlaunched run exits 1" "$RC" "1"
assert_contains "and says so" "$ERR" "no launched run"
run ../x --next; assert_equals "traversal runid exits 1" "$RC" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
