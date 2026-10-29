#!/usr/bin/env bash
#
# refresh-blockers.sh — re-read every not-yet-closed blocker's state into graph.json.
#
# The graph is frozen at launch, but a blocker outside the run (another run's slice, an
# issue closed by hand) can close hours later; ready.sh trusts blockerStates, so without
# this its dependents stay stranded for the whole run. admit.sh calls this before asking
# ready.sh what is admissible. Only open/unknown refs are re-read — a closed one stays
# closed. A failed lookup leaves the old state (fail closed: never unblocks on a blip).
#
# Only blockers OUTSIDE the run are re-read. One of the run's own issues is satisfied by being
# merged by the run (ready.sh's --merged), never by a close on GitHub: a hand-close would admit
# its dependents onto a run branch without its code.
#
# stdout: `blocker-closed #N` per flip. That blocker's code reached the base branch AFTER the run
# branch was cut, so a dependent is built without it unless the base is merged into the run branch.
#
# Usage: bash refresh-blockers.sh <graph.json> [repo-dir]   (gh runs in repo-dir, default .)

set -uo pipefail
GRAPH="${1:?usage: refresh-blockers.sh <graph.json> [repo-dir]}"
cd "${2:-.}" || exit 1
command -v gh >/dev/null 2>&1 || exit 0

UPD="{}"
for n in $(jq -r '[.issues[].n | tostring] as $own | .blockerStates // {} | to_entries[] | select(.value != "closed" and ([.key] | inside($own) | not)) | .key' "$GRAPH"); do
    s="$(gh issue view "$n" --json state -q .state 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    case "$s" in
        open|closed) UPD="$(jq -c --arg n "$n" --arg s "$s" '. + {($n): $s}' <<<"$UPD")"
                     [ "$s" != closed ] || echo "blocker-closed #$n" ;;
    esac
done
[ "$UPD" != "{}" ] || exit 0
jq --argjson u "$UPD" '.blockerStates += $u' "$GRAPH" >"$GRAPH.tmp" && mv -f "$GRAPH.tmp" "$GRAPH"
