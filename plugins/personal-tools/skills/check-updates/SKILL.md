---
name: check-updates
description: Report whether a newer kit release exists on GitHub — compares the installed plugin version against the latest GitHub Release and prints either "up to date" or "vX.Y.Z available — run /update-kit". Use for "/check-updates", "check for updates", "is the kit up to date?".
argument-hint: ""
model: inherit
allowed-tools: Bash
---

Check whether a newer kit release is available. No arguments needed.

## Steps

1. **Locate the backing script** — it lives at
   `${CLAUDE_PLUGIN_ROOT}/scripts/check-update.sh`.

2. **Run it** with Bash:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-update.sh"
   ```
   The script reads the installed version from
   `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`, queries the GitHub
   Releases API, and compares the two by numeric semver ordering
   (major.minor.patch). It prints one of:
   - `kit is up to date (vX.Y.Z)` — installed version is equal to or newer than
     the latest release (a local/dev checkout that is ahead is never asked to
     downgrade).
   - `vX.Y.Z available — run /update-kit to upgrade` — the latest release is
     strictly newer than the installed version.

   On any network or API failure the script exits 0 with no output (fail-open).

3. **Report the result.** Relay the script output to the user. If the script
   prints nothing (network failure or no version info available), tell the user
   that the update check could not be completed and to try again later.
