#!/usr/bin/env bash
#
# SessionStart auto-resume for the workflow plugin.
#
# The other half of the handoff loop. When the watchdog gates a plan start
# (Phase A) or prompts a post-wrap /handoff (Phase C), it writes
# ~/.claude/.pending-handoff and tells the user to run /clear (or to run
# /handoff, which then clears). A PreCompact hook also writes a handoff before
# EVERY compaction (a manual /compact or a harness auto-compact), so a
# user-initiated or harness compact re-injects the plan too — not only
# workflow-driven ones. All of those fire SessionStart (source=clear /
# source=compact). This hook reads the handoff and, if we are in the same repo it
# came from, re-injects the plan so the user only ever has to type the one command
# plus a kickoff word:
#
#   * source=clear   (Phase A / /handoff) -> "implement the plan @path" wording.
#     Fresh context, so the agent starts the plan from the committed baseline.
#   * source=compact (manual/auto /compact) -> "continue the plan @path" wording.
#   * anything else  (startup/resume) -> treated as "continue" (graceful fallback).
#
# On ANY clear or compact we reset this session's Phase-B/C wrap sentinels FIRST —
# before the handoff lookup and repo guard below — so a later climb back over the
# nudge threshold can drive another wrap -> /handoff cycle. This runs even when no
# workflow handoff exists (a manual /compact or a harness auto-compact writes
# none), which is exactly the case where the old handoff-gated reset was
# unreachable. (On /clear with a new session_id this is a harmless no-op against a
# fresh namespace; on a same-id resume it re-arms the cycle.) The Phase-A plangate
# sentinel is left alone — keyed by the last-gated plan id, it re-fires on a new
# plan without a reset.
#
# Fail open: any error exits 0. If we are NOT in the handoff's repo, leave the
# handoff untouched and stay silent, so a launch in another project never steals
# or drops it.
#
# Caveat: the handoff is one global file, and PreCompact now writes it before EVERY
# compaction, so across concurrent repos it is last-writer-wins — a /compact in
# repo B overwrites an unconsumed handoff from repo A. Acceptable: B's handoff is
# correct for B, and a dropped cross-repo handoff costs at most one plan
# re-injection (the repo guard still prevents B from consuming A's plan).

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

source = data.get("source") or ""

# Reset this session's Phase-B/C wrap sentinels on ANY compact/clear, independent
# of whether a workflow handoff exists. A manual /compact or a harness
# auto-compact writes no handoff, so the old reset (which lived after the handoff
# early-return) never ran for them and Phase B stayed silent for the rest of the
# session. Keyed by session_id; writes no stdout, so the no-handoff / wrong-repo
# silence contracts below are preserved. The plangate sentinel is intentionally
# left alone — Phase A re-fires on a genuinely new plan id on its own, and
# resetting it would refire on the same plan right after a compact/clear.
if source in ("compact", "clear"):
    session_id = str(data.get("session_id") or "default")
    skey = hashlib.sha1(session_id.encode()).hexdigest()[:16]
    for prefix in ("workflow-nudged-", "workflow-compacted-"):
        try:
            os.remove(os.path.join(tempfile.gettempdir(), prefix + skey + ".json"))
        except Exception:
            pass

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
        "Resume (workflow): " + verb + " the plan @" + str(plan) + " on "
        + str(branch) + ". Prior work is committed — "
        + ("start from the committed baseline; do not redo any completed steps."
           if source == "clear" else
           "continue from where the plan and the commits leave off; do not redo "
           "completed steps.")
    )
else:
    add = (
        "Resume (workflow): continue the prior in-progress work on "
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
