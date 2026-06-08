#!/usr/bin/env bash
#
# Tests for scripts/watchdog.sh — the context watchdog hook.
#
# Black-box: we drive a real git repo + synthetic transcript JSONL + hook
# payload, run the actual hook, and assert on the JSON it prints, the per-session
# sentinels it writes, and the handoff it saves. The watchdog reads context
# occupancy from the LAST assistant transcript entry's input-side usage.
#
# Covers the phases and orchestrate gate:
#   * Orchestrate gate — /orchestrate at >= 60k context -> advisory /clear hint
#     (no block, prompt survives); /orchestrate under threshold -> silent;
#     non-orchestrate at >= 60k -> silent; threshold is env-overridable.
#   * Phase B — wrap nudge: >= nudge -> wrap-up nudge, once per cycle, per-event
#     label, env-overridable.
#   * Phase C — post-wrap handoff prompt (Stop): clean tree + wrap commit after
#     the nudge -> continue-handoff + /handoff instruction; dirty / no-wrap /
#     no-nudge -> silent; one-shot per cycle.
#   * Fail-open: a missing transcript stays silent.
#
# Run: bash plugins/workflow/tests/test_watchdog.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHDOG="$PLUGIN_ROOT/scripts/watchdog.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Isolate state files ($TMPDIR is honored by python's tempfile) and the handoff
# / plans dir (HOME) from any real sessions on this machine.
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
GLOBAL_HOME="$WORK/home"
mkdir -p "$GLOBAL_HOME/.claude/handoffs"
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

# Fresh repo + clear any prior handoff so tests that assert on it start clean.
# Per-session sentinels are keyed by session_id (unique per test) so they need
# no clearing here.
init_repo() {
    rm -rf "$PROJECT_DIR"
    rm -f "$HANDOFF"
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

# run_watchdog <event> <sid> <transcript> — print the hook's stdout.
run_watchdog() {
    local event="$1" sid="$2" tr="$3" prompt="${4:-}"
    printf '{"hook_event_name":"%s","session_id":"%s","transcript_path":"%s","stop_hook_active":false,"prompt":"%s"}' \
        "$event" "$sid" "$tr" "$prompt" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
            bash "$WATCHDOG"
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
nudged_path()    { sentinel_path "workflow-nudged-"    "$1"; }
compacted_path() { sentinel_path "workflow-compacted-" "$1"; }

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
echo "test: under the nudge threshold stays silent and writes no state"
init_repo
make_transcript "$WORK/under.jsonl" 1000
out=$(run_watchdog UserPromptSubmit sid-under "$WORK/under.jsonl")
assert_empty "under threshold: silent" "$out"
assert_nofile "no nudge sentinel under threshold" "$(nudged_path sid-under)"

# ---------------------------------------------------------------------------
echo "test: Phase B — over the nudge threshold nudges and sets the sentinel"
init_repo
make_transcript "$WORK/over.jsonl" 200000
out=$(run_watchdog UserPromptSubmit sid-nudge "$WORK/over.jsonl")
assert_contains "emits the wrap-up nudge" "$out" "Context over budget"
assert_contains "labels the UserPromptSubmit event" "$out" '"hookEventName": "UserPromptSubmit"'
assert_contains "shows a user-facing systemMessage" "$out" "wrap it up"
assert_file "creates the nudge sentinel" "$(nudged_path sid-nudge)"
assert_contains "records HEAD in the nudge sentinel" "$(read_field "$(nudged_path sid-nudge)" head)" "$(g rev-parse HEAD)"

# ---------------------------------------------------------------------------
echo "test: the nudge fires at most once per cycle"
out=$(run_watchdog UserPromptSubmit sid-nudge "$WORK/over.jsonl")
assert_empty "second over-threshold call stays silent" "$out"

# ---------------------------------------------------------------------------
echo "test: the nudge labels the PostToolUse event when fired there"
init_repo
make_transcript "$WORK/ptu.jsonl" 200000
out=$(run_watchdog PostToolUse sid-ptu "$WORK/ptu.jsonl")
assert_contains "labels the PostToolUse event" "$out" '"hookEventName": "PostToolUse"'

# ---------------------------------------------------------------------------
echo "test: the nudge threshold is env-overridable"
init_repo
make_transcript "$WORK/envov.jsonl" 1000
out=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"sid-env","transcript_path":"%s","stop_hook_active":false}' "$WORK/envov.jsonl" \
    | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        WORKFLOW_NUDGE_TOKENS=500 bash "$WATCHDOG")
assert_contains "a lowered threshold trips on a small transcript" "$out" "Context over budget"

# ---------------------------------------------------------------------------
echo "test: Phase B — the default nudge threshold is 100k (no env override)"
init_repo
make_transcript "$WORK/default100.jsonl" 110000
out=$(run_watchdog UserPromptSubmit sid-default100 "$WORK/default100.jsonl")
assert_contains "110k over the 100k default nudges" "$out" "Context over budget"

# ---------------------------------------------------------------------------
echo "test: orchestrate gate — /orchestrate at >= 60k emits an advisory hint (no block)"
init_repo
make_transcript "$WORK/orch-over.jsonl" 70000
out=$(run_watchdog UserPromptSubmit sid-orch-over "$WORK/orch-over.jsonl" "/orchestrate")
assert_not_contains "does NOT block (prompt survives)" "$out" '"decision": "block"'
assert_contains "injects the advisory as additionalContext" "$out" '"hookEventName": "UserPromptSubmit"'
assert_contains "tells user to run /clear" "$out" '/clear'
assert_contains "tells user to then /orchestrate" "$out" '/orchestrate'
assert_contains "shows a user-facing systemMessage" "$out" "workflow:"

# ---------------------------------------------------------------------------
echo "test: orchestrate gate — /orchestrate under 60k stays silent"
init_repo
make_transcript "$WORK/orch-under.jsonl" 1000
out=$(run_watchdog UserPromptSubmit sid-orch-under "$WORK/orch-under.jsonl" "/orchestrate")
assert_empty "/orchestrate under threshold: silent" "$out"

# ---------------------------------------------------------------------------
echo "test: orchestrate gate — non-orchestrate prompt at >= 60k stays silent"
init_repo
make_transcript "$WORK/orch-other.jsonl" 70000
out=$(run_watchdog UserPromptSubmit sid-orch-other "$WORK/orch-other.jsonl" "run the loop")
assert_empty "non-/orchestrate prompt at >= 60k: silent" "$out"
out=$(run_watchdog UserPromptSubmit sid-orch-other2 "$WORK/orch-other.jsonl" "please orchestrate")
assert_empty "natural-language orchestrate phrasing: silent" "$out"

# ---------------------------------------------------------------------------
echo "test: orchestrate gate — threshold honors WORKFLOW_PLANGATE_TOKENS"
init_repo
make_transcript "$WORK/orch-env.jsonl" 1000
out=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"sid-orch-env","transcript_path":"%s","stop_hook_active":false,"prompt":"/orchestrate"}' \
    "$WORK/orch-env.jsonl" \
    | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        WORKFLOW_PLANGATE_TOKENS=500 bash "$WATCHDOG")
assert_contains "a lowered plangate threshold trips on a small transcript" "$out" "workflow:"
assert_not_contains "still advisory (no block)" "$out" '"decision": "block"'

# ---------------------------------------------------------------------------
echo "test: Phase C — clean tree + wrap commit after the nudge prompts /handoff"
init_repo
make_transcript "$WORK/cycle.jsonl" 200000
run_watchdog UserPromptSubmit sid-c "$WORK/cycle.jsonl" >/dev/null   # nudge: records HEAD
commit_file src/app.py "print(1)"                                    # the wrap-up commit
out=$(run_watchdog Stop sid-c "$WORK/cycle.jsonl")
assert_contains "Phase C announces the wrap-up + /handoff" "$out" "wrap-up committed"
assert_contains "Phase C tells the user to run /handoff" "$out" '/handoff'
assert_contains "Phase C mentions clearing into fresh context" "$out" '/clear'
assert_file "Phase C wrote the continue-handoff" "$HANDOFF"
assert_equals "handoff records the repo toplevel" "$(read_field "$HANDOFF" git_toplevel)" "$(g rev-parse --show-toplevel)"
assert_equals "handoff baseline = current HEAD" "$(read_field "$HANDOFF" baseline_head)" "$(g rev-parse HEAD)"
assert_file "sets the compacted sentinel" "$(compacted_path sid-c)"

# ---------------------------------------------------------------------------
echo "test: Phase C is one-shot per cycle"
out=$(run_watchdog Stop sid-c "$WORK/cycle.jsonl")
assert_empty "second Stop in the same cycle stays silent" "$out"

# ---------------------------------------------------------------------------
echo "test: Phase C stays silent until a wrap commit lands (HEAD unmoved)"
init_repo
make_transcript "$WORK/nowrap.jsonl" 200000
run_watchdog UserPromptSubmit sid-nowrap "$WORK/nowrap.jsonl" >/dev/null   # nudge at HEAD
out=$(run_watchdog Stop sid-nowrap "$WORK/nowrap.jsonl")                   # no commit since
assert_empty "no wrap commit yet: silent" "$out"
assert_nofile "no handoff without a wrap commit" "$HANDOFF"

# ---------------------------------------------------------------------------
echo "test: Phase C stays silent on a dirty tree even after a wrap commit"
init_repo
make_transcript "$WORK/dirty.jsonl" 200000
run_watchdog UserPromptSubmit sid-dirty "$WORK/dirty.jsonl" >/dev/null
commit_file src/app.py "print(1)"                                # HEAD advances
printf 'uncommitted\n' >"$PROJECT_DIR/src/app.py"                 # ...but tree is now dirty
out=$(run_watchdog Stop sid-dirty "$WORK/dirty.jsonl")
assert_empty "dirty tree: silent" "$out"
assert_nofile "no handoff on a dirty tree" "$HANDOFF"

# ---------------------------------------------------------------------------
echo "test: Phase C without a prior nudge stays silent"
init_repo
make_transcript "$WORK/nonudge.jsonl" 200000
commit_file src/app.py "print(1)"
out=$(run_watchdog Stop sid-nonudge "$WORK/nonudge.jsonl")
assert_empty "Stop without a prior nudge: silent" "$out"
assert_nofile "no handoff without a prior nudge" "$HANDOFF"

# ---------------------------------------------------------------------------
echo "test: a missing transcript path fails open (silent)"
init_repo
out=$(run_watchdog UserPromptSubmit sid-notr "$WORK/nope.jsonl")
assert_empty "missing transcript: silent" "$out"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
