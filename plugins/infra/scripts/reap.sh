#!/usr/bin/env bash
#
# reap.sh — kill what a worker left running.
#
# Usage:
#   bash reap.sh <runid>/<issue>    # that issue's processes (exact tag)
#   bash reap.sh <runid>/           # every worker process of the run
#
# spawn.sh exports ORCH_WORKER=<runid>/<issue> into the worker's environment, and children
# inherit it — through setsid, nohup and a daemonizing double fork too. A backgrounded build
# (`nix build &`) the worker never waited for outlives the worker's process group, so a group
# kill cannot find it; the tag can. Matching processes get TERM, a few seconds, then KILL.
#
# Never kills itself or an ancestor: the spawn wrapper calls this and carries the tag too.
# Reads /proc/<pid>/environ, so it is Linux-only and a silent no-op elsewhere.
#
# Output: `reaped N process(es)`. Exit 0 whether or not anything matched.

set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }
USAGE="usage: reap.sh <runid>/<issue> | <runid>/"

[ $# -eq 1 ] || die "$USAGE"
TAG="$1"
case "$TAG" in */*) ;; *) die "$USAGE" ;; esac
case "$TAG" in *[!A-Za-z0-9._/-]*|/*) die "tag may only contain [A-Za-z0-9._/-], got '$TAG'" ;; esac
[ -d /proc/self ] || { echo "reaped 0 process(es) (no /proc here)"; exit 0; }

PROTECT=" $$ "
p=$$
while [ "${p:-0}" -gt 1 ]; do
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    PROTECT="$PROTECT${p:-0} "
done

matches() {
    local env pid
    for env in /proc/[0-9]*/environ; do
        pid="${env#/proc/}"; pid="${pid%/environ}"
        case "$PROTECT" in *" $pid "*) continue ;; esac
        tr '\0' '\n' <"$env" 2>/dev/null | awk -v t="ORCH_WORKER=$TAG" '
            { if (substr(t, length(t)) == "/" ? index($0, t) == 1 : $0 == t) f = 1 }
            END { exit !f }' && echo "$pid"
    done
}

PIDS="$(matches)"
N=0
for pid in $PIDS; do kill -TERM "$pid" 2>/dev/null && N=$((N + 1)); done
if [ "$N" -gt 0 ]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.5
        LEFT=""
        for pid in $PIDS; do kill -0 "$pid" 2>/dev/null && LEFT="$LEFT $pid"; done
        [ -n "$LEFT" ] || break
    done
    for pid in ${LEFT:-}; do kill -KILL "$pid" 2>/dev/null; done
fi
echo "reaped $N process(es)"
