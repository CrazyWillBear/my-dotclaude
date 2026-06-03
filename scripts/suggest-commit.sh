#!/usr/bin/env bash
#
# Stop hook for the team-code-review plugin.
#
# Advisory commit nudge. Reads the hook payload from stdin and — when the
# uncommitted tracked work looks worth a commit (a large diff, or a plan that
# was approved and then implemented) — emits a soft "block" decision suggesting
# the agent commit the batch (via /commit or by hand). It never commits anything
# itself; it only suggests.
#
# This hook is registered BEFORE scripts/review.sh in hooks.json. Both are soft
# and independent: neither suppresses the other, and "consider committing" plus
# "review these files" are different concerns that can both surface on one stop.
#
# Design notes (mirrors review.sh):
#   * Hooks are plain shell commands; they cannot commit or call tools for the
#     user. So we hand the main agent a suggestion instead of acting.
#   * We always "fail open": any error / missing dependency exits 0 so we never
#     wedge the user's session.
#   * Deduped once per batch: we record the current HEAD per session and stay
#     silent until a new commit moves HEAD, so we nudge at most once per batch.

# Capture the hook JSON into an env var (avoids stdin/quoting headaches in python).
export HOOK_INPUT="$(cat)"

# No python3 or git? Don't block the user — just bow out quietly.
command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Quoted heredoc so literal punctuation in the script body can never break
# shell quoting. HOOK_INPUT travels via the environment, so stdin stays free.
python3 <<"PY" || exit 0
import os, json, sys, subprocess, tempfile, hashlib

# Tunable thresholds for the size signal.
FILE_THRESHOLD = 3    # suggest once this many tracked files have changed, or
LINE_THRESHOLD = 80   # this many added+deleted lines across them.

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

# numstat counts staged + unstaged *tracked* changes only — untracked/new files
# are not counted. That is deliberate and matches the /commit skill this nudge
# points at (it stages tracked changes with git add -u and leaves untracked
# files alone), so a batch of only-new files is never nudged.
file_count = 0
line_count = 0
for row in numstat.splitlines():
    row = row.strip()
    if not row:
        continue
    parts = row.split("\t")
    if len(parts) < 3:
        continue
    file_count += 1
    added, deleted = parts[0], parts[1]
    if added.isdigit():
        line_count += int(added)
    if deleted.isdigit():
        line_count += int(deleted)

# Nothing tracked changed → never suggest committing.
if file_count == 0:
    sys.exit(0)

# Size signal: enough files OR enough churn.
size_signal = file_count >= FILE_THRESHOLD or line_count >= LINE_THRESHOLD

# Plan signal: a plan was approved (ExitPlanMode tool_use in the transcript) and
# tracked changes now exist. Approximate — we cannot truly verify a plan is done.
# Only worth scanning when the size signal has not already fired, since the
# transcript can be large and the plan signal cannot change an already-true result.
plan_signal = False
transcript = data.get("transcript_path", "")
if not size_signal and transcript and os.path.isfile(transcript):
    try:
        with open(transcript, "r", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                msg = entry.get("message")
                if not isinstance(msg, dict):
                    continue
                content = msg.get("content")
                if not isinstance(content, list):
                    continue
                for block in content:
                    if (isinstance(block, dict)
                            and block.get("type") == "tool_use"
                            and block.get("name") == "ExitPlanMode"):
                        plan_signal = True
                        break
                if plan_signal:
                    break
    except Exception:
        plan_signal = False

if not (size_signal or plan_signal):
    sys.exit(0)

# Dedupe ("once per batch"): per-session state file keyed by session_id, storing
# the HEAD we last suggested at. Same HEAD → already nudged this batch → silent.
# A commit moves HEAD, so the next batch is eligible again.
session_id = str(data.get("session_id") or "default")
key = hashlib.sha1(session_id.encode()).hexdigest()[:16]
state_path = os.path.join(tempfile.gettempdir(), "team-code-review-commit-" + key + ".json")

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

# Build one message that folds both signals into a single suggestion.
if line_count:
    churn = str(file_count) + " file(s), ~" + str(line_count) + " changed line(s)"
else:
    churn = str(file_count) + " file(s)"

if plan_signal:
    lead = "A planned change looks implemented and " + churn + " of tracked work is uncommitted."
else:
    lead = churn + " of tracked work is uncommitted."

reason = (
    "Heads up (team-code-review commit nudge): " + lead
    + " If this is a good stopping point, consider committing this batch — run "
    + "/commit to have the committer subagent write the message and commit the "
    + "tracked changes, or commit yourself. If it is not a good stopping point, "
    + "ignore this and keep going; you will not be nudged again until the next commit."
)

print(json.dumps({"decision": "block", "reason": reason}))
sys.exit(0)
PY
