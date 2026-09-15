---
name: update-kit
description: Apply the latest kit release on this machine — updates the my-dotclaude marketplace entry and every plugin it lists, then reminds you to restart Claude Code. Use for "/update-kit", "update the kit", "apply latest kit release".
argument-hint: ""
model: inherit
allowed-tools: Bash
---

Apply the latest kit release on this machine. No arguments needed.

## Steps

1. **Locate the backing script** — it lives at
   `${CLAUDE_PLUGIN_ROOT}/scripts/update-kit.sh`.

2. **Run it** with Bash:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/update-kit.sh"
   ```
   The script issues `claude plugin marketplace update my-dotclaude`, then one
   `claude plugin update <name>` call per plugin listed in
   `.claude-plugin/marketplace.json` (derived, not hardcoded, so a plugin added
   to the manifest later gets updated here too). A listed plugin that isn't
   installed yet is installed with `claude plugin install <name>@my-dotclaude`
   instead. If that install fails too, the script still finishes the other
   plugins and the status line, then exits non-zero.

   It then refreshes the status line, which is not plugin payload: the
   marketplace update above also refreshes Claude Code's local copy of the repo
   (a git clone for a GitHub install, the live checkout for a `directory`
   install), so the script reads that location from `known_marketplaces.json`
   and reuses `setup/lib/common.sh`'s installer to copy the new
   `global/statusline.py` into `~/.claude/` and merge the `settings.json`
   wiring — backing up the old files first. A refresh failure is non-fatal: the
   plugin update still succeeded.

3. **Report the result.** If the script exits non-zero, surface the error and
   tell the user to check their `claude` CLI installation — or, when it names
   a `claude plugin install` command, to run that command. If it exits 0, confirm
   that the kit was updated and remind them to **restart Claude Code** so the new
   versions take effect.
