#!/usr/bin/env bash
#
# update-kit.sh — apply the latest kit release on this machine.
#
# Three parts:
#   1. Update the marketplace via the `claude` CLI:
#        claude plugin marketplace update my-dotclaude
#   2. Update every plugin our marketplace lists — derived from
#      .claude-plugin/marketplace.json (via tcr_our_plugin_names in
#      setup/lib/common.sh) rather than hardcoded, so a plugin added to the
#      manifest later gets updated here too:
#        claude plugin update <name>   # for each plugin in the manifest
#      falling back to `claude plugin install <name>@my-dotclaude` for a plugin
#      the manifest gained after this machine installed the kit.
#      setup/lib/common.sh is sourced from the local marketplace repo copy when
#      found, else fetched over curl (same bootstrap setup-dev.sh/setup-simple.sh
#      use) so this still derives the list instead of falling back to hardcoding.
#   3. Refresh the status line. global/statusline.py and its settings.json
#      `statusLine` wiring are NOT plugin payload, so steps 1-2 do not carry
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

REPO="CrazyWillBear/my-dotclaude"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"

# our_marketplace_root — installLocation of the my-dotclaude marketplace (its
# local repo copy: a full git clone for a GitHub install, or the live checkout
# for a `directory` install). Prints nothing (and a note to stdout) when
# known_marketplaces.json or the marketplace entry can't be found.
our_marketplace_root() {
  local config_dir known root
  config_dir="${CLAUDE_CONFIG_DIR:-${HOME:-/nonexistent}/.claude}"
  known="$config_dir/plugins/known_marketplaces.json"
  if [ ! -f "$known" ]; then
    printf 'note: %s not found; skipped deriving the plugin list and status line refresh.\n' "$known" >&2
    return 0
  fi
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
    printf 'note: my-dotclaude marketplace repo copy not found; skipped deriving the plugin list and status line refresh.\n' >&2
    return 0
  fi
  printf '%s\n' "$root"
}

claude plugin marketplace update my-dotclaude

ROOT="$(our_marketplace_root)"
COMMON="${ROOT:+$ROOT/setup/lib/common.sh}"
if [ -n "$COMMON" ] && [ -f "$COMMON" ]; then
  TCR_LOCAL_ROOT="$ROOT"
  # shellcheck source=/dev/null
  . "$COMMON"
else
  TCR_LOCAL_ROOT=""
  _common_tmp="$(mktemp)"
  trap 'rm -f "$_common_tmp"' EXIT
  if curl -fsSL "$RAW_BASE/setup/lib/common.sh" -o "$_common_tmp" && [ -s "$_common_tmp" ]; then
    # shellcheck disable=SC1090
    . "$_common_tmp"
  else
    printf 'note: could not fetch setup/lib/common.sh from %s; skipped plugin updates and status line refresh — run: claude plugin update <name>\n' "$RAW_BASE" >&2
  fi
fi

if declare -F tcr_our_plugin_names >/dev/null; then
  if [ -n "$TCR_LOCAL_ROOT" ] && [ -f "$TCR_LOCAL_ROOT/.claude-plugin/marketplace.json" ]; then
    # Local marketplace copy path. Bare assignment (not a process
    # substitution): under `set -euo pipefail` this lets a tcr_die inside
    # tcr_our_plugin_names (e.g. a malformed manifest) abort the script
    # instead of silently reading zero names.
    names="$(tcr_our_plugin_names)"
  else
    # Remote-fallback path: the marketplace update already ran, so a failure
    # here (429, flaky DNS on the manifest fetch) must stay non-fatal,
    # matching the script's own "status-line refresh failure is non-fatal"
    # contract — suppress errexit instead of letting tcr_die kill the script.
    if ! names="$(tcr_our_plugin_names)"; then
      printf 'note: could not derive plugin list from %s; skipped plugin updates — run: claude plugin update <name>\n' "$RAW_BASE" >&2
      names=""
    fi
  fi
  # A plugin added to the manifest after this machine installed the kit isn't
  # installed yet, so `plugin update` fails for it — install it instead.
  # tcr_install_plugin only warns on failure, so one bad plugin can't abort
  # the updates listed after it.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    claude plugin update "$name" || tcr_install_plugin "${name}@${OUR_MARKETPLACE}"
  done <<< "$names"
fi

# refresh_statusline — copy the latest status line out of the marketplace's
# local repo copy and (re)wire it into settings.json. Prints a note and returns
# without error whenever the repo copy or installer can't be located, so a
# missing piece never blocks the (already-applied) plugin update.
refresh_statusline() {
  declare -F tcr_install_statusline >/dev/null || return 0
  tcr_install_statusline
}

# Subshell-guarded so a tcr_die inside the installer can't abort the whole
# update and skip the restart reminder — the plugins are already updated.
( refresh_statusline ) \
  || printf 'note: status line refresh failed; run setup-dev.sh to refresh it.\n'

# tcr_install_plugin only flags a failed install, so fail the run here — after
# the other plugins and the status line — rather than report "Done".
if [ "${TCR_INSTALL_FAILED:-0}" = "1" ]; then
  printf '\nerror: a plugin neither updated nor installed — run the claude plugin install command(s) shown above, then restart Claude Code.\n' >&2
  exit 1
fi

printf '\nDone. Restart Claude Code to apply the updated kit.\n'
