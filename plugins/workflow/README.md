# workflow

Three features in one plugin, versioned here with the rest of my setup:

1. **`/orchestrate`** — an autonomous dev loop that solves GitHub issues in parallel
   isolated worktrees, merges the finished branches in dependency order, then reviews each
   built slice with `my-review` — surfacing findings in the round report and filing
   `mock-debt` follow-ups from its central-mechanism audit.
2. **`/pipeline`** — a single-task plan→build→review chain whose planner, implementer, and
   reviewer models are **routed to the task's complexity tier** (a Step-0.5 `classify-task`
   call), which then builds it in an isolated worktree, reviews the diff with the `my-review`
   agent, and routes findings by severity through a capped fix loop.
3. **A context watchdog** — hooks that drive deliberate, *early* `/clear` and `/handoff`
   as the window fills, instead of waiting for Claude Code's near-the-limit auto-compact.

```
plugins/workflow/
├── .claude-plugin/plugin.json        # manifest
├── skills/
│   ├── orchestrate/SKILL.md          # /orchestrate — the parallel issue-solving loop
│   ├── pipeline/SKILL.md             # /pipeline — plan→build→review one task
│   └── classify-task/SKILL.md        # /classify-task — tier a task, return the model roster
├── agents/
│   ├── implementer.md                # inherits model, xhigh effort — builds one issue/work order in one worktree
│   ├── merger.md                     # inherits model, xhigh effort — merges branches in dep order, resolves conflicts
│   └── planner.md                    # fable, high effort — plans/replans/triages for /pipeline, read-only
├── hooks/hooks.json                  # wires the scripts below to hook events
├── scripts/
│   ├── watchdog.sh                   # orchestrate gate + climb-refiring wrap nudge
│   ├── resume.sh                     # SessionStart: re-inject the common-dir-keyed handoff (worktree-reuse aware) after /clear or /compact
│   ├── save-handoff.sh               # PreCompact: write a handoff before every compaction
│   ├── suggest-docs.sh               # Stop: soft nudge when a batch changed code but no docs
│   └── prd-reap.sh                   # detect fully-closed PRDs from a round's closed slice issues
├── tests/                            # one bash test per script + the orchestrate skill
└── README.md                         # this file
```

## Inside the dev loop (`/orchestrate`)

`/orchestrate [N] [--max K] [--complexity <tier>]` runs **N** rounds (default 1), building up to
**K** issues in parallel per round (default 3). It runs on the **main thread** because only the
main thread can spawn subagents.

**The whole run executes in one orchestration worktree.** A step-0 `EnterWorktree` moves the run
into a linked worktree off the launch branch (skipped if already in one), so the merger writes to a
worktree the `personal-tools` `worktree-guard` allows and the **primary checkout is never touched**.
Per-issue implementer worktrees nest under it. The merged result is **left on the orchestration
branch** for you to merge into `dev`/`main` yourself — the run never merges back to the launch
branch, and cleanup removes only the per-issue child worktrees.

Each round:

1. **Ready set.** Compute the issues whose every `## Blocked by` ref is **closed**; skip
   `hitl` issues (those need a human). Take up to K of them.
2. **Classify (per-issue planner + implementer models).** Route each ready issue's **planner** and
   **implementer** models by complexity **tier**, classified **in-workflow**: a Workflow leaf can't
   reuse the `classify-task` skill (it fans out its own Explore subagents), so each ready issue gets
   an **explore→classify** pass that emits a real tier, **auto-accepted — no interactive confirm**
   (the run is autonomous past the launch gate). `--complexity <tier>` skips classification and pins
   every issue to that tier. The planner, implementer, and reviewer models are routed per issue; the
   round's single merger is per-round.
3. **Plan (per-issue work order).** Before the build, route each issue's **planner** by its tier and
   write its **work order** — a cheap **sonnet** minimal plan for a trivial issue, else the
   **`workflow:planner`** subagent (mode=plan) at the tier's planner model. Ordered steps + a
   `## Acceptance criteria` heading + the done-check. **No plan comment is posted and no approval
   gate fires** — the run stays autonomous.
4. **Fan out implementers.** Spawn one **implementer** per ready issue on its **confirmed model**,
   each in its own isolated git worktree (`issue-<N>` at `.worktrees/issue-<N>`), handed the step-3
   plan as its **work order**. Each builds TDD-first, runs the project's done-check, and commits —
   never touching another worktree or the base branch.
5. **Merge.** Hand the completed branches to the **merger**, which merges them into
   the base branch serially in dependency (topological) order, attempting to resolve
   conflicts **gated by the done-check**. An unresolvable conflict or a red check **stops
   and reports** rather than keeping an unverified resolution — the worktree is left for
   inspection.
6. **Close + reap.** Close the merged issues. `prd-reap.sh` then checks whether any parent
   `prd` issue is now fully done (every non-`hitl` child closed) and flags it ready-to-close.
7. **Review (per-issue).** Spawn **`personal-tools:my-review`** on each built slice's branch diff
   (`<base>..issue-<N>`) at the tier's **reviewer** model (`opus`/`opus`/`fable`), handed the issue's
   plan for conformance context. It reports severity-tagged findings — correctness, security, broken
   tests, **stale docs** — and runs the **central-mechanism / mock-drift audit**: a declared central
   mock is confirmed and an undeclared one auto-converted, each filing a `mock-debt` follow-up.
   Ordinary findings are **surfaced in the round report**; my-review **never edits code**.

my-review is a backstop, not a fixer. `/orchestrate` **hard-depends** on the `personal-tools`
`my-review` agent and **fails loud at launch** if it's missing (as `/pipeline` does). This slice
**surfaces** ordinary findings in the round report and files `mock-debt` follow-ups from its audit;
the fix loop that **acts** on the ordinary findings ships in a later slice. PR merges stay a human
decision; the loop never merges PRs.

## Inside the pipeline (`/pipeline`)

`/pipeline <issue#|task text> [--max-cycles K] [--complexity trivial|standard|complex]
[--self-plan]` runs
**one task** through the standardized chain — **models routed to the task's complexity tier**
— for work not worth slicing into an issue graph. Three input modes: an **issue number**
(autonomous — scope was pre-approved; a `prd`-labeled issue is accepted, refused if `hitl`-labeled or any `## Blocked by`
ref is still open; exactly two writes to the target issue, the plan comment and the result
comment — step 7's label creates and follow-up issues are the only other outward writes), a
**grilled task** (a `/grill-me` alignment exists in the session — the plan may be drift-checked
with `/verify-plan` and gated on user approval, per the conditions below), or **bare text** (same
gate, no drift-check).

**Step 0.5 — tier routing.** Before the worktree or any planner/implementer/reviewer spawn, a
`classify-task` call explores the touched code and classifies the task into a complexity tier,
which fixes the roster for the whole run:

| tier | planner | implementer | reviewer |
|---|---|---|---|
| trivial | sonnet | sonnet | opus |
| standard | opus | sonnet | opus |
| complex | fable | opus | fable |

`classify-task` runs its own confirm/override ask — the **one interactive stop before the fix
loop** even in autonomous issue mode, before any planner/implementer/reviewer spawns.
`--complexity <tier>` skips classification and
takes that row directly. (The old hardwired roster ≈ the **complex** tier.)

**Step 2 — who writes the plan (authorship ladder, first match wins).** A four-rule ladder
decides authorship: (1) **`--self-plan`** (flag or a natural-language "plan it yourself") →
inline, any mode/tier; (2) **trivial tier** → an automatic **minimal inline plan** that still
carries ordered steps, `## Acceptance criteria`, and the done-check; (3) **grill mode,
standard/complex** → an `AskUserQuestion` picks inline or subagent; (4) **bare/issue mode,
standard/complex** → the `workflow:planner` subagent (today's default). Rules **1–2 are the
inline levers** — they hand authorship to the **main thread** (no planner spawn), since it often
holds fuller context, especially after a `/grill-me`; rule 3 is an ask and rule 4 the subagent
default. Issue mode adds **no new ask** — its authorship is flag- or tier-driven, and classify's
tier confirm stays the only interactive stop. The **plan gate**
(grill/bare) now fires only when **tier is complex or the plan was subagent-authored** — an inline
trivial/standard plan skips it; and **verify-plan** runs on grill standard/complex only (skipped
on trivial). Step-5 replans always spawn the planner subagent, never inline; a `/clear` + `go`
resume reuses the embedded plan and never re-spawns a Step-2 planner.

The run then enters an isolated worktree (orchestrate's step-0 pattern; `issue-<N>` or
`pipeline-<slug>`), and chains: **planner** (`model: <planner>`, high — ordered steps with file
paths, testable acceptance criteria, the project done-check, risks; **only when the plan is
subagent-authored** — an inline plan per rules 1–2 skips this spawn) → **implementer** (spawned
with `model: <implementer>`, handed the plan as a *work order*) → **my-review** (the
`personal-tools` xhigh reviewer on `model: <reviewer>`, hard dependency — the run fails loud at
start if it's missing) on the branch diff. Findings route by severity:

| severity | route |
|---|---|
| low | filed as `review-fix` + `ready-for-agent` issues; never fixed in-run |
| medium | planner triage call → one ordered fix-list |
| high | ONE collective replan covering all highs (mediums appended) |
| critical | each gets its own full plan→implement→review cycle |

Declared mock-debt is filed as a `mock-debt` issue at finish — the pipeline files it directly.
Fix rounds go to a fresh implementer (`model: <implementer>`),
then a **scoped re-review** (prior findings addressed? + the fix delta only) — the reviewer
model is **held constant** across every re-review. Re-reviews are capped at `--max-cycles`
(default 2); hitting the cap with medium+ findings open pauses on an AskUserQuestion (continue /
stop / take over). State persists at every phase boundary into the handoff dir (a
`<branch>-pipeline.md` state doc plus the `.pending.json` resume pointer) — including the
**confirmed roster**, so a `/clear` + `go` resume never re-classifies. The finished branch is
**left for the user** — the pipeline never pushes, never merges, never closes the issue.

## Inside the watchdog

`hooks.json` wires five scripts to Claude Code hook events. All of them **fail open**: a
missing `python3`/`git` or any error exits 0, so they never wedge a session.

- **`watchdog.sh`** (UserPromptSubmit + PostToolUse + Stop) reads live context occupancy
  from the transcript — the last assistant entry's `input_tokens + cache_read +
  cache_creation` — and fires two signals. No hook can type a slash command, so it injects
  instructions and tells you the one command to run.
  - **Orchestrate gate** (advisory, UserPromptSubmit only): when you type the `/orchestrate`
    slash command (bare or with args) and context is already ≥ `WORKFLOW_PLANGATE_TOKENS`
    (default **60k**), it injects a hint to run `/clear` first so the loop starts in a fresh
    window. It is **purely advisory** — never a `decision: block` — so `/orchestrate` still
    runs if you proceed. Natural-language phrasing ("please orchestrate") does *not* match;
    it requires the leading slash.
  - **Wrap nudge** (any active work): when occupancy crosses `WORKFLOW_NUDGE_TOKENS`
    (default **250k**), it nudges you to wrap up at the next natural breaking point, commit,
    and run `/handoff`. It **re-fires on context climb** — every 50k past the last fire
    (250k → 300k → 350k …) — so a dropped or unseen first nudge self-recovers instead of
    staying silent for the session. Subagent-return turns (`Task`/`Agent` PostToolUse) are
    skipped entirely.
- **`resume.sh`** (SessionStart) re-injects the in-flight per-repo handoff after each
  `/clear` or `/compact`, and deletes the wrap-nudge sentinel — re-arming the nudge from the
  250k floor. The handoff dir is keyed by the repo's shared `--git-common-dir`, so a handoff
  written inside a linked worktree resumes from anywhere in the repo; when it was written in a
  worktree, the re-injected order tells the fresh session to `EnterWorktree(path=…)` that
  worktree first. Resolution is **3-tier**: the common-dir key, then the old `--show-toplevel`
  key (one release of migration), then the legacy global pointer.
- **`save-handoff.sh`** (PreCompact) writes a handoff before *every* compaction — a manual
  `/compact` or Claude Code's auto-compact — so the plan re-injects either way.
- **`suggest-docs.sh`** (Stop) gives a soft nudge when a batch changed code but touched no
  docs (`*.md`), so usage/behavior docs land in the same commit. Advisory, deduped once per
  `HEAD`, silent the moment any `.md` is in the batch. This is the *interactive* counterpart
  to `my-review`'s stale-docs check: the Stop hook nudges you while you work; `my-review`
  is the AFK backstop that flags a stale doc in the round report when an autonomous round leaves
  one behind.

### Long session, in practice

The watchdog turns a long session into deliberate `/clear` points instead of one late
auto-compact:

1. **Starting `/orchestrate` in a full window** → advisory hint to `/clear` first, then
   re-run `/orchestrate`, so the loop runs in fresh context.
2. **Crossing ~250k mid-work** → nudge to wrap at a natural breaking point, commit, and run
   `/handoff` (re-firing every ~50k as context climbs).
3. **`/handoff`** (from the `personal-tools` plugin) writes a rich handoff doc + a per-repo
   resume pointer and walks you through `/clear`; `resume.sh` then re-injects the plan into
   the fresh window, where it auto-resumes.

### Thresholds & env

| Var | Default | Effect |
|---|---|---|
| `WORKFLOW_PLANGATE_TOKENS` | `60000` | orchestrate-gate floor (advisory `/clear` hint) |
| `WORKFLOW_NUDGE_TOKENS` | `250000` | wrap-nudge floor |
| `DOCS_FILE_THRESHOLD` / `DOCS_LINE_THRESHOLD` | off | optional sensitivity for the docs nudge |

The 50k climb-refire step is hardcoded (a fixed design choice), not env-overridable.

## Conventions

- **Labels:** `prd` (PRD tracking issue), `ready-for-agent` (orchestrate-eligible), `hitl`
  (needs a human, skipped by the loop), `review-fix` (a follow-up from `my-review` findings; also
  `ready-for-agent`).
- **Dependencies:** each issue body ends with a `## Blocked by` section listing bare `#N`
  refs (one per line) or the literal `None - can start immediately`. An issue is *ready*
  iff every blocker is **closed**.

Adding a script or agent is just dropping a file in (and wiring a script into `hooks.json`),
then **restarting Claude Code** so it registers.
