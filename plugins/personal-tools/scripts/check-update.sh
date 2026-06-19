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
# Compare by numeric semver ordering
# ---------------------------------------------------------------------------
# Returns 0 (success) when $1 is strictly greater than $2 by major.minor.patch,
# comparing each component as a base-10 integer (so 10 > 9, and leading zeros
# are not read as octal). Any non-numeric component is treated as 0, keeping
# the fail-open spirit of the script. Components missing on either side default
# to 0 (e.g. "1.2" behaves like "1.2.0").
# num: parse a single version component into a base-10 integer. Non-numeric or
# missing input yields 0, so a malformed tag can never crash the comparison
# (keeps the fail-open spirit). Leading zeros are stripped before $((10#..)).
num() {
    local c="$1"
    case "$c" in
        ''|*[!0-9]*) printf '0' ;;
        *)           printf '%d' "$((10#$c))" ;;
    esac
}

semver_gt() {
    local a="$1" b="$2"
    local IFS=.
    # shellcheck disable=SC2206
    local a_parts=($a) b_parts=($b)
    local i a_n b_n
    for i in 0 1 2; do
        a_n="$(num "${a_parts[i]:-0}")"
        b_n="$(num "${b_parts[i]:-0}")"
        if [ "$a_n" -gt "$b_n" ]; then
            return 0
        elif [ "$a_n" -lt "$b_n" ]; then
            return 1
        fi
    done
    # All components equal → not strictly greater.
    return 1
}

# ---------------------------------------------------------------------------
# Report: prompt an upgrade ONLY when latest is strictly greater than installed.
# When installed == latest OR installed > latest (local ahead), report up to
# date — never prompt a downgrade.
# ---------------------------------------------------------------------------
if semver_gt "$latest_stripped" "$installed_stripped"; then
    printf '%s available — run /update-kit to upgrade\n' "$latest_tag"
else
    printf 'kit is up to date (v%s)\n' "$installed_stripped"
fi
