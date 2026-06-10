#!/usr/bin/env bash
#
# SessionStart auto-resume for the workflow plugin.
#
# The other half of the handoff loop. When the watchdog fires the 100k wrap
# signal it tells the agent to commit and run /handoff, which writes a per-repo
# keyed resume pointer (~/.claude/handoffs/<sha1(toplevel)[:16]>/.pending.json) and
# clears context. A PreCompact hook also writes a handoff before EVERY compaction
# (a manual /compact or a harness auto-compact), so a user-initiated or harness
# compact re-injects the plan too — not only workflow-driven ones. All of those
# fire SessionStart (source=clear / source=compact). This hook resolves the pointer
# for the current repo and, if we are in the same repo it came from, re-injects the
# plan so the user only ever has to type the one command plus a kickoff word:
#
#   * source=clear   (/handoff) -> "implement the plan @path" wording.
#     Fresh context, so the agent starts the plan from the committed baseline.
#   * source=compact (manual/auto /compact) -> "continue the plan @path" wording.
#   * anything else  (startup/resume) -> treated as "continue" (graceful fallback).
#
# On ANY clear or compact we reset this session's wrap sentinel FIRST — before the
# handoff lookup and repo guard below — so a later climb back over the nudge
# threshold can drive another wrap -> /handoff cycle. This runs even when no
# workflow handoff exists (a manual /compact or a harness auto-compact writes
# none), which is exactly the case where the old handoff-gated reset was
# unreachable. (On /clear with a new session_id this is a harmless no-op against a
# fresh namespace; on a same-id resume it re-arms the cycle.) The plangate
# sentinel is left alone — keyed by the last-gated plan id, it re-fires on a new
# plan without a reset.
#
# Fail open: any error exits 0. If we are NOT in the handoff's repo, leave the
# handoff untouched and stay silent, so a launch in another project never steals
# or drops it.
#
# Pointer resolution is per-repo keyed first, legacy global second: we read
# <keyed-dir>/.pending.json for the current repo, then fall back to the legacy
# global ~/.claude/.pending-handoff (one-release migration; repo-guarded), and
# consume whichever we actually used. Per-repo keying means concurrent repos no
# longer collide — the old single global file was last-writer-wins across repos;
# that caveat now applies only to the legacy fallback, which is going away.

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

# Reset this session's wrap sentinel on ANY compact/clear, independent of whether
# a workflow handoff exists. A manual /compact or a harness auto-compact writes no
# handoff, so the old reset (which lived after the handoff early-return) never ran
# for them and the nudge stayed silent for the rest of the session. Keyed by
# session_id; writes no stdout, so the no-handoff / wrong-repo silence contracts
# below are preserved. The plangate sentinel is intentionally left alone — it
# re-fires on a genuinely new plan id on its own.
if source in ("compact", "clear"):
    session_id = str(data.get("session_id") or "default")
    skey = hashlib.sha1(session_id.encode()).hexdigest()[:16]
    try:
        os.remove(os.path.join(tempfile.gettempdir(), "workflow-nudged-" + skey + ".json"))
    except Exception:
        pass

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


# toplevel is needed both to compute the per-repo keyed pointer path and for the
# repo guard, so resolve it before reading the pointer.
toplevel = git("rev-parse", "--show-toplevel")

# Pointer resolution: the new per-repo keyed pointer first, then the legacy global
# file (one-release migration). Consume exactly whichever we use.
keyed_path = None
if toplevel:
    key = hashlib.sha1(toplevel.encode()).hexdigest()[:16]
    keyed_path = os.path.expanduser(
        os.path.join("~/.claude/handoffs", key, ".pending.json")
    )
legacy_path = os.path.expanduser("~/.claude/.pending-handoff")

handoff_path = None
for cand in (keyed_path, legacy_path):
    if cand and os.path.isfile(cand):
        handoff_path = cand
        break
if not handoff_path:
    sys.exit(0)
try:
    with open(handoff_path) as fh:
        ho = json.load(fh)
except Exception:
    sys.exit(0)
if not isinstance(ho, dict):
    sys.exit(0)

# Repo guard: only resume in the repo the handoff came from. (Keyed pointers
# always match; this gates the legacy global fallback against a foreign repo.)
if not toplevel or toplevel != ho.get("git_toplevel"):
    sys.exit(0)

# Clear the consumed pointer so we resume exactly once.
try:
    os.remove(handoff_path)
except Exception:
    pass

# Tell the fresh/compacted session what to do. /clear means fresh context, so the
# agent implements the handoff from the committed baseline; /compact (and the
# fallback) means continue from where the handoff and commits leave off.
handoff = ho.get("handoff_path")
branch = ho.get("branch") or git("rev-parse", "--abbrev-ref", "HEAD") or "the current branch"
verb = "implement" if source == "clear" else "continue"
if handoff:
    add = (
        "Resume (workflow): " + verb + " the handoff @" + str(handoff) + " on "
        + str(branch) + ". Prior work is committed — "
        + ("start from the committed baseline; do not redo any completed steps."
           if source == "clear" else
           "continue from where the handoff and the commits leave off; do not redo "
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
