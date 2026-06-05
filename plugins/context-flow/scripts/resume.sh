#!/usr/bin/env bash
#
# SessionStart auto-resume for the context-flow plugin.
#
# The other half of the handoff loop. When the watchdog gates a plan start
# (Phase A) or prompts a post-wrap compact (Phase C), it writes
# ~/.claude/.pending-handoff and tells the user to run /clear or /compact. Both
# of those fire SessionStart (source=clear / source=compact). This hook reads the
# handoff and, if we are in the same repo it came from, re-injects the plan so the
# user only ever has to type the one command plus a kickoff word:
#
#   * source=clear   (Phase A) -> "implement the plan @path" wording. Fresh
#     context, so the agent starts the plan from the committed baseline.
#   * source=compact (Phase C) -> "continue the plan @path" wording, AND reset the
#     Phase-B/C sentinels for this session so a later climb back over the nudge
#     threshold can drive a SECOND wrap -> /compact cycle in the same long session.
#   * anything else  (startup/resume) -> treated as "continue" (graceful fallback).
#
# Fail open: any error exits 0. If we are NOT in the handoff's repo, leave the
# handoff untouched and stay silent, so a launch in another project never steals
# or drops it. context-flow no longer touches my-code-review state — the reviewer
# is never deferred now, so my-code-review's own SessionStart seeding suffices.

export HOOK_INPUT="$(cat)"

command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

python3 <<"PY" || exit 0
import os, json, sys, hashlib, tempfile, subprocess

raw = os.environ.get("HOOK_INPUT", "")
try:
    data = json.loads(raw) if raw else {}
except Exception:
    sys.exit(0)

handoff_path = os.path.expanduser("~/.claude/.pending-handoff")
if not os.path.isfile(handoff_path):
    sys.exit(0)
try:
    with open(handoff_path) as fh:
        ho = json.load(fh)
except Exception:
    sys.exit(0)
if not isinstance(ho, dict):
    sys.exit(0)

project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
source = data.get("source") or ""


def git(*args):
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

# Repo guard: only resume in the repo the handoff came from.
toplevel = git("rev-parse", "--show-toplevel")
if not toplevel or toplevel != ho.get("git_toplevel"):
    sys.exit(0)

# On a /compact resume, reset this session's Phase-B/C sentinels so a later climb
# back over the nudge threshold can drive a second wrap -> /compact cycle. (If
# /compact keeps the same session_id these clear the live sentinels; if it mints
# a new one the new session simply has none — either way the cycle can repeat.)
# The plangate sentinel is intentionally NOT reset here: Phase A is once per
# session (one plan start), and it does not recur within a long execution.
if source == "compact":
    session_id = str(data.get("session_id") or "default")
    skey = hashlib.sha1(session_id.encode()).hexdigest()[:16]
    for prefix in ("context-flow-nudged-", "context-flow-compacted-"):
        try:
            os.remove(os.path.join(tempfile.gettempdir(), prefix + skey + ".json"))
        except Exception:
            pass

# Clear the handoff so we resume exactly once.
try:
    os.remove(handoff_path)
except Exception:
    pass

# Tell the fresh/compacted session what to do. /clear means fresh context, so the
# agent implements the plan from the committed baseline; /compact (and the
# fallback) means continue from where the plan and commits leave off.
plan = ho.get("plan_path")
branch = ho.get("branch") or git("rev-parse", "--abbrev-ref", "HEAD") or "the current branch"
verb = "implement" if source == "clear" else "continue"
if plan:
    add = (
        "Resume (context-flow): " + verb + " the plan @" + str(plan) + " on "
        + str(branch) + ". Prior work is committed — "
        + ("start from the committed baseline; do not redo any completed steps."
           if source == "clear" else
           "continue from where the plan and the commits leave off; do not redo "
           "completed steps.")
    )
else:
    add = (
        "Resume (context-flow): continue the prior in-progress work on "
        + str(branch) + ". It is committed — pick up from the latest commits."
    )

sys.stdout.write(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": add,
    }
}))
sys.exit(0)
PY
