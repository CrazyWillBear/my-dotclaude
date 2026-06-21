#!/usr/bin/env bash
#
# Tests for scripts/update-kit.sh
#
# Black-box: we stub `claude` on PATH so it logs every invocation to a file and
# point HOME at a sandbox, then assert:
#   1. `claude plugin marketplace update my-dotclaude` is called first.
#   2. `claude plugin update personal-tools` is called second.
#   3. `claude plugin update workflow` is called third.
#   4. The restart reminder is printed to stdout.
#   5. The script exits 0.
#   6. The status line is refreshed from the marketplace's local repo copy:
#      ~/.claude/statusline.py is written (matching global/statusline.py) and
#      the statusLine block is merged into ~/.claude/settings.json.
#   7. When the marketplace copy can't be located, the refresh is skipped
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
echo "test: exactly three claude invocations are made"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    count=$(wc -l < "$CLAUDE_STUB_LOG")
    assert_equals "three claude calls recorded" "$count" "3"
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
echo "test: second call is 'claude plugin update personal-tools'"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    second=$(sed -n '2p' "$CLAUDE_STUB_LOG")
    assert_equals "second call: update personal-tools" "$second" "plugin update personal-tools"
else
    no "cannot check second call — log missing"
fi

# ---------------------------------------------------------------------------
echo "test: third call is 'claude plugin update workflow'"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    third=$(sed -n '3p' "$CLAUDE_STUB_LOG")
    assert_equals "third call: update workflow" "$third" "plugin update workflow"
else
    no "cannot check third call — log missing"
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
# Graceful skip: a sandbox with no known_marketplaces.json must not error.
# ---------------------------------------------------------------------------
echo "test: missing marketplace metadata -> refresh skipped, still succeeds"
EMPTY_HOME="$WORK/empty-home"
mkdir -p "$EMPTY_HOME/.claude"
rm -f "$CLAUDE_STUB_LOG"
out2=$(PATH="$WORK/bin:$PATH" HOME="$EMPTY_HOME" bash "$SCRIPT" 2>&1)
rc2=$?
assert_equals "exit 0 even without marketplace metadata" "$rc2" "0"
assert_contains "still prints restart reminder" "$out2" "Restart"
assert_not_contains "no statusline written without metadata" \
    "$(ls "$EMPTY_HOME/.claude" 2>/dev/null)" "statusline.py"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
