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
#   bash review-cmd.sh <tier> <base-sha> <out-file>
#
#     <base-sha>     what the review diffs against. A SHA, NOT a branch name — see below.
#     <out-file>     where codex writes its final message (the review itself)
#
# Output: the argv, ONE ARGUMENT PER LINE, on stdout; nothing on stdout on failure.
# Exit 0 = a command was printed. Exit 1 = it could not be built, loud on stderr.
#
# ── THE THREE THINGS THIS ARGV GETS RIGHT, EACH VERIFIED AGAINST codex-cli 0.155.0 ──
#
# NO `-C`. `codex exec review` does not take it — only the top-level `codex exec` does;
# passing it dies with "unexpected argument '-C' found". Both callers `cd` into the
# worktree before running this, which is what scopes the review.
#
# NO TRAILING PROMPT, AND NO --output-schema. `--base` and `[PROMPT]` are MUTUALLY
# EXCLUSIVE — "the argument '--base <BRANCH>' cannot be used with '[PROMPT]'" — so the
# verdict's shape cannot be requested in prose. `--output-schema` was the obvious
# substitute and it DOES NOT WORK: codex accepts the flag on a review turn and ignores it.
# Ground-truthed twice — a real run on ops-os issue #28 returned prose where the schema was
# required, and a direct probe here returned prose again with `--json` showing no
# structured findings event either (only an `agent_message` carrying the same text).
# Passing a flag that silently does nothing is worse than not passing it: it reads as a
# guarantee that is not there.
#
# So the REVIEW'S OWN OUTPUT FORMAT is the contract, and it is a stable one — it is codex's
# review template, not something a prompt asked for. Verified shapes:
#   findings   `- [P1] <title> — <path>:<lines>` list items, one per finding
#   clean      ordinary prose, exit 0, no `[Pn]` marker anywhere
# worker-report.sh counts those markers (P0/P1 high, P2 medium, P3+ low) and REFUSES
# anything it cannot read that way, so a drift in this format costs a run rather than
# inventing a clean verdict.
#
# A SHA, NOT A BRANCH NAME. The worker can write `refs/` (it is a granted writable root —
# common-git-dir.sh --roots), so a worker that ran `git branch -f <base> HEAD` would empty
# its own diff and an HONEST reviewer would return a clean verdict. Resolving the base to
# a commit BEFORE the worker starts and reviewing against that SHA closes the door: moving
# a ref afterwards changes nothing the reviewer looks at. `--base` is documented as
# <BRANCH> but accepts a SHA — verified: codex echoes "changes against '<sha>'" and
# proceeds. This is the second way a worker could have graded its own diff.

set -uo pipefail

INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "error: $*" >&2; exit 1; }

TIER="${1:-}"
BASE_SHA="${2:-}"
OUTFILE="${3:-}"
[ -n "$TIER" ] && [ -n "$BASE_SHA" ] && [ -n "$OUTFILE" ] \
    || die "usage: review-cmd.sh <tier> <base-sha> <out-file>"

# A branch name here would silently reintroduce the movable-base hole above, and the
# callers resolve it themselves, so anything that is not a hex object name is a caller bug.
case "$BASE_SHA" in
    *[!0-9a-f]*|"") die "base must be a resolved SHA, not a ref: '$BASE_SHA'" ;;
esac
[ "${#BASE_SHA}" -ge 7 ] || die "base sha is too short to be unambiguous: '$BASE_SHA'"

[ -f "$INFRA/resolve-tier.sh" ] || die "missing infra sibling: $INFRA/resolve-tier.sh"
ROSTER="$(bash "$INFRA/resolve-tier.sh" "$TIER" 2>/dev/null)"
REVIEWER_MODEL="$(printf '%s\n' "$ROSTER" | sed -n 's/^reviewer_model=//p' | head -1)"
REVIEWER_BACKEND="$(printf '%s\n' "$ROSTER" | sed -n 's/^reviewer_backend=//p' | head -1)"

# `sandbox_mode=read-only` is PINNED, not inherited. `exec review` takes no `-s`, so
# without this the reviewer runs at whatever the user's ~/.codex/config.toml defaults to —
# and a user configured with `danger-full-access` would run a model reading
# worker-authored, injectable content on the host with approval_policy=never. The reviewer
# writes nothing but its own final message, so read-only costs it nothing. Same `-c`
# override mechanism worker-resume.sh already relies on for the resumed worker's sandbox.
# `-o` is how the review is captured. NOT stdout: that carries codex's own banner and
# progress lines, and the review would have to be fished back out of them.
set -- codex exec review \
    --base "$BASE_SHA" \
    -c "approval_policy=never" \
    -c "sandbox_mode=read-only" \
    -o "$OUTFILE"

# `-m` only for a CODEX reviewer cell. A claude-backed cell — every row of the SHIPPED
# table — names opus or sonnet, which codex does not have, so passing it would make the
# review die outright. Leaving the flag off takes codex's default model instead: weaker
# than the tier asked for, but a review that errors out is no review at all, and that
# fails the whole run closed at worker-report.sh.
if [ "$REVIEWER_BACKEND" = codex ] && [ -n "$REVIEWER_MODEL" ]; then
    set -- "$@" -m "$REVIEWER_MODEL"
fi

printf '%s\n' "$@"
