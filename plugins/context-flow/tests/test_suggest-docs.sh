#!/usr/bin/env bash
#
# Tests for scripts/suggest-docs.sh — the docs-staleness Stop hook.
#
# Black-box: we drive a real git repo + hook payload, run the actual hook, and
# assert on the JSON it prints and the per-session dedupe state it writes. The
# hook fires a SOFT "block" nudge only when a batch changed code (>=1 non-.md
# tracked file) and touched NO .md file.
#
# Covers:
#   * code-only change -> soft nudge fires (reason carries the docs wording);
#   * any .md in the batch -> silent (docs already being touched);
#   * no tracked changes -> silent;
#   * same HEAD twice -> second call deduped silent;
#   * stop_hook_active -> silent (no re-loop);
#   * no git / python3 on PATH -> fail open (exit 0, silent).
#
# Run: bash plugins/context-flow/tests/test_suggest-docs.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUGGEST="$PLUGIN_ROOT/scripts/suggest-docs.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Isolate state files ($TMPDIR is honored by python's tempfile) from real sessions.
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
GLOBAL_HOME="$WORK/home"
mkdir -p "$GLOBAL_HOME/.claude"

PROJECT_DIR="$WORK/proj"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_empty() { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected silence, got: $2)"; fi; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_file() { if [ -f "$2" ]; then ok "$1"; else no "$1 (missing file $2)"; fi; }

g() { git -C "$PROJECT_DIR" "$@"; }

init_repo() {
    rm -rf "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR"
    g init -q
    g config user.email t@t.com
    g config user.name t
    printf 'seed\n' >"$PROJECT_DIR/.gitkeep"
    g add -A
    g commit -q -m base
}

# stage_change <path> <content> — write a tracked change since HEAD (staged), so
# it shows up in `git diff --numstat HEAD`.
stage_change() {
    mkdir -p "$(dirname "$PROJECT_DIR/$1")"
    printf '%s\n' "$2" >"$PROJECT_DIR/$1"
    g add -A
}

# run_suggest <sid> [stop_hook_active] — run the Stop hook, print its stdout.
run_suggest() {
    local sid="$1" sha="${2:-false}"
    printf '{"hook_event_name":"Stop","session_id":"%s","stop_hook_active":%s}' "$sid" "$sha" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
            bash "$SUGGEST"
}

# docs_state <sid> — the per-session dedupe state path the hook computes.
docs_state() {
    python3 - "$1" <<'PY'
import sys, hashlib, tempfile, os
key = hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16]
print(os.path.join(tempfile.gettempdir(), "context-flow-docs-" + key + ".json"))
PY
}

# ---------------------------------------------------------------------------
echo "test: a code-only change fires the soft docs nudge"
init_repo
stage_change src/app.sh "echo hi"
out=$(run_suggest sid-d1)
assert_contains "code-only change emits a block decision" "$out" '"decision": "block"'
assert_contains "reason carries the docs-staleness wording" "$out" "no docs"
assert_contains "reason mentions folding docs into the commit" "$out" "fold them into this commit"
assert_file "writes the per-session dedupe state" "$(docs_state sid-d1)"

# ---------------------------------------------------------------------------
echo "test: a .md in the batch silences the nudge"
init_repo
stage_change src/app.sh "echo hi"
stage_change README.md "docs updated"
out=$(run_suggest sid-d2)
assert_empty "a touched .md silences the nudge" "$out"

# ---------------------------------------------------------------------------
echo "test: no tracked changes stays silent"
init_repo
out=$(run_suggest sid-d3)
assert_empty "no tracked changes: silent" "$out"

# ---------------------------------------------------------------------------
echo "test: the nudge is deduped once per HEAD"
init_repo
stage_change src/app.sh "echo hi"
out=$(run_suggest sid-d4)
assert_contains "first call at this HEAD fires" "$out" '"decision": "block"'
out=$(run_suggest sid-d4)
assert_empty "second call at the same HEAD is deduped silent" "$out"

# ---------------------------------------------------------------------------
echo "test: stop_hook_active stays silent (no re-loop)"
init_repo
stage_change src/app.sh "echo hi"
out=$(run_suggest sid-d5 true)
assert_empty "stop_hook_active true: silent" "$out"

# ---------------------------------------------------------------------------
echo "test: no git / python3 on PATH fails open (exit 0, silent)"
init_repo
stage_change src/app.sh "echo hi"
mkdir -p "$WORK/empty"
BASH_BIN="$(command -v bash)"
out=$(printf '{"hook_event_name":"Stop","session_id":"sid-d6","stop_hook_active":false}' \
    | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        PATH="$WORK/empty" "$BASH_BIN" "$SUGGEST" 2>/dev/null)
rc=$?
assert_empty "no git/python3: fail open silent" "$out"
assert_equals "fail open exits 0" "$rc" "0"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
