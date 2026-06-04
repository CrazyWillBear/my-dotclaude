#!/usr/bin/env bash
#
# Tests for scripts/watchdog.sh — the context watchdog hook.
#
# Black-box: we drive a real git repo + synthetic transcript JSONL + hook
# payload, run the actual hook, and assert on the JSON it prints, the per-session
# sentinels it writes, the handoff it saves, and its reuse of my-code-review's
# checkpoint.sh / review.sh (the deferral). The watchdog reads context occupancy
# from the LAST assistant transcript entry's input-side usage.
#
# Covers: under/over the nudge threshold, once-per-session dedup, the per-event
# hookEventName label, the plan-accept gate (over + under), env-overridable
# thresholds, the Stop handoff (armed vs not, baseline capture), the fail-open
# silent paths, and the review-deferral integration (arm -> review silent).
#
# Run: bash plugins/context-flow/tests/test_watchdog.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHDOG="$PLUGIN_ROOT/scripts/watchdog.sh"
MCR_ROOT="$(cd "$PLUGIN_ROOT/../my-code-review" && pwd)"
CKPT="$MCR_ROOT/scripts/checkpoint.sh"
REVIEW="$MCR_ROOT/scripts/review.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Isolate state files ($TMPDIR is honored by python's tempfile) and the handoff
# / plans dir (HOME) from any real sessions on this machine.
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
GLOBAL_HOME="$WORK/home"
mkdir -p "$GLOBAL_HOME/.claude/plans"
printf '# Plan\n1. one\n2. two\n' >"$GLOBAL_HOME/.claude/plans/active.md"
HANDOFF="$GLOBAL_HOME/.claude/.pending-handoff"

PROJECT_DIR="$WORK/proj"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_empty() { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected silence, got: $2)"; fi; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_file() { if [ -f "$2" ]; then ok "$1"; else no "$1 (missing file $2)"; fi; }
assert_nofile() { if [ -f "$2" ]; then no "$1 (unexpected file $2)"; else ok "$1"; fi; }

g() { git -C "$PROJECT_DIR" "$@"; }

# Fresh repo + clear the per-repo (toplevel-keyed) deferral state and any prior
# handoff, so tests that assert on those start clean. Per-session sentinels are
# keyed by session_id (unique per test) so they need no clearing here.
init_repo() {
    rm -rf "$PROJECT_DIR"
    rm -f "$TMPDIR"/my-code-review-plan-*.json "$HANDOFF"
    mkdir -p "$PROJECT_DIR/.claude"
    g init -q
    g config user.email t@t.com
    g config user.name t
    printf 'seed\n' >"$PROJECT_DIR/.gitkeep"
    g add -A
    g commit -q -m base
}

commit_file() {
    mkdir -p "$(dirname "$PROJECT_DIR/$1")"
    printf '%s\n' "$2" >"$PROJECT_DIR/$1"
    g add -A
    g commit -q -m "change $1"
}

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

# make_plan_transcript <file> <total>  — like make_transcript but with an
# ExitPlanMode tool_use early on, so plan_accepted() fires while the last entry
# still carries <total> tokens.
make_plan_transcript() {
    python3 - "$1" "$2" <<'PY'
import sys, json
path, total = sys.argv[1], int(sys.argv[2])
rows = [
    {"type": "assistant", "message": {"role": "assistant",
        "content": [{"type": "tool_use", "name": "ExitPlanMode", "input": {}}],
        "usage": {"input_tokens": 3, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}},
    {"type": "assistant", "message": {"role": "assistant", "usage": {
        "input_tokens": total, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 5}}},
]
with open(path, "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
}

# run_watchdog <event> <sid> <transcript> [stop_active] — print the hook's stdout.
run_watchdog() {
    local event="$1" sid="$2" tr="$3" active="${4:-false}"
    printf '{"hook_event_name":"%s","session_id":"%s","transcript_path":"%s","stop_hook_active":%s}' \
        "$event" "$sid" "$tr" "$active" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
            CONTEXT_FLOW_CHECKPOINT_SH="$CKPT" bash "$WATCHDOG"
}

# review.sh drivers (for the deferral-integration test).
run_review() {
    printf '{"session_id":"%s","stop_hook_active":false}' "$1" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$MCR_ROOT" \
            bash "$REVIEW"
}
run_review_ss() {
    printf '{"session_id":"%s","hook_event_name":"SessionStart"}' "$1" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$MCR_ROOT" \
            bash "$REVIEW"
}

# sentinel_path <prefix> <sid> — the per-session sentinel path the hook computes.
sentinel_path() {
    python3 - "$1" "$2" <<'PY'
import sys, hashlib, tempfile, os
prefix, sid = sys.argv[1], sys.argv[2]
key = hashlib.sha1(sid.encode()).hexdigest()[:16]
print(os.path.join(tempfile.gettempdir(), prefix + key + ".json"))
PY
}
nudged_path()   { sentinel_path "context-flow-nudged-"   "$1"; }
plangate_path() { sentinel_path "context-flow-plangate-" "$1"; }
head_state()    { sentinel_path "my-code-review-head-"   "$1"; }

# plan_state_file — the per-repo checkpoint deferral path (keyed sha1(toplevel)).
plan_state_file() {
    local root; root="$(g rev-parse --show-toplevel)"
    python3 - "$root" <<'PY'
import sys, hashlib, tempfile, os
key = hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16]
print(os.path.join(tempfile.gettempdir(), "my-code-review-plan-" + key + ".json"))
PY
}

# read_field <json-file> <field> — print one top-level field.
read_field() {
    python3 - "$1" "$2" <<'PY'
import sys, json
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
    print(v if v is not None else "")
except Exception:
    print("")
PY
}

# ---------------------------------------------------------------------------
echo "test: under the nudge threshold stays silent and arms nothing"
init_repo
make_transcript "$WORK/under.jsonl" 1000
out=$(run_watchdog UserPromptSubmit sid-under "$WORK/under.jsonl")
assert_empty "under threshold: silent" "$out"
assert_nofile "no nudge sentinel under threshold" "$(nudged_path sid-under)"
assert_nofile "no review deferral under threshold" "$(plan_state_file)"

# ---------------------------------------------------------------------------
echo "test: over the nudge threshold nudges, sets the sentinel, and arms review deferral"
init_repo
make_transcript "$WORK/over.jsonl" 200000
out=$(run_watchdog UserPromptSubmit sid-nudge "$WORK/over.jsonl")
assert_contains "emits the wrap-up nudge" "$out" "Context over budget"
assert_contains "labels the UserPromptSubmit event" "$out" '"hookEventName": "UserPromptSubmit"'
assert_contains "shows a user-facing systemMessage" "$out" "wrapping up"
assert_file "creates the nudge sentinel" "$(nudged_path sid-nudge)"
psf="$(plan_state_file)"
assert_file "arms the review deferral (checkpoint state)" "$psf"
assert_equals "deferral defer_review is true" "$(read_field "$psf" defer_review)" "True"

# ---------------------------------------------------------------------------
echo "test: the nudge fires at most once per session"
out=$(run_watchdog UserPromptSubmit sid-nudge "$WORK/over.jsonl")
assert_empty "second over-threshold call stays silent" "$out"

# ---------------------------------------------------------------------------
echo "test: the nudge labels the PostToolUse event when fired there"
init_repo
make_transcript "$WORK/ptu.jsonl" 200000
out=$(run_watchdog PostToolUse sid-ptu "$WORK/ptu.jsonl")
assert_contains "labels the PostToolUse event" "$out" '"hookEventName": "PostToolUse"'

# ---------------------------------------------------------------------------
echo "test: plan-accept gate over the gate threshold saves a handoff and asks to relaunch"
init_repo
make_plan_transcript "$WORK/gate.jsonl" 70000
out=$(run_watchdog UserPromptSubmit sid-gate "$WORK/gate.jsonl")
assert_contains "tells the user to relaunch" "$out" "Relaunch to execute"
assert_contains "tells the agent a plan was approved" "$out" "plan was just approved"
assert_file "writes the handoff" "$HANDOFF"
assert_file "sets the plan-gate sentinel" "$(plangate_path sid-gate)"
assert_nofile "plan-gate does NOT arm the review deferral" "$(plan_state_file)"

# ---------------------------------------------------------------------------
echo "test: plan-accept gate under the gate threshold is a silent one-shot"
init_repo
make_plan_transcript "$WORK/gate-under.jsonl" 1000
out=$(run_watchdog UserPromptSubmit sid-gate-under "$WORK/gate-under.jsonl")
assert_empty "under the gate threshold: silent" "$out"
assert_nofile "no handoff under the gate threshold" "$HANDOFF"
assert_file "still records the gate sentinel (one-shot)" "$(plangate_path sid-gate-under)"

# ---------------------------------------------------------------------------
echo "test: the nudge threshold is env-overridable"
init_repo
make_transcript "$WORK/envov.jsonl" 1000
out=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"sid-env","transcript_path":"%s","stop_hook_active":false}' "$WORK/envov.jsonl" \
    | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        CONTEXT_FLOW_CHECKPOINT_SH="$CKPT" CONTEXT_FLOW_NUDGE_TOKENS=500 bash "$WATCHDOG")
assert_contains "a lowered threshold trips on a small transcript" "$out" "Context over budget"

# ---------------------------------------------------------------------------
echo "test: Stop without an armed session stays silent and writes no handoff"
init_repo
make_transcript "$WORK/stop-noarm.jsonl" 200000
out=$(run_watchdog Stop sid-stop-noarm "$WORK/stop-noarm.jsonl")
assert_empty "Stop without arm: silent" "$out"
assert_nofile "no handoff without an armed session" "$HANDOFF"

# ---------------------------------------------------------------------------
echo "test: Stop after arming writes the handoff and captures the reviewed baseline"
init_repo
make_transcript "$WORK/stop.jsonl" 200000
run_watchdog UserPromptSubmit sid-stop "$WORK/stop.jsonl" >/dev/null    # arms this session
base="$(g rev-parse HEAD)"
printf '{"reviewed":"%s"}' "$base" >"$(head_state sid-stop)"           # plant the reviewed marker
commit_file src/app.py "print(1)"                                       # HEAD advances past it
out=$(run_watchdog Stop sid-stop "$WORK/stop.jsonl")
assert_contains "Stop announces the saved handoff" "$out" "handoff saved"
assert_file "Stop wrote the handoff" "$HANDOFF"
assert_equals "handoff baseline = the reviewed marker" "$(read_field "$HANDOFF" baseline_head)" "$base"
assert_equals "handoff records the repo toplevel" "$(read_field "$HANDOFF" git_toplevel)" "$(g rev-parse --show-toplevel)"
assert_equals "handoff records the plan path" "$(read_field "$HANDOFF" plan_path)" "$GLOBAL_HOME/.claude/plans/active.md"

# ---------------------------------------------------------------------------
echo "test: a missing transcript path fails open (silent)"
init_repo
out=$(run_watchdog UserPromptSubmit sid-notr "$WORK/nope.jsonl")
assert_empty "missing transcript: silent" "$out"

# ---------------------------------------------------------------------------
echo "test: arming the deferral makes review.sh stay silent on a fresh commit"
init_repo
make_transcript "$WORK/defer.jsonl" 200000
run_review_ss sid-defer >/dev/null                                      # seed review baseline at base
run_watchdog UserPromptSubmit sid-defer "$WORK/defer.jsonl" >/dev/null   # arm the deferral
commit_file src/x.py "print(1)"
rout=$(run_review sid-defer)
assert_empty "review is deferred while the watchdog has it armed" "$rout"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
