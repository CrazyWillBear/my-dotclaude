#!/usr/bin/env bash
#
# worker-cmd.sh — print the argv of a one-shot CLAUDE worker, NUL-delimited.
#
# One builder for the two places that launch one: spawn.sh (a build or fix turn) and
# worker-resume.sh (the same worker resumed with an answer). A resume launched with
# different flags than its spawn is a different worker on the same branch — another model,
# another toolset, another config dir — so the argv lives here once, as review-cmd.sh does
# for the reviewer.
#
# Usage:
#   bash worker-cmd.sh <model> <effort> <worktree> <schema-json> [--browser] [--resume ID] -- <prompt>
#   bash worker-cmd.sh --deny     # just the shared --disallowedTools list (spawn.sh's peer form)
#
# The worker runs in the IMPLEMENTER BOX: CLAUDE_CONFIG_DIR is ~/.claude/kit/boxes/implementer
# (moved by CLAUDE_BOX_ROOT), which link-kit.sh builds with the user's credentials, the
# implementer contract as CLAUDE.md, and only the worktree-guard hook — none of the user's
# MCP servers, plugins, skills, memory or global CLAUDE.md. `env` carries it into the argv
# so the caller needs no export.
#
# Why each flag is here:
#   -p ... --output-format stream-json --verbose
#                       one-shot; one JSON event per line into events.jsonl. The first
#                       `system/init` event carries the session_id a resume needs; the
#                       final `result` event carries the `structured_output` report.
#   --json-schema       forces the final answer into the status schema — the role
#                       codex's --output-schema plays.
#   --permission-mode bypassPermissions
#                       nobody is there to answer a permission prompt.
#   --mcp-config ... --strict-mcp-config
#                       no MCP servers, or only Playwright with --browser. `--mcp-config`
#                       is variadic, so --strict-mcp-config ends its list.
#   --add-dir <worktree>
#                       fences the FILE tools to the worktree. It does not fence Bash; the
#                       containment is the denylist plus worktree isolation, not a sandbox.
#   --disallowedTools   the irreversible, outward-facing writes stay on the main thread.
#                       `git push` and `gh issue comment` are deliberately allowed. `gh api`
#                       / `gh repo` / `gh workflow` / `gh release` are denied too: `gh api`
#                       can close, edit and merge.
#   -- <prompt>         `--disallowedTools` is VARIADIC: a prompt after it without `--` is
#                       parsed as more deny rules and the worker starts with no task.

set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }

DENY=("Bash(git merge:*)" "Bash(git worktree:*)" "Bash(gh pr:*)"
      "Bash(gh issue close:*)" "Bash(gh issue edit:*)"
      "Bash(gh api:*)" "Bash(gh repo:*)" "Bash(gh workflow:*)" "Bash(gh release:*)")

if [ "${1:-}" = --deny ]; then
    printf '%s\0' "${DENY[@]}"
    exit 0
fi

[ $# -ge 4 ] || die "usage: worker-cmd.sh <model> <effort> <worktree> <schema-json> [--browser] [--resume ID] -- <prompt>"
MODEL="$1"; EFFORT="$2"; WORKTREE="$3"; SCHEMA="$4"; shift 4
BROWSER=""; RESUME=""; PROMPT=""; HAVE_PROMPT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --browser) BROWSER=1; shift ;;
        --resume)  [ $# -ge 2 ] || die "--resume needs a session id"; RESUME="$2"; shift 2 ;;
        --)        [ $# -eq 2 ] || die "exactly one prompt argument must follow --"
                   PROMPT="$2"; HAVE_PROMPT=1; shift 2 ;;
        *)         die "unknown flag $1" ;;
    esac
done
[ -n "$MODEL" ] && [ -n "$EFFORT" ] && [ -n "$WORKTREE" ] || die "model, effort and worktree are required"
[ -n "$SCHEMA" ] || die "the status schema is required"
[ -n "$HAVE_PROMPT" ] && [ -n "$PROMPT" ] || die "a prompt is required after --"

BOX="${CLAUDE_BOX_ROOT:-${HOME:-/nonexistent}/.claude/kit/boxes}/implementer"

MCP_JSON='{"mcpServers":{}}'
[ -z "$BROWSER" ] || MCP_JSON='{"mcpServers":{"playwright":{"command":"npx","args":["@playwright/mcp@latest"]}}}'

CMD=(env "CLAUDE_CONFIG_DIR=$BOX" claude -p)
[ -z "$RESUME" ] || CMD+=(--resume "$RESUME")
CMD+=(--model "$MODEL" --effort "$EFFORT"
      --permission-mode bypassPermissions
      --system-prompt-snapshot off
      --mcp-config "$MCP_JSON" --strict-mcp-config
      --add-dir "$WORKTREE"
      --output-format stream-json --verbose
      --json-schema "$SCHEMA"
      --disallowedTools "${DENY[@]}"
      -- "$PROMPT")
printf '%s\0' "${CMD[@]}"
