#!/usr/bin/env bash
#
# Tests for the plugin-install wiring in setup/lib/common.sh and the setup scripts.
#
# Black-box: we source the library with a stub `claude` on PATH, drive the install
# helpers directly, and assert on the recorded `claude` invocations + output. No
# network and no real `claude` CLI are needed.
#
# Covers:
#   * the new plugin-id constants hold the expected plugin@marketplace strings.
#   * tcr_install_plugin / tcr_install_composio_plugins / tcr_install_security_sweep
#     are defined, and so are the existing installers (refactor didn't drop them).
#   * tcr_install_composio_plugins adds the Composio marketplace once and installs
#     perf + security-guidance.
#   * tcr_install_security_sweep adds the Onome-AJ marketplace and installs security-sweep.
#   * a failed `claude plugin install` sets TCR_INSTALL_FAILED=1 and warns (non-fatal).
#   * setup-dev.sh and setup-simple.sh each wire the two new installers once.
#
# Run: bash setup/tests/test_plugin_wiring.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON="$SETUP_DIR/lib/common.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }

# make_claude_stub [fail-on-install] — write a stub `claude` that records every
# invocation to $WORK/calls/claude. With the argument set, it exits 1 whenever its
# args begin with `plugin install` (to simulate a failed install); otherwise exit 0.
make_claude_stub() {
  local fail_install="${1:-}"
  mkdir -p "$WORK/stubs" "$WORK/calls"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "claude $*" >> "%s/calls/claude"\n' "$WORK"
    if [ -n "$fail_install" ]; then
      printf 'if [ "$1" = "plugin" ] && [ "$2" = "install" ]; then exit 1; fi\n'
    fi
    printf 'exit 0\n'
  } > "$WORK/stubs/claude"
  chmod +x "$WORK/stubs/claude"
}

# claude_calls — emit the recorded `claude` invocations.
claude_calls() { cat "$WORK/calls/claude" 2>/dev/null || true; }

# reset the recorded calls between tests.
reset_calls() { rm -rf "$WORK/calls"; mkdir -p "$WORK/calls"; }

# run_fn <stub-dir> <shell-snippet> — source common.sh with the stub dir ahead of
# PATH and NO_COLOR set, run the snippet, and echo the resulting TCR_INSTALL_FAILED.
run_fn() {
  local stub_dir="$1" snippet="$2"
  PATH="$stub_dir:$PATH" bash -c "
    NO_COLOR=1; TCR_LOCAL_ROOT=''; export NO_COLOR TCR_LOCAL_ROOT
    . '$COMMON'
    TCR_INSTALL_FAILED=0
    $snippet
    echo \"INSTALL_FAILED=\$TCR_INSTALL_FAILED\"
  " 2>&1
}

# ---- test: plugin-id constants ----------------------------------------------
echo "test: new plugin-id constants hold the expected values"
consts=$(bash -c ". '$COMMON'
  echo \"COMPOSIO=\$COMPOSIO_MARKETPLACE_REPO\"
  echo \"PERF=\$PERF_PLUGIN\"
  echo \"GUIDANCE=\$SECURITY_GUIDANCE_PLUGIN\"
  echo \"SWEEP_REPO=\$SECURITY_SWEEP_REPO\"
  echo \"SWEEP=\$SECURITY_SWEEP_PLUGIN\"" 2>&1)
assert_contains "COMPOSIO_MARKETPLACE_REPO" "$consts" "COMPOSIO=ComposioHQ/awesome-claude-plugins"
assert_contains "PERF_PLUGIN"               "$consts" "PERF=perf@awesome-claude-plugins"
assert_contains "SECURITY_GUIDANCE_PLUGIN"  "$consts" "GUIDANCE=security-guidance@awesome-claude-plugins"
assert_contains "SECURITY_SWEEP_REPO"       "$consts" "SWEEP_REPO=Onome-AJ/security-sweep-plugin"
assert_contains "SECURITY_SWEEP_PLUGIN"     "$consts" "SWEEP=security-sweep@security-sweep-marketplace"

# ---- test: installer functions are defined ----------------------------------
echo "test: installer functions (new + existing) are defined"
defs=$(bash -c ". '$COMMON'
  for f in tcr_install_plugin tcr_install_composio_plugins tcr_install_security_sweep \
           tcr_install_personal_tools tcr_install_workflow tcr_install_caveman \
           tcr_install_agent_sdk_dev; do
    declare -F \"\$f\" >/dev/null && echo \"def \$f\" || echo \"missing \$f\"
  done" 2>&1)
assert_contains "tcr_install_plugin defined"           "$defs" "def tcr_install_plugin"
assert_contains "tcr_install_composio_plugins defined" "$defs" "def tcr_install_composio_plugins"
assert_contains "tcr_install_security_sweep defined"   "$defs" "def tcr_install_security_sweep"
assert_not_contains "no installer missing"             "$defs" "missing "

# ---- test: tcr_install_composio_plugins ------------------------------------
echo "test: tcr_install_composio_plugins adds marketplace once, installs perf + security-guidance"
reset_calls
make_claude_stub
out=$(run_fn "$WORK/stubs" "tcr_install_composio_plugins")
calls=$(claude_calls)
assert_contains "adds Composio marketplace" "$calls" "plugin marketplace add ComposioHQ/awesome-claude-plugins"
assert_contains "installs perf"             "$calls" "plugin install perf@awesome-claude-plugins"
assert_contains "installs security-guidance" "$calls" "plugin install security-guidance@awesome-claude-plugins"
assert_equals  "marketplace added exactly once" "$(printf '%s\n' "$calls" | grep -c 'marketplace add ComposioHQ')" "1"
assert_contains "INSTALL_FAILED stays 0"    "$out" "INSTALL_FAILED=0"

# ---- test: tcr_install_security_sweep --------------------------------------
echo "test: tcr_install_security_sweep adds its marketplace and installs security-sweep"
reset_calls
make_claude_stub
out=$(run_fn "$WORK/stubs" "tcr_install_security_sweep")
calls=$(claude_calls)
assert_contains "adds security-sweep marketplace" "$calls" "plugin marketplace add Onome-AJ/security-sweep-plugin"
assert_contains "installs security-sweep"         "$calls" "plugin install security-sweep@security-sweep-marketplace"
assert_contains "INSTALL_FAILED stays 0"          "$out" "INSTALL_FAILED=0"

# ---- test: a failed install is non-fatal and flags TCR_INSTALL_FAILED -------
echo "test: failed 'claude plugin install' -> warns, sets INSTALL_FAILED=1, non-fatal"
reset_calls
make_claude_stub fail
out=$(run_fn "$WORK/stubs" "tcr_install_plugin perf@awesome-claude-plugins")
assert_contains "emits a warning"            "$out" "warn"
assert_contains "warning names the plugin"   "$out" "perf@awesome-claude-plugins"
assert_contains "INSTALL_FAILED set to 1"    "$out" "INSTALL_FAILED=1"

# ---- test: setup scripts wire both new installers once -----------------------
echo "test: setup-dev.sh and setup-simple.sh each call the two new installers once"
for f in setup-dev.sh setup-simple.sh; do
  composio=$(grep -c "tcr_install_composio_plugins" "$SETUP_DIR/$f" || true)
  sweep=$(grep -c "tcr_install_security_sweep" "$SETUP_DIR/$f" || true)
  assert_equals "$f calls tcr_install_composio_plugins once" "$composio" "1"
  assert_equals "$f calls tcr_install_security_sweep once"   "$sweep" "1"
done

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
