#!/usr/bin/env bash
#
# Tests for scripts/watchdog.sh — the orchestrate context gate.
#
# Black-box: we drive a synthetic transcript JSONL + hook payload, run the actual
# hook, and assert on the JSON it prints. The watchdog reads context occupancy
# from the LAST assistant transcript entry's input-side usage.
#
# Covers:
#   * Orchestrate gate — /orchestrate at >= 60k context -> advisory /clear hint
#     (no block, prompt survives); /orchestrate under threshold -> silent;
#     non-orchestrate at >= 60k -> silent; arguments still match; a different
#     command (/orchestrated-thing) does not; threshold is env-overridable.
#   * No periodic wrap/handoff nudge — a large context on its own is ALWAYS
#     silent, on every event. (The old 250k nudge was removed: it interrupted
#     long autonomous runs, and /orchestrate now runs its loop on the main
#     thread where a mid-run "wrap up and /handoff" is actively harmful.)
#   * Peer rotation nudge — the ONE exception to that silence, and it is scoped:
#     only a session whose own name is a `manager`/`doer` row in this project's
#     roster.json, only past THAT row's rotate_at. The orchestrator row, a worker
#     row, a name absent from the roster, and an unnamed interactive session are
#     all silent (docs/swarm-design.md § Rotation).
#   * Only UserPromptSubmit is handled — PostToolUse and Stop are silent.
#   * Fail-open: a missing transcript stays silent.
#
# Run: bash plugins/context/tests/test_watchdog.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHDOG="$PLUGIN_ROOT/scripts/watchdog.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Isolate state files ($TMPDIR is honored by python's tempfile) and HOME from any
# real sessions on this machine.
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
GLOBAL_HOME="$WORK/home"
mkdir -p "$GLOBAL_HOME/.claude/handoffs"

PROJECT_DIR="$WORK/proj"
mkdir -p "$PROJECT_DIR"

# A SECOND project, this one a swarm: the peer branch is roster-gated, so every test
# above keeps its silence by virtue of $PROJECT_DIR having no roster at all.
SWARM_DIR="$WORK/swarm-proj"
mkdir -p "$SWARM_DIR/.claude/swarm"

# The watchdog asks infra "what is my name?" through the stable link, and infra asks
# the `claude` CLI. Both are real here: the REAL session-status.sh at the REAL address
# ($HOME/.claude/kit/infra), over a stub `claude agents --json` fixture.
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
mkdir -p "$GLOBAL_HOME/.claude/kit"
ln -s "$REPO_ROOT/plugins/infra" "$GLOBAL_HOME/.claude/kit/infra"

BIN="$WORK/bin"
mkdir -p "$BIN"
PATH="$BIN:$PATH"
export PATH
cat >"$BIN/claude" <<STUB
#!/usr/bin/env bash
[ "\$1" = agents ] && exec cat "$WORK/agents.json"
exit 0
STUB
chmod +x "$BIN/claude"

# agents <name> — the session list `--self` resolves against. An empty name is how an
# ordinary interactive session looks: it is in no agent list under any name.
agents() {
    if [ -z "$1" ]; then
        printf '[]\n' >"$WORK/agents.json"
    else
        printf '[{"sessionId":"sid-peer","name":"%s","cwd":"%s","kind":"background","state":"busy"}]\n' \
            "$1" "$SWARM_DIR" >"$WORK/agents.json"
    fi
}

# roster <json> — this project's roster.json.
roster() { printf '%s\n' "$1" >"$SWARM_DIR/.claude/swarm/roster.json"; }

# run_peer <transcript> — the hook, run as a session named by the last `agents` call,
# inside the swarm project.
run_peer() {
    printf '{"hook_event_name":"UserPromptSubmit","session_id":"sid-peer","transcript_path":"%s","prompt":"carry on"}' "$1" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$SWARM_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
            CLAUDE_CODE_SESSION_ID=sid-peer bash "$WATCHDOG"
}

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_empty() { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected silence, got: $2)"; fi; }

# make_transcript <file> <total>  — a transcript whose LAST assistant entry sums
# to <total> input-side tokens (an earlier, smaller entry proves we take the last).
make_transcript() {
    python3 - "$1" "$2" <<'PY'
import sys, json
path, total = sys.argv[1], int(sys.argv[2])
rows = [
    {"type": "user", "message": {"role": "user", "content": "hi"}},
    {"type": "assistant", "message": {"role": "assistant", "usage": {
        "input_tokens": 3, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 1}}},
    {"type": "assistant", "message": {"role": "assistant", "usage": {
        "input_tokens": total, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 5}}},
]
with open(path, "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
}

# run_watchdog <event> <sid> <transcript> [<prompt>] [<tool_name>] — hook stdout.
run_watchdog() {
    local event="$1" sid="$2" tr="$3" prompt="${4:-}" tool="${5:-}"
    printf '{"hook_event_name":"%s","session_id":"%s","transcript_path":"%s","stop_hook_active":false,"prompt":"%s","tool_name":"%s"}' \
        "$event" "$sid" "$tr" "$prompt" "$tool" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
            bash "$WATCHDOG"
}

# ---------------------------------------------------------------------------
echo "test: no wrap/handoff nudge — a huge context alone is silent on every event"
make_transcript "$WORK/huge.jsonl" 900000
out=$(run_watchdog UserPromptSubmit sid-huge "$WORK/huge.jsonl")
assert_empty "900k with no /orchestrate prompt: silent" "$out"
assert_not_contains "never mentions /handoff" "$out" "/handoff"
out=$(run_watchdog PostToolUse sid-huge2 "$WORK/huge.jsonl")
assert_empty "PostToolUse at 900k: silent" "$out"
out=$(run_watchdog Stop sid-huge3 "$WORK/huge.jsonl")
assert_empty "Stop at 900k: silent" "$out"

# ---------------------------------------------------------------------------
echo "test: the gate never fires outside UserPromptSubmit"
make_transcript "$WORK/ptu.jsonl" 70000
out=$(run_watchdog PostToolUse sid-ptu "$WORK/ptu.jsonl" "/orchestrate")
assert_empty "PostToolUse with an /orchestrate prompt: silent" "$out"

# ---------------------------------------------------------------------------
echo "test: orchestrate gate — /orchestrate at >= 60k emits an advisory hint (no block)"
make_transcript "$WORK/orch-over.jsonl" 70000
out=$(run_watchdog UserPromptSubmit sid-orch-over "$WORK/orch-over.jsonl" "/orchestrate")
assert_not_contains "does NOT block (prompt survives)" "$out" '"decision": "block"'
assert_contains "injects the advisory as additionalContext" "$out" '"hookEventName": "UserPromptSubmit"'
assert_contains "tells user to run /clear" "$out" '/clear'
assert_contains "tells user to then /orchestrate" "$out" '/orchestrate'
assert_contains "shows a user-facing systemMessage" "$out" "workflow:"

# ---------------------------------------------------------------------------
echo "test: orchestrate gate — /orchestrate under 60k stays silent"
make_transcript "$WORK/orch-under.jsonl" 1000
out=$(run_watchdog UserPromptSubmit sid-orch-under "$WORK/orch-under.jsonl" "/orchestrate")
assert_empty "/orchestrate under threshold: silent" "$out"

# ---------------------------------------------------------------------------
echo "test: orchestrate gate — non-orchestrate prompt at >= 60k stays silent"
make_transcript "$WORK/orch-other.jsonl" 70000
out=$(run_watchdog UserPromptSubmit sid-orch-other "$WORK/orch-other.jsonl" "run the loop")
assert_empty "non-/orchestrate prompt at >= 60k: silent" "$out"
out=$(run_watchdog UserPromptSubmit sid-orch-other2 "$WORK/orch-other.jsonl" "please orchestrate")
assert_empty "natural-language orchestrate phrasing: silent" "$out"

# ---------------------------------------------------------------------------
echo "test: orchestrate gate — /orchestrate with arguments at >= 60k emits advisory"
make_transcript "$WORK/orch-args.jsonl" 70000
out=$(run_watchdog UserPromptSubmit sid-orch-args1 "$WORK/orch-args.jsonl" "/orchestrate 3")
assert_not_contains "/orchestrate 3: no block" "$out" '"decision": "block"'
assert_contains "/orchestrate 3: advisory hint" "$out" "workflow:"
assert_contains "/orchestrate 3: tells user /clear" "$out" '/clear'
out=$(run_watchdog UserPromptSubmit sid-orch-args2 "$WORK/orch-args.jsonl" "/orchestrate --max 2")
assert_not_contains "/orchestrate --max 2: no block" "$out" '"decision": "block"'
assert_contains "/orchestrate --max 2: advisory hint" "$out" "workflow:"
out=$(run_watchdog UserPromptSubmit sid-orch-args3 "$WORK/orch-args.jsonl" "/orchestrate 3 --max 2")
assert_not_contains "/orchestrate 3 --max 2: no block" "$out" '"decision": "block"'
assert_contains "/orchestrate 3 --max 2: advisory hint" "$out" "workflow:"

# ---------------------------------------------------------------------------
echo "test: orchestrate gate — /orchestrate with arguments under 60k stays silent"
make_transcript "$WORK/orch-args-under.jsonl" 1000
out=$(run_watchdog UserPromptSubmit sid-orch-argsU1 "$WORK/orch-args-under.jsonl" "/orchestrate 3")
assert_empty "/orchestrate 3 under threshold: silent" "$out"
out=$(run_watchdog UserPromptSubmit sid-orch-argsU2 "$WORK/orch-args-under.jsonl" "/orchestrate --max 2")
assert_empty "/orchestrate --max 2 under threshold: silent" "$out"

# ---------------------------------------------------------------------------
echo "test: orchestrate gate — /orchestrated-thing (no trailing-space boundary) stays silent"
make_transcript "$WORK/orch-nosub.jsonl" 70000
out=$(run_watchdog UserPromptSubmit sid-orch-nosub "$WORK/orch-nosub.jsonl" "/orchestrated-thing")
assert_empty "/orchestrated-thing (different command): silent" "$out"

# ---------------------------------------------------------------------------
echo "test: orchestrate gate — threshold honors WORKFLOW_PLANGATE_TOKENS"
make_transcript "$WORK/orch-env.jsonl" 1000
out=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"sid-orch-env","transcript_path":"%s","stop_hook_active":false,"prompt":"/orchestrate"}' \
    "$WORK/orch-env.jsonl" \
    | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        WORKFLOW_PLANGATE_TOKENS=500 bash "$WATCHDOG")
assert_contains "a lowered plangate threshold trips on a small transcript" "$out" "workflow:"
assert_not_contains "still advisory (no block)" "$out" '"decision": "block"'

# ---------------------------------------------------------------------------
echo "test: a missing transcript path fails open (silent)"
out=$(run_watchdog UserPromptSubmit sid-notr "$WORK/nope.jsonl" "/orchestrate")
assert_empty "missing transcript: silent" "$out"

# ---------------------------------------------------------------------------
# THE CENTRAL MECHANISM. A peer measures its OWN occupancy — `claude agents --json`
# exposes no context size, so nothing else can — and past its roster row's rotate_at
# it asks for a rotation. It never rotates itself: it nudges, and the orchestrator
# runs `swarm.sh rotate` (docs/swarm-design.md § Rotation).
echo "test: a roster peer past its rotate_at is nudged to /handoff"
roster '{
  "orchestrator": {"kind":"orchestrator","backend":"claude","model":"opus","effort":"high"},
  "swe-manager":  {"kind":"manager","backend":"claude","model":"opus","effort":"high","rotate_at":50000}
}'
agents swe-manager
make_transcript "$WORK/peer-over.jsonl" 60000
out=$(run_peer "$WORK/peer-over.jsonl")
assert_contains "injects as additionalContext" "$out" '"hookEventName": "UserPromptSubmit"'
assert_not_contains "never blocks the prompt" "$out" '"decision": "block"'
assert_contains "names the command to run" "$out" "/handoff"
assert_contains "at the next natural stopping point, not now" "$out" "natural stopping point"
assert_contains "report back over SendMessage" "$out" "SendMessage"
assert_contains "to the roster's orchestrator, by name" "$out" "orchestrator"
assert_contains "and hand over the doc path" "$out" "path"
assert_contains "shows a user-facing systemMessage" "$out" "swarm:"

echo "test: the same peer under its rotate_at is silent"
make_transcript "$WORK/peer-under.jsonl" 40000
assert_empty "under rotate_at: silent" "$(run_peer "$WORK/peer-under.jsonl")"

# rotate_at is per-row, so a row that omits it must fall back to the documented 300k
# (docs/swarm-design.md § Rotation) — the same default roster.sh serves.
echo "test: a row with no rotate_at falls back to the documented 300k default"
roster '{
  "orchestrator": {"kind":"orchestrator","backend":"claude","model":"opus","effort":"high"},
  "swe-manager":  {"kind":"manager","backend":"claude","model":"opus","effort":"high"}
}'
make_transcript "$WORK/peer-290k.jsonl" 290000
assert_empty "290k with the default 300k: silent" "$(run_peer "$WORK/peer-290k.jsonl")"
make_transcript "$WORK/peer-310k.jsonl" 310000
assert_contains "310k with the default 300k: nudged" "$(run_peer "$WORK/peer-310k.jsonl")" "/handoff"

# The orchestrator is Will's own session. A "wrap up and /handoff" in the seat someone
# is sitting in is the interruption the old periodic nudge was deleted for.
echo "test: the orchestrator is never nudged, however full it is"
agents orchestrator
assert_empty "orchestrator at 310k: silent" "$(run_peer "$WORK/peer-310k.jsonl")"

echo "test: a worker row is not a peer and is never nudged"
roster '{
  "orchestrator": {"kind":"orchestrator","backend":"claude","model":"opus","effort":"high"},
  "swe-manager":  {"kind":"manager","backend":"claude","model":"opus","effort":"high"},
  "builder":      {"kind":"worker","backend":"claude","model":"opus","effort":"high","manager":"swe-manager"}
}'
agents builder
assert_empty "worker row at 310k: silent" "$(run_peer "$WORK/peer-310k.jsonl")"

# An interactive session carries no `-n` name, so it is in no agent list under one and
# `--self` cannot resolve it. That is what keeps the nudge out of a human's window.
echo "test: an unnamed interactive session is silent"
agents ""
assert_empty "no name to match a roster role: silent" "$(run_peer "$WORK/peer-310k.jsonl")"

echo "test: a name that is in no roster row is silent"
agents some-other-session
assert_empty "unknown name at 310k: silent" "$(run_peer "$WORK/peer-310k.jsonl")"

# Fail open, every way the swarm side can be absent or broken.
echo "test: the peer branch fails open"
agents swe-manager
rm -f "$SWARM_DIR/.claude/swarm/roster.json"
assert_empty "no roster.json: silent" "$(run_peer "$WORK/peer-310k.jsonl")"
roster 'not json at all'
assert_empty "unreadable roster: silent" "$(run_peer "$WORK/peer-310k.jsonl")"
roster '{
  "orchestrator": {"kind":"orchestrator","backend":"claude","model":"opus","effort":"high"},
  "swe-manager":  {"kind":"manager","backend":"claude","model":"opus","effort":"high"}
}'
assert_contains "sanity: the good roster still nudges" "$(run_peer "$WORK/peer-310k.jsonl")" "/handoff"
mv "$GLOBAL_HOME/.claude/kit/infra" "$GLOBAL_HOME/.claude/kit/infra.off"
assert_empty "no infra link — cannot know its own name: silent" "$(run_peer "$WORK/peer-310k.jsonl")"
mv "$GLOBAL_HOME/.claude/kit/infra.off" "$GLOBAL_HOME/.claude/kit/infra"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
