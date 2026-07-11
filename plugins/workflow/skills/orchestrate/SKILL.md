---
name: orchestrate
description: Run N rounds of the autonomous issue-solving loop inside a Workflow — the main thread first resolves the run's scope to an explicit issue allowlist (--issues, or --prd N walked into its child slices, never a repo-wide label sweep), then each round ONE cheap haiku call picks that round's ready set from the allowlist (blockers closed, skip hitl) and tiers every issue in the same pass (auto-accepted) to tier-route its planner, implementer and reviewer models, plans each standard/complex issue into a work order with the workflow:planner subagent at the tier's planner model (a trivial issue skips the plan stage — its implementer self-plans), builds up to K ready issues with one implementer each in isolated git worktrees, reviews each built slice with `personal-tools:my-review` at the tier's reviewer model — running the central-mechanism / mock-drift audit — and acts on the findings through a per-issue planner-free fix loop (capped by --max-cycles, default 2: the findings themselves are the implementer's work order; low→file), build→review→fix pipelining per issue with no cross-issue barrier, before handing the clean-or-capped branches to a merger that merges in dependency order and resolves conflicts under the done-check; one haiku bookkeeping call then files the lows (grouped and parked) + cap-remainder as review-fix follow-ups while re-blocking dependents, the workflow hands the merged-issue list back to the main thread, which closes those issues itself and verifies every close, and open mock-debt mirrors into the PRD ledger. Use for "/orchestrate", "run the loop", "build the ready issues".
argument-hint: "[N rounds=1] [--max K=3] [--max-cycles K=2] [--complexity trivial|standard|complex] [--prd N] [--issues N,N,...]"
effort: high
allowed-tools: Read, Grep, Bash, Agent, Skill, AskUserQuestion, Workflow
---

Run the autonomous issue-solving loop on this repo's GitHub issues. The round loop runs inside a
**Workflow** — the skill body **no longer runs the round on the main thread**. The main thread does
only four things: resolve the run's **scope** (Step 0a), enter the orchestration worktree (Step 0b),
invoke the Workflow (Step 1), and, on return, **close the merged issues**, exit the worktree and
report (Step 2 + end-of-run PRD reap). Running the round inside the Workflow keeps per-issue chatter
(implementer reports, merge results) out of the main conversational context — only compact results
return. The **closes are the deliberate exception**: they stay on the main thread (Step 2), because
an **irreversible outward-facing** GitHub write belongs where the conversational context can account
for it — see Step 0a's note on #77.

`$ARGUMENTS` = `[N] [--max K] [--max-cycles K] [--complexity <tier>] [--prd N] [--issues N,N,...]` —
**N** rounds (default 1);
**`--max K`** = max issues built in parallel per round (default 3); **`--max-cycles K`** = the
per-issue fix-loop cap (default **2**) — the **initial review is free**
and the cap **counts re-reviews**, each re-review decrementing the budget; **`--complexity <tier>`**
(trivial|standard|complex) pins every issue to that tier and skips per-issue classification;
**`--prd N`** scopes the run to PRD #N's child slices, and **`--issues N,N,...`** scopes it to a
literal issue list (Step 0a).

Backend is **GitHub Issues via `gh`** — no `gh api`, no PR merges. Never touch issues labeled
`hitl` (needs a human) or `prd` (a PRD tracking doc — slice it with `/to-issues` first). Never
push. Each round **picks and tiers the ready set in ONE cheap haiku call** (tiers auto-accepted —
**no interactive confirm**) and **tier-routes its implementer model** via the launch-resolved
`ROSTER`; `--complexity <tier>` pins every issue to one tier and skips classification. A per-issue
**plan stage** (tier-routed by `ROSTER[issue.tier].planner`) writes each **standard/complex**
issue's **work order** with the **`workflow:planner`** subagent — a **trivial** issue **skips the
plan stage entirely** and its implementer self-plans. One
**implementer** then builds each issue; then **`personal-tools:my-review`** reviews each built slice
at the tier's **reviewer** model, and a per-issue **planner-free fix loop** (capped by
`--max-cycles`, default 2) acts on the findings — the review's own findings block **is** the fix
work order, handed straight to a fresh implementer — before the clean-or-capped branch merges.

## Tier routing

Each ready issue's **planner**, **implementer**, and **reviewer** `{model, effort}` are routed by
its complexity **tier**, emitted by the **ready-set picker itself** and **auto-accepted** —
there is **no interactive confirm**, because the whole run is autonomous past the launch gate. The
tier→`{model, effort}` mapping lives in the plugin's `model-tiers.json`, resolved by
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-tier.sh" <tier>`; the **main thread runs that helper
once per tier at launch** (Step 1) and inlines the results into a single **`ROSTER`** const in the
workflow script, so the round itself never re-resolves.

A Workflow leaf `agent()` **can't** reuse the `classify-task` skill (that skill fans out its own
Explore subagents from the main thread), so classification **rides the ready-set pick**: the ONE
**`haiku` `agent()` call** that lists the ready issues already reads every body + comments to decide
readiness, and it emits a **real tier** per issue in the same pass. There is **no per-issue classify
agent and no separate explore stage**: the picker is a cheap leaf that may grep the repo itself, and
a tier is a model-routing hint, not a deliverable — spending extra agents to produce a one-word
answer was pure overhead. The emitted tier indexes the launch-resolved `ROSTER` —
`ROSTER[issue.tier].planner`, `ROSTER[issue.tier].implementer`, `ROSTER[issue.tier].reviewer`, each
a `{model, effort}` pair. The round runs a per-issue **plan stage** before the build for
standard/complex issues only (its `{model, effort}` is `ROSTER[issue.tier].planner`) and a per-issue
**review stage** after it (`ROSTER[issue.tier].reviewer`, via `personal-tools:my-review`).
**`--complexity <tier>`** pins every issue to that tier and **skips classification** entirely.

The **`workflow:merger`** is **not** tier-routed — it is spawned with no `model`/`effort` and its
frontmatter pins govern (**opus**). A bad merge resolution corrupts the base branch for every issue
in the round, so the merger is the one stage that never gets a cheap model.

## Hard dependency — fail loud at launch
The loop **hard-depends on the `personal-tools` plugin**: the **`my-review`** agent reviews each
built slice (Step 6) and runs the central-mechanism / mock-drift audit; the planner-free fix
loop (Step 7) then re-reviews with the same agent. **Before entering the
worktree (Step 0b)**, check it's available — if `personal-tools:my-review` is **not** in your
available agents, **fail loud** naming the missing piece — e.g. "personal-tools plugin not
installed: my-review agent unavailable" — and **stop**. Do **not** substitute another reviewer.
This mirrors `/pipeline`'s Step-0 hard-dep check.

## Step 0a — resolve the run's scope to an explicit issue allowlist
**This is the fix for #77's defect A, and it runs on the main thread before anything else.** The
loop used to pick its work with a repo-wide `ready-for-agent` label query. That is a correctness
bug, not a convenience one: on a real run it swept in an unrelated issue from a different PRD and
**built it into the PRD's branch**. Nothing tied the picked issues back to the work you asked for.

So the round **never queries for work**. The main thread resolves an **explicit issue allowlist**
first, and the workflow may only ever build from it:

- **`--issues N,N,...`** → that literal list *is* the allowlist. Highest precedence.
- **`--prd N`** → the allowlist is PRD #N's child slices. Resolve them with the shared helper —
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/prd-children.sh" <N>` — which prints one
  `<number> <state> <labels-csv>` line per genuine child (it owns the `Part of #N` trailer matching,
  so GitHub's tokenized search can't hand you a slice of #10 when you asked for #1). Keep the
  children that are **open**, carry **`ready-for-agent`**, and carry neither `hitl` nor `prd`.
- **neither flag** → **infer, then confirm**. List the open PRDs
  (`gh issue list --label prd --state open --json number,title`). **Exactly one** → scope to it and
  say so in the launch report. **More than one** → **AskUserQuestion** with the PRD titles and scope
  to the answer. **None** → there is no PRD to scope to; fall back to the repo's open
  `ready-for-agent` issues, and **say plainly in the launch report that the run is unscoped** and
  which issues it will therefore consider. (This prompt is *pre*-gate — it does not break the
  autonomous contract, which starts at the Workflow permission dialog.)

The resolved allowlist is passed into the Workflow as `scope` (an array of issue numbers). **The
allowlist is frozen at launch** and never re-queried. That freeze is load-bearing twice over:

- **Nothing the run files can be built by the run.** A `review-fix` follow-up the round files in
  step 9 is not in the allowlist, so a later round cannot pick it up and build it. Without the
  freeze, a **cap-remainder** filed at `--max-cycles` would be rebuilt next round — silently
  bypassing the very cap that parked it.
- It bounds the blast radius to the work you named, which is what #77 asked for.

If the allowlist is **empty**, stop before entering the worktree and say why — an empty scope is
never a reason to widen the query.

## Step 0b — enter the orchestration worktree (once, before the Workflow)
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
- **base branch** = `git rev-parse --abbrev-ref HEAD` (the **orchestration branch** from Step 0b).

**Resolve the ROSTER at launch (main thread).** Before invoking the Workflow, run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-tier.sh" <tier>` **once per tier** — three calls,
`trivial` / `standard` / `complex` — parse each output's seven `key=value` lines (`planner_model` /
`planner_effort` / `implementer_model` / `implementer_effort` / `reviewer_model` /
`reviewer_effort`), and inline the resolved values into the single `ROSTER` const of the workflow
script you pass to the Workflow tool — **never hand-write those values**. If any call prints a
`WARN` (missing or invalid config), surface it to the user and continue on the fallback (standard)
roster it returned. The `ROSTER` is then frozen for the whole run.

Then **invoke the Workflow tool** with the orchestrate round-loop workflow, passing `rounds=N`,
`maxParallel=K`, `maxCycles=<--max-cycles K, default 2>` (the per-issue fix-loop cap), the
**`scope` allowlist resolved in Step 0a** (the only issues the run may ever build), the
**pinned `--complexity <tier>` if given** (else unset — classify per issue),
and that base repo path + branch as the run's base. The skill
**passes the orchestration worktree** path and branch into the workflow as its base, so every
per-issue worktree and the merger operate **under** the orchestration worktree and the
**primary checkout is never touched**. Approving the **Workflow permission dialog is the single launch gate** — after you
approve it the run is autonomous; no per-round prompt fires until the end-of-run PRD offer.

The workflow the tool runs (an `export const meta {…}` + `agent()`/`pipeline()` script) implements
the round loop below. Its shape:

**Transcribe the call signatures exactly.** Every spawn is `agent(prompt, opts)` — the prompt is the
**first positional argument**, never a field inside an object. `opts` is
`{ model, effort, agentType, schema, label, phase, isolation }`. Three traps, each of which fails
*silently*: passing one object (`agent({ … })`) sends the whole thing as the prompt and no `opts`, so
tier routing degrades to session defaults; the opts key is **`agentType`**, not `subagent_type` (that
is the `Agent` tool's spelling and is ignored here); and a bare `agent()` returns the subagent's text
**as a string**, so any result you destructure must pass a `schema:`. Likewise `pipeline(items,
…stages)` takes the item list plus stage callbacks — not an array of already-started promises.

**Normalize `args` before destructuring.** The Workflow tool hands the script its inputs — the
base repo path and branch, `rounds`, `maxParallel`, `maxCycles`, and any pinned `complexity` — as a
single value that **may arrive as a JSON string rather than an object**. Read it blindly and
`const { rounds } = args` yields `undefined`; `round < undefined` is `false`, so the round loop
falls straight through, spawns nothing, and reports a **silent empty success** (the #53 / #70 / #73
class). The script must **parse-or-throw**: normalize with
`typeof args === 'string' ? JSON.parse(args) : args`, then **throw** if `rounds` is missing or not a
number, and only then destructure. A workflow that throws is loud; a workflow that reads `undefined`
exits clean having done nothing.

```js
export const meta = {
  name: "orchestrate-round-loop",
  // inputs: baseRepo (orchestration-worktree path), baseBranch, rounds (N), maxParallel (K),
  //         maxCycles (per-issue fix-loop cap, default 2), doneCheck (the project's done-check command),
  //         complexity (pinned tier from --complexity, or undefined → classify per issue),
  //         scope (the Step-0a issue allowlist — the ONLY issues this run may build)
};

// `args` may reach the script as a JSON STRING, not an object — normalize before reading, then
// parse-or-throw. A blind bare destructure of `args` on a string yields undefined and the round loop
// falls through spawning nothing (silent empty success). Throw loud instead of exiting clean-empty.
const input = typeof args === 'string' ? JSON.parse(args) : args;
if (!input || typeof input.rounds !== 'number') throw new Error(`bad args: ${JSON.stringify(args)}`);
// The scope allowlist is REQUIRED (#77 defect A). An absent/empty scope must throw, never degrade
// into a repo-wide query — a run that picks its own work can build issues nobody asked for.
if (!Array.isArray(input.scope) || input.scope.length === 0)
  throw new Error(`empty scope: refusing to pick work repo-wide — see Step 0a`);
const { baseRepo, baseBranch, rounds, maxParallel, maxCycles, complexity, scope } = input;

// JSON Schemas for the spawns whose results are read as objects. Without these,
// agent() hands back a string and every property access below is undefined.
//   READY_SCHEMA  → { issues: [{ n, title, body, comments, tier }] }  // comments: never body-only;
//                                                                     // tier emitted by the same call
//   BUILT_SCHEMA  → { n, branch, failed }
//   REVIEW_SCHEMA → { findings: [{ severity, path, summary }] }
//   MERGE_SCHEMA  → { mergedIssues: [{ n, mergeCommit }], conflictStop, doneCheckRed }
//                    // mergeCommit rides along: the main thread quotes it in the close comment
//                    // (Step 2), so the merger must return it, not just the issue number

// Tier → { planner, implementer, reviewer } × { model, effort }. The main thread resolves each
// tier through resolve-tier.sh at launch (Step 1) and inlines the values below — resolved at
// launch, NEVER hand-write these values (they are placeholders in this doc):
const ROSTER = {
  trivial:  { planner:     { model: "<trivial_planner_model>",     effort: "<trivial_planner_effort>"     },
              implementer: { model: "<trivial_implementer_model>", effort: "<trivial_implementer_effort>" },
              reviewer:    { model: "<trivial_reviewer_model>",    effort: "<trivial_reviewer_effort>"    } },
  standard: { planner:     { model: "<standard_planner_model>",     effort: "<standard_planner_effort>"     },
              implementer: { model: "<standard_implementer_model>", effort: "<standard_implementer_effort>" },
              reviewer:    { model: "<standard_reviewer_model>",    effort: "<standard_reviewer_effort>"    } },
  complex:  { planner:     { model: "<complex_planner_model>",     effort: "<complex_planner_effort>"     },
              implementer: { model: "<complex_implementer_model>", effort: "<complex_implementer_effort>" },
              reviewer:    { model: "<complex_reviewer_model>",    effort: "<complex_reviewer_effort>"    } },
};

// The RE-PICK GUARD (#77 fix 3). The workflow no longer closes the issues it merges — the main
// thread does, on return (Step 2). So an issue merged in round 1 is STILL OPEN in round 2 and the
// picker will hand it back. Track what this run merged and exclude it from every later round: that
// makes the loop convergent WHETHER OR NOT the close ever lands, which is exactly what the 1.84M-token
// spin lacked. (A blocked close used to leave the ready set undrained, so rounds 2-5 rebuilt the same
// issues at full cost.) Convergence must not depend on a GitHub write succeeding.
const mergedThisRun = new Map();   // issue number → merge commit, accumulated across rounds

// Repeat for N rounds, or until the ready set drains.
for (let round = 0; round < rounds; round++) {
  // 1.+2. Pick the ready set AND tier every issue — ONE haiku call for the whole round. The picker
  //    reads ONLY the Step-0a allowlist (never a repo-wide label query — #77 defect A), already
  //    reads each issue's body + comments to decide readiness, so it emits the tier in the same pass
  //    (rubric in step 2) — no per-issue classify agents. Tiers auto-accepted. Pinned to haiku at low
  //    effort: NOT tier-routed (routing is what it is deciding), and never left to the session default
  //    (an unpinned picker silently runs on the expensive session model).
  const candidates = scope.filter(n => !mergedThisRun.has(n));    // re-pick guard, applied BEFORE the spawn
  if (candidates.length === 0) return stop("scope drained");      // every scoped issue is built → done
  const ready = await agent(
    `Of these issues ONLY — ${JSON.stringify(candidates)} — list the ready ones AND tier each
     (trivial|standard|complex); see steps 1–2`,
    { model: "haiku", effort: "low", schema: READY_SCHEMA });
  // Belt to the filter's suspenders: a picker that hallucinates an out-of-scope or already-merged
  // issue gets it dropped here, loudly, rather than building work nobody asked for.
  const inScope = ready.issues.filter(i => {
    if (mergedThisRun.has(i.n)) { log(`re-pick guard: dropping #${i.n} — already merged this run`); return false; }
    if (!scope.includes(i.n))   { log(`scope guard: dropping #${i.n} — outside the run's allowlist`); return false; }
    return true;
  });
  if (inScope.length === 0) return stop("empty ready set");       // empty ready set → stop
  const picked = inScope.slice(0, maxParallel);                   // up to K, lowest number first
  if (complexity) picked.forEach(i => { i.tier = complexity; });  // escape hatch: pin overrides
                                                                  // the emitted tiers

  // 3. Plan the STANDARD/COMPLEX issues → their work order. No plan comment, no gate — autonomous.
  //    trivial: NO plan stage at all — issue.plan stays null and the implementer self-plans (it
  //    already plans TDD-first by its own contract; a separate planner spawn was duplicated work).
  //    standard/complex: workflow:planner mode=plan at ROSTER[issue.tier].planner.
  //    No schema — the plan text IS the return value, and it is the work order.
  //    The planner gets the issue's COMMENTS as well as its body — a comment may hold the answer.
  for (const issue of picked) {
    if (issue.tier === "trivial") { issue.plan = null; continue; }   // implementer self-plans
    issue.plan = await agent(
      `mode=plan · issue #${issue.n} body + comments in → plan text out; see step 3
       \n\n${issue.body}\n\n## Issue comments\n${issue.comments}`,
      { agentType: "workflow:planner",
        model:     ROSTER[issue.tier].planner.model,
        effort:    ROSTER[issue.tier].planner.effort });
  }

  // 4.–6. Build → initial review → fix loop, per issue, as ONE pipeline — NO barrier between the
  //    stages: issue A runs its fix loop while issue B is still building. Wall-clock = the slowest
  //    single issue's chain, not sum-of-slowest-per-stage.
  const results = await pipeline(picked,
    // 4. One worktree + one implementer per picked issue. Work order = the plan text when there is
    //    one; for a trivial issue (issue.plan === null) the ISSUE BODY is the work order and the
    //    implementer self-plans.
    issue =>
      agent(
        issue.plan
          ? `Work order = the plan below (steps + ## Acceptance criteria + done-check), plus the issue's
             comments, the worktree path, the branch, and a commit-scope hint from the repo log.
             \n\n${issue.plan}\n\n## Issue comments\n${issue.comments}`
          : `Work order = issue #${issue.n} below — SELF-PLAN it (trivial tier, no planner ran), then
             build it TDD-first. Plus the worktree path, the branch, and a commit-scope hint.
             \n\n${issue.body}\n\n## Issue comments\n${issue.comments}`,
        { agentType: "workflow:implementer",
          model:     ROSTER[issue.tier].implementer.model,
          effort:    ROSTER[issue.tier].implementer.effort,
          // worktree created by step 4, owned by the implementer — no isolation opt here
          schema:    BUILT_SCHEMA }),
    // 5.+6. Initial review (FREE — does not count against maxCycles), then the PLANNER-FREE fix
    //    loop. personal-tools:my-review at the tier's reviewer model on the branch diff
    //    (<base>..issue-<N>), handed issue.plan for conformance context. It runs the central-
    //    mechanism / mock-drift audit (declared → confirm; undeclared central mock → auto-convert;
    //    both file a mock-debt follow-up — my-review OWNS that filing) and returns a findings block.
    //    The fix loop hands the medium-or-worse findings STRAIGHT to a fresh implementer — a finding
    //    already names the path, the defect, and the fix, so re-planning it was a whole extra agent
    //    restating the reviewer. Loop until clean-or-capped, BEFORE it merges. maxCycles (default 2)
    //    counts RE-REVIEWS. Reviewer model HELD CONSTANT. Criticals lead the work order (ascending
    //    path — deterministic), then highs, then mediums. low → filed in step 9, never fixed in-run.
    //    No cap AskUserQuestion gate — autonomous.
    async (b, issue) => {
      if (!b || b.failed) return b;                                   // dead build → no review; caught below
      issue.review = await agent(
        `Review the branch diff <base>..issue-${issue.n}. Plan for conformance context:\n\n${issue.plan}
         \n\nIssue #${issue.n}'s comments — ground truth for the review:\n${issue.comments}`,
        { agentType: "personal-tools:my-review",
          model:     ROSTER[issue.tier].reviewer.model,
          effort:    ROSTER[issue.tier].reviewer.effort,
          schema:    REVIEW_SCHEMA });
      let cycles = 0;
      while (mediumOrWorseOpen(issue.review) && cycles < maxCycles) {
        const preFix = revParse(`issue-${issue.n}`);                  // <pre-fix HEAD> for the delta
        const fixOrder = orderFindings(issue.review);                 // plain code: critical → high →
                                                                      // medium, ascending path. NO
                                                                      // planner spawn.
        await agent(
          `Work order = these review findings — fix each, TDD-first, then run the done-check.
           Do NOT re-plan the issue; fix exactly what is listed.\n\n${fixOrder}`,
          { agentType: "workflow:implementer",
            model:     ROSTER[issue.tier].implementer.model,
            effort:    ROSTER[issue.tier].implementer.effort,
            schema:    BUILT_SCHEMA });
        issue.review = await agent(
          `(a) Verify the prior findings are addressed, (b) review ONLY the delta ${preFix}..HEAD`,
          { agentType: "personal-tools:my-review",
            model:     ROSTER[issue.tier].reviewer.model,
            effort:    ROSTER[issue.tier].reviewer.effort,
            schema:    REVIEW_SCHEMA });
        cycles++;
      }
      issue.capRemainder = mediumOrWorse(issue.review);               // open at cap → filed in step 9,
      return b;                                                       // merges anyway
    });
  if (results.some(b => !b || b.failed)) return stop("implementer failure");   // null = agent died

  // 7. Merge the clean/capped branches serially in ascending issue number, conflicts gated by the
  //    done-check. Runs AFTER the fix loop — all-lows/clean and cap-exhausted slices both merge.
  const merged = await agent(                       // no model/effort → the merger's frontmatter pins govern
    "Merge this round's branches serially, ascending issue number. Base = the orchestration worktree.",
    { agentType: "workflow:merger", schema: MERGE_SCHEMA });
  if (merged.conflictStop || merged.doneCheckRed) return stop("conflict-stop / red done-check");

  // 8. NO CLOSE HERE (#77 fix 1). The workflow records what it merged and hands the list back; the
  //    MAIN THREAD closes and verifies (Step 2). A close is an irreversible outward-facing write, and
  //    from inside a low-context subagent it reads as an unexplained destructive act against a
  //    pre-existing GitHub issue — a safety classifier killed exactly this call on the run that burned
  //    1.84M tokens, and it was right to. Recording into mergedThisRun is what keeps the loop
  //    convergent in the meantime (see the re-pick guard above).
  for (const m of merged.mergedIssues) mergedThisRun.set(m.n, m.mergeCommit);

  // 9. ONE haiku agent for the round's ADDITIVE gh writes — a Workflow can't run gh itself, and these
  //    spawns were previously unpinned (→ session model) and per-item. They are mechanical templating
  //    over text the round already produced, and they only ever ADD (file / append) — never close,
  //    never delete — which is what makes them safe to hand a cheap subagent at all. It files each
  //    slice's lows as ONE grouped, PARKED follow-up (label review-fix ONLY — no ready-for-agent, so
  //    nothing ever auto-builds a nit) and each cap-remainder as a review-fix + ready-for-agent
  //    follow-up, then appends the filed #N into any open dependent's ## Blocked by via gh issue edit —
  //    touching no other part of the dependent's body. my-review already filed the mock-debt
  //    (steps 5–6) — do NOT re-file it.
  await agent(
    `Round bookkeeping via gh; see step 9. File these follow-ups, then re-block dependents.
     Do NOT close any issue — the main thread owns that.
     \n\n${ghWriteManifest(picked)}`,                                 // plain code: lows + capRemainder per issue
    { model: "haiku", effort: "low" });                               // mechanical writes — never the session model
}

// The merged-issue list is the workflow's RETURN VALUE — the main thread closes these itself and
// verifies each close (Step 2). Returning them is the only way they ever get closed.
return { mergedIssues: [...mergedThisRun].map(([n, mergeCommit]) => ({ n, mergeCommit })) };
```

## Each round (inside the Workflow)
Everything in this section happens **inside the Workflow**, over up to **K** ready issues:

1. **Pick the ready set — and tier it — in ONE haiku call** (a workflow agent, since a Workflow
   can't run `gh`/git itself; pinned `model: "haiku"`, `effort: "low"` — an unpinned picker silently
   runs on the expensive session model). It reads **only the Step-0a allowlist**, one issue at a
   time — `gh issue view <N> --json number,title,labels,body,comments` for each `N` in `scope`,
   minus anything already merged this run (the **re-pick guard**). It **never runs a repo-wide label
   query**: a picker that can discover its own work can build issues nobody asked for, which is #77's
   defect A.
   The same call **emits each issue's tier** by the step-2 rubric — it is already reading every
   body and comment thread to judge readiness, so classification is a free rider, not a second pass.
   **Fetch the comments, not just the body** — an issue's **comments carry guidance** (a human's
   answer, a prior review's ruling) that the body may never absorb, and a **comment-blind** loop
   rediscovers the settled question and guesses at it. Carry each issue's comments through the
   round: they ride the work order into the planner (step 3), the implementer (step 5), and the
   reviewer (step 6). For each
   issue, parse the `## Blocked by` section (C2): bare `#N` refs, or `None - can start immediately`.
   An issue is **ready** iff **every** `#N` blocker is **closed** (`gh issue view <N> --json state`).
   **Skip** any issue also labeled `hitl` or `prd` (the `--label ready-for-agent` filter already
   excludes a correctly-labeled PRD; this is a belt-and-suspenders guard against a hand-added
   label). **Mock-debt gate (C7):** an issue labeled `e2e-gate` is **not ready** while **any** open
   `mock-debt` issue exists (`gh issue list --label mock-debt --state open --json number` —
   non-empty → hold the gate), even if all its `## Blocked by` refs are closed; report it as
   `blocked — N mock-debt open`. The open `mock-debt` set **is** the ledger (the source of truth).
   If the ready set is empty → an **empty ready set** stops the loop with a report.
2. **Tier rubric (applied by the step-1 picker, auto-accepted).** A Workflow leaf `agent()`
   **can't** reuse the `classify-task` skill (it fans out its own Explore subagents from the main
   thread), so the **step-1 picker itself** — already pinned to `haiku` at `low` effort, **not**
   tier-routed, since routing is what it is *deciding* — reads each issue's body **and its
   comments** and emits a **real tier** (trivial/standard/complex) by classify-task's rubric.
   *Size is not the signal*: a seam move or new infrastructure is **complex**, mechanical
   no-decision edits are **trivial**. It may grep the repo itself if the issue text is thin; there
   is **no per-issue classify agent and no separate explore stage** — a tier is a one-word
   model-routing hint, and spending dedicated agents to produce it cost more than the routing
   saved. The tier is **auto-accepted — no interactive confirm** (the run is autonomous past
   the launch gate), and it **tier-routes the planner, implementer and reviewer** via `ROSTER`.
   **`--complexity <tier>`** overrides the emitted tiers — it **pins every issue** to that tier and
   **skips classification** (the picker still runs; only its tier output is ignored).
3. **Plan the standard/complex issues → their work order (autonomous — no plan comment, no gate).**
   Before the build, a **plan stage** runs **only for standard and complex** issues: the
   **`workflow:planner`** subagent (`agentType: workflow:planner`, `mode: plan`,
   `model: ROSTER[issue.tier].planner.model`, `effort: ROSTER[issue.tier].planner.effort`) handed the
   issue body **and its comments** (step 1 fetched both — a comment may carry the settled answer),
   which returns the plan as its **final text** (ordered steps with file paths +
   `## Acceptance criteria` + the done-check + risks). Capture that plan text as the issue's **work
   order**.

   A **trivial** issue gets **no plan stage at all** — `issue.plan` stays null, the **issue body is
   the work order**, and the **implementer self-plans** (planning TDD-first is already in the
   implementer's own contract, so a separate planner spawn just restated the issue). This is the one
   place orchestrate **diverges from `/pipeline`**'s Step-2 authorship ladder, which still authors a
   minimal plan inline for trivial: inside a Workflow that ladder costs a whole extra agent, and it
   bought nothing the implementer wasn't already doing.

   The run stays autonomous:
   **no plan comment is posted to the issue and no plan-approval gate fires**
   (the Workflow launch gate was the only stop). `--complexity <tier>` still pins the tier, so the
   planner model follows the pinned row — and **`--complexity trivial` skips the plan stage for
   every issue**.
4. **Create worktrees.** Take up to **K** ready issues (lowest number first). For each, from the
   base branch (C4): `git worktree add .worktrees/issue-<N> -b issue-<N> <base>`.
5. **Fan out implementers in parallel.** One **`workflow:implementer`** per picked issue, each handed
   its **work order** — the **plan text** from step 3 (ordered steps + `## Acceptance criteria` +
   done-check) — plus the issue's **comments** (step 1), the **absolute** worktree path, the branch
   `issue-<N>`, and a **commit-scope
   hint** (the issue's `<scope>`). The plan **replaces the implementer's self-plan** for these issues
   (the implementer builds against the work order, not a plan of its own). They run concurrently,
   **each on the model its tier routed** (`ROSTER[issue.tier].implementer`). Steps 5–7 run as **one
   `pipeline()` per issue with no cross-issue barrier** — issue A enters review and its fix loop
   while issue B is still building, so the round's wall-clock is the slowest single issue's chain,
   not sum-of-slowest-per-stage. An **implementer failure** stops the loop — **before any merge** —
   with a report.
6. **Review each built slice — initial review (free).** As soon as an issue's build finishes (the
   per-issue pipeline — no waiting on sibling builds), spawn
   **`personal-tools:my-review`** (one `Agent` call, `model: ROSTER[issue.tier].reviewer.model`,
   `effort: ROSTER[issue.tier].reviewer.effort`) on that issue's **branch diff** — the commit range `<base>..issue-<N>` — with the issue's
   **plan** (captured in step 3 as `issue.plan`; **null for a trivial issue**, which had no plan
   stage — then the **issue body** is the conformance context) in the prompt, the issue's
   **comments** (step 1 — they are the ground truth the review checks the slice against), plus the
   **issue number** so the audit can read its `## Central mechanism` line. my-review returns a verdict
   plus a machine-readable `findings` block, and runs the **central-mechanism / mock-drift audit**:
   declared central mock → confirm; **undeclared** central mock → **auto-convert** — both file a
   `mock-debt` follow-up (labels `mock-debt`, `ready-for-agent`) that the ready-rule's mock-debt gate
   holds the `e2e-gate` on. **my-review OWNS the mock-debt filing** — the workflow does not re-file it
   (step 9). This **initial review is free** — it does not count against `--max-cycles`; the fix loop
   (step 7) acts on its findings **before it merges**.
7. **Planner-free fix loop (capped by `--max-cycles`, autonomous).** Parse each slice's `findings`
   block and act on it **per issue** — re-implementing and re-reviewing **for real** until the slice
   is **clean-or-capped** before it merges. `--max-cycles K` (**default 2**, matching `/pipeline`)
   **counts re-reviews**: the step-6 review is free, and each re-review decrements the budget. The
   **reviewer model is held constant** across every re-review (`ROSTER[issue.tier].reviewer`, fixed
   for the run).

   **No planner runs in the fix loop.** A review finding already names the path, the defect, and the
   fix — re-planning it spawns an agent whose whole job is to restate the reviewer in other words.
   So the **findings block itself is the fix work order**, assembled in plain script code, no agent:

   | severity | route |
   |---|---|
   | **low** | filed as a follow-up (step 9), **never fixed in-run** |
   | **medium / high / critical** | goes into the fix work order handed straight to a fresh implementer |

   Order the work order **criticals first, then highs, then mediums**, each group **ascending by
   path** — deterministic, and the implementer fixes the dangerous things before the cosmetic ones.
   All severities go in **one work order per cycle**: no per-critical cycle, no collective-replan
   spawn, no `mode=triage` spawn. (`workflow:planner`'s `replan` / `triage` modes still exist and
   `/pipeline` still uses them; orchestrate no longer does.)

   Each fix round goes to a **fresh `workflow:implementer`**
   (`model: ROSTER[issue.tier].implementer.model`, `effort: ROSTER[issue.tier].implementer.effort`,
   work order = the ordered findings, told to **fix exactly what is listed and not re-plan the
   issue**), followed by a **scoped re-review**: spawn **`personal-tools:my-review`** again asking it
   to (a) verify each prior finding is addressed and (b) review **only the fix delta** — the commit
   range `<pre-fix HEAD>..HEAD`, not the whole branch.

   **No cap gate** — unlike `/pipeline`, orchestrate never prompts at the cap (the run is autonomous
   past the launch gate; no interactive +1-cycle grant fires). A slice reaching **all-lows (or a
   clean review) passes the branch**. When the **cap is exhausted with medium-or-worse findings still
   open**, those become the **cap-remainder**: they are filed as follow-ups (step 9) and the branch
   **merges anyway**.
8. **Merge + verify via the merger — but do NOT close (C4).** After the fix loop clears or caps each slice,
   hand the **completed branches** to the **`workflow:merger`**, passing the **absolute
   orchestration-worktree** path as this run's base repo (a linked worktree → the guard allows the
   merger's writes) and its **base branch**, the **ordered list of completed issues** (each: `#N`,
   branch `issue-<N>`, and its **absolute worktree path**) in **ascending issue number**, and the
   project's **done-check command**. Ascending issue number is the **deterministic** merge order; the
   picked issues' blockers were already closed, but file-level overlap can still collide — **conflicts
   are expected and the merger resolves them under the done-check**. The merger merges serially,
   **resolves conflicts by default (gated by the done-check)**, and returns per-issue results plus the
   final done-check result and any conflict-stops. Act on its result:
   - issues it merged green → recorded into **`mergedThisRun`** (issue number → merge commit) and
     **returned to the main thread**, which closes them in Step 2. **The workflow never closes an
     issue.** The close is an **irreversible outward-facing** GitHub write, and inside a low-context
     subagent it reads as an unexplained destructive act against a pre-existing issue — on the run
     behind #77 a safety classifier killed exactly this call, correctly, and the resulting undrained
     ready set spun rounds 2–5 into rebuilding the same issues at full cost (1.84M tokens). Because
     they stay open until the run ends, `mergedThisRun` is what drains the loop: an issue merged in
     one round is **excluded from every later round** by the step-1 **re-pick guard**, so convergence
     never depends on a GitHub write succeeding;
   - a **conflict-stop** (unresolvable conflict or a **red done-check** after resolution), or an
     implementer-reported failure → comment that issue, leave its worktree, and **stop the loop**
     with a report. **Never keep an unverified resolution** — that discipline lives in the merger.
     (A stop still **returns** whatever `mergedThisRun` holds — those issues really did merge and
     must still be closed.)
9. **Round bookkeeping — ONE haiku agent for the round's additive gh writes.** These filings are
   **mechanical templating over text the round already produced**, so they batch into a
   **single `agent()` call pinned to `haiku` at `low` effort** (previously these spawns were unpinned
   — silently running per-item on the session model). That one agent files the follow-ups below and
   re-blocks dependents. It **only ever adds** — files an issue, appends to a body — and **never
   closes and never deletes**; that is precisely what makes it safe to hand a cheap, low-context
   subagent, and it is why the **closes moved out** to the main thread (step 8). Ensure the labels
   exist (`gh label create review-fix 2>/dev/null || true`, same for `ready-for-agent`). The workflow
   absorbs the filing `my-review` does not — two kinds, routed differently:

   | what | label(s) | why |
   |---|---|---|
   | **lows** — **one grouped** follow-up per slice, collecting that slice's low findings | `review-fix` **only** | **Parked.** A low is by definition not worth an agent, so it must not be *auto-buildable*: `ready-for-agent` would make the loop pick it up and spend a full plan→build→review on a nit. A human promotes it when they judge it worth doing. |
   | **cap-remainder** — medium-or-worse left open when `--max-cycles` exhausted | `review-fix` + `ready-for-agent` | Real work, genuinely ready for a future run. |

   File each with `gh issue create --title '<one-line fix>' --label review-fix --body-file <tmp>`
   (adding `--label ready-for-agent` for the cap-remainder only; single-quote the title — it embeds
   review-derived text that may carry shell metacharacters) with the template `## What to build` (the
   fix) / `## Acceptance criteria` / `## Blocked by` (`None - can start immediately` unless the fix
   depends on this branch landing — then name it).

   Note the labels are only the *second* line of defence. The first is Step 0a's frozen allowlist:
   **nothing the run files can be built by the run**, because the scope is fixed at launch and a
   newly-filed issue is not in it. That freeze is what stops a **cap-remainder** — which *is*
   `ready-for-agent` — from being rebuilt next round and silently bypassing the very cap that parked
   it.

   **Mock-debt stays my-review's job:** the central-mechanism audit already filed the
   declared / auto-converted `mock-debt` follow-ups in step 6, so the **workflow does not re-file mock-debt**
   — it only files lows + cap-remainder as `review-fix`. **Re-block dependents:** when a
   filed `review-fix` / cap-remainder issue is one a still-open **dependent** must not build on, append
   its `#N` into that dependent's existing `## Blocked by` section — read the dependent's body, add the
   ref to the `## Blocked by` block only, and write it back with
   `gh issue edit <dependent> --body-file <patched>`. Touch **no other part** of the dependent's body.
   (my-review explicitly disclaims this dependent re-wiring — the workflow owns it.)

Repeat for **N** rounds or until the ready set drains. The merger attempts to resolve conflicts
under the done-check; an **empty ready set**, a **conflict-stop** / **red done-check**, or an
**implementer failure** stops the loop with a clear report; everything else continues to the next
round. The result is **left on the orchestration branch** for you to merge into `dev`/`main`
yourself — the run never merges back to the launch branch and never removes the orchestration
worktree.

## Step 2 — on return: close the merged issues, exit the worktree, report
When the Workflow returns, back on the main thread. **Close first** — before the worktree exit and
before the report — so a failed close is loud and stops the run rather than being buried under a
success table:

- **Close from the main thread (#77 fix 1).** The workflow **returns the merged-issue list**
  (`{ mergedIssues: [{ n, mergeCommit }] }`) instead of closing anything itself. Close each one here:
  `gh issue close <N> --comment "Merged in <mergeCommit> by /orchestrate."` This is the **only** place
  the run closes an issue. An **irreversible outward-facing** write belongs on the main thread, where
  the conversational context can account for it: the same call, made from inside a low-context
  subagent, was killed by a safety classifier on the run behind #77 — and it *should* have been,
  because that subagent had been handed an issue it could not explain.
- **Verify every close (#77 fix 2).** A close that silently fails must not pass as success. After
  closing, re-read each issue's state — `gh issue view <N> --json state` — and if any issue is
  **still open after its close**, **stop and report it loudly**, naming the issue and the merge commit
  it was merged in. Do **not** run the PRD reap on an unverified close: the reap would read a
  still-open child and draw the wrong conclusion. (The loop itself stays convergent regardless — the
  workflow's `mergedThisRun` re-pick guard never re-picks a merged issue, close or no close — so this
  check is about *reporting the truth*, not about rescuing the loop.)
- **`ExitWorktree(keep)`** — return to the original directory with the **orchestration branch** and
  worktree intact (or the session-exit prompt offers keep/remove). The merged rounds all land on the
  orchestration branch inside the orchestration worktree — never on the launch branch and never in
  the primary checkout.
- Print a **status table**: issue `#` → title → merged? / closed? → done-check → review verdict →
  notes (conflicts, failures). If any `mock-debt` is open, add a one-line **ledger summary**
  (`mock-debt: N open — #A, #B …`) and note any `e2e-gate` held by it.
- **Report the review + fix-loop outcome (Steps 6–9).** For each built slice, include `my-review`'s
  final verdict and how the **planner-free fix loop** resolved its findings — what it fixed in-run,
  and any **lows / cap-remainder** filed as `review-fix` follow-ups (with the dependents re-blocked
  onto them). Name any `mock-debt` follow-up the audit filed (it feeds the ledger summary above). The
  fix loop **acts** on the findings **before each branch merges**; this report records what it fixed
  and what it filed.
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
