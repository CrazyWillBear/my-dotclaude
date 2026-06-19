#!/usr/bin/env bash
#
# Tests for scripts/notify-update.sh — the SessionStart update-notify hook.
#
# Black-box (watchdog-test style): we stub `curl` on PATH, point the throttle
# cache at an isolated dir via NOTIFY_UPDATE_CACHE_DIR, feed a SessionStart hook
# payload on stdin, run the real hook, and assert on the JSON it prints plus the
# cache file it writes:
#   1. Newer release available -> emits a notice naming the version + /update-kit.
#   2. Already up to date       -> stays silent.
#   3. Throttle: a second call within the window does NOT re-hit the network.
#   4. Network error            -> fail-open: exits 0, no alarming output, no error.
#
# The hook REUSES scripts/check-update.sh for the version check/compare — these
# tests stub the same `curl` seam check-update.sh uses, never the compare itself.
#
# Run: bash plugins/personal-tools/tests/test_notify-update.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PLUGIN_ROOT/scripts/notify-update.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_empty()        { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected silence, got: $2)"; fi; }
assert_file()         { if [ -f "$2" ]; then ok "$1"; else no "$1 (missing file $2)"; fi; }

# ---------------------------------------------------------------------------
# Helper: build a fake plugin.json with a given installed version
# ---------------------------------------------------------------------------
make_plugin_json() {
    local dir="$1" version="$2"
    mkdir -p "$dir/scripts" "$dir/.claude-plugin"
    cat > "$dir/.claude-plugin/plugin.json" <<JSON
{
  "name": "personal-tools",
  "version": "$version"
}
JSON
    # The hook resolves check-update.sh under its own plugin root, so symlink the
    # real script into the fake root so the reuse path is exercised verbatim.
    ln -sf "$PLUGIN_ROOT/scripts/check-update.sh" "$dir/scripts/check-update.sh"
    ln -sf "$HOOK" "$dir/scripts/notify-update.sh"
}

# Helper: a curl stub that records each invocation to a hit-log, so we can prove
# the throttle prevents a second network call.
make_curl() {
    local bindir="$1" tag="$2" hitlog="$3" mode="${4:-ok}"
    mkdir -p "$bindir"
    cat > "$bindir/curl" <<STUB
#!/usr/bin/env bash
echo hit >> "$hitlog"
$( [ "$mode" = "fail" ] && printf 'exit 1' || printf "printf '{\"tag_name\":\"%s\"}'" "$tag" )
STUB
    chmod +x "$bindir/curl"
}

# run_hook <plugin_root> <bindir> <cache_dir> — feed a SessionStart payload.
run_hook() {
    printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"sid-test"}' \
        | CLAUDE_PLUGIN_ROOT="$1" PATH="$2:$PATH" NOTIFY_UPDATE_CACHE_DIR="$3" \
            bash "$HOOK" 2>&1
}

# ---------------------------------------------------------------------------
echo "test: hook exists and is executable"
if [ -f "$HOOK" ]; then ok "notify-update.sh present"; else no "notify-update.sh missing at $HOOK"; fi
if [ -x "$HOOK" ]; then ok "notify-update.sh is executable"; else no "notify-update.sh not executable"; fi

# ---------------------------------------------------------------------------
echo "test: newer release available — emits a notice naming the version and /update-kit"
ROOT1="$WORK/case1"; make_plugin_json "$ROOT1" "0.1.0"
HIT1="$WORK/hit1.log"; : > "$HIT1"
make_curl "$WORK/bin1" "v0.2.0" "$HIT1"
CACHE1="$WORK/cache1"
out1=$(run_hook "$ROOT1" "$WORK/bin1" "$CACHE1")
exit1=$?
assert_equals "newer: exits 0" "$exit1" "0"
assert_contains "newer: names the new version" "$out1" "v0.2.0"
assert_contains "newer: mentions /update-kit" "$out1" "/update-kit"
assert_file "newer: writes the throttle cache" "$CACHE1/last-check.json"

# ---------------------------------------------------------------------------
echo "test: throttle — second call within the window does NOT re-hit the network"
# case1's cache is fresh; a second invocation must replay it, not call curl again.
hits_before=$(wc -l < "$HIT1")
out1b=$(run_hook "$ROOT1" "$WORK/bin1" "$CACHE1")
exit1b=$?
hits_after=$(wc -l < "$HIT1")
assert_equals "throttle: exits 0" "$exit1b" "0"
assert_equals "throttle: no extra network hit within the window" "$hits_after" "$hits_before"
assert_contains "throttle: replays the cached notice (still names version)" "$out1b" "v0.2.0"

# ---------------------------------------------------------------------------
echo "test: already up to date — stays silent"
ROOT2="$WORK/case2"; make_plugin_json "$ROOT2" "0.1.0"
HIT2="$WORK/hit2.log"; : > "$HIT2"
make_curl "$WORK/bin2" "v0.1.0" "$HIT2"
CACHE2="$WORK/cache2"
out2=$(run_hook "$ROOT2" "$WORK/bin2" "$CACHE2")
exit2=$?
assert_equals "up-to-date: exits 0" "$exit2" "0"
assert_empty "up-to-date: no notice emitted" "$out2"

# ---------------------------------------------------------------------------
echo "test: network error — fail-open: exits 0, no alarming output"
ROOT3="$WORK/case3"; make_plugin_json "$ROOT3" "0.1.0"
HIT3="$WORK/hit3.log"; : > "$HIT3"
make_curl "$WORK/bin3" "" "$HIT3" fail
CACHE3="$WORK/cache3"
out3=$(run_hook "$ROOT3" "$WORK/bin3" "$CACHE3")
exit3=$?
assert_equals "network-fail: exits 0" "$exit3" "0"
assert_empty "network-fail: no notice emitted" "$out3"
assert_not_contains "network-fail: no 'error' in output" "$out3" "error"
assert_not_contains "network-fail: no 'Error' in output" "$out3" "Error"

# ---------------------------------------------------------------------------
echo "test: stale cache — re-hits the network after the throttle window expires"
ROOT4="$WORK/case4"; make_plugin_json "$ROOT4" "0.1.0"
HIT4="$WORK/hit4.log"; : > "$HIT4"
make_curl "$WORK/bin4" "v0.2.0" "$HIT4"
CACHE4="$WORK/cache4"
out4a=$(run_hook "$ROOT4" "$WORK/bin4" "$CACHE4")   # first call, populates cache
hits4a=$(wc -l < "$HIT4")
# Backdate the cache well past the ~24h window.
touch -d '3 days ago' "$CACHE4/last-check.json" 2>/dev/null \
    || touch -t "$(date -d '3 days ago' +%Y%m%d%H%M 2>/dev/null || echo 200001010000)" "$CACHE4/last-check.json" 2>/dev/null
out4b=$(run_hook "$ROOT4" "$WORK/bin4" "$CACHE4")   # cache stale -> must re-hit
hits4b=$(wc -l < "$HIT4")
if [ "$hits4b" -gt "$hits4a" ]; then ok "stale: re-hits network after window expires"; else no "stale: did not re-hit (before=$hits4a after=$hits4b)"; fi
assert_contains "stale: still names the new version" "$out4b" "v0.2.0"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
