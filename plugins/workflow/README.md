# workflow

**`/orchestrate`** — the **standing dispatcher**, versioned here with the rest of my setup. It
routes work by **shape**: one explicit unit of work goes to **`/adhoc`** (a subagent chain), an
issue graph or PRD runs **one boxed, one-shot worker per issue** in its own worktree, and anything
ambiguous is discussed rather than built. It absorbed the old `/pipeline`; there is one front door.

**`/to-prd`** and **`/to-issues`** are the manager's front half: `/to-prd` captures a thoroughly discussed idea
as a decision-record PRD issue, and `/to-issues` slices a PRD (or a spec, or the current discussion) into the
tiered, dependency-ordered `ready-for-agent` issues `/orchestrate` then builds.

The [`context`](../context/README.md) plugin is a companion, not a dependency called at
runtime (the star rule — see `docs/swarm-design.md` § Plugin split): its watchdog advises
`/clear` before `/orchestrate` runs in an already-full window, and its `/handoff` is how you
hand an in-flight `/orchestrate` run to a fresh session.

```
plugins/workflow/
├── .claude-plugin/plugin.json        # manifest
├── skills/
│   ├── orchestrate/SKILL.md          # /orchestrate — the dispatcher and the session lane's runbook
│   ├── adhoc/SKILL.md                # /adhoc — one explicit unit of work as a subagent chain
│   ├── classify-task/SKILL.md        # /classify-task — tier a task; the roster is resolved via infra's resolve-tier.sh
│   ├── to-prd/SKILL.md               # /to-prd — write a PRD, file it as a labeled GitHub issue
│   └── to-issues/SKILL.md            # /to-issues <#> — slice a PRD into vertical-slice issues, tiered for /orchestrate
├── agents/
│   ├── implementer.md                # opus, max effort (fallback; spawns pass the chain's top cell) — builds one issue in one worktree
│   ├── merger.md                     # opus, xhigh effort — resolves the fold's conflicted remainder
│   └── planner.md                    # opus, high effort — the plan contract; in the session lane consult.sh runs it on the planner cell and posts **Plan** to the issue
├── scripts/
│   ├── launch.sh                     # start a session-lane run: checks, allowlist, graph, tiers, orchestration worktree, run.env
│   ├── admit.sh                      # admit an issue (worktree, plan, spawn) or fill free slots from ready.sh
│   ├── handle-report.sh              # wait for the next worker report and act on it by table; --merged / --answer / --resource
│   ├── end-run.sh                    # integration review, preview, push, one PR with Closes #N, cleanup
│   ├── run-env.sh                    # sourced by the four above: run.env, paths, the one spawn call
│   ├── ready.sh                      # which scoped issues are READY right now, + the empty-set classification
│   ├── run-log.sh                    # append-only run log: scope · admitted · merged · held · respawned · decision · planned · consulted · escalated · follow-up · integration-review
│   ├── follow-up.sh                  # a capped merge's open findings → one scheduled follow-up that re-blocks its dependents
│   ├── merge-fold.sh                 # deterministic model-free merge fold; refuses when the base is behind its upstream
│   ├── prd-children.sh               # resolve a PRD's child slices (launch.sh's scope and open-child count)
│   └── scope-graph.sh                # fetch the whole issue graph at launch (bodies, comments, tiers, blockers, mock-debt)
├── tests/                            # one bash test per script + one per skill and agent
└── README.md                         # this file
```

`spawn.sh`, `session-status.sh`, `resolve-tier.sh` and `model-tiers.json` live
in the [`infra`](../infra/README.md) plugin; workflow calls them at `~/.claude/kit/infra/scripts/`.

## The session lane

`SKILL.md` is a **runbook over scripts**: the model runs them, relays what they print for a human,
and acts on three kinds of line. Every decision is a script's, with a real test.

1. **`launch.sh`** — dependency checks (kit links, worker boxes, CLIs), the **explicit allowlist**
   (`--issues`, or `--prd N`'s open `ready-for-agent` children via `prd-children.sh`), the graph
   fetched **once** (`scope-graph.sh`), tiers from `tier:*` labels (missing → `missing-tier:`, the
   skill backfills with `/classify-task` and reruns), the launch fetch check (`merge-fold.sh`), the
   orchestration worktree `orchestrate-<runid>`, and `run.env` for every later script.
2. **`admit.sh --next`** — `ready.sh` over the frozen graph, minus what is merged, held or in flight
   (all from `run-log.sh`); the lowest ready issues fill `--max` (default 6) slots: a worktree off
   the orchestration branch, a `**Plan**` from `consult.sh` for standard and complex, then
   `spawn.sh` at attempt 0. Blocker states are re-read live first, so a blocker that closes
   mid-run unblocks its dependents. A repo may ship `.orchestrate/provision.sh` (run by `admit.sh`
   before the first spawn: `<runid> <issue> <worktree>` in, `NAME=VALUE` lines out, stored as that
   issue's env) and `.orchestrate/teardown.sh` (same args, run per issue by `end-run.sh` with that issue's env
   exported); both are read from the launch commit, never a worktree. A third,
   `.orchestrate/post-fold.sh`, runs in the orchestration worktree after every clean fold (args
   `<runid> <issue> <worktree>`, no provisioned env); non-zero hands the already-committed merge to
   the merger and holds other folds and new admissions until it is fixed. `provision.sh`'s stdout is
   reserved for `NAME=VALUE` lines.
3. **`handle-report.sh --wait`** — blocks on the in-flight workers (`worker-report.sh --any`) and
   handles the first report by table: clean → fold it in; findings → a fix round on the same model;
   `escalate.sh` says otherwise → a decide, a capped merge with a follow-up, or a respawn on the next
   model of the tier's chain (at the top: drain); a deviation → `consult.sh consult` and a resumed
   worker; a question, a missing resource or a merge conflict → printed for the human or the
   `merger` agent. Then `admit.sh --next` refills the slot.
4. **`end-run.sh`** — the integration review, the end-merge preview, a push and **one PR** into the
   launch branch with `Closes #N` per merged slice, then cleanup (teardown hook, env files, and the
   worker worktrees and branches whose work is already on the run branch).

**A worker is a process, not a session.** Codex workers are `codex exec`; claude workers are
`claude -p` in the **implementer box** (`~/.claude/kit/boxes/implementer`, a per-role config dir with
the implementer contract as its `CLAUDE.md` and none of the user's plugins, skills, memory or MCP
servers). Both leave the same run dir — event stream, schema'd report, pid, exit — and both are
reviewed by the same sibling reviewer (`my-review` in the reviewer box) after they exit. Fix rounds
are fresh workers that read the issue's latest `**Review round**` comment.

**The issue thread is the bus.** Each agent reads the issue **and its comments**, does its job, and
appends its own; **findings never pass through the orchestrator**. The issue carries what cannot be
regenerated (review findings, decisions, notes to future readers); run dirs and worktrees carry what
can. **Brevity is a correctness property**: every later run reads every comment.

**Recovery.** Workers **commit after every green sub-step**, which caps the loss from a kill at one
sub-step and makes killing on suspicion affordable. `escalate.sh` decides from countable evidence —
a failure, a third deviation, the second review of an attempt still carrying high or medium findings,
a stall, a full context — never by asking the worker. `ESCALATE_ROUND_BACKSTOP=6` bounds every
issue's review rounds; a capped issue merges and its open findings become one follow-up issue that
blocks its dependents.

`/orchestrate` **hard-depends** on the `personal-tools` `my-review` agent, which owns the
`mock-debt` filing from its central-mechanism audit. The loop never merges the PR and never closes an
issue: the slices close when you merge it.

## Design notes

- **Why the main thread.** The loop relays human questions, spawns the merger, and enters and
  leaves the orchestration worktree — all things a subagent cannot do for the user. It moved off the
  Workflow tool, which has no way to wait on or talk to a running worker.
- **Why scripts, not prose.** A model doing a topological sweep, counting rounds or remembering an
  attempt number across turns hallucinates (#77's 1.84M-token loop rebuilt the same issues). Prose
  can only be grep-tested; a script gets fixtures.
- **Why boxed one-shot workers.** A full user config costs a worker ~44k tokens before it reads its
  task (hundreds of MCP tools, every plugin skill, the global `CLAUDE.md`, memory); a box costs
  ~21k, the reviewer box ~7k. One-shot processes also leave no registry rows (one machine had 394
  finished `orch-*` sessions) and need no inbox, so the cross-session message gate is gone.
- **Why the allowlist is frozen.** A repo-wide `ready-for-agent` query once built an unrelated issue
  into a PRD's branch (#77). Nothing the run files is built by the run, except a capped merge's
  follow-up, which enters the frozen graph through `follow-up.sh`.
- **Why a fold, then a merger.** `git merge-tree` decides conflict-freeness for free; only the
  conflicted remainder needs a model, and conflict-freeness is relative to the accumulating base.
- **Why one PR, and `Closes #N`.** In-run merges are automatic (gating them deadlocks the run); the
  end merge is a human decision. Closing on merge keeps every irreversible GitHub write on the
  user's side of that decision.

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
