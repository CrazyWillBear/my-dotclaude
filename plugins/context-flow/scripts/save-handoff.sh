#!/usr/bin/env bash
#
# Shared handoff writer for the context-flow plugin.
#
# Single source of the ~/.claude/.pending-handoff JSON schema that resume.sh
# reads. Used by the watchdog's Phase-A plan-start gate and Phase-C post-wrap
# compact prompt, and by the PreCompact hook (which calls it with NO args before
# every compaction), so the schema lives in exactly one place.
#
#   save-handoff.sh [--session ID] [--size N]
#
#     --session ID   session id; recorded for debugging (informational).
#     --size N       context-token occupancy to record (informational).
#
# Git state is read from CLAUDE_PROJECT_DIR (else cwd). The baseline is simply the
# current HEAD — prior work is committed before a handoff. context-flow no longer
# defers code review, so there is no review state to read or arm here. Fail open:
# any error exits 0 so a handoff attempt never wedges the session.

set -u

export SH_SESSION="" SH_SIZE=""
while [ $# -gt 0 ]; do
    case "$1" in
        # Value flags guard against a missing/flag-like value so a bare
        # `--session --size 5` cannot swallow `--size` as the session id.
        --session) case "${2:-}" in ""|--*) shift 1 ;; *) SH_SESSION="$2"; shift 2 ;; esac ;;
        --size)    case "${2:-}" in ""|--*) shift 1 ;; *) SH_SIZE="$2";    shift 2 ;; esac ;;
        *)         shift ;;
    esac
done

command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

python3 <<"PY" || exit 0
import os, json, sys, time, glob, subprocess

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


session_id = os.environ.get("SH_SESSION") or ""
try:
    size = int(os.environ.get("SH_SIZE") or 0)
except Exception:
    size = 0


def resolve_plan():
    # Plan being executed: newest *.md in ~/.claude/plans.
    try:
        plans = glob.glob(os.path.join(os.path.expanduser("~/.claude/plans"), "*.md"))
        return max(plans, key=os.path.getmtime) if plans else None
    except Exception:
        return None


obj = {
    "plan_path":      resolve_plan(),
    "branch":         git("rev-parse", "--abbrev-ref", "HEAD"),
    "git_toplevel":   git("rev-parse", "--show-toplevel"),
    "baseline_head":  git("rev-parse", "HEAD"),
    "session_id":     session_id or None,
    "context_tokens": size or None,
    "ts":             int(time.time()),
}

# Outside a git repo there is nothing to resume — git_toplevel is null and
# resume.sh's repo guard would reject the handoff anyway. Skip writing so a
# PreCompact firing in a non-repo dir leaves no junk handoff for a later session
# to spuriously consume.
if not obj.get("git_toplevel"):
    sys.exit(0)

path = os.path.expanduser("~/.claude/.pending-handoff")
try:
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with open(path, "w") as fh:
        json.dump(obj, fh)
except Exception:
    sys.exit(0)
sys.exit(0)
PY
