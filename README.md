# my-dotclaude

My Claude Code setup, version-controlled so I can drop it back onto a fresh machine in
one command. It's also packaged so anyone can install the same kit, with the review output
tuned for either a developer or a non-coder.

## What's in here

- **Global `CLAUDE.md`** (`global/CLAUDE.md` → `~/.claude/CLAUDE.md`) — my machine-wide
  working rules: test-driven, small diffs, ask before anything destructive, never
  commit secrets. (The non-developer kit installs a plain-English `CLAUDE.md` instead.)
- **`my-code-review`** plugin (`plugins/my-code-review/`) — runs an automatic code
  review on every turn (plus an on-demand `/review`), routed through one shared, tunable
  rubric.
- **`personal-tools`** plugin (`plugins/personal-tools/`) — my own slash commands and
  subagents (`/explain` for a whole-codebase overview, `/explain-dir` for one directory,
  `/commit` to review-and-commit the current changes).
- **`context-flow`** plugin (`plugins/context-flow/`) — a context watchdog that drives
  deliberate, early `/clear` and `/compact` as the window fills, and auto-resumes the
  in-flight plan around each command.
- **[caveman](https://github.com/JuliusBrussee/caveman)** — third-party plugin for
  terse output; installed alongside the above.
- **[agent-sdk-dev](https://github.com/anthropics/claude-plugins-official)** — Anthropic's
  official plugin for scaffolding Claude Agent SDK apps (`/new-sdk-app`); installed
  alongside the above.
- **Setup scripts** (`setup/`) — two user-wide installers: `setup-dev` (developer) and
  `setup-simple` (non-developer). Both install the same kit into `~/.claude`.

## Install

Both setups are **user-wide** — they install into `~/.claude`, not a project folder, so the
kit follows you across every project. They install the same plugins, the Playwright MCP, and
a read-only `gh` allowlist; they differ only in audience:

| | Developer (`setup-dev`) | Non-developer (`setup-simple`) |
|---|---|---|
| global `CLAUDE.md` | technical conventions (`global/CLAUDE.md`) | plain-English, no-jargon contract |
| `model` | `opus` | Claude Code's default |
| caveman level | `full` (terse) | `lite` (a little more readable) |
| review output | severity-grouped (blocker / warning / nit) | "what I found, fixed, and why" |

Review output is technical by default; the non-developer setup writes `~/.claude/review-audience`
= `plain` to switch it. Any single project can override the user-wide default by writing
`plain` or `technical` to its own `<project>/.claude/review-audience`.

The installers back up any existing `~/.claude/CLAUDE.md` and `~/.claude/settings.json` before
touching them, and won't overwrite an existing global `CLAUDE.md` without `--force`. Restart
Claude Code afterward.

They also add the **Playwright MCP** server and a **read-only `gh` (GitHub CLI) allowlist**.
**For GitHub I use `gh`, not a GitHub MCP server** — on a machine with `gh`, the CLI plus Bash
already cover the whole GitHub API (`gh api` reaches any endpoint), so a GitHub MCP would only
add a managed token and per-session tool-schema overhead for structured-tool ergonomics I don't
need. So the setup instead allowlists the common read-only `gh` commands (PR / issue / repo /
run reads — deliberately **not** `gh api`, which can mutate) so they don't prompt, and warns if
`gh` isn't installed or logged in. Playwright stays an MCP because it has no CLI equivalent.

### Option A — let Claude Code do it (no terminal needed)

Open Claude Code and paste one of these:

**Non-developer:**

> I'm not a programmer and I want to start a project with your help. Please set up Claude
> Code for me: read the setup instructions at
> https://github.com/CrazyWillBear/my-dotclaude/blob/main/AGENT_SETUP.md and follow
> the **non-developer** steps. Install everything, set it up so you automatically check
> your own work, and explain what you're doing in plain English.

**Developer:**

> Set up Claude Code with my full kit. Read
> https://github.com/CrazyWillBear/my-dotclaude/blob/main/AGENT_SETUP.md and follow
> the **developer** steps: install the plugins, the Playwright MCP, and the `gh` allowlist,
> write the global CLAUDE.md, and enable automatic code review on every turn.

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

### Option C — just the review plugin (manual)

If you only want `my-code-review` and will write your own `CLAUDE.md`:

```
/plugin marketplace add CrazyWillBear/my-dotclaude
/plugin install my-code-review@my-dotclaude
```

## How the auto-review works

When Claude finishes a turn in which files were edited, a `Stop` hook notices the
changed files and asks Claude to hand them to a dedicated **`code-reviewer` subagent**.
The subagent reviews in a fresh context (so it isn't grading its own work) against the
team rubric, covering **correctness & bugs**, **security**, **style & conventions**, and
**performance & simplicity**.

> Hooks are plain shell commands and can't spawn a subagent themselves — so the hook
> *prompts the main agent* to launch the subagent. It only fires when files were
> actually edited, and won't re-review the same file twice in a session. When the review
> audience is `plain` (the non-developer setup writes `~/.claude/review-audience` = `plain`,
> or a project can set its own) the hook tells Claude to fix what it finds and report back
> in plain English instead of a severity list.

A second `Stop` hook (`plugins/my-code-review/scripts/suggest-commit.sh`) runs **before** the reviewer and is
purely advisory: when the uncommitted tracked work looks worth a commit — a large diff
(≥ 3 files or ≥ 80 changed lines) **or** a plan that was approved and then implemented — it
softly suggests committing the batch (run `/commit` or commit by hand). The two signals
collapse into **one** suggestion, and it's deduped **once per batch** (silent until the next
commit moves `HEAD`). It never commits anything itself, and never suppresses the review —
they're independent concerns. Because the batch may already be committed by the time the
reviewer runs, the `code-reviewer` reads `git diff HEAD` when the tree is dirty and falls
back to `git show HEAD` when it's clean.

## Keeping context fresh (context-flow)

The `context-flow` plugin (`plugins/context-flow/`) manages the context window with
deliberate, **early** `/clear` and `/compact` instead of waiting for Claude Code's
near-the-limit auto-compact. No hook or agent can type a slash command, so the watchdog
halts the agent and tells you the one command to type, then handles everything around it.
Three steps over a long plan:

1. **Plan start (`/clear`).** When you approve a plan and the window is already large
   (≥ 60k tokens), the watchdog saves a handoff and halts *before* any code is written:
   run `/clear`, then send `go`. The plan re-injects into fresh context. The gate is keyed
   by the plan's `ExitPlanMode` id, so it re-fires for each *new* plan you approve later in
   the same session (and across `/clear` / `/compact`), not just the first.
2. **Mid-plan wrap (commit).** Once the window crosses ~120k, it nudges you to wrap up at
   a natural breaking point and commit — the code review runs normally on that wrap-up
   commit (context-flow no longer defers it).
3. **After review (`/compact`).** On the next clean stop after the wrap commit, it prompts
   you to run `/compact` (once the review and any fixes are in), then send `continue`. The
   plan re-injects into the compacted thread, and a later climb back over the threshold
   repeats the wrap → `/compact` cycle.

A separate **docs-staleness** Stop hook (`scripts/suggest-docs.sh`) gives a soft nudge when
a batch changed code but touched no docs (`*.md`), so usage/behavior docs get folded into
the same commit. It's advisory, deduped once per `HEAD`, and silent the moment any `.md` is
in the batch.

Thresholds are env-overridable (`CONTEXT_FLOW_PLANGATE_TOKENS`,
`CONTEXT_FLOW_NUDGE_TOKENS`; the docs nudge takes optional `DOCS_FILE_THRESHOLD` /
`DOCS_LINE_THRESHOLD`, off by default). As with the review hook, it
fails open: missing `python3`/`git` or any error just means it does nothing.

## Layout

```
my-dotclaude/
├── .claude-plugin/marketplace.json  # lists my-code-review + personal-tools + context-flow
├── plugins/
│   ├── my-code-review/            # the auto-review plugin (a plugin)
│   │   ├── .claude-plugin/plugin.json
│   │   ├── hooks/hooks.json         # registers the Stop hooks (suggest-commit, then review)
│   │   ├── scripts/suggest-commit.sh# advisory: nudges to commit a big/completed batch (runs first)
│   │   ├── scripts/review.sh        # finds edited files, emits the review prompt (audience-aware)
│   │   ├── agents/code-reviewer.md  # the fresh-context reviewer subagent
│   │   ├── skills/review-rubric/SKILL.md  # the shared, tunable rubric (source of truth)
│   │   ├── commands/review.md       # on-demand /review command
│   │   └── tests/                   # hook + history tests
│   ├── context-flow/              # the context watchdog (early /clear + /compact, plan auto-resume)
│   │   ├── scripts/watchdog.sh      # thresholds: plan-start /clear gate, wrap nudge, post-wrap /compact prompt
│   │   ├── scripts/resume.sh        # SessionStart: re-injects the plan after /clear or /compact
│   │   ├── scripts/suggest-docs.sh  # Stop: soft nudge when a batch changed code but no docs
│   │   ├── scripts/save-handoff.sh  # shared handoff writer
│   │   └── tests/                   # watchdog + resume + suggest-docs tests
│   └── personal-tools/             # my personal skills + agents (a second plugin); holds the project-scaffold templates + /init-python-project
├── global/CLAUDE.md                 # my global ~/.claude/CLAUDE.md (developer setup)
├── templates/simple/CLAUDE.md       # plain-English global CLAUDE.md (installed by setup-simple)
├── setup/                           # setup-dev / setup-simple (.sh + .ps1) + lib
└── AGENT_SETUP.md                   # instructions Claude follows for the paste-a-prompt path
```

**Requirements:** `bash` and `python3` (the review hook uses python3 to parse the
transcript; if it's missing the hook fails open — it does nothing rather than blocking).
The setup scripts also need the `claude` CLI; the shell (`.sh`) scripts use `curl`, while
the PowerShell (`.ps1`) scripts use the built-in `Invoke-WebRequest`.
Caveman and the Playwright MCP both need Node ≥ 18 (Playwright runs via `npx`). GitHub
access is optional and uses the [`gh` CLI](https://cli.github.com) — install it and run
`gh auth login` to enable the allowlisted commands; the setup just warns if it's absent.

> **Note:** caveman's verbosity level is set per *machine*, not per project (it has no
> per-project setting). The non-developer setup sets the machine default to `lite`.

## Tuning the rubric

`plugins/my-code-review/skills/review-rubric/SKILL.md` is the single source of truth. Add rules (architecture
conventions, banned patterns, required test coverage) under the relevant section. Both
the auto-review and `/review` pick up the change immediately.

## Notes & limits

- The auto-review reviews each file **once per session**; if you edit it again later,
  re-run `/review`.
- `decision: block` is a strong instruction to the agent, not a hard runtime gate — it
  reliably triggers the review but is driven by the model.
- The PowerShell scripts are **untested** and gated behind `-Continue`.

## License

[MIT](./LICENSE) © William Chastain
