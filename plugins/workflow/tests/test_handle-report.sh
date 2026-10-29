#!/usr/bin/env bash
#
# Tests for scripts/handle-report.sh — one case per row of its decision table.
#
# The REAL handle-report.sh runs beside the real admit.sh, ready.sh, run-log.sh and
# merge-fold.sh (a copied workflow dir whose follow-up.sh is a stub), against a real git
# repo with an orchestration worktree. Infra is a stub dir (worker-report.sh, escalate.sh,
# consult.sh, spawn.sh, worker-resume.sh) plus the real resolve-tier.sh and env-pairs.sh.
#
# Run: bash plugins/workflow/tests/test_handle-report.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_WF="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
REAL_INFRA="$(cd "$SCRIPT_DIR/../../infra/scripts" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in '$2')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

export HOME="$WORK/home" CODEX_RUN_ROOT="$WORK/runs" STUB_LOG="$WORK/log" HANDLE_RETRY_SLEEP=0
unset CLAUDE_PROJECT_DIR ESCALATE_REVIEW_CAP

WF="$WORK/wf"; mkdir -p "$WF"
for f in handle-report.sh run-env.sh admit.sh ready.sh run-log.sh merge-fold.sh; do cp "$REAL_WF/$f" "$WF/"; done
cat >"$WF/follow-up.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG.followup"
echo "follow-up: #$2 → #900 (tier:$3) re-blocked none"
STUB

INFRA="$WORK/infra"; mkdir -p "$INFRA"; export ORCH_INFRA="$INFRA"
cp "$REAL_INFRA/resolve-tier.sh" "$REAL_INFRA/env-pairs.sh" "$REAL_INFRA/common-git-dir.sh" "$INFRA/"
cat >"$INFRA/worker-report.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG.wr"
[ -z "${STUB_WR_SLEEP:-}" ] || sleep "$STUB_WR_SLEEP"
[ -z "${STUB_WR_ERR:-}" ] || { echo "$STUB_WR_ERR" >&2; exit 1; }
echo "$STUB_REPORT"
STUB
cat >"$INFRA/escalate.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG.esc"
[ -z "${STUB_ESC_FAIL:-}" ] || { echo "error: could not read issue comments" >&2; exit 1; }
[ -z "${STUB_ESC_ONLY:-}" ] || [ "$2" = "$STUB_ESC_ONLY" ] || exit 0
[ -z "${STUB_ESC:-}" ] || echo "$STUB_ESC"
STUB
cat >"$INFRA/consult.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG.consult"
[ -z "${STUB_CONSULT_SLEEP:-}" ] || sleep "$STUB_CONSULT_SLEEP"
[ -z "${STUB_CONSULT_FAIL:-}" ] || { echo "error: past the cap" >&2; exit 1; }
STUB
cat >"$INFRA/reap.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG.reap"
STUB
cat >"$INFRA/spawn.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG.spawn"
STUB
# Like the real one, it clears the run dir's `exit` before the resumed turn runs.
cat >"$INFRA/worker-resume.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG.resume"
rm -f "${CODEX_RUN_ROOT:?}/${1:?}/issue-${2:?}/exit"
STUB

CFG="$WORK/cfg"; mkdir -p "$CFG"
cat >"$CFG/model-tiers.json" <<'JSON'
{
  "trivial":  { "planner": { "backend": "claude", "model": "haiku", "effort": "low" },
                "implementer": [ { "backend": "codex", "model": "gpt-6-luna", "effort": "high" },
                                 { "backend": "codex", "model": "gpt-6-sol", "effort": "high" },
                                 { "backend": "claude", "model": "sonnet", "effort": "high" } ],
                "reviewer": { "backend": "claude", "model": "sonnet", "effort": "low" } },
  "standard": { "planner": { "backend": "claude", "model": "opus", "effort": "medium" },
                "implementer": [ { "backend": "codex", "model": "gpt-6-luna", "effort": "high" },
                                 { "backend": "claude", "model": "opus", "effort": "medium" } ],
                "reviewer": { "backend": "claude", "model": "opus", "effort": "medium" } },
  "complex":  { "planner": { "backend": "claude", "model": "opus", "effort": "high" },
                "implementer": { "backend": "claude", "model": "opus", "effort": "high" },
                "reviewer": { "backend": "claude", "model": "opus", "effort": "high" } }
}
JSON
export RESOLVE_TIER_ROOT="$CFG"

REPO="$WORK/repo"
git init -q -b dev "$REPO"
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
printf 'x\n' >"$REPO/f"; mkdir "$REPO/.orchestrate"
printf '#!/usr/bin/env bash\n[ -z "${STUB_FD9:-}" ] || { ( : >&9 ) 2>/dev/null && { echo "fd 9 leaked"; exit 1; }; }\n[ -z "${STUB_POSTFOLD_FAIL:-}" ] || { echo "two alembic heads" >&2; exit 1; }\n' >"$REPO/.orchestrate/post-fold.sh"
git -C "$REPO" add f .orchestrate; git -C "$REPO" commit -qm init
ORCH_WT="$WORK/orchwt"
git -C "$REPO" worktree add -q -b orchestrate-r1 "$ORCH_WT" dev
# issue-N branches: each adds its own file (merges clean); 19 and 20 both edit f (20 conflicts).
mkbranch() {
    git -C "$REPO" branch "issue-$1" orchestrate-r1
    git -C "$REPO" worktree add -q "$REPO/.worktrees/r1/issue-$1" "issue-$1"
    printf '%s\n' "${2:-$1}" >"$REPO/.worktrees/r1/issue-$1/${3:-f$1}"
    git -C "$REPO/.worktrees/r1/issue-$1" add -A; git -C "$REPO/.worktrees/r1/issue-$1" commit -qm "issue $1"
}
for n in 11 12 13 14 15 16 17 18 21 22; do mkbranch "$n"; done
mkbranch 19 nineteen f; mkbranch 20 twenty f; mkbranch 23; mkbranch 24; mkbranch 25

GRAPH="$WORK/graph.json"
python3 - "$GRAPH" <<'PY'
import json, sys
tiers = {11: "standard", 12: "standard", 13: "standard", 14: "standard", 15: "standard",
         16: "complex", 17: "trivial", 18: "standard", 19: "standard", 20: "standard",
         21: "standard", 22: "standard", 23: "standard", 24: "standard", 25: "standard", 30: "standard"}
issues = [{"n": n, "title": "t%d" % n, "state": "open", "labels": ["ready-for-agent"],
           "tier": t, "body": "", "comments": "", "blockedBy": ([14] if n == 30 else [])}
          for n, t in tiers.items()]
json.dump({"issues": issues, "blockerStates": {"14": "open"}, "mockDebtOpen": []}, open(sys.argv[1], "w"))
PY
mkdir -p "$CODEX_RUN_ROOT/r1"
cat >"$CODEX_RUN_ROOT/r1/run.env" <<EOF2
RUNID=r1
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
BASE_BRANCH=dev
BASE_REPO=$REPO
ORCH_BRANCH=orchestrate-r1
ORCH_WT=$ORCH_WT
GRAPH=$GRAPH
MAX=1
PRD=
SKIP_UNKNOWN=
EOF2
rl() { (cd "$REPO" && bash "$WF/run-log.sh" "$@"); }
# Everything but 30 is "admitted" up front; MAX=1 keeps admit.sh from admitting more.
for n in 11 12 13 14 15 16 17 18 19 20 21 22; do rl append r1 admitted "{\"n\":$n,\"tier\":\"x\"}" >/dev/null; done
dead() { sleep 0 & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }
mkrun() {   # mkrun <N> <attempt> <role> <rounds-lines>
    local d="$CODEX_RUN_ROOT/r1/issue-$1"; mkdir -p "$d"
    printf 'orch-r1-issue-%s-a%s\n' "$1" "$2" >"$d/session-name"
    printf '%s\n' "$3" >"$d/role"; printf "${4:-}" >"$d/rounds"
    dead >"$d/pid"; printf '0\n' >"$d/exit"
}
reset() { for f in wr esc consult spawn resume followup; do : >"$STUB_LOG.$f"; done; unset STUB_ESC STUB_REPORT STUB_WR_ERR STUB_CONSULT_FAIL STUB_ESC_FAIL STUB_WR_SLEEP STUB_ESC_ONLY; }
# live_leader — a sleeping process that leads its own group, like spawn.sh's wrapper.
live_leader() { set -m; sleep 300 & LEADER=$!; set +m; }
run() { OUT="$(cd "$ORCH_WT" && bash "$WF/handle-report.sh" r1 "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }
state() { rl state r1; }

echo "test: a clean build is folded in, logged merged, and the slot refilled"
reset; mkrun 11 0 build '1 0 high, 0 medium, 2 low\n'
STUB_REPORT="issue 11 built head=abc1234 review=0 high, 0 medium, 2 low" run --wait
assert_equals "exit 0" "$RC" "0"
assert_contains "merged" "$OUT" "merged #11"
assert_equals "the branch is on the orchestration branch" "$(git -C "$ORCH_WT" merge-base --is-ancestor issue-11 HEAD && echo yes)" "yes"
assert_contains "logged merged" "$(state)" "merged=11"
assert_contains "the wait set is the in-flight workers" "$(cat "$STUB_LOG.wr")" "--any r1 11 12"
assert_contains "escalate.sh ran first, at the recorded attempt" "$(cat "$STUB_LOG.esc")" "r1 11 standard $REPO/.worktrees/r1/issue-11 --base orchestrate-r1 --attempt 0"
assert_contains "admit.sh --next reports the in-flight set after" "$OUT" "in-flight:"

echo "test: findings with no signal draw a fix round on the same attempt"
reset; mkrun 12 0 build '1 1 high, 1 medium, 0 low\n'
STUB_REPORT="issue 12 built head=abc1234 review=1 high, 1 medium, 0 low" run --wait
assert_contains "the fix round" "$OUT" "fix #12 round=1 attempt=0"
assert_contains "spawned as a fix, same attempt" "$(cat "$STUB_LOG.spawn")" "r1 12 standard $REPO/.worktrees/r1/issue-12 orchestrate-r1 --role fix --round 1 --attempt 0"

echo "test: recurrence draws a decide, then the fix round"
reset; mkrun 13 0 fix '1 0 high, 1 medium, 0 low\n2 0 high, 1 medium, 0 low\n'
STUB_ESC="recurrence: src/a.py" STUB_REPORT="issue 13 fixed round=1 head=abc1234 review=0 high, 1 medium, 0 low" run --wait
assert_contains "the decide" "$(cat "$STUB_LOG.consult")" "decide r1 13 standard"
assert_contains "logged consulted" "$(state)" "consulted=13:1"
assert_contains "then the fix round" "$(cat "$STUB_LOG.spawn")" "--role fix --round 2 --attempt 0"

echo "test: no-progress caps the issue: logged, folded in, follow-up filed"
reset; mkrun 14 1 fix '1 1 high, 0 medium, 0 low\n'
STUB_ESC="no-progress: review 3 has 1 high+medium" STUB_REPORT="issue 14 fixed round=2 head=abc1234 review=1 high, 0 medium, 0 low" run --wait
assert_contains "capped" "$OUT" "capped #14 no-progress"
assert_contains "merged anyway" "$OUT" "merged #14"
assert_contains "the follow-up" "$OUT" "follow-up: #14 → #900"
assert_contains "follow-up.sh got the issue, tier and graph" "$(cat "$STUB_LOG.followup")" "r1 14 standard $GRAPH"
assert_contains "logged escalated" "$(state)" "escalated=14:1"

echo "test: review-cap respawns the FIX round at the next chain position"
reset; mkrun 15 0 build '1 1 high, 0 medium, 0 low\n'
STUB_ESC="review-cap: review 1 still has 1 high" STUB_REPORT="issue 15 built head=abc1234 review=1 high, 0 medium, 0 low" run --wait
assert_contains "escalated" "$OUT" "escalated #15 review-cap → attempt 1"
assert_contains "respawned as a fix at attempt 1" "$(cat "$STUB_LOG.spawn")" "r1 15 standard $REPO/.worktrees/r1/issue-15 orchestrate-r1 --role fix --round 1 --attempt 1"

echo "test: quota skips the remaining codex positions to the claude cell"
reset; mkrun 17 0 build ''
STUB_ESC="quota: usage limit" STUB_REPORT="issue 17 failed quota" run --wait
assert_contains "skips gpt-6-sol (attempt 1) for the claude cell (attempt 2)" "$OUT" "escalated #17 quota → attempt 2"

echo "test: a deviation is consulted and the worker resumed, not shown to a human"
reset; mkrun 18 0 build ''
STUB_REPORT="issue 18 escalate deviation: step 2 assumed X" run --wait
assert_contains "consulted and resumed" "$OUT" "consulted #18; resumed"
for _ in 1 2 3 4 5; do [ -s "$STUB_LOG.resume" ] && break; sleep 0.5; done
assert_contains "worker-resume got the consult pointer" "$(cat "$STUB_LOG.resume")" "read the newest **Consult** comment on #18"
assert_contains "at the recorded attempt" "$(cat "$STUB_LOG.resume")" "--attempt 0"

echo "test: a refused consult is a deviation-cap escalation"
reset; mkrun 18 0 build ''
STUB_CONSULT_FAIL=1 STUB_REPORT="issue 18 escalate deviation: again" run --wait
assert_contains "escalated" "$OUT" "escalated #18 deviation-cap → attempt 1"

echo "test: a question pauses the issue for the human; --wait then skips it"
reset; mkrun 21 0 build ''
STUB_REPORT="issue 21 escalate is the budget per request?" run --wait
assert_contains "relayed verbatim" "$OUT" "escalate #21 is the budget per request?"
reset; mkrun 12 0 fix '1 1 high, 1 medium, 0 low\n2 0 high, 0 medium, 0 low\n'
STUB_REPORT="issue 12 fixed round=1 head=abc1234 review=0 high, 0 medium, 0 low" run --wait
assert_not_contains "a paused issue is not waited on" "$(cat "$STUB_LOG.wr")" " 21"
run --answer 21 "per request"
assert_contains "--answer resumes it" "$OUT" "resumed #21"
for _ in 1 2 3 4 5; do grep -q 'per request' "$STUB_LOG.resume" 2>/dev/null && break; sleep 0.5; done
assert_contains "with the answer" "$(cat "$STUB_LOG.resume")" "--answer per request"

echo "test: blocked infra pauses; --resource stores the pairs privately and respawns"
reset; mkrun 22 0 build ''
STUB_REPORT="issue 22 blocked infra: postgres" run --wait
assert_contains "relayed" "$OUT" "blocked #22 infra: postgres"
run --resource 22 --env DATABASE_URL=postgres://secret
assert_contains "respawned with the NAME" "$OUT" "respawned #22 with DATABASE_URL"
assert_equals "the pairs file is 0600" "$(stat -c %a "$CODEX_RUN_ROOT/r1/issue-22/env")" "600"
assert_contains "the worker gets the value" "$(cat "$STUB_LOG.spawn")" "--env DATABASE_URL=postgres://secret"
assert_not_contains "the run log never does" "$(rl replay r1)" "postgres://secret"
reset; mkrun 22 0 build '1 1 high, 0 medium, 0 low\n'
STUB_REPORT="issue 22 built head=abc1234 review=1 high, 0 medium, 0 low" run --wait
assert_contains "every later spawn re-passes it" "$(cat "$STUB_LOG.spawn")" "--env DATABASE_URL=postgres://secret"

echo "test: a clean fold whose post-fold check fails goes to the merger, merged but not recorded"
reset; mkrun 16 0 build ''
STUB_POSTFOLD_FAIL=1 STUB_REPORT="issue 16 built head=abc1234 review=0 high, 0 medium, 0 low" run --wait
assert_contains "handed to the merger with the check's message" "$OUT" "conflict #16 post-fold"
assert_contains "naming the failure" "$OUT" "two alembic heads"
assert_not_contains "and not logged merged" "$(state | grep '^merged=')" "16"
assert_equals "and parks it as post-fold (admission and other folds wait)" "$(cat "$CODEX_RUN_ROOT/r1/issue-16/paused")" "post-fold"
run --merged 16
assert_contains "--merged records it once the merger's fix is in" "$OUT" "merged #16"

echo "test: the post-fold hook runs without the run lock's fd 9"
reset; rl append r1 admitted '{"n":23,"tier":"x"}' >/dev/null; mkrun 23 0 build ''
STUB_FD9=1 STUB_REPORT="issue 23 built head=abc1234 review=0 high, 0 medium, 0 low" run --wait
assert_contains "no leak: it folded" "$OUT" "merged #23"

echo "test: a fold whose post-fold check cannot finish in this call is deferred, not merged and misread as a failure"
reset; rl append r1 admitted '{"n":24,"tier":"x"}' >/dev/null; mkrun 24 0 build ''
ORCH_BUDGET=30 STUB_REPORT="issue 24 built head=abc1234 review=0 high, 0 medium, 0 low" run --wait
assert_contains "deferred" "$OUT" "deferred #24"
assert_not_contains "no merge, no merger hand-off" "$OUT" "conflict #24"
assert_not_contains "and not logged merged" "$(state | grep '^merged=')" "24"
assert_equals "still unpaused, so the next call reports it again" "$(ls "$CODEX_RUN_ROOT/r1/issue-24" | grep -c '^paused$')" "0"
STUB_REPORT="issue 24 built head=abc1234 review=0 high, 0 medium, 0 low" run --wait
assert_contains "it folds on a call with a full budget" "$OUT" "merged #24"

echo "test: a capped report whose fold is deferred counts the cap once, however often it is re-reported"
reset; rl append r1 admitted '{"n":25,"tier":"x"}' >/dev/null; mkrun 25 0 build ''
for _ in 1 2; do ORCH_BUDGET=30 STUB_ESC="no-progress: review 3 has 1 high+medium" STUB_REPORT="issue 25 built head=abc1234 review=1 high, 0 medium, 0 low" run --wait; done
assert_contains "deferred" "$OUT" "deferred #25"
assert_equals "one escalated event" "$(rl replay r1 | jq -c 'select(.event == "escalated" and .n == 25)' | wc -l | tr -d ' ')" "1"

echo "test: a conflict pauses for the merger; --merged lands it"
reset; mkrun 19 0 build ''
STUB_REPORT="issue 19 built head=abc1234 review=0 high, 0 medium, 0 low" run --wait
assert_contains "19 merges" "$OUT" "merged #19"
reset; mkrun 20 0 build ''
STUB_REPORT="issue 20 built head=abc1234 review=0 high, 0 medium, 0 low" run --wait
assert_contains "20 conflicts, and the caller is told what to do" "$OUT" "conflict #20 f — spawn workflow:merger"
echo "test: while a merger holds the base branch a clean fold waits, and lands after --merged"
reset; mkrun 21 0 build ''
STUB_REPORT="issue 21 built head=abc1234 review=0 high, 0 medium, 0 low" run --wait
assert_contains "21 is queued behind the merger on #20" "$OUT" "queued #21 its fold waits for the merger on #20"
assert_not_contains "and is not merged" "$(state | grep "^merged=")" "21"
run --merged 20
assert_equals "--merged refuses an unmerged branch" "$RC" "1"
(cd "$ORCH_WT" && git merge -q -X theirs --no-edit issue-20 >/dev/null 2>&1)
run --merged 20
assert_contains "--merged logs it" "$OUT" "merged #20"
assert_contains "and lands the queued fold" "$OUT" "merged #21"
assert_contains "and the log agrees" "$(state)" "merged=11,12,14,16,19,20,21,23"

echo "test: a timeout says waiting; an unreadable report holds the issue"
reset
STUB_WR_ERR="error: timed out after 540s waiting" run --wait
assert_contains "waiting" "$OUT" "waiting:"
STUB_WR_ERR="error: issue 13 reported built but no independent review was recorded" run --wait
assert_contains "held with the reason" "$OUT" "held #13 no readable report"

echo "test: --retry lifts a hold: the old worker state is kept aside, the env carried over"
mkrun 13 0 build ''; printf 'K=V\0' >"$CODEX_RUN_ROOT/r1/issue-13/env"
run --retry 11; assert_equals "a slice that is not held is refused" "$RC" "1"
assert_contains "and says so" "$ERR" "not held"
run --retry 13
assert_contains "released" "$OUT" "released #13"
heldnow="$(state | sed -n 's/^held=//p')"
case ",$heldnow," in *,13,*) no "13 is still held ($heldnow)" ;; *) ok "no longer held" ;; esac
assert_equals "the previous worker's state is kept, not deleted" \
    "$(ls -d "$CODEX_RUN_ROOT"/r1/issue-13.held-* 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_equals "the provisioned env is carried to the fresh admission" "$(cat "$CODEX_RUN_ROOT/r1/issue-13/env" 2>/dev/null | tr '\0' '|')" "K=V|"
assert_equals "and nothing else (no stale exit to be re-reported)" "$(ls "$CODEX_RUN_ROOT/r1/issue-13")" "env"
run --retry; assert_equals "--retry needs an issue" "$RC" "1"

echo "test: --hold drops one paused in-flight issue and the run goes on"
run --hold 13; assert_equals "a slice that is not in flight is refused" "$RC" "1"
assert_contains "and says so" "$ERR" "not in flight"
rl append r1 admitted '{"n":13,"tier":"standard"}' >/dev/null
mkrun 13 0 build ''; printf 'blocked\n' >"$CODEX_RUN_ROOT/r1/issue-13/paused"
run --hold 13 infra: no redis
assert_contains "held with the operator's reason" "$OUT" "held #13 infra: no redis"
case " $(state | sed -n 's/^held=//p' | tr ',' ' ') " in *" 13 "*) ok "13 is held in the log" ;; *) no "13 is not held" ;; esac
assert_equals "its pause is cleared" "$(ls "$CODEX_RUN_ROOT/r1/issue-13" | grep -c '^paused$')" "0"
case " $(state | sed -n 's/^in_flight=//p' | tr ',' ' ') " in *" 13 "*) no "13 still takes a slot" ;; *) ok "its slot is free" ;; esac
run --retry 13; assert_contains "and --retry re-admits it later" "$OUT" "released #13"
run --hold; assert_equals "--hold needs an issue" "$RC" "1"

echo "test: everything in flight paused still admits what is ready"
git -C "$REPO" branch orchestrate-r2
GRAPH2="$WORK/graph2.json"
python3 - "$GRAPH2" <<'PY'
import json, sys
issues = [{"n": n, "title": "t%d" % n, "state": "open", "labels": ["ready-for-agent"], "tier": "standard",
           "body": "", "comments": "", "blockedBy": []} for n in (41, 42)]
json.dump({"issues": issues, "blockerStates": {}, "mockDebtOpen": []}, open(sys.argv[1], "w"))
PY
mkdir -p "$CODEX_RUN_ROOT/r2/issue-41"
sed -e 's/^RUNID=.*/RUNID=r2/' -e 's/^ORCH_BRANCH=.*/ORCH_BRANCH=orchestrate-r2/' -e "s|^GRAPH=.*|GRAPH=$GRAPH2|" -e 's/^MAX=.*/MAX=3/' \
    "$CODEX_RUN_ROOT/r1/run.env" >"$CODEX_RUN_ROOT/r2/run.env"
rl append r2 admitted '{"n":41,"tier":"standard"}' >/dev/null
printf 'blocked\n' >"$CODEX_RUN_ROOT/r2/issue-41/paused"
OUT="$(cd "$ORCH_WT" && bash "$WF/handle-report.sh" r2 --wait 2>/dev/null)"
assert_contains "the ready slice is started" "$OUT" "planning #42"
assert_contains "and the pause is still shown" "$OUT" "paused: #41 (blocked)"

echo "test: on a timeout, a STALLED running worker is escalated from outside"
reset; mkrun 15 0 build ''; rm -f "$CODEX_RUN_ROOT/r1/issue-15/exit"
live_leader; printf '%s\n' "$LEADER" >"$CODEX_RUN_ROOT/r1/issue-15/pid"
STUB_ESC_ONLY=15 STUB_WR_ERR="error: timed out after 240s waiting" STUB_ESC="stall: no event-log activity for 21 minutes" run --wait
assert_contains "escalated" "$OUT" "escalated #15 stall → attempt 1"
assert_contains "escalate.sh looked at the running worker" "$(cat "$STUB_LOG.esc")" "r1 15 standard"
if kill -0 "$LEADER" 2>/dev/null; then no "the stalled worker survived"; kill -- -"$LEADER" 2>/dev/null; else ok "the stalled worker was group-killed"; fi
assert_contains "and respawned in its role" "$(cat "$STUB_LOG.spawn")" "--role build --round 1 --attempt 1"
assert_contains "and what it left running was reaped by tag" "$(cat "$STUB_LOG.reap" 2>/dev/null)" "r1/15"

echo "test: a transient escalate.sh failure is retried, then reported — never a hold"
reset; mkrun 15 0 build '1 0 high, 0 medium, 0 low\n'
STUB_ESC_FAIL=1 STUB_REPORT="issue 15 built head=abc1234 review=0 high, 0 medium, 0 low" run --wait
assert_equals "retried once" "$(grep -c 'r1 15 ' "$STUB_LOG.esc")" "2"
assert_contains "an error line for the caller" "$OUT" "error: escalate.sh failed for #15"
assert_not_contains "never held" "$(state | sed -n 's/^held=//p')" "15"

echo "test: backstop on a FAILED report ends the issue — no respawn"
reset; mkrun 17 0 fix ''
STUB_ESC="backstop: 6 review rounds" STUB_REPORT="issue 17 failed tests red" run --wait
assert_contains "ended" "$OUT" "held #17 ended: backstop"
assert_equals "nothing respawned" "$(cat "$STUB_LOG.spawn")" ""

echo "test: a worker that already wrote exit is never killed — its pid may be recycled"
reset; mkrun 18 0 build '1 1 high, 0 medium, 0 low\n'
live_leader; printf '%s\n' "$LEADER" >"$CODEX_RUN_ROOT/r1/issue-18/pid"
STUB_ESC="review-cap: still 1 high" STUB_REPORT="issue 18 built head=abc1234 review=1 high, 0 medium, 0 low" run --wait
if kill -0 "$LEADER" 2>/dev/null; then ok "the unrelated process lives"; kill -- -"$LEADER" 2>/dev/null; else no "a recycled pid was killed"; fi
assert_contains "and the respawn still happened" "$OUT" "escalated #18 review-cap"

echo "test: the timeout scan dry-runs first, skips finished workers, and never errors"
reset; mkrun 15 1 build ''   # finished: exit present
STUB_ESC="review-cap: still 1 high" STUB_WR_ERR="error: timed out" run --wait
assert_not_contains "a finished worker is left for the next --wait to report" "$(cat "$STUB_LOG.esc")" "r1 15 "
reset; mkrun 15 1 build ''; rm -f "$CODEX_RUN_ROOT/r1/issue-15/exit"
STUB_ESC_ONLY=15 STUB_ESC="review-cap: still 1 high" STUB_WR_ERR="error: timed out" run --wait
assert_contains "a running worker is checked with --dry-run" "$(cat "$STUB_LOG.esc")" "--attempt 1 --dry-run"
assert_equals "and a non-runtime signal is never run for real" "$(grep -c 'r1 15 ' "$STUB_LOG.esc")" "1"
assert_contains "so it only waits" "$OUT" "waiting:"
reset; mkrun 15 1 build ''; rm -f "$CODEX_RUN_ROOT/r1/issue-15/exit"
STUB_ESC_FAIL=1 STUB_WR_ERR="error: timed out" run --wait
assert_not_contains "a failed scan is not an error line" "$OUT" "error:"

echo "test: a decide that cannot finish in this call is a real deferral"
reset; mkrun 15 1 fix '1 0 high, 1 medium, 0 low\n2 0 high, 1 medium, 0 low\n'
printf '1\t2\tsrc/a.py\n' >"$CODEX_RUN_ROOT/r1/issue-15/recurrence"
ORCH_BUDGET=50 STUB_ESC="recurrence: src/a.py" STUB_REPORT="issue 15 fixed round=1 head=abc1234 review=0 high, 1 medium, 0 low" run --wait
assert_contains "deferred" "$OUT" "deferred #15 its decide did not finish"
assert_equals "no fix round without the decision" "$(cat "$STUB_LOG.spawn")" ""
assert_equals "and the fire is un-spent so it is asked again" "$(cat "$CODEX_RUN_ROOT/r1/issue-15/recurrence")" ""

echo "test: a deferral is bounded — past the limit the consult runs without a budget"
reset; mkrun 15 1 fix '1 0 high, 1 medium, 0 low\n2 0 high, 1 medium, 0 low\n'
printf '2\n' >"$CODEX_RUN_ROOT/r1/issue-15/deferrals"
ORCH_BUDGET=50 STUB_ESC="recurrence: src/a.py" STUB_REPORT="issue 15 fixed round=1 head=abc1234 review=0 high, 1 medium, 0 low" run --wait
assert_contains "the decide ran" "$OUT" "decided #15"
assert_contains "and the fix round followed" "$(cat "$STUB_LOG.spawn")" "--role fix"
if [ -e "$CODEX_RUN_ROOT/r1/issue-15/deferrals" ]; then no "the count was not reset"; else ok "a finished consult resets the count"; fi

echo "test: past the cap a consult is still hard-capped, and a hung one holds the issue"
reset; mkrun 18 1 build ''
printf '2\n' >"$CODEX_RUN_ROOT/r1/issue-18/deferrals"
CONSULT_TIMEOUT=1 STUB_CONSULT_SLEEP=5 STUB_REPORT="issue 18 escalate deviation: step 1" run --wait
assert_contains "held, not deferred again" "$OUT" "held #18 consult timed out after 1s"
assert_not_contains "and nothing resumed" "$(cat "$STUB_LOG.resume")" " 18 "

echo "test: a plan that finished while workers run is collected on the timeout"
reset; mkdir -p "$CODEX_RUN_ROOT/r1/plans"; printf '1\n' >"$CODEX_RUN_ROOT/r1/plans/30.rc"; : >"$CODEX_RUN_ROOT/r1/plans/30.started"
STUB_WR_ERR="error: timed out" run --wait
assert_contains "collected (held here: the stub plan failed)" "$OUT" "held #30 plan failed"

echo "test: the human's input is never dropped on a busy run"
(exec 9>"$CODEX_RUN_ROOT/r1/.lock"; flock 9; sleep 3) &
sleep 0.5
OUT="$(cd "$ORCH_WT" && ORCH_LOCK_WAIT=0 bash "$WF/handle-report.sh" r1 --answer 21 "x" 2>&1)"; RC=$?
assert_equals "exit 1" "$RC" "1"
assert_contains "an error to retry, not waiting:" "$OUT" "error: run r1 is busy"
wait

echo "test: one call at a time per run"
reset; mkrun 12 0 build ''
(STUB_WR_SLEEP=3 STUB_WR_ERR="error: timed out" bash "$WF/handle-report.sh" r1 --wait >/dev/null 2>&1 &)
sleep 1
OUT="$(cd "$ORCH_WT" && ORCH_LOCK_WAIT=0 bash "$WF/handle-report.sh" r1 --wait 2>/dev/null)"
assert_contains "the second call waits its turn" "$OUT" "waiting: another admit.sh or handle-report.sh is still running"
sleep 3

echo "test: failure at the top of the chain drains the run"
reset; mkrun 16 0 build ''
STUB_ESC="failed: the worker exited 3" STUB_REPORT="issue 16 failed done-check red" run --wait
assert_contains "drain" "$OUT" "drain: #16 failed at the top of its chain"
assert_equals "nothing respawned" "$(cat "$STUB_LOG.spawn")" ""
assert_contains "the drain is a recorded decision" "$(state)" "decision=drain: #16"
assert_not_contains "admit.sh admits nothing after a drain, even with #30 unblocked" \
    "$(cd "$ORCH_WT" && bash "$WF/admit.sh" r1 --next)" "admitted"

echo "test: --max rewrites the run's cap (it is read fresh by every admission)"
run --max 0; assert_equals "0 is refused" "$RC" "1"
run --max abc; assert_equals "junk is refused" "$RC" "1"
run --max 2
assert_contains "reports the change" "$OUT" "max 2 (was 1)"
assert_contains "run.env carries it" "$(cat "$CODEX_RUN_ROOT/r1/run.env")" "MAX=2"
run --max 1
assert_contains "and back" "$(cat "$CODEX_RUN_ROOT/r1/run.env")" "MAX=1"

echo "test: a worker that finished with no readable report is escalated, not held, while the chain has a next cell"
reset; mkrun 21 0 build ''
STUB_WR_ERR="error: issue 21 finished clean but wrote no report to last-message.txt" run --wait
assert_contains "escalated to the next cell" "$OUT" "escalated #21 failed → attempt 1"
assert_contains "respawned there" "$(cat "$STUB_LOG.spawn")" "r1 21 standard $REPO/.worktrees/r1/issue-21 orchestrate-r1 --role build --round 1 --attempt 1"
reset; mkrun 21 1 build ''
STUB_WR_ERR="error: issue 21 wrote an unreadable report (bad json): x" run --wait
assert_contains "at the top of the chain it is held, as before" "$OUT" "held #21 no readable report"
assert_not_contains "and never drains the run for a report glitch" "$OUT" "drain:"

echo "test: a hold keeps a stopped worker's work on a prev/ branch, uncommitted files included"
reset; mkrun 22 0 build ''
printf 'wip\n' >"$REPO/.worktrees/r1/issue-22/dirty"
HEAD22="$(git -C "$REPO" rev-parse issue-22)"
STUB_WR_ERR="error: issue 22 reported built but no independent review was recorded" run --wait
assert_contains "held" "$OUT" "held #22 no readable report"
assert_contains "and says where the work is" "$OUT" "prev/issue-22-r1"
assert_equals "the dirty file was committed onto the salvage branch" \
    "$(git -C "$REPO" show prev/issue-22-r1:dirty 2>/dev/null)" "wip"
assert_equals "the worker's own commit is on it too" \
    "$(git -C "$REPO" show prev/issue-22-r1:f22 2>/dev/null)" "22"
assert_equals "issue-22 itself did not move — a retry never inherits a WIP commit" \
    "$(git -C "$REPO" rev-parse issue-22)" "$HEAD22"
assert_equals "and the worktree's own state is untouched" \
    "$(git -C "$REPO/.worktrees/r1/issue-22" status --porcelain | tr -d ' ')" "??dirty"

echo "test: a worktree holding a nested repo is not salvaged — its config would run on the host"
reset; mkrun 21 1 build ''
git -C "$REPO" branch -D prev/issue-21-r1 >/dev/null 2>&1
NEST="$REPO/.worktrees/r1/issue-21/sub"
mkdir -p "$NEST" && git -C "$NEST" init -q
printf '[filter "x"]\n\tclean = touch %s/canary\n' "$WORK" >>"$NEST/.git/config"
printf '* filter=x\n' >"$NEST/.gitattributes"; printf 'a\n' >"$NEST/a"
STUB_WR_ERR="error: issue 21 reported built but no independent review was recorded" run --wait
assert_contains "held" "$OUT" "held #21"
if git -C "$REPO" rev-parse --verify -q prev/issue-21-r1 >/dev/null; then no "a worktree with a nested repo was salvaged"; else ok "no salvage branch"; fi
if [ -e "$WORK/canary" ]; then no "the nested repo's filter ran on the host"; else ok "the nested repo's filter never ran"; fi
rm -rf "$NEST"

echo "test: a nested repo under a deep node_modules is not salvaged either"
reset; mkrun 21 1 build ''
NEST="$REPO/.worktrees/r1/issue-21/sub/node_modules/x"
mkdir -p "$NEST" && git -C "$NEST" init -q
printf 'a\n' >"$NEST/a"
STUB_WR_ERR="error: issue 21 reported built but no independent review was recorded" run --wait
if git -C "$REPO" rev-parse --verify -q prev/issue-21-r1 >/dev/null; then no "a deep node_modules repo was salvaged"; else ok "no salvage branch"; fi
rm -rf "$REPO/.worktrees/r1/issue-21/sub"

echo "test: a committed gitlink is not salvaged"
reset; mkrun 21 1 build ''
git -C "$REPO/.worktrees/r1/issue-21" update-index --add --cacheinfo 160000,"$(git -C "$REPO" rev-parse HEAD)",0vendored
# A listing past the pipe buffer, all after the gitlink: a `ls-tree | grep -q` would SIGPIPE.
mkdir "$REPO/.worktrees/r1/issue-21/many"
for i in $(seq 1 2500); do : >"$REPO/.worktrees/r1/issue-21/many/a-long-file-name-to-fill-the-pipe-buffer-$i"; done
git -C "$REPO/.worktrees/r1/issue-21" add many
git -C "$REPO/.worktrees/r1/issue-21" commit -q -m "gitlink"
STUB_WR_ERR="error: issue 21 reported built but no independent review was recorded" run --wait
if git -C "$REPO" rev-parse --verify -q prev/issue-21-r1 >/dev/null; then no "a worktree with a gitlink was salvaged"; else ok "no salvage branch"; fi
git -C "$REPO/.worktrees/r1/issue-21" reset -q --hard HEAD~1

echo "test: a still-running worker is never touched by a salvage"
reset; mkrun 17 0 build ''; rm -f "$CODEX_RUN_ROOT/r1/issue-17/exit"
git -C "$REPO" branch -D prev/issue-17-r1 >/dev/null 2>&1   # left by an earlier hold of #17
live_leader; printf '%s\n' "$LEADER" >"$CODEX_RUN_ROOT/r1/issue-17/pid"
printf 'wip\n' >"$REPO/.worktrees/r1/issue-17/dirty"
STUB_WR_ERR="error: issue 17 reported built but no independent review was recorded" run --wait
kill -- -"$LEADER" 2>/dev/null
assert_contains "still held" "$OUT" "held #17"
if git -C "$REPO" rev-parse --verify -q prev/issue-17-r1 >/dev/null; then no "a live worker's work was salvaged"; else ok "no salvage branch for a live worker"; fi
assert_equals "its dirty file is still uncommitted" "$(git -C "$REPO/.worktrees/r1/issue-17" status --porcelain | tr -d ' ')" "??dirty"

echo "test: --retry refuses an issue whose fold was merged and then reverted"
rl append r1 admitted '{"n":51,"tier":"standard"}' >/dev/null; rl append r1 held '{"n":51,"why":"merger stopped"}' >/dev/null
run --retry 51; assert_contains "a hold with no fold on the run branch is released" "$OUT" "released #51"
rl append r1 held '{"n":51,"why":"merger stopped"}' >/dev/null
git -C "$REPO" branch issue-51 orchestrate-r1
git -C "$ORCH_WT" commit -q --allow-empty -m "Merge branch 'issue-51' into orchestrate-r1"
run --retry 51; assert_equals "refused once its fold is on the run branch" "$RC" "1"
assert_contains "and says why" "$ERR" "folded into orchestrate-r1 and then reverted"
git -C "$REPO" branch -q -D issue-51
run --retry 51; assert_contains "deleting issue-51 (the remedy it names) lifts the refusal" "$OUT" "released #51"

echo "test: bad usage fails loud"
run; assert_equals "no mode" "$RC" "1"
run --answer 21; assert_equals "no answer" "$RC" "1"
run --resource 22 DATABASE_URL=x; assert_equals "pairs need --env" "$RC" "1"
OUT="$(bash "$WF/handle-report.sh" nope --wait 2>&1)"; assert_contains "unlaunched run" "$OUT" "no launched run"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
