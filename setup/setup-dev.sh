#!/usr/bin/env bash
#
# Developer setup for the team-code-review plugin.
# Run inside the project directory you want to set up:
#
#   curl -fsSL https://raw.githubusercontent.com/CrazyWillBear/code-review-plugin/main/setup/setup-dev.sh | bash
#
# or, from a local checkout:
#
#   bash setup/setup-dev.sh [--force] [--no-color]
#
# What it does (in the current directory):
#   - initializes a git repo if there isn't one
#   - writes technical CLAUDE.md + STYLEGUIDE.md (won't overwrite without --force)
#   - installs the team-code-review plugin and the caveman plugin (full mode)
#   - marks this project for technical review output

set -euo pipefail

REPO="CrazyWillBear/code-review-plugin"
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
      printf 'setup-dev.sh — developer setup for the team-code-review plugin.\n'
      printf 'Run inside the project directory you want to set up.\n'
      printf 'Options: --force (overwrite existing CLAUDE.md/STYLEGUIDE.md), --no-color\n'
      exit 0 ;;
    *) tcr_warn "ignoring unknown option: $arg" ;;
  esac
done
export TCR_FORCE TCR_LOCAL_ROOT

tcr_check_deps
tcr_step "Developer setup in: $(pwd)"
tcr_git_init
tcr_write_template dev/CLAUDE.md CLAUDE.md
tcr_write_template dev/STYLEGUIDE.md STYLEGUIDE.md
tcr_write_audience technical
tcr_install_review_plugin
tcr_install_caveman

if [ "${TCR_INSTALL_FAILED:-0}" = "1" ]; then
  tcr_warn "a plugin did not install automatically — run the 'claude plugin install' command(s) shown above, then restart Claude Code."
fi

printf '\n%sDone.%s Next:\n' "${_C_BOLD:-}" "${_C_OFF:-}"
printf '  1. Restart Claude Code so it loads the plugins.\n'
printf '  2. Fill in the <...> placeholders in CLAUDE.md and STYLEGUIDE.md.\n'
printf '  3. Edit a file and finish a turn — the code review runs automatically.\n'
