#!/usr/bin/env bash
#
# Tests for scripts/review-cmd.sh — the INDEPENDENT reviewer's argv, built in ONE place
# for both callers (spawn.sh and worker-resume.sh).
#
# WHY THIS SCRIPT IS WORTH ITS OWN TEST. #96's e2e gate caught a codex worker reviewing
# its own diff: the `codex exec review` it was told to run could never start inside its own
# sandbox, so it substituted its own judgement and reported a clean independent review that
# had never happened. The reviewer is now a sibling process, and the two things that make
# that trustworthy are both decided here — WHICH MODEL reviews (the tier's reviewer cell,
# not the implementer's), and the COUNTS line that makes the verdict machine-readable
# instead of prose someone has to interpret.
#
# THE CENTRAL MECHANISM is that every argument stays SINGLE-LINE. The output is one
# argument per line and the callers read it back that way, so a newline smuggled into the
# prompt would split one argument into two and hand codex a truncated prompt with the rest
# as a stray positional. That is asserted directly rather than assumed.
#
# Run: bash plugins/infra/tests/test_review-cmd.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/review-cmd.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in '$2')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (found '$3')" ;; *) ok "$1" ;; esac; }
# Pinned by VALUE, not substring: a model name that appeared only as part of a longer
# argument would pass a substring check while never reaching codex as the -m value.
assert_arg() {
    if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"
    else no "$1 (no argv line exactly '$3')"; fi
}

# A codex-backed roster. The SHIPPED table is deliberately all-claude, so the codex cells
# have to be supplied here.
CFG="$WORK/cfg"
mkdir -p "$CFG"
cat >"$CFG/model-tiers.json" <<'JSON'
{
  "trivial":  { "planner": { "backend": "claude", "model": "haiku", "effort": "medium" },
                "implementer": { "backend": "codex", "model": "gpt-5.6-luna", "effort": "max" },
                "reviewer": { "backend": "codex", "model": "gpt-5.6-terra", "effort": "high" } },
  "standard": { "planner": { "backend": "claude", "model": "sonnet", "effort": "high" },
                "implementer": { "backend": "codex", "model": "gpt-5.6-terra", "effort": "max" },
                "reviewer": { "backend": "codex", "model": "gpt-5.6-sol", "effort": "high" } },
  "complex":  { "planner": { "backend": "claude", "model": "opus", "effort": "xhigh" },
                "implementer": { "backend": "claude", "model": "opus", "effort": "high" },
                "reviewer": { "backend": "claude", "model": "opus", "effort": "xhigh" } }
}
JSON
export RESOLVE_TIER_ROOT="$CFG"

run() {
    local errf="$WORK/err"
    OUT="$(bash "$SCRIPT" "$@" 2>"$errf")"
    RC=$?
    ERR="$(cat "$errf")"
}

# ---------------------------------------------------------------------------
echo "test: it builds a codex exec review against the base branch"
run standard /tmp/wt main
assert_equals "exit 0" "$RC" "0"
assert_arg "codex"        "$OUT" "codex"
assert_arg "exec"         "$OUT" "exec"
assert_arg "review"       "$OUT" "review"
assert_arg "--base"       "$OUT" "--base"
assert_arg "the base branch by value" "$OUT" "main"
assert_arg "-C the worktree"          "$OUT" "/tmp/wt"
assert_arg "no approval prompts"      "$OUT" "approval_policy=never"
# Without the network the reviewer cannot reach the model at all, and workspace-write is
# OFFLINE by default — the same silent-and-fatal loss the worker's own spawn guards.
assert_arg "the network, whose loss is silent and fatal" "$OUT" \
    "sandbox_workspace_write.network_access=true"

echo "test: it reviews at the tier's REVIEWER model, never the implementer's"
# THE POINT OF THE REVIEWER COLUMN. standard's implementer is terra and its reviewer is
# sol here, precisely so a builder that echoed the implementer's model would be caught.
assert_arg "-m" "$OUT" "-m"
assert_arg "the reviewer's model" "$OUT" "gpt-5.6-sol"
assert_not_contains "and not the implementer's" "$OUT" "gpt-5.6-terra"

run trivial /tmp/wt main
assert_arg "trivial reviews at ITS reviewer cell" "$OUT" "gpt-5.6-terra"
assert_not_contains "not its luna implementer" "$OUT" "gpt-5.6-luna"

echo "test: a CLAUDE reviewer cell leaves -m off — codex has no opus to review with"
# Every cell of the SHIPPED table is claude, so a user who flips only the implementer to
# codex lands here. Passing opus would make the review die on a model codex does not have,
# leaving no review.txt — which worker-report.sh refuses, turning a wrong-model review
# into a run that cannot land at all.
run complex /tmp/wt main
assert_equals "exit 0 — it still builds a reviewer" "$RC" "0"
assert_arg "still a review" "$OUT" "review"
assert_not_contains "but never hands codex a claude model" "$OUT" "opus"
assert_not_contains "and no -m at all" "$OUT" "-m"

echo "test: the prompt pins the COUNTS line worker-report.sh reads"
# worker-report.sh parses ONLY that line. Without it the reviewer writes prose, no verdict
# is found, and every run fails closed — loudly, but every single time. These two strings
# and that regex are one contract.
run standard /tmp/wt main
assert_contains "the exact format" "$OUT" "COUNTS: <H> high, <M> medium, <L> low"
assert_contains "including the nothing-found case" "$OUT" "COUNTS: 0 high, 0 medium, 0 low"
assert_contains "and says it must be last" "$OUT" "LAST line"

echo "test: EVERY argument is single-line — the callers read one argument per line"
# The whole encoding rests on this. A newline anywhere in the prompt would silently split
# one argument into two, and codex would get a truncated prompt plus a stray positional.
run standard /tmp/wt main
NLINES="$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
# codex, exec, review, -C, <wt>, --base, <b>, -c, <k=v>, -c, <k=v>, -m, <model>, <prompt>
assert_equals "the argument count is exactly what was built" "$NLINES" "14"
assert_equals "the prompt is the LAST argument" \
    "$(printf '%s\n' "$OUT" | tail -1 | cut -c1-6)" "Review"

echo "test: usage errors fail loudly, with nothing on stdout to misread as a command"
run
assert_equals "no args exits 1" "$RC" "1"
assert_equals "nothing on stdout" "$OUT" ""
assert_contains "usage" "$ERR" "usage"
run standard /tmp/wt
assert_equals "a missing base exits 1" "$RC" "1"
assert_equals "nothing on stdout" "$OUT" ""

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
