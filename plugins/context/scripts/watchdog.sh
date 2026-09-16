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
# is excluded — it is the human's own session, the one seat an interruption lands in.
#
# WHERE THE NAME COMES FROM: the transcript itself. `claude -n NAME` writes
# `{"type":"agent-name","agentName":NAME,...}` rows into the JSONL, so the file this
# hook already opens for occupancy also answers "who am I?" — no `claude agents --json`
# subprocess on every prompt, and no call into another plugin, which the star topology
# forbids outright (§ Plugin split: context calls into NOTHING). A session started
# without -n writes no such row and so matches no roster role, which is what keeps this
# out of an ordinary interactive window. A renamed session has several rows; the LAST
# wins (seen live: a peer renamed from performance-engineer-cogito).
#
# Stateless, like the gate: it re-fires on every prompt until the peer is actually
# rotated. That is deliberate — a nudge the peer deferred once should still be true.
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
# There is deliberately NO periodic "wrap up and /handoff" nudge for an ordinary
# session, at any occupancy. It fired on any work at a fixed occupancy and interrupted
# long autonomous runs at their worst moment; a session that needs a handoff still gets
# one from the PreCompact hook (save-handoff.sh), which fires on real compaction rather
# than on a guess. The peer nudge above is the one exception, and the three gates in
# item 2 are what make it one: a roster peer's whole purpose is to be rotated.

# Capture the hook JSON into an env var (avoids stdin/quoting headaches in python).
export HOOK_INPUT="$(cat)"

# Need python3; without it, bow out quietly (never wedge a session).
command -v python3 >/dev/null 2>&1 || exit 0

# Quoted heredoc so literal punctuation/apostrophes in the body can never break
# shell quoting. HOOK_INPUT travels via the environment, so stdin stays free.
python3 <<"PY" || exit 0
import os, json, sys

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

# roster.sh's own DEFAULTS, and the design doc's documented default. Duplicated here on
# purpose: roster.sh lives in the SWARM plugin and context calls into nothing
# (docs/swarm-design.md § Plugin split), so one int is cheaper than a cross-plugin
# path. ponytail: the comment is the only link between the two — move them together.
ROTATE_AT_DEFAULT = 300000
PEER_KINDS = ("manager", "doer")

event      = data.get("hook_event_name", "")
prompt     = str(data.get("prompt") or "").strip()
transcript = data.get("transcript_path", "")

# The gate is UserPromptSubmit-only; everything else is silent.
if event != "UserPromptSubmit":
    sys.exit(0)


def transcript_state(path):
    # One pass, two answers: the LAST assistant entry's input-side usage = current
    # occupancy, and the LAST agent-name row = this session's own name (or None).
    if not path or not os.path.isfile(path):
        return None, None
    last = None
    name = None
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
                if entry.get("type") == "agent-name":
                    name = entry.get("agentName") or name
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
        return None, None
    if not isinstance(last, dict):
        return None, name
    try:
        return (int(last.get("input_tokens", 0) or 0)
                + int(last.get("cache_read_input_tokens", 0) or 0)
                + int(last.get("cache_creation_input_tokens", 0) or 0)), name
    except Exception:
        return None, name


def emit(system_message, context):
    sys.stdout.write(json.dumps({
        "systemMessage": system_message,
        "hookSpecificOutput": {
            "hookEventName": event,
            "additionalContext": context,
        },
    }))
    sys.exit(0)


size, me = transcript_state(transcript)

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
if size is None or not me:
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


# A name that is no role, or a role that is not a PEER — the orchestrator's own session
# and every worker row land here — is silent, at any occupancy.
row = roster.get(me)
if not isinstance(row, dict) or row.get("kind") not in PEER_KINDS:
    sys.exit(0)

limit = rotate_at(row)
if size < limit:
    sys.exit(0)

orch = next((name for name, row in roster.items()
             if isinstance(row, dict) and row.get("kind") == "orchestrator"),
            "your orchestrator")
kb, limit = size // 1000, limit // 1000
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
