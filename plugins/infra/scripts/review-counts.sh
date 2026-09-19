#!/usr/bin/env bash
#
# review-counts.sh — read one `codex exec review` output file and print its finding counts.
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
# WHY IT PARSES PROSE. `codex exec review` cannot be asked for a machine-readable shape:
# `--base` forbids a trailing PROMPT, and `--output-schema` is accepted on a review turn
# and then SILENTLY IGNORED (ground-truthed twice — see review-cmd.sh). `--json` does not
# help either: the event stream carries the same prose in an `agent_message` and no
# structured findings event. So the review's own template is the contract:
#
#   findings   `- [P1] <title> — <path>:<lines>` list items, one per finding
#   clean      ordinary prose, exit 0, no `[Pn]` marker anywhere
#
# Severity maps P0/P1 -> high, P2 -> medium, P3+ -> low.
#
# THE ONE RULE THAT MATTERS: an unreadable file is NOT a clean one. A file that mentions a
# `[Pn]` marker but not as a list item is format drift, and drift must never be counted as
# zero findings — that is the invented-fact failure that merges unreviewed code, the whole
# reason this path exists (#96). Refusing costs a run; guessing costs a review.

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
    # A genuinely clean review: the reviewer exited 0 and said so in prose.
    print("0 high, 0 medium, 0 low")
    sys.exit(0)

high = sum(1 for m in marks if m in ("0", "1"))
med = sum(1 for m in marks if m == "2")
print("%d high, %d medium, %d low" % (high, med, len(marks) - high - med))
PY
