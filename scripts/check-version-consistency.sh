#!/usr/bin/env bash
#
# check-version-consistency.sh
#
# Verifies that the `version` field in both plugin.json files matches the
# version recorded in VERSION.  Exits 0 when everything is in sync; exits 1
# (with a human-readable message) when any discrepancy is found.
#
# Usage: bash scripts/check-version-consistency.sh
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

VERSION_FILE="$ROOT/VERSION"

# ---------------------------------------------------------------------------
# Read canonical version
# ---------------------------------------------------------------------------
if [ ! -f "$VERSION_FILE" ]; then
    printf 'Error: VERSION file not found at %s\n' "$VERSION_FILE" >&2
    exit 1
fi

CANONICAL="$(cat "$VERSION_FILE" | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
# Check each plugin.json
# ---------------------------------------------------------------------------
fail=0

check_plugin() {
    local label="$1"
    local json_file="$2"

    if [ ! -f "$json_file" ]; then
        printf 'Error: plugin.json not found: %s\n' "$json_file" >&2
        fail=1
        return
    fi

    local plugin_ver
    plugin_ver="$(jq -r '.version' "$json_file")"

    if [ "$plugin_ver" != "$CANONICAL" ]; then
        printf 'Version mismatch in %s: VERSION says "%s", plugin.json says "%s"\n' \
            "$label" "$CANONICAL" "$plugin_ver" >&2
        fail=1
    fi
}

check_plugin "personal-tools" "$ROOT/plugins/personal-tools/.claude-plugin/plugin.json"
check_plugin "workflow"        "$ROOT/plugins/workflow/.claude-plugin/plugin.json"

if [ "$fail" -ne 0 ]; then
    printf 'Version consistency check FAILED — run: bash scripts/sync-version.sh %s\n' \
        "$CANONICAL" >&2
    exit 1
fi

printf 'Version consistency check passed: all files at %s\n' "$CANONICAL"
