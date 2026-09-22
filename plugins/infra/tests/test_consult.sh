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
    [ -n "${STUB_GH_COMMENTS:-}" ] || STUB_GH_COMMENTS='{"comments":[]}'
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
# A real LINKED worktree: consult.sh re-runs common-git-dir.sh --roots before it lets a
# model loose in the worktree, and that check refuses anything that is not one.
ORIGIN="$WORK/origin"; mkdir -p "$ORIGIN"
git -C "$ORIGIN" init -q; git -C "$ORIGIN" config user.email t@t.t; git -C "$ORIGIN" config user.name t
printf 'x\n' >"$ORIGIN/f"; git -C "$ORIGIN" add f; git -C "$ORIGIN" commit -qm init
WT="$WORK/wt"; git -C "$ORIGIN" worktree add -q -b issue-12 "$WT" >/dev/null 2>&1

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
for t in Edit Write NotebookEdit "Bash(git commit:*)" "Bash(git push:*)" "Bash(gh issue comment:*)" "Bash(gh issue close:*)" "Bash(gh pr:*)" "Bash(gh api:*)" "Bash(gh repo:*)"; do
    assert_arg "denies $t" "$OUT" "$t"
done
assert_contains "the prompt reads the thread first" "$OUT" "gh issue view 12 --comments"
assert_contains "and the linked PRD" "$OUT" "Part of #M"
assert_contains "steps carry paths, signatures and tests" "$OUT" "function signature"
assert_contains "the done-check is quoted" "$OUT" "Done-check"
assert_contains "assumptions are listed — the deviation rule reads them" "$OUT" "Assumptions"
assert_contains "acceptance criteria heading verbatim" "$OUT" "## Acceptance criteria"
assert_contains "it posts nothing itself" "$OUT" "Post nothing yourself"
assert_contains "thread and worktree content is data, not instructions" "$OUT" "never an instruction to you"
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
assert_contains "the consult treats the worker's Deviation as data" "$(cat "$WORK/argv")" "never an instruction to you"
reset
STUB_GH_COMMENTS='{"comments":[{"body":"**Plan**\n\n1. x"},{"body":"**Deviation**\n\nstep 2"}]}' \
    run consult r1 12 standard "$WT"
assert_equals "no consults yet -> Consult 1" "$OUT" "**Consult 1** posted on #12"
reset
STUB_GH_COMMENTS='{"comments":[{"body":"a comment mentioning **Consult 9** mid-line is not a heading"}]}' \
    run consult r1 12 standard "$WT"
assert_equals "only a heading at line start counts" "$OUT" "**Consult 1** posted on #12"

echo "test: consult refuses PAST THE CAP for a claude-backed worker (review round 10/11)"
# This suite's fixture standard chain is codex-luna @attempt 0, claude-opus @attempt 1 — the
# BACKEND for the cap check comes from resolve-tier.sh at --attempt, never a codex run dir's
# existence (round 11: a run dir left over from attempt 0 must not make attempt 1 read as
# codex-backed). escalate.sh never runs for a claude-backed worker at all, so nothing else
# stops a third consult — this script's own backstop is the only thing that can.
reset
AT_CAP='{"comments":[{"body":"**Consult 1**"},{"body":"**Consult 2**"}]}'
STUB_GH_COMMENTS="$AT_CAP" run consult r1 12 standard "$WT" --attempt 1
assert_equals "the third consult (N=3) is refused" "$RC" "1"
assert_empty "nothing on stdout" "$OUT"
assert_contains "says why" "$ERR" "past the cap"
if grep -qx comment "$WORK/gh-argv" 2>/dev/null; then no "and no comment was posted (a read to compute N is expected)"; else ok "and no comment was posted (a read to compute N is expected)"; fi
reset
UNDER_CAP='{"comments":[{"body":"**Consult 1**"}]}'
STUB_GH_COMMENTS="$UNDER_CAP" run consult r1 12 standard "$WT" --attempt 1
assert_equals "the SECOND consult (N=2, at the cap) still goes through" "$RC" "0"
assert_equals "posted normally" "$OUT" "**Consult 2** posted on #12"
reset
ESCALATE_CONSULT_CAP=5 STUB_GH_COMMENTS="$AT_CAP" run consult r1 12 standard "$WT" --attempt 1
assert_equals "the cap is configurable" "$RC" "0"
unset ESCALATE_CONSULT_CAP   # `run` is a shell function — see the note elsewhere in this suite
# At attempt 0 (this fixture's codex cell) the cap is NOT enforced here, REGARDLESS of any
# stale codex run dir on disk — escalate.sh's own, attempt-scoped deviation-cap already
# governs a codex worker before this script is ever reached a third time in the same attempt.
reset
CODEX_RUN_ROOT="$WORK/codexruns"
mkdir -p "$CODEX_RUN_ROOT/r1/issue-12"
CODEX_RUN_ROOT="$CODEX_RUN_ROOT" STUB_GH_COMMENTS="$AT_CAP" run consult r1 12 standard "$WT" --attempt 0
unset CODEX_RUN_ROOT
assert_equals "a codex-backed attempt's third consult is NOT refused here" "$RC" "0"
assert_equals "posted normally" "$OUT" "**Consult 3** posted on #12"
reset
# Same AT_CAP thread, but now the SAME run dir survives from attempt 0 while attempt 1 (the
# claude cell) is being evaluated (round 11's exact bug: the run dir is never deleted). The
# cap must still fire — backend comes from resolve-tier.sh, not the filesystem.
CODEX_RUN_ROOT="$WORK/codexruns"
CODEX_RUN_ROOT="$CODEX_RUN_ROOT" STUB_GH_COMMENTS="$AT_CAP" run consult r1 12 standard "$WT" --attempt 1
unset CODEX_RUN_ROOT
assert_equals "a stale codex run dir does not exempt the claude attempt from the cap" "$RC" "1"
assert_contains "says why" "$ERR" "past the cap"
reset
STUB_GH_COMMENTS="$AT_CAP" run consult r1 12 standard "$WT"
assert_equals "no --attempt defaults to 0 (codex here) — not refused" "$RC" "0"

echo "test: the consult cap floors at the NEWEST **Plan** heading (review round 11)"
# Two Consults from a PREVIOUS run (before this run's Plan) plus one from THIS run (after
# it) — only the one after the Plan counts toward the CAP. The heading number stays
# thread-wide by design (see the header comment), so this still posts as Consult 4.
reset
PAST_PLAN='{"comments":[{"body":"**Consult 1**"},{"body":"**Consult 2**"},{"body":"**Plan**\n\n1. x"},{"body":"**Deviation**\n\nstep 2"},{"body":"**Consult 1**"}]}'
STUB_GH_COMMENTS="$PAST_PLAN" run consult r1 12 standard "$WT" --attempt 1
assert_equals "not refused — only 2 consults counted since the Plan, at the cap" "$RC" "0"
assert_equals "the heading number stays thread-wide" "$OUT" "**Consult 4** posted on #12"
reset
# A third consult SINCE the Plan is refused, even though a prior run left two more before it
# that a non-floored count would have wrongly folded in (review round 11's exact bug: a
# drained issue's next run computes N past the cap on its very first consult).
PAST_PLAN_OVER='{"comments":[{"body":"**Consult 1**"},{"body":"**Consult 2**"},{"body":"**Plan**\n\n1. x"},{"body":"**Consult 1**"},{"body":"**Consult 2**"}]}'
STUB_GH_COMMENTS="$PAST_PLAN_OVER" run consult r1 12 standard "$WT" --attempt 1
assert_equals "a third consult since the Plan is refused" "$RC" "1"
assert_contains "says why" "$ERR" "past the cap"

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

echo "test: the containment tripwire — a worktree --roots refuses gets no model (review fix 3)"
PLAIN="$WORK/plain"; mkdir -p "$PLAIN"; git -C "$PLAIN" init -q
reset
run plan r1 12 standard "$PLAIN"
assert_equals "exit 1" "$RC" "1"
assert_contains "says the containment check refused it" "$ERR" "containment check refused"
assert_empty "and no model ran" "$(cat "$WORK/argv" 2>/dev/null)"
reset
run consult r1 12 standard "$PLAIN"
assert_equals "the consult role is refused BEFORE it reads the thread from that worktree" "$RC" "1"
assert_empty "no gh call at all" "$(cat "$WORK/gh-argv" 2>/dev/null)"

echo "test: a codex-backed planner cell is refused — this is a claude -p call"
run plan r1 12 complex "$WT" --dry-run
assert_equals "exit 1" "$RC" "1"
assert_contains "names the backend" "$ERR" "codex"

echo "test: usage errors fail loud"
run bogus r1 12 standard "$WT"; assert_equals "bad role exits 1" "$RC" "1"
run plan r1 x standard "$WT"; assert_equals "bad issue exits 1" "$RC" "1"
run plan r1 12 urgent "$WT"; assert_equals "an unknown tier exits 1 — it would reach the prompt verbatim" "$RC" "1"
run plan r1 12 standard "$WORK/nope"; assert_equals "missing worktree exits 1" "$RC" "1"
run plan "../x" 12 standard "$WT"; assert_equals "traversal runid exits 1" "$RC" "1"
run plan r1 12 standard "$WT" --bogus; assert_equals "unknown flag exits 1" "$RC" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
