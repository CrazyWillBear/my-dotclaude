#!/usr/bin/env bash
#
# Tests for scripts/record-review.sh and scripts/review-history.sh — the
# review-history recorder and its metrics viewer.
#
# Black-box: feed the recorder JSON on stdin, then read back the JSONL it wrote
# and the viewer's formatted report. Run: bash plugins/my-code-review/tests/test_history.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RECORD="$PLUGIN_ROOT/scripts/record-review.sh"
VIEW="$PLUGIN_ROOT/scripts/review-history.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROJECT_DIR="$WORK/proj"
mkdir -p "$PROJECT_DIR"
HIST="$PROJECT_DIR/.claude/review-history.jsonl"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want $3, got $2)"; fi; }

record() { CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$RECORD"; }
view() { CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$VIEW" "$@"; }
lines() { if [ -f "$HIST" ]; then wc -l <"$HIST" | tr -d ' '; else echo 0; fi; }

# ---------------------------------------------------------------------------
echo "test: records a valid review as one JSONL line"
printf '%s' '{"verdict":"CHANGES REQUESTED","files":["/proj/a.py"],"findings":[{"severity":"blocker","path":"/proj/a.py","line":12,"note":"unchecked null"}]}' | record
assert_eq "one line written" "$(lines)" "1"
body="$(cat "$HIST")"
assert_contains "stores verdict" "$body" '"verdict": "CHANGES REQUESTED"'
assert_contains "stores file" "$body" '/proj/a.py'
assert_contains "stores severity" "$body" '"severity": "blocker"'
assert_contains "stamps a timestamp" "$body" '"ts":'

# ---------------------------------------------------------------------------
echo "test: malformed input is ignored, nothing appended"
before="$(lines)"
printf '%s' 'not json at all' | record
assert_eq "no new line on bad JSON" "$(lines)" "$before"

echo "test: empty input is ignored"
printf '' | record
assert_eq "no new line on empty input" "$(lines)" "$before"

# ---------------------------------------------------------------------------
echo "test: viewer reports nothing when history is absent"
EMPTY="$WORK/empty"; mkdir -p "$EMPTY"
out=$(CLAUDE_PROJECT_DIR="$EMPTY" bash "$VIEW")
assert_contains "says no history yet" "$out" "No review history yet"

# ---------------------------------------------------------------------------
echo "test: viewer aggregates metrics across reviews"
printf '%s' '{"verdict":"APPROVE WITH NITS","files":["/proj/b.py"],"findings":[{"severity":"nit","path":"/proj/b.py","note":"rename var"},{"severity":"warning","path":"/proj/a.py","note":"broad except"}]}' | record
out="$(view)"
assert_contains "counts total reviews" "$out" "2 review(s)"
assert_contains "shows blocker count" "$out" "blocker  1"
assert_contains "shows warning count" "$out" "warning  1"
assert_contains "names the repeat-offender section" "$out" "Files with the most"
assert_contains "ranks a.py by its blocker+warning count" "$out" "2  /proj/a.py"
assert_not_contains "excludes a nit-only file from the ranking" "$out" "/proj/b.py"
assert_contains "lists recent reviews" "$out" "Recent reviews"

# ---------------------------------------------------------------------------
echo "test: recorder fails open when the history dir cannot be created"
BADP="$WORK/badproj"; mkdir -p "$BADP"
: >"$BADP/.claude"   # .claude exists as a file, so makedirs() raises -> fail open
printf '%s' '{"verdict":"APPROVE","files":[],"findings":[]}' \
    | CLAUDE_PROJECT_DIR="$BADP" bash "$RECORD"
assert_eq "recorder exits 0 on write error" "$?" "0"

# ---------------------------------------------------------------------------
echo "test: viewer tolerates a non-numeric recent-count arg"
out=$(view abc); rc=$?
assert_eq "viewer exits 0 on bad arg" "$rc" "0"
assert_contains "viewer still renders with default count" "$out" "Recent reviews"

echo "test: viewer honors a numeric recent-count arg"
out=$(view 1)
assert_contains "viewer uses the given count" "$out" "last 1"

# ---------------------------------------------------------------------------
echo "test: a bare-string files value is normalized to a one-item list"
printf '%s' '{"verdict":"APPROVE","files":"/proj/c.py","findings":[]}' | record
assert_contains "wraps a bare string into a list" "$(tail -n1 "$HIST")" '"files": ["/proj/c.py"]'

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
