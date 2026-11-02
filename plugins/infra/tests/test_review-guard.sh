#!/usr/bin/env bash
#
# Tests for scripts/review-guard.sh — runs the reviewer, unless the branch has no commits
# past its base: there is nothing to review, and a reviewer asked anyway reports "no commits
# to review" as a finding, which files a follow-up issue for an empty slice (#26 -> #27). It
# is NOT a clean verdict either (a worker that committed nothing would fold as merged): the
# guard refuses with exit 3 and no verdict, so the slice is held for a human.
#
# Run: bash plugins/infra/tests/test_review-guard.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$(cd "$SCRIPT_DIR/../scripts" && pwd)/review-guard.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
REPO="$WORK/repo"
git init -q "$REPO"
git -C "$REPO" commit -q --allow-empty -m base
BASE="$(git -C "$REPO" rev-parse HEAD)"
# a stand-in reviewer: records that it ran and echoes its arguments
printf '#!/usr/bin/env bash\ntouch "%s/ran"\nprintf "reviewed:%%s\\n" "$*"\n' "$WORK" >"$WORK/reviewer"
run() { OUT="$(cd "$REPO" && bash "$GUARD" "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }

echo "test: no commits past the base — no verdict at all, and the reviewer never runs"
run "$BASE" bash "$WORK/reviewer" a
assert_equals "exit 3" "$RC" "3"
assert_equals "nothing on stdout a counter could read as clean" "$OUT" ""
case "$ERR" in *"no commits past its base"*) ok "says why on stderr" ;; *) no "stderr: $ERR" ;; esac
[ ! -e "$WORK/ran" ] && ok "reviewer not run" || no "reviewer ran on an empty branch"

echo "test: commits past the base — the reviewer runs, argv intact"
git -C "$REPO" commit -q --allow-empty -m work
run "$BASE" bash "$WORK/reviewer" "a b" c
assert_equals "its output passes through" "$OUT" "reviewed:a b c"
[ -e "$WORK/ran" ] && ok "reviewer ran" || no "reviewer did not run"

echo "test: an unresolvable base — fail open, the reviewer runs"
rm -f "$WORK/ran"
run deadbeefdeadbeefdeadbeefdeadbeefdeadbeef bash "$WORK/reviewer" x
assert_equals "reviewer output" "$OUT" "reviewed:x"

echo "test: the reviewer's exit code is the guard's"
printf '#!/usr/bin/env bash\nexit 7\n' >"$WORK/failing"
run "$BASE" bash "$WORK/failing"
assert_equals "exit 7" "$RC" "7"

echo "test: bad usage fails loud"
run "$BASE"
assert_equals "no command" "$RC" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
