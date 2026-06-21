#!/usr/bin/env bash
#
# Developer setup — installs the full user-wide Claude Code kit into ~/.claude:
# the global CLAUDE.md (technical), model=opus, a default context status line,
# the personal-tools + workflow + caveman + agent-sdk-dev + perf +
# security-guidance + security-sweep plugins, the Playwright MCP server, and a
# gh (GitHub CLI) allowlist (read-only reads + issue-write for the dev loop).
# User scope — not tied to any one project.
#
#   curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-dev.sh | bash
#
# or, from a local checkout:
#
#   bash setup/setup-dev.sh [--force] [--no-color]
#
# --force overwrites an existing ~/.claude/CLAUDE.md (a timestamped backup is
# always kept either way).

set -euo pipefail

REPO="CrazyWillBear/my-dotclaude"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"

# Honor --no-color before sourcing the library (it picks colors at source time).
case " $* " in *" --no-color "*) NO_COLOR=1; export NO_COLOR ;; esac

# Resolve our own location so we can run from a checkout or via `curl | bash`.
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -f "$(cd "$(dirname "$SELF")" && pwd)/lib/common.sh" ]; then
  SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
  TCR_LOCAL_ROOT="$(cd "$SELF_DIR/.." && pwd)"
  # shellcheck source=lib/common.sh
  . "$SELF_DIR/lib/common.sh"
else
  TCR_LOCAL_ROOT=""
  command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }
  _tcr_tmp="$(mktemp)"
  trap 'rm -f "$_tcr_tmp"' EXIT
  curl -fsSL "$RAW_BASE/setup/lib/common.sh" -o "$_tcr_tmp" \
    || { echo "error: could not fetch setup library" >&2; exit 1; }
  [ -s "$_tcr_tmp" ] || { echo "error: fetched setup library is empty" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$_tcr_tmp"
fi

TCR_FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) TCR_FORCE=1 ;;
    --no-color) : ;;  # already handled before sourcing (see top)
    -h|--help)
      printf 'setup-dev.sh — install the full user-wide Claude Code kit (user scope).\n'
      printf 'Writes ~/.claude/CLAUDE.md (technical), sets model=opus, installs the status line + plugins, the Playwright MCP, and a gh allowlist.\n'
      printf 'Options: --force (overwrite an existing ~/.claude/CLAUDE.md), --no-color\n'
      exit 0 ;;
    *) tcr_warn "ignoring unknown option: $arg" ;;
  esac
done
export TCR_FORCE TCR_LOCAL_ROOT

# This path is user-scope (~/.claude), so it only needs claude (and curl when remote).
tcr_require claude "Install Claude Code (the 'claude' CLI), then re-run."
if [ -z "${TCR_LOCAL_ROOT:-}" ]; then
  tcr_require curl "Install curl, or run this script from a local checkout of the repo."
fi

tcr_step "Developer setup into: $HOME/.claude"
tcr_install_global_claudemd
tcr_set_setting model opus
tcr_install_statusline         # default context status line (folds in caveman badge)
tcr_install_ctags
tcr_add_our_marketplace         # register our marketplace (local checkout or repo)
tcr_install_personal_tools      # from our marketplace
tcr_install_workflow            # from our marketplace
tcr_install_caveman
tcr_install_agent_sdk_dev
tcr_install_composio_plugins    # third-party: perf + security-guidance
tcr_install_security_sweep      # third-party: read-only security-scan skill
tcr_install_playwright_mcp
tcr_setup_gh

if [ "${TCR_INSTALL_FAILED:-0}" = "1" ]; then
  tcr_warn "a plugin did not install automatically — run the 'claude plugin install' command(s) shown above, then restart Claude Code."
fi

printf '\n%sDone.%s Next:\n' "${_C_BOLD:-}" "${_C_OFF:-}"
printf '  1. Restart Claude Code so it loads the global CLAUDE.md and plugins.\n'
printf '  2. Run /plugin to confirm personal-tools, workflow, caveman, agent-sdk-dev, perf, security-guidance, and security-sweep are enabled.\n'
printf '  3. Run /mcp to confirm the Playwright server, and install gh (https://cli.github.com) + run gh auth login for GitHub.\n'
