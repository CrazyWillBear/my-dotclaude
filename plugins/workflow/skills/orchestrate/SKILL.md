---
name: orchestrate
description: Run N rounds of the autonomous issue-solving loop, backed by a Workflow script — pick the ready set (blockers closed, skip hitl/prd, hold the e2e-gate while any mock-debt is open), build up to K ready issues in parallel via workflow:implementer agents in isolated git worktrees, merge the completed branches serially via a workflow:merger under the project done-check, and close the merged issues. Use for "/orchestrate", "run the loop", "build the ready issues".
argument-hint: "[N rounds=1] [--max K=3] [--complexity trivial|standard|complex]"
effort: high
allowed-tools: Read, Grep, Bash, Workflow, AskUserQuestion
---

Run the autonomous issue-solving loop on this repo's GitHub issues.
`$ARGUMENTS` = `[N] [--max K] [--complexity trivial|standard|complex]` — **N** rounds (default 1);
**K** = max issues built in parallel per round (default 3); **`--complexity <tier>`** pins every
issue to that tier and skips per-issue classification (see below).

Backend is **GitHub Issues via `gh`** — no `gh api`, no PR merges. Never touch issues labeled
`hitl` (needs a human) or `prd` (a PRD tracking doc — slice it with `/to-issues` first). Never
push.

**The round loop runs inside a Workflow.** This skill body does the one-time Step 0 / Setup, then
hands the whole per-round loop — pick, build, merge, close — to a committed Workflow script via the
**Workflow** tool. The skill body itself **never spawns `Agent` calls**; the workflow's phase
agents do. The **Workflow permission dialog is the single launch gate** — once you approve it, the
run is autonomous until it returns.

## Step 0 — enter the orchestration worktree (once, before Setup)
The **whole run executes in one worktree** so the merger writes to a linked worktree (the
`PreToolUse` guard allows that) and the **primary checkout is never touched**. Decide by where you
are now — canonicalize both with `realpath` first, since git may print a relative `.git`:
- **In the primary checkout** (`git rev-parse --git-dir` and `--git-common-dir` resolve to the
  **same** path) → record `base=$(git rev-parse HEAD)` **before** the call, then call
  **`EnterWorktree(name: "orchestrate-<n>")`** with a unique `<n>` (e.g.
  `orchestrate-$(date +%s)`). This creates `.claude/worktrees/orchestrate-<n>` on branch
  `orchestrate-<n>` and switches this session into it. The branch point follows the
  `worktree.baseRef` setting: `head` (which the kit's setup scripts install) uses the current
  `HEAD`, but the built-in default is `fresh` = `origin/<default-branch>`, which silently drops
  local commits. So **verify the base after entering**: if `git rev-parse HEAD` ≠ `$base`, run
  `git reset --hard "$base"` — the worktree is brand-new, so the reset is safe.
- **Already in a linked worktree** (the two **differ**) → **skip**; this worktree is already
  isolated and *is* the orchestration worktree. (`EnterWorktree(name:…)` refuses to nest a new
  worktree while you're in a worktree session anyway.)

Everything below runs **from the orchestration worktree**. The result is **left on the
orchestration branch** for you to merge into `dev`/`main` yourself — the run never merges back to
the launch branch and never removes the orchestration worktree.

## Setup (once, before the run)
- **Base branch** = the current branch (the **orchestration branch** from Step 0):
  `git rev-parse --abbrev-ref HEAD`. Every per-issue worktree branches from it and merges back into
  it; the merged result stays on it.
- **Orchestration-worktree path** = `git rev-parse --show-toplevel` — the **absolute** path of this
  linked worktree. It is the workflow's `base`: the repo the pick agent cuts child worktrees under
  and the merger writes to.
- **Locally exclude worktrees** so they don't dirty the tree: append `.worktrees/` to
  `"$(git rev-parse --git-dir)"/info/exclude` if not already there (a local exclude — doesn't
  modify the tracked `.gitignore`).
- **Locate the project done-check** — the single command that runs the project's tests / linter /
  type-checker (from its `CLAUDE.md` / `STYLEGUIDE.md` / config). The merger gates every conflict
  resolution on it, so it is required; if the project defines none, **say so** and stop rather than
  running the loop blind.

## Run the workflow
Invoke the **Workflow** tool **once**, pointing it at the committed script that drives the round
loop:

- **`scriptPath`** = `<this skill's directory>/orchestrate.workflow.js` — resolve the skill dir via
  `$CLAUDE_PLUGIN_ROOT` when it's set (`$CLAUDE_PLUGIN_ROOT/skills/orchestrate/orchestrate.workflow.js`),
  else the directory this `SKILL.md` lives in.
- **`args`**:

  ```
  {
    base:       "<orchestration-worktree path from git rev-parse --show-toplevel>",
    baseBranch: "<base branch from Setup>",
    rounds:     N,          // from $ARGUMENTS (default 1)
    max:        K,          // from --max (default 3)
    doneCheck:  "<the project done-check command>",
    complexity: <tier|undefined>  // from --complexity: pins every issue, skips classify
  }
  ```

Approving the **Workflow permission dialog** is the **single launch gate**; after it the run is
autonomous. Each round the script runs five phases:

1. **pick** — a Bash-capable agent computes the ready set (`--label ready-for-agent --state open`;
   every `## Blocked by` ref closed; skip `hitl`/`prd`; **hold any `e2e-gate` issue while an open
   `mock-debt` issue exists**), takes up to **K** lowest-numbered issues, and cuts each a
   deterministic worktree `.worktrees/issue-<N>` on branch `issue-<N>`.
2. **classify** — one cheap leaf agent per ready issue **explores then classifies** it into a
   complexity tier (trivial / standard / complex), and the workflow **routes that issue's
   implementer model** by tier. The returned tier is **auto-accepted** — no interactive confirm,
   since the run is autonomous after the launch gate. **`--complexity <tier>`** pins every issue to
   that tier and skips this phase entirely. The tier → model routing table is embedded in
   `orchestrate.workflow.js` byte-identical to the one in the `classify-task` and `pipeline` skills;
   only the **implementer** column is used here (the loop has no per-issue planner/reviewer yet).
3. **build** — up to K **`workflow:implementer`** agents run **in parallel**, one per ready issue,
   each in its own worktree on the tier-routed model: plan, build TDD-first, run the done-check,
   commit.
4. **merge** — the completed branches (acceptance met **and** done-check green) go to one
   **`workflow:merger`** agent, which merges them serially in **ascending** issue number and
   resolves conflicts **gated by the done-check**.
5. **close** — a Bash-capable agent closes each merged-green issue (`gh issue close … --comment`)
   and reclaims its child worktree; failures and conflict-stops are commented, their worktrees left
   intact.

**Stop rules.** An **empty ready set**, a **merger conflict-stop** (unresolvable conflict or a red
done-check after resolution), a **red final done-check**, or an **implementer failure** each
**stops the loop** — the close phase still runs first so green issues close, then the run returns a
`stopReason`. Otherwise it continues until **N** rounds finish or the ready set drains.

## Report
From the workflow's returned summary (`roundsRun`, `perIssue`, `closed`, `stopReason`, `mockDebt`),
print a **status table**: issue `#` → title → merged? / closed? → done-check → notes (any declared
`mock-debt` lines, conflicts, failures). Name the `stopReason` if the loop stopped early. If any
implementer declared `mock-debt`, list those lines so a follow-up can be filed (per-issue review
returns in a later slice).

**Where the work lives.** All merged rounds land on the **orchestration branch** inside the
orchestration worktree — never on the launch branch and never in the primary checkout. End the
report by naming that branch + worktree path and telling me to merge it into `dev`/`main` when I'm
satisfied.

## End-of-run: PRD reap

After **all rounds** finish (or the loop stops), collect every issue number closed during this
run and pass them to the reap helper. Locate the repo root with
`git rev-parse --show-toplevel`, then run:

```
bash <repo-root>/plugins/workflow/scripts/prd-reap.sh <N1> [N2 ...]
```

The helper prints one line per finding to stdout:

- `ready <prd_number>` — every child slice of that PRD is closed; the PRD is eligible
  to close.
- `blocked <prd_number> hitl <hitl_N> [hitl_N ...]` — the only open children carry the
  `hitl` label; a human must review before closing.

**If the helper prints nothing**, the final report is unchanged — do not add any prompt
or mention of PRDs. The autonomous contract is fully preserved for runs where no PRD
qualifies.

**For each `ready` PRD**, add an offer to the final report (never auto-close):

> PRD #N appears complete — all child slices are closed. Close it? (yes/no)

On **yes**: run `gh issue close <N> --comment "All child slices are closed — closing this PRD."`.
Never edit the PRD's spec content or delete the issue. (The mock-debt ledger mirror returns with
the per-issue reviewer in a later slice.)

**For each `blocked` PRD**, note it in the final report without offering to close:

> PRD #N is blocked — open `hitl` issue(s): #H [#H …] need human review before closing.

These PRD offers and notes appear only in the **final report**, after all rounds. They
never interrupt mid-loop rounds.

## Finish
After the report and any PRD offers, if Step 0 entered a fresh worktree, call `ExitWorktree(keep)`
to return to the original directory with the orchestration branch intact (or the session-exit
prompt offers keep/remove). If you were already in a linked worktree, leave it in place.
