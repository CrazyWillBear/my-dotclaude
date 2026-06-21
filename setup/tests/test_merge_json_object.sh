#!/usr/bin/env bash
#
# Tests for tcr_merge_json_object in setup/lib/common.sh.
#
# Black-box: source the library in a subshell, drive tcr_merge_json_object
# directly against scratch files, and assert on the resulting JSON + output.
#
# Covers:
#   * fresh file              -> creates {key: value}.
#   * existing object         -> merges in, sibling keys preserved, backup kept.
#   * unparseable file        -> left untouched, warns (does not clobber).
#   * idempotent re-run       -> resulting JSON is identical.
#   * invalid JSON blob       -> hard error (non-zero exit, "internal" message).
#
# Run: bash setup/tests/test_merge_json_object.sh  (non-zero if any fail)

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

REAL_BASH="$(command -v bash)"

# run_merge <cfg> <key> <blob> — source common.sh and call the function. Echoes
# the function output; sets global RC to its exit code. Blobs must not contain
# single quotes (we wrap them in single quotes for the subshell).
run_merge() {
  local out
  out=$(NO_COLOR=1 "$REAL_BASH" -c "
    export NO_COLOR
    . '$COMMON'
    tcr_merge_json_object '$1' '$2' '$3'
  " 2>&1)
  RC=$?
  printf '%s' "$out"
}

# json_field <file> <key> — the JSON value at <key>, normalized (or empty).
json_field() {
  python3 -c "import json,sys; print(json.dumps(json.load(open('$1')).get('$2')))" 2>/dev/null
}
# json_norm <file> — whole file as sorted-key canonical JSON (or empty).
json_norm() {
  python3 -c "import json; print(json.dumps(json.load(open('$1')),sort_keys=True))" 2>/dev/null
}

BLOB='{"type":"command","command":"python3 status.py"}'

# ---- test: fresh file -> creates {key: value} ------------------------------
echo "test: fresh file -> creates the key"
CFG="$WORK/fresh.json"
out=$(run_merge "$CFG" statusLine "$BLOB")
assert_contains "reports set" "$out" "set statusLine"
[ "$(json_field "$CFG" statusLine)" = '{"type": "command", "command": "python3 status.py"}' ] \
  && ok "value written correctly" || no "value written correctly (got: $(json_field "$CFG" statusLine))"

# ---- test: existing object -> merge, preserve siblings, backup -------------
echo "test: existing object -> merges in, preserves siblings, backs up"
CFG="$WORK/existing.json"
printf '{"model":"opus","permissions":{"allow":["x"]}}\n' > "$CFG"
out=$(run_merge "$CFG" statusLine "$BLOB")
assert_contains "reports backup" "$out" "backed up $CFG"
[ "$(json_field "$CFG" model)" = '"opus"' ] && ok "sibling key preserved" || no "sibling key preserved"
[ "$(json_field "$CFG" statusLine)" != "null" ] && ok "new key merged in" || no "new key merged in"
bak=$(ls "$CFG".bak.* 2>/dev/null | head -1)
[ -n "$bak" ] && grep -q '"model":"opus"' "$bak" && ok "backup holds original" || no "backup holds original"

# ---- test: unparseable file -> untouched -----------------------------------
echo "test: unparseable file -> left untouched, warns"
CFG="$WORK/bad.json"
printf '{ this is not json, ' > "$CFG"
before=$(cat "$CFG")
out=$(run_merge "$CFG" statusLine "$BLOB")
assert_contains "warns about non-JSON" "$out" "isn't plain JSON"
[ "$(cat "$CFG")" = "$before" ] && ok "file untouched" || no "file untouched"

# ---- test: idempotent re-run -----------------------------------------------
echo "test: idempotent re-run -> identical JSON"
CFG="$WORK/idem.json"
run_merge "$CFG" statusLine "$BLOB" >/dev/null
first=$(json_norm "$CFG")
run_merge "$CFG" statusLine "$BLOB" >/dev/null
second=$(json_norm "$CFG")
[ -n "$first" ] && [ "$first" = "$second" ] && ok "re-run produces identical JSON" \
  || no "re-run produces identical JSON ($first vs $second)"

# ---- test: invalid blob -> hard error --------------------------------------
echo "test: invalid JSON blob -> hard error"
CFG="$WORK/blob.json"
# Call directly (not via run_merge): command substitution would swallow the exit
# code we need to assert on.
out=$(NO_COLOR=1 "$REAL_BASH" -c "
    export NO_COLOR
    . '$COMMON'
    tcr_merge_json_object '$CFG' statusLine '{not valid}'
  " 2>&1)
rc=$?
[ "$rc" -ne 0 ] && ok "non-zero exit on bad blob" || no "non-zero exit on bad blob"
assert_contains "reports internal error" "$out" "internal"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
