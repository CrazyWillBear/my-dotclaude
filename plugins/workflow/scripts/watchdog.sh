#!/usr/bin/env bash
#
# Context watchdog for the workflow plugin.
#
# Wired on UserPromptSubmit + PostToolUse (detect mid-work). It reads the LIVE
# context occupancy from the transcript and fires a one-shot signal when the
# window fills — the agent wraps up, commits, and runs /handoff in one step.
# (No hook or agent can run /clear, /handoff, or /compact itself; they are
# user-typed REPL input only.)
#
#   * 100k signal — mid-execution wrap-and-handoff nudge (active events,
#     >= WORKFLOW_NUDGE_TOKENS, default 100k): once per cycle, ask the agent to
#     wrap up at the next natural breaking point, commit, and run /handoff. The
#     signal fires on any work (not orchestrate-specific). resume.sh re-arms the
#     sentinel on /clear or /compact so a later climb back over 100k in the same
#     long session can re-fire.
#
# Orchestrate gate (advisory, UserPromptSubmit only): when the user types the
# /orchestrate slash command (bare or with arguments, e.g. `/orchestrate 3` or
# `/orchestrate --max 2`) and main-thread context >= WORKFLOW_PLANGATE_TOKENS
# (default 60k), inject an advisory hint telling them to run /clear first, then
# /orchestrate — so the loop runs in fresh context. Never a decision:block; the
# orchestrate prompt still runs if the user proceeds. Natural-language phrasing
# and non-orchestrate prompts are always silent.
#
# Metric = the LAST assistant transcript entry's
#   usage.input_tokens + cache_read_input_tokens + cache_creation_input_tokens
# i.e. the tokens the model just saw = current occupancy.
#
# Design notes:
#   * Hooks are plain shell; they cannot run /compact, /clear, /handoff, or any
#     tool. So we inject instructions and write files; the only manual step is the
#     one command.
#   * Fail open: any error / missing dependency exits 0 so we never wedge a session.
#   * Per-session sentinels (sha1(session_id)[:16] temp files) bound each signal.
#   * Subagents are never triggered — metric reads the main transcript only.

# Capture the hook JSON into an env var (avoids stdin/quoting headaches in python).
export HOOK_INPUT="$(cat)"

# Need python3; without it, bow out quietly (never wedge a session).
command -v python3 >/dev/null 2>&1 || exit 0

# Quoted heredoc so literal punctuation/apostrophes in the body can never break
# shell quoting. HOOK_INPUT travels via the environment, so stdin stays free.
python3 <<"PY" || exit 0
import os, json, sys, time, tempfile, hashlib

raw = os.environ.get("HOOK_INPUT", "")
try:
    data = json.loads(raw) if raw else {}
except Exception:
    sys.exit(0)

# Thresholds (env-overridable). Defaults: nudge at 100k, orchestrate gate at 60k.
def _int_env(name, default):
    try:
        return int(os.environ.get(name) or default)
    except Exception:
        return default

NUDGE    = _int_env("WORKFLOW_NUDGE_TOKENS", 100000)
PLANGATE = _int_env("WORKFLOW_PLANGATE_TOKENS", 60000)

event       = data.get("hook_event_name", "")
prompt      = str(data.get("prompt") or "").strip()
transcript  = data.get("transcript_path", "")
session_id  = str(data.get("session_id") or "default")

tmp = tempfile.gettempdir()
skey = hashlib.sha1(session_id.encode()).hexdigest()[:16]
nudged_path = os.path.join(tmp, "workflow-nudged-" + skey + ".json")


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


def touch(path, extra=None):
    obj = {"ts": int(time.time())}
    if extra:
        obj.update(extra)
    try:
        with open(path, "w") as fh:
            json.dump(obj, fh)
    except Exception:
        pass


def emit(obj):
    sys.stdout.write(json.dumps(obj))
    sys.exit(0)


size = context_tokens(transcript)

# Active events (UserPromptSubmit / PostToolUse) only.
if event not in ("UserPromptSubmit", "PostToolUse"):
    sys.exit(0)

# --- Orchestrate gate (advisory): on UserPromptSubmit, when the /orchestrate
# slash command is typed (bare or with arguments like `3`, `--max 2`, `3 --max 2`)
# and context >= PLANGATE, inject an advisory hint to run /clear first so the loop
# starts in fresh context. Never a decision:block — the prompt survives and
# /orchestrate still runs if the user proceeds. Non-orchestrate prompts and
# /orchestrate under the threshold are always silent. Natural-language phrasing
# like "please orchestrate" does NOT match (requires leading slash + word boundary).
is_orchestrate = prompt == "/orchestrate" or prompt.startswith("/orchestrate ")
if (event == "UserPromptSubmit"
        and is_orchestrate
        and size is not None
        and size >= PLANGATE):
    kb = size // 1000
    emit({
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
    })

# --- 100k universal signal: once per cycle, tell the agent to wrap up at the
# next natural breaking point, commit, and run /handoff. Fires on any work
# (not orchestrate-specific). Silent on subsequent events while still over budget
# (sentinel guards re-fire). resume.sh re-arms on /clear or /compact.
if size is not None and size >= NUDGE and not os.path.exists(nudged_path):
    touch(nudged_path)
    kb = size // 1000
    emit({
        "systemMessage":
            "workflow: ~%dk tokens in context — wrap it up soon, commit, and run `/handoff`." % kb,
        "hookSpecificOutput": {
            "hookEventName": event,
            "additionalContext":
                "Context over budget (~%dk tokens). Stop at the next natural "
                "breaking point: finish and COMMIT the current sub-task, then "
                "run `/handoff` — it saves a rich handoff doc + resume pointer "
                "and walks you through `/clear` into fresh context where the "
                "plan auto-resumes. Do not start new work before then." % kb,
        },
    })

sys.exit(0)
PY
