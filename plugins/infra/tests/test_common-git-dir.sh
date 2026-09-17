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

# run() with one extra environment assignment. A stray GIT_DIR steers git's resolution as
# surely as a rewritten file does, and both callers inherit the orchestrator's environment.
run_env() {
    local errf="$WORK/err" assign="$1"
    shift
    OUT="$(env "$assign" bash "$SCRIPT" "$@" 2>"$errf")"
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

echo "test: --roots REFUSES anything that is not a linked worktree"
# TWO DISTINCT SHAPES, which need TWO DISTINCT REPOS. $REPO grew a linked worktree at line 58,
# so by here it is the MAIN-worktree case and cannot also stand in for a plain repo — running
# the identical command twice under two labels proves only one of them. The main-worktree case
# is the dangerous one: that is the user's own checkout, where OWN == GITDIR too, and handing
# back the whole shared .git there is the full hooks/config escape with nothing on stderr.
PLAIN="$WORK/plainrepo"
mkdir -p "$PLAIN"
git -C "$PLAIN" init -q
run --roots "$PLAIN"
assert_equals "a plain repo with no worktrees exits 1" "$RC" "1"
assert_empty "and prints no roots" "$OUT"
assert_contains "says a linked worktree is required" "$ERR" "LINKED worktree"
assert_contains "and names a remedy, not just the reason" "$ERR" "git worktree add"

run --roots "$REPO"
assert_equals "the MAIN worktree of a multi-worktree repo exits 1" "$RC" "1"
assert_empty "and prints no roots either" "$OUT"
assert_contains "same refusal for the user's own checkout shape" "$ERR" "LINKED worktree"

echo "test: --roots refuses when extensions.worktreeConfig makes config.worktree writable"
# config.worktree sits inside the worktree's OWN git dir, which IS granted, and git reads it
# on top of the shared config when the extension is on — so core.sshCommand written there is
# host code execution. `git sparse-checkout set` enables the extension on its own.
git -C "$WORK/linked" config extensions.worktreeConfig true
run --roots "$WORK/linked"
assert_equals "exits 1" "$RC" "1"
assert_empty "and prints no roots" "$OUT"
assert_contains "names the reason" "$ERR" "worktreeConfig"
git -C "$WORK/linked" config --unset extensions.worktreeConfig

echo "test: --roots refuses a config.worktree ALREADY planted in the granted git dir"
# The extension check is point-in-time. With the extension off, a worker can still write
# $OWN/config.worktree today and have it arm the moment anyone runs `git sparse-checkout set`.
# Nothing removes it and a resume re-runs the same passing check, so refuse what we can see.
PLANTED="$(cd "$(git -C "$WORK/linked" rev-parse --git-dir)" && pwd -P)/config.worktree"
printf '[core]\n\tsshCommand = /tmp/pwned\n' >"$PLANTED"
run --roots "$WORK/linked"
assert_equals "exits 1 even though the extension is off" "$RC" "1"
assert_empty "and prints no roots" "$OUT"
assert_contains "names the planted file" "$ERR" "config.worktree"
rm -f "$PLANTED"

echo "test: --roots REFUSES a rewritten commondir, which would steer the roots elsewhere"
# $GITDIR comes from `git rev-parse --git-common-dir`, which commondir redirects — so without
# this guard a worker rewrites one file inside its own writable git dir and the roots point at
# ANOTHER repository's objects/refs/logs. Reproduced 2026-09-17. The victim repo stands in for
# the user's own checkout.
git init -q "$WORK/victim"
OWNDIR3="$(cd "$(git -C "$WORK/linked" rev-parse --git-dir)" && pwd -P)"
cp "$OWNDIR3/commondir" "$WORK/commondir.bak"
printf '%s\n' "$WORK/victim/.git" >"$OWNDIR3/commondir"
run --roots "$WORK/linked"
assert_equals "exits 1" "$RC" "1"
assert_empty "and prints no roots — never a root set aimed at another repo" "$OUT"
assert_contains "names the rewrite" "$ERR" "commondir has been rewritten"
cp "$WORK/commondir.bak" "$OWNDIR3/commondir"
run --roots "$WORK/linked"
assert_equals "and an honest worktree still passes once restored" "$RC" "0"

# A victim repo that HAS a linked worktree — the shape a repointed .git must aim at, and
# what the user's own checkout looks like (this repo keeps worktrees under .claude/).
VREPO="$WORK/vrepo"
mkdir -p "$VREPO"
git -C "$VREPO" init -q
git -C "$VREPO" config user.email t@t.t
git -C "$VREPO" config user.name t
printf 'v\n' >"$VREPO/f"
git -C "$VREPO" add f
git -C "$VREPO" commit -qm init
git -C "$VREPO" worktree add -q -b vwt "$WORK/vlinked" >/dev/null 2>&1
VOWN="$(cd "$(git -C "$WORK/vlinked" rev-parse --git-dir)" && pwd -P)"
cp "$WORK/linked/.git" "$WORK/dotgit.bak"

echo "test: --roots REFUSES a .git repointed at another repo, which steers BOTH compared values"
# Containment compares $GITDIR against $OWN, but both resolve from $WORKTREE/.git — a
# regular file in the writable workspace root. Repointing it moves both sides together, so
# containment alone still passed while every root aimed at the victim. Reproduced 2026-09-17.
printf 'gitdir: %s\n' "$VOWN" >"$WORK/linked/.git"
run --roots "$WORK/linked"
assert_equals "exits 1" "$RC" "1"
assert_empty "and prints no roots aimed at the victim" "$OUT"
assert_contains "names the repointing" "$ERR" "repointed"
cp "$WORK/dotgit.bak" "$WORK/linked/.git"

echo "test: --roots REFUSES a .git replaced by a SYMLINK to another repo's git dir"
# The same steer with no file content written at all — pwd -P canonicalises straight through.
rm -f "$WORK/linked/.git"
ln -s "$VOWN" "$WORK/linked/.git"
run --roots "$WORK/linked"
assert_equals "exits 1" "$RC" "1"
assert_empty "and prints no roots" "$OUT"
assert_contains "names the repointing" "$ERR" "repointed"
rm -f "$WORK/linked/.git"
cp "$WORK/dotgit.bak" "$WORK/linked/.git"
run --roots "$WORK/linked"
assert_equals "and the honest worktree still passes once restored" "$RC" "0"

echo "test: --roots ignores GIT_DIR in the environment, which steers git with no file write"
# Needs no sandbox bypass and no write anywhere: spawn.sh and worker-resume.sh inherit the
# orchestrator's environment, and worker-resume.sh re-runs --roots at resume time.
run_env "GIT_DIR=$VOWN" --roots "$WORK/linked"
assert_equals "exit 0 — answers for the worktree, not for what GIT_DIR names" "$RC" "0"
assert_contains "roots stay on the real repo" "$OUT" "$(cd "$REPO/.git" && pwd -P)/objects"
case "$OUT" in
    *vrepo*) no "GIT_DIR steered the roots at the victim repo" ;;
    *) ok "no victim path anywhere in the roots" ;;
esac

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
