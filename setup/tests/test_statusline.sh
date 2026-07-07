#!/usr/bin/env bash
#
# Tests for global/statusline.py — the default status line renderer.
#
# Black-box: pipe a sample Claude Code stdin JSON into the script with a
# controlled HOME / CLAUDE_CONFIG_DIR / XDG_CACHE_HOME (so the real machine's
# caveman flag and update cache never leak in) and assert on the printed line.
#
# Covers: dir (~-relative), git branch (+ non-repo omits it), model, effort
# level (+ absent-hides), token formatting + 0k fallback, cost, caveman fold
# (+ symlink refusal), and the update flag.
#
# Run: bash setup/tests/test_statusline.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SL="$ROOT/global/statusline.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Empty scratch config/cache so caveman + update segments stay off by default.
EMPTY_CFG="$WORK/empty-cfg"; mkdir -p "$EMPTY_CFG"
EMPTY_CACHE="$WORK/empty-cache"; mkdir -p "$EMPTY_CACHE"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
has()    { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
has_not() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# run_sl <json> — render with the empty scratch config/cache + given HOME.
run_sl() {
  printf '%s' "$1" | HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$EMPTY_CFG" \
    XDG_CACHE_HOME="$EMPTY_CACHE" python3 "$SL"
}

# A git repo under HOME, with one commit so HEAD resolves to a branch name.
HOME_DIR="$WORK/home"; mkdir -p "$HOME_DIR"
REPO="$HOME_DIR/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init

# ---- test: full render ------------------------------------------------------
echo "test: full render"
json='{"model":{"display_name":"Opus 4.8"},"effort":{"level":"high"},"workspace":{"current_dir":"'"$REPO"'"},"context_window":{"total_input_tokens":47000},"cost":{"total_cost_usd":0.42}}'
out=$(run_sl "$json")
has "dir is ~-relative"     "$out" "~/repo"
has "git branch shown"      "$out" "⎇ main"
has "model shown"           "$out" "Opus 4.8"
has "effort level shown"    "$out" "high"
has "tokens k-formatted"    "$out" "47k"
has "cost shown"            "$out" "\$0.42"
has "tokens/cost combined"  "$out" "47k / \$0.42"
has_not "line churn removed" "$out" "+0/-0"

# ---- test: control chars stripped from human-text segments -----------------
# A directory name can legally contain an ESC byte; the model/style names
# arrive on stdin. None may smuggle a terminal escape into the rendered line.
# The ESC bytes are carried as JSON \u001b escapes (a raw ESC byte would make
# the JSON invalid and short-circuit to the empty-data fallback, exercising
# nothing). The dim separator legitimately uses ESC "[2m"/"[0m", so we assert
# on the *injected* sequences specifically (ESC "[31m", ESC "[2J").
echo "test: control-char/escape stripping"
esc=$(printf '\033')
json='{"model":{"display_name":"Op\u001b[31mus"},"workspace":{"current_dir":"'"$HOME_DIR"'/p\u001b[2Jlain"}}'
out=$(run_sl "$json")
case "$out" in *"${esc}[31m"*) no "injected ESC[31m stripped" ;; *) ok "injected ESC[31m stripped" ;; esac
case "$out" in *"${esc}[2J"*)  no "injected ESC[2J stripped"  ;; *) ok "injected ESC[2J stripped"  ;; esac
has "separator ESC preserved" "$out" "${esc}[2m"

# ---- test: effort absent -> no effort segment ------------------------------
echo "test: effort absent -> segment hidden"
json='{"model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"'"$REPO"'"},"context_window":{"total_input_tokens":47000},"cost":{"total_cost_usd":0.42}}'
out=$(run_sl "$json")
has "model still shown"     "$out" "Opus 4.8"
has_not "no stray effort seg when absent" "$out" "medium"

# ---- test: token fallback when context_window absent ------------------------
echo "test: token fallback -> 0k"
json='{"model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"'"$REPO"'"},"cost":{"total_cost_usd":0}}'
out=$(run_sl "$json")
has "missing context_window -> 0k" "$out" "0k"

# ---- test: non-repo dir omits branch ---------------------------------------
echo "test: non-repo dir -> no branch segment"
PLAIN="$HOME_DIR/plain"; mkdir -p "$PLAIN"
json='{"model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"'"$PLAIN"'"}}'
out=$(run_sl "$json")
has_not "no branch glyph" "$out" "⎇"
has "still shows dir" "$out" "~/plain"

# ---- test: caveman fold -----------------------------------------------------
echo "test: caveman fold"
CFG="$WORK/cfg-cave"; mkdir -p "$CFG"
printf 'lite\n' > "$CFG/.caveman-active"
json='{"model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"'"$PLAIN"'"}}'
out=$(printf '%s' "$json" | HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$CFG" XDG_CACHE_HOME="$EMPTY_CACHE" python3 "$SL")
has "caveman:lite shown" "$out" "caveman:lite"

echo "test: caveman flag via symlink -> ignored"
CFG2="$WORK/cfg-link"; mkdir -p "$CFG2"
printf 'lite\n' > "$WORK/secret-mode"
ln -s "$WORK/secret-mode" "$CFG2/.caveman-active"
out=$(printf '%s' "$json" | HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$CFG2" XDG_CACHE_HOME="$EMPTY_CACHE" python3 "$SL")
has_not "symlinked flag ignored" "$out" "caveman"

# ---- test: cost resets on /clear (session_id change) -----------------------
# cost.total_cost_usd is process-scoped and survives /clear; the renderer
# anchors a per-session baseline and subtracts it, so the shown cost resets
# when session_id changes and re-arms when the raw total drops (new process).
echo "test: cost baseline reset on session change"
COSTC="$WORK/cache-cost"; mkdir -p "$COSTC"
cost_sl() {  # cost_sl <session_id> <total_cost_usd>
  printf '{"model":{"display_name":"Opus 4.8"},"session_id":"%s","workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":%s}}' \
    "$1" "$PLAIN" "$2" | HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$EMPTY_CFG" \
    XDG_CACHE_HOME="$COSTC" python3 "$SL"
}
has     "first sighting anchors baseline -> \$0.00" "$(cost_sl sessA 0.42)" "\$0.00"
has     "same session shows delta -> \$0.08"        "$(cost_sl sessA 0.50)" "\$0.08"
has     "new session_id (/clear) resets -> \$0.00"  "$(cost_sl sessB 0.55)" "\$0.00"
has     "cost climbs in new session -> \$0.05"      "$(cost_sl sessB 0.60)" "\$0.05"
has     "raw total drop re-arms -> \$0.00"          "$(cost_sl sessB 0.02)" "\$0.00"

echo "test: cost without session_id shows raw total"
json='{"model":{"display_name":"Opus 4.8"},"session_id":"","workspace":{"current_dir":"'"$PLAIN"'"},"cost":{"total_cost_usd":0.77}}'
out=$(printf '%s' "$json" | HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$EMPTY_CFG" XDG_CACHE_HOME="$COSTC" python3 "$SL")
has "no session_id -> raw cost" "$out" "\$0.77"

# ---- test: update flag ------------------------------------------------------
echo "test: update flag"
CACHE="$WORK/cache-upd"; mkdir -p "$CACHE/my-dotclaude"
printf 'v9.9.9 available — run /update-kit to upgrade' > "$CACHE/my-dotclaude/last-check.json"
json='{"model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"'"$PLAIN"'"}}'
out=$(printf '%s' "$json" | HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$EMPTY_CFG" XDG_CACHE_HOME="$CACHE" python3 "$SL")
has "update flag shown" "$out" "⬆ update"

echo "test: up-to-date cache -> no update flag"
printf 'kit is up to date (v0.2.1)' > "$CACHE/my-dotclaude/last-check.json"
out=$(printf '%s' "$json" | HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$EMPTY_CFG" XDG_CACHE_HOME="$CACHE" python3 "$SL")
has_not "no update flag when current" "$out" "update"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
