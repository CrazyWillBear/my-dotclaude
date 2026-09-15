---
name: orchestrate
description: The standing dispatcher for agent work — routes by SHAPE, not size. One unit of work with you present runs as a subagent chain (implementer → my-review → fold+merge); an issue graph or PRD runs as one real `claude --bg` session per issue, named `orch-<runid>-issue-<N>`, spawned with the tier's model into its own git worktree, reporting back over SendMessage; anything ambiguous is discussed and nothing is built. Scope is always an explicit issue allowlist (--issues, or --prd N walked into its child slices, never a repo-wide label sweep), tiers come from each issue's persisted `tier:trivial|standard|complex` label, and the graph is fetched once with scope-graph.sh and frozen. Readiness (every `## Blocked by` ref closed, skip hitl, hold an e2e-gate while mock-debt is open) is computed by ready.sh, not by a model. The issue thread is the coordination medium: each agent reads the issue and its comments, does its job, appends its own, and findings never pass through the orchestrator. Merging is fold-first (merge-fold.sh lands every conflict-free branch with plain git; only the conflicted remainder reaches the merger agent), the end merge and the single PR are offered and gated on you, and every irreversible `gh` write stays on the main thread. Absorbs the old /pipeline. Use for "/orchestrate", "run the loop", "build the ready issues", "orchestrate this".
argument-hint: "[--max N=5] [--max-cycles K=2] [--merge-split-at K=5] [--prd N] [--issues N,N,...] [--skip-unknown]"
effort: high
allowed-tools: Read, Grep, Bash, Agent, Skill, AskUserQuestion, SendMessage, ListAgents
---

`/orchestrate` is the **standing dispatcher**. You talk to it all day; it decides what shape the
work is and runs it. It is not a batch job you launch and walk away from — though for a PRD it
behaves like one, because that is the right shape for a PRD.

**It runs on the main thread. Never as a subagent.** A subagent's `SendMessage` goes out under its
*parent session's* address and the replies land in the parent's conversation, not the subagent's —
a subagent orchestrator would talk and never hear back. Every worker reply would vanish.

**It absorbs `/pipeline`.** There is one front door. Two front doors to the same room rot apart.

`$ARGUMENTS` = `[--max N] [--max-cycles K] [--merge-split-at K] [--prd N] [--issues N,N,...]
[--skip-unknown]`

- **`--max N`** — **concurrent issues in flight** (default **5**), not a batch size. A slot frees
  when its issue merges, and the freed slot takes the next ready issue.
- **`--max-cycles K`** — the per-issue fix-round cap (default **2**). The initial review is free;
  the cap counts **re-reviews**.
- **`--merge-split-at K`** — the conflicted remainder above which the merge is split (default
  **5**). See [Merge](#merge).
- **`--prd N`** / **`--issues N,N,...`** — the scope. See [The allowlist](#the-allowlist).
- **`--skip-unknown`** — downgrade the unfetchable-issue error to a logged skip. Off by default,
  because failing loud on a partial scope is right.

There are **no rounds** and **no tier flag**. A tier is a **persisted label** — edit `tier:trivial`
/ `tier:standard` / `tier:complex` on the issue to change how it routes.

Backend is **GitHub Issues via `gh`** — no `gh api`, no PR merges. Never touch issues labeled
`hitl` (needs a human) or `prd` (a tracking doc — slice it with `/to-issues` first).

## Hard dependency — fail loud at launch

Both lanes hard-depend on the **`personal-tools`** plugin: **`my-review`** reviews every built
slice and runs the central-mechanism / mock-drift audit. Before doing anything else, check it is
available — if `personal-tools:my-review` is **not** in your available agents, **fail loud** naming
the missing piece ("personal-tools plugin not installed: my-review agent unavailable") and **stop**.
Do not substitute another reviewer.

Both lanes also need the **`infra`** plugin: `session-status.sh`, `check-inbound.sh` and
`resolve-tier.sh` live there and are called at `~/.claude/kit/infra/scripts/` (a symlink its
SessionStart hook writes). If `~/.claude/kit/infra` is missing, **fail loud**
("infra plugin not installed: ~/.claude/kit/infra missing") and **stop**.

The **session lane** additionally needs the `claude` CLI on `PATH` (it spawns real sessions).
`session-status.sh` fails loud if it is missing; do not paper over that by falling back to
subagents — the lanes are not interchangeable, and silently building a 20-slice PRD in one
session's context is the failure the lane split exists to prevent.

### `crossSessionInbound` — check this before a session-lane run

**A worker's report is HELD for the user's approval when the sender's permission-mode class
differs from this session's.** Workers run `bypassPermissions` (they must — see the spawn
protocol), so unless the orchestrator does too, **every** `issue <N> built …` report and every
idle notice stops for a click. On a 20-slice PRD that is dozens of interruptions in a loop whose
entire promise is that it runs unattended. Observed on a real run, not inferred.

**Run the check — do not eyeball it:**

```bash
bash ~/.claude/kit/infra/scripts/check-inbound.sh
```

| exit | meaning | what to do |
|---|---|---|
| **0** | `accept` — reports will be delivered | proceed |
| **1** | held for approval | **say so in the launch line and let the user decide.** A run that stops on every report still works; it just is not unattended. Never refuse to start over this — some users want to review every message |
| **2** | `refuse` — reports will **never** arrive | **stop.** The session lane cannot work. Offer the ad-hoc lane instead |

The fix, when they want one, is one setting in `~/.claude/settings.json`:

```json
{ "crossSessionInbound": "accept" }
```

Values are `accept` (deliver), `hold` (park for review), `refuse` (opt out). **Unset means
mode parity** — a message auto-delivers only when the sender's permission-mode class matches
yours, which is exactly why a `bypassPermissions` worker reporting to a prompting orchestrator
gets held. An explicit value always wins.

It must be set at the **user** level: a repo's settings may only *tighten* this, so a project
`.claude/settings.json` cannot loosen a user-level `hold`, and managed org policy overrides both.
Setting it mid-run was observed to take effect on the very next worker report, but set it
**before** launching a run rather than relying on that.

**Say what it costs before anyone sets it.** `accept` delivers messages from *any* local Claude
session without review — not just this run's workers. It is a machine-wide relaxation in exchange
for an unattended loop. If the user does not want that, the session lane still works; it just
stops for an approval on every report, so **tell them that up front** instead of letting them
discover it mid-run. The ad-hoc lane is unaffected — subagents are not cross-session.

---

# Step 0 — dispatch

**Route by SHAPE, not size.** A one-line typo fix and a 300-line refactor are the same shape if
they are one unit of work with you sitting there; a 3-issue graph and a 30-issue PRD are the same
shape as each other, and a different one.

| what you said | lane |
|---|---|
| **one unit of work**, explicit, and you are present | **ad-hoc** — a subagent chain on the main thread |
| an **issue graph** or a **PRD** (`--prd`, `--issues`, or "run the ready issues") | **session lane** — one `claude --bg` session per issue |
| **ambiguous** — the goal, the place, or "done" is missing | **discuss. Build nothing.** |

**"Explicit instruction"** means you can answer all three from the message alone:

- **What** — the change, concretely.
- **Where** — the file, the module, the issue.
- **Done** — how you would know it worked.

*"Fix the null check in `parser.py` — it crashes on an empty header row"* passes all three.
*"That null check is sketchy"* fails **what** and **done**: it names a place and a feeling.

Any one missing → **discuss**. Not "make a reasonable assumption and start" — the ambiguous lane
exists because building the wrong thing well is the expensive outcome.

**Announce the lane in one line and proceed. Do not ask.** An explicit instruction must never wait
on a confirmation you already gave; the announcement *is* the veto window:

> Ad-hoc lane: implementer → my-review → merge, on `issue-parser-null`. Starting.

> Session lane: 6 slices of PRD #41, 5 in flight, run `orchestrate-20260906-141500`. Starting.

---

# The ad-hoc lane

One unit of work, you are present, nothing to schedule. This is what `/pipeline` used to be.

1. **Classify** — run the `classify-task` skill (batch mode, `--no-confirm`) to get the tier, and
   resolve its roster with `bash ~/.claude/kit/infra/scripts/resolve-tier.sh <tier>`. **Never
   prompt to confirm or override a tier.** Auto-accept and say what you got.
2. **Worktree** — `EnterWorktree(name: "adhoc-<slug>")` unless you are already in a linked worktree.
3. **Plan (complex only)** — spawn `workflow:planner` at the tier's planner roster. Trivial and
   standard self-plan; see [The planner](#the-planner).
4. **Build** — spawn `workflow:implementer` at the tier's implementer roster.
5. **Review** — spawn `personal-tools:my-review` at the tier's reviewer roster. **Always a
   subagent**, spawned by you: a subagent never inherits the parent conversation, so the
   adversarial fresh-context property holds.
6. **Fix rounds** — a **fresh** implementer per round, handed the review's findings, capped by
   `--max-cycles`. Never the implementer that wrote the code.
7. **Merge** — `merge-fold.sh`, then **offer** the merge back to `dev`/`main`. Offered, never taken.

The ad-hoc lane never spawns a session, never writes a run log, and never opens a PR. It is a
chain, and when it ends you are still holding the context.

---

# The session lane

One **real `claude --bg` session per issue**, spawned by you, working in its own git worktree,
reporting back over `SendMessage`.

**Why sessions and not subagents:** a session can be attached to, killed and respawned; it can
spawn its own subagents (a subagent cannot); and it carries a real context window sized for a whole
issue. **A session costs ≈40k tokens to start**, which only pays for long parallel work — so
`tier:trivial` issues get an orchestrator-spawned **subagent** instead, and only `standard` and
`complex` get a session.

**One session per issue. Never a reused per-slot session.** A reused slot carries the previous
issue's context into the next build — which is precisely the poisoning the fresh-context reviewer
exists to prevent. When an issue is done, its session exits.

## Names and paths

| thing | shape |
|---|---|
| run id | `<ts>` — the same timestamp as the orchestration branch, e.g. `20260906-141500` |
| orchestration branch / worktree | `orchestrate-<runid>` |
| worker session | `orch-<runid>-issue-<N>` |
| issue worktree | `<baseRepo>/.worktrees/<runid>/issue-<N>` |
| issue branch | `issue-<N>` |

**The run prefix is load-bearing.** `claude agents --json` is **global**, and multiple concurrent
orchestrator sessions are the *intended* usage — a PRD run in one terminal, ad-hoc work in another.
Without the prefix one orchestrator can see, wake and **stop** another run's workers.

## Step 1 — the allowlist

**This is #77's defect A, and it runs first.** The loop used to pick its work with a repo-wide
`ready-for-agent` query. That is a correctness bug: on a real run it swept in an unrelated issue
from a different PRD and built it into that PRD's branch.

So the run **never queries for work**. Resolve an **explicit issue allowlist** first:

- **`--issues N,N,...`** → that literal list *is* the allowlist. Highest precedence.
- **`--prd N`** → PRD #N's child slices, via
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/prd-children.sh" <N>`, which prints one
  `<number> <state> <labels-csv>` line per genuine child (it owns the `Part of #N` trailer matching,
  so GitHub's tokenized search cannot hand you a slice of #10 when you asked for #1). Keep the
  children that are **open**, carry **`ready-for-agent`**, and carry neither `hitl` nor `prd`.
- **neither flag** → **infer, then confirm.** List open PRDs
  (`gh issue list --label prd --state open --json number,title`). Exactly one → scope to it and say
  so. More than one → **AskUserQuestion** with the titles. None → fall back to the repo's open
  `ready-for-agent` issues and **say plainly that the run is unscoped**, listing what it will
  consider.

**The allowlist is frozen at launch** and never re-queried. That freeze does two jobs:

- **Nothing the run files can be built by the run.** A `review-fix` follow-up filed mid-run is not
  in the allowlist, so a cap-remainder cannot be immediately rebuilt — silently bypassing the cap
  that parked it.
- It bounds the blast radius to the work you named.

An **empty allowlist** stops the run. An empty scope is never a reason to widen the query.

## Step 2 — tiers

Read each scoped issue's labels; take its tier from `tier:trivial` / `tier:standard` /
`tier:complex`.

- **Missing → backfill.** Run `/classify-task <N> --no-confirm` (it fans out its own Explore agents,
  so the tier is grounded), then persist it: ensure the label exists
  (`gh label create tier:standard --description "complexity tier: standard" 2>/dev/null || true`)
  and write it with `gh issue edit <N> --add-label tier:<t>`. The next run reads the label.
- **Auto-accept.** **Never prompt** to confirm or override a tier. Report the backfills in the
  launch line; that is the whole interaction.
- **Conflicting labels** → the **highest tier wins** (complex > standard > trivial), and warn.
  Under-tiering is the expensive failure: it routes real work to a model too cheap for it and you
  pay for the bad build *and* the fix rounds chasing it.

## Step 3 — the graph, fetched once

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/scope-graph.sh" <N1> [N2 ...] > "$GRAPH"
```

One JSON document — `{ issues: [{ n, title, state, labels, tier, body, comments, blockedBy }],
blockerStates, mockDebtOpen }`. Keep it in a **file**; you will pass its **path** to `ready.sh`
every round and you must never read it yourself (see [Context discipline](#context-discipline)).

Empty output means the fetch failed. Stop; do not degrade into a repo-wide query.

Then record the scope:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-log.sh" append "$RUNID" scope '{"issues":[12,13,14]}'
```

## Step 4 — the orchestration worktree

The whole run executes in **one** worktree, so the merge writes to a linked worktree and the
**primary checkout is never touched**. Canonicalize with `realpath` first — git may print a
relative `.git`:

- **In the primary checkout** (`git rev-parse --git-dir` and `--git-common-dir` resolve to the
  **same** path) → record `base=$(git rev-parse HEAD)` **before** the call, then
  **`EnterWorktree(name: "orchestrate-<runid>")`**. The branch point follows `worktree.baseRef`:
  `head` (which this kit's setup installs) uses the current `HEAD`, but the built-in default is
  `fresh` = `origin/<default-branch>`, which **silently drops local commits**. So verify after
  entering: if `git rev-parse HEAD` ≠ `$base`, run `git reset --hard "$base"` — the worktree is
  brand-new, so the reset is safe.
- **Already in a linked worktree** (the two **differ**) → **skip**; this worktree *is* the
  orchestration worktree.

**Then exclude the per-issue worktrees.** They nest at `<baseRepo>/.worktrees/<runid>/issue-<N>`,
inside the orchestration worktree's own tree, so without this they show up as untracked files in
`git status` while the merge runs. Append to the repo's **local** exclude (untracked — never a
tracked `.gitignore` edit in the user's repo), idempotently:

```bash
excl="$(git rev-parse --git-common-dir)/info/exclude"
grep -qxF '.worktrees/' "$excl" 2>/dev/null || printf '.worktrees/\n' >> "$excl"
```

Say this in the final report: it is a persistent mutation of the user's real repo that outlives the
run.

**Then resolve the run's own address, once:**

```bash
ORCH="$(bash ~/.claude/kit/infra/scripts/session-status.sh --self)"
```

That is the name every worker will `SendMessage`. Resolve it **here and pass it to every spawn**
rather than letting each spawn re-resolve: the name is this session's *display title*, which is
model-generated and can change, and a rename mid-run would leave already-spawned workers
addressing a name that no longer exists. If you want it stable and unambiguous, launch the
orchestrator itself as `claude -n orch-<runid>`.

## Step 5 — the admission loop

This is the whole scheduler. It is a loop **you** run, on the main thread, and it is deliberately
boring: every decision in it is either a script's output or a message that arrived.

**Each pass:**

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ready.sh" "$GRAPH" \
     --merged <each merged issue> --held <each held> --in-flight <each in flight>
```

- **numbers on stdout** → admissible, ascending. Admit the lowest-numbered ones until `--max` slots
  are full.
- **`nothing-to-do:` on stderr, exit 0** → a designed empty. If nothing is in flight, the run is
  done. Report the reason verbatim.
- **`error:` on stderr, exit 1** → an *unexplained* empty (all-`hitl`, blocked on an unclosed
  out-of-scope issue, a `## Blocked by` ref aimed at a PR number, which never resolves to
  "closed"). **Stop and report it.** Never treat it as "finished".

**Never compute readiness yourself.** It is a topological sweep over a frozen graph — arithmetic a
model can, and historically did, hallucinate.

**To admit an issue:**

1. **Context map** (see [The context map](#the-context-map)) — at **admission**, not at launch.
2. **Worktree**:
   ```bash
   git -C "$baseRepo" worktree add -b "issue-<N>" ".worktrees/<runid>/issue-<N>" "$baseBranch"
   ```
3. **Spawn** — `tier:trivial` → an orchestrator-spawned `workflow:implementer` **subagent**;
   `standard`/`complex` → a **session**:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/spawn.sh" "$RUNID" <N> <tier> \
        "$baseRepo/.worktrees/$RUNID/issue-<N>" "$baseBranch" --orchestrator "$ORCH"
   ```
   **Know the id, not just the name.** `claude stop` and `claude attach` take an **id**
   (`Usage: claude stop <id>`) and reject a session name outright — the name addresses
   `SendMessage`, the id controls the process. `claude --bg` prints a banner *containing*
   the id rather than a bare id, so don't parse spawn's output: read it from
   **`session-status.sh <runid>`, column 2**, when you need it.
4. **Subscribe** — immediately after the spawn, `SendMessage` to `orch-<runid>-issue-<N>` with
   `notify_when_idle: true` and **no message**. See [Liveness](#liveness).

**The session is the implementer.** `spawn.sh`'s prompt points it at
`plugins/workflow/agents/implementer.md` and names the obligation that cannot be lost: build the
slice's **central mechanism for real**, and where real wiring genuinely must be deferred,
**declare** it (`Mocked: <what>. Real wiring blocked by: #N`). An undeclared central mock is the
drift the whole `/to-prd`→`/to-issues`→`/orchestrate` chain exists to catch, and a session that
never reads the implementer contract would never declare one.

**Then wait.** Do not poll. The next thing that happens is a message.

**`my-review` reports; the SESSION posts.** my-review is **report-only** — it never comments, never
edits, and its one write carve-out is filing a `mock-debt` issue from its audit. So the worker
session takes my-review's report and posts the `**Review round N**` comment itself. If you ever
change that, change it in `spawn.sh`'s prompt too: the comment is the cycle counter, and a stage
that nobody owns is a stage that silently does not happen.

**When a worker reports** `issue <N> built head=<sha> review=<H high, M medium, L low>` (or
`issue <N> fixed round=<K> head=<sha> review=…` from a fix round — same handling, and `round=K`
is how you confirm which round just landed):

- **`H > 0` or `M > 0`, and rounds remain** → spawn a **fix round**:
  `spawn.sh ... --role fix --round <K>`. A **fresh** session every round: nothing compounds, and
  the fixer is not defending its own code.
- **clean, or the cap is spent** → the issue joins the **merge queue**.
- **`issue <N> failed <why>`** → **drain**: admit nothing new, let the in-flight work finish, then
  stop and report. Killing the loop mid-flight strands built, reviewed branches that had already
  earned their merge.

**Cycles are counted by reading the issue** — the number of `**Review round N**` comments on it —
never by a field you keep. See [The bus](#the-bus).

**Failure is drain-then-stop, not kill.**

---

# Spawn protocol

`spawn.sh` owns the flags, and its test pins every one of them. The two that are not obvious:

- **`--permission-mode bypassPermissions`** — an unattended session in `manual` or `acceptEdits`
  **deadlocks on its first prompt** with nobody there to answer. This was observed, not assumed.
- **`--disallowedTools`** — `git merge`, `git worktree`, `gh pr`, `gh issue close`, `gh issue edit`.
  Every **irreversible, outward-facing** write stays on the main thread (#77: a close fired from a
  low-context subagent was killed by a safety classifier — *correctly*, because that agent could not
  explain the issue it was closing). **`git push` and `gh issue comment` are deliberately allowed**:
  a comment is additive, never destructive, and the issue thread is the bus.

  **Known limit, accepted:** `--add-dir` fences the **file tools**, not Bash. The containment here
  is the denylist plus worktree isolation — it is not a sandbox.

**Every spawn prompt must tell the session to report with `SendMessage`.** A session's plain text
output is **invisible** to every other agent — a probe session, asked a question, printed its answer
into its own transcript where nobody could see it. Miss this line and the orchestrator waits
forever. `spawn.sh` writes it into every prompt; if you ever hand-roll a spawn, write it yourself.

**The orchestrator's address** comes from `bash session-status.sh --self`, which matches
`$CLAUDE_CODE_SESSION_ID` against the agent list. `spawn.sh` resolves it automatically and **fails
loud** if it cannot — a worker that cannot name its orchestrator reports into the void.

---

# The bus

**The issue thread is the coordination medium.** Each agent reads the issue and its comments, does
its job, and appends its own. **Findings are never handed through the orchestrator.** This makes
"manage, don't track" structural instead of a rule somebody has to remember.

What goes where:

| carries | where |
|---|---|
| review findings, decisions, notes a future reader needs | **the issue** — it cannot be regenerated |
| the context map, worktree paths, scratch | **local files** — regenerable, and free to delete |

A file index posted to an issue is **permanent garbage** that every future run pays to read.
`scope-graph.sh` pulls comments into the graph, so everything on the issue is context forever.

## The comment contract

**Brevity is a correctness property here, not a style preference.** A verbose review comment
poisons every subsequent run's context — including runs a year from now.

````
**Review round 1** — 1 high, 2 medium, 3 low

- **high** `src/billing/retry.py:42` — retry loop can re-submit a charge; no idempotency
  key on the second attempt.
- **medium** `tests/test_retry.py` — this test passes with the implementation stubbed.
````

Plus, rarely, a **note** comment for something a future reader genuinely needs — a constraint
discovered mid-build, an approach ruled out and why. Not a progress log.

The build session's first comment is one line: `Tackled #N on branch issue-N`, plus anything of
note.

**`**Review round N**` is the counter.** The number of those comments on an issue *is* how many
review cycles it has had. Nothing stores it; nothing can disagree with it.

---

# The context map

One **sonnet `Explore`** at **admission** — not at launch. A dependent's map should reflect its
**merged blockers**, and at launch those blockers have not been built yet.

Write it to the issue's worktree as `CONTEXT-MAP.md`. Flat: **path + one line each**. No structure,
no summaries of summaries.

```
src/billing/retry.py — the retry loop this issue changes
src/billing/client.py — calls it; owns the idempotency key
tests/test_retry.py — the existing coverage
```

**It is a hint, not a contract.** A pointer to a file that moved costs the implementer one failed
`Read`. There are **no sha stamps and no staleness protocol** — if a session doubts the map, it
deletes it and re-runs `Explore`. Anything more is a synchronization problem invented to serve a
convenience.

**The map is for the implementer only.** The reviewer has the **diff**, which already names every
changed file, and `my-review`'s scope is explicitly the change plus its grepped neighbours. Handing
a reviewer a map would widen its scope, which is the opposite of what it is for.

---

# The planner

**Kept — for `complex` issues only, and spawned by the build session, not by the orchestrator.**

`/pipeline` was the planner's other consumer and `/pipeline` is gone, so its fate had to be settled.
The reasoning:

- **Why keep it:** on a complex issue the cross-cutting design call is worth settling *before* any
  code exists. That is a different job from the TDD-first planning already in the implementer's
  contract.
- **Why only complex:** the planner was measured as a second full repo exploration in front of an
  implementer that explores anyway — 83 of 317 agent-minutes on a 56-agent run, **26% of all work**,
  to hand over a document the implementer would have derived. Trivial and standard **self-plan**.
- **Why the session spawns it, not the orchestrator:** a plan is prose, and prose the orchestrator
  reads is prose in the orchestrator's context forever ([Context discipline](#context-discipline)).
  The build session spawns `workflow:planner` as its first act, keeps the plan in its own context,
  and the orchestrator never sees a word of it.

---

# Liveness

**Subscribe, don't poll.** At spawn, `SendMessage` to the worker with `notify_when_idle: true` and
**no message**. That is a pure subscription: it costs the worker nothing, and it fires **once**,
when the session goes idle or exits. The tool contract says explicitly never to poll `ListAgents`
or send "are you done?" messages — a polled worker pays for every poll out of its own context.

**For state, use the script:**

```bash
bash ~/.claude/kit/infra/scripts/session-status.sh "$RUNID" <expected issue numbers>
```

**Expect only the issues that actually have a session.** `tier:trivial` issues are built by an
orchestrator-spawned subagent, so naming one here reports it `gone` — which the recovery rules
read as "it never came up" and answer with a respawn of work that is already running.

One line per session — `<name> <id> <kind> <state>`:

| state | means |
|---|---|
| `busy` | working |
| `idle` | finished its turn — pair with the issue's comments to see what it did |
| `blocked` | a **permission wedge**: it is asking for something and nobody is there |
| `done` | reported itself finished |
| `stopped` | killed by `claude stop` — what a respawn waits for, and not the same as `gone` |
| `gone` | expected but not listed — it never came up, or it exited |

**Never parse `claude logs`.** It is a raw ANSI screen dump — cursor moves and spinner frames, not
a transcript.

## Recovery

**Commit after every green sub-step.** This is the *recovery mechanism*, not hygiene: it caps the
loss from a kill at one sub-step, which is what makes killing on **suspicion** affordable — and
that, in turn, is what resolves the otherwise-unresolvable "is it busy or is it wedged?" judgment
call. You do not have to be right; you have to be cheap to be wrong.

**`stop` → verify stopped → respawn.**

```bash
S=~/.claude/kit/infra/scripts/session-status.sh
# the id — column 2 — NOT the name. `claude stop <name>` fails: "No job matching …"
id=$("$S" "$RUNID" <N> | awk '$4 == "busy" {print $2}')
claude stop "$id"
# verify: NO row for this issue may still be busy
[ -z "$("$S" "$RUNID" <N> | awk '$4 == "busy"')" ] || exit 1
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-log.sh" append "$RUNID" respawned '{"n":<N>}'
bash "${CLAUDE_PLUGIN_ROOT}/scripts/spawn.sh" ...                     # same worktree, same branch
```

**One issue can have several rows.** Every session a run ever started keeps its row (the list
includes completed ones on purpose — see `gone` above), so after a respawn you will see the old
`stopped` row *and* the new `busy` one under the same name. **Match on state, never on the name
alone**, and read the newest live row as the current session. A rule like "is issue-14 busy?" is
ambiguous the moment a respawn happens — which is exactly when you are asking.

- **Never `rm`.** It deletes the worktree "when safe" — which is exactly the state being recovered.
- **Never spawn onto a worktree whose previous session is still listed alive.** Two processes on one
  worktree corrupts it. Verify first, every time.
- **A stop can be acknowledged and not take.** Observed: `claude stop <id>` printed
  `stopped <id>` while the session stayed `working` across repeated attempts. So **wait
  bounded, then escalate — never spin**:

  ```bash
  timeout 60 bash -c 'until [ -z "$("$S" "$RUNID" <N> | awk "\$4 == \"busy\"")" ]; do sleep 5; done'
  ```

  If that times out, **do not respawn**. The safety rule is unchanged — two processes on one
  worktree corrupts it — so tell the user instead, naming the id and the worktree, and let them
  kill it by hand. An unbounded wait here turns a recoverable wedge into a silent hang of the
  recovery path itself.
- The respawned session picks up from the **last commit**, not from the top of the issue.

**Respawn once. Escalate on the second failure.** A task that wedges two sessions gets a human, not
a third 40k-token spawn. The count comes from the run log:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-log.sh" state "$RUNID"    # respawned=12:2,13:1
```

Nothing else records it — git and GitHub have no idea a session was killed — which is why
`respawned` is one of the run log's four events.

---

# Escalation

A worker that hits something only a human can answer `SendMessage`s the orchestrator:
`issue <N> escalate <question>`.

**Offer both routes. Recommend one.**

> #14's session is asking whether the retry budget is per-request or per-session. I can relay the
> answer, or you can `claude attach 7f3a1c04` and talk to it directly. Recommend attaching — this
> is about the code.

Give the **id**, not the name — `claude attach` takes an id (`Usage: claude attach <id>`), and you
kept it at spawn.

- **Mediate** for short calls: a scope question, a yes/no, a name.
- **Attach** for real back-and-forth about code. Relaying that would drag the code itself into the
  orchestrator's context, which is the one thing the orchestrator must not accumulate.

`claude attach <id>` detaches with `←` or `Ctrl+Z` and **the session keeps running** — background
sessions are owned by the background service, not the terminal (they carry no `pid` in
`agents --json`).

**An escalated session is exempt from the deadline** while you are engaged with it. Otherwise the
watchdog kills the session you are in the middle of a conversation with.

**A session that resolves an escalation directly with you MUST report the resolution** — a
`SendMessage` back *and* an issue comment — before continuing. Without that the orchestrator's
state silently diverges from reality: it thinks #14 is blocked while #14 is three commits past it.

---

# Merge

## Fold first, remainder second

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-fold.sh" "$baseBranch" issue-12 issue-13 issue-14
```

`merge-fold.sh` lands every conflict-free branch with **plain git**, in order, testing each with
`git merge-tree --write-tree` before touching the working tree. Only the **conflicted remainder**
reaches the `workflow:merger` agent.

**It is a fold, not a filter.** Conflict-freeness is relative to the **accumulating** base: a branch
that is clean against the base can conflict once an earlier branch has landed. A filter would merge
both and corrupt the result.

The merger is **never tier-routed** — it runs at its frontmatter's **opus**. A bad conflict
resolution corrupts the base branch for every issue in the run.

## The split

**`--merge-split-at`, default 5.** `K` — the size of the conflicted remainder — is **measured** by
the fold, every run, for free.

**The two-at-a-time path is not built.** Build it when real runs report `K > 5`. The crossover comes
from `C·K²/4 > S` with a measured session cost `S ≈ 40k` and per-conflict cost `C ≈ 5k`, giving
≈5.7. Until then, one merger.

## What is gated and what is not

- **In-run merges** (`issue-<N>` → `orchestrate-<runid>`) are **automatic**. Gating them deadlocks
  the run: a dependent cannot start until its blocker merges.
- **The end merge is offered and gated on you** — along with deleting the merged branches.
- **One PR at the end, not per slice.** A per-slice PR puts the network, CI and the permission
  classifier inside the linearization point, which is the measured friction this design exists to
  remove.

A merge that lands **capped** (findings remained at `--max-cycles`) **holds its dependents** for the
rest of the run — they would be building on known debt:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-log.sh" append "$RUNID" held '{"n":15,"why":"blocker #12 merged capped"}'
```

---

# Context discipline

**The orchestrator never `Read`s a source file, never runs `git diff`, never runs the done-check,
never opens a findings file.** Workers report a fixed-shape status line; artifacts go to files or
issue comments; the orchestrator passes **paths and numbers**.

Target: **~50 tokens per issue, not 800.** A dispatcher that reads the work it dispatches stops
being able to dispatch.

**On-demand summaries only.** When you ask about an issue, spawn an agent to answer — never
accumulate the answer in advance:

| you ask | who answers |
|---|---|
| "what happened on #14?" | a **haiku** agent: read its comments + `git diff base..issue-14`, return a paragraph |
| "is #14's code right?" | `Explore`, or a reviewer-model agent — a different question, a different model |

Never automatic. A summary nobody asked for is context nobody chose to spend.

**Deterministic logic lives in scripts, not in this file.** Prose can only be grep-tested. The
readiness rules, session state, the spawn flags, the run log and the merge fold are all scripts
with real tests:

| script | owns |
|---|---|
| `ready.sh` | readiness + the empty-set classification |
| `session-status.sh` | worker state, and `--self` |
| `spawn.sh` | the session command and the worker prompt contract |
| `run-log.sh` | scope · held · respawned · decision |
| `check-inbound.sh` | whether worker reports can reach the orchestrator at all |
| `merge-fold.sh` | the deterministic fold |
| `scope-graph.sh` | the one graph fetch |
| `prd-children.sh` / `prd-reap.sh` | PRD scoping and the end-of-run reap |
| `resolve-tier.sh` | tier → {model, effort} |

`session-status.sh`, `check-inbound.sh` and `resolve-tier.sh` live in the **infra** plugin and are
always called at `~/.claude/kit/infra/scripts/`.

---

# End of run

The run ends when `ready.sh` reports a **designed empty** with nothing in flight, or when a drain
finishes. Then, on the main thread and in this order — **close first**, so a failed close is loud
instead of buried under a success table:

1. **Merge and PR — offered, not taken.** Offer the end merge of `orchestrate-<runid>` into
   `dev`/`main`, and offer **one** PR. Offer deleting the merged `issue-<N>` branches.
2. **Close the merged issues (#77 fix 1).** This is the **only** place the run closes an issue:
   ```bash
   gh issue close <N> --comment "Merged in <sha> by /orchestrate."
   ```
   An irreversible outward-facing write belongs on the main thread, where the conversational context
   can account for it.
3. **Verify every close (#77 fix 2).** Re-read each with `gh issue view <N> --json state`. Any issue
   **still open after its close** → stop and report it loudly, naming the issue and the merge commit.
   Do not run the PRD reap on an unverified close: the reap would read a still-open child and draw
   the wrong conclusion. (The run stays convergent regardless — `ready.sh --merged` never re-admits
   a merged issue, close or no close. This check is about reporting the truth.)
4. **Comment each conflict-stop onto its issue** — additive, never a close or an edit:
   > `/orchestrate` could not merge this: `<reason>`. The branch and its worktree are left intact at
   > `<path>` — resolve and re-run.
5. **`ExitWorktree(keep)`** — the orchestration branch and worktree stay intact.
6. **Report.** One row per scoped issue:

   | column | source |
   |---|---|
   | `#` → title | the Step-3 graph |
   | tier (and whether **backfilled**) | your Step-2 record — it covers every scoped issue, attempted or not |
   | merged? closed? | the fold's output + the close verification |
   | merge commit | the fold's output |
   | review outcome | the issue's **last review-round comment** — read it now, on demand, not during the run |
   | notes | `run-log.sh state` (held, respawns, decisions) + `ready.sh`'s classification |

   Below the table: the stop reason if it drained; the **held** dependents and why; the **unbuilt**
   issues (scoped, admissible, never admitted); any respawns; the `.git/info/exclude` line Step 4
   added to the user's real repo; and, if any `mock-debt` is open, a one-line ledger summary
   (`mock-debt: N open — #A, #B`) naming any `e2e-gate` it held.

7. **Mirror the ledger (C7).** For a PRD run, reflect the open `mock-debt` set into the PRD body:
   rewrite **only** a delimited `## Mock-debt ledger` section (`- [ ] #N — <what>` open, `- [x]`
   closed) from `gh issue list --label mock-debt --json number,title,state`. Touch no other part of
   the PRD body. The **label query is authoritative** for the gate, so a stale mirror never breaks
   enforcement.

8. **PRD reap.** Pass every issue closed this run to the helper:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/prd-reap.sh" <N1> [N2 ...]
   ```
   - `ready <prd>` → **offer** in the final report, never auto-close:
     > PRD #N appears complete — all child slices are closed. Close it? (yes/no)

     On yes: `gh issue close <N> --comment "All child slices are closed — closing this PRD."`
   - `blocked <prd> hitl <H> ...` → note it, do not offer:
     > PRD #N is blocked — open `hitl` issue(s): #H need human review before closing.
   - **Prints nothing** → the report is unchanged. Do not mention PRDs at all.

---

# Deliberately not built

Each of these is something a fresh session will reasonably want to add. Each was argued down:

- **Two-at-a-time conflict resolution** — until a real run reports `K > 5`. The fold measures it for
  free every run.
- **Recon to predict file overlap** — the fold *observes* conflicts directly, so predicting them is
  solving a problem we can now just measure. (The context-map form of recon survives; it has a
  different justification.)
- **A frozen "contract" commit of stubs / type signatures** — the `## Blocked by` DAG already
  prevents concurrent work on an interface that does not exist, and this commits speculative stubs
  to a base branch that may be abandoned.
- **Waves / round barriers** — continuous scheduling with slot refill is strictly better.
- **Watch tables, claim tables, notification queues** — the issue thread replaces all three.
- **Per-slice PRs** — see [What is gated](#what-is-gated-and-what-is-not).
- **A worker-scoped context nudge** — nothing compounds: every fix round is a fresh session.
- **A periodic wrap-and-handoff nudge** — deliberately deleted; `watchdog.sh` is the orchestrate
  gate only.
