#!/usr/bin/env bash
#
# Orchestrate context gate + swarm peer rotation nudge, for the context plugin.
#
# Two independent advisories on one hook, both on UserPromptSubmit.
#
# 1. THE ORCHESTRATE GATE. When the user types the /orchestrate slash
# command (bare or with arguments, e.g. `/orchestrate 3` or
# `/orchestrate --max 2`) and main-thread context is already >=
# WORKFLOW_PLANGATE_TOKENS (default 60k), inject an advisory hint telling them to
# run /clear first — so the loop starts in a fresh window. /orchestrate keeps the
# orchestrator ON the main thread, so its context is the run's budget; starting
# it half-full is what strands a run mid-flight.
#
# 2. THE PEER ROTATION NUDGE (docs/swarm-design.md § Rotation). A swarm peer is a
# standing `claude --bg` session named by its roster role. `claude agents --json`
# exposes no context size, so the orchestrator CANNOT measure a peer — the trigger has
# to live in the peer, and this hook is already the only thing that reads a session's
# own occupancy. Past the roster row's `rotate_at` it injects: at the next natural
# stopping point run /handoff, then tell the orchestrator you are ready with the doc
# path. The peer picks the moment; nothing rotates itself.
#
# This is deliberately NOT the periodic nudge that was deleted (see the note at the
# bottom). That one fired in any session at a fixed occupancy and interrupted long
# autonomous runs. This one is gated three ways: the session's own name must be a
# `manager` or `doer` row in THIS project's roster.json, the threshold is that row's,
# and it says "next natural stopping point" so the model chooses. The orchestrator row
# is excluded — it is the human's own session, the one seat an interruption lands in —
# and an ordinary interactive session carries no `-n` name, so it matches no row.
#
# Never a decision:block — the orchestrate prompt still runs if the user
# proceeds. Natural-language phrasing and non-orchestrate prompts are always
# silent.
#
# Metric = the LAST assistant transcript entry's
#   usage.input_tokens + cache_read_input_tokens + cache_creation_input_tokens
# i.e. the tokens the model just saw = current occupancy.
#
# Design notes:
#   * Hooks are plain shell; they cannot run /compact, /clear, /handoff, or any
#     tool. So we inject instructions; the only manual step is the one command.
#   * Fail open: any error / missing dependency exits 0 so we never wedge a session.
#   * Stateless — the gate is a pure function of (event, prompt, context size).
#   * Subagents are never triggered — metric reads the main transcript only.
#
# There is deliberately NO periodic "wrap up and /handoff" nudge. It fired on any
# work at a fixed occupancy and interrupted long autonomous runs at their worst
# moment; a session that needs a handoff still gets one from the PreCompact hook
# (save-handoff.sh), which fires on real compaction rather than on a guess.

# Capture the hook JSON into an env var (avoids stdin/quoting headaches in python).
export HOOK_INPUT="$(cat)"

# Need python3; without it, bow out quietly (never wedge a session).
command -v python3 >/dev/null 2>&1 || exit 0

# Quoted heredoc so literal punctuation/apostrophes in the body can never break
# shell quoting. HOOK_INPUT travels via the environment, so stdin stays free.
python3 <<"PY" || exit 0
import os, json, subprocess, sys

raw = os.environ.get("HOOK_INPUT", "")
try:
    data = json.loads(raw) if raw else {}
except Exception:
    sys.exit(0)


def _int_env(name, default):
    try:
        return int(os.environ.get(name) or default)
    except Exception:
        return default


PLANGATE = _int_env("WORKFLOW_PLANGATE_TOKENS", 60000)

# roster.sh's own fallback, and the design doc's documented default. Duplicated here
# rather than shelled out for: roster.sh lives in the SWARM plugin, and nothing calls
# across plugins except into infra (docs/swarm-design.md § Plugin split).
ROTATE_AT_DEFAULT = 300000
PEER_KINDS = ("manager", "doer")

event      = data.get("hook_event_name", "")
prompt     = str(data.get("prompt") or "").strip()
transcript = data.get("transcript_path", "")

# The gate is UserPromptSubmit-only; everything else is silent.
if event != "UserPromptSubmit":
    sys.exit(0)


def context_tokens(path):
    # Sum of the LAST assistant entry's input-side usage = current occupancy.
    if not path or not os.path.isfile(path):
        return None
    last = None
    try:
        with open(path, "r", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get("type") != "assistant":
                    continue
                msg = entry.get("message")
                if not isinstance(msg, dict):
                    continue
                usage = msg.get("usage")
                if isinstance(usage, dict):
                    last = usage
    except Exception:
        return None
    if not isinstance(last, dict):
        return None
    try:
        return (int(last.get("input_tokens", 0) or 0)
                + int(last.get("cache_read_input_tokens", 0) or 0)
                + int(last.get("cache_creation_input_tokens", 0) or 0))
    except Exception:
        return None


def emit(system_message, context):
    sys.stdout.write(json.dumps({
        "systemMessage": system_message,
        "hookSpecificOutput": {
            "hookEventName": event,
            "additionalContext": context,
        },
    }))
    sys.exit(0)


size = context_tokens(transcript)

# --- 1. the orchestrate gate -----------------------------------------------
# Requires a leading slash + word boundary: "please orchestrate" does NOT match,
# and neither does a different command like /orchestrated-thing.
if prompt == "/orchestrate" or prompt.startswith("/orchestrate "):
    if size is None or size < PLANGATE:
        sys.exit(0)
    kb = size // 1000
    emit(
        "workflow: context already ~%dk tokens — /orchestrate works best "
        "in a fresh window. Run `/clear`, then `/orchestrate`." % kb,
        "The user is about to run /orchestrate, but the context window "
        "is already ~%dk tokens. Advise them to run `/clear` first, "
        "then `/orchestrate`, so the orchestration loop starts in fresh "
        "context. Only proceed without clearing if the user explicitly "
        "insists." % kb,
    )

# --- 2. the peer rotation nudge -------------------------------------------
if size is None:
    sys.exit(0)

project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or ""
try:
    with open(os.path.join(project_dir, ".claude", "swarm", "roster.json")) as fh:
        roster = json.load(fh)
    assert isinstance(roster, dict)
except Exception:
    # Not a swarm project, or a roster nobody can read. Either way this is not the
    # place to complain about it — roster.sh validate is.
    sys.exit(0)


def rotate_at(row):
    try:
        return int(row.get("rotate_at") or ROTATE_AT_DEFAULT)
    except Exception:
        return ROTATE_AT_DEFAULT


peers = {name: row for name, row in roster.items()
         if isinstance(row, dict) and row.get("kind") in PEER_KINDS}
if not peers:
    sys.exit(0)

# Cheapest gate first. Resolving this session's name costs a `claude agents --json`
# subprocess, and this hook runs on EVERY prompt in the project — so no peer row can
# possibly be past its threshold means don't pay for it.
if size < min(rotate_at(row) for row in peers.values()):
    sys.exit(0)

# Who am I? Only infra knows, and only through the stable link.
status = os.path.expanduser("~/.claude/kit/infra/scripts/session-status.sh")
me = ""
if os.path.isfile(status):
    try:
        result = subprocess.run(["bash", status, "--self"],
                                capture_output=True, text=True, timeout=60)
        if result.returncode == 0:
            me = result.stdout.strip()
    except Exception:
        me = ""

# No name, a name that is no role, or a role that is not a peer — the orchestrator's
# own session and every worker row land here. Silent.
if me not in peers or size < rotate_at(peers[me]):
    sys.exit(0)

orch = next((name for name, row in roster.items()
             if isinstance(row, dict) and row.get("kind") == "orchestrator"),
            "your orchestrator")
kb, limit = size // 1000, rotate_at(peers[me]) // 1000
emit(
    "swarm: %s is at ~%dk tokens, past its rotate_at of %dk — /handoff at the next "
    "natural stopping point." % (me, kb, limit),
    "Your context is ~%dk tokens, past the `%s` roster row's rotate_at of %dk, so you "
    "are due to rotate. At the NEXT NATURAL STOPPING POINT — finish what is in flight "
    "first, never mid-task — run `/handoff`, then SendMessage \"%s\" that you are "
    "ready to rotate, naming the handoff doc's path. A message that arrives after you "
    "start /handoff goes into the doc verbatim before you reply ready. Keep working "
    "until that stopping point; you do not rotate yourself." % (kb, me, limit, orch),
)
PY
