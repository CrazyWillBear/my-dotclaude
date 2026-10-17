#!/usr/bin/env bash
#
# claude-report.sh — turn a claude worker's stream into the run dir's report file.
#
# Usage: bash claude-report.sh <rundir>
#
# A codex worker writes last-message.txt itself (`-o`). A `claude -p` worker has no such
# flag: its schema'd report is the `structured_output` of the LAST `result` event in
# events.jsonl (a resume appends a second turn to the same log, so the last one is this
# turn's). This writes that object to last-message.txt, so everything downstream —
# session-status.sh, worker-report.sh, escalate.sh and the wrapper's review gate — reads
# one file for both backends.
#
# Writes nothing when there is no report (a crash, or a result with no structured output):
# an ABSENT file is what sends worker-report.sh down its "no report" path, and a guessed
# one would read as a real outcome. Always exits 0.

RUNDIR="${1:-}"
[ -n "$RUNDIR" ] && [ -f "$RUNDIR/events.jsonl" ] || exit 0
[ -s "$RUNDIR/last-message.txt" ] && exit 0
REPORT="$(jq -cR 'fromjson? | select(type == "object" and .type == "result") | .structured_output // empty' \
    "$RUNDIR/events.jsonl" 2>/dev/null | tail -1)"
[ -z "$REPORT" ] || printf '%s\n' "$REPORT" >"$RUNDIR/last-message.txt"
exit 0
