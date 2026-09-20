#!/usr/bin/env bash
#
# review-tokens.sh — read the INDEPENDENT reviewer's real token usage from its own
# rollout, so reviewer cost is no longer invisible (#98).
#
# WHY THIS EXISTS. `codex exec review --json`'s `turn.completed` event reports an
# ALL-ZERO usage block — ground-truthed on two independent runs. `codex exec review`
# does not do the review itself: it forks a "review" SUBAGENT thread that does the
# actual work, and THAT thread is what accumulates real `token_usage_record` entries —
# in its OWN rollout file under `~/.codex/sessions/<Y>/<M>/<D>/rollout-<ts>-<uuid>.jsonl`,
# separate from the reviewer's own. Ground-truthed against two real rollouts (ops-os
# issue #28, this repo's #96 gate run issue-23): the subagent rollout's `session_id`
# (line 0, `session_meta`) equals the reviewer's OWN thread id, and its `id` differs —
# that difference IS the parent/child distinction: a rollout whose `id` equals its own
# `session_id` is a top-level thread, never a subagent's.
#
# NO --json NEEDED, and none is added to review-cmd.sh's argv — that would buy four
# zeroes and break worker-report.sh's stderr diagnostic (#98). Every `codex exec`
# invocation prints "session id: <uuid>" in its plain banner, UNCONDITIONALLY, and
# that banner is already captured, unconditionally, in review-stderr.log. That line
# IS the reviewer's own thread id — no new capture, just reading a file that already
# exists.
#
# Usage: bash review-tokens.sh <review-stderr-log>
#   <review-stderr-log>   the reviewer's captured stdout+stderr (spawn.sh already
#                         writes this at $RUNDIR/review-stderr.log)
#   $CODEX_SESSIONS_ROOT  override for ~/.codex/sessions (the test seam; same pattern
#                         as $CODEX_RUN_ROOT elsewhere in this plugin)
#
# Output: the subagent's LAST `token_usage_record`'s `turn_token_usage`, one line of
# compact JSON (input_tokens, cached_input_tokens, cache_write_input_tokens,
# output_tokens, reasoning_output_tokens, total_tokens) — the cumulative total for
# that review, per the field's own name.
#
# Exit 0 = found and read. Exit 1 = no "session id:" banner, no rollout joins it, or
# the joined rollout never recorded usage — loud on stderr, NOTHING on stdout. This is
# cost VISIBILITY, not a merge gate, but an invented number is still an invented
# number, so the same review-counts.sh discipline applies: unreadable is never zero.

set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }

LOG="${1:-}"
[ -n "$LOG" ] || die "usage: review-tokens.sh <review-stderr-log>"
[ -f "$LOG" ] || die "no review-stderr log at $LOG"

ROOT="${CODEX_SESSIONS_ROOT:-${HOME:-/nonexistent}/.codex/sessions}"
[ -d "$ROOT" ] || die "no codex sessions root at $ROOT"

LOG="$LOG" ROOT="$ROOT" python3 <<'PY'
import json, os, re, sys

log = os.environ["LOG"]
root = os.environ["ROOT"]

try:
    with open(log, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
except OSError as exc:
    print("error: cannot read %s: %s" % (log, exc), file=sys.stderr)
    sys.exit(1)

# The banner is `\x1b[1msession id:\x1b[0m <uuid>` — the escape codes sit OUTSIDE the
# text we match, so a plain substring-then-uuid search never has to think about them.
m = re.search(
    r"session id:.*?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})", text)
if not m:
    print('error: no "session id:" banner in %s — the reviewer\'s own thread id is '
          "unknown" % log, file=sys.stderr)
    sys.exit(1)
thread_id = m.group(1)

# Walk the whole tree rather than assume today's Y/M/D: a fix round's review can run
# after midnight relative to when the run started, and this directory is small enough
# (one user's codex history) that a full scan costs nothing worth guarding.
child = None
for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        if not (name.startswith("rollout-") and name.endswith(".jsonl")):
            continue
        path = os.path.join(dirpath, name)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                first = fh.readline()
        except OSError:
            continue
        try:
            meta = json.loads(first).get("payload", {})
        except (json.JSONDecodeError, AttributeError):
            continue
        # session_id == thread_id alone also matches the reviewer's OWN rollout (where
        # id == session_id == thread_id) — id != thread_id is what picks the subagent.
        if meta.get("session_id") == thread_id and meta.get("id") != thread_id:
            child = path
            break
    if child:
        break

if not child:
    print("error: no subagent rollout under %s joins reviewer thread %s by session_id"
          % (root, thread_id), file=sys.stderr)
    sys.exit(1)

last_usage = None
try:
    with open(child, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("type") == "token_usage_record":
                usage = rec.get("payload", {}).get("turn_token_usage")
                if usage is not None:
                    last_usage = usage
except OSError as exc:
    print("error: cannot read %s: %s" % (child, exc), file=sys.stderr)
    sys.exit(1)

if last_usage is None:
    print("error: %s recorded no token_usage_record" % child, file=sys.stderr)
    sys.exit(1)

print(json.dumps(last_usage, sort_keys=True, separators=(",", ":")))
PY
