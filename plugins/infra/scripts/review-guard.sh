#!/usr/bin/env bash
#
# review-guard.sh — run the reviewer, unless there is nothing for it to review.
#
# Usage (from the review checkout):
#   bash review-guard.sh <base-sha> <reviewer argv...>
#
# A branch with no commits past its base has nothing to review, and asking the reviewer anyway
# makes it report "no commits to review" as a finding — which the capped merge turns into a
# follow-up issue for an empty slice (#26 -> #27). But an empty branch is NOT a clean verdict
# either: a worker that reported built and committed nothing (forgot to, a hook rejected it,
# reset its branch) would fold as merged and close its issue with nothing built. So this exits
# 3 with the reason on stderr and no verdict: the wrapper records no review, worker-report.sh
# refuses the report, and handle-report.sh holds the slice for a human. Fails open the other
# way: a base that does not resolve runs the real review. The reviewer's stdout and exit code
# are this script's. spawn.sh's wrapper and worker-resume.sh both run it, so the two can never
# review differently.

set -uo pipefail
[ $# -ge 2 ] || { echo "usage: review-guard.sh <base-sha> <reviewer argv...>" >&2; exit 1; }
if [ "$(git rev-list --count "$1..HEAD" 2>/dev/null)" = 0 ]; then
    echo "no commits past its base — the slice reported built but nothing is committed to review" >&2
    exit 3
fi
shift
exec "$@"
