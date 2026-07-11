#!/usr/bin/env bash
#
# Tests for scripts/prd-children.sh — the PRD-child resolver.
#
# prd-children.sh is the single source of truth for "which issues belong to
# PRD #N".  Two callers share it:
#
#   * prd-reap.sh    — to decide whether every child is closed (PRD ready).
#   * /orchestrate   — to scope the round's ready set to the PRD being built,
#                      instead of a repo-wide `--label ready-for-agent` sweep
#                      that can pick up work the user never asked for (#77
#                      defect A: an unrelated issue got built into a PRD branch).
#
# Contract:
#   bash prd-children.sh <prd_number>
#     -> one line per genuine child:  "<number> <state> <labels-csv>"
#        (labels-csv is "-" when the child carries no labels)
#     -> silence + exit 0 when there are no children, the arg is missing, or a
#        dependency/gh call fails (fail-open, matching prd-reap.sh).
#
# The "genuine child" rule is the strict one prd-reap.sh established: the
# reference must be a real `Part of #N` trailer on its own line.  GitHub's
# --search is tokenized full-text, so it returns prefix collisions (#10, #100)
# and issues that merely *quote* the convention in prose.  Both must be dropped.
#
# Run: bash plugins/workflow/tests/test_prd-children.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHILDREN="$PLUGIN_ROOT/scripts/prd-children.sh"

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

# ---------------------------------------------------------------------------
# gh shim — same shape as test_prd-reap.sh.
#   $WORK/issue_body/<N>        — JSON for `gh issue view <N> --json body`
#   $WORK/issue_body_error/<N>  — sentinel: make that fetch exit non-zero
#   $WORK/issue_list/<prd>      — JSON array for `gh issue list --search "Part of #<prd>"`
GH_BIN="$WORK/bin/gh"
mkdir -p "$WORK/bin" "$WORK/issue_body" "$WORK/issue_body_error" "$WORK/issue_list"

cat >"$GH_BIN" <<'SHIMEOF'
#!/usr/bin/env bash
WORK_DIR="${FAKE_GH_WORK}"

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    N="$3"
    if [ -f "$WORK_DIR/issue_body_error/$N" ]; then
        printf 'gh: error fetching issue %s\n' "$N" >&2
        exit 1
    fi
    if [ -f "$WORK_DIR/issue_body/$N" ]; then
        cat "$WORK_DIR/issue_body/$N"
        exit 0
    fi
    printf '{"body":""}\n'
    exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
    prd=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --search) shift; prd="${1##*#}" ;;
        esac
        shift
    done
    if [ -f "$WORK_DIR/issue_list/$prd" ]; then
        cat "$WORK_DIR/issue_list/$prd"
        exit 0
    fi
    printf '[]\n'
    exit 0
fi

printf 'fake gh: unhandled: %s\n' "$*" >&2
exit 1
SHIMEOF
chmod +x "$GH_BIN"

set_body()  { printf '%s\n' "$2" >"$WORK/issue_body/$1"; }
set_list()  { printf '%s\n' "$2" >"$WORK/issue_list/$1"; }
run_children() { FAKE_GH_WORK="$WORK" PATH="$WORK/bin:$PATH" bash "$CHILDREN" "$@"; }

# ---------------------------------------------------------------------------
echo "test: genuine children are listed with state + labels"
set_list 1 '[{"number":5,"state":"open","labels":[{"name":"ready-for-agent"}]},
             {"number":6,"state":"closed","labels":[{"name":"ready-for-agent"},{"name":"e2e-gate"}]}]'
set_body 5 '{"body":"Slice.\n\nPart of #1\n"}'
set_body 6 '{"body":"Slice.\n\nPart of #1\n"}'
out="$(run_children 1)"
assert_contains "open child listed with its label"   "$out" "5 open ready-for-agent"
assert_contains "closed child listed, labels as csv" "$out" "6 closed ready-for-agent,e2e-gate"

# ---------------------------------------------------------------------------
echo "test: a child with no labels renders '-' (never an empty trailing field)"
set_list 2 '[{"number":7,"state":"open","labels":[]}]'
set_body 7 '{"body":"Part of #2\n"}'
out="$(run_children 2)"
assert_equals "unlabeled child renders a '-' placeholder" "$out" "7 open -"

# ---------------------------------------------------------------------------
echo "test: prefix collisions are dropped (searching #1 must not match 'Part of #10')"
# GitHub's tokenized --search returns #10's slice as a candidate for 'Part of #1'.
set_list 1 '[{"number":5,"state":"open","labels":[]},
             {"number":50,"state":"open","labels":[]}]'
set_body 5  '{"body":"Part of #1\n"}'
set_body 50 '{"body":"Part of #10\n"}'
out="$(run_children 1)"
assert_contains "the genuine #1 child survives"        "$out" "5 open"
assert_not_contains "the #10 child is not a #1 child"  "$out" "50 open"

# ---------------------------------------------------------------------------
echo "test: a body that merely QUOTES the convention mid-prose is not a child"
set_list 3 '[{"number":8,"state":"open","labels":[]}]'
set_body 8 '{"body":"Slices carry a `Part of #3` trailer to link them back.\n"}'
out="$(run_children 3)"
assert_empty "mid-prose mention is not a trailer" "$out"

# ---------------------------------------------------------------------------
echo "test: no children -> silence, exit 0"
out="$(run_children 99)"; rc=$?
assert_empty  "no output for a PRD with no children" "$out"
assert_equals "exit 0 when there are no children"    "$rc" "0"

# ---------------------------------------------------------------------------
echo "test: a failed body fetch keeps the candidate (fail-open, as prd-reap does)"
# Dropping it would silently hide a genuine open child — which, for /orchestrate,
# would silently narrow the scope, and for prd-reap would wrongly report 'ready'.
set_list 4 '[{"number":9,"state":"open","labels":[{"name":"ready-for-agent"}]}]'
: >"$WORK/issue_body_error/9"
out="$(run_children 4)"
assert_contains "unverifiable candidate is kept, not dropped" "$out" "9 open ready-for-agent"
rm -f "$WORK/issue_body_error/9"

# ---------------------------------------------------------------------------
echo "test: a missing PRD argument is silent, exit 0 (never a usage explosion)"
out="$(run_children 2>/dev/null)"; rc=$?
assert_empty  "no output without an argument" "$out"
assert_equals "exit 0 without an argument"    "$rc" "0"

# ---------------------------------------------------------------------------
echo "test: output is line-per-child and parseable by a plain read loop"
set_list 5 '[{"number":11,"state":"open","labels":[{"name":"hitl"}]},
             {"number":12,"state":"open","labels":[{"name":"ready-for-agent"}]}]'
set_body 11 '{"body":"Part of #5\n"}'
set_body 12 '{"body":"Part of #5\n"}'
count=0
while read -r n state labels; do
    [ -n "$n" ] || continue
    count=$((count + 1))
    case "$n" in
        11) assert_equals "hitl child carries its label"  "$labels" "hitl" ;;
        12) assert_equals "ready child carries its label" "$labels" "ready-for-agent" ;;
        *)  no "unexpected child number: $n ($state $labels)" ;;
    esac
done <<EOF
$(run_children 5)
EOF
assert_equals "exactly two children parsed" "$count" "2"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
