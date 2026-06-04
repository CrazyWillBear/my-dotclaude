#!/usr/bin/env bash
#
# SessionStart auto-resume for the context-flow plugin.
#
# The other half of the handoff loop: when a session that was over budget ended,
# watchdog.sh wrote ~/.claude/.pending-handoff. On the next launch this hook
# reads it and, if we're in the same repo it came from:
#
#   1. Seeds review.sh's per-session reviewed-HEAD marker for THIS (new) session
#      to the pre-handoff baseline, OVERWRITING it. review.sh's own SessionStart
#      seed only writes when the marker is absent, so overwriting here makes the
#      result independent of SessionStart hook order across the two plugins —
#      either way the marker ends at the baseline, and the first clean Stop
#      reviews the whole baseline..HEAD range at once (the commits made during
#      the pre-restart wrap-up).
#   2. Runs checkpoint.sh done to clear the review deferral the watchdog armed.
#   3. Clears the handoff (resume exactly once) and injects a resume instruction.
#
# Fail open: any error exits 0. If we're NOT in the handoff's repo, leave the
# handoff untouched and stay silent, so a relaunch in another project never
# steals or drops it.

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

# 1. Seed review.sh's reviewed marker for the NEW session to the baseline.
baseline = ho.get("baseline_head")
session_id = str(data.get("session_id") or "default")
if baseline:
    skey = hashlib.sha1(session_id.encode()).hexdigest()[:16]
    head_state = os.path.join(tempfile.gettempdir(), "my-code-review-head-" + skey + ".json")
    try:
        with open(head_state, "w") as fh:
            json.dump({"reviewed": baseline}, fh)
    except Exception:
        pass

# 2. Clear the review deferral (checkpoint.sh done), keyed on the repo toplevel.
ckpt = os.environ.get("CONTEXT_FLOW_CHECKPOINT_SH")
if not ckpt:
    root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
    if root:
        ckpt = os.path.join(root, "..", "my-code-review", "scripts", "checkpoint.sh")
if ckpt and os.path.isfile(ckpt):
    try:
        subprocess.run(["bash", ckpt, "done"], cwd=project_dir,
                       capture_output=True, timeout=10)
    except Exception:
        pass

# 3. Clear the handoff so we resume exactly once.
try:
    os.remove(handoff_path)
except Exception:
    pass

# Tell the fresh session what to continue.
plan = ho.get("plan_path")
branch = ho.get("branch") or git("rev-parse", "--abbrev-ref", "HEAD") or "the current branch"
if plan:
    add = (
        "Resume (context-flow): implement the plan @" + str(plan) + " on "
        + str(branch) + ". Prior work is committed — continue from where the plan "
        "and the commits leave off; do not redo completed steps."
    )
else:
    add = (
        "Resume (context-flow): continue the prior in-progress work on "
        + str(branch) + ". It is committed — pick up from the latest commits."
    )

# Review was only deferred (batched) when the handoff armed it (the Stop path).
# The plan-accept gate hands off WITHOUT arming, so review runs normally there.
if ho.get("armed"):
    add += (" Code review has been re-enabled and will run once over everything "
            "committed since the handoff.")
else:
    add += " Code review has been re-enabled."

# A manual /handoff can attach a prose summary; surface it for continuity.
summary = ho.get("summary")
if summary:
    add += "\n\nHandoff summary from the prior session:\n" + str(summary)

sys.stdout.write(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": add,
    }
}))
sys.exit(0)
PY
