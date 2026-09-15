#!/usr/bin/env bash
#
# Tests for scripts/roster.sh — validate a project's .claude/swarm/roster.json and
# answer `get <role> <field>` / `list [kind]` (central mechanism).
#
# Black-box, exercised for REAL: every assertion drives the shipped script against a
# REAL roster.json written into a tmpdir passed as roster.sh's project-dir argument.
# There is no inlined/stubbed roster anywhere in this test.
#
#   1. Script exists, is executable, has no jq dependency (python3 does the parsing).
#   2. The shipped example (plugins/swarm/templates/roster.json — the same rows
#      /init-swarm draws from) validates clean and every get/list query works,
#      including rotate_at/autocompact falling back to their documented defaults
#      when the row omits them (the shipped example does).
#   3. validate/get/list all reject a row with an unknown kind.
#   4. validate/get/list all reject a worker row with no manager.
#   5. A worker row WITH a manager is accepted (the manager check isn't overzealous).
#   6. Missing roster.json, malformed JSON, and a non-object roster each fail loudly.
#   7. get: unknown role, and a field with no value and no default, each fail loudly.
#   8. list's kind-vs-project-dir disambiguation (0/1/2 positional args).
#   9. With no project-dir argument, the default is $PWD.
#
# Run: bash plugins/swarm/tests/test_roster.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/roster.sh"
SHIPPED_EXAMPLE="$PLUGIN_ROOT/templates/roster.json"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }

# roster <dir> <text> — write <text> as <dir>/.claude/swarm/roster.json.
roster() { mkdir -p "$1/.claude/swarm"; printf '%s' "$2" > "$1/.claude/swarm/roster.json"; }

# run <args...> — run the real script and set OUT / ERR / RC.
run() {
    local errfile="$WORK/err"
    OUT="$(bash "$SCRIPT" "$@" 2>"$errfile")"
    RC=$?
    ERR="$(cat "$errfile")"
}

# ---------------------------------------------------------------------------
echo "test: script exists, is executable, and has no jq dependency"
if [ -f "$SCRIPT" ]; then ok "roster.sh present at scripts/roster.sh"; else no "roster.sh missing at $SCRIPT"; fi
if [ -x "$SCRIPT" ]; then ok "roster.sh is executable"; else no "roster.sh is not executable"; fi
SCRIPT_SRC=""
[ -f "$SCRIPT" ] && SCRIPT_SRC="$(cat "$SCRIPT")"
assert_not_contains "helper has no jq dependency" "$SCRIPT_SRC" "jq"

# ---------------------------------------------------------------------------
echo "test: the shipped example (same rows /init-swarm draws from) validates and answers every query"
[ -f "$SHIPPED_EXAMPLE" ] || no "shipped example missing at $SHIPPED_EXAMPLE"

SHIPPED="$WORK/shipped"
mkdir -p "$SHIPPED/.claude/swarm"
cp "$SHIPPED_EXAMPLE" "$SHIPPED/.claude/swarm/roster.json"

run validate "$SHIPPED"
assert_equals "shipped: validate exit 0" "$RC" "0"
assert_equals "shipped: validate has no stderr" "$ERR" ""

run list "$SHIPPED"
assert_equals "shipped: list exit 0" "$RC" "0"
assert_equals "shipped: list is all three roles in file order" "$OUT" "$(printf 'orchestrator\nswe-manager\nperformance-engineer')"

run list manager "$SHIPPED"
assert_equals "shipped: list manager -> swe-manager only" "$OUT" "swe-manager"

run list doer "$SHIPPED"
assert_equals "shipped: list doer -> performance-engineer only" "$OUT" "performance-engineer"

run list worker "$SHIPPED"
assert_equals "shipped: list worker -> none" "$OUT" ""
assert_equals "shipped: list worker exit 0 (empty is not an error)" "$RC" "0"

run get orchestrator kind "$SHIPPED"
assert_equals "shipped: get orchestrator kind" "$OUT" "orchestrator"

run get swe-manager backend "$SHIPPED"
assert_equals "shipped: get swe-manager backend" "$OUT" "claude"

run get performance-engineer model "$SHIPPED"
assert_equals "shipped: get performance-engineer model" "$OUT" "opus"

run get orchestrator effort "$SHIPPED"
assert_equals "shipped: get orchestrator effort" "$OUT" "high"

echo "test: rotate_at/autocompact fall back to their documented defaults when omitted"
run get orchestrator rotate_at "$SHIPPED"
assert_equals "shipped: rotate_at defaults to 300000" "$OUT" "300000"
run get swe-manager autocompact "$SHIPPED"
assert_equals "shipped: autocompact defaults to 400000" "$OUT" "400000"

# ---------------------------------------------------------------------------
echo "test: an unknown kind is rejected by validate, get, and list"
BADKIND="$WORK/badkind"
roster "$BADKIND" '{"orchestrator": {"kind": "supervisor", "backend": "claude", "model": "opus", "effort": "high"}}'

run validate "$BADKIND"
assert_equals "badkind: validate exit 1" "$RC" "1"
assert_contains "badkind: validate names the problem" "$ERR" "unknown kind"

run list "$BADKIND"
assert_equals "badkind: list also exit 1" "$RC" "1"
assert_contains "badkind: list also rejects" "$ERR" "unknown kind"

run get orchestrator kind "$BADKIND"
assert_equals "badkind: get also exit 1" "$RC" "1"
assert_contains "badkind: get also rejects" "$ERR" "unknown kind"

# ---------------------------------------------------------------------------
echo "test: a worker row with no manager is rejected"
NOMANAGER="$WORK/nomanager"
roster "$NOMANAGER" '{
  "swe-manager": {"kind": "manager", "backend": "claude", "model": "opus", "effort": "high"},
  "implementer-1": {"kind": "worker", "backend": "codex", "model": "terra", "effort": "medium"}
}'
run validate "$NOMANAGER"
assert_equals "nomanager: validate exit 1" "$RC" "1"
assert_contains "nomanager: names the workerless role" "$ERR" "implementer-1"
assert_contains "nomanager: names the problem" "$ERR" "manager"

echo "test: a worker row WITH a manager is accepted (the check is not overzealous)"
WITHMANAGER="$WORK/withmanager"
roster "$WITHMANAGER" '{
  "swe-manager": {"kind": "manager", "backend": "claude", "model": "opus", "effort": "high"},
  "implementer-1": {"kind": "worker", "backend": "codex", "model": "terra", "effort": "medium", "manager": "swe-manager"}
}'
run validate "$WITHMANAGER"
assert_equals "withmanager: validate exit 0" "$RC" "0"
run get implementer-1 manager "$WITHMANAGER"
assert_equals "withmanager: get implementer-1 manager" "$OUT" "swe-manager"

# ---------------------------------------------------------------------------
echo "test: missing roster, malformed JSON, and a non-object roster all fail loudly"

MISSING="$WORK/missing"
mkdir -p "$MISSING"
run validate "$MISSING"
assert_equals "missing: exit 1" "$RC" "1"
assert_contains "missing: says no roster" "$ERR" "error:"

MALFORMED="$WORK/malformed"
roster "$MALFORMED" '{not json'
run validate "$MALFORMED"
assert_equals "malformed: exit 1" "$RC" "1"
assert_contains "malformed: says so" "$ERR" "error:"

NOTOBJECT="$WORK/notobject"
roster "$NOTOBJECT" '["orchestrator"]'
run validate "$NOTOBJECT"
assert_equals "not-an-object: exit 1" "$RC" "1"
assert_contains "not-an-object: says so" "$ERR" "error:"

# ---------------------------------------------------------------------------
echo "test: get fails loudly on an unknown role or a field with no value and no default"
run get nobody kind "$SHIPPED"
assert_equals "unknown role: exit 1" "$RC" "1"
assert_contains "unknown role: names it" "$ERR" "nobody"

run get orchestrator nonexistent-field "$SHIPPED"
assert_equals "unknown field: exit 1" "$RC" "1"
assert_contains "unknown field: names it" "$ERR" "nonexistent-field"

# ---------------------------------------------------------------------------
echo "test: list's kind-vs-project-dir disambiguation"
run list "$SHIPPED"
assert_equals "list, 1 arg, not a kind -> treated as project-dir" "$RC" "0"
assert_contains "list, 1 arg project-dir includes orchestrator" "$OUT" "orchestrator"

run list worker "$SHIPPED"
assert_equals "list, 2 args -> kind then project-dir" "$RC" "0"

run list bogus-kind "$SHIPPED"
assert_equals "list, 2 args, first not a real kind -> usage error" "$RC" "1"

# ---------------------------------------------------------------------------
echo "test: with no project-dir argument, the default is \$PWD"
OUT="$(cd "$SHIPPED" && bash "$SCRIPT" get orchestrator kind)"
RC=$?
assert_equals "cwd default: exit 0" "$RC" "0"
assert_equals "cwd default: reads \$PWD/.claude/swarm/roster.json" "$OUT" "orchestrator"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
