#!/usr/bin/env bash
#
# Tests for scripts/distill-transcript.sh — the session-log distiller /verify-plan
# runs before it measures.
#
# A Claude Code transcript is mostly NOT conversation: tool results, tool-call
# parameters, thinking blocks and harness bookkeeping dwarf the spoken text. On a
# real design session this measured 1.71 MB raw against ~138 KB of actual dialogue.
# Distilling first is what keeps a long session under /verify-plan's size cap
# instead of tripping it — and a long design session is exactly when you most want
# the check to run.
#
# The contract that matters: EVERY non-blank user/assistant text block survives.
# Losing one silently would make the verifier report ALIGNED against a decision it
# never read, which is worse than not running it at all.
#
# Covers:
#   * every non-blank text block is kept, in order, labelled by role
#   * bare-string content (user turns) and text blocks (assistant turns) both kept
#   * tool_use / tool_result / thinking blocks are dropped
#   * non-user/assistant entries (system, attachment, ...) are dropped
#   * a turn whose only content is a tool_result produces no stanza
#   * malformed JSON lines are skipped, not fatal
#   * output is substantially smaller than input
#   * usage / missing-file errors exit non-zero
#
# Run: bash plugins/personal-tools/tests/test_distill-transcript.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DISTILL="$PLUGIN_ROOT/scripts/distill-transcript.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }

SRC="$WORK/t.jsonl"
{
  # user turn, bare-string content
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"USERSAIDONE"}}'
  # assistant turn: thinking + text + tool_use — only the text survives
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"THINKINGSECRET"},{"type":"text","text":"ASSISTANTSAIDONE"},{"type":"tool_use","name":"Bash","input":{"command":"TOOLCALLJUNK"}}]}}'
  # user turn that is ONLY a tool_result — no stanza
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"TOOLRESULTJUNK"}]}}'
  # user turn: tool_result AND text — the text survives
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"MOREJUNK"},{"type":"text","text":"USERSAIDTWO"}]}}'
  # harness bookkeeping entries — dropped wholesale
  printf '%s\n' '{"type":"system","content":"SYSTEMJUNK"}'
  printf '%s\n' '{"type":"attachment","content":"ATTACHJUNK"}'
  # blank text block — produces no stanza
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"   "}]}}'
  # malformed line — skipped, not fatal
  printf '%s\n' '{"type":"assistant","message":{'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ASSISTANTSAIDTWO"}]}}'
} > "$SRC"

OUT="$WORK/out.md"
run_out="$(bash "$DISTILL" "$SRC" "$OUT" 2>&1)"; rc=$?
assert_equals "exits 0 on a valid transcript" "$rc" "0"
body="$(cat "$OUT" 2>/dev/null || true)"

echo "test: every spoken turn survives"
assert_contains "user bare-string kept"          "$body" "USERSAIDONE"
assert_contains "assistant text kept"            "$body" "ASSISTANTSAIDONE"
assert_contains "user text beside a tool_result" "$body" "USERSAIDTWO"
assert_contains "turn after a malformed line"    "$body" "ASSISTANTSAIDTWO"
assert_contains "roles are labelled"             "$body" "=== USER ==="
assert_contains "assistant role labelled"        "$body" "=== ASSISTANT ==="

echo "test: non-conversation content is dropped"
assert_not_contains "thinking dropped"     "$body" "THINKINGSECRET"
assert_not_contains "tool_use dropped"     "$body" "TOOLCALLJUNK"
assert_not_contains "tool_result dropped"  "$body" "TOOLRESULTJUNK"
assert_not_contains "second tool_result dropped" "$body" "MOREJUNK"
assert_not_contains "system entry dropped" "$body" "SYSTEMJUNK"
assert_not_contains "attachment dropped"   "$body" "ATTACHJUNK"

echo "test: stanza count matches the non-blank spoken turns (4)"
assert_equals "four stanzas written" "$(grep -c '^=== ' "$OUT")" "4"

echo "test: it reports what it did, and shrinks the input"
assert_contains "reports the output path" "$run_out" "$OUT"
assert_contains "reports turn count"      "$run_out" "turns=4"
if [ "$(wc -c < "$OUT")" -lt "$(wc -c < "$SRC")" ]; then ok "output smaller than input"; else no "output smaller than input"; fi

echo "test: errors exit non-zero"
if bash "$DISTILL" >/dev/null 2>&1;                     then no "no args exits non-zero";       else ok "no args exits non-zero"; fi
if bash "$DISTILL" "$WORK/nope.jsonl" >/dev/null 2>&1;  then no "missing file exits non-zero";  else ok "missing file exits non-zero"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
