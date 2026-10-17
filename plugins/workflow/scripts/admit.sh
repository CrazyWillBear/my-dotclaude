#!/usr/bin/env bash
#
# admit.sh — admit scoped issues into a launched /orchestrate run.
#
# Usage:
#   bash admit.sh <runid> <N>        # admit one issue
#   bash admit.sh <runid> --next     # fill every free slot (MAX − in flight) from ready.sh
#
# Admitting an issue: cut its worktree (`issue-<N>` off the orchestration branch, at
# <repo>/.worktrees/<runid>/issue-<N>); for standard and complex, consult.sh posts the
# **Plan** (a failed plan is logged `held` and NOTHING is spawned onto an issue with no
# plan); then spawn.sh at attempt 0, and run-log `admitted`. Worktrees are cut one at a
# time (git's ref locks), the plans and spawns run in parallel — one opus plan per issue
# is minutes, and Bash calls are capped at ten.
#
# --next reads merged / held / in-flight from run-log.sh and asks ready.sh what is
# admissible; readiness is never computed here. A recorded drain (`decision` "drain: …")
# stops all admission.
#
# Output, one line per outcome:
#   admitted #N tier=<t> attempt=0
#   held #N <why>
# then exactly one of:
#   in-flight: 12,13            something is running
#   nothing-to-do: <why>        nothing running and nothing admissible (ready.sh's reason)
#   error: <why>                ready.sh's unexplained empty — stop and report (exit 1)

set -uo pipefail
# shellcheck source=run-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-env.sh"

[ $# -eq 2 ] || die "usage: admit.sh <runid> <N> | admit.sh <runid> --next"
load_run "$1"
TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

# prepare <N> — the sequential half: validate and cut the worktree. Prints a held line on failure.
prepare() {
    local n="$1" wt
    [ -n "$(tier_of "$n")" ] || { hold "$n" "no tier in the graph (not in scope?)"; return 1; }
    wt="$(worktree_of "$n")"
    git -C "$BASE_REPO" worktree add -q -b "issue-$n" "$wt" "$ORCH_BRANCH" >/dev/null 2>"$TMP/wt-$n.err" \
        || { hold "$n" "worktree: $(tail -1 "$TMP/wt-$n.err")"; return 1; }
}

# launch <N> — the parallel half: plan (non-trivial), spawn, log.
launch() {
    local n="$1" tier
    tier="$(tier_of "$n")"
    if [ "$tier" != trivial ]; then
        if ! bash "$INFRA/consult.sh" plan "$RUNID" "$n" "$tier" "$(worktree_of "$n")" \
                >"$TMP/plan-$n.out" 2>"$TMP/plan-$n.err" </dev/null; then
            hold "$n" "plan failed: $(tail -1 "$TMP/plan-$n.err")"; return
        fi
        runlog append "$RUNID" planned "{\"n\":$n}" >/dev/null
    fi
    spawn_issue "$n" build 1 0 2>"$TMP/spawn-$n.err" </dev/null \
        || { hold "$n" "spawn failed: $(tail -1 "$TMP/spawn-$n.err")"; return; }
    runlog append "$RUNID" admitted "{\"n\":$n,\"tier\":\"$tier\"}" >/dev/null
    echo "admitted #$n tier=$tier attempt=0"
}

hold() {
    runlog append "$RUNID" held "$(jq -cn --argjson n "$1" --arg why "$2" '{n: $n, why: $why}')" >/dev/null
    echo "held #$1 $2"
}

admit_all() {   # admit_all <N>... — prepare in order, launch in parallel, print in order
    local n ok=()
    for n in "$@"; do prepare "$n" && ok+=("$n"); done
    for n in ${ok[@]+"${ok[@]}"}; do launch "$n" >"$TMP/out-$n" & done
    wait
    for n in ${ok[@]+"${ok[@]}"}; do cat "$TMP/out-$n"; done
}

in_flight_line() {
    local f
    f="$(run_state in_flight)"
    [ -n "${f// /}" ] && echo "in-flight: $(printf '%s' "$f" | xargs | tr ' ' ',')"
}

if [ "$2" != --next ]; then
    N="${2#\#}"
    case "$N" in ''|*[!0-9]*) die "issue must be a number, got '$2'" ;; esac
    case " $(run_state in_flight) $(run_state merged) " in *" $N "*) die "#$N is already admitted" ;; esac
    admit_all "$N"
    in_flight_line
    exit 0
fi

STATE="$(runlog state "$RUNID" 2>/dev/null)"
DRAIN="$(printf '%s\n' "$STATE" | sed -n 's/^decision=\(drain: .*\)$/\1/p' | head -1)"
if [ -n "$DRAIN" ]; then
    in_flight_line || echo "nothing-to-do: drained ($DRAIN)"
    exit 0
fi

ARGS=()
for n in $(run_state merged);    do ARGS+=(--merged "$n"); done
for n in $(run_state held);      do ARGS+=(--held "$n"); done
for n in $(run_state in_flight); do ARGS+=(--in-flight "$n"); done
[ -z "${SKIP_UNKNOWN:-}" ] || ARGS+=(--skip-unknown)
READY="$(bash "$WF/ready.sh" "$GRAPH" ${ARGS[@]+"${ARGS[@]}"} 2>"$TMP/ready.err")"; RC=$?
WHY="$(head -1 "$TMP/ready.err")"
if [ "$RC" -ne 0 ]; then
    in_flight_line
    echo "${WHY:-error: ready.sh failed}"
    exit 1
fi

INFLIGHT=0
for n in $(run_state in_flight); do INFLIGHT=$((INFLIGHT + 1)); done
SLOTS=$((MAX - INFLIGHT))
PICK=()
for n in $READY; do
    [ "${#PICK[@]}" -lt "$SLOTS" ] || break
    PICK+=("$n")
done
[ "${#PICK[@]}" -eq 0 ] || admit_all "${PICK[@]}"
# Every pick held and nothing running: the next pass sees them held and may find others.
# It terminates — each pass holds at least one more issue or admits one.
if [ "${#PICK[@]}" -gt 0 ] && [ -z "$(run_state in_flight | tr -d ' ')" ]; then
    exec bash "$0" "$RUNID" --next
fi
in_flight_line || echo "${WHY:-nothing-to-do: nothing admissible}"
