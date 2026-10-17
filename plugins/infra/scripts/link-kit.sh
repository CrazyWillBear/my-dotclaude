#!/usr/bin/env bash
#
# link-kit.sh — SessionStart hook: point ~/.claude/kit/infra at this plugin's root, link
# ~/.claude/kit/personal-tools, and build the worker boxes under ~/.claude/kit/boxes/.
#
# Other plugins cannot know where infra is installed (a marketplace cache path, a
# dev checkout), so they call its scripts through this one fixed address instead:
#   bash ~/.claude/kit/infra/scripts/session-status.sh --self
# See docs/swarm-design.md § Plugin split — nothing calls across plugins except
# into infra, and only through this link.
#
# personal-tools is linked too: the reviewer box needs `--plugin-dir` for my-review and the
# implementer box's settings run worktree-guard.sh, and a marketplace install has no stable
# sibling path (versioned cache dirs), so it is found as a checkout sibling or through
# installed_plugins.json.
#
# A BOX is a per-role CLAUDE_CONFIG_DIR for /orchestrate's one-shot `claude -p` workers: the
# user's credentials (symlinked), the role's own CLAUDE.md, and a settings.json with only the
# hooks the role needs — none of the user's MCP servers, plugins, skills, memory or global
# CLAUDE.md, which cost every launch ~16k tokens before it read a word of its task.
#
# Idempotent; repoints a stale or dangling link. Refuses (exit 1) if a real file or
# directory sits at the infra path — a hook never deletes user files. Silent on success:
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

# --- personal-tools -----------------------------------------------------------------
CFG="${CLAUDE_CONFIG_DIR:-$HOME_DIR/.claude}"
PT_LINK="$HOME_DIR/.claude/kit/personal-tools"
PT=""
if [ -d "$ROOT/../personal-tools/scripts" ]; then
    PT="$(cd "$ROOT/../personal-tools" && pwd -P)"
elif [ -f "$CFG/plugins/installed_plugins.json" ] && command -v jq >/dev/null 2>&1; then
    PT="$(jq -r 'first(.plugins | to_entries[] | select(.key | startswith("personal-tools@"))
                 | .value[0].installPath) // empty' "$CFG/plugins/installed_plugins.json" 2>/dev/null)"
fi
if [ -n "$PT" ] && [ -d "$PT" ]; then
    if [ -e "$PT_LINK" ] && [ ! -L "$PT_LINK" ]; then
        echo "infra: $PT_LINK exists and is not a symlink — remove it so the worker boxes can reach personal-tools" >&2
    else
        ln -sfn "$PT" "$PT_LINK" 2>/dev/null || [ -L "$PT_LINK" ]
    fi
fi

# --- worker boxes -------------------------------------------------------------------
BOX_ROOT="${CLAUDE_BOX_ROOT:-$HOME_DIR/.claude/kit/boxes}"

# A token refresh inside a box replaces its credentials symlink with a regular file (the CLI
# writes by rename), and from then on that file holds the live tokens. Before re-linking,
# the box file with the LATEST `claudeAiOauth.expiresAt` across all boxes is copied back to
# the user's (atomically, private) if it beats theirs — so a refresh is never lost and a
# re-link never clobbers newer tokens. A file with no refresh token (a box that cleared its
# credentials after a rejected refresh) is never copied. Residual risk, not covered: a
# refresh that ROTATES the refresh token mid-run leaves the other side stale until the next
# SessionStart (README § The stable address).
expires() { jq -r 'if (.claudeAiOauth.refreshToken // "") == "" then -1 else (.claudeAiOauth.expiresAt // 0) end' "$1" 2>/dev/null || echo -1; }
if command -v jq >/dev/null 2>&1; then
    best=""; best_exp="$( [ -f "$CFG/.credentials.json" ] && expires "$CFG/.credentials.json" || echo -1)"
    for role in implementer planner reviewer; do
        f="$BOX_ROOT/$role/.credentials.json"
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        e="$(expires "$f")"
        case "$e" in ''|*[!0-9-]*) continue ;; esac
        [ "$e" -gt "${best_exp:--1}" ] 2>/dev/null && { best="$f"; best_exp="$e"; }
    done
    if [ -n "$best" ]; then
        ( umask 077; cp -f "$best" "$CFG/.credentials.json.box-sync.$$" \
            && mv -f "$CFG/.credentials.json.box-sync.$$" "$CFG/.credentials.json" ) 2>/dev/null
    fi
fi
for role in implementer planner reviewer; do
    box="$BOX_ROOT/$role"
    mkdir -p "$box" || continue
    creds="$box/.credentials.json"
    ln -sfn "$CFG/.credentials.json" "$creds" 2>/dev/null
    cp -f "$ROOT/boxes/$role/CLAUDE.md" "$box/CLAUDE.md" 2>/dev/null
    if [ "$role" = implementer ]; then
        # The primary-checkout guard every interactive session has, so a boxed worker that
        # wanders out of its worktree is stopped the same way.
        printf '{"hooks":{"PreToolUse":[{"matcher":"Edit|Write|NotebookEdit","hooks":[{"type":"command","command":"bash \\"%s\\""}]}]}}\n' \
            "$PT_LINK/scripts/worktree-guard.sh" >"$box/settings.json"
    else
        printf '{}\n' >"$box/settings.json"
    fi
    # Box transcripts are scratch: a run deletes its own at the end; this catches the rest.
    [ -d "$box/projects" ] && find "$box/projects" -type f -mtime +7 -delete 2>/dev/null
done
exit 0
