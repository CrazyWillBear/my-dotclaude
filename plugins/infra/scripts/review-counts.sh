#!/usr/bin/env bash
#
# review-counts.sh — read one independent-reviewer output file and print its finding counts.
#
# Usage:  bash review-counts.sh <review-file> [--findings <round> | --prior <rundir>]
# Output: exactly `<H> high, <M> medium, <L> low` on stdout.
# Exit 0 = a verdict was read. Exit 1 = it could not be, NOTHING on stdout.
#
# `--findings N` prints, instead of the counts, one line per finding in the run-dir
# ledger-entry shape `finding<TAB><round><TAB><severity><TAB><title><TAB><path:line>`
# (path empty when the item has none), nothing for a clean review, and the identical
# refusals. It is the ONLY producer of ledger finding lines (#110).
# `--prior <rundir>` checks that a scoped review restates every open finding from the
# latest ledger round by exact title and path. Missing identities refuse the verdict.
# When the scoped prompt falls back to a full review (no usable head or prior round),
# this check also falls back to ordinary counting.
#
# WHY THIS IS ITS OWN SCRIPT. Three callers need the same counts — worker-report.sh (the
# verdict the orchestrator acts on), and spawn.sh's wrapper and worker-resume.sh (the
# heading of the "Review round" comment). If those disagreed, the issue thread would say
# one thing and the merge queue would act on another. It lived inline in all three for
# about an hour and was already three copies, one of them subtly different.
#
# THE FORMAT IS THE CONTRACT. The reviewer (`claude -p` spawning my-review, built by
# review-cmd.sh — #104) is told to emit exactly this and nothing else, and the shape was
# inherited from `codex exec review`'s own template, which review-cmd.sh used to run:
#
#   findings   `- [P1] <title> — <path>:<lines>` list items, one per finding; scoped
#              re-reviews (#115) may restate a resolved finding as `[fixed]`, which is
#              never counted and becomes a `fixed` ledger entry
#   clean      the literal line `No findings.` and no `[Pn]` marker anywhere
#
# Severity maps P0/P1 -> high, P2 -> medium, P3+ -> low.
#
# THE ONE RULE THAT MATTERS: an unreadable file is NOT a clean one. A file that mentions a
# `[Pn]` marker but not as a list item is format drift; so is prose with neither a marker
# nor the clean line (a reviewer that wrote its findings as a headed list instead). Drift
# must never be counted as zero findings — that is the invented-fact failure that merges
# unreviewed code, the whole reason this path exists (#96). Refusing costs a run; guessing
# costs a review. (Codex's clean reviews were free prose; that path is retired for workers,
# which is what lets clean be pinned to a literal.)

set -uo pipefail

USAGE="usage: review-counts.sh <review-file> [--findings <round> | --prior <rundir>]"
FILE="${1:-}"
[ -n "$FILE" ] || { echo "$USAGE" >&2; exit 1; }
ROUND=""
PRIOR_DIR=""
if [ "${2:-}" = "--findings" ]; then
    ROUND="${3:-}"
    case "$ROUND" in ''|*[!0-9]*) echo "$USAGE" >&2; exit 1 ;; esac
elif [ "${2:-}" = "--prior" ]; then
    PRIOR_DIR="${3:-}"
    [ -n "$PRIOR_DIR" ] || { echo "$USAGE" >&2; exit 1; }
elif [ -n "${2:-}" ]; then
    echo "$USAGE" >&2; exit 1
fi
[ -f "$FILE" ] || { echo "error: no review file at $FILE" >&2; exit 1; }

REVIEW_FILE="$FILE" LEDGER_ROUND="$ROUND" PRIOR_DIR="$PRIOR_DIR" python3 <<'PY'
from collections import Counter
import os, re, sys

try:
    with open(os.environ["REVIEW_FILE"], encoding="utf-8", errors="replace") as fh:
        text = fh.read()
except OSError as exc:
    print("error: cannot read review file: %s" % exc, file=sys.stderr)
    sys.exit(1)

if not text.strip():
    print("error: the review file is empty — the reviewer produced no verdict",
          file=sys.stderr)
    sys.exit(1)

ROUND = os.environ.get("LEDGER_ROUND", "")
PRIOR_DIR = os.environ.get("PRIOR_DIR", "")

def sev(p):
    return "high" if p in ("0", "1") else "medium" if p == "2" else "low"

items = re.findall(r"(?m)^[ \t]*[-*][ \t]*\[(P[0-9]|fixed)\][ \t]*(.*)$", text)
marks = [m[1:] for m, _ in items if m != "fixed"]
if len(re.findall(r"\[P[0-9]\]", text)) != len(marks):
    print("error: the review mentions a [Pn] severity but not as a finding list item — "
          "its format has drifted and an unreadable review is not a clean one",
          file=sys.stderr)
    sys.exit(1)

if PRIOR_DIR:
    try:
        with open(os.path.join(PRIOR_DIR, "reviewed-head"), encoding="utf-8") as fh:
            head = fh.readline().strip()
        with open(os.path.join(PRIOR_DIR, "rounds"), encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        head, lines = "", []
    headers = [line.split(" ", 1)[0] for line in lines if line[:1].isdigit()]
    last = headers[-1] if headers else ""
    previous = Counter()
    if re.fullmatch(r"[0-9a-f]{7,}", head) and last:
        for line in lines:
            fields = line.split("\t")
            if len(fields) >= 5 and fields[0] == "finding" and fields[1] == last and fields[2] != "fixed":
                previous[(fields[3], fields[4])] += 1
    if previous:
        restated = Counter()
        for _, rest in items:
            title, sep, loc = rest.rpartition(" — ")
            if not sep:
                title, loc = rest, ""
            restated[(" ".join(title.split()), " ".join(loc.split()))] += 1
        missing = previous - restated
        if missing:
            title, loc = next(iter(missing))
            print("error: scoped review omitted prior finding %s — %s" % (title, loc),
                  file=sys.stderr)
            sys.exit(1)

if not items:
    if text.strip() == "No findings.":
        # A genuinely clean review: the ENTIRE output is the one literal it was given.
        # Anything around it is a reviewer that ignored its format, and that is refused.
        if not ROUND:
            print("0 high, 0 medium, 0 low")
        sys.exit(0)
    print("error: the review has no finding list items and no 'No findings.' line — "
          "its format has drifted and an unreadable review is not a clean one",
          file=sys.stderr)
    sys.exit(1)

if ROUND:
    for m, rest in items:
        # The location is whatever follows the LAST spaced em dash; a title may hold one.
        title, sep, loc = rest.rpartition(" — ")
        if not sep:
            title, loc = rest, ""
        print("finding\t%s\t%s\t%s\t%s"
              % (ROUND, "fixed" if m == "fixed" else sev(m[1:]),
                 " ".join(title.split()), " ".join(loc.split())))
    sys.exit(0)

high = sum(1 for m in marks if sev(m) == "high")
med = sum(1 for m in marks if sev(m) == "medium")
print("%d high, %d medium, %d low" % (high, med, len(marks) - high - med))
PY
