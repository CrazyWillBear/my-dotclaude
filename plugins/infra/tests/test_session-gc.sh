#!/usr/bin/env bash
#
# Tests for scripts/session-gc.sh — removes terminal orch-* registry rows, never a live one.
# The registry and `claude rm` are a stub; nothing here touches a real session.
#
# Run: bash plugins/infra/tests/test_session-gc.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GC="$SCRIPT_DIR/../scripts/session-gc.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in '$2')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

BIN="$WORK/bin"; mkdir -p "$BIN"
cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = agents ]; then cat "$STUB_AGENTS"; exit "${STUB_AGENTS_RC:-0}"; fi
if [ "$1" = rm ]; then printf '%s\n' "$2" >>"$STUB_RM"; [ "$2" != bad1 ]; exit; fi
exit 0
STUB
chmod +x "$BIN/claude"
export PATH="$BIN:$PATH" STUB_AGENTS="$WORK/agents.json" STUB_RM="$WORK/rm.log"
cat >"$STUB_AGENTS" <<'JSON'
[
  {"id":"d1","kind":"background","name":"orch-r1-issue-12-a0","state":"done"},
  {"id":"s1","kind":"background","name":"orch-r1-issue-13-a0-r1","state":"stopped"},
  {"id":"f1","kind":"background","name":"orch-r2-issue-14-a0","state":"failed"},
  {"id":"b1","kind":"background","name":"orch-r1-issue-15-a0","state":"working"},
  {"id":"i1","kind":"background","name":"orch-r1-issue-16-a0","state":"idle"},
  {"id":"k1","kind":"background","name":"orch-r1-issue-17-a0","state":"blocked"},
  {"id":"p1","kind":"background","name":"swe-manager","state":"done"},
  {"id":"x1","kind":"interactive","name":"orch-r1-issue-18-a0","status":"done"}
]
JSON

echo "test: --run removes this run's terminal rows only"
rm -f "$STUB_RM"
out=$(bash "$GC" --run r1); rc=$?
assert_equals "exit 0" "$rc" "0"
assert_equals "done and stopped rows of r1" "$(sort "$STUB_RM" | tr '\n' ' ')" "d1 s1 "
assert_contains "names what it removed" "$out" "removed orch-r1-issue-12-a0 d1"

echo "test: --all-terminal reaches every run, still never a live row"
rm -f "$STUB_RM"
bash "$GC" --all-terminal >/dev/null
removed="$(sort "$STUB_RM" | tr '\n' ' ')"
assert_equals "every terminal orch- background row" "$removed" "d1 f1 s1 "
for live in b1 i1 k1 p1 x1; do assert_not_contains "never $live" "$removed" "$live"; done

echo "test: nothing to remove says so"
printf '[]\n' >"$STUB_AGENTS"
assert_equals "empty registry" "$(bash "$GC" --run r1)" "nothing to remove"

echo "test: a failed removal is loud, the rest still run"
printf '[{"id":"bad1","kind":"background","name":"orch-r1-issue-1-a0","state":"done"},{"id":"ok1","kind":"background","name":"orch-r1-issue-2-a0","state":"done"}]\n' >"$STUB_AGENTS"
rm -f "$STUB_RM"
bash "$GC" --run r1 >/dev/null 2>"$WORK/err"; rc=$?
assert_equals "exit 1" "$rc" "1"
assert_contains "the other row was still removed" "$(cat "$STUB_RM")" "ok1"
assert_contains "names the failure" "$(cat "$WORK/err")" "bad1"

echo "test: an unreadable registry and bad usage fail loud"
printf 'not json' >"$STUB_AGENTS"
bash "$GC" --run r1 >/dev/null 2>&1; assert_equals "junk registry exits 1" "$?" "1"
bash "$GC" >/dev/null 2>&1; assert_equals "no flag exits 1" "$?" "1"
bash "$GC" --run ../x >/dev/null 2>&1; assert_equals "traversal runid exits 1" "$?" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
