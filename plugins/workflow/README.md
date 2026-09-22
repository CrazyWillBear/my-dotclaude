# workflow

**`/orchestrate`** — the **standing dispatcher**, versioned here with the rest of my setup. It
routes work by **shape**: one explicit unit of work runs as a subagent chain, an issue graph or
PRD gets **one real `claude --bg` session per issue** in its own worktree, and anything ambiguous
is discussed rather than built. It absorbed the old `/pipeline`; there is one front door.

**`/to-prd`** and **`/to-issues`** are the manager's front half: `/to-prd` turns an aligned task
into a PRD issue, and `/to-issues` slices a PRD (or a spec, or the current discussion) into the
tiered, dependency-ordered `ready-for-agent` issues `/orchestrate` then builds.

The [`context`](../context/README.md) plugin is a companion, not a dependency called at
runtime (the star rule — see `docs/swarm-design.md` § Plugin split): its watchdog advises
`/clear` before `/orchestrate` runs in an already-full window, and its `/handoff` is how you
hand an in-flight `/orchestrate` run to a fresh session.

```
plugins/workflow/
├── .claude-plugin/plugin.json        # manifest
├── skills/
│   ├── orchestrate/SKILL.md          # /orchestrate — the dispatcher and both its lanes
│   ├── classify-task/SKILL.md        # /classify-task — tier a task; the roster is resolved via infra's resolve-tier.sh
│   ├── to-prd/SKILL.md               # /to-prd — write a PRD, file it as a labeled GitHub issue
│   └── to-issues/SKILL.md            # /to-issues <#> — slice a PRD into vertical-slice issues, tiered for /orchestrate
├── agents/
│   ├── implementer.md                # sonnet, max effort — builds one issue in one worktree
│   ├── merger.md                     # opus, xhigh effort — resolves the fold's conflicted remainder
│   └── planner.md                    # opus, high effort — the plan contract; in the session lane consult.sh runs it on the planner cell and posts **Plan** to the issue
├── scripts/
│   ├── ready.sh                      # which scoped issues are READY right now, + the empty-set classification
│   ├── run-log.sh                    # append-only run log: scope · held · respawned · decision · planned · consulted · escalated
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
`done` / `stopped` / `failed` (codex workers) / `gone`, and **fails loud** if `claude` is missing or returns junk — silence there would read
as "every session finished". **Never parse `claude logs`**: it is a raw ANSI screen dump.

Workers **commit after every green sub-step**. That is the *recovery mechanism*, not hygiene: it caps
the loss from a kill at one sub-step, which is what makes killing on **suspicion** affordable and
resolves the otherwise-unresolvable "busy or wedged?" call. Recovery is **`stop` → verify stopped →
respawn** onto the same worktree — with the session **id**, since `claude stop` rejects a name — never `rm` (it deletes the worktree being recovered), and never
onto a worktree whose previous session is still alive. A **codex** worker is replaced along its
tier's implementer chain (luna → terra → opus) by `escalate.sh`, from countable evidence — a
`failed` report, a third deviation, a second review round with findings, a stall, a full context
— never by asking it; at the top of the chain the run drains. The counts come from `run-log.sh`,
because nothing in git or GitHub records that a session was killed or a model changed.

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

## The orchestrate gate

Context management (the four hooks + `/handoff` + `/handoff-plan`) moved to the
[`context`](../context/README.md) plugin — see its README for the full hook reference. The
one piece worth knowing here: `context`'s `watchdog.sh` (`UserPromptSubmit`) advises `/clear`
when you type the `/orchestrate` slash command (bare or with args) and context is already ≥
`WORKFLOW_PLANGATE_TOKENS` (default **60k**) — **purely advisory**, never a `decision: block`,
so `/orchestrate` still runs if you proceed. Natural-language phrasing ("please orchestrate")
does *not* match; it requires the leading slash.

To hand an in-flight `/orchestrate` run to a fresh session, run `context`'s `/handoff`.

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

Adding a script or agent is just dropping a file in, then **restarting Claude Code** so it
registers.
