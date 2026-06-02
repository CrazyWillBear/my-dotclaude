#!/usr/bin/env bash
#
# Non-developer setup for the team-code-review plugin.
# Run inside the (possibly empty) folder you want your project to live in:
#
#   curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-simple.sh | bash
#
# or, from a local checkout:
#
#   bash setup/setup-simple.sh [--force] [--no-color]
#
# What it does (in the current directory):
#   - initializes a git repo so your work is always saved
#   - writes a plain-English CLAUDE.md (no STYLEGUIDE — you don't write code)
#   - installs the team-code-review plugin and the caveman plugin (lite mode)
#   - marks this project for plain-language review summaries

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
      printf 'setup-simple.sh — non-developer setup for the team-code-review plugin.\n'
      printf 'Run inside the folder you want your project to live in.\n'
      printf 'Options: --force (overwrite an existing CLAUDE.md), --no-color\n'
      exit 0 ;;
    *) tcr_warn "ignoring unknown option: $arg" ;;
  esac
done
export TCR_FORCE TCR_LOCAL_ROOT

tcr_check_deps
tcr_step "Setting up your project in: $(pwd)"
tcr_git_init
tcr_write_template simple/CLAUDE.md CLAUDE.md
tcr_write_audience plain
tcr_install_review_plugin
tcr_install_caveman
tcr_set_caveman_level lite

if [ "${TCR_INSTALL_FAILED:-0}" = "1" ]; then
  tcr_warn "a helper did not install automatically — run the 'claude plugin install' command(s) shown above, then restart Claude Code."
fi

printf '\n%sAll set!%s Here is what to do next:\n' "${_C_BOLD:-}" "${_C_OFF:-}"
printf '  1. Close and reopen Claude Code so the new helpers load.\n'
printf '  2. Just tell Claude what you want to build — in plain English.\n'
printf '  3. Claude will handle the technical parts and check its own work for you.\n'
