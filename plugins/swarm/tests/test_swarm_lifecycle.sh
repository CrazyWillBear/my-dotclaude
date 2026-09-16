#!/usr/bin/env bash
#
# Tests for scripts/swarm.sh up|down|attach — the swarm's process lifecycle.
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
cat >"$BIN/claude" <<STUB
#!/usr/bin/env bash
if [ "\$1" = agents ]; then cat "$WORK/agents.json"; exit 0; fi
mkdir -p "$CALLS"
n=\$(find "$CALLS" -type f | wc -l)
{ printf 'CWD=%s\n' "\$PWD"; printf '%s\n' "\$@"; } >"$CALLS/\$n"
STUB
chmod +x "$BIN/claude"

reset_calls() { rm -rf "$CALLS"; mkdir -p "$CALLS"; }
call() { cat "$CALLS/$1" 2>/dev/null; }
ncalls() { find "$CALLS" -type f 2>/dev/null | wc -l | tr -d ' '; }
# value_of <argv-text> <flag> — the argument that follows <flag>
value_of() { printf '%s\n' "$1" | grep -A1 -xF -- "$2" | tail -1; }

agents() { printf '%s\n' "$1" >"$WORK/agents.json"; }

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
assert_equals "its brief" "$(value_of "$spawn" --brief)" \
    "$PROJECT/.claude/swarm/inbox/performance-engineer/brief.md"
assert_equals "the shared charter" "$(value_of "$spawn" --append-system-prompt)" \
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
mv "$PROJECT/.claude/swarm/inbox/swe-manager/brief.md" "$PROJECT/.claude/swarm/inbox/swe-manager/brief.off"
run up "$PROJECT"
assert_equals "exits 1" "$RC" "1"
assert_contains "names the missing brief" "$ERR" "brief.md"
assert_contains "and says re-running is safe" "$ERR" "re-run"
assert_not_contains "the orchestrator is NOT handed a half-built swarm" \
    "$(cat "$CALLS"/* 2>/dev/null)" "--resume"
mv "$PROJECT/.claude/swarm/inbox/swe-manager/brief.off" "$PROJECT/.claude/swarm/inbox/swe-manager/brief.md"

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

echo "test: down on a swarm that is not up says so and exits 0"
reset_calls
agents '[]'
run down "$PROJECT"
assert_equals "exit 0" "$RC" "0"
assert_equals "stops nothing" "$(ncalls)" "0"
assert_contains "and says so" "$OUT" "not running"

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
assert_contains "usage lists attach" "$ERR" "attach"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
