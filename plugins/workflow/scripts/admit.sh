#!/usr/bin/env bash
#
# admit.sh — admit scoped issues into a launched /orchestrate run.
#
# Usage:
#   bash admit.sh <runid> <N>        # admit one issue
#   bash admit.sh <runid> --next     # collect finished plans, then fill every free slot
#
# Admitting an issue: cut its worktree (`issue-<N>` off the orchestration branch, at
# <repo>/.worktrees/<runid>/issue-<N>); a trivial issue is spawned at once (spawn.sh,
# attempt 0, run-log `admitted`). A standard or complex one first needs a **Plan**:
# consult.sh runs DETACHED (its own process group, PLAN_TIMEOUT cap, default 30 min) and
# this call returns — an opus plan outlasts any Bash call. Each later pass COLLECTS finished
# plans: exit 0 → run-log `planned`, spawn, `admitted`; anything else → `held` (nothing is
# ever spawned onto an issue with no plan). A planning issue holds its slot and counts as in
# flight for ready.sh, so it is never admitted twice.
#
# One call at a time per run (run_lock). An existing issue-<N> worktree is reused; an
# existing issue-<N> BRANCH is reused only when it grew from this run's base — a stale one
# from an earlier run is held, never built on.
#
# --next first refreshes blocker states (refresh-blockers.sh), then reads merged / held / in-flight from run-log.sh and asks ready.sh what is
# admissible; readiness is never computed here. A recorded drain (`decision` "drain: …")
# stops all admission (finished plans are still collected, never spawned).
#
# Output, one line per outcome:
#   admitted #N tier=<t> attempt=0      planning #N tier=<t>      held #N <why>
# then exactly one of:
#   in-flight: 12,13            something is running (workers, or plans with planning: …)
#   waiting: planning #N …      only plans are running — call again
#   nothing-to-do: <why>        nothing running and nothing admissible (ready.sh's reason)
#   error: <why>                ready.sh's unexplained empty — stop and report (exit 1)

set -uo pipefail
# shellcheck source=run-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-env.sh"

[ $# -eq 2 ] || die "usage: admit.sh <runid> <N> | admit.sh <runid> --next"
load_run "$1"
run_lock
TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "${TMP:?}"' EXIT
PLANS="$RUN_DIR/plans"
mkdir -p "$PLANS" || die "cannot create $PLANS"

hold() {
    runlog append "$RUNID" held "$(jq -cn --argjson n "$1" --arg why "$2" '{n: $n, why: $why}')" >/dev/null
    echo "held #$1 $2"
}

# prepare <N> — validate and cut (or reuse) the worktree. Prints a held line on failure.
prepare() {
    local n="$1" wt
    [ -n "$(tier_of "$n")" ] || { hold "$n" "no tier in the graph (not in scope?)"; return 1; }
    wt="$(worktree_of "$n")"
    if [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "issue-$n" ]; then return 0; fi
    if git -C "$BASE_REPO" show-ref --verify --quiet "refs/heads/issue-$n"; then
        git -C "$BASE_REPO" merge-base --is-ancestor "$BASE_SHA" "issue-$n" 2>/dev/null \
            || { hold "$n" "a stale issue-$n branch from an earlier run exists — delete or rename it"; return 1; }
        git -C "$BASE_REPO" worktree add -q "$wt" "issue-$n" >/dev/null 2>"$TMP/wt-$n.err"
    else
        git -C "$BASE_REPO" worktree add -q -b "issue-$n" "$wt" "$ORCH_BRANCH" >/dev/null 2>"$TMP/wt-$n.err"
    fi || { hold "$n" "worktree: $(tail -1 "$TMP/wt-$n.err")"; return 1; }
}

spawn_now() {   # spawn_now <N> — attempt 0, logged; 1 when it was held instead
    spawn_issue "$1" build 1 0 2>"$TMP/spawn-$1.err" </dev/null \
        || { hold "$1" "spawn failed: $(tail -1 "$TMP/spawn-$1.err")"; return 1; }
    runlog append "$RUNID" admitted "{\"n\":$1,\"tier\":\"$(tier_of "$1")\"}" >/dev/null
    echo "admitted #$1 tier=$(tier_of "$1") attempt=0"
}

# start <N> — prepare, then spawn (trivial) or start the detached plan. Fails when the issue
# was held instead: a held pick must not use up a slot.
start() {
    local n="$1" tier
    prepare "$n" || return
    tier="$(tier_of "$n")"
    if [ "$tier" = trivial ]; then spawn_now "$n"; return; fi
    rm -f "$PLANS/$n.rc" "$PLANS/$n.out" "$PLANS/$n.err"
    : >"$PLANS/$n.started"
    # Detached: its own group (set -m), no stdin, and fd 9 (the run lock) closed, so it
    # neither blocks the next call nor dies with this one.
    ( set -m; nohup bash -c 'timeout "$1" bash "$2" plan "$3" "$4" "$5" "$6" >"$7.out" 2>"$7.err" </dev/null
                             echo $? >"$7.rc.tmp" && mv -f "$7.rc.tmp" "$7.rc"' _ "${PLAN_TIMEOUT:-1800}" "$INFRA/consult.sh" \
        "$RUNID" "$n" "$tier" "$(worktree_of "$n")" "$PLANS/$n" </dev/null >/dev/null 2>&1 9>&- & )
    echo "planning #$n tier=$tier"
}

# collect — every finished plan becomes a spawn or a hold. A good plan needs a free worker
# slot: when --max was lowered under it, it waits (`.rc.deferred`, still counted as planning)
# and is looked at again on the next pass.
collect() {
    local f n rc live
    live="$(run_state in_flight | wc -w)"
    for f in "$PLANS"/*.rc.deferred; do [ -e "$f" ] && mv -f "$f" "${f%.deferred}"; done
    for f in "$PLANS"/*.rc; do
        [ -e "$f" ] || continue
        n="$(basename "$f" .rc)"; rc="$(head -1 "$f")"
        if [ -n "$DRAIN" ]; then
            hold "$n" "plan finished after the drain — not spawned"
        elif [ "$rc" = 0 ]; then
            if [ "$live" -ge "$MAX" ]; then mv -f "$f" "$f.deferred"; continue; fi
            runlog append "$RUNID" planned "{\"n\":$n}" >/dev/null
            ! spawn_now "$n" || live=$((live + 1))
        elif [ "$rc" = 124 ]; then
            hold "$n" "plan timed out after ${PLAN_TIMEOUT:-1800}s"
        else
            hold "$n" "plan failed: $(tail -1 "$PLANS/$n.err" 2>/dev/null)"
        fi
        rm -f "$PLANS/$n".*
    done
}

planning() { for f in "$PLANS"/*.started; do [ -e "$f" ] && basename "$f" .started; done; }

final_line() {
    local f p
    f="$(run_state in_flight | xargs)"; p="$(planning | xargs)"
    if [ -n "$f" ]; then
        echo "in-flight: ${f// /,}${p:+ planning: ${p// /,}}"
    elif [ -n "$p" ]; then
        echo "waiting: planning #${p// /, #} — call handle-report.sh $RUNID --wait again"
    else
        return 1
    fi
}

STATE="$(runlog state "$RUNID" 2>/dev/null)"
DRAIN="$(printf '%s\n' "$STATE" | sed -n 's/^decision=\(drain: .*\)$/\1/p' | head -1)"
collect

if [ "$2" != --next ]; then
    N="${2#\#}"
    case "$N" in ''|*[!0-9]*) die "issue must be a number, got '$2'" ;; esac
    case " $(run_state in_flight) $(run_state merged) $(planning | xargs) " in
        *" $N "*) die "#$N is already admitted" ;;
    esac
    start "$N"
    final_line
    exit 0
fi

if [ -n "$DRAIN" ]; then
    final_line || echo "nothing-to-do: drained ($DRAIN)"
    exit 0
fi

bash "$WF/refresh-blockers.sh" "$GRAPH" "$BASE_REPO" 2>/dev/null   # blockers can close mid-run
ARGS=()
for n in $(run_state merged);                   do ARGS+=(--merged "$n"); done
for n in $(run_state held);                     do ARGS+=(--held "$n"); done
for n in $(run_state in_flight) $(planning);    do ARGS+=(--in-flight "$n"); done
[ -z "${SKIP_UNKNOWN:-}" ] || ARGS+=(--skip-unknown)
READY="$(bash "$WF/ready.sh" "$GRAPH" ${ARGS[@]+"${ARGS[@]}"} 2>"$TMP/ready.err")"; RC=$?
WHY="$(head -1 "$TMP/ready.err")"
if [ "$RC" -ne 0 ]; then
    final_line
    echo "${WHY:-error: ready.sh failed}"
    exit 1
fi

BUSY=0
for n in $(run_state in_flight) $(planning); do BUSY=$((BUSY + 1)); done
for n in $READY; do
    [ "$BUSY" -lt "$MAX" ] || break
    ! start "$n" || BUSY=$((BUSY + 1))
done
# Every pick held and nothing running: the next pass sees them held and may find others.
# It terminates — each pass holds at least one more issue or starts one.
if ! final_line; then
    if [ -n "$READY" ]; then
        rm -rf "${TMP:?}"
        exec bash "$0" "$RUNID" --next
    fi
    echo "${WHY:-nothing-to-do: nothing admissible}"
fi
