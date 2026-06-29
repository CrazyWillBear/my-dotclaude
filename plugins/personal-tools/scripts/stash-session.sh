#!/usr/bin/env bash
#
# stash-session.sh — UserPromptSubmit hook for personal-tools.
#
# Stashes this session's transcript_path to a temp file so the /verify-plan skill
# (which never receives session_id/transcript_path in its execution context) can find
# the current session log. Keyed by sha1(git-toplevel)[:16] — the same key the skill
# recomputes — so hook and skill always agree even when running in different
# subdirectories of the same repo.
#
# Fires on every UserPromptSubmit (including the /verify-plan prompt itself), so the
# stash is always the most-recent session for this repo. That also defeats the
# two-sessions-in-one-repo race: the most-recent prompt wins.
#
# Non-git directories fall back to sha1(cwd)[:16] so the stash still works outside
# any repo.
#
# Fail-open: every error path exits 0. This hook must NEVER wedge a session or block
# a prompt.

export HOOK_INPUT="$(cat)"
command -v python3 >/dev/null 2>&1 || exit 0

python3 <<"PY" || exit 0
import os, json, sys, subprocess, hashlib, tempfile

raw = os.environ.get("HOOK_INPUT", "")
try:
    data = json.loads(raw) if raw else {}
except Exception:
    sys.exit(0)

transcript = str(data.get("transcript_path") or "").strip()
cwd = str(data.get("cwd") or os.getcwd()).strip()

# Nothing to stash if the transcript path is absent (shouldn't happen on
# UserPromptSubmit, but be defensive).
if not transcript:
    sys.exit(0)

# Key by git toplevel so that subdirectory cwd still matches the skill's key.
# Fall back to cwd if git is absent or cwd is outside a repo.
root = cwd
try:
    out = subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, timeout=5,
    )
    if out.returncode == 0 and out.stdout.strip():
        root = out.stdout.strip()
except Exception:
    pass

key = hashlib.sha1(root.encode()).hexdigest()[:16]
path = os.path.join(tempfile.gettempdir(), "verify-plan-session-" + key + ".path")
try:
    with open(path, "w") as fh:
        fh.write(transcript + "\n")
except Exception:
    pass
PY
exit 0
