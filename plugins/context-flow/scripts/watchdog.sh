#!/usr/bin/env bash
#
# Context watchdog for the context-flow plugin.
#
# Wired on UserPromptSubmit + PostToolUse (detect mid-work) and Stop (the wrap
# seam). It reads the LIVE context occupancy from the transcript and drives a
# deliberate, EARLY /clear or /compact as the window fills — the user types the
# one command, the hook handles everything around it. (No hook or agent can run
# /clear or /compact itself; they are user-typed REPL input only.) Three phases:
#
#   * Phase A — plan-start clear gate (active events, on an ExitPlanMode accept,
#     >= CONTEXT_FLOW_PLANGATE_TOKENS, default 60k): one-shot per session. Save a
#     handoff and HALT the agent with "do NOT implement yet; run /clear, then send
#     `go`". On PostToolUse this is decision:"block"; on UserPromptSubmit it is the
#     same halt via hookSpecificOutput.additionalContext — a block there would
#     discard the user's typed prompt. resume.sh re-injects after the /clear.
#   * Phase B — mid-execution wrap nudge (active events, >= CONTEXT_FLOW_NUDGE_
#     TOKENS, default 160k): once per cycle, ask the agent to wrap up at a natural
#     breaking point and commit. Records HEAD so Phase C can tell a wrap landed.
#     Does NOT touch code review — the reviewer runs normally on the wrap commit.
#   * Phase C — post-wrap compact prompt (Stop, the next clean stop after the
#     nudge once a wrap commit exists): one-shot per cycle. Save a handoff and
#     tell the user to run /compact (once the review and fixes are in), then send
#     `continue`. resume.sh re-injects the plan and resets the Phase-B/C sentinels
#     after the /compact so a later climb can re-nudge in the same long session.
#
# Metric = the LAST assistant transcript entry's
#   usage.input_tokens + cache_read_input_tokens + cache_creation_input_tokens
# i.e. the tokens the model just saw = current occupancy.
#
# Design notes (mirrors my-code-review's review.sh):
#   * Hooks are plain shell; they cannot run /compact, /clear, or any tool. So we
#     inject instructions and write files; the only manual step is the one command.
#   * Fail open: any error / missing dependency exits 0 so we never wedge a session.
#   * Per-session sentinels (sha1(session_id)[:16] temp files) bound each signal,
#     mirroring review.sh's reviewed-HEAD marker.
#   * The handoff JSON is written by the shared scripts/save-handoff.sh (single
#     schema writer) — we never build it here.

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

# Thresholds (env-overridable). Defaults: nudge at 160k, plan-accept gate at 60k.
def _int_env(name, default):
    try:
        return int(os.environ.get(name) or default)
    except Exception:
        return default

NUDGE    = _int_env("CONTEXT_FLOW_NUDGE_TOKENS", 160000)
PLANGATE = _int_env("CONTEXT_FLOW_PLANGATE_TOKENS", 60000)

event       = data.get("hook_event_name", "")
transcript  = data.get("transcript_path", "")
session_id  = str(data.get("session_id") or "default")
project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")

tmp = tempfile.gettempdir()
skey = hashlib.sha1(session_id.encode()).hexdigest()[:16]
nudged_path    = os.path.join(tmp, "context-flow-nudged-"    + skey + ".json")
plangate_path  = os.path.join(tmp, "context-flow-plangate-"  + skey + ".json")
compacted_path = os.path.join(tmp, "context-flow-compacted-" + skey + ".json")


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


def touch(path, extra=None):
    obj = {"ts": int(time.time())}
    if extra:
        obj.update(extra)
    try:
        with open(path, "w") as fh:
            json.dump(obj, fh)
    except Exception:
        pass


def read_json(path):
    try:
        with open(path) as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


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


def tree_dirty():
    # git diff --quiet HEAD exits nonzero when tracked changes differ from HEAD.
    # On any error treat as dirty so Phase C never fires on an unclear state.
    try:
        rc = subprocess.run(
            ["git", "-C", project_dir, "diff", "--quiet", "HEAD"],
            capture_output=True, timeout=10,
        ).returncode
    except Exception:
        return True
    return rc != 0


def save_handoff(size):
    # Delegate to the shared writer so the handoff schema lives in one place.
    sh = os.environ.get("CONTEXT_FLOW_SAVE_HANDOFF_SH")
    if not sh and plugin_root:
        sh = os.path.join(plugin_root, "scripts", "save-handoff.sh")
    if not sh or not os.path.isfile(sh):
        return
    args = ["bash", sh, "--session", session_id, "--size", str(size)]
    try:
        subprocess.run(args, cwd=project_dir, capture_output=True, timeout=10)
    except Exception:
        pass


def emit(obj):
    sys.stdout.write(json.dumps(obj))
    sys.exit(0)


size = context_tokens(transcript)

# --- Phase C — Stop: prompt /compact once the wrap-up commit has landed. ------
if event == "Stop":
    if not os.path.exists(nudged_path):       # no nudge this cycle -> nothing to do
        sys.exit(0)
    if os.path.exists(compacted_path):        # already prompted this cycle
        sys.exit(0)
    head = git("rev-parse", "HEAD")
    nudge_head = read_json(nudged_path).get("head")
    if not head or not nudge_head or head == nudge_head:
        sys.exit(0)                           # no wrap commit landed yet
    if tree_dirty():
        sys.exit(0)                           # still mid-work; wait for a clean stop
    save_handoff(size or 0)
    touch(compacted_path)
    emit({"systemMessage":
          "context-flow: wrap-up committed. Once the code review and any fixes "
          "are in, run `/compact`, then send `continue` — I'll re-inject the "
          "plan and keep going in compacted context."})

# --- Active events (UserPromptSubmit / PostToolUse). -------------------------
# Phase A — plan-start clear gate: one-shot at the first event after an
# ExitPlanMode accept. Over the gate, HALT the agent and ask for a /clear.
# plan_accepted() detects a *proposed* plan (an ExitPlanMode tool_use) — normally
# an accept, but like suggest-commit.sh it cannot truly tell accept from reject.
# Only consume the one-shot once the metric is readable: a transient transcript
# read miss (size is None) must NOT burn the gate, or the plan-start halt would
# be disabled for the rest of the session.
if not os.path.exists(plangate_path) and plan_accepted(transcript) and size is not None:
    touch(plangate_path)  # one gate per session, now that the metric is readable
    if size >= PLANGATE:
        save_handoff(size)
        kb = size // 1000
        halt_instruction = (
            "A plan was just approved, but the context window is already "
            "~%dk tokens — too full to execute the plan cleanly. Do NOT begin "
            "implementing. Tell the user to run `/clear`, then send `go`: "
            "context-flow saved a handoff and will re-inject the plan into the "
            "fresh session automatically, so no work is lost. Only continue "
            "without clearing if the user explicitly insists." % kb
        )
        halt_message = (
            "context-flow: context already ~%dk tokens at plan start. Run "
            "`/clear`, then send `go` — the plan will auto-resume in fresh "
            "context." % kb
        )
        # The watchdog is wired on both UserPromptSubmit and PostToolUse, so the
        # plan-accept gate can fire on either. Branch the emit by event:
        if event == "UserPromptSubmit":
            # On UserPromptSubmit, decision:"block" DISCARDS the user's typed
            # message and surfaces only `reason` — so typing `go` right after a
            # plan would be silently eaten. Inject the same halt as
            # additionalContext instead: it lands as context without discarding
            # the prompt.
            emit({
                "systemMessage": halt_message,
                "hookSpecificOutput": {
                    "hookEventName": event,
                    "additionalContext": halt_instruction,
                },
            })
        else:
            # PostToolUse (the natural plan-accept seam): decision:"block" feeds
            # `reason` to the model with nothing to discard — the intended halt.
            emit({
                "decision": "block",
                "reason": halt_instruction,
                "systemMessage": halt_message,
            })

# Phase B — mid-execution wrap nudge: once per cycle, ask to wrap up + commit.
# Record HEAD so Phase C can detect that a wrap commit later advanced it.
if size is not None and size >= NUDGE and not os.path.exists(nudged_path):
    # A null HEAD (no commits / git failed) records head: null, which Phase C's
    # `not nudge_head` guard treats as "no wrap detectable" -> Phase C stays off
    # this cycle. Acceptable: we never falsely fire the /compact prompt.
    touch(nudged_path, {"head": git("rev-parse", "HEAD")})
    kb = size // 1000
    emit({
        "systemMessage":
            "context-flow: ~%dk tokens in context — wrap up at the next stopping "
            "point and commit." % kb,
        "hookSpecificOutput": {
            "hookEventName": event,
            "additionalContext":
                "Context over budget (~%dk tokens). Stop at the next natural "
                "breaking point: finish and COMMIT the current sub-task, and "
                "don't start new work. Once it is committed and reviewed I'll "
                "prompt the user to run /compact and you'll continue from "
                "there — do not start new work before then." % kb,
        },
    })

sys.exit(0)
PY
