#!/usr/bin/env bash
#
# Tests for scripts/sync-version.sh — sets VERSION and both plugin.json files.
#
# Black-box: we set up a fake repo tree in a tmpdir (VERSION + two plugin.json
# stubs), run sync-version.sh against it, and assert the version appears in
# all three files. No network and no real `claude` CLI needed.
#
# Covers:
#   * happy path: VERSION, personal-tools plugin.json, workflow plugin.json
#     all updated to the supplied version.
#   * missing argument -> non-zero exit with a usage message.
#   * invalid semver format -> non-zero exit with an error message.
#   * idempotent: running twice with the same version leaves files correct.
#
# Run: bash scripts/tests/test_sync_version.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC="$SCRIPTS_ROOT/sync-version.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_exit()         { if [ "$2" -eq "$3" ]; then ok "$1"; else no "$1 (want exit $3, got $2)"; fi; }

# ---------------------------------------------------------------------------
# Build a minimal fake repo tree under $WORK/repo mirroring the real layout:
#   $WORK/repo/VERSION
#   $WORK/repo/plugins/personal-tools/.claude-plugin/plugin.json
#   $WORK/repo/plugins/workflow/.claude-plugin/plugin.json
# ---------------------------------------------------------------------------
setup_repo() {
    local ver="${1:-0.1.0}"
    rm -rf "$WORK/repo"
    mkdir -p "$WORK/repo/plugins/personal-tools/.claude-plugin"
    mkdir -p "$WORK/repo/plugins/workflow/.claude-plugin"

    printf '%s\n' "$ver" > "$WORK/repo/VERSION"

    # Minimal plugin.json stubs that match the real file shape.
    cat > "$WORK/repo/plugins/personal-tools/.claude-plugin/plugin.json" <<EOF
{
  "name": "personal-tools",
  "version": "$ver",
  "description": "stub"
}
EOF
    cat > "$WORK/repo/plugins/workflow/.claude-plugin/plugin.json" <<EOF
{
  "name": "workflow",
  "version": "$ver",
  "description": "stub"
}
EOF
}

# run_sync <version> — run the script against $WORK/repo, capture combined output
# and the exit code.
run_sync() {
    local ver="$1"
    out=$(REPO_ROOT="$WORK/repo" bash "$SYNC" "$ver" 2>&1)
    rc=$?
}

# ---------------------------------------------------------------------------
echo "test: happy path — all three files updated to 0.2.0"
setup_repo "0.1.0"
run_sync "0.2.0"
assert_exit "exits 0 on success" "$rc" 0

ver_file=$(cat "$WORK/repo/VERSION")
assert_equals "VERSION file updated" "$ver_file" "0.2.0"

pt_ver=$(jq -r '.version' "$WORK/repo/plugins/personal-tools/.claude-plugin/plugin.json")
assert_equals "personal-tools plugin.json updated" "$pt_ver" "0.2.0"

wf_ver=$(jq -r '.version' "$WORK/repo/plugins/workflow/.claude-plugin/plugin.json")
assert_equals "workflow plugin.json updated" "$wf_ver" "0.2.0"

# ---------------------------------------------------------------------------
echo "test: idempotent — running twice with same version leaves files correct"
setup_repo "0.1.0"
run_sync "0.3.0"
run_sync "0.3.0"
assert_exit "exits 0 on second run" "$rc" 0
ver_file=$(cat "$WORK/repo/VERSION")
assert_equals "VERSION still correct after idempotent run" "$ver_file" "0.3.0"

# ---------------------------------------------------------------------------
echo "test: missing argument -> non-zero exit with usage message"
setup_repo "0.1.0"
out=$(REPO_ROOT="$WORK/repo" bash "$SYNC" 2>&1)
rc=$?
assert_exit "exits non-zero when no arg" "$rc" 1
assert_contains "usage message shown" "$out" "Usage"

# ---------------------------------------------------------------------------
echo "test: invalid semver -> non-zero exit with error message"
setup_repo "0.1.0"
run_sync "not-a-version"
assert_exit "exits non-zero for bad semver" "$rc" 1
assert_contains "error message mentions format" "$out" "semver"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
