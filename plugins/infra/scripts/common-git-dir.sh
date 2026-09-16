#!/usr/bin/env bash
#
# common-git-dir.sh — print a worktree's CANONICAL common git dir, or die loudly.
#
# `-s workspace-write` keeps `.git` READ-ONLY, and for a LINKED worktree the objects and
# refs live in the MAIN repo's common git dir. Without that path in
# `sandbox_workspace_write.writable_roots`, a codex worker does the entire issue and only
# then discovers it cannot commit — reporting that fact in its final message, after the
# work is done and unsaved.
#
# This is ONE script rather than a copy in each caller because spawn.sh and
# worker-resume.sh must produce the IDENTICAL value. A resume that resolved it even
# slightly differently — skipping `pwd -P`, or not dying when the `cd` fails and passing
# `writable_roots=[""]` — would hand the resumed worker a different writable root than the
# spawn gave it, and the failure is silent until the worker cannot commit.
#
# Usage:  bash common-git-dir.sh <worktree>
# Output: the absolute, symlink-resolved path on stdout.
# Exit:   0 with the path, or 1 with a reason on stderr and nothing on stdout.

set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }

WORKTREE="${1:-}"
[ -n "$WORKTREE" ] || die "usage: common-git-dir.sh <worktree>"
[ -d "$WORKTREE" ] || die "worktree does not exist: $WORKTREE"

GITDIR="$(git -C "$WORKTREE" rev-parse --git-common-dir 2>/dev/null)" \
    || die "not a git worktree, so a codex worker could never commit: $WORKTREE"
# `--git-common-dir` answers relative to the worktree for a plain repo (".git") and
# absolute for a linked one, so normalise before resolving.
case "$GITDIR" in /*) ;; *) GITDIR="$WORKTREE/$GITDIR" ;; esac
GITDIR="$(cd "$GITDIR" 2>/dev/null && pwd -P)" \
    || die "could not resolve the repo's common git dir for: $WORKTREE"

printf '%s\n' "$GITDIR"
