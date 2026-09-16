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
├── pid                 # alive => busy
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
