# Setup instructions for Claude Code

You are reading this because a user asked you to set up this project for them using
the **team-code-review** plugin. Do the steps below for the audience they asked for
(developer or non-developer). Keep the user informed in plain language as you go.

**Repository:** `https://github.com/CrazyWillBear/code-review-plugin`
**Raw base:** `https://raw.githubusercontent.com/CrazyWillBear/code-review-plugin/main`

Work in the user's **current project directory**. Do not create a new subfolder
unless they ask.

---

## Developer setup

**Preferred — run the script** (one command, does everything):

```bash
curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/code-review-plugin/main/setup/setup-dev.sh | bash
```

On Windows PowerShell (the `.ps1` scripts are untested; `-Continue` accepts that risk
— `irm | iex` can't pass parameters, so use a scriptblock):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/CrazyWillBear/code-review-plugin/main/setup/setup-dev.ps1))) -Continue
```

**Fallback — if you cannot run that script**, do these steps yourself with your tools:

1. If the directory is not a git repo, run `git init`.
2. Write `CLAUDE.md` from `<raw base>/templates/dev/CLAUDE.md` (don't overwrite an
   existing one without asking).
3. Write `STYLEGUIDE.md` from `<raw base>/templates/dev/STYLEGUIDE.md`.
4. Create `.claude/review-audience` containing the single word `technical`.
5. Install the plugins (prefer the `claude` CLI):
   ```bash
   claude plugin marketplace add CrazyWillBear/code-review-plugin
   claude plugin install team-code-review@team-code-review
   claude plugin marketplace add JuliusBrussee/caveman
   claude plugin install caveman@caveman
   ```
   If the `claude` CLI is unavailable, enable them by editing the user's
   `~/.claude/settings.json`: add both marketplaces under `extraKnownMarketplaces`
   and set `"team-code-review@team-code-review": true` and `"caveman@caveman": true`
   under `enabledPlugins`.

Finish by telling the user to **restart Claude Code**, and to fill in the `<...>`
placeholders in `CLAUDE.md` / `STYLEGUIDE.md` with their project's real test, lint,
and typecheck commands.

---

## Non-developer setup

The user is **not** a programmer. Explain everything in plain English, do all the
technical work yourself, and confirm before anything that can't be undone.

**Preferred — run the script:**

```bash
curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/code-review-plugin/main/setup/setup-simple.sh | bash
```

On Windows PowerShell (the `.ps1` scripts are untested; `-Continue` accepts that risk
— `irm | iex` can't pass parameters, so use a scriptblock):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/CrazyWillBear/code-review-plugin/main/setup/setup-simple.ps1))) -Continue
```

**Fallback — if you cannot run that script**, do these steps yourself:

1. If the directory is not a git repo, run `git init` (so their work is always saved).
2. Write `CLAUDE.md` from `<raw base>/templates/simple/CLAUDE.md`. Do **not** add a
   STYLEGUIDE.md.
3. Create `.claude/review-audience` containing the single word `plain`.
4. Install the plugins (same commands as the developer fallback above:
   `team-code-review@team-code-review` and `caveman@caveman`).
5. Make caveman a little less terse for them: set its default level to `lite` by
   writing `{"defaultMode":"lite"}` (merging if the file exists) into
   `~/.config/caveman/config.json` (on Windows: `%APPDATA%\caveman\config.json`; if
   `$XDG_CONFIG_HOME` is set, use `$XDG_CONFIG_HOME/caveman/config.json`).

Finish by telling the user, in plain words, that everything is ready: they should
close and reopen Claude Code, then just describe what they want to build — you'll
handle the rest and double-check your own work for them.
