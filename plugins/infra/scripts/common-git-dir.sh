#!/usr/bin/env bash
#
# common-git-dir.sh — a worktree's CANONICAL common git dir, and the narrowed set of
# writable roots a codex worker needs inside it.
#
# `-s workspace-write` keeps `.git` READ-ONLY, and for a LINKED worktree the objects and
# refs live in the MAIN repo's common git dir. Without those paths in
# `sandbox_workspace_write.writable_roots`, a codex worker does the entire issue and only
# then discovers it cannot commit — reporting that fact in its final message, after the
# work is done and unsaved.
#
# WHY NARROWED, not the whole common dir. That dir also holds `hooks/` and `config`, which
# git EXECUTES: a worker that writes `hooks/pre-commit`, or sets `core.sshCommand` in
# `config`, gets code execution on the host the next time ANYONE runs git in that repo —
# another worker, the merge, or the user in their own checkout. Worktrees isolate working
# FILES; they all share one `.git`. Granting the whole dir is what made that reachable.
#
# Verified on codex-cli 0.154 (2026-09-16), ground-truthed from outside the sandbox on a
# real ~/code path (NOT under /tmp, which workspace-write allows by default and which
# silently voids this kind of test):
#   * with roots narrowed to the set below, a commit still succeeds;
#   * `.git/hooks/pre-commit` and a canary outside the project are BLOCKED.
#
# This is ONE script rather than a copy in each caller because spawn.sh and
# worker-resume.sh must produce the IDENTICAL value: a resume that resolved it even
# slightly differently would hand the worker a different writable root than the spawn did,
# and the failure is silent until the worker cannot commit.
#
# Usage:
#   bash common-git-dir.sh <worktree>            # the canonical common git dir
#   bash common-git-dir.sh --roots <worktree>    # a TOML array for writable_roots
#
# `--roots` requires a LINKED worktree and REFUSES anything else, including the main
# working tree of a repo that has them — see the branch below for why.
# Exit: 0 with the value, or 1 with a reason on stderr and nothing on stdout.

set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }

MODE=dir
if [ "${1:-}" = "--roots" ]; then MODE=roots; shift; fi

WORKTREE="${1:-}"
[ -n "$WORKTREE" ] || die "usage: common-git-dir.sh [--roots] <worktree>"
[ -d "$WORKTREE" ] || die "worktree does not exist: $WORKTREE"

GITDIR="$(git -C "$WORKTREE" rev-parse --git-common-dir 2>/dev/null)" \
    || die "not a git worktree, so a codex worker could never commit: $WORKTREE"
# `--git-common-dir` answers relative to the worktree for a plain repo (".git") and
# absolute for a linked one, so normalise before resolving.
case "$GITDIR" in /*) ;; *) GITDIR="$WORKTREE/$GITDIR" ;; esac
GITDIR="$(cd "$GITDIR" 2>/dev/null && pwd -P)" \
    || die "could not resolve the repo's common git dir for: $WORKTREE"

if [ "$MODE" = dir ]; then
    printf '%s\n' "$GITDIR"
    exit 0
fi

# The worktree's OWN git dir. For a linked worktree that is <common>/worktrees/<name>,
# holding this worktree's HEAD, index and COMMIT_EDITMSG — all written by a commit.
OWN="$(git -C "$WORKTREE" rev-parse --git-dir 2>/dev/null)" \
    || die "cannot resolve the git dir for: $WORKTREE"
case "$OWN" in /*) ;; *) OWN="$WORKTREE/$OWN" ;; esac
OWN="$(cd "$OWN" 2>/dev/null && pwd -P)" \
    || die "could not resolve this worktree's own git dir for: $WORKTREE"

if [ "$OWN" = "$GITDIR" ]; then
    # NOT a linked worktree. Two shapes land here: a plain repo, and the MAIN working tree
    # of a repo that HAS linked worktrees — i.e. the user's own checkout, whose .git every
    # sibling worktree shares. Both keep HEAD, index and COMMIT_EDITMSG directly in the
    # common dir, so granting what a commit needs means granting hooks/ and config too:
    # exactly the host-code-execution escape this script exists to close. Refusing is not
    # a limitation, it is the point — every real worker runs in a linked worktree, and
    # handing back a silently WIDE root for the user's own checkout would be the worst
    # case of all. Fail loud, like every other refusal here.
    die "a codex worker must run in a LINKED worktree; refusing to grant the whole common git dir for: $WORKTREE
  remedy: create one with \`git worktree add <path>\` and point the worker at that path. A
  resume must be handed the SAME worktree its spawn used, or it runs with different roots."
fi

# $GITDIR came from `git rev-parse --git-common-dir` — EXACTLY the value that `commondir`,
# a file inside the writable $OWN, redirects (gitrepository-layout(5)). So a worker that
# rewrites it during its turn steers THIS script: the roots below would be built against a
# different repository, and the next spawn or resume would hand that worker write access to
# that repo's objects, refs and logs — the user's own checkout included. Reproduced
# 2026-09-17: rewriting commondir moved every root except $OWN onto an unrelated repo, at
# exit 0, with nothing on stderr.
#
# An honest linked worktree ALWAYS has its own git dir at <common>/worktrees/<name>, so
# requiring that refuses the rewritten shape and nothing else. This closes the
# roots-steering half of the commondir residual. The other half — git run by a human IN
# that worktree still follows the rewritten commondir to a planted config — is not closed
# by this and stays the accepted residual (docs/swarm-design.md § Roster).
case "$OWN" in
    "$GITDIR"/worktrees/*) ;;
    *) die "this worktree's own git dir is not inside the common git dir it names, so commondir has been rewritten: $WORKTREE
  its git dir:  $OWN
  commondir says: $GITDIR
  remedy: do not reuse this worktree — discard it. A worker that rewrote commondir was
  trying to steer the sandbox at another repository." ;;
esac

# `config.worktree` lives INSIDE $OWN, and when extensions.worktreeConfig is enabled git
# reads it in addition to the shared config — so core.sshCommand, core.hooksPath or
# core.fsmonitor written there is host code execution the next time anyone runs git in
# this worktree, which the merge step and the user both do. A worker cannot switch the
# extension on itself (the shared config is not writable), but a repo that already uses it
# is exposed, and `git sparse-checkout set` turns it on by itself. $OWN cannot be narrowed
# further without losing HEAD/index, so refuse instead.
if [ "$(git -C "$WORKTREE" config --bool --get extensions.worktreeConfig 2>/dev/null)" = "true" ]; then
    die "extensions.worktreeConfig is enabled, so a writable config.worktree would be host code execution: $WORKTREE
  remedy: run the worker in a repo that does not use worktree-specific config, or unset it with
  \`git config --unset extensions.worktreeConfig\` AND delete the leftover config.worktree —
  unsetting alone leaves the file, which the next check refuses on its own. Note that
  \`git sparse-checkout set\` turns the extension back on by itself."
fi

# The check above is POINT-IN-TIME and cannot be otherwise: it proves the extension is off NOW,
# not that it stays off. $OWN is writable, so a worker can plant a DORMANT config.worktree that
# arms the moment anyone enables the extension later — and `git sparse-checkout set` enables it
# without being asked. A file that is already there is the half we can actually see, so refuse
# it rather than grant a root that contains a loaded payload.
if [ -e "$OWN/config.worktree" ]; then
    die "a config.worktree is already present in this worktree's git dir and would arm if extensions.worktreeConfig were ever enabled: $OWN/config.worktree
  remedy: delete the file if it was not put there deliberately. On a RESUME that is the only
  remedy — a resume must be handed the same worktree its spawn used, so \"use a different
  worktree\" is not available there. This is a point-in-time check: it cannot see a file
  planted after the worker starts."
fi

# objects + refs: where the commit and the branch tip land.
# logs:           reflog updates for those refs.
# $OWN:           this worktree's HEAD/index/COMMIT_EDITMSG.
# Never the SHARED hooks/ or config — the two things git executes.
printf '["%s/objects","%s/refs","%s/logs","%s"]\n' "$GITDIR" "$GITDIR" "$GITDIR" "$OWN"
