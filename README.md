# my-dotclaude

My Claude Code setup, version-controlled so I can drop it back onto a fresh machine in
one command. It's also packaged so anyone can install the same kit, tuned for either a
developer or a non-coder.

Deep docs live with the code they describe: the `workflow` plugin's internals (the
autonomous loop + the context watchdog) are in
[`plugins/workflow/README.md`](plugins/workflow/README.md), and the slash-command kit is
in [`plugins/personal-tools/README.md`](plugins/personal-tools/README.md). This file is
the front door: what it is, how to install it, and how the pieces fit.

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
- **`personal-tools`** plugin (`plugins/personal-tools/`) — my own slash commands and
  subagents: `/explain`, `/diagnose`, `/dedup-search`, `/init-python-project`,
  and the human-in-the-loop dev front-end `/grill-me` → `/to-prd` → `/to-issues` plus
  `/handoff`. **Full reference:** [`plugins/personal-tools/README.md`](plugins/personal-tools/README.md).
- **`workflow`** plugin (`plugins/workflow/`) — two things in one plugin: an autonomous
  dev loop (`/orchestrate`) that solves GitHub issues in parallel worktrees, and a context
  watchdog that drives deliberate, early `/clear` and `/handoff` as the window fills.
  **Full reference:** [`plugins/workflow/README.md`](plugins/workflow/README.md).
- **[caveman](https://github.com/JuliusBrussee/caveman)** — third-party plugin for
  terse output; installed alongside the above.
- **[agent-sdk-dev](https://github.com/anthropics/claude-plugins-official)** — Anthropic's
  official plugin for scaffolding Claude Agent SDK apps (`/new-sdk-app`); installed
  alongside the above.
- **[perf](https://github.com/ComposioHQ/awesome-claude-plugins/tree/master/perf)** and
  **[security-guidance](https://github.com/ComposioHQ/awesome-claude-plugins/tree/master/security-guidance)**
  — third-party plugins from Composio's marketplace: `/perf` runs a multi-phase
  performance investigation (baseline → profile → hypothesis → optimize), and
  `security-guidance` adds an advisory hook that flags risky code (`eval(`, `execSync(`,
  `os.system`, …) before a write. (The guidance hook *blocks* the first such edit per
  session so it gets a second look; set `ENABLE_SECURITY_REMINDER=0` to silence it.)
- **[security-sweep](https://github.com/Onome-AJ/security-sweep-plugin)** — third-party,
  read-only security-scan skill: greps the project for secrets, injection, auth/config
  issues, and weak deps against OWASP / LLM / Mobile top-ten patterns.
- **Setup scripts** (`setup/`) — two user-wide installers: `setup-dev` (developer) and
  `setup-simple` (non-developer). Both install the same kit into `~/.claude`.

## How to use

What you actually type day to day. One human-in-the-loop front-end and one AFK loop, with
**GitHub Issues as the tracker** (via the `gh` CLI).

### The dev pipeline

1. **`/grill-me`** interrogates you about the task — scope, constraints, edge cases,
   acceptance criteria — and emits a shared-understanding summary shaped to feed the PRD.
2. **`/to-prd`** explores the repo, maps the testing seams, fills the PRD template, and
   publishes it as one GitHub issue labelled `prd`.
3. **`/to-issues`** breaks the PRD into **tracer-bullet vertical slices** (each cuts all
   layers and is demoable alone), publishing them in dependency order so each issue's
   `## Blocked by` section carries real `#N` refs.
4. **`/orchestrate [N] [--max K]`** then runs N rounds AFK: it picks the ready issues,
   builds each in parallel, merges the finished branches back in order, closes them, and
   files follow-ups for anything a reviewer flags.

The machinery behind each step — worktrees, the merger, the reviewer, label conventions —
is in [`plugins/workflow/README.md`](plugins/workflow/README.md); the per-command details
are in [`plugins/personal-tools/README.md`](plugins/personal-tools/README.md).

### Working a long session

The `workflow` plugin manages the context window with deliberate, **early** `/clear` and
`/handoff` instead of waiting for Claude Code's near-the-limit auto-compact. No hook or
agent can type a slash command, so the watchdog halts the agent and tells you the one
command to type. In short:

1. **Starting `/orchestrate` in a full window (≥ 60k tokens)** → an *advisory* nudge to run
   `/clear` first, then re-run `/orchestrate`, so the loop starts in fresh context. It never
   blocks — `/orchestrate` still runs if you proceed.
2. **Crossing ~250k mid-work** → a nudge to wrap up at a natural breaking point, commit, and
   run `/handoff`. It re-fires on context **climb** — every ~50k past the last fire — so a
   dropped first nudge self-recovers.
3. **`/handoff`** writes a rich handoff doc + the resume pointer (both keyed per-repo) and
   walks you through `/clear` into fresh context, where the plan auto-resumes.

The full hook wiring (`watchdog.sh`, `resume.sh`, `save-handoff.sh`, `suggest-docs.sh`),
the env-overridable thresholds, and the `PreCompact` handoff are documented in
[`plugins/workflow/README.md`](plugins/workflow/README.md#inside-the-watchdog).

## Install (full)

The full picture behind [Quickstart](#quickstart): what the audiences differ on, what the
installers touch, and the single-plugin path.

The two setups install the same plugins, the Playwright MCP, and a `gh` allowlist; they
differ only in audience:

| | Developer (`setup-dev`) | Non-developer (`setup-simple`) |
|---|---|---|
| global `CLAUDE.md` | technical conventions (`global/CLAUDE.md`) | plain-English, no-jargon contract |
| `model` | `opus` | Claude Code's default |
| caveman level | `full` (terse) | `lite` (a little more readable) |
| universal-ctags | installed (for code navigation) | not installed |

The installers back up any existing `~/.claude/CLAUDE.md` and `~/.claude/settings.json` before
touching them, and won't overwrite an existing global `CLAUDE.md` without `--force`.

### Option C — just one plugin (manual)

If you only want, say, the `workflow` plugin and will write your own `CLAUDE.md`:

```
/plugin marketplace add CrazyWillBear/my-dotclaude
/plugin install workflow@my-dotclaude
```

(Swap `workflow` for `personal-tools` for the slash-command kit.)

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
├── .claude-plugin/marketplace.json  # lists personal-tools + workflow
├── plugins/
│   ├── personal-tools/   # slash commands + subagents — see plugins/personal-tools/README.md
│   └── workflow/         # autonomous dev loop + context watchdog — see plugins/workflow/README.md
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
the `claude` CLI and use `curl`. Caveman and the Playwright MCP both need
Node ≥ 18 (Playwright runs via `npx`). The dev pipeline (`/to-prd`, `/to-issues`,
`/orchestrate`) needs the [`gh` CLI](https://cli.github.com) installed and
`gh auth login`'d; the setup just warns if it's absent.

> **Note:** caveman's verbosity level is set per *machine*, not per project (it has no
> per-project setting). The non-developer setup sets the machine default to `lite`.

### Notes & limits

- The orchestrate gate (the `/clear`-first nudge before `/orchestrate`) is **advisory** —
  it injects a hint but never `decision: block`s, so `/orchestrate` still runs if you
  proceed. The wrap nudge at 250k is likewise a model-directed instruction, not a hard
  runtime gate.
- `/orchestrate` runs subagents via the Agent tool on the main thread (subagents can't spawn
  subagents); the sonnet merger attempts to resolve merge conflicts gated by the done-check,
  but an **unresolvable conflict or a failed done-check stops and reports** rather than
  keeping an unverified resolution, leaving the worktree for inspection.

## License

[MIT](./LICENSE) © William Chastain
