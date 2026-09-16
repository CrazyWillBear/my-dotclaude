#!/usr/bin/env bash
#
# Tests for skills/orchestrate/SKILL.md — the orchestrate skill prose.
#
# The skill is prose, so these are grep tests and they can only prove that a
# STRING DESCRIBING the behavior is present. That is exactly why the deterministic
# half of the loop was moved into scripts/ (ready.sh, session-status.sh, spawn.sh,
# run-log.sh, merge-fold.sh), where it is tested for behavior. What is left here is
# the part that genuinely is instruction to a model, and each assertion below marks
# a place where forgetting the instruction fails SILENTLY:
#
#   * the orchestrator runs on the MAIN THREAD — a subagent orchestrator's
#     SendMessage replies land in its parent's conversation, so it would talk and
#     never hear back
#   * a worker's plain output is INVISIBLE — miss the SendMessage line and the
#     orchestrator waits forever
#   * the run prefix on session names — `claude agents --json` is global, and
#     without it one run can stop another run's workers
#   * readiness comes from ready.sh, never from the model's own arithmetic
#   * the orchestrator never reads a diff, a plan or a findings file
#   * the irreversible gh writes stay on the main thread (#77)
#   * the end merge and the PR are OFFERED, in-run merges are automatic
#
# It also pins the things deliberately DELETED, because each is something a fresh
# session will reasonably re-add: the Workflow tool, the js scheduler block, and
# /pipeline.
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
assert_not_matches()  { if printf '%s\n' "$2" | grep -Eqi -- "$3"; then no "$1 (unexpected match: $3)"; else ok "$1"; fi; }

if [ ! -f "$SKILL_FILE" ]; then
    printf '  FAIL: SKILL.md missing at %s\n' "$SKILL_FILE"
    exit 1
fi
BODY="$(cat "$SKILL_FILE")"
FM="$(sed -n '/^---$/,/^---$/p' "$SKILL_FILE")"

# ---------------------------------------------------------------------------
echo "test: frontmatter"
assert_contains "name is orchestrate" "$FM" "name: orchestrate"
assert_contains "has a description" "$FM" "description:"
assert_contains "argument-hint carries --max" "$FM" "--max"
assert_contains "argument-hint carries --merge-split-at" "$FM" "--merge-split-at"
assert_contains "allowed-tools includes SendMessage" "$FM" "SendMessage"
assert_contains "allowed-tools includes Bash" "$FM" "Bash"
assert_not_contains "the Workflow tool is gone" "$FM" "Workflow"

echo "test: the orchestrator runs on the main thread, never as a subagent"
assert_matches "says main thread, never a subagent" "$BODY" "main thread.*never as a subagent|Never as a subagent"
assert_matches "explains why: replies land in the parent" "$BODY" "parent"

echo "test: it absorbs /pipeline and is the one front door"
assert_matches "absorbs pipeline" "$BODY" "absorbs .?/?pipeline"
assert_not_matches "does not tell anyone to run /pipeline" "$BODY" "run .?/pipeline|use .?/pipeline"

# ---------------------------------------------------------------------------
echo "test: the cross-session message gate is called out before a run"
assert_contains "names the setting" "$BODY" "crossSessionInbound"
assert_matches "explains the permission-class mismatch" "$BODY" "permission-mode class"
assert_matches "says it must be user-level" "$BODY" "may only .{0,2}tighten"
assert_matches "states the cost honestly" "$BODY" "any. local Claude session without review|machine-wide relaxation"
# The check must be RUN, not just described — prose protects nobody on a fresh install.
assert_contains "runs the check script" "$BODY" "check-inbound.sh"
assert_matches "handles all three exit codes" "$BODY" "exit 2|\\*\\*2\\*\\*"
assert_matches "never refuses to start over a mere hold" "$BODY" "Never refuse to start over this"

echo "test: Step 0 dispatch routes by shape"
assert_matches "routes by SHAPE not size" "$BODY" "by SHAPE, not size|shape, not size"
assert_contains "ad-hoc lane for one unit with the user present" "$BODY" "ad-hoc"
assert_contains "session lane for an issue graph or PRD" "$BODY" "session lane"
assert_matches "ambiguous builds nothing" "$BODY" "discuss.*[Bb]uild nothing|Build nothing"
assert_contains "explicit = what/where/done" "$BODY" "**Done**"
assert_matches "announces the lane and proceeds without asking" "$BODY" "Announce the lane.*[Dd]o not ask|announcement .?is.? the veto window"

echo "test: the tier gate never prompts"
assert_matches "never prompt to confirm a tier" "$BODY" "[Nn]ever prompt.*tier|tier.*auto-accept|Auto-accept"

# ---------------------------------------------------------------------------
echo "test: workers — sessions for standard/complex, subagent for trivial"
assert_matches "trivial gets a subagent" "$BODY" "trivial.*subagent"
assert_matches "session startup cost justifies the split" "$BODY" "40k"
assert_matches "one session per issue, never reused" "$BODY" "[Nn]ever a reused per-slot session|One session per issue"
assert_contains "session name carries the run" "$BODY" "orch-<runid>-issue-<N>"
assert_contains "worktree carries the run" "$BODY" ".worktrees/<runid>/issue-<N>"
assert_matches "explains why the prefix matters" "$BODY" "agents --json.*global|global.*agents --json"

echo "test: the spawn protocol's silent-failure traps"
assert_matches "plain output is invisible" "$BODY" "invisible"
assert_contains "workers report with SendMessage" "$BODY" "SendMessage"
assert_contains "bypassPermissions" "$BODY" "bypassPermissions"
assert_matches "an unattended session in manual mode deadlocks" "$BODY" "deadlock"
assert_contains "denylist keeps merge off the worker" "$BODY" "git merge"
assert_contains "denylist keeps gh issue close off the worker" "$BODY" "gh issue close"
assert_matches "push and comment stay allowed" "$BODY" "push.{0,2} and .{0,2}gh issue comment.{0,2} are deliberately allowed"
assert_matches "add-dir does not fence Bash — stated as a known limit" "$BODY" "not fence Bash|fences the .*file tools"
assert_contains "the orchestrator address comes from --self" "$BODY" "session-status.sh --self"

echo "test: fix rounds are fresh sessions"
assert_matches "a fresh session per fix round" "$BODY" "fresh.*session|--role fix"
assert_matches "the fixer is not defending its own code" "$BODY" "not defending its own code|nobody is defending"

# ---------------------------------------------------------------------------
echo "test: the bus — the issue thread is the coordination medium"
assert_matches "issue thread is the medium" "$BODY" "issue thread is the coordination medium"
assert_matches "findings never pass through the orchestrator" "$BODY" "never handed through the orchestrator"
assert_matches "issue carries what cannot be regenerated" "$BODY" "cannot be regenerated"
assert_matches "local files carry the regenerable" "$BODY" "regenerable"
assert_matches "brevity is a correctness property" "$BODY" "[Bb]revity is a correctness property"
assert_contains "the review comment format" "$BODY" "**Review round 1**"
assert_matches "cycles are counted from the comments" "$BODY" "counted by reading the issue|number of those comments"

echo "test: the context map"
assert_contains "written at admission" "$BODY" "at **admission**"
assert_contains "as a local file in the worktree" "$BODY" "CONTEXT-MAP.md"
assert_matches "a hint, not a contract" "$BODY" "hint, not a contract"
assert_matches "no staleness protocol" "$BODY" "no staleness protocol|no sha stamps"
assert_matches "for the implementer only" "$BODY" "map is for the implementer only"

echo "test: the planner's fate is decided in writing"
assert_matches "kept for complex only" "$BODY" "complex.* only|only complex"
assert_matches "and the reason is recorded" "$BODY" "26% of all work|83 of 317"
assert_matches "spawned by the session, not the orchestrator" "$BODY" "session spawns it, not the orchestrator|spawned by the build session"

# ---------------------------------------------------------------------------
echo "test: liveness — subscribe, never poll"
assert_contains "notify_when_idle subscription" "$BODY" "notify_when_idle"
assert_matches "no message at spawn" "$BODY" "no message"
assert_matches "never poll" "$BODY" "[Ss]ubscribe, don.t poll|never to poll"
assert_contains "state comes from session-status.sh" "$BODY" "session-status.sh"
assert_matches "blocked means a permission wedge" "$BODY" "permission wedge"
assert_matches "never parse claude logs" "$BODY" "Never parse .?claude logs"

echo "test: a codex worker is a PID, so the claude-only controls are called out"
# `claude stop` and `claude attach` take a SESSION id; column 2 of a codex row is a PID,
# and a codex worker has no inbox to attach to or escalate through mid-run. Claiming
# "nothing changes" would send the recovery path at a process with the wrong tool.
assert_not_matches "no blanket 'nothing changes' for the codex backend" "$BODY" "so nothing changes"
assert_matches "a codex row is stopped with kill, not claude stop" "$BODY" "kill.{0,40}not .?claude stop|claude stop.{0,60}kill"
assert_matches "and it cannot escalate mid-run" "$BODY" "cannot escalate mid-run|no mid-run escalation"

echo "test: control is by session ID, not by name — stop/attach reject a name"
assert_matches "says the id is what stop/attach take" "$BODY" "id, not the name|takes an id"
assert_matches "reads the id from session-status, not from spawn output" "$BODY" "column 2"
assert_matches "attach is shown with an id" "$BODY" "claude attach [0-9a-f]{8}"
assert_not_matches "never shows attach with a session name" "$BODY" "claude attach orch-"
assert_not_matches "never shows stop with a session name" "$BODY" "claude stop orch-"

echo "test: my-review posts nothing — the session owns the review comment"
assert_matches "my-review is report-only" "$BODY" "my-review.{0,4} is .{0,2}report-only"
assert_matches "the session posts the comment" "$BODY" "the SESSION posts|session takes my-review"

echo "test: the fix-round report shape is handled"
assert_contains "fixed round= is documented" "$BODY" "fixed round="

echo "test: the session lane keeps the mock-debt declaration contract"
assert_matches "points the session at the implementer contract" "$BODY" "agents/implementer.md"
assert_matches "names the declaration" "$BODY" "Real wiring blocked by"

echo "test: trivial issues are excluded from the expected-session list"
assert_matches "says trivial issues have no session" "$BODY" "Expect only the issues that actually have a session"

echo "test: the orchestrator address is resolved once and passed"
assert_contains "resolved with --self at setup" "$BODY" 'ORCH="$(bash'
assert_matches "explains why not per-spawn" "$BODY" "rename mid-run"

echo "test: recovery"
assert_matches "commit per green sub-step is the recovery mechanism" "$BODY" "recovery mechanism.{0,2}, not hygiene"
assert_contains "stop, verify, respawn" "$BODY" "claude stop"
assert_matches "never rm — it deletes the worktree" "$BODY" "Never .?rm"
assert_matches "never spawn onto a live worktree" "$BODY" "still listed alive"
assert_matches "respawn once, escalate on the second" "$BODY" "[Rr]espawn once"
# A stop that is acknowledged but does not take would hang the "verify stopped" gate
# forever — observed live, so the wait is bounded and ends in an escalation.
assert_matches "a stop may not take" "$BODY" "acknowledged and not take"
assert_matches "the wait is bounded" "$BODY" "wait.{0,10}bounded|timeout 60"
assert_matches "and it escalates rather than respawning blindly" "$BODY" "do not respawn"
assert_contains "the count comes from the run log" "$BODY" "run-log.sh"

echo "test: a respawned issue has several rows — match on state, not the name"
assert_matches "warns about multiple rows per issue" "$BODY" "several rows|One issue can have"
assert_matches "says to match on state" "$BODY" "Match on state, never on the name"

echo "test: escalation"
assert_matches "offers both mediate and attach" "$BODY" "claude attach"
assert_matches "recommends attach for code back-and-forth" "$BODY" "[Aa]ttach.*code|code.*attach"
assert_matches "escalated session is exempt from the deadline" "$BODY" "exempt from the deadline"
assert_matches "resolution must be reported back" "$BODY" "MUST report the resolution|must report the resolution"

# ---------------------------------------------------------------------------
echo "test: merge"
assert_contains "fold first" "$BODY" "merge-fold.sh"
assert_matches "a fold, not a filter" "$BODY" "fold, not a filter"
assert_matches "only the remainder reaches the merger" "$BODY" "conflicted remainder"
assert_matches "merger is never tier-routed" "$BODY" "never tier-routed"
assert_contains "the split threshold" "$BODY" "--merge-split-at"
assert_matches "two-at-a-time is not built yet" "$BODY" "not built"
assert_matches "in-run merges are automatic" "$BODY" "In-run merges.*automatic|are .?.?automatic"
assert_matches "the end merge is gated on the user" "$BODY" "end merge is offered and gated"
assert_matches "one PR at the end, not per slice" "$BODY" "One PR at the end"
assert_matches "a capped merge holds its dependents" "$BODY" "capped.*holds its dependents|holds its dependents"

echo "test: context discipline"
assert_matches "never reads a source file or a diff" "$BODY" "never .?Read.?s a source file"
assert_matches "passes paths and numbers" "$BODY" "paths and numbers"
assert_matches "the token target is stated" "$BODY" "50 tokens per issue"
assert_matches "summaries are on demand only" "$BODY" "[Oo]n-demand summaries only"
assert_matches "haiku answers a recap" "$BODY" "haiku"
assert_matches "deterministic logic lives in scripts" "$BODY" "lives in scripts"

# ---------------------------------------------------------------------------
echo "test: scope is an explicit allowlist, never a repo-wide sweep (#77 defect A)"
assert_matches "never queries for work" "$BODY" "never .?queries for work"
assert_contains "--issues is the literal allowlist" "$BODY" "--issues"
assert_contains "--prd walks prd-children.sh" "$BODY" "prd-children.sh"
assert_matches "frozen at launch" "$BODY" "frozen at launch"
assert_matches "nothing the run files can be built by the run" "$BODY" "Nothing the run files can be built by the run"
assert_matches "an empty allowlist stops the run" "$BODY" "empty allowlist stops the run|empty scope is never a reason"

echo "test: readiness is a script, not the model's arithmetic"
assert_contains "ready.sh is called with the graph" "$BODY" "ready.sh"
assert_matches "never compute readiness yourself" "$BODY" "Never compute readiness yourself"
assert_matches "the three ready.sh outcomes are all handled" "$BODY" "nothing-to-do"
assert_matches "an unexplained empty stops the run" "$BODY" "[Nn]ever treat it as .?finished"
assert_contains "the graph is fetched once" "$BODY" "scope-graph.sh"
assert_matches "e2e-gate is held by open mock-debt" "$BODY" "e2e-gate"

echo "test: the orchestration worktree"
assert_contains "EnterWorktree" "$BODY" "EnterWorktree"
assert_contains "ExitWorktree(keep)" "$BODY" "ExitWorktree(keep)"
assert_matches "verifies the base after entering (worktree.baseRef)" "$BODY" "worktree.baseRef"
assert_contains "excludes .worktrees/ locally" "$BODY" "info/exclude"
assert_matches "and says so in the report" "$BODY" "outlives the run|persistent mutation"

# ---------------------------------------------------------------------------
echo "test: the irreversible gh writes stay on the main thread (#77)"
assert_matches "close from the main thread only" "$BODY" "only.*place the run closes an issue"
assert_contains "closes with the merge commit" "$BODY" "gh issue close"
assert_matches "every close is verified" "$BODY" "Verify every close"
assert_matches "a still-open issue stops and reports loudly" "$BODY" "still open after its close"
assert_matches "conflict stops are commented onto the issue" "$BODY" "conflict-stop"

echo "test: the PRD reap is unchanged"
assert_contains "calls prd-reap.sh" "$BODY" "prd-reap.sh"
assert_contains "ready <prd> offers" "$BODY" "ready <prd>"
assert_contains "blocked <prd> only notes" "$BODY" "blocked <prd>"
assert_matches "never auto-closes a PRD" "$BODY" "never auto-close"
assert_matches "prints nothing -> report unchanged" "$BODY" "report is unchanged"
assert_matches "only the delimited ledger section is rewritten" "$BODY" "Touch no other part"
assert_matches "the label query stays authoritative" "$BODY" "authoritative"

# ---------------------------------------------------------------------------
echo "test: the deleted machinery stays deleted"
assert_not_matches "no Workflow tool invocation" "$BODY" "invoke the Workflow|Workflow tool"
assert_not_matches "no js scheduler block" "$BODY" '^```js$'
assert_not_contains "no export const meta" "$BODY" "export const meta"
assert_not_matches "no ROSTER const inlined into a script" "$BODY" "ROSTER\["
assert_matches "the wrap-and-handoff nudge stays deleted" "$BODY" "periodic wrap-and-handoff nudge.*deliberately deleted|wrap-and-handoff nudge"
assert_matches "and the deletions are recorded as deliberate" "$BODY" "Deliberately not built"

echo "test: the not-built list keeps its reasons"
assert_matches "two-at-a-time" "$BODY" "Two-at-a-time"
assert_matches "recon to predict overlap" "$BODY" "[Rr]econ to predict"
assert_matches "contract stubs commit" "$BODY" "stubs"
assert_matches "waves / round barriers" "$BODY" "[Ww]aves"
assert_matches "watch/claim tables" "$BODY" "claim tables"
assert_matches "per-slice PRs" "$BODY" "[Pp]er-slice PRs"

# ---------------------------------------------------------------------------
echo "test: it stays smaller than the thing it replaced"
lines=$(wc -l <"$SKILL_FILE")
if [ "$lines" -lt 900 ]; then ok "SKILL.md is $lines lines (was 1330)"; else no "SKILL.md grew back to $lines lines"; fi

echo "test: infra scripts are called by infra's stable path, never workflow's root"
for s in check-inbound.sh "resolve-tier.sh <tier>" "session-status.sh --self" spawn.sh; do
    assert_contains "calls $s via ~/.claude/kit/infra" "$BODY" "bash ~/.claude/kit/infra/scripts/$s"
done
for s in session-status.sh check-inbound.sh resolve-tier.sh spawn.sh; do
    assert_not_contains "no plugin-root path to $s" "$BODY" '${CLAUDE_PLUGIN_ROOT}/scripts/'"$s"
done
assert_contains "fails loud without infra" "$BODY" "infra plugin not installed"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
