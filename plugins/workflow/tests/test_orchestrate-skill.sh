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

echo "test: the ad-hoc lane's claim about the shipped roster is TRUE of the shipped roster"
# The lane spawns through `Agent`, which takes claude model names only, so what it says
# about `model-tiers.json` decides whether it passes a usable model or a `gpt-*` one.
# Prose alone cannot stay honest here: assert it against the table it describes.
assert_not_matches "no stale 'every cell is codex' claim" "$BODY" "every worker cell.{0,40}codex"
assert_matches "the substitution is conditional on the cell" "$BODY" "[Ii]f a cell does say .?codex"
TIERS="$(cd "$PLUGIN_ROOT/../infra" && pwd)/model-tiers.json"
if grep -q '"backend": *"codex"' "$TIERS"; then
    # not a failure of the table — a failure of THIS paragraph to have been updated with it
    assert_matches "a codex cell shipped, so the lane must not call the roster claude-only" \
        "$BODY" "backend: .?codex.? in (some|every)"
else
    assert_matches "the table is claude-only and the lane says so" "$BODY" \
        "backend: .?claude.? in every cell"
fi

echo "test: a subagent runs the chain's TOP cell — the Agent tool takes no codex model (review fix 2)"
assert_matches "never the frontmatter default" "$BODY" "never the frontmatter default"
assert_matches "the ad-hoc substitution is the top cell too" "$BODY" "top cell.*implementer_chain-1"

echo "test: the tier gate never prompts"
assert_matches "never prompt to confirm a tier" "$BODY" "[Nn]ever prompt.*tier|tier.*auto-accept|Auto-accept"
assert_contains "resolver source labels are documented" "$BODY" "source=user|shipped|fallback"
assert_matches "the launch line reports the selected source" "$BODY" "launch line.{0,100}source=|source=.{0,100}launch line"
assert_matches "the source is copied from resolver stdout" "$BODY" "resolver.{0,50}stdout|stdout.{0,50}resolver"
ANNOUNCE_BLOCK="$(sed -n '/^\*\*Announce the lane/,/^---$/p' "$SKILL_FILE")"
assert_contains "resolver is run before the launch announcement" "$ANNOUNCE_BLOCK" 'bash ~/.claude/kit/infra/scripts/resolve-tier.sh standard'
assert_contains "resolver prints the source row to the Bash output" "$ANNOUNCE_BLOCK" "| sed -n '/^source=/p'"
assert_not_contains "source is not hidden in a shell assignment" "$ANNOUNCE_BLOCK" 'TIER_SOURCE='
assert_matches "launch uses the row visible in Bash output" "$ANNOUNCE_BLOCK" 'printed .?source=.? row.{0,60}Bash output'
assert_contains "launch examples use the resolver's source value" "$ANNOUNCE_BLOCK" 'source=<source>'
assert_not_contains "launch examples do not hardcode the shipped source" "$ANNOUNCE_BLOCK" 'source=shipped'

# ---------------------------------------------------------------------------
echo "test: workers — every tier spawns through spawn.sh; trivial starts on codex, never a subagent"
assert_matches "every tier spawns at attempt 0" "$BODY" "Spawn.*every tier"
assert_matches "trivial starts on codex" "$BODY" "trivial.*codex"
assert_not_matches "trivial is no longer a subagent" "$BODY" "trivial.*orchestrator-spawned.*subagent"
assert_matches "session startup cost justifies the split" "$BODY" "40k"
assert_matches "one session per issue, never reused" "$BODY" "[Nn]ever a reused per-slot session|One session per issue"
assert_contains "session name carries the run" "$BODY" "orch-<runid>-issue-<N>"
assert_contains "worktree carries the run" "$BODY" ".worktrees/<runid>/issue-<N>"
assert_matches "explains why the prefix matters" "$BODY" "agents --json.*global|global.*agents --json"

echo "test: the spawn protocol's silent-failure traps"
assert_matches "plain output is invisible" "$BODY" "invisible"
assert_contains "workers report with SendMessage" "$BODY" "SendMessage"
assert_contains "bypassPermissions" "$BODY" "bypassPermissions"
assert_contains "the orchestrator address comes from --self" "$BODY" "session-status.sh --self"
# The flags, the denylist and why each exists moved to infra's README (spawn.sh's own
# test pins the actual flags — see plugins/infra/tests/test_spawn.sh); SKILL.md keeps a pointer.
assert_contains "the full spawn protocol points at infra's README" "$BODY" "../../../infra/README.md#spawn-protocol"

echo "test: fix rounds are fresh sessions"
assert_matches "a fresh session per fix round" "$BODY" "fresh.*session|--role fix"
assert_matches "the fixer is not defending its own code" "$BODY" "not defending its own code|nobody is defending"

# ---------------------------------------------------------------------------
echo "test: the bus — the issue thread is the coordination medium"
assert_matches "issue thread is the medium" "$BODY" "issue thread is the coordination medium"
assert_matches "findings never pass through the orchestrator" "$BODY" "never (pass|handed) through the orchestrator"
assert_matches "cycles are counted from the AUTHORITATIVE source" "$BODY" "AUTHORITATIVE source"
assert_matches "claude-backed counts the comments, codex-backed counts the ledger" "$BODY" "codex-backed issue.s count is"
# The regenerable/not-regenerable table, brevity rationale and the review-comment example
# moved to infra's README; the issue thread's brevity mandate itself lives in and is pinned
# by agents/implementer.md (the contract every build session actually reads).
assert_contains "the comment contract points at infra's README" "$BODY" "../../../infra/README.md#the-bus"

echo "test: the context map"
assert_contains "written at admission" "$BODY" "at **admission**"
assert_contains "as a local file in the worktree" "$BODY" "CONTEXT-MAP.md"
assert_matches "a hint, not a contract" "$BODY" "hint, not a contract"
assert_matches "no staleness protocol" "$BODY" "no staleness protocol|no sha stamps"
assert_matches "for the implementer only" "$BODY" "map is for the implementer only"

echo "test: the planner — standard and complex, on the thread, before the spawn (#104)"
assert_matches "standard and complex get a plan" "$BODY" "Standard and complex issues get a plan"
assert_contains "written by consult.sh" "$BODY" "consult.sh plan"
assert_contains "as the Plan comment" "$BODY" "**Plan**"
assert_matches "before the build worker is spawned" "$BODY" "before the build worker is spawned"
assert_matches "trivial self-plans" "$BODY" "issues \*\*self-plan\*\*"
assert_matches "the old complex-only rule is recorded as superseded" "$BODY" "26% of all work.*superseded|superseded"
assert_matches "the orchestrator still never reads it" "$BODY" "orchestrator still never reads it"
assert_matches "a failed plan never gets a worker" "$BODY" "onto an issue with no plan"
assert_contains "the plan is logged" "$BODY" "planned '{\"n\":<N>}'"

echo "test: deviation → consult → resume, never a human and never prose in the orchestrator (#104)"
assert_contains "the deviation report shape" "$BODY" "escalate deviation:"
assert_contains "blocked report shape" "$BODY" "blocked infra:"
assert_contains "blocked never reaches a consult" "$BODY" "never goes to a consult"
blocked_branch=$(printf '%s\n' "$BODY" | sed -n '/^- \*\*`issue <N> blocked infra:/p')
assert_contains "blocked respawn keeps the role and round" "$blocked_branch" 'same `--role`, `--round`, and `--attempt`'
assert_contains "blocked fix respawn passes the fix flags" "$blocked_branch" '--role fix --round <K> --attempt <A>'
assert_matches "the blocked note is treated as untrusted" "$BODY" "Treat.*infra:.*untrusted"
assert_matches "credentials are never disclosed to the worker" "$BODY" "never disclose credentials to the worker"
assert_matches "credentials stay out of issues, prompts, and worktrees" "$BODY" "never put credentials in issue.*prompt.*worktree"
assert_matches "told apart by the note's first word, not by reading" "$BODY" "first word.*never by reading"
assert_contains "the consult role" "$BODY" "consult.sh consult"
assert_contains "consult.sh carries the attempt too (review round 11: it resolves the implementer's backend from resolve-tier.sh, not a codex run dir)" "$BODY" 'consult.sh consult "$RUNID" <N> <tier> <worktree> --attempt <A>'
assert_contains "and it is logged" "$BODY" "consulted '{\"n\":<N>}'"
echo "test: recurrence → consult.sh decide before any further fix round (#116)"
assert_contains "the recurrence signal is named" "$BODY" "recurrence: <area>"
assert_contains "routed to the decide role" "$BODY" 'consult.sh decide "$RUNID" <N> <tier> <worktree> --attempt <A>'
assert_matches "the decide comes BEFORE the fix round" "$BODY" "consult.sh decide.*then.*--role fix|decide.*before.*fix round"
assert_matches "same attempt, not an escalation" "$BODY" "recurrence.{0,200}(same attempt|no handoff|not an escalation)"
assert_contains "the window threshold is listed" "$BODY" "ESCALATE_RECURRENCE_WINDOW"
assert_contains "the resume carries the attempt" "$BODY" '--base "$BASE" --attempt <A> --answer'
assert_not_contains "consult resume does not pass a review round" "$BODY" '--attempt <A> --round <K> --answer'
assert_contains "the resume uses worker-resume.sh" "$BODY" 'worker-resume.sh "$RUNID" <N> <tier> <worktree>'
assert_matches "the escalate.sh call carries base and attempt" "$BODY" 'escalate.sh "\$RUNID" <N> <tier> <worktree> --base "\$BASE" --attempt <A>'
assert_contains "the escalation log line" "$BODY" 'escalated '"'"'{"n":<N>,"reason":"<reason>","attempt":<A>}'"'"''

assert_matches "the answer is a POINTER to the thread, not the decision text" "$BODY" "read the newest .?.?Consult.?.? comment"
assert_matches "escalate.sh runs first: the third deviation escalates" "$BODY" "deviation is an escalation"

echo "test: provisioned infra resources survive later worker turns"
resource_suffix="\${resource_args[@]+\"\${resource_args[@]}\"}"
assert_contains "the blocked infra report is named" "$BODY" "blocked infra:"
assert_contains "the resource example shows the env flag shape" "$BODY" "--env DATABASE_URL=<actual-value>"
assert_not_contains "generic commands never inject sample credentials" "$BODY" "--env DATABASE_URL=postgres://..."
assert_contains "the resume accepts the same env flag" "$BODY" '`worker-resume.sh` takes the same flag'
assert_contains "the run log records the env name only" "$BODY" '"env":["DATABASE_URL"]'
assert_matches "the log rule says names, never the values" "$BODY" "names, never the values"
assert_contains "provisioned pairs stay in per-issue orchestrator state" "$BODY" \
    "Keep the exact env pairs per issue in the orchestrator's live context"
assert_contains "empty resource args are allowed" "$BODY" 'resource_args=()'
assert_contains "actual pairs are appended to the resource args" "$BODY" 'resource_args+=(--env "$pair")'
assert_contains "Claude settings paths are retained for cleanup" "$BODY" \
    "save the Claude settings file path"
assert_contains "stopped Claude sessions have their private settings removed" "$BODY" \
    "remove its settings file and private directory"
assert_contains "a superseded or merged Claude worker has its settings removed too" "$BODY" \
    "superseded by a fix-round session, or its issue merged"
assert_contains "the run end sweeps every leftover settings dir for the run" "$BODY" \
    'rm -rf -- "${TMPDIR:-/tmp}"/claude-env."$RUNID".issue-*'
assert_contains "fix rounds re-pass the provisioned env" "$BODY" \
    "--role fix --round <K> --attempt <A> $resource_suffix"
assert_contains "escalation replacements re-pass the provisioned env" "$BODY" \
    "--attempt <A+1> $resource_suffix"
assert_contains "consult-answer resumes re-pass the provisioned env" "$BODY" \
    "--answer \"Consult posted: read the newest **Consult** comment on #<N> and follow its decision.\" $resource_suffix"
assert_contains "human-answer resumes re-pass the provisioned env" "$BODY" \
    "--answer \"...\" --attempt <A> $resource_suffix"

echo "test: escalation by script — chain, attempt, stop, respawn, drain at the top (#104)"
assert_matches "a script decides, never the worker" "$BODY" "script decides.*never the worker"
assert_contains "the chain is named" "$BODY" "6-luna → 6-sol → opus"
assert_contains "spawn takes the attempt" "$BODY" "--attempt 0"
assert_matches "run on every wake" "$BODY" "On every wake"
assert_matches "one line or nothing" "$BODY" "one line.*or .?.?nothing"
assert_matches "the handoff is posted by the script" "$BODY" "Handoff.?.? comment"
assert_matches "stop the worker first" "$BODY" "Stop the worker"
assert_matches "respawn at attempt+1 on the same worktree" "$BODY" "attempt <A\+1>.*same worktree"
assert_matches "the top of the chain drains" "$BODY" "past the top of.*chain.*(drain|failed)"
assert_matches "nothing is resumed across a model change" "$BODY" "Nothing is resumed across a model change"
assert_matches "fix rounds carry the attempt" "$BODY" "--role fix --round <K> --attempt <A>"
assert_matches "claude workers are never escalated" "$BODY" "[Cc]laude-backed workers .{0,30}never escalated"
assert_matches "a quota reason skips the remaining codex positions" "$BODY" "quota.{0,120}skip.{0,40}codex"

# ---------------------------------------------------------------------------
echo "test: liveness — subscribe, never poll"
assert_contains "notify_when_idle subscription" "$BODY" "notify_when_idle"
assert_contains "waits on worker messages and idle notices" "$BODY" "wait on worker messages and idle notices"
assert_contains "long idle tick is a fallback only" "$BODY" "long idle tick is a fallback only"
assert_matches "no message at spawn" "$BODY" "no message"
assert_matches "never poll" "$BODY" "never poll"
assert_contains "state comes from session-status.sh" "$BODY" "session-status.sh"
# The state table (busy/idle/blocked/done/stopped/gone) and "never parse claude logs" moved
# to infra's README, alongside session-status.sh — the script whose own test pins these states.
assert_contains "liveness and recovery point at infra's README" "$BODY" "../../../infra/README.md#liveness-and-recovery"

# The codex backend's control rules (a codex row is a PID: group-kill it, never `claude
# stop`, and it cannot escalate mid-run) live with the liveness/recovery prose in infra's
# README, and are pinned by plugins/infra/tests/test_readme.sh.

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

echo "test: the orchestrator address is resolved once and passed"
assert_contains "resolved with --self at setup" "$BODY" 'ORCH="$(bash'
assert_matches "explains why not per-spawn" "$BODY" "rename mid-run"

echo "test: recovery"
assert_contains "stop, verify, respawn" "$BODY" "claude stop"
assert_contains "the count comes from the run log" "$BODY" "run-log.sh"
# The recovery mechanism rationale, the never-rm / never-spawn-onto-a-live-worktree rules,
# the bounded-wait/escalate procedure and the several-rows-per-issue caveat all moved to
# infra's README (see the liveness-and-recovery pointer assertion above).

echo "test: escalation"
assert_matches "offers both mediate and attach" "$BODY" "claude attach"
assert_matches "recommends attach for code back-and-forth" "$BODY" "[Aa]ttach.*code|code.*attach"
assert_matches "escalated session is exempt from the deadline" "$BODY" "exempt from the deadline"
assert_matches "resolution must be reported back" "$BODY" "MUST report the resolution|must report the resolution"

# ---------------------------------------------------------------------------
echo "test: merge"
assert_contains "fold first" "$BODY" "merge-fold.sh"
assert_contains "in-run fold allows upstream drift after the launch check" "$BODY" 'merge-fold.sh" --allow-behind "$baseBranch"'
assert_matches "a fold, not a filter" "$BODY" "fold, not a filter"
assert_matches "only the remainder reaches the merger" "$BODY" "conflicted remainder"
assert_matches "merger is never tier-routed" "$BODY" "never tier-routed"
assert_contains "the split threshold" "$BODY" "--merge-split-at"
assert_matches "two-at-a-time is not built yet" "$BODY" "not built"
assert_matches "in-run merges are automatic" "$BODY" "In-run merges.*automatic|are .?.?automatic"
assert_matches "the end merge is gated on the user" "$BODY" "end merge is offered and gated"
assert_contains "end-of-run integration review calls follow-up.sh" "$BODY" 'follow-up.sh" --integration "$RUNID" "$base"'
END_RUN="$(sed -n '/^# End of run$/,$p' "$SKILL_FILE")"
integration_offset=$(printf '%s\n' "$END_RUN" | grep -nF -- '--integration' | head -1 | cut -d: -f1)
preview_offset=$(printf '%s\n' "$END_RUN" | grep -nF -- 'merge-fold.sh" --preview' | head -1 | cut -d: -f1)
if [ -n "$integration_offset" ] && [ -n "$preview_offset" ] && [ "$integration_offset" -lt "$preview_offset" ]; then ok "integration review runs before the end-merge preview"; else no "integration review runs before the end-merge preview"; fi
assert_matches "integration result belongs in the end-merge offer" "$BODY" "integration.{0,80}end-merge offer|end-merge offer.{0,80}integration"
assert_contains "end merge is previewed against the upstream" "$BODY" 'merge-fold.sh" --preview'
prev_ln=$(grep -nF 'merge-fold.sh" --preview' "$SKILL_FILE" | head -1 | cut -d: -f1)
offer_ln=$(grep -nF 'Offer the end merge' "$SKILL_FILE" | head -1 | cut -d: -f1)
if [ -n "$prev_ln" ] && [ -n "$offer_ln" ] && [ "$prev_ln" -lt "$offer_ln" ]; then ok "preview runs before the end-merge offer"; else no "preview runs before the end-merge offer"; fi
assert_matches "the preview result is shown in the offer" "$BODY" "preview.*(offer|before asking)|offer.*preview"
assert_contains "end-merge preview resolves the target's configured upstream" "$BODY" '"$target@{upstream}"'
assert_contains "end-merge preview falls back to the local target" "$BODY" 'preview_ref="${target_upstream:-$target}"'
assert_contains "no-upstream preview tells the user it uses the local branch" "$BODY" 'When no upstream is configured for "$target", preview the local "$target" branch and say so in the offer.'
assert_not_contains "end-merge preview does not assume origin" "$BODY" 'merge-fold.sh" --preview origin/<target>'
assert_matches "one PR at the end, not per slice" "$BODY" "One PR at the end"
assert_matches "a capped merge files a follow-up" "$BODY" "capped.*follow-up.sh"
assert_contains "capped-merge dependents are an orchestrator hold" "$BODY" "capped-merge dependents"
assert_matches "a failed follow-up.sh holds the dependents" "$BODY" "follow-up.sh.*non-zero.*held"
assert_matches "follow-up.sh gets the issue's attempt" "$BODY" "follow-up.sh.*--attempt <A>"
assert_contains "run-log table includes integration-review" "$BODY" '| `run-log.sh` | scope · held · respawned · decision · planned · consulted · escalated · follow-up · integration-review |'

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
assert_matches "--held is defined beside its usage as the user's explicit hold" "$BODY" "--held.*explicit hold"
assert_matches "--held is never 'waiting on a blocker'" "$BODY" "never .?waiting on a blocker"
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
check_ln=$(grep -nF 'scripts/merge-fold.sh" "$(git rev-parse --abbrev-ref HEAD)"' "$SKILL_FILE" | head -1 | cut -d: -f1)
base_ln=$(grep -nF 'base=$(git rev-parse HEAD)' "$SKILL_FILE" | head -1 | cut -d: -f1)
if [ -n "$check_ln" ] && [ -n "$base_ln" ] && [ "$check_ln" -lt "$base_ln" ]; then ok "launch fetch check runs before the base snapshot"; else no "launch fetch check runs before the base snapshot"; fi
assert_contains "the override flag is documented" "$BODY" "--allow-behind"
assert_matches "the check result goes in the launch line" "$BODY" "behind.*launch line|launch line.*behind"

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
# Keep one line of headroom for integration changes before the <700 merged-file gate.
if [ "$lines" -lt 699 ]; then ok "SKILL.md is $lines lines (was 757 before the infra prose trim)"; else no "SKILL.md grew back to $lines lines"; fi

echo "test: infra scripts are called by infra's stable path, never workflow's root"
for s in check-inbound.sh "resolve-tier.sh <tier>" "session-status.sh --self" spawn.sh consult.sh escalate.sh; do
    assert_contains "calls $s via ~/.claude/kit/infra" "$BODY" "bash ~/.claude/kit/infra/scripts/$s"
done
for s in session-status.sh check-inbound.sh resolve-tier.sh spawn.sh consult.sh escalate.sh; do
    assert_not_contains "no plugin-root path to $s" "$BODY" '${CLAUDE_PLUGIN_ROOT}/scripts/'"$s"
done
assert_contains "fails loud without infra" "$BODY" "infra plugin not installed"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
