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
#  11. The offer/note appears only end-of-run — mid-loop rounds are uninterrupted.
#  12. The skill never edits the PRD body.
#  13. (issue #63) The skill invokes the Workflow tool for the round loop — the
#      round no longer runs on the main thread, the Workflow permission dialog is
#      the single launch gate, the orchestration worktree is passed in as the
#      base and exited via ExitWorktree(keep), and the workflow runs
#      build (workflow:implementer, up to K) -> merge (workflow:merger) -> close,
#      stopping on an empty ready set / conflict-stop / red done-check /
#      implementer failure.
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

# ---------------------------------------------------------------------------
echo "test: skill file exists at the expected discovery path"
if [ -f "$SKILL_FILE" ]; then
    ok "SKILL.md present at skills/orchestrate/SKILL.md"
else
    no "SKILL.md missing at $SKILL_FILE"
fi

# Read the file once for all content checks.
content=""
if [ -f "$SKILL_FILE" ]; then
    content="$(cat "$SKILL_FILE")"
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
echo "test: prd-reap step is end-of-run only (after all rounds)"
assert_contains "end-of-run placement stated" "$content" "After **all rounds**"

# ---------------------------------------------------------------------------
echo "test: mid-loop rounds are uninterrupted"
assert_contains "mid-loop uninterrupted stated" "$content" "never interrupt mid-loop rounds"

# --- mock-debt gate (C7) ---------------------------------------------------
echo "test: ready-rule holds the e2e-gate while mock-debt is open"
assert_contains "e2e-gate referenced in ready-rule" "$content" "e2e-gate"
assert_contains "mock-debt gate tag present" "$content" "Mock-debt gate (C7)"
assert_contains "mock-debt label query is the gate" "$content" "--label mock-debt --state open"
assert_contains "gate holds while debt open" "$content" "not ready"

echo "test: orchestrator mirrors the ledger into the PRD body (visibility, not enforcement)"
assert_contains "ledger section named" "$content" "## Mock-debt ledger"
assert_contains "label query is authoritative for the gate" "$content" "authoritative"

echo "test: round report surfaces open mock-debt"
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

# --- Workflow-backed round (issue #63) -------------------------------------
echo "test: frontmatter allows the Workflow tool"
assert_contains "Workflow tool allowed" "$content" "Workflow"

echo "test: frontmatter retains Skill + AskUserQuestion (end-of-run PRD-close offer)"
assert_contains "Skill tool allowed" "$content" "Skill"
assert_contains "AskUserQuestion tool allowed" "$content" "AskUserQuestion"

echo "test: argument-hint parses N rounds and --max K"
assert_contains "N rounds + --max K in argument-hint" "$content" "[N rounds=1] [--max K=3]"

echo "test: the round loop runs inside the Workflow, not on the main thread"
assert_contains "skill invokes the Workflow tool" "$content" "Workflow tool"
assert_contains "round no longer runs on the main thread" "$content" "no longer runs the round on the main thread"
assert_contains "Workflow permission dialog is the single launch gate" "$content" "single launch gate"

echo "test: the orchestration worktree base is passed into the Workflow, exited with keep"
assert_contains "orchestration worktree passed into the workflow as base" "$content" "passes the orchestration worktree"
assert_contains "ExitWorktree(keep) on return" "$content" "ExitWorktree(keep)"

echo "test: the workflow builds up to K issues, one implementer each"
assert_contains "up to K issues per round" "$content" "up to **K**"
assert_contains "one workflow:implementer per picked issue" "$content" "workflow:implementer"

echo "test: completed branches go to the workflow:merger, merged issues are closed"
assert_contains "merger merges the completed branches" "$content" "workflow:merger"
assert_contains "merged issues are closed" "$content" "gh issue close"

echo "test: the ready-set stage reads each issue's comments, not just its body"
# A human (or a prior review) may leave the definitive answer as an issue
# comment. Fetching body-only makes that guidance structurally invisible to the
# planner, the implementer AND the reviewer — they rediscover the open question
# and guess. This is what landed the wrong claim in #71.
assert_contains "ready-set fetches comments alongside the body" "$content" \
    "--json number,title,labels,body,comments"
# The old body-only fetch ended at `body` + closing backtick. Pin its absence.
assert_not_contains "no body-only ready-set fetch" "$content" 'number,title,labels,body`'
assert_contains "READY_SCHEMA carries comments + tier" "$content" "{ n, title, body, comments, tier }"
assert_contains "comments ride the work order into the planner" "$content" \
    "body **and its comments**"
assert_contains "comment-blindness named as the failure mode" "$content" "comment-blind"

echo "test: stop conditions — empty ready set / conflict-stop / red done-check / implementer failure"
assert_contains "empty ready set stops the loop" "$content" "empty ready set"
assert_contains "conflict-stop stops the loop" "$content" "conflict-stop"
assert_contains "red done-check stops the loop" "$content" "red done-check"
assert_contains "implementer failure stops the loop" "$content" "implementer failure"

# --- per-issue in-workflow classify + launch-resolved ROSTER (issue #64, #53) --
# orchestrate no longer embeds the tier table: the main thread resolves each
# tier via resolve-tier.sh at launch and inlines the values into ONE ROSTER
# const (placeholder form in prose, no literal model/effort values), indexed as
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

echo "test: --complexity escape hatch pins every issue and skips classification"
assert_contains "--complexity in argument-hint" "$content" "[--complexity trivial|standard|complex]"
assert_contains "--complexity pins every issue" "$content" "pins every issue"
assert_contains "--complexity skips classification" "$content" "skips classification"

# Classification RIDES the ready-set pick: the ONE haiku call that lists the
# ready issues emits each issue's tier in the same pass. No per-issue classify
# agents, no explore stage — dedicated agents to produce a one-word routing hint
# cost more than the routing saved (the 3-issue/41-agent run). The picker is
# pinned to haiku (NOT tier-routed: routing is what it is deciding, and an
# unpinned picker silently runs on the session model).
echo "test: the ready-set picker tiers every issue in the same single haiku call"
assert_contains "pick and tier merged into one call" "$content" "picks and tiers the ready set in ONE cheap haiku call"
assert_contains "picker pinned to haiku" "$content" 'model: "haiku"'
assert_contains "picker emits a real tier" "$content" "real tier"
assert_contains "no per-issue classify agent" "$content" "no per-issue classify agent"
assert_not_contains "the explore→classify two-stage pass is gone" "$content" "explore→classify"
assert_not_contains "no separate explore agent per issue" "$content" "Explore issue #"
assert_not_contains "the per-issue CLS_SCHEMA classify spawn is gone" "$content" "CLS_SCHEMA"

echo "test: classification is auto-accepted with no interactive confirm"
assert_contains "tier auto-accepted" "$content" "auto-accepted"
assert_contains "no interactive confirm" "$content" "no interactive confirm"

echo "test: the implementer model is routed by the issue's tier"
assert_contains "implementer tier-routed" "$content" "tier-routes its implementer"
assert_contains "implementer routed via ROSTER" "$content" "ROSTER[issue.tier].implementer"

# --- tier-routed plan stage, standard/complex ONLY (issue #65, #53) --------
# A plan stage runs AFTER classify and BEFORE the implementer fan-out, but ONLY
# for standard/complex issues (workflow:planner mode=plan at
# ROSTER[issue.tier].planner). A TRIVIAL issue gets NO plan stage: the issue body
# is the work order and the implementer self-plans, which its own contract
# already covers — a planner spawn there just restated the issue. The plan is
# handed to the implementer as its work order, and the run stays autonomous — no
# plan comment, no plan gate.
echo "test: a plan stage runs before the implementer/build stage"
assert_contains "plan step named in the round prose" "$content" "Plan the standard/complex issues"
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
assert_not_contains "plan is never posted as an issue comment" "$content" "gh issue comment"

# --- per-issue my-review + mock-drift audit; round reviewer removed (#66) ---
# Each built slice is reviewed by personal-tools:my-review at the tier's
# reviewer {model, effort} (ROSTER[issue.tier].reviewer), my-review runs the
# central-mechanism / mock-drift audit, /orchestrate hard-deps on the my-review
# agent (fail loud at launch), and the round-level workflow:reviewer agent is
# gone — no dangling references survive.
echo "test: a per-issue my-review stage reviews each built slice"
assert_contains "my-review agent spawned per issue" "$content" "personal-tools:my-review"
assert_contains "review runs on the issue's branch diff" "$content" "issue-<N>"
assert_contains "findings surface in the round report" "$content" "findings"

echo "test: ROSTER routes the reviewer by tier"
assert_contains "reviewer routed via ROSTER" "$content" "ROSTER[issue.tier].reviewer"

echo "test: /orchestrate hard-deps on the my-review agent (fail loud at launch)"
assert_contains "hard-dependency on the personal-tools plugin" "$content" "personal-tools"
assert_contains "fail loud when my-review unavailable" "$content" "fail loud"

echo "test: the central-mechanism / mock-drift audit runs via my-review"
assert_contains "mock-drift audit named" "$content" "mock-drift"
assert_contains "central-mechanism audit named" "$content" "central-mechanism"

echo "test: the round-level workflow:reviewer agent is gone (no dangling refs)"
assert_not_contains "no workflow:reviewer round agent" "$content" "workflow:reviewer"
assert_not_contains "no reference to the deleted reviewer.md" "$content" "reviewer.md"
assert_not_contains "no stale 'per-issue review lands later' prose" "$content" "lands in a later slice"

# --- planner-free fix loop + finding filing + mock-debt (issue #67) ---------
# The round ACTS on findings via a per-issue fix loop capped by --max-cycles
# (default 2), BEFORE the branch merges. NO planner runs in the loop: a finding
# already names the path, the defect and the fix, so the findings block itself is
# the implementer's work order (criticals first, then highs, then mediums, each
# ascending by path); low→file. All-lows/clean passes; cap-exhausted-with-medium+
# files those as review-fix follow-ups and merges anyway (autonomous — no cap
# gate). The workflow files lows + cap-remainder and re-blocks dependents;
# mock-debt filing stays my-review's job.
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

echo "test: workflow files lows + cap-remainder as review-fix + ready-for-agent"
assert_contains "review-fix label filed by the workflow" "$content" "--label review-fix"
assert_contains "ready-for-agent label filed by the workflow" "$content" "--label ready-for-agent"
assert_contains "cap-remainder is filed as a follow-up" "$content" "cap-remainder"

echo "test: workflow re-blocks dependents' ## Blocked by via gh issue edit"
assert_contains "dependent re-block uses gh issue edit" "$content" "gh issue edit"
assert_contains "re-block appends into the dependent's existing Blocked by" "$content" "into that dependent's existing"

# The round's ADDITIVE gh writes (follow-up filings, dependent re-blocks) are
# mechanical templating over text the round already produced — they batch into
# ONE haiku agent instead of unpinned per-item spawns on the session model.
# The CLOSES are NOT among them: see the #77 block below — an irreversible
# outward-facing write does not belong in a low-context subagent.
echo "test: filings + re-blocks batch into one cheap haiku bookkeeping agent"
assert_contains "one bookkeeping agent for the additive gh writes" "$content" "ONE haiku agent for the round's additive gh writes"
assert_contains "bookkeeping spawn pinned cheap in the script" "$content" "never the session model"

# --- #77: PRD-scoped ready set + main-thread close + re-pick guard ----------
# Two defects burned 1.84M tokens on a real run:
#   A. the ready set was a repo-wide `--label ready-for-agent` sweep, so it built
#      an unrelated issue (#101) into the PRD's branch.
#   B. the close ran inside a workflow subagent; a safety classifier killed it
#      (correctly — the subagent could not account for #101), the closes never
#      landed, the ready set never drained, and rounds 2-5 rebuilt the same
#      issues at full cost.
echo "test: #77 defect A — the ready set is scoped to an explicit allowlist, never repo-wide"
assert_contains "--prd / --issues scope in argument-hint" "$content" "[--prd N] [--issues N,N,...]"
assert_contains "scope resolved to an explicit issue allowlist" "$content" "explicit issue allowlist"
assert_contains "PRD children resolved via the prd-children helper" "$content" "prd-children.sh"
assert_contains "the allowlist is frozen at launch" "$content" "allowlist is frozen at launch"
# The repo-wide sweep is the bug. The picker now reads only the allowlisted issues.
assert_not_contains "no repo-wide ready-for-agent sweep" "$content" "gh issue list --label ready-for-agent --state open"
assert_contains "picker reads only the allowlisted issues" "$content" "gh issue view <N> --json number,title,labels,body,comments"

echo "test: #77 defect B — closes run on the main thread, not in a subagent"
assert_contains "close from the main thread stated" "$content" "Close from the main thread"
assert_contains "the workflow returns the merged-issue list instead of closing" "$content" "returns the merged-issue list"
assert_contains "an irreversible outward-facing write stays out of a subagent" "$content" "irreversible outward-facing"
assert_not_contains "the bookkeeping agent no longer closes issues" "$content" "close each merged issue"

echo "test: #77 — every close is verified by re-reading state, and fails loud if still open"
assert_contains "close verified by re-reading state" "$content" "gh issue view <N> --json state"
assert_contains "a silently-failed close is loud" "$content" "still open after its close"

echo "test: #77 — a re-pick guard makes the loop convergent even if a close never lands"
assert_contains "merged-this-run set named" "$content" "mergedThisRun"
assert_contains "re-pick guard named" "$content" "re-pick guard"
assert_contains "already-merged issues are excluded from later rounds" "$content" "excluded from every later round"

echo "test: #77 — lows are filed grouped and parked (no ready-for-agent, so nothing rebuilds them)"
assert_contains "lows parked without the ready-for-agent label" "$content" "parked"
assert_contains "lows filed grouped, one issue per slice" "$content" "one grouped"
assert_contains "nothing the run files can be built by the run" "$content" "nothing the run files can be built by the run"

# Build -> review -> fix runs as ONE pipeline per issue, no cross-issue barrier:
# issue A can be in its fix loop while issue B still builds.
echo "test: build->review->fix pipelines per issue with no cross-issue barrier"
assert_contains "per-issue pipeline named in the prose" "$content" "no cross-issue barrier"
assert_contains "review starts as soon as its build finishes" "$content" "As soon as an issue's build finishes"

echo "test: mock-debt filing stays my-review's job — the workflow does not re-file it"
assert_contains "mock-debt filing owned by my-review" "$content" "my-review OWNS"
assert_contains "workflow does not re-file mock-debt" "$content" "does not re-file mock-debt"

echo "test: round reorder — review + fix loop run BEFORE the merge"
assert_contains "fix loop acts before the branch merges" "$content" "before it merges"
assert_contains "merge runs after the fix loop" "$content" "After the fix loop"

echo "test: end-of-run still mirrors the mock-debt ledger + prints a summary"
assert_contains "ledger mirror still present" "$content" "## Mock-debt ledger"
assert_contains "ledger summary still printed" "$content" "mock-debt: N open"

# --- round-loop schematic matches the real Workflow agent() API (issue #73) --
# The JS block is a schematic the main thread transcribes into the script it
# hands the Workflow tool. Its call sites must therefore match the runtime's
# actual signature:
#
#   agent(prompt, { model, effort, agentType, schema, ... })
#
# The single-object form agent({...}) passes everything as the *prompt* and no
# opts at all, so model/effort/agentType would be silently dropped and every
# spawn would fall back to session defaults. `subagent_type` is the Agent
# tool's key and means nothing here; the opts key is `agentType`. Bare agent()
# returns a string, so any spawn whose result is destructured needs `schema:`.
#
# The absence checks run against the ```js block ALONE, not the whole file: the
# surrounding prose deliberately names both wrong forms in order to warn about
# them, and must stay free to do so.
js_block=""
if [ -f "$SKILL_FILE" ]; then
    js_block="$(awk '/^```js$/{inblock=1; next} /^```$/{inblock=0} inblock' "$SKILL_FILE")"
fi

echo "test: schematic uses the real two-arg agent(prompt, opts) form"
if [ -n "$js_block" ]; then
    ok "js round-loop block extracted"
else
    no "js round-loop block not found in SKILL.md"
fi
assert_not_contains "single-object agent({...}) call form is gone" "$js_block" "agent({"
assert_contains "real signature is documented" "$content" "agent(prompt, opts)"

echo "test: schematic uses the Workflow opts key agentType, not subagent_type"
assert_contains "agentType is the opts key" "$js_block" "agentType:"
assert_not_contains "Agent-tool spelling subagent_type is gone" "$js_block" "subagent_type"

echo "test: structured-return spawns pass schema so their results are objects"
assert_contains "schema passed on structured-return spawns" "$js_block" "schema:"

echo "test: pipeline() receives the item list plus a stage callback"
assert_contains "pipeline takes items + stage callbacks" "$js_block" "pipeline(picked,"
assert_not_contains "pre-started promise array is gone" "$js_block" "pipeline(picked.map("

# --- args parse-or-throw, never silent-empty (issue #74) -------------------
# The Workflow tool may deliver the script's inputs as a JSON STRING, not an
# object. A blind `const { rounds } = args` then yields undefined and the round
# loop falls through spawning nothing — a silent empty success (the #53/#70/#73
# class). Step 1 must normalize args and parse-or-throw. The absence check is
# scoped to the ```js block alone (the prose is free to name the wrong form).
echo "test: Step 1 states args may arrive as a JSON string and must be normalized"
assert_contains "prose warns args may arrive as a JSON string" "$content" "may arrive as a JSON string"

echo "test: the schematic normalizes args (JSON-string tolerant) before reading them"
assert_contains "typeof-string normalization present" "$js_block" "typeof args === 'string'"

echo "test: the schematic parses-or-throws on malformed rounds (never falls through)"
assert_contains "parse-or-throw guard throws" "$js_block" "throw new Error"

echo "test: the schematic never blind-destructures args"
assert_not_contains "no bare const { rounds } = args in the js block" "$js_block" "const { rounds } = args"

echo "test: implementer spawns don't set isolation (worktree is created in step 4 prose)"
assert_not_contains "isolation opt is gone from implementer spawns" "$js_block" "isolation:"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
