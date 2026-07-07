#!/usr/bin/env bash
#
# Tests for scripts/stash-session.sh — the UserPromptSubmit hook that stashes the
# current session's transcript_path for /verify-plan to read back.
#
# Black-box: feed JSON on stdin via pipe, assert on the temp file written.
# Isolation: $TMPDIR is pointed at an isolated work dir per test so we don't
# clash with live stash files.
#
# Cases:
#   1. Git-repo cwd: hook writes the stash at sha1(canonical --git-common-dir)[:16] key.
#   2. Non-git cwd: hook falls back to sha1(cwd)[:16] key, still writes.
#   3. Missing transcript_path: hook exits 0 and writes nothing.
#   4. Malformed JSON: hook exits 0 and writes nothing (fail-open).
#   5. Linked worktree cwd: same key as the primary checkout (one shared stash).
#   6. Lockstep: hook and /verify-plan SKILL both key on --git-common-dir, and the
#      skill has a session-id fallback for stale transcript paths.
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

# ---------------------------------------------------------------------------
# Helper: canonical absolute --git-common-dir for a repo path — the root the
# hook keys on. Mirrors the hook's realpath(join(cwd, --git-common-dir)).
# ---------------------------------------------------------------------------
common_dir() {
    (cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
}

# ===========================================================================
echo "test 1: git-repo cwd — stash written at sha1(canonical common dir) key"
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

KEY="$(sha1_key "$(common_dir "$REPO")")"
STASH="$T/tmp/verify-plan-session-$KEY.path"

assert_file "stash file written" "$STASH"
CONTENT="$(cat "$STASH" | tr -d '\n')"
assert_equals "stash contains transcript path" "$CONTENT" "$TRANSCRIPT"

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
STASH2="$T/tmp/verify-plan-session-$KEY2.path"

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
COUNT="$(find "$T/tmp" -name 'verify-plan-session-*.path' 2>/dev/null | wc -l)"
assert_equals "no stash file written" "$COUNT" "0"

# ===========================================================================
echo "test 4: malformed JSON — exits 0, no crash"
# ===========================================================================
T="$WORK/t4"
mkdir -p "$T/tmp"

run_hook "not valid json {{{{" "$T/tmp"
rc=$?
assert_exit0 "exits 0 on malformed JSON" "$rc"

COUNT="$(find "$T/tmp" -name 'verify-plan-session-*.path' 2>/dev/null | wc -l)"
assert_equals "no stash file on malformed JSON" "$COUNT" "0"

# ===========================================================================
echo "test 5: linked worktree cwd — same stash key as the primary checkout"
# ===========================================================================
T="$WORK/t5"
mkdir -p "$T/tmp"

REPO5="$T/repo"
mkdir -p "$REPO5"
git -C "$REPO5" init -q
git -C "$REPO5" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPO5" worktree add -q "$T/wt" -b t5-wt

# Hook fires from the primary checkout, then from the linked worktree.
JSON5P="$(printf '{"hook_event_name":"UserPromptSubmit","transcript_path":"%s","cwd":"%s"}' \
    "/fake/primary.jsonl" "$REPO5")"
run_hook "$JSON5P" "$T/tmp"
JSON5W="$(printf '{"hook_event_name":"UserPromptSubmit","transcript_path":"%s","cwd":"%s"}' \
    "/fake/worktree.jsonl" "$T/wt")"
run_hook "$JSON5W" "$T/tmp"

KEY5="$(sha1_key "$(common_dir "$REPO5")")"
STASH5="$T/tmp/verify-plan-session-$KEY5.path"

assert_file "stash written at the shared common-dir key" "$STASH5"
assert_equals "worktree hook overwrote the same stash" \
    "$(cat "$STASH5" | tr -d '\n')" "/fake/worktree.jsonl"
COUNT5="$(find "$T/tmp" -name 'verify-plan-session-*.path' 2>/dev/null | wc -l)"
assert_equals "primary + worktree share ONE stash file" "$COUNT5" "1"

# ===========================================================================
echo "test 6: hook and /verify-plan skill key in lockstep on --git-common-dir"
# ===========================================================================
SKILL="$PLUGIN_ROOT/skills/verify-plan/SKILL.md"

if grep -q -- '--git-common-dir' "$HOOK"; then
    ok "hook keys on --git-common-dir"
else
    no "hook keys on --git-common-dir"
fi
if grep -q -- '--git-common-dir' "$SKILL"; then
    ok "skill keys on --git-common-dir"
else
    no "skill keys on --git-common-dir"
fi
if grep -q -- '--show-toplevel' "$HOOK" || grep -q -- '--show-toplevel' "$SKILL"; then
    no "no stale --show-toplevel keying remains"
else
    ok "no stale --show-toplevel keying remains"
fi
if grep -q '\.claude/projects' "$SKILL"; then
    ok "skill has a session-id fallback for stale transcript paths"
else
    no "skill has a session-id fallback for stale transcript paths"
fi

# ===========================================================================
echo ""
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
