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
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
