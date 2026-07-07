---
name: orchestrate
description: Run N rounds of the autonomous issue-solving loop inside a Workflow — each round an agent picks the ready set (blockers closed, skip hitl), classifies each ready issue in-workflow (explore→classify, auto-accepted) to tier-route its implementer model, builds up to K ready issues with one implementer each in isolated git worktrees, hands the completed branches to a merger that merges in dependency order and resolves conflicts under the done-check, then closes the merged issues. Use for "/orchestrate", "run the loop", "build the ready issues".
argument-hint: "[N rounds=1] [--max K=3] [--complexity trivial|standard|complex]"
effort: high
allowed-tools: Read, Grep, Bash, Agent, Skill, AskUserQuestion, Workflow
---

Run the autonomous issue-solving loop on this repo's GitHub issues. The round loop runs inside a
**Workflow** — the skill body **no longer runs the round on the main thread**. The main thread does
only three things: enter the orchestration worktree (Step 0), invoke the Workflow (Step 1), and, on
return, exit the worktree and report (Step 2 + end-of-run PRD reap). Running the round inside the
Workflow keeps per-issue chatter (implementer reports, merge results) out of the main conversational
context — only compact results return.

`$ARGUMENTS` = `[N] [--max K] [--complexity <tier>]` — **N** rounds (default 1); **K** = max issues
built in parallel per round (default 3); **`--complexity <tier>`** (trivial|standard|complex) pins
every issue to that tier and skips per-issue classification.

Backend is **GitHub Issues via `gh`** — no `gh api`, no PR merges. Never touch issues labeled
`hitl` (needs a human) or `prd` (a PRD tracking doc — slice it with `/to-issues` first). Never
push. Each round **classifies every ready issue in-workflow** (explore→classify, auto-accepted —
**no interactive confirm**) and **tier-routes its implementer model** per the table below;
`--complexity <tier>` pins every issue to one tier and skips classification. One **implementer**
builds each issue (it self-plans); **per-issue review** still lands in a later slice.

## Tier routing

Each ready issue's **implementer** model is routed by its complexity **tier**, classified
**in-workflow** (explore→classify) and **auto-accepted** — there is **no interactive confirm**,
because the whole run is autonomous past the launch gate. This tier table must stay
**byte-identical** to the copies in the `classify-task` and `/pipeline` skills (the three form a
drift-guard trio — never edit one table without the others):

| tier | planner | implementer | reviewer |
|---|---|---|---|
| trivial | sonnet | sonnet | opus |
| standard | opus | sonnet | opus |
| complex | fable | opus | fable |

Only the **implementer** column routes here — the round has no per-issue planner or reviewer (the
implementer self-plans; per-issue review lands in a later slice). A Workflow leaf `agent()`
**can't** reuse the `classify-task` skill (that skill fans out its own Explore subagents from the
main thread), so each issue is classified by two in-workflow stages that emit a **real tier**, then
that tier picks the implementer model from the table's implementer column. **`--complexity <tier>`**
pins every issue to that tier's row and **skips classification** entirely.

## Step 0 — enter the orchestration worktree (once, before the Workflow)
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

## Step 1 — invoke the Workflow (the single launch gate)
The round loop runs as a **Workflow**, not on the main thread. From the orchestration worktree,
record the run's base for the workflow:
- **base repo path** = `git rev-parse --show-toplevel` (a linked worktree — the merger's writes land
  here and the `PreToolUse` guard allows that);
- **base branch** = `git rev-parse --abbrev-ref HEAD` (the **orchestration branch** from Step 0).

Then **invoke the Workflow tool** with the orchestrate round-loop workflow, passing `rounds=N`,
`maxParallel=K`, the **pinned `--complexity <tier>` if given** (else unset — classify per issue),
and that base repo path + branch as the run's base. The skill
**passes the orchestration worktree** path and branch into the workflow as its base, so every
per-issue worktree and the merger operate **under** the orchestration worktree and the
**primary checkout is never touched**. Approving the **Workflow permission dialog is the single launch gate** — after you
approve it the run is autonomous; no per-round prompt fires until the end-of-run PRD offer.

The workflow the tool runs (an `export const meta {…}` + `agent()`/`pipeline()` script) implements
the round loop below. Its shape:

```js
export const meta = {
  name: "orchestrate-round-loop",
  // inputs: baseRepo (orchestration-worktree path), baseBranch, rounds (N), maxParallel (K),
  //         doneCheck (the project's done-check command),
  //         complexity (pinned tier from --complexity, or undefined → classify per issue)
};

// Tier → implementer model — the implementer column of the tier table above.
const IMPLEMENTER_MODEL = { trivial: "sonnet", standard: "sonnet", complex: "opus" };

// Repeat for N rounds, or until the ready set drains.
for (let round = 0; round < rounds; round++) {
  // 1. Pick the ready set — a Workflow agent, since a Workflow can't run gh/git itself.
  const ready = await agent({ /* picks ready-for-agent issues; see "Each round" step 1 */ });
  if (ready.issues.length === 0) return stop("empty ready set");   // empty ready set → stop

  // 2. Classify each picked issue in-workflow (explore→classify), tier auto-accepted.
  //    --complexity pins every issue to one tier and skips both stages.
  const picked = ready.issues.slice(0, maxParallel);   // up to K, lowest number first
  for (const issue of picked) {
    if (complexity) { issue.tier = complexity; continue; }        // escape hatch: pin, no classify
    const found = await agent({ /* explores this issue's touched code; see step 2 */ });
    const cls   = await agent({ /* reads `found` + issue body → { tier }; see step 2 */ });
    issue.tier  = cls.tier;                                       // real tier, auto-accepted
  }

  // 3. One worktree + one implementer per picked issue, model routed by its tier.
  const built = await pipeline(picked.map(issue =>
    agent({ subagent_type: "workflow:implementer", model: IMPLEMENTER_MODEL[issue.tier] })));
  if (built.some(b => b.failed)) return stop("implementer failure");

  // 4. Merge serially in ascending issue number, conflicts gated by the done-check.
  const merged = await agent({ subagent_type: "workflow:merger" /* base = orchestration worktree */ });
  if (merged.conflictStop || merged.doneCheckRed) return stop("conflict-stop / red done-check");

  // 5. Close the merged issues.
  for (const n of merged.mergedIssues) gh(`issue close ${n} --comment "<merge commit>"`);
}
```

## Each round (inside the Workflow)
Everything in this section happens **inside the Workflow**, over up to **K** ready issues:

1. **Pick the ready set** (a workflow agent, since a Workflow can't run `gh`/git itself).
   `gh issue list --label ready-for-agent --state open --json number,title,labels,body`. For each
   issue, parse the `## Blocked by` section (C2): bare `#N` refs, or `None - can start immediately`.
   An issue is **ready** iff **every** `#N` blocker is **closed** (`gh issue view <N> --json state`).
   **Skip** any issue also labeled `hitl` or `prd` (the `--label ready-for-agent` filter already
   excludes a correctly-labeled PRD; this is a belt-and-suspenders guard against a hand-added
   label). **Mock-debt gate (C7):** an issue labeled `e2e-gate` is **not ready** while **any** open
   `mock-debt` issue exists (`gh issue list --label mock-debt --state open --json number` —
   non-empty → hold the gate), even if all its `## Blocked by` refs are closed; report it as
   `blocked — N mock-debt open`. The open `mock-debt` set **is** the ledger (the source of truth).
   If the ready set is empty → an **empty ready set** stops the loop with a report.
2. **Classify each picked issue in-workflow (explore→classify, auto-accepted).** A Workflow leaf
   `agent()` **can't** reuse the `classify-task` skill (it fans out its own Explore subagents from
   the main thread), so each picked issue is classified by **two in-workflow stages**: an
   **explore** agent maps the issue's touched code (relevant files, the seams/contracts it moves,
   downstream consumers), then a **classify** agent reads that exploration plus the issue body and
   emits a **real tier** (trivial/standard/complex) by classify-task's rubric — *size is not the
   signal*: a seam move or new infrastructure is **complex**, mechanical no-decision edits are
   **trivial**. The tier is **auto-accepted — no interactive confirm** (the run is autonomous past
   the launch gate), and it **tier-routes its implementer model** via the tier table's implementer
   column. **`--complexity <tier>`** short-circuits both stages — it **pins every issue** to that
   tier's row and **skips classification**, so no explore/classify runs.
3. **Create worktrees.** Take up to **K** ready issues (lowest number first). For each, from the
   base branch (C4): `git worktree add .worktrees/issue-<N> -b issue-<N> <base>`.
4. **Fan out implementers in parallel.** One **`workflow:implementer`** per picked issue, each given
   the issue number, its full body, the **absolute** worktree path, and the branch `issue-<N>`.
   They run concurrently, **each on the model its tier routed** (the implementer column) — the
   implementer still **self-plans** (per-issue review lands in a later slice). An **implementer
   failure** stops the loop with a report.
5. **Merge + verify via the merger (C4).** Collect the results, then hand the **completed branches**
   to the **`workflow:merger`**, passing the **absolute orchestration-worktree** path as this run's
   base repo (a linked worktree → the guard allows the merger's writes) and its **base branch**, the
   **ordered list of completed issues** (each: `#N`, branch `issue-<N>`, and its **absolute worktree
   path**) in **ascending issue number**, and the project's **done-check command**. Ascending issue
   number is the **deterministic** merge order; the picked issues' blockers were already closed, but
   file-level overlap can still collide — **conflicts are expected and the merger resolves them under
   the done-check**. The merger merges serially, **resolves conflicts by default (gated by the
   done-check)**, and returns per-issue results plus the final done-check result and any
   conflict-stops. Act on its result:
   - issues it merged green → `gh issue close <N>` each (comment the merge commit);
   - a **conflict-stop** (unresolvable conflict or a **red done-check** after resolution), or an
     implementer-reported failure → comment that issue, leave its worktree, and **stop the loop**
     with a report. **Never keep an unverified resolution** — that discipline lives in the merger.

Repeat for **N** rounds or until the ready set drains. The merger attempts to resolve conflicts
under the done-check; an **empty ready set**, a **conflict-stop** / **red done-check**, or an
**implementer failure** stops the loop with a clear report; everything else continues to the next
round. The result is **left on the orchestration branch** for you to merge into `dev`/`main`
yourself — the run never merges back to the launch branch and never removes the orchestration
worktree.

## Step 2 — on return: exit the worktree + report
When the Workflow returns, back on the main thread:

- **`ExitWorktree(keep)`** — return to the original directory with the **orchestration branch** and
  worktree intact (or the session-exit prompt offers keep/remove). The merged rounds all land on the
  orchestration branch inside the orchestration worktree — never on the launch branch and never in
  the primary checkout.
- Print a **status table**: issue `#` → title → merged? / closed? → done-check → notes (conflicts,
  failures). If any `mock-debt` is open, add a one-line **ledger summary**
  (`mock-debt: N open — #A, #B …`) and note any `e2e-gate` held by it.
- **Mirror the ledger (C7).** If this was a PRD run (slices carry `Part of #<prd>`), reflect the
  open `mock-debt` set into the PRD body for human visibility: rewrite **only** a delimited
  `## Mock-debt ledger` section (a checklist — `- [ ] #N — <what>` for open, `- [x]` for closed)
  from `gh issue list --label mock-debt --json number,title,state`. Touch **no other part** of the
  PRD body. The label query — not this mirror — is **authoritative** for the gate, so a stale mirror
  never breaks enforcement.
- End the final report by naming that branch + worktree path and telling me to merge it into
  `dev`/`main` when I'm satisfied.

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
Never edit the PRD's spec content or delete the issue. (The one exception is the delimited
`## Mock-debt ledger` section the orchestrator maintains in Step 2 — it owns that section only.)

**For each `blocked` PRD**, note it in the final report without offering to close:

> PRD #N is blocked — open `hitl` issue(s): #H [#H …] need human review before closing.

These PRD offers and notes appear only in the **final report** (Step 2), after all rounds. They
never interrupt mid-loop rounds.
