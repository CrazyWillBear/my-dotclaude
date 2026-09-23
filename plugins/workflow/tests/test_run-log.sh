#!/usr/bin/env bash
#
# Tests for scripts/run-log.sh — the orchestrator's append-only run log.
#
# The log stores seven things and no more: scope, held, respawned, decision, and
# (#104) planned, consulted, escalated. The vocabulary is small BY DESIGN — the issue
# thread carries everything else, and a second copy of a fact that lives on the issue
# can only disagree with it. So the tests pin the vocabulary shut as hard as they pin
# the folding.
#
# Covers:
#   * append -> replay round trip, in order, with a ts on every record
#   * append is APPEND-ONLY: a second writer never clobbers the first
#   * an unknown event, junk JSON, a non-object payload and a junk runid all fail
#   * state folds scope, held (deduped), respawn COUNTS and decisions
#   * a torn line is counted, never silently dropped
#   * replay/state on a run that was never logged fails loud
#   * the log is keyed per repo, beside the handoffs — two repos never collide
#   * the keyed dir matches the context plugin's save-handoff.sh independently —
#     no cross-plugin call (a marketplace install cannot address a sibling plugin
#     by relative path; see docs/swarm-design.md § Plugin split)
#
# Run: bash plugins/workflow/tests/test_run-log.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNLOG="$PLUGIN_ROOT/scripts/run-log.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
GLOBAL_HOME="$WORK/home"
mkdir -p "$GLOBAL_HOME/.claude/handoffs"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in: $2)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

mkrepo() {
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" config user.email t@t.com
    git -C "$1" config user.name t
}
mkrepo "$WORK/repo"
mkrepo "$WORK/other"

# rl <repo> <args...>
rl() { local repo="$1"; shift; (cd "$repo" && HOME="$GLOBAL_HOME" bash "$RUNLOG" "$@") 2>"$WORK/err"; }
r()  { rl "$WORK/repo" "$@"; }
err() { cat "$WORK/err"; }

# rl() with HOME removed entirely rather than pointed somewhere fake.
rl_nohome() { local repo="$1"; shift; (cd "$repo" && env -u HOME bash "$RUNLOG" "$@") 2>"$WORK/err"; }

echo "test: no HOME at all -> fails where it can say why, not on an unbound variable"
# The per-repo keyed dir expands $HOME, and run-log.sh runs under `set -u`. That line sits
# BEFORE the runid and event validation, so any invocation inside a repo reaches it.
rl_nohome "$WORK/repo" append r1 scope '{"issues":[1]}'
case "$(err)" in
    *"unbound variable"*) no "no HOME: aborted on an unbound \$HOME" ;;
    *) ok "no HOME: no unbound-variable abort" ;;
esac

# ---------------------------------------------------------------------------
echo "test: append then replay round-trips, in order"
r append run1 scope '{"issues":[12,13,14]}'
r append run1 held '{"n":15,"why":"capped merge"}'
out=$(r replay run1)
assert_equals "two lines" "$(printf '%s\n' "$out" | wc -l)" "2"
assert_contains "scope first" "$(printf '%s\n' "$out" | head -1)" '"event": "scope"'
assert_contains "held second" "$(printf '%s\n' "$out" | tail -1)" '"event": "held"'
assert_contains "payload survives" "$out" "capped merge"
assert_contains "every record is timestamped" "$out" '"ts":'

echo "test: an event with no payload is fine"
r append run1 decision
assert_equals "three lines" "$(r replay run1 | wc -l)" "3"

echo "test: appending never clobbers — the log is append-only"
before=$(r replay run1 | wc -l)
r append run1 respawned '{"n":12}'
assert_equals "one more line, nothing lost" "$(r replay run1 | wc -l)" "$((before + 1))"

# ---------------------------------------------------------------------------
echo "test: state folds scope, held, respawn COUNTS and decisions"
r append run2 scope '{"issues":[12,13]}'
r append run2 scope '{"issues":[13,14]}'
r append run2 held '{"n":15}'
r append run2 held '{"n":15}'
r append run2 respawned '{"n":12}'
r append run2 respawned '{"n":12}'
r append run2 respawned '{"n":13}'
r append run2 decision '{"what":"merged #12 despite low findings — filed as follow-up"}'
out=$(r state run2)
assert_contains "runid" "$out" "runid=run2"
assert_contains "scope is the union, in order" "$out" "scope=12,13,14"
assert_contains "held is deduped" "$out" "held=15"
assert_contains "respawn counts, not events" "$out" "respawned=12:2,13:1"
assert_contains "decisions carry their text" "$out" "decision=merged #12 despite low findings"

echo "test: respawn counts are what 'respawn once, escalate on the second' reads"
assert_equals "12 respawned twice" "$(printf '%s\n' "$out" | sed -n 's/^respawned=//p')" "12:2,13:1"

echo "test: planned / consulted / escalated fold per issue, like respawned (#104)"
# Deviation rate is DATA: after a handful of issues these counts answer whether terra
# can take the complex implementer slot. Consults and escalations are COUNTS per issue;
# planned is a set (one plan per issue).
r append run5 planned '{"n":12}'
r append run5 planned '{"n":13}'
r append run5 planned '{"n":12}'
r append run5 consulted '{"n":12}'
r append run5 consulted '{"n":12}'
r append run5 escalated '{"n":12,"reason":"failed","attempt":0}'
r append run5 escalated '{"n":13,"reason":"stall","attempt":1}'
r append run5 escalated '{"n":13,"reason":"deviation-cap","attempt":0}'
out=$(r state run5)
assert_contains "planned is a deduped set" "$out" "planned=12,13"
assert_contains "consult counts per issue" "$out" "consulted=12:2"
assert_contains "escalation counts per issue" "$out" "escalated=12:1,13:2"
assert_contains "the escalation reasons survive replay for the pilot's numbers" "$(r replay run5)" '"reason": "deviation-cap"'

echo "test: follow-up folds parent:child (#117)"
r append run6 follow-up '{"n":84,"child":131,"reblocked":[85,95]}'
assert_contains "followups fold" "$(r state run6)" "followups=84:131"

echo "test: integration-review is an accepted event (#121)"
r append run7 integration-review '{"high":1,"medium":0,"low":2,"child":900}'
assert_equals "append exits 0" "$?" "0"
assert_contains "replay shows the event" "$(r replay run7)" '"event": "integration-review"'

echo "test: an empty log folds to empty fields, not a crash"
r append run3 decision '{"what":"nothing yet"}'
out=$(r state run3)
assert_contains "empty scope" "$out" "scope="
assert_contains "empty held" "$out" "held="
assert_contains "empty planned" "$out" "planned="
assert_contains "empty consulted" "$out" "consulted="
assert_contains "empty escalated" "$out" "escalated="
assert_contains "empty followups" "$out" "followups="

echo "test: a torn line is COUNTED, never silently dropped"
printf 'not json\n' >>"$(r path run2)"
assert_contains "reports the unparseable line" "$(r state run2)" "unparseable_lines=1"
assert_contains "and still folds the good ones" "$(r state run2)" "scope=12,13,14"

# ---------------------------------------------------------------------------
echo "test: the vocabulary is closed"
r append run1 spawned '{"n":12}' >/dev/null; assert_equals "unknown event exits 1" "$?" "1"
assert_contains "names the vocabulary" "$(err)" "scope | held | respawned | decision | planned | consulted | escalated | follow-up | integration-review"
assert_not_contains "and did not write it" "$(r replay run1)" '"event": "spawned"' 
r append run1 >/dev/null; assert_equals "no event exits 1" "$?" "1"

echo "test: a payload cannot overwrite the fields the file guarantees"
r append run4 held '{"event":"spawned","ts":0,"n":9}'
line=$(r replay run4)
assert_contains "the event stays held" "$line" '"event": "held"'
assert_not_contains "the payload event is discarded" "$line" '"event": "spawned"'
assert_not_contains "the payload ts is discarded" "$line" '"ts": 0'
assert_contains "and it still folds as held" "$(r state run4)" "held=9"

echo "test: bad input fails loud"
r append run1 held 'not json' >/dev/null; assert_equals "junk payload exits 1" "$?" "1"
assert_contains "says it was not JSON" "$(err)" "not JSON"
r append run1 held '[1,2]' >/dev/null; assert_equals "a JSON array exits 1" "$?" "1"
assert_contains "wants an object" "$(err)" "must be a JSON object"
r append 'run 1;rm -rf' held >/dev/null; assert_equals "junk runid exits 1" "$?" "1"
r append '..' held >/dev/null; assert_equals "a .. runid exits 1 — dots are allowed, a path step is not" "$?" "1"
r bogus run1 >/dev/null; assert_equals "unknown command exits 1" "$?" "1"
r replay >/dev/null; assert_equals "missing runid exits 1" "$?" "1"

echo "test: a run that was never logged fails loud, not empty"
r replay never >/dev/null; assert_equals "replay exits 1" "$?" "1"
assert_contains "says where it looked" "$(err)" "no run log for 'never'"
r state never >/dev/null; assert_equals "state exits 1" "$?" "1"

# ---------------------------------------------------------------------------
echo "test: the log is keyed per repo, beside the handoffs"
assert_contains "lives under the keyed handoff dir" "$(r path run1)" "$GLOBAL_HOME/.claude/handoffs/"
assert_contains "in runs/" "$(r path run1)" "/runs/run1.jsonl"
rl "$WORK/other" append run1 scope '{"issues":[99]}'
assert_contains "another repo's run1 is a different file" \
    "$(rl "$WORK/other" state run1)" "scope=99"
assert_contains "and this repo's is untouched" "$(r state run1)" "scope=12,13,14"

echo "test: outside a git repo it fails loud rather than writing somewhere random"
(cd "$WORK" && HOME="$GLOBAL_HOME" bash "$RUNLOG" append run1 scope) >/dev/null 2>"$WORK/err"
assert_equals "exits 1" "$?" "1"
assert_contains "says why" "$(err)" "keyed per repo"

# ---------------------------------------------------------------------------
echo "test: no cross-plugin call — run-log.sh never shells out to save-handoff.sh"
assert_not_contains "run-log.sh source has no save-handoff.sh invocation (prose mentions are fine)" \
    "$(cat "$RUNLOG")" '/save-handoff.sh"'

echo "test: run-log.sh's keyed dir matches the context plugin's save-handoff.sh --print-dir (one keying scheme, not two)"
CONTEXT_SAVE="$PLUGIN_ROOT/../context/scripts/save-handoff.sh"
if [ -f "$CONTEXT_SAVE" ]; then ok "context plugin's save-handoff.sh exists"; else no "context plugin's save-handoff.sh exists (missing: $CONTEXT_SAVE)"; fi
expected_dir="$(HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$WORK/repo" bash "$CONTEXT_SAVE" --print-dir)"
got_dir="$(dirname "$(dirname "$(r path run1)")")"
assert_equals "run-log and save-handoff key the same repo identically" "$got_dir" "$expected_dir"

echo "test: keying still works with sha1sum absent from PATH (not present on macOS by default)"
NOSHA_BIN="$WORK/nosha-bin"
mkdir -p "$NOSHA_BIN"
for bin in git python3; do
    p="$(command -v "$bin" 2>/dev/null)" && ln -sf "$p" "$NOSHA_BIN/$bin"
done
BASH_BIN="$(command -v bash)"
nosha_dir="$(cd "$WORK/repo" && HOME="$GLOBAL_HOME" PATH="$NOSHA_BIN" "$BASH_BIN" "$RUNLOG" path run1 2>"$WORK/err")"
assert_equals "same keyed dir with sha1sum missing from PATH" "$nosha_dir" "$(r path run1)"

echo "test: run-log.sh does not depend on the sha1sum binary"
assert_not_contains "no sha1sum invocation in source" "$(cat "$RUNLOG")" "sha1sum"

echo "test: a failing key computation dies loud instead of collapsing to the unkeyed dir"
FAILPY_BIN="$WORK/failpy-bin"
mkdir -p "$FAILPY_BIN"
REAL_PYTHON3="$(command -v python3)"
REAL_GIT="$(command -v git)"
ln -sf "$REAL_GIT" "$FAILPY_BIN/git"
cat >"$FAILPY_BIN/python3" <<EOF
#!$BASH_BIN
if [ "\$1" = "-c" ]; then
    echo "simulated key-computation failure" >&2
    exit 1
fi
exec "$REAL_PYTHON3" "\$@"
EOF
chmod +x "$FAILPY_BIN/python3"
out=$(cd "$WORK/repo" && HOME="$GLOBAL_HOME" PATH="$FAILPY_BIN" "$BASH_BIN" "$RUNLOG" path run1 2>"$WORK/err")
rc=$?
assert_equals "exits 1 rather than printing a collapsed path" "$rc" "1"
assert_equals "prints nothing on stdout" "$out" ""
assert_contains "says the key computation failed" "$(cat "$WORK/err")" "key"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
