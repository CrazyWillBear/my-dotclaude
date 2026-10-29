#!/usr/bin/env bash
#
# Tests for scripts/end-run.sh — integration review, preview, push, one PR with a
# `Closes #N` per merged slice, cleanup. The REAL end-run.sh runs beside the real run-env.sh,
# run-log.sh and merge-fold.sh; follow-up.sh, gh and infra's session-gc.sh are stubs, and the
# push goes to a real bare remote.
#
# Run: bash plugins/workflow/tests/test_end-run.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_WF="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in '$2')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

export HOME="$WORK/home" CODEX_RUN_ROOT="$WORK/runs" STUB_LOG="$WORK/log" CLAUDE_BOX_ROOT="$WORK/boxes"
unset CLAUDE_PROJECT_DIR
WF="$WORK/wf"; mkdir -p "$WF"
for f in end-run.sh run-env.sh run-log.sh merge-fold.sh; do cp "$REAL_WF/$f" "$WF/"; done
cat >"$WF/follow-up.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG.followup"
echo "integration: 0 high, 0 medium, 1 low — nothing filed"
STUB
INFRA="$WORK/infra"; mkdir -p "$INFRA"; export ORCH_INFRA="$INFRA"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$STUB_LOG.gc"\nif [ -n "${STUB_GC_FAIL:-}" ]; then echo "removed a x"; echo "error: could not remove b y" >&2; exit 1; fi\necho "nothing to remove"\n' >"$INFRA/session-gc.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$STUB_LOG.reap"\necho "reaped 2 process(es)"\n' >"$INFRA/reap.sh"
BIN="$WORK/bin"; mkdir -p "$BIN"
cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = repo ]; then echo "${STUB_DEFAULT:-dev}"; exit 0; fi
printf '%s\n' "$@" >"$STUB_LOG.gh"
while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$STUB_LOG.body"; shift; done
echo "https://github.com/o/r/pull/7"
STUB
chmod +x "$BIN/gh"; export PATH="$BIN:$PATH"

UPSTREAM="$WORK/up.git"; git init -q --bare "$UPSTREAM"
REPO="$WORK/repo"; git init -q -b dev "$REPO"
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
printf 'x\n' >"$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm init
git -C "$REPO" remote add origin "$UPSTREAM"; git -C "$REPO" push -q -u origin dev
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
ORCH_WT="$WORK/orchwt"; git -C "$REPO" worktree add -q -b orchestrate-r1 "$ORCH_WT" dev
git -C "$ORCH_WT" config user.email t@t.t; git -C "$ORCH_WT" config user.name t
printf 'a\n' >"$ORCH_WT/a"; git -C "$ORCH_WT" add a; git -C "$ORCH_WT" commit -qm "merge issue-11"

# Worker leftovers: #11 merged into the run branch (worktree + issue + prev branch), #13 holds unmerged work.
git -C "$REPO" branch issue-11 orchestrate-r1; git -C "$REPO" branch prev/issue-11-r1 orchestrate-r1
git -C "$REPO" worktree add -q "$REPO/.worktrees/r1/issue-11" issue-11
git -C "$REPO" worktree add -q -b issue-13 "$REPO/.worktrees/r1/issue-13" dev
git -C "$REPO/.worktrees/r1/issue-13" -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m unmerged
git -C "$REPO" branch prev/issue-13-r1 issue-13

GRAPH="$WORK/graph.json"
printf '%s' '{"issues":[{"n":11,"title":"one","tier":"standard","labels":[]},{"n":12,"title":"two","tier":"trivial","labels":[]},{"n":13,"title":"three","tier":"complex","labels":[]},{"n":14,"title":"four","tier":"standard","labels":[]}],"blockerStates":{},"mockDebtOpen":[]}' >"$GRAPH"
mkrunenv() {
    mkdir -p "$CODEX_RUN_ROOT/$1"
    cat >"$CODEX_RUN_ROOT/$1/run.env" <<EOF2
RUNID=$1
BASE_SHA=$BASE_SHA
BASE_BRANCH=dev
BASE_REPO=$REPO
ORCH_BRANCH=orchestrate-$1
ORCH_WT=$2
GRAPH=$GRAPH
MAX=8
PRD=20
SKIP_UNKNOWN=
EOF2
}
mkrunenv r1 "$ORCH_WT"
rl() { (cd "$REPO" && bash "$WF/run-log.sh" "$@") >/dev/null; }
for n in 11 12 13; do rl append r1 admitted "{\"n\":$n,\"tier\":\"x\"}"; done
rl append r1 merged '{"n":11,"sha":"aaaaaaa1"}'; rl append r1 merged '{"n":12,"sha":"bbbbbbb2"}'
rl append r1 escalated '{"n":12,"reason":"review-cap","attempt":0}'
rl append r1 held '{"n":13,"why":"drained: failed"}'
# #14 was held and then released (--retry), and never re-admitted: its old hold must not show
rl append r1 held '{"n":14,"why":"stale branch"}'; rl append r1 released '{"n":14}'
rl append r1 decision '{"what":"follow-up: #12 is itself a follow-up; its open findings need a human"}'
rl append r1 decision '{"what":"follow-up: #11 is itself a follow-up; its open findings need a human"}'

# run dirs: a worker's session id, a provisioned env file; box transcripts for it and another
for n in 11 12; do mkdir -p "$CODEX_RUN_ROOT/r1/issue-$n"; done
printf '{"type":"system","subtype":"init","session_id":"sid-aaa"}\n' >"$CODEX_RUN_ROOT/r1/issue-11/events.jsonl"
printf 'DATABASE_URL=x\0' >"$CODEX_RUN_ROOT/r1/issue-12/env"
mkdir -p "$CLAUDE_BOX_ROOT/implementer/projects/p" "$CLAUDE_BOX_ROOT/implementer/projects/p/sid-aaa"
: >"$CLAUDE_BOX_ROOT/implementer/projects/p/sid-aaa.jsonl"
: >"$CLAUDE_BOX_ROOT/implementer/projects/p/sid-other.jsonl"

echo "test: a run with merged slices pushes and opens ONE PR that closes them"
OUT="$(bash "$WF/end-run.sh" r1 2>"$WORK/err")"; RC=$?
assert_equals "exit 0" "$RC" "0"
assert_contains "the PR url" "$OUT" "pr: https://github.com/o/r/pull/7"
G="$(cat "$STUB_LOG.gh")"
assert_contains "gh pr create" "$G" "pr
create"
assert_contains "into the launch branch" "$G" "--base
dev"
assert_contains "from the orchestration branch" "$G" "--head
orchestrate-r1"
assert_contains "titled with the PRD and the slices" "$G" "orchestrate r1: PRD #20, #11, #12"
B="$(cat "$STUB_LOG.body")"
assert_contains "Closes the first merged slice" "$B" "Closes #11"
assert_contains "Closes the second" "$B" "Closes #12"
assert_not_contains "never a held one" "$B" "Closes #13"
assert_contains "the table names outcomes" "$B" "| #13 | three | complex | held: drained: failed | - |"
assert_contains "and escalations" "$B" "| #12 | two | trivial | merged bbbbbbb | review-cap |"
assert_contains "an issue never admitted is not built" "$B" "| #14 | four | standard | not built | - |"
assert_contains "the integration review" "$B" "integration review: integration: 0 high"
assert_contains "the preview against the upstream" "$B" "preview vs origin/dev: clean"
assert_contains "findings nobody filed are in the PR body" "$B" "- follow-up: #12 is itself a follow-up; its open findings need a human"
assert_contains "every unfiled line gets its own bullet" "$B" "- follow-up: #11 is itself a follow-up"
assert_contains "and in the output" "$OUT" "follow-up: #12 is itself a follow-up"
assert_contains "the exclude note" "$B" "info/exclude"
assert_contains "follow-up.sh reviewed launch..HEAD" "$(cat "$STUB_LOG.followup")" "--integration r1 $BASE_SHA $(git -C "$ORCH_WT" rev-parse HEAD) $GRAPH"
assert_equals "the branch was pushed" "$(git -C "$UPSTREAM" rev-parse orchestrate-r1)" "$(git -C "$ORCH_WT" rev-parse HEAD)"
assert_contains "session-gc for this run" "$(cat "$STUB_LOG.gc")" "--run r1"
assert_contains "leftover worker processes of the whole run are reaped" "$(cat "$STUB_LOG.reap")" "r1/"
assert_contains "and the count is reported" "$OUT" "reaped 2 process(es)"
if [ -e "$CODEX_RUN_ROOT/r1/issue-12/env" ]; then no "env file left behind"; else ok "env files removed"; fi
if [ -e "$CLAUDE_BOX_ROOT/implementer/projects/p/sid-aaa.jsonl" ] || [ -e "$CLAUDE_BOX_ROOT/implementer/projects/p/sid-aaa" ]; then
    no "this run's transcript survived"; else ok "this run's transcript removed"; fi
if [ -e "$CLAUDE_BOX_ROOT/implementer/projects/p/sid-other.jsonl" ]; then ok "an unrelated transcript kept"; else no "an unrelated transcript was removed"; fi
assert_contains "and says what it cleaned" "$OUT" "2 worker transcript path(s) removed"

echo "test: merged worker worktrees and branches go; unmerged work stays"
for x in "$REPO/.worktrees/r1/issue-11"; do if [ -e "$x" ]; then no "merged worktree left"; else ok "merged worktree removed"; fi; done
for br in issue-11 prev/issue-11-r1; do
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$br"; then no "merged $br left"; else ok "merged $br deleted"; fi
done
for br in issue-13 prev/issue-13-r1; do
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$br"; then ok "unmerged $br kept"; else no "unmerged $br deleted"; fi
done
if [ -d "$REPO/.worktrees/r1/issue-13" ]; then ok "unmerged worktree kept"; else no "unmerged worktree removed"; fi
assert_contains "and the counts are reported" "$OUT" "worktrees/branches: 3 removed, 2 kept"

assert_not_contains "on the default branch, no close warning" "$OUT" "will NOT close"
assert_not_contains "a clean cleanup does not claim a failure" "$OUT" "FAILED"

echo "test: a failed session cleanup is reported as failed, with its error lines"
git -C "$UPSTREAM" update-ref -d refs/heads/orchestrate-r1
OUT="$(STUB_GC_FAIL=1 bash "$WF/end-run.sh" r1 2>/dev/null)"
assert_contains "the cleanup line says FAILED" "$OUT" "cleanup: session-gc FAILED (exit 1)"
assert_contains "and quotes the error" "$OUT" "error: could not remove b y"

echo "test: a PR into a non-default branch says loudly that GitHub will not close the slices"
git -C "$UPSTREAM" update-ref -d refs/heads/orchestrate-r1
OUT="$(STUB_DEFAULT=main bash "$WF/end-run.sh" r1 2>/dev/null)"
assert_contains "in the output" "$OUT" "GitHub will NOT close #11, #12"
assert_contains "and atop the PR body" "$(head -1 "$STUB_LOG.body")" "targets dev, not the default branch main"

echo "test: nothing merged — no push, no PR, and it says so"
ORCH2="$WORK/orch2"; git -C "$REPO" worktree add -q -b orchestrate-r2 "$ORCH2" dev
mkrunenv r2 "$ORCH2"
rl append r2 admitted '{"n":11,"tier":"x"}'; rl append r2 held '{"n":11,"why":"plan failed"}'
: >"$STUB_LOG.gh"
OUT="$(bash "$WF/end-run.sh" r2 2>/dev/null)"
assert_contains "no PR" "$OUT" "pr: none — nothing merged"
assert_equals "gh never called" "$(cat "$STUB_LOG.gh")" ""
assert_contains "no integration review either" "$OUT" "integration review: nothing merged"

echo "test: no origin remote — the work stays on the branch, and it says so"
REPO3="$WORK/repo3"; git init -q -b dev "$REPO3"
git -C "$REPO3" config user.email t@t.t; git -C "$REPO3" config user.name t
printf 'x\n' >"$REPO3/f"; mkdir "$REPO3/.orchestrate"
printf '#!/usr/bin/env bash\necho "$*" >>"$STUB_LOG.teardown"\n[ "$2" != 12 ]\n' >"$REPO3/.orchestrate/teardown.sh"
git -C "$REPO3" add f .orchestrate; git -C "$REPO3" commit -qm init
ORCH3="$WORK/orch3"; git -C "$REPO3" worktree add -q -b orchestrate-r3 "$ORCH3" dev
printf 'b\n' >"$ORCH3/b"; git -C "$ORCH3" add b; git -C "$ORCH3" -c user.email=t@t.t -c user.name=t commit -qm m
mkrunenv r3 "$ORCH3"; sed -i "s|^BASE_REPO=.*|BASE_REPO=$REPO3|; s|^BASE_SHA=.*|BASE_SHA=$(git -C "$REPO3" rev-parse dev)|" "$CODEX_RUN_ROOT/r3/run.env"
(cd "$REPO3" && bash "$WF/run-log.sh" append r3 merged '{"n":11,"sha":"c"}' >/dev/null)
mkdir -p "$CODEX_RUN_ROOT/r3/issue-11" "$CODEX_RUN_ROOT/r3/issue-12"
OUT="$(bash "$WF/end-run.sh" r3 2>/dev/null)"
assert_contains "names the gap" "$OUT" "pr: none — no origin remote"

echo "test: the repo's teardown.sh runs once per issue with a run dir; a failure is reported"
assert_equals "called with runid, issue and worktree, in order" "$(cat "$STUB_LOG.teardown")" \
    "r3 11 $REPO3/.worktrees/r3/issue-11
r3 12 $REPO3/.worktrees/r3/issue-12"
assert_contains "and the failure is counted" "$OUT" "teardown ran for 1 issue(s), 1 FAILED"

echo "test: bad usage fails loud"
bash "$WF/end-run.sh" >/dev/null 2>&1; assert_equals "no runid" "$?" "1"
bash "$WF/end-run.sh" nope >/dev/null 2>&1; assert_equals "unlaunched run" "$?" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
