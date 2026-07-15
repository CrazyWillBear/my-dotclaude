#!/usr/bin/env bash
#
# BEHAVIOR test for the orchestrate scheduler's js block (skills/orchestrate/SKILL.md).
#
# Every OTHER assertion about that block — all 300-odd of them, in test_orchestrate-skill.sh — is a
# grep. A grep proves a STRING is present: a string that *describes* the behavior. It cannot prove
# the block DOES anything, and the block once shipped with three unguarded spawns (a dead reviewer
# merged an unreviewed slice, and its dependent was built on top) under a fully green suite. That is
# mock-drift at the suite level: the test passes while the property it names does not hold.
#
# So this one EXECUTES the block. orchestrate-block.harness.js extracts it from the SKILL, compiles
# it as the async function body the Workflow runtime runs it as, and drives it against a stubbed
# agent() — killing each spawn in turn (a dead agent returns NULL, it does not throw) and asserting
# the run DRAINS rather than degrading into a wrong answer.
#
# The harness is JS because the artifact under test is JS; it is the only non-bash thing in the
# suite, so node is a SOFT dependency exactly as it is for the block's syntax check — absent node,
# this skips green (CI must not need node).
#
# Run: bash plugins/workflow/tests/test_orchestrate-block-behavior.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$SCRIPT_DIR/orchestrate-block.harness.js"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

# ---------------------------------------------------------------------------
echo "test: the orchestrate scheduler block BEHAVES (executed against a stubbed agent, not grepped)"
if ! command -v node >/dev/null 2>&1; then
    ok "SKIPPED: node not installed (the rest of the suite is pure bash — CI must not need node)"
elif [ ! -f "$HARNESS" ]; then
    no "harness missing at $HARNESS"
elif node "$HARNESS"; then
    ok "every guard in the js block holds when its spawn dies"
else
    no "the js block's behavior harness failed (see the FAIL lines above)"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
