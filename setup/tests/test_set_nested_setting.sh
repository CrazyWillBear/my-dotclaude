#!/usr/bin/env bash
#
# Tests for tcr_set_nested_setting in setup/lib/common.sh.
#
# Black-box: source the library with HOME pointed at a scratch dir (the helper
# writes to $HOME/.claude/settings.json), call the function, assert on the result.
#
# Covers:
#   * fresh file              -> creates {worktree:{baseRef:head}}.
#   * existing object         -> sub-key added, sibling sub-key + top-level keys kept.
#   * unparseable file        -> left untouched, warns (does not clobber).
#   * idempotent re-run       -> identical JSON.
#   * deep dotted key         -> creates intermediate objects.
#   * both setups wire it once.
#
# Run: bash setup/tests/test_set_nested_setting.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON="$SETUP_DIR/lib/common.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }

if ! command -v python3 >/dev/null 2>&1; then
  printf 'SKIP: python3 not found; tcr_set_nested_setting is a manual no-op\n'
  exit 0
fi

REAL_BASH="$(command -v bash)"

# run_nested <home> <dotted.key> <value> — source common.sh with HOME overridden
# and call the function. Echoes output; sets RC.
run_nested() {
  local out
  out=$(NO_COLOR=1 HOME="$1" "$REAL_BASH" -c "
    export NO_COLOR HOME
    . '$COMMON'
    tcr_set_nested_setting '$2' '$3'
  " 2>&1)
  RC=$?
  printf '%s' "$out"
}

# nv <file> <dotted.key> — JSON value at the nested path (or null/empty).
nv() {
  python3 -c "import json
d=json.load(open('$1'))
for k in '$2'.split('.'):
    d=d.get(k) if isinstance(d,dict) else None
print(json.dumps(d))" 2>/dev/null
}
# norm <file> — whole file as canonical sorted JSON.
norm() { python3 -c "import json;print(json.dumps(json.load(open('$1')),sort_keys=True))" 2>/dev/null; }

# ---- fresh file ------------------------------------------------------------
echo "test: fresh file -> creates worktree.baseRef"
H="$WORK/h1"; mkdir -p "$H"
out=$(run_nested "$H" worktree.baseRef head)
CFG="$H/.claude/settings.json"
assert_contains "reports set" "$out" "set worktree.baseRef=head"
[ "$(nv "$CFG" worktree.baseRef)" = '"head"' ] && ok "nested value written" \
  || no "nested value written (got: $(nv "$CFG" worktree.baseRef))"

# ---- existing object: siblings preserved -----------------------------------
echo "test: existing object -> sub-key added, siblings preserved, backup kept"
H="$WORK/h2"; mkdir -p "$H/.claude"
printf '{"worktree":{"autoCleanup":true},"model":"opus"}\n' > "$H/.claude/settings.json"
out=$(run_nested "$H" worktree.baseRef head)
CFG="$H/.claude/settings.json"
[ "$(nv "$CFG" worktree.autoCleanup)" = 'true' ] && ok "sibling sub-key preserved" || no "sibling sub-key preserved"
[ "$(nv "$CFG" worktree.baseRef)" = '"head"' ] && ok "baseRef added" || no "baseRef added"
[ "$(nv "$CFG" model)" = '"opus"' ] && ok "top-level sibling preserved" || no "top-level sibling preserved"
assert_contains "reports backup" "$out" "backed up"

# ---- unparseable file ------------------------------------------------------
echo "test: unparseable file -> left untouched, warns"
H="$WORK/h3"; mkdir -p "$H/.claude"
printf '{ not json,,, ' > "$H/.claude/settings.json"
before=$(cat "$H/.claude/settings.json")
out=$(run_nested "$H" worktree.baseRef head)
assert_contains "warns about non-JSON" "$out" "isn't plain JSON"
[ "$(cat "$H/.claude/settings.json")" = "$before" ] && ok "file untouched" || no "file untouched"

# ---- idempotent ------------------------------------------------------------
echo "test: idempotent re-run -> identical JSON"
H="$WORK/h4"; mkdir -p "$H"
run_nested "$H" worktree.baseRef head >/dev/null
first=$(norm "$H/.claude/settings.json")
run_nested "$H" worktree.baseRef head >/dev/null
second=$(norm "$H/.claude/settings.json")
[ -n "$first" ] && [ "$first" = "$second" ] && ok "re-run identical" || no "re-run identical ($first vs $second)"

# ---- deep dotted key -------------------------------------------------------
echo "test: deep dotted key -> creates intermediate objects"
H="$WORK/h5"; mkdir -p "$H"
run_nested "$H" a.b.c deep >/dev/null
[ "$(nv "$H/.claude/settings.json" a.b.c)" = '"deep"' ] && ok "deep nested created" || no "deep nested created"

# ---- both setups wire it ---------------------------------------------------
echo "test: both setups wire worktree.baseRef=head exactly once"
for s in setup-dev.sh setup-simple.sh; do
  n=$(grep -c 'tcr_set_nested_setting worktree.baseRef head' "$SETUP_DIR/$s")
  [ "$n" -eq 1 ] && ok "$s wires it once" || no "$s wires it ($n times)"
done

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
