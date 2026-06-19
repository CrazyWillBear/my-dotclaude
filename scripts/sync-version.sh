#!/usr/bin/env bash
#
# sync-version.sh <x.y.z>
#
# Writes the given version into:
#   - VERSION  (repo root)
#   - plugins/personal-tools/.claude-plugin/plugin.json
#   - plugins/workflow/.claude-plugin/plugin.json
#
# Usage: bash scripts/sync-version.sh 1.2.3
#
# The script locates the repo root via REPO_ROOT (env var) or by walking up
# from its own location — this allows tests to override the root without any
# special flags.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate repo root
# ---------------------------------------------------------------------------
if [ -n "${REPO_ROOT:-}" ]; then
    ROOT="$REPO_ROOT"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# ---------------------------------------------------------------------------
# Validate argument
# ---------------------------------------------------------------------------
if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
    printf 'Usage: bash scripts/sync-version.sh <x.y.z>\n' >&2
    exit 1
fi

NEW_VER="$1"

# Require x.y.z semver (digits only, three parts).
if ! printf '%s' "$NEW_VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf 'Error: "%s" is not a valid semver (expected x.y.z format).\n' "$NEW_VER" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Write VERSION file
# ---------------------------------------------------------------------------
printf '%s\n' "$NEW_VER" > "$ROOT/VERSION"

# ---------------------------------------------------------------------------
# Update plugin.json files — use jq for robust JSON editing
# ---------------------------------------------------------------------------
PT_JSON="$ROOT/plugins/personal-tools/.claude-plugin/plugin.json"
WF_JSON="$ROOT/plugins/workflow/.claude-plugin/plugin.json"

for json_file in "$PT_JSON" "$WF_JSON"; do
    if [ ! -f "$json_file" ]; then
        printf 'Error: expected file not found: %s\n' "$json_file" >&2
        exit 1
    fi
    tmp="$(mktemp)"
    jq --arg v "$NEW_VER" '.version = $v' "$json_file" > "$tmp"
    mv "$tmp" "$json_file"
done

printf 'Synced version %s into VERSION and both plugin.json files.\n' "$NEW_VER"
