#!/usr/bin/env bash
# Shared helpers for the my-dotclaude setup scripts (setup-dev.sh / setup-simple.sh).
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
# Anthropic's official marketplace ships with Claude Code (usually already registered);
# agent-sdk-dev scaffolds new Claude Agent SDK apps.
OFFICIAL_MARKETPLACE_REPO="anthropics/claude-plugins-official"
AGENT_SDK_PLUGIN="agent-sdk-dev@claude-plugins-official"
# Playwright MCP server (browser automation), added at user scope via `claude mcp add`.
PLAYWRIGHT_MCP_PKG="@playwright/mcp@latest"

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
# Project-scope helper. Unused by the shipped user-wide setup; retained for a
# future project-scope /scaffold-* skill (see templates/dev/).

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
# Project-scope helper, unused by the shipped user-wide setup (retained for a
# future /scaffold-* skill).

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

# Installs agent-sdk-dev from Anthropic's official marketplace (Claude Agent SDK scaffolder).
tcr_install_agent_sdk_dev() {
  tcr_step "Installing the agent-sdk-dev plugin"
  tcr_add_marketplace "$OFFICIAL_MARKETPLACE_REPO"
  if claude plugin install "$AGENT_SDK_PLUGIN" >/dev/null 2>&1; then
    tcr_ok "enabled $AGENT_SDK_PLUGIN"
  else
    TCR_INSTALL_FAILED=1
    tcr_warn "could not install $AGENT_SDK_PLUGIN automatically — run: claude plugin install $AGENT_SDK_PLUGIN"
  fi
}

# --- MCP servers + GitHub CLI access -----------------------------------------

# Adds the Playwright MCP server (browser automation) at user scope. Idempotent:
# skips when already configured. No secret involved.
tcr_install_playwright_mcp() {
  tcr_step "Adding the Playwright MCP server (user scope)"
  if claude mcp get playwright >/dev/null 2>&1; then
    tcr_ok "playwright MCP already configured"
    return 0
  fi
  if claude mcp add playwright -s user -- npx "$PLAYWRIGHT_MCP_PKG" >/dev/null 2>&1; then
    tcr_ok "added playwright MCP"
  else
    TCR_INSTALL_FAILED=1
    tcr_warn "could not add the playwright MCP automatically — run: claude mcp add playwright -s user -- npx $PLAYWRIGHT_MCP_PKG"
  fi
}

# GitHub access uses the gh CLI, not a GitHub MCP server: on a machine with gh,
# gh + Bash already cover the whole GitHub API, so an MCP would only add a managed
# token and per-session tool-schema overhead. This adds a read-only gh allowlist (so
# common reads do not prompt) and checks that gh is installed and authenticated.
tcr_setup_gh() {
  tcr_step "Configuring gh (GitHub CLI) access"
  # Read-only subcommands only. gh api is intentionally omitted — it can POST/DELETE,
  # so it is not read-only under prefix matching.
  tcr_add_permissions \
    "Bash(gh pr view:*)" "Bash(gh pr list:*)" "Bash(gh pr diff:*)" "Bash(gh pr checks:*)" \
    "Bash(gh issue view:*)" "Bash(gh issue list:*)" "Bash(gh repo view:*)" \
    "Bash(gh run view:*)" "Bash(gh run list:*)" "Bash(gh release view:*)" \
    "Bash(gh search:*)" "Bash(gh auth status:*)"
  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      tcr_ok "gh is installed and authenticated"
    else
      tcr_warn "gh is installed but not logged in — run: gh auth login"
    fi
  else
    tcr_warn "gh (GitHub CLI) not found — install it from https://cli.github.com and run 'gh auth login'. Claude uses gh for GitHub (there is no GitHub MCP)."
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
# Project-scope helper, unused by the shipped user-wide setup (retained for a
# future /scaffold-* skill). The user-wide default lives at ~/.claude (see
# tcr_write_global_audience).

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
  tcr_merge_json_string "$(tcr_caveman_config_path)" defaultMode "$1"
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

# tcr_install_global_claudemd [<source-relpath>] — write a CLAUDE.md source
# (default home/CLAUDE.md; non-dev passes templates/simple/CLAUDE.md) to
# ~/.claude/CLAUDE.md. Backs up and skips an existing file unless TCR_FORCE=1.
tcr_install_global_claudemd() {
  local src="${1:-home/CLAUDE.md}"
  local dest="$HOME/.claude/CLAUDE.md"
  mkdir -p "$HOME/.claude"
  if [ -e "$dest" ] && [ "${TCR_FORCE:-0}" != "1" ]; then
    tcr_warn "$dest already exists — leaving it untouched (use --force to overwrite)."
    return 0
  fi
  tcr_backup_file "$dest"
  if [ -n "${TCR_LOCAL_ROOT:-}" ] && [ -f "$TCR_LOCAL_ROOT/$src" ]; then
    cp "$TCR_LOCAL_ROOT/$src" "$dest"
  else
    curl -fsSL "$RAW_BASE/$src" -o "$dest" \
      || tcr_die "Could not download $src from $RAW_BASE."
  fi
  tcr_ok "wrote $dest"
}

# tcr_write_global_audience <plain|technical> — write ~/.claude/review-audience,
# the user-wide review-output default (the review hook falls back to it when a
# project has no .claude/review-audience). Backs up an existing marker.
tcr_write_global_audience() {
  local dest="$HOME/.claude/review-audience"
  mkdir -p "$HOME/.claude"
  tcr_backup_file "$dest"
  printf '%s\n' "$1" > "$dest"
  tcr_ok "set user-wide review style to '$1' ($dest)"
}

# tcr_merge_json_string <cfg> <key> <string-value>
# Merge one string key into a JSON object file, preserving every other key.
# Creates the file when absent. Never overwrites a non-empty file it cannot
# parse — it warns and leaves that file untouched, so it can't silently eat an
# existing config (settings.json hooks/permissions, caveman settings, …). Backs
# up before a successful overwrite.
tcr_merge_json_string() {
  local cfg="$1" key="$2" value="$3"
  mkdir -p "$(dirname "$cfg")"

  if ! command -v python3 >/dev/null 2>&1; then
    if [ ! -s "$cfg" ]; then
      printf '{\n  "%s": "%s"\n}\n' "$key" "$value" > "$cfg"
      tcr_ok "set $key = \"$value\" ($cfg)"
    else
      tcr_warn "python3 not found and $cfg already exists — set \"$key\": \"$value\" in it manually."
    fi
    return 0
  fi

  # python3 merges the key in, backs the file up only when it's about to
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
    tcr_warn "$cfg isn't plain JSON (comments or a trailing comma?) — left it untouched; set \"$key\": \"$value\" in it manually."
    return 0
  elif [ "$rc" -ne 0 ]; then
    tcr_die "failed to update $cfg (python3 exit $rc)."
  fi
  [ -n "$bak" ] && tcr_ok "backed up $cfg -> $bak"
  tcr_ok "set $key = \"$value\" ($cfg)"
}

# tcr_set_setting <key> <string-value> — merge a setting into ~/.claude/settings.json.
tcr_set_setting() {
  tcr_merge_json_string "$HOME/.claude/settings.json" "$1" "$2"
}

# tcr_add_permissions <perm> [<perm> ...]
# Merge permission strings into .permissions.allow of ~/.claude/settings.json,
# preserving every other key and any existing allow entries (union, de-duped).
# Same safety as tcr_merge_json_string: never clobbers a non-empty file it cannot
# parse, and backs up before a successful overwrite.
tcr_add_permissions() {
  local cfg="$HOME/.claude/settings.json"
  mkdir -p "$(dirname "$cfg")"
  # Pass the permissions as a newline-joined env var so no literal quote reaches python.
  local perms
  perms="$(printf '%s\n' "$@")"

  if ! command -v python3 >/dev/null 2>&1; then
    tcr_warn "python3 not found — add these to permissions.allow in $cfg manually: $*"
    return 0
  fi

  local bak rc=0
  bak="$(TCR_CFG="$cfg" TCR_PERMS="$perms" python3 - <<'PY'
import json, os, shutil, sys, time

cfg = os.environ["TCR_CFG"]
perms = [p for p in os.environ["TCR_PERMS"].splitlines() if p]

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

block = data.get("permissions")
if not isinstance(block, dict):
    block = {}
allow = block.get("allow")
if not isinstance(allow, list):
    allow = []
for p in perms:
    if p not in allow:
        allow.append(p)
block["allow"] = allow
data["permissions"] = block
with open(cfg, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
)" || rc=$?

  if [ "$rc" -eq 3 ]; then
    tcr_warn "$cfg isn't plain JSON (comments or a trailing comma?) — left it untouched; add these to permissions.allow manually: $*"
    return 0
  elif [ "$rc" -ne 0 ]; then
    tcr_die "failed to update $cfg (python3 exit $rc)."
  fi
  [ -n "$bak" ] && tcr_ok "backed up $cfg -> $bak"
  tcr_ok "added $# gh permission(s) to permissions.allow ($cfg)"
}
