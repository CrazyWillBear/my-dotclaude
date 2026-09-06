#!/usr/bin/env bash
#
# Tests for scripts/ready.sh — the scheduler's readiness check.
#
# Readiness is a topological check over the FROZEN graph, and it is the one piece
# of the loop that must never guess: an issue admitted too early builds against a
# blocker that does not exist yet, and an issue never admitted stalls the run.
#
# Covers:
#   * the happy set — ascending, one per line
#   * blocked by an OPEN blocker, in scope and out of scope
#   * hitl / prd skip
#   * e2e-gate held by open mock-debt, then released
#   * --merged (re-admit guard AND blocker satisfaction), --held, --in-flight
#   * every empty-set classification: complete scope, gate-held, busy, and the
#     UNEXPLAINED empty that must exit non-zero
#   * unknown-state issues: error by default, skipped with --skip-unknown
#   * junk / missing / empty input fails loud
#
# Run: bash plugins/workflow/tests/test_ready.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READY="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/ready.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in: $2)" ;; esac; }

# issue <n> <state> <labels csv> <blockedBy csv>
issue() {
    python3 -c '
import json, sys
n, state, labels, blocked = sys.argv[1:5]
print(json.dumps({
    "n": int(n), "title": "t%s" % n, "state": state,
    "labels": [l for l in labels.split(",") if l],
    "tier": "standard", "body": "", "comments": "",
    "blockedBy": [int(b) for b in blocked.split(",") if b],
}))' "$@"
}

# graph <mockDebtOpen csv> <blockerStates as n=state,...> -- <issue json>...
graph() {
    local debt="$1" states="$2"; shift 3
    python3 -c '
import json, sys
debt, states = sys.argv[1], sys.argv[2]
print(json.dumps({
    "issues": [json.loads(a) for a in sys.argv[3:]],
    "blockerStates": dict(p.split("=") for p in states.split(",") if p),
    "mockDebtOpen": [int(d) for d in debt.split(",") if d],
}))' "$debt" "$states" "$@"
}

run() { bash "$READY" "$@" 2>"$WORK/err"; }
err() { cat "$WORK/err"; }

# ---------------------------------------------------------------------------
echo "test: the happy set — open, unblocked, ascending"
g=$(graph "" "" -- "$(issue 12 open ready-for-agent '')" "$(issue 10 open ready-for-agent '')")
out=$(printf '%s' "$g" | run)
assert_equals "ready set is 10 then 12" "$out" "$(printf '10\n12')"

echo "test: reads a graph FILE as well as stdin"
printf '%s' "$g" >"$WORK/g.json"
assert_equals "same set from a file" "$(run "$WORK/g.json")" "$(printf '10\n12')"

echo "test: an OPEN blocker holds its dependent"
g=$(graph "" "10=open" -- "$(issue 10 open '' '')" "$(issue 11 open '' 10)")
assert_equals "only the blocker is ready" "$(printf '%s' "$g" | run)" "10"

echo "test: a CLOSED blocker releases its dependent"
g=$(graph "" "10=closed" -- "$(issue 11 open '' 10)")
assert_equals "dependent is ready" "$(printf '%s' "$g" | run)" "11"

echo "test: an OUT-OF-SCOPE open blocker holds — and reads as an unexplained empty"
g=$(graph "" "99=open" -- "$(issue 11 open '' 99)")
out=$(printf '%s' "$g" | run); rc=$?
assert_equals "no ready issues" "$out" ""
assert_equals "exits non-zero (silent-empty class)" "$rc" "1"
assert_contains "says nothing is READY" "$(err)" "no scoped issue is READY"

echo "test: a blocker whose state is unknown (a ref aimed at a PR) fails CLOSED"
g=$(graph "" "99=unknown" -- "$(issue 11 open '' 99)")
printf '%s' "$g" | run >/dev/null; assert_equals "not ready, exits 1" "$?" "1"

echo "test: hitl and prd labels are skipped"
g=$(graph "" "" -- "$(issue 10 open hitl '')" "$(issue 11 open prd '')" "$(issue 12 open '' '')")
assert_equals "only the unlabelled issue" "$(printf '%s' "$g" | run)" "12"

echo "test: a closed issue is never ready"
g=$(graph "" "" -- "$(issue 10 closed '' '')" "$(issue 12 open '' '')")
assert_equals "closed excluded" "$(printf '%s' "$g" | run)" "12"

# ---------------------------------------------------------------------------
echo "test: e2e-gate is held while mock-debt is open, and released when it clears"
g=$(graph "31" "" -- "$(issue 20 open e2e-gate '')" "$(issue 21 open '' '')")
assert_equals "gate issue held, other ready" "$(printf '%s' "$g" | run)" "21"
g=$(graph "" "" -- "$(issue 20 open e2e-gate '')" "$(issue 21 open '' '')")
assert_equals "gate released with an empty ledger" "$(printf '%s' "$g" | run)" "$(printf '20\n21')"

echo "test: an e2e-gate-only scope held by mock-debt is a CLEAN empty, not an error"
g=$(graph "31,34" "" -- "$(issue 20 open e2e-gate '')")
out=$(printf '%s' "$g" | run); rc=$?
assert_equals "no ready issues" "$out" ""
assert_equals "exit 0 — the gate did its job" "$rc" "0"
assert_contains "explains the hold" "$(err)" "e2e-gate-held by open mock-debt"
assert_contains "names the debt" "$(err)" "#31, #34"

echo "test: a gate hold PLUS an unexplained hold still errors, but names the gate"
g=$(graph "31" "99=open" -- "$(issue 20 open e2e-gate '')" "$(issue 11 open '' 99)")
printf '%s' "$g" | run >/dev/null; rc=$?
assert_equals "exits 1" "$rc" "1"
assert_contains "names the designed gate hold" "$(err)" "BY DESIGN"

# ---------------------------------------------------------------------------
echo "test: --merged is a re-admit guard AND satisfies dependents"
g=$(graph "" "10=open" -- "$(issue 10 open '' '')" "$(issue 11 open '' 10)")
assert_equals "merged blocker releases dependent, blocker not re-admitted" \
    "$(printf '%s' "$g" | run --merged 10)" "11"

echo "test: --held and --in-flight exclude"
g=$(graph "" "" -- "$(issue 10 open '' '')" "$(issue 11 open '' '')" "$(issue 12 open '' '')")
assert_equals "held and in-flight dropped" "$(printf '%s' "$g" | run --held 10 --in-flight 11)" "12"
assert_equals "flags accept #N and comma lists" "$(printf '%s' "$g" | run --held '#10,11')" "12"

# The ORDINARY MID-RUN CASE, and the one a fixture-only suite missed: slots full,
# and what is left is blocked by what is building plus a permanent hitl. Calling that
# an error aborts a healthy run on its first scheduling pass. Work in flight settles
# it: the unexplained-empty error is a LAUNCH guard, not a per-pass one.
echo "test: with work in flight, an otherwise-unexplained empty is CLEAN"
g=$(graph "" "1=open" -- "$(issue 1 open '' '')" "$(issue 2 open '' '')" \
                        "$(issue 3 open '' 1)" "$(issue 4 open hitl '')")
printf '%s' "$g" | run --in-flight 1 --in-flight 2 >/dev/null; rc=$?
assert_equals "exit 0 — the run is progressing" "$rc" "0"
assert_contains "names what is in flight" "$(err)" "#1, #2 in flight"
# ...and the SAME graph with nothing in flight is still the error it should be.
printf '%s' "$g" | run --merged 1 --merged 2 --merged 3 >/dev/null; rc=$?
assert_equals "with nothing in flight it is an error again" "$rc" "1"

echo "test: everything in flight is a CLEAN empty"
g=$(graph "" "" -- "$(issue 10 open '' '')")
printf '%s' "$g" | run --in-flight 10 >/dev/null; rc=$?
assert_equals "exit 0" "$rc" "0"
assert_contains "says in flight" "$(err)" "in flight"

echo "test: a fully merged/closed scope is a CLEAN empty"
g=$(graph "" "" -- "$(issue 10 closed '' '')" "$(issue 11 open '' '')")
printf '%s' "$g" | run --merged 11 >/dev/null; rc=$?
assert_equals "exit 0" "$rc" "0"
assert_contains "says the scope is complete" "$(err)" "scope is complete"

echo "test: an all-hitl scope is an ERROR, not a clean empty"
g=$(graph "" "" -- "$(issue 10 open hitl '')")
printf '%s' "$g" | run >/dev/null; assert_equals "exits 1" "$?" "1"

# ---------------------------------------------------------------------------
echo "test: an unfetchable issue errors by default and is skipped on request"
g=$(graph "" "" -- "$(issue 10 unknown '' '')" "$(issue 11 open '' '')")
printf '%s' "$g" | run >/dev/null; rc=$?
assert_equals "partial scope refuses to run" "$rc" "1"
assert_contains "says why" "$(err)" "refusing to run on a partial scope"
out=$(printf '%s' "$g" | run --skip-unknown)
assert_equals "--skip-unknown builds the rest" "$out" "11"
assert_contains "--skip-unknown is logged, never silent" "$(err)" "dropping unfetchable #10"

echo "test: an all-unknown scope is never reported as complete"
g=$(graph "" "" -- "$(issue 10 unknown '' '')")
printf '%s' "$g" | run --skip-unknown >/dev/null; assert_equals "exits 1" "$?" "1"

echo "test: junk, empty and missing input fail loud"
printf 'not json' | run >/dev/null; assert_equals "junk exits 1" "$?" "1"
printf '{"issues":[]}' | run >/dev/null; rc=$?
assert_equals "empty graph exits 1" "$rc" "1"
assert_contains "refuses a repo-wide sweep" "$(err)" "refusing to pick work repo-wide"
run "$WORK/nope.json" >/dev/null; assert_equals "missing file exits 1" "$?" "1"
printf '%s' "$g" | run --bogus >/dev/null; assert_equals "unknown flag exits 1" "$?" "1"

# ---------------------------------------------------------------------------
# The caller is a model assembling argv by hand, so a malformed flag must fail fast.
# `shift 2` on a trailing flag fails WITHOUT shifting under `set -u`, which used to
# spin the loop forever — a hung dispatcher, the silent stall this design fears most.
echo "test: malformed arguments fail fast, never hang"
timeout 5 bash "$READY" "$WORK/g.json" --merged >/dev/null 2>"$WORK/err"; rc=$?
assert_equals "a trailing flag exits 1 (not 124 — a hang)" "$rc" "1"
assert_contains "says which flag" "$(err)" "--merged requires a value"
timeout 5 bash "$READY" "$WORK/g.json" --held >/dev/null 2>&1; assert_equals "--held too" "$?" "1"
timeout 5 bash "$READY" "$WORK/g.json" --in-flight >/dev/null 2>&1; assert_equals "--in-flight too" "$?" "1"
timeout 5 bash "$READY" "$WORK/g.json" --merged abc >/dev/null 2>"$WORK/err"; rc=$?
assert_equals "a non-numeric value exits 1 rather than silently doing nothing" "$rc" "1"
assert_contains "says what it wanted" "$(err)" "wants issue numbers"
timeout 5 bash "$READY" "$WORK/g.json" extra.json >/dev/null 2>"$WORK/err"; rc=$?
assert_equals "a second positional exits 1" "$rc" "1"
assert_contains "names both paths" "$(err)" "two graph paths given"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
