#!/usr/bin/env bash
#
# Tests for scripts/swarm.sh up|down|rotate|attach — the swarm's process lifecycle.
#
# Black-box and driven for REAL: a real project dir with a real roster.json, charter
# and briefs, the REAL infra scripts reached through the REAL stable link
# (`$HOME/.claude/kit/infra`, docs/swarm-design.md § Plugin split), and a STUB `claude`
# on PATH that answers `agents --json` from a fixture and records every other
# invocation's argv, one argument per line, plus the cwd it was launched from.
#
# That stub is what makes the central mechanism assertable: `up` against a roster and
# an agent list must issue EXACTLY the spawns the difference between them implies —
# no more (a second copy of a live peer, racing it for the same inbox) and no fewer
# (a peer silently absent, with briefs piling up in an inbox nobody reads).
#
# Covers:
#   * up spawns only the peers that are not already live, and pins that spawn's argv
#   * up spawns peers FROM the project dir — session-status finds a peer by cwd, so a
#     peer born in the wrong cwd is invisible to every later down/attach
#   * up then execs the orchestrator: resume by the saved id, or fresh with its brief
#   * a peer that fails to spawn stops up before the orchestrator, loudly
#   * down stops each live peer BY ID and never by name; it never touches the orchestrator
#   * rotate waits for idle, RE-CHECKS idle, stops that id and respawns with --handoff;
#     it refuses a blocked peer, a non-peer row and a bad handoff path, and in every
#     refusal it stops nothing; a peer that is already dead is respawned on the handoff
#     rather than refused (docs/swarm-design.md § Rotation)
#   * attach resolves the role name to an id and execs `claude attach <id>`
#   * every failure path is loud: no roster, no orchestrator row, no infra link,
#     an unknown role, a role that is not running
#
# Run: bash plugins/swarm/tests/test_swarm_lifecycle.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/swarm.sh"
SHIPPED_ROSTER="$PLUGIN_ROOT/templates/roster.json"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A fake HOME carrying the REAL infra plugin at the REAL stable address. swarm reaches
# infra only through this link, so pointing it at the real scripts exercises the real
# session-status.sh and spawn.sh rather than a mock of either.
export HOME="$WORK/home"
mkdir -p "$HOME/.claude/kit"
ln -s "$REPO_ROOT/plugins/infra" "$HOME/.claude/kit/infra"

BIN="$WORK/bin"
mkdir -p "$BIN"
PATH="$BIN:$PATH"
export PATH

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

# A stub `claude`. `agents --json` answers from the fixture; anything else — a spawn's
# exec, `claude stop`, `claude attach`, the orchestrator resume — is recorded as one
# numbered file holding its cwd and then its argv, one argument per line.
CALLS="$WORK/calls"
# `agents --json` answers from agents.json, or — when a test scripted one with
# agents_seq — from the next file in the sequence, so a `rotate` poll loop can be
# walked through busy -> idle -> idle. Once the sequence runs out the final state
# sticks, so a loop that polls more times than the test scripted still sees it.
cat >"$BIN/claude" <<STUB
#!/usr/bin/env bash
if [ "\$1" = agents ]; then
    n=\$(cat "$WORK/agents.n" 2>/dev/null || echo 0)
    if [ -f "$WORK/agents.\$n.json" ]; then
        cat "$WORK/agents.\$n.json"; echo \$((n + 1)) >"$WORK/agents.n"
    else
        cat "$WORK/agents.json"
    fi
    exit 0
fi
mkdir -p "$CALLS"
n=\$(find "$CALLS" -type f | wc -l | tr -d ' ')
{ printf 'CWD=%s\n' "\$PWD"; printf '%s\n' "\$@"; } >"$CALLS/\$n"
# STUB_STOP_FAIL makes \`claude stop\` refuse the way the real one does on a bad id.
if [ "\$1" = stop ] && [ -n "\${STUB_STOP_FAIL:-}" ]; then
    echo "No job matching \$2" >&2
    exit 1
fi
STUB
chmod +x "$BIN/claude"

reset_calls() { rm -rf "$CALLS"; mkdir -p "$CALLS"; }
call() { cat "$CALLS/$1" 2>/dev/null; }
ncalls() { find "$CALLS" -type f 2>/dev/null | wc -l | tr -d ' '; }
# value_of <argv-text> <flag> — the argument that follows <flag>
value_of() { printf '%s\n' "$1" | grep -A1 -xF -- "$2" | tail -1; }

agents() { rm -f "$WORK"/agents.[0-9]*.json "$WORK/agents.n"; printf '%s\n' "$1" >"$WORK/agents.json"; }

# agents_seq <json>... — one answer per `claude agents --json` call, in order.
agents_seq() {
    agents "$*"                       # clears any previous sequence
    local i=0 j
    for j in "$@"; do printf '%s\n' "$j" >"$WORK/agents.$i.json"; i=$((i + 1)); done
    printf '%s\n' "${!#}" >"$WORK/agents.json"
}

# A rotate in a test must never actually sleep, and must be able to time out at once.
export SWARM_ROTATE_INTERVAL=0

run() {
    local errfile="$WORK/err"
    OUT="$(bash "$SCRIPT" "$@" 2>"$errfile")"
    RC=$?
    ERR="$(cat "$errfile")"
}

# setup_project <dir> — a real .claude/swarm tree: the shipped roster, a charter, and
# one brief per role, exactly as /init-swarm writes them.
setup_project() {
    local dir="$1"
    mkdir -p "$dir/.claude/swarm"
    cp "$SHIPPED_ROSTER" "$dir/.claude/swarm/roster.json"
    printf 'CHARTER: act within your role without sign-off.\n' >"$dir/.claude/swarm/charter.md"
    local role
    for role in orchestrator swe-manager performance-engineer; do
        mkdir -p "$dir/.claude/swarm/inbox/$role"
        printf 'You are the %s. Standing brief.\n' "$role" >"$dir/.claude/swarm/inbox/$role/brief.md"
    done
}

PROJECT="$WORK/project"
setup_project "$PROJECT"

# ---------------------------------------------------------------------------
# THE CENTRAL MECHANISM. One peer is already live; the other is not. `up` must issue
# exactly one spawn — for the missing one — and then hand the terminal to the
# orchestrator. A second copy of a live peer would race it for the same inbox.
echo "test: up spawns ONLY the roster peers that are not already live"
reset_calls
agents '[
  { "id": "p111", "cwd": "'"$PROJECT"'", "kind": "background", "name": "swe-manager", "state": "idle" },
  { "id": "w999", "cwd": "'"$PROJECT"'", "kind": "background", "name": "orch-r1-issue-3", "state": "busy" }
]'
printf 'sess-orch-42\n' >"$PROJECT/.claude/swarm/orchestrator.session"
run up "$PROJECT"

assert_equals "exit 0" "$RC" "0"
assert_equals "two calls: one spawn, one orchestrator resume" "$(ncalls)" "2"
assert_contains "says the live peer was left alone" "$OUT" "swe-manager already up"

spawn="$(call 0)"
assert_contains "the spawn is a background session" "$spawn" "--bg"
assert_equals "named for the MISSING peer, not the live one" "$(value_of "$spawn" -n)" "performance-engineer"
# spawn.sh reads the brief and the charter and passes their TEXT, so what reaches
# `claude` is the only proof the right two files were opened: this project's charter
# (not the plugin template) and THIS role's brief (not the other peer's).
assert_equals "the project's charter, appended to the system prompt" \
    "$(value_of "$spawn" --append-system-prompt)" \
    "CHARTER: act within your role without sign-off."
assert_equals "the roster row's model" "$(value_of "$spawn" --model)" "opus"
assert_equals "the roster row's effort" "$(value_of "$spawn" --effort)" "high"
assert_equals "the roster's autocompact backstop" "$(value_of "$spawn" --autocompact)" "400000"
assert_contains "the brief text is the prompt" "$spawn" "You are the performance-engineer"
assert_contains "and it reports to the orchestrator role" "$spawn" '"orchestrator"'
assert_not_contains "the live peer is NOT respawned" "$spawn" "swe-manager"
# A peer has no --add-dir, and session-status finds it again by cwd. Born anywhere
# else it is invisible to every later `down` and `attach`.
assert_contains "spawned FROM the project dir" "$spawn" "CWD=$PROJECT"

echo "test: up then execs the orchestrator, resumed by its saved id"
resume="$(call 1)"
assert_contains "resumes" "$resume" "--resume"
assert_equals "by the id the orchestrator saved" "$(value_of "$resume" --resume)" "sess-orch-42"
assert_not_contains "and does not start a second one in the background" "$resume" "--bg"
assert_contains "from the project dir" "$resume" "CWD=$PROJECT"

echo "test: with no saved id, up starts the orchestrator fresh from its brief"
reset_calls
rm -f "$PROJECT/.claude/swarm/orchestrator.session"
agents '[
  { "id": "p111", "cwd": "'"$PROJECT"'", "kind": "background", "name": "swe-manager", "state": "idle" },
  { "id": "p222", "cwd": "'"$PROJECT"'", "kind": "background", "name": "performance-engineer", "state": "busy" }
]'
run up "$PROJECT"
assert_equals "exit 0" "$RC" "0"
assert_equals "nothing to spawn — just the orchestrator" "$(ncalls)" "1"
fresh="$(call 0)"
assert_not_contains "not a resume" "$fresh" "--resume"
assert_equals "named for its role" "$(value_of "$fresh" -n)" "orchestrator"
assert_equals "the roster row's model" "$(value_of "$fresh" --model)" "opus"
assert_contains "its brief is the prompt" "$fresh" "You are the orchestrator"

echo "test: an empty session file is not an id"
reset_calls
: >"$PROJECT/.claude/swarm/orchestrator.session"
run up "$PROJECT"
assert_not_contains "falls back to a fresh start" "$(call 0)" "--resume"
rm -f "$PROJECT/.claude/swarm/orchestrator.session"

# A `stopped` session still holds its name and shows up in the agent list. Reading it
# as "already up" is how `swarm.sh down` followed by `swarm.sh up` brings nothing back.
echo "test: a stopped or finished peer is respawned, not counted as live"
for dead in stopped done gone; do
    reset_calls
    if [ "$dead" = gone ]; then
        agents '[]'
    else
        agents '[{ "id": "p111", "cwd": "'"$PROJECT"'", "kind": "background",
                   "name": "swe-manager", "state": "'"$dead"'" }]'
    fi
    run up "$PROJECT"
    names="$(cat "$CALLS"/* 2>/dev/null)"
    assert_contains "a $dead peer is respawned" "$names" "swe-manager"
done

echo "test: a peer that cannot spawn stops up before the orchestrator"
reset_calls
agents '[]'
printf 'sess-orch-42\n' >"$PROJECT/.claude/swarm/orchestrator.session"
mv "$PROJECT/.claude/swarm/inbox/swe-manager/brief.md" "$PROJECT/.claude/swarm/inbox/swe-manager/brief.off"
run up "$PROJECT"
assert_equals "exits 1" "$RC" "1"
assert_contains "names the missing brief" "$ERR" "brief.md"
assert_contains "names the role that did not start" "$ERR" "swe-manager"
assert_contains "and says re-running is safe" "$ERR" "re-run"
assert_equals "only the peer that COULD start did" "$(ncalls)" "1"
assert_not_contains "the orchestrator is NOT handed a half-built swarm" \
    "$(cat "$CALLS"/* 2>/dev/null)" "--resume"
mv "$PROJECT/.claude/swarm/inbox/swe-manager/brief.off" "$PROJECT/.claude/swarm/inbox/swe-manager/brief.md"
rm -f "$PROJECT/.claude/swarm/orchestrator.session"

# `up` cds into the project — to spawn, and again for the exec that replaces this
# process. A path still held relative at that point re-resolves against the new cwd
# and every brief, charter and roster read after it points at nothing.
echo "test: a relative project-dir works — it is made absolute before the first cd"
reset_calls
agents '[]'
( cd "$WORK" && bash "$SCRIPT" up project ) >"$WORK/out" 2>"$WORK/err"
RC=$?; OUT="$(cat "$WORK/out")"; ERR="$(cat "$WORK/err")"
assert_equals "exit 0" "$RC" "0"
assert_equals "both peers spawned, then the orchestrator" "$(ncalls)" "3"
calls_all="$(cat "$CALLS"/* 2>/dev/null)"
assert_contains "the briefs were found under the absolute dir" "$calls_all" "You are the orchestrator"
assert_contains "and the peers were spawned FROM it" "$calls_all" "CWD=$PROJECT"

echo "test: a project-dir that does not exist is a loud failure"
run up "$WORK/nope"
assert_equals "exits 1" "$RC" "1"
assert_contains "names the directory" "$ERR" "nope"

# ---------------------------------------------------------------------------
# `claude stop <name>` fails outright ("No job matching …"), so a down that reaches
# for the name silently stops nothing while reporting success.
echo "test: down stops every live peer BY ID, never by name"
reset_calls
agents '[
  { "id": "p111", "cwd": "'"$PROJECT"'", "kind": "background", "name": "swe-manager", "state": "idle" },
  { "id": "p222", "cwd": "'"$PROJECT"'", "kind": "background", "name": "performance-engineer", "state": "busy" },
  { "id": "o333", "cwd": "'"$PROJECT"'", "kind": "background", "name": "orchestrator", "state": "idle" },
  { "id": "x444", "cwd": "/somewhere/else", "kind": "background", "name": "swe-manager", "state": "idle" }
]'
run down "$PROJECT"
assert_equals "exit 0" "$RC" "0"
assert_equals "one stop per live peer" "$(ncalls)" "2"
stops="$(cat "$CALLS"/*)"
assert_contains "stops the manager by id" "$stops" "p111"
assert_contains "stops the doer by id" "$stops" "p222"
assert_not_contains "never by name" "$stops" "swe-manager"
assert_not_contains "never by name" "$stops" "performance-engineer"
assert_not_contains "and never the orchestrator — that is Will's session" "$stops" "o333"
assert_not_contains "nor another project's peer of the same name" "$stops" "x444"
assert_contains "reports what it stopped" "$OUT" "p111"

# `claude stop` on a session that is already stopped is noise at best; worse, it hides
# which peers this down actually ended.
echo "test: down leaves an already-stopped peer alone"
reset_calls
agents '[
  { "id": "p111", "cwd": "'"$PROJECT"'", "kind": "background", "name": "swe-manager", "state": "stopped" },
  { "id": "p222", "cwd": "'"$PROJECT"'", "kind": "background", "name": "performance-engineer", "state": "idle" }
]'
run down "$PROJECT"
assert_equals "only the live one is stopped" "$(ncalls)" "1"
assert_contains "by its id" "$(call 0)" "p222"
assert_contains "and the stopped one is reported, not re-stopped" "$OUT" "swe-manager not running"

echo "test: down on a swarm that is not up says so and exits 0"
reset_calls
agents '[]'
run down "$PROJECT"
assert_equals "exit 0" "$RC" "0"
assert_equals "stops nothing" "$(ncalls)" "0"
assert_contains "and says so" "$OUT" "not running"

# A down that reports success while a peer keeps running is the worst outcome here:
# the next `up` skips it as already live and the stale peer owns the inbox forever.
echo "test: a stop that fails exits non-zero and surfaces claude's own reason"
reset_calls
agents '[
  { "id": "p111", "cwd": "'"$PROJECT"'", "kind": "background", "name": "swe-manager", "state": "idle" },
  { "id": "p222", "cwd": "'"$PROJECT"'", "kind": "background", "name": "performance-engineer", "state": "busy" }
]'
export STUB_STOP_FAIL=1
run down "$PROJECT"
unset STUB_STOP_FAIL
assert_equals "exits 1" "$RC" "1"
assert_contains "names the peer" "$ERR" "swe-manager"
assert_contains "and its id" "$ERR" "p111"
assert_contains "quoting what claude said" "$ERR" "No job matching"
assert_equals "every peer was still tried, not just the first" "$(ncalls)" "2"
assert_contains "and says the peers are still up" "$ERR" "still running"

# ---------------------------------------------------------------------------
# ROTATE'S CENTRAL MECHANISM. The peer is busy, then goes idle; rotate must wait it
# out, re-check idle, stop THAT id, and respawn under the SAME name with the handoff
# prepended. The name is the address every other session sends to, so the one thing
# rotate may never do is leave it unclaimed (docs/swarm-design.md § Rotation).
echo "test: rotate waits for idle, stops by id, and respawns with the handoff"
reset_calls
HANDOFF="$WORK/handoff.md"
printf 'In flight: issue 41 awaiting review.\n' >"$HANDOFF"
LIVE='{ "id": "p111", "cwd": "'"$PROJECT"'", "kind": "background", "name": "swe-manager", "state": "%s" },
      { "id": "o333", "cwd": "'"$PROJECT"'", "kind": "background", "name": "orchestrator", "state": "idle" },
      { "id": "x444", "cwd": "/somewhere/else", "kind": "background", "name": "swe-manager", "state": "idle" }'
busy="[$(printf "$LIVE" busy)]"
idle="[$(printf "$LIVE" idle)]"
agents_seq "$busy" "$idle" "$idle"
SWARM_ROTATE_TIMEOUT=60 run rotate swe-manager "$HANDOFF" "$PROJECT"

assert_equals "exit 0" "$RC" "0"
assert_equals "one stop, then one spawn" "$(ncalls)" "2"
stop="$(call 0)"
assert_contains "stops" "$stop" "stop"
assert_contains "the id it last saw idle" "$stop" "p111"
assert_not_contains "never by name — claude stop rejects one" "$stop" "swe-manager"
assert_not_contains "never the orchestrator" "$stop" "o333"
assert_not_contains "nor another project's peer of the same name" "$stop" "x444"

respawn="$(call 1)"
assert_contains "respawns in the background" "$respawn" "--bg"
assert_equals "under the SAME name — it is the address" "$(value_of "$respawn" -n)" "swe-manager"
assert_contains "with the handoff doc" "$respawn" "$HANDOFF"
assert_contains "told to read it FIRST, before its standing brief" "$respawn" "FIRST"
assert_contains "and the brief is still there" "$respawn" "You are the swe-manager"
assert_equals "the roster row's model" "$(value_of "$respawn" --model)" "opus"
assert_contains "spawned FROM the project dir" "$respawn" "CWD=$PROJECT"
assert_contains "reports what it did" "$OUT" "p111"
# Three polls: it waited out the busy read, then required idle TWICE.
assert_equals "idle was required twice, not once" "$(cat "$WORK/agents.n")" "3"

# Window 2 of § Rotation: a brief lands between the peer's "ready" reply and the stop.
# The re-check is the only thing that catches it; without it the peer is killed one
# message into a turn nobody will redo.
echo "test: a peer that goes busy again between the two idle reads is NOT stopped"
reset_calls
agents_seq "$idle" "$busy"
SWARM_ROTATE_TIMEOUT=0 run rotate swe-manager "$HANDOFF" "$PROJECT"
assert_equals "exits 1" "$RC" "1"
assert_equals "stops nothing" "$(ncalls)" "0"
assert_contains "says it never settled" "$ERR" "idle"

echo "test: rotate refuses a blocked peer and stops nothing"
reset_calls
agents "[$(printf "$LIVE" blocked)]"
SWARM_ROTATE_TIMEOUT=0 run rotate swe-manager "$HANDOFF" "$PROJECT"
assert_equals "exits 1" "$RC" "1"
assert_equals "stops nothing" "$(ncalls)" "0"
assert_contains "names the role" "$ERR" "swe-manager"
assert_contains "says it is blocked" "$ERR" "blocked"
assert_contains "and how to clear it" "$ERR" "attach"

echo "test: rotate times out on a peer that never goes idle, and stops nothing"
reset_calls
agents "[$(printf "$LIVE" busy)]"
SWARM_ROTATE_TIMEOUT=0 run rotate swe-manager "$HANDOFF" "$PROJECT"
assert_equals "exits 1" "$RC" "1"
assert_equals "stops nothing" "$(ncalls)" "0"
assert_contains "says it timed out" "$ERR" "did not go idle"

# A handoff path that turns out to be unusable must be found BEFORE the stop. Found
# after, the role is dead with no successor and the handoff is unreadable anyway.
echo "test: an unusable handoff path is refused before anything is stopped"
reset_calls
agents "[$(printf "$LIVE" idle)]"
SWARM_ROTATE_TIMEOUT=60 run rotate swe-manager "$WORK/vanished.md" "$PROJECT"
assert_equals "a missing handoff exits 1" "$RC" "1"
assert_contains "names the path" "$ERR" "vanished.md"
assert_equals "and the peer is left running" "$(ncalls)" "0"
: >"$WORK/empty.md"
run rotate swe-manager "$WORK/empty.md" "$PROJECT"
assert_equals "an empty handoff exits 1" "$RC" "1"
assert_equals "and stops nothing" "$(ncalls)" "0"

# `up` would bring a dead peer back from its brief alone, losing the predecessor's doc.
# The orchestrator asked for a rotation ONTO this handoff, so honour that.
echo "test: a peer that is already dead is respawned ON the handoff, not refused"
for dead in stopped done; do
    reset_calls
    agents "[$(printf "$LIVE" "$dead")]"
    run rotate swe-manager "$HANDOFF" "$PROJECT"
    assert_equals "$dead: exit 0" "$RC" "0"
    assert_equals "$dead: nothing stopped, just the respawn" "$(ncalls)" "1"
    assert_contains "$dead: and it carries the handoff" "$(call 0)" "$HANDOFF"
    assert_contains "$dead: says it was not running" "$OUT" "not running"
done
reset_calls
agents '[]'
run rotate swe-manager "$HANDOFF" "$PROJECT"
assert_equals "gone: exit 0" "$RC" "0"
assert_equals "gone: nothing stopped, just the respawn" "$(ncalls)" "1"
assert_contains "gone: and it carries the handoff" "$(call 0)" "$HANDOFF"

echo "test: rotate refuses any row that is not a peer"
reset_calls
agents "[$(printf "$LIVE" idle)]"
run rotate orchestrator "$HANDOFF" "$PROJECT"
assert_equals "the orchestrator is Will's session, not a peer — exits 1" "$RC" "1"
assert_contains "says so" "$ERR" "peer"
run rotate not-a-role "$HANDOFF" "$PROJECT"
assert_equals "a role absent from the roster exits 1" "$RC" "1"
assert_contains "names it" "$ERR" "not-a-role"
assert_equals "nothing was stopped in either case" "$(ncalls)" "0"

echo "test: rotate needs both a role and a handoff path"
run rotate swe-manager
assert_equals "no handoff path exits 1" "$RC" "1"
assert_contains "prints usage" "$ERR" "usage:"
run rotate
assert_equals "no role exits 1" "$RC" "1"
assert_contains "prints usage" "$ERR" "usage:"

# ---------------------------------------------------------------------------
echo "test: attach resolves the role NAME to an id and attaches to the id"
reset_calls
agents '[{ "id": "p222", "cwd": "'"$PROJECT"'", "kind": "background",
           "name": "performance-engineer", "state": "idle" }]'
run attach performance-engineer "$PROJECT"
assert_equals "exit 0" "$RC" "0"
att="$(call 0)"
assert_contains "attaches" "$att" "attach"
assert_contains "by id" "$att" "p222"
assert_not_contains "never by name — claude attach rejects one" "$att" "performance-engineer"

echo "test: attach fails loud rather than leaving you at a dead prompt"
reset_calls
agents '[]'
run attach performance-engineer "$PROJECT"
assert_equals "a role that is not running exits 1" "$RC" "1"
assert_contains "names the role" "$ERR" "performance-engineer"
assert_contains "and says how to start it" "$ERR" "up"
assert_equals "attaches to nothing" "$(ncalls)" "0"
run attach not-a-role "$PROJECT"
assert_equals "a role absent from the roster exits 1" "$RC" "1"
assert_contains "names it" "$ERR" "not-a-role"
run attach
assert_equals "attach with no role exits 1" "$RC" "1"
assert_contains "prints usage" "$ERR" "usage:"

# ---------------------------------------------------------------------------
echo "test: every setup failure is loud, never a half-started swarm"
agents '[]'
BARE="$WORK/bare"; mkdir -p "$BARE"
run up "$BARE"
assert_equals "no roster exits 1" "$RC" "1"
assert_contains "names the path" "$ERR" "roster.json"

NOORCH="$WORK/noorch"
setup_project "$NOORCH"
python3 - "$NOORCH/.claude/swarm/roster.json" <<'PY'
import json, sys
p = sys.argv[1]
r = json.load(open(p))
del r["orchestrator"]
json.dump(r, open(p, "w"))
PY
run up "$NOORCH"
assert_equals "a roster with no orchestrator row exits 1" "$RC" "1"
assert_contains "says why it matters" "$ERR" "orchestrator"

HOME_SAVED="$HOME"
export HOME="$WORK/nolink"; mkdir -p "$HOME"
run up "$PROJECT"
assert_equals "no infra link exits 1" "$RC" "1"
assert_contains "names the stable address" "$ERR" ".claude/kit/infra"
export HOME="$HOME_SAVED"

run bogus
assert_equals "an unknown verb exits 1" "$RC" "1"
assert_contains "prints usage" "$ERR" "usage:"
assert_contains "usage lists up" "$ERR" "up"
assert_contains "usage lists down" "$ERR" "down"
assert_contains "usage lists rotate" "$ERR" "rotate"
assert_contains "usage lists attach" "$ERR" "attach"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
