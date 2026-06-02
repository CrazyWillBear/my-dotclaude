#!/usr/bin/env bash
#
# Non-developer setup — installs the full Claude Code kit into ~/.claude, tuned
# for someone who does not write code: the global CLAUDE.md (plain-English), the
# team-code-review + personal-tools + caveman + agent-sdk-dev plugins, the
# Playwright MCP server, a read-only gh (GitHub CLI) allowlist, caveman set to
# its gentler "lite" level, and review summaries written in plain language. User
# scope — not tied to any one project. (Model is left at Claude Code's default.)
#
#   curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-simple.sh | bash
#
# or, from a local checkout:
#
#   bash setup/setup-simple.sh [--force] [--no-color]
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
      printf 'setup-simple.sh — non-developer setup: the full Claude Code kit at ~/.claude with plain-English output.\n'
      printf 'Writes ~/.claude/CLAUDE.md (plain), installs the plugins + Playwright MCP + gh allowlist, caveman lite, plain review output.\n'
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

tcr_step "Setting up your Claude Code in: $HOME/.claude"
tcr_install_global_claudemd templates/simple/CLAUDE.md
tcr_install_review_plugin       # also adds our marketplace
tcr_install_personal_tools      # reuses the marketplace added above
tcr_install_caveman
tcr_install_agent_sdk_dev
tcr_install_playwright_mcp
tcr_setup_gh
tcr_set_caveman_level lite
tcr_write_global_audience plain

if [ "${TCR_INSTALL_FAILED:-0}" = "1" ]; then
  tcr_warn "a helper did not install automatically — run the 'claude plugin install' command(s) shown above, then restart Claude Code."
fi

printf '\n%sAll set!%s Here is what to do next:\n' "${_C_BOLD:-}" "${_C_OFF:-}"
printf '  1. Close and reopen Claude Code so the new helpers load.\n'
printf '  2. Just tell Claude what you want to build — in plain English.\n'
printf '  3. Claude will handle the technical parts and check its own work for you.\n'
