# my-dotclaude

My Claude Code setup, version-controlled so I can drop it back onto a fresh machine in
one command. It's also packaged so anyone can install the same kit, with the review output
tuned for either a developer or a non-coder.

## What's in here

- **Global `CLAUDE.md`** (`global/CLAUDE.md` → `~/.claude/CLAUDE.md`) — my machine-wide
  working rules: test-driven, small diffs, ask before anything destructive, never
  commit secrets. (The non-developer kit installs a plain-English `CLAUDE.md` instead.)
- **`team-code-review`** plugin — runs an automatic code review on every turn (plus an
  on-demand `/review`), routed through one shared, tunable rubric. *This is the repo
  root, installed as a plugin.*
- **`personal-tools`** plugin (`plugins/personal-tools/`) — my own slash commands and
  subagents (`/explain` for a whole-codebase overview, `/explain-dir` for one directory).
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

If you only want `team-code-review` and will write your own `CLAUDE.md`:

```
/plugin marketplace add CrazyWillBear/my-dotclaude
/plugin install team-code-review@my-dotclaude
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

## Layout

```
my-dotclaude/
├── .claude-plugin/
│   ├── plugin.json              # team-code-review manifest (repo root IS this plugin)
│   └── marketplace.json         # lists team-code-review + personal-tools
├── hooks/hooks.json             # registers the Stop hook
├── scripts/review.sh            # finds edited files, emits the review prompt (audience-aware)
├── agents/code-reviewer.md      # the fresh-context reviewer subagent
├── skills/review-rubric/SKILL.md# the shared, tunable rubric (source of truth)
├── commands/review.md           # on-demand /review command
├── global/CLAUDE.md             # my global ~/.claude/CLAUDE.md (developer setup)
├── plugins/personal-tools/      # my personal skills + agents (a second plugin); holds the project-scaffold templates + /init-python-project
├── templates/simple/CLAUDE.md   # plain-English global CLAUDE.md (installed by setup-simple)
├── setup/                       # setup-dev / setup-simple (.sh + .ps1) + lib
└── AGENT_SETUP.md               # instructions Claude follows for the paste-a-prompt path
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

`skills/review-rubric/SKILL.md` is the single source of truth. Add rules (architecture
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
