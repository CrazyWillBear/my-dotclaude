#!/usr/bin/env bash
#
# check-update.sh — report whether a newer kit release exists.
#
# Reads the installed plugin version from:
#   ${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json
#
# Queries the GitHub Releases API:
#   https://api.github.com/repos/CrazyWillBear/my-dotclaude/releases/latest
#
# Prints one of:
#   "kit is up to date (vX.Y.Z)"
#   "vX.Y.Z available — run /update-kit to upgrade"
#
# Fails open: any network error, API failure, or unparseable response → exit 0
# with no output (silent).
#
# `curl` is invoked from PATH so a test can shim it.
#
# Usage: bash check-update.sh

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the plugin root
# ---------------------------------------------------------------------------
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

# ---------------------------------------------------------------------------
# Read installed version from plugin.json
# ---------------------------------------------------------------------------
if [ ! -f "$PLUGIN_JSON" ]; then
    exit 0
fi

# Extract version with grep+sed — avoids requiring jq
installed_ver="$(grep '"version"' "$PLUGIN_JSON" | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
if [ -z "$installed_ver" ]; then
    exit 0
fi

# ---------------------------------------------------------------------------
# Query GitHub Releases API (fail open on any error)
# ---------------------------------------------------------------------------
api_url="https://api.github.com/repos/CrazyWillBear/my-dotclaude/releases/latest"

# curl flags: silent, fail on HTTP error, 10s timeout
raw="$(curl -sf --max-time 10 "$api_url" 2>/dev/null)" || exit 0

# Extract tag_name from the JSON response
latest_tag="$(printf '%s' "$raw" | grep '"tag_name"' | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
if [ -z "$latest_tag" ]; then
    exit 0
fi

# Normalize: strip leading "v" for comparison, keep original tag for display
installed_stripped="${installed_ver#v}"
latest_stripped="${latest_tag#v}"

# ---------------------------------------------------------------------------
# Compare and report
# ---------------------------------------------------------------------------
if [ "$installed_stripped" = "$latest_stripped" ]; then
    printf 'kit is up to date (v%s)\n' "$installed_stripped"
else
    printf '%s available — run /update-kit to upgrade\n' "$latest_tag"
fi
