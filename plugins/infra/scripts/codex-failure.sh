#!/usr/bin/env bash
#
# codex-failure.sh — read a codex crash reason from its event log, then stderr.
#
# Usage: bash codex-failure.sh <rundir>
# Output: at most one flattened reason line; always exits 0.
#
# WHY THE EVENT LOG COMES FIRST. stderr.log starts with Codex's harmless
# "Reading additional input from stdin..." banner, which caused #82 to be
# misreported as a stdin failure. The event stream carries the actual error.
# A usage-limit message is prefixed `quota:` because every codex model in the
# chain shares the quota, so trying the next codex position cannot help.

CODEX_FAILURE_RUNDIR="${1:-}" python3 <<'PY'
import json, os, re

rundir = os.environ.get("CODEX_FAILURE_RUNDIR", "")

def flat(value):
    return " ".join(str(value).split()) or "(no reason given)"

message = None
try:
    with open(os.path.join(rundir, "events.jsonl"), encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                event = json.loads(line)
            except (TypeError, ValueError):
                continue
            if not isinstance(event, dict):
                continue
            if event.get("type") == "error" and "message" in event:
                message = event["message"]
            elif event.get("type") == "turn.failed":
                error = event.get("error")
                if isinstance(error, dict) and "message" in error:
                    message = error["message"]
except OSError:
    pass

if message is not None:
    why = flat(message)[:500]
    if re.search(r"usage[ _]limit", why, re.I):
        print("quota: " + why)
    else:
        print(why)
else:
    try:
        with open(os.path.join(rundir, "stderr.log"), encoding="utf-8", errors="replace") as fh:
            tail = fh.read()[-500:]
    except OSError:
        tail = ""
    if tail.strip():
        print(flat(tail)[:500])
PY
