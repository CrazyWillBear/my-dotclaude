#!/usr/bin/env bash
#
# release-if-bumped.sh
#
# Compares the version in VERSION to the latest v* git tag.  When VERSION is
# ahead (i.e. no tag for that version yet), it creates git tag vX.Y.Z and
# runs `gh release create vX.Y.Z --generate-notes`.  When VERSION matches the
# latest tag — or a tag for that version already exists — the script is a
# no-op so it is safe to run on every push to main.
#
# Usage: bash scripts/release-if-bumped.sh
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
# Read VERSION
# ---------------------------------------------------------------------------
if [ ! -f "$VERSION_FILE" ]; then
    printf 'Error: VERSION file not found at %s\n' "$VERSION_FILE" >&2
    exit 1
fi

CURRENT="$(cat "$VERSION_FILE" | tr -d '[:space:]')"

if ! printf '%s' "$CURRENT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf 'Error: VERSION contains an invalid semver: "%s"\n' "$CURRENT" >&2
    exit 1
fi

TAG="v${CURRENT}"

# ---------------------------------------------------------------------------
# Check whether a tag for this exact version already exists
# ---------------------------------------------------------------------------
EXISTING_TAGS="$(git tag --list 'v*')"

if printf '%s\n' "$EXISTING_TAGS" | grep -qxF "$TAG"; then
    printf 'No-op: tag %s already exists.\n' "$TAG"
    exit 0
fi

# ---------------------------------------------------------------------------
# Create the tag and GitHub Release
# ---------------------------------------------------------------------------
printf 'Creating tag %s and GitHub Release...\n' "$TAG"

git tag "$TAG"
gh release create "$TAG" --generate-notes

printf 'Released %s.\n' "$TAG"
