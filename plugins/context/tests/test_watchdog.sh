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
#     only a session whose transcript names it (`{"type":"agent-name"}`, which is
#     what `claude -n` writes) as a `manager`/`doer` row in this project's
#     roster.json, only past THAT row's rotate_at, and only past its first turn (a
#     freshly-rotated peer's transcript starts brand new, so turn 1 can already be
#     past rotate_at from resume overhead alone — #102). The orchestrator row, a
#     worker row, a name absent from the roster, and an unnamed session are all
#     silent (docs/swarm-design.md § Rotation).
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

# roster <json> — this project's roster.json.
roster() { printf '%s\n' "$1" >"$SWARM_DIR/.claude/swarm/roster.json"; }

# run_peer <transcript> [prompt] — the hook, inside the swarm project. The session's
# NAME is not passed in: it comes out of the transcript, exactly as it does live.
run_peer() {
    printf '{"hook_event_name":"UserPromptSubmit","session_id":"sid-peer","transcript_path":"%s","prompt":"%s"}' \
        "$1" "${2:-carry on}" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$SWARM_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
            bash "$WATCHDOG"
}

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_empty() { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected silence, got: $2)"; fi; }

# make_transcript <file> <total> [name] [lead] — a transcript whose LAST assistant
# entry sums to <total> input-side tokens. [lead] (default 1) is the number of
# earlier, smaller dummy assistant entries before it — 1 proves we take the LAST
# entry, not the first; 0 makes the total entry the transcript's ONLY turn, which is
# what a just-rotated peer's brand-new transcript looks like (see the rotate_at
# grace-turn tests below).
#
# [name] adds the `agent-name` rows `claude -n` writes. A session RENAMED mid-run has
# two of them (seen live: a peer renamed from performance-engineer-cogito), so a stale
# first row is included to pin that the LAST one wins. No [name] is an ordinary session
# started without -n: no such row at all.
make_transcript() {
    python3 - "$1" "$2" "${3:-}" "${4:-1}" <<'PY'
import sys, json
path, total, name, lead = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
rows = [{"type": "user", "message": {"role": "user", "content": "hi"}}]
for _ in range(lead):
    rows.append({"type": "assistant", "message": {"role": "assistant", "usage": {
        "input_tokens": 3, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 1}}})
rows.append({"type": "assistant", "message": {"role": "assistant", "usage": {
    "input_tokens": total, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 5}}})
if name:
    rows.insert(0, {"type": "agent-name", "agentName": "a-stale-former-name", "sessionId": "s"})
    rows.insert(2, {"type": "agent-name", "agentName": name, "sessionId": "s"})
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
ROSTER='{
  "orchestrator": {"kind":"orchestrator","backend":"claude","model":"opus","effort":"high"},
  "swe-manager":  {"kind":"manager","backend":"claude","model":"opus","effort":"high"},
  "perf-eng":     {"kind":"doer","backend":"claude","model":"opus","effort":"high","rotate_at":120000},
  "builder":      {"kind":"worker","backend":"claude","model":"opus","effort":"high","manager":"swe-manager"}
}'
roster "$ROSTER"

echo "test: a roster peer past its rotate_at is nudged to /handoff"
make_transcript "$WORK/mgr-over.jsonl" 310000 swe-manager
out=$(run_peer "$WORK/mgr-over.jsonl")
assert_contains "injects as additionalContext" "$out" '"hookEventName": "UserPromptSubmit"'
assert_not_contains "never blocks the prompt" "$out" '"decision": "block"'
assert_contains "names the command to run" "$out" "/handoff"
assert_contains "at the next natural stopping point, not now" "$out" "natural stopping point"
assert_contains "report back over SendMessage" "$out" "SendMessage"
assert_contains "to the roster's orchestrator, by name" "$out" "orchestrator"
assert_contains "and hand over the doc path" "$out" "path"
assert_contains "names the role whose row was read" "$out" "swe-manager"
assert_contains "shows a user-facing systemMessage" "$out" "swarm:"

# #102: `swarm.sh rotate` stops the old process and spawns a brand-new one onto the
# handoff doc, so the successor's transcript starts empty — turn 1 can already be past
# rotate_at from resume overhead alone (reading the handoff + the resume preamble),
# before any real work happens. The guard is one turn's grace.
echo "test: a freshly-resumed session past rotate_at on turn 1 alone is not nudged"
make_transcript "$WORK/resumed-t1.jsonl" 310000 swe-manager 0
assert_empty "past rotate_at on the very first turn: silent (resume overhead, not work)" \
    "$(run_peer "$WORK/resumed-t1.jsonl")"

echo "test: the same session nudges once it reaches a second turn"
assert_contains "past rotate_at on turn 2 (mgr-over.jsonl, 2 turns): nudged" \
    "$(run_peer "$WORK/mgr-over.jsonl")" "/handoff"

# A hook that prints two JSON objects prints invalid JSON, and the whole advisory is
# dropped — so this has to be exactly one document, never the gate's plus the nudge's.
echo "test: the hook prints exactly one JSON object"
printf '%s' "$out" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' \
    && ok "the nudge parses as one JSON document" || no "the nudge is not valid JSON"
over=$(run_peer "$WORK/mgr-over.jsonl" "/orchestrate")
printf '%s' "$over" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' \
    && ok "a peer past rotate_at typing /orchestrate still prints one document" \
    || no "gate and nudge were concatenated"
assert_contains "and it is the orchestrate gate that wins" "$over" "workflow:"
assert_not_contains "not both" "$over" "swarm:"

echo "test: the same peer under its rotate_at is silent"
make_transcript "$WORK/mgr-under.jsonl" 290000 swe-manager
assert_empty "290k against the default 300k: silent" "$(run_peer "$WORK/mgr-under.jsonl")"

# rotate_at is per-row. The manager row above omits it and falls back to the documented
# 300k (docs/swarm-design.md § Rotation, the same default roster.sh serves); this row
# sets its own, and 150k must trip it while it sits far under the default.
echo "test: a row's own rotate_at is what is read, not the default"
make_transcript "$WORK/doer.jsonl" 150000 perf-eng
assert_contains "150k against the row's 120k: nudged" "$(run_peer "$WORK/doer.jsonl")" "/handoff"
make_transcript "$WORK/doer-under.jsonl" 110000 perf-eng
assert_empty "110k against the row's 120k: silent" "$(run_peer "$WORK/doer-under.jsonl")"
make_transcript "$WORK/mgr-150.jsonl" 150000 swe-manager
assert_empty "the same 150k on the default-300k row: silent" "$(run_peer "$WORK/mgr-150.jsonl")"

# The orchestrator is Will's own session. A "wrap up and /handoff" in the seat someone
# is sitting in is the interruption the old periodic nudge was deleted for.
echo "test: the orchestrator is never nudged, however full it is"
make_transcript "$WORK/orch.jsonl" 900000 orchestrator
assert_empty "orchestrator at 900k: silent" "$(run_peer "$WORK/orch.jsonl")"

echo "test: a worker row is not a session and is never nudged"
make_transcript "$WORK/worker.jsonl" 900000 builder
assert_empty "worker row at 900k: silent" "$(run_peer "$WORK/worker.jsonl")"

# A session started without -n writes no agent-name row, so it matches no roster role.
# That is what keeps the nudge out of an ordinary interactive window.
echo "test: a session with no name in its transcript is silent"
make_transcript "$WORK/unnamed.jsonl" 900000
assert_empty "no agent-name row at 900k: silent" "$(run_peer "$WORK/unnamed.jsonl")"
make_transcript "$WORK/stranger.jsonl" 900000 some-other-session
assert_empty "a name in no roster row at 900k: silent" "$(run_peer "$WORK/stranger.jsonl")"

# Fail open, every way the swarm side can be absent or broken: a hook that errors on a
# half-edited roster wedges the session it was meant to help.
echo "test: the peer branch fails open"
rm -f "$SWARM_DIR/.claude/swarm/roster.json"
assert_empty "no roster.json: silent" "$(run_peer "$WORK/mgr-over.jsonl")"
roster 'not json at all'
assert_empty "unreadable roster: silent" "$(run_peer "$WORK/mgr-over.jsonl")"
roster '{"swe-manager": "not an object"}'
assert_empty "a row that is not an object: silent" "$(run_peer "$WORK/mgr-over.jsonl")"
roster '{"swe-manager": {"kind":"manager","backend":"claude","model":"opus","effort":"high","rotate_at":"soon"}}'
assert_contains "a junk rotate_at falls back to the default" "$(run_peer "$WORK/mgr-over.jsonl")" "/handoff"
roster "$ROSTER"
assert_contains "sanity: the good roster still nudges" "$(run_peer "$WORK/mgr-over.jsonl")" "/handoff"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
