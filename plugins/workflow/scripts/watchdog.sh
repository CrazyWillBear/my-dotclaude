#!/usr/bin/env bash
#
# Context watchdog for the workflow plugin.
#
# Wired on UserPromptSubmit + PostToolUse (detect mid-work) and Stop (the wrap
# seam). It reads the LIVE context occupancy from the transcript and drives a
# deliberate, EARLY /clear or /handoff as the window fills — the user types the
# one command, the hook handles everything around it. (No hook or agent can run
# /clear, /handoff, or /compact itself; they are user-typed REPL input only.)
# Two phases:
#
#   * Phase B — mid-execution wrap nudge (active events, >= WORKFLOW_NUDGE_
#     TOKENS, default 100k): once per cycle, ask the agent to wrap it up soon at a
#     natural breaking point and commit. Records HEAD so Phase C can tell a wrap
#     landed. Does NOT touch code review — the project's own checks run on the
#     wrap commit.
#   * Phase C — post-wrap handoff prompt (Stop, the next clean stop after the
#     nudge once a wrap commit exists): one-shot per cycle. Save a handoff and
#     tell the user to run /handoff (once the work is committed), which captures a
#     rich handoff doc + resume pointer and walks them through /clear into fresh
#     context. resume.sh re-injects the plan and resets the Phase-B/C sentinels
#     after the /clear or /compact so a later climb can re-nudge in the same long
#     session.
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
project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")

tmp = tempfile.gettempdir()
skey = hashlib.sha1(session_id.encode()).hexdigest()[:16]
nudged_path    = os.path.join(tmp, "workflow-nudged-"    + skey + ".json")
compacted_path = os.path.join(tmp, "workflow-compacted-" + skey + ".json")


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
    sh = os.environ.get("WORKFLOW_SAVE_HANDOFF_SH")
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

# --- Phase C — Stop: prompt /handoff once the wrap-up commit has landed. -------
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
          "workflow: wrap-up committed. Once the work and any fixes are in, run "
          "`/handoff` — it saves a rich handoff doc + resume pointer and walks "
          "you through `/clear` into fresh context, where the plan auto-resumes."})

# --- Active events (UserPromptSubmit / PostToolUse). -------------------------
# Orchestrate gate (advisory): on UserPromptSubmit, when the /orchestrate slash
# command is typed (bare or with arguments like `3`, `--max 2`, `3 --max 2`) and
# context >= PLANGATE, inject an advisory hint to run /clear first so the loop
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

# Phase B — mid-execution wrap nudge: once per cycle, ask to wrap up + commit.
# Record HEAD so Phase C can detect that a wrap commit later advanced it.
if size is not None and size >= NUDGE and not os.path.exists(nudged_path):
    # A null HEAD (no commits / git failed) records head: null, which Phase C's
    # `not nudge_head` guard treats as "no wrap detectable" -> Phase C stays off
    # this cycle. Acceptable: we never falsely fire the /handoff prompt.
    touch(nudged_path, {"head": git("rev-parse", "HEAD")})
    kb = size // 1000
    emit({
        "systemMessage":
            "workflow: ~%dk tokens in context — wrap it up soon and commit." % kb,
        "hookSpecificOutput": {
            "hookEventName": event,
            "additionalContext":
                "Context over budget (~%dk tokens). Stop at the next natural "
                "breaking point: finish and COMMIT the current sub-task, and "
                "don't start new work. Once it is committed and reviewed I'll "
                "prompt the user to run /handoff and you'll continue in fresh "
                "context — do not start new work before then." % kb,
        },
    })

sys.exit(0)
PY
