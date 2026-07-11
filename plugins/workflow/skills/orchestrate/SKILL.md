---
name: orchestrate
description: Run N rounds of the autonomous issue-solving loop inside a Workflow — each round an agent picks the ready set (blockers closed, skip hitl), classifies each ready issue with one cheap haiku call (auto-accepted) to tier-route its planner, implementer and reviewer models, plans each standard/complex issue into a work order with the workflow:planner subagent at the tier's planner model (a trivial issue skips the plan stage — its implementer self-plans), builds up to K ready issues with one implementer each in isolated git worktrees, reviews each built slice with `personal-tools:my-review` at the tier's reviewer model — running the central-mechanism / mock-drift audit — and acts on the findings through a per-issue planner-free fix loop (capped by --max-cycles, default 2: the findings themselves are the implementer's work order; low→file) before handing the clean-or-capped branches to a merger that merges in dependency order and resolves conflicts under the done-check, closes the merged issues, and files the lows + cap-remainder as review-fix follow-ups while re-blocking dependents and mirroring open mock-debt into the PRD ledger. Use for "/orchestrate", "run the loop", "build the ready issues".
argument-hint: "[N rounds=1] [--max K=3] [--max-cycles K=2] [--complexity trivial|standard|complex]"
effort: high
allowed-tools: Read, Grep, Bash, Agent, Skill, AskUserQuestion, Workflow
---

Run the autonomous issue-solving loop on this repo's GitHub issues. The round loop runs inside a
**Workflow** — the skill body **no longer runs the round on the main thread**. The main thread does
only three things: enter the orchestration worktree (Step 0), invoke the Workflow (Step 1), and, on
return, exit the worktree and report (Step 2 + end-of-run PRD reap). Running the round inside the
Workflow keeps per-issue chatter (implementer reports, merge results) out of the main conversational
context — only compact results return.

`$ARGUMENTS` = `[N] [--max K] [--max-cycles K] [--complexity <tier>]` — **N** rounds (default 1);
**`--max K`** = max issues built in parallel per round (default 3); **`--max-cycles K`** = the
per-issue fix-loop cap (default **2**) — the **initial review is free**
and the cap **counts re-reviews**, each re-review decrementing the budget; **`--complexity <tier>`**
(trivial|standard|complex) pins every issue to that tier and skips per-issue classification.

Backend is **GitHub Issues via `gh`** — no `gh api`, no PR merges. Never touch issues labeled
`hitl` (needs a human) or `prd` (a PRD tracking doc — slice it with `/to-issues` first). Never
push. Each round **classifies every ready issue with one cheap in-workflow call** (auto-accepted —
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
its complexity **tier**, classified by **one cheap in-workflow call** and **auto-accepted** —
there is **no interactive confirm**, because the whole run is autonomous past the launch gate. The
tier→`{model, effort}` mapping lives in the plugin's `model-tiers.json`, resolved by
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-tier.sh" <tier>`; the **main thread runs that helper
once per tier at launch** (Step 1) and inlines the results into a single **`ROSTER`** const in the
workflow script, so the round itself never re-resolves.

A Workflow leaf `agent()` **can't** reuse the `classify-task` skill (that skill fans out its own
Explore subagents from the main thread), so each issue is classified by **one** in-workflow stage —
a **single `haiku` `agent()` call** that reads the issue body + comments and emits a **real tier**.
There is **no separate explore stage**: the classifier is a cheap leaf that may grep the repo
itself, and the tier is a model-routing hint, not a deliverable — two agents per issue to produce a
one-word answer was pure overhead. The emitted tier indexes the launch-resolved `ROSTER` —
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
built slice (Step 6) and runs the central-mechanism / mock-drift audit; the severity-routed fix
loop (Step 7) then re-reviews with the same agent. **Before entering the
worktree (Step 0)**, check it's available — if `personal-tools:my-review` is **not** in your
available agents, **fail loud** naming the missing piece — e.g. "personal-tools plugin not
installed: my-review agent unavailable" — and **stop**. Do **not** substitute another reviewer.
This mirrors `/pipeline`'s Step-0 hard-dep check.

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
  //         complexity (pinned tier from --complexity, or undefined → classify per issue)
};

// `args` may reach the script as a JSON STRING, not an object — normalize before reading, then
// parse-or-throw. A blind bare destructure of `args` on a string yields undefined and the round loop
// falls through spawning nothing (silent empty success). Throw loud instead of exiting clean-empty.
const input = typeof args === 'string' ? JSON.parse(args) : args;
if (!input || typeof input.rounds !== 'number') throw new Error(`bad args: ${JSON.stringify(args)}`);
const { baseRepo, baseBranch, rounds, maxParallel, maxCycles, complexity } = input;

// JSON Schemas for the spawns whose results are read as objects. Without these,
// agent() hands back a string and every property access below is undefined.
//   READY_SCHEMA  → { issues: [{ n, title, body, comments }] }   // comments: never body-only
//   CLS_SCHEMA    → { tier }
//   BUILT_SCHEMA  → { n, branch, failed }
//   REVIEW_SCHEMA → { findings: [{ severity, path, summary }] }
//   MERGE_SCHEMA  → { mergedIssues, conflictStop, doneCheckRed }

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

// Repeat for N rounds, or until the ready set drains.
for (let round = 0; round < rounds; round++) {
  // 1. Pick the ready set — a Workflow agent, since a Workflow can't run gh/git itself.
  const ready = await agent(
    `List the ready-for-agent issues; see "Each round" step 1`,
    { schema: READY_SCHEMA });
  if (ready.issues.length === 0) return stop("empty ready set");   // empty ready set → stop

  // 2. Classify each picked issue with ONE cheap haiku call — tier auto-accepted. No explore stage:
  //    the classifier greps for itself if it needs to. --complexity pins the tier and skips this.
  const picked = ready.issues.slice(0, maxParallel);   // up to K, lowest number first
  for (const issue of picked) {
    if (complexity) { issue.tier = complexity; continue; }        // escape hatch: pin, no classify
    const cls = await agent(
      `Issue #${issue.n} body + comments → tier (trivial|standard|complex); see step 2
       \n\n${issue.body}\n\n## Issue comments\n${issue.comments}`,
      { model: "haiku", effort: "low", schema: CLS_SCHEMA });     // hardcoded cheap — NOT tier-routed
    issue.tier = cls.tier;                                        // real tier, auto-accepted
  }

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

  // 4. One worktree + one implementer per picked issue. Work order = the plan text when there is one;
  //    for a trivial issue (issue.plan === null) the ISSUE BODY is the work order and the implementer
  //    self-plans. pipeline(items, stage) — pass the ITEM LIST and a stage callback, not promises.
  const built = await pipeline(picked, issue =>
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
        schema:    BUILT_SCHEMA }));
  if (built.some(b => !b || b.failed)) return stop("implementer failure");   // null = agent died

  // 5. Review each built slice (INITIAL review — FREE, does not count against maxCycles):
  //    personal-tools:my-review at the tier's reviewer model on the issue's branch diff
  //    (<base>..issue-<N>), handed issue.plan for conformance context. It runs the central-mechanism
  //    / mock-drift audit (declared → confirm; undeclared central mock → auto-convert; both file a
  //    mock-debt follow-up — my-review OWNS that filing) and returns a findings block.
  for (const issue of picked) {
    issue.review = await agent(
      `Review the branch diff <base>..issue-${issue.n}. Plan for conformance context:\n\n${issue.plan}
       \n\nIssue #${issue.n}'s comments — ground truth for the review:\n${issue.comments}`,
      { agentType: "personal-tools:my-review",
        model:     ROSTER[issue.tier].reviewer.model,
        effort:    ROSTER[issue.tier].reviewer.effort,
        schema:    REVIEW_SCHEMA });
  }

  // 6. Fix loop per issue — PLANNER-FREE. The review's own findings block IS the work order: a
  //    finding already names the path, the defect, and the fix, so re-planning it was a whole extra
  //    agent restating the reviewer. Hand the medium-or-worse findings straight to a fresh
  //    implementer, then re-review. Loop until clean-or-capped, BEFORE it merges. maxCycles
  //    (default 2) counts RE-REVIEWS (the step-5 review is free). Reviewer model HELD CONSTANT.
  //    Criticals lead the work order (ascending path — deterministic), then highs, then mediums.
  //    low → filed in step 9, never fixed in-run. No cap AskUserQuestion gate — autonomous.
  for (const issue of picked) {
    let cycles = 0;
    while (mediumOrWorseOpen(issue.review) && cycles < maxCycles) {
      const preFix = revParse(`issue-${issue.n}`);                    // <pre-fix HEAD> for the delta
      const fixOrder = orderFindings(issue.review);                   // plain code: critical → high → medium,
                                                                      // ascending path. NO planner spawn.
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
    issue.capRemainder = mediumOrWorse(issue.review);                 // open at cap → filed in step 9, merges anyway
  }

  // 7. Merge the clean/capped branches serially in ascending issue number, conflicts gated by the
  //    done-check. Runs AFTER the fix loop — all-lows/clean and cap-exhausted slices both merge.
  const merged = await agent(                       // no model/effort → the merger's frontmatter pins govern
    "Merge this round's branches serially, ascending issue number. Base = the orchestration worktree.",
    { agentType: "workflow:merger", schema: MERGE_SCHEMA });
  if (merged.conflictStop || merged.doneCheckRed) return stop("conflict-stop / red done-check");

  // 8. Close the merged issues.
  for (const n of merged.mergedIssues) gh(`issue close ${n} --comment "<merge commit>"`);

  // 9. File the lows + cap-remainder as review-fix + ready-for-agent follow-ups, then append each
  //    into any open dependent's ## Blocked by (gh issue edit). my-review already filed the mock-debt
  //    (steps 5–6) — the workflow does NOT re-file it.
  for (const issue of picked)
    fileReviewFix(lows(issue.review).concat(issue.capRemainder));     // gh issue create … --label review-fix; then gh issue edit dependents
}
```

## Each round (inside the Workflow)
Everything in this section happens **inside the Workflow**, over up to **K** ready issues:

1. **Pick the ready set** (a workflow agent, since a Workflow can't run `gh`/git itself).
   `gh issue list --label ready-for-agent --state open --json number,title,labels,body,comments`.
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
2. **Classify each picked issue with one cheap call (auto-accepted).** A Workflow leaf `agent()`
   **can't** reuse the `classify-task` skill (it fans out its own Explore subagents from the main
   thread), so each picked issue is classified by **one in-workflow stage**: a **single `agent()`
   call pinned to `haiku` at `low` effort** — **not** tier-routed, since routing is what it is
   *deciding* — that reads the issue body **and its comments** and emits a **real tier**
   (trivial/standard/complex) by classify-task's rubric. *Size is not the signal*: a seam move or new
   infrastructure is **complex**, mechanical no-decision edits are **trivial**. It may grep the repo
   itself if the issue text is thin; there is **no separate explore stage** feeding it — a tier is a
   one-word model-routing hint, and spending two agents per issue to produce it cost more than the
   routing saved. The tier is **auto-accepted — no interactive confirm** (the run is autonomous past
   the launch gate), and it **tier-routes the planner, implementer and reviewer** via `ROSTER`.
   **`--complexity <tier>`** short-circuits the stage — it **pins every issue** to that tier and
   **skips classification**, so no classify call runs at all.
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
   **each on the model its tier routed** (`ROSTER[issue.tier].implementer`). An **implementer failure** stops
   the loop with a report.
6. **Review each built slice — initial review (free).** For each issue the round built, spawn
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
8. **Merge + verify via the merger, then close (C4).** After the fix loop clears or caps each slice,
   hand the **completed branches** to the **`workflow:merger`**, passing the **absolute
   orchestration-worktree** path as this run's base repo (a linked worktree → the guard allows the
   merger's writes) and its **base branch**, the **ordered list of completed issues** (each: `#N`,
   branch `issue-<N>`, and its **absolute worktree path**) in **ascending issue number**, and the
   project's **done-check command**. Ascending issue number is the **deterministic** merge order; the
   picked issues' blockers were already closed, but file-level overlap can still collide — **conflicts
   are expected and the merger resolves them under the done-check**. The merger merges serially,
   **resolves conflicts by default (gated by the done-check)**, and returns per-issue results plus the
   final done-check result and any conflict-stops. Act on its result:
   - issues it merged green → `gh issue close <N>` each (comment the merge commit);
   - a **conflict-stop** (unresolvable conflict or a **red done-check** after resolution), or an
     implementer-reported failure → comment that issue, leave its worktree, and **stop the loop**
     with a report. **Never keep an unverified resolution** — that discipline lives in the merger.
9. **File the lows + cap-remainder; re-block dependents.** The workflow absorbs the filing `my-review`
   does not: for every **low** finding and every **cap-remainder** (medium-or-worse left open when the
   cap exhausted), file a follow-up issue. Ensure the labels exist
   (`gh label create review-fix 2>/dev/null || true`, same for `ready-for-agent`), then
   `gh issue create --title '<one-line fix>' --label ready-for-agent --label review-fix
   --body-file <tmp>` (single-quote the title — it embeds review-derived text that may carry shell
   metacharacters) with the template `## What to build` (the fix) / `## Acceptance criteria` /
   `## Blocked by` (`None - can start immediately` unless the fix depends on this branch landing —
   then name it). **Mock-debt stays my-review's job:** the central-mechanism audit already filed the
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

## Step 2 — on return: exit the worktree + report
When the Workflow returns, back on the main thread:

- **`ExitWorktree(keep)`** — return to the original directory with the **orchestration branch** and
  worktree intact (or the session-exit prompt offers keep/remove). The merged rounds all land on the
  orchestration branch inside the orchestration worktree — never on the launch branch and never in
  the primary checkout.
- Print a **status table**: issue `#` → title → merged? / closed? → done-check → review verdict →
  notes (conflicts, failures). If any `mock-debt` is open, add a one-line **ledger summary**
  (`mock-debt: N open — #A, #B …`) and note any `e2e-gate` held by it.
- **Report the review + fix-loop outcome (Steps 6–9).** For each built slice, include `my-review`'s
  final verdict and how the **severity-routed fix loop** resolved its findings — what it fixed in-run,
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
