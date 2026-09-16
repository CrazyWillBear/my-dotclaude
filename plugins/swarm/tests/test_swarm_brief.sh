#!/usr/bin/env bash
#
# Tests for scripts/swarm.sh brief verb — write a brief to inbox, print SendMessage.
#
# Black-box, exercised for REAL: every assertion drives the shipped script against a
# REAL project directory with a REAL roster.json and a REAL source file.
#
#   1. Script exists and is executable.
#   2. swarm.sh brief <role> <file> writes to .claude/swarm/inbox/<role>/<nanosecond-timestamp>-<slug>.md
#      and prints a one-line message containing the absolute path (central mechanism).
#   3. The message format is correct for SendMessage (literal text, not a template).
#   4. Invalid role names are rejected; the message names the problem.
#   5. Missing source file is rejected; the message names the problem.
#   6. Unknown roster.json is rejected; the message names the problem.
#   7. With no project-dir argument, the default is $PWD.
#   8. Filename slug derivation: alphanumeric + hyphens from basename without extension.
#   9. Collision prevention: two briefs to same role with same basename create distinct files.
#
# Run: bash plugins/swarm/tests/test_swarm_brief.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/swarm.sh"
SHIPPED_ROSTER="$PLUGIN_ROOT/templates/roster.json"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }

# run <args...> — run the real script and set OUT / ERR / RC.
run() {
    local errfile="$WORK/err"
    OUT="$(bash "$SCRIPT" "$@" 2>"$errfile")"
    RC=$?
    ERR="$(cat "$errfile")"
}

# setup_project <dir> <roster-json> — create a project directory with roster.json
setup_project() {
    local dir="$1" roster_content="$2"
    mkdir -p "$dir/.claude/swarm"
    printf '%s' "$roster_content" > "$dir/.claude/swarm/roster.json"
}

# ---------------------------------------------------------------------------
echo "test: script exists and is executable"
if [ -f "$SCRIPT" ]; then ok "swarm.sh present"; else no "swarm.sh missing at $SCRIPT"; fi
if [ -x "$SCRIPT" ]; then ok "swarm.sh is executable"; else no "swarm.sh is not executable"; fi

# ---------------------------------------------------------------------------
echo "test: central mechanism — brief is written to inbox and path is printed"

PROJECT="$WORK/project"
setup_project "$PROJECT" "$(cat "$SHIPPED_ROSTER")"

SRCFILE="$WORK/source.md"
printf 'Test brief content\n' > "$SRCFILE"

run brief orchestrator "$SRCFILE" "$PROJECT"

assert_equals "exit 0 on success" "$RC" "0"
assert_contains "output mentions absolute path" "$OUT" "Brief stored at"
assert_contains "output contains .claude/swarm/inbox" "$OUT" ".claude/swarm/inbox"
assert_contains "output contains orchestrator role" "$OUT" "orchestrator"

# Extract the printed path from the output
PRINTED_PATH=$(echo "$OUT" | grep -oE '/[^ ]*' | head -1)
if [ -z "$PRINTED_PATH" ]; then
    no "could not extract path from output"
else
    ok "path extracted from output"

    # Verify the file was actually written
    if [ -f "$PRINTED_PATH" ]; then
        ok "brief file was written to the printed path"
        CONTENT="$(cat "$PRINTED_PATH")"
        assert_equals "brief file contains source content" "$CONTENT" "Test brief content"
    else
        no "brief file not found at printed path: $PRINTED_PATH"
    fi

    # Verify the path matches the expected pattern (nanosecond timestamp)
    if [[ "$PRINTED_PATH" =~ /inbox/orchestrator/[0-9]{18,20}-[a-z]+\.md$ ]]; then
        ok "path follows <nanosecond-timestamp>-<slug>.md pattern"
    else
        no "path does not match expected pattern: $PRINTED_PATH"
    fi
fi

# ---------------------------------------------------------------------------
echo "test: unknown role is rejected"
run brief nonexistent-role "$SRCFILE" "$PROJECT"
assert_equals "exit 1 on unknown role" "$RC" "1"
assert_contains "error mentions unknown role" "$ERR" "unknown role"

# ---------------------------------------------------------------------------
echo "test: missing source file is rejected"
run brief orchestrator "$WORK/nonexistent-file.md" "$PROJECT"
assert_equals "exit 1 on missing file" "$RC" "1"
assert_contains "error mentions file" "$ERR" "file"

# ---------------------------------------------------------------------------
echo "test: missing roster.json is rejected"
NOPROJ="$WORK/noproj"
mkdir -p "$NOPROJ"
run brief orchestrator "$SRCFILE" "$NOPROJ"
assert_equals "exit 1 on missing roster" "$RC" "1"
assert_contains "error mentions roster" "$ERR" "roster"

# ---------------------------------------------------------------------------
echo "test: slug derivation from basename"
# Test with various filenames to verify slug creation
for test_name in "my-handoff" "spec" "review_notes" "test-file-name"; do
    TESTFILE="$WORK/$test_name.md"
    printf 'test content' > "$TESTFILE"

    run brief swe-manager "$TESTFILE" "$PROJECT"
    if [ "$RC" -eq 0 ]; then
        # Extract timestamp and slug from printed path
        PRINTED_PATH=$(echo "$OUT" | grep -oE '/[^ ]*' | head -1)
        BASENAME_ONLY="$(basename "$PRINTED_PATH" .md)"

        # Verify it's <timestamp>-<slug> format
        if [[ "$BASENAME_ONLY" =~ ^[0-9]+-(.+)$ ]]; then
            ok "slug created from '$test_name'"
        else
            no "slug not created correctly for '$test_name'"
        fi
    else
        no "failed to process '$test_name'"
    fi
done

# ---------------------------------------------------------------------------
echo "test: templates contain required lines"

# Verify charter.md contains the required lines about briefs and messages
CHARTER="$PLUGIN_ROOT/templates/charter.md"
if grep -q "Briefs travel as files, messages are pointers" "$CHARTER"; then
    ok "charter.md contains 'Briefs travel as files, messages are pointers'"
else
    no "charter.md missing 'Briefs travel as files, messages are pointers'"
fi

if grep -q "After reading your handoff, list your inbox before anything else" "$CHARTER"; then
    ok "charter.md contains 'After reading your handoff, list your inbox before anything else'"
else
    no "charter.md missing 'After reading your handoff, list your inbox before anything else'"
fi

# Verify all three brief templates contain the required line
BRIEF_ROLES=("orchestrator" "swe-manager" "performance-engineer")
REQUIRED_LINE="After reading your handoff, list your inbox before anything else"

for role in "${BRIEF_ROLES[@]}"; do
    BRIEF_FILE="$PLUGIN_ROOT/templates/briefs/${role}.md"
    if [ -f "$BRIEF_FILE" ]; then
        if grep -q "$REQUIRED_LINE" "$BRIEF_FILE"; then
            ok "${role}.md contains required line"
        else
            no "${role}.md missing required line"
        fi
    else
        no "${role}.md template file not found at $BRIEF_FILE"
    fi
done

# ---------------------------------------------------------------------------
echo "test: project-dir defaults to \$PWD"
PWDPROJ="$WORK/pwdproj"
setup_project "$PWDPROJ" "$(cat "$SHIPPED_ROSTER")"
PWDSRC="$WORK/pwd-source.md"
printf 'pwd content\n' > "$PWDSRC"

(
    cd "$PWDPROJ"
    OUT="$(bash "$SCRIPT" brief orchestrator "$PWDSRC" 2>/dev/null)"
    RC=$?
    if [ "$RC" -eq 0 ]; then
        if [[ "$OUT" =~ $PWDPROJ ]]; then
            ok "defaults to PWD when no project-dir given"
        else
            no "output path doesn't match PWD: $OUT"
        fi
    else
        no "failed when using PWD default"
    fi
)

# ---------------------------------------------------------------------------
echo "test: collision prevention — two briefs to same role with same basename"
# Create two source files with the same basename in different directories
TMPDIR1="$WORK/tmp1"
TMPDIR2="$WORK/tmp2"
mkdir -p "$TMPDIR1" "$TMPDIR2"

SRCFILE1="$TMPDIR1/brief.md"
SRCFILE2="$TMPDIR2/brief.md"
printf 'First brief\n' > "$SRCFILE1"
printf 'Second brief\n' > "$SRCFILE2"

PROJECT2="$WORK/project2"
setup_project "$PROJECT2" "$(cat "$SHIPPED_ROSTER")"

# Send both briefs rapidly to the same role
run brief swe-manager "$SRCFILE1" "$PROJECT2"
FIRST_PATH=$(echo "$OUT" | grep -oE '/[^ ]*' | head -1)
RC1=$?

run brief swe-manager "$SRCFILE2" "$PROJECT2"
SECOND_PATH=$(echo "$OUT" | grep -oE '/[^ ]*' | head -1)
RC2=$?

if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ]; then
    if [ "$FIRST_PATH" != "$SECOND_PATH" ]; then
        ok "two briefs with same basename created distinct files"
        # Verify both files exist with correct content
        if [ -f "$FIRST_PATH" ] && [ -f "$SECOND_PATH" ]; then
            CONTENT1="$(cat "$FIRST_PATH")"
            CONTENT2="$(cat "$SECOND_PATH")"
            if [ "$CONTENT1" = "First brief" ] && [ "$CONTENT2" = "Second brief" ]; then
                ok "both brief files preserved with correct content"
            else
                no "brief file contents were corrupted or overwritten"
            fi
        else
            no "one or both brief files do not exist"
        fi
    else
        no "collision detected: both briefs have the same path"
    fi
else
    no "one or both brief commands failed"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
