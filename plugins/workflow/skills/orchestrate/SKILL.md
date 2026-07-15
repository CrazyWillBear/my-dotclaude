---
name: orchestrate
description: Run the autonomous issue-solving loop inside a Workflow — the main thread resolves the run's scope to an explicit issue allowlist (--issues, or --prd N walked into its child slices, never a repo-wide label sweep), reads each scoped issue's persisted complexity tier from its `tier:trivial|standard|complex` label (backfilling a missing one with the classify-task skill and writing the label back), and fetches the whole issue graph once with scope-graph.sh; the Workflow then runs a continuous scheduler over that frozen graph — readiness (every `## Blocked by` ref closed, skip hitl, hold an e2e-gate while mock-debt is open) is computed in plain JS, not by a model — keeping --max N issues in flight, each slot running plan (workflow:planner, complex tier only — trivial and standard issues self-plan) → build (workflow:implementer in an isolated git worktree at the tier's implementer model) → review (personal-tools:my-review at the tier's reviewer model, running the central-mechanism / mock-drift audit) → a planner-free fix loop capped by --max-cycles → a serial merge queue (one workflow:merger, opus, merges in dependency order under the done-check). A merged issue unblocks its dependents and the freed slot admits the next ready issue; a failure drains the run instead of killing it mid-flight. Per-issue haiku bookkeeping files the lows (grouped, parked) + cap-remainder as review-fix follow-ups and re-blocks dependents; the workflow hands the merged-issue list back to the main thread, which closes those issues itself and verifies every close, and open mock-debt mirrors into the PRD ledger. Use for "/orchestrate", "run the loop", "build the ready issues".
argument-hint: "[--max N=5] [--max-cycles K=2] [--prd N] [--issues N,N,...] [--skip-unknown]"
effort: high
allowed-tools: Read, Grep, Bash, Agent, Skill, AskUserQuestion, Workflow
---

Run the autonomous issue-solving loop on this repo's GitHub issues. The loop runs inside a
**Workflow** — the skill body **no longer runs the loop on the main thread**. The main thread does
only four things: resolve the run's **scope, tiers and graph** (Step 0a), enter the orchestration
worktree (Step 0b), invoke the Workflow (Step 1), and, on return, **close the merged issues**, exit
the worktree and report (Step 2 + end-of-run PRD reap). Running the loop inside the Workflow keeps
per-issue chatter (implementer reports, merge results) out of the main conversational context — only
compact results return. The **closes are the deliberate exception**: they stay on the main thread
(Step 2), because an **irreversible outward-facing** GitHub write belongs where the conversational
context can account for it — see Step 0a's note on #77.

`$ARGUMENTS` = `[--max N] [--max-cycles K] [--prd N] [--issues N,N,...] [--skip-unknown]` —
**`--max N`** = the number of **concurrent issues in flight** (default **5**), *not* a batch size:
each slot runs its own plan → build → review/fix → merge chain, and when an issue's **merge lands**
its dependents unblock and the freed slot **takes the** next ready issue. (Merging is serial and
batched — one merger spawn drains the whole queue — so a slot frees when the **batch carrying its
issue** lands, not the instant that one branch merges.) **`--max-cycles K`** = the
per-issue fix-loop cap (default **2**) — the **initial review is free** and the cap **counts
re-reviews**, each re-review decrementing the budget. **`--prd N`** scopes the run to PRD #N's child
slices, and **`--issues N,N,...`** scopes it to a literal issue list (Step 0a).
**`--skip-unknown`** downgrades the unfetchable-issue throw (a deleted or renamed child) from a
hard stop to a logged skip — off by default, because failing loud on a partial scope is right.

There are **no rounds** and **no tier flag**. A tier is a **persisted label** — edit
`tier:trivial` / `tier:standard` / `tier:complex` on the issue to change how it routes.

Backend is **GitHub Issues via `gh`** — no `gh api`, no PR merges. Never touch issues labeled
`hitl` (needs a human) or `prd` (a PRD tracking doc — slice it with `/to-issues` first). Never
push. Each admitted issue **tier-routes its implementer** (and its planner and reviewer) model via
the launch-resolved `ROSTER`. A per-issue **plan stage** (tier-routed by `ROSTER[issue.tier].planner`)
writes a **complex** issue's **work order** with the **`workflow:planner`** subagent — **trivial and
standard** issues **skip the plan stage entirely** and their implementers self-plan. One
**implementer** then builds the issue; then **`personal-tools:my-review`** reviews the built slice at
the tier's **reviewer** model, and a per-issue **planner-free fix loop** (capped by `--max-cycles`,
default 2) acts on the findings — the review's own findings block **is** the fix work order, handed
straight to a fresh implementer — before the clean-or-capped branch merges.

## Tier routing

Each issue's **planner**, **implementer**, and **reviewer** `{model, effort}` are routed by its
complexity **tier**, and the tier is a **persisted GitHub label**: `tier:trivial`, `tier:standard`,
`tier:complex`. `/to-issues` sets it at slice time, grounded in the exploration it already did; this
skill **reads** it at launch (Step 0a) and **backfills** any issue that is missing one. The tier is
therefore **visible, editable and durable** — not a guess re-made on every run.

This replaced a cheap `haiku` leaf that emitted the tier as a free rider on the ready-set pick:
ungrounded, invisible, never persisted. **Under-tiering is the expensive failure** — it routes real
work to a model too cheap for it, and you pay for the bad build *and* the fix cycles that chase it.

The tier→`{model, effort}` mapping lives in the plugin's `model-tiers.json`, resolved by
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-tier.sh" <tier>`; the **main thread runs that helper
once per tier at launch** (Step 1) and inlines the results into a single **`ROSTER`** const in the
workflow script, so the scheduler never re-resolves. The emitted tier indexes it —
`ROSTER[issue.tier].planner`, `ROSTER[issue.tier].implementer`, `ROSTER[issue.tier].reviewer`, each a
`{model, effort}` pair.

The **`workflow:merger`** is **not** tier-routed — it is spawned with no `model`/`effort` and its
frontmatter pins govern (**opus**). A bad merge resolution corrupts the base branch for every issue
in the run, so the merger is the one stage that never gets a cheap model.

## Hard dependency — fail loud at launch
The loop **hard-depends on the `personal-tools` plugin**: the **`my-review`** agent reviews each
built slice (step 5) and runs the central-mechanism / mock-drift audit; the planner-free fix
loop (step 6) then re-reviews with the same agent. **Before entering the
worktree (Step 0b)**, check it's available — if `personal-tools:my-review` is **not** in your
available agents, **fail loud** naming the missing piece — e.g. "personal-tools plugin not
installed: my-review agent unavailable" — and **stop**. Do **not** substitute another reviewer.
This mirrors `/pipeline`'s Step-0 hard-dep check.

## Step 0a — resolve the scope, the tiers, and the graph (main thread)

### The allowlist
**This is the fix for #77's defect A, and it runs on the main thread before anything else.** The
loop used to pick its work with a repo-wide `ready-for-agent` label query. That is a correctness
bug, not a convenience one: on a real run it swept in an unrelated issue from a different PRD and
**built it into the PRD's branch**. Nothing tied the picked issues back to the work you asked for.

So the run **never queries for work**. The main thread resolves an **explicit issue allowlist**
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

**The allowlist is frozen at launch** and never re-queried. That freeze is load-bearing twice over:

- **Nothing the run files can be built by the run.** A `review-fix` follow-up the scheduler files in
  step 8 is not in the allowlist, so it cannot be picked up and built. Without the freeze, a
  **cap-remainder** filed at `--max-cycles` would be rebuilt immediately — silently bypassing the
  very cap that parked it.
- It bounds the blast radius to the work you named, which is what #77 asked for.

If the allowlist is **empty**, stop before entering the worktree and say why — an empty scope is
never a reason to widen the query.

### Tier resolution
Read each scoped issue's labels and take its tier from `tier:trivial` / `tier:standard` /
`tier:complex`.

- **Missing a `tier:*` label → backfill it.** Run the **`classify-task`** skill in **batch mode**
  (`/classify-task <N> --no-confirm`) — it fans out its own Explore agents from the main thread, so
  the tier is *grounded*, and batch mode suppresses its per-issue confirm. Then **persist it**:
  ensure the labels exist
  (`gh label create tier:standard --description "complexity tier: standard" 2>/dev/null || true`,
  same for `tier:trivial` and `tier:complex`) and write it back with
  `gh issue edit <N> --add-label tier:<t>`. The next run reads the label instead of re-classifying.
- **The tier is auto-accepted.** **Never prompt** to confirm or override a tier — the run is
  autonomous past the launch gate, and a tier is a model-routing hint, not a deliverable. Report the
  backfilled tiers in the launch report; that is the whole interaction.
- **Conflicting labels** (an issue carrying two `tier:*` labels) → the **highest tier wins**
  (complex > standard > trivial) and you **warn** in the launch report. A mislabel must never route
  real work to a model too cheap for it.

The scope is now `[{ n, tier }]` for every allowlisted issue.

### Graph fetch
Run the graph helper **once**, over the whole allowlist:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/scope-graph.sh" <N1> [N2 ...]
```

It prints **one JSON document** — `{ issues: [{ n, title, state, labels, tier, body, comments,
blockedBy }], blockerStates, mockDebtOpen }` — and that JSON **is the workflow's world**: the issue
bodies **and their comments**, every issue's `blockedBy` refs parsed from its `## Blocked by` section
(bare `#N` refs; a `#N` in prose is not a blocker), the `blockerStates` of every ref (in scope or
not), and the open `mock-debt` ledger. Empty output → the workflow's empty-graph throw fires, loudly.

The graph is **frozen at launch**, exactly like the allowlist: bodies, comments and blocker states
are read once. This is what lets the scheduler compute readiness itself, with **no model call** and
no mid-run `gh` re-reads (a Workflow cannot run `gh` at all).

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

**Then exclude the per-issue worktrees.** The run nests every issue's worktree at
`<baseRepo>/.worktrees/issue-<N>` — **inside** the orchestration worktree's own working tree — so
without this they show up as untracked files in `git status` while the **merger** resolves conflicts
and runs its final done-check. Append the path to the repo's **local** exclude file (untracked, not
a tracked `.gitignore` edit in the user's repo), idempotently:

```bash
excl="$(git rev-parse --git-common-dir)/info/exclude"
grep -qxF '.worktrees/' "$excl" 2>/dev/null || printf '.worktrees/\n' >> "$excl"
```

## Step 1 — invoke the Workflow (the single launch gate)
The scheduler runs as a **Workflow**, not on the main thread. From the orchestration worktree,
record the run's base for the workflow:
- **base repo path** = `git rev-parse --show-toplevel` (a linked worktree — the merger's writes land
  here and the `PreToolUse` guard allows that);
- **base branch** = `git rev-parse --abbrev-ref HEAD` (the **orchestration branch** from Step 0b).

**Resolve the ROSTER at launch (main thread).** Before invoking the Workflow, run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-tier.sh" <tier>` **once per tier** — three calls,
`trivial` / `standard` / `complex` — parse each output's `key=value` lines (`planner_model` /
`planner_effort` / `implementer_model` / `implementer_effort` / `reviewer_model` /
`reviewer_effort`), and inline the resolved values into the single `ROSTER` const of the workflow
script you pass to the Workflow tool — **never hand-write those values**. If any call prints a
`WARN` (missing or invalid config), surface it to the user and continue on the fallback (standard)
roster it returned. The `ROSTER` is then frozen for the whole run.

Then **invoke the Workflow tool** with the orchestrate scheduler workflow. **This list is the only
thing that carries a value into the script**, and the script reads each one off `input` — a key
missing here arrives as `undefined`, so pass **every** one of them:

| input | value |
|---|---|
| `baseRepo=` | the base repo path above (the **orchestration worktree**) |
| `baseBranch=` | the base branch above (the **orchestration branch**) |
| `maxParallel=` | `--max N`, default **5** |
| `maxCycles=` | `--max-cycles K`, default **2** |
| `doneCheck=` | the project's done-check command |
| `graph=` | the frozen JSON resolved in Step 0a — the **only** issues the run may ever build |
| `skipUnknown=` | **true** when `--skip-unknown` was passed, else **false** |

(A flag that is parsed, documented and guarded but never *passed* is inert: the script would read
`input.skipUnknown` as `undefined`, `--skip-unknown` would do nothing, and the unfetchable-issue
throw would fire anyway.)

The skill **passes the orchestration worktree** path and branch into the workflow as its base, so
every per-issue worktree and the merger operate **under** the orchestration worktree and the
**primary checkout is never touched**. Approving the **Workflow permission dialog is the single
launch gate** — after you approve it the run is autonomous; no prompt fires until the end-of-run PRD
offer.

The workflow the tool runs (an `export const meta {…}` + `agent()` script) implements the scheduler
below. Its shape:

**Transcribe the call signatures exactly.** Every spawn is `agent(prompt, opts)` — the prompt is the
**first positional argument**, never a field inside an object. `opts` is
`{ model, effort, agentType, schema, label, phase, isolation }`. Three traps, each of which fails
*silently*: passing one object (`agent({ … })`) sends the whole thing as the prompt and no `opts`, so
tier routing degrades to session defaults; the opts key is **`agentType`**, not `subagent_type` (that
is the `Agent` tool's spelling and is ignored here); and a bare `agent()` returns the subagent's text
**as a string**, so any result you destructure must pass a `schema:`.

**Every spawn can die, and a dead agent returns `null` — it does not throw.** So **every**
`agent()` call site guards its result before reading it, and the js block below carries a
**`GUARD AUDIT`** comment naming all eight and the guard each one has. An unguarded spawn does not
crash the run; it *degrades* it into a wrong answer — a null **review** reads as a clean review (no
findings → no fix loop → the slice merges **unreviewed**), and a null **plan** is indistinguishable
from the self-planning tiers' deliberate null (a complex issue's implementer is then told to
self-plan).

**Normalize `args` before destructuring.** The Workflow tool hands the script its inputs — the
base repo path and branch, `maxParallel`, `maxCycles`, `doneCheck`, `skipUnknown`, and the `graph`
(Step 1's table lists them all) — as a
single value that **may arrive as a JSON string rather than an object**. Read it blindly and every
field yields `undefined`; the scheduler's slot loop then falls straight through, spawns nothing, and
reports a **silent empty success** (the #53 / #70 / #73 class). The script must **parse-or-throw**:
normalize with `typeof args === 'string' ? JSON.parse(args) : args`, then **throw** if `maxParallel`
is missing or not a number, or if the `graph` has no issues, and only then destructure. A workflow
that throws is loud; a workflow that reads `undefined` exits clean having done nothing.

**Then guard the graph's *contents* — fail loud before any spawn.** A non-empty graph is not a
runnable one, and the same silent-empty failure walks in through the side door:
- **any scoped issue whose fetch failed** (`state: "unknown"` — an unauthenticated `gh`, a deleted
  issue) → **throw**. `scope-graph.sh` deliberately keeps it rather than dropping it, but nothing
  downstream reacts: `isReady` wants `open`, so the run would admit nothing, break on its first pass
  and return a clean empty success on a scope that was never really fetched. **`--skip-unknown`**
  downgrades this one throw to a **logged skip**: fail-loud is the right default, but with no escape
  hatch a single deleted or renamed child makes a 20-slice PRD **permanently unrunnable** until its
  body is hand-edited. A skipped issue is named in the log, never silently dropped;
- **nothing in the scope is *ready*** (`!graph.issues.some(isReady)`) → **classify, then throw**.
  Note this is **readiness**, not openness: an all-open scope in which every issue is blocked by an
  **unclosed out-of-scope** issue, or by a `## Blocked by` ref aimed at a **PR number** (which
  `gh issue view` cannot resolve, so it lands `unknown` and never `closed`), or in which every issue
  carries `hitl`, passes an openness check, **admits nothing**, breaks on the first pass and returns
  `{ mergedIssues: [], stopReason: null }` — reading as a clean drain. Same silent-empty class,
  front door this time.

  But **not every empty ready set is a broken scope**, and a guard that cannot tell *"nothing to do"*
  from *"the scope is broken"* converts two **designed, expected** states into a hard error. So
  **classify the emptiness first** and return a **clean empty that says why** for these two:
  **every scoped issue is already closed** (re-running `--prd N` after the last slice landed —
  and `--issues` does no state filter at all), or **the only issues left are `e2e-gate` issues held
  by open `mock-debt`** (the gate doing precisely its job — throwing there would make the gate's
  success look like a crash). **Throw only when the emptiness is unexplained**;
- **any open issue with no tier** (`!ROSTER[i.tier]`) → **throw**. Tier resolution above backfills
  every one, so a null tier here means `classify-task` or the label write failed — and
  `ROSTER[null].planner` is a `TypeError` that would kill the chain *after* the run already paid for
  its first build.

```js
// THIS BLOCK IS EXECUTED BY A TEST. `plugins/workflow/tests/orchestrate-block.harness.js` extracts
// it, compiles it as the async function body the Workflow runtime runs it as, and drives it against
// a stubbed agent() — killing each spawn in turn to assert the run DRAINS instead of degrading. So
// an edit here can break a test that is about BEHAVIOR, not about a string; run that harness (or
// `bash plugins/workflow/tests/test_orchestrate-block-behavior.sh`) after touching this block.
export const meta = {
  name: "orchestrate-scheduler",
  // inputs: baseRepo (orchestration-worktree path), baseBranch,
  //         maxParallel (--max N, default 5 — CONCURRENT issues in flight, NOT a batch size),
  //         maxCycles (per-issue fix-loop cap, default 2),
  //         doneCheck (the project's done-check command),
  //         skipUnknown (--skip-unknown: log-and-skip an unfetchable issue instead of throwing),
  //         graph (scope-graph.sh's JSON, resolved in Step 0a and FROZEN at launch:
  //                { issues: [{ n, title, state, labels, tier, body, comments, blockedBy }],
  //                  blockerStates, mockDebtOpen })
};

// `args` may reach the script as a JSON STRING, not an object — normalize before reading, then
// parse-or-throw. A blind bare destructure on a string yields undefined and the slot loop falls
// through spawning nothing (silent empty success). Throw loud instead of exiting clean-empty.
const input = typeof args === 'string' ? JSON.parse(args) : args;
if (!input || typeof input.maxParallel !== 'number') throw new Error(`bad args: ${JSON.stringify(args)}`);
// The graph IS the Step-0a allowlist (#77 defect A). An absent/empty graph must throw, never degrade
// into a repo-wide query — a run that picks its own work can build issues nobody asked for.
if (!input.graph || !Array.isArray(input.graph.issues) || input.graph.issues.length === 0)
  throw new Error(`empty graph: refusing to pick work repo-wide — see Step 0a`);
const { baseRepo, baseBranch, maxParallel, maxCycles, doneCheck, graph } = input;
const skipUnknown = input.skipUnknown === true;

// ---- the spawn schemas: LITERAL JSON Schema objects, defined HERE ----
// Every spawn whose result is read as an object passes one of these. This block is transcribed
// VERBATIM, so a `schema: BUILT_SCHEMA` with no definition in scope is a ReferenceError on the real
// run — the exact crash class the mergeManifest / ghWriteManifest definitions below exist to kill.
// Never leave a schema for the transcriber to guess: without one, agent() hands back a STRING and
// every property access is undefined.
// REQUIRED ONLY WHAT A FAILURE REALLY KNOWS. A schema that marks `worktree` / `branch` / `head`
// required forces a model on the FAILURE path — where the worktree was never created and the
// build never landed a commit — to FABRICATE them to satisfy the contract. Harmless while they
// are read only after `failed` is checked, but a plausible-looking invented `head` becomes the
// fix loop's delta base the moment `failed` is mis-set. So: `n` + `failed` are required on both
// failure-carrying schemas; everything a failed agent cannot honestly know is OPTIONAL, and the
// code below treats it as such. (Audited across all five: REVIEW / MERGE / FILED have no failure
// path — a dead one returns null, which the call sites now guard — and every field they require
// is one a SUCCESSFUL result genuinely has, so they stay as they are.)
const SETUP_SCHEMA = {                          // the per-issue worktree the setup agent created
  type: "object",
  properties: {
    n:        { type: "number" },
    worktree: { type: "string" },               // ABSOLUTE path — verified against worktreeOf(n)
    branch:   { type: "string" },               // issue-<N>
    failed:   { type: "boolean" },
  },
  required: ["n", "failed"],
};
const BUILT_SCHEMA = {
  type: "object",
  properties: {
    n:        { type: "number" },
    branch:   { type: "string" },
    worktree: { type: "string" },
    // head: the branch's HEAD sha AFTER this build. A Workflow cannot shell out, so it cannot
    // rev-parse — the sha must RIDE BACK here or the fix loop has no <pre-fix HEAD> to scope its
    // re-review to. Optional, not required: a FAILED build has no head to report, and the delta
    // base degrades to baseBranch (a full-branch re-review) rather than to "undefined..HEAD".
    head:     { type: "string" },
    failed:   { type: "boolean" },              // red done-check / gave up — the chain drains on it
  },
  required: ["n", "failed"],
};
const REVIEW_SCHEMA = {
  type: "object",
  properties: {
    verdict:  { type: "string" },               // my-review's one-line verdict — Step 2 prints it
    findings: {
      type: "array",
      items: {
        type: "object",
        properties: {
          severity: { type: "string", enum: ["critical", "high", "medium", "low"] },
          path:     { type: "string" },
          summary:  { type: "string" },
        },
        required: ["severity", "path", "summary"],
      },
    },
    // the mock-debt issues THIS review filed — they union into openMockDebt, so the e2e-gate is
    // held by debt the run itself created, not only by debt that predated it
    mockDebtFiled: { type: "array", items: { type: "number" } },
  },
  required: ["verdict", "findings", "mockDebtFiled"],
};
const MERGE_SCHEMA = {
  type: "object",
  properties: {
    mergedIssues: {
      type: "array",
      items: {
        type: "object",
        // mergeCommit rides along: the main thread quotes it in the close comment (Step 2), so the
        // merger must return it, not just the issue number
        properties: { n: { type: "number" }, mergeCommit: { type: "string" } },
        required: ["n", "mergeCommit"],
      },
    },
    // A LIST, not one stop: the merger continues through the batch after a stop ("After all
    // merges" runs regardless), so ONE batch can stop on SEVERAL issues. A singular field would
    // keep one and vanish the rest — attempted, unmerged, unreported, with no reason given. Each
    // stop carries its WORKTREE so the report can say where to look.
    conflictStops: {
      type: "array",
      items: {
        type: "object",
        properties: { n: { type: "number" }, reason: { type: "string" }, worktree: { type: "string" } },
        required: ["n", "reason", "worktree"],
      },
    },
    doneCheckRed: { type: "boolean" },
  },
  required: ["mergedIssues", "conflictStops", "doneCheckRed"],
};
const FILED_SCHEMA = {                          // the follow-up issues the bookkeeper actually created
  type: "object",
  properties: { filed: { type: "array", items: { type: "number" } } },
  required: ["filed"],
};

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

// ---- state (all plain data — the scheduler never asks a model anything) ----
// This block declares; it spawns nothing. It sits ABOVE the launch guards because isReady — which
// one of those guards now calls — is built on it, and a `const` arrow does not hoist.
const runLog     = [];                    // the run's own log — RETURNED, so the report can print it
const log        = m => runLog.push(m);   // a Workflow has no console; the log rides home in the result
const byNumber   = n => graph.issues.find(i => i.n === n);
const dependents = n => graph.issues.filter(i => i.blockedBy.includes(n));   // direct dependents, in scope
const worktreeOf = n => `${baseRepo}/.worktrees/issue-${n}`;   // the path REQUESTED of the setup agent
const closed = new Set([                                    // launch-frozen: states, not queries
  ...Object.entries(graph.blockerStates).filter(([, s]) => s === "closed").map(([n]) => Number(n)),
  ...graph.issues.filter(i => i.state === "closed").map(i => i.n),
]);
// A blocker whose state could not be read — e.g. a `## Blocked by` ref aimed at a PR, which
// `gh issue view` cannot resolve — is never "closed", so its dependent can never be ready. Failing
// CLOSED is right; vanishing from the report is not. Say it once, at launch.
const unknownBlockers = Object.entries(graph.blockerStates)
  .filter(([, s]) => s === "unknown").map(([n]) => `#${n}`);
if (unknownBlockers.length)
  log(`blockers with unknown state (their dependents can never become ready): ${unknownBlockers.join(", ")}`);

// The RE-ADMIT GUARD (#77 fix 3). The workflow no longer closes the issues it merges — the main
// thread does, on return (Step 2). So a merged issue is STILL OPEN in the frozen graph. Track what
// this run merged and never re-admit it: that makes the run convergent WHETHER OR NOT the close ever
// lands, which is exactly what the 1.84M-token spin lacked. Convergence must not depend on a GitHub
// write succeeding.
const mergedThisRun = new Map();          // issue number → merge commit
const held          = new Set();          // dependents of a CAPPED merge — held for the rest of the run
const openMockDebt  = new Set(graph.mockDebtOpen);   // seeded at launch, unioned with mockDebtFiled
const inFlight      = new Map();          // issue number → its chain promise (one per slot)
const mergeQueue    = [];                 // built+reviewed issues waiting to merge (SERIAL)
const bookkeeping   = [];                 // fire-and-forget filing promises, awaited before the return
const bookkeepingFailures = [];           // a filing that REJECTED — surfaced in the return, never silent
const conflictStops = [];                 // [{ n, reason, worktree }] — a batch can stop on SEVERAL
let mergeWorker  = null;                  // the ONE merge worker's promise, or null
let stopReason   = null;                  // set → DRAIN MODE: admit nothing new, let in-flight finish

const drain = reason => {                 // drain-then-stop: never kill in-flight work mid-chain
  if (!stopReason) { stopReason = reason; log(`draining: ${reason}`); }
};

// An IMPROVISATION DETECTOR — not a source of truth. The worktree path and the branch are
// MODEL-SUPPLIED (a haiku setup agent reports them; an implementer echoes them back) and they would
// drive `git -C <path>` for the reviewer, the fix implementer and, through mergeManifest, the
// MERGER, which writes the base branch — and the worktree-guard hook is a PreToolUse matcher on
// Edit|Write|NotebookEdit ONLY, so it does not fence an agent's Bash. We asked for ONE exact path
// and ONE exact branch. So the echoed value is checked against exactly that, and any other value
// DRAINS the chain — the agent that improvised a path never gets a git command pointed at it.
// Note what that makes the echo: information-free. A value that must equal `worktreeOf(n)` to
// survive the check tells us only "the agent obeyed" — so what the later stages are actually handed
// is the constant the SCHEDULER computed (see runIssue), never the model's string. Both together:
// the check catches the improviser, and the constant means a passing echo cannot smuggle anything
// in. (This is also why the `isolation` opt was rejected — it cannot name the branch. Accepting an
// unchecked branch name back from a model gives up what that rejection bought.)
const verifyTree = (issue, tree, branch, who) => {
  if (tree !== worktreeOf(issue.n) || branch !== `issue-${issue.n}`) {
    drain(`${who} on #${issue.n} reported worktree ${tree} · branch ${branch} — `
        + `expected ${worktreeOf(issue.n)} · issue-${issue.n}`);
    return false;
  }
  return true;
};

// Readiness is a topological check over the frozen graph — PLAIN JS, no model call. (It used to be a
// haiku "picker" agent only because a Workflow can't run gh; a model doing DAG arithmetic can, and
// did, hallucinate.) The graph IS the allowlist, so the scope guard is structural: an issue that
// isn't in graph.issues can never be admitted.
const isReady = i =>
  i.state === "open" &&
  !mergedThisRun.has(i.n) &&                        // re-admit guard
  !held.has(i.n) &&                                 // dependent of a capped merge
  !inFlight.has(i.n) &&
  !i.labels.includes("hitl") && !i.labels.includes("prd") &&
  i.blockedBy.every(b => closed.has(b) || mergedThisRun.has(b)) &&
  (!i.labels.includes("e2e-gate") || openMockDebt.size === 0);   // Mock-debt gate (C7)

// ---- launch guards: FAIL LOUD BEFORE ANY SPAWN, never after paying for the first build ----
// scope-graph.sh KEEPS an unfetchable issue as state "unknown" rather than dropping it (a drop
// would narrow your scope behind your back). But nothing downstream reacted to "unknown": isReady
// wants "open", so an unauthenticated `gh` would yield a non-empty graph in which NOTHING is
// admissible — the loop breaks on its first pass and returns a CLEAN EMPTY SUCCESS. That is the
// #53/#70/#73 silent-empty class the parse-or-throw above exists to kill, walking in through the
// side door. React to it here.
const unfetched = graph.issues.filter(i => i.state === "unknown");
if (unfetched.length && !skipUnknown)
  throw new Error(`graph fetch failed for ${unfetched.map(i => `#${i.n}`).join(", ")}: refusing to run on a partial scope (pass --skip-unknown to skip them)`);
if (unfetched.length)   // --skip-unknown: LOGGED, never silently dropped. One dead ref in a 20-slice
                        // PRD must not hard-block the other 19 until the body is hand-edited.
  log(`--skip-unknown: dropping unfetchable ${unfetched.map(i => `#${i.n}`).join(", ")} from the scope`);
// NOTHING READY — not merely "nothing open". Every issue blocked by an unclosed OUT-OF-SCOPE issue,
// or by a `## Blocked by` ref aimed at a PR number (never "closed", by design), or every issue
// `hitl`-labelled, all pass an openness check while admitting NOTHING: the loop breaks on its first
// pass and returns { mergedIssues: [], stopReason: null }, which READS AS A CLEAN DRAIN. Guard on
// the thing the loop actually asks (isReady), not on a proxy for it.
//
// But an empty ready set is not always a BROKEN scope, and a guard that cannot tell "nothing to do"
// from "the scope is broken" turns two LEGITIMATE, DESIGNED states into a hard error.
// Classify the emptiness first; throw only when it is UNEXPLAINED:
//   * every scoped issue already closed/merged → the scope is DONE. Re-running `--prd N` after the
//     last slice landed hits this (and `--issues` does no state filter at all — which is why the
//     `unbuilt` filter below exists). The old openness guard returned a clean empty here, correctly;
//   * the only issues left are e2e-gate issues held by OPEN mock-debt → the mock-debt gate did
//     exactly what it exists to do. Throwing on it would make the gate's success look like a crash.
// Both return a clean empty that SAYS WHY. Everything else — all-hitl, blocked on an unclosed
// out-of-scope issue, a `## Blocked by` ref aimed at a PR — is the silent-empty class: throw.
if (!graph.issues.some(isReady)) {
  const openScoped = graph.issues.filter(i => i.state === "open");
  const gateHeld   = openScoped.filter(i =>                     // ready but for the mock-debt gate
    i.labels.includes("e2e-gate") && openMockDebt.size > 0
    && !i.labels.includes("hitl") && !i.labels.includes("prd")
    && i.blockedBy.every(b => closed.has(b)));
  // TEST CLOSEDNESS DIRECTLY. `openScoped.length === 0` reads like "everything is closed" and is
  // NOT: an issue whose state could not be read is "unknown" — neither open NOR closed — so a scope
  // of nothing but unknowns satisfies it. And --skip-unknown downgrades the `unfetched` throw above
  // to a log, so control REACHES here with exactly that scope: the run would exit clean while
  // stating, falsely, that the scope is complete. That is the #53/#70/#73 silent-empty class walking
  // back in through the guard written to kill it. `.every(closed)` lets any unknown remnant fall
  // through to the throw, where it belongs.
  const allClosed = graph.issues.every(i => i.state === "closed");
  const nothingToDo =
    allClosed
      ? `every scoped issue is already closed — the scope is complete`
      // `openScoped.length > 0`, or an EMPTY open set makes the gate branch fire on `0 === 0` and
      // reports a mock-debt hold that is holding nothing.
      : gateHeld.length === openScoped.length && openScoped.length > 0
        ? `every remaining scoped issue (${gateHeld.map(i => `#${i.n}`).join(", ")}) is `
          + `e2e-gate-held by open mock-debt (${[...openMockDebt].map(n => `#${n}`).join(", ")})`
        : null;
  if (!nothingToDo)
    // NAME THE PARTS THAT ARE EXPLAINED. A gate hold is a DESIGNED state: when it explains only
    // SOME of the scope (an e2e-gate held by mock-debt + one unrelated hitl issue) the throw is
    // still right — loud over silent — but a bare "nothing is READY" misattributes the gate's
    // correct behavior as a broken scope. Same for issues --skip-unknown dropped.
    throw new Error(`no scoped issue is READY (open, unblocked, not hitl/prd): nothing to build — refusing a silent empty success`
      + (gateHeld.length
          ? ` · e2e-gate-held by open mock-debt (BY DESIGN): ${gateHeld.map(i => `#${i.n}`).join(", ")}`
          : ``)
      + (unfetched.length
          ? ` · unfetchable, skipped by --skip-unknown: ${unfetched.map(i => `#${i.n}`).join(", ")}`
          : ``));
  log(`nothing to do: ${nothingToDo}`);
  // The report's FULL shape, not a bare {}: Step 2 destructures every field below.
  return { mergedIssues: [], stopReason: null, conflictStops: [], held: [], bookkeepingFailures: [],
           perIssue: [], unbuilt: openScoped.map(i => i.n), log: runLog };
}
// Step 0a backfills every missing tier, so a null tier HERE means classify-task or the
// `gh issue edit --add-label` write failed for that issue. ROSTER[null] is undefined, and
// ROSTER[issue.tier].planner.model would then TypeError mid-chain — after the run already paid for
// its first build. Refuse at launch instead.
const untiered = graph.issues.filter(i => i.state === "open" && !ROSTER[i.tier]);
if (untiered.length)
  throw new Error(`untiered issue(s) ${untiered.map(i => `#${i.n}`).join(", ")}: Step 0a's tier backfill did not land`);

// ---- findings: ONE definition of "medium or worse", so nothing has to guess its return type ----
const SEVERITY_RANK = { critical: 0, high: 1, medium: 2 };
// Returns an ARRAY of findings (possibly empty), ordered criticals → highs → mediums, each group
// ascending by path. It must be an array because step 8 has to FILE the cap-remainder, not merely
// count it — and an empty array is TRUTHY, so every caller tests `.length`, never the value itself.
const mediumOrWorse = review => (review?.findings || [])
  .filter(f => f && f.severity in SEVERITY_RANK)
  .sort((a, b) => SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity]
                  || String(a.path).localeCompare(String(b.path)));
const mediumOrWorseOpen = review => mediumOrWorse(review).length > 0;   // the fix loop's condition
// The fix work order: those ordered findings rendered as text. Plain code — NO planner spawn.
const orderFindings = review => mediumOrWorse(review)
  .map(f => `- [${f.severity}] ${f.path} — ${f.summary}`).join("\n");
// Absorb a review: union its mock-debt filings into the gate's hold set, and ACCUMULATE its lows.
// Lows accumulate because a delta-scoped re-review will not re-list a low the first review found,
// and lows are never fixed in-run — reading them off the final review alone would lose most of them.
const findingKey   = f => `${f.severity}|${f.path}|${f.summary}`;
const absorbReview = (issue, review) => {
  (review?.mockDebtFiled || []).forEach(n => openMockDebt.add(n));
  for (const f of review?.findings || [])
    if (f?.severity === "low" && !issue.lows.some(l => findingKey(l) === findingKey(f))) issue.lows.push(f);
};

// ---- the two agent input manifests (plain templating — DEFINED, never left to the transcriber) ----
// The branch and worktree come off the ISSUE — the scheduler's own computed constants, which the
// setup agent's echo was verified against (verifyTree) before any git command was pointed at them.
const mergeManifest = batch => [
  `base repo (a linked worktree — the guard allows writes here): ${baseRepo}`,
  `base branch: ${baseBranch}`,
  `done-check: ${doneCheck}`,
  `merge these serially, in ascending issue number:`,
  ...batch.map(i => `- #${i.n} · branch ${i.branch} · worktree ${i.worktree}`),
].join("\n");

const ghWriteManifest = issue => [
  `issue #${issue.n} — merged in ${mergedThisRun.get(issue.n)}`,
  `lows → ONE grouped follow-up, label review-fix ONLY (parked; never ready-for-agent):`,
  ...issue.lows.map(f => `- ${f.path} — ${f.summary}`),
  `cap-remainder → review-fix + ready-for-agent (real work, genuinely ready for a future run):`,
  ...(issue.capRemainder || []).map(f => `- [${f.severity}] ${f.path} — ${f.summary}`),
  `re-block these dependents onto whatever you file: ${dependents(issue.n).map(d => `#${d.n}`).join(", ") || "none"}`,
  `a blocker ref MUST be a bare "#N" alone on its own line under "## Blocked by" — no trailing prose,`,
  `or the next run's graph parser will not see it and will build the dependent on unpaid debt.`,
].join("\n");

// ---- the scheduler: continuous, no round barrier ----
while (true) {
  while (!stopReason && inFlight.size < maxParallel) {          // fill every free slot
    const next = graph.issues.filter(isReady).sort((a, b) => a.n - b.n)[0];   // lowest number first
    if (!next) break;                                          // nothing admissible right now
    inFlight.set(next.n, runIssue(next));
  }
  if (inFlight.size === 0) {
    // Drain the merge QUEUE too, not just a running worker: a chain can free its slot in the window
    // between runMerges exiting its `while (mergeQueue.length)` check and the `.finally()` that
    // clears mergeWorker — leaving its issue queued with nobody left to merge it.
    if (mergeWorker || mergeQueue.length) { await pumpMerge(); continue; }  // let the last merges land
    break;                                                      // scope drained (or fully drained by a stop)
  }
  await Promise.race([...inFlight.values()]);                   // a chain finished → re-scan, refill
}
// allSettled, NOT all: bookkeeping is fire-and-forget, and one rejected filing must never discard
// the return below. A bookkeeping failure cannot be allowed to cost a CLOSE — an unclosed merged
// issue is what the next run rebuilds from scratch (the 1.84M-token failure mode). Each promise
// already .catch()es into bookkeepingFailures at creation (see fileFollowUps), so a failure is
// VISIBLE in the return rather than dying inside a settled array nobody reads.
await Promise.allSettled(bookkeeping);
// The return SERVES Step 2's report: every column the report prints comes from here (or from the
// main thread's own Step-0a record). A bare { mergedIssues, stopReason } would make the report
// unimplementable — the verdicts, the held dependents and the filings would die inside the Workflow.
return {
  mergedIssues: [...mergedThisRun].map(([n, mergeCommit]) => ({ n, mergeCommit })),
  stopReason,
  conflictStops,                                   // [{ n, reason, worktree }] — ALL of them
  held: [...held],                                 // dependents of a capped merge, held all run
  bookkeepingFailures,                             // a filing that REJECTED: its lows / cap-remainder
                                                   // were NOT filed and its dependents were NOT
                                                   // re-blocked — the next run would build them on
                                                   // unpaid debt, so the report must SAY SO
  perIssue: graph.issues.filter(i => i.attempted).map(i => ({
    n:            i.n,
    tier:         i.tier,
    verdict:      i.review?.verdict ?? null,       // my-review's final verdict
    lowsFiled:    i.lows.length,
    capRemainder: (i.capRemainder || []).length,   // medium+ still open at the cap, filed anyway
    followUps:    i.followUps || [],               // the review-fix issues bookkeeping actually filed
  })),
  // "scoped but never admitted" — so it must name only issues that COULD have been admitted. An
  // issue already CLOSED at launch (reachable via --issues, which does no state filter) or carrying
  // hitl / prd was never a candidate: listing it here reports a non-problem as a problem.
  unbuilt: graph.issues
    .filter(i => !i.attempted && i.state === "open"
                 && !i.labels.includes("hitl") && !i.labels.includes("prd"))
    .map(i => i.n),                                // blocked, held, or drained past
  log: runLog,
};

// ---- one slot's chain: plan → build → review → fix loop → merge ----
// Every prompt below interpolates REAL values (the worktree path, the branch, the base branch, the
// done-check). A literal transcription of a placeholder hands the agent the placeholder.
//
// GUARD AUDIT — every agent() call site in this script, and the guard it carries. A DEAD AGENT
// RETURNS NULL (it does not throw), so an unguarded spawn does not crash: it degrades, silently,
// into a WRONG ANSWER. All eight are listed so the next reader can see the sweep is complete:
//   1. setup        → `if (!setup || setup.failed)` + verifyTree — drains
//   2. planner      → `if (issue.tier === "complex" && !issue.plan)` — drains. NOT optional: a null
//                     plan is INDISTINGUISHABLE from the self-planning tiers' deliberate null, so a
//                     dead planner would hand a COMPLEX issue's implementer "no planner ran:
//                     SELF-PLAN it".
//   3. implementer  → `if (!built || built.failed)` + verifyTree — drains
//   4. review       → `if (!issue.review)` — drains. THE WORST ONE TO MISS: mediumOrWorse(null) is
//                     [], so mediumOrWorseOpen is false, the fix loop is SKIPPED, capRemainder is
//                     [] — and the slice merges as CLEAN. A dead reviewer would merge an UNREVIEWED
//                     slice, leave `verdict: null`, and let its dependents build on it (they are
//                     not even `held`, because an empty capRemainder means "clean").
//   5. fix impl.    → `if (!fixed || fixed.failed)` — drains
//   6. re-review    → `if (!issue.review)` — drains, same reasoning as 4 (a null re-review would
//                     end the loop as though the fixes had come back clean)
//   7. merger       → `if (!merged || !Array.isArray(merged.mergedIssues))` — drains
//   8. bookkeeper   → `.then(r => { if (!r) throw … })` into its `.catch` — recorded in
//                     bookkeepingFailures (it is fire-and-forget, so it must never drain the run)
async function runIssue(issue) {
  issue.attempted = true;                  // → the report's `perIssue` / `unbuilt` split
  issue.lows      = [];                    // accumulated across every review of this issue
  try {
    // 0. SETUP — cut this issue's worktree + branch. THIS IS A SPAWN, and it has to be: a Workflow
    //    script cannot shell out, and both implementer.md and merger.md forbid creating a worktree
    //    — so if nobody spawns for it, the implementer is handed a path that does not exist and is
    //    forbidden to create it. Agents CAN shell out; hence a cheap setup agent, one mechanical
    //    git command, pinned like the bookkeeper.
    //    AT ADMISSION, not at launch: a dependent must branch from a base that ALREADY contains its
    //    merged blocker. Cutting every worktree up front would silently build B on a base lacking A.
    const setup = await agent(
      `Create this issue's isolated worktree and branch. Run EXACTLY this one command, nothing else:
       git -C ${baseRepo} worktree add ${worktreeOf(issue.n)} -b issue-${issue.n} ${baseBranch}
       Then report the ABSOLUTE worktree path and the branch you created. If the command fails
       (e.g. the branch or path already exists), report failed: true with the error — do NOT
       improvise a different path, branch or base.`,
      { model: "haiku", effort: "low", schema: SETUP_SCHEMA });
    if (!setup || setup.failed) { drain(`worktree setup failed on #${issue.n}`); return; }   // null = agent died
    // VERIFY, then use the value WE computed. verifyTree drains unless the agent echoed back exactly
    // `worktreeOf(n)` / `issue-<N>`, which is what makes the echo an improvisation detector — and
    // also what makes it information-free: past the check it can only BE the constant. So assign the
    // constant. Assigning the model's string instead would be identical on every path that survives
    // the check and strictly worse on the paths that do not (a trailing slash, a symlinked baseRepo,
    // an optional field simply omitted), and it is what left the docs claiming a model-supplied path
    // feeds the merger while the guard was quietly ensuring it never could.
    if (!verifyTree(issue, setup.worktree, setup.branch, "setup")) return;
    issue.worktree = worktreeOf(issue.n);
    issue.branch   = `issue-${issue.n}`;

    // 1. Plan — COMPLEX ONLY. No plan comment, no gate — autonomous.
    //    trivial AND standard: NO plan stage at all — issue.plan stays null and the implementer
    //    self-plans (it already plans TDD-first by its own contract, and it re-explores the repo
    //    regardless, so a planner spawn ahead of it was a SECOND full exploration billed to buy a
    //    document the implementer would have derived anyway — measured at 26% of a real run's
    //    agent-minutes). A complex issue keeps its planner: there, the cross-cutting design call is
    //    worth a dedicated pass BEFORE any code is written.
    //    No schema — the plan text IS the return value, and it is the work order.
    //    The planner gets the issue's COMMENTS as well as its body — a comment may hold the answer.
    issue.plan = issue.tier !== "complex" ? null : await agent(
      `mode=plan · issue #${issue.n} body + comments in → plan text out; see step 3.
       done-check: ${doneCheck}
       \n\n${issue.body}\n\n## Issue comments\n${issue.comments}`,
      { agentType: "workflow:planner",
        model:     ROSTER[issue.tier].planner.model,
        effort:    ROSTER[issue.tier].planner.effort });
    // GUARD 2. A dead planner returns null — and for a COMPLEX issue that null is INDISTINGUISHABLE
    // from the self-planning tiers' deliberate null. Unguarded, the build below would hand a COMPLEX
    // issue's implementer a prompt that reads "no planner ran: SELF-PLAN it", silently downgrading
    // the one tier whose whole point is that it gets a plan first. (Note this is a truthiness check
    // on the PLAN TEXT, not on a schema'd object: the planner returns bare text by design.)
    if (issue.tier === "complex" && !issue.plan) { drain(`planner failed on #${issue.n}`); return; }

    // 2. Build — one worktree, one implementer. Work order = the plan text when there is one; for a
    //    self-planning issue (issue.plan === null) the ISSUE BODY is the work order. The worktree is
    //    the one the setup agent just created, and its ABSOLUTE path + branch ride in the prompt.
    const built = await agent(
      `${issue.plan
          ? `Work order = the plan below — ordered steps + ## Acceptance criteria + the done-check.\n\n${issue.plan}`
          : `Work order = issue #${issue.n} below. No planner ran (${issue.tier} tier self-plans): SELF-PLAN it, then build it TDD-first.\n\n${issue.body}`}
       \n\n## Issue comments\n${issue.comments}
       \n\n## Where to work
       worktree: ${issue.worktree} · branch: ${issue.branch} · cut from ${baseBranch} in ${baseRepo}
       done-check: ${doneCheck}
       commit scope: match the repo's git log convention.`,
      { agentType: "workflow:implementer",
        model:     ROSTER[issue.tier].implementer.model,
        effort:    ROSTER[issue.tier].implementer.effort,
        // NO isolation opt: `isolation` yields a FRESH, UNNAMED worktree, so it cannot cut a branch
        // named issue-<N> from a chosen base — which is exactly what the merger needs. The setup
        // agent (step 0) owns creation; the implementer is forbidden to create one.
        schema:    BUILT_SCHEMA });
    if (!built || built.failed) { drain(`implementer failure on #${issue.n}`); return; }   // null = agent died
    // The build's own report of where it worked, run through the SAME improvisation detector (same
    // untrusted model output; the merger's `git -C` is downstream of it). No assignment: issue.worktree
    // is already the verified constant, and an implementer that omits the optional echo entirely has
    // improvised nothing — it is checked against that constant, not required to restate it. `head` is
    // optional in BUILT_SCHEMA too — a build that omits it degrades the re-review below, it does not drain.
    if (!verifyTree(issue, built.worktree || issue.worktree, built.branch || issue.branch, "build")) return;

    // 3. Initial review (FREE — does not count against maxCycles), then the PLANNER-FREE fix loop.
    //    my-review runs the central-mechanism / mock-drift audit and OWNS the mock-debt filing; it
    //    reports what it filed as mockDebtFiled, which unions into openMockDebt so the e2e-gate is
    //    held by debt THIS RUN created, not just debt that predated it.
    issue.review = await agent(
      `Review issue #${issue.n}'s branch diff ${baseBranch}..${issue.branch} in ${issue.worktree}.
       Conformance context (its plan — or, for a self-planning issue, its body):\n\n${issue.plan || issue.body}
       \n\nIssue #${issue.n}'s comments — ground truth for the review:\n${issue.comments}`,
      { agentType: "personal-tools:my-review",
        model:     ROSTER[issue.tier].reviewer.model,
        effort:    ROSTER[issue.tier].reviewer.effort,
        schema:    REVIEW_SCHEMA });
    // GUARD 4 — THE REVIEW GATE ITSELF. A dead reviewer returns null, and null does not crash
    // anything downstream: mediumOrWorse(null) is [], mediumOrWorseOpen is false, the fix loop is
    // SKIPPED, capRemainder is [] — so the slice merges as CLEAN, its dependents are not held, and
    // perIssue.verdict rides home as null. An unreviewed slice would merge and be built upon.
    // The review is a GATE: no review, no merge.
    if (!issue.review) { drain(`review failed on #${issue.n}`); return; }
    absorbReview(issue, issue.review);
    // The delta base for the re-review. A Workflow cannot shell out, so it cannot rev-parse — the
    // sha rides back on BUILT_SCHEMA.head instead. `head` is OPTIONAL there (a failed build has
    // none to give), so fall back to the base branch: a re-review of the whole branch is a superset
    // of the delta — safe — whereas `undefined` would render the literal range "undefined..HEAD".
    // But SAFE IS NOT SILENT. A SUCCESSFUL build always knows its head, so an omission here is the
    // schema's optionality being taken up on the one path where it should not be — and the whole
    // cost of it (every re-review of this issue widened from the delta to the entire branch: slower,
    // noisier, re-litigating code this run never touched) would otherwise land with no log line and
    // nothing in the report. Say it once, and let the report carry it.
    if (!built.head)
      log(`#${issue.n}: build reported no head — re-review widened to the full branch (${baseBranch}..HEAD)`);
    let preFix = built.head || baseBranch;
    let cycles = 0;
    while (mediumOrWorseOpen(issue.review) && cycles < maxCycles) {
      const fixOrder = orderFindings(issue.review);                 // plain code: critical → high →
                                                                    // medium, ascending path. NO
                                                                    // planner spawn.
      const fixed = await agent(
        `Work order = these review findings — fix each, TDD-first, then run the done-check.
         Do NOT re-plan the issue; fix exactly what is listed.
         worktree: ${issue.worktree} · branch: ${issue.branch} · done-check: ${doneCheck}
         \n\n${fixOrder}`,
        { agentType: "workflow:implementer",
          model:     ROSTER[issue.tier].implementer.model,
          effort:    ROSTER[issue.tier].implementer.effort,
          schema:    BUILT_SCHEMA });
      // MIRROR THE BUILD GUARD. Reading only `fixed?.head` treats a fix implementer that reports
      // failed: true (red done-check) as a NO-OP: the loop re-reviews, exhausts the cap, and the
      // slice MERGES ANYWAY with a cap-remainder. A clean merge is not done-check gated — the
      // merger gates its conflict RESOLUTIONS and runs one final check after the whole batch — so
      // the broken branch lands, the main thread CLOSES its issue, and the run drains on a red base.
      if (!fixed || fixed.failed) { drain(`fix implementer failure on #${issue.n}`); return; }
      issue.review = await agent(
        `Issue #${issue.n} in ${issue.worktree} (branch ${issue.branch}):
         (a) verify each prior finding below is addressed, (b) review ONLY the delta ${preFix}..HEAD.
         \n\n${fixOrder}`,
        { agentType: "personal-tools:my-review",
          model:     ROSTER[issue.tier].reviewer.model,
          effort:    ROSTER[issue.tier].reviewer.effort,
          schema:    REVIEW_SCHEMA });
      // GUARD 6 — same gate as guard 4, and the same silent degradation: a null re-review would
      // end the loop as though the fixes had come back CLEAN, and the known-defective slice would
      // merge with an empty capRemainder — so its dependents would not even be held.
      if (!issue.review) { drain(`re-review failed on #${issue.n}`); return; }
      absorbReview(issue, issue.review);
      preFix = fixed.head || preFix;                                // next cycle's delta base
      cycles++;
    }
    issue.capRemainder = mediumOrWorse(issue.review);   // ARRAY, open at the cap → filed in step 8, merges anyway

    // 4. Hand off to the SERIAL merge queue and wait until this issue actually LEAVES it: merging is
    //    the one stage that is never concurrent. Re-pump rather than awaiting once — mergeWorker is
    //    cleared in a `.finally()` microtask AFTER runMerges exits its `while (mergeQueue.length)`
    //    check, so a single `await pumpMerge()` landing in that window rides an already-settled
    //    promise, resolves instantly and frees the slot while this issue sits in the queue FOREVER:
    //    built, reviewed, never merged, never closed, never reported.
    mergeQueue.push(issue);
    do { await pumpMerge(); } while (mergeQueue.includes(issue));
  } catch (e) {
    // The contract is DRAIN-then-stop, NOT kill. Without this catch a dead agent rejects the chain
    // promise, Promise.race re-throws it, and the whole workflow dies — discarding the return, so
    // every issue that really did merge is never closed and the next run rebuilds it.
    drain(`chain failed on #${issue.n}: ${e?.message || e}`);
  } finally {
    inFlight.delete(issue.n);                                       // free the slot, whatever happened
  }
}

// ---- the merge worker: SERIAL, one merger spawn at a time ----
function pumpMerge() {
  // Start a worker only when no merge is running; otherwise ride the running one — it drains the
  // whole queue, including whatever was pushed after it started. The worker promise NEVER rejects:
  // a rejection here would propagate into every chain awaiting it, and into the main loop's
  // `await pumpMerge()`, throwing the run away along with its merged-issue list.
  if (!mergeWorker && mergeQueue.length)
    mergeWorker = runMerges()
      .catch(e => drain(`merge worker failed: ${e?.message || e}`))
      .finally(() => { mergeWorker = null; });
  return mergeWorker;
}

async function runMerges() {
  while (mergeQueue.length) {
    const batch = mergeQueue.splice(0).sort((a, b) => a.n - b.n);   // everything queued, ascending
    const merged = await agent(                  // no model/effort → the merger's frontmatter pins govern
      `Merge these branches serially, in ascending issue number, into the orchestration worktree's base
       branch; resolve conflicts under the done-check.\n\n${mergeManifest(batch)}`,
      { agentType: "workflow:merger", schema: MERGE_SCHEMA });
    // A DEAD merger returns null. Reading merged.mergedIssues would TypeError → the worker rejects →
    // every chain awaiting pumpMerge() rejects → the workflow throws. The BUILD path guards its agent
    // (`if (!built || built.failed)`); the MERGE path must too.
    if (!merged || !Array.isArray(merged.mergedIssues)) {
      drain(`merger returned nothing for ${batch.map(i => `#${i.n}`).join(", ")}`);
      return;                                                       // that batch stays unmerged; the run drains
    }
    for (const m of merged.mergedIssues) {
      // SCOPE GUARD. The merger's numbers are not trusted verbatim: Step 2 runs `gh issue close` on
      // every entry, so a hallucinated number is an IRREVERSIBLE close on an unrelated issue.
      const issue = byNumber(m?.n);
      if (!issue) { log(`dropping #${m?.n} — outside the run's allowlist`); continue; }
      // NO CLOSE HERE (#77 fix 1) — the workflow records what it merged and hands the list back; the
      // MAIN THREAD closes and verifies (Step 2).
      mergedThisRun.set(issue.n, m.mergeCommit);
      // A CAPPED merge (medium+ findings still open at maxCycles) landed a KNOWN-DEFECTIVE slice.
      // Its direct dependents would otherwise unblock in-memory and build straight on top of it —
      // so hold them for the rest of the run. (The old round loop re-read GitHub each round and got
      // this for free; an in-memory scheduler must do it explicitly.)
      // `.length`, NOT truthiness: capRemainder is an ARRAY, and `[]` is truthy — testing the array
      // itself would hold every CLEAN merge's dependents too, and the scope would never drain.
      if (issue.capRemainder?.length)
        for (const d of dependents(issue.n)) { held.add(d.n); log(`held #${d.n}: #${issue.n} merged capped`); }
      if (issue.lows?.length || issue.capRemainder?.length)         // nothing to file → don't spawn
        bookkeeping.push(fileFollowUps(issue));                     // fire-and-forget: never blocks the slot
    }
    // PUSH, never assign: a batch can stop on SEVERAL issues (the merger continues through the
    // batch), and a later batch's stop must not OVERWRITE an earlier one — that would leave
    // stopReason naming the first stop while the report named only the last. Each stop carries the
    // worktree it left intact, so the report can say where to look.
    let stopsAccepted = 0;
    for (const cs of merged.conflictStops || []) {
      // SCOPE GUARD — the SAME trust boundary as mergedIssues above, because this list also drives
      // an OUTWARD-FACING GitHub write: Step 2 posts a comment on every conflict-stop it is handed.
      // Same untrusted model output, same allowlist check; a hallucinated number would post that
      // comment on an unrelated issue.
      const issue = byNumber(cs?.n);
      if (!issue) { log(`dropping conflict-stop #${cs?.n} — outside the run's allowlist`); continue; }
      conflictStops.push(cs);
      stopsAccepted++;
      log(`conflict-stop on #${cs.n} (worktree ${cs.worktree}): ${cs.reason}`);
      drain(`conflict-stop on #${cs.n}: ${cs.reason}`);             // first stop wins the stopReason
    }
    // Keyed off the stops we ACCEPTED, not off the raw list: a batch whose every stop was dropped
    // as out-of-allowlist has drained nothing, so a red done-check must still drain the run.
    if (!stopsAccepted && merged.doneCheckRed) {
      drain("red done-check after merge");
    }
  }
}

// ---- per-issue bookkeeping: ONE cheap haiku call, fired as the issue clears ----
// Mechanical templating over text the run already produced, and ONLY ever additive (file / append) —
// never a close, never a delete — which is what makes it safe to hand a cheap subagent at all.
// Per issue, not batched at the end: a killed run keeps every filing made so far.
function fileFollowUps(issue) {
  return agent(
    `Bookkeeping for issue #${issue.n} via gh; see step 8. File its follow-ups, then re-block dependents.
     Do NOT close any issue — the main thread owns that.\n\n${ghWriteManifest(issue)}`,   // lows + capRemainder
    { model: "haiku", effort: "low", schema: FILED_SCHEMA })   // mechanical additive writes — never the session model
    // GUARD 8. A dead agent RETURNS NULL — it does not reject — so `r?.filed || []` would swallow
    // the likelier failure whole: followUps [], no bookkeepingFailures entry, and the exact
    // consequence the .catch below exists to surface (lows/cap-remainder never filed, dependents
    // never re-blocked, the next run building them on unpaid debt) left silent. THROW on a null so
    // the one honest error path below owns both failure modes.
    .then(r => {
      if (!r) throw new Error("bookkeeper returned nothing (agent died) — nothing was filed");
      issue.followUps = r.filed || [];                         // → the report names what was filed
    })
    // CATCH AT CREATION. Promise.allSettled at the end keeps a rejection from discarding the
    // return, but nothing reads the settled array — so a rejected bookkeeper would be INVISIBLE:
    // the cap-remainder never filed, the dependents never re-blocked, followUps reporting [], and
    // the NEXT run building those dependents on unpaid debt (the dangerous direction). Catching
    // here also closes the unhandled-rejection window between the failure and the end-of-run await.
    .catch(e => {
      const msg = `bookkeeping FAILED for #${issue.n} — its lows/cap-remainder were NOT filed and `
                + `its dependents were NOT re-blocked: ${e?.message || e}`;
      bookkeepingFailures.push({ n: issue.n, reason: `${e?.message || e}` });
      log(msg);                                                // → returned, and Step 2 must print it
    });
}
```

## The scheduler (inside the Workflow)
Everything in this section happens **inside the Workflow**. There is **no round barrier**: the
scheduler keeps up to **`--max N`** issues in flight and refills a slot the moment one clears.

1. **Readiness — plain script code, no agent.** An issue is **ready** iff it is **open**, not already
   merged this run (the **re-admit guard**), not **held**, not in flight, carries neither `hitl` nor
   `prd`, and **every** `#N` in its `## Blocked by` is **closed** — either closed at launch
   (`graph.blockerStates`) or merged by this run (`mergedThisRun`). This is a topological sweep over
   the launch-frozen graph, so it is computed in **plain JS with no model call**. (It was a `haiku`
   picker agent only because a Workflow can't run `gh` — a model doing DAG arithmetic could
   hallucinate a blocker closed, and the tier it guessed on the side was never persisted anyway.)
   **Mock-debt gate (C7):** an issue labeled `e2e-gate` is **not ready** while `openMockDebt` is
   non-empty — that set is seeded from `graph.mockDebtOpen` at launch and **unioned with every
   review's `mockDebtFiled`**, so debt the run *itself* creates holds the gate too. Report a held
   gate as `blocked — N mock-debt open`. The open `mock-debt` set **is** the ledger.
2. **Admission — the slot loop.** While the run is not draining and a slot is free, admit the
   **lowest-numbered** ready issue. Each slot runs one issue's whole chain (steps 3–7) and, when the
   chain clears, the next ready issue **takes the slot**. A merge unblocks that issue's dependents,
   which become ready on the next scan. The run ends when the scope drains — nothing in flight and
   nothing admissible.

   **Failure is drain-then-stop, not kill.** An **implementer failure**, a **conflict-stop** or a
   **red done-check** puts the run into **drain mode**: **admit nothing new**, let the in-flight
   chains **finish through merge**, then return with the stop reason. Killing the loop mid-chain
   would strand built, reviewed branches that had already earned their merge.
3. **Plan the complex issues → their work order (autonomous — no plan comment, no gate).**
   A **plan stage** runs **only for complex** issues: the **`workflow:planner`** subagent
   (`agentType: workflow:planner`, `mode: plan`, `model: ROSTER[issue.tier].planner.model`,
   `effort: ROSTER[issue.tier].planner.effort`) handed the issue body **and its comments** (the graph
   carried both — a comment may carry the settled answer), which returns the plan as its **final
   text** (ordered steps with file paths + `## Acceptance criteria` + the done-check + risks). Capture
   that plan text as the issue's **work order**.

   A **trivial or standard** issue gets **no plan stage at all** — `issue.plan` stays null, the
   **issue body is the work order**, and the **implementer self-plans** (planning TDD-first is already
   in the implementer's own contract). The planner was **a second full repo exploration in front of an
   implementer that explores anyway**, and it was **measured**: on a 56-agent run it burned 83 of 317
   agent-minutes — **26% of all work** — to hand over a document the implementer would have derived
   itself, with plans routinely costing as much as the build they preceded. Only **complex** keeps it,
   where a cross-cutting design call is worth settling before any code is written.

   This is where orchestrate **diverges from `/pipeline`**, which still authors a plan for every tier:
   pipeline runs ONE task and the plan is a human-legible artifact of that run, while inside a
   Workflow every plan is a whole extra agent on the critical path of a slot that could be building.

   The run stays autonomous: **no plan comment is posted to the issue** and
   **no plan-approval gate fires** (the Workflow launch gate was the only stop).
4. **Set up the worktree, then build (C4).**

   **The worktree is cut by a `setup agent` — nobody else can.** The scheduler **cannot create it
   itself**: a Workflow script cannot shell out. Nor may the implementer or the merger — both are
   explicitly forbidden to run `git worktree add`, and that prohibition **stays**. **Agents can shell
   out; Workflow scripts cannot** — so the owner is a **setup agent**: one `agent()` spawn pinned
   `{ model: "haiku", effort: "low" }` (the same cheap class as the bookkeeper — one mechanical git
   command), whose entire job is

   ```
   git -C <baseRepo> worktree add <baseRepo>/.worktrees/issue-<N> -b issue-<N> <baseBranch>
   ```

   and which returns the **absolute worktree path and the branch** (`SETUP_SCHEMA`). It is spawned
   **at admission, as the first stage of the issue's chain — not at launch**: a dependent must branch
   from a base that **already contains its merged blocker**, so cutting every worktree up front would
   silently build B on a base lacking A. Its failure **drains the run**, exactly like a failed build.

   It is **not** `isolation:` on the implementer spawn: that opt yields a **fresh, unnamed** worktree,
   so it cannot cut a branch named `issue-<N>` from a chosen base — which is precisely what the
   merger needs.

   **The echo is an improvisation detector, not a source of truth.** The path and branch the setup
   agent reports are **model-supplied**, and they would become the `git -C <path>` of three later
   agents — including the **merger**, which writes the base branch (the worktree-guard hook is a
   `PreToolUse` matcher on `Edit|Write|NotebookEdit` **only**, so it does not fence an agent's
   `Bash`). We asked for **one exact path and one exact branch**, so the scheduler **verifies** what
   came back — `<baseRepo>/.worktrees/issue-<N>` and `issue-<N>` — and **drains** the chain on any
   other value, for the setup agent's report and for the implementer's echo of it alike. That check
   is what catches an agent that improvised its own path; it is also what makes the echoed value
   **information-free**, since past the check it can only *be* the constant. So what actually feeds
   the implementer, the review, the fix loop and the merge manifest is the path the **scheduler
   computed** — `worktreeOf(N)` — and the echo's only job is to fail the run when an agent went
   somewhere else. Accepting an unchecked branch name back from a model would give up exactly what
   rejecting `isolation:` bought.

   **Then build.** Spawn one **`workflow:implementer`** handed its **work order** — the **plan text**
   from step 3 (ordered steps + `## Acceptance criteria` + done-check) — plus the issue's
   **comments**, the **absolute** worktree path and the branch (the verified `worktreeOf(N)` /
   `issue-<N>`), and a **commit-scope hint** (the issue's `<scope>`). The plan
   **replaces the implementer's self-plan** for these issues (it builds against the work order, not a
   plan of its own). It runs on the model its tier routed (`ROSTER[issue.tier].implementer`).
   Chains run **concurrently with no cross-issue barrier** — issue A is in its fix loop while issue B
   is still building.
5. **Review the built slice — initial review (free).** **As soon as an issue's build finishes** (no
   waiting on sibling builds), spawn **`personal-tools:my-review`** (`model:
   ROSTER[issue.tier].reviewer.model`, `effort: ROSTER[issue.tier].reviewer.effort`) on that issue's
   **branch diff** — the commit range `<base>..issue-<N>` — with the issue's **plan** (captured in
   step 3; **null for a trivial or standard issue**, which had no plan stage — then the **issue body**
   is the conformance context), the issue's **comments** (they are the ground truth the review checks the
   slice against — a **comment-blind** loop rediscovers a settled question and guesses at it), plus
   the **issue number** so the audit can read its `## Central mechanism` line. my-review returns a
   verdict plus a machine-readable `findings` block, and runs the **central-mechanism / mock-drift
   audit**: declared central mock → confirm; **undeclared** central mock → **auto-convert** — both
   file a `mock-debt` follow-up. **my-review OWNS the mock-debt filing** — the workflow
   **does not re-file mock-debt** (step 8) — and it **reports the numbers it filed** as
   `mockDebtFiled`, which the scheduler unions into `openMockDebt` (step 1's gate). This **initial
   review is free** — it does not count against `--max-cycles`.

   **The review is a gate: no review, no merge.** A dead reviewer returns **null**, and null is not
   an error downstream — it is an *empty findings list*. Unguarded, it would skip the fix loop, empty
   the cap-remainder, merge the slice as **clean**, leave its dependents **unheld** and report a
   `null` verdict: an **unreviewed slice merged and built upon**. So a null review (initial **or**
   re-review) **drains the run**, exactly like a failed build.
6. **Planner-free fix loop (capped by `--max-cycles`, autonomous).** Parse the slice's `findings`
   block and act on it — re-implementing and re-reviewing **for real** until the slice is
   **clean-or-capped**, **before it merges**. `--max-cycles K` (**default 2**, matching `/pipeline`)
   **counts re-reviews**: the step-5 review is free, and each re-review decrements the budget. The
   **reviewer model is held constant** across every re-review (`ROSTER[issue.tier].reviewer`, fixed
   for the run).

   **No planner runs in the fix loop.** A review finding already names the path, the defect, and the
   fix — re-planning it spawns an agent whose whole job is to restate the reviewer in other words.
   So the **findings block itself is the fix work order**, assembled in plain script code, no agent:

   | severity | route |
   |---|---|
   | **low** | filed as a follow-up (step 8), **never fixed in-run** |
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
   past the launch gate; no interactive extra-cycle grant fires). A slice reaching **all-lows (or a
   clean review) passes the branch**. When the **cap is exhausted with medium-or-worse findings still
   open**, those become the **cap-remainder**: they are filed as follow-ups (step 8) and the branch
   **merges anyway**.
7. **Merge — the serial merge queue.** **After the fix loop** clears or caps a slice, its branch joins
   the **merge queue**. Merging is **serial**: whenever the queue is non-empty and **no merge is
   running**, spawn **ONE `workflow:merger`** (no `model`/`effort` — its frontmatter opus pins govern)
   and hand it **everything queued, in ascending issue number**, the **absolute
   orchestration-worktree** path as this run's base repo (a linked worktree → the guard allows the
   merger's writes) and its base branch, each issue's branch `issue-<N>` and **absolute worktree
   path**, and the project's **done-check command**. **Within a batch**, ascending issue number is the
   **deterministic** merge order; batches themselves follow **completion order** — an issue merges in
   the first batch that is running when it joins the queue. Blockers were already closed, but
   file-level overlap can still collide — **conflicts are expected and the merger resolves them under
   the done-check**. Act on its result:
   - issues it merged green → recorded into **`mergedThisRun`** (issue number → merge commit) and
     **returned to the main thread**, which closes them in Step 2. **The workflow never closes an
     issue.** The close is an **irreversible outward-facing** GitHub write, and inside a low-context
     subagent it reads as an unexplained destructive act against a pre-existing issue — on the run
     behind #77 a safety classifier killed exactly this call, correctly, and the resulting undrained
     ready set rebuilt the same issues at full cost (1.84M tokens). Because they stay open in the
     frozen graph, `mergedThisRun` is what drains the run: a merged issue is **never re-admitted**
     (step 1's guard), so convergence never depends on a GitHub write succeeding;
   - **a slice that merged CAPPED holds its dependents.** If the merged issue had a **cap-remainder**
     (medium-or-worse findings still open at `--max-cycles`), it landed a **known-defective** slice —
     so every direct dependent still in scope is added to **`held`** and
     stays held **for the rest of the run**, logged in the report.
     Otherwise it would unblock in-memory and build straight on top
     of a slice the reviewer just condemned;
   - a **conflict-stop** (unresolvable conflict or a **red done-check** after resolution) → **drain
     mode** (step 2): leave that issue's worktree intact, admit nothing new, let the in-flight chains
     finish, and **carry the stop home**. The merger returns **`conflictStops: [{ n, reason,
     worktree }]`** — a **list**, because it merges on through the batch, so **one batch can stop on
     several issues**, and each stop names the **worktree it left intact** so the report can say where
     to look. The workflow **pushes** each onto its own `conflictStops` and never **assigns** (a later
     batch's stop overwriting an earlier one would leave `stopReason` naming one issue while the
     report named another), and returns them all. **Never keep an unverified resolution** — that
     discipline lives in the merger. (A drain still **returns** whatever `mergedThisRun` holds — those
     issues really did merge and must still be closed.)

     **Who writes the stop onto the issue.** Enumerate *every* actor, not a convenient subset: the
     **Workflow** cannot run `gh` at all; the **merger** is forbidden to comment; the **bookkeeper**
     only ever *files*; and **the main thread **can** — it already runs `gh issue close --comment`
     there (Step 2). So the comment is **not** ownerless, which is what an earlier version of this
     document concluded — by silently omitting the fourth actor. **The main thread owns it:** on
     return it comments each `conflictStops` entry onto its issue (Step 2). (Reasoning over an
     incomplete set of actors until an action looks impossible is exactly how this document once left
     the per-issue worktree with **no creator at all** — see step 4.)
8. **Per-issue bookkeeping — ONE cheap haiku call, fire-and-forget.** As each issue clears its merge,
   a **single `agent()` call pinned to `haiku` at `low` effort** files that issue's follow-ups and
   re-blocks its dependents. It is **fire-and-forget**: the slot does not wait on it, and it runs
   **per issue rather than batched at the end**, so a run that is killed keeps every filing it already
   made. Every such promise is collected and awaited **before the workflow returns**, so nothing is
   lost to an early exit either. It **only ever adds** — files an issue, appends to a body — and
   **never closes and never deletes**; that is precisely what makes it safe to hand a cheap,
   low-context subagent, and it is why the **closes moved out** to the main thread (step 7). Ensure
   the labels exist (`gh label create review-fix 2>/dev/null || true`, same for `ready-for-agent`).
   Two kinds of filing, routed differently:

   | what | label(s) | why |
   |---|---|---|
   | **lows** — **one grouped** follow-up per slice, collecting that slice's low findings | `review-fix` **only** | **Parked.** A low is by definition not worth an agent, so it must not be *auto-buildable*: `ready-for-agent` would make a future run spend a full plan→build→review on a nit. A human promotes it when they judge it worth doing. |
   | **cap-remainder** — medium-or-worse left open when `--max-cycles` exhausted | `review-fix` + `ready-for-agent` | Real work, genuinely ready for a future run. |

   File each with `gh issue create --title '<one-line fix>' --label review-fix --body-file <tmp>`
   (adding `--label ready-for-agent` for the cap-remainder only; single-quote the title — it embeds
   review-derived text that may carry shell metacharacters) with the template `## What to build` (the
   fix) / `## Acceptance criteria` / `## Blocked by` (`None - can start immediately` unless the fix
   depends on this branch landing — then name it). Issues filed mid-run get **no `tier:*` label** —
   they are outside the launch freeze, and a future run backfills the tier when it scopes them.

   Note the labels are only the *second* line of defence. The first is Step 0a's frozen allowlist:
   **nothing the run files can be built by the run**, because the scope is fixed at launch and a
   newly-filed issue is not in it. That freeze is what stops a **cap-remainder** — which *is*
   `ready-for-agent` — from being rebuilt by the same run and silently bypassing the very cap that
   parked it.

   **Mock-debt stays my-review's job:** the central-mechanism audit already filed the declared /
   auto-converted `mock-debt` follow-ups in step 5, so the workflow **does not re-file mock-debt** —
   it only files lows + cap-remainder as `review-fix`. **Re-block dependents:** when a filed
   `review-fix` / cap-remainder issue is one a still-open **dependent** must not build on, append its
   `#N` into that dependent's existing `## Blocked by` section — read the dependent's body, add the
   ref to the `## Blocked by` block only, and write it back with
   `gh issue edit <dependent> --body-file <patched>`. Touch **no other part** of the dependent's body.
   (my-review explicitly disclaims this dependent re-wiring — the workflow owns it.)

   **The ref's format is load-bearing — state it in the prompt.** `scope-graph.sh` reads a blocker
   only when it is a **bare `#N` on its own line** inside the section (`#99`, or a list item `- #99`)
   — **one ref per line, no trailing prose**. A reasonable-looking `- #99 — fix the parser nit` is
   **prose**, so the next run's scheduler cannot see it and **builds the dependent on unpaid debt** —
   the dangerous direction of the parse. If the section holds `None - can start immediately`, replace
   that line with the ref rather than appending under it.

The run ends when the **scope drains** (nothing in flight, nothing admissible) or a **drain-then-stop**
condition — an **implementer failure**, a **conflict-stop**, or a **red done-check** — empties the
in-flight set. Either way the result is **left on the orchestration branch** for you to merge into
`dev`/`main` yourself — the run never merges back to the launch branch and never removes the
orchestration worktree.

## Step 2 — on return: close the merged issues, exit the worktree, report
When the Workflow returns, back on the main thread. **Close first** — before the worktree exit and
before the report — so a failed close is loud and stops the run rather than being buried under a
success table:

**What the workflow returns.** The report below is the user-facing contract, so the return value
**serves it** — every column comes from one of these fields, or from the main thread's own Step-0a
record. Nothing the report needs is allowed to die inside the Workflow:

```
{ mergedIssues: [{ n, mergeCommit }],          // → close these (below), print the sha
  stopReason,                                  // null = the scope drained cleanly
  conflictStops: [{ n, reason, worktree }],    // EVERY merge that stopped — a batch can stop on several
  held: [n, …],                                // dependents held by a capped merge
  bookkeepingFailures: [{ n, reason }],        // a filing that REJECTED — its follow-ups were never
                                               // filed and its dependents were never re-blocked
  perIssue: [{ n, tier, verdict,               // my-review's final verdict — ATTEMPTED issues only
               lowsFiled, capRemainder,        // counts filed as review-fix follow-ups
               followUps: [n, …] }],           // the issue numbers bookkeeping actually filed
  unbuilt: [n, …],                             // scoped, admissible, but never admitted (blocked / held /
                                               // drained past) — closed and hitl/prd issues are NOT listed
  log: [line, …] }                             // the scheduler's own log (holds, drops, unknown blockers)
```

- **Close from the main thread (#77 fix 1).** The workflow **returns the merged-issue list**
  (`mergedIssues`) instead of closing anything itself. Close
  each one here: `gh issue close <N> --comment "Merged in <mergeCommit> by /orchestrate."` This is the
  **only** place the run closes an issue. An **irreversible outward-facing** write belongs on the main
  thread, where the conversational context can account for it: the same call, made from inside a
  low-context subagent, was killed by a safety classifier on the run behind #77 — and it *should* have
  been, because that subagent had been handed an issue it could not explain.
- **Verify every close (#77 fix 2).** A close that silently fails must not pass as success. After
  closing, re-read each issue's state — `gh issue view <N> --json state` — and if any issue is
  **still open after its close**, **stop and report it loudly**, naming the issue and the merge commit
  it was merged in. Do **not** run the PRD reap on an unverified close: the reap would read a
  still-open child and draw the wrong conclusion. (The run itself stays convergent regardless — the
  workflow's `mergedThisRun` re-admit guard never re-admits a merged issue, close or no close — so
  this check is about *reporting the truth*, not about rescuing the loop.)
- **Comment each conflict-stop onto its issue.** For every `conflictStops` entry, post
  `gh issue comment <N> --body "/orchestrate could not merge this: <reason>. The branch and its
  worktree are left intact at <worktree> — resolve and re-run."` The **main thread** owns this write
  for the same reason it owns the close: it is outward-facing, and the conversational context can
  account for it. (It is *additive* — never a close, never an edit of the issue's body.) This is the
  fourth actor step 7 enumerates; the Workflow, the merger and the bookkeeper genuinely cannot do it.
- **`ExitWorktree(keep)`** — return to the original directory with the **orchestration branch** and
  worktree intact (or the session-exit prompt offers keep/remove). Everything the run merged lands on
  the orchestration branch inside the orchestration worktree — never on the launch branch and never in
  the primary checkout.
- Print a **status table**, one row per scoped issue, each cell sourced from the return or from your
  own Step-0a record — nothing invented. Note the provenance split: `perIssue[]` holds **only the
  attempted** issues, so a blocked, held or never-admitted issue has **no `perIssue` row** — its tier
  still comes from your **Step-0a scope record** (`[{ n, tier }]`, which covers *every* scoped issue),
  and its verdict cell is simply **empty**. A table that sourced tier from `perIssue[]` would be
  unimplementable for exactly the rows it most needs to explain:

  | column | where it comes from |
  |---|---|
  | issue `#` → title | the Step-0a `graph` |
  | tier (and whether it was **backfilled**) | your **Step-0a scope record** — it covers every scoped issue, attempted or not; **backfilled?** likewise (the workflow never saw the backfill). `perIssue[].tier` merely echoes it for the attempted ones |
  | merged? / closed? | `mergedIssues` (+ the close verification above) |
  | merge commit | `mergedIssues[].mergeCommit` |
  | review verdict | `perIssue[].verdict` — **empty** for an issue with no `perIssue` row (never attempted) |
  | notes | `perIssue[].lowsFiled` / `.capRemainder` / `.followUps`, plus `held`, `unbuilt`, `conflictStops`, `bookkeepingFailures` and `stopReason` |

  Then, below the table: the `stopReason` if the run drained (naming every `conflictStops` issue,
  reason and worktree when that is what stopped it), the **`held`** dependents and why (each was a
  dependent of a slice that merged **capped**), the **`unbuilt`** issues (scoped and admissible but
  never admitted), and any line the scheduler wrote to `log` (holds, out-of-allowlist merge results it
  dropped, blockers whose state it could not read, issues skipped by `--skip-unknown`, and any build
  that **reported no head** — its re-reviews were widened from the delta to the whole branch). If any
  `mock-debt` is open, add a one-line **ledger summary** (`mock-debt: N open — #A, #B …`) and note any
  `e2e-gate` held by it.
- **Say what the run changed outside the worktrees.** Step 0b appended `.worktrees/` to the repo's
  **`.git/info/exclude`** — a persistent, untracked mutation of the user's real repo that outlives
  the run (it is idempotent, and it is what keeps the per-issue worktrees out of `git status` while
  the merger works). It is small, but it is theirs: name it in one line rather than leaving them to
  find it.
- **Surface `bookkeepingFailures` loudly.** Each entry means that issue's **lows / cap-remainder were
  never filed** and its **dependents were never re-blocked** — so a future run would build those
  dependents on **unpaid debt**. Name the issue and the reason, and say plainly that the follow-ups
  must be filed by hand (or the run re-driven) before the dependents are built.
- **Report the review + fix-loop outcome (steps 5–8).** For each built slice, print `perIssue[].verdict`
  — `my-review`'s final verdict — and how the **planner-free fix loop** resolved its findings: the
  **lows** and **cap-remainder** it filed as `review-fix` follow-ups (`lowsFiled` / `capRemainder`
  counts, `followUps` for the issue numbers actually created, with the dependents re-blocked onto
  them). Name any `mock-debt` follow-up the audit filed (it feeds the ledger summary above).
- **Mirror the ledger (C7).** If this was a PRD run (slices carry `Part of #<prd>`), reflect the
  open `mock-debt` set into the PRD body for human visibility: rewrite **only** a delimited
  `## Mock-debt ledger` section (a checklist — `- [ ] #N — <what>` for open, `- [x]` for closed)
  from `gh issue list --label mock-debt --json number,title,state`. Touch **no other part** of the
  PRD body. The label query — not this mirror — is **authoritative** for the gate, so a stale mirror
  never breaks enforcement.
- End the final report by naming that branch + worktree path and telling me to merge it into
  `dev`/`main` when I'm satisfied.

## End-of-run: PRD reap

After the run drains (or a stop drains it), collect every issue number closed during this
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

These PRD offers and notes appear only in the **final report** (Step 2), after the run drains. They
**never interrupt the scheduler**.
