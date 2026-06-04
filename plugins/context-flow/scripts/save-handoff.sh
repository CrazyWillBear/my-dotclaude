#!/usr/bin/env bash
#
# Shared handoff writer for the context-flow plugin.
#
# Single source of the ~/.claude/.pending-handoff JSON schema that resume.sh
# reads. Used by both the automatic Stop path (watchdog.sh) and the manual
# /handoff skill, so the schema lives in exactly one place.
#
#   save-handoff.sh [--session ID] [--size N] [--summary TEXT] [--arm]
#
#     --session ID   session id; used to read review.sh's reviewed-HEAD marker
#                    so the resumed session reviews FROM the right baseline.
#                    Absent (e.g. from agent Bash, where it is unset) -> HEAD.
#     --size N       context-token occupancy to record (informational).
#     --summary TEXT optional prose summary; resume.sh appends it to the resume
#                    instruction. The manual /handoff path uses this.
#     --arm          also defer code review (checkpoint.sh arm) so the resumed
#                    session reviews the wrap-up commits as one batch. The Stop
#                    path and the skill arm; the plan-accept gate does NOT.
#
# Git state is read from CLAUDE_PROJECT_DIR (else cwd). Fail open: any error
# exits 0 so a handoff attempt never wedges the session.

set -u

export SH_SESSION="" SH_SIZE="" SH_SUMMARY="" SH_ARM=""
while [ $# -gt 0 ]; do
    case "$1" in
        # Value flags guard against a missing/flag-like value so a bare
        # `--session --size 5` cannot swallow `--size` as the session id.
        --session) case "${2:-}" in ""|--*) shift 1 ;; *) SH_SESSION="$2"; shift 2 ;; esac ;;
        --size)    case "${2:-}" in ""|--*) shift 1 ;; *) SH_SIZE="$2";    shift 2 ;; esac ;;
        --summary) case "${2:-}" in ""|--*) shift 1 ;; *) SH_SUMMARY="$2"; shift 2 ;; esac ;;
        --arm)     SH_ARM="1"; shift ;;
        *)         shift ;;
    esac
done

command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Defer review first (reuse my-code-review's checkpoint.sh). It keys on the repo
# toplevel from its cwd, so run it inside the project dir to match review.sh.
if [ -n "$SH_ARM" ]; then
    ckpt="${CONTEXT_FLOW_CHECKPOINT_SH:-${CLAUDE_PLUGIN_ROOT:-}/../my-code-review/scripts/checkpoint.sh}"
    if [ -f "$ckpt" ]; then
        ( cd "${CLAUDE_PROJECT_DIR:-$PWD}" && bash "$ckpt" arm >/dev/null 2>&1 ) || true
    fi
fi

python3 <<"PY" || exit 0
import os, json, sys, time, glob, hashlib, tempfile, subprocess

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
summary = os.environ.get("SH_SUMMARY") or ""
try:
    size = int(os.environ.get("SH_SIZE") or 0)
except Exception:
    size = 0


def resolve_plan():
    # Plan being executed: newest *.md in ~/.claude/plans (checkpoint.sh's rule).
    try:
        plans = glob.glob(os.path.join(os.path.expanduser("~/.claude/plans"), "*.md"))
        return max(plans, key=os.path.getmtime) if plans else None
    except Exception:
        return None


def baseline():
    # review.sh's per-session reviewed marker = oldest unreviewed commit = the
    # baseline the resumed session must review FROM. Falls back to HEAD.
    if session_id:
        key = hashlib.sha1(session_id.encode()).hexdigest()[:16]
        p = os.path.join(tempfile.gettempdir(), "my-code-review-head-" + key + ".json")
        try:
            d = json.load(open(p))
            if isinstance(d, dict) and d.get("reviewed"):
                return d["reviewed"]
        except Exception:
            pass
    return git("rev-parse", "HEAD")


obj = {
    "plan_path":      resolve_plan(),
    "branch":         git("rev-parse", "--abbrev-ref", "HEAD"),
    "git_toplevel":   git("rev-parse", "--show-toplevel"),
    "baseline_head":  baseline(),
    "armed":          bool(os.environ.get("SH_ARM")),
    "session_id":     session_id or None,
    "context_tokens": size or None,
    "ts":             int(time.time()),
}
if summary:
    obj["summary"] = summary

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
