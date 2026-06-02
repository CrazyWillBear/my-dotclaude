# my-dotclaude

My Claude Code setup, version-controlled so I can drop it back onto a fresh machine in
one command. It's also packaged so anyone can install the same code-review setup in
their own projects.

## What's in here

- **Global `CLAUDE.md`** (`home/CLAUDE.md` → `~/.claude/CLAUDE.md`) — my machine-wide
  working rules: test-driven, small diffs, ask before anything destructive, never
  commit secrets.
- **`team-code-review`** plugin — runs an automatic code review on every turn (plus an
  on-demand `/review`), routed through one shared, tunable rubric. *This is the repo
  root, installed as a plugin.*
- **`personal-tools`** plugin (`plugins/personal-tools/`) — my own slash commands and
  subagents (`/recap`, the `explainer` agent).
- **[caveman](https://github.com/JuliusBrussee/caveman)** — third-party plugin for
  terse output; installed alongside the above.
- **Setup scripts** (`setup/`) — one to restore my whole setup, two to bootstrap a
  project for anyone who wants the code-review combo.

## Restore my setup (me)

On a new machine, install the global `CLAUDE.md`, all my plugins, and my default model
in one go (user scope — not tied to any project):

```bash
curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-personal.sh | bash
```

It backs up any existing `~/.claude/CLAUDE.md` and `~/.claude/settings.json` before
touching them, and won't overwrite an existing global `CLAUDE.md` without `--force`.
Restart Claude Code afterward.

<details>
<summary>Windows (PowerShell) — untested, use at your own risk</summary>

The `.ps1` scripts print a warning and **do nothing unless you pass `-Continue`**.
Because `irm | iex` can't forward parameters, invoke as a scriptblock:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-personal.ps1))) -Continue
```
</details>

## Use it yourself (anyone)

You don't have to be me to use the code-review setup. These bootstrap a **single
project** (in the current directory) with `team-code-review` + caveman and a starting
`CLAUDE.md`. They do **not** install my global config or `personal-tools`.

There are two audiences:

| | Developer | Non-developer |
|---|---|---|
| `CLAUDE.md` | technical conventions | plain-English, no-jargon contract |
| `STYLEGUIDE.md` | yes (language-agnostic template) | — |
| caveman level | `full` (terse) | `lite` (a little more readable) |
| review output | severity-grouped (blocker / warning / nit) | "what I found, fixed, and why" |

### Option A — let Claude Code do it (no terminal needed)

Open Claude Code in your project folder and paste one of these:

**Non-developer:**

> I'm not a programmer and I want to start a project with your help. Please set up this
> folder for me: read the setup instructions at
> https://github.com/CrazyWillBear/my-dotclaude/blob/main/AGENT_SETUP.md and follow
> the **non-developer** steps. Install everything, set it up so you automatically check
> your own work, and explain what you're doing in plain English.

**Developer:**

> Set up this project with the team-code-review plugin. Read
> https://github.com/CrazyWillBear/my-dotclaude/blob/main/AGENT_SETUP.md and follow
> the **developer** steps: install the team-code-review and caveman plugins, add CLAUDE.md
> and STYLEGUIDE.md, and enable automatic code review on every turn.

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
overwrite an existing `CLAUDE.md`):

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
> actually edited, and won't re-review the same file twice in a session. For a
> non-developer project (`.claude/review-audience` = `plain`) the hook tells Claude to
> fix what it finds and report back in plain English instead of a severity list.

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
├── home/CLAUDE.md               # my global ~/.claude/CLAUDE.md
├── plugins/personal-tools/      # my personal commands + agents (a second plugin)
├── templates/                   # CLAUDE.md / STYLEGUIDE.md dropped into a project
│   ├── dev/  └── simple/
├── setup/                       # setup-personal / setup-dev / setup-simple (.sh + .ps1) + lib
└── AGENT_SETUP.md               # instructions Claude follows for the paste-a-prompt path
```

**Requirements:** `bash` and `python3` (the review hook uses python3 to parse the
transcript; if it's missing the hook fails open — it does nothing rather than blocking).
The setup scripts also need `git` and the `claude` CLI; the shell (`.sh`) scripts use
`curl`, while the PowerShell (`.ps1`) scripts use the built-in `Invoke-WebRequest`.
Caveman needs Node ≥ 18.

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
