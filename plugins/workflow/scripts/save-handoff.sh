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
#   ~/.claude/handoffs/<sha1(git_toplevel)[:16]>/
# as .pending.json (pointer) and <branch-slug>.md (doc). Per-repo keying means
# concurrent /handoff across repos never clobber each other (the old single global
# ~/.claude/.pending-handoff was last-writer-wins). resume.sh recomputes the same
# sha; the /handoff skill writes the same layout inline.
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


def keyed_dir(toplevel):
    # Per-repo handoff dir: ~/.claude/handoffs/<sha1(git_toplevel)[:16]>.
    # The 16-hex key must be byte-identical to resume.sh and the /handoff skill,
    # which both compute sha1(toplevel)[:16] (bash: sha1sum | cut -c1-16).
    if not toplevel:
        return None
    key = hashlib.sha1(toplevel.encode()).hexdigest()[:16]
    return os.path.expanduser(os.path.join("~/.claude/handoffs", key))


toplevel = git("rev-parse", "--show-toplevel")

# --print-dir: emit the keyed dir for the current repo and exit (empty outside a
# repo). The canonical reference the skill mirrors and the drift test checks.
if os.environ.get("SH_PRINT_DIR"):
    kd = keyed_dir(toplevel)
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
    kd = keyed_dir(toplevel)
    if not branch or not kd:
        return None
    try:
        safe = branch.replace("/", "-")
        path = os.path.join(kd, safe + ".md")
        return path if os.path.isfile(path) else None
    except Exception:
        return None


branch_val = git("rev-parse", "--abbrev-ref", "HEAD")
obj = {
    "handoff_path":   resolve_handoff(branch_val),
    "branch":         branch_val,
    "git_toplevel":   toplevel,
    "baseline_head":  git("rev-parse", "HEAD"),
    "session_id":     session_id or None,
    "context_tokens": size or None,
    "ts":             int(time.time()),
}

# Outside a git repo there is nothing to resume — git_toplevel is null and
# resume.sh's repo guard would reject the handoff anyway. Skip writing so a
# PreCompact firing in a non-repo dir leaves no junk handoff for a later session
# to spuriously consume.
if not toplevel:
    sys.exit(0)

# Per-repo keyed pointer: <keyed-dir>/.pending.json. Concurrent /handoff across
# repos write distinct files, so they never clobber each other.
path = os.path.join(keyed_dir(toplevel), ".pending.json")
try:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(obj, fh)
except Exception:
    sys.exit(0)
sys.exit(0)
PY
