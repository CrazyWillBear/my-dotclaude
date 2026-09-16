# my-dotclaude

My Claude Code setup, version-controlled so I can drop it back onto a fresh machine in
one command. It's also packaged so anyone can install the same kit, tuned for either a
developer or a non-coder.

Deep docs live with the code they describe: the `workflow` plugin's autonomous loop is in
[`plugins/workflow/README.md`](plugins/workflow/README.md), the context watchdog and
`/handoff` are in [`plugins/context/README.md`](plugins/context/README.md), and the
slash-command kit is in
[`plugins/personal-tools/README.md`](plugins/personal-tools/README.md). This file is the
front door: what it is, how to install it, and how the pieces fit.

## Quickstart

Both setups are **user-wide** — they install into `~/.claude`, not a project folder, so
the kit follows you across every project. Pick one and you're done; full install details
are in [Install (full)](#install-full) below.

### Option A — let Claude Code do it (no terminal needed)

Open Claude Code and paste one of these:

**Non-developer:**

> I'm not a programmer and I want to start a project with your help. Please set up Claude
> Code for me: read the setup instructions at
> https://github.com/CrazyWillBear/my-dotclaude/blob/main/AGENT_SETUP.md and follow
> the **non-developer** steps. Install everything and explain what you're doing in plain
> English.

**Developer:**

> Set up Claude Code with my full kit. Read
> https://github.com/CrazyWillBear/my-dotclaude/blob/main/AGENT_SETUP.md and follow
> the **developer** steps: install the plugins, the Playwright MCP, and the `gh` allowlist,
> and write the global CLAUDE.md.

### Option B — run a script

```bash
# developer (macOS / Linux / WSL)
curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-dev.sh | bash
# non-developer
curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-simple.sh | bash
```

macOS / Linux / WSL only. On Windows, run the scripts under WSL.

Then **restart Claude Code** so it loads the plugins.

## What's in here

- **Global `CLAUDE.md`** (`global/CLAUDE.md` → `~/.claude/CLAUDE.md`) — my machine-wide
  working rules: test-driven, small diffs, ask before anything destructive, never
  commit secrets. (The non-developer kit installs a plain-English `CLAUDE.md` instead.)
- **`context`** plugin (`plugins/context/`) — context-window management: the four hooks
  (watchdog, resume, save-handoff, suggest-docs) that drive deliberate, early `/clear` and
  `/handoff` as a session's window fills, plus the `/handoff` and `/handoff-plan` skills
  themselves. Calls into nothing else, so every other plugin can depend on it.
  **Full reference:** [`plugins/context/README.md`](plugins/context/README.md).
- **`personal-tools`** plugin (`plugins/personal-tools/`) — my own slash commands and
  subagents: `/explain`, `/diagnose`, `/my-review`, `/dedup-search`, `/init-python-project`,
  and the human-in-the-loop front-end `/grill-me`. It also
  ships the **worktree guard** — a `PreToolUse` hook that keeps writes out of a repo's
  primary checkout and into a per-task worktree (`EnterWorktree`), so parallel sessions
  never collide, plus a `SessionStart` GC backstop for crash-orphaned worktrees.
  **Full reference:** [`plugins/personal-tools/README.md`](plugins/personal-tools/README.md).
- **`infra`** plugin (`plugins/infra/`) — scripts-only shared layer (session state, inbound
  check, tier resolution). A `SessionStart` hook links `~/.claude/kit/infra` so other plugins
  call its scripts by one fixed path. `workflow` needs it.
  **Full reference:** [`plugins/infra/README.md`](plugins/infra/README.md).
- **`workflow`** plugin (`plugins/workflow/`) — `/orchestrate`, a standing dispatcher that
  routes work by shape: one explicit unit runs as a subagent chain; an issue graph or PRD
  gets one real background Claude Code session per issue, each in its own worktree,
  coordinating over the issue thread. Also ships the manager's front half, `/to-prd` → `/to-issues`,
  which turns an aligned task into a PRD issue and slices it into the tiered issues `/orchestrate` builds.
  **Full reference:** [`plugins/workflow/README.md`](plugins/workflow/README.md).
- **`swarm`** plugin (`plugins/swarm/`) — roster-driven multi-session teams: `/init-swarm` writes
  a project's `.claude/swarm/roster.json`, charter, and one brief per chosen role (orchestrator,
  swe-manager, performance-engineer), and `swarm.sh` runs the team — `up`, `down`, `rotate`,
  `attach`, and `brief` (drop a brief into a role's inbox).
  Replaces the third-party perf plugin with a performance-engineer role.
- **[ponytail](https://github.com/DietrichGebert/ponytail)** — third-party plugin for
  minimal, YAGNI-first code; installed alongside the above.
- **[agent-sdk-dev](https://github.com/anthropics/claude-plugins-official)** — Anthropic's
  official plugin for scaffolding Claude Agent SDK apps (`/new-sdk-app`); installed
  alongside the above.
- **[security-guidance](https://github.com/ComposioHQ/awesome-claude-plugins/tree/master/security-guidance)**
  — third-party plugin from Composio's marketplace: adds an advisory hook that flags
  problematic code patterns before writes. The hook blocks the first such edit per session
  so it gets a second look; set `ENABLE_SECURITY_REMINDER=0` to silence it.
- **[security-sweep](https://github.com/Onome-AJ/security-sweep-plugin)** — third-party,
  read-only security-scan skill: greps the project for secrets, injection, auth/config
  issues, and weak deps against OWASP / LLM / Mobile top-ten patterns.
- **Setup scripts** (`setup/`) — two user-wide installers: `setup-dev` (developer) and
  `setup-simple` (non-developer). Both install the same kit into `~/.claude`.

## How to use

What you actually type day to day. One human-in-the-loop front-end and one AFK loop, with
**GitHub Issues as the tracker** (via the `gh` CLI).

### The issue loop

1. **`/grill-me`** interrogates you about the task — scope, constraints, edge cases,
   acceptance criteria — and emits a shared-understanding summary shaped to feed the PRD.
2. **`/to-prd`** explores the repo, maps the testing seams, fills the PRD template, and
   publishes it as one GitHub issue labelled `prd`.
3. **`/to-issues`** breaks the PRD into **tracer-bullet vertical slices** (each cuts all
   layers and is demoable alone), publishing them in dependency order so each issue's
   `## Blocked by` section carries real `#N` refs — each labelled with its complexity
   **tier** (`tier:trivial|standard|complex`), which is what routes the agent models later.
4. **`/orchestrate [--max N]`** then runs AFK until the scope drains: it keeps N issues in
   flight (readiness computed by a script over a launch-frozen issue graph, never guessed),
   spawns **one background Claude Code session per issue** into its own worktree, and each
   session reviews its own slice with `my-review` and posts the findings **onto the issue** —
   so the findings never pass through the orchestrator's context. Conflict-free branches are
   merged by a deterministic fold; only the conflicted remainder reaches an agent.

For a **single task** not worth slicing into an issue graph, `/orchestrate` runs the same
discipline in one pass without spawning anything: it announces the ad-hoc lane and chains
plan (complex only) → build → `my-review` → capped fix rounds → an **offered** merge. There is
no separate command — two front doors to the same room rot apart.

The machinery behind each step — worktrees, the merger, the per-issue `my-review` stage, label
conventions — is in [`plugins/workflow/README.md`](plugins/workflow/README.md); the per-command
details are in [`plugins/personal-tools/README.md`](plugins/personal-tools/README.md).

### Working a long session

The `context` plugin manages the context window with deliberate, **early** `/clear` and
`/handoff` instead of waiting for Claude Code's near-the-limit auto-compact. No hook or
agent can type a slash command, so the watchdog halts the agent and tells you the one
command to type. In short:

1. **Starting `/orchestrate` in a full window (≥ 60k tokens)** → an *advisory* nudge to run
   `/clear` first, then re-run `/orchestrate`, so the loop starts in fresh context. It never
   blocks — `/orchestrate` still runs if you proceed.
2. **`/handoff`** writes a rich handoff doc + the resume pointer (both keyed per-repo) and
   walks you through `/clear` into fresh context, where the plan auto-resumes.

The full hook wiring (`watchdog.sh`, `resume.sh`, `save-handoff.sh`, `suggest-docs.sh`),
the env-overridable thresholds, and the `PreCompact` handoff are documented in
[`plugins/context/README.md`](plugins/context/README.md#inside-the-watchdog).

### Keeping the kit updated

The kit ships as versioned GitHub Releases, and updates reach an installed machine
through the `personal-tools` plugin — no need to re-run the installer:

1. **A new release is cut** when a version bump lands on `main` (see the maintainer's
   release model in [`CLAUDE.md`](CLAUDE.md#release--versioning)).
2. **You hear about it.** A `SessionStart` hook quietly checks once a day whether a newer
   release exists and, if so, surfaces a one-line notice naming the version and pointing
   you at `/update-kit`. It's throttled to ~once per 24h and **fails open** — a network
   hiccup just stays silent, never blocking the session.
3. **`/check-updates`** — run it any time to ask on demand. It prints either
   `kit is up to date (vX.Y.Z)` or `vX.Y.Z available — run /update-kit to upgrade`.
4. **`/update-kit`** — applies the latest release: it updates the `my-dotclaude`
   marketplace entry and every plugin listed in its manifest, refreshes the status line,
   then reminds you to **restart Claude Code** so the new versions load. Works for both
   the developer and non-developer setups.

Per-command details are in
[`plugins/personal-tools/README.md`](plugins/personal-tools/README.md).

## Install (full)

The full picture behind [Quickstart](#quickstart): what the audiences differ on, what the
installers touch, and the single-plugin path.

The two setups install the same plugins, the Playwright MCP, and a `gh` allowlist; they
differ only in audience:

| | Developer (`setup-dev`) | Non-developer (`setup-simple`) |
|---|---|---|
| global `CLAUDE.md` | technical conventions (`global/CLAUDE.md`) | plain-English, no-jargon contract |
| `model` | `opus` | Claude Code's default |
| status line | context line (dir · branch · model · tokens · cost · churn · update flag; folds in the ponytail badge) | not set |
| ponytail level | `full` (default) | `lite` (a little gentler) |
| universal-ctags | installed (for code navigation) | not installed |

The installers back up any existing `~/.claude/CLAUDE.md` and `~/.claude/settings.json` before
touching them, and won't overwrite an existing global `CLAUDE.md` without `--force`.

### Option C — just one plugin (manual)

If you only want, say, the `workflow` plugin and will write your own `CLAUDE.md`:

```
/plugin marketplace add CrazyWillBear/my-dotclaude
/plugin install infra@my-dotclaude
/plugin install workflow@my-dotclaude
```

(`workflow` calls `infra`'s scripts, so install both. Swap them for `personal-tools` for the
slash-command kit.)

### What gets installed

Beyond the plugins, both setups add the **Playwright MCP** server and a **`gh` (GitHub
CLI) allowlist**; the developer setup also installs **universal-ctags** (idempotent —
skipped if `ctags` is already on PATH).

**For GitHub I use `gh`, not a GitHub MCP server** — on a machine with `gh`, the CLI plus
Bash already cover the whole GitHub API, so a GitHub MCP would only add a managed token and
per-session tool-schema overhead. The allowlist covers the common **read-only** `gh`
commands (PR / issue / repo / run reads) **plus** the issue-write commands the dev loop
needs — `gh issue create`, `gh issue edit`, `gh issue comment`, `gh issue close`, and
`gh label create` — so `/to-prd`, `/to-issues`, and `/orchestrate` can file and update
issues without prompting. It deliberately **excludes `gh api`** (which can POST/DELETE any
endpoint) and **`gh pr merge`** (merges stay a human decision). The setup warns if `gh`
isn't installed or logged in. Playwright stays an MCP because it has no CLI equivalent.

## Reference

### Layout

```
my-dotclaude/
├── .claude-plugin/marketplace.json  # lists context + personal-tools + infra + workflow + swarm
├── plugins/
│   ├── context/           # watchdog/resume/handoff hooks + /handoff, /handoff-plan — see plugins/context/README.md
│   ├── personal-tools/    # slash commands + subagents — see plugins/personal-tools/README.md
│   ├── infra/             # shared scripts at ~/.claude/kit/infra — see plugins/infra/README.md
│   ├── workflow/          # /orchestrate dispatcher + /to-prd, /to-issues — see plugins/workflow/README.md
│   └── swarm/             # /init-swarm roster, charter + briefs; swarm.sh up|down|rotate|attach|brief
├── global/
│   ├── CLAUDE.md         # my global ~/.claude/CLAUDE.md (developer setup)
│   └── CLAUDE.simple.md  # plain-English variant (installed by setup-simple)
├── setup/                # setup-dev.sh / setup-simple.sh + lib/ + tests/
└── AGENT_SETUP.md        # instructions Claude follows for the paste-a-prompt path
```

Each plugin's own `README.md` carries its full file tree and per-piece reference.

### Requirements

`bash` and `python3` (the watchdog uses python3 to parse the transcript; if it's missing
the hook fails open — it does nothing rather than blocking). The setup scripts also need
the `claude` CLI and use `curl`. Ponytail and the Playwright MCP both need
Node ≥ 18 (Playwright runs via `npx`). The issue loop (`/to-prd`, `/to-issues`,
`/orchestrate`) needs the [`gh` CLI](https://cli.github.com) installed and
`gh auth login`'d; the setup just warns if it's absent.

> **Note:** ponytail's intensity level is set per *machine*, not per project (it has no
> per-project setting). The non-developer setup sets the machine default to `lite`.

### Notes & limits

- The orchestrate gate (the `/clear`-first nudge before `/orchestrate`) is **advisory** —
  it injects a hint but never `decision: block`s, so `/orchestrate` still runs if you
  proceed. There is deliberately no periodic wrap-up nudge — it interrupted long autonomous
  runs; `save-handoff.sh` still writes a handoff on real compaction.
- `/orchestrate` runs subagents via the Agent tool on the main thread (subagents can't spawn
  subagents); the opus merger attempts to resolve merge conflicts gated by the done-check,
  but an **unresolvable conflict or a failed done-check stops and reports** rather than
  keeping an unverified resolution, leaving the worktree for inspection.

## License

[MIT](./LICENSE) © William Chastain
