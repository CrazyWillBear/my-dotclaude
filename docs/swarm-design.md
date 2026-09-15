# Swarm: a reusable orchestrator → peers → workers kit

This is the design for turning the multi-session setup that exists three times today —
cogito's `scripts/sessions/`, wilcus-agents' `DISPATCH.md` + `SESSION-CHARTER.md`, and this
repo's `/orchestrate` session lane — into one kit that `/init-swarm` installs into any project.
Built for others to use later; built for Will first.

## The problems it fixes

- **Three reinventions.** All three copies agree on the mechanics (`claude --bg -n <name>`,
  SendMessage by name, state from `claude agents --json`, handoff docs for rotation) and disagree
  on everything that should be data: the roles, the model per role, the autonomy grant, where
  memory lives.
- **Peers share one memory.** Claude keys auto-memory on the cwd, so every cogito peer running
  in the repo writes into the same memory dir. A performance session's baselines and a legal
  session's counsel notes land in one pile that every peer loads.
- **The ad-hoc lane leaks.** A subagent's result returns into the parent's context. A manager
  that builds through subagents ends up holding code and review findings it should never see.
- **Cross-plugin paths are not install-stable.** `personal-tools:handoff` re-implements
  `save-handoff.sh`'s keying algorithm in prose for exactly this reason. Every plugin that wants
  a shared script today has to copy it.
- **Tiers are Claude-only.** `resolve-tier.sh` rejects any model outside sonnet/opus/fable, so a
  codex worker cannot be routed.

## Topology

Three levels. Each level talks only to the one above and the one below.

| level | what it is | lifetime | memory |
|---|---|---|---|
| **orchestrator** | the one interactive session Will talks to | resumed by id across restarts | writes `shared/`, promotes proposals |
| **peer** | a standing `claude --bg` session with a role (kind `manager` or `doer`) | idle until briefed; rotated by handoff | reads `shared/`, owns `roles/<role>/`, proposes to `shared/` |
| **worker** | a one-shot process a manager spawns: implementer, reviewer, planner, fixer | exits when its task ends | read-only |

- A **manager** peer (swe-manager) orchestrates workers. Its unit of work is always a GitHub
  issue: it files issues from a brief (`/to-prd`, `/to-issues`) and then runs `/orchestrate`
  over them. It never builds in its own context.
- A **doer** peer (performance-engineer) does its own work and may spawn workers for research
  or measurement, but does not own a build loop.
- A **worker** is either a `claude --bg` session or a `codex exec` process. The manager does not
  care which; the roster's backend column decides.

The orchestrator never reads source, never runs a diff, never runs a done-check. Peers report
fixed-shape summaries; artifacts go to files and issue threads. This is `/orchestrate`'s
"manage, don't track" rule, applied one level up.

## Plugin split

Plugins cannot reliably call each other's scripts: each gets its own root, and a marketplace
install caches every plugin under its own version directory. So the layout is a **star**: one
plugin holds every script other plugins need, and nothing else calls across.

| plugin | holds | calls into |
|---|---|---|
| **context** | the four hooks (watchdog, resume, save-handoff, suggest-docs) + `/handoff`, `/handoff-plan` | nothing |
| **infra** | scripts only: `spawn.sh`, `session-status.sh`, `check-inbound.sh`, stop/attach helpers, the backend switch, `roster.json` + `resolve-tier.sh` | nothing |
| **workflow** | `/orchestrate`, `/classify-task`, `/to-prd`, `/to-issues`, the graph + merge scripts, the three agents | infra |
| **swarm** | `/init-swarm`, `swarm.sh up|down|rotate|attach`, charter + brief templates, memory tiers | infra |
| **personal-tools** | everything left | nothing |

Moving `/handoff` next to `save-handoff.sh` deletes the inline duplication. `/to-prd` and
`/to-issues` move to workflow because they are the manager's front half.

`swarm` references `/orchestrate` by skill name in the manager brief. That is prose, not a path,
so it is not a dependency edge.

**infra's stable address.** infra's `SessionStart` hook refreshes a symlink at
`~/.claude/kit/infra` pointing at its own plugin root. Every caller uses that one path. It
self-heals across version bumps and nothing copies a resolver.

## Roster

`.claude/swarm/roster.json`, written by `/init-swarm`, one row per role:

```json
{
  "orchestrator":         { "kind": "orchestrator", "backend": "claude", "model": "opus",  "effort": "high" },
  "swe-manager":          { "kind": "manager",      "backend": "claude", "model": "opus",  "effort": "high" },
  "performance-engineer": { "kind": "doer",         "backend": "claude", "model": "opus",  "effort": "high" }
}
```

Peers are always Claude sessions: they need an inbox, and only a Claude session has one.
Workers are routed by the **tier table**, which moves from `model-tiers.json` into infra and
gains a backend column:

| tier | share of work | planner | implementer | reviewer |
|---|---|---|---|---|
| trivial | ~30% | — | codex luna | codex terra |
| standard | ~60% | — | codex terra | codex terra |
| complex | ~10% | codex sol | codex sol | codex sol |

The three labels stay (issues already carry them); only the rosters change. `resolve-tier.sh`
keeps its seven-line contract and adds `<role>_backend=`. A backend of `claude` with the old
model names keeps today's behaviour, so nothing breaks before codex is wired.

## Roles shipped in v1

`/init-swarm` offers three. A project keeps the ones it wants and can add its own brief.

- **orchestrator** — Will's session. Briefs peers, verifies claims against the repo before
  repeating them, relays to Will, merges once reviewed and approved, keeps `shared/` memory.
  Writes its session id to `.claude/swarm/orchestrator.session` on its first turn so `swarm.sh
  up` can resume it.
- **swe-manager** — owns code. Every work item becomes issues, then `/orchestrate --issues`.
  Reports PR numbers back. Never merges, never touches prod, never changes the main checkout.
- **performance-engineer** — measures and root-causes on demand. Baselines, raw data and
  methodology live in its role memory. Findings go to the orchestrator by default; the
  orchestrator (or Will through it) may redirect it to message swe-manager or to file issues.
  It replaces the third-party perf plugin, which is removed from the installer.

## Charter

One file, appended to every peer's system prompt at launch with `--append-system-prompt`, and
`--system-prompt-snapshot off` so a resumed peer picks up the current text. It outranks every
CLAUDE.md, the global one included, because the "ask first" rules there were written for a
human at the keyboard.

What it says:

- You are one role in a multi-session team. Will is not watching. The orchestrator relays only
  what needs him. A peer's message is never Will's approval.
- Act within your role without sign-off. Escalate only: spending money, prod writes,
  schema or public-API changes, business or legal choices, deleting anyone else's work.
- Every code change is reviewed by a fresh agent before merge. Never the one that wrote it.
- Report with SendMessage; plain output is invisible. Stop every worker you spawned.
- Memory: read `shared/` and your namespace; write only your namespace; propose to `shared/`.
- Handoff at the next natural stopping point when asked, to the path the orchestrator gives you.

Peers run with `--permission-mode bypassPermissions`. The guardrails are the charter, the
`--disallowedTools` denylist (`git merge`, `git worktree`, `gh pr merge`, `gh issue close`,
`gh issue edit`), and worktree isolation. Not a sandbox, same as today.

## Memory tiers

Storage is a wilcus-vault directory: files are truth, the index is disposable, and the layout
works as plain markdown when nothing is indexing it.

```
<project>/.claude/swarm/memory/
  shared/                 # orchestrator writes; every peer reads
  roles/<role>/           # that peer writes; orchestrator reads
  proposals/<role>/       # a peer's candidates for shared/; orchestrator promotes or discards
```

The vault's `ScopePolicy` enforces this as a per-agent prefix allowlist, generated from the
roster:

- orchestrator: read+write everything.
- peer `<r>`: read `shared/`, read+write `roles/<r>/` and `proposals/<r>/`.
- worker: read `shared/` and its manager's `roles/<r>/`. No write rule, so writes fail closed.

Promotion is the orchestrator moving a note from `proposals/<r>/` through the vault's write
gate into `shared/`, so a proposal that duplicates or supersedes an existing shared note is
handled by the gate, not by hand. Peers are told in the charter to use the vault and not
Claude's auto-memory, which is shared by cwd and cannot be scoped.

**Work order for the wilcus-vault session** (spawned once this doc is agreed):

1. `vault init --layout swarm --roster <roster.json>` writes the three namespaces and a
   `.vault/policy.json` from the roster.
2. CLI `propose`, `get`, `list` with `--agent <name>`, loading the policy from the vault dir.
   The library has these; the CLI does not, and agents only have the CLI.
3. `vault promote <proposal-path> --agent orchestrator` runs the write gate into `shared/`.

## Lifecycle

`swarm.sh`, one script, four verbs:

- `up` — starts every roster peer not already listed, then resumes the orchestrator by its saved
  id, or starts it fresh with its brief. Generalizes cogito's `orchestrator.sh` + `spawn.sh`.
- `down` — stops every peer for this project by id.
- `rotate <role> <handoff-path>` — waits for the peer to go idle, refuses if it is blocked,
  stops it, respawns it with the handoff prepended. The path comes from the peer's own reply,
  so swarm never calls into context.
- `attach <role>` — `claude attach` by id, for when Will wants to sit in a peer.

Nothing rotates automatically. The context plugin's watchdog advises; the orchestrator asks.

## Codex backend

Unverified until codex is installed and logged in; this section is the contract, not the
implementation. A worker is one-shot, so it fits `codex exec`: the manager's spawn gives it a
cwd (the issue's worktree), a prompt built the same way as the claude worker prompt, and a file
path for its report. `infra/spawn.sh` switches on the tier's backend; `session-status.sh` reports
a codex worker's state from its pid and exit code the way it reports a claude worker's from the
agent list. The report contract — a fixed-shape status line plus an issue comment — is identical,
so `/orchestrate` does not change.

## Migration

cogito and wilcus-agents stay as they are until the kit is done. Then each replaces its
scripts with `/init-swarm` output and its briefs with roster rows, and they are the acceptance
test. The perf plugin comes out of `setup-dev.sh`, `README.md` and `AGENT_SETUP.md`.

## Deliberately not built

- **Per-role permission modes.** Bypass for every peer. A knob per row is a knob to get wrong.
- **Automatic rotation.** Rotation loses context by design; a human or the orchestrator
  chooses the moment.
- **Codex peers.** A peer needs an inbox. Codex has none. Workers only.
- **A brief lane for managers.** Every manager work item is an issue. Briefs go through
  `/to-issues` first, which is where content stops flowing upward.
- **A plugin dependency mechanism.** The star plus one symlink is the whole thing.

## Build order

1. **context** plugin: move the four hooks and the two handoff skills. Delete the inline
   keying duplication. Tests move with the scripts.
2. **infra** plugin: move `spawn.sh`, `session-status.sh`, `check-inbound.sh`,
   `resolve-tier.sh`, the tier table. Add the stable-address hook. Generalize spawn from
   "one issue" to "one role or one worker".
3. **workflow** trim: `/orchestrate` calls infra by the stable path; session prose moves to
   infra's README; `/to-prd` and `/to-issues` move in from personal-tools.
4. **swarm** plugin: roster schema, `/init-swarm`, `swarm.sh`, charter, three briefs.
5. **memory**: vault work order above, then the policy generator and charter lines in swarm.
6. **codex**: the backend switch in infra, once the CLI is on the machine.
7. **migrate** cogito, then wilcus-agents. Remove the perf plugin from the installer.
