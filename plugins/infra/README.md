# infra

Scripts-only shared layer. Other plugins call these scripts; infra calls into nothing.
See [`docs/swarm-design.md` § Plugin split](../../docs/swarm-design.md).

```
plugins/infra/
├── .claude-plugin/plugin.json   # manifest
├── hooks/hooks.json             # SessionStart → scripts/link-kit.sh
├── model-tiers.json             # tier → {model, effort} roster, read by resolve-tier.sh
├── scripts/
│   ├── link-kit.sh              # SessionStart: point ~/.claude/kit/infra at this plugin's root
│   ├── spawn.sh                 # build (or print) the `claude --bg` command for a worker (one issue) or a peer (one role)
│   ├── session-status.sh        # worker session state from `claude agents --json`; --self resolves this session's name
│   ├── check-inbound.sh         # pre-run: can worker reports reach the orchestrator? (crossSessionInbound)
│   └── resolve-tier.sh          # resolve a complexity tier → its {model, effort} roster (awk, no jq; standard fallback)
├── tests/                       # one bash test per script
└── README.md                    # this file
```

## `spawn.sh` — two forms, one command

A **worker** is one-shot and owns one issue; a **peer** is a standing role session that idles
between briefs and is rotated by handoff ([`docs/swarm-design.md` § Topology](../../docs/swarm-design.md)).
They share one command builder on purpose — the same name, denylist, `bypassPermissions`,
`--system-prompt-snapshot off` and closed stdin — because letting them drift apart is the
reinvention this kit replaces.

```bash
# worker: tier-routed model, fenced to its worktree, started from it
bash ~/.claude/kit/infra/scripts/spawn.sh <runid> <issue> <tier> <worktree> <base> [--role build|fix]

# peer: named by its role, carrying the charter and its brief
bash ~/.claude/kit/infra/scripts/spawn.sh peer --name swe-manager \
     --brief b.md --charter c.md --model opus --effort high [--handoff h.md] [--autocompact 400k]
```

A peer's `--name` **is** its stable address: rotation stops the process and respawns under the
same name, so there is no run prefix. `--charter`'s text is appended to the system prompt (the CLI
has no `--append-system-prompt-file`), and `--handoff` prepends a read-this-first instruction
naming the predecessor's doc, before the brief. Peers are not tier-routed — their roster row
carries the model. `--dry-run` prints the command one argument per line.

## Spawn protocol

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

## The stable address

A plugin's install path is a versioned cache directory, so no other plugin can find infra
by relative path. Instead, infra's `SessionStart` hook keeps a symlink at
`~/.claude/kit/infra` pointing at its own root, and every caller uses that one path:

```bash
bash ~/.claude/kit/infra/scripts/session-status.sh --self
```

The link appears on the first session start after install, and is repointed on every
start, so it follows version bumps. If a real directory sits at that path, the hook
refuses and says so rather than delete it.

## Liveness and recovery

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

### Recovery

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
# run-log.sh is the orchestrator's own script (plugins/workflow/scripts/), not infra's.
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-log.sh" append "$RUNID" respawned '{"n":<N>}'
bash ~/.claude/kit/infra/scripts/spawn.sh ...                         # same worktree, same branch
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
# run-log.sh is the orchestrator's own script (plugins/workflow/scripts/), not infra's.
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-log.sh" state "$RUNID"    # respawned=12:2,13:1
```

Nothing else records it — git and GitHub have no idea a session was killed — which is why
`respawned` is one of the run log's four events.

## The bus

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

### The comment contract

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
