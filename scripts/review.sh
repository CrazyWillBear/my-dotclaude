#!/usr/bin/env bash
#
# Stop hook for the team-code-review plugin.
#
# Reads the hook payload from stdin, scans the session transcript for files
# this session edited, and — if any have not been reviewed yet — emits a
# "block" decision asking the main agent to delegate to the `code-reviewer`
# subagent. If there is nothing to review, it stays completely silent.
#
# Design notes:
#   * Hooks are plain shell commands; they cannot call the Task tool directly.
#     So instead of reviewing here, we hand the main agent an instruction.
#   * We always "fail open": any error exits 0 so we never wedge the user's
#     session over a parsing hiccup or a missing dependency.

# Capture the hook JSON into an env var (avoids stdin/quoting headaches in python).
export HOOK_INPUT="$(cat)"

# No python3? Don't block the user — just bow out quietly.
command -v python3 >/dev/null 2>&1 || exit 0

python3 -c '
import os, json, sys, tempfile, hashlib

raw = os.environ.get("HOOK_INPUT", "")
try:
    data = json.loads(raw) if raw else {}
except Exception:
    sys.exit(0)

# If this stop is itself the result of a previous stop-hook continuation,
# the review already ran this turn. Stay silent to avoid an infinite loop.
if data.get("stop_hook_active"):
    sys.exit(0)

transcript = data.get("transcript_path", "")
if not transcript or not os.path.isfile(transcript):
    sys.exit(0)

EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
touched = []
seen = set()
with open(transcript, "r", errors="ignore") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except Exception:
            continue
        msg = entry.get("message")
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") != "tool_use":
                continue
            if block.get("name") not in EDIT_TOOLS:
                continue
            inp = block.get("input") or {}
            path = inp.get("file_path") or inp.get("notebook_path")
            if path and path not in seen:
                seen.add(path)
                touched.append(path)

if not touched:
    sys.exit(0)

# Only flag files we have not already reviewed this session, so long sessions
# do not re-review the same files on every single turn.
session_id = str(data.get("session_id") or "default")
key = hashlib.sha1(session_id.encode()).hexdigest()[:16]
state_path = os.path.join(tempfile.gettempdir(), "team-code-review-" + key + ".json")
already = set()
try:
    with open(state_path) as fh:
        already = set(json.load(fh))
except Exception:
    already = set()

new_files = [p for p in touched if p not in already]
if not new_files:
    sys.exit(0)

try:
    with open(state_path, "w") as fh:
        json.dump(sorted(set(touched) | already), fh)
except Exception:
    pass

plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
if plugin_root:
    rubric = os.path.join(plugin_root, "skills", "review-rubric", "SKILL.md")
else:
    rubric = "the team review rubric (skills/review-rubric/SKILL.md in this plugin)"

file_list = "\n".join("  - " + p for p in new_files)

# A project can opt into plain-language review output by writing "plain" to
# .claude/review-audience (the non-developer setup does this). Default is the
# technical, severity-grouped report aimed at developers. We look under the
# project root (CLAUDE_PROJECT_DIR is set by Claude Code for hooks) and fall
# back to the current working directory.
project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
audience = "technical"
try:
    with open(os.path.join(project_dir, ".claude", "review-audience")) as fh:
        marker = fh.read().strip().lower()
    if marker in ("plain", "technical"):
        audience = marker
except Exception:
    pass

if audience == "plain":
    reason = (
        "Automatic code review (team-code-review plugin). You edited these "
        "file(s) this session and have not reviewed them yet:\n"
        + file_list
        + "\n\nBefore you finish, use the Task tool to launch the `code-reviewer` "
        "subagent. Give it the exact file paths above and tell it to apply the "
        "team rubric at:\n  " + rubric
        + "\n\nThe person you are helping is NOT a programmer. The technical "
        "findings from the subagent are for you, not for them: use them to fix "
        "any real problems it reports (bugs, security issues, breakage). Then give a "
        "short, friendly, plain-English summary of what you did — what was "
        "wrong, what you changed, and why it matters to them. No jargon, no "
        "severity labels, no file:line references. If nothing needed fixing, "
        "say so in one reassuring sentence."
    )
else:
    reason = (
        "Auto code-review (team-code-review plugin). These file(s) were edited "
        "this session and have not been reviewed yet:\n"
        + file_list
        + "\n\nBefore you finish, use the Task tool to launch the `code-reviewer` "
        "subagent. Give it the exact file paths above and tell it to apply the "
        "team rubric at:\n  " + rubric
        + "\n\nWhen the subagent reports back, summarize its findings for me "
        "grouped by severity (blocker / warning / nit). If the changes are "
        "trivial (docs, comments, formatting) you may note that briefly and stop."
    )

print(json.dumps({"decision": "block", "reason": reason}))
sys.exit(0)
' || exit 0
