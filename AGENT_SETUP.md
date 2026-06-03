# Setup instructions for Claude Code

You are reading this because a user asked you to set up their Claude Code environment
from the **my-dotclaude** repo. Both paths install the same full kit **user-wide** (into
`~/.claude`, not a project folder); they differ only in audience. Keep the user informed
in plain language as you go:

- **Developer setup** — global technical `CLAUDE.md`, the code-review + personal-tools +
  caveman + agent-sdk-dev plugins, the Playwright MCP, a read-only `gh` allowlist,
  `model=opus`, and technical (severity-grouped) review output.
- **Non-developer setup** — the same kit, but with a plain-English global `CLAUDE.md`,
  caveman set to `lite`, plain-language review summaries, and the model left at Claude
  Code's default.

### Pick the path — ask first

**Do not guess.** Unless the user has already made it unambiguous, **ask one plain
question** and wait for the answer:

> Do you write code yourself, or would you rather I handle all the technical
> parts for you?
>
> - **I write code** → developer setup (technical review reports, `model=opus`).
> - **Handle it for me** → non-developer setup (plain-English summaries, no jargon).

Map their answer: writes code → **Developer setup**; wants it handled → **Non-developer
setup**. If they only say "set me up" with no other signal, ask this question first.

**Repository:** `https://github.com/CrazyWillBear/my-dotclaude`
**Raw base:** `https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main`

Both setups are **user-scope** — they touch `~/.claude`, not the current project. They do
not run `git init` or write any project files.

---

## Developer setup

**Preferred — run the script** (one command, does everything):

```bash
curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-dev.sh | bash
```

On Windows PowerShell (the `.ps1` scripts are untested; `-Continue` accepts that risk
— `irm | iex` can't pass parameters, so use a scriptblock):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-dev.ps1))) -Continue
```

**Fallback — if you cannot run that script**, do these yourself (all user-scope):

1. Back up `~/.claude/CLAUDE.md` and `~/.claude/settings.json` if they exist, then write
   `~/.claude/CLAUDE.md` from `<raw base>/global/CLAUDE.md` (don't overwrite an existing one
   without asking).
2. Merge `"model": "opus"` into `~/.claude/settings.json`, preserving other keys.
3. Install the plugins (prefer the `claude` CLI):
   ```bash
   claude plugin marketplace add CrazyWillBear/my-dotclaude
   claude plugin install team-code-review@my-dotclaude
   claude plugin install personal-tools@my-dotclaude
   claude plugin marketplace add JuliusBrussee/caveman
   claude plugin install caveman@caveman
   claude plugin marketplace add anthropics/claude-plugins-official
   claude plugin install agent-sdk-dev@claude-plugins-official
   ```
   If the `claude` CLI is unavailable, enable the plugins by editing
   `~/.claude/settings.json`: add the marketplaces under `extraKnownMarketplaces` and set
   each plugin to `true` under `enabledPlugins`.
4. Add the Playwright MCP server at user scope:
   ```bash
   claude mcp add playwright -s user -- npx @playwright/mcp@latest
   ```
5. For GitHub, allowlist the common read-only `gh` commands under `permissions.allow` in
   `~/.claude/settings.json` (e.g. `Bash(gh pr view:*)`, `Bash(gh pr list:*)`,
   `Bash(gh issue view:*)`, `Bash(gh repo view:*)`, `Bash(gh run view:*)` — **not**
   `gh api`, which can mutate), and tell them to install `gh` and run `gh auth login` if
   it isn't set up. (Claude uses `gh`, not a GitHub MCP.)

Review output defaults to technical with no marker, so there is nothing else to write.
Finish by telling the user to **restart Claude Code**.

---

## Non-developer setup

The user is **not** a programmer. Explain everything in plain English, do all the
technical work yourself, and confirm before anything that can't be undone.

**Preferred — run the script:**

```bash
curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-simple.sh | bash
```

On Windows PowerShell (the `.ps1` scripts are untested; `-Continue` accepts that risk
— `irm | iex` can't pass parameters, so use a scriptblock):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-simple.ps1))) -Continue
```

**Fallback — if you cannot run that script**, do these yourself (all user-scope):

1. Back up `~/.claude/CLAUDE.md` if it exists, then write `~/.claude/CLAUDE.md` from
   `<raw base>/templates/simple/CLAUDE.md`. Leave the model at Claude Code's default
   (don't set `model=opus`).
2. Install the same plugins and the Playwright MCP as the developer fallback above (steps
   3–4), and set up the read-only `gh` allowlist (step 5).
3. Make caveman a little less terse: set its default level to `lite` by writing
   `{"defaultMode":"lite"}` (merging if the file exists) into
   `~/.config/caveman/config.json` (on Windows: `%APPDATA%\caveman\config.json`; if
   `$XDG_CONFIG_HOME` is set, use `$XDG_CONFIG_HOME/caveman/config.json`).
4. Write `~/.claude/review-audience` containing the single word `plain` so reviews come
   back in plain language.

Finish by telling the user, in plain words, that everything is ready: they should close
and reopen Claude Code, then just describe what they want to build — you'll handle the
rest and double-check your own work for them.
