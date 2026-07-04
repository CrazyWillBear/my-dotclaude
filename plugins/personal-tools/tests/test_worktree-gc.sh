#!/usr/bin/env bash
#
# Tests for scripts/worktree-gc.sh — the SessionStart backstop that sweeps
# crash-orphaned kit worktrees (<repo>/.claude/worktrees/*).
#
# Black-box: build a throwaway repo, add worktrees, drive them into a known state,
# run the hook (JSON on stdin, CLAUDE_PROJECT_DIR in the env), and assert which
# worktree dirs survive. Removal happens ONLY when ALL guards pass; every other
# case keeps the worktree. The hook is always silent and exits 0 (fail-open).
#
# Cases:
#   1. clean + no unique commits + old + not-cwd      -> REMOVED
#   2. dirty tree                                      -> kept
#   3. has unique commits vs base                      -> kept
#   4. fresh (mtime within the age window)             -> kept
#   5. is the current session's worktree               -> kept
#   6. worktree NOT under .claude/worktrees/           -> kept (not a kit worktree)
#   7. non-git project dir                             -> fail-open, no crash
#
# Run: bash plugins/personal-tools/tests/test_worktree-gc.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PLUGIN_ROOT/scripts/worktree-gc.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_exit0()    { if [ "$2" -eq 0 ]; then ok "$1"; else no "$1 (exit $2, want 0)"; fi; }
assert_gone()     { if [ -d "$2" ]; then no "$1 (still present: $2)"; else ok "$1"; fi; }
assert_present()  { if [ -d "$2" ]; then ok "$1"; else no "$1 (unexpectedly removed: $2)"; fi; }
assert_silent()   { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected silence, got: $2)"; fi; }

# Skip all tests if python3 is absent — the hook exits 0 (no-op) without acting.
if ! command -v python3 >/dev/null 2>&1; then
    printf 'SKIP: python3 not found; worktree-gc hook is a no-op\n'
    exit 0
fi

mk_repo() {  # echoes a fresh, uniquely-named repo path with one real commit
    local r; r="$(mktemp -d "$WORK/repo.XXXXXX")"
    git -C "$r" init -q >/dev/null 2>&1
    git -C "$r" config user.email t@t.t
    git -C "$r" config user.name t
    printf 'seed\n' >"$r/seed.txt"
    git -C "$r" add -A >/dev/null 2>&1
    git -C "$r" commit -q -m init >/dev/null 2>&1
    printf '%s' "$r"
}

add_wt() {  # add_wt <repo> <relpath> <branch>  — echoes absolute worktree path
    git -C "$1" worktree add "$2" -b "$3" HEAD >/dev/null 2>&1
    ( cd "$1/$2" && pwd -P )
}

backdate() {  # backdate <path> — set mtime ~28h ago (older than the 12h window)
    local old; old="$(( $(date +%s) - 100000 ))"
    touch -d "@$old" "$1"
}

# run_gc <project_dir> — run the hook; stdout in $out, exit in $rc.
run_gc() {
    out="$(printf '{"hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$1" \
        | CLAUDE_PROJECT_DIR="$1" bash "$HOOK")"
    rc=$?
}

# ---------------------------------------------------------------------------
echo "test: a clean, commit-free, old, non-cwd worktree is removed"
repo="$(mk_repo)"
wt="$(add_wt "$repo" .claude/worktrees/orphan orphan)"
backdate "$wt"
run_gc "$repo"
assert_exit0 "hook exits 0" "$rc"
assert_silent "hook is silent" "$out"
assert_gone "orphan worktree removed" "$wt"

# ---------------------------------------------------------------------------
echo "test: a dirty worktree is kept"
repo="$(mk_repo)"
wt="$(add_wt "$repo" .claude/worktrees/dirty dirty)"
printf 'scratch\n' >"$wt/uncommitted.txt"   # untracked -> dirty
backdate "$wt"
run_gc "$repo"
assert_exit0 "hook exits 0" "$rc"
assert_present "dirty worktree kept" "$wt"

# ---------------------------------------------------------------------------
echo "test: a worktree with unique commits is kept"
repo="$(mk_repo)"
wt="$(add_wt "$repo" .claude/worktrees/hascommits hascommits)"
git -C "$wt" commit -q --allow-empty -m "unique work"   # clean tree, but ahead of base
backdate "$wt"
run_gc "$repo"
assert_exit0 "hook exits 0" "$rc"
assert_present "worktree with commits kept" "$wt"

# ---------------------------------------------------------------------------
echo "test: a fresh worktree (recent mtime) is kept"
repo="$(mk_repo)"
wt="$(add_wt "$repo" .claude/worktrees/fresh fresh)"   # mtime = now, do NOT backdate
run_gc "$repo"
assert_exit0 "hook exits 0" "$rc"
assert_present "fresh worktree kept" "$wt"

# ---------------------------------------------------------------------------
echo "test: the current session's own worktree is never removed"
repo="$(mk_repo)"
wt="$(add_wt "$repo" .claude/worktrees/iam-cwd iamcwd)"
backdate "$wt"
run_gc "$wt"        # session is IN this worktree
assert_exit0 "hook exits 0" "$rc"
assert_present "cwd worktree kept" "$wt"

# ---------------------------------------------------------------------------
echo "test: a worktree outside .claude/worktrees/ is not a kit worktree (kept)"
repo="$(mk_repo)"
wt="$(add_wt "$repo" external-wt extbr)"   # not under .claude/worktrees/
backdate "$wt"
run_gc "$repo"
assert_exit0 "hook exits 0" "$rc"
assert_present "external worktree kept" "$wt"

# ---------------------------------------------------------------------------
echo "test: a non-git project dir fails open (no crash)"
nonrepo="$WORK/nonrepo"
mkdir -p "$nonrepo"
run_gc "$nonrepo"
assert_exit0 "hook exits 0 outside a repo" "$rc"
assert_silent "hook silent outside a repo" "$out"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
