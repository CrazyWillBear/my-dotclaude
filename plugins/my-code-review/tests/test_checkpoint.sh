#!/usr/bin/env bash
#
# Tests for scripts/checkpoint.sh (the /checkpoint command helper) and its
# interaction with scripts/review.sh.
#
# Black-box: we drive a real git repo, run the actual scripts, and assert on the
# JSON / text they print plus the per-repo state file they share. checkpoint.sh
# arms a "defer_review" flag so review.sh stays silent AND freezes its
# reviewed-HEAD marker for the lifetime of a long plan, then reviews the whole
# baseline..HEAD range once after `done`. A forgotten `done` self-heals via TTL.
#
# Covers: arm writes {defer_review, armed_at}; step counting (ordered list,
# heading fallback, ceil halfway); newest-plan resolution; done deletes state;
# review.sh stays silent + does NOT advance its marker while armed; the full
# range is reviewed after done; a stale armed_at self-clears and reviews.
#
# Run: bash plugins/my-code-review/tests/test_checkpoint.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CKPT="$PLUGIN_ROOT/scripts/checkpoint.sh"
HOOK="$PLUGIN_ROOT/scripts/review.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Isolate state files (python's tempfile honors $TMPDIR) from real sessions, and
# give a controlled HOME so the ~/.claude/plans lookup is deterministic.
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
GLOBAL_HOME="$WORK/home"
mkdir -p "$GLOBAL_HOME/.claude/plans"

PROJECT_DIR="$WORK/proj"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_empty() { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected silence, got: $2)"; fi; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }

g() { git -C "$PROJECT_DIR" "$@"; }

init_repo() {
    rm -rf "$PROJECT_DIR"
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

# arm <args...> / disarm  — run checkpoint.sh from inside the repo (it keys on
# `git rev-parse --show-toplevel`, computed from the cwd). TMPDIR is exported.
arm()    { ( cd "$PROJECT_DIR" && HOME="$GLOBAL_HOME" bash "$CKPT" arm "$@" ); }
disarm() { ( cd "$PROJECT_DIR" && HOME="$GLOBAL_HOME" bash "$CKPT" done    ); }

# run_hook <session_id>  — drive review.sh on a Stop event; print its stdout.
run_hook() {
    printf '{"session_id":"%s","stop_hook_active":false}' "$1" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
            bash "$HOOK"
}

# plan_state_file  — the per-repo state path both scripts compute (sha1 of the
# git toplevel, under python's tempfile dir).
plan_state_file() {
    local root; root="$(g rev-parse --show-toplevel)"
    python3 - "$root" <<'PY'
import sys, hashlib, tempfile, os
key = hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16]
print(os.path.join(tempfile.gettempdir(), "my-code-review-plan-" + key + ".json"))
PY
}

# head_state_file <sid> / read_reviewed <sid>  — inspect review.sh's per-session
# reviewed-HEAD marker, to prove the checkpoint freezes it.
head_state_file() {
    python3 - "$1" <<'PY'
import sys, hashlib, tempfile, os
key = hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16]
print(os.path.join(tempfile.gettempdir(), "my-code-review-head-" + key + ".json"))
PY
}
read_reviewed() {
    python3 - "$(head_state_file "$1")" <<'PY'
import sys, json
try:
    print(json.load(open(sys.argv[1])).get("reviewed", ""))
except Exception:
    print("")
PY
}

# read_state_field <path> <field>  — pull one field from the JSON state file.
read_state_field() {
    python3 - "$1" "$2" <<'PY'
import sys, json
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
    print(v if v is not None else "")
except Exception:
    print("")
PY
}

# Plan fixtures with known step counts.
mk_plan() { printf '%s' "$2" >"$1"; }
PLAN4="$WORK/plan4.md"; mk_plan "$PLAN4" $'# Plan\n1. one\n2. two\n3. three\n4. four\n'
PLAN5="$WORK/plan5.md"; mk_plan "$PLAN5" $'# Plan\n1. one\n2. two\n3. three\n4. four\n5. five\n'
PLAN_HEAD="$WORK/planh.md"; mk_plan "$PLAN_HEAD" $'# Title\n## One\nbody\n## Two\nbody\n## Three\nbody\n'

# ---------------------------------------------------------------------------
echo "test: arm writes defer_review + armed_at and reports the halfway step"
init_repo
out=$(arm "$PLAN4")
psf="$(plan_state_file)"
assert_equals "defer_review is true" "$(read_state_field "$psf" defer_review)" "True"
armed="$(read_state_field "$psf" armed_at)"
case "$armed" in ''|*[!0-9]*) no "armed_at is an epoch int (got '$armed')" ;; *) ok "armed_at is an epoch int" ;; esac
assert_contains "reports step count" "$out" "steps (heuristic): 4"
assert_contains "reports halfway step (ceil(4/2)=2)" "$out" "after step 2"
assert_contains "echoes the plan path" "$out" "$PLAN4"

# ---------------------------------------------------------------------------
echo "test: halfway is ceil(N/2) for an odd step count"
init_repo
out=$(arm "$PLAN5")
assert_contains "counts 5 steps" "$out" "steps (heuristic): 5"
assert_contains "halfway is ceil(5/2)=3" "$out" "after step 3"

# ---------------------------------------------------------------------------
echo "test: step counting falls back to ## / ### headings"
init_repo
out=$(arm "$PLAN_HEAD")
assert_contains "counts 3 headings when no ordered list" "$out" "steps (heuristic): 3"

# ---------------------------------------------------------------------------
echo "test: no-arg arm resolves the newest *.md in ~/.claude/plans"
init_repo
mk_plan "$GLOBAL_HOME/.claude/plans/old.md" $'1. a\n2. b\n'
mk_plan "$GLOBAL_HOME/.claude/plans/new.md" $'1. a\n2. b\n3. c\n4. d\n5. e\n6. f\n'
touch -d '2020-01-01 00:00:00' "$GLOBAL_HOME/.claude/plans/old.md"
touch -d '2020-06-01 00:00:00' "$GLOBAL_HOME/.claude/plans/new.md"
out=$(arm)
assert_contains "picks the newest plan" "$out" "/new.md"
assert_contains "counts the newest plan's steps" "$out" "steps (heuristic): 6"
rm -f "$GLOBAL_HOME/.claude/plans/old.md" "$GLOBAL_HOME/.claude/plans/new.md"

# ---------------------------------------------------------------------------
echo "test: done deletes the state file"
init_repo
arm "$PLAN4" >/dev/null
psf="$(plan_state_file)"
[ -f "$psf" ] && ok "state file exists after arm" || no "state file exists after arm"
out=$(disarm)
[ -f "$psf" ] && no "state file removed after done" || ok "state file removed after done"
assert_contains "done reports it cleared" "$out" "cleared"

# ---------------------------------------------------------------------------
echo "test: while armed, review.sh stays silent and freezes its marker"
init_repo
run_hook sid-defer >/dev/null            # first sight seeds the baseline (= base HEAD)
base="$(g rev-parse HEAD)"
commit_file src/app.py "print(1)"        # HEAD advances past the baseline
arm "$PLAN4" >/dev/null                   # defer review for the whole plan
out=$(run_hook sid-defer)
assert_empty "armed: review stays silent" "$out"
assert_equals "marker frozen at the baseline (not advanced)" "$(read_reviewed sid-defer)" "$base"

# ---------------------------------------------------------------------------
echo "test: after done, review.sh reviews the whole baseline..HEAD range once"
commit_file src/more.py "x = 2"          # a second commit during the plan's 2nd half
disarm >/dev/null
out=$(run_hook sid-defer)
assert_contains "reviews the first commit's file" "$out" "src/app.py"
assert_contains "reviews the second commit's file" "$out" "src/more.py"
assert_contains "emits a single block decision" "$out" '"decision": "block"'

# ---------------------------------------------------------------------------
echo "test: a stale armed_at self-heals (review resumes, stale file removed)"
init_repo
run_hook sid-stale >/dev/null            # seed baseline
commit_file src/y.py "y = 1"
psf="$(plan_state_file)"
printf '{"defer_review":true,"armed_at":0}' >"$psf"   # armed_at=0 -> far past the TTL
out=$(run_hook sid-stale)
assert_contains "stale defer self-heals -> reviews" "$out" "src/y.py"
[ -f "$psf" ] && no "stale state file removed" || ok "stale state file removed"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
