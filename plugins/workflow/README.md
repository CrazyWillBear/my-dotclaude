# workflow

Two features in one plugin, versioned here with the rest of my setup:

1. **`/orchestrate`** — the **standing dispatcher**. It routes work by **shape**: one explicit
   unit of work runs as a subagent chain, an issue graph or PRD gets **one real `claude --bg`
   session per issue** in its own worktree, and anything ambiguous is discussed rather than
   built. It absorbed the old `/pipeline`; there is one front door.
2. **An orchestrate context gate** — a `UserPromptSubmit` hook that advises `/clear` when you
   type `/orchestrate` with a window that is already full, so the loop starts with room to run.

```
plugins/workflow/
├── .claude-plugin/plugin.json        # manifest
├── skills/
│   ├── orchestrate/SKILL.md          # /orchestrate — the dispatcher and both its lanes
│   └── classify-task/SKILL.md        # /classify-task — tier a task; the roster is resolved via infra's resolve-tier.sh
├── agents/
│   ├── implementer.md                # sonnet, max effort — builds one issue in one worktree
│   ├── merger.md                     # opus, xhigh effort — resolves the fold's conflicted remainder
│   └── planner.md                    # opus, high effort — complex-tier planning only, read-only
├── hooks/hooks.json                  # wires the scripts below to hook events
├── scripts/
│   ├── watchdog.sh                   # UserPromptSubmit: advise /clear before /orchestrate in a full window
│   ├── resume.sh                     # SessionStart: re-inject the common-dir-keyed handoff (worktree-reuse aware) after /clear or /compact
│   ├── save-handoff.sh               # PreCompact: write a handoff before every compaction; OWNS the per-repo keyed dir
│   ├── suggest-docs.sh               # Stop: soft nudge when a batch changed code but no docs
│   ├── ready.sh                      # which scoped issues are READY right now, + the empty-set classification
│   ├── run-log.sh                    # append-only run log: scope · held · respawned · decision
│   ├── merge-fold.sh                 # deterministic model-free merge fold; prints the conflicted remainder
│   ├── prd-children.sh               # resolve a PRD's child slices (shared: orchestrate's scope + prd-reap)
│   ├── prd-reap.sh                   # detect fully-closed PRDs from the run's closed slice issues
│   └── scope-graph.sh                # fetch the whole issue graph at launch (bodies, comments, tiers, blockers, mock-debt)
├── tests/                            # one bash test per script + one per skill and agent
└── README.md                         # this file
```

`spawn.sh`, `session-status.sh`, `check-inbound.sh`, `resolve-tier.sh` and `model-tiers.json` live
in the [`infra`](../infra/README.md) plugin; workflow calls them at `~/.claude/kit/infra/scripts/`.

## Why it works this way

The loop used to run inside the **Workflow** tool. That kept per-issue chatter out of the main
conversation, but it foreclosed the thing this design needs: **a Workflow has no messaging
primitive**. `agent()` is one-shot, there is no inbox, and a running script cannot reach a running
agent. So the loop moved to the **main thread**, where it drives real background Claude Code
sessions that can be messaged, attached to, killed and respawned.

**The orchestrator is never a subagent.** A subagent's `SendMessage` goes out under its *parent
session's* address and replies land in the parent's conversation — a subagent orchestrator would
talk and never hear back.

## Step 0 — dispatch

| what you said | lane |
|---|---|
| one unit of work, explicit, and you are present | **ad-hoc** — a subagent chain |
| an issue graph or PRD (`--prd`, `--issues`) | **session lane** — one `claude --bg` session per issue |
| ambiguous — the goal, the place, or "done" is missing | **discuss; build nothing** |

"Explicit" means **what**, **where** and **done** are all answerable from the message alone. The
lane is **announced in one line, not asked** — the announcement is the veto window.

## The ad-hoc lane

Classify → worktree → (plan, complex only) → build → `my-review` → capped fix rounds → fold →
**offer** the merge. This is what `/pipeline` used to be. It never spawns a session, never writes a
run log, and never opens a PR.

## The session lane

**One session per issue, never reused.** A reused slot carries the previous issue's context into
the next build — the exact poisoning the fresh-context reviewer exists to prevent. A session costs
**≈40k tokens** to start, which only pays for long parallel work, so `tier:trivial` issues get a
subagent instead and only `standard` / `complex` get a session.

Names carry the run: sessions are `orch-<runid>-issue-<N>`, worktrees `.worktrees/<runid>/issue-<N>`.
`claude agents --json` is **global** and concurrent orchestrator runs are the intended usage — without
the prefix one run can see, wake and **stop** another run's workers.

**The run only ever builds an explicit allowlist.** `--issues N,N,...` is a literal list, `--prd N`
walks PRD #N's child slices (`prd-children.sh`), and with neither flag the skill infers the open PRD
(asking if there's more than one). The loop **never runs a repo-wide `ready-for-agent` query** — one
that did swept an unrelated issue into a PRD's branch (#77). The allowlist is **frozen at launch**, so
**nothing the run files can be built by the run**: a `review-fix` follow-up filed mid-run — including a
cap-remainder — waits for a future run instead of bypassing the cap that parked it.

**The tier is a label, not a guess.** `tier:trivial` / `tier:standard` / `tier:complex`, set by
`/to-issues` at slice time, **read** at launch and **backfilled** when missing (real `classify-task`,
Explore-grounded, auto-accepted — a tier is **never** an interactive prompt). Conflicting labels
resolve to the **highest** tier. Edit the label to change how an issue routes; there is no tier flag.

**The graph is fetched once.** `scope-graph.sh` prints the whole scoped graph as one JSON document —
bodies, comments, labels, tiers, `## Blocked by` refs, the state of every ref (in scope or not), and
the open `mock-debt` ledger. Readiness is then computed by **`ready.sh`**, never by a model: a
topological sweep is arithmetic a model can hallucinate. `ready.sh` also **classifies an empty ready
set** — a designed empty (scope complete, everything held or in flight, an `e2e-gate` held by open
mock-debt) exits 0 and says why; an unexplained one (all-`hitl`, a blocker outside the scope, a
`## Blocked by` ref aimed at a PR) exits **1**, because a clean empty success that reads as "all done"
is the failure mode this whole design keeps circling back to.

**The whole run executes in one orchestration worktree** off the launch branch (`EnterWorktree`,
skipped if you are already in one), with per-issue worktrees nested under it. The merged result is
**left on the orchestration branch** — the run never merges back to the launch branch.

### The loop

1. **`ready.sh`** over the frozen graph, minus what merged, is held, or is in flight.
2. **Admit** the lowest-numbered ready issues up to `--max N` (default 5). For each: write a
   `CONTEXT-MAP.md` into its worktree (one sonnet `Explore` at **admission**, so a dependent's map
   reflects its merged blockers), cut the worktree, and **`spawn.sh`** the session.
3. **Subscribe, don't poll.** `SendMessage` with `notify_when_idle: true` and **no message** — a pure
   subscription that costs the worker nothing and fires once when it goes idle.
4. **The session builds**, spawns `my-review` itself, posts a review-round comment on the issue, and
   **reports and exits**. A session's plain output is **invisible** to other agents, so every spawn
   prompt tells it to report with `SendMessage` — miss that line and the orchestrator waits forever.
5. **Fix rounds are fresh sessions** (`--role fix`), told to work from the issue's latest review-round
   comment. Nothing compounds, and the fixer is not defending its own code. Capped by `--max-cycles`
   (default 2); **cycles are counted by reading the issue's review-round comments**, never stored.
6. **Merge is a fold first.** `merge-fold.sh` lands every conflict-free branch with plain git, testing
   each with `git merge-tree --write-tree` before touching the working tree; only the **conflicted
   remainder** reaches the `merger` agent (**opus**, never tier-routed). It is a *fold*, not a filter:
   conflict-freeness is relative to the accumulating base.
7. **In-run merges are automatic; the end merge and the single PR are offered.** Gating in-run merges
   would deadlock the run. One PR at the end keeps the network, CI and the permission classifier out
   of the linearization point.
8. **Closes happen on the main thread, and every close is verified.** An irreversible outward-facing
   write belongs where the conversational context can account for it: run from a low-context subagent,
   this exact call was killed by a safety classifier, the ready set never drained, and the loop rebuilt
   the same issues for 1.84M tokens (#77).

**A failure drains the run; it doesn't kill it.** Admission stops, in-flight work finishes, and the
run reports its stop reason. Killing mid-flight strands branches that had already earned their merge.

### The issue thread is the bus

Each agent reads the issue **and its comments**, does its job, and appends its own. **Findings never
pass through the orchestrator** — which makes "manage, don't track" structural rather than a rule
somebody has to remember. The issue carries what **cannot be regenerated** (review findings,
decisions, notes to future readers); local files carry what can (the context map). Comment format is
a contract, and **brevity is a correctness property**: a verbose review comment poisons every later
run's context.

### Liveness and recovery

`session-status.sh <runid>` classifies each worker `busy` / `idle` / `blocked` (a permission wedge) /
`done` / `gone`, and **fails loud** if `claude` is missing or returns junk — silence there would read
as "every session finished". **Never parse `claude logs`**: it is a raw ANSI screen dump.

Workers **commit after every green sub-step**. That is the *recovery mechanism*, not hygiene: it caps
the loss from a kill at one sub-step, which is what makes killing on **suspicion** affordable and
resolves the otherwise-unresolvable "busy or wedged?" call. Recovery is **`stop` → verify stopped →
respawn** onto the same worktree — with the session **id**, since `claude stop` rejects a name — never `rm` (it deletes the worktree being recovered), and never
onto a worktree whose previous session is still alive. **Respawn once, escalate on the second**; the
count comes from `run-log.sh`, because nothing in git or GitHub records that a session was killed.

An escalating worker messages the orchestrator, which **offers both** mediation and
`claude attach <id>` (column 2 of `session-status.sh`) — attach for anything about code, so the code never enters the
orchestrator's context. An escalated session is **exempt from the deadline** while you are engaged,
and must **report the resolution** back before continuing.

### Context discipline

The orchestrator **never reads a source file, never runs `git diff`, never runs the done-check, never
opens a findings file**. Workers report fixed-shape status lines; artifacts go to files or issue
comments; the orchestrator passes paths and numbers. Target ≈**50 tokens per issue**. Summaries are
**on demand only** — a haiku agent for "what happened on #14?", a reviewer-model agent for "is #14's
code right?".

Deterministic logic lives in **scripts**, not in prose: prose can only be grep-tested, and every
script here is driven against real fixtures by its own test.

**Before a session-lane run, `check-inbound.sh` asks whether worker reports can reach the
orchestrator at all.** Workers run `bypassPermissions`, and a
peer message whose permission-mode class differs from the receiving session's is **held for the
user's approval** — so without `{"crossSessionInbound": "accept"}` in `~/.claude/settings.json`,
every worker report interrupts the loop it was supposed to run without. It has to be user-level (a
repo may only tighten it), and it is a real relaxation: `accept` delivers messages from *any* local
session, not only this run's workers. Observed on a live run.

`/orchestrate` **hard-depends** on the `personal-tools` `my-review` agent and fails loud at launch if
it is missing. my-review **owns** the `mock-debt` filing from its central-mechanism audit. PR merges
stay a human decision; the loop never merges PRs.

## Inside the watchdog

`hooks.json` wires five scripts to Claude Code hook events. All of them **fail open**: a
missing `python3`/`git` or any error exits 0, so they never wedge a session.

- **`watchdog.sh`** (UserPromptSubmit) reads live context occupancy
  from the transcript — the last assistant entry's `input_tokens + cache_read +
  cache_creation` — and fires one advisory signal. No hook can type a slash command, so it
  injects instructions and tells you the one command to run.
  - **Orchestrate gate** (advisory, UserPromptSubmit only): when you type the `/orchestrate`
    slash command (bare or with args) and context is already ≥ `WORKFLOW_PLANGATE_TOKENS`
    (default **60k**), it injects a hint to run `/clear` first so the loop starts in a fresh
    window. It is **purely advisory** — never a `decision: block` — so `/orchestrate` still
    runs if you proceed. Natural-language phrasing ("please orchestrate") does *not* match;
    it requires the leading slash.

  There is deliberately **no periodic wrap-up nudge**. An earlier version fired at a fixed
  occupancy on any work and told the agent to stop, commit and `/handoff` — which interrupted
  long autonomous runs at their worst moment, and is actively wrong now that `/orchestrate`
  runs its loop on the main thread. A session that genuinely needs a handoff still gets one
  from `save-handoff.sh` on `PreCompact`, which fires on real compaction rather than a guess.
- **`resume.sh`** (SessionStart) re-injects the in-flight per-repo handoff after each
  `/clear` or `/compact`. The handoff dir is keyed by the repo's shared `--git-common-dir`, so a handoff
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
  is the AFK backstop that flags a stale doc in the run report when an autonomous slice leaves
  one behind.

### Long session, in practice

The watchdog turns a long session into deliberate `/clear` points instead of one late
auto-compact:

1. **Starting `/orchestrate` in a full window** → advisory hint to `/clear` first, then
   re-run `/orchestrate`, so the loop runs in fresh context.
2. **`/handoff`** (from the `personal-tools` plugin) writes a rich handoff doc + a per-repo
   resume pointer and walks you through `/clear`; `resume.sh` then re-injects the plan into
   the fresh window, where it auto-resumes.

### Thresholds & env

| Var | Default | Effect |
|---|---|---|
| `WORKFLOW_PLANGATE_TOKENS` | `60000` | orchestrate-gate floor (advisory `/clear` hint) |
| `DOCS_FILE_THRESHOLD` / `DOCS_LINE_THRESHOLD` | off | optional sensitivity for the docs nudge |

## Conventions

- **Labels:** `prd` (PRD tracking issue), `ready-for-agent` (orchestrate-eligible), `hitl`
  (needs a human, skipped by the loop), `review-fix` (a follow-up from `my-review` findings; also
  `ready-for-agent`), `tier:trivial` / `tier:standard` / `tier:complex` (the issue's complexity
  tier — set by `/to-issues` at slice time, backfilled by `/orchestrate` at launch, and the sole
  input to model routing), `mock-debt` (central mechanism mocked; the open set is the ledger) and
  `e2e-gate` (the final slice; held while any `mock-debt` is open).
- **Dependencies:** each issue body ends with a `## Blocked by` section listing bare `#N`
  refs (one per line) or the literal `None - can start immediately`. An issue is *ready*
  iff every blocker is **closed**. A `#N` in prose is **not** a blocker — only a bare ref on its
  own line inside that section counts (`scripts/scope-graph.sh` owns the parse).

Adding a script or agent is just dropping a file in (and wiring a script into `hooks.json`),
then **restarting Claude Code** so it registers.
