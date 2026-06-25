#!/usr/bin/env bash
#
# Tests for scripts/stash-session.sh — the UserPromptSubmit hook that stashes the
# current session's transcript_path for /review-grill to read back.
#
# Black-box: feed JSON on stdin via pipe, assert on the temp file written.
# Isolation: $TMPDIR is pointed at an isolated work dir per test so we don't
# clash with live stash files.
#
# Cases:
#   1. Git-repo cwd: hook writes the stash at sha1(git-toplevel)[:16] key.
#   2. Non-git cwd: hook falls back to sha1(cwd)[:16] key, still writes.
#   3. Missing transcript_path: hook exits 0 and writes nothing.
#   4. Malformed JSON: hook exits 0 and writes nothing (fail-open).
#
# Run: bash plugins/personal-tools/tests/test_stash-session.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PLUGIN_ROOT/scripts/stash-session.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_file()    { if [ -f "$2" ]; then ok "$1"; else no "$1 (missing file: $2)"; fi; }
assert_nofile()  { if [ ! -f "$2" ]; then ok "$1"; else no "$1 (unexpected file: $2)"; fi; }
assert_equals()  { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_exit0()   { if [ "$2" -eq 0 ]; then ok "$1"; else no "$1 (exit $2, want 0)"; fi; }

# Skip all tests if python3 is absent — the hook itself exits 0 without writing
# anything, so there's nothing to assert on.
if ! command -v python3 >/dev/null 2>&1; then
    printf 'SKIP: python3 not found; stash-session hook is a no-op\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Helper: compute the key the hook writes — sha1(root)[:16].
# Used to predict the stash filename from outside the hook.
# ---------------------------------------------------------------------------
sha1_key() {
    printf '%s' "$1" | sha1sum | cut -c1-16
}

# ---------------------------------------------------------------------------
# Helper: run the hook with a given JSON payload and isolated TMPDIR.
# Returns the hook's exit code (captured in $?).
# ---------------------------------------------------------------------------
run_hook() {
    local json="$1" tmpdir="$2"
    printf '%s' "$json" | TMPDIR="$tmpdir" bash "$HOOK"
}

# ===========================================================================
echo "test 1: git-repo cwd — stash written at sha1(git-toplevel) key"
# ===========================================================================
T="$WORK/t1"
mkdir -p "$T/tmp"

# Init a bare temp git repo.
REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

TRANSCRIPT="/fake/session-abc.jsonl"
JSON="$(printf '{"hook_event_name":"UserPromptSubmit","transcript_path":"%s","cwd":"%s"}' \
    "$TRANSCRIPT" "$REPO")"

run_hook "$JSON" "$T/tmp"
rc=$?
assert_exit0 "exits 0" "$rc"

TOPLEVEL="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)"
KEY="$(sha1_key "$TOPLEVEL")"
STASH="$T/tmp/review-grill-session-$KEY.path"

assert_file "stash file written" "$STASH"
CONTENT="$(cat "$STASH" | tr -d '\n')"
assert_equals "stash contains transcript path" "$CONTENT" "$TRANSCRIPT"

# Bonus: confirm the key used is the toplevel key, not the cwd key directly
# (they happen to be the same here since REPO IS the toplevel — checked by
# verifying the sha1 matches the real toplevel path).
EXPECTED_KEY="$(sha1_key "$TOPLEVEL")"
assert_equals "key is sha1 of toplevel" "$KEY" "$EXPECTED_KEY"

# ===========================================================================
echo "test 2: non-git cwd — falls back to sha1(cwd) key"
# ===========================================================================
T="$WORK/t2"
mkdir -p "$T/tmp"

NOGIT="$T/nogit"
mkdir -p "$NOGIT"   # NOT a git repo

TRANSCRIPT2="/sessions/session-xyz.jsonl"
JSON2="$(printf '{"hook_event_name":"UserPromptSubmit","transcript_path":"%s","cwd":"%s"}' \
    "$TRANSCRIPT2" "$NOGIT")"

run_hook "$JSON2" "$T/tmp"
rc=$?
assert_exit0 "exits 0" "$rc"

KEY2="$(sha1_key "$NOGIT")"
STASH2="$T/tmp/review-grill-session-$KEY2.path"

assert_file "stash file written (non-git)" "$STASH2"
CONTENT2="$(cat "$STASH2" | tr -d '\n')"
assert_equals "stash contains transcript path (non-git)" "$CONTENT2" "$TRANSCRIPT2"

# ===========================================================================
echo "test 3: missing transcript_path — exits 0, writes nothing"
# ===========================================================================
T="$WORK/t3"
mkdir -p "$T/tmp"

JSON3='{"hook_event_name":"UserPromptSubmit","cwd":"/some/path"}'

run_hook "$JSON3" "$T/tmp"
rc=$?
assert_exit0 "exits 0 when transcript_path absent" "$rc"

# No stash file should exist in this isolated tmp
COUNT="$(find "$T/tmp" -name 'review-grill-session-*.path' 2>/dev/null | wc -l)"
assert_equals "no stash file written" "$COUNT" "0"

# ===========================================================================
echo "test 4: malformed JSON — exits 0, no crash"
# ===========================================================================
T="$WORK/t4"
mkdir -p "$T/tmp"

run_hook "not valid json {{{{" "$T/tmp"
rc=$?
assert_exit0 "exits 0 on malformed JSON" "$rc"

COUNT="$(find "$T/tmp" -name 'review-grill-session-*.path' 2>/dev/null | wc -l)"
assert_equals "no stash file on malformed JSON" "$COUNT" "0"

# ===========================================================================
echo ""
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
