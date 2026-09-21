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
# not the implementer's), and WHAT IT DIFFS AGAINST (a base pinned to a SHA before the
# worker ran, since a base named by branch could be moved by the worker itself).
#
# What it deliberately does NOT do is ask for a machine-readable verdict: a review turn
# takes no prompt beside --base and ignores --output-schema. review-counts.sh parses
# codex's own review template instead, and test_review-counts.sh pins that against real
# captured output.
#
# THE CENTRAL MECHANISM is that this argv actually parses. The first version of this fix
# shipped a command the installed CLI rejects outright — `-C` is not a flag of
# `codex exec review`, and `--base` cannot be combined with a trailing PROMPT — so the
# reviewer died on every run and every codex build failed closed. A stub cannot catch that,
# which is why the shape is pinned here against what was verified on codex-cli 0.155.0.
# Every argument also stays SINGLE-LINE: the callers read the output back one argument per
# line, so a newline would split one into two and hand codex a stray positional.
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
# Every case passes a SHA: review-cmd.sh refuses anything that is not one, because a base
# resolved by NAME could be moved by the worker (refs/ is a granted writable root),
# emptying its own diff and buying a clean verdict from an honest reviewer.
SHA=0123456789abcdef0123456789abcdef01234567
OUTF=/tmp/rundir/review.txt
# NOT created on disk — review-cmd.sh is a pure argv builder and must not require the
# scratch dir to exist yet (a dry run builds this before anything is created on disk).
SCRATCH=/tmp/rundir/review-scratch

echo "test: it builds a codex exec review against the base COMMIT"
run standard "$SHA" "$OUTF" "$SCRATCH"
assert_equals "exit 0" "$RC" "0"
assert_arg "codex"   "$OUT" "codex"
assert_arg "exec"    "$OUT" "exec"
assert_arg "review"  "$OUT" "review"
assert_arg "--base"  "$OUT" "--base"
assert_arg "the base by value, as a sha" "$OUT" "$SHA"
assert_arg "no approval prompts"         "$OUT" "approval_policy=never"

echo "test: -C is NEVER passed — codex exec review does not take it"
# Verified against codex-cli 0.155.0: `-C` there dies with "unexpected argument '-C'
# found". It is a top-level `codex exec` flag only. Both callers cd into a DISPOSABLE
# clone instead (#99), which is what scopes the review without making the worktree itself
# writable — see the sandbox test below.
assert_not_contains "no -C" "$(printf '%s\n' "$OUT" | grep -Fx -- '-C')" "-C"

echo "test: NO trailing prompt, and NO --output-schema either"
# Verified on 0.155.0: "the argument '--base <BRANCH>' cannot be used with '[PROMPT]'",
# so the verdict's shape cannot be requested in prose. --output-schema was the obvious
# substitute and it DOES NOT WORK — codex accepts it on a review turn and ignores it
# (proven twice: a real ops-os run returned prose where the schema was required, and a
# direct probe returned prose again with --json showing no structured findings event).
# Passing a flag that silently does nothing is worse than not passing it: it reads as a
# guarantee that is not there. review-counts.sh parses the review's own template instead.
assert_arg "a file for the verdict" "$OUT" "-o"
assert_arg "the out file"           "$OUT" "$OUTF"
assert_not_contains "no schema, because it would be silently ignored" "$OUT" "--output-schema"
assert_not_contains "nothing that looks like a prose instruction" "$OUT" "print exactly"

echo "test: the sandbox is PINNED workspace-write with a NARROWED scratch root, not inherited"
# `exec review` takes no -s, so without this the reviewer runs at whatever
# ~/.codex/config.toml defaults to. A user configured with danger-full-access would have a
# model reading worker-authored, injectable content run on the HOST with approvals off.
#
# It is workspace-write, not read-only (#99) — read-only blocked a test runner from ever
# creating a tempfile, so the done-check could never actually execute. But workspace-write
# grants `writable_roots` IN ADDITION TO wherever it runs from, with no key to subtract
# that — ground-truthed on codex-cli 0.155.1, see review-cmd.sh — so the callers never run
# this FROM the worktree; they run it from a disposable clone instead, and only this
# SCRATCH dir needs to be writable inside it.
assert_arg "no longer read-only" "$OUT" "sandbox_mode=workspace-write"
assert_not_contains "and never read-only" "$OUT" "sandbox_mode=read-only"
assert_arg "the ONE scratch root is granted" "$OUT" \
    "sandbox_workspace_write.writable_roots=[\"$SCRATCH\"]"
# The blanket /tmp and $TMPDIR grants workspace-write hands out BY DEFAULT are excluded —
# narrower than relying on them, and made safe only because the caller also runs this argv
# with TMPDIR set to the one scratch root above (spawn.sh / worker-resume.sh).
assert_arg "the default /tmp grant is excluded" "$OUT" \
    "sandbox_workspace_write.exclude_slash_tmp=true"
assert_arg "the default \$TMPDIR grant is excluded" "$OUT" \
    "sandbox_workspace_write.exclude_tmpdir_env_var=true"

echo "test: it reviews at the tier's REVIEWER model, never the implementer's"
# THE POINT OF THE REVIEWER COLUMN. standard's implementer is terra and its reviewer sol
# here, precisely so a builder that echoed the implementer's model would be caught.
assert_arg "-m"                    "$OUT" "-m"
assert_arg "the reviewer's model"  "$OUT" "gpt-5.6-sol"
assert_not_contains "and not the implementer's" "$OUT" "gpt-5.6-terra"

run trivial "$SHA" "$OUTF" "$SCRATCH"
assert_arg "trivial reviews at ITS reviewer cell" "$OUT" "gpt-5.6-terra"
assert_not_contains "not its luna implementer"    "$OUT" "gpt-5.6-luna"

echo "test: a CLAUDE reviewer cell leaves -m off — codex has no opus to review with"
# Every cell of the SHIPPED table is claude, so a user who flips only the implementer to
# codex lands here. Passing opus would make the review die on a model codex does not have,
# leaving no review.json — which worker-report.sh refuses, turning a wrong-model review
# into a run that cannot land at all.
run complex "$SHA" "$OUTF" "$SCRATCH"
assert_equals "exit 0 — it still builds a reviewer" "$RC" "0"
assert_arg "still a review" "$OUT" "review"
assert_not_contains "but never hands codex a claude model" "$OUT" "opus"
assert_not_contains "and no -m at all" "$(printf '%s\n' "$OUT" | grep -Fx -- '-m')" "-m"

echo "test: a BRANCH NAME is refused — only a resolved sha closes the movable-base hole"
# The whole point of pinning. If this accepted "main", a worker could `git branch -f main
# HEAD` and the reviewer would diff nothing.
run standard main "$OUTF" "$SCRATCH"
assert_equals "exits 1" "$RC" "1"
assert_equals "nothing on stdout" "$OUT" ""
assert_contains "says it wants a sha" "$ERR" "resolved SHA"

run standard abc123 "$OUTF" "$SCRATCH"
assert_equals "a too-short sha is refused too" "$RC" "1"
assert_contains "says why" "$ERR" "too short"

echo "test: EVERY argument is single-line — the callers read one argument per line"
# The whole encoding rests on this. A newline anywhere would silently split one argument
# into two, and codex would get a stray positional.
run standard "$SHA" "$OUTF" "$SCRATCH"
NLINES="$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
# codex, exec, review, --base, <sha>, -c, <k=v>, -c, <k=v>, -c, <k=v>, -c, <k=v>,
# -o, <file>, -m, <model>
assert_equals "the argument count is exactly what was built" "$NLINES" "19"

echo "test: a relative scratch dir is refused"
# Spliced verbatim into a TOML array value — a relative path would resolve against
# whatever codex treats as cwd rather than what the caller meant.
run standard "$SHA" "$OUTF" "relative/scratch"
assert_equals "exits 1" "$RC" "1"
assert_equals "nothing on stdout" "$OUT" ""
assert_contains "says why" "$ERR" "absolute path"

echo "test: usage errors fail loudly, with nothing on stdout to misread as a command"
run
assert_equals "no args exits 1" "$RC" "1"
assert_equals "nothing on stdout" "$OUT" ""
assert_contains "usage" "$ERR" "usage"
run standard "$SHA"
assert_equals "a missing out file exits 1" "$RC" "1"
assert_equals "nothing on stdout" "$OUT" ""

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
