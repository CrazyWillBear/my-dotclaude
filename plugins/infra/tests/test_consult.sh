#!/usr/bin/env bash
#
# Tests for scripts/consult.sh — the planner / consult one-shot (#104).
#
# Driven for REAL against a STUB `claude` (records its argv one per line and its cwd,
# prints canned text) and a STUB `gh` (records every call; answers `issue view` with a
# canned comment listing; copies the posted --body-file so its content is assertable).
# The stub formats are the declared central mock: what a real `claude -p` prints and
# what `gh issue view --json comments` returns. The REAL resolve-tier.sh picks the model.
#
# What matters and why:
#   * the call runs at the PLANNER cell's model/effort, never the implementer's — the
#     whole feature is "smart plan, cheap loop"
#   * it is read-only by denylist: a planner that edits is an implementer without a review
#   * the plan/consult heading is FIXED — escalate.sh counts `**Consult N**` on the thread,
#     and the worker's prompt names `**Plan**`; a drifted heading is invisible to both
#   * the consult number comes from the thread, so the cap reads the same fact
#   * empty output is never posted — an empty **Plan** reads as "no plan" to the worker
#
# Run: bash plugins/infra/tests/test_consult.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/consult.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }
assert_arg() { if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else no "$1 (no arg line '$3')"; fi; }
assert_empty() { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected empty, got '$2')"; fi; }

CFG="$WORK/cfg"; mkdir -p "$CFG"
cat >"$CFG/model-tiers.json" <<'JSON'
{
  "trivial":  { "planner": { "backend": "claude", "model": "haiku", "effort": "low" },
                "implementer": { "backend": "codex", "model": "gpt-5.6-luna", "effort": "max" },
                "reviewer": { "backend": "claude", "model": "opus", "effort": "low" } },
  "standard": { "planner": { "backend": "claude", "model": "opus", "effort": "medium" },
                "implementer": [ { "backend": "codex", "model": "gpt-5.6-luna", "effort": "xhigh" },
                                 { "backend": "claude", "model": "opus", "effort": "medium" } ],
                "reviewer": { "backend": "claude", "model": "opus", "effort": "medium" } },
  "complex":  { "planner": { "backend": "codex", "model": "gpt-5.6-sol", "effort": "high" },
                "implementer": { "backend": "claude", "model": "opus", "effort": "medium" },
                "reviewer": { "backend": "claude", "model": "opus", "effort": "high" } }
}
JSON
export RESOLVE_TIER_ROOT="$CFG"

BIN="$WORK/bin"; mkdir -p "$BIN"
cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${STUB_CLAUDE_ARGV:-/dev/null}"
pwd >"${STUB_CLAUDE_CWD:-/dev/null}"
printf '%s' "${STUB_CLAUDE_TEXT-1. Edit src/a.py: add f(x: int) -> int. Test first: tests/test_a.py.}"
exit "${STUB_CLAUDE_EXIT:-0}"
STUB
cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"${STUB_GH_ARGV:-/dev/null}"
if [ "${1:-}" = issue ] && [ "${2:-}" = view ]; then
    : "${STUB_GH_COMMENTS:='{"comments":[]}'}"
    printf '%s' "$STUB_GH_COMMENTS"
    exit 0
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = comment ]; then
    while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "${STUB_GH_BODY:-/dev/null}"; shift; done
fi
exit "${STUB_GH_EXIT:-0}"
STUB
chmod +x "$BIN/claude" "$BIN/gh"
export PATH="$BIN:$PATH"
WT="$WORK/wt"; mkdir -p "$WT"

run() { OUT="$(bash "$SCRIPT" "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }
reset() { rm -f "$WORK/argv" "$WORK/cwd" "$WORK/gh-argv" "$WORK/body"; }
export STUB_CLAUDE_ARGV="$WORK/argv" STUB_CLAUDE_CWD="$WORK/cwd" STUB_GH_ARGV="$WORK/gh-argv" STUB_GH_BODY="$WORK/body"

# ---------------------------------------------------------------------------
echo "test: plan is a claude -p call at the PLANNER cell, read-only, from the worktree"
reset
run plan r1 12 standard "$WT" --dry-run
assert_equals "exit 0" "$RC" "0"
assert_arg "claude" "$OUT" "claude"
assert_arg "one-shot print" "$OUT" "-p"
assert_arg "--model" "$OUT" "--model"
assert_arg "the planner cell's model (opus), not the implementer's (luna)" "$OUT" "opus"
assert_not_contains "never the implementer's model" "$OUT" "gpt-5.6-luna"
assert_arg "the planner cell's effort" "$OUT" "medium"
assert_arg "unattended: bypassPermissions" "$OUT" "bypassPermissions"
assert_arg "fenced to the worktree" "$OUT" "$WT"
for t in Edit Write NotebookEdit "Bash(git commit:*)" "Bash(git push:*)" "Bash(gh issue comment:*)" "Bash(gh issue close:*)" "Bash(gh pr:*)"; do
    assert_arg "denies $t" "$OUT" "$t"
done
assert_contains "the prompt reads the thread first" "$OUT" "gh issue view 12 --comments"
assert_contains "and the linked PRD" "$OUT" "Part of #M"
assert_contains "steps carry paths, signatures and tests" "$OUT" "function signature"
assert_contains "the done-check is quoted" "$OUT" "Done-check"
assert_contains "assumptions are listed — the deviation rule reads them" "$OUT" "Assumptions"
assert_contains "acceptance criteria heading verbatim" "$OUT" "## Acceptance criteria"
assert_contains "it posts nothing itself" "$OUT" "Post nothing yourself"
p=$(printf '%s\n' "$OUT" | grep -n "You are the PLANNER" | head -1 | cut -d: -f1)
d=$(printf '%s\n' "$OUT" | grep -nxF -- "--" | tail -1 | cut -d: -f1)
if [ -n "$p" ] && [ -n "$d" ] && [ "$p" -eq "$((d + 1))" ]; then ok "the prompt is fenced after --"; else no "prompt at $p is not right after -- at $d"; fi
assert_empty "a dry run posts nothing" "$(cat "$WORK/gh-argv" 2>/dev/null)"

echo "test: a real plan call posts ONE **Plan** comment with the model's text"
reset
run plan r1 12 standard "$WT"
assert_equals "exit 0" "$RC" "0"
assert_equals "says what it posted" "$OUT" "**Plan** posted on #12"
assert_equals "claude ran from the worktree" "$(cat "$WORK/cwd")" "$WT"
assert_contains "gh issue comment was called" "$(cat "$WORK/gh-argv")" "comment"
assert_contains "on the right issue" "$(cat "$WORK/gh-argv")" "12"
assert_contains "as a body file" "$(cat "$WORK/gh-argv")" "--body-file"
assert_equals "the heading is the fixed one, first line" "$(head -1 "$WORK/body")" "**Plan**"
assert_contains "and the plan text follows" "$(cat "$WORK/body")" "tests/test_a.py"
assert_equals "exactly one gh call — a plan reads no thread of its own" "$(grep -c '^issue$' "$WORK/gh-argv")" "1"

echo "test: consult numbers itself from the thread and posts **Consult N**"
reset
STUB_GH_COMMENTS='{"comments":[{"body":"**Plan**\n\n1. x"},{"body":"**Deviation**\n\nstep 2: f is not there"},{"body":"**Consult 1**\n\nDo y"},{"body":"**Review round 1** — 0 high, 0 medium, 0 low"},{"body":"**Deviation**\n\nstep 3"}]}' \
STUB_CLAUDE_TEXT='**Decision** — skip step 3.' run consult r1 12 standard "$WT"
assert_equals "exit 0" "$RC" "0"
assert_equals "the second consult" "$OUT" "**Consult 2** posted on #12"
assert_equals "heading first" "$(head -1 "$WORK/body")" "**Consult 2**"
assert_contains "decision text follows" "$(cat "$WORK/body")" "skip step 3"
assert_contains "the thread was read through gh issue view --json comments" "$(cat "$WORK/gh-argv")" "--json"
assert_contains "the prompt answers the NEWEST deviation" "$(cat "$WORK/argv")" "Deviation"
assert_contains "and may revise the steps" "$(cat "$WORK/argv")" "Revised steps"
reset
STUB_GH_COMMENTS='{"comments":[{"body":"**Plan**\n\n1. x"},{"body":"**Deviation**\n\nstep 2"}]}' \
    run consult r1 12 standard "$WT"
assert_equals "no consults yet -> Consult 1" "$OUT" "**Consult 1** posted on #12"
reset
STUB_GH_COMMENTS='{"comments":[{"body":"a comment mentioning **Consult 9** mid-line is not a heading"}]}' \
    run consult r1 12 standard "$WT"
assert_equals "only a heading at line start counts" "$OUT" "**Consult 1** posted on #12"

echo "test: empty output is NEVER posted"
reset
STUB_CLAUDE_TEXT='   ' run plan r1 12 standard "$WT"
assert_equals "exit 1" "$RC" "1"
assert_empty "nothing on stdout" "$OUT"
assert_contains "says why" "$ERR" "no text"
assert_empty "and no comment was posted" "$(cat "$WORK/gh-argv" 2>/dev/null)"
reset
STUB_CLAUDE_EXIT=2 run plan r1 12 standard "$WT"
assert_equals "a failed call exits 1" "$RC" "1"
assert_empty "and posts nothing" "$(cat "$WORK/gh-argv" 2>/dev/null)"
reset
STUB_GH_EXIT=1 run plan r1 12 standard "$WT"
assert_equals "a failed post exits 1" "$RC" "1"
assert_empty "with nothing on stdout" "$OUT"

echo "test: a codex-backed planner cell is refused — this is a claude -p call"
run plan r1 12 complex "$WT" --dry-run
assert_equals "exit 1" "$RC" "1"
assert_contains "names the backend" "$ERR" "codex"

echo "test: usage errors fail loud"
run bogus r1 12 standard "$WT"; assert_equals "bad role exits 1" "$RC" "1"
run plan r1 x standard "$WT"; assert_equals "bad issue exits 1" "$RC" "1"
run plan r1 12 standard "$WORK/nope"; assert_equals "missing worktree exits 1" "$RC" "1"
run plan "../x" 12 standard "$WT"; assert_equals "traversal runid exits 1" "$RC" "1"
run plan r1 12 standard "$WT" --bogus; assert_equals "unknown flag exits 1" "$RC" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
