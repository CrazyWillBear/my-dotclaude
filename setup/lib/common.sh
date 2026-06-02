#!/usr/bin/env bash
# Shared helpers for the team-code-review setup scripts (setup-dev.sh / setup-simple.sh).
#
# Source this from an entry script. Before sourcing, the entry script should set:
#   TCR_LOCAL_ROOT  - absolute path to a local repo checkout, or "" when unknown
#                     (e.g. run via `curl | bash`). When set, templates/plugin are
#                     taken from the local copy; otherwise they are fetched from GitHub.
#
# All functions are prefixed `tcr_` to avoid clobbering the caller's namespace.

REPO="CrazyWillBear/code-review-plugin"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"
OUR_MARKETPLACE="team-code-review"
OUR_PLUGIN="team-code-review@${OUR_MARKETPLACE}"
CAVEMAN_REPO="JuliusBrussee/caveman"
CAVEMAN_PLUGIN="caveman@caveman"

# Set to 1 when a plugin install genuinely fails, so the entry script can soften
# its closing "Done" banner instead of claiming success over a failed install.
TCR_INSTALL_FAILED=0

# --- logging -----------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _C_BLUE=$'\033[34m'; _C_GREEN=$'\033[32m'; _C_YELLOW=$'\033[33m'
  _C_RED=$'\033[31m'; _C_BOLD=$'\033[1m'; _C_OFF=$'\033[0m'
else
  _C_BLUE=""; _C_GREEN=""; _C_YELLOW=""; _C_RED=""; _C_BOLD=""; _C_OFF=""
fi

tcr_step() { printf '%s==>%s %s\n' "$_C_BLUE$_C_BOLD" "$_C_OFF" "$*"; }
tcr_ok()   { printf '%s  ok%s %s\n' "$_C_GREEN" "$_C_OFF" "$*"; }
tcr_warn() { printf '%swarn%s %s\n' "$_C_YELLOW" "$_C_OFF" "$*" >&2; }
tcr_die()  { printf '%serror%s %s\n' "$_C_RED" "$_C_OFF" "$*" >&2; exit 1; }

# --- dependencies ------------------------------------------------------------

tcr_require() {
  command -v "$1" >/dev/null 2>&1 || tcr_die "$1 is required but not found on PATH. $2"
}

tcr_check_deps() {
  tcr_require git "Install git, then re-run."
  tcr_require claude "Install Claude Code (the 'claude' CLI), then re-run."
  # curl is only needed for the remote-template path.
  if [ -z "${TCR_LOCAL_ROOT:-}" ]; then
    tcr_require curl "Install curl, or run this script from a local checkout of the repo."
  fi
}

# --- templates ---------------------------------------------------------------

# tcr_write_template <relpath-under-templates/> <dest-file>
# Copies from a local checkout when available, else downloads from GitHub.
# Never overwrites an existing dest unless TCR_FORCE=1.
tcr_write_template() {
  local rel="$1" dest="$2"
  if [ -e "$dest" ] && [ "${TCR_FORCE:-0}" != "1" ]; then
    tcr_warn "$dest already exists — leaving it untouched (use --force to overwrite)."
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  if [ -n "${TCR_LOCAL_ROOT:-}" ] && [ -f "$TCR_LOCAL_ROOT/templates/$rel" ]; then
    cp "$TCR_LOCAL_ROOT/templates/$rel" "$dest"
  else
    curl -fsSL "$RAW_BASE/templates/$rel" -o "$dest" \
      || tcr_die "Could not download template '$rel' from $RAW_BASE."
  fi
  tcr_ok "wrote $dest"
}

# --- git ---------------------------------------------------------------------

tcr_git_init() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tcr_ok "git repository already present"
  else
    git init -q
    tcr_ok "initialized a git repository"
  fi
}

# --- plugins -----------------------------------------------------------------

# tcr_add_marketplace <name-or-repo-or-path>
tcr_add_marketplace() {
  claude plugin marketplace add "$1" >/dev/null 2>&1 \
    || tcr_warn "could not add marketplace '$1' (it may already be registered)."
}

tcr_install_review_plugin() {
  tcr_step "Installing the team-code-review plugin"
  if [ -n "${TCR_LOCAL_ROOT:-}" ] && [ -f "$TCR_LOCAL_ROOT/.claude-plugin/marketplace.json" ]; then
    tcr_add_marketplace "$TCR_LOCAL_ROOT"
  else
    tcr_add_marketplace "$REPO"
  fi
  if claude plugin install "$OUR_PLUGIN" >/dev/null 2>&1; then
    tcr_ok "enabled $OUR_PLUGIN"
  else
    TCR_INSTALL_FAILED=1
    tcr_warn "could not install $OUR_PLUGIN automatically — run: claude plugin install $OUR_PLUGIN"
  fi
}

tcr_install_caveman() {
  tcr_step "Installing the caveman plugin"
  tcr_add_marketplace "$CAVEMAN_REPO"
  if claude plugin install "$CAVEMAN_PLUGIN" >/dev/null 2>&1; then
    tcr_ok "enabled $CAVEMAN_PLUGIN"
  else
    TCR_INSTALL_FAILED=1
    tcr_warn "could not install $CAVEMAN_PLUGIN automatically — run: claude plugin install $CAVEMAN_PLUGIN"
  fi
}

# --- project marker ----------------------------------------------------------

# tcr_write_audience <plain|technical>
tcr_write_audience() {
  mkdir -p .claude
  printf '%s\n' "$1" > .claude/review-audience
  tcr_ok "set review style to '$1' (.claude/review-audience)"
}

# --- caveman level -----------------------------------------------------------

tcr_caveman_config_path() {
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s/caveman/config.json' "$XDG_CONFIG_HOME"
  else
    printf '%s/.config/caveman/config.json' "$HOME"
  fi
}

# tcr_set_caveman_level <lite|full|ultra|...>
# Sets caveman's machine-wide default mode by merging into its config.json.
tcr_set_caveman_level() {
  local level="$1" cfg
  cfg="$(tcr_caveman_config_path)"
  mkdir -p "$(dirname "$cfg")"
  if command -v python3 >/dev/null 2>&1; then
    TCR_CFG="$cfg" TCR_LEVEL="$level" python3 - <<'PY'
import json, os
cfg = os.environ["TCR_CFG"]
level = os.environ["TCR_LEVEL"]
data = {}
try:
    with open(cfg) as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
data["defaultMode"] = level
with open(cfg, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
  elif [ ! -e "$cfg" ]; then
    printf '{\n  "defaultMode": "%s"\n}\n' "$level" > "$cfg"
  else
    tcr_warn "python3 not found and $cfg already exists — set caveman level manually: add \"defaultMode\": \"$level\"."
    return 0
  fi
  tcr_ok "set caveman default level to '$level' ($cfg)"
}
