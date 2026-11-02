#!/usr/bin/env bash
#
# session-gc.sh — remove finished `orch-*` rows from the background-session registry.
#
# Usage:
#   bash session-gc.sh --run <runid>       # this run's rows only (orch-<runid>-…)
#   bash session-gc.sh --all-terminal      # every orch-* row, any run
#
# /orchestrate's workers used to be `claude --bg` sessions, and nothing removed their rows:
# one machine held 413 `orch-*` rows, 394 of them finished. Workers are one-shot processes
# now and add no rows, so this is the cleanup for what is left and for any run that still
# spawned sessions. `claude rm <id>` deletes a row; a worktree the session did not create —
# every orch worker's — is left alone (verified 2026-10-17).
#
# Only a `background` row named `orch-…` in state done, stopped or failed is removed. Never
# busy, idle, blocked or working: a live session is someone's work in progress.
#
# Output: `removed <name> <id>` per row, or `nothing to remove`. Exit 1 when the registry
# cannot be read or a removal fails (the rest still run).

set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }

PREFIX=""
case "${1:-}" in
    --run)
        [ $# -eq 2 ] || die "usage: session-gc.sh --run <runid> | --all-terminal"
        case "$2" in .|..|''|*[!A-Za-z0-9._-]*) die "runid may only contain [A-Za-z0-9._-]" ;; esac
        PREFIX="orch-$2-" ;;
    --all-terminal)
        [ $# -eq 1 ] || die "usage: session-gc.sh --run <runid> | --all-terminal"
        PREFIX="orch-" ;;
    *) die "usage: session-gc.sh --run <runid> | --all-terminal" ;;
esac
command -v claude >/dev/null 2>&1 || die "claude CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

LIST="$(timeout 60 claude agents --json --all 2>/dev/null </dev/null)" \
    || die "\`claude agents --json --all\` failed"
ROWS="$(printf '%s' "$LIST" | jq -r --arg p "$PREFIX" '
    .[] | select(type == "object" and .kind == "background"
                 and ((.name // "") | startswith($p))
                 and (.state == "done" or .state == "stopped" or .state == "failed"))
        | "\(.id)\t\(.name)"' 2>/dev/null)" || die "\`claude agents --json\` did not return a JSON array"

[ -n "$ROWS" ] || { echo "nothing to remove"; exit 0; }
RC=0
while IFS="$(printf '\t')" read -r id name; do
    [ -n "$id" ] || continue
    if timeout 60 claude rm "$id" >/dev/null 2>&1 </dev/null; then
        echo "removed $name $id"
    else
        echo "error: could not remove $name $id" >&2; RC=1
    fi
done <<<"$ROWS"
exit "$RC"
