#!/usr/bin/env bash
#
# Summarize this project's code-review history.
#
# Reads ${CLAUDE_PROJECT_DIR}/.claude/review-history.jsonl (written by
# record-review.sh) and prints aggregate metrics plus the most recent reviews.
# Optional first arg: how many recent entries to show (default 10).

# Unlike the silent recorder, this is a user-facing command, so if python3 is
# missing we say so rather than exiting quietly.
command -v python3 >/dev/null 2>&1 || { echo "python3 not found; cannot read review history."; exit 0; }

export RH_RECENT="${1:-10}"

python3 -c '
import os, json, sys
from collections import Counter

project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
path = os.path.join(project_dir, ".claude", "review-history.jsonl")
if not os.path.isfile(path):
    print("No review history yet (%s)." % path)
    sys.exit(0)

entries = []
with open(path, errors="ignore") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except Exception:
            continue

if not entries:
    print("No review history yet.")
    sys.exit(0)

try:
    recent_n = max(1, int(os.environ.get("RH_RECENT", "10")))
except ValueError:
    recent_n = 10

sev_total = Counter()
verdict_total = Counter()
file_hits = Counter()
for e in entries:
    verdict_total[e.get("verdict") or "(none)"] += 1
    for f in (e.get("findings") or []):
        sev = (f.get("severity") or "").lower()
        if sev:
            sev_total[sev] += 1
        p = f.get("path") or ""
        if p and sev in ("blocker", "warning"):
            file_hits[p] += 1

print("Code review history -- %d review(s)" % len(entries))
print()
print("Findings by severity:")
for sev in ("blocker", "warning", "nit"):
    print("  %-8s %d" % (sev, sev_total.get(sev, 0)))
print()
print("Verdicts:")
for v, n in verdict_total.most_common():
    print("  %-22s %d" % (v, n))

if file_hits:
    print()
    print("Files with the most blocker/warning findings:")
    for p, n in file_hits.most_common(5):
        print("  %3d  %s" % (n, p))

print()
print("Recent reviews (last %d):" % recent_n)
for e in entries[-recent_n:][::-1]:
    c = Counter((f.get("severity") or "").lower() for f in (e.get("findings") or []))
    counts = ", ".join("%d %s" % (c[s], s) for s in ("blocker", "warning", "nit") if c.get(s)) or "no findings"
    nfiles = len(e.get("files") or [])
    print("  %s  %-20s  %s  (%d file%s)" % (
        e.get("ts", "?"), e.get("verdict") or "(none)", counts,
        nfiles, "" if nfiles == 1 else "s"))
'
