#!/usr/bin/env bash
#
# worktree-guard.sh — PreToolUse hook for personal-tools (matcher Edit|Write|NotebookEdit).
#
# Enforces the worktree rule: the git PRIMARY working tree is off-limits for writes.
# Edits/writes must happen in a linked worktree (created with EnterWorktree), so parallel
# Claude sessions on one repo can't collide in the same checkout.
#
# Decision is BY TARGET PATH, stateless (no sentinel):
#   * target inside a LINKED worktree (rev-parse --git-dir != --git-common-dir) -> ALLOW
#   * target inside the PRIMARY tree (--git-dir == --git-common-dir)            -> DENY
#       unless a merge/rebase is in progress (legit conflict resolution; also the
#       /orchestrate merger) or the kill-switch MYDOTCLAUDE_WORKTREE_GUARD=0 is set.
#   * non-repo / git error / missing path / bad JSON                            -> ALLOW
#
# ALLOW is a SILENT exit 0 (never permissionDecision:"allow") so we don't override the
# user's allow/ask config or short-circuit downstream PreToolUse hooks. DENY emits a
# hookSpecificOutput blob (exit 0); the reason names EnterWorktree so the agent knows the
# fix AND so EnterWorktree's own self-gate (needs the word "worktree") is satisfied.
#
# Fail-open: every error path allows. This hook must NEVER wedge a session.

export HOOK_INPUT="$(cat)"
command -v python3 >/dev/null 2>&1 || exit 0

python3 <<"PY" || exit 0
import os, json, sys, subprocess

raw = os.environ.get("HOOK_INPUT", "")
try:
    data = json.loads(raw) if raw else {}
except Exception:
    sys.exit(0)  # malformed -> allow

ti = data.get("tool_input") or {}
# Edit/Write use file_path; NotebookEdit uses notebook_path.
path = str(ti.get("file_path") or ti.get("notebook_path") or "").strip()
if not path:
    sys.exit(0)  # nothing to gate -> allow

cwd = str(data.get("cwd") or os.getcwd())
if not os.path.isabs(path):
    path = os.path.join(cwd, path)

# Resolve to the nearest EXISTING ancestor directory (new-file/new-dir writes).
d = os.path.dirname(path)
while d and not os.path.isdir(d):
    parent = os.path.dirname(d)
    if parent == d:
        break
    d = parent
if not d or not os.path.isdir(d):
    sys.exit(0)  # can't resolve -> allow


def git(*args):
    return subprocess.run(
        ["git", "-C", d, *args], capture_output=True, text=True, timeout=5
    )


try:
    r_gd = git("rev-parse", "--git-dir")
    r_gcd = git("rev-parse", "--git-common-dir")
except Exception:
    sys.exit(0)  # git missing/timeout -> allow
if r_gd.returncode != 0 or r_gcd.returncode != 0:
    sys.exit(0)  # not a repo -> allow

# git may emit a relative path (".git") from the repo root — canonicalize both.
gd = os.path.realpath(os.path.join(d, r_gd.stdout.strip()))
gcd = os.path.realpath(os.path.join(d, r_gcd.stdout.strip()))

if gd != gcd:
    sys.exit(0)  # LINKED worktree -> allow

# --- PRIMARY tree below ---

if os.environ.get("MYDOTCLAUDE_WORKTREE_GUARD") == "0":
    sys.exit(0)  # kill-switch (degradation for Claude Code without EnterWorktree)

# An in-progress merge/rebase/cherry-pick means this edit is legit conflict resolution
# (a human resolving conflicts, or the /orchestrate merger) -> allow.
for marker in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD"):
    if os.path.exists(os.path.join(gcd, marker)):
        sys.exit(0)
for subdir in ("rebase-merge", "rebase-apply"):
    if os.path.isdir(os.path.join(gcd, subdir)):
        sys.exit(0)

reason = (
    "This is the primary checkout — writes here are off-limits. Call EnterWorktree to "
    "move this session into a worktree (per the worktree rule), then redo this edit."
)
try:
    st = git("status", "--porcelain")
    if st.returncode == 0 and st.stdout.strip():
        reason += (
            " First ask the user to commit or stash the uncommitted changes — "
            "EnterWorktree (baseRef=head) will not carry them."
        )
except Exception:
    pass

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }
}))
sys.exit(0)
PY
exit 0
