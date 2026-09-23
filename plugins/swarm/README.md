# swarm

Roster-driven **multi-session teams**. `/init-swarm` scaffolds a project's roster, charter and
briefs; `swarm.sh` runs the team. See
[`docs/swarm-design.md` § Roster / § Lifecycle / § Rotation](../../docs/swarm-design.md).

```
plugins/swarm/
├── .claude-plugin/plugin.json        # manifest
├── skills/
│   └── init-swarm/SKILL.md           # /init-swarm — write .claude/swarm/ for this project; spawns nothing
├── scripts/
│   ├── swarm.sh                      # run the team: up | down | rotate | attach | brief
│   ├── roster.sh                     # validate roster.json, and answer get/list against it
│   └── memory.sh                     # scaffold .claude/swarm/memory/ (real wilcus-vault, or a fallback tree)
├── templates/
│   ├── roster.json                   # all three default roles, keyed by role name
│   ├── charter.md                    # the standing rules appended to every peer's system prompt
│   └── briefs/<role>.md              # one starting brief per shipped role
├── tests/                            # one bash test per script, plus one for the skill
└── README.md                         # this file
```

`spawn.sh`, `session-status.sh` and `resolve-tier.sh` live in the [`infra`](../infra/README.md)
plugin. swarm reaches them **only** through the stable link `~/.claude/kit/infra/scripts/`,
refreshed by infra's own SessionStart hook — never by a relative path, because a marketplace
install caches each plugin under its own version directory.

## What a project gets

`/init-swarm` asks which of the three shipped roles the project wants and writes **only** those,
under `.claude/swarm/`:

```
.claude/swarm/
├── roster.json              # the chosen rows, copied verbatim from the template
├── charter.md               # written unconditionally — every role shares it
├── inbox/<role>/brief.md    # one per chosen role
├── memory/                  # shared/, roles/<role>/, proposals/<role>/
└── orchestrator.session     # the orchestrator's own session id, written on its first turn
```

It **spawns nothing**. Starting the team is `swarm.sh up`, afterwards. It also never clobbers
silently: an existing roster, charter or brief is shown as a diff and confirmed before it is
overwritten.

## Three kinds of row, and only one of them is a session

`roster.json` is one object keyed by role name, each row carrying `kind`, `backend`, `model`,
`effort` (plus optional `rotate_at` / `autocompact`, defaulting to 300000 / 400000).

| kind | what it is |
|---|---|
| `manager`, `doer` | a **peer** — a standing `claude --bg` session named by its role, which idles between briefs and is replaced by rotation |
| `orchestrator` | **your own interactive session**, the one that relays and merges. Not a peer; `swarm.sh` never starts or stops it as one |
| `worker` | never a session at all — one-shot task work, spawned per issue by `/orchestrate` |

A `worker` row must name its `manager`, and that manager must exist in the same roster.

## `swarm.sh` — the lifecycle

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm.sh" up          [project-dir]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm.sh" down        [project-dir]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm.sh" rotate <role> <handoff-path> [project-dir]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm.sh" attach <role> [project-dir]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/swarm.sh" brief  <role> <file> [project-dir]
```

`project-dir` defaults to `$PWD`.

- **`up`** starts every peer that is not already running, then hands you the terminal as the
  orchestrator — resumed from `orchestrator.session`, or started fresh from its brief. Idempotent.
  A peer that fails to spawn aborts `up` **before** the orchestrator: a half-built swarm the
  orchestrator cannot see is worse than no swarm at all.
- **`down`** stops this project's live peers. Never the orchestrator.
- **`rotate`** replaces one peer's process while keeping its name — wait for idle, stop, respawn
  with the predecessor's handoff prepended. It is the peer equivalent of `/clear` then `go`.
  Nothing here measures context: the peer nudges itself from its own transcript (the
  [`context`](../context/README.md) plugin's watchdog), and you rotate it once it replies that it
  is ready.
- **`brief`** copies a file into a role's inbox — a manual, occasional call; nothing in `up`,
  `down`, `rotate` or `attach` invokes it. In practice an inbox holds only the role's
  standing `brief.md` from init; a peer lists it once after a handoff, but ongoing
  coordination is `SendMessage`, not a file drop.

**Addressing is the one thing to get right.** `claude stop` and `claude attach` take a session
**id** and reject a name outright; the name is what `SendMessage` uses. Every id here comes from
`session-status.sh`, column 2.

**Peers are scoped by cwd, not by name.** A peer carries no run prefix — the name is the stable
address a rotation reuses — so two projects each running a `swe-manager` share a name. That is why
a peer is spawned *from* its project directory, and why `down` in one project cannot reach
another's.

Note that "already up" means `busy`, `idle` or `blocked`. A `stopped` or `done` session is still
listed under its name, and reading those as live is exactly how a `down` then `up` brings nothing
back.

## `roster.sh` — and why it fails closed

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/roster.sh" validate [project-dir]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/roster.sh" get <role> <field> [project-dir]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/roster.sh" list [kind] [project-dir]
```

Every command validates the **whole** roster before answering anything, so a `get` against a file
with one bad row anywhere fails exactly as `validate` would. This is deliberately the opposite of
infra's `resolve-tier.sh`, which fails **open** to a standard roster: `model-tiers.json` is a
hot-path lookup a caller cannot afford to lose, while `roster.json` is authored data, and a caller
proceeding from a broken one could spawn a peer under the wrong model or permissions.

## `memory.sh` — vault when it is real, a plain tree otherwise

`memory.sh scaffold` builds `.claude/swarm/memory/` from the roster. It runs real
[`wilcus-vault`](../../docs/swarm-design.md) — `vault init --layout swarm --roster … --vault …` —
only when `vault` is on `PATH` **and** its `--help` names `--layout swarm`. A bare `command -v
vault` would also match HashiCorp Vault, which shares the binary name, and firing our init flags
at that would be confusing at best and act against an unrelated Vault server at worst.

Anything failing that check is treated as vault-absent: the same `shared/`, `roles/<role>/` and
`proposals/<role>/` directories are created by hand for every `manager` and `doer` row, with no
`.vault-policy.json` — only vault writes one.

`vault init` refuses a directory that already exists, is non-empty and carries no policy file of
its own, which is precisely what an earlier fallback run leaves behind. If that tree contains no
files anywhere, it is cleared and handed to vault for real; if it contains any file, this refuses
and says so rather than guessing.

## The charter

`charter.md` is appended to **every** peer's system prompt at launch, and it **outranks every
CLAUDE.md, the global one included** — those "ask first" rules were written for a human at the
keyboard, and a peer is not one. It sets the standing terms: act within your role without
sign-off, escalate only money / prod / schema / public-API / legal / someone else's work, every
change reviewed by a fresh agent, report with `SendMessage` because plain output is invisible, and
write only your own memory namespace while proposing into `shared/`.

## Conventions

- Roster kinds are a closed set: `orchestrator` | `manager` | `doer` | `worker`.
- Editing a shipped template changes what *future* `/init-swarm` runs write; it does not touch a
  project that has already been scaffolded.
- Adding a script is just dropping a file in, then restarting Claude Code so it registers.
