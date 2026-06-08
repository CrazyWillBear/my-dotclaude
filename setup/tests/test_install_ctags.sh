#!/usr/bin/env bash
#
# Tests for tcr_install_ctags in setup/lib/common.sh.
#
# Black-box: we source the library with a controlled PATH, drive tcr_install_ctags
# directly, and assert on its output and exit behavior.
#
# Covers:
#   * ctags already on PATH -> "already installed", exit 0, no install attempted.
#   * ctags absent, brew present -> calls "brew install universal-ctags".
#   * ctags absent, pacman present -> calls "pacman -S --noconfirm ctags".
#   * ctags absent, apt present -> calls "apt-get install -y ctags".
#   * ctags absent, dnf present -> calls "dnf install -y ctags".
#   * install command fails -> warns (non-fatal), exit 0 from the function.
#   * no supported package manager -> warns (non-fatal), exit 0.
#
# Run: bash setup/tests/test_install_ctags.sh  (non-zero if any fail)

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

# ---- stub helpers -----------------------------------------------------------
# Create a stub binary at $WORK/stubs/<name> that exits 0 by default, or with
# the given code, and records its invocation to $WORK/calls/<name>.
#
# make_stub <name> [exit-code]
make_stub() {
  local name="$1" code="${2:-0}"
  mkdir -p "$WORK/stubs" "$WORK/calls"
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls/%s"\nexit %s\n' \
    "$name" "$WORK" "$name" "$code" > "$WORK/stubs/$name"
  chmod +x "$WORK/stubs/$name"
}

# stub_calls <name> — emit the recorded invocation(s) for <name>.
stub_calls() { cat "$WORK/calls/$1" 2>/dev/null || true; }

# REAL_BASH / REAL_PYTHON3 — absolute paths so the subshell can find them even
# when the stub PATH does not include /usr/bin directly.
REAL_BASH="$(command -v bash)"
REAL_PYTHON3="$(command -v python3 2>/dev/null || true)"

# _SYS_BIN — a private directory containing symlinks to just bash, python3, and
# the builtins that common.sh needs (printf, mkdir, cp, date).  This avoids
# polluting the fake PATH with real package-manager binaries (e.g. pacman on
# Arch) that would shadow test stubs.
_SYS_BIN="$WORK/sysbin"
mkdir -p "$_SYS_BIN"
ln -sf "$REAL_BASH" "$_SYS_BIN/bash"
[ -n "$REAL_PYTHON3" ] && ln -sf "$REAL_PYTHON3" "$_SYS_BIN/python3"
# Link all the standard utilities common.sh and bash itself need.
for _b in printf mkdir cp date mktemp dirname rm cat; do
  _p="$(command -v "$_b" 2>/dev/null || true)"
  [ -n "$_p" ] && ln -sf "$_p" "$_SYS_BIN/$_b" 2>/dev/null || true
done

# run_ctags_with_path <stub-dir> — source common.sh with NO_COLOR set to
# suppress color codes, then call tcr_install_ctags, capturing combined output.
# Only the stub dir and our curated sysbin dir are on PATH, so real package
# managers (pacman, etc.) on the host cannot shadow test stubs.
run_ctags_with_path() {
  local stub_dir="$1"
  PATH="$stub_dir:$_SYS_BIN" "$REAL_BASH" -c "
    TCR_LOCAL_ROOT=''; NO_COLOR=1; export TCR_LOCAL_ROOT NO_COLOR
    . '$COMMON'
    TCR_INSTALL_FAILED=0
    tcr_install_ctags
    echo \"INSTALL_FAILED=\$TCR_INSTALL_FAILED\"
  " 2>&1
}

# Reset the stubs/calls workspace between tests.
reset_work() {
  rm -rf "$WORK/stubs" "$WORK/calls"
}

# ---- test: ctags already on PATH --------------------------------------------
echo "test: ctags already on PATH -> skip install"
reset_work
# create a real ctags stub so `command -v ctags` succeeds
make_stub ctags
FAKE_PATH="$WORK/stubs"
out=$(run_ctags_with_path "$FAKE_PATH" 2>&1)
assert_contains "reports already installed"  "$out" "already installed"
assert_not_contains "does not attempt install" "$out" "installed ctags via"
assert_contains "INSTALL_FAILED stays 0" "$out" "INSTALL_FAILED=0"
# ctags stub itself should NOT have been invoked (only command -v fires)
calls=$(stub_calls ctags)
assert_equals "ctags stub not executed" "$calls" ""

# ---- test: brew path --------------------------------------------------------
echo "test: ctags absent, brew present -> uses brew install universal-ctags"
reset_work
make_stub brew
FAKE_PATH="$WORK/stubs"
out=$(run_ctags_with_path "$FAKE_PATH" 2>&1)
assert_contains "ok message mentions brew" "$out" "installed ctags via brew"
assert_contains "INSTALL_FAILED stays 0" "$out" "INSTALL_FAILED=0"
calls=$(stub_calls brew)
assert_contains "brew called with universal-ctags" "$calls" "universal-ctags"

# ---- test: pacman path ------------------------------------------------------
echo "test: ctags absent, pacman present -> uses pacman -S --noconfirm ctags"
reset_work
make_stub pacman
FAKE_PATH="$WORK/stubs"
out=$(run_ctags_with_path "$FAKE_PATH" 2>&1)
assert_contains "ok message mentions pacman" "$out" "installed ctags via pacman"
assert_contains "INSTALL_FAILED stays 0" "$out" "INSTALL_FAILED=0"
calls=$(stub_calls pacman)
assert_contains "pacman called with ctags" "$calls" "ctags"
assert_contains "pacman called with --noconfirm" "$calls" "--noconfirm"

# ---- test: apt-get path -----------------------------------------------------
echo "test: ctags absent, apt-get present -> uses apt-get install -y ctags"
reset_work
make_stub apt-get
FAKE_PATH="$WORK/stubs"
out=$(run_ctags_with_path "$FAKE_PATH" 2>&1)
assert_contains "ok message mentions apt-get" "$out" "installed ctags via apt-get"
assert_contains "INSTALL_FAILED stays 0" "$out" "INSTALL_FAILED=0"
calls=$(stub_calls apt-get)
assert_contains "apt-get called with ctags" "$calls" "ctags"

# ---- test: dnf path ---------------------------------------------------------
echo "test: ctags absent, dnf present -> uses dnf install -y ctags"
reset_work
make_stub dnf
FAKE_PATH="$WORK/stubs"
out=$(run_ctags_with_path "$FAKE_PATH" 2>&1)
assert_contains "ok message mentions dnf" "$out" "installed ctags via dnf"
assert_contains "INSTALL_FAILED stays 0" "$out" "INSTALL_FAILED=0"
calls=$(stub_calls dnf)
assert_contains "dnf called with ctags" "$calls" "ctags"

# ---- test: install command fails -> warn and continue -----------------------
echo "test: install command fails -> warns, non-fatal (exit 0 from function)"
reset_work
make_stub brew 1    # brew exits 1
FAKE_PATH="$WORK/stubs"
out=$(run_ctags_with_path "$FAKE_PATH" 2>&1)
assert_contains "emits a warning"          "$out" "warn"
assert_contains "warning mentions brew cmd" "$out" "brew install universal-ctags"
assert_contains "INSTALL_FAILED set to 1"   "$out" "INSTALL_FAILED=1"
# The function itself must not abort the enclosing script (no 'exit 1')
# We verify by checking that INSTALL_FAILED=1 was echoed (i.e., execution continued)

# ---- test: no supported package manager -> warn, non-fatal ------------------
echo "test: no supported package manager -> warns, non-fatal"
reset_work
FAKE_PATH="$WORK/stubs"   # stubs dir has nothing in it
out=$(run_ctags_with_path "$FAKE_PATH" 2>&1)
assert_contains "emits a warning"        "$out" "warn"
assert_contains "mentions manual install" "$out" "universal-ctags manually"
assert_contains "INSTALL_FAILED set to 1" "$out" "INSTALL_FAILED=1"

# ---- test: setup-dev.sh calls tcr_install_ctags; setup-simple.sh does not --
echo "test: setup-dev.sh wires tcr_install_ctags; setup-simple.sh does not"
dev_calls=$(grep -c "tcr_install_ctags" "$SETUP_DIR/setup-dev.sh" || true)
simple_calls=$(grep -c "tcr_install_ctags" "$SETUP_DIR/setup-simple.sh" || true)
assert_equals "setup-dev.sh calls tcr_install_ctags once" "$dev_calls" "1"
assert_equals "setup-simple.sh does not call tcr_install_ctags" "$simple_calls" "0"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
