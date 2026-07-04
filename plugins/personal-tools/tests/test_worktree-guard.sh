#!/usr/bin/env bash
#
# Tests for scripts/worktree-guard.sh — the PreToolUse hook that denies Edit/Write/
# NotebookEdit into a git PRIMARY working tree and forces work into a linked worktree.
#
# Black-box: feed the hook JSON on stdin via pipe, assert on stdout (a deny emits a
# hookSpecificOutput JSON blob; an allow is silent) and the exit code (always 0).
# Isolation: each test builds its own throwaway git repo under a mktemp dir.
#
# Detection contract: a path resolves to the PRIMARY tree when
# `git rev-parse --git-dir` == `--git-common-dir`; a LINKED worktree differs.
#
# Cases:
#   1. Write to a primary-tree file            -> DENY (names EnterWorktree)
#   2. Write to a file in a linked worktree    -> ALLOW (silent)
#   3. Path outside any git repo               -> ALLOW (silent)
#   4. Missing file_path AND notebook_path     -> ALLOW (silent)
#   5. Malformed JSON                          -> ALLOW (silent, fail-open)
#   6. New (nonexistent) file under primary    -> DENY (nearest-ancestor resolution)
#   7. New file under a linked worktree        -> ALLOW
#   8. Merge in progress (MERGE_HEAD) primary  -> ALLOW (conflict resolution / merger)
#   9. NotebookEdit notebook_path in primary   -> DENY (field fallback)
#  10. Dirty primary tree                      -> DENY reason has commit/stash guidance
#  11. Kill-switch MYDOTCLAUDE_WORKTREE_GUARD=0 -> ALLOW even in primary
#
# Run: bash plugins/personal-tools/tests/test_worktree-guard.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PLUGIN_ROOT/scripts/worktree-guard.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_exit0()   { if [ "$2" -eq 0 ]; then ok "$1"; else no "$1 (exit $2, want 0)"; fi; }
assert_deny()    { if printf '%s' "$2" | grep -q '"permissionDecision": *"deny"'; then ok "$1"; else no "$1 (no deny in: $2)"; fi; }
assert_allow()   { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected silent, got: $2)"; fi; }
assert_has()     { if printf '%s' "$2" | grep -q "$3"; then ok "$1"; else no "$1 (missing '$3' in: $2)"; fi; }

# Skip all tests if python3 is absent — the hook exits 0 (allow) without acting,
# so there's nothing to assert on.
if ! command -v python3 >/dev/null 2>&1; then
    printf 'SKIP: python3 not found; worktree-guard hook is allow-only no-op\n'
    exit 0
fi

# Build a throwaway repo with one commit; echo its path.
mk_repo() {
    local r="$1"
    mkdir -p "$r"
    git -C "$r" init -q
    git -C "$r" config user.email t@t.t
    git -C "$r" config user.name t
    git -C "$r" commit -q --allow-empty -m init
}

# Run the hook with a JSON payload; capture stdout. Returns exit in $rc.
run_hook() {
    local json="$1"; shift
    printf '%s' "$json" | env "$@" bash "$HOOK"
}

mkjson() {  # mkjson <tool> <field> <path> <cwd>
    printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"%s":"%s"},"cwd":"%s"}' \
        "$1" "$2" "$3" "$4"
}

# ===========================================================================
echo "test 1: write to a primary-tree file -> DENY"
# ===========================================================================
R="$WORK/r1"; mk_repo "$R"
OUT="$(run_hook "$(mkjson Write file_path "$R/foo.txt" "$R")")"; rc=$?
assert_exit0 "exits 0" "$rc"
assert_deny "denies primary-tree write" "$OUT"
assert_has "names EnterWorktree" "$OUT" "EnterWorktree"

# ===========================================================================
echo "test 2: write to a file in a linked worktree -> ALLOW"
# ===========================================================================
R="$WORK/r2"; mk_repo "$R"
git -C "$R" worktree add -q "$R/.claude/worktrees/wt" -b wt HEAD
OUT="$(run_hook "$(mkjson Write file_path "$R/.claude/worktrees/wt/foo.txt" "$R/.claude/worktrees/wt")")"; rc=$?
assert_exit0 "exits 0" "$rc"
assert_allow "allows linked-worktree write" "$OUT"

# ===========================================================================
echo "test 3: path outside any git repo -> ALLOW"
# ===========================================================================
NOGIT="$WORK/nogit"; mkdir -p "$NOGIT"
OUT="$(run_hook "$(mkjson Write file_path "$NOGIT/foo.txt" "$NOGIT")")"; rc=$?
assert_exit0 "exits 0" "$rc"
assert_allow "allows non-repo path" "$OUT"

# ===========================================================================
echo "test 4: missing file_path and notebook_path -> ALLOW"
# ===========================================================================
R="$WORK/r4"; mk_repo "$R"
OUT="$(run_hook "$(printf '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{},"cwd":"%s"}' "$R")")"; rc=$?
assert_exit0 "exits 0" "$rc"
assert_allow "allows when no path field" "$OUT"

# ===========================================================================
echo "test 5: malformed JSON -> ALLOW (fail-open)"
# ===========================================================================
OUT="$(run_hook "not valid json {{{{")"; rc=$?
assert_exit0 "exits 0 on malformed JSON" "$rc"
assert_allow "allows on malformed JSON" "$OUT"

# ===========================================================================
echo "test 6: new (nonexistent) file under primary -> DENY"
# ===========================================================================
R="$WORK/r6"; mk_repo "$R"
OUT="$(run_hook "$(mkjson Write file_path "$R/newdir/sub/new.txt" "$R")")"; rc=$?
assert_exit0 "exits 0" "$rc"
assert_deny "denies new file under primary (ancestor resolution)" "$OUT"

# ===========================================================================
echo "test 7: new file under a linked worktree -> ALLOW"
# ===========================================================================
R="$WORK/r7"; mk_repo "$R"
git -C "$R" worktree add -q "$R/.claude/worktrees/wt" -b wt HEAD
OUT="$(run_hook "$(mkjson Write file_path "$R/.claude/worktrees/wt/newdir/new.txt" "$R/.claude/worktrees/wt")")"; rc=$?
assert_exit0 "exits 0" "$rc"
assert_allow "allows new file under linked worktree" "$OUT"

# ===========================================================================
echo "test 8: merge in progress (MERGE_HEAD) on primary -> ALLOW"
# ===========================================================================
R="$WORK/r8"; mk_repo "$R"
touch "$R/.git/MERGE_HEAD"
OUT="$(run_hook "$(mkjson Edit file_path "$R/foo.txt" "$R")")"; rc=$?
assert_exit0 "exits 0" "$rc"
assert_allow "allows primary write during in-progress merge" "$OUT"

# ===========================================================================
echo "test 9: NotebookEdit notebook_path in primary -> DENY"
# ===========================================================================
R="$WORK/r9"; mk_repo "$R"
OUT="$(run_hook "$(mkjson NotebookEdit notebook_path "$R/nb.ipynb" "$R")")"; rc=$?
assert_exit0 "exits 0" "$rc"
assert_deny "denies NotebookEdit via notebook_path fallback" "$OUT"

# ===========================================================================
echo "test 10: dirty primary tree -> DENY reason has commit/stash guidance"
# ===========================================================================
R="$WORK/r10"; mk_repo "$R"
echo dirty > "$R/dirty.txt"   # untracked -> porcelain non-empty
OUT="$(run_hook "$(mkjson Write file_path "$R/foo.txt" "$R")")"; rc=$?
assert_exit0 "exits 0" "$rc"
assert_deny "denies (dirty tree)" "$OUT"
assert_has "reason mentions commit or stash" "$OUT" "stash"

# ===========================================================================
echo "test 11: kill-switch MYDOTCLAUDE_WORKTREE_GUARD=0 -> ALLOW in primary"
# ===========================================================================
R="$WORK/r11"; mk_repo "$R"
OUT="$(run_hook "$(mkjson Write file_path "$R/foo.txt" "$R")" MYDOTCLAUDE_WORKTREE_GUARD=0)"; rc=$?
assert_exit0 "exits 0" "$rc"
assert_allow "kill-switch allows primary write" "$OUT"

# ===========================================================================
echo ""
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
