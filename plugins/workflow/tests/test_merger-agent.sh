#!/usr/bin/env bash
#
# Tests for agents/merger.md — the /orchestrate merger agent prose.
#
# The agent is prose — not executable code — so we validate its frontmatter pins
# and the output contract orchestrate's MERGE_SCHEMA reads:
#
#   1. File exists at the expected discovery path.
#   2. Frontmatter pins name: merger, model: opus, and effort: xhigh.
#      orchestrate's merger spawn passes no explicit model or effort, so this
#      pin governs outright. The merger is never tier-routed: it is the single
#      serial worker draining orchestrate's merge queue, and a bad conflict
#      resolution corrupts the base branch for every issue in the run — so it
#      never gets a cheap model.
#   3. The per-issue output line carries the MERGE COMMIT SHA. MERGE_SCHEMA
#      requires it and the main thread quotes it in the close comment ("Merged in
#      <mergeCommit>"); an output contract that never asks for it leaves schema
#      coercion to invent one.
#
# Run: bash plugins/workflow/tests/test_merger-agent.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_FILE="$PLUGIN_ROOT/agents/merger.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
echo "test: agent file exists at the expected discovery path"
if [ -f "$AGENT_FILE" ]; then
    ok "merger.md present at agents/merger.md"
else
    no "merger.md missing at $AGENT_FILE"
fi

content=""
if [ -f "$AGENT_FILE" ]; then
    content="$(cat "$AGENT_FILE")"
fi

# ---------------------------------------------------------------------------
echo "test: frontmatter pins name: merger, model: opus, effort: xhigh"
assert_contains "name field present" "$content" "name: merger"
assert_contains "model pinned to opus" "$content" "model: opus"
assert_not_contains "cheap merger model is gone" "$content" "model: sonnet"
assert_not_contains "model: inherit is gone" "$content" "model: inherit"
assert_contains "effort pinned to xhigh" "$content" "effort: xhigh"

# ---------------------------------------------------------------------------
echo "test: the output contract asks for the merge commit sha (MERGE_SCHEMA needs it)"
assert_contains "merge commit sha requested per issue" "$content" "merge commit sha"
assert_contains "the sha is read off the base branch" "$content" "rev-parse HEAD"

# ---------------------------------------------------------------------------
# The merger continues through the batch after a stop ("After all merges" runs
# regardless), so ONE batch can stop on SEVERAL issues. MERGE_SCHEMA therefore reads
# `conflictStops` as a LIST — and each entry must carry the WORKTREE PATH, or the report
# cannot tell the user where to go look.
#
# The previous assertion here just grepped the word "conflict-stop", which this file
# already contained before the feature existed: it passed with the feature deleted. These
# are anchored on the behaviour they name.
echo "test: the merger reports ALL conflict-stops in a batch, each with its worktree"
assert_contains "every stop is reported, not just the first" "$content" "report **all** of them"
assert_contains "a stop carries the worktree path to look in" "$content" "its worktree path"
assert_contains "a stop carries its reason" "$content" "the reason (unresolvable, or red"
assert_contains "an unverified resolution is never kept" "$content" "Never keep an unverified resolution"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
