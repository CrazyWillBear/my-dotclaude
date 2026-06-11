# my-dotclaude

My Claude Code setup, version-controlled so I can drop it back onto a fresh machine in
one command. It's also packaged so anyone can install the same kit, tuned for either a
developer or a non-coder.

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
  subagents: `/explain` (whole-codebase overview), `/explain-dir` (one directory),
  `/commit` (review-and-commit the current changes), `/init-python-project` (scaffold
  Python docs), `/diagnose` (root-cause debugging), and the human-in-the-loop dev
  front-end `/grill-me` → `/to-prd` → `/to-issues` plus `/handoff`.
- **`workflow`** plugin (`plugins/workflow/`) — two things in one plugin: an autonomous
  dev loop (`/orchestrate`) that solves GitHub issues in parallel worktrees, and a
  context watchdog that drives deliberate, early `/clear` and `/handoff` as the window
  fills. (How both work in detail: [How it works](#how-it-works).)
- **[caveman](https://github.com/JuliusBrussee/caveman)** — third-party plugin for
  terse output; installed alongside the above.
- **[agent-sdk-dev](https://github.com/anthropics/claude-plugins-official)** — Anthropic's
  official plugin for scaffolding Claude Agent SDK apps (`/new-sdk-app`); installed
  alongside the above.
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
   files follow-ups for anything a reviewer flags. (The machinery behind this —
   worktrees, the merger, the reviewer — is in
   [Inside the dev loop](#inside-the-dev-loop).)

### Working a long session

The `workflow` plugin manages the context window with deliberate, **early** `/clear` and
`/handoff` instead of waiting for Claude Code's near-the-limit auto-compact. No hook or
agent can type a slash command, so the watchdog halts the agent and tells you the one
command to type, then handles everything around it. Three steps over a long plan:

1. **Plan start (`/clear`).** When you approve a plan and the window is already large
   (≥ 60k tokens), the watchdog saves a handoff and halts *before* any code is written:
   run `/clear`, then send `go`. The plan re-injects into fresh context.
2. **Mid-plan wrap (commit + `/handoff`).** Once the window crosses ~100k, it nudges you to
   wrap up soon at a natural breaking point, commit, and run `/handoff`. The nudge re-fires
   on context **climb** — every ~30k tokens past the last fire (100k → 130k → 160k …) — so a
   dropped or unseen first nudge self-recovers instead of staying silent for the session.
3. **The handoff (`/handoff`).** `/handoff` writes a rich handoff doc plus the resume pointer
   (both keyed per-repo) and walks you through `/clear` into fresh context, where the plan
   auto-resumes. `/clear` and `/compact` re-arm the cycle from the 100k floor.

## How it works

The machinery behind the two `workflow` features, plus the conventions the pieces agree on.

### Inside the dev loop

`/orchestrate` runs rounds of *parallel* issue-solving: an opus orchestrator picks the
ready set, fans out sonnet implementers in **isolated git worktrees**, hands the completed
branches to a **sonnet merger** that merges in dependency order and resolves conflicts
under the done-check, then an **fable reviewer** files blocking follow-up issues.

In detail, each round: it computes the **ready set** (every blocker closed, `hitl` issues
skipped), spins up to K isolated worktrees, fans out sonnet implementers in parallel,
hands the completed branches to the sonnet merger that merges them back in topological
order (resolving conflicts under the done-check), closes the issues, and runs the opus
reviewer that files `review-fix` follow-ups and wires them into dependents' `## Blocked by`
so a fix always lands before its dependents start. The reviewer reads the merged diff for
correctness, security, broken tests, and **stale docs** (a code change that left its
README / `CLAUDE.md` describing the old behavior) — it **never edits code**.

The reviewer is a backstop, not a fixer, and the feedback path is **async**: each
`review-fix` is itself a `ready-for-agent` issue that a *fresh implementer builds in a
later round*. So a single `/orchestrate` (N=1) **files** the follow-ups but doesn't build
them — they show up as open issues; run another round (`/orchestrate 2`, or re-run) to let
the loop pick them up and close them.

One branch + worktree per issue (`issue-<N>` at `.worktrees/issue-<N>`); merge order is a
topological sort of `Blocked by`. The merger attempts to resolve conflicts gated by the
done-check, and an **unresolvable conflict or a red check stops and reports**. PR merges
stay a human decision — the loop never merges PRs.

### Inside the watchdog

The watchdog (`scripts/watchdog.sh`) drives the three-step flow above off token
thresholds, and a `SessionStart` hook (`scripts/resume.sh`) re-injects the in-flight plan
around each `/clear` or `/compact`. The plan-start gate is keyed by the plan's
`ExitPlanMode` id, so it re-fires for each *new* plan you approve later in the same session
(and across `/clear` / `/compact`), not just the first.

**Any `/compact` is safe too.** A `PreCompact` hook writes a handoff before *every*
compaction — a manual `/compact` you run yourself or Claude Code's auto-compact — so the
plan re-injects and the wrap cycle re-arms either way.

A separate **docs-staleness** Stop hook (`scripts/suggest-docs.sh`) gives a soft nudge when
a batch changed code but touched no docs (`*.md`), so usage/behavior docs get folded into
the same commit. It's advisory, deduped once per `HEAD`, and silent the moment any `.md` is
in the batch. This is the *interactive*-session counterpart to the reviewer's stale-docs
check inside `/orchestrate`: the Stop hook nudges you while you work; the reviewer is the
AFK backstop that files a `review-fix` when an autonomous round leaves a doc behind.

Thresholds are env-overridable (`WORKFLOW_PLANGATE_TOKENS`, `WORKFLOW_NUDGE_TOKENS`; the
docs nudge takes optional `DOCS_FILE_THRESHOLD` / `DOCS_LINE_THRESHOLD`, off by default). It
fails open: missing `python3`/`git` or any error just means it does nothing.

### Conventions

- **Labels:** `prd` (PRD tracking issue), `ready-for-agent` (orchestrate-eligible), `hitl`
  (needs a human, skipped by the loop), `review-fix` (reviewer follow-up; also
  `ready-for-agent`).
- **Dependencies:** each issue body ends with a `## Blocked by` section listing bare `#N`
  refs (one per line) or the literal `None - can start immediately`. An issue is *ready*
  iff every blocker is **closed**.

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
CLI) allowlist**. **For GitHub I use `gh`, not a GitHub MCP server** — on a machine with
`gh`, the CLI plus Bash already cover the whole GitHub API, so a GitHub MCP would only add
a managed token and per-session tool-schema overhead. The allowlist covers the common
**read-only** `gh` commands (PR / issue / repo / run reads) **plus** the four
**issue-write** commands the dev loop needs — `gh issue create`, `gh issue edit`,
`gh issue comment`, `gh issue close` — so `/to-prd`, `/to-issues`, and `/orchestrate` can
file and update issues without prompting. It deliberately **excludes `gh api`** (which can
POST/DELETE any endpoint) and **`gh pr merge`** (merges stay a human decision). The setup
warns if `gh` isn't installed or logged in. Playwright stays an MCP because it has no CLI
equivalent.

## Reference

### Layout

```
my-dotclaude/
├── .claude-plugin/marketplace.json  # lists personal-tools + workflow
├── plugins/
│   ├── personal-tools/             # my personal skills + agents
│   │   ├── skills/                 # /commit, /diagnose, /explain, /explain-dir,
│   │   │                           #   /init-python-project, /grill-me, /to-prd,
│   │   │                           #   /to-issues, /handoff
│   │   ├── agents/                 # commit (isolated committer), explain-dir (haiku)
│   │   └── templates/              # CLAUDE.md + STYLEGUIDE.md for the init-* skills
│   └── workflow/                   # the autonomous dev loop + context watchdog
│       ├── skills/orchestrate/SKILL.md  # /orchestrate — the parallel issue-solving loop
│       ├── agents/implementer.md   # sonnet implementer (works in one worktree)
│       ├── agents/merger.md        # sonnet merger (merges branches in dep order, resolves conflicts)
│       ├── agents/reviewer.md      # opus caveman-style reviewer (files follow-ups)
│       ├── scripts/watchdog.sh     # thresholds: orchestrate /clear gate, climb-refiring wrap nudge
│       ├── scripts/resume.sh       # SessionStart: re-injects the per-repo-keyed handoff after /clear or /compact
│       ├── scripts/suggest-docs.sh # Stop: soft nudge when a batch changed code but no docs
│       ├── scripts/save-handoff.sh # shared handoff writer
│       └── tests/                  # watchdog + resume + suggest-docs tests
├── global/CLAUDE.md                 # my global ~/.claude/CLAUDE.md (developer setup)
├── global/CLAUDE.simple.md          # plain-English global CLAUDE.md (installed by setup-simple)
├── setup/                           # setup-dev.sh / setup-simple.sh + lib
└── AGENT_SETUP.md                   # instructions Claude follows for the paste-a-prompt path
```

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

- `decision: block` (used by the watchdog's plan-start gate) is a strong instruction to the
  agent, not a hard runtime gate — it reliably halts but is driven by the model.
- `/orchestrate` runs subagents via the Task tool on the main thread (subagents can't spawn
  subagents); the sonnet merger attempts to resolve merge conflicts gated by the done-check,
  but an **unresolvable conflict or a failed done-check stops and reports** rather than
  keeping an unverified resolution, leaving the worktree for inspection.

## License

[MIT](./LICENSE) © William Chastain
