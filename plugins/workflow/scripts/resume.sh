#!/usr/bin/env bash
#
# SessionStart auto-resume for the workflow plugin.
#
# The other half of the handoff loop. When the watchdog fires the 250k wrap
# signal it tells the agent to commit and run /handoff, which writes a per-repo
# keyed resume pointer (~/.claude/handoffs/<sha1(git_common_dir)[:16]>/.pending.json)
# and clears context. A PreCompact hook also writes a handoff before EVERY
# compaction (a manual /compact or a harness auto-compact), so a user-initiated or
# harness compact re-injects the plan too — not only workflow-driven ones. All of
# those fire SessionStart (source=clear / source=compact). This hook resolves the
# pointer for the current repo and, if we are in the same repo it came from,
# re-injects the plan so the user only ever has to type the one command plus a
# kickoff word. Every variant orders the agent to read the handoff file FIRST —
# before any other tool call or reply — so the resumed session never acts on stale
# context:
#
#   * source=clear   (/handoff) -> read the handoff, then "implement the handoff".
#     Fresh context, so the agent starts the plan from the committed baseline.
#   * source=compact (manual/auto /compact) -> read the handoff, then "continue".
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
# Pointer resolution is 3-tier, in priority order, consuming exactly the one used:
#   1. NEW per-repo COMMON-DIR key — <sha1(realpath(--git-common-dir))[:16]>. Keyed
#      by the shared common .git, so a handoff written in a linked worktree resolves
#      from the primary tree and every sibling worktree (they share one pointer).
#   2. OLD per-repo TOPLEVEL key — <sha1(--show-toplevel)[:16]> (one-release
#      migration: pointers written by the pre-common-dir kit still resume once).
#   3. Legacy global ~/.claude/.pending-handoff (older migration fallback).
# Identity guard per pointer: a pointer carrying git_common_dir must match the
# current common dir; an older one (no git_common_dir) must match git_toplevel —
# preserving the wrong-repo guard for the legacy/old tiers.
#
# Worktree reuse: if the pointer's git_toplevel is a live LINKED worktree of this
# repo that differs from the current toplevel (e.g. handoff written inside a
# worktree, resumed from the primary tree), the injected order is prefixed with a
# directive to call EnterWorktree(path=<that worktree>) FIRST, so the resumed
# session continues IN that worktree (and the word "worktree" + the rewritten
# CLAUDE.md satisfy EnterWorktree's self-gate).

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


def git_at(cwd, *args):
    try:
        out = subprocess.run(
            ["git", "-C", cwd, *args],
            capture_output=True, text=True, timeout=10,
        )
    except Exception:
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip()


def git(*args):
    return git_at(project_dir, *args)


def common_git_dir(cwd):
    # Canonical absolute --git-common-dir for a working tree: identical from the
    # primary tree and every linked worktree (one shared common .git). realpath
    # turns git's possibly-relative ".git" into the same physical path the writer
    # (save-handoff.sh / the skills) computes, so the keys match byte-for-byte.
    raw = git_at(cwd, "rev-parse", "--git-common-dir")
    if not raw:
        return None
    return os.path.realpath(os.path.join(cwd, raw))


# toplevel + common_dir are needed both to compute the per-repo keyed pointer
# paths and for the identity guards, so resolve them before reading the pointer.
toplevel = git("rev-parse", "--show-toplevel")
common_dir = common_git_dir(project_dir)


def keyed_pointer(key_src):
    if not key_src:
        return None
    key = hashlib.sha1(key_src.encode()).hexdigest()[:16]
    return os.path.expanduser(os.path.join("~/.claude/handoffs", key, ".pending.json"))


# 3-tier pointer resolution: new common-dir key, then old toplevel key (one-release
# migration), then the legacy global file. Consume exactly whichever we use.
candidates = [
    keyed_pointer(common_dir),                       # 1. new common-dir key
    keyed_pointer(toplevel),                          # 2. old toplevel key (migration)
    os.path.expanduser("~/.claude/.pending-handoff"), # 3. legacy global
]

handoff_path = None
for cand in candidates:
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

# Identity guard: only resume in the repo the handoff came from. A pointer that
# carries git_common_dir is matched on the shared common dir (so it resumes from
# the primary tree or any sibling worktree); an older pointer without it falls back
# to the git_toplevel match (preserving the wrong-repo guard for the legacy/old
# tiers).
if ho.get("git_common_dir"):
    if not common_dir or common_dir != ho.get("git_common_dir"):
        sys.exit(0)
else:
    if not toplevel or toplevel != ho.get("git_toplevel"):
        sys.exit(0)

# Clear the consumed pointer so we resume exactly once.
try:
    os.remove(handoff_path)
except Exception:
    pass


def reuse_worktree(ho_top):
    # The handoff's git_toplevel is a reuse target when it is a live LINKED worktree
    # of THIS repo that differs from where we are now — e.g. the handoff was written
    # inside a worktree and we are resuming from the primary tree. Returns the
    # worktree path to enter, or None (resume in place).
    if not ho_top or not toplevel or ho_top == toplevel:
        return None
    gd = git_at(ho_top, "rev-parse", "--git-dir")
    cd = git_at(ho_top, "rev-parse", "--git-common-dir")
    if not gd or not cd:
        return None  # not a live working tree (e.g. worktree was removed)
    gd = os.path.realpath(os.path.join(ho_top, gd))
    cd = os.path.realpath(os.path.join(ho_top, cd))
    if gd == cd:
        return None  # ho_top is a primary tree, not a linked worktree
    if not common_dir or cd != common_dir:
        return None  # belongs to a different repo
    wl = git("worktree", "list", "--porcelain") or ""
    live = set()
    for line in wl.splitlines():
        if line.startswith("worktree "):
            live.add(os.path.realpath(line[len("worktree "):]))
    return ho_top if os.path.realpath(ho_top) in live else None


# Tell the fresh/compacted session what to do. /clear means fresh context, so the
# agent implements the handoff from the committed baseline; /compact (and the
# fallback) means continue from where the handoff and commits leave off.
handoff = ho.get("handoff_path")
branch = ho.get("branch") or git("rev-parse", "--abbrev-ref", "HEAD") or "the current branch"
verb = "implement" if source == "clear" else "continue"

# If the handoff lives in a sibling worktree, the very first move must be to enter
# it (before reading the handoff), so the resumed work happens in the right tree.
enter = reuse_worktree(ho.get("git_toplevel"))
prefix = ""
if enter:
    prefix = (
        "This work lives in the git worktree " + str(enter) + ". Your FIRST action, "
        "before any other tool call or reply, MUST be to call "
        "EnterWorktree(path=" + str(enter) + ") to move into it. THEN: "
    )

if handoff:
    body = (
        ("your FIRST action this session, before any other tool call or reply, MUST be to "
         if not enter else "")
        + "read the handoff file @" + str(handoff)
        + " in full. Then " + verb + " the handoff on " + str(branch)
        + ". Prior work is committed — "
        + ("start from the committed baseline; do not redo any completed steps."
           if source == "clear" else
           "continue from where the handoff and the commits leave off; do not redo "
           "completed steps.")
    )
    add = "Resume (workflow): " + prefix + body
else:
    add = (
        "Resume (workflow): " + prefix
        + "continue the prior in-progress work on "
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
