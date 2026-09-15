#!/usr/bin/env bash
#
# Tests for scripts/check-marketplace-plugins.sh — the reverse-direction check:
# every plugins/*/.claude-plugin/plugin.json must be listed as a source in
# .claude-plugin/marketplace.json.
#
# Black-box: we set up a fake repo tree in a tmpdir and invoke the script
# with REPO_ROOT pointing at it. No network needed; jq must be on PATH.
#
# Covers:
#   * every plugin dir listed in the manifest -> exit 0.
#   * a plugin dir on disk missing from the manifest -> exit non-zero with message.
#   * marketplace manifest missing -> exit non-zero with message.
#
# Run: bash scripts/tests/test_check_marketplace_plugins.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPTS_ROOT/check-marketplace-plugins.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_exit()      { if [ "$2" -eq "$3" ]; then ok "$1"; else no "$1 (want exit $3, got $2)"; fi; }

setup_repo() {
    rm -rf "$WORK/repo"
    mkdir -p "$WORK/repo/.claude-plugin"
    mkdir -p "$WORK/repo/plugins/personal-tools/.claude-plugin"
    mkdir -p "$WORK/repo/plugins/workflow/.claude-plugin"
    printf '{"name":"personal-tools","version":"0.1.0"}\n' \
        > "$WORK/repo/plugins/personal-tools/.claude-plugin/plugin.json"
    printf '{"name":"workflow","version":"0.1.0"}\n' \
        > "$WORK/repo/plugins/workflow/.claude-plugin/plugin.json"
    cat > "$WORK/repo/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "my-dotclaude",
  "plugins": [
    {"name": "personal-tools", "source": "./plugins/personal-tools"},
    {"name": "workflow", "source": "./plugins/workflow"}
  ]
}
EOF
}

run_check() {
    out=$(REPO_ROOT="$WORK/repo" bash "$CHECK" 2>&1)
    rc=$?
}

# ---------------------------------------------------------------------------
echo "test: every plugin dir listed in the manifest -> exit 0"
setup_repo
run_check
assert_exit "exits 0 when every plugin dir is listed" "$rc" 0

# ---------------------------------------------------------------------------
echo "test: a plugin dir on disk missing from the manifest -> exit non-zero with message"
setup_repo
mkdir -p "$WORK/repo/plugins/context/.claude-plugin"
printf '{"name":"context","version":"0.1.0"}\n' \
    > "$WORK/repo/plugins/context/.claude-plugin/plugin.json"
run_check
assert_exit "exits non-zero when a plugin dir drifts from the manifest" "$rc" 1
assert_contains "message names the missing plugin" "$out" "context"

# ---------------------------------------------------------------------------
echo "test: marketplace manifest missing -> exit non-zero with message"
setup_repo
rm -f "$WORK/repo/.claude-plugin/marketplace.json"
run_check
assert_exit "exits non-zero when the manifest is missing" "$rc" 1
assert_contains "message mentions the manifest path" "$out" "marketplace.json"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
