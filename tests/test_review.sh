#!/usr/bin/env bash
#
# Tests for scripts/review.sh — the commit-gated Stop-hook trigger logic.
#
# Black-box: we drive a real git repo + hook payload, run the actual hook
# script, and assert on the JSON it prints to stdout. The hook reviews COMMITTED
# work (not working-tree edits): it seeds a baseline HEAD on first sight, stays
# silent while the tree is dirty (deferring to the commit gate), and emits a
# block once HEAD advances past the last-reviewed commit on a clean tree.
#
# Covers: baseline seeding, the dirty-tree defer, the post-commit review, the
# docs/lockfile/generated skip filter, per-commit dedup, NOT short-circuiting on
# stop_hook_active (the commit->review chain needs this), audience selection,
# and the fail-open silent paths.
#
# Run: bash tests/test_review.sh   (exits non-zero if any test fails)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/scripts/review.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Isolate dedup state files ($TMPDIR is honored by python's tempfile) from any
# real sessions on this machine.
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"

PROJECT_DIR="$WORK/proj"

# A controlled, empty user-home so the user-wide audience fallback
# (~/.claude/review-audience) is deterministic regardless of the real home.
GLOBAL_HOME="$WORK/home"
mkdir -p "$GLOBAL_HOME/.claude"

pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_empty() { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected silence, got: $2)"; fi; }

g() { git -C "$PROJECT_DIR" "$@"; }

# Fresh repo with one base commit. Wipes any prior state in PROJECT_DIR.
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

# commit_file <relpath> <content>  — write + commit a tracked file.
commit_file() {
    mkdir -p "$(dirname "$PROJECT_DIR/$1")"
    printf '%s\n' "$2" >"$PROJECT_DIR/$1"
    g add -A
    g commit -q -m "change $1"
}

# run_hook <session_id> [stop_hook_active]  — print the hook's stdout.
run_hook() {
    local sid="$1" active="${2:-false}"
    printf '{"session_id":"%s","stop_hook_active":%s}' "$sid" "$active" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
            bash "$HOOK"
}

# First hook call of a session records the baseline HEAD silently.
seed() { run_hook "$1" >/dev/null; }

# ---------------------------------------------------------------------------
echo "test: first sight of a session seeds the baseline silently"
init_repo
out=$(run_hook sid-seed)
assert_empty "no review on the seeding call" "$out"

# ---------------------------------------------------------------------------
echo "test: reviews a source file committed after the baseline"
init_repo
seed sid-1
commit_file src/app.py "print(1)"
out=$(run_hook sid-1)
assert_contains "emits block decision" "$out" '"decision": "block"'
assert_contains "lists the committed source file" "$out" "src/app.py"

# ---------------------------------------------------------------------------
echo "test: stays silent while the tree is dirty (defers to the commit gate)"
init_repo
seed sid-dirty
commit_file src/x.py "v1"                         # an unreviewed commit exists
printf 'v2\n' >"$PROJECT_DIR/src/x.py"            # ...but the tree is now dirty
out=$(run_hook sid-dirty)
assert_empty "dirty tree -> silent" "$out"
g add -A && g commit -q -m "commit x"             # commit it
out=$(run_hook sid-dirty)
assert_contains "reviews once the tree is clean" "$out" "src/x.py"

# ---------------------------------------------------------------------------
echo "test: skips docs, lockfiles, and generated files by path"
init_repo
seed sid-2
mkdir -p "$PROJECT_DIR/src" "$PROJECT_DIR/docs" "$PROJECT_DIR/web" \
         "$PROJECT_DIR/api" "$PROJECT_DIR/node_modules/dep"
printf 'print(1)\n' >"$PROJECT_DIR/src/app.py"
printf '# readme\n' >"$PROJECT_DIR/README.md"
printf 'guide\n' >"$PROJECT_DIR/docs/guide.rst"
printf '{}\n' >"$PROJECT_DIR/package-lock.json"
printf 'x\n' >"$PROJECT_DIR/web/app.min.js"
printf 'x = 1\n' >"$PROJECT_DIR/api/service_pb2.py"
printf 'x\n' >"$PROJECT_DIR/node_modules/dep/index.js"
g add -A && g commit -q -m "batch"
out=$(run_hook sid-2)
assert_contains "still reviews the source file" "$out" "src/app.py"
assert_not_contains "skips README.md" "$out" "README.md"
assert_not_contains "skips .rst doc" "$out" "guide.rst"
assert_not_contains "skips lockfile" "$out" "package-lock.json"
assert_not_contains "skips .min.js" "$out" "app.min.js"
assert_not_contains "skips protobuf _pb2.py" "$out" "service_pb2.py"
assert_not_contains "skips node_modules path" "$out" "node_modules"

# ---------------------------------------------------------------------------
echo "test: silent when every committed file is skippable"
init_repo
seed sid-3
printf '# readme\n' >"$PROJECT_DIR/README.md"
printf 'lock\n' >"$PROJECT_DIR/yarn.lock"
g add -A && g commit -q -m "docs only"
out=$(run_hook sid-3)
assert_empty "no decision when nothing reviewable" "$out"

# ---------------------------------------------------------------------------
echo "test: skips files with a generated header marker"
init_repo
seed sid-4
mkdir -p "$PROJECT_DIR/src"
printf '# Code generated by tool. DO NOT EDIT.\nx = 1\n' >"$PROJECT_DIR/gen_config.py"
printf 'real = 1\n' >"$PROJECT_DIR/src/real.py"
g add -A && g commit -q -m "gen + real"
out=$(run_hook sid-4)
assert_contains "reviews the hand-written file" "$out" "src/real.py"
assert_not_contains "skips DO NOT EDIT file" "$out" "gen_config.py"

# ---------------------------------------------------------------------------
echo "test: does not re-review the same commit within a session"
init_repo
seed sid-5
commit_file src/app.py "print(1)"
out1=$(run_hook sid-5)
assert_contains "first call reviews" "$out1" "src/app.py"
out2=$(run_hook sid-5)
assert_empty "second call (no new commit) stays silent" "$out2"

# ---------------------------------------------------------------------------
echo "test: reviews even on a stop-hook continuation (the commit->review chain)"
init_repo
seed sid-chain
commit_file src/app.py "print(1)"
out=$(run_hook sid-chain true)
assert_contains "does NOT short-circuit on stop_hook_active" "$out" '"decision": "block"'

# ---------------------------------------------------------------------------
echo "test: plain audience produces a non-technical instruction"
init_repo
echo plain >"$PROJECT_DIR/.claude/review-audience"
seed sid-6
commit_file src/app.py "print(1)"
out=$(run_hook sid-6)
assert_contains "uses plain-English framing" "$out" "NOT a programmer"

# ---------------------------------------------------------------------------
echo "test: user-wide plain audience (no project marker) produces plain framing"
init_repo
echo plain >"$GLOBAL_HOME/.claude/review-audience"
seed sid-9
commit_file src/app.py "print(1)"
out=$(run_hook sid-9)
assert_contains "global plain marker applies" "$out" "NOT a programmer"

# ---------------------------------------------------------------------------
echo "test: a project marker overrides the user-wide default"
init_repo
echo technical >"$PROJECT_DIR/.claude/review-audience"   # global still 'plain' from above
seed sid-10
commit_file src/app.py "print(1)"
out=$(run_hook sid-10)
assert_contains "project technical wins over global plain" "$out" "grouped by severity"
assert_not_contains "no plain framing when project overrides" "$out" "NOT a programmer"
rm -f "$GLOBAL_HOME/.claude/review-audience"

# ---------------------------------------------------------------------------
echo "test: neither marker present falls back to technical"
init_repo
seed sid-11
commit_file src/app.py "print(1)"
out=$(run_hook sid-11)
assert_contains "defaults to technical framing" "$out" "grouped by severity"
assert_not_contains "no plain framing by default" "$out" "NOT a programmer"

# ---------------------------------------------------------------------------
echo "test: not a git repo stays silent"
NONGIT="$WORK/nongit"
mkdir -p "$NONGIT"
out=$(printf '{"session_id":"x","stop_hook_active":false}' \
    | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$NONGIT" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$HOOK")
assert_empty "no decision outside a git work tree" "$out"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
