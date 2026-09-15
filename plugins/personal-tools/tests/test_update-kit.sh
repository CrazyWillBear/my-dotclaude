#!/usr/bin/env bash
#
# Tests for scripts/update-kit.sh
#
# Black-box: we stub `claude` on PATH so it logs every invocation to a file and
# point HOME at a sandbox, then assert:
#   1. `claude plugin marketplace update my-dotclaude` is called first.
#   2. every plugin listed in .claude-plugin/marketplace.json is then updated
#      (derived, not hardcoded to personal-tools/workflow — a third plugin in
#      the manifest must be updated too).
#   3. The restart reminder is printed to stdout.
#   4. The script exits 0.
#   5. The status line is refreshed from the marketplace's local repo copy:
#      ~/.claude/statusline.py is written (matching global/statusline.py) and
#      the statusLine block is merged into ~/.claude/settings.json.
#   6. When the marketplace copy can't be located, the refresh is skipped
#      gracefully — the script still exits 0 and prints the restart reminder.
#
# Run: bash plugins/personal-tools/tests/test_update-kit.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/update-kit.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }

# ---------------------------------------------------------------------------
# Build a stub `claude` that appends each invocation as a line to $WORK/calls.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/claude" <<'STUB'
#!/usr/bin/env bash
# Stub claude: record each invocation (all args on one line) then exit 0.
printf '%s\n' "$*" >> "$CLAUDE_STUB_LOG"
exit 0
STUB
chmod +x "$WORK/bin/claude"

export CLAUDE_STUB_LOG="$WORK/calls"

# ---------------------------------------------------------------------------
echo "test: script exists at the expected path"
if [ -f "$SCRIPT" ]; then
    ok "update-kit.sh present at scripts/update-kit.sh"
else
    no "update-kit.sh missing at $SCRIPT"
fi

# ---------------------------------------------------------------------------
echo "test: script is executable"
if [ -x "$SCRIPT" ]; then
    ok "update-kit.sh is executable"
else
    no "update-kit.sh is not executable"
fi

# ---------------------------------------------------------------------------
# A sandbox HOME whose known_marketplaces.json points the my-dotclaude
# marketplace at THIS repo checkout — so the status-line refresh copies the
# real global/statusline.py and reuses the real setup/lib/common.sh installer.
# ---------------------------------------------------------------------------
HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR/.claude/plugins"
cat > "$HOME_DIR/.claude/plugins/known_marketplaces.json" <<EOF
{
  "my-dotclaude": {
    "source": { "source": "directory", "path": "$REPO_ROOT" },
    "installLocation": "$REPO_ROOT"
  }
}
EOF

# ---------------------------------------------------------------------------
# Run the script with the stub claude on PATH and the sandbox HOME.
# ---------------------------------------------------------------------------
rm -f "$CLAUDE_STUB_LOG"
out=$(PATH="$WORK/bin:$PATH" HOME="$HOME_DIR" bash "$SCRIPT" 2>&1)
exit_code=$?

# ---------------------------------------------------------------------------
echo "test: script exits 0"
if [ "$exit_code" -eq 0 ]; then
    ok "exit code is 0"
else
    no "exit code is $exit_code (want 0)"
fi

# ---------------------------------------------------------------------------
echo "test: one marketplace-update call plus one plugin-update call per manifest plugin"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    count=$(wc -l < "$CLAUDE_STUB_LOG")
    assert_equals "three claude calls recorded (marketplace + 2 real plugins)" "$count" "3"
else
    no "no claude calls recorded (log missing)"
fi

# ---------------------------------------------------------------------------
echo "test: first call is 'claude plugin marketplace update my-dotclaude'"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    first=$(sed -n '1p' "$CLAUDE_STUB_LOG")
    assert_equals "first call: marketplace update" "$first" "plugin marketplace update my-dotclaude"
else
    no "cannot check first call — log missing"
fi

# ---------------------------------------------------------------------------
echo "test: personal-tools and workflow are each updated (order not asserted)"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    calls="$(cat "$CLAUDE_STUB_LOG")"
    assert_contains "updates personal-tools" "$calls" "plugin update personal-tools"
    assert_contains "updates workflow"       "$calls" "plugin update workflow"
else
    no "cannot check plugin update calls — log missing"
fi

# ---------------------------------------------------------------------------
echo "test: a third plugin in the manifest is updated too — not hardcoded to personal-tools/workflow"
THIRD_HOME="$WORK/third-home"
FAKE_ROOT="$WORK/fakerepo"
mkdir -p "$THIRD_HOME/.claude/plugins" "$FAKE_ROOT/.claude-plugin" "$FAKE_ROOT/setup/lib" "$FAKE_ROOT/global"
cp "$REPO_ROOT/setup/lib/common.sh" "$FAKE_ROOT/setup/lib/common.sh"
cp "$REPO_ROOT/global/statusline.py" "$FAKE_ROOT/global/statusline.py"
cat > "$FAKE_ROOT/.claude-plugin/marketplace.json" <<'EOF'
{
  "plugins": [
    {"name": "personal-tools"},
    {"name": "workflow"},
    {"name": "context"}
  ]
}
EOF
cat > "$THIRD_HOME/.claude/plugins/known_marketplaces.json" <<EOF
{
  "my-dotclaude": {
    "source": { "source": "directory", "path": "$FAKE_ROOT" },
    "installLocation": "$FAKE_ROOT"
  }
}
EOF
rm -f "$CLAUDE_STUB_LOG"
out3=$(PATH="$WORK/bin:$PATH" HOME="$THIRD_HOME" bash "$SCRIPT" 2>&1)
rc3=$?
assert_equals "exits 0 with a third plugin in the manifest" "$rc3" "0"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    calls3="$(cat "$CLAUDE_STUB_LOG")"
    count3=$(wc -l < "$CLAUDE_STUB_LOG")
    assert_equals "four claude calls (marketplace + 3 plugins)" "$count3" "4"
    assert_contains "updates the third, unnamed plugin" "$calls3" "plugin update context"
else
    no "no claude calls recorded for the third-plugin manifest"
fi

# ---------------------------------------------------------------------------
echo "test: output includes a restart reminder"
assert_contains "restart reminder in output" "$out" "Restart"

# ---------------------------------------------------------------------------
echo "test: restart reminder mentions Claude Code"
assert_contains "restart reminder mentions Claude Code" "$out" "Claude Code"

# ---------------------------------------------------------------------------
echo "test: status line is refreshed from the marketplace repo copy"
if [ -f "$HOME_DIR/.claude/statusline.py" ]; then
    if diff -q "$HOME_DIR/.claude/statusline.py" "$REPO_ROOT/global/statusline.py" >/dev/null; then
        ok "statusline.py installed and matches global/statusline.py"
    else
        no "statusline.py installed but differs from global/statusline.py"
    fi
else
    no "statusline.py was not written to the sandbox ~/.claude"
fi

# ---------------------------------------------------------------------------
echo "test: settings.json gets the statusLine wiring"
if [ -f "$HOME_DIR/.claude/settings.json" ]; then
    settings="$(cat "$HOME_DIR/.claude/settings.json")"
    assert_contains "settings.json has statusLine" "$settings" '"statusLine"'
    assert_contains "statusLine points at statusline.py" "$settings" "statusline.py"
else
    no "settings.json was not written to the sandbox ~/.claude"
fi

# ---------------------------------------------------------------------------
# No known_marketplaces.json + no network: must not error, and must not
# silently claim success while doing nothing dangerous — just skip.
# ---------------------------------------------------------------------------
echo "test: missing marketplace metadata and no network -> refresh skipped, still succeeds"
EMPTY_HOME="$WORK/empty-home"
mkdir -p "$EMPTY_HOME/.claude"
mkdir -p "$WORK/offline-stubs"
cat > "$WORK/offline-stubs/curl" <<'EOF'
#!/usr/bin/env bash
# Stub curl: simulate no network for the common.sh bootstrap fetch.
exit 1
EOF
chmod +x "$WORK/offline-stubs/curl"
rm -f "$CLAUDE_STUB_LOG"
out2=$(PATH="$WORK/offline-stubs:$WORK/bin:$PATH" HOME="$EMPTY_HOME" bash "$SCRIPT" 2>&1)
rc2=$?
assert_equals "exit 0 even without marketplace metadata or network" "$rc2" "0"
assert_contains "still prints restart reminder" "$out2" "Restart"
assert_not_contains "no statusline written without metadata or network" \
    "$(ls "$EMPTY_HOME/.claude" 2>/dev/null)" "statusline.py"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    assert_equals "only the marketplace-update call, no plugin updates" \
        "$(wc -l < "$CLAUDE_STUB_LOG")" "1"
else
    no "no claude calls recorded (log missing)"
fi

# ---------------------------------------------------------------------------
# No known_marketplaces.json, but the network is up: update-kit.sh must fall
# back to fetching setup/lib/common.sh remotely (same bootstrap setup-dev.sh
# uses) rather than silently skipping every plugin update — the round-2 fix
# for the regression where the old hardcoded two-plugin update always ran.
# ---------------------------------------------------------------------------
echo "test: missing marketplace metadata but network up -> derives plugin list via remote common.sh, still updates every plugin"
REMOTE_HOME="$WORK/remote-home"
mkdir -p "$REMOTE_HOME/.claude"
mkdir -p "$WORK/remote-stubs"
cat > "$WORK/remote-stubs/curl" <<'EOF'
#!/usr/bin/env bash
# Stub curl: serve a minimal common.sh fixture (defining just the two
# functions update-kit.sh needs) for any setup/lib/common.sh URL.
out=""
url=""
for ((i = 1; i <= $#; i++)); do
    case "${!i}" in
        -o) j=$((i + 1)); out="${!j}" ;;
        http*://*) url="${!i}" ;;
    esac
done
case "$url" in
    *setup/lib/common.sh)
        cat > "$out" <<'SH'
tcr_our_plugin_names() { printf 'personal-tools\nworkflow\nremote-third\n'; }
tcr_install_statusline() { :; }
SH
        exit 0
        ;;
esac
exit 1
EOF
chmod +x "$WORK/remote-stubs/curl"
rm -f "$CLAUDE_STUB_LOG"
out3r=$(PATH="$WORK/remote-stubs:$WORK/bin:$PATH" HOME="$REMOTE_HOME" bash "$SCRIPT" 2>&1)
rc3r=$?
assert_equals "exit 0 with the remote common.sh fallback" "$rc3r" "0"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    calls3r="$(cat "$CLAUDE_STUB_LOG")"
    assert_contains "remote fallback still updates personal-tools" "$calls3r" "plugin update personal-tools"
    assert_contains "remote fallback still updates workflow"       "$calls3r" "plugin update workflow"
    assert_contains "remote fallback updates a plugin not hardcoded here" "$calls3r" "plugin update remote-third"
else
    no "no claude calls recorded for the remote-fallback path"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
