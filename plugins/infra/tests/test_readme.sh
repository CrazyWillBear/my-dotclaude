#!/usr/bin/env bash
#
# Tests for README.md — infra's own prose, since the SKILL.md trim (see
# workflow/tests/test_orchestrate-skill.sh) moved the spawn protocol, the bus, and the
# liveness/recovery procedure here with no coverage following them.
#
# This is prose, so these are grep tests: they can only prove a STRING DESCRIBING the
# behavior is present. The state table and session-status.sh's own flags are pinned by
# test_session-status.sh; spawn.sh's flags by test_spawn.sh. What's covered here is the
# recovery procedure itself, which is only ever written down, never executed by a script:
# never `rm`, never spawn onto a still-live worktree, bounded-wait-then-escalate, respawn
# once, the trivial-tier exclusion from the expected-session list, and never parse
# `claude logs`.
#
# Run: bash plugins/infra/tests/test_readme.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
README_FILE="$PLUGIN_ROOT/README.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_matches()  { if printf '%s\n' "$2" | grep -Eqi -- "$3"; then ok "$1"; else no "$1 (no match: $3)"; fi; }

if [ ! -f "$README_FILE" ]; then
    printf '  FAIL: README.md missing at %s\n' "$README_FILE"
    exit 1
fi
BODY="$(cat "$README_FILE")"

echo "test: recovery"
assert_matches "commit per green sub-step is the recovery mechanism" "$BODY" "recovery mechanism.{0,2}, not hygiene"
assert_matches "never rm — it deletes the worktree" "$BODY" "Never .?rm"
assert_matches "never spawn onto a live worktree" "$BODY" "still listed alive"
assert_matches "respawn once, escalate on the second" "$BODY" "[Rr]espawn once"
assert_matches "a stop may not take" "$BODY" "acknowledged and not take"
assert_matches "the wait is bounded" "$BODY" "wait.{0,10}bounded|timeout 60"
assert_matches "and it escalates rather than respawning blindly" "$BODY" "do not respawn"
assert_contains "the count comes from the run log" "$BODY" "run-log.sh"

echo "test: a respawned issue has several rows — match on state, not the name"
assert_matches "warns about multiple rows per issue" "$BODY" "several rows|One issue can have"
assert_matches "says to match on state" "$BODY" "Match on state, never on the name"

echo "test: liveness"
assert_matches "blocked means a permission wedge" "$BODY" "permission wedge"
assert_matches "never parse claude logs" "$BODY" "Never parse .?claude logs"

echo "test: trivial issues are excluded from the expected-session list"
assert_matches "says trivial issues have no session" "$BODY" "Expect only the issues that actually have a session"

echo "test: run-log.sh is flagged as the orchestrator's script, not infra's"
# It's still the correct call (CLAUDE_PLUGIN_ROOT resolves under whichever skill is
# running the recovery procedure, i.e. the orchestrator's), but infra's own scripts/
# has no run-log.sh, so an unqualified reference here reads like infra's own script.
note_count=$(printf '%s' "$BODY" | grep -c "not infra's")
if [ "$note_count" -ge 2 ]; then
    ok "run-log.sh's foreign origin is noted at both call sites ($note_count)"
else
    no "run-log.sh's foreign origin noted only $note_count/2 times"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
