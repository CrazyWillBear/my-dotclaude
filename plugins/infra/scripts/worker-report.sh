#!/usr/bin/env bash
#
# worker-report.sh — block until one CODEX worker finishes, then print its report in the
# session lane's own vocabulary.
#
# WHY THIS EXISTS. A claude worker reports with `SendMessage`: the orchestrator subscribes
# at spawn with `notify_when_idle` and the next thing that happens is a message. A
# `codex exec` worker is a PROCESS — no inbox, no SendMessage — and its report is the
# schema'd final message in `last-message.txt`, which NOTHING read before this script
# (#96). A flipped roster without this leaves the orchestrator waiting on a session that
# does not exist, forever. That is why the roster flip was held.
#
# The orchestrator still does not poll. It makes ONE blocking call per worker and gets
# back the same one-line report it already branches on, so the admission loop's handling
# of built / fixed / failed / escalate is unchanged.
#
# Usage:
#   bash worker-report.sh <runid> <issue> [--interval S] [--timeout S]
#
#     --interval S   seconds between state reads (default 10)
#     --timeout  S   give up after S seconds (default 7200; 0 waits forever)
#
# Output: EXACTLY ONE line on stdout, one of —
#   issue <N> built head=<sha> review=<H high, M medium, L low>
#   issue <N> fixed round=<K> head=<sha> review=<H high, M medium, L low>
#   issue <N> failed <one short line why>
#   issue <N> escalate <question>
#
# Exit codes:
#   0  a report was printed. `failed` and `escalate` ARE reports — the orchestrator has a
#      branch for each, so they are this script succeeding, not this script failing.
#   1  NO report could be produced: bad usage, no run dir, a timeout, or a worker that
#      finished without a readable report. Loud on stderr, and NOTHING on stdout.
#
# That split is the whole safety property. A timeout or an unreadable report must never
# reach the orchestrator looking like a result: it would merge a branch nothing built, or
# mark an issue clean that was never reviewed. When this script cannot say what happened,
# it says nothing on stdout and exits 1.
#
# State comes from session-status.sh rather than a second copy of the pid/exit rules.
# Those rules are subtle in exactly the places that matter — a worker caught mid-launch
# is `busy`, a dead pid with no exit file is `failed` and never a quiet `done` — and a
# private second implementation here is the half that silently rots.

set -uo pipefail

INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "error: $*" >&2; exit 1; }

RUNID="${1:-}"; ISSUE="${2:-}"
shift 2 2>/dev/null || true
INTERVAL=10
TIMEOUT=7200

while [ $# -gt 0 ]; do
    case "$1" in
        --interval) [ $# -ge 2 ] || die "--interval needs a value"; INTERVAL="$2"; shift 2 ;;
        --timeout)  [ $# -ge 2 ] || die "--timeout needs a value";  TIMEOUT="$2";  shift 2 ;;
        *)          die "unknown flag $1" ;;
    esac
done

[ -n "$RUNID" ] && [ -n "$ISSUE" ] || die "usage: worker-report.sh <runid> <issue> [--interval S] [--timeout S]"
case "$ISSUE"    in ''|*[!0-9]*) die "issue must be a number, got '$ISSUE'" ;; esac
case "$INTERVAL" in ''|*[!0-9]*) die "--interval must be a number, got '$INTERVAL'" ;; esac
case "$TIMEOUT"  in ''|*[!0-9]*) die "--timeout must be a number, got '$TIMEOUT'" ;; esac
# Same guard as spawn.sh and run-log.sh: $RUNID is joined into a filesystem path below.
case "$RUNID" in *[!A-Za-z0-9._-]*) die "runid may only contain [A-Za-z0-9._-], got '$RUNID'" ;; esac
[ "$INTERVAL" -gt 0 ] || die "--interval must be greater than 0"

[ -f "$INFRA/session-status.sh" ] || die "missing infra sibling: $INFRA/session-status.sh"

RUNDIR="${CODEX_RUN_ROOT:-$HOME/.claude/codex-runs}/$RUNID/issue-$ISSUE"
# Fail now rather than after a 2-hour wait. No run dir means no codex worker was ever
# spawned for this issue — a caller that reached here with a claude-backed worker is
# asking the wrong question, and should be told so immediately.
[ -d "$RUNDIR" ] || die "no codex run dir for issue $ISSUE: $RUNDIR (is this worker codex-backed?)"

NAME="orch-$RUNID-issue-$ISSUE"
START=$SECONDS
STATE=""

while : ; do
    OUT="$(bash "$INFRA/session-status.sh" "$RUNID" 2>/dev/null)"
    STATE="$(printf '%s\n' "$OUT" | awk -v n="$NAME" '$1 == n { print $4 }' | head -1)"

    case "$STATE" in
        done|failed) break ;;
        busy|"")     ;;   # "" == not listed yet; the run dir exists, so it is coming
        *)           ;;   # any other spelling: keep waiting rather than guess
    esac

    if [ "$TIMEOUT" -gt 0 ] && [ $((SECONDS - START)) -ge "$TIMEOUT" ]; then
        die "timed out after ${TIMEOUT}s waiting for issue $ISSUE (last state: ${STATE:-unlisted}) — \
the worker may still be running; nothing was reported"
    fi
    sleep "$INTERVAL"
done

# Terminal. The report is the schema'd final message; on a crash there may be none, and
# then stderr.log is the only place the reason lands (README § Two backends).
REPORT_ISSUE="$ISSUE" REPORT_STATE="$STATE" REPORT_DIR="$RUNDIR" python3 <<"PY"
import json, os, sys

issue = int(os.environ["REPORT_ISSUE"])
state = os.environ["REPORT_STATE"]
rundir = os.environ["REPORT_DIR"]

def flat(s):
    # The orchestrator parses ONE line. A note carrying a traceback would otherwise
    # desync the lane, and a blank one would produce a report that says nothing.
    return " ".join(str(s).split()) or "(no reason given)"

def read(name):
    try:
        with open(os.path.join(rundir, name)) as fh:
            return fh.read().strip()
    except OSError:
        return ""

raw = read("last-message.txt")

if not raw:
    # No report at all. If codex exited non-zero this is the expected shape of a crash,
    # and the run is still reportable: `failed` plus whatever stderr caught. If it exited
    # CLEAN with no report, something is wrong we cannot characterise — refuse to invent
    # a result, because the caller would read any line here as a real outcome.
    if state == "failed":
        tail = flat(read("stderr.log")[-500:]) if read("stderr.log") else "no reason recorded"
        print("issue %d failed %s" % (issue, tail))
        sys.exit(0)
    print("error: issue %d finished clean but wrote no report to last-message.txt" % issue,
          file=sys.stderr)
    sys.exit(1)

try:
    r = json.loads(raw)
    if not isinstance(r, dict):
        raise ValueError("not a JSON object")
except Exception as exc:
    # --output-schema is what makes the final message machine-readable; if it did not
    # hold, the honest answer is that we do not know what happened.
    print("error: issue %d wrote an unreadable report (%s): %s"
          % (issue, exc, flat(raw)[:200]), file=sys.stderr)
    sys.exit(1)

status = str(r.get("status", "")).strip()
head   = flat(r.get("head", "")) if r.get("head") else ""
review = flat(r.get("review", "")) if r.get("review") else ""
note   = flat(r.get("note", ""))

# The worker names the issue in its own report; trust the caller's number over it, but
# say so, because a mismatch means the prompt and the spawn disagree about who is who.
try:
    if int(r.get("issue", issue)) != issue:
        print("warning: issue %d reported itself as %s" % (issue, r.get("issue")),
              file=sys.stderr)
except (TypeError, ValueError):
    pass

if status in ("built", "fixed"):
    # A clean exit that reports built/fixed but names no commit is not a success: the
    # merge queue would take a branch with nothing on it.
    if not head:
        print("error: issue %d reported %s with no head sha" % (issue, status), file=sys.stderr)
        sys.exit(1)
    if not review:
        review = "0 high, 0 medium, 0 low"
    if status == "fixed":
        try:
            rnd = int(r.get("round", 0))
        except (TypeError, ValueError):
            rnd = 0
        if rnd < 1:
            print("error: issue %d reported fixed with no round number" % issue, file=sys.stderr)
            sys.exit(1)
        print("issue %d fixed round=%d head=%s review=%s" % (issue, rnd, head, review))
    else:
        print("issue %d built head=%s review=%s" % (issue, head, review))
    sys.exit(0)

if status == "failed":
    print("issue %d failed %s" % (issue, note))
    sys.exit(0)

if status == "escalate":
    # Resumable: the thread outlives the process, so the answer goes back with
    # `codex exec resume`. See README § Escalation on a codex worker.
    print("issue %d escalate %s" % (issue, note))
    sys.exit(0)

print("error: issue %d reported an unknown status %r" % (issue, status), file=sys.stderr)
sys.exit(1)
PY
