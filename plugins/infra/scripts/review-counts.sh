#!/usr/bin/env bash
#
# review-counts.sh — read one independent-reviewer output file and print its finding counts.
#
# Usage:  bash review-counts.sh <review-file>
# Output: exactly `<H> high, <M> medium, <L> low` on stdout.
# Exit 0 = a verdict was read. Exit 1 = it could not be, NOTHING on stdout.
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
#   findings   `- [P1] <title> — <path>:<lines>` list items, one per finding
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

FILE="${1:-}"
[ -n "$FILE" ] || { echo "usage: review-counts.sh <review-file>" >&2; exit 1; }
[ -f "$FILE" ] || { echo "error: no review file at $FILE" >&2; exit 1; }

REVIEW_FILE="$FILE" python3 <<'PY'
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

marks = re.findall(r"(?m)^\s*[-*]\s*\[P([0-9])\]", text)
if not marks:
    if re.search(r"\[P[0-9]\]", text):
        print("error: the review mentions a [Pn] severity but not as a finding list item — "
              "its format has drifted and an unreadable review is not a clean one",
              file=sys.stderr)
        sys.exit(1)
    if re.search(r"(?mi)^\s*no findings\.?\s*$", text):
        # A genuinely clean review: the reviewer said so in the one shape it was given.
        print("0 high, 0 medium, 0 low")
        sys.exit(0)
    print("error: the review has no finding list items and no 'No findings.' line — "
          "its format has drifted and an unreadable review is not a clean one",
          file=sys.stderr)
    sys.exit(1)

high = sum(1 for m in marks if m in ("0", "1"))
med = sum(1 for m in marks if m == "2")
print("%d high, %d medium, %d low" % (high, med, len(marks) - high - med))
PY
