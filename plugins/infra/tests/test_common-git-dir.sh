#!/usr/bin/env bash
#
# Tests for scripts/common-git-dir.sh — the ONE resolution of a worktree's common git dir.
#
# This exists as a script rather than a copy in each caller because spawn.sh and
# worker-resume.sh must produce the IDENTICAL value: it becomes
# `sandbox_workspace_write.writable_roots`, and a resume that resolves it differently than
# its spawn hands the worker a different writable root. The failure is silent until the
# worker has done the whole issue and cannot commit.
#
# The load-bearing case is the LINKED worktree — every real orchestrate worker — where the
# objects and refs live in the MAIN repo's git dir, not the worktree's own.
#
# Run: bash plugins/infra/tests/test_common-git-dir.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/common-git-dir.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in '$2')" ;; esac; }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected empty, got '$2')"; fi; }

run() {
    local errf="$WORK/err"
    OUT="$(bash "$SCRIPT" "$@" 2>"$errf")"
    RC=$?
    ERR="$(cat "$errf")"
}

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
printf 'x\n' >"$REPO/f"
git -C "$REPO" add f
git -C "$REPO" commit -qm init

echo "test: a plain repo resolves to its own .git, absolute"
run "$REPO"
assert_equals "exit 0" "$RC" "0"
assert_equals "the canonical .git" "$OUT" "$(cd "$REPO/.git" && pwd -P)"
case "$OUT" in /*) ok "absolute" ;; *) no "not absolute: $OUT" ;; esac

echo "test: a LINKED worktree resolves to the MAIN repo's git dir, not its own"
# The whole reason this value is needed: workspace-write keeps .git read-only, and a
# linked worktree's objects and refs live in the common dir. Resolving to the worktree's
# own gitdir (.git/worktrees/<name>) would leave the worker unable to commit.
git -C "$REPO" worktree add -q -b wt "$WORK/linked" >/dev/null 2>&1
run "$WORK/linked"
assert_equals "exit 0" "$RC" "0"
assert_equals "the MAIN repo's .git" "$OUT" "$(cd "$REPO/.git" && pwd -P)"

CANON="$(cd "$REPO/.git" && pwd -P)"

echo "test: --roots narrows a LINKED worktree to what a commit touches, never hooks or config"
# This is the branch EVERY real worker takes, and the one that closes the escape. Granting
# the whole common dir made .git/hooks and .git/config writable, and git EXECUTES both: a
# hook written by one worker then runs in every sibling worktree and in the user's own
# checkout. Verified on codex-cli 0.154, ground-truthed from outside the sandbox on a real
# ~/code path — with these roots a commit still lands and .git/hooks is blocked.
OWNDIR="$(cd "$(git -C "$WORK/linked" rev-parse --git-dir)" && pwd -P)"
run --roots "$WORK/linked"
assert_equals "exit 0" "$RC" "0"
assert_equals "exactly the four roots a commit touches" "$OUT" \
    "[\"$CANON/objects\",\"$CANON/refs\",\"$CANON/logs\",\"$OWNDIR\"]"
case "$OUT" in
    *hooks*) no "hooks/ is writable — the host-code-execution escape is open again" ;;
    *)       ok "hooks/ is never granted" ;;
esac
case "$OUT" in
    *config*) no "config is writable — core.sshCommand is reachable again" ;;
    *)        ok "config is never granted" ;;
esac
# The whole dir would appear as a bare "<canon>" element; narrowed roots only ever carry
# "<canon>/something", so this catches a silent revert to granting everything.
case "$OUT" in
    *\"$CANON\"*) no "the WHOLE common dir is granted — narrowing is defeated" ;;
    *)            ok "the whole common dir is not granted" ;;
esac

echo "test: --roots on a PLAIN repo keeps the whole dir, because nothing there can be narrowed"
# HEAD, index and COMMIT_EDITMSG sit directly in the common dir of a plain repo, so
# excluding it would stop the worker committing at all. Workers always run in linked
# worktrees; this branch exists so the script is honest about the repo it cannot protect,
# rather than silently granting less than a commit needs.
run --roots "$REPO"
assert_equals "exit 0" "$RC" "0"
assert_equals "the whole dir, explicitly" "$OUT" "[\"$CANON\"]"

echo "test: --roots fails loud too, rather than printing an empty root list"
run --roots "$WORK/no-such-dir-at-all"
assert_equals "exits 1" "$RC" "1"
assert_empty "and prints no roots" "$OUT"
assert_contains "names it" "$ERR" "does not exist"

echo "test: symlinks are resolved, so the spawn and a later resume agree textually"
ln -s "$REPO" "$WORK/link-to-repo"
run "$WORK/link-to-repo"
assert_equals "exit 0" "$RC" "0"
assert_equals "same canonical path as the real one" "$OUT" "$(cd "$REPO/.git" && pwd -P)"

echo "test: it fails LOUD rather than printing an empty root"
# `writable_roots=[""]` is the silent-failure shape: the worker runs, cannot commit, and
# says so only in its final message. Every refusal must be exit 1 with EMPTY stdout.
mkdir -p "$WORK/notgit"
run "$WORK/notgit"
assert_equals "a non-repo exits 1" "$RC" "1"
assert_empty "and prints no path" "$OUT"
assert_contains "says why" "$ERR" "not a git worktree"

run "$WORK/does-not-exist"
assert_equals "a missing dir exits 1" "$RC" "1"
assert_empty "and prints no path" "$OUT"
assert_contains "names it" "$ERR" "does not exist"

# `run ""`, never a bare `run`: an empty "$@" under `set -u` is an unbound-variable abort on
# bash 3.2, which macOS still ships and this repo designs for — it would take the whole file
# down there while CI stayed green. The empty string exercises the identical refusal.
run ""
assert_equals "no argument exits 1" "$RC" "1"
assert_empty "and prints no path" "$OUT"
assert_contains "usage" "$ERR" "usage"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
