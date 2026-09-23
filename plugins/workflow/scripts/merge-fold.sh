#!/usr/bin/env bash
#
# Deterministic merge fold — the model-free half of the merge stage.
#
#   merge-fold.sh <base-branch> <branch> [branch ...]
#
# Run from inside the worktree that has <base-branch> checked out. Folds each
# branch into the base IN THE GIVEN ORDER, testing every step with
# `git merge-tree --write-tree` before touching the working tree, and sets aside
# the ones that conflict. Prints one line per branch plus a summary:
#
#   merged   <branch> <sha>            merged cleanly (or was already merged)
#   conflict <branch> <path,path,...>  set aside — needs a merger agent
#   unknown  <branch>                  no such local branch; skipped, fold continues
#   summary  merged=<n> conflicted=<k>
#
# Exit 0 whenever the fold ran, conflicts included — a remainder is expected
# output, not an error. Exit 1 only on a usage or repo error.
#
# WHY A FOLD AND NOT A FILTER. Conflict-freeness is relative to the ACCUMULATING
# base, not to the original one: two branches can each merge cleanly into base and
# cleanly against each other, and still conflict once a third has landed. Testing
# every branch against the untouched base and then merging the whole "clean set"
# would silently corrupt exactly those cases. So each test runs against the
# CURRENT HEAD, after everything before it has landed.
#
# WHY IT EXISTS. Merging used to spawn an opus merger agent for the whole queue,
# including the branches that merge without any conflict at all — the expensive
# model on the common path. `git merge-tree` decides that question exactly, for
# free, with no test run and no working-tree write. Only the remainder needs a
# model. That remainder's SIZE is also the number that decides whether one merger
# session or two is cheaper (see the orchestrate skill's merge stage).
#
# The caller runs the project's done-check ONCE after the fold — not per merge.
# Nothing here runs tests.

set -u

die() { printf 'merge-fold: %s\n' "$1" >&2; exit 1; }

[ "$#" -ge 2 ] || die "usage: merge-fold.sh <base-branch> <branch> [branch ...]"

git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"

base="$1"; shift

current="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ "$current" = "$base" ] || die "base branch '$base' is not checked out here (on '$current') — run this in the worktree that holds it"

merged=0
conflicted=0

for b in "$@"; do
    if ! git rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1; then
        printf 'unknown %s\n' "$b"
        continue
    fi

    # Dry-run the merge against the CURRENT head. No working-tree write, no tests.
    if out="$(git merge-tree --write-tree HEAD "$b" 2>&1)"; then
        # Clean per merge-tree — do the real merge. --no-ff keeps one commit per
        # issue branch so a bad slice stays revertible on its own.
        if git merge --no-ff --no-edit "$b" >/dev/null 2>&1; then
            printf 'merged %s %s\n' "$b" "$(git rev-parse HEAD)"
            merged=$((merged + 1))
        else
            # merge-tree said clean and the real merge still failed (a hook, an
            # unmerged index, a dirty tree). Never leave a half-merge behind.
            git merge --abort >/dev/null 2>&1 || true
            printf 'conflict %s <merge-failed-after-clean-dry-run>\n' "$b"
            conflicted=$((conflicted + 1))
        fi
    else
        # Conflict. The `<mode> <oid> <stage>\t<path>` lines are git's stable
        # machine format; the prose "CONFLICT (...)" messages are not.
        paths="$(printf '%s\n' "$out" \
            | sed -n 's/^[0-7]\{6\} [0-9a-f]\{7,\} [123]'"$(printf '\t')"'//p' \
            | sort -u | paste -sd, -)"
        [ -n "$paths" ] || paths="<paths-unavailable>"
        printf 'conflict %s %s\n' "$b" "$paths"
        conflicted=$((conflicted + 1))
    fi
done

printf 'summary merged=%d conflicted=%d\n' "$merged" "$conflicted"
