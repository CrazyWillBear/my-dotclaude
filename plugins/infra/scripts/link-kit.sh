#!/usr/bin/env bash
#
# link-kit.sh — SessionStart hook: point ~/.claude/kit/infra at this plugin's root.
#
# Other plugins cannot know where infra is installed (a marketplace cache path, a
# dev checkout), so they call its scripts through this one fixed address instead:
#   bash ~/.claude/kit/infra/scripts/session-status.sh --self
# See docs/swarm-design.md § Plugin split — nothing calls across plugins except
# into infra, and only through this link.
#
# Idempotent; repoints a stale or dangling link. Refuses (exit 1) if a real file or
# directory sits at the path — a hook never deletes user files. Silent on success:
# SessionStart stdout lands in the session's context.

set -uo pipefail

# pwd -P: run through the link itself, a logical path would point the link at itself.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 1
# $HOME is not guaranteed: systemd units, `env -i` and some hook harnesses run without it,
# and under `set -u` a bare expansion aborts this hook before it can report anything. Named
# once because it is used twice.
HOME_DIR="${HOME:-/nonexistent}"
LINK="$HOME_DIR/.claude/kit/infra"

if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    echo "infra: $LINK exists and is not a symlink — remove it so other plugins can reach infra's scripts" >&2
    exit 1
fi
mkdir -p "$HOME_DIR/.claude/kit" || exit 1
# ponytail: concurrent SessionStarts race the unlink/create; the winner's link is equally valid
ln -sfn "$ROOT" "$LINK" 2>/dev/null || [ -L "$LINK" ]
