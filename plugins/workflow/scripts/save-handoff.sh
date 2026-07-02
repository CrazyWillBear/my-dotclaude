#!/usr/bin/env bash
#
# Shared handoff writer for the workflow plugin.
#
# Single source of the resume-pointer JSON schema that resume.sh reads, and the
# owner of the per-repo handoff keying. Used by the watchdog's Phase-A plan-start
# gate and Phase-C post-wrap handoff prompt, and by the PreCompact hook (which
# calls it with NO args before every compaction), so the schema lives in exactly
# one place.
#
#   save-handoff.sh [--session ID] [--size N]
#   save-handoff.sh --print-dir
#
#     --session ID   session id; recorded for debugging (informational).
#     --size N       context-token occupancy to record (informational).
#     --print-dir    print the per-repo keyed handoff dir for the current repo and
#                    exit (empty + exit 0 outside a repo). The canonical reference
#                    the /handoff skill mirrors and a drift test asserts against.
#
# Handoff keying: both the resume pointer and the handoff doc live under
#   ~/.claude/handoffs/<sha1(git_common_dir)[:16]>/
# as .pending.json (pointer) and <branch-slug>.md (doc). Keyed by the COMMON git
# dir (not the worktree toplevel) so the primary tree and all its linked worktrees
# share one pointer — a handoff written in a worktree resumes from anywhere in the
# repo. Per-repo keying also means concurrent /handoff across repos never clobber
# each other (the old single global ~/.claude/.pending-handoff was last-writer-wins).
# resume.sh recomputes the same sha; the /handoff + /handoff-plan skills write the
# same layout inline.
#
# Git state is read from CLAUDE_PROJECT_DIR (else cwd). The baseline is simply the
# current HEAD — prior work is committed before a handoff. Fail open: any error
# exits 0 so a handoff attempt never wedges the session.

set -u

export SH_SESSION="" SH_SIZE="" SH_PRINT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        # Value flags guard against a missing/flag-like value so a bare
        # `--session --size 5` cannot swallow `--size` as the session id.
        --session)   case "${2:-}" in ""|--*) shift 1 ;; *) SH_SESSION="$2"; shift 2 ;; esac ;;
        --size)      case "${2:-}" in ""|--*) shift 1 ;; *) SH_SIZE="$2";    shift 2 ;; esac ;;
        --print-dir) SH_PRINT_DIR=1; shift ;;
        *)           shift ;;
    esac
done

command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

python3 <<"PY" || exit 0
import os, json, sys, time, glob, hashlib, subprocess

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


def keyed_dir(common_dir):
    # Per-repo handoff dir: ~/.claude/handoffs/<sha1(git_common_dir)[:16]>.
    # Keyed by the COMMON git dir so the primary tree and all its linked worktrees
    # share one pointer. The 16-hex key must be byte-identical to resume.sh and the
    # /handoff + /handoff-plan skills, which compute the same sha1 over the canonical
    # absolute --git-common-dir (bash: (cd "$gcd" && pwd -P) | sha1sum | cut -c1-16).
    if not common_dir:
        return None
    key = hashlib.sha1(common_dir.encode()).hexdigest()[:16]
    return os.path.expanduser(os.path.join("~/.claude/handoffs", key))


def common_git_dir():
    # Canonical absolute --git-common-dir: identical from the primary tree and every
    # linked worktree (they share one common .git). realpath(join(...)) turns git's
    # possibly-relative ".git" into the same physical path the bash skills compute.
    raw = git("rev-parse", "--git-common-dir")
    if not raw:
        return None
    return os.path.realpath(os.path.join(project_dir, raw))


toplevel = git("rev-parse", "--show-toplevel")
common_dir = common_git_dir()

# --print-dir: emit the keyed dir for the current repo and exit (empty outside a
# repo). The canonical reference the skill mirrors and the drift test checks.
if os.environ.get("SH_PRINT_DIR"):
    kd = keyed_dir(common_dir)
    if kd:
        sys.stdout.write(kd)
    sys.exit(0)

session_id = os.environ.get("SH_SESSION") or ""
try:
    size = int(os.environ.get("SH_SIZE") or 0)
except Exception:
    size = 0


def resolve_handoff(branch):
    # Handoff doc written by /handoff: <keyed-dir>/<branch-slug>.md
    # (branch slashes replaced with dashes, same rule the skill uses).
    # Fallback: <branch-slug>-pipeline.md — the /pipeline skill's phase-boundary
    # state doc — so a PreCompact firing mid-pipeline points the resume order at
    # the pipeline state instead of nulling handoff_path and orphaning it.
    kd = keyed_dir(common_dir)
    if not branch or not kd:
        return None
    try:
        safe = branch.replace("/", "-")
        for suffix in (".md", "-pipeline.md"):
            path = os.path.join(kd, safe + suffix)
            if os.path.isfile(path):
                return path
        return None
    except Exception:
        return None


branch_val = git("rev-parse", "--abbrev-ref", "HEAD")
obj = {
    "handoff_path":   resolve_handoff(branch_val),
    "branch":         branch_val,
    "git_toplevel":   toplevel,
    "git_common_dir": common_dir,
    "baseline_head":  git("rev-parse", "HEAD"),
    "session_id":     session_id or None,
    "context_tokens": size or None,
    "ts":             int(time.time()),
}

# Outside a git repo there is nothing to resume — git_toplevel is null and
# resume.sh's repo guard would reject the handoff anyway. Skip writing so a
# PreCompact firing in a non-repo dir leaves no junk handoff for a later session
# to spuriously consume.
if not common_dir:
    sys.exit(0)

# Per-repo keyed pointer: <keyed-dir>/.pending.json. Concurrent /handoff across
# repos write distinct files, so they never clobber each other.
path = os.path.join(keyed_dir(common_dir), ".pending.json")
try:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(obj, fh)
except Exception:
    sys.exit(0)
sys.exit(0)
PY
