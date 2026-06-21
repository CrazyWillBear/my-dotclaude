#!/usr/bin/env bash
#
# update-kit.sh — apply the latest kit release on this machine.
#
# Two parts:
#   1. Update the marketplace + both plugins via the `claude` CLI:
#        claude plugin marketplace update my-dotclaude
#        claude plugin update personal-tools
#        claude plugin update workflow
#   2. Refresh the status line. global/statusline.py and its settings.json
#      `statusLine` wiring are NOT plugin payload, so step 1 does not carry
#      them. But the marketplace update in step 1 refreshes the local copy of
#      the repo that Claude Code keeps for the my-dotclaude marketplace — a full
#      git clone for a GitHub install, or the live checkout for a `directory`
#      install. We read that location from known_marketplaces.json and reuse the
#      canonical installer (tcr_install_statusline in setup/lib/common.sh, which
#      ships in that same repo copy) to copy the new statusline.py and merge the
#      settings.json wiring — backing up whatever was there first.
#
# `claude` is invoked from PATH so a test can shim it. A status-line refresh
# failure is non-fatal: the plugin update already succeeded.
#
# Usage: bash update-kit.sh

set -euo pipefail

claude plugin marketplace update my-dotclaude
claude plugin update personal-tools
claude plugin update workflow

# refresh_statusline — copy the latest status line out of the marketplace's
# local repo copy and (re)wire it into settings.json. Prints a note and returns
# without error whenever the repo copy or installer can't be located, so a
# missing piece never blocks the (already-applied) plugin update.
refresh_statusline() {
  local config_dir known root common
  config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  known="$config_dir/plugins/known_marketplaces.json"
  if [ ! -f "$known" ]; then
    printf 'note: %s not found; skipped status line refresh.\n' "$known"
    return 0
  fi
  # installLocation of the my-dotclaude marketplace = its local repo copy.
  root="$(python3 - "$known" <<'PY' 2>/dev/null
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print((data.get("my-dotclaude") or {}).get("installLocation", ""))
except Exception:
    pass
PY
)" || root=""
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    printf 'note: my-dotclaude marketplace repo copy not found; skipped status line refresh.\n'
    return 0
  fi
  common="$root/setup/lib/common.sh"
  if [ ! -f "$common" ]; then
    printf 'note: %s not found; skipped status line refresh.\n' "$common"
    return 0
  fi
  # Reuse the canonical installer from the repo copy. With TCR_LOCAL_ROOT set it
  # copies global/statusline.py from there (no network) and merges the
  # settings.json statusLine block, backing up any existing files first.
  TCR_LOCAL_ROOT="$root"
  # shellcheck source=/dev/null
  . "$common"
  tcr_install_statusline
}

# Subshell-guarded so a tcr_die inside the installer can't abort the whole
# update and skip the restart reminder — the plugins are already updated.
( refresh_statusline ) \
  || printf 'note: status line refresh failed; run setup-dev.sh to refresh it.\n'

printf '\nDone. Restart Claude Code to apply the updated kit.\n'
