#!/usr/bin/env bash
#
# Tests for scripts/resume.sh — the SessionStart auto-resume hook.
#
# Black-box: we plant a ~/.claude/.pending-handoff, run the actual hook in a real
# git repo, and assert on the resume instruction it injects, the review baseline
# it seeds, the deferral it clears, and the handoff it removes. The review
# continuity is the subtle part: resume OVERWRITES review.sh's per-session marker
# to the recorded baseline so the order of the two SessionStart hooks doesn't
# matter, and the resumed session reviews the whole baseline..HEAD range once.
#
# Covers: the happy-path round-trip; the wrong-repo no-op (handoff preserved);
# no-handoff silence; order-independent overwrite; checkpoint.sh-done clearing an
# armed deferral; the no-plan and summary message variants; and the end-to-end
# arm -> defer -> resume -> review-fires integration with review.sh.
#
# Run: bash plugins/context-flow/tests/test_resume.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESUME="$PLUGIN_ROOT/scripts/resume.sh"
MCR_ROOT="$(cd "$PLUGIN_ROOT/../my-code-review" && pwd)"
CKPT="$MCR_ROOT/scripts/checkpoint.sh"
REVIEW="$MCR_ROOT/scripts/review.sh"

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

commit_file() {
    mkdir -p "$(dirname "$PROJECT_DIR/$1")"
    printf '%s\n' "$2" >"$PROJECT_DIR/$1"
    g add -A
    g commit -q -m "change $1"
}

# make_handoff <toplevel> <baseline> <branch> <plan> [summary]
make_handoff() {
    python3 - "$HANDOFF" "$1" "$2" "$3" "$4" "${5:-}" <<'PY'
import sys, json
path, top, base, branch, plan, summary = sys.argv[1:7]
obj = {"plan_path": plan or None, "branch": branch, "git_toplevel": top,
       "baseline_head": base, "session_id": "old-sid", "context_tokens": 200000, "ts": 0}
if summary:
    obj["summary"] = summary
with open(path, "w") as fh:
    json.dump(obj, fh)
PY
}

run_resume() {
    printf '{"hook_event_name":"SessionStart","session_id":"%s"}' "$1" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
            CONTEXT_FLOW_CHECKPOINT_SH="$CKPT" bash "$RESUME"
}

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

sentinel_path() {
    python3 - "$1" "$2" <<'PY'
import sys, hashlib, tempfile, os
prefix, sid = sys.argv[1], sys.argv[2]
key = hashlib.sha1(sid.encode()).hexdigest()[:16]
print(os.path.join(tempfile.gettempdir(), prefix + key + ".json"))
PY
}
head_state() { sentinel_path "my-code-review-head-" "$1"; }

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
echo "test: resume in the handoff's repo injects the resume instruction and clears the handoff"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
make_handoff "$top" "$base" "feat/ctx" "$PLAN"
out=$(run_resume sid-r1)
assert_contains "emits a SessionStart additionalContext" "$out" '"hookEventName": "SessionStart"'
assert_contains "names the plan to resume" "$out" "active.md"
assert_contains "names the branch" "$out" "feat/ctx"
assert_equals "seeds the review marker to the baseline" "$(read_field "$(head_state sid-r1)" reviewed)" "$base"
assert_nofile "clears the handoff (resume once)" "$HANDOFF"

# ---------------------------------------------------------------------------
echo "test: a handoff from another repo is a no-op (preserved, silent)"
init_repo
base="$(g rev-parse HEAD)"
make_handoff "/some/other/repo" "$base" "main" ""
out=$(run_resume sid-r2)
assert_empty "wrong repo: silent" "$out"
assert_file "wrong repo: handoff preserved" "$HANDOFF"
assert_nofile "wrong repo: no review marker seeded" "$(head_state sid-r2)"

# ---------------------------------------------------------------------------
echo "test: no handoff present stays silent"
init_repo
out=$(run_resume sid-r3)
assert_empty "no handoff: silent" "$out"

# ---------------------------------------------------------------------------
echo "test: resume overwrites an already-seeded marker (order-independent vs review.sh)"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
commit_file src/a.py "a = 1"                                   # HEAD now != base
printf '{"reviewed":"%s"}' "$(g rev-parse HEAD)" >"$(head_state sid-r4)"  # as if review.sh seeded first
make_handoff "$top" "$base" "main" ""
run_resume sid-r4 >/dev/null
assert_equals "marker overwritten back to the baseline" "$(read_field "$(head_state sid-r4)" reviewed)" "$base"

# ---------------------------------------------------------------------------
echo "test: resume clears an armed review deferral (checkpoint done)"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
( cd "$PROJECT_DIR" && HOME="$GLOBAL_HOME" bash "$CKPT" arm >/dev/null )
assert_file "deferral armed before resume" "$(plan_state_file)"
make_handoff "$top" "$base" "main" ""
run_resume sid-r5 >/dev/null
assert_nofile "resume cleared the deferral" "$(plan_state_file)"

# ---------------------------------------------------------------------------
echo "test: a handoff without a plan path uses the no-plan phrasing"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
make_handoff "$top" "$base" "main" ""
out=$(run_resume sid-r6)
assert_contains "uses the no-plan resume phrasing" "$out" "continue the prior in-progress work"

# ---------------------------------------------------------------------------
echo "test: a manual handoff summary is surfaced to the resumed session"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
make_handoff "$top" "$base" "main" "$PLAN" "Finished step 1; next is step 2; mind the migration."
out=$(run_resume sid-r7)
assert_contains "surfaces the prose summary" "$out" "next is step 2"

# ---------------------------------------------------------------------------
echo "test: end-to-end — deferred wrap-up commit is reviewed once after resume"
init_repo
run_review_ss sid-rt >/dev/null                                # review baseline seeded at base
base="$(g rev-parse HEAD)"
( cd "$PROJECT_DIR" && HOME="$GLOBAL_HOME" bash "$CKPT" arm >/dev/null )   # defer during wrap-up
commit_file src/app.py "print(1)"                              # committed while deferred
assert_empty "review stays silent during the deferred wrap-up" "$(run_review sid-rt)"
top="$(g rev-parse --show-toplevel)"
make_handoff "$top" "$base" "main" ""                          # hand off at the pre-wrap baseline
run_resume sid-rt-new >/dev/null                               # resume under a fresh session id
rout=$(run_review sid-rt-new)
assert_contains "after resume, the wrap-up commit is reviewed" "$rout" "src/app.py"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
