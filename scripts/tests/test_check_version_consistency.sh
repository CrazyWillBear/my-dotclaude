#!/usr/bin/env bash
#
# Tests for scripts/check-version-consistency.sh — exits 0 when all versions
# match VERSION, non-zero when any plugin.json differs.
#
# Black-box: we set up a fake repo tree in a tmpdir and invoke the script
# with REPO_ROOT pointing at it. No network and no external tools needed.
#
# Covers:
#   * all three in sync -> exit 0.
#   * personal-tools plugin.json desynced -> exit non-zero with message.
#   * workflow plugin.json desynced -> exit non-zero with message.
#   * both plugin.json desynced -> exit non-zero.
#   * VERSION file missing -> exit non-zero with message.
#
# Run: bash scripts/tests/test_check_version_consistency.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPTS_ROOT/check-version-consistency.sh"

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
# Helpers to build a fake repo tree.
# ---------------------------------------------------------------------------
setup_repo() {
    local root_ver="$1" pt_ver="$2" wf_ver="$3"
    rm -rf "$WORK/repo"
    mkdir -p "$WORK/repo/plugins/personal-tools/.claude-plugin"
    mkdir -p "$WORK/repo/plugins/workflow/.claude-plugin"

    printf '%s\n' "$root_ver" > "$WORK/repo/VERSION"

    cat > "$WORK/repo/plugins/personal-tools/.claude-plugin/plugin.json" <<EOF
{
  "name": "personal-tools",
  "version": "$pt_ver",
  "description": "stub"
}
EOF
    cat > "$WORK/repo/plugins/workflow/.claude-plugin/plugin.json" <<EOF
{
  "name": "workflow",
  "version": "$wf_ver",
  "description": "stub"
}
EOF
}

run_check() {
    out=$(REPO_ROOT="$WORK/repo" bash "$CHECK" 2>&1)
    rc=$?
}

# ---------------------------------------------------------------------------
echo "test: all versions in sync -> exit 0"
setup_repo "0.1.0" "0.1.0" "0.1.0"
run_check
assert_exit "exits 0 when synced" "$rc" 0

# ---------------------------------------------------------------------------
echo "test: personal-tools plugin.json desynced -> exit non-zero with message"
setup_repo "0.2.0" "0.1.0" "0.2.0"
run_check
assert_exit "exits non-zero when personal-tools desynced" "$rc" 1
assert_contains "message mentions personal-tools" "$out" "personal-tools"

# ---------------------------------------------------------------------------
echo "test: workflow plugin.json desynced -> exit non-zero with message"
setup_repo "0.2.0" "0.2.0" "0.1.0"
run_check
assert_exit "exits non-zero when workflow desynced" "$rc" 1
assert_contains "message mentions workflow" "$out" "workflow"

# ---------------------------------------------------------------------------
echo "test: both plugin.json desynced -> exit non-zero"
setup_repo "0.3.0" "0.1.0" "0.2.0"
run_check
assert_exit "exits non-zero when both desynced" "$rc" 1

# ---------------------------------------------------------------------------
echo "test: VERSION file missing -> exit non-zero with message"
rm -rf "$WORK/repo"
mkdir -p "$WORK/repo/plugins/personal-tools/.claude-plugin"
mkdir -p "$WORK/repo/plugins/workflow/.claude-plugin"
# no VERSION file
cat > "$WORK/repo/plugins/personal-tools/.claude-plugin/plugin.json" \
    <<< '{"name":"personal-tools","version":"0.1.0","description":"stub"}'
cat > "$WORK/repo/plugins/workflow/.claude-plugin/plugin.json" \
    <<< '{"name":"workflow","version":"0.1.0","description":"stub"}'
run_check
assert_exit "exits non-zero when VERSION missing" "$rc" 1
assert_contains "message mentions VERSION" "$out" "VERSION"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
