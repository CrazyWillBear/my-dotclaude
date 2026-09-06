#!/usr/bin/env bash
#
# run-log.sh — the orchestrator's append-only run log.
#
# Usage:
#   bash run-log.sh append <runid> <event> ['{"json":"payload"}']
#   bash run-log.sh replay <runid>        # every event, in order, as JSONL
#   bash run-log.sh state  <runid>        # the folded state, as key=value lines
#   bash run-log.sh path   <runid>        # where the log lives
#
# Events — THE WHOLE VOCABULARY, deliberately: scope · held · respawned · decision.
# An unknown event is an error, so the vocabulary cannot drift by accident.
#
# The issue thread is the coordination medium (decision 12), which makes almost
# everything a run log would traditionally store redundant — and a stored copy is
# worse than redundant, because it can disagree with the truth:
#
#   not stored          recovered from
#   ----------          --------------
#   spawned             session-status.sh / `claude agents --json`
#   merged              git log <base>..orchestrate-<ts>
#   reviewed, cycles    COUNT THE REVIEW-ROUND COMMENTS ON THE ISSUE — never a field
#   escalated + fix     the issue comment the escalation protocol requires
#
# `respawned` is the one thing genuinely underivable: nothing in git or GitHub
# records that a session was killed and restarted, and "respawn once, escalate on
# the second" needs the count. `held` is stored because a capped merge's hold is an
# in-run judgment, not a fact on the issue.
#
# Append-only means no read-modify-write: no lost updates, and no format drift
# after a compact. Each line gets a `ts` and the event name; the rest is yours.
#
# The log lives beside the handoffs, in the same per-repo keyed dir — one keying
# scheme for the repo, not two. save-handoff.sh --print-dir OWNS that keying.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "error: $*" >&2; exit 1; }

CMD="${1:-}"
RUNID="${2:-}"
[ -n "$CMD" ] && [ -n "$RUNID" ] || die "usage: run-log.sh append|replay|state|path <runid> [event] [json]"

command -v python3 >/dev/null 2>&1 || die "python3 not found"

DIR="$(bash "$SCRIPT_DIR/save-handoff.sh" --print-dir 2>/dev/null)"
[ -n "$DIR" ] || die "not in a git repo — the run log is keyed per repo"

case "$RUNID" in *[!A-Za-z0-9._-]*) die "runid may only contain [A-Za-z0-9._-]" ;; esac

LOG="$DIR/runs/$RUNID.jsonl"

case "$CMD" in
    path)
        printf '%s\n' "$LOG"
        ;;

    append)
        EVENT="${3:-}"
        case "$EVENT" in
            scope|held|respawned|decision) ;;
            "") die "append needs an event: scope | held | respawned | decision" ;;
            *)  die "unknown event '$EVENT' — the vocabulary is scope | held | respawned | decision" ;;
        esac
        mkdir -p "$DIR/runs" || die "cannot create $DIR/runs"
        RUNLOG_EVENT="$EVENT" RUNLOG_PAYLOAD="${4:-}" RUNLOG_FILE="$LOG" python3 <<"PY" || exit 1
import json, os, sys, time

payload = os.environ.get("RUNLOG_PAYLOAD", "").strip()
if payload:
    try:
        data = json.loads(payload)
    except Exception:
        print("error: payload is not JSON: %s" % payload[:120], file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, dict):
        print("error: payload must be a JSON object", file=sys.stderr)
        sys.exit(1)
else:
    data = {}

# The payload goes in FIRST so it can never overwrite the two fields this file
# guarantees. The other order let `append run1 held '{"event":"spawned"}'` write a
# record outside the closed vocabulary — which `state` then silently stops folding.
record = {**data, "ts": int(time.time()), "event": os.environ["RUNLOG_EVENT"]}
with open(os.environ["RUNLOG_FILE"], "a") as fh:
    fh.write(json.dumps(record, sort_keys=True) + "\n")
PY
        ;;

    replay)
        [ -f "$LOG" ] || die "no run log for '$RUNID' (looked in $LOG)"
        cat "$LOG"
        ;;

    state)
        [ -f "$LOG" ] || die "no run log for '$RUNID' (looked in $LOG)"
        RUNLOG_FILE="$LOG" RUNLOG_RUNID="$RUNID" python3 <<"PY"
import json, os, sys

scope, held, respawns, decisions = [], [], {}, []
bad = 0

with open(os.environ["RUNLOG_FILE"]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            bad += 1          # a torn line is reported, never silently dropped
            continue
        event = rec.get("event")
        if event == "scope":
            for n in rec.get("issues") or []:
                if n not in scope:
                    scope.append(n)
        elif event == "held":
            n = rec.get("n")
            if n is not None and n not in held:
                held.append(n)
        elif event == "respawned":
            n = rec.get("n")
            if n is not None:
                respawns[n] = respawns.get(n, 0) + 1
        elif event == "decision":
            decisions.append(str(rec.get("what") or "").replace("\n", " "))

out = ["runid=%s" % os.environ["RUNLOG_RUNID"]]
out.append("scope=%s" % ",".join(str(n) for n in scope))
out.append("held=%s" % ",".join(str(n) for n in sorted(held)))
out.append("respawned=%s" % ",".join("%s:%d" % (n, c) for n, c in sorted(respawns.items())))
for d in decisions:
    out.append("decision=%s" % d)
if bad:
    out.append("unparseable_lines=%d" % bad)
print("\n".join(out))
PY
        ;;

    *)
        die "unknown command '$CMD' — append | replay | state | path"
        ;;
esac
