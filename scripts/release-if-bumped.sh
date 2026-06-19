#!/usr/bin/env bash
#
# release-if-bumped.sh
#
# Compares the version in VERSION to the latest v* git tag.  It releases ONLY
# when VERSION is strictly greater (by numeric semver) than the highest existing
# v* tag: it creates git tag vX.Y.Z, pushes it, and runs
# `gh release create vX.Y.Z --generate-notes`.  When VERSION equals the latest
# tag, when a tag for that exact version already exists, or when VERSION is
# behind the latest tag (e.g. an accidental downgrade), the script is a no-op —
# so it is safe to run on every push to main and never cuts an out-of-order
# release.
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
# semver_gt A B — succeed (return 0) when A is strictly greater than B by
# numeric major.minor.patch ordering (so 0.10.0 > 0.9.0, and leading zeros are
# not read as octal). Missing components default to 0; non-numeric components
# are treated as 0 so a malformed tag can never crash the comparison.
# ---------------------------------------------------------------------------
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
    return 1   # all components equal → not strictly greater
}

# ---------------------------------------------------------------------------
# Refuse to re-tag an exact version that already exists.
# ---------------------------------------------------------------------------
EXISTING_TAGS="$(git tag --list 'v*')"

if printf '%s\n' "$EXISTING_TAGS" | grep -qxF "$TAG"; then
    printf 'No-op: tag %s already exists.\n' "$TAG"
    exit 0
fi

# ---------------------------------------------------------------------------
# Find the highest existing v* tag and release ONLY when VERSION is strictly
# greater. This blocks an out-of-order release if VERSION is ever set behind the
# latest tag (e.g. an accidental downgrade to a version that was never tagged).
# An empty tag list behaves like 0.0.0, so the first release always proceeds.
# ---------------------------------------------------------------------------
LATEST_STRIPPED="0.0.0"
while IFS= read -r t; do
    [ -n "$t" ] || continue
    t_stripped="${t#v}"
    if semver_gt "$t_stripped" "$LATEST_STRIPPED"; then
        LATEST_STRIPPED="$t_stripped"
    fi
done <<< "$EXISTING_TAGS"

if ! semver_gt "$CURRENT" "$LATEST_STRIPPED"; then
    printf 'No-op: VERSION %s is not ahead of the latest tag v%s.\n' \
        "$CURRENT" "$LATEST_STRIPPED"
    exit 0
fi

# ---------------------------------------------------------------------------
# Create the tag, push it (pinning it to this exact commit), and cut the Release.
# ---------------------------------------------------------------------------
printf 'Creating tag %s and GitHub Release...\n' "$TAG"

git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" --generate-notes

printf 'Released %s.\n' "$TAG"
