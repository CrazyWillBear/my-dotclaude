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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/worker-resume.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CODEX_ROOT="$WORK/codexruns"
export CODEX_RUN_ROOT="$CODEX_ROOT"

BIN="$WORK/bin"
mkdir -p "$BIN"

# session-status.sh (via worker-report.sh) needs the CLI; no claude sessions in fixtures.
printf '#!/usr/bin/env bash\nif [ "${1:-}" = agents ]; then echo "[]"; exit 0; fi\nexit 0\n' \
    >"$BIN/claude"
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
                "implementer": { "backend": "codex", "model": "gpt-5.6-terra", "effort": "max" },
                "reviewer": { "backend": "codex", "model": "gpt-5.6-terra", "effort": "high" } },
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

run() {
    local errf="$WORK/err"
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

echo "test: -s and -C are never passed — resume rejects both"
assert_not_contains "no -s" "$(printf '%s\n' "$OUT" | grep -Fx -- '-s')" "-s"
assert_not_contains "no -C" "$(printf '%s\n' "$OUT" | grep -Fx -- '-C')" "-C"

echo "test: the answer reaches the worker"
run r1 80 standard "$REPO" --answer "the budget is per-request" --dry-run
assert_contains "answer is in the prompt" "$OUT" "the budget is per-request"
assert_contains "and it is told to continue, not restart" "$OUT" "do not start over"
assert_contains "and how to report" "$OUT" "output schema"

echo "test: --answer-file is the same thing for a long answer"
printf 'a long\nmulti-line answer\n' >"$WORK/ans.txt"
run r1 80 standard "$REPO" --answer-file "$WORK/ans.txt" --dry-run
assert_equals "exit 0" "$RC" "0"
assert_contains "carries the file's text" "$OUT" "multi-line answer"

# ---------------------------------------------------------------------------
echo "test: a real resume records the new exit code and reports through worker-report.sh"
# The stub writes the NEW report, so a pass here proves rendering is delegated rather
# than reimplemented — and that the stale previous report was cleared first.
cat >"$BIN/codex" <<'STUB'
#!/usr/bin/env bash
pwd >"$STUB_CWD"
printf '%s\n' "$@" >"$STUB_ARGV"
out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && { out="$2"; break; }; shift; done
[ -z "$out" ] || printf '%s' "$STUB_REPORT" >"$out"
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$BIN/codex"
export STUB_CWD="$WORK/cwd" STUB_ARGV="$WORK/argv"
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

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
