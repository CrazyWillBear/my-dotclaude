#!/usr/bin/env bash
#
# handle-report.sh — wait for the next worker report and act on it, by table.
#
# Usage:
#   bash handle-report.sh <runid> --wait                    # block (≤ ~9 min) for the next report
#   bash handle-report.sh <runid> --merged <N>              # the merger landed issue-<N>
#   bash handle-report.sh <runid> --answer <N> <text>       # a human answered #N's question
#   bash handle-report.sh <runid> --resource <N> --env K=V…  # a human provisioned #N's resource
#
# --wait blocks in worker-report.sh --any (≤ HANDLE_WAIT_TIMEOUT, default 240 s) on the
# in-flight workers (run-log.sh) that are not PAUSED on a human or a merger. On a timeout it
# runs escalate.sh on every worker still running — a stall or a full context is only visible
# from outside — acts on what fires, and otherwise prints `waiting: …`; the caller calls it
# again. One call at a time per run (run_lock), inside a wall-clock budget: a plan or consult
# that would cross it is deferred to the next call, never turned into a hold. A report is
# then handled:
#
#   report                     escalate.sh says         action
#   built/fixed, 0 high+med    (nothing)                fold it in (merge-fold.sh) → merged / conflict
#   built/fixed, findings      (nothing)                fix round, same attempt
#   built/fixed                recurrence: <area>       consult.sh decide, then the fix round
#   built/fixed                no-progress: / backstop: log escalated; fold it in CAPPED → follow-up.sh
#   any                        any other reason         group-kill, log escalated, respawn at the next
#                                                       chain position (quota: the first claude cell);
#                                                       past the top: DRAIN
#   escalate deviation: …      (nothing)                consult.sh consult, then worker-resume.sh
#   escalate <question>        (nothing)                PAUSE — printed for the human (--answer)
#   blocked infra: <what>      (nothing)                PAUSE — printed for the human (--resource)
#
# Then admit.sh --next refills the freed slots. A drain logs `decision` "drain: …" and
# admit.sh stops admitting; the run ends when nothing is in flight.
#
# Every outcome is ONE line; the caller acts only on: escalate/blocked (relay to the human),
# conflict (spawn workflow:merger, then --merged), and error:. Exit 0 except on bad usage.

set -uo pipefail
# shellcheck source=run-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-env.sh"

USAGE="usage: handle-report.sh <runid> --wait | --merged N | --answer N <text> | --resource N --env K=V..."
[ $# -ge 2 ] || die "$USAGE"
load_run "$1"; shift
MODE="$1"; shift
run_lock
TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

hold() {
    runlog append "$RUNID" held "$(jq -cn --argjson n "$1" --arg why "$2" '{n: $n, why: $why}')" >/dev/null
    echo "held #$1 $2"
}
drain() {
    runlog append "$RUNID" held "$(jq -cn --argjson n "$1" --arg why "drained: $2" '{n: $n, why: $why}')" >/dev/null
    runlog append "$RUNID" decision "$(jq -cn --arg w "drain: #$1 $2" '{what: $w}')" >/dev/null
    echo "drain: #$1 $2"
}
pause() { printf '%s\n' "$2" >"$(issue_dir "$1")/paused"; }
unpause() { rm -f "$(issue_dir "$1")/paused"; }
capped() {
    runlog replay "$RUNID" 2>/dev/null | jq -e --argjson n "$1" \
        'select(.event == "escalated" and .n == $n and (.reason == "no-progress" or .reason == "backstop"))' \
        >/dev/null 2>&1
}

# kill_worker <N> — group-kill the wrapper (it leads its own group), bounded wait.
kill_worker() {
    local pid
    # A worker that wrote `exit` is gone; its pid may already belong to someone else.
    [ ! -e "$(issue_dir "$1")/exit" ] || return 0
    pid="$(head -1 "$(issue_dir "$1")/pid" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    kill -0 "$pid" 2>/dev/null || return 0
    [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$pid" ] || return 1
    kill -- -"$pid" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || return 0; sleep 2; done
    kill -9 -- -"$pid" 2>/dev/null; sleep 1
    ! kill -0 "$pid" 2>/dev/null
}

# escalate_to_next <N> <reason> <detail> <attempt> <role> <round>
escalate_to_next() {
    local n="$1" reason="$2" detail="$3" a="$4" role="$5" round="$6" tier chain next b
    [ "$role" = fix ] || { role=build; round=1; }
    tier="$(tier_of "$n")"
    kill_worker "$n" || { hold "$n" "could not stop the worker (pid not a live group leader) — not respawning onto its worktree"; return; }
    runlog append "$RUNID" escalated "$(jq -cn --argjson n "$n" --arg r "$reason" --argjson a "$a" '{n: $n, reason: $r, attempt: $a}')" >/dev/null
    chain="$(bash "$INFRA/resolve-tier.sh" "$tier" 0 2>/dev/null | sed -n 's/^implementer_chain=//p')"
    next=$((a + 1))
    if [ "$reason" = quota ]; then
        # Every codex model shares the quota: skip to the first claude cell, if any.
        while [ "$next" -lt "${chain:-1}" ]; do
            b="$(bash "$INFRA/resolve-tier.sh" "$tier" "$next" 2>/dev/null | sed -n 's/^implementer_backend=//p')"
            [ "$b" = claude ] && break
            next=$((next + 1))
        done
    fi
    if [ "$next" -ge "${chain:-1}" ]; then
        drain "$n" "$reason at the top of its chain: $detail"; return
    fi
    spawn_issue "$n" "$role" "$round" "$next" 2>"$TMP/spawn.err" \
        || { drain "$n" "respawn failed: $(tail -1 "$TMP/spawn.err")"; return; }
    echo "escalated #$n $reason → attempt $next"
}

follow_up() {
    local n="$1" dep
    if bash "$WF/follow-up.sh" "$RUNID" "$n" "$(tier_of "$n")" "$GRAPH" >"$TMP/fu.out" 2>"$TMP/fu.err"; then
        cat "$TMP/fu.out"; tail -1 "$TMP/fu.err" | grep '^follow-up: .*nothing filed' || true
    else
        echo "follow-up failed #$n: $(tail -1 "$TMP/fu.err")"
        for dep in $(jq -r --argjson n "$n" '.issues[] | select((.blockedBy // []) | index($n)) | .n' "$GRAPH"); do
            hold "$dep" "follow-up for #$n failed"
        done
    fi
}

# fold <N> — land issue-<N> on the orchestration branch with plain git, or hand it to the merger.
fold() {
    local n="$1" out
    out="$(cd "$ORCH_WT" && bash "$WF/merge-fold.sh" --allow-behind "$ORCH_BRANCH" "issue-$n" 2>&1)"
    case "$(printf '%s\n' "$out" | awk -v b="issue-$n" '$2 == b {print $1; exit}')" in
        merged)
            local sha; sha="$(printf '%s\n' "$out" | awk -v b="issue-$n" '$1 == "merged" && $2 == b {print $3}')"
            unpause "$n"
            runlog append "$RUNID" merged "$(jq -cn --argjson n "$n" --arg s "$sha" '{n: $n, sha: $s}')" >/dev/null
            echo "merged #$n ${sha:0:7}"
            ! capped "$n" || follow_up "$n" ;;
        conflict)
            pause "$n" conflict
            echo "conflict #$n $(printf '%s\n' "$out" | awk -v b="issue-$n" '$1 == "conflict" && $2 == b {print $3}') — spawn workflow:merger for issue-$n into $ORCH_BRANCH in $ORCH_WT, then: handle-report.sh $RUNID --merged $n" ;;
        *)
            hold "$n" "fold failed: $(printf '%s' "$out" | tail -1)" ;;
    esac
}

escalate() {   # escalate <N> <tier> <worktree> <attempt> — escalate.sh, retried once
    bash "$INFRA/escalate.sh" "$RUNID" "$1" "$2" "$3" --base "$ORCH_BRANCH" --attempt "$4" 2>"$TMP/esc.err" && return
    sleep "${HANDLE_RETRY_SLEEP:-5}"
    bash "$INFRA/escalate.sh" "$RUNID" "$1" "$2" "$3" --base "$ORCH_BRANCH" --attempt "$4" 2>"$TMP/esc.err"
}

# timed <consult args…> — consult.sh inside what is left of this call's budget; 124 = deferred.
timed_consult() {
    local left; left="$(budget_left)"
    [ "$left" -ge 60 ] || return 124
    timeout "$left" bash "$INFRA/consult.sh" "$@" >/dev/null 2>"$TMP/c.err" </dev/null
}

resume_bg() {   # resume_bg <N> <answer> — worker-resume.sh, backgrounded; the next --wait reads it
    local n="$1" d
    d="$(issue_dir "$n")"
    env_args "$n"
    ( set -m; nohup bash "$INFRA/worker-resume.sh" "$RUNID" "$n" "$(tier_of "$n")" "$(worktree_of "$n")" \
        --base "$ORCH_BRANCH" --attempt "$(attempt_of "$n")" --answer "$2" ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
        >"$d/resume.log" 2>&1 </dev/null & )
    # It clears `exit` before it runs anything; until then the old terminal state would be
    # re-reported. A resume that never gets that far is held, not looped on.
    for _ in $(seq 1 30); do [ -e "$d/exit" ] || return 0; sleep 1; done
    hold "$n" "resume did not start: $(tail -1 "$d/resume.log" 2>/dev/null)"; return 1
}

# handle "<report line>"
handle() {
    local line="$1" n status rest tier a k role reason key detail h m wt rc
    n="$(printf '%s' "$line" | awk '{print $2}')"; status="$(printf '%s' "$line" | awk '{print $3}')"
    rest="${line#issue "$n" "$status"}"; rest="${rest# }"
    tier="$(tier_of "$n")"; a="$(attempt_of "$n")"; k="$(rounds_of "$n")"; k="${k:-0}"
    role="$(head -1 "$(issue_dir "$n")/role" 2>/dev/null)"; role="${role:-build}"
    wt="$(worktree_of "$n")"
    # Retried once: its thread read is a `gh` call, and a blip must not end a reviewed issue.
    # Still failing → an error line and the issue stays in flight (re-reported next call).
    reason="$(escalate "$n" "$tier" "$wt" "$a")" \
        || { echo "error: escalate.sh failed for #$n: $(tail -1 "$TMP/esc.err")"; return; }
    key="${reason%%:*}"; detail="${reason#*: }"
    case "$status" in
    built|fixed)
        h="$(printf '%s' "$rest" | sed -n 's/.*review=\([0-9]*\) high.*/\1/p')"
        m="$(printf '%s' "$rest" | sed -n 's/.*review=[0-9]* high, \([0-9]*\) medium.*/\1/p')"
        case "$key" in
        "")
            if [ "$((${h:-0} + ${m:-0}))" -eq 0 ]; then fold "$n"
            else
                spawn_issue "$n" fix "$k" "$a" 2>"$TMP/spawn.err" \
                    || { hold "$n" "fix round failed to spawn: $(tail -1 "$TMP/spawn.err")"; return; }
                echo "fix #$n round=$k attempt=$a ($h high, $m medium)"
            fi ;;
        recurrence)
            if timed_consult decide "$RUNID" "$n" "$tier" "$wt" --attempt "$a"; then
                runlog append "$RUNID" consulted "{\"n\":$n}" >/dev/null
                echo "decided #$n $detail"
            else
                echo "decide refused #$n: $(tail -1 "$TMP/c.err") — fixing anyway"
            fi
            spawn_issue "$n" fix "$k" "$a" 2>"$TMP/spawn.err" \
                || { hold "$n" "fix round failed to spawn: $(tail -1 "$TMP/spawn.err")"; return; }
            echo "fix #$n round=$k attempt=$a (after the decision)" ;;
        no-progress|backstop)
            runlog append "$RUNID" escalated "$(jq -cn --argjson n "$n" --arg r "$key" --argjson a "$a" '{n: $n, reason: $r, attempt: $a}')" >/dev/null
            echo "capped #$n $reason"
            fold "$n" ;;
        *)
            escalate_to_next "$n" "$key" "$detail" "$a" fix "$k" ;;
        esac ;;
    failed|escalate)
        case "$key" in
        no-progress|backstop)
            # The issue's loop is over and there is nothing built to merge: end it, no respawn.
            hold "$n" "ended: $reason"; return ;;
        "") ;;
        *)  escalate_to_next "$n" "$key" "$detail" "$a" "$role" "$k"; return ;;
        esac
        if [ "$status" = failed ]; then drain "$n" "failed: $rest"
        elif [ "${rest#deviation:}" != "$rest" ]; then
            timed_consult consult "$RUNID" "$n" "$tier" "$wt" --attempt "$a"; rc=$?
            if [ "$rc" -eq 0 ]; then
                runlog append "$RUNID" consulted "{\"n\":$n}" >/dev/null
                resume_bg "$n" "Consult posted: read the newest **Consult** comment on #$n and follow its decision." \
                    && echo "consulted #$n; resumed"
            elif [ "$rc" -eq 124 ]; then
                echo "deferred #$n its consult did not finish in this call; retried on the next --wait"
            else
                escalate_to_next "$n" deviation-cap "consult refused: $(tail -1 "$TMP/c.err")" "$a" "$role" "$k"
            fi
        else
            pause "$n" escalate
            echo "escalate #$n $rest"
        fi ;;
    blocked)
        pause "$n" blocked
        echo "blocked #$n $rest" ;;
    *)
        hold "$n" "unknown report: $line" ;;
    esac
}

next() { bash "$WF/admit.sh" "$RUNID" --next; }

case "$MODE" in
--wait)
    [ $# -eq 0 ] || die "$USAGE"
    WAITSET=(); PAUSED=()
    for n in $(run_state in_flight); do
        if [ -f "$(issue_dir "$n")/paused" ]; then PAUSED+=("#$n ($(head -1 "$(issue_dir "$n")/paused"))")
        else WAITSET+=("$n"); fi
    done
    if [ "${#WAITSET[@]}" -eq 0 ]; then
        if [ "${#PAUSED[@]}" -gt 0 ]; then echo "paused: ${PAUSED[*]}"; else next; fi
        exit 0
    fi
    LINE="$(bash "$INFRA/worker-report.sh" --any "$RUNID" "${WAITSET[@]}" \
        --timeout "${HANDLE_WAIT_TIMEOUT:-240}" --interval "${HANDLE_WAIT_INTERVAL:-10}" 2>"$TMP/wr.err")"; RC=$?
    if [ "$RC" -ne 0 ]; then
        if grep -q 'timed out' "$TMP/wr.err"; then
            # Nobody reported: look at the ones still running. A stall, a full context or a
            # worker that died without an exit code is only visible from out here.
            ACTED=""
            for n in "${WAITSET[@]}"; do
                a="$(attempt_of "$n")"; k="$(rounds_of "$n")"
                role="$(head -1 "$(issue_dir "$n")/role" 2>/dev/null)"
                reason="$(escalate "$n" "$(tier_of "$n")" "$(worktree_of "$n")" "$a")" \
                    || { echo "error: escalate.sh failed for #$n: $(tail -1 "$TMP/esc.err")"; ACTED=1; continue; }
                case "${reason%%:*}" in
                    "") ;;
                    stall|occupancy|failed|quota)
                        escalate_to_next "$n" "${reason%%:*}" "${reason#*: }" "$a" "${role:-build}" "${k:-0}"
                        ACTED=1 ;;
                esac
            done
            if [ -n "$ACTED" ]; then next
            else echo "waiting: $(printf '%s ' "${WAITSET[@]}" | xargs | tr ' ' ',')"; fi
            exit 0
        fi
        N="$(sed -n 's/^error: issue \([0-9]*\) .*/\1/p' "$TMP/wr.err" | head -1)"
        [ -n "$N" ] || { echo "error: worker-report.sh: $(tail -1 "$TMP/wr.err")"; exit 0; }
        hold "$N" "no readable report: $(sed -n 's/^error: //p' "$TMP/wr.err" | head -1 | cut -c1-300)"
    else
        handle "$LINE"
    fi
    next ;;
--merged)
    [ $# -eq 1 ] || die "$USAGE"
    N="${1#\#}"; case "$N" in ''|*[!0-9]*) die "issue must be a number" ;; esac
    git -C "$ORCH_WT" merge-base --is-ancestor "issue-$N" HEAD 2>/dev/null \
        || die "issue-$N is not merged into $ORCH_BRANCH yet"
    unpause "$N"
    runlog append "$RUNID" merged "$(jq -cn --argjson n "$N" --arg s "$(git -C "$ORCH_WT" rev-parse HEAD)" '{n: $n, sha: $s}')" >/dev/null
    echo "merged #$N $(git -C "$ORCH_WT" rev-parse --short=7 HEAD)"
    ! capped "$N" || follow_up "$N"
    next ;;
--answer)
    [ $# -eq 2 ] || die "$USAGE"
    N="${1#\#}"; case "$N" in ''|*[!0-9]*) die "issue must be a number" ;; esac
    [ -n "${2//[[:space:]]/}" ] || die "the answer is empty"
    unpause "$N"
    resume_bg "$N" "$2" && echo "resumed #$N" ;;
--resource)
    [ $# -ge 3 ] || die "$USAGE"
    N="${1#\#}"; shift; case "$N" in ''|*[!0-9]*) die "issue must be a number" ;; esac
    PAIRS=()
    while [ $# -gt 0 ]; do
        [ "$1" = --env ] && [ $# -ge 2 ] || die "$USAGE"
        PAIRS+=("$2"); shift 2
    done
    bash "$INFRA/env-pairs.sh" "${PAIRS[@]}" || exit 1
    ( umask 077; printf '%s\0' "${PAIRS[@]}" >"$(issue_dir "$N")/env" ) || die "cannot store the pairs"
    kill_worker "$N" || die "could not stop #$N's worker"
    unpause "$N"
    ROLE="$(head -1 "$(issue_dir "$N")/role" 2>/dev/null)"; ROLE="${ROLE:-build}"
    ROUND=1; [ "$ROLE" = build ] || ROUND="$(rounds_of "$N")"
    spawn_issue "$N" "$ROLE" "${ROUND:-1}" "$(attempt_of "$N")" 2>"$TMP/spawn.err" \
        || die "respawn failed: $(tail -1 "$TMP/spawn.err")"
    NAMES="$(for p in "${PAIRS[@]}"; do printf '%s\n' "${p%%=*}"; done | jq -R . | jq -cs .)"
    runlog append "$RUNID" respawned "{\"n\":$N,\"reason\":\"infra\",\"env\":$NAMES}" >/dev/null
    echo "respawned #$N with $(printf '%s' "$NAMES" | jq -r 'join(",")')" ;;
*) die "$USAGE" ;;
esac
