#!/usr/bin/env bash
#
# Tests for scripts/review-tokens.sh — reading the reviewer's REAL token usage out of its
# subagent rollout (#98), since `codex exec review --json` itself reports all zeroes.
#
# THE CENTRAL MECHANISM is the join: the reviewer's own thread id (read from the "session
# id:" banner review-stderr.log already carries — no --json needed) equals the subagent
# rollout's `session_id`; that subagent's own `id` differs, which is what tells it apart
# from the reviewer's OWN rollout (id == session_id there). Fixture shapes below are
# trimmed but field-faithful to two real captured rollouts (ops-os issue #28, this repo's
# #96 gate run issue-23) — verified by hand against the actual files under
# ~/.codex/sessions before this test was written.
#
# Run: bash plugins/infra/tests/test_review-tokens.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/review-tokens.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SESSIONS="$WORK/sessions"
export CODEX_SESSIONS_ROOT="$SESSIONS"
mkdir -p "$SESSIONS"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in '$2')" ;; esac; }

run() {   # run <log-file> -> OUT/ERR/RC
    local errf="$WORK/err"
    OUT="$(bash "$SCRIPT" "$1" 2>"$errf")"
    RC=$?
    ERR="$(cat "$errf")"
}

# A real reviewer banner: the escape codes sit AROUND "session id:", not inside it —
# `\x1b[1msession id:\x1b[0m <uuid>` — ground-truthed against a real review-stderr.log.
mklog() {   # mklog <file> <thread-id>
    printf 'OpenAI Codex v0.155.0\n--------\nworkdir: /fake/worktree\n' >"$1"
    printf '\033[1msession id:\033[0m %s\n--------\n' "$2" >>"$1"
}

# mkrollout <session_id> <id> [usage-json ...] — one session_meta line, then one
# token_usage_record line per extra argument. `id == session_id` is the reviewer's OWN
# rollout shape; `id != session_id` is the subagent's.
mkrollout() {
    local sid="$1" id="$2" f="$WORK/sessions/2026/09/18/rollout-2026-09-18T00-00-00-$2.jsonl"
    mkdir -p "$(dirname "$f")"
    printf '{"type":"session_meta","payload":{"session_id":"%s","id":"%s","cwd":"/fake/worktree"}}\n' \
        "$sid" "$id" >"$f"
    shift 2
    for usage in "$@"; do
        printf '{"type":"token_usage_record","payload":{"thread_id":"%s","session_id":"%s","turn_token_usage":%s}}\n' \
            "$id" "$sid" "$usage" >>"$f"
    done
}

PARENT="11111111-1111-1111-1111-111111111111"
CHILD="22222222-2222-2222-2222-222222222222"
USAGE1='{"input_tokens":100,"cached_input_tokens":10,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":130}'
USAGE2='{"input_tokens":500,"cached_input_tokens":400,"cache_write_input_tokens":0,"output_tokens":80,"reasoning_output_tokens":30,"total_tokens":610}'
EXPECTED='{"cache_write_input_tokens":0,"cached_input_tokens":400,"input_tokens":500,"output_tokens":80,"reasoning_output_tokens":30,"total_tokens":610}'

# ---------------------------------------------------------------------------
echo "test: joins by session_id and picks the LAST token_usage_record, not the first"
mkrollout "$PARENT" "$PARENT"                    # the reviewer's own rollout: no usage
mkrollout "$PARENT" "$CHILD" "$USAGE1" "$USAGE2" # the subagent: two records, cumulative
mklog "$WORK/review-stderr.log" "$PARENT"
run "$WORK/review-stderr.log"
assert_equals "exit 0" "$RC" "0"
assert_equals "the LAST record's turn_token_usage, sorted-key compact JSON" "$OUT" "$EXPECTED"

echo "test: the reviewer's OWN rollout (id == session_id) is never mistaken for the child"
rm -rf "$SESSIONS"; mkdir -p "$SESSIONS"
mkrollout "$PARENT" "$PARENT" "$USAGE1"   # even if IT somehow carried a usage record
mklog "$WORK/review-stderr.log" "$PARENT"
run "$WORK/review-stderr.log"
assert_equals "exit 1 — no subagent, so no number is invented" "$RC" "1"
assert_equals "NOTHING on stdout" "$OUT" ""
assert_contains "says no subagent rollout joined" "$ERR" "no subagent rollout"

# ---------------------------------------------------------------------------
echo "test: no \"session id:\" banner in the log — refused, not guessed"
rm -rf "$SESSIONS"; mkdir -p "$SESSIONS"
printf 'OpenAI Codex v0.155.0\n--------\nsomething went wrong\n' >"$WORK/review-stderr.log"
run "$WORK/review-stderr.log"
assert_equals "exit 1" "$RC" "1"
assert_equals "NOTHING on stdout" "$OUT" ""
assert_contains "names the missing banner" "$ERR" "session id"

echo "test: session id present but no rollout anywhere joins it"
mklog "$WORK/review-stderr.log" "$PARENT"
run "$WORK/review-stderr.log"
assert_equals "exit 1" "$RC" "1"
assert_equals "NOTHING on stdout" "$OUT" ""
assert_contains "says nothing joined" "$ERR" "no subagent rollout"

echo "test: the child rollout exists but never recorded a token_usage_record"
rm -rf "$SESSIONS"; mkdir -p "$SESSIONS"
mkrollout "$PARENT" "$CHILD"   # session_meta only, no usage line at all
mklog "$WORK/review-stderr.log" "$PARENT"
run "$WORK/review-stderr.log"
assert_equals "exit 1" "$RC" "1"
assert_equals "NOTHING on stdout" "$OUT" ""
assert_contains "says no usage was recorded" "$ERR" "recorded no token_usage_record"

echo "test: a MISSING review-stderr log is refused"
run "$WORK/no-such-log.txt"
assert_equals "exit 1" "$RC" "1"
assert_equals "NOTHING on stdout" "$OUT" ""
assert_contains "names the missing file" "$ERR" "no review-stderr log"

echo "test: no argument at all is a usage error"
OUT="$(bash "$SCRIPT" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"
assert_equals "exit 1" "$RC" "1"
assert_equals "NOTHING on stdout" "$OUT" ""
assert_contains "usage" "$ERR" "usage"

echo "test: a missing sessions root is refused rather than silently scanning nothing"
rm -rf "$SESSIONS"
mklog "$WORK/review-stderr.log" "$PARENT"
run "$WORK/review-stderr.log"
assert_equals "exit 1" "$RC" "1"
assert_equals "NOTHING on stdout" "$OUT" ""
assert_contains "names the missing root" "$ERR" "no codex sessions root"
mkdir -p "$SESSIONS"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
