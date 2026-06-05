#!/usr/bin/env bash
#
# Tests for scripts/resume.sh — the SessionStart auto-resume hook.
#
# Black-box: we plant a ~/.claude/.pending-handoff, run the actual hook in a real
# git repo, and assert on the resume instruction it injects, the handoff it
# removes, and (on a /compact resume) the Phase-B/C sentinels it resets. The hook
# is source-aware: /clear -> "implement the plan" wording (fresh context),
# /compact -> "continue the plan" wording + sentinel reset (so a later climb can
# re-nudge), and any other source falls back to "continue".
#
# Covers: the clear/compact/startup wording variants; the wrong-repo no-op
# (handoff preserved); no-handoff silence; the no-plan variant; the
# /compact sentinel reset proven by a subsequent re-nudge; and that context-flow
# no longer touches my-code-review state (it neither seeds the review marker nor
# clears a deferral).
#
# Run: bash plugins/context-flow/tests/test_resume.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESUME="$PLUGIN_ROOT/scripts/resume.sh"
WATCHDOG="$PLUGIN_ROOT/scripts/watchdog.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
GLOBAL_HOME="$WORK/home"
mkdir -p "$GLOBAL_HOME/.claude/plans"
printf '# Plan\n1. one\n2. two\n' >"$GLOBAL_HOME/.claude/plans/active.md"
PLAN="$GLOBAL_HOME/.claude/plans/active.md"
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

# make_handoff <toplevel> <baseline> <branch> <plan>
make_handoff() {
    python3 - "$HANDOFF" "$1" "$2" "$3" "$4" <<'PY'
import sys, json
path, top, base, branch, plan = sys.argv[1:6]
obj = {"plan_path": plan or None, "branch": branch, "git_toplevel": top,
       "baseline_head": base, "session_id": "old-sid",
       "context_tokens": 200000, "ts": 0}
with open(path, "w") as fh:
    json.dump(obj, fh)
PY
}

# run_resume <source> <sid> — run the SessionStart hook with the given source.
run_resume() {
    printf '{"hook_event_name":"SessionStart","source":"%s","session_id":"%s"}' "$1" "$2" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
            bash "$RESUME"
}

# make_transcript <file> <total> — last assistant entry sums to <total> tokens.
make_transcript() {
    python3 - "$1" "$2" <<'PY'
import sys, json
path, total = sys.argv[1], int(sys.argv[2])
rows = [
    {"type": "assistant", "message": {"role": "assistant", "usage": {
        "input_tokens": total, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 5}}},
]
with open(path, "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
}

run_watchdog() {
    printf '{"hook_event_name":"%s","session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$1" "$2" "$3" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
            bash "$WATCHDOG"
}

sentinel_path() {
    python3 - "$1" "$2" <<'PY'
import sys, hashlib, tempfile, os
prefix, sid = sys.argv[1], sys.argv[2]
key = hashlib.sha1(sid.encode()).hexdigest()[:16]
print(os.path.join(tempfile.gettempdir(), prefix + key + ".json"))
PY
}
nudged_path()    { sentinel_path "context-flow-nudged-"    "$1"; }
compacted_path() { sentinel_path "context-flow-compacted-" "$1"; }
head_state()     { sentinel_path "my-code-review-head-"    "$1"; }

plan_state_file() {
    local root; root="$(g rev-parse --show-toplevel)"
    python3 - "$root" <<'PY'
import sys, hashlib, tempfile, os
key = hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16]
print(os.path.join(tempfile.gettempdir(), "my-code-review-plan-" + key + ".json"))
PY
}

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
echo "test: source=clear injects the 'implement' wording and clears the handoff"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
make_handoff "$top" "$base" "feat/ctx" "$PLAN"
out=$(run_resume clear sid-r1)
assert_contains "emits a SessionStart additionalContext" "$out" '"hookEventName": "SessionStart"'
assert_contains "uses the implement wording" "$out" "implement the plan"
assert_contains "names the plan to resume" "$out" "active.md"
assert_contains "names the branch" "$out" "feat/ctx"
assert_contains "tells the agent not to redo work" "$out" "do not redo"
assert_nofile "clears the handoff (resume once)" "$HANDOFF"
assert_nofile "does NOT seed a my-code-review marker" "$(head_state sid-r1)"

# ---------------------------------------------------------------------------
echo "test: source=compact injects the 'continue' wording and resets Phase-B/C sentinels"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
: >"$(nudged_path sid-r2)"            # pretend Phase B/C already fired this session
: >"$(compacted_path sid-r2)"
make_handoff "$top" "$base" "main" "$PLAN"
out=$(run_resume compact sid-r2)
assert_contains "uses the continue wording" "$out" "continue the plan"
assert_nofile "resets the nudge sentinel" "$(nudged_path sid-r2)"
assert_nofile "resets the compacted sentinel" "$(compacted_path sid-r2)"
assert_nofile "clears the handoff" "$HANDOFF"
# Proof the reset re-arms the cycle: a fresh >=120k transcript re-nudges.
make_transcript "$WORK/renudge.jsonl" 200000
rout=$(run_watchdog UserPromptSubmit sid-r2 "$WORK/renudge.jsonl")
assert_contains "a later climb re-nudges after the reset" "$rout" "Context over budget"

# ---------------------------------------------------------------------------
echo "test: source=clear also resets Phase-B/C sentinels (re-arms the wrap cycle)"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
: >"$(nudged_path sid-r2c)"            # pretend Phase B/C already fired this session
: >"$(compacted_path sid-r2c)"
make_handoff "$top" "$base" "main" "$PLAN"
out=$(run_resume clear sid-r2c)
assert_contains "uses the implement wording" "$out" "implement the plan"
assert_nofile "clear resets the nudge sentinel" "$(nudged_path sid-r2c)"
assert_nofile "clear resets the compacted sentinel" "$(compacted_path sid-r2c)"
assert_nofile "clears the handoff" "$HANDOFF"
# Proof the reset re-arms the cycle: a fresh >=120k transcript re-nudges.
make_transcript "$WORK/renudge-clear.jsonl" 130000
rout=$(run_watchdog UserPromptSubmit sid-r2c "$WORK/renudge-clear.jsonl")
assert_contains "a later climb re-nudges after the clear reset" "$rout" "Context over budget"

# ---------------------------------------------------------------------------
echo "test: an unknown source falls back to the 'continue' wording"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
make_handoff "$top" "$base" "main" "$PLAN"
out=$(run_resume startup sid-r3)
assert_contains "fallback uses the continue wording" "$out" "continue the plan"

# ---------------------------------------------------------------------------
echo "test: a handoff from another repo is a no-op (preserved, silent)"
init_repo
base="$(g rev-parse HEAD)"
make_handoff "/some/other/repo" "$base" "main" ""
out=$(run_resume clear sid-r4)
assert_empty "wrong repo: silent" "$out"
assert_file "wrong repo: handoff preserved" "$HANDOFF"

# ---------------------------------------------------------------------------
echo "test: no handoff present stays silent"
init_repo
out=$(run_resume clear sid-r5)
assert_empty "no handoff: silent" "$out"

# ---------------------------------------------------------------------------
echo "test: a handoff without a plan path uses the no-plan phrasing"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
make_handoff "$top" "$base" "main" ""
out=$(run_resume clear sid-r6)
assert_contains "uses the no-plan resume phrasing" "$out" "continue the prior in-progress work"

# ---------------------------------------------------------------------------
echo "test: resume does not touch a my-code-review deferral (decoupled)"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
printf '{"defer_review":true,"armed_at":0}' >"$(plan_state_file)"   # a live deferral
make_handoff "$top" "$base" "main" "$PLAN"
run_resume compact sid-r8 >/dev/null
assert_file "leaves the my-code-review deferral untouched" "$(plan_state_file)"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
