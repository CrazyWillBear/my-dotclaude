---
name: pipeline
description: Run one task through the plan→build→review pipeline — a Step-0 classify-task call routes the planner/implementer/reviewer models to the task's complexity tier, then the planner writes a plan, the implementer builds it in an isolated worktree, the my-review agent reviews the diff, and findings route by severity (low→issues, medium→triaged fix-list, high→collective replan, critical→own cycle). For single tasks not worth slicing into an issue graph. Use for "/pipeline <issue#|task>", "pipeline this".
argument-hint: "[issue# | task text] [--max-cycles K=2] [--complexity trivial|standard|complex]"
effort: high
allowed-tools: Read, Grep, Glob, Bash, Write, Agent, Skill, AskUserQuestion
---

Run one task through the standardized pipeline with **models routed by complexity tier**
(classified in Step 0), and a severity-routed fix loop.
`$ARGUMENTS` = `[issue# | task text] [--max-cycles K] [--complexity trivial|standard|complex]` —
**K** = max review cycles (default **2**). You run on the **main thread** because only the main
thread can spawn subagents.

This is the single-task sibling of `/orchestrate` — for work not worth slicing into an issue
graph. The result is a **branch left for the user**: **never push**, never merge, never close
the issue.

**Resume:** if the session's resume order points at a `*-pipeline.md` state doc, this is a
resumed run — re-enter the recorded worktree (`EnterWorktree(path: …)`), read the state doc in
full, and continue from the recorded phase with the recorded cycle count and open findings.
Do not redo completed phases. The state doc records the **confirmed roster** (tier + the three
models) — reuse it; **never re-classify on resume**.

## Step 0 — preflight

1. **Parse `$ARGUMENTS`.** A leading integer (`12`, `#12`) → **issue mode**. Otherwise the text
   is the task: **grill mode** if a `/grill-me` alignment exists in this session, else
   **bare mode**. Extract `--max-cycles K` (default 2) and `--complexity <tier>` (optional —
   consumed in Step 0.5).
2. **Hard-dep check.** The chain needs the `personal-tools` plugin: the `my-review` agent and
   the `verify-plan` skill. If either is missing (not in your available agents/skills), **fail
   loud naming the missing piece** — e.g. "personal-tools plugin not installed: my-review agent
   unavailable" — and stop. Do not substitute another reviewer.
3. **Issue mode only:** `gh issue view <N> --json title,body,labels,state`. **Refuse** (report
   and stop, mirroring orchestrate's ready rule) if:
   - the issue is closed, or labeled `prd` (a PRD tracking doc — slice it with `/to-issues`
     first) or `hitl` (needs a human);
   - any `## Blocked by` ref (bare `#N` lines; `None - can start immediately` passes) is still
     **open** (`gh issue view <ref> --json state`). An issue is ready iff **every** blocker is
     closed.
   Issue mode is **autonomous** — scope was pre-approved when the issue was filed — with
   **one interactive stop**: the Step-0.5 tier confirm, before any subagent spawns (skipped when
   `--complexity` is passed). Exactly two writes go **to the target issue**: the plan comment
   (step 2) and the result comment (step 8). (Step 7's label creates and follow-up issues —
   lows and declared mock-debt — happen in either mode and are the only other outward writes.)
4. **Grill/bare mode:** distill the brief **yourself on the main thread** — the task text plus
   (grill mode) the constraints, edge cases, and acceptance criteria surfaced by the grill.
   The planner gets the distilled brief, not the raw conversation.

## Step 0.5 — classify (pick the roster)

The models below are **tier-routed**, not fixed. This tier table is the source of truth
(byte-identical to `classify-task`'s):

| tier | planner | implementer | reviewer |
|---|---|---|---|
| trivial | sonnet | sonnet | opus |
| standard | opus | sonnet | opus |
| complex | fable | opus | fable |

- **`--complexity <tier>` given** → skip classification; take that tier's row from the table as
  the **confirmed roster** (no rationale — record `rationale=(--complexity <tier>)`).
- **Otherwise** → invoke the **`classify-task` skill** (Skill tool) with the issue body (issue
  mode) or the distilled brief (grill/bare). It explores the touched code, classifies, and runs
  **its own** confirm/override `AskUserQuestion` — the single interactive stop, in **both** modes,
  before any subagent spawns. Parse its output contract (`tier=` / `planner=` / `implementer=` /
  `reviewer=` / `rationale=`) into the **confirmed roster** that drives every spawn below. Keep
  the `rationale` for Step 2 surfacing.

The confirmed roster is fixed for the whole run — the **reviewer model is held constant across
every re-review**. Substitute it into the `model:` placeholders (`<planner>`, `<implementer>`,
`<reviewer>`) in Steps 2–5.

## Step 1 — enter the worktree

Orchestrate's step-0 pattern verbatim. Decide by where you are now — canonicalize both with
`realpath` first, since git may print a relative `.git`:
- **In the primary checkout** (`git rev-parse --git-dir` and `--git-common-dir` resolve to the
  **same** path) → call **`EnterWorktree(name: "issue-<N>")`** (issue mode) or
  **`EnterWorktree(name: "pipeline-<slug>")`** (grill/bare; `<slug>` = short kebab slug of the
  task). This creates the worktree off the current `HEAD` (`worktree.baseRef=head`) and
  switches the session into it.
- **Already in a linked worktree** (the two **differ**) → **skip**; this worktree is already
  isolated.

Record `baseline=$(git rev-parse HEAD)` — the review diffs against it. Everything below runs
from the worktree. At the very end, **`ExitWorktree(keep)`** — the branch and worktree stay for
the user.

## Step 2 — plan

Spawn **`workflow:planner`** (one `Agent` call, `subagent_type: workflow:planner`,
`model: "<planner>"`) with **mode=plan** and the issue body (issue mode) or distilled brief
(grill/bare). The planner returns the plan as text; **you write it** to a scratchpad file
(`<scratchpad>/pipeline-plan.md`).

Then, by mode:
- **Grill mode:** invoke the **`verify-plan` skill** (Skill tool) to drift-check the plan
  against this session's decisions. If it reports mismatches, fix the plan (edit the file
  yourself for wording; respawn the planner only if the drift is structural). If verify-plan
  errors because its session stash is missing, **relay its remedy verbatim** and stop — don't
  reimplement the check.
- **Grill + bare modes — plan gate:** show the plan to the user — alongside the **tier and its
  rationale** from Step 0.5 — and iterate: **you** (the main agent) revise the plan file per
  their feedback — no planner round-trip — until they approve. Do not proceed unapproved.
- **Issue mode — no gate:** post the plan as an issue comment
  (`gh issue comment <N> --body-file <plan>`), prefixing the **tier and rationale** (this is the
  first outward write), then proceed.

## Step 3 — implement

Spawn **`workflow:implementer`** on the confirmed roster's implementer (one `Agent` call,
`subagent_type: workflow:implementer`, `model: "<implementer>"`) handing it a **work order**: the full
plan text (steps + `## Acceptance criteria`), the **absolute worktree path**, the **branch**,
and a commit-scope hint from the repo log. It builds TDD-first, runs the project's done-check,
and commits.

If it reports **failure or blocked** (red done-check, ambiguous plan, unmet blocker): **stop
and report honestly** — what it tried, what failed, where the branch is. Don't spawn a fixer
blind.

## Step 4 — review

Spawn **`personal-tools:my-review`** (one `Agent` call, `model: "<reviewer>"`) on the branch
diff — the commit range `<baseline>..HEAD` — with the plan file path in the prompt for
conformance context. It returns
a verdict plus findings ending in a machine-readable ```findings block:

```
severity=critical|high|medium|low path=<path>:<line> replan=yes|no summary=<one line>
```

## Step 5 — route findings

Parse the ```findings block (empty block → clean; skip to step 7). Route by severity:

| severity | route |
|---|---|
| **low** | file as GitHub issues (step 7) — both modes; never fixed in this run |
| **medium** | spawn the planner in **mode=triage** (cheap call, mediums only) → ONE ordered fix-list; any `replan=yes` medium or `needs-real-plan` flag escalates that item into the high route |
| **high** | ONE **collective replan** covering **all high findings together** (planner mode=replan, mediums appended) — one coherent revision, not per-finding patches |
| **critical** | **each critical finding gets its own full plan→implement→review cycle** (planner mode=replan scoped to that finding alone, then steps 3–4 again) |

**When one review returns both criticals and highs:** run the per-critical cycles **first**
(ascending by path, so the order is deterministic), then the ONE collective high replan —
mediums append to the collective replan only. At each scoped re-review, drop any finding a
prior cycle already resolved.

Fix rounds go to a **fresh implementer spawn** (`model: "<implementer>"`), work order = the
fix-list or revised plan. Then a **scoped re-review**: spawn `personal-tools:my-review`
(`model: "<reviewer>"` — **held constant** across every re-review in the run) again asking it
to (a) verify each prior finding is addressed and (b) review **only the fix delta**
(`<pre-fix HEAD>..HEAD`) — not the whole branch again.

**Cycle budget:** `--max-cycles` (default 2) counts **re-reviews** — the initial review is
free; each re-review decrements the budget.

## Step 6 — cap hit

If the budget is exhausted and **medium-or-worse findings remain open**, **pause and ask**
(AskUserQuestion): **continue** (grant +1 cycle) / **stop and report** (branch stays as-is,
open findings listed) / **user takes over** (report state, exit cleanly). Never loop past the
cap silently. On **stop** or **take over**, report the open findings, then delete the step-9
resume state (the `.pending.json` pointer and the `-pipeline.md` state doc) — a run the user
ended must not resurrect at the next session start. Only **continue** keeps the state.

## Step 7 — file the lows + declared mock-debt

For each **low** finding, file a follow-up issue (both modes). Ensure the labels exist
(`gh label create review-fix 2>/dev/null || true`, same for `ready-for-agent`), then
`gh issue create --title '<one-line fix>' --label ready-for-agent --label review-fix
--body-file <tmp>` using the reviewer's verbatim template (single-quote the title — it embeds
review-derived text, which may carry shell metacharacters echoed from repo content): `## What to build` (the fix),
`## Acceptance criteria`, `## Blocked by` (`None - can start immediately` unless the fix
depends on this branch landing — then name the issue/branch).

Also file any **`## Mock-debt` the implementer declared** — there is no orchestrate reviewer
on this path, so the pipeline files it or nobody does. Ensure the label
(`gh label create mock-debt --description "central mechanism mocked; wire it real" 2>/dev/null || true`),
then file with reviewer.md's mock-debt template: `## What to build` (wire real `<X>`, removing
the mock), `## Central mechanism` (the now-real interface), `## Acceptance criteria` (the
central mechanism runs real and the test exercises it), `## Blocked by` (from the declaration,
or `None - can start immediately`).

## Step 8 — finish

Final report: plan summary, commits on the branch (`git log <baseline>..HEAD --oneline`),
review verdict + cycles used, issues filed, anything unresolved. Name the **branch + worktree
path** and tell the user the merge is theirs — **never push**, never merge, never close the
issue. Issue mode: post the result as an issue comment (`gh issue comment <N>`) — the second
and last outward write.

Then delete the resume state (step 9's pointer + state doc) and `ExitWorktree(keep)`.

## Step 9 — resume state (write at every phase boundary)

So `/clear` + `go` continues the run, persist state at each phase boundary — **planned /
gated / built / cycle-N**:

1. **Key the handoff dir** exactly as `save-handoff.sh` does (a drift test enforces this —
   don't diverge): `common_dir="$(git rev-parse --git-common-dir)"`, canonicalize
   `common_dir="$(cd "$common_dir" && pwd -P)"`, then
   `repo_key="$(printf %s "$common_dir" | sha1sum | cut -c1-16)"` and
   `dir=~/.claude/handoffs/$repo_key` (`mkdir -p "$dir"`).
2. **Write the state doc** `$dir/<branch-slug>-pipeline.md` (every `/` in the branch → `-`):
   mode, target (issue# or brief), branch, worktree path, current phase, cycles used, the
   **confirmed roster** (tier + the three models — so a resume never re-classifies), **the
   full current plan text embedded** (the scratchpad may not survive a clear), and open
   findings. Overwrite on each boundary.
3. **Write the resume pointer** `$dir/.pending.json` with the **Write tool**, exactly the
   workflow schema (`resume.sh` consumes it and re-injects the resume order, including
   re-entering the worktree):
   ```json
   {
     "handoff_path": "<absolute path to the -pipeline.md state doc>",
     "branch": "<branch>",
     "git_toplevel": "<git rev-parse --show-toplevel>",
     "git_common_dir": "<canonical common_dir>",
     "baseline_head": "<the step-1 baseline commit>",
     "session_id": null,
     "context_tokens": null,
     "ts": <date +%s>
   }
   ```
4. **On clean finish** (step 8): delete both — `rm -f "$dir/.pending.json"
   "$dir/<branch-slug>-pipeline.md"`. A finished run must not resurrect.
