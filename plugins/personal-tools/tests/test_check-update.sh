#!/usr/bin/env bash
#
# Tests for scripts/check-update.sh
#
# Black-box: we stub `curl` on PATH and provide a temporary plugin.json, then assert:
#   1. When the API returns a newer tag, output names that tag and mentions /update-kit.
#   2. When the API returns the same tag, output says up to date.
#   3. When curl fails (network error), script exits 0 with no alarming error output.
#
# Run: bash plugins/personal-tools/tests/test_check-update.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/check-update.sh"

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
# Helper: build a fake plugin.json with a given version
# ---------------------------------------------------------------------------
make_plugin_json() {
    local dir="$1" version="$2"
    mkdir -p "$dir/.claude-plugin"
    cat > "$dir/.claude-plugin/plugin.json" <<JSON
{
  "name": "personal-tools",
  "version": "$version"
}
JSON
}

# ---------------------------------------------------------------------------
echo "test: script exists at the expected path"
if [ -f "$SCRIPT" ]; then
    ok "check-update.sh present at scripts/check-update.sh"
else
    no "check-update.sh missing at $SCRIPT"
fi

# ---------------------------------------------------------------------------
echo "test: script is executable"
if [ -x "$SCRIPT" ]; then
    ok "check-update.sh is executable"
else
    no "check-update.sh is not executable"
fi

# ---------------------------------------------------------------------------
# Case 1: API returns a newer tag — expect version name + /update-kit mention
# ---------------------------------------------------------------------------
echo "test: newer version available — reports new tag and names /update-kit"

FAKE_ROOT_1="$WORK/case1"
make_plugin_json "$FAKE_ROOT_1" "0.1.0"

mkdir -p "$WORK/bin1"
cat > "$WORK/bin1/curl" <<'STUB'
#!/usr/bin/env bash
# Return a GitHub releases API response with a newer tag
printf '{"tag_name":"v0.2.0"}'
exit 0
STUB
chmod +x "$WORK/bin1/curl"

out1=$(CLAUDE_PLUGIN_ROOT="$FAKE_ROOT_1" PATH="$WORK/bin1:$PATH" bash "$SCRIPT" 2>&1)
exit1=$?

assert_equals "newer: exits 0" "$exit1" "0"
assert_contains "newer: output contains new version" "$out1" "v0.2.0"
assert_contains "newer: output mentions /update-kit" "$out1" "/update-kit"

# ---------------------------------------------------------------------------
# Case 2: API returns the same tag — expect up to date message
# ---------------------------------------------------------------------------
echo "test: equal version — reports up to date"

FAKE_ROOT_2="$WORK/case2"
make_plugin_json "$FAKE_ROOT_2" "0.1.0"

mkdir -p "$WORK/bin2"
cat > "$WORK/bin2/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"tag_name":"v0.1.0"}'
exit 0
STUB
chmod +x "$WORK/bin2/curl"

out2=$(CLAUDE_PLUGIN_ROOT="$FAKE_ROOT_2" PATH="$WORK/bin2:$PATH" bash "$SCRIPT" 2>&1)
exit2=$?

assert_equals "equal: exits 0" "$exit2" "0"
assert_contains "equal: output says up to date" "$out2" "up to date"

# ---------------------------------------------------------------------------
# Case 3: Network / API failure (curl exits non-zero) — fail open
# ---------------------------------------------------------------------------
echo "test: network failure — exits 0, no error output"

FAKE_ROOT_3="$WORK/case3"
make_plugin_json "$FAKE_ROOT_3" "0.1.0"

mkdir -p "$WORK/bin3"
cat > "$WORK/bin3/curl" <<'STUB'
#!/usr/bin/env bash
# Simulate a network failure
exit 1
STUB
chmod +x "$WORK/bin3/curl"

out3=$(CLAUDE_PLUGIN_ROOT="$FAKE_ROOT_3" PATH="$WORK/bin3:$PATH" bash "$SCRIPT" 2>&1)
exit3=$?

assert_equals "network-fail: exits 0" "$exit3" "0"
assert_not_contains "network-fail: no 'error' in output" "$out3" "error"
assert_not_contains "network-fail: no 'Error' in output" "$out3" "Error"

# ---------------------------------------------------------------------------
# Case 4: API returns garbage JSON — fail open
# ---------------------------------------------------------------------------
echo "test: garbage API response — exits 0, no error output"

FAKE_ROOT_4="$WORK/case4"
make_plugin_json "$FAKE_ROOT_4" "0.1.0"

mkdir -p "$WORK/bin4"
cat > "$WORK/bin4/curl" <<'STUB'
#!/usr/bin/env bash
printf 'not json at all'
exit 0
STUB
chmod +x "$WORK/bin4/curl"

out4=$(CLAUDE_PLUGIN_ROOT="$FAKE_ROOT_4" PATH="$WORK/bin4:$PATH" bash "$SCRIPT" 2>&1)
exit4=$?

assert_equals "garbage-json: exits 0" "$exit4" "0"
assert_not_contains "garbage-json: no 'error' in output" "$out4" "error"
assert_not_contains "garbage-json: no 'Error' in output" "$out4" "Error"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
