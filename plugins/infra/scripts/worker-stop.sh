#!/usr/bin/env bash
#
# worker-stop.sh — stop a run's finished claude worker sessions, to free their process.
#
# Usage:
#   bash worker-stop.sh <runid> <issue>    # every live session of one issue (all attempts/rounds)
#   bash worker-stop.sh <runid> --all      # every live worker session of the run
#
# A worker is one-shot, but a `claude --bg` session stays resident (~160 MB, plus its own
# MCP servers) after it reports unless something stops it. /orchestrate calls this the
# moment a worker's job is over, so a PRD run does not pile up dozens of idle sessions.
#
# This only stops the PROCESS. The conversation is kept (`claude attach <id>` reopens it),
# and the worktree and branch are never touched — a stopped worker costs nothing to keep.
#
# Only LIVE (busy/idle/blocked) `background` rows are stopped, by id (session-status.sh
# column 2). Skipped on purpose: stopped/done/gone rows (nothing to stop); codex rows (a
# PID, not a session id — the process exits by itself, and stopping one is a group kill,
# README § Recovery); interactive rows (someone's own terminal). Matching is by the run's
# worker-name shape, so the orchestrator and other runs' workers are never reachable.
#
# A stop can be acknowledged and not take (README § Recovery), so it waits, bounded
# (WORKER_STOP_WAIT seconds, default 30), until the status is no longer live. A session
# still live after that exits 1 naming its id — do not spawn onto its worktree.
# Nothing live -> exit 0 and says so, so it is safe to call twice.

set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: worker-stop.sh <runid> <issue|--all>"
RUNID="$1"; TARGET="${2#\#}"
case "$RUNID" in .|..|*[!A-Za-z0-9._-]*) die "runid may only contain [A-Za-z0-9._-] and may not be . or .., got '$RUNID'" ;; esac
[ -n "$RUNID" ] || die "runid is required"
if [ "$TARGET" = --all ]; then
    PATTERN="-issue-[0-9]+(-a[0-9]+(-r[0-9]+)?)?$"
else
    case "$TARGET" in ''|*[!0-9]*) die "issue must be a number or --all, got '$TARGET'" ;; esac
    PATTERN="-issue-$TARGET(-a[0-9]+(-r[0-9]+)?)?$"
fi

STATUS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/session-status.sh"

# `<name> <id> <kind> <state>` rows still live for this target. Not stderr-silenced: a
# failed status read must be loud (silence would read as "nothing to stop").
live_rows() {
    local rows
    rows="$(bash "$STATUS" "$RUNID" 2>/dev/null)" || return 1
    printf '%s\n' "$rows" | awk -v pat="$PATTERN" \
        '$1 ~ pat && $2 != "-" && $3 == "background" && ($4 == "busy" || $4 == "idle" || $4 == "blocked")'
}

rows="$(live_rows)" || die "could not read session state for run $RUNID"
[ -n "$rows" ] || { echo "nothing to stop"; exit 0; }

while read -r name id _; do
    claude stop "$id" >/dev/null 2>&1
    echo "stopped $name $id"
done <<<"$rows"

# Bounded wait for every stop to take; then name whatever is still live.
deadline=$((SECONDS + ${WORKER_STOP_WAIT:-30}))
while :; do
    still="$(live_rows)" || die "could not re-read session state for run $RUNID"
    [ -n "$still" ] && [ "$SECONDS" -lt "$deadline" ] || break
    sleep 1
done
[ -z "$still" ] || {
    printf '%s\n' "$still" | while read -r name id _; do echo "error: still live after stop: $name $id" >&2; done
    exit 1
}
