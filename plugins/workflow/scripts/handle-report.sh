#!/usr/bin/env bash
#
# handle-report.sh — wait for the next worker report and act on it, by table.
#
# Usage:
#   bash handle-report.sh <runid> --wait                    # block (≤ ~9 min) for the next report
#   bash handle-report.sh <runid> --merged <N>              # the merger landed issue-<N>
#   bash handle-report.sh <runid> --answer <N> <text>       # a human answered #N's question
#   bash handle-report.sh <runid> --resource <N> --env K=V…  # a human provisioned #N's resource
#   bash handle-report.sh <runid> --retry <N>               # lift #N's hold: it is admitted afresh
#   bash handle-report.sh <runid> --max <N>                 # change the run's worker cap mid-run
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

USAGE="usage: handle-report.sh <runid> --wait | --merged N | --answer N <text> | --resource N --env K=V... | --retry N | --max N"
[ $# -ge 2 ] || die "$USAGE"
load_run "$1"; shift
MODE="$1"; shift
if [ "$MODE" = --wait ]; then run_lock; else run_lock strict; fi
TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

# salvage <N> — keep a stopped worker's work before a hold or drain strands it: commit what it
# left uncommitted and point prev/issue-N-<runid> at the branch. Prints the branch name, or
# nothing when there was nothing to keep (no worker, still running, or a worktree that fails the
# containment check — the same tripwire spawn.sh runs before the first host git in a worktree).
salvage() {
    local n="$1" d wt pid
    d="$(issue_dir "$n")"; wt="$(worktree_of "$n")"
    [ -f "$d/pid" ] && [ -d "$wt" ] || return 0
    pid="$(head -1 "$d/pid" 2>/dev/null)"
    { [ -e "$d/exit" ] || ! kill -0 "$pid" 2>/dev/null; } || return 0
    bash "$INFRA/common-git-dir.sh" --roots "$wt" >/dev/null 2>&1 || return 0
    local g=(git -C "$wt" -c core.fsmonitor=false -c core.hooksPath=/dev/null)
    [ "$("${g[@]}" symbolic-ref --short HEAD 2>/dev/null)" = "issue-$n" ] || return 0
    if [ -n "$("${g[@]}" status --porcelain 2>/dev/null)" ]; then
        "${g[@]}" add -A >/dev/null 2>&1 \
            && "${g[@]}" -c user.name=orchestrate -c user.email=orchestrate@localhost \
                commit -q --no-verify -m "WIP: salvaged from #$n by run $RUNID" >/dev/null 2>&1
    fi
    "${g[@]}" branch -f "prev/issue-$n-$RUNID" "issue-$n" >/dev/null 2>&1 && echo "prev/issue-$n-$RUNID"
}
# kept_note <N> — " (work kept on <branch>)" when a salvage saved something, else nothing.
kept_note() { local b; b="$(salvage "$1")"; [ -z "$b" ] || printf ' (work kept on %s)' "$b"; }
hold() {
    runlog append "$RUNID" held "$(jq -cn --argjson n "$1" --arg why "$2" '{n: $n, why: $why}')" >/dev/null
    echo "held #$1 $2$(kept_note "$1")"
}
drain() {
    runlog append "$RUNID" held "$(jq -cn --argjson n "$1" --arg why "drained: $2" '{n: $n, why: $why}')" >/dev/null
    runlog append "$RUNID" decision "$(jq -cn --arg w "drain: #$1 $2" '{what: $w}')" >/dev/null
    echo "drain: #$1 $2$(kept_note "$1")"
}
pause() { printf '%s\n' "$2" >"$(issue_dir "$1")/paused"; }
unpause() { rm -f "$(issue_dir "$1")/paused"; }
capped() {
    runlog replay "$RUNID" 2>/dev/null | jq -e --argjson n "$1" \
        'select(.event == "escalated" and .n == $n and (.reason == "no-progress" or .reason == "backstop"))' \
        >/dev/null 2>&1
}

# kill_worker <N> — stop the worker, then reap what it left running (a backgrounded build
# outlives the group kill; reap.sh finds it by the ORCH_WORKER tag in its environment).
kill_worker() {
    local rc
    group_kill "$1"; rc=$?
    bash "$INFRA/reap.sh" "$RUNID/$1" >/dev/null 2>&1
    return "$rc"
}

# group_kill <N> — group-kill the wrapper (it leads its own group), bounded wait.
group_kill() {
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
#
# A deferral is bounded: the issue's run dir counts them (`deferrals`), and past
# HANDLE_MAX_DEFERRALS (default 2) the consult runs past the call's budget, capped only by
# CONSULT_TIMEOUT (default 30 min) — the call may overrun Bash's cap once, which beats
# re-asking the same opus call forever while every other finished worker queues behind it.
# Hitting that hard cap returns 125: the caller holds the issue, never defers again. A
# finished consult resets the count.
timed_consult() {
    local n="$3" left c f
    f="$(issue_dir "$n")/deferrals"
    c="$(head -1 "$f" 2>/dev/null)"; c="${c:-0}"
    if [ "$c" -ge "${HANDLE_MAX_DEFERRALS:-2}" ]; then
        timeout "${CONSULT_TIMEOUT:-1800}" bash "$INFRA/consult.sh" "$@" >/dev/null 2>"$TMP/c.err" </dev/null
        local rc=$?
        rm -f "$f"
        [ "$rc" -ne 124 ] || return 125
        return "$rc"
    fi
    left="$(budget_left)"
    if [ "$left" -lt 60 ]; then echo $((c + 1)) >"$f"; return 124; fi
    timeout "$left" bash "$INFRA/consult.sh" "$@" >/dev/null 2>"$TMP/c.err" </dev/null; local rc=$?
    if [ "$rc" -eq 124 ]; then echo $((c + 1)) >"$f"; else rm -f "$f"; fi
    return "$rc"
}

resume_bg() {   # resume_bg <N> <answer> — worker-resume.sh, backgrounded; the next --wait reads it
    local n="$1" d
    d="$(issue_dir "$n")"
    env_args "$n"
    ( set -m; nohup bash "$INFRA/worker-resume.sh" "$RUNID" "$n" "$(tier_of "$n")" "$(worktree_of "$n")" \
        --base "$ORCH_BRANCH" --attempt "$(attempt_of "$n")" --answer "$2" ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
        >"$d/resume.log" 2>&1 </dev/null 9>&- & )
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
            timed_consult decide "$RUNID" "$n" "$tier" "$wt" --attempt "$a"; rc=$?
            if [ "$rc" -eq 0 ]; then
                runlog append "$RUNID" consulted "{\"n\":$n}" >/dev/null
                echo "decided #$n $detail"
            elif [ "$rc" -eq 125 ]; then
                hold "$n" "decide timed out after ${CONSULT_TIMEOUT:-1800}s"; return
            elif [ "$rc" -eq 124 ]; then
                # A real deferral: un-spend the fire escalate.sh just recorded for this round,
                # so the next --wait re-reports this worker and asks for the decide again.
                sed -i "/^$a	$k	/d" "$(issue_dir "$n")/recurrence" 2>/dev/null
                echo "deferred #$n its decide did not finish in this call; asked again on the next --wait"
                return
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
            elif [ "$rc" -eq 125 ]; then
                hold "$n" "consult timed out after ${CONSULT_TIMEOUT:-1800}s"
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
    # The wait leaves HANDLE_RESERVE seconds of this call's budget for handling what it
    # returns (a decide or a consult runs inline) — a call that overruns Bash's cap is moved
    # to the background and its lines are never read.
    WAIT=$(( $(budget_left) - ${HANDLE_RESERVE:-420} ))
    [ "$WAIT" -le "${HANDLE_WAIT_TIMEOUT:-240}" ] || WAIT="${HANDLE_WAIT_TIMEOUT:-240}"
    [ "$WAIT" -ge 5 ] || WAIT=5
    if [ "${#WAITSET[@]}" -eq 0 ]; then
        # No worker to wait on. Plans may still be running: wait for one to finish, then let
        # admit.sh collect it.
        if ls "$RUN_DIR"/plans/*.started >/dev/null 2>&1; then
            for _ in $(seq 1 "$((WAIT / 5))"); do
                ls "$RUN_DIR"/plans/*.rc >/dev/null 2>&1 && break
                sleep 5
            done
            next
        elif [ "${#PAUSED[@]}" -gt 0 ]; then
            # Waiting on a human is no reason to leave a free slot idle.
            next; echo "paused: ${PAUSED[*]}"
        else next; fi
        exit 0
    fi
    LINE="$(bash "$INFRA/worker-report.sh" --any "$RUNID" "${WAITSET[@]}" \
        --timeout "$WAIT" --interval "${HANDLE_WAIT_INTERVAL:-10}" 2>"$TMP/wr.err")"; RC=$?
    if [ "$RC" -ne 0 ]; then
        if grep -q 'timed out' "$TMP/wr.err"; then
            # Nobody reported: look at the ones still running. A stall, a full context or a
            # worker that died without an exit code is only visible from out here.
            # A DRY run first: escalate.sh's real run posts a Handoff and writes its marks, and
            # on a worker that finished since the last poll it could fire a review-cap or a
            # recurrence this scan would then throw away. Finished workers are skipped (the
            # next --wait reports them); a failed scan is skipped too — a background check
            # must never stop the run.
            ACTED=""
            for n in "${WAITSET[@]}"; do
                [ ! -e "$(issue_dir "$n")/exit" ] || continue
                a="$(attempt_of "$n")"; k="$(rounds_of "$n")"
                role="$(head -1 "$(issue_dir "$n")/role" 2>/dev/null)"
                tier="$(tier_of "$n")"; wt="$(worktree_of "$n")"
                reason="$(bash "$INFRA/escalate.sh" "$RUNID" "$n" "$tier" "$wt" --base "$ORCH_BRANCH" \
                    --attempt "$a" --dry-run 2>/dev/null)" || continue
                case "${reason%%:*}" in stall|occupancy|failed|quota) ;; *) continue ;; esac
                reason="$(bash "$INFRA/escalate.sh" "$RUNID" "$n" "$tier" "$wt" --base "$ORCH_BRANCH" \
                    --attempt "$a" 2>/dev/null)" || continue
                case "${reason%%:*}" in
                    stall|occupancy|failed|quota)
                        escalate_to_next "$n" "${reason%%:*}" "${reason#*: }" "$a" "${role:-build}" "${k:-0}"
                        ACTED=1 ;;
                esac
            done
            # A plan that finished meanwhile is collected now, not when some worker next reports.
            if [ -n "$ACTED" ] || ls "$RUN_DIR"/plans/*.rc >/dev/null 2>&1; then next
            else echo "waiting: $(printf '%s ' "${WAITSET[@]}" | xargs | tr ' ' ',')"; fi
            exit 0
        fi
        N="$(sed -n 's/^error: issue \([0-9]*\) .*/\1/p' "$TMP/wr.err" | head -1)"
        [ -n "$N" ] || { echo "error: worker-report.sh: $(tail -1 "$TMP/wr.err")"; exit 0; }
        WHY="$(sed -n 's/^error: //p' "$TMP/wr.err" | head -1 | cut -c1-300)"
        a="$(attempt_of "$N")"; k="$(rounds_of "$N")"; role="$(head -1 "$(issue_dir "$N")/role" 2>/dev/null)"
        chain="$(bash "$INFRA/resolve-tier.sh" "$(tier_of "$N")" 0 2>/dev/null | sed -n 's/^implementer_chain=//p')"
        # A worker that ended with no report at all is "failed": the next cell of its chain
        # picks up its worktree, as for any other failure. At the top there is no next cell;
        # that is a hold (not a drain — a report glitch must not stop the whole run).
        case "$WHY" in
            *"wrote no report"*|*"unreadable report"*)
                if [ "$((a + 1))" -lt "${chain:-1}" ]; then
                    escalate_to_next "$N" failed "no report: $WHY" "$a" "${role:-build}" "${k:-0}"
                    next; exit 0
                fi ;;
        esac
        hold "$N" "no readable report: $WHY"
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
--retry)
    # A hold is the run's judgment, not the issue's: once its cause is fixed (a stale branch
    # deleted, a prerequisite landed) this lifts it. A retry is a FRESH admission, so the old
    # worker's run dir (rounds, chain position) is kept aside, not reused; only the human's
    # provisioned env pairs carry over. The worktree and branch are reused by admit.sh.
    [ $# -eq 1 ] || die "$USAGE"
    N="${1#\#}"; case "$N" in ''|*[!0-9]*) die "issue must be a number" ;; esac
    case " $(run_state held) " in *" $N "*) ;; *) die "#$N is not held" ;; esac
    kill_worker "$N" || die "could not stop #$N's worker"
    d="$(issue_dir "$N")"
    if [ -d "$d" ]; then
        old="$d.held-$(date +%s)-$$"
        mv "$d" "$old" || die "cannot set #$N's run dir aside"
        mkdir -p "$d" || die "cannot recreate $d"
        [ ! -f "$old/env" ] || cp -p "$old/env" "$d/env" || die "cannot carry #$N's env over"
    fi
    rm -f "$RUN_DIR/plans/$N".*
    runlog append "$RUNID" released "{\"n\":$N}" >/dev/null
    echo "released #$N"
    next ;;
--max)
    [ $# -eq 1 ] || die "$USAGE"
    case "$1" in ''|0|*[!0-9]*) die "--max must be a number of 1 or more, got '$1'" ;; esac
    sed "s/^MAX=.*/MAX=$1/" "$RUN_DIR/run.env" >"$RUN_DIR/run.env.tmp" \
        && mv -f "$RUN_DIR/run.env.tmp" "$RUN_DIR/run.env" || die "cannot rewrite $RUN_DIR/run.env"
    echo "max $1 (was $MAX)"
    # A lower cap stops new admissions and lets what runs finish; a higher one fills at once.
    next ;;
*) die "$USAGE" ;;
esac
