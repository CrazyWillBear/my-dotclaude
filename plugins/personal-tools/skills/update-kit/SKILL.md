---
name: update-kit
description: Apply the latest kit release on this machine — updates the my-dotclaude marketplace entry and both plugins, then reminds you to restart Claude Code. Use for "/update-kit", "update the kit", "apply latest kit release".
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
   The script issues three `claude` CLI calls in order:
   - `claude plugin marketplace update my-dotclaude`
   - `claude plugin update personal-tools`
   - `claude plugin update workflow`

3. **Report the result.** If the script exits non-zero, surface the error and
   tell the user to check their `claude` CLI installation. If it exits 0, confirm
   that the kit was updated and remind them to **restart Claude Code** so the new
   versions take effect.
