#!/usr/bin/env bash
#
# Append one code-review result to the project's review history.
#
# Reads a JSON object on stdin, e.g.:
#   {"verdict": "CHANGES REQUESTED",
#    "files": ["/abs/a.py"],
#    "findings": [{"severity": "blocker", "path": "/abs/a.py",
#                  "line": 12, "note": "unchecked null deref"}]}
#
# Stamps it with a UTC timestamp + session id and appends one JSON line to
# ${CLAUDE_PROJECT_DIR}/.claude/review-history.jsonl. Fails open: any bad input
# or write error exits 0 so it never wedges the session.

export REVIEW_INPUT="$(cat)"

# No python3? Stay silent — this is a fire-and-forget recorder — and exit 0.
command -v python3 >/dev/null 2>&1 || exit 0

# Every error path inside the program exits 0 on its own (fail-open). The
# trailing `|| exit 0` is a last-resort guard for the interpreter itself failing
# to start, so a recording hiccup never wedges the session.
python3 -c '
import os, json, sys, datetime

raw = os.environ.get("REVIEW_INPUT", "")
try:
    data = json.loads(raw) if raw.strip() else None
except Exception:
    data = None
if not isinstance(data, dict):
    sys.stderr.write("record-review: ignoring missing or malformed JSON input\n")
    sys.exit(0)

files = data.get("files")
if isinstance(files, str):
    files = [files]
files = [str(x) for x in files] if isinstance(files, list) else []

findings = []
raw_findings = data.get("findings")
if isinstance(raw_findings, list):
    for f in raw_findings:
        if not isinstance(f, dict):
            continue
        line = f.get("line")
        findings.append({
            "severity": str(f.get("severity", "")).strip().lower(),
            "path": str(f.get("path", "")),
            "line": line if isinstance(line, int) else None,
            "note": str(f.get("note", ""))[:300],
        })

entry = {
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "session": os.environ.get("CLAUDE_SESSION_ID", ""),
    "verdict": str(data.get("verdict", "")).strip(),
    "files": files,
    "findings": findings,
}

project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
out_dir = os.path.join(project_dir, ".claude")
out_path = os.path.join(out_dir, "review-history.jsonl")
try:
    os.makedirs(out_dir, exist_ok=True)
    with open(out_path, "a") as fh:
        fh.write(json.dumps(entry) + "\n")
except Exception as e:
    sys.stderr.write("record-review: could not write history: %s\n" % e)
    sys.exit(0)
' || exit 0
