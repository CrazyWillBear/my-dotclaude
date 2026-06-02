#!/usr/bin/env bash
# Shared helpers for the my-dotclaude setup scripts (setup-personal.sh / setup-dev.sh / setup-simple.sh).
#
# Source this from an entry script. Before sourcing, the entry script should set:
#   TCR_LOCAL_ROOT  - absolute path to a local repo checkout, or "" when unknown
#                     (e.g. run via `curl | bash`). When set, templates/plugin are
#                     taken from the local copy; otherwise they are fetched from GitHub.
#
# All functions are prefixed `tcr_` to avoid clobbering the caller's namespace.

REPO="CrazyWillBear/my-dotclaude"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"
OUR_MARKETPLACE="my-dotclaude"
OUR_PLUGIN="team-code-review@${OUR_MARKETPLACE}"
PERSONAL_PLUGIN="personal-tools@${OUR_MARKETPLACE}"
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

# Installs personal-tools. Assumes our marketplace is already added (call
# tcr_install_review_plugin first, or tcr_add_marketplace, before this).
tcr_install_personal_tools() {
  tcr_step "Installing the personal-tools plugin"
  if claude plugin install "$PERSONAL_PLUGIN" >/dev/null 2>&1; then
    tcr_ok "enabled $PERSONAL_PLUGIN"
  else
    TCR_INSTALL_FAILED=1
    tcr_warn "could not install $PERSONAL_PLUGIN automatically — run: claude plugin install $PERSONAL_PLUGIN"
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

# --- global (~/.claude) install ----------------------------------------------

# tcr_backup_file <path> — copy to <path>.bak.<timestamp> when it exists.
tcr_backup_file() {
  if [ -e "$1" ]; then
    local bak
    bak="$1.bak.$(date +%Y%m%d%H%M%S)"
    cp "$1" "$bak"
    tcr_ok "backed up $1 -> $bak"
  fi
}

# tcr_install_global_claudemd — write home/CLAUDE.md to ~/.claude/CLAUDE.md.
# Backs up and skips an existing file unless TCR_FORCE=1.
tcr_install_global_claudemd() {
  local dest="$HOME/.claude/CLAUDE.md"
  mkdir -p "$HOME/.claude"
  if [ -e "$dest" ] && [ "${TCR_FORCE:-0}" != "1" ]; then
    tcr_warn "$dest already exists — leaving it untouched (use --force to overwrite)."
    return 0
  fi
  tcr_backup_file "$dest"
  if [ -n "${TCR_LOCAL_ROOT:-}" ] && [ -f "$TCR_LOCAL_ROOT/home/CLAUDE.md" ]; then
    cp "$TCR_LOCAL_ROOT/home/CLAUDE.md" "$dest"
  else
    curl -fsSL "$RAW_BASE/home/CLAUDE.md" -o "$dest" \
      || tcr_die "Could not download home/CLAUDE.md from $RAW_BASE."
  fi
  tcr_ok "wrote $dest"
}

# tcr_set_setting <key> <string-value> — merge one string setting into
# ~/.claude/settings.json, preserving everything else. Refuses to overwrite a
# non-empty file it cannot parse (so it never silently eats existing hooks or
# permissions), and backs up the file before a successful merge.
tcr_set_setting() {
  local key="$1" value="$2" cfg="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"

  if ! command -v python3 >/dev/null 2>&1; then
    if [ ! -s "$cfg" ]; then
      printf '{\n  "%s": "%s"\n}\n' "$key" "$value" > "$cfg"
      tcr_ok "set $key = \"$value\" ($cfg)"
    else
      tcr_warn "python3 not found and $cfg already exists — set \"$key\": \"$value\" in it manually."
    fi
    return 0
  fi

  # python3 reads the existing file, backs it up only when it's about to
  # overwrite real content, and prints the backup path (if any) on stdout.
  local bak rc=0
  bak="$(TCR_CFG="$cfg" TCR_KEY="$key" TCR_VALUE="$value" python3 - <<'PY'
import json, os, shutil, sys, time

cfg = os.environ["TCR_CFG"]
key = os.environ["TCR_KEY"]
value = os.environ["TCR_VALUE"]

data = {}
if os.path.exists(cfg):
    with open(cfg) as fh:
        raw = fh.read()
    if raw.strip():
        try:
            data = json.loads(raw)
        except ValueError:
            sys.exit(3)  # non-empty but unparseable — do not clobber
        if not isinstance(data, dict):
            sys.exit(3)
        bak = cfg + ".bak." + time.strftime("%Y%m%d%H%M%S")
        shutil.copy2(cfg, bak)
        print(bak)

data[key] = value
with open(cfg, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
)" || rc=$?

  if [ "$rc" -eq 3 ]; then
    tcr_die "existing $cfg isn't plain JSON (comments or a trailing comma?) — refusing to overwrite it. Add \"$key\": \"$value\" to it yourself."
  elif [ "$rc" -ne 0 ]; then
    tcr_die "failed to update $cfg (python3 exit $rc)."
  fi
  [ -n "$bak" ] && tcr_ok "backed up $cfg -> $bak"
  tcr_ok "set $key = \"$value\" ($cfg)"
}
