# my-dotclaude

My Claude Code setup, version-controlled so I can drop it back onto a fresh machine in
one command. It's also packaged so anyone can install the same kit, tuned for either a
developer or a non-coder.

## What's in here

- **Global `CLAUDE.md`** (`global/CLAUDE.md` → `~/.claude/CLAUDE.md`) — my machine-wide
  working rules: test-driven, small diffs, ask before anything destructive, never
  commit secrets. (The non-developer kit installs a plain-English `CLAUDE.md` instead.)
- **`personal-tools`** plugin (`plugins/personal-tools/`) — my own slash commands and
  subagents: `/explain` (whole-codebase overview), `/explain-dir` (one directory),
  `/commit` (review-and-commit the current changes), `/init-python-project` (scaffold
  Python docs), `/diagnose` (root-cause debugging), and the human-in-the-loop dev
  front-end `/grill-me` → `/to-prd` → `/to-issues` plus `/handoff`.
- **`workflow`** plugin (`plugins/workflow/`) — two things in one plugin:
  1. **An autonomous dev loop** (`/orchestrate`) that runs rounds of *parallel*
     issue-solving — an opus orchestrator picks the ready set, fans out sonnet
     implementers in **isolated git worktrees**, merges in dependency order, then an
     **opus reviewer** files blocking follow-up issues.
  2. **A context watchdog** that drives deliberate, early `/clear` and `/handoff` as the
     window fills, and auto-resumes the in-flight plan around each command.
- **[caveman](https://github.com/JuliusBrussee/caveman)** — third-party plugin for
  terse output; installed alongside the above.
- **[agent-sdk-dev](https://github.com/anthropics/claude-plugins-official)** — Anthropic's
  official plugin for scaffolding Claude Agent SDK apps (`/new-sdk-app`); installed
  alongside the above.
- **Setup scripts** (`setup/`) — two user-wide installers: `setup-dev` (developer) and
  `setup-simple` (non-developer). Both install the same kit into `~/.claude`.

## The dev pipeline

One human-in-the-loop front-end and one AFK loop, with **GitHub Issues as the tracker**
(via the `gh` CLI):

1. **`/grill-me`** interrogates you about the task — scope, constraints, edge cases,
   acceptance criteria — and emits a shared-understanding summary shaped to feed the PRD.
2. **`/to-prd`** explores the repo, maps the testing seams, fills the PRD template, and
   publishes it as one GitHub issue labelled `ready-for-agent`.
3. **`/to-issues`** breaks the PRD into **tracer-bullet vertical slices** (each cuts all
   layers and is demoable alone), publishing them in dependency order so each issue's
   `## Blocked by` section carries real `#N` refs.
4. **`/orchestrate [N] [--max K]`** then runs N rounds AFK: it computes the **ready set**
   (every blocker closed, `hitl` issues skipped), spins up to K isolated worktrees, fans
   out sonnet implementers in parallel, merges branches back in topological order, closes
   the issues, and runs an opus reviewer that files `review-fix` follow-ups and wires them
   into dependents' `## Blocked by` so a fix always lands before its dependents start.

Shared conventions the pieces agree on:

- **Labels:** `ready-for-agent` (orchestrate-eligible), `hitl` (needs a human, skipped by
  the loop), `review-fix` (reviewer follow-up; also `ready-for-agent`).
- **Dependencies:** each issue body ends with a `## Blocked by` section listing bare `#N`
  refs (one per line) or the literal `None - can start immediately`. An issue is *ready*
  iff every blocker is **closed**.
- **Worktrees:** one branch + worktree per issue (`issue-<N>` at `.worktrees/issue-<N>`);
  merge order is a topological sort of `Blocked by`; conflicts **stop and report**, never
  auto-resolve. PR merges stay a human decision — the loop never merges PRs.

## Install

Both setups are **user-wide** — they install into `~/.claude`, not a project folder, so the
kit follows you across every project. They install the same plugins, the Playwright MCP, and
a `gh` allowlist; they differ only in audience:

| | Developer (`setup-dev`) | Non-developer (`setup-simple`) |
|---|---|---|
| global `CLAUDE.md` | technical conventions (`global/CLAUDE.md`) | plain-English, no-jargon contract |
| `model` | `opus` | Claude Code's default |
| caveman level | `full` (terse) | `lite` (a little more readable) |

The installers back up any existing `~/.claude/CLAUDE.md` and `~/.claude/settings.json` before
touching them, and won't overwrite an existing global `CLAUDE.md` without `--force`. Restart
Claude Code afterward.

They also add the **Playwright MCP** server and a **`gh` (GitHub CLI) allowlist**. **For
GitHub I use `gh`, not a GitHub MCP server** — on a machine with `gh`, the CLI plus Bash
already cover the whole GitHub API, so a GitHub MCP would only add a managed token and
per-session tool-schema overhead. The allowlist covers the common **read-only** `gh`
commands (PR / issue / repo / run reads) **plus** the four **issue-write** commands the dev
loop needs — `gh issue create`, `gh issue edit`, `gh issue comment`, `gh issue close` — so
`/to-prd`, `/to-issues`, and `/orchestrate` can file and update issues without prompting. It
deliberately **excludes `gh api`** (which can POST/DELETE any endpoint) and **`gh pr merge`**
(merges stay a human decision). The setup warns if `gh` isn't installed or logged in.
Playwright stays an MCP because it has no CLI equivalent.

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

<details>
<summary>Windows (PowerShell) — untested, use at your own risk</summary>

The `.ps1` scripts print a warning and **do nothing unless you pass `-Continue`**.
Because `irm | iex` can't forward parameters, invoke as a scriptblock (add `-Force` to
overwrite an existing `~/.claude/CLAUDE.md`):

```powershell
# developer
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-dev.ps1))) -Continue
# non-developer
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-simple.ps1))) -Continue
```
</details>

Then **restart Claude Code** so it loads the plugins.

### Option C — just one plugin (manual)

If you only want, say, the `workflow` plugin and will write your own `CLAUDE.md`:

```
/plugin marketplace add CrazyWillBear/my-dotclaude
/plugin install workflow@my-dotclaude
```

(Swap `workflow` for `personal-tools` for the slash-command kit.)

## Keeping context fresh (workflow)

The `workflow` plugin manages the context window with deliberate, **early** `/clear` and
`/handoff` instead of waiting for Claude Code's near-the-limit auto-compact. No hook or
agent can type a slash command, so the watchdog halts the agent and tells you the one
command to type, then handles everything around it. Three steps over a long plan:

1. **Plan start (`/clear`).** When you approve a plan and the window is already large
   (≥ 60k tokens), the watchdog saves a handoff and halts *before* any code is written:
   run `/clear`, then send `go`. The plan re-injects into fresh context. The gate is keyed
   by the plan's `ExitPlanMode` id, so it re-fires for each *new* plan you approve later in
   the same session (and across `/clear` / `/compact`), not just the first.
2. **Mid-plan wrap (commit).** Once the window crosses ~100k, it nudges you to wrap it up
   soon at a natural breaking point and commit.
3. **After the wrap (`/handoff`).** On the next clean stop after the wrap commit, it
   prompts you to run `/handoff`, which writes a rich handoff doc plus the resume pointer
   and walks you through `/clear` into fresh context, where the plan auto-resumes. A later
   climb back over the threshold repeats the wrap → `/handoff` cycle.

**Any `/compact` is safe too.** A `PreCompact` hook writes a handoff before *every*
compaction — a manual `/compact` you run yourself or Claude Code's auto-compact — so the
plan re-injects and the wrap cycle re-arms either way.

A separate **docs-staleness** Stop hook (`scripts/suggest-docs.sh`) gives a soft nudge when
a batch changed code but touched no docs (`*.md`), so usage/behavior docs get folded into
the same commit. It's advisory, deduped once per `HEAD`, and silent the moment any `.md` is
in the batch.

Thresholds are env-overridable (`WORKFLOW_PLANGATE_TOKENS`, `WORKFLOW_NUDGE_TOKENS`; the
docs nudge takes optional `DOCS_FILE_THRESHOLD` / `DOCS_LINE_THRESHOLD`, off by default). It
fails open: missing `python3`/`git` or any error just means it does nothing.

## Layout

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
│       ├── agents/reviewer.md      # opus caveman-style reviewer (files follow-ups)
│       ├── scripts/watchdog.sh     # thresholds: plan-start /clear gate, wrap nudge, /handoff prompt
│       ├── scripts/resume.sh       # SessionStart: re-injects the plan after /clear or /compact
│       ├── scripts/suggest-docs.sh # Stop: soft nudge when a batch changed code but no docs
│       ├── scripts/save-handoff.sh # shared handoff writer
│       └── tests/                  # watchdog + resume + suggest-docs tests
├── global/CLAUDE.md                 # my global ~/.claude/CLAUDE.md (developer setup)
├── templates/simple/CLAUDE.md       # plain-English global CLAUDE.md (installed by setup-simple)
├── setup/                           # setup-dev / setup-simple (.sh + .ps1) + lib
└── AGENT_SETUP.md                   # instructions Claude follows for the paste-a-prompt path
```

**Requirements:** `bash` and `python3` (the watchdog uses python3 to parse the transcript;
if it's missing the hook fails open — it does nothing rather than blocking). The setup
scripts also need the `claude` CLI; the shell (`.sh`) scripts use `curl`, while the
PowerShell (`.ps1`) scripts use the built-in `Invoke-WebRequest`. Caveman and the Playwright
MCP both need Node ≥ 18 (Playwright runs via `npx`). The dev pipeline (`/to-prd`,
`/to-issues`, `/orchestrate`) needs the [`gh` CLI](https://cli.github.com) installed and
`gh auth login`'d; the setup just warns if it's absent.

> **Note:** caveman's verbosity level is set per *machine*, not per project (it has no
> per-project setting). The non-developer setup sets the machine default to `lite`.

## Notes & limits

- `decision: block` (used by the watchdog's plan-start gate) is a strong instruction to the
  agent, not a hard runtime gate — it reliably halts but is driven by the model.
- `/orchestrate` runs subagents via the Task tool on the main thread (subagents can't spawn
  subagents); merge conflicts or a failed done-check **stop and report** rather than
  auto-resolving, leaving the worktree for inspection.
- The PowerShell scripts are **untested** and gated behind `-Continue`.

## License

[MIT](./LICENSE) © William Chastain
