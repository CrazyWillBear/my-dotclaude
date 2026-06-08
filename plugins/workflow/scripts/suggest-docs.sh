#!/usr/bin/env bash
#
# Docs-staleness nudge — a Stop hook for the workflow plugin.
#
# When a batch changed code but touched NO docs, give a soft "heads up — docs may
# be stale" so the docs get folded into the same commit. It never edits or commits
# anything itself: a Stop hook can only refuse the stop and hand the agent a
# suggestion. The block + per-HEAD dedupe means it fires at most once per batch.
#
# This is an independent soft nudge that rides out on the same Stop batch as the
# watchdog — cross-plugin Stop ordering does not matter, since each surfaces its
# own advisory and none suppresses another.
#
# Design notes:
#   * Hooks are plain shell; they cannot edit docs or call tools for the user. So
#     we hand the main agent a suggestion instead of acting.
#   * Fail open: any error / missing dependency exits 0 so we never wedge a session.
#   * Deduped once per batch: we record the current HEAD per session and stay
#     silent until a commit moves HEAD, so we nudge at most once per batch.

# Capture the hook JSON into an env var (avoids stdin/quoting headaches in python).
export HOOK_INPUT="$(cat)"

# No python3 or git? Don't block the user — just bow out quietly.
command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Quoted heredoc so literal punctuation in the script body can never break
# shell quoting. HOOK_INPUT travels via the environment, so stdin stays free.
python3 <<"PY" || exit 0
import os, json, sys, subprocess, tempfile, hashlib

# Optional churn guard (default OFF -> nudge on ANY non-doc change). A noisy repo
# can require a minimum: with either set, fire only past that many non-doc files
# OR that many added+deleted lines.
def _int_env(name, default):
    try:
        return int(os.environ.get(name) or default)
    except Exception:
        return default

FILE_THRESHOLD = _int_env("DOCS_FILE_THRESHOLD", 0)
LINE_THRESHOLD = _int_env("DOCS_LINE_THRESHOLD", 0)

raw = os.environ.get("HOOK_INPUT", "")
try:
    data = json.loads(raw) if raw else {}
except Exception:
    sys.exit(0)

# If this stop is itself a continuation from a previous stop-hook block, we
# already ran this turn. Stay silent to avoid looping.
if data.get("stop_hook_active"):
    sys.exit(0)

project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()

def git(*args):
    # Run a git command in the project dir; return stripped stdout, or None on
    # any failure (not a repo, git error, etc.). Never raises.
    try:
        out = subprocess.run(
            ["git", "-C", project_dir, *args],
            capture_output=True, text=True, timeout=10,
        )
    except Exception:
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip()

# Bail if this is not a work tree.
if git("rev-parse", "--is-inside-work-tree") != "true":
    sys.exit(0)

# Current HEAD ("none" before the first commit) — used as the dedupe key below.
current_head = git("rev-parse", "HEAD") or "none"

# Measure tracked changes since HEAD. numstat is one row per file:
#   <added>\t<deleted>\t<path>   (added/deleted are "-" for binary files)
numstat = git("diff", "--numstat", "HEAD")
if numstat is None:
    sys.exit(0)

# Classify each changed path. A *.md (case-insensitive) is a doc; everything else
# is code/config. We fire ONLY when code changed and NO doc was touched.
doc_count = 0
nondoc_count = 0
nondoc_lines = 0
for row in numstat.splitlines():
    row = row.strip()
    if not row:
        continue
    parts = row.split("\t")
    if len(parts) < 3:
        continue
    added, deleted, path = parts[0], parts[1], parts[2]
    if path.lower().endswith(".md"):
        doc_count += 1
        continue
    nondoc_count += 1
    if added.isdigit():
        nondoc_lines += int(added)
    if deleted.isdigit():
        nondoc_lines += int(deleted)

# A doc was touched (docs already being updated) OR nothing non-doc changed ->
# nothing to nudge about.
if doc_count > 0 or nondoc_count == 0:
    sys.exit(0)

# Optional churn guard: if either threshold is set, require enough non-doc churn.
if FILE_THRESHOLD or LINE_THRESHOLD:
    if not (nondoc_count >= FILE_THRESHOLD or nondoc_lines >= LINE_THRESHOLD):
        sys.exit(0)

# Dedupe ("once per batch"): per-session state file keyed by session_id, storing
# the HEAD we last nudged at. Same HEAD -> already nudged this batch -> silent.
# A commit moves HEAD, so the next batch is eligible again.
session_id = str(data.get("session_id") or "default")
key = hashlib.sha1(session_id.encode()).hexdigest()[:16]
state_path = os.path.join(tempfile.gettempdir(), "workflow-docs-" + key + ".json")

try:
    with open(state_path) as fh:
        last = json.load(fh)
except Exception:
    last = {}

if isinstance(last, dict) and last.get("head") == current_head:
    sys.exit(0)

try:
    with open(state_path, "w") as fh:
        json.dump({"head": current_head}, fh)
except Exception:
    pass

if nondoc_lines:
    churn = str(nondoc_count) + " file(s), ~" + str(nondoc_lines) + " changed line(s)"
else:
    churn = str(nondoc_count) + " file(s)"

reason = (
    "Heads up (workflow docs nudge): this batch changed code (" + churn + ") "
    "but no docs (README, plugin docs, SKILL.md, CLAUDE.md). If the behavior or "
    "usage changed, update the relevant docs and fold them into this commit; "
    "otherwise ignore — you won't be nudged again until the next commit."
)

print(json.dumps({"decision": "block", "reason": reason}))
sys.exit(0)
PY
