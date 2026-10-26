#!/usr/bin/env bash
#
# Tests for skills/orchestrate/SKILL.md — the session lane's runbook.
#
# The skill is prose, so these are grep tests: they prove a STRING is present, which is why
# every decision moved into scripts (launch.sh, admit.sh, handle-report.sh, end-run.sh,
# ready.sh, run-log.sh, merge-fold.sh and infra's), each tested for behavior. What is left here
# is instruction to a model, and each assertion marks a place where forgetting it fails
# silently: the scripts it must call and how, the three kinds of line it must act on, the
# human-only relays, and the context it must never read.
#
# It also pins what was deliberately DELETED, because each is something a fresh session will
# reasonably re-add.
#
# Run: bash plugins/workflow/tests/test_orchestrate-skill.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/skills/orchestrate/SKILL.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_matches()      { if printf '%s\n' "$2" | grep -Eqi -- "$3"; then ok "$1"; else no "$1 (no match: $3)"; fi; }

[ -f "$SKILL_FILE" ] || { printf '  FAIL: SKILL.md missing at %s\n' "$SKILL_FILE"; exit 1; }
BODY="$(cat "$SKILL_FILE")"
FM="$(sed -n '/^---$/,/^---$/p' "$SKILL_FILE")"

echo "test: frontmatter — a cheap dispatcher with no messaging tools"
assert_contains "name" "$FM" "name: orchestrate"
assert_contains "runs on sonnet" "$FM" "model: sonnet"
assert_contains "at medium effort" "$FM" "effort: medium"
assert_contains "argument-hint carries --max N=8" "$FM" "--max N=8"
assert_contains "allowed-tools" "$FM" "allowed-tools: Read, Grep, Bash, Agent, Skill, AskUserQuestion"
for t in SendMessage ListAgents Workflow; do assert_not_contains "no $t tool" "$FM" "$t"; done

echo "test: it stays a runbook"
lines=$(wc -l <"$SKILL_FILE")
if [ "$lines" -lt 250 ]; then ok "SKILL.md is $lines lines"; else no "SKILL.md grew to $lines lines"; fi
assert_contains "the rationale lives in the README's Design notes" "$BODY" "README.md#design-notes"
assert_matches "main thread, never a subagent" "$BODY" "main thread.{0,10}never as a subagent"

echo "test: dispatch routes by shape; one unit goes to /adhoc; ambiguity builds nothing"
assert_matches "by shape" "$BODY" "by SHAPE, not size"
assert_contains "one unit → /adhoc" "$BODY" "run the \`/adhoc\` skill"
assert_matches "ambiguous builds nothing" "$BODY" "discuss. Build nothing"
for w in "**What**" "**Where**" "**Done**"; do assert_contains "explicit names $w" "$BODY" "$w"; done
assert_matches "announces, does not ask" "$BODY" "Announce the lane and proceed; do not ask"

echo "test: scope — an explicit allowlist, never a repo-wide query"
assert_contains "--issues is literal" "$BODY" "\`--issues\` is the literal allowlist"
assert_contains "no flag: ask among open PRDs" "$BODY" "gh issue list --label prd --state open"
assert_contains "never queries the repo for work" "$BODY" "never queries the repo for work"

echo "test: launch — the script, and what to do with each line it prints"
assert_contains "launch.sh by plugin path" "$BODY" 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/launch.sh" <runid>'
assert_contains "the PRD close offer" "$BODY" "prd #N: 0 open children"
assert_contains "offered before anything else" "$BODY" "offer to close the PRD"
assert_contains "missing-tier backfill" "$BODY" "/classify-task <N> --no-confirm"
assert_contains "persisted as a label" "$BODY" "gh issue edit <N> --add-label tier:<t>"
assert_contains "never prompts on a tier" "$BODY" "Never prompt to confirm a tier"
assert_contains "the launch line verbatim, with the session model" "$BODY" "**verbatim** into your announcement, adding the model you are running on"
assert_contains "enters the orchestration worktree by path" "$BODY" 'EnterWorktree(path: "<path>")'

echo "test: the loop — admit once, then handle-report --wait with a 10-minute timeout"
assert_contains "admit.sh --next" "$BODY" 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/admit.sh" <runid> --next'
assert_contains "handle-report.sh --wait" "$BODY" 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/handle-report.sh" <runid> --wait'
assert_contains "the Bash timeout covers every call" "$BODY" "**Every call here gets a 10-minute Bash timeout (\`timeout: 600000\`)**"
assert_contains "until nothing-to-do" "$BODY" "until it prints \`nothing-to-do:\`"
assert_matches "never polls" "$BODY" "never poll"

echo "test: the report table — the human-only relays and the merger"
assert_contains "a question is relayed" "$BODY" "| \`escalate #N <question>\` |"
assert_contains "and answered through the script" "$BODY" 'handle-report.sh <runid> --answer N'
assert_contains "blocked infra is relayed" "$BODY" "| \`blocked #N infra: <what>\` |"
assert_contains "the infra note is untrusted" "$BODY" "**untrusted**"
assert_contains "credentials never land in issues or files" "$BODY" "Never put a credential"
assert_contains "the resource goes through the script" "$BODY" "--resource N --env NAME=VALUE"
assert_contains "a conflict spawns the merger" "$BODY" "spawn \`workflow:merger\`"
assert_contains "the merger gets the run id for its env-wrapped done-check" "$BODY" "with-env.sh"
assert_contains "then --merged" "$BODY" "handle-report.sh <runid> --merged N"
assert_contains "error stops the loop" "$BODY" "| \`error: …\` | stop the loop"
assert_contains "everything else is the scripts' doing" "$BODY" "nothing — the scripts acted"

echo "test: context discipline"
assert_contains "never reads code, diffs, graph or findings" "$BODY" "Never read a source file, a diff, the graph or a findings file"
assert_contains "findings never pass through the orchestrator" "$BODY" "findings never pass through you"
assert_contains "on-demand summaries" "$BODY" "spawn a haiku agent"

echo "test: the end — end-run.sh, one PR, nothing closed by the run"
assert_contains "end-run.sh" "$BODY" 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/end-run.sh" <runid>'
assert_contains "one PR with Closes" "$BODY" "\`Closes #N\` per merged slice"
assert_contains "leaves the worktree" "$BODY" "ExitWorktree(keep)"
assert_contains "the run never closes or merges" "$BODY" "never closes an issue and never merges the PR"
assert_contains "the mock-debt ledger mirror" "$BODY" "## Mock-debt ledger"

echo "test: deliberately not built"
assert_contains "the section" "$BODY" "# Deliberately not built"
n=$(sed -n '/^# Deliberately not built/,$p' "$SKILL_FILE" | grep -c '^- ')
if [ "$n" -eq 6 ]; then ok "six bullets"; else no "deliberately-not-built has $n bullets, not 6"; fi

echo "test: the deleted machinery stays deleted"
for gone in check-inbound notify_when_idle CONTEXT-MAP "claude attach" "claude stop" "--bg" \
            "Merged in <sha> by /orchestrate" prd-reap worker-stop crossSessionInbound SendMessage \
            "--orchestrator" "session-status.sh --self" "Workflow tool"; do
    assert_not_contains "no $gone" "$BODY" "$gone"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
