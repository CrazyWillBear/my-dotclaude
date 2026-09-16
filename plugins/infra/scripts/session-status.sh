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
#   bash session-status.sh --self                             # this session's own name
#   bash session-status.sh --peers <project-dir> <role> ...   # roster peers of one project
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
# `--peers` is the same question for a SWARM PEER. A peer is named by its role with no
# run prefix — the name is the stable address a rotation reuses (docs/swarm-design.md
# § Rotation) — so the run-prefix filter above cannot see one. It prints one line per
# role asked for, in that order, `gone` for a role with no session, and swarm.sh up /
# down / attach all read column 2 from it.
#
# It is scoped to one project's cwd, and that scope is load-bearing: role names are
# generic, so two projects each running a `swe-manager` share a name. Unscoped, a
# `swarm.sh down` in one project would stop the other project's peer. An entry with no
# cwd cannot be attributed to this project and so reads `gone` — the safe direction is
# a duplicate spawn, never someone else's session killed.
#
# Output: one line per session, `<name> <id> <kind> <state>`. THE ID IS THE SECOND
# COLUMN AND YOU NEED IT: `claude stop` and `claude attach` take an id, not a name
# (`Usage: claude stop <id>`), and reject a name outright.
#
# States:
#   busy     working
#   idle     waiting — for a background worker that is the DONE signal (it finished
#            its turn); pair it with the issue's comments to see what it did
#   blocked  a permission wedge — it is asking for something and nobody is there
#   done     the session reported itself finished/completed
#   stopped  killed by `claude stop` — the state a respawn waits for. NOT `gone`: the
#            session and its transcript still exist, and the worktree is untouched
#   failed   codex workers only: exited non-zero, or died without recording an exit code
#   gone     expected (a positional N) but not listed at all — it never came up
#
# A CODEX-backed worker is in no agent list — it is a process. It is read instead from
# `${CODEX_RUN_ROOT:-~/.claude/codex-runs}/<runid>/issue-<N>/`, where spawn.sh leaves a
# pid file and an exit file beside the event log, and it reports in the SAME vocabulary
# (live pid -> busy, exit 0 -> done, anything else -> failed) with the PID in column 2.
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

usage() {
    echo "error: usage: session-status.sh <runid> [issue numbers] | --self | --peers <project-dir> <role> ..." >&2
    exit 1
}

RUNID="${1:-}"
[ -n "$RUNID" ] || usage
shift

PROJECT_DIR=""; PEERS=""
if [ "$RUNID" = --peers ]; then
    # <project-dir> plus at least one role: a --peers with no roles would print
    # nothing and exit 0, which reads exactly like "no peers are up".
    [ $# -ge 2 ] || usage
    PROJECT_DIR="$1"; shift
    PEERS="$*"
    set --
fi

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 1; }
command -v claude  >/dev/null 2>&1 || { echo "error: claude CLI not found — cannot read session state" >&2; exit 1; }

EXPECT=""
for arg in "$@"; do
    n="${arg//[[:space:]]/}"; n="${n#\#}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    EXPECT="$EXPECT $n"
done

# Where spawn.sh leaves a codex worker's run dir. Same default on both sides, and both
# read the same override — if these two ever disagree, a live codex worker reports as
# nothing at all. test_session-status.sh pins the default against a real spawn.
export STATUS_RUNID="$RUNID" STATUS_EXPECT="$EXPECT" \
       STATUS_PROJECT_DIR="$PROJECT_DIR" STATUS_PEERS="$PEERS" \
       STATUS_CODEX_ROOT="${CODEX_RUN_ROOT:-$HOME/.claude/codex-runs}"

python3 <<"PY"
import json, os, subprocess, sys

runid  = os.environ["STATUS_RUNID"]
prefix = "orch-%s-" % runid
self_mode  = runid == "--self"
peers_mode = runid == "--peers"
expect = [int(t) for t in os.environ.get("STATUS_EXPECT", "").split()]
peers  = os.environ.get("STATUS_PEERS", "").split()
project_dir = os.path.realpath(os.environ.get("STATUS_PROJECT_DIR", "")) if peers_mode else ""

try:
    # --all is REQUIRED, not optional: without it the list holds only ACTIVE
    # sessions, so a worker that finished and exited is indistinguishable from one
    # that never spawned — both absent, both `gone`. The recovery rules key off
    # `gone`, so a completed worker would draw a respawn of work already done.
    result = subprocess.run(["claude", "agents", "--json", "--all"],
                            capture_output=True, text=True, timeout=60)
except Exception as exc:
    print("error: `claude agents --json --all` failed: %s" % exc, file=sys.stderr)
    sys.exit(1)
if result.returncode != 0:
    print("error: `claude agents --json --all` exited %d: %s"
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
# One vocabulary across both kinds. A background session reports `working` where an
# interactive one reports `busy`; leaving both spellings through would mean the
# documented states above are a lie for half the sessions, and a caller matching on
# `busy` would read a working session as something it has no rule for.
# The states that mean a session is still there to talk to. Everything else — stopped,
# done, gone, unknown — is a peer that has to be respawned, not one to stop or attach to.
LIVE = ("busy", "idle", "blocked")

def state_of(agent):
    raw = (agent.get("state") or agent.get("status") or "").lower()
    if raw in ("done", "completed", "finished", "exited"):
        return "done"
    if raw in ("working", "running", "busy"):
        return "busy"
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

if peers_mode:
    live = {}
    for agent in agents:
        if not isinstance(agent, dict):
            continue
        if agent.get("name") not in peers:
            continue
        # No cwd = not attributable to this project. Reads `gone`, which costs a
        # duplicate spawn at worst; the other direction stops a stranger's session.
        cwd = agent.get("cwd")
        if not cwd or os.path.realpath(cwd) != project_dir:
            continue
        # A rotation leaves the stopped predecessor in the list under the SAME name.
        # A running entry always wins it, so one line per role is the live one.
        name = agent["name"]
        if name in live and state_of(live[name]) in LIVE and state_of(agent) not in LIVE:
            continue
        live[name] = agent
    for role in peers:
        agent = live.get(role)
        if agent is None:
            print("%s - - gone" % role)
        else:
            print("%s %s %s %s" % (role, agent.get("id") or "-",
                                   agent.get("kind") or "-", state_of(agent)))
    sys.exit(0)

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

# A CODEX worker is a process, not a session: it is in no agent list at all. spawn.sh
# leaves <codex root>/<runid>/issue-<N>/ with a pid file and, when the run ends, an exit
# file beside the event log (docs/swarm-design.md § Codex backend) — that pair IS its
# state. This runs BEFORE the `gone` pass so a live codex worker is never reported gone.
#
# The words go through the same state_of() the agent list does, deliberately: working ->
# busy, completed -> done. /orchestrate's liveness loop waits on `$4 == "busy"`, so a
# private spelling here would read as finished the moment the worker started and the run
# would merge branches nothing had built yet. Column 2 is the PID — and it is the WRAPPER's,
# which leads its own process group, so a stop is `kill -- -<pid>`: a plain `kill` reaps the
# wrapper and orphans codex onto the worktree.
codex_root = os.path.join(os.environ.get("STATUS_CODEX_ROOT", ""), runid)
if not (self_mode or peers_mode) and os.path.isdir(codex_root):
    for entry in sorted(os.listdir(codex_root)):
        if not entry.startswith("issue-"):
            continue
        name = prefix + entry
        if name in seen:
            continue
        def read(fname):
            try:
                with open(os.path.join(codex_root, entry, fname)) as fh:
                    return fh.read().strip()
            except OSError:
                return None
        pid, code = read("pid"), read("exit")
        if code is not None:
            raw = "completed" if code == "0" else "failed"
        elif pid is None:
            # spawn.sh makes the run dir, backgrounds codex, THEN records $!. A poll
            # landing in that window sees no pid file. The two wrong answers are not
            # symmetrical: calling a live worker dead lets /orchestrate respawn it or
            # merge a branch it has not finished, while calling a dead one live only
            # stalls, visibly. So the launch window reports busy.
            raw = "working"
        else:
            # spawn.sh writes the exit file from the same subshell it records the pid
            # for, so that pid outlives codex itself. A dead pid with no exit file is
            # therefore a worker that was KILLED — `failed`, never a quiet `done`.
            alive = False
            try:
                os.kill(int(pid), 0)
                alive = True
            except PermissionError:      # someone else's process: it exists
                alive = True
            except (OSError, TypeError, ValueError):
                alive = False
            raw = "working" if alive else "failed"
        seen.add(name)
        lines.append("%s %s codex %s" % (name, pid or "-", state_of({"state": raw})))

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
