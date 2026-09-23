#!/usr/bin/env bash
#
# Tests for scripts/merge-fold.sh — the deterministic merge fold.
#
# The fold is the model-free half of the merge stage: it folds each branch into
# the base in order, testing every step with `git merge-tree --write-tree` before
# it touches the working tree, and sets aside the ones that conflict. Only that
# remainder needs a merger agent, and its SIZE is the number that decides whether
# one merger session or two is cheaper.
#
# Covers:
#   * all-clean fold — every branch merged, remainder empty
#   * upstream checks — behind blocks by default, --allow-behind folds, current proceeds
#   * no upstream is reported once and the fold still proceeds
#   * a conflicting branch is set aside, and the CLEAN ones still land
#   * ORDER DEPENDENCE — a branch that is clean against the base but conflicts
#     once an earlier branch has landed is reported as a conflict. This is why
#     the fold is a fold and not a filter; a filter would merge both and corrupt.
#   * conflicting paths are named in the output
#   * an already-merged branch counts as merged (no-op, not an error)
#   * the base branch is left checked out and the merges are real commits
#   * unknown branch -> reported, does not abort the rest of the fold
#   * --preview <upstream-ref> — clean / conflict <paths> against the upstream, working tree untouched
#   * base-only launch check succeeds; usage errors exit non-zero
#
# Run: bash plugins/workflow/tests/test_merge-fold.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FOLD="$PLUGIN_ROOT/scripts/merge-fold.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
R="$WORK/repo"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in: $2)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }

g() { git -C "$R" "$@"; }

# A repo on `base` with f.txt (the shared collision file) and a seed commit.
init_repo() {
    rm -rf "$R"; mkdir -p "$R"
    g init -q -b base
    g config user.email t@t.com
    g config user.name t
    printf 'a\nb\nc\n' >"$R/f.txt"
    g add -A; g commit -qm seed
}

# branch <name> <file> <content> — cut from base, one commit, back to base.
branch() {
    g checkout -q -b "$1" base
    printf '%s\n' "$3" >"$R/$2"
    g add -A; g commit -qm "$1"
    g checkout -q base
}

# add_origin <n> — attach a bare origin to R, then advance it by n commits
# from a separate clone. R deliberately does not fetch; merge-fold owns that.
add_origin() {
    local n="$1" i
    rm -rf "$WORK/origin.git" "$WORK/other"
    git init -q --bare "$WORK/origin.git"
    g remote add origin "$WORK/origin.git"
    g push -q -u origin base
    git clone -q -b base "$WORK/origin.git" "$WORK/other"
    git -C "$WORK/other" config user.email t@t.com
    git -C "$WORK/other" config user.name t
    for ((i = 1; i <= n; i++)); do
        printf 'upstream %d\n' "$i" >"$WORK/other/up${i}.txt"
        git -C "$WORK/other" add -A
        git -C "$WORK/other" commit -qm "upstream $i"
    done
    git -C "$WORK/other" push -q origin base
}

run_fold() { (cd "$R" && bash "$FOLD" "$@" 2>&1); }

# ---------------------------------------------------------------------------
echo "test: all-clean fold merges every branch and leaves an empty remainder"
init_repo
branch t1 one.txt ONE
branch t2 two.txt TWO
branch t3 three.txt THREE
out=$(run_fold base t1 t2 t3)
assert_contains "t1 merged" "$out" "merged t1"
assert_contains "t2 merged" "$out" "merged t2"
assert_contains "t3 merged" "$out" "merged t3"
assert_contains "summary reports 3 merged, 0 conflicted" "$out" "summary merged=3 conflicted=0"
assert_not_contains "no conflict lines" "$out" "conflict "
assert_equals "still on base" "$(g rev-parse --abbrev-ref HEAD)" "base"
assert_equals "one.txt landed" "$(cat "$R/one.txt")" "ONE"
assert_equals "three.txt landed" "$(cat "$R/three.txt")" "THREE"

# ---------------------------------------------------------------------------
echo "test: a conflicting branch is set aside while the clean ones still land"
init_repo
branch c1 one.txt ONE
g checkout -q -b c2 base; printf 'a\nb\nZZZ\n' >"$R/f.txt"; g add -A; g commit -qm c2; g checkout -q base
g checkout -q -b c3 base; printf 'a\nb\nYYY\n' >"$R/f.txt"; g add -A; g commit -qm c3; g checkout -q base
out=$(run_fold base c1 c2 c3)
assert_contains "c1 merged" "$out" "merged c1"
assert_contains "c2 merged (first writer wins)" "$out" "merged c2"
assert_contains "c3 set aside" "$out" "conflict c3"
assert_contains "summary reports the remainder" "$out" "summary merged=2 conflicted=1"
assert_equals "the clean branch still landed" "$(cat "$R/one.txt")" "ONE"
assert_equals "the conflicted branch did NOT land" "$(sed -n 3p "$R/f.txt")" "ZZZ"

# ---------------------------------------------------------------------------
echo "test: ORDER DEPENDENCE — clean against base, conflicting after an earlier merge"
init_repo
# Both touch line 3. Each is individually clean against base; the second is not
# clean once the first has landed. A filter would merge both; a fold must not.
g checkout -q -b o1 base; printf 'a\nb\nFIRST\n' >"$R/f.txt"; g add -A; g commit -qm o1; g checkout -q base
g checkout -q -b o2 base; printf 'a\nb\nSECOND\n' >"$R/f.txt"; g add -A; g commit -qm o2; g checkout -q base
# proof of the premise: o2 IS clean against the untouched base
if (cd "$R" && git merge-tree --write-tree base o2 >/dev/null 2>&1); then
    ok "premise: o2 is clean against base alone"
else
    no "premise: o2 should be clean against base alone"
fi
out=$(run_fold base o1 o2)
assert_contains "o1 merged" "$out" "merged o1"
assert_contains "o2 conflicts once o1 has landed" "$out" "conflict o2"
assert_contains "names the conflicting path" "$out" "f.txt"
assert_equals "base holds o1's content, not a corrupt blend" "$(sed -n 3p "$R/f.txt")" "FIRST"

# ---------------------------------------------------------------------------
echo "test: an already-merged branch counts as merged, not an error"
init_repo
branch a1 one.txt ONE
out=$(run_fold base a1)
assert_contains "first fold merges it" "$out" "merged a1"
out=$(run_fold base a1)
assert_contains "second fold is a no-op merge" "$out" "merged a1"
assert_contains "summary counts it as merged" "$out" "summary merged=1 conflicted=0"

# ---------------------------------------------------------------------------
echo "test: an unknown branch is reported and does not abort the fold"
init_repo
branch u1 one.txt ONE
branch u2 two.txt TWO
out=$(run_fold base u1 nope-does-not-exist u2)
assert_contains "unknown branch reported" "$out" "unknown nope-does-not-exist"
assert_contains "the fold continued to u2" "$out" "merged u2"
assert_equals "u2 landed despite the bad ref" "$(cat "$R/two.txt")" "TWO"

# ---------------------------------------------------------------------------
echo "test: origin ahead refuses, names the count, and folds nothing"
init_repo
branch t1 one.txt ONE
add_origin 2
out=$(run_fold base t1); rc=$?
assert_equals "behind base exits 2" "$rc" "2"
assert_contains "behind count and upstream reported" "$out" "behind base 2 origin/base"
assert_contains "override is suggested" "$out" "--allow-behind"
assert_not_contains "behind branch was not merged" "$out" "merged t1"
assert_not_contains "behind fold has no summary" "$out" "summary"
if [ ! -e "$R/one.txt" ]; then ok "behind branch left the base unchanged"; else no "behind branch left the base unchanged"; fi

# ---------------------------------------------------------------------------
echo "test: --allow-behind folds normally"
init_repo
branch t1 one.txt ONE
add_origin 2
out=$(run_fold --allow-behind base t1); rc=$?
assert_equals "override exits 0" "$rc" "0"
assert_contains "override merges t1" "$out" "merged t1"
assert_contains "override reports success" "$out" "summary merged=1 conflicted=0"
assert_equals "override lands one.txt" "$(cat "$R/one.txt")" "ONE"

# ---------------------------------------------------------------------------
echo "test: an up-to-date origin folds normally"
init_repo
branch t1 one.txt ONE
add_origin 0
out=$(run_fold base t1); rc=$?
assert_equals "up-to-date fold exits 0" "$rc" "0"
assert_contains "up-to-date fold merges t1" "$out" "merged t1"
assert_not_contains "up-to-date fold has no behind line" "$out" "behind"

# ---------------------------------------------------------------------------
echo "test: no upstream is reported once and branches still fold"
init_repo
branch u1 one.txt ONE
branch u2 two.txt TWO
out=$(run_fold base u1 u2); rc=$?
assert_equals "no-upstream fold exits 0" "$rc" "0"
assert_equals "one no-upstream line" "$(printf '%s\n' "$out" | grep -c '^upstream none base$')" "1"
assert_contains "no-upstream fold reports success" "$out" "summary merged=2 conflicted=0"

# ---------------------------------------------------------------------------
echo "test: --preview reports a conflict without changing the working tree"
init_repo
add_origin 0
(cd "$WORK/other" && git pull -q)
printf 'a\nb\nUPSTREAM\n' >"$WORK/other/f.txt"
git -C "$WORK/other" add -A; git -C "$WORK/other" commit -qm upstream
git -C "$WORK/other" push -q origin base
printf 'a\nb\nLOCAL\n' >"$R/f.txt"
g add -A; g commit -qm local
head_before=$(g rev-parse HEAD)
out=$(run_fold --preview origin/base); rc=$?
assert_equals "conflict preview exits 0" "$rc" "0"
assert_contains "conflict preview names f.txt" "$out" "conflict f.txt"
assert_equals "conflict preview leaves the index clean" "$(g status --porcelain)" ""
assert_equals "conflict preview leaves HEAD unchanged" "$(g rev-parse HEAD)" "$head_before"
assert_equals "conflict preview leaves the local file untouched" "$(sed -n 3p "$R/f.txt")" "LOCAL"
assert_not_contains "conflict preview has no summary" "$out" "summary"

# ---------------------------------------------------------------------------
echo "test: --preview reports exactly clean and leaves upstream files out of the working tree"
init_repo
add_origin 1
branch t1 one.txt ONE
g merge -q --no-ff --no-edit t1
out=$(run_fold --preview origin/base); rc=$?
assert_equals "clean preview exits 0" "$rc" "0"
assert_equals "clean preview prints exactly clean" "$out" "clean"
assert_equals "clean preview leaves the index clean" "$(g status --porcelain)" ""
if [ ! -e "$R/up1.txt" ]; then ok "clean preview leaves upstream files out of the working tree"; else no "clean preview leaves upstream files out of the working tree"; fi

# ---------------------------------------------------------------------------
echo "test: usage errors exit non-zero"
init_repo
if (cd "$R" && bash "$FOLD" >/dev/null 2>&1); then no "no args should exit non-zero"; else ok "no args exits non-zero"; fi
if (cd "$R" && bash "$FOLD" base >/dev/null 2>&1); then ok "base only runs the check and exits 0"; else no "base only runs the check and exits 0"; fi
if (cd "$R" && bash "$FOLD" --allow-behind >/dev/null 2>&1); then no "allow-behind without a base exits non-zero"; else ok "allow-behind without a base exits non-zero"; fi
if (cd "$R" && bash "$FOLD" --preview >/dev/null 2>&1); then no "preview without a ref exits non-zero"; else ok "preview without a ref exits non-zero"; fi
if (cd "$R" && bash "$FOLD" --preview no-such/ref >/dev/null 2>&1); then no "preview with an unknown ref exits non-zero"; else ok "preview with an unknown ref exits non-zero"; fi
if (cd "$WORK" && bash "$FOLD" base t1 >/dev/null 2>&1); then no "outside a repo should exit non-zero"; else ok "outside a repo exits non-zero"; fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
