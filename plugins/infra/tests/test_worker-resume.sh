#!/usr/bin/env bash
#
# Tests for scripts/worker-resume.sh — answering a codex worker's escalation by resuming
# its thread (#96).
#
# Driven for REAL: real run dirs in spawn.sh's layout, a real git worktree for the
# writable-roots resolution, the REAL resolve-tier.sh, the REAL worker-report.sh doing the
# rendering, and a STUB `codex` that records its argv one line per argument plus the cwd
# it was launched from.
#
# THE CENTRAL MECHANISM is the flag set. `codex exec resume` inherits NONE of the sandbox
# and accepts neither -s nor -C, and an unknown `-c` key is swallowed silently — so a
# resume that quietly loses `network_access` produces an OFFLINE worker that fails its own
# gh protocol and looks like it merely finished badly. There is no runtime signal for
# that, which is exactly why it is pinned here by ARGV rather than by outcome.
#
# Run: bash plugins/infra/tests/test_worker-resume.sh   (non-zero if any fail)

set -u
unset DATABASE_URL FOO

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/worker-resume.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CODEX_ROOT="$WORK/codexruns"
export CODEX_RUN_ROOT="$CODEX_ROOT"

BIN="$WORK/bin"
mkdir -p "$BIN"

# `claude` plays two parts: session-status.sh (via worker-report.sh) lists agents with it
# (none in these fixtures), and it IS the independent reviewer (`claude -p`, #104) — which
# records its argv, cwd and TMPDIR (#99) and prints its verdict to stdout.
cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = agents ]; then echo "[]"; exit 0; fi
if [ "${1:-}" = -p ]; then
    [ -n "${STUB_HOST_ENV_OUT:-}" ] && printf '%s|%s\n' "${DATABASE_URL:-}" "${FOO:-}" >"$STUB_HOST_ENV_OUT"
    printf '%s\n' "$@" >"${STUB_REVIEW_ARGV:-/dev/null}"
printf '%s\n' "$#" >"${STUB_REVIEW_ARGC:-/dev/null}"
    pwd >"${STUB_REVIEW_CWD:-/dev/null}"
    [ -e ../reviewing ] && printf 'yes\n' >"${STUB_REVIEW_MARKER:-/dev/null}"
    printenv TMPDIR >"${STUB_REVIEW_TMPDIR:-/dev/null}" 2>/dev/null || true
    rj="${STUB_REVIEW_TEXT:-}"
    [ -n "$rj" ] || rj='- [P2] a finding — src/f:1'
    printf '%s\n' "$rj"
    exit "${STUB_REVIEW_EXIT:-0}"
fi
exit 0
STUB
chmod +x "$BIN/claude"
PATH="$BIN:$PATH"
export PATH

# A tier table that actually routes to codex. The SHIPPED table is deliberately all
# claude (the flip is held), so a codex-backed roster has to be supplied here.
CFG="$WORK/cfg"
mkdir -p "$CFG"
cat >"$CFG/model-tiers.json" <<'JSON'
{
  "trivial":  { "planner": { "backend": "codex", "model": "gpt-5.6-luna", "effort": "low" },
                "implementer": { "backend": "codex", "model": "gpt-5.6-luna", "effort": "medium" },
                "reviewer": { "backend": "codex", "model": "gpt-5.6-terra", "effort": "high" } },
  "standard": { "planner": { "backend": "codex", "model": "gpt-5.6-terra", "effort": "high" },
                "implementer": [ { "backend": "codex", "model": "gpt-5.6-terra", "effort": "max" },
                                 { "backend": "codex", "model": "gpt-5.6-sol", "effort": "high" } ],
                "reviewer": { "backend": "claude", "model": "opus", "effort": "high" } },
  "complex":  { "planner": { "backend": "claude", "model": "opus", "effort": "xhigh" },
                "implementer": { "backend": "claude", "model": "opus", "effort": "high" },
                "reviewer": { "backend": "claude", "model": "opus", "effort": "xhigh" } }
}
JSON
export RESOLVE_TIER_ROOT="$CFG"

# A real git worktree: the script resolves --git-common-dir for writable_roots.
# A LINKED worktree — the shape every real worker runs in, and the only one
# `common-git-dir.sh --roots` will grant roots for. A plain repo takes the refusal branch,
# and before that branch existed it silently pinned the PRE-narrowing value here.
ORIGIN="$WORK/origin"
mkdir -p "$ORIGIN"
git -C "$ORIGIN" init -q
git -C "$ORIGIN" config user.email t@t.t
git -C "$ORIGIN" config user.name t
printf 'x\n' >"$ORIGIN/f"
git -C "$ORIGIN" add f
git -C "$ORIGIN" commit -qm init
# A real `base` branch: the script resolves the base to a SHA before reviewing (a base
# resolved by NAME could be moved by the worker, emptying its own diff), so the fixture
# needs a base that actually exists rather than a placeholder string.
git -C "$ORIGIN" branch base
REPO="$WORK/repo"
git -C "$ORIGIN" worktree add -q -b wt "$REPO" >/dev/null 2>&1

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in '$2')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpectedly found '$3')" ;; *) ok "$1" ;; esac; }
assert_empty()        { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected empty, got '$2')"; fi; }
# argv is checked line-by-line: a flag present as a SUBSTRING of some other argument is
# not the same as a flag actually passed.
assert_arg()          { if printf '%s\n' "$2" | grep -Fxq -- "$3"; then ok "$1"
                        else no "$1 (no argv line exactly '$3')"; fi; }

# mkrun <issue> [last-message] — a run dir with a thread id, as spawn.sh leaves it.
mkrun() {
    local d="$CODEX_ROOT/r1/issue-$1"
    mkdir -p "$d"
    printf '{"type":"thread.started","thread_id":"thr-%s-abc"}\n' "$1" >"$d/events.jsonl"
    printf '{}\n' >"$d/status-schema.json"
    printf '1\n' >"$d/exit"
    printf '%s' "${2:-}" >"$d/last-message.txt"
}

# --base is REQUIRED by the script (the post-resume review diffs against it), and every
# case below except the one that asserts the requirement itself is about something else.
# Injecting a default keeps those cases about what they are testing; the requirement gets
# its own test, which calls $SCRIPT directly to bypass this.
run() {
    local errf="$WORK/err"
    case " $* " in *" --base "*) ;; *) set -- "$@" --base base ;; esac
    OUT="$(timeout 60 bash "$SCRIPT" "$@" 2>"$errf")"
    RC=$?
    ERR="$(cat "$errf")"
}

# ---------------------------------------------------------------------------
echo "test: the resume re-passes every sandbox flag, because it inherits NONE of them"
mkrun 80
run r1 80 standard "$REPO" --answer "per-request" --dry-run
assert_equals "exit 0" "$RC" "0"
assert_arg "resumes"                    "$OUT" "resume"
assert_arg "the thread it left behind"  "$OUT" "thr-80-abc"
assert_arg "the tier's model, not the config default" "$OUT" "gpt-5.6-terra"
assert_arg "the tier's effort"          "$OUT" "model_reasoning_effort=max"
assert_arg "no approval prompts"        "$OUT" "approval_policy=never"
assert_arg "the sandbox MODE, since -s does not exist on resume" \
                                        "$OUT" "sandbox_mode=workspace-write"
assert_arg "the NETWORK, whose loss is silent and fatal" \
                                        "$OUT" "sandbox_workspace_write.network_access=true"
# Pinned by VALUE, not by substring: `writable_roots=[""]` contains the word too, and an
# empty or textually divergent root is exactly how a resumed worker silently loses the
# ability to commit. test_spawn.sh pins the spawn side the same way.
EXPECT_GITDIR="$(cd "$ORIGIN/.git" && pwd -P)"
EXPECT_OWN="$(cd "$(git -C "$REPO" rev-parse --git-dir)" && pwd -P)"
assert_arg "the NARROWED roots, spelled exactly as the spawn spells them" "$OUT" \
    "sandbox_workspace_write.writable_roots=[\"$EXPECT_GITDIR/objects\",\"$EXPECT_GITDIR/refs\",\"$EXPECT_GITDIR/logs\",\"$EXPECT_OWN\"]"
assert_not_contains "the whole common git dir is never granted on resume either" "$OUT" \
    "sandbox_workspace_write.writable_roots=[\"$EXPECT_GITDIR\"]"
assert_arg "the schema, so the report stays machine-readable" \
                                        "$OUT" "--output-schema"
assert_contains "writes the report where worker-report.sh reads it" "$OUT" "last-message.txt"

echo "test: --attempt re-passes the CHAIN cell's model, so a resume is not a stranger (#104)"
run r1 80 standard "$REPO" --answer "x" --attempt 1 --dry-run
assert_equals "exit 0" "$RC" "0"
assert_arg "attempt 1 is the chain's second cell" "$OUT" "gpt-5.6-sol"
assert_arg "at its effort" "$OUT" "model_reasoning_effort=high"
assert_not_contains "not the head" "$OUT" "gpt-5.6-terra"
run r1 80 standard "$REPO" --answer "x" --attempt 2 --dry-run
assert_equals "past the top: the resolver falls back to claude, which resume refuses" "$RC" "1"
run r1 80 standard "$REPO" --answer "x" --attempt q --dry-run
assert_equals "a non-numeric attempt exits 1" "$RC" "1"

echo "test: -s and -C are never passed — resume rejects both"
assert_not_contains "no -s" "$(printf '%s\n' "$OUT" | grep -Fx -- '-s')" "-s"
assert_not_contains "no -C" "$(printf '%s\n' "$OUT" | grep -Fx -- '-C')" "-C"

echo "test: the answer reaches the worker"
run r1 80 standard "$REPO" --answer "the budget is per-request" --dry-run
assert_contains "answer is in the prompt" "$OUT" "the budget is per-request"
assert_contains "and it is told to continue, not restart" "$OUT" "do not start over"
assert_contains "and how to report" "$OUT" "output schema"
assert_contains "and how to report missing infrastructure" "$OUT" "infra: <what is missing>"

echo "test: --answer-file is the same thing for a long answer"
printf 'a long\nmulti-line answer\n' >"$WORK/ans.txt"
run r1 80 standard "$REPO" --answer-file "$WORK/ans.txt" --dry-run
assert_equals "exit 0" "$RC" "0"
assert_contains "carries the file's text" "$OUT" "multi-line answer"

# ---------------------------------------------------------------------------
echo "test: a real resume records the new exit code and reports through worker-report.sh"
# The stub writes the NEW report, so a pass here proves rendering is delegated rather
# than reimplemented — and that the stale previous report was cleared first.
# The independent reviewer is the `claude -p` stub above (its argv goes to
# STUB_REVIEW_ARGV, which the reviewer test below reads); this stub is the WORKER only.
cat >"$BIN/codex" <<'STUB'
#!/usr/bin/env bash
pwd >"$STUB_CWD"
printf '%s\n' "$@" >"$STUB_ARGV"
# Stands in for a worker that reached the run dir (#99's non-default-CODEX_RUN_ROOT threat
# model) and planted a symlink at review-checkout BEFORE the resume's own cleanup runs.
if [ -n "${STUB_PLANT_SYMLINK_AT:-}" ]; then
    mkdir -p "$(dirname "$STUB_PLANT_SYMLINK_AT")"
    ln -sfn "${STUB_PLANT_SYMLINK_TARGET:?}" "$STUB_PLANT_SYMLINK_AT"
fi
out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && { out="$2"; break; }; shift; done
[ -z "$out" ] || printf '%s' "$STUB_REPORT" >"$out"
[ -n "${STUB_ENV_OUT:-}" ] && printf '%s|%s\n' "${DATABASE_URL:-}" "${FOO:-}" >"$STUB_ENV_OUT"
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$BIN/codex"

# gh is STUBBED, not permitted to be real: the reviewer's findings are posted to the issue
# as the "Review round" comment, and a test that reached the real gh would comment on
# whatever repo the suite happens to run in. It records the call so the post is assertable.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >>"${STUB_GH_ARGV:-/dev/null}"\nexit 0\n' \
    >"$BIN/gh"
chmod +x "$BIN/gh"

export STUB_CWD="$WORK/cwd" STUB_ARGV="$WORK/argv"
export STUB_REVIEW_ARGV="$WORK/review-argv" STUB_GH_ARGV="$WORK/gh-argv" STUB_REVIEW_ARGC="$WORK/review-argc" STUB_REVIEW_MARKER="$WORK/review-marker"
mkrun 81 '{"issue":81,"status":"escalate","round":0,"head":"","review":"","note":"old question"}'
STUB_REPORT='{"issue":81,"status":"built","round":0,"head":"9c2b4d1","review":"0 high, 1 medium, 0 low","note":""}' \
    run r1 81 standard "$REPO" --answer "per-request"
assert_equals "exit 0" "$RC" "0"
assert_equals "the RESUMED turn's report, rendered by worker-report.sh" "$OUT" \
    "issue 81 built head=9c2b4d1 review=0 high, 1 medium, 0 low"
assert_not_contains "and not the stale escalation it replaced" "$OUT" "old question"
assert_equals "the new exit code is recorded" "$(cat "$CODEX_ROOT/r1/issue-81/exit")" "0"
assert_equals "launched FROM the worktree, since resume has no -C" \
    "$(cat "$WORK/cwd")" "$REPO"

echo "test: --env reaches a real resumed worker without entering run files"
mkrun 90 '{"issue":90,"status":"escalate","round":0,"head":"","review":"","note":"old question"}'
STUB_ENV_OUT="$WORK/env-resume" \
    STUB_HOST_ENV_OUT="$WORK/host-env-resume" \
    STUB_REPORT='{"issue":90,"status":"built","round":0,"head":"abc","review":"","note":""}' \
    run r1 90 standard "$REPO" --answer x --env DATABASE_URL=postgres://x --env FOO=bar
assert_equals "resumed worker receives both --env values" \
    "$(cat "$WORK/env-resume" 2>/dev/null)" "postgres://x|bar"
assert_equals "resume host reviewer receives neither worker value" \
    "$(cat "$WORK/host-env-resume" 2>/dev/null)" '|'
leak=$(grep -rF 'postgres://x' "$CODEX_ROOT/r1/issue-90" 2>/dev/null || true)
assert_empty "resume run dir never contains the env value" "$leak"

mkrun 91 '{"issue":91,"status":"escalate","round":0,"head":"","review":"","note":"q"}'
run r1 91 standard "$REPO" --answer x --env DATABASE_URL=postgres://x --dry-run
assert_equals "resume dry run exits 0" "$RC" "0"
assert_not_contains "resume dry run never prints the env value" "$OUT" "postgres://x"
HOST_SECRET_CANARY=host-canary run r1 91 standard "$REPO" --answer x --env STRIPE_API_KEY=private-canary --dry-run
assert_arg "resume keeps explicitly provisioned KEY names in shell commands" "$OUT" \
    'shell_environment_policy.ignore_default_excludes=true'
excl=$(printf '%s\n' "$OUT" | grep '^shell_environment_policy.exclude=')
assert_contains "resume still filters inherited host secret names" "$excl" '"HOST_SECRET_CANARY"'
assert_not_contains "resume does not filter the provisioned name" "$excl" 'STRIPE_API_KEY'
assert_not_contains "resume config argv never prints the KEY value" "$OUT" 'private-canary'
assert_not_contains "resume config argv never prints a host secret value" "$OUT" 'host-canary'

echo "test: a resume that crashes is reported as failed, not as the previous turn's success"
mkrun 82 '{"issue":82,"status":"built","round":0,"head":"stale99","review":"0 high, 0 medium, 0 low","note":""}'
printf 'codex: fatal: thread not found\n' >"$CODEX_ROOT/r1/issue-82/stderr.log"
STUB_REPORT='' STUB_EXIT=4 run r1 82 standard "$REPO" --answer "x"
assert_equals "exit 0 — a crash is still characterisable" "$RC" "0"
assert_contains "failed" "$OUT" "issue 82 failed"
assert_not_contains "the stale success is gone" "$OUT" "stale99"
# stderr.log is appended to across turns and the no-report path reports its tail as the
# reason, so without clearing it this crash would be explained by a turn that ran hours
# ago — a truthful `failed` with an actively misleading reason, read by a human.
assert_not_contains "and not the PREVIOUS turn's stderr reason" "$OUT" "thread not found"

# ---------------------------------------------------------------------------
echo "test: it refuses to resume a worker that has not finished"
# The first side effect of a resume is `rm` of the exit file, so a mis-aimed call would
# both start a second codex on a worktree the first is still writing AND destroy the
# running worker's exit code. Everywhere else in this kit that is the cardinal sin.
mkdir -p "$CODEX_ROOT/r1/issue-85"
printf '{"type":"thread.started","thread_id":"thr-85-abc"}\n' >"$CODEX_ROOT/r1/issue-85/events.jsonl"
printf '{}\n' >"$CODEX_ROOT/r1/issue-85/status-schema.json"   # note: no exit file
run r1 85 standard "$REPO" --answer "x" --dry-run
assert_equals "a still-running worker exits 1" "$RC" "1"
assert_contains "says it has not finished" "$ERR" "has not finished"
assert_equals "and the events.jsonl it would have resumed is untouched" \
    "$(cat "$CODEX_ROOT/r1/issue-85/events.jsonl")" \
    '{"type":"thread.started","thread_id":"thr-85-abc"}'

echo "test: it refuses what it cannot safely resume"
mkrun 83
run r1 83 complex "$REPO" --answer "x" --dry-run
assert_equals "a claude-backed tier exits 1" "$RC" "1"
assert_empty "and prints no command" "$OUT"
assert_contains "says why" "$ERR" "not codex"

rm -f "$CODEX_ROOT/r1/issue-83/events.jsonl"
run r1 83 standard "$REPO" --answer "x" --dry-run
assert_equals "no events.jsonl exits 1" "$RC" "1"
assert_contains "names what is missing" "$ERR" "events.jsonl"

mkdir -p "$CODEX_ROOT/r1/issue-84"
printf '{"type":"turn.completed"}\n' >"$CODEX_ROOT/r1/issue-84/events.jsonl"
printf '{}\n' >"$CODEX_ROOT/r1/issue-84/status-schema.json"
run r1 84 standard "$REPO" --answer "x" --dry-run
assert_equals "a run dir with no thread id exits 1" "$RC" "1"
assert_contains "says so" "$ERR" "no thread_id"

run r1 999 standard "$REPO" --answer "x" --dry-run
assert_equals "no run dir exits 1" "$RC" "1"
assert_contains "names it" "$ERR" "no codex run dir"

echo "test: usage errors fail immediately and loudly"
run r1 80 standard "$REPO" --dry-run
assert_equals "no answer exits 1" "$RC" "1"
assert_contains "says an answer is required" "$ERR" "answer is required"

run r1 80 standard "$REPO" --answer "   " --dry-run
assert_equals "a whitespace-only answer exits 1" "$RC" "1"
assert_contains "says it is empty" "$ERR" "empty"

run "../../escape" 80 standard "$REPO" --answer "x" --dry-run
assert_equals "traversal runid exits 1" "$RC" "1"
assert_contains "same guard as spawn.sh" "$ERR" "runid may only contain"

run r1 notanumber standard "$REPO" --answer "x" --dry-run
assert_equals "non-numeric issue exits 1" "$RC" "1"
assert_contains "says which" "$ERR" "issue must be a number"

run r1 80 standard "$WORK/nosuchtree" --answer "x" --dry-run
assert_equals "a missing worktree exits 1" "$RC" "1"
assert_contains "names it" "$ERR" "no such worktree"

run r1 80 standard "$REPO" --answer "x" --bogus
assert_equals "unknown flag exits 1" "$RC" "1"
assert_contains "names it" "$ERR" "unknown flag"

run r1 80 standard "$REPO" --answer x --env NOEQUALS
assert_equals "malformed --env exits 1" "$RC" "1"
assert_contains "malformed --env says NAME=VALUE" "$ERR" "NAME=VALUE"
assert_not_contains "malformed --env never echoes its argument" "$ERR" "NOEQUALS"
assert_equals "malformed --env leaves the old exit file untouched" \
    "$(cat "$CODEX_ROOT/r1/issue-80/exit")" "1"

run r1 80 standard "$REPO" --answer x --env PATH=private-canary
assert_equals "resume rejects a reserved command-path variable" "$RC" "1"
assert_contains "resume explains the reserved name" "$ERR" "reserved"
assert_not_contains "resume never echoes the value" "$ERR" "private-canary"
assert_equals "reserved --env leaves the old exit file untouched" \
    "$(cat "$CODEX_ROOT/r1/issue-80/exit")" "1"

run r1 80 standard "$REPO" --answer x --env LD_AUDIT=private-canary
assert_equals "resume rejects loader variables" "$RC" "1"
assert_contains "loader rejection explains the reserved name" "$ERR" "reserved"
assert_equals "loader rejection leaves the old exit file untouched" \
    "$(cat "$CODEX_ROOT/r1/issue-80/exit")" "1"

# ---------------------------------------------------------------------------
# THE INDEPENDENT REVIEWER. A resumed worker's branch is as unreviewed as a freshly built
# one, and this script used to end by asking the WORKER for a review count it produced by
# reviewing itself (#96). These assert the replacement: a sibling reviewer, its verdict
# taken from its own output, and a run that cannot land when it did not run.
echo "test: the resumed turn ends with a SIBLING reviewer, not the worker's own review"
rm -f "$WORK/review-argv" "$WORK/gh-argv" "$WORK/review-cwd" "$WORK/review-tmpdir"
mkrun 86 '{"issue":86,"status":"escalate","round":0,"head":"","review":"","note":"q"}'
mkdir -p "$CODEX_ROOT/r1/issue-86"
printf '1 0 high, 0 medium, 0 low\n2 0 high, 0 medium, 0 low\n3 0 high, 0 medium, 0 low\n' \
    >"$CODEX_ROOT/r1/issue-86/rounds"
STUB_REPORT='{"issue":86,"status":"built","round":0,"head":"abc1234","review":"","note":""}' \
    STUB_REVIEW_TEXT='- [P1] a finding — src/f:1
- [P1] another — src/g:2
- [P3] a nit — src/h:3' \
    STUB_REVIEW_CWD="$WORK/review-cwd" STUB_REVIEW_TMPDIR="$WORK/review-tmpdir" \
    run r1 86 standard "$REPO" --answer "x" --base base
assert_equals "exit 0" "$RC" "0"
assert_contains "the REVIEWER's verdict reaches the report" "$OUT" \
    "issue 86 built head=abc1234 review=2 high, 0 medium, 1 low"
assert_contains "a reviewer really ran — claude -p (#104)" "$(cat "$WORK/review-argv" 2>/dev/null)" "personal-tools:my-review"
assert_equals "the prompt reached claude as ONE argument (review round 2)" "$(cat "$WORK/review-argc" 2>/dev/null)" "25"
# A SHA, not the branch name it was given: a name could be moved by the worker.
assert_not_contains "the base is NOT passed as a branch name" \
    "$(cat "$WORK/review-argv" 2>/dev/null)" "base..HEAD"
assert_contains "but as a resolved sha" "$(cat "$WORK/review-argv" 2>/dev/null)" \
    "$(git -C "$REPO" rev-parse --verify base^{commit})..HEAD"
assert_contains "at the tier's REVIEWER model, not the implementer's" \
    "$(cat "$WORK/review-argv" 2>/dev/null)" "opus"
assert_not_contains "never the implementer's" \
    "$(cat "$WORK/review-argv" 2>/dev/null)" "gpt-5.6-terra"
# THE SECURITY PROPERTY (#99): the review ran somewhere that is NOT the real worktree —
# a disposable clone instead — with TMPDIR pointed at the one scratch root the sandbox
# actually granted.
RUNDIR86="$CODEX_ROOT/r1/issue-86"
assert_equals "the reviewing marker existed while the review ran" "$(cat "$WORK/review-marker" 2>/dev/null)" "yes"
assert_equals "the review ran in the disposable checkout" \
    "$(cat "$WORK/review-cwd" 2>/dev/null)" "$RUNDIR86/review-checkout"
assert_not_contains "never in the real worktree" "$(cat "$WORK/review-cwd" 2>/dev/null)" "$REPO"
assert_equals "TMPDIR matches the ONE root the sandbox actually granted" \
    "$(cat "$WORK/review-tmpdir" 2>/dev/null)" "$RUNDIR86/review-scratch"
if [ -e "$RUNDIR86/review-checkout" ] || [ -e "$RUNDIR86/review-scratch" ]; then
    no "the disposable checkout or scratch dir survived the review"
else
    ok "the disposable checkout and scratch dir are cleaned up after the review"
fi

echo "test: the reviewer's findings are posted as the round's issue comment"
assert_contains "gh issue comment was called" "$(cat "$WORK/gh-argv" 2>/dev/null)" "comment"
assert_contains "on the right issue" "$(cat "$WORK/gh-argv" 2>/dev/null)" "86"
# The body travels as a FILE, not an argument: a review is multi-line model-written text,
# and passing it as --body would put it at the mercy of shell quoting.
assert_contains "as a --body-file" "$(cat "$WORK/gh-argv" 2>/dev/null)" "--body-file"
COMMENT="$(cat "$CODEX_ROOT/r1/issue-86/review-comment.md" 2>/dev/null)"
assert_contains "numbered from the ledger" "$COMMENT" "**Review round 4**"
assert_contains "and the reviewer's own findings text" "$COMMENT" "a finding"
# The heading's counts come from review-counts.sh, the SAME script worker-report.sh reads
# the verdict with — so the issue thread and the merge queue cannot disagree.
assert_contains "with the counts in the heading" "$COMMENT" "2 high, 0 medium, 1 low"
assert_equals "round 4's line is followed by its three finding entries" \
    "$(sed -n '/^4 /,$p' "$CODEX_ROOT/r1/issue-86/rounds" 2>/dev/null)" \
    "$(printf '4 2 high, 0 medium, 1 low\nfinding\t4\thigh\ta finding\tsrc/f:1\nfinding\t4\thigh\tanother\tsrc/g:2\nfinding\t4\tlow\ta nit\tsrc/h:3')"

run r1 86 standard "$REPO" --answer "x" --round 4 --dry-run
assert_equals "resume refuses the removed --round flag" "$RC" "1"
assert_contains "and reports an unknown flag" "$ERR" "unknown flag"

echo "test: a review-checkout symlink planted during the worker's OWN turn is neutralised"
# THE ORDERING BUG (#99 follow-up). review-checkout/review-scratch must be cleared AFTER
# the worker's turn, not before it — clearing before leaves the window between "before the
# worker runs" and "the clone trusts the path" wide open for that SAME worker (a
# non-default CODEX_RUN_ROOT reaching the run dir) to plant a symlink there. `mkdir -p`
# over a symlink-to-directory no-ops instead of failing, and `git clone` into one writes
# through it, so an unneutralised plant would hand the reviewer's sandbox grant and TMPDIR
# to a directory the WORKER chose.
rm -f "$WORK/review-argv" "$WORK/gh-argv" "$WORK/review-cwd" "$WORK/review-tmpdir"
SENTINEL="$WORK/sentinel-91"; rm -rf "$SENTINEL"; mkdir -p "$SENTINEL"
mkrun 91 '{"issue":91,"status":"escalate","round":0,"head":"","review":"","note":"q"}'
STUB_REPORT='{"issue":91,"status":"built","round":0,"head":"abc1234","review":"","note":""}' \
    STUB_PLANT_SYMLINK_AT="$CODEX_ROOT/r1/issue-91/review-checkout" \
    STUB_PLANT_SYMLINK_TARGET="$SENTINEL" \
    STUB_REVIEW_CWD="$WORK/review-cwd" STUB_REVIEW_TMPDIR="$WORK/review-tmpdir" \
    run r1 91 standard "$REPO" --answer "x" --base base
assert_equals "exit 0 — the plant did not wedge the resume" "$RC" "0"
assert_contains "the review still ran for real, against the real clone" "$OUT" \
    "issue 91 built"
# The decisive check: nothing landed in the attacker's sentinel directory. A dereferenced
# plant would have `git clone` write the checkout's files straight into it.
if [ -z "$(ls -A "$SENTINEL" 2>/dev/null)" ]; then
    ok "the sentinel directory the plant pointed at stayed empty"
else
    no "the clone wrote through the planted symlink into the sentinel directory"
fi
RUNDIR91="$CODEX_ROOT/r1/issue-91"
assert_equals "TMPDIR still resolved to the legitimate scratch root, not the plant" \
    "$(cat "$WORK/review-tmpdir" 2>/dev/null)" "$RUNDIR91/review-scratch"

echo "test: a FAILED review leaves no verdict behind — the run fails CLOSED"
# The sharp one. A reviewer that dies must not leave a half-written review.txt: a COUNTS
# line from the middle of an aborted run would be read as a real verdict, which is the
# same class of invented-fact the self-review was.
rm -f "$WORK/review-argv"
mkrun 87 '{"issue":87,"status":"escalate","round":0,"head":"","review":"","note":"q"}'
STUB_REPORT='{"issue":87,"status":"built","round":0,"head":"abc1234","review":"","note":""}' \
    STUB_REVIEW_EXIT=3 \
    run r1 87 standard "$REPO" --answer "x" --base base
assert_equals "exit 1 — we do not know if the branch is clean" "$RC" "1"
assert_empty "nothing on stdout the lane could act on" "$OUT"
assert_contains "says no review was recorded" "$ERR" "no independent review"
if [ -f "$CODEX_ROOT/r1/issue-87/review.txt" ]; then
    no "a failed review left review.txt behind"
else
    ok "the failed review's output was deleted, not left to be misread"
fi

echo "test: a worker that grades itself anyway is ignored, not believed"
# The worker is told to send "". One that sends a verdict regardless is the exact shape of
# the bug: its claim must never reach the report line.
rm -f "$WORK/review-argv"
mkrun 88 '{"issue":88,"status":"escalate","round":0,"head":"","review":"","note":"q"}'
STUB_REPORT='{"issue":88,"status":"built","round":0,"head":"abc1234","review":"0 high, 0 medium, 0 low","note":""}' \
    STUB_REVIEW_TEXT='- [P1] one — a:1
- [P1] two — b:2
- [P1] three — c:3' \
    run r1 88 standard "$REPO" --answer "x" --base base
assert_equals "exit 0" "$RC" "0"
assert_contains "the reviewer's verdict won" "$OUT" "review=3 high, 0 medium, 0 low"
assert_not_contains "the worker's self-grade did not" "$OUT" "0 high, 0 medium, 0 low"

echo "test: a resume that ESCALATES again is not reviewed — nothing was built to review"
# The reviewer is gated on the REPORTED STATUS, not just the exit code: a worker that
# escalates or fails also exits 0. Reviewing one of those posts a "**Review round**"
# comment on a half-built branch, and the orchestrate lane counts those comments as the
# run's cycles — so an escalation would silently spend a fix round it never used.
rm -f "$WORK/review-argv" "$WORK/gh-argv"
mkrun 89 '{"issue":89,"status":"escalate","round":0,"head":"","review":"","note":"first q"}'
STUB_REPORT='{"issue":89,"status":"escalate","round":0,"head":"","review":"","note":"still stuck"}' \
    run r1 89 standard "$REPO" --answer "x" --base base
assert_equals "exit 0 — an escalation is still a report" "$RC" "0"
assert_contains "it comes back as the question" "$OUT" "issue 89 escalate still stuck"
assert_empty "no reviewer ran" "$(cat "$WORK/review-argv" 2>/dev/null)"
assert_empty "and no review comment was posted" "$(cat "$WORK/gh-argv" 2>/dev/null)"

echo "test: a resume that FAILS is not reviewed either"
rm -f "$WORK/review-argv" "$WORK/gh-argv"
mkrun 90 '{"issue":90,"status":"escalate","round":0,"head":"","review":"","note":"q"}'
STUB_REPORT='{"issue":90,"status":"failed","round":0,"head":"","review":"","note":"the base moved"}' \
    run r1 90 standard "$REPO" --answer "x" --base base
assert_equals "exit 0 — a failure is a report" "$RC" "0"
assert_contains "reported as failed" "$OUT" "issue 90 failed"
assert_empty "no reviewer ran" "$(cat "$WORK/review-argv" 2>/dev/null)"

echo "test: --base is REQUIRED — a resume that skipped the review would land unreviewed"
# $SCRIPT directly, bypassing run()'s injected default.
ERRF="$WORK/err-nobase"
OUT="$(timeout 60 bash "$SCRIPT" r1 80 standard "$REPO" --answer "x" --dry-run 2>"$ERRF")"
RC=$?
assert_equals "exits 1" "$RC" "1"
assert_contains "says why" "$(cat "$ERRF")" "--base"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
