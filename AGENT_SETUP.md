# Setup instructions for Claude Code

You are reading this because a user asked you to set up their Claude Code environment
from the **my-dotclaude** repo. Both paths install the same full kit **user-wide** (into
`~/.claude`, not a project folder); they differ only in audience. Keep the user informed
in plain language as you go:

- **Developer setup** — global technical `CLAUDE.md`, the personal-tools + workflow +
  caveman + agent-sdk-dev plugins, the Playwright MCP, a `gh` allowlist (read-only reads +
  issue-write), and `model=opus`.
- **Non-developer setup** — the same kit, but with a plain-English global `CLAUDE.md`,
  caveman set to `lite`, and the model left at Claude Code's default.

### Pick the path — ask first

**Do not guess.** Unless the user has already made it unambiguous, **ask one plain
question** and wait for the answer:

> Do you write code yourself, or would you rather I handle all the technical
> parts for you?
>
> - **I write code** → developer setup (`model=opus`, technical conventions).
> - **Handle it for me** → non-developer setup (plain-English, no jargon).

Map their answer: writes code → **Developer setup**; wants it handled → **Non-developer
setup**. If they only say "set me up" with no other signal, ask this question first.

**Repository:** `https://github.com/CrazyWillBear/my-dotclaude`
**Raw base:** `https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main`

Both setups are **user-scope** — they touch `~/.claude`, not the current project. They do
not run `git init` or write any project files. They are also **non-destructive to an
existing `~/.claude/CLAUDE.md`**: the script asks before replacing it (on "no" it keeps the
user's file and prints the source URL), and `settings.json` is merged key-by-key with a
timestamped backup — so the kit never silently eats config the user already has.

---

## Developer setup

**Preferred — run the script** (one command, does everything):

```bash
curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-dev.sh | bash
```

macOS / Linux / WSL only (on Windows, run under WSL).

**Fallback — if you cannot run that script**, do these yourself (all user-scope):

1. Install the global `CLAUDE.md` from `<raw base>/global/CLAUDE.md` — **never overwrite
   an existing one blind.**
   - **No `~/.claude/CLAUDE.md` yet** → just write it.
   - **One already exists** → back it up, then *add on* rather than replace. Show the user
     the kit's rules and ask which they want:
     - **Append** — drop the kit's rules into their file inside a marked block
       (`<!-- BEGIN my-dotclaude -->` … `<!-- END my-dotclaude -->`), and call out any rule
       that contradicts theirs so they can decide.
     - **Merge** — read both and produce one coherent file, walking them through each
       conflict as you hit it.
     - (Or, if they say so: keep theirs untouched, or replace entirely.)
     Resolve every conflict *in conversation* — don't silently pick a winner.
2. Merge `"model": "opus"` into `~/.claude/settings.json`, preserving other keys. If the
   file already sets `model` to something else, don't silently swap it — tell the user the
   current value vs. `opus` and ask before changing it.
3. Install the plugins (prefer the `claude` CLI):
   ```bash
   claude plugin marketplace add CrazyWillBear/my-dotclaude
   claude plugin install personal-tools@my-dotclaude
   claude plugin install workflow@my-dotclaude
   claude plugin marketplace add JuliusBrussee/caveman
   claude plugin install caveman@caveman
   claude plugin marketplace add anthropics/claude-plugins-official
   claude plugin install agent-sdk-dev@claude-plugins-official
   claude plugin marketplace add ComposioHQ/awesome-claude-plugins
   claude plugin install perf@awesome-claude-plugins
   claude plugin install security-guidance@awesome-claude-plugins
   claude plugin marketplace add Onome-AJ/security-sweep-plugin
   claude plugin install security-sweep@security-sweep-marketplace
   ```
   If the `claude` CLI is unavailable, enable the plugins by editing
   `~/.claude/settings.json`: add the marketplaces under `extraKnownMarketplaces` and set
   each plugin to `true` under `enabledPlugins`.
4. Add the Playwright MCP server at user scope:
   ```bash
   claude mcp add playwright -s user -- npx @playwright/mcp@latest
   ```
5. For GitHub, allowlist the common read-only `gh` commands under `permissions.allow` in
   `~/.claude/settings.json` (e.g. `Bash(gh pr view:*)`, `Bash(gh issue view:*)`,
   `Bash(gh repo view:*)`, `Bash(gh run view:*)`) **plus** the four issue-write commands the
   dev loop needs (`Bash(gh issue create:*)`, `Bash(gh issue edit:*)`,
   `Bash(gh issue comment:*)`, `Bash(gh issue close:*)`) — but **not** `gh api` (can
   POST/DELETE any endpoint) or `gh pr merge` (merges stay a human decision). Tell them to
   install `gh` and run `gh auth login` if it isn't set up. (Claude uses `gh`, not a GitHub
   MCP.)

Finish by telling the user to **restart Claude Code**.

---

## Non-developer setup

The user is **not** a programmer. Explain everything in plain English, do all the
technical work yourself, and confirm before anything that can't be undone.

**Preferred — run the script:**

```bash
curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-simple.sh | bash
```

macOS / Linux / WSL only (on Windows, run under WSL).

**Fallback — if you cannot run that script**, do these yourself (all user-scope):

1. Install the global `CLAUDE.md` from `<raw base>/global/CLAUDE.simple.md`, following the
   same **never-overwrite-blind** rule as the developer fallback (step 1 above): if a
   `~/.claude/CLAUDE.md` already exists, back it up and *add on* — offer the user append vs.
   merge and resolve any conflict in conversation, never a silent replace. Leave the model
   at Claude Code's default (don't set `model=opus`).
2. Install the same plugins and the Playwright MCP as the developer fallback above (steps
   3–4), and set up the `gh` allowlist (step 5).
3. Make caveman a little less terse: set its default level to `lite` by writing
   `{"defaultMode":"lite"}` (merging if the file exists) into
   `~/.config/caveman/config.json` (on Windows: `%APPDATA%\caveman\config.json`; if
   `$XDG_CONFIG_HOME` is set, use `$XDG_CONFIG_HOME/caveman/config.json`).

Finish by telling the user, in plain words, that everything is ready: they should close
and reopen Claude Code, then just describe what they want to build — you'll handle the
rest and double-check your own work for them.

---

## Keeping the kit updated

Both setups install the `personal-tools` plugin, which keeps the kit current after the
first install — the user never has to re-run the installer. New versions ship as GitHub
Releases and reach the machine like this:

- **A `SessionStart` hook** checks ~once a day whether a newer release exists and, if so,
  surfaces a short non-blocking notice naming the version and suggesting `/update-kit`. It
  fails open (a network error just stays silent).
- **`/check-updates`** asks on demand, printing `kit is up to date (vX.Y.Z)` or
  `vX.Y.Z available — run /update-kit to upgrade`.
- **`/update-kit`** applies the latest release: it updates the `my-dotclaude` marketplace
  entry and both the `personal-tools` and `workflow` plugins, then reminds the user to
  **restart Claude Code** so the new versions load.

When you finish a setup, mention these to the user in plain language so they know how
they'll get updates.
