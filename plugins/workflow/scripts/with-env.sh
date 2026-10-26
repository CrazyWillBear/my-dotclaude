#!/usr/bin/env bash
#
# with-env.sh — run a command with the env pairs provisioned for one or more issues.
#
# Usage:
#   bash with-env.sh <runid> <N>[,<N>...] -- <command> [args...]
#
# The pairs a human gave a worker (`handle-report.sh --resource N --env K=V`) live NUL-
# delimited in <run dir>/issue-N/env. The workers get them from spawn.sh; the merger's
# done-check gets them from here — without it a merge gate skips every DB test and e2e the
# workers ran, and a bad conflict resolution lands green. Pairs of several issues are
# merged, a later issue winning a repeated name; an issue with none contributes nothing.
#
# The values are EXPORTED, never put in any argv, and never printed: this script and the
# model that calls it see only names. The command's exit code is this script's.

set -uo pipefail
# shellcheck source=run-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-env.sh"

USAGE="usage: with-env.sh <runid> <N>[,<N>...] -- <command> [args...]"
[ $# -ge 4 ] && [ "$3" = -- ] || die "$USAGE"
load_run "$1"
ISSUES="$2"; shift 3
for n in ${ISSUES//,/ }; do
    case "${n#\#}" in ''|*[!0-9]*) die "issues must be numbers, got '$n'" ;; esac
    [ -f "$(issue_dir "${n#\#}")/env" ] || continue
    while IFS= read -r -d '' pair; do export "$pair"; done <"$(issue_dir "${n#\#}")/env"
done
exec "$@"
