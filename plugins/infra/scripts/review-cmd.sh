#!/usr/bin/env bash
#
# review-cmd.sh — print the INDEPENDENT reviewer's argv, one argument per line.
#
# WHY THIS IS ITS OWN SCRIPT. Two callers run the reviewer — spawn.sh after a build or
# fix round, worker-resume.sh after an answered escalation — and they must run the SAME
# command. This is the identical argument common-git-dir.sh makes for --roots: a second
# copy is the half that silently rots, and here the rot is invisible, because a review at
# the wrong model still produces a confident, well-formatted verdict.
#
# WHY A REVIEWER RUNS AT ALL, SEPARATELY. A codex worker used to be told to review its own
# diff with `codex exec review`. That call is NESTED inside the worker's own sandbox and
# always fails — "failed to initialize in-process app-server client: Read-only file system
# (os error 30)", because ~/.codex is not among its writable_roots. #96's e2e gate caught
# what the worker did next: it substituted its own judgement of its own diff and reported
# a clean review, indistinguishable downstream from one that really ran. Running the
# reviewer as a SIBLING process fixes both halves — a top-level codex invocation is inside
# nobody's sandbox, and the verdict never passes through the thing that wrote the code.
#
# Usage:
#   bash review-cmd.sh <tier> <worktree> <base-branch>
#
# Output: the argv, ONE ARGUMENT PER LINE, on stdout; nothing on stdout on failure.
# Exit 0 = a command was printed. Exit 1 = it could not be built, loud on stderr.
#
# One-per-line is only sound because every argument is single-line, the prompt included.
# Keep it that way: a newline inside an argument would split it into two, and the caller
# would hand codex a truncated prompt with the remainder as a stray positional. A NUL
# encoding would lift that restriction but needs `mapfile -d ''`, which is bash 4+ — and
# README.md and AGENT_SETUP.md both promise macOS, whose system bash is 3.2.

set -uo pipefail

INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "error: $*" >&2; exit 1; }

TIER="${1:-}"
WORKTREE="${2:-}"
BASE="${3:-}"
[ -n "$TIER" ] && [ -n "$WORKTREE" ] && [ -n "$BASE" ] \
    || die "usage: review-cmd.sh <tier> <worktree> <base-branch>"

[ -f "$INFRA/resolve-tier.sh" ] || die "missing infra sibling: $INFRA/resolve-tier.sh"
ROSTER="$(bash "$INFRA/resolve-tier.sh" "$TIER" 2>/dev/null)"
REVIEWER_MODEL="$(printf '%s\n' "$ROSTER" | sed -n 's/^reviewer_model=//p' | head -1)"
REVIEWER_BACKEND="$(printf '%s\n' "$ROSTER" | sed -n 's/^reviewer_backend=//p' | head -1)"

# `-m` only for a CODEX reviewer cell. A claude-backed cell — every row of the SHIPPED
# table — names opus or sonnet, which codex does not have, so passing it would make the
# review die outright. Leaving the flag off takes codex's default model instead: weaker
# than the tier asked for, but a review that errors out is no review at all, and that
# fails the whole run closed at worker-report.sh.
set -- codex exec review \
    -C "$WORKTREE" \
    --base "$BASE" \
    -c "approval_policy=never" \
    -c "sandbox_workspace_write.network_access=true"
if [ "$REVIEWER_BACKEND" = codex ] && [ -n "$REVIEWER_MODEL" ]; then
    set -- "$@" -m "$REVIEWER_MODEL"
fi

# The trailing PROMPT is what makes the verdict machine-readable. `codex exec review`
# writes prose, and parsing prose for a finding count is how a "0 high" gets invented out
# of a sentence that merely contains the word. Demanding one exact final line means
# worker-report.sh either finds that line or says it does not know — never a cheerful
# default. KEEP THIS WORDING AND worker-report.sh's COUNTS REGEX IN STEP.
set -- "$@" "Review this branch's diff against $BASE. Report every finding with its file and line, graded high / medium / low. Then, as the LAST line of your output and nothing after it, print exactly: 'COUNTS: <H> high, <M> medium, <L> low', with the three integers being how many findings you graded at each level. Print that line even when you found nothing, as: 'COUNTS: 0 high, 0 medium, 0 low'."

printf '%s\n' "$@"
