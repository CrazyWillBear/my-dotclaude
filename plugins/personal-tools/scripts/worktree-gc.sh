#!/usr/bin/env bash
#
# worktree-gc.sh — SessionStart backstop for personal-tools.
#
# EnterWorktree's native exit-prompt / ExitWorktree(remove) handle the live session.
# This is the crash/abandon backstop: at session start it sweeps the kit's own
# worktrees (<repo>/.claude/worktrees/*) and removes the ones that are safely
# garbage — so an orphaned worktree left by a killed session doesn't pile up.
#
# A worktree is removed ONLY when ALL hold (conservative — when in doubt, keep):
#   * it lives under .claude/worktrees/ (a kit worktree, not one the user made);
#   * it is NOT the worktree this session is in;
#   * its tree is clean (`git status --porcelain` empty);
#   * it has NO unique commits — its HEAD is an ancestor of the main worktree's
#     branch (nothing would be lost);
#   * its dir mtime is older than MYDOTCLAUDE_WORKTREE_GC_AGE seconds
#     (default 43200 = 12h) — so a concurrent session's fresh, still-empty worktree
#     is never swept out from under it.
# Removal is `git worktree remove` WITHOUT --force (git refuses if it raced dirty),
# then a single `git worktree prune`. Silent, fail-open: any error exits 0.

export HOOK_INPUT="$(cat)"
command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

python3 <<"PY" || exit 0
import os, json, sys, time, subprocess

raw = os.environ.get("HOOK_INPUT", "")
try:
    data = json.loads(raw) if raw else {}
except Exception:
    data = {}

project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd()


def git(*args, cwd=None):
    try:
        return subprocess.run(
            ["git", "-C", cwd or project_dir, *args],
            capture_output=True, text=True, timeout=10,
        )
    except Exception:
        return None


# Must be in a git repo to have worktrees to sweep.
r = git("rev-parse", "--git-common-dir")
if r is None or r.returncode != 0:
    sys.exit(0)  # not a repo / git error -> fail-open

# The worktree this session is in — never GC ourselves.
rt = git("rev-parse", "--show-toplevel")
if rt is not None and rt.returncode == 0 and rt.stdout.strip():
    current_top = os.path.realpath(rt.stdout.strip())
else:
    current_top = os.path.realpath(project_dir)

wl = git("worktree", "list", "--porcelain")
if wl is None or wl.returncode != 0:
    sys.exit(0)

# Parse the porcelain blocks (blank-line separated). First block = main worktree.
blocks = []
cur = {}
for line in wl.stdout.splitlines():
    if not line.strip():
        if cur:
            blocks.append(cur)
            cur = {}
        continue
    if line.startswith("worktree "):
        cur = {"path": line[len("worktree "):]}
    elif line.startswith("HEAD "):
        cur["head"] = line[len("HEAD "):].strip()
    elif line.startswith("branch "):
        cur["branch"] = line[len("branch "):].strip()
    elif line.strip() == "detached":
        cur["detached"] = True
    elif line.strip() == "bare":
        cur["bare"] = True
if cur:
    blocks.append(cur)

if not blocks:
    sys.exit(0)

# Base = the main worktree's branch (or its HEAD if detached) — "no unique commits"
# is measured against this.
main = blocks[0]
base_ref = main.get("branch") or main.get("head")
if not base_ref:
    sys.exit(0)

try:
    age = int(os.environ.get("MYDOTCLAUDE_WORKTREE_GC_AGE") or 43200)
except Exception:
    age = 43200
now = time.time()

removed_any = False
for wt in blocks[1:]:
    path = wt.get("path")
    if not path:
        continue
    # Only kit worktrees under .claude/worktrees/ — never the user's own.
    if "/.claude/worktrees/" not in path.replace(os.sep, "/"):
        continue
    rp = os.path.realpath(path)
    if rp == current_top:
        continue  # never GC the worktree we're in
    if not os.path.isdir(rp):
        continue  # already gone on disk; prune at the end cleans the admin files
    # Fresh? A concurrent session may have just created it — leave it alone.
    try:
        if (now - os.path.getmtime(rp)) < age:
            continue
    except Exception:
        continue
    # Clean tree?
    st = git("status", "--porcelain", cwd=rp)
    if st is None or st.returncode != 0 or st.stdout.strip():
        continue  # dirty or unreadable -> keep
    # No unique commits — HEAD already contained in the base branch?
    head = wt.get("head")
    if not head:
        continue
    anc = git("merge-base", "--is-ancestor", head, base_ref)
    if anc is None or anc.returncode != 0:
        continue  # has commits not on base -> keep
    # All guards passed -> remove (no --force; git refuses if it raced dirty).
    rm = git("worktree", "remove", path)
    if rm is not None and rm.returncode == 0:
        removed_any = True

if removed_any:
    git("worktree", "prune")
sys.exit(0)
PY
exit 0
