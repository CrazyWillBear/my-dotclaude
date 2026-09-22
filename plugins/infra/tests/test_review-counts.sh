#!/usr/bin/env bash
#
# Tests for scripts/review-counts.sh — turning one independent-reviewer output into the
# finding counts the whole run is decided by.
#
# THE FORMAT. The reviewer is `claude -p` spawning my-review (review-cmd.sh, #104), told
# to emit `- [Pn] title — path:line` items or the literal `No findings.`. The item shape
# was inherited from `codex exec review`'s own template, which this script used to parse;
# the finding fixtures below are REAL CODEX OUTPUT copied verbatim from actual runs (a
# one-P1 review and the two-P2 review from ops-os issue #28), and they still parse — the
# one thing that changed is that a CLEAN review is now the literal line, not free prose.
#
# THE CENTRAL MECHANISM is that an UNREADABLE review is refused, never counted as clean.
# Zero findings and "I could not read this" are the same number of findings and opposite
# facts: one sends a branch to the merge queue, the other must stop the run. Every refusal
# path below asserts NOTHING on stdout, because a caller reads any output as a verdict.
#
# Run: bash plugins/infra/tests/test_review-counts.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/review-counts.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in '$2')" ;; esac; }

run() {   # run <file> -> OUT/ERR/RC
    local errf="$WORK/err"
    OUT="$(bash "$SCRIPT" "$1" 2>"$errf")"
    RC=$?
    ERR="$(cat "$errf")"
}

# ---------------------------------------------------------------------------
echo "test: the clean literal counts zero"
printf 'No findings.\n' >"$WORK/clean.txt"
run "$WORK/clean.txt"
assert_equals "exit 0" "$RC" "0"
assert_equals "zero across the board" "$OUT" "0 high, 0 medium, 0 low"
printf 'Reviewed %s..HEAD as one unit.\n\nno findings\n' abc >"$WORK/clean2.txt"
run "$WORK/clean2.txt"
assert_equals "the literal may follow a line of preamble, case-insensitive" "$OUT" "0 high, 0 medium, 0 low"

echo "test: free prose with no markers is REFUSED — it used to be codex's clean shape"
# `codex exec review` said "clean" in free prose. The claude reviewer is given one shape
# for clean, so prose without it is a reviewer that ignored its format — which is exactly
# what a reviewer that wrote its findings as a headed list would look like too.
cat >"$WORK/prose.txt" <<'EOF'
The change only updates the README description and introduces no functional issues.
EOF
run "$WORK/prose.txt"
assert_equals "exit 1" "$RC" "1"
assert_equals "NOTHING on stdout" "$OUT" ""
assert_contains "says the format drifted" "$ERR" "drifted"

echo "test: REAL codex output — one P1 becomes one high"
# Verbatim from a real run against a diff adding subprocess(shell=True).
cat >"$WORK/p1.txt" <<'EOF'
The new command runner introduces shell injection whenever its input is derived from an untrusted source. The arithmetic additions do not present an equivalent correctness issue.

Review comment:

- [P1] Avoid executing caller input through a shell — /tmp/x/m.py:13-13
  When `cmd` contains user-controlled or externally sourced text, `shell=True` allows shell metacharacters such as `;` and `&&` to execute additional commands with the process's privileges.
EOF
run "$WORK/p1.txt"
assert_equals "exit 0" "$RC" "0"
assert_equals "P1 is a high" "$OUT" "1 high, 0 medium, 0 low"

echo "test: REAL codex output — two P2s become two mediums (ops-os issue #28)"
# Verbatim shape from the run that proved --output-schema is ignored on a review turn.
cat >"$WORK/p2.txt" <<'EOF'
Vector searches can silently omit pages while asynchronous embedding batches are pending.

Full review comments:

- [P2] Reject searches while any page lacks an embedding — packages/retrieval/src/vector.ts:131-133
  During initial backfill this filter ignores unembedded rows.

- [P2] Reconcile the legacy document embedding column — migrations/0021_document_page_embeddings.sql:1-1
  This migration ships a 384-dimensional embedding job but leaves documents.embedding at vector(1536).
EOF
run "$WORK/p2.txt"
assert_equals "exit 0" "$RC" "0"
assert_equals "both counted as medium" "$OUT" "0 high, 2 medium, 0 low"

echo "test: severities map P0/P1 high, P2 medium, P3+ low"
cat >"$WORK/mix.txt" <<'EOF'
Findings:

- [P0] a critical one — a.py:1
- [P1] another high — b.py:2
- [P2] a medium — c.py:3
- [P3] a low — d.py:4
- [P4] also a low — e.py:5
EOF
run "$WORK/mix.txt"
assert_equals "exit 0" "$RC" "0"
assert_equals "the full mapping" "$OUT" "2 high, 1 medium, 2 low"

echo "test: a '*' bullet counts too — the template's list marker is not load-bearing"
printf '* [P1] a finding — a.py:1\n' >"$WORK/star.txt"
run "$WORK/star.txt"
assert_equals "counted" "$OUT" "1 high, 0 medium, 0 low"

# ---------------------------------------------------------------------------
# THE REFUSALS. Each one must print NOTHING on stdout: the callers read any output as a
# verdict, and a verdict is what decides whether unreviewed code reaches the merge queue.
echo "test: FORMAT DRIFT is refused, not counted as clean"
# A [Pn] severity is mentioned, but not as a finding list item. The honest answer is that
# this script no longer understands the format — NOT that the reviewer found nothing.
cat >"$WORK/drift.txt" <<'EOF'
I reviewed the diff and rated the one issue I found as [P1] severity, described below.

The function does not validate its input.
EOF
run "$WORK/drift.txt"
assert_equals "exit 1" "$RC" "1"
assert_equals "NOTHING on stdout" "$OUT" ""
assert_contains "says the format drifted" "$ERR" "drifted"

echo "test: an EMPTY review is refused — the reviewer produced no verdict"
: >"$WORK/empty.txt"
run "$WORK/empty.txt"
assert_equals "exit 1" "$RC" "1"
assert_equals "NOTHING on stdout" "$OUT" ""
assert_contains "says it is empty" "$ERR" "empty"

echo "test: whitespace only is empty too"
printf '\n  \n\t\n' >"$WORK/blank.txt"
run "$WORK/blank.txt"
assert_equals "exit 1" "$RC" "1"
assert_equals "NOTHING on stdout" "$OUT" ""

echo "test: a MISSING file is refused — that is what a deleted failed review looks like"
# Both callers delete the output of a reviewer that failed, so this is the live path for
# "the review did not happen", not a hypothetical.
run "$WORK/nosuchfile.txt"
assert_equals "exit 1" "$RC" "1"
assert_equals "NOTHING on stdout" "$OUT" ""
assert_contains "names the missing file" "$ERR" "no review file"

echo "test: no argument at all is a usage error, not an empty verdict"
OUT="$(bash "$SCRIPT" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"
assert_equals "exit 1" "$RC" "1"
assert_equals "NOTHING on stdout" "$OUT" ""
assert_contains "usage" "$ERR" "usage"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
