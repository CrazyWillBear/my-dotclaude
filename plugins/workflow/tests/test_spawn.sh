#!/usr/bin/env bash
#
# Tests for scripts/spawn.sh — the worker session command for one issue.
#
# Every assertion here is about a way an unattended session dies quietly: a name
# without the run prefix (one run stops another's workers), a permission mode that
# deadlocks on the first prompt, a denylist that lets a worker merge or close, a
# denylist so wide the worker cannot comment on its own issue, or a prompt that
# forgets to say "report with SendMessage" — after which the orchestrator waits
# forever for output that was never addressed to it.
#
# Run: bash plugins/workflow/tests/test_spawn.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/spawn.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }
# the arg list is one-per-line, so an exact-line match is a real "this arg is present"
assert_arg() { if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else no "$1 (no arg line '$3')"; fi; }

dry() { bash "$SPAWN" "$@" --dry-run --orchestrator orch-main 2>"$WORK/err"; }
err() { cat "$WORK/err"; }

# ---------------------------------------------------------------------------
echo "test: the command carries the run-prefixed name and the tier's roster"
out=$(dry 20260906-101500 12 standard /w/issue-12 orchestrate-20260906)
assert_arg "background" "$out" "--bg"
assert_arg "run-prefixed session name" "$out" "orch-20260906-101500-issue-12"
assert_arg "standard tier -> sonnet implementer" "$out" "sonnet"
out_c=$(dry 20260906-101500 12 complex /w/issue-12 orchestrate-20260906)
assert_arg "complex tier -> opus implementer" "$out_c" "opus"
assert_not_contains "and not the standard model" "$(printf '%s\n' "$out_c" | grep -A1 -- '--model')" "sonnet"

echo "test: an unattended session never comes up able to prompt"
assert_arg "bypassPermissions" "$out" "bypassPermissions"
assert_arg "--add-dir the worktree" "$out" "/w/issue-12"

echo "test: the denylist keeps the irreversible writes on the main thread"
assert_arg "no git merge" "$out" "Bash(git merge:*)"
assert_arg "no git worktree" "$out" "Bash(git worktree:*)"
assert_arg "no gh pr" "$out" "Bash(gh pr:*)"
assert_arg "no gh issue close" "$out" "Bash(gh issue close:*)"
assert_arg "no gh issue edit" "$out" "Bash(gh issue edit:*)"

echo "test: push and issue comment stay ALLOWED — the thread is the bus"
assert_not_contains "push not denied" "$out" "Bash(git push"
assert_not_contains "comment not denied" "$out" "Bash(gh issue comment"

echo "test: the prompt tells the worker plain output is invisible"
assert_contains "names SendMessage" "$out" "SendMessage"
assert_contains "says output is invisible" "$out" "INVISIBLE"
assert_contains "addresses the orchestrator by name" "$out" '"orch-main"'
assert_contains "fixed-shape status line" "$out" "issue 12 built head="

echo "test: the build prompt carries the load-bearing protocol"
assert_contains "reads the issue comments first" "$out" "--comments"
assert_contains "posts the tackled comment" "$out" "Tackled #12"
assert_contains "commit per green sub-step is framed as RECOVERY" "$out" "COMMIT AFTER EVERY GREEN SUB-STEP"
assert_contains "spawns my-review itself" "$out" "personal-tools:my-review"
assert_contains "does not fix its own findings" "$out" "a fresh session does that"
assert_contains "context map is a hint" "$out" "CONTEXT-MAP.md"
assert_contains "escalation path" "$out" "escalate"

echo "test: --role fix is a fresh session working from the review comment"
out=$(dry 20260906-101500 12 standard /w/issue-12 orchestrate-20260906 --role fix --round 2)
assert_contains "says which round" "$out" "FIX ROUND 2"
assert_contains "did not write this code" "$out" "You did not write this code"
assert_contains "reads the review comment" "$out" "Review round"
assert_contains "reports the round back" "$out" "round=2"
assert_not_contains "does not re-post the tackled comment" "$out" "Tackled #12"

echo "test: --orchestrator resolves from this session when omitted"
out=$(bash "$SPAWN" r1 12 standard /w/issue-12 base --dry-run 2>"$WORK/err"); rc=$?
if [ "$rc" -eq 0 ]; then
    assert_contains "resolved a name" "$out" "SendMessage"
else
    assert_contains "or fails LOUD — a worker with no address reports into the void" \
        "$(err)" "pass --orchestrator NAME"
fi

# ---------------------------------------------------------------------------
echo "test: bad input fails loud instead of spawning something wrong"
bash "$SPAWN" r1 >/dev/null 2>"$WORK/err"; assert_equals "too few args exits 1" "$?" "1"
assert_contains "prints usage" "$(err)" "usage:"
dry r1 twelve standard /w base >/dev/null; assert_equals "non-numeric issue exits 1" "$?" "1"
dry r1 12 standard /w base --role sideways >/dev/null; assert_equals "bad role exits 1" "$?" "1"
dry r1 12 standard /w base --bogus >/dev/null; assert_equals "unknown flag exits 1" "$?" "1"
assert_contains "names the flag" "$(err)" "unknown flag"

echo "test: an unknown tier still spawns — resolve-tier.sh falls back to standard"
out=$(dry r1 12 nonsense /w/issue-12 base); assert_arg "fallback roster" "$out" "sonnet"

echo "test: a real spawn refuses a worktree that does not exist"
bash "$SPAWN" r1 12 standard "$WORK/nope" base --orchestrator orch-main >/dev/null 2>"$WORK/err"
assert_equals "exits 1" "$?" "1"
assert_contains "says which path" "$(err)" "worktree does not exist"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
