#!/usr/bin/env bash
#
# Helper for the /checkpoint command (my-code-review plugin).
#
# Arms / disarms a per-repo "deferred review" state so a LONG plan can be
# executed with a halfway pause for /compact, while the auto code-review
# (scripts/review.sh) fires ONCE at the end over the whole change instead of
# nagging per commit.
#
#   checkpoint.sh arm [plan_path]
#       Resolve the plan file (the given path, else the newest *.md in
#       ~/.claude/plans), count its steps, write the deferred-review state
#       {defer_review:true, armed_at:<epoch>}, and print a one-line summary
#       (resolved path, step count N, the halfway step ceil(N/2)).
#
#   checkpoint.sh done
#       Delete the state file, re-enabling normal per-commit review. The agent
#       runs this at the very end of the plan so the final Stop reviews the
#       whole baseline..HEAD range at once.
#
# State lives in ONE temp file per repo, keyed sha1(git toplevel)[:16] as
# my-code-review-plan-<key>.json, shared with review.sh. We key on the git root
# (not the session id) because this helper runs in the agent's Bash, where
# CLAUDE_SESSION_ID / CLAUDE_PROJECT_DIR are UNSET — but `git rev-parse
# --show-toplevel` is computable on both this side and the hook side.
#
# Known limits (also in the plan / command):
#   * The agent must run `done` to re-enable review; if it forgets, review stays
#     deferred until the armed_at TTL (24h, enforced in review.sh) self-heals.
#   * Step counting is heuristic (ordered-list items, else ## / ### headings).
#   * State is repo-keyed: two concurrent checkpointed plans in the SAME repo
#     would share one state file. Rare; documented.
#
# Fail-open: any error exits 0 so the command never wedges the session. It may
# print a note that it could not arm — the plan still runs, just without the
# deferred review.

set -u

command -v python3 >/dev/null 2>&1 || { echo "checkpoint: python3 not found; review will not be deferred."; exit 0; }
command -v git     >/dev/null 2>&1 || { echo "checkpoint: git not found; review will not be deferred.";     exit 0; }

export CKPT_ACTION="${1:-arm}"
export CKPT_PLAN_ARG="${2:-}"

# Quoted heredoc so literal punctuation in the body can never break shell
# quoting. Arguments travel via the environment, so stdin/quoting stays simple.
python3 <<"PY" || exit 0
import os, sys, json, glob, math, re, time, hashlib, tempfile, subprocess

action   = os.environ.get("CKPT_ACTION", "arm")
plan_arg = os.environ.get("CKPT_PLAN_ARG", "").strip()

def git(*args):
    # Run git from the current working dir; return stripped stdout or None.
    try:
        out = subprocess.run(["git", *args], capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip()

root = git("rev-parse", "--show-toplevel")
if not root:
    print("checkpoint: not inside a git repo; review will not be deferred.")
    sys.exit(0)

key = hashlib.sha1(root.encode()).hexdigest()[:16]
state_path = os.path.join(tempfile.gettempdir(), "my-code-review-plan-" + key + ".json")

# --- done: clear the deferral -------------------------------------------------
if action == "done":
    try:
        os.remove(state_path)
    except Exception:
        pass  # already gone, or unwritable; either way review is no longer deferred
    print("checkpoint: cleared — the end-of-plan code review will run on the next stop.")
    sys.exit(0)

# --- arm (default): defer review + report the halfway point -------------------
def resolve_plan(arg):
    # Explicit path wins; otherwise the newest *.md the user just approved.
    if arg:
        p = os.path.expanduser(arg)
        return p if os.path.isfile(p) else None
    plans = glob.glob(os.path.join(os.path.expanduser("~/.claude/plans"), "*.md"))
    if not plans:
        return None
    return max(plans, key=os.path.getmtime)

def count_steps(path):
    # Heuristic: top-level ordered-list items, else ## / ### headings; max wins.
    try:
        with open(path, errors="ignore") as fh:
            lines = fh.readlines()
    except Exception:
        return 0
    ordered  = sum(1 for ln in lines if re.match(r"^\s*\d+\.\s", ln))
    headings = sum(1 for ln in lines if re.match(r"^#{2,3}\s", ln))
    return max(ordered, headings)

plan = resolve_plan(plan_arg)
n    = count_steps(plan) if plan else 0
half = math.ceil(n / 2) if n else 0

try:
    with open(state_path, "w") as fh:
        json.dump({"defer_review": True, "armed_at": int(time.time())}, fh)
except Exception:
    print("checkpoint: could not write state; review will NOT be deferred.")
    sys.exit(0)

if plan and n:
    print("checkpoint armed — the auto code-review is deferred until you run `checkpoint.sh done`.")
    print("  plan: " + plan)
    print("  steps (heuristic): " + str(n))
    print("  checkpoint after step " + str(half)
          + " — commit, check off finished steps, then stop for /compact.")
elif plan:
    print("checkpoint armed (could not count steps in the plan).")
    print("  plan: " + plan)
    print("  pick a natural halfway point to commit, then stop for /compact.")
else:
    print("checkpoint armed, but no plan file found (none given, none in ~/.claude/plans).")
    print("  pick a natural halfway point to commit, then stop for /compact.")
sys.exit(0)
PY
