#!/usr/bin/env bash
#
# run-tests.sh
#
# Drives the repo's full bash test suite — every test_*.sh under setup/tests,
# plugins/*/tests, and scripts/tests — and exits NON-ZERO if any test fails.
#
# This is the CI-facing version of the done-check loop documented in CLAUDE.md.
# That loop guards each test with `|| echo "FAIL: $t"`, so it ALWAYS exits 0 and
# can never make a job red. This runner drops that guard: it runs each test, and
# any test that exits non-zero flips a failure flag that makes the whole run exit
# non-zero. (Every test in this repo ends with `[ "$fail" -eq 0 ]`, so a failed
# assertion is a non-zero exit — the exit code is the source of truth.) A run that
# finds no tests is also treated as a failure.
#
# Usage: bash scripts/run-tests.sh
#
# Locates the repo root via TESTS_ROOT (env var, used by tests) or by walking up
# from its own location — mirrors check-version-consistency.sh's REPO_ROOT seam.

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate repo root
# ---------------------------------------------------------------------------
if [ -n "${TESTS_ROOT:-}" ]; then
    ROOT="$TESTS_ROOT"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

cd "$ROOT" || { printf 'Error: cannot cd to repo root %s\n' "$ROOT" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Collect tests across the canonical layout.
# ---------------------------------------------------------------------------
failed=0
ran=0

for t in setup/tests/test_*.sh plugins/*/tests/test_*.sh scripts/tests/test_*.sh; do
    [ -f "$t" ] || continue   # skip unmatched globs
    ran=$((ran + 1))
    printf '== %s\n' "$t"

    if bash "$t"; then
        :
    else
        printf 'FAILED: %s (exit %d)\n' "$t" "$?"
        failed=1
    fi
done

if [ "$ran" -eq 0 ]; then
    printf 'Error: no test files found under %s — nothing ran\n' "$ROOT" >&2
    exit 1
fi

if [ "$failed" -ne 0 ]; then
    printf '\nTest suite FAILED (%d test files run)\n' "$ran" >&2
    exit 1
fi

printf '\nAll %d test files passed\n' "$ran"
