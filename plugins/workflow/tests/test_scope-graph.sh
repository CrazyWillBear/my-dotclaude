#!/usr/bin/env bash
#
# Tests for scripts/scope-graph.sh — /orchestrate's launch-time issue-graph fetch.
#
# The graph is what killed the haiku "picker".  Readiness ("every `## Blocked by`
# ref is closed") is a topological sweep over a DAG — pure computation a model can
# hallucinate.  The picker was only ever an agent because a Workflow can't run
# `gh`.  So the MAIN THREAD fetches the whole graph once, at launch, and the
# workflow computes readiness in plain JS over this JSON.
#
# Contract:
#   bash scope-graph.sh <N1> [N2 ...]
#     -> ONE JSON document on stdout:
#        { "issues": [ { n, title, state, labels, tier, body, comments, blockedBy } ],
#          "blockerStates": { "<ref>": "open"|"closed"|"unknown" },   # every ref, in-scope or not
#          "mockDebtOpen": [ <numbers> ] }                            # the mock-debt ledger
#     -> silence + exit 0 when the args are missing/junk or a dependency is absent
#        (fail-open, matching prd-children.sh / prd-reap.sh).  Empty output makes
#        the workflow's empty-graph throw fire, loudly — never a silent degrade.
#
# Parsing rules under test:
#   * `## Blocked by` holds BARE `#N` refs, one per line, or `None - can start
#     immediately`.  A `#N` mentioned in PROSE (anywhere, including inside the
#     section) is NOT a blocker — matching it would deadlock the scheduler on an
#     issue that was never a dependency.
#   * the tier is a PERSISTED LABEL (`tier:trivial|standard|complex`), null when
#     absent (→ /orchestrate backfills it); conflicting double-labels resolve to
#     the HIGHEST tier, so a mislabel can never route real work to a cheap model.
#   * a FAILED mock-debt ledger query is NOT "no open mock-debt".  Collapsing it to
#     `[]` would silently DISARM the e2e-gate — the single enforcement point of the
#     whole anti-mock-drift design — so it takes the documented loud path instead:
#     silence + exit 0, which fires the workflow's empty-graph throw.
#
# Run: bash plugins/workflow/tests/test_scope-graph.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GRAPH="$PLUGIN_ROOT/scripts/scope-graph.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no()  { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want: '$3', got: '$2')"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_empty()        { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected silence, got: $2)"; fi; }

# jget <python-expr over `d`> <json> — read one field out of the emitted graph.
# python3 is already a hard dependency of the script under test.
jget() { printf '%s' "$2" | python3 -c "import json,sys
d = json.load(sys.stdin)
print($1)" 2>/dev/null; }

# ---------------------------------------------------------------------------
# gh shim — the test_prd-children.sh pattern.
#   $WORK/issue/<N>        — JSON for `gh issue view <N> --json ...`
#   $WORK/issue_error/<N>  — sentinel: make that fetch exit non-zero
#   $WORK/mock_debt        — JSON array for `gh issue list --label mock-debt ...`
#   $WORK/list_error       — sentinel: make `gh issue list` exit non-zero (auth blip)
GH_BIN="$WORK/bin/gh"
mkdir -p "$WORK/bin" "$WORK/issue" "$WORK/issue_error"

cat >"$GH_BIN" <<'SHIMEOF'
#!/usr/bin/env bash
WORK_DIR="${FAKE_GH_WORK}"

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    N="$3"
    printf '%s\n' "$N" >>"$WORK_DIR/viewed"
    if [ -f "$WORK_DIR/issue_error/$N" ]; then
        printf 'gh: error fetching issue %s\n' "$N" >&2
        exit 1
    fi
    if [ -f "$WORK_DIR/issue/$N" ]; then
        cat "$WORK_DIR/issue/$N"
        exit 0
    fi
    printf '{"number":%s,"title":"untitled","state":"OPEN","labels":[],"body":"","comments":[]}\n' "$N"
    exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
    if [ -f "$WORK_DIR/list_error" ]; then
        printf 'gh: could not authenticate\n' >&2
        exit 1
    fi
    if [ -f "$WORK_DIR/mock_debt" ]; then
        cat "$WORK_DIR/mock_debt"
        exit 0
    fi
    printf '[]\n'
    exit 0
fi

printf 'fake gh: unhandled: %s\n' "$*" >&2
exit 1
SHIMEOF
chmod +x "$GH_BIN"

set_issue()     { printf '%s\n' "$2" >"$WORK/issue/$1"; }
set_mock_debt() { printf '%s\n' "$1" >"$WORK/mock_debt"; }
run_graph()     { FAKE_GH_WORK="$WORK" PATH="$WORK/bin:$PATH" bash "$GRAPH" "$@"; }

# ---------------------------------------------------------------------------
echo "test: the helper emits ONE valid JSON document with the three top-level keys"
set_issue 10 '{"number":10,"title":"base slice","state":"CLOSED","labels":[{"name":"ready-for-agent"},{"name":"tier:trivial"}],"body":"## Blocked by\nNone - can start immediately\n","comments":[]}'
set_issue 12 '{"number":12,"title":"dependent slice","state":"OPEN","labels":[{"name":"ready-for-agent"},{"name":"tier:standard"}],"body":"## What to build\nA thing.\n\n## Blocked by\n#10\n#11\n","comments":[{"author":{"login":"will"},"body":"Use the existing parser."}]}'
out="$(run_graph 10 12)"
assert_equals "output parses as JSON"         "$(jget 'type(d).__name__' "$out")" "dict"
assert_equals "issues key present"            "$(jget 'len(d["issues"])' "$out")" "2"
assert_equals "blockerStates key present"     "$(jget '"blockerStates" in d' "$out")" "True"
assert_equals "mockDebtOpen key present"      "$(jget '"mockDebtOpen" in d' "$out")" "True"

# ---------------------------------------------------------------------------
echo "test: blockedBy parses the bare #N refs under '## Blocked by'"
assert_equals "bare refs collected in order" \
    "$(jget 'd["issues"][1]["blockedBy"]' "$out")" "[10, 11]"

echo "test: 'None - can start immediately' parses to an EMPTY blocker list"
assert_equals "None sentinel means no blockers" \
    "$(jget 'd["issues"][0]["blockedBy"]' "$out")" "[]"

echo "test: each scoped issue carries its title, state, labels, body and comments"
assert_equals "state is normalized lowercase" "$(jget 'd["issues"][1]["state"]' "$out")" "open"
assert_equals "closed state survives"         "$(jget 'd["issues"][0]["state"]' "$out")" "closed"
assert_contains "labels carried through"      "$(jget 'd["issues"][1]["labels"]' "$out")" "ready-for-agent"
assert_contains "body carried through"        "$(jget 'd["issues"][1]["body"]' "$out")" "A thing."
# Comments are ground truth (a human's answer, a prior review's ruling) — a
# comment-blind loop rediscovers the settled question and guesses at it.
assert_contains "comments are concatenated, author-attributed" \
    "$(jget 'd["issues"][1]["comments"]' "$out")" "will"
assert_contains "comment body carried through" \
    "$(jget 'd["issues"][1]["comments"]' "$out")" "Use the existing parser."

# ---------------------------------------------------------------------------
echo "test: blocker states are fetched for EVERY ref — in scope or not"
# #11 is not in the scope allowlist, but #12 is blocked by it: without its state
# the scheduler cannot tell whether #12 is ready.
set_issue 11 '{"number":11,"title":"out of scope","state":"CLOSED","labels":[],"body":"","comments":[]}'
out="$(run_graph 10 12)"
assert_equals "in-scope blocker state present"      "$(jget 'd["blockerStates"]["10"]' "$out")" "closed"
assert_equals "out-of-scope blocker state fetched"  "$(jget 'd["blockerStates"]["11"]' "$out")" "closed"

# ---------------------------------------------------------------------------
echo "test: a #N mentioned in PROSE is NOT a blocker"
# A prose ref matched as a blocker would deadlock the scheduler on an issue that
# was never a dependency — the graph must only take BARE refs on their own line.
set_issue 20 '{"number":20,"title":"prose refs","state":"OPEN","labels":[],"body":"## What to build\nFinish the parser started in #99.\n\n## Blocked by\nWaits on #98 landing first\nNone - can start immediately\n","comments":[]}'
out="$(run_graph 20)"
assert_equals "no blockers parsed from prose" "$(jget 'd["issues"][0]["blockedBy"]' "$out")" "[]"
assert_not_contains "prose ref outside the section is not a blocker state" \
    "$(jget 'sorted(d["blockerStates"])' "$out")" "99"
assert_not_contains "prose ref INSIDE the section is not a blocker state" \
    "$(jget 'sorted(d["blockerStates"])' "$out")" "98"

# ---------------------------------------------------------------------------
echo "test: refs after the Blocked by section (a later heading) are not blockers"
set_issue 21 '{"number":21,"title":"section bounded","state":"OPEN","labels":[],"body":"## Blocked by\n#10\n\n## Notes\n#77\n","comments":[]}'
out="$(run_graph 21)"
assert_equals "only the in-section ref is a blocker" "$(jget 'd["issues"][0]["blockedBy"]' "$out")" "[10]"

# ---------------------------------------------------------------------------
echo "test: the tier comes from the persisted tier:* label"
set_issue 30 '{"number":30,"title":"labelled","state":"OPEN","labels":[{"name":"tier:complex"}],"body":"","comments":[]}'
set_issue 31 '{"number":31,"title":"unlabelled","state":"OPEN","labels":[{"name":"ready-for-agent"}],"body":"","comments":[]}'
out="$(run_graph 30 31)"
assert_equals "tier parsed from the label"      "$(jget 'd["issues"][0]["tier"]' "$out")" "complex"
assert_equals "no tier:* label -> null tier"    "$(jget 'json.dumps(d["issues"][1]["tier"])' "$out")" "null"

echo "test: conflicting tier labels resolve to the HIGHEST tier (never route real work cheap)"
set_issue 32 '{"number":32,"title":"double-labelled","state":"OPEN","labels":[{"name":"tier:trivial"},{"name":"tier:complex"}],"body":"","comments":[]}'
out="$(run_graph 32)"
assert_equals "highest tier wins"          "$(jget 'd["issues"][0]["tier"]' "$out")" "complex"
assert_contains "both labels still visible so the caller can warn" \
    "$(jget 'd["issues"][0]["labels"]' "$out")" "tier:trivial"

# ---------------------------------------------------------------------------
echo "test: the open mock-debt ledger is fetched (the e2e-gate's hold set)"
set_mock_debt '[{"number":34},{"number":31}]'
out="$(run_graph 30)"
assert_equals "open mock-debt numbers collected" "$(jget 'd["mockDebtOpen"]' "$out")" "[31, 34]"
rm -f "$WORK/mock_debt"
out="$(run_graph 30)"
assert_equals "no open mock-debt -> empty list" "$(jget 'd["mockDebtOpen"]' "$out")" "[]"

# ---------------------------------------------------------------------------
echo "test: a FAILED ledger query is not 'no debt' — it prints nothing and exits 0"
# An auth blip or a transient API error must never be indistinguishable from an empty
# ledger: collapsing the failure to [] would silently DISARM the e2e-gate, the single
# enforcement point of the whole anti-mock-drift design. The loud path instead: no
# output, exit 0 — which fires the workflow's empty-graph throw.
: >"$WORK/list_error"
out="$(run_graph 30 2>/dev/null)"; rc=$?
assert_empty  "no graph is printed when the ledger query fails" "$out"
assert_equals "exit 0 (fail-open, like every other failure path)" "$rc" "0"
rm -f "$WORK/list_error"

# ---------------------------------------------------------------------------
echo "test: the parsing rules warn that a blocker ref must be an ISSUE, not a PR"
# `gh issue view <PR#>` fails, so a PR ref lands as state "unknown" — never "closed" —
# and its dependent is never ready. Fail-closed is right; being undocumented is not.
header="$(cat "$GRAPH")"
assert_contains "PR-number blocker ref documented" "$header" "PR number"

# ---------------------------------------------------------------------------
echo "test: a failed issue fetch is kept as state 'unknown', never silently dropped"
# Dropping it would silently narrow the run's scope; 'unknown' is not 'open', so
# the scheduler will not build it, and the graph still shows it to the report.
: >"$WORK/issue_error/40"
out="$(run_graph 40)"
assert_equals "the unfetchable issue is still in the graph" "$(jget 'len(d["issues"])' "$out")" "1"
assert_equals "its state is unknown, not open"              "$(jget 'd["issues"][0]["state"]' "$out")" "unknown"
rm -f "$WORK/issue_error/40"

# ---------------------------------------------------------------------------
echo "test: fail-open — no arguments is silent, exit 0 (never a usage explosion)"
out="$(run_graph 2>/dev/null)"; rc=$?
assert_empty  "no output without arguments" "$out"
assert_equals "exit 0 without arguments"    "$rc" "0"

echo "test: fail-open — junk arguments are silent, exit 0"
out="$(run_graph "not-a-number" 2>/dev/null)"; rc=$?
assert_empty  "no output for a non-numeric argument" "$out"
assert_equals "exit 0 for a non-numeric argument"    "$rc" "0"

echo "test: fail-open — a missing gh exits 0 silently"
# Absolute bash: the stripped PATH must starve the SCRIPT of gh, not the shell of bash.
BASH_BIN="$(command -v bash)"
out="$(PATH="$WORK/empty" "$BASH_BIN" "$GRAPH" 12 2>/dev/null)"; rc=$?
assert_empty  "no output when gh is absent" "$out"
assert_equals "exit 0 when gh is absent"    "$rc" "0"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
