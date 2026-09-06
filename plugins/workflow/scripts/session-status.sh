#!/usr/bin/env bash
#
# session-status.sh — the state of one run's `claude --bg` worker sessions.
#
# /orchestrate spawns one background session per issue, named `orch-<runid>-issue-<N>`.
# The run-prefix is not cosmetic: `claude agents --json` is GLOBAL, and concurrent
# orchestrator runs are the intended usage. Without the prefix filter one run can see,
# wake and stop another run's workers.
#
# Usage:
#   bash session-status.sh <runid> [N ...]
#   bash session-status.sh --self          # this session's own name
#
# `--self` matches $CLAUDE_CODE_SESSION_ID against the agent list and prints the
# session's display name. That name is the orchestrator's ADDRESS: a worker replies
# with SendMessage, which takes a name, and a worker that cannot address its
# orchestrator reports into the void (decision 9). spawn.sh resolves it this way.
#
#   N ...   issue numbers this run EXPECTS to be alive. Each one with no session is
#           reported `gone` — a spawn that never came up, or a session that exited,
#           must not read as "nothing to check".
#
# Output: one line per session, `<name> <id> <kind> <state>`:
#   busy     working
#   idle     waiting — for a background worker that is the DONE signal (it finished
#            its turn); pair it with the issue's comments to see what it did
#   blocked  a permission wedge — it is asking for something and nobody is there
#   done     the session reported itself finished/completed
#   gone     expected (a positional N) but not listed at all
#
# NEVER parse `claude logs`: it is a raw ANSI screen dump, cursor moves and spinner
# frames, not a transcript.
#
# Fails LOUD (exit 1, message on stderr) when `claude` is missing, times out, or
# returns something that is not a JSON array. Silence here would read as "every
# session finished" and the orchestrator would merge a run that never built anything.
# Zero matching sessions with nothing expected is a real state, so it exits 0 — but
# it still SAYS so on stderr.

set -uo pipefail

RUNID="${1:-}"
[ -n "$RUNID" ] || { echo "error: usage: session-status.sh <runid> [issue numbers] | --self" >&2; exit 1; }
shift

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 1; }
command -v claude  >/dev/null 2>&1 || { echo "error: claude CLI not found — cannot read session state" >&2; exit 1; }

EXPECT=""
for arg in "$@"; do
    n="${arg//[[:space:]]/}"; n="${n#\#}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    EXPECT="$EXPECT $n"
done

export STATUS_RUNID="$RUNID" STATUS_EXPECT="$EXPECT"

python3 <<"PY"
import json, os, subprocess, sys

runid  = os.environ["STATUS_RUNID"]
prefix = "orch-%s-" % runid
self_mode = runid == "--self"
expect = [int(t) for t in os.environ.get("STATUS_EXPECT", "").split()]

try:
    result = subprocess.run(["claude", "agents", "--json"],
                            capture_output=True, text=True, timeout=60)
except Exception as exc:
    print("error: `claude agents --json` failed: %s" % exc, file=sys.stderr)
    sys.exit(1)
if result.returncode != 0:
    print("error: `claude agents --json` exited %d: %s"
          % (result.returncode, (result.stderr or "").strip()[:200]), file=sys.stderr)
    sys.exit(1)
try:
    agents = json.loads(result.stdout)
except Exception:
    print("error: `claude agents --json` did not return JSON: %s"
          % result.stdout.strip()[:200], file=sys.stderr)
    sys.exit(1)
if not isinstance(agents, list):
    print("error: `claude agents --json` returned %s, expected a list" % type(agents).__name__,
          file=sys.stderr)
    sys.exit(1)

# Background entries carry `state` and no `pid`; interactive ones carry `status` and a
# `pid`. Read both — a run's workers are background, but a session someone attached to
# and restarted by hand must not vanish from the report.
def state_of(agent):
    raw = (agent.get("state") or agent.get("status") or "").lower()
    if raw in ("done", "completed", "finished", "exited"):
        return "done"
    return raw or "unknown"

if self_mode:
    me = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not me:
        print("error: CLAUDE_CODE_SESSION_ID is unset — cannot identify this session",
              file=sys.stderr)
        sys.exit(1)
    for agent in agents:
        if isinstance(agent, dict) and agent.get("sessionId") == me:
            name = agent.get("name") or ""
            if not name:
                break
            print(name)
            sys.exit(0)
    print("error: this session (%s) is not in `claude agents --json`, or has no name — "
          "pass the orchestrator name explicitly" % me[:8], file=sys.stderr)
    sys.exit(1)

seen = set()
lines = []
for agent in agents:
    if not isinstance(agent, dict):
        continue
    name = agent.get("name") or ""
    if not name.startswith(prefix):
        continue
    seen.add(name)
    lines.append("%s %s %s %s" % (name, agent.get("id") or "-",
                                  agent.get("kind") or "-", state_of(agent)))

for n in expect:
    name = "%sissue-%d" % (prefix, n)
    if name not in seen:
        lines.append("%s - - gone" % name)

lines.sort()
if lines:
    print("\n".join(lines))
else:
    print("no sessions matching %s* (none spawned yet, or all exited)" % prefix, file=sys.stderr)
sys.exit(0)
PY
