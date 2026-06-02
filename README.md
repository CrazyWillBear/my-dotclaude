# team-code-review

A Claude Code plugin that runs an **automatic code review on every turn**, plus an
on-demand `/review` command. Both route through one shared, tunable rubric so the
whole team reviews to the same standard.

It ships with **setup scripts for two audiences**:

- **Developers** — code review + [caveman](https://github.com/JuliusBrussee/caveman)
  (terse output), plus technical `CLAUDE.md` + `STYLEGUIDE.md` conventions.
- **Non-developers** — the same safety net, but Claude explains itself in plain
  English and the review reports back as "here's what I fixed and why."

## What it does

When Claude finishes a turn in which files were edited, a `Stop` hook notices the
changed files and asks Claude to hand them to a dedicated **`code-reviewer` subagent**.
The subagent reviews in a fresh context (so it isn't grading its own work) against the
team rubric, covering:

- **Correctness & bugs**
- **Security**
- **Style & conventions**
- **Performance & simplicity**

> Hooks are plain shell commands and can't spawn a subagent themselves — so the hook
> *prompts the main agent* to launch the subagent. It only fires when files were
> actually edited, and won't re-review the same file twice in a session.

## Quick start

Pick your audience, then either let Claude install it for you (no terminal needed) or
run a one-line script. **Run setup inside the folder you want the project to live in.**

### Option A — let Claude Code do it (recommended for non-developers)

Open Claude Code in your project folder and paste one of these:

**Non-developer:**

> I'm not a programmer and I want to start a project with your help. Please set up this
> folder for me: read the setup instructions at
> https://github.com/CrazyWillBear/code-review-plugin/blob/main/AGENT_SETUP.md and follow
> the **non-developer** steps. Install everything, set it up so you automatically check
> your own work, and explain what you're doing in plain English.

**Developer:**

> Set up this project with the team-code-review plugin. Read
> https://github.com/CrazyWillBear/code-review-plugin/blob/main/AGENT_SETUP.md and follow
> the **developer** steps: install the team-code-review and caveman plugins, add CLAUDE.md
> and STYLEGUIDE.md, and enable automatic code review on every turn.

### Option B — run a script

**Developer** (macOS / Linux / WSL):

```bash
curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/code-review-plugin/main/setup/setup-dev.sh | bash
```

**Non-developer:**

```bash
curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/code-review-plugin/main/setup/setup-simple.sh | bash
```

**Windows (PowerShell):**

> ⚠️ **The PowerShell scripts are untested — use at your own risk.** They print this
> warning and **do nothing unless you pass `-Continue`**. Because `irm | iex` can't
> forward parameters, invoke them as a scriptblock (add `-Force` to overwrite an
> existing `CLAUDE.md`):

```powershell
# developer
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/CrazyWillBear/code-review-plugin/main/setup/setup-dev.ps1))) -Continue
# non-developer
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/CrazyWillBear/code-review-plugin/main/setup/setup-simple.ps1))) -Continue
```

Prefer to inspect first? Download, read, then run:

```powershell
irm https://raw.githubusercontent.com/CrazyWillBear/code-review-plugin/main/setup/setup-dev.ps1 -OutFile setup-dev.ps1
pwsh -File setup-dev.ps1 -Continue
```

Then **restart Claude Code** so it loads the plugins.

### Option C — just the plugin (manual)

If you only want the review plugin and will write your own `CLAUDE.md`:

```
/plugin marketplace add CrazyWillBear/code-review-plugin
/plugin install team-code-review@team-code-review
```

## What each setup does

Both run in the current directory and: initialize a git repo (if needed), install the
`team-code-review` and `caveman` plugins, drop in a `CLAUDE.md`, and write
`.claude/review-audience` (a marker the review hook reads).

| | Developer | Non-developer |
|---|---|---|
| `CLAUDE.md` | technical conventions | plain-English, no-jargon contract |
| `STYLEGUIDE.md` | yes (language-agnostic template) | — |
| caveman level | `full` (terse) | `lite` (a little more readable) |
| review output | severity-grouped (blocker / warning / nit) | "what I found, fixed, and why" |

> **Note:** caveman's verbosity level is set per *machine*, not per project (it has no
> per-project setting). The non-developer setup sets the machine default to `lite`.

## How it's built

```
code-review-plugin/
├── .claude-plugin/
│   ├── plugin.json              # plugin manifest
│   └── marketplace.json         # marketplace listing (for /plugin install)
├── hooks/hooks.json             # registers the Stop hook
├── scripts/review.sh            # finds edited files, emits the review prompt (audience-aware)
├── agents/code-reviewer.md      # the fresh-context reviewer subagent
├── skills/review-rubric/SKILL.md# the shared, tunable rubric (source of truth)
├── commands/review.md           # on-demand /review command
├── templates/                   # CLAUDE.md / STYLEGUIDE.md dropped into your project
│   ├── dev/  └── simple/
├── setup/                       # setup-dev / setup-simple scripts (.sh + .ps1) + lib
└── AGENT_SETUP.md               # instructions Claude follows for Option A
```

**Requirements:** `bash` and `python3` (the hook uses python3 to parse the transcript;
if it's missing the hook fails open — it does nothing rather than blocking). The setup
scripts also need `git` and the `claude` CLI; the shell (`.sh`) scripts use `curl`,
while the PowerShell (`.ps1`) scripts use the built-in `Invoke-WebRequest`. Caveman
needs Node ≥ 18.

## Tuning the rubric

`skills/review-rubric/SKILL.md` is the single source of truth. Add team-specific rules
(architecture conventions, banned patterns, required test coverage) under the relevant
section and open a PR. Both the auto-review and `/review` pick up the change immediately.

## Notes & limits

- The auto-review reviews each file **once per session**; if you edit it again later,
  re-run `/review`.
- `decision: block` is a strong instruction to the agent, not a hard runtime gate — it
  reliably triggers the review but is driven by the model.
- The auto-hook's scope is "files edited this session." `/review` can target a git ref
  or specific files instead.

## License

[MIT](./LICENSE) © William Chastain
