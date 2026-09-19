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
# The orchestrator still does not poll. It makes ONE blocking call — per worker, or per
# SET with --any — and gets back the same one-line report it already branches on, so the
# admission loop's handling of built / fixed / failed / escalate is unchanged.
#
# Usage:
#   bash worker-report.sh <runid> <issue> [--interval S] [--timeout S]
#   bash worker-report.sh --any <runid> <issue> [issue ...] [--interval S] [--timeout S]
#
#     --any          wait on the SET and report the FIRST worker to finish, rather than
#                    blocking on one named worker. Builds run in parallel either way —
#                    what the single form serialises is SCHEDULING: a fast issue queued
#                    behind a slow one cannot free its admission slot until the slow one
#                    is done. Pass the issues still IN FLIGHT and drop each one as it
#                    reports; a worker that already reported stays terminal forever, so
#                    leaving it in the set returns it again instead of waiting.
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

ANY=""
if [ "${1:-}" = --any ]; then ANY=1; shift; fi

RUNID="${1:-}"
[ $# -eq 0 ] || shift
INTERVAL=10
TIMEOUT=7200
ISSUES=""

# Positionals after the runid are issue numbers; anything starting with `-` is a flag.
# The old parser died on ANY extra positional, so nothing that worked before changes
# shape here — a bare `--bogus` still dies as an unknown flag rather than being read
# as an issue.
while [ $# -gt 0 ]; do
    case "$1" in
        --interval) [ $# -ge 2 ] || die "--interval needs a value"; INTERVAL="$2"; shift 2 ;;
        --timeout)  [ $# -ge 2 ] || die "--timeout needs a value";  TIMEOUT="$2";  shift 2 ;;
        -*)         die "unknown flag $1" ;;
        *)          ISSUES="${ISSUES:+$ISSUES }$1"; shift ;;
    esac
done

USAGE="usage: worker-report.sh <runid> <issue> [--interval S] [--timeout S]
       worker-report.sh --any <runid> <issue> [issue ...] [--interval S] [--timeout S]"
[ -n "$RUNID" ] && [ -n "$ISSUES" ] || die "$USAGE"
# Without --any this script reports exactly ONE worker. A second number means the caller
# wanted --any and did not say so: reporting the first and silently dropping the rest
# would leave those workers with nobody waiting on them, which is the same stranding
# --any exists to prevent.
if [ -z "$ANY" ]; then
    case "$ISSUES" in *\ *) die "more than one issue needs --any: $USAGE" ;; esac
fi
for i in $ISSUES; do
    case "$i" in ''|*[!0-9]*) die "issue must be a number, got '$i'" ;; esac
done
case "$INTERVAL" in ''|*[!0-9]*) die "--interval must be a number, got '$INTERVAL'" ;; esac
case "$TIMEOUT"  in ''|*[!0-9]*) die "--timeout must be a number, got '$TIMEOUT'" ;; esac
# Same guard as spawn.sh and run-log.sh: $RUNID is joined into a filesystem path below.
case "$RUNID" in *[!A-Za-z0-9._-]*) die "runid may only contain [A-Za-z0-9._-], got '$RUNID'" ;; esac
[ "$INTERVAL" -gt 0 ] || die "--interval must be greater than 0"

[ -f "$INFRA/session-status.sh" ] || die "missing infra sibling: $INFRA/session-status.sh"

CODEX_ROOT="${CODEX_RUN_ROOT:-${HOME:-/nonexistent}/.claude/codex-runs}/$RUNID"
# Fail now rather than after a 2-hour wait. No run dir means no codex worker was ever
# spawned for this issue — a caller that reached here with a claude-backed worker is
# asking the wrong question, and should be told so immediately. EVERY issue in the set
# is checked: one claude-backed number mixed into an --any set would otherwise just
# never match, and the whole call would time out with nothing to show for it.
for i in $ISSUES; do
    [ -d "$CODEX_ROOT/issue-$i" ] || \
        die "no codex run dir for issue $i: $CODEX_ROOT/issue-$i (is this worker codex-backed?)"
done

START=$SECONDS
ISSUE=""
STATE=""

while : ; do
    OUT="$(bash "$INFRA/session-status.sh" "$RUNID" 2>/dev/null)"
    # Column 3 is the backend, column 4 the state. Filtering on `codex` keeps a CLAUDE
    # session sharing the run prefix out of the answer: it reports over SendMessage and
    # has no last-message.txt, so rendering it here would exit 1 on a worker that is
    # perfectly healthy. A row that is not terminal, or not in the asked-for set, simply
    # does not match and the loop waits — the same "keep waiting rather than guess" the
    # single-worker form had for an unknown state spelling.
    HIT="$(printf '%s\n' "$OUT" | awk -v pre="orch-$RUNID-issue-" -v want=" $ISSUES " '
        BEGIN { plen = length(pre) }
        $3 == "codex" && ($4 == "done" || $4 == "failed") && substr($1, 1, plen) == pre {
            n = substr($1, plen + 1)
            if (index(want, " " n " ") > 0) { print n " " $4; exit }
        }')"
    if [ -n "$HIT" ]; then
        ISSUE="${HIT%% *}"
        STATE="${HIT##* }"
        break
    fi

    if [ "$TIMEOUT" -gt 0 ] && [ $((SECONDS - START)) -ge "$TIMEOUT" ]; then
        die "timed out after ${TIMEOUT}s waiting for issue $ISSUES — \
the worker may still be running; nothing was reported"
    fi
    sleep "$INTERVAL"
done

RUNDIR="$CODEX_ROOT/issue-$ISSUE"

# Terminal. The report is the schema'd final message; on a crash there may be none, and
# then stderr.log is the only place the reason lands (README § Two backends).
REPORT_ISSUE="$ISSUE" REPORT_STATE="$STATE" REPORT_DIR="$RUNDIR" REPORT_INFRA="$INFRA" \
    python3 <<"PY"
import json, os, re, subprocess, sys

issue = int(os.environ["REPORT_ISSUE"])
state = os.environ["REPORT_STATE"]
rundir = os.environ["REPORT_DIR"]
infra = os.environ["REPORT_INFRA"]

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

def independent_review():
    # THE VERDICT COMES FROM THE REVIEWER, NEVER FROM THE WORKER. review.txt is the
    # final message of the sibling `codex exec review` process that
    # spawn.sh/worker-resume.sh run AFTER the worker exits; the worker cannot write it and
    # is told to report an empty `review`.
    #
    # This is the fix for what #96's e2e gate caught: the worker used to run the review
    # itself, that nested call could never start inside its sandbox, and it filled the
    # required field with its own opinion of its own diff — reporting a clean independent
    # review that had never run. Taking the counts from the reviewer's own output makes
    # that substitution impossible rather than merely discouraged.
    #
    # The counting lives in review-counts.sh, not here: spawn.sh's wrapper and
    # worker-resume.sh put the SAME counts in the "Review round" comment's heading, and a
    # private second implementation here is how the issue thread and the merge queue would
    # end up disagreeing about what the review found. That script also owns the rule that
    # an UNREADABLE review is refused rather than counted as clean.
    path = os.path.join(rundir, "review.txt")
    if not os.path.exists(path):
        return ""
    try:
        out = subprocess.run(["bash", os.path.join(infra, "review-counts.sh"), path],
                             capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""

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
    # `head` is worker-controlled and lands in a SPACE-DELIMITED line the orchestrator
    # parses positionally, so one carrying its own " review=..." could smuggle a second,
    # cleaner review into the report. The worker is told to read the issue's comments, which
    # anyone can write, so this is an untrusted-input path and not a hypothetical.
    # VALIDATED BEFORE THE REVIEW IS LOOKED UP: the worker's own report has to be coherent
    # before the reviewer's verdict on it means anything, and a run that fails both should
    # name the defect the worker is actually responsible for.
    if not re.match(r"^[0-9a-f]{7,40}$", head):
        print("error: issue %d reported a head that is not a sha: %r" % (issue, head),
              file=sys.stderr)
        sys.exit(1)
    # A worker that filled in `review` disobeyed its prompt — it is told to send "" — and
    # the value is DISCARDED rather than trusted, because a worker grading its own diff is
    # the failure this whole path exists to prevent. Say so on stderr: it means the prompt
    # and the worker have drifted, which is worth seeing even though it changes nothing.
    if review:
        print("warning: issue %d reported its own review %r — discarded; the independent "
              "reviewer's verdict is the only one used" % (issue, review), file=sys.stderr)
    # An ABSENT review is not a CLEAN review. review.txt is missing when the reviewer never
    # ran or failed (both callers DELETE a failed one), and unparseable when it ran but
    # never emitted its COUNTS line. Defaulting either to "0 high, 0 medium, 0 low" would
    # INVENT the single fact that decides whether the issue takes another fix round or goes
    # straight to the merge queue. Same reasoning as the empty head above: unknown is
    # exit 1, never a cheerful default.
    review = independent_review()
    if not review:
        # The reason lives in review-stderr.log — the reviewer's own output, the
        # containment tripwire's refusal, or a schema the turn did not honour. Without it
        # this error says only that something went wrong, for every one of those causes.
        why = flat(read("review-stderr.log")[-300:]) if read("review-stderr.log") else \
            "no reviewer output recorded"
        print("error: issue %d reported %s but no independent review was recorded in "
              "review.txt — a review that did not run is not a clean one: %s"
              % (issue, status, why), file=sys.stderr)
        sys.exit(1)
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
