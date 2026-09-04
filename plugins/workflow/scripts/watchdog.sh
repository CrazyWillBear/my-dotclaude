#!/usr/bin/env bash
#
# Orchestrate context gate for the workflow plugin.
#
# Wired on UserPromptSubmit only. When the user types the /orchestrate slash
# command (bare or with arguments, e.g. `/orchestrate 3` or
# `/orchestrate --max 2`) and main-thread context is already >=
# WORKFLOW_PLANGATE_TOKENS (default 60k), inject an advisory hint telling them to
# run /clear first — so the loop starts in a fresh window. /orchestrate keeps the
# orchestrator ON the main thread, so its context is the run's budget; starting
# it half-full is what strands a run mid-flight.
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


# Requires a leading slash + word boundary: "please orchestrate" does NOT match,
# and neither does a different command like /orchestrated-thing.
is_orchestrate = prompt == "/orchestrate" or prompt.startswith("/orchestrate ")
if not is_orchestrate:
    sys.exit(0)

size = context_tokens(transcript)
if size is None or size < PLANGATE:
    sys.exit(0)

kb = size // 1000
sys.stdout.write(json.dumps({
    "systemMessage": (
        "workflow: context already ~%dk tokens — /orchestrate works best "
        "in a fresh window. Run `/clear`, then `/orchestrate`." % kb
    ),
    "hookSpecificOutput": {
        "hookEventName": event,
        "additionalContext": (
            "The user is about to run /orchestrate, but the context window "
            "is already ~%dk tokens. Advise them to run `/clear` first, "
            "then `/orchestrate`, so the orchestration loop starts in fresh "
            "context. Only proceed without clearing if the user explicitly "
            "insists." % kb
        ),
    },
}))
sys.exit(0)
PY
