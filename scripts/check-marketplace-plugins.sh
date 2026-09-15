#!/usr/bin/env bash
#
# check-marketplace-plugins.sh
#
# Reverse-direction check on .claude-plugin/marketplace.json: every
# plugins/*/.claude-plugin/plugin.json on disk must be listed as a plugin
# source in the marketplace manifest. CI's "Validate JSON and manifests" step
# already checks the forward direction (every manifest-listed source has a
# plugin.json); without this, the two derived plugin lists can silently drift
# — a plugin dir added under plugins/ without a matching marketplace entry
# would never surface as a CI failure.
#
# Usage: bash scripts/check-marketplace-plugins.sh
#
# The script locates the repo root via REPO_ROOT (env var) or by walking up
# from its own location — this allows tests to override the root without any
# special flags.

set -euo pipefail

if [ -n "${REPO_ROOT:-}" ]; then
    ROOT="$REPO_ROOT"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

MP="$ROOT/.claude-plugin/marketplace.json"
if [ ! -f "$MP" ]; then
    printf 'Error: marketplace manifest not found: %s\n' "$MP" >&2
    exit 1
fi

fail=0

shopt -s nullglob
plugin_jsons=("$ROOT"/plugins/*/.claude-plugin/plugin.json)
shopt -u nullglob

for json_file in "${plugin_jsons[@]}"; do
    plugin_dir="$(basename "$(dirname "$(dirname "$json_file")")")"
    src="./plugins/$plugin_dir"
    if ! jq -e --arg src "$src" '.plugins | any(.source == $src)' "$MP" >/dev/null; then
        printf 'plugins/%s/.claude-plugin/plugin.json exists but is not listed in %s\n' \
            "$plugin_dir" "$MP" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    printf 'Marketplace plugin check FAILED — add the missing plugin(s) to %s\n' "$MP" >&2
    exit 1
fi

printf 'Marketplace plugin check passed: every plugins/*/plugin.json is listed in %s\n' "$MP"
