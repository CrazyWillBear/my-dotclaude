#!/usr/bin/env bash
#
# Tests for skills/orchestrate/SKILL.md — the orchestrate skill prose.
#
# The skill is prose — not executable code — so we validate its structure,
# required frontmatter fields, and the key content obligations the issue-18
# acceptance criteria demand:
#
#   1. File exists at the expected discovery path.
#   2. Frontmatter contains required fields (name, description).
#   3. The skill instructs the orchestrator to call prd-reap.sh at end-of-run
#      with the run's closed issue numbers.
#   4. The skill names the correct helper path so agents call it correctly.
#   5. The skill describes the 'ready' output line and its meaning.
#   6. The skill describes the 'blocked' output line and its meaning.
#   7. The skill offers (prompts, never auto-closes) for each ready PRD.
#   8. The skill instructs using gh issue close (not delete) for a yes answer.
#   9. A blocked PRD is reported, not offered for closing.
#  10. When nothing qualifies the final report is unchanged (no prompt).
#  11. The offer/note appears only end-of-run — the scheduler is uninterrupted.
#  12. The skill never edits the PRD body.
#  13. (issue #63) The skill invokes the Workflow tool for the run — the loop no
#      longer runs on the main thread, the Workflow permission dialog is the
#      single launch gate, the orchestration worktree is passed in as the base
#      and exited via ExitWorktree(keep), and the workflow runs
#      build (workflow:implementer) -> merge (workflow:merger) -> return,
#      draining on a conflict-stop / red done-check / implementer failure.
#  14. (tier labels + scheduler) The tier is a PERSISTED LABEL read at launch and
#      backfilled when missing; the graph is fetched once by scope-graph.sh and
#      readiness is computed in PLAIN JS (no picker agent); rounds are gone —
#      a continuous scheduler keeps --max N issues in flight.
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
# Line-scoped absence check. A bare substring ban is a REPO-WIDE ban on a token, which
# is how "no plan comment" grew into "the skill may never mention `gh issue comment`
# anywhere" — a test dictating a product decision. A regex over each line bans the
# FORM, not the token.
assert_not_matches() {
    if printf '%s\n' "$2" | grep -Eq -- "$3"; then no "$1 (unexpected match: $3)"; else ok "$1"; fi
}

# ---------------------------------------------------------------------------
echo "test: skill file exists at the expected discovery path"
if [ -f "$SKILL_FILE" ]; then
    ok "SKILL.md present at skills/orchestrate/SKILL.md"
else
    no "SKILL.md missing at $SKILL_FILE"
fi

# Read the file once for all content checks.
content=""
js_block=""
if [ -f "$SKILL_FILE" ]; then
    content="$(cat "$SKILL_FILE")"
    # The ```js scheduler block ALONE. Absence checks run against it rather than the
    # whole file: the surrounding prose deliberately names the wrong forms in order to
    # warn about them, and must stay free to do so.
    js_block="$(awk '/^```js$/{inblock=1; next} /^```$/{inblock=0} inblock' "$SKILL_FILE")"
fi

# ---------------------------------------------------------------------------
echo "test: frontmatter contains 'name: orchestrate'"
assert_contains "name field present" "$content" "name: orchestrate"

# ---------------------------------------------------------------------------
echo "test: frontmatter contains a description field"
assert_contains "description field present" "$content" "description:"

# ---------------------------------------------------------------------------
echo "test: skill instructs calling prd-reap.sh at end-of-run"
assert_contains "prd-reap.sh invocation present" "$content" "prd-reap.sh"

# ---------------------------------------------------------------------------
echo "test: skill names the correct helper path (plugins/workflow/scripts/prd-reap.sh)"
assert_contains "correct helper path present" "$content" "plugins/workflow/scripts/prd-reap.sh"

# ---------------------------------------------------------------------------
echo "test: skill passes closed issue numbers to the helper"
# The invocation must show numbers (N1, N2, etc.) being passed as arguments.
assert_contains "closed issue numbers passed as arguments" "$content" "N1"

# ---------------------------------------------------------------------------
echo "test: skill describes the 'ready' output line"
assert_contains "ready output line described" "$content" "ready <prd_number>"

# ---------------------------------------------------------------------------
echo "test: skill describes the 'blocked' output line"
assert_contains "blocked output line described" "$content" "blocked <prd_number> hitl"

# ---------------------------------------------------------------------------
echo "test: skill prompts the user (never auto-closes) for a ready PRD"
assert_contains "offer prompt present (yes/no)" "$content" "yes/no"
assert_contains "never auto-close language present" "$content" "never auto-close"

# ---------------------------------------------------------------------------
echo "test: skill instructs gh issue close (not delete) on yes"
assert_contains "gh issue close present" "$content" "gh issue close"
assert_not_contains "gh issue delete must NOT appear" "$content" "gh issue delete"

# ---------------------------------------------------------------------------
echo "test: skill instructs adding a completion comment when closing"
assert_contains "completion comment present" "$content" "--comment"

# ---------------------------------------------------------------------------
echo "test: skill never edits the PRD spec content (ledger section carve-out aside)"
assert_contains "never edit PRD spec content stated" "$content" "Never edit the PRD's spec content"

# ---------------------------------------------------------------------------
echo "test: skill reports blocked PRDs without offering to close them"
assert_contains "blocked reported not offered" "$content" "without offering to close"

# ---------------------------------------------------------------------------
echo "test: skill specifies no-op when helper prints nothing (autonomous contract)"
assert_contains "no-op when nothing qualifies" "$content" "the final report is unchanged"

# ---------------------------------------------------------------------------
echo "test: prd-reap step is end-of-run only (after the run drains)"
assert_contains "end-of-run placement stated" "$content" "After the run drains"

# ---------------------------------------------------------------------------
echo "test: the PRD offers never interrupt the scheduler"
assert_contains "mid-run uninterrupted stated" "$content" "never interrupt the scheduler"

# --- mock-debt gate (C7) ---------------------------------------------------
echo "test: the ready-rule holds the e2e-gate while mock-debt is open"
assert_contains "e2e-gate referenced in the ready-rule" "$content" "e2e-gate"
assert_contains "mock-debt gate tag present" "$content" "Mock-debt gate (C7)"
assert_contains "gate holds while debt open" "$content" "not ready"
# The gate no longer re-queries gh mid-run: the launch graph seeds the open set and
# every review's filings union into it. A held gate must see debt the RUN files, not
# just debt that predated it.
assert_contains "open mock-debt set tracked in the workflow" "$content" "openMockDebt"
assert_contains "launch ledger seeds the set" "$content" "graph.mockDebtOpen"
assert_contains "reviews report what they filed" "$content" "mockDebtFiled"

echo "test: orchestrator mirrors the ledger into the PRD body (visibility, not enforcement)"
assert_contains "ledger section named" "$content" "## Mock-debt ledger"
assert_contains "label query is authoritative for the gate" "$content" "authoritative"

echo "test: the final report surfaces open mock-debt"
assert_contains "report mentions mock-debt" "$content" "mock-debt: N open"

# --- worktree isolation (step 0) -------------------------------------------
echo "test: step 0 runs the whole loop in one orchestration worktree"
assert_contains "step 0 enters an orchestration worktree via EnterWorktree" "$content" "EnterWorktree(name:"
assert_contains "base recorded before worktree entry" "$content" 'base=$(git rev-parse HEAD)'
assert_contains "worktree base drift guard resets to base" "$content" 'git reset --hard "$base"'
assert_contains "names the orchestration worktree" "$content" "orchestration worktree"
assert_contains "result is left on the orchestration branch" "$content" "orchestration branch"
assert_contains "merger is handed the orchestration-worktree path" "$content" "orchestration-worktree"
assert_contains "primary checkout is never touched" "$content" "primary checkout is never touched"
# worktreeOf() nests every per-issue worktree at <baseRepo>/.worktrees/issue-<N> — INSIDE the
# orchestration worktree's own working tree — and the setup agent now really creates them. Left
# untracked, they show up in `git status` during the merger's conflict resolution and its final
# done-check. Exclude them locally (never a tracked .gitignore edit in the user's repo).
assert_contains "the per-issue worktrees are excluded in the base repo" "$content" "info/exclude"
assert_contains "the excluded path is .worktrees/" "$content" "'.worktrees/'"

# --- Workflow-backed run (issue #63) ---------------------------------------
echo "test: frontmatter allows the Workflow tool"
assert_contains "Workflow tool allowed" "$content" "Workflow"

echo "test: frontmatter retains Skill + AskUserQuestion (classify backfill + PRD-close offer)"
assert_contains "Skill tool allowed" "$content" "Skill"
assert_contains "AskUserQuestion tool allowed" "$content" "AskUserQuestion"

echo "test: the run loop lives inside the Workflow, not on the main thread"
assert_contains "skill invokes the Workflow tool" "$content" "Workflow tool"
assert_contains "the run no longer executes on the main thread" "$content" "no longer runs the loop on the main thread"
assert_contains "Workflow permission dialog is the single launch gate" "$content" "single launch gate"

echo "test: the orchestration worktree base is passed into the Workflow, exited with keep"
assert_contains "orchestration worktree passed into the workflow as base" "$content" "passes the orchestration worktree"
assert_contains "ExitWorktree(keep) on return" "$content" "ExitWorktree(keep)"

echo "test: the workflow builds each admitted issue with one implementer"
assert_contains "one workflow:implementer per admitted issue" "$content" "workflow:implementer"

echo "test: completed branches go to the workflow:merger, merged issues are closed"
assert_contains "merger merges the completed branches" "$content" "workflow:merger"
assert_contains "merged issues are closed" "$content" "gh issue close"

# --- tier is a PERSISTED LABEL, read at launch, backfilled when missing ------
# The tier used to be a guess emitted by the same cheap haiku picker that listed
# the ready set — ungrounded, invisible, never persisted. Under-tiering routes real
# work to a model too cheap for it (bad builds, burned fix cycles). Now /to-issues
# sets `tier:<t>` at slice time and /orchestrate READS the label; a missing label is
# backfilled with the real classify-task skill (Explore-grounded) and WRITTEN BACK.
echo "test: the tier is a persisted GitHub label read at launch"
assert_contains "tier:trivial label named"  "$content" "tier:trivial"
assert_contains "tier:standard label named" "$content" "tier:standard"
assert_contains "tier:complex label named"  "$content" "tier:complex"
assert_contains "labels are read at launch" "$content" "Tier resolution"

echo "test: a missing tier label is backfilled via classify-task and persisted"
assert_contains "backfill runs the classify-task skill" "$content" "classify-task"
assert_contains "backfill runs classify in batch mode" "$content" "--no-confirm"
assert_contains "the backfilled tier is written back as a label" "$content" "gh issue edit <N> --add-label tier:"
assert_contains "the tier is auto-accepted, never confirmed" "$content" "Never prompt** to confirm or override a tier"
assert_contains "conflicting tier labels resolve to the highest" "$content" "highest tier wins"

echo "test: --complexity is GONE — the label is the only way to set a tier"
assert_not_contains "no --complexity flag" "$content" "--complexity"
assert_not_contains "no pinned-complexity workflow input" "$content" "complexity (pinned"

# --- the graph is fetched once; readiness is PLAIN JS, not a model call ------
# Readiness ("every `## Blocked by` ref closed") is a topological sweep over a DAG:
# pure computation the haiku picker could hallucinate. It was only an agent because
# a Workflow can't run gh. The main thread now fetches the whole graph at launch.
echo "test: the launch graph is fetched by scope-graph.sh (no picker agent)"
assert_contains "scope-graph helper invoked" "$content" 'scripts/scope-graph.sh'
assert_contains "graph is the workflow's world" "$content" "that JSON **is the workflow's world**"
assert_contains "graph carries each issue's blockedBy refs" "$content" "blockedBy"
assert_contains "graph carries the blocker states" "$content" "blockerStates"
assert_contains "the graph is frozen at launch" "$content" "frozen at launch"

echo "test: readiness is computed in plain JS — no model decides it"
assert_contains "isReady is plain script code" "$content" "isReady"
assert_contains "no model call for readiness" "$content" "no model call"
assert_not_contains "the haiku ready-set picker is gone" "$content" "picks and tiers the ready set in ONE cheap haiku call"
assert_not_contains "the READY_SCHEMA picker spawn is gone" "$content" "READY_SCHEMA"
assert_not_contains "no per-issue gh fetch by a picker" "$content" "gh issue view <N> --json number,title,labels,body,comments"
assert_not_contains "no repo-wide ready-for-agent sweep" "$content" "gh issue list --label ready-for-agent --state open"

# --- rounds are GONE: a continuous scheduler with --max N in flight ----------
echo "test: argument-hint takes --max N=5 (concurrency), not N rounds"
assert_contains "--max N=5 in argument-hint" "$content" "[--max N=5]"
assert_contains "--max is concurrency, not a batch size" "$content" "concurrent issues in flight"
assert_not_contains "the N-rounds argument is gone" "$content" "[N rounds=1]"
assert_not_contains "the old --max K=3 batch arg is gone" "$content" "[--max K=3]"

echo "test: the scheduler is continuous — a merge unblocks dependents, a slot refills"
assert_contains "scheduler section present" "$content" "## The scheduler"
assert_contains "a freed slot admits the next ready issue" "$content" "takes the slot"
assert_contains "no round barrier" "$content" "no round barrier"
assert_not_contains "no round loop remains" "$content" "for (let round"

echo "test: a failure DRAINS the run — in-flight issues finish, nothing new is admitted"
assert_contains "drain-then-stop named" "$content" "drain-then-stop"
assert_contains "no new issues are admitted while draining" "$content" "admit nothing new"
assert_contains "in-flight chains finish through merge" "$content" "finish through merge"
assert_contains "implementer failure drains the run" "$content" "implementer failure"
assert_contains "conflict-stop drains the run" "$content" "conflict-stop"
assert_contains "red done-check drains the run" "$content" "red done-check"

echo "test: merging stays SERIAL — one merge worker, one merger spawn at a time"
assert_contains "merge queue named" "$content" "merge queue"
assert_contains "merging is serial" "$content" "serial"
assert_contains "one merger runs at a time" "$content" "no merge is running"
assert_contains "merger handed the queue in ascending issue number" "$content" "ascending issue number"

# A slice that merged CAPPED (medium+ findings still open at --max-cycles) is known
# defective. Its dependents would unblock in-memory and build on top of it. The old
# round loop re-read GitHub each round, which gave this for free; the in-memory
# scheduler must hold them explicitly.
echo "test: dependents of a CAPPED merge are held for the rest of the run"
assert_contains "held set named" "$content" "added to **\`held\`**"
assert_contains "capped merge holds its direct dependents" "$content" "merged CAPPED holds its dependents"
assert_contains "the hold lasts the rest of the run" "$content" "stays held **for the rest of the run**"
assert_contains "the reason is a known-defective slice" "$content" "known-defective"
# `capRemainder` is an ARRAY of findings (step 8 must FILE them) — and `[]` is truthy.
# Testing it for truthiness would hold every clean merge's dependents for the whole run:
# the scope never drains and the run silently builds only the root issues.
assert_contains "the cap-remainder hold tests .length, not truthiness" "$js_block" "capRemainder?.length"

# --- per-issue in-workflow tier routing + launch-resolved ROSTER (#64, #53) ---
# orchestrate does not embed the tier table: the main thread resolves each tier via
# resolve-tier.sh at launch and inlines the values into ONE ROSTER const (placeholder
# form in prose, no literal model/effort values), indexed as
# ROSTER[issue.tier].<role>.model / .effort. The old *_MODEL maps are gone.
echo "test: launch-resolved ROSTER const replaces the embedded tier table + *_MODEL maps"
assert_contains "resolve-tier helper invoked" "$content" 'resolve-tier.sh'
assert_contains "launch-time ROSTER const" "$content" "const ROSTER"
assert_contains "resolved values never hand-written" "$content" "never hand-write"
assert_contains "efforts routed too (ROSTER carries .effort)" "$content" ".effort"
# Assemble the forbidden literals from fragments so these guards don't themselves
# reintroduce the strings the repo-wide drift-sweep forbids (tier row + *_MODEL maps).
BAR='|'
MMAP='_MODEL'
assert_not_contains "embedded tier table gone" "$content" "$BAR trivial $BAR sonnet $BAR sonnet $BAR opus $BAR"
assert_not_contains "old planner-model map gone" "$content" "PLANNER${MMAP}"
assert_not_contains "old implementer-model map gone" "$content" "IMPLEMENTER${MMAP}"
assert_not_contains "old reviewer-model map gone" "$content" "REVIEWER${MMAP}"

echo "test: the implementer model is routed by the issue's tier"
assert_contains "implementer tier-routed" "$content" "tier-routes its implementer"
assert_contains "implementer routed via ROSTER" "$content" "ROSTER[issue.tier].implementer"

echo "test: the merger is NOT tier-routed — its frontmatter opus pin governs"
assert_contains "merger not tier-routed" "$content" "not** tier-routed"

# --- tier-routed plan stage, standard/complex ONLY (issue #65, #53) --------
echo "test: a plan stage runs before the implementer/build stage"
assert_contains "plan step named in the prose" "$content" "Plan the standard/complex issues"
assert_contains "ROSTER routes the planner by tier" "$content" "ROSTER[issue.tier].planner"

echo "test: standard/complex are planned by workflow:planner; trivial skips the plan stage"
assert_contains "standard/complex use workflow:planner in plan mode" "$content" "mode: plan"
assert_contains "trivial gets no plan stage at all" "$content" "no plan stage"
assert_contains "trivial implementer self-plans instead" "$content" "self-plans"
assert_not_contains "the trivial minimal-plan leaf agent is gone" "$content" "minimal-plan"

echo "test: the plan is handed to the implementer as a work order"
assert_contains "implementer gets a work order" "$content" "work order"
assert_contains "plan replaces the implementer self-plan" "$content" "replaces the implementer's self-plan"

echo "test: the run stays autonomous — no plan comment, no plan-approval gate"
assert_contains "no plan comment posted to the issue" "$content" "no plan comment is posted to the issue"
assert_contains "no plan-approval gate fires" "$content" "no plan-approval gate fires"
# ALLOWLIST the one legitimate comment, rather than banning a phrase. A repo-wide substring ban
# on `gh issue comment` was too broad (it vetoed every OTHER comment the main thread makes — it
# already runs `gh issue close --comment`), but a `gh issue comment.*plan` regex is too narrow:
# it is line-scoped AND order-scoped, so an instruction split over two lines, or phrased "post
# the work order as a comment", sails straight through — the same prose-phrase grep this suite
# elsewhere condemns for passing with the feature deleted. So: every `gh issue comment` line in
# the skill must BE the conflict-stop write. Anything else — a plan comment included — fails.
non_conflict_comments="$(printf '%s\n' "$content" | grep -F -- 'gh issue comment' \
    | grep -Ev 'conflictStops|could not merge' || true)"
if [ -z "$non_conflict_comments" ]; then
    ok "the only gh issue comment in the skill is the conflict-stop write"
else
    no "a non-conflict-stop gh issue comment appears in the skill: $non_conflict_comments"
fi

# --- comments ride the work order ------------------------------------------
# A human (or a prior review) may leave the definitive answer as an issue comment.
# A body-only graph makes that guidance structurally invisible to the planner, the
# implementer AND the reviewer — they rediscover the open question and guess. This
# is what landed the wrong claim in #71.
echo "test: the graph carries each issue's comments, and they ride the work order"
assert_contains "graph carries comments alongside the body" "$content" "comments"
assert_contains "comments ride the work order into the planner" "$content" "body **and its comments**"
assert_contains "comment-blindness named as the failure mode" "$content" "comment-blind"

# --- per-issue my-review + mock-drift audit (#66) ---------------------------
echo "test: a per-issue my-review stage reviews each built slice"
assert_contains "my-review agent spawned per issue" "$content" "personal-tools:my-review"
assert_contains "review runs on the issue's branch diff" "$content" "issue-<N>"
assert_contains "findings surface in the final report" "$content" "findings"

echo "test: ROSTER routes the reviewer by tier"
assert_contains "reviewer routed via ROSTER" "$content" "ROSTER[issue.tier].reviewer"

echo "test: /orchestrate hard-deps on the my-review agent (fail loud at launch)"
assert_contains "hard-dependency on the personal-tools plugin" "$content" "personal-tools"
assert_contains "fail loud when my-review unavailable" "$content" "fail loud"

echo "test: the central-mechanism / mock-drift audit runs via my-review"
assert_contains "mock-drift audit named" "$content" "mock-drift"
assert_contains "central-mechanism audit named" "$content" "central-mechanism"

echo "test: the round-level workflow:reviewer agent is gone (no dangling refs)"
assert_not_contains "no workflow:reviewer agent" "$content" "workflow:reviewer"
assert_not_contains "no reference to the deleted reviewer.md" "$content" "reviewer.md"

# --- planner-free fix loop + finding filing + mock-debt (issue #67) ---------
echo "test: --max-cycles caps the per-issue fix loop (default 2, initial review free)"
assert_contains "--max-cycles in argument-hint" "$content" "[--max-cycles K=2]"
assert_contains "--max-cycles named in the body" "$content" "--max-cycles K"
assert_contains "fix-loop cap default 2" "$content" "default **2**"
assert_contains "initial review is free" "$content" "initial review is free"
assert_contains "cap counts re-reviews" "$content" "counts re-reviews"

echo "test: the fix loop is planner-free — the findings block IS the work order"
assert_contains "fix loop named planner-free" "$content" "Planner-free fix loop"
assert_contains "no planner spawns in the loop" "$content" "No planner runs in the fix loop"
assert_contains "findings block is the fix work order" "$content" "findings block itself is the fix work order"
assert_contains "criticals lead, then highs, then mediums" "$content" "criticals first"
assert_contains "low → filed, never fixed in-run" "$content" "never fixed in-run"
assert_not_contains "no per-critical plan cycle" "$content" "own full plan→implement→review cycle"
assert_not_contains "no collective high replan spawn" "$content" "ONE collective replan"
assert_not_contains "no triage spawn in the fix loop" "$content" "spawn **workflow:planner** in **mode=triage**"

echo "test: re-reviews cover only the fix delta; reviewer model held constant"
assert_contains "re-review scoped to the fix delta" "$content" "<pre-fix HEAD>..HEAD"
assert_contains "reviewer model held constant across re-reviews" "$content" "held constant"

echo "test: all-lows/clean passes; cap-exhausted-with-medium+ merges anyway (autonomous)"
assert_contains "all-lows passes the branch" "$content" "all-lows"
assert_contains "cap remainder merges the branch anyway" "$content" "merges anyway"
assert_contains "no interactive cap gate (autonomous)" "$content" "No cap gate"
assert_not_contains "no pipeline-style +1-cycle grant at the cap" "$content" "grant +1 cycle"

echo "test: the workflow files lows + cap-remainder as review-fix + ready-for-agent"
assert_contains "review-fix label filed by the workflow" "$content" "--label review-fix"
assert_contains "ready-for-agent label filed by the workflow" "$content" "--label ready-for-agent"
assert_contains "cap-remainder is filed as a follow-up" "$content" "cap-remainder"

echo "test: the workflow re-blocks dependents' ## Blocked by via gh issue edit"
assert_contains "dependent re-block uses gh issue edit" "$content" "gh issue edit"
assert_contains "re-block appends into the dependent's existing Blocked by" "$content" "into that dependent's existing"

# Bookkeeping is PER ISSUE and FIRE-AND-FORGET: it files as each issue clears, so a
# killed run keeps every filing made so far (an end-of-run batch would lose them
# all), and it never blocks the slot. Still pinned cheap — these are mechanical,
# ADDITIVE writes (file / append), never a close, never a delete.
echo "test: bookkeeping is one cheap haiku call per issue, fire-and-forget"
assert_contains "per-issue bookkeeping agent" "$content" "Per-issue bookkeeping"
assert_contains "bookkeeping does not block the slot" "$content" "fire-and-forget"
assert_contains "bookkeeping pinned to haiku" "$content" 'model: "haiku"'
assert_contains "bookkeeping never runs on the session model" "$content" "never the session model"
assert_contains "every bookkeeping promise is awaited before the workflow returns" "$content" "before the workflow returns"

# --- #77: scoped allowlist + main-thread close + re-admit guard --------------
# Two defects burned 1.84M tokens on a real run:
#   A. the ready set was a repo-wide `--label ready-for-agent` sweep, so it built
#      an unrelated issue (#101) into the PRD's branch.
#   B. the close ran inside a workflow subagent; a safety classifier killed it
#      (correctly — the subagent could not account for #101), the closes never
#      landed, the ready set never drained, and the loop rebuilt the same issues
#      at full cost.
echo "test: #77 defect A — the scope is an explicit allowlist, never repo-wide"
assert_contains "--prd / --issues scope in argument-hint" "$content" "[--prd N] [--issues N,N,...]"
assert_contains "scope resolved to an explicit issue allowlist" "$content" "explicit issue allowlist"
assert_contains "PRD children resolved via the prd-children helper" "$content" "prd-children.sh"
assert_contains "the allowlist is frozen at launch" "$content" "allowlist is frozen at launch"
assert_contains "the scheduler may only build the allowlist" "$content" "scope guard"

echo "test: #77 defect B — closes run on the main thread, not in a subagent"
assert_contains "close from the main thread stated" "$content" "Close from the main thread"
assert_contains "the workflow returns the merged-issue list instead of closing" "$content" "returns the merged-issue list"
assert_contains "an irreversible outward-facing write stays out of a subagent" "$content" "irreversible outward-facing"
assert_not_contains "the bookkeeping agent no longer closes issues" "$content" "close each merged issue"

echo "test: #77 — every close is verified by re-reading state, and fails loud if still open"
assert_contains "close verified by re-reading state" "$content" "gh issue view <N> --json state"
assert_contains "a silently-failed close is loud" "$content" "still open after its close"

echo "test: #77 — a re-admit guard makes the run convergent even if a close never lands"
assert_contains "merged-this-run map named" "$content" "mergedThisRun"
assert_contains "re-admit guard named" "$content" "re-admit guard"
assert_contains "already-merged issues are never re-admitted" "$content" "never re-admitted"

echo "test: #77 — lows are filed grouped and parked (no ready-for-agent, so nothing rebuilds them)"
assert_contains "lows parked without the ready-for-agent label" "$content" "parked"
assert_contains "lows filed grouped, one issue per slice" "$content" "one grouped"
assert_contains "nothing the run files can be built by the run" "$content" "nothing the run files can be built by the run"

echo "test: build->review->fix runs per issue with no cross-issue barrier"
assert_contains "per-issue chain named in the prose" "$content" "no cross-issue barrier"
assert_contains "review starts as soon as its build finishes" "$content" "As soon as an issue's build finishes"

echo "test: mock-debt filing stays my-review's job — the workflow does not re-file it"
assert_contains "mock-debt filing owned by my-review" "$content" "my-review OWNS"
assert_contains "workflow does not re-file mock-debt" "$content" "does not re-file mock-debt"

echo "test: review + fix loop run BEFORE the merge"
assert_contains "fix loop acts before the branch merges" "$content" "before it merges"
assert_contains "merge runs after the fix loop" "$content" "After the fix loop"

echo "test: end-of-run still mirrors the mock-debt ledger + prints a summary"
assert_contains "ledger mirror still present" "$content" "## Mock-debt ledger"
assert_contains "ledger summary still printed" "$content" "mock-debt: N open"

# --- the js schematic matches the real Workflow agent() API (issue #73) ------
# The JS block is a schematic the main thread transcribes into the script it hands
# the Workflow tool. Its call sites must match the runtime's actual signature:
#
#   agent(prompt, { model, effort, agentType, schema, ... })
#
# The single-object form agent({...}) passes everything as the *prompt* and no opts
# at all, so model/effort/agentType would be silently dropped and every spawn would
# fall back to session defaults. `subagent_type` is the Agent tool's key and means
# nothing here; the opts key is `agentType`. Bare agent() returns a string, so any
# spawn whose result is destructured needs `schema:`.
#
# The absence checks run against the ```js block ALONE (extracted at the top of this
# file), not the whole file: the surrounding prose deliberately names both wrong forms
# in order to warn about them, and must stay free to do so.

echo "test: schematic uses the real two-arg agent(prompt, opts) form"
if [ -n "$js_block" ]; then
    ok "js scheduler block extracted"
else
    no "js scheduler block not found in SKILL.md"
fi
assert_not_contains "single-object agent({...}) call form is gone" "$js_block" "agent({"
assert_contains "real signature is documented" "$content" "agent(prompt, opts)"

echo "test: schematic uses the Workflow opts key agentType, not subagent_type"
assert_contains "agentType is the opts key" "$js_block" "agentType:"
assert_not_contains "Agent-tool spelling subagent_type is gone" "$js_block" "subagent_type"

echo "test: structured-return spawns pass schema so their results are objects"
assert_contains "schema passed on structured-return spawns" "$js_block" "schema:"

echo "test: the schematic's scheduler races the in-flight chains (no round barrier)"
assert_contains "in-flight chains are raced, not barriered" "$js_block" "Promise.race"
assert_contains "concurrency capped by maxParallel" "$js_block" "maxParallel"

# --- args parse-or-throw, never silent-empty (issue #74) -------------------
# The Workflow tool may deliver the script's inputs as a JSON STRING, not an object.
# A blind `const { maxParallel } = args` then yields undefined and the scheduler
# falls through spawning nothing — a silent empty success (the #53/#70/#73 class).
# Step 1 must normalize args and parse-or-throw. The absence check is scoped to the
# ```js block alone (the prose is free to name the wrong form).
echo "test: Step 1 states args may arrive as a JSON string and must be normalized"
assert_contains "prose warns args may arrive as a JSON string" "$content" "may arrive as a JSON string"

echo "test: the schematic normalizes args (JSON-string tolerant) before reading them"
assert_contains "typeof-string normalization present" "$js_block" "typeof args === 'string'"

echo "test: the schematic parses-or-throws on malformed inputs (never falls through)"
assert_contains "parse-or-throw guard throws" "$js_block" "throw new Error"

echo "test: an empty graph throws — it never degrades into a repo-wide query"
assert_contains "empty-graph throw present" "$js_block" "graph.issues"

echo "test: the schematic never blind-destructures args"
assert_not_contains "no bare const { maxParallel } = args in the js block" "$js_block" "const { maxParallel } = args"

# --- SOMEBODY must create the per-issue worktree -----------------------------
# The hole this pins: the scheduler was told to run `git worktree add` itself, but a
# Workflow script CANNOT shell out, and both implementer.md and merger.md forbid
# creating a worktree. So the implementer was handed a path that did not exist and was
# forbidden to create it — every build would die on its first `git -C <nonexistent>` or
# improvise into the orchestration worktree, where N concurrent implementers interleave
# commits on ONE branch and no `issue-<N>` branch ever exists for the merger to merge.
#
# The owner is a cheap per-issue SETUP AGENT (agents can shell out; Workflow scripts
# cannot), spawned at ADMISSION as runIssue's first stage — not at launch, because a
# dependent must branch from a base that already holds its merged blocker.
echo "test: a per-issue setup agent creates the worktree — the scheduler cannot shell out"
assert_contains "the setup agent runs git worktree add, at the requested path" \
    "$js_block" 'worktree add ${worktreeOf(issue.n)}'
assert_contains "it cuts the issue-<N> branch from the base branch" "$js_block" '-b issue-${issue.n} ${baseBranch}'
# One mechanical git command — the same cheap class as the bookkeeper, and schema'd so
# the path comes back as an OBJECT rather than as prose the scheduler must re-parse.
assert_contains "the setup agent is pinned cheap and schema'd" \
    "$js_block" '{ model: "haiku", effort: "low", schema: SETUP_SCHEMA }'
assert_contains "a failed setup drains the run, like a failed build" "$js_block" "!setup || setup.failed"
# What feeds the chain is the path the SCHEDULER computed, not the model's echo of it. The echo is
# verified against that constant (verifyTree, below) and drains the chain on any other value — which
# is what makes it an improvisation detector, and equally what makes it information-free: past the
# check it can only BE the constant. Assigning the constant is therefore identical on every path
# that survives the check and strictly safer on the ones that do not (a trailing slash, a symlinked
# baseRepo, an omitted optional field would each drain a healthy run).
assert_contains "the chain is fed the path the SCHEDULER computed, not the model's echo" \
    "$js_block" "issue.worktree = worktreeOf(issue.n)"
assert_contains "...and the branch likewise" "$js_block" 'issue.branch   = `issue-${issue.n}`'
assert_contains "step 4 hands worktree creation to the setup agent" "$content" "setup agent"
assert_not_contains "step 4 no longer tells the SCHEDULER to create the worktree" \
    "$content" "Create the issue's worktree from the base branch"
# NOT `isolation:` — it yields a FRESH, UNNAMED worktree, so it cannot cut a branch
# named issue-<N> from a chosen base, which is exactly what the merger needs.
assert_not_contains "isolation opt is not the mechanism (it cannot name the branch)" "$js_block" "isolation:"

# --- every schema the schematic REFERENCES must be DEFINED in it ---------------
# The js block is transcribed VERBATIM. A spawn that passes `schema: BUILT_SCHEMA` with
# no definition in scope throws ReferenceError on the real run — the same crash class
# the mergeManifest / ghWriteManifest definitions exist to prevent. Leaving a schema to
# the transcriber to guess is leaving the contract to the transcriber to guess.
echo "test: every *_SCHEMA the schematic passes is defined in the block (no ReferenceError)"
assert_contains "SETUP_SCHEMA defined"  "$js_block" "const SETUP_SCHEMA"
assert_contains "BUILT_SCHEMA defined"  "$js_block" "const BUILT_SCHEMA"
assert_contains "REVIEW_SCHEMA defined" "$js_block" "const REVIEW_SCHEMA"
assert_contains "MERGE_SCHEMA defined"  "$js_block" "const MERGE_SCHEMA"
assert_contains "FILED_SCHEMA defined"  "$js_block" "const FILED_SCHEMA"
assert_contains "the schemas are real JSON Schema objects, not prose" "$js_block" 'type: "object"'

# --- the schematic must be genuinely RUNNABLE (prose bugs are real bugs) -----
# The js block is transcribed VERBATIM into the script handed to the Workflow tool, so
# a temporal-dead-zone reference, an undefined helper, or an unguarded await is a real
# crash on a real run — not a documentation nit.

# First line in the js block containing <needle>, or empty.
js_line() { printf '%s\n' "$js_block" | grep -n -m1 -F -- "$1" | cut -d: -f1; }
# <def> must be EVALUATED before <use> is reached. A `const` arrow does not hoist: it
# sits in the temporal dead zone until its declaration runs, so a call above it throws
# ReferenceError. (A `function` declaration does hoist — those are fine anywhere.)
assert_before() {
    local dl ul
    dl="$(js_line "$2")"; ul="$(js_line "$3")"
    if [ -n "$dl" ] && [ -n "$ul" ] && [ "$dl" -lt "$ul" ]; then
        ok "$1"
    else
        no "$1 (def at line '${dl:-MISSING}', first use at line '${ul:-MISSING}')"
    fi
}

echo "test: every const helper is declared before the scheduler loop reaches it (no TDZ)"
assert_before "absorbReview declared above the scheduler loop" "const absorbReview" "while (true)"
assert_before "mediumOrWorse declared above the scheduler loop" "const mediumOrWorse " "while (true)"
assert_before "orderFindings declared above the scheduler loop" "const orderFindings" "while (true)"
assert_before "mergeManifest declared above the scheduler loop" "const mergeManifest" "while (true)"
assert_before "ghWriteManifest declared above the scheduler loop" "const ghWriteManifest" "while (true)"
assert_before "log declared above the scheduler loop" "const log " "while (true)"
assert_before "SETUP_SCHEMA declared above the scheduler loop"  "const SETUP_SCHEMA"  "while (true)"
assert_before "BUILT_SCHEMA declared above the scheduler loop"  "const BUILT_SCHEMA"  "while (true)"
assert_before "REVIEW_SCHEMA declared above the scheduler loop" "const REVIEW_SCHEMA" "while (true)"
assert_before "MERGE_SCHEMA declared above the scheduler loop"  "const MERGE_SCHEMA"  "while (true)"
assert_before "FILED_SCHEMA declared above the scheduler loop"  "const FILED_SCHEMA"  "while (true)"
# isReady now BACKS a launch guard, so it must be declared above that guard too — not
# merely above the loop.
assert_before "isReady declared above the launch guard that calls it" \
    "const isReady" "!graph.issues.some(isReady)"

echo "test: the schematic defines every helper it calls — no guess-the-return-type"
assert_contains "mediumOrWorse defined (returns an ARRAY of findings)" "$js_block" "const mediumOrWorse"
assert_contains "mediumOrWorseOpen defined (returns a BOOLEAN)" "$js_block" "const mediumOrWorseOpen"
assert_contains "orderFindings defined (criticals, then highs, then mediums)" "$js_block" "const orderFindings"
assert_contains "mergeManifest defined (the merger's input contract)" "$js_block" "const mergeManifest"
assert_contains "ghWriteManifest defined (the bookkeeper's input contract)" "$js_block" "const ghWriteManifest"
# A Workflow script cannot shell out, so it cannot rev-parse. The pre-fix HEAD rides
# back on BUILT_SCHEMA instead of being read from git.
assert_not_contains "no revParse — a Workflow cannot run git" "$js_block" "revParse"
assert_contains "the pre-fix HEAD comes back on BUILT_SCHEMA" "$js_block" "let preFix = built.head"

echo "test: a bookkeeping failure never costs a close (allSettled, not all)"
assert_contains "bookkeeping is awaited with allSettled" "$js_block" "Promise.allSettled(bookkeeping)"
assert_not_contains "a rejecting filing must not discard the return" "$js_block" "Promise.all(bookkeeping)"
# allSettled alone makes a rejected filing INVISIBLE: nothing reads the settled array, so
# the cap-remainder is never filed, the dependents are never re-blocked, `followUps`
# reports [], and the NEXT run builds those dependents on unpaid debt — the dangerous
# direction. Catch at creation (which also closes the unhandled-rejection window) and
# carry the failure home.
assert_contains "a rejected filing is caught where it is created" "$js_block" ".catch(e =>"
assert_contains "bookkeeping failures ride home in the report" "$js_block" "bookkeepingFailures"
assert_contains "Step 2 prints the bookkeeping failures" "$content" "\`bookkeepingFailures\`"
# A .catch() only fires on a REJECTION — but a dead agent RETURNS NULL. `r?.filed || []` swallows
# that null into an empty filing: no bookkeepingFailures entry, followUps [], the cap-remainder
# never filed and the dependents never re-blocked, so the NEXT run builds them on unpaid debt.
# The likelier failure path must reach the same .catch.
assert_contains "a bookkeeper that returns NOTHING fails loudly (null != empty filing)" \
    "$js_block" "bookkeeper returned nothing"

# A model forced to satisfy `required` on a FAILURE path fabricates the fields. `worktree` /
# `branch` / `head` are only ever read after `failed` is checked — but a fabricated `head` would
# become the fix loop's delta base the moment `failed` is mis-set. Require only what a failure
# report genuinely has: the issue number and the flag.
echo "test: the failure-path schemas require only what a failed agent really knows"
assert_contains "SETUP_SCHEMA/BUILT_SCHEMA require only n + failed" "$js_block" 'required: ["n", "failed"]'
assert_not_contains "SETUP_SCHEMA no longer forces a worktree on a failure" \
    "$js_block" 'required: ["n", "worktree", "branch", "failed"]'
assert_not_contains "BUILT_SCHEMA no longer forces a head on a failure" \
    "$js_block" 'required: ["n", "branch", "worktree", "head", "failed"]'
# ...and with `head` optional, the delta base must degrade to the base branch, never to the
# string "undefined" in a `${preFix}..HEAD` range.
assert_contains "a missing head degrades the re-review to the full branch" "$js_block" "built.head || baseBranch"

echo "test: a dead merger drains the run — it never rejects the chain"
assert_contains "the merger's result is guarded before it is read" "$js_block" "if (!merged"
assert_contains "runIssue catches instead of rejecting its chain" "$js_block" "} catch ("
# Anchored on the DRAIN CALL inside the catch, not on the prose phrase "drain-then-stop,
# not kill" — that phrase predates the catch and would keep passing with the catch
# deleted, so it pinned the CLAIM, not the behaviour.
assert_contains "a caught chain failure drains rather than kills" "$js_block" "drain(\`chain failed on #"

# The BUILD path drains on `!built || built.failed`; the FIX path used to read only
# `fixed?.head`. A fix implementer reporting failed:true (red done-check) was a no-op:
# the loop re-reviewed, exhausted the cap, and the slice MERGED ANYWAY with a
# cap-remainder — a clean merge is not done-check gated (merger.md gates only the
# conflict resolutions and the final post-batch check), so a broken branch lands, its
# issue is CLOSED by the main thread, and the run drains on a red base.
echo "test: a failed FIX implementer drains too — a red branch must never merge"
assert_contains "the build implementer's failure drains" "$js_block" "!built || built.failed"
assert_contains "the fix implementer's failure drains" "$js_block" "!fixed || fixed.failed"

# EVERY spawn can die, and the schematic says so twice ("null = agent died", "A DEAD merger
# returns null"). A guard sweep that covers only the implementers leaves the two REVIEW spawns
# and the PLANNER unguarded — and those are the worst two to miss:
#   * a null review makes mediumOrWorse(null) → [], so mediumOrWorseOpen is false, the fix loop
#     is SKIPPED, capRemainder is [] and the slice merges as CLEAN — a dead reviewer merges an
#     UNREVIEWED slice and lets its dependents build on it;
#   * a null plan is indistinguishable from "trivial tier", so a dead planner on a COMPLEX issue
#     hands the implementer a prompt that says "Trivial tier — no planner ran: SELF-PLAN it".
echo "test: EVERY agent() spawn is guarded — a dead agent drains, never degrades silently"
assert_contains "a dead planner drains (null plan != trivial tier)" "$js_block" 'issue.tier !== "trivial" && !issue.plan'
assert_contains "a dead reviewer drains (initial review)" "$js_block" "!issue.review"
assert_contains "a dead re-reviewer drains (fix loop)" "$js_block" "review failed on #"
assert_contains "the guard sweep is audited in the block" "$js_block" "GUARD AUDIT"

echo "test: the merger's returned issue numbers are re-checked against the allowlist"
# A hallucinated number would otherwise become an irreversible `gh issue close` on an
# unrelated issue in Step 2.
assert_contains "out-of-allowlist merge results are dropped" "$js_block" "outside the run's allowlist"

# The conflict-stop path is the SAME trust boundary: Step 2 posts an outward-facing
# `gh issue comment` to every number the merger returns there, so a hallucinated number is an
# outward write on an unrelated issue. mergedIssues is allowlist-checked; conflictStops must be.
echo "test: conflict-stop issue numbers are allowlist-checked too (they drive an outward write)"
assert_contains "a conflict-stop outside the allowlist is dropped" "$js_block" "dropping conflict-stop"
assert_contains "the conflict-stop guard uses the same byNumber allowlist" "$js_block" "byNumber(cs?.n)"

# The worktree path and the branch are MODEL-SUPPLIED (a haiku setup agent, then an implementer
# echoing them back) and they drive `git -C <path>` for the reviewer, the fix implementer and the
# MERGER — which writes the base branch. worktree-guard.sh is a PreToolUse hook on Edit|Write only,
# so it does not fence an agent's Bash. The scheduler ASKED for an exact path, so it can check it.
echo "test: the reported worktree + branch are verified against the ones we asked for"
assert_contains "a verifier exists" "$js_block" "verifyTree"
assert_contains "it pins the path to worktreeOf(n)" "$js_block" "tree !== worktreeOf(issue.n)"
assert_contains "it pins the branch to issue-<N>" "$js_block" 'branch !== `issue-${issue.n}`'
assert_contains "setup's report is verified" "$js_block" 'verifyTree(issue, setup.worktree, setup.branch'
assert_contains "the build's report is verified too" "$js_block" "verifyTree(issue, built.worktree"

echo "test: no lost merge — a chain re-pumps until its issue leaves the queue"
# mergeWorker is cleared in a .finally() microtask AFTER runMerges exits its while
# check: a chain that pushes in that window rides an already-settled promise and frees
# its slot while its issue sits in the queue forever.
assert_contains "the chain re-pumps until its issue is out of the queue" "$js_block" "mergeQueue.includes(issue)"
assert_contains "the main loop drains the queue before breaking" "$js_block" "mergeWorker || mergeQueue.length"

echo "test: launch guards fail loud BEFORE any spawn is paid for"
assert_contains "an unfetchable scoped issue refuses the run" "$js_block" 'i.state === "unknown"'
# The guard must test READINESS, not openness. An all-open scope in which every issue is
# blocked by an unclosed OUT-OF-SCOPE issue (or by a `## Blocked by` ref aimed at a PR
# number, which scope-graph.sh resolves to "unknown" — never "closed"), or in which every
# issue is `hitl`-labelled, passes an openness guard, admits NOTHING, breaks on the first
# pass, and returns a clean `{ mergedIssues: [], stopReason: null }`. That reads as a
# clean drain: the silent-empty class, straight back through the front door.
assert_contains "NOTHING READY refuses the run (silent-empty class)" \
    "$js_block" "!graph.issues.some(isReady)"
assert_not_contains "the too-loose openness-only guard is gone" \
    "$js_block" '!graph.issues.some(i => i.state === "open")'
assert_contains "an untiered open issue refuses the run" "$js_block" "!ROSTER[i.tier]"
assert_contains "the empty/partial-scope refusal is loud" "$content" "fail loud before any spawn"

# ...but an empty ready set is not always a BROKEN scope, and a guard that cannot tell
# "nothing to do" from "the scope is broken" turns two LEGITIMATE states into a hard error:
#   * every scoped issue already closed — re-running `--prd N` after the last slice landed
#     (`unbuilt`'s own state filter exists precisely because `--issues` does no state filter);
#   * the only issues left are e2e-gate issues held by OPEN mock-debt — a DESIGNED state, the
#     exact one the mock-debt gate exists to produce.
# Both are clean empties with a stated reason. Throw only when the emptiness is UNEXPLAINED.
echo "test: a legitimately-complete or gate-held scope returns a clean empty, never a throw"
assert_contains "the empty ready set is CLASSIFIED before throwing" "$js_block" "Classify the emptiness"
assert_contains "an all-closed scope is a clean empty" "$js_block" "every scoped issue is already closed"
assert_contains "a mock-debt-held e2e-gate scope is a clean empty" "$js_block" "e2e-gate-held by open mock-debt"
# Anchored on the RETURN STATEMENT, not on the prose `{ mergedIssues: [], stopReason: null }` the
# comments above already quote — that string would pass with the early return deleted.
assert_contains "the clean empty returns the report's full shape" \
    "$js_block" "return { mergedIssues: [], stopReason: null, conflictStops: []"
assert_contains "the clean empty states its reason" "$js_block" "log(\`nothing to do:"
assert_contains "an UNEXPLAINED empty still throws" "$js_block" "refusing a silent empty success"

# Fail-loud is the right DEFAULT for an unfetchable issue, but with no escape hatch one
# deleted or renamed child makes a 20-slice PRD permanently unrunnable until its body is
# hand-edited.
echo "test: --skip-unknown lets one dead ref not hard-block a whole PRD"
assert_contains "--skip-unknown in the argument-hint" "$content" "[--skip-unknown]"
assert_contains "the guard honours the opt-in" "$js_block" "skipUnknown"
assert_contains "a skipped issue is still named in the log, never silently dropped" \
    "$js_block" "--skip-unknown"

# ...and the flag is INERT unless Step 1 actually hands it to the Workflow tool. Step 1 is the
# only place that says what the main thread passes in; the script reads `input.skipUnknown`, so a
# key missing from that list arrives `undefined` → skipUnknown = false → the throw always fires.
# Asserting the flag in the argument-hint and in the js block certifies a BROKEN chain unless the
# carrying link is asserted too. Every value the script reads off `input` must appear in Step 1.
echo 'test: every input the script reads off `input` is passed by Step 1'
for k in baseRepo baseBranch maxParallel maxCycles doneCheck graph skipUnknown; do
    assert_contains "Step 1 passes $k= to the Workflow tool" "$content" "\`$k="
done

echo "test: the spawn prompts interpolate real values, never placeholders"
assert_not_contains "no literal <base> placeholder in a prompt" "$js_block" "<base>.."
assert_contains "the review diff names the real base branch" "$js_block" '${baseBranch}..${issue.branch}'
# The setup agent's RETURNED path — not a computed guess — is what every later stage is
# handed, so a worktree created somewhere else than the scheduler assumed still works.
assert_contains "the fix implementer is handed the returned worktree path" "$js_block" 'worktree: ${issue.worktree}'
assert_contains "the fix implementer is handed the returned branch" "$js_block" 'branch: ${issue.branch}'
assert_contains "the fix implementer is handed the done-check" "$js_block" 'done-check: ${doneCheck}'
assert_contains "the merge manifest carries the returned worktree, not a guess" "$js_block" "i.worktree"

echo "test: bookkeeping only spawns when there is something to file"
assert_contains "fileFollowUps is guarded on lows/cap-remainder" "$js_block" "issue.lows?.length"

# --- the return value SERVES the report (Step 2's contract) ------------------
# Step 2's report demands each issue's tier, verdict, the HELD dependents, the lows /
# cap-remainder filed and the stop reason. A return of just { mergedIssues, stopReason }
# makes that report unimplementable — every other field dies inside the Workflow.
echo "test: the workflow return carries everything Step 2's report prints"
assert_contains "merged issues + their merge commits" "$js_block" "mergedIssues:"
assert_contains "the stop reason" "$js_block" "stopReason,"
assert_contains "the held dependents" "$js_block" "held: [...held]"
assert_contains "a per-issue record (tier, verdict, filings)" "$js_block" "perIssue:"
assert_contains "the issues never built" "$js_block" "unbuilt:"
assert_contains "the run log" "$js_block" "log: runLog"

# `unbuilt` reads as "scoped but never admitted — something went wrong". Sweeping in the
# issues that were ALREADY CLOSED at launch (reachable via --issues, which does no state
# filter) or that carry `hitl` / `prd` reports a non-problem as a problem.
echo "test: unbuilt names only issues that COULD have been built"
assert_contains "unbuilt excludes the closed and the label-excluded" "$js_block" "!i.attempted && i.state === \"open\""

# merger.md says "Any conflict-stopS" and continues through the batch, so ONE batch can
# stop on SEVERAL issues. A singular field keeps one and vanishes the rest — they land in
# perIssue as attempted, not in mergedIssues, not in unbuilt, with no reason given — and a
# later batch's stop OVERWRITES an earlier one while stopReason still names the first, so
# the report contradicts itself.
echo "test: conflict-stops are a LIST and are PUSHED, never overwritten"
assert_contains "the return carries a list of conflict-stops" "$js_block" "conflictStops,"
assert_contains "each stop is pushed, not assigned" "$js_block" "conflictStops.push"
assert_not_contains "the singular assignment is gone" "$js_block" "conflictStop = merged.conflictStop"
assert_contains "a stop carries the worktree to look in" "$js_block" "worktree"

echo "test: Step 2's report spec consumes exactly the returned fields"
assert_contains "report reads perIssue" "$content" "\`perIssue\`"
assert_contains "report reads held" "$content" "\`held\`"
assert_contains "report reads unbuilt" "$content" "\`unbuilt\`"
assert_contains "report reads the run log" "$content" "\`log\`"
# The table promises one row per SCOPED issue, but perIssue[] only holds the ATTEMPTED
# ones — a blocked or held issue has no row there. Tier must come from the main thread's
# own Step-0a scope record, which covers every scoped issue.
assert_contains "tier is sourced from the Step-0a scope, not perIssue" "$content" "Step-0a scope record"
assert_contains "an unattempted issue's verdict cell is explicitly empty" "$content" "no \`perIssue\` row"

# --- the re-block ref must PARSE (scope-graph's BARE_REF) --------------------
# The graph parser takes a blocker ref only as a whole line (`#N` or `- #N`). A haiku
# bookkeeper writing `- #99 — fix the parser nit` is then invisible to the next run's
# scheduler, which builds the dependent on unpaid debt — the dangerous direction.
echo "test: step 8 states the EXACT ## Blocked by ref format the graph parser reads"
assert_contains "bare ref, one per line" "$content" "bare \`#N\` on its own line"
assert_contains "no trailing prose on the ref line" "$content" "no trailing prose"

# --- the conflict-stop instruction must be implementable --------------------
# The old instruction ("comment that issue") named no owner: the Workflow cannot run gh,
# the merger is forbidden to comment, the bookkeeper only files. But the enumeration that
# concluded "so it is reported, not commented" OMITTED THE MAIN THREAD — which can, and
# already does (`gh issue close --comment`). Reasoning over an incomplete actor set until
# an action looks ownerless is precisely how the worktree hole above got built. Every
# actor is now named, and the owner is the main thread.
echo "test: a conflict-stop has a NAMED owner — the main thread comments it on return"
assert_not_contains "the ownerless comment instruction is gone" "$content" "comment that issue"
assert_contains "the conflict-stops are surfaced in the final report" "$content" "conflictStops"
assert_contains "the main thread is named as an actor that CAN comment" "$content" "the main thread **can**"
assert_contains "the main thread comments the stop on its issue" "$content" "gh issue comment <N>"
assert_contains "the comment names the worktree left intact" "$content" "left intact at <worktree>"

# --- the js block must actually PARSE (the only test of the ARTIFACT, not a string) ---------
# Everything above greps for strings INSIDE the block. A 519-line script transcribed verbatim
# into a real Workflow is one hand-edit away from a syntax error that no grep can catch, so
# parse it for real.
#
# The parse MODE is the subtle part, and the naive form is a NO-OP:
#   * the block opens with `export const meta`, so `node --check <file>.js` takes node's
#     module-detection path and exits 0 unconditionally — it passes a file containing
#     `const x = ;` (verified on node v22). A green "node --check" there proves nothing;
#   * the block is valid in NEITHER standard mode anyway: `export` is a syntax error in CJS,
#     and the block's top-level `return` is a syntax error in ESM. It has BOTH, plus top-level
#     `await` — a combination only an ASYNC FUNCTION BODY accepts, which is what the Workflow
#     runtime evidently runs it as.
# So reproduce the runtime's shape: drop the `export ` keyword, wrap the rest in an async
# function (top-level `return` and `await` are then both legal, and `args` gets bound), and use
# a .cjs extension so no detection path can silently swallow a broken file. A NEGATIVE CONTROL
# then proves the check is live: the same file with a syntax error appended MUST fail.
echo "test: the js scheduler block parses (real syntax check, not a grep)"
if ! command -v node >/dev/null 2>&1; then
    ok "SKIPPED: node not installed (the rest of the suite is pure bash — CI must not need node)"
elif [ -z "$js_block" ]; then
    no "js scheduler block not found — nothing to parse"
else
    tmpdir="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand tmpdir now, not at trap time
    trap "rm -rf '$tmpdir'" EXIT
    {
        printf 'async function __workflow(args) {\n'
        printf '%s\n' "$js_block" | sed 's/^export const meta/const meta/'
        printf '}\n'
    } > "$tmpdir/block.cjs"

    if node --check "$tmpdir/block.cjs" 2>"$tmpdir/err"; then
        ok "the js block parses as a Workflow async body"
    else
        no "the js block is not valid JavaScript: $(cat "$tmpdir/err")"
    fi

    # Negative control — if THIS passes, the syntax check above is vacuous and proves nothing.
    # Inject the error INSIDE the wrapper's body, not after its closing brace: appending it outside
    # would only prove the FILE is parsed strictly, when the claim under test is that an error in
    # the BLOCK is caught. (Either placement fails the parse — but only this one tests the claim.)
    {
        printf 'async function __workflow(args) {\n'
        printf 'const __deliberate_syntax_error = ;\n'
        printf '%s\n' "$js_block" | sed 's/^export const meta/const meta/'
        printf '}\n'
    } > "$tmpdir/broken.cjs"
    if node --check "$tmpdir/broken.cjs" >/dev/null 2>&1; then
        no "node --check is a NO-OP here (it passed a file with a syntax error) — the check above proves nothing"
    else
        ok "negative control: node --check really does reject a broken block"
    fi
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
