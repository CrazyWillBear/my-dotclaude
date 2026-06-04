#!/usr/bin/env bash
#
# Context watchdog for the context-flow plugin.
#
# Wired on UserPromptSubmit + PostToolUse (detect mid-work) and Stop (the
# handoff). It reads the LIVE context occupancy from the transcript and, as the
# window fills, drives a clean handoff + session-restart instead of an in-place
# /compact (which no hook can trigger). Three jobs, by event:
#
#   * UserPromptSubmit / PostToolUse, over CONTEXT_FLOW_NUDGE_TOKENS (default
#     150k), once per session: inject a "wrap up + commit the current sub-task,
#     don't start new work" nudge, and arm the my-code-review deferral
#     (checkpoint.sh arm) so review stays quiet through the coming restart seam.
#   * Plan-accept gate — the first event after an ExitPlanMode acceptance: if
#     context is already over CONTEXT_FLOW_PLANGATE_TOKENS (default 60k), save a
#     handoff and tell the user to relaunch BEFORE executing, so the plan runs
#     with fresh context. One-shot per session. Does NOT defer review (no work
#     has happened yet — deferring would suppress review all session if ignored).
#   * Stop, if armed this session and still over budget: write the handoff (plan
#     path, branch, pre-handoff reviewed baseline) and tell the user to relaunch.
#     resume.sh auto-resumes on the next launch.
#
# Metric = the LAST assistant transcript entry's
#   usage.input_tokens + cache_read_input_tokens + cache_creation_input_tokens
# i.e. the tokens the model just saw = current occupancy. (Not caveman-stats'
# cumulative output_tokens — different number, wrong signal here.)
#
# Design notes (mirrors my-code-review's review.sh / suggest-commit.sh):
#   * Hooks are plain shell; they cannot run /compact, /clear, or any tool. So
#     we inject instructions and write files; the only manual step is relaunch.
#   * Fail open: any error / missing dependency exits 0 so we never wedge a
#     session.
#   * Per-session sentinels (sha1(session_id)[:16] temp files) bound each signal
#     to once per session, mirroring review.sh's reviewed-HEAD marker.
#   * The handoff JSON is written by the shared scripts/save-handoff.sh (single
#     schema writer, also used by the /handoff skill) — we never build it here.

# Capture the hook JSON into an env var (avoids stdin/quoting headaches in python).
export HOOK_INPUT="$(cat)"

# Need python3 and git; without either, bow out quietly (never wedge a session).
command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Quoted heredoc so literal punctuation/apostrophes in the body can never break
# shell quoting. HOOK_INPUT travels via the environment, so stdin stays free.
python3 <<"PY" || exit 0
import os, json, sys, time, tempfile, hashlib, subprocess

raw = os.environ.get("HOOK_INPUT", "")
try:
    data = json.loads(raw) if raw else {}
except Exception:
    sys.exit(0)

# Thresholds (env-overridable). Defaults: nudge at 150k, plan-accept gate at 60k.
def _int_env(name, default):
    try:
        return int(os.environ.get(name) or default)
    except Exception:
        return default

NUDGE    = _int_env("CONTEXT_FLOW_NUDGE_TOKENS", 150000)
PLANGATE = _int_env("CONTEXT_FLOW_PLANGATE_TOKENS", 60000)

event       = data.get("hook_event_name", "")
transcript  = data.get("transcript_path", "")
session_id  = str(data.get("session_id") or "default")
project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")

tmp = tempfile.gettempdir()
skey = hashlib.sha1(session_id.encode()).hexdigest()[:16]
nudged_path   = os.path.join(tmp, "context-flow-nudged-"   + skey + ".json")
plangate_path = os.path.join(tmp, "context-flow-plangate-" + skey + ".json")


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


def plan_accepted(path):
    # True if an ExitPlanMode tool_use appears anywhere in the transcript
    # (mirrors suggest-commit.sh's detection).
    if not path or not os.path.isfile(path):
        return False
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
                msg = entry.get("message")
                if not isinstance(msg, dict):
                    continue
                content = msg.get("content")
                if not isinstance(content, list):
                    continue
                for block in content:
                    if (isinstance(block, dict)
                            and block.get("type") == "tool_use"
                            and block.get("name") == "ExitPlanMode"):
                        return True
    except Exception:
        return False
    return False


def touch(path):
    try:
        with open(path, "w") as fh:
            json.dump({"ts": int(time.time())}, fh)
    except Exception:
        pass


def run_checkpoint(action):
    # Reuse my-code-review's sibling checkpoint.sh to arm/clear the per-repo
    # review deferral. It keys on `git rev-parse --show-toplevel` from its cwd,
    # so run it inside the project dir to match review.sh's key.
    ckpt = os.environ.get("CONTEXT_FLOW_CHECKPOINT_SH")
    if not ckpt and plugin_root:
        ckpt = os.path.join(plugin_root, "..", "my-code-review", "scripts", "checkpoint.sh")
    if not ckpt or not os.path.isfile(ckpt):
        return
    try:
        subprocess.run(["bash", ckpt, action], cwd=project_dir,
                       capture_output=True, timeout=10)
    except Exception:
        pass


def save_handoff(size, arm):
    # Delegate to the shared writer so the handoff schema lives in one place.
    sh = os.environ.get("CONTEXT_FLOW_SAVE_HANDOFF_SH")
    if not sh and plugin_root:
        sh = os.path.join(plugin_root, "scripts", "save-handoff.sh")
    if not sh or not os.path.isfile(sh):
        return
    args = ["bash", sh, "--session", session_id, "--size", str(size)]
    if arm:
        args.append("--arm")
    try:
        subprocess.run(args, cwd=project_dir, capture_output=True, timeout=10)
    except Exception:
        pass


def emit(obj):
    sys.stdout.write(json.dumps(obj))
    sys.exit(0)


size = context_tokens(transcript)

# --- Stop: hand off if armed this session and still over budget. -------------
if event == "Stop":
    if not os.path.exists(nudged_path):
        sys.exit(0)
    if size is None or size < NUDGE:
        sys.exit(0)
    save_handoff(size, arm=True)
    kb = size // 1000
    emit({"systemMessage":
          "context-flow: handoff saved (~%dk tokens in context). `exit` then "
          "`claude` to continue with fresh context — I'll auto-resume." % kb})

# --- Active events (UserPromptSubmit / PostToolUse). -------------------------
# Plan-accept gate: one-shot at the first event after an ExitPlanMode accept.
if not os.path.exists(plangate_path) and plan_accepted(transcript):
    touch(plangate_path)  # mark observed regardless of action: one gate/session
    if size is not None and size >= PLANGATE:
        save_handoff(size, arm=False)
        kb = size // 1000
        emit({
            "systemMessage":
                "context-flow: context already ~%dk tokens at plan start. "
                "Relaunch to execute with fresh context — `exit` then `claude`; "
                "plan saved, I'll auto-resume." % kb,
            "hookSpecificOutput": {
                "hookEventName": event,
                "additionalContext":
                    "A plan was just approved, but the context window is already "
                    "~%dk tokens. Recommend the user relaunch (`exit` then "
                    "`claude`) before executing: a handoff is saved that will "
                    "auto-resume this plan with fresh context. If they prefer to "
                    "push on anyway, you may continue." % kb,
            },
        })

# Budget nudge: once per session, arm review deferral + ask to wrap up.
if size is not None and size >= NUDGE and not os.path.exists(nudged_path):
    touch(nudged_path)
    run_checkpoint("arm")
    kb = size // 1000
    emit({
        "systemMessage":
            "context-flow: ~%dk tokens in context — wrapping up at the next "
            "stopping point." % kb,
        "hookSpecificOutput": {
            "hookEventName": event,
            "additionalContext":
                "Context over budget (~%dk tokens). Stop at the next natural "
                "stopping point: finish and COMMIT the current sub-task, and "
                "don't start new work. When you stop I'll save a handoff so you "
                "can relaunch with fresh context and auto-resume. Code review is "
                "paused until then." % kb,
        },
    })

sys.exit(0)
PY
