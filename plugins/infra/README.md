# infra

Scripts-only shared layer. Other plugins call these scripts; infra calls into nothing.
See [`docs/swarm-design.md` § Plugin split](../../docs/swarm-design.md).

```
plugins/infra/
├── .claude-plugin/plugin.json   # manifest
├── hooks/hooks.json             # SessionStart → scripts/link-kit.sh
├── model-tiers.json             # tier → {model, effort, backend} roster, read by resolve-tier.sh
├── scripts/
│   ├── link-kit.sh              # SessionStart: point ~/.claude/kit/infra at this plugin's root
│   ├── spawn.sh                 # start (or print) a worker (one issue) or a peer (one role): `claude --bg`, or `codex exec` when the tier says codex
│   ├── session-status.sh        # session state from `claude agents --json` + the codex run dir; --self resolves this session's name, --peers resolves roster roles to ids
│   ├── check-inbound.sh         # pre-run: can worker reports reach the orchestrator? (crossSessionInbound)
│   └── resolve-tier.sh          # resolve a complexity tier → its {model, effort, backend} roster (awk, no jq; standard fallback)
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

## Two backends, for the worker form only

A worker whose tier's `implementer_backend` is `codex` runs `codex exec` in the background
instead of `claude --bg` ([`docs/swarm-design.md` § Codex backend](../../docs/swarm-design.md)).
Codex has no agent list, so the run dir **is** the session:

```
${CODEX_RUN_ROOT:-~/.claude/codex-runs}/<runid>/issue-<N>/
├── events.jsonl        # the --json event stream
├── stderr.log          # codex's progress, and the ONLY place a failure's reason lands
├── last-message.txt    # -o: the final message, shaped by --output-schema
├── status-schema.json  # the worker's fixed-shape status report
├── pid                 # alive => busy. The WRAPPER's pid, and its group leader:
│                       #   stop it with `kill -- -<pid>` or codex is orphaned
└── exit                # 0 => done, anything else => failed
```

`session-status.sh <runid>` reports those alongside the claude sessions, in the same
vocabulary, with the PID in column 2. The spawn returns immediately and prints the run dir.

The repo's **common** git dir goes in `sandbox_workspace_write.writable_roots`, because
`-s workspace-write` keeps `.git` read-only and a worker that cannot commit has nothing to
hand back. A **peer is never codex** — a peer needs an inbox and codex has none.

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
| `failed` | codex workers only: exited non-zero, or died without recording an exit code |
| `gone` | expected but not listed — it never came up, or it exited |

A **codex** worker is a process, not a session, so it is in no agent list: `session-status.sh`
reads it from `${CODEX_RUN_ROOT:-~/.claude/codex-runs}/<runid>/issue-<N>/` instead, and column 2
is its PID. It reports in this same vocabulary — `busy`, then `done` or `failed` — and it never
goes `idle`, so the liveness wait below reads it unchanged. **Control does not.** Column 2 is a
PID, and `claude stop` and `claude attach` take a *session* id: a codex row is stopped with
`kill`, **not `claude stop`**, and there is nothing to attach to.

**Kill the process GROUP, not the pid.** That PID is `spawn.sh`'s wrapper and `codex` is its
child, so a bare kill of it reaps the wrapper, leaves codex running as an **orphan still writing
the worktree**, and writes no exit file — which this table reads as `failed`, which clears the
respawn gate below, which puts a second worker on a worktree the first never left. `spawn.sh`
starts the wrapper under bash job control for exactly this, so the recorded pid leads its own
group and one kill reaches both: `kill -- -"$id"`, then `kill -9 -- -"$id"` if it outlives the
bounded wait below.

A codex worker also has no inbox, so it **cannot escalate mid-run** — an `escalate`
reaches you only in its final message, after the process has already exited. Its reason for
dying is in `stderr.log` beside the event log; nothing else records it.

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
# column 3 is the backend, and it decides the stop: a codex id is a PID, which
# `claude stop` cannot take, and the kill has to be a GROUP kill (see above).
read -r id kind < <("$S" <runid> <N> | awk '$4 == "busy" {print $2, $3}')
# Both guards below exit 1 and they mean OPPOSITE things, so each one says which it was:
# "nothing to do" is safe, the other means a pid you must not kill or respawn over.
[ -n "$id" ] || { echo "nothing busy for issue <N>: nothing to stop"; exit 1; }
# The codex pid is the wrapper and leads its own group. If it no longer does, that group
# is someone else's — plausibly another run's worker — or there is no group at all.
case "$kind" in
    codex) [ "$(ps -o pgid= -p "$id" | tr -d ' ')" = "$id" ] ||
               { echo "pid $id is not a live group leader (recycled, dead, or still launching): do NOT kill, do NOT respawn"; exit 1; }
           kill -- -"$id" ;;
    *)     claude stop "$id" ;;
esac
# verify: NO row for this issue may still be busy
[ -z "$("$S" <runid> <N> | awk '$4 == "busy"')" ] || exit 1
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
  timeout 60 bash -c 'S=~/.claude/kit/infra/scripts/session-status.sh; until [ -z "$("$S" <runid> <N> | awk "\$4 == \"busy\"")" ]; do sleep 5; done'
  ```

  **Self-contained on purpose — fill `<runid>` and `<N>` in, do not reach for `$S`.** You run
  this as its own command, which is a **fresh shell**: the `S=` in the recovery block above is
  gone. That is why every status read that gates a respawn — here and at both reads in the
  recovery block — takes the `<runid>` placeholder and not `$RUNID`. A placeholder left as a
  variable reference expands to nothing, the command substitution comes back empty, the `until`
  is satisfied on its first pass, and the wait passes instantly — which is a stop that did not
  take, missed.

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
