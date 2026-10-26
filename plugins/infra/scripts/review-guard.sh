#!/usr/bin/env bash
#
# review-guard.sh — run the reviewer, unless there is nothing for it to review.
#
# Usage (from the review checkout):
#   bash review-guard.sh <base-sha> <reviewer argv...>
#
# A branch with no commits past its base (a deliberately empty slice) gets the clean verdict
# review-counts.sh reads, without starting a reviewer. Asked anyway, the reviewer reports "no
# commits to review" as a finding, and the capped merge files a follow-up issue for an empty
# slice. Fails open: a base that does not resolve runs the real review. The reviewer's stdout
# and exit code are this script's. spawn.sh's wrapper and worker-resume.sh both run it, so the
# two can never review differently.

set -uo pipefail
[ $# -ge 2 ] || { echo "usage: review-guard.sh <base-sha> <reviewer argv...>" >&2; exit 1; }
if [ "$(git rev-list --count "$1..HEAD" 2>/dev/null)" = 0 ]; then
    echo "No findings."
    exit 0
fi
shift
exec "$@"
