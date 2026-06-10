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
mkdir -p "$WORK/bin" "$WORK/issue_body" "$WORK/issue_body_error" "$WORK/issue_list"

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
    # Check for a simulated error sentinel first.
    error_file="$WORK_DIR/issue_body_error/$N"
    if [ -f "$error_file" ]; then
        printf 'gh: error fetching issue %s\n' "$N" >&2
        exit 1
    fi
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

# Helper: mark an issue number so the gh shim returns a non-zero exit (simulates network/rate-limit error).
set_body_error() {
    local n="$1"
    touch "$WORK/issue_body_error/$n"
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
# Set bodies so re-verification confirms both are genuine children of PRD #2.
set_body 8 '{"body":"Part of #2\n"}'

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
# Set bodies so re-verification confirms both are genuine children of PRD #3.
set_body 10 '{"body":"Part of #3\n"}'

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
# Set bodies so re-verification confirms each child genuinely belongs to its PRD.
set_body 14 '{"body":"Part of #4\n"}'
set_body 15 '{"body":"Part of #5\n"}'

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
# Set body for #21 so re-verification confirms it belongs to PRD #6.
set_body 21 '{"body":"Part of #6\n"}'

out=$(printf '20\n' | FAKE_GH_WORK="$WORK" PATH="$WORK/bin:$PATH" bash "$REAP")
assert_contains "stdin-supplied number -> PRD 6 ready" "$out" "6"
assert_contains "stdin path reports ready" "$out" "ready"

# ---------------------------------------------------------------------------
echo "test: false-positive from fuzzy search (ready path) — search for #7 returns issue referencing #70"

# Slice #30 says "Part of #7"
set_body 30 '{"body":"Slice.\n\nPart of #7\n"}'
# PRD #7 has one real closed child: #30 (body confirms Part of #7).
# The gh search also returns issue #31, which is open but whose body says "Part of #70" — a false positive.
set_list 7 '[{"number":30,"state":"closed","labels":[]},{"number":31,"state":"open","labels":[]}]'
set_body 30 '{"body":"Part of #7\n"}'
set_body 31 '{"body":"Part of #70\n"}'

out=$(run_reap 30)
assert_contains     "false-positive excluded: PRD 7 still ready" "$out" "ready"
assert_contains     "PRD 7 number appears"                        "$out" "7"
assert_not_contains "no spurious blocked for PRD 7"              "$out" "blocked"

# ---------------------------------------------------------------------------
echo "test: false-positive from fuzzy search (blocked path) — hitl false-positive must not produce spurious blocked"

# Slice #32 says "Part of #8"
set_body 32 '{"body":"Part of #8\n"}'
# PRD #8 real children: #32 (closed). Search also returns #33, which is open+hitl but body says "Part of #80".
set_list 8 '[{"number":32,"state":"closed","labels":[]},{"number":33,"state":"open","labels":[{"name":"hitl"}]}]'
set_body 33 '{"body":"Part of #80\n"}'

out=$(run_reap 32)
assert_not_contains "no spurious blocked for PRD 8"             "$out" "blocked"
assert_contains     "PRD 8 is ready (false hitl-positive gone)" "$out" "ready"
assert_contains     "PRD 8 number appears"                      "$out" "8"

# ---------------------------------------------------------------------------
echo "test: body-fetch error on open non-hitl child — PRD must NOT be reported ready"
# Regression: get_children used to drop any candidate whose body-fetch errored,
# silently converting a real open child into no child, making the PRD look done.

# Slice #40 says "Part of #9"
set_body 40 '{"body":"Part of #9\n"}'
# PRD #9: #40 (closed) and #41 (open, no hitl). Body-fetch for #41 will error.
set_list 9 '[{"number":40,"state":"closed","labels":[]},{"number":41,"state":"open","labels":[]}]'
set_body 40 '{"body":"Part of #9\n"}'
set_body_error 41   # simulate transient gh error for child #41

out=$(run_reap 40)
assert_not_contains "body-fetch error: PRD 9 must NOT appear ready"   "$out" "ready"
assert_not_contains "body-fetch error: PRD 9 must NOT appear blocked" "$out" "blocked"
assert_empty        "body-fetch error: output is empty (non-hitl open child retained)" "$out"

# ---------------------------------------------------------------------------
echo "test: body-fetch error on open hitl child — PRD must NOT be reported ready"
# Same regression, but the open child carries a hitl label.
# Without the fix the PRD would be reported 'ready' (dropped child made it look all-closed).
# With the fix the candidate is kept so the PRD is 'blocked'.

# Slice #42 says "Part of #11"
set_body 42 '{"body":"Part of #11\n"}'
# PRD #11: #42 (closed) and #43 (open, hitl). Body-fetch for #43 will error.
set_list 11 '[{"number":42,"state":"closed","labels":[]},{"number":43,"state":"open","labels":[{"name":"hitl"}]}]'
set_body 42 '{"body":"Part of #11\n"}'
set_body_error 43   # simulate transient gh error for child #43

out=$(run_reap 42)
assert_not_contains "body-fetch error: hitl PRD 11 must NOT appear ready" "$out" "ready"
assert_contains     "body-fetch error: hitl PRD 11 must appear blocked"   "$out" "blocked"
assert_contains     "body-fetch error: hitl issue 43 must appear"         "$out" "43"

# ---------------------------------------------------------------------------
echo "test: 'Part of #N' quoted mid-sentence (not own line) is NOT a candidate PRD"
# Regression: parse_prd_refs used to scrape 'Part of #N' anywhere in the body,
# so a slice whose prose *quotes* an example reference produced a spurious PRD.
# (This is the latent bug dogfooding surfaced: issue bodies explaining the search
#  collision literally contain `Part of #1` / `Part of #100` inline.)

set_body 50 '{"body":"This explains a search for `Part of #1` also matches `Part of #100` in prose.\n"}'
# If 1 or 100 were (wrongly) treated as candidates, get_children would run; give
# them a body that would re-verify so any leak shows up as output.
set_list 1   '[{"number":50,"state":"closed","labels":[]}]'
set_list 100 '[{"number":50,"state":"closed","labels":[]}]'

out=$(run_reap 50)
assert_empty "inline-quoted Part-of refs yield no candidate PRD" "$out"

# ---------------------------------------------------------------------------
echo "test: child whose body only quotes 'Part of #N' inline is excluded from re-verify"
# Regression: get_children's re-verify pattern matched the ref anywhere in a
# candidate body, so a prose-only mention turned a non-child into a counted child.

# Slice #52 is a genuine child of PRD #60 (own-line trailer).
set_body 52 '{"body":"Slice.\n\nPart of #60\n"}'
# Search for PRD #60 returns #52 (real, closed) and #53 (open, non-hitl) whose body
# only quotes the ref inline — must be excluded so PRD #60 reads ready.
set_list 60 '[{"number":52,"state":"closed","labels":[]},{"number":53,"state":"open","labels":[]}]'
set_body 52 '{"body":"Part of #60\n"}'
set_body 53 '{"body":"Docs note: write `Part of #60` as a trailer line.\n"}'

out=$(run_reap 52)
assert_contains     "inline-only child excluded: PRD 60 ready" "$out" "ready"
assert_contains     "PRD 60 number appears"                    "$out" "60"
assert_not_contains "no spurious blocked for PRD 60"           "$out" "blocked"

# ---------------------------------------------------------------------------
echo "test: candidate PRD with no verified children is NOT reported ready"
# Guard against a vacuously-empty child set printing 'ready' (the #100-does-not-exist
# case from dogfooding: search returns nothing -> empty set must not look all-closed).

set_body 55 '{"body":"Part of #70\n"}'
# Deliberately set no list for PRD #70 -> shim returns '[]' -> no children.

out=$(run_reap 55)
assert_empty "PRD with zero children yields no output" "$out"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
