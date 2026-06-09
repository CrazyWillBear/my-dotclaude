#!/usr/bin/env bash
#
# Tests for scripts/prd-reap.sh — the PRD-reap helper.
#
# Black-box: we stub `gh` via a PATH shim returning canned JSON, run the actual
# script, and assert on its stdout. No network required.
#
# Covers all acceptance criteria:
#   * All children closed       -> PRD reported ready-to-close.
#   * One open non-hitl child   -> PRD NOT reported ready (nor blocked).
#   * Only open child is hitl   -> PRD reported blocked with the hitl issue number.
#   * Slice with no "Part of #" -> no output (no candidate PRD).
#   * Multiple distinct PRDs    -> each evaluated independently.
#
# Run: bash plugins/workflow/tests/test_prd-reap.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REAP="$PLUGIN_ROOT/scripts/prd-reap.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no()  { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_empty()        { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected silence, got: $2)"; fi; }

# ---------------------------------------------------------------------------
# gh shim infrastructure
#
# We write a fake `gh` script into $WORK/bin and prepend that to PATH.
# The shim is rebuilt per test scenario by overwriting $WORK/bin/gh.
#
# The shim is driven by two associative-array-style flat files in $WORK:
#   $WORK/issue_body/<N>   — the JSON body string for `gh issue view <N> --json body`
#   $WORK/issue_list/<prd> — JSON array for `gh issue list --search "Part of #<prd>"`
#
# The shim itself just dispatches on the arguments it receives.

GH_BIN="$WORK/bin/gh"
mkdir -p "$WORK/bin" "$WORK/issue_body" "$WORK/issue_list"

# write_gh_shim — (re)write the PATH-prepended fake gh.
write_gh_shim() {
    cat >"$GH_BIN" <<'SHIMEOF'
#!/usr/bin/env bash
# Fake gh shim for prd-reap tests.
# Dispatches on: issue view <N> --json body  |  issue list ...
WORK_DIR="${FAKE_GH_WORK}"

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    N="$3"
    # Any remaining args are flags (--json body, etc.) — ignore.
    file="$WORK_DIR/issue_body/$N"
    if [ -f "$file" ]; then
        cat "$file"
        exit 0
    fi
    # Unknown issue: return empty body.
    printf '{"body":""}\n'
    exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
    # Extract the --search value (we look for "Part of #<prd>").
    prd=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --search)
                shift
                # $1 is now the search string, e.g. 'Part of #42'
                prd="${1##*#}"
                ;;
        esac
        shift
    done
    file="$WORK_DIR/issue_list/$prd"
    if [ -f "$file" ]; then
        cat "$file"
        exit 0
    fi
    printf '[]\n'
    exit 0
fi

# Fallback — unknown subcommand.
printf 'fake gh: unhandled: %s\n' "$*" >&2
exit 1
SHIMEOF
    chmod +x "$GH_BIN"
}

write_gh_shim

# Helper: set the body for a given issue number.
set_body() {
    local n="$1" body="$2"
    printf '%s\n' "$body" >"$WORK/issue_body/$n"
}

# Helper: set the child-list JSON for a given PRD number.
# JSON is an array of objects: [{"number":N,"state":"open"|"closed","labels":[{"name":"..."}]}]
set_list() {
    local prd="$1" json="$2"
    printf '%s\n' "$json" >"$WORK/issue_list/$prd"
}

# Run the reap script with FAKE_GH_WORK set and the shim on PATH.
run_reap() {
    FAKE_GH_WORK="$WORK" PATH="$WORK/bin:$PATH" bash "$REAP" "$@"
}

# ---------------------------------------------------------------------------
echo "test: all children closed -> PRD reported ready-to-close"

# Slice #5 says "Part of #1"
set_body 5 '{"body":"Fixes the bug.\n\nPart of #1\n"}'
# PRD #1 has two children: #5 (closed) and #6 (closed)
set_list 1 '[{"number":5,"state":"closed","labels":[]},{"number":6,"state":"closed","labels":[]}]'

out=$(run_reap 5)
assert_contains "ready PRD is in output" "$out" "ready"
assert_contains "PRD number appears" "$out" "1"
assert_not_contains "not reported blocked" "$out" "blocked"

# ---------------------------------------------------------------------------
echo "test: PRD with one open non-hitl child is NOT reported ready or blocked"

# Slice #7 says "Part of #2"
set_body 7 '{"body":"Slice.\n\nPart of #2\n"}'
# PRD #2 has one open non-hitl child #8
set_list 2 '[{"number":7,"state":"closed","labels":[]},{"number":8,"state":"open","labels":[]}]'

out=$(run_reap 7)
assert_not_contains "not reported ready" "$out" "ready"
assert_not_contains "not reported blocked" "$out" "blocked"
assert_empty "output is empty when non-hitl open child exists" "$out"

# ---------------------------------------------------------------------------
echo "test: PRD whose only open child is hitl-labeled is reported blocked"

# Slice #9 says "Part of #3"
set_body 9 '{"body":"Slice.\n\nPart of #3\n"}'
# PRD #3: #9 closed, #10 open+hitl
set_list 3 '[{"number":9,"state":"closed","labels":[]},{"number":10,"state":"open","labels":[{"name":"hitl"}]}]'

out=$(run_reap 9)
assert_contains "blocked PRD is in output" "$out" "blocked"
assert_contains "PRD number appears" "$out" "3"
assert_contains "hitl issue number appears" "$out" "10"
assert_not_contains "not reported ready" "$out" "ready"

# ---------------------------------------------------------------------------
echo "test: closed slice with no 'Part of #' reference yields no output"

set_body 11 '{"body":"Just a description with no parent reference.\n"}'

out=$(run_reap 11)
assert_empty "no Part-of ref -> empty output" "$out"

# ---------------------------------------------------------------------------
echo "test: multiple distinct PRDs are each evaluated independently"

# Slices #12 -> PRD #4 (all closed -> ready), #13 -> PRD #5 (open hitl -> blocked)
set_body 12 '{"body":"Part of #4\n"}'
set_body 13 '{"body":"Part of #5\n"}'

set_list 4 '[{"number":12,"state":"closed","labels":[]},{"number":14,"state":"closed","labels":[]}]'
set_list 5 '[{"number":13,"state":"closed","labels":[]},{"number":15,"state":"open","labels":[{"name":"hitl"}]}]'

out=$(run_reap 12 13)
assert_contains "PRD 4 reported ready" "$out" "4"
assert_contains "ready keyword present" "$out" "ready"
assert_contains "PRD 5 reported blocked" "$out" "5"
assert_contains "blocked keyword present" "$out" "blocked"
assert_contains "hitl issue 15 mentioned" "$out" "15"
# Verify they're independent: PRD 4 is ready, PRD 5 is blocked — both must appear.
assert_not_contains "PRD 4 not reported blocked" "$out" "blocked.*4"

# ---------------------------------------------------------------------------
echo "test: issue numbers can also be read from stdin"

set_body 20 '{"body":"Part of #6\n"}'
set_list 6 '[{"number":20,"state":"closed","labels":[]},{"number":21,"state":"closed","labels":[]}]'

out=$(printf '20\n' | FAKE_GH_WORK="$WORK" PATH="$WORK/bin:$PATH" bash "$REAP")
assert_contains "stdin-supplied number -> PRD 6 ready" "$out" "6"
assert_contains "stdin path reports ready" "$out" "ready"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
