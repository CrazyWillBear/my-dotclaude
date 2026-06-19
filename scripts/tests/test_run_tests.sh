#!/usr/bin/env bash
#
# Tests for scripts/run-tests.sh — the CI test-loop runner that drives every
# bash test under the repo's tests/ dirs and exits NON-ZERO if any test fails.
#
# This is the mechanism that makes CI go red on a failing test: unlike the
# documented done-check loop (which swallows failures via `|| echo FAIL`),
# run-tests.sh must propagate a non-zero exit when any test fails.
#
# Black-box: we build a fake repo tree in a tmpdir whose layout matches the
# real glob (setup/tests, plugins/*/tests, scripts/tests) and point the runner
# at it via TESTS_ROOT. No network, no external tools.
#
# Covers:
#   * all tests pass            -> exit 0.
#   * one failing test          -> exit non-zero.
#   * a test that prints "FAIL:" text but exits 0 -> exit 0 (exit code is the
#     sole signal; output text must not produce false positives).
#   * no test files at all      -> exit non-zero (nothing ran is a failure).
#
# Run: bash scripts/tests/test_run_tests.sh  (non-zero if any assertion fails)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$SCRIPTS_ROOT/run-tests.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_exit()         { if [ "$2" -eq "$3" ]; then ok "$1"; else no "$1 (want exit $3, got $2)"; fi; }
assert_nonzero()      { if [ "$2" -ne 0 ]; then ok "$1"; else no "$1 (want non-zero, got 0)"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }

# ---------------------------------------------------------------------------
# Build a fake repo tree with the canonical tests/ layout.
# ---------------------------------------------------------------------------
reset_repo() {
    rm -rf "$WORK/repo"
    mkdir -p "$WORK/repo/setup/tests"
    mkdir -p "$WORK/repo/plugins/foo/tests"
    mkdir -p "$WORK/repo/scripts/tests"
}

add_test() {  # add_test <relpath> <exit_code> [extra-line]
    local rel="$1" code="$2" extra="${3:-}"
    {
        printf '#!/usr/bin/env bash\n'
        [ -n "$extra" ] && printf '%s\n' "$extra"
        printf 'exit %s\n' "$code"
    } > "$WORK/repo/$rel"
}

run_runner() {
    out=$(TESTS_ROOT="$WORK/repo" bash "$RUNNER" 2>&1)
    rc=$?
}

# ---------------------------------------------------------------------------
echo "test: all tests pass -> exit 0"
reset_repo
add_test "setup/tests/test_a.sh" 0
add_test "plugins/foo/tests/test_b.sh" 0
add_test "scripts/tests/test_c.sh" 0
run_runner
assert_exit "exits 0 when all tests pass" "$rc" 0

# ---------------------------------------------------------------------------
echo "test: one failing test -> exit non-zero"
reset_repo
add_test "setup/tests/test_a.sh" 0
add_test "plugins/foo/tests/test_b.sh" 1
add_test "scripts/tests/test_c.sh" 0
run_runner
assert_nonzero "exits non-zero when a test fails" "$rc"
assert_contains "names the failing test" "$out" "test_b.sh"

# ---------------------------------------------------------------------------
echo "test: test prints FAIL: text but exits 0 -> green (exit code is the signal)"
reset_repo
add_test "scripts/tests/test_c.sh" 0 'echo "FAIL: this is just output text"'
run_runner
assert_exit "stays green when output mentions FAIL: but exit is 0" "$rc" 0

# ---------------------------------------------------------------------------
echo "test: no test files at all -> exit non-zero"
reset_repo
run_runner
assert_nonzero "exits non-zero when no tests were found" "$rc"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
