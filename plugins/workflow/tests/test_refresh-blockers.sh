#!/usr/bin/env bash
#
# Tests for scripts/refresh-blockers.sh — open blockers are re-read live into graph.json;
# closed stay closed; a failed lookup changes nothing. `gh` is a stub on PATH.
#
# Run: bash plugins/workflow/tests/test_refresh-blockers.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$(cd "$SCRIPT_DIR/../scripts" && pwd)/refresh-blockers.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }

mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
# gh issue view <n> --json state -q .state
echo "$3" >>"$STUB_LOG"
case "$3" in 10) echo CLOSED ;; 11) echo OPEN ;; 12) exit 1 ;; esac
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" STUB_LOG="$WORK/gh.log"

G="$WORK/graph.json"
echo '{"issues":[{"n":1}],"blockerStates":{"9":"closed","10":"open","11":"open","12":"unknown"},"mockDebtOpen":[]}' >"$G"
bash "$REFRESH" "$G" "$WORK"
st() { jq -r --arg n "$1" '.blockerStates[$n]' "$G"; }

echo "test: an externally-closed blocker flips to closed"
assert_equals "#10 closed" "$(st 10)" "closed"
echo "test: a still-open blocker stays open"
assert_equals "#11 open" "$(st 11)" "open"
echo "test: a failed lookup leaves the old state"
assert_equals "#12 unknown" "$(st 12)" "unknown"
echo "test: closed refs are not re-queried"
assert_equals "#9 closed" "$(st 9)" "closed"
assert_equals "no gh call for #9" "$(grep -c '^9$' "$STUB_LOG")" "0"
assert_equals "rest of the graph intact" "$(jq -c .issues "$G")" '[{"n":1}]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
