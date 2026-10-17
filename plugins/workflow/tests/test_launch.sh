#!/usr/bin/env bash
#
# Tests for scripts/launch.sh — the session lane's launch: checks, allowlist, graph, tiers,
# the fetch check, the orchestration worktree and run.env.
#
# The REAL launch.sh runs from a copy of the workflow scripts dir whose scope-graph.sh and
# prd-children.sh are stubs (they would call gh); run-env.sh, run-log.sh and merge-fold.sh
# are the real ones. Infra is the real infra dir with a fixture tier table.
#
# Run: bash plugins/workflow/tests/test_launch.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_WF="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
REAL_INFRA="$(cd "$SCRIPT_DIR/../../infra/scripts" && pwd)"
WORK="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in '$2')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

export HOME="$WORK/home"
mkdir -p "$HOME/.claude/kit/personal-tools/agents"
export CLAUDE_BOX_ROOT="$WORK/boxes" CODEX_RUN_ROOT="$WORK/runs" ORCH_INFRA="$REAL_INFRA"
for r in implementer planner reviewer; do mkdir -p "$CLAUDE_BOX_ROOT/$r"; printf '# %s\n' "$r" >"$CLAUDE_BOX_ROOT/$r/CLAUDE.md"; done
unset CLAUDE_PROJECT_DIR

CFG="$WORK/cfg"; mkdir -p "$CFG"
cat >"$CFG/model-tiers.json" <<'JSON'
{
  "trivial":  { "planner": { "backend": "claude", "model": "haiku", "effort": "low" },
                "implementer": { "backend": "claude", "model": "haiku", "effort": "low" },
                "reviewer": { "backend": "claude", "model": "sonnet", "effort": "low" } },
  "standard": { "planner": { "backend": "claude", "model": "opus", "effort": "medium" },
                "implementer": { "backend": "claude", "model": "sonnet", "effort": "high" },
                "reviewer": { "backend": "claude", "model": "opus", "effort": "medium" } },
  "complex":  { "planner": { "backend": "claude", "model": "opus", "effort": "high" },
                "implementer": { "backend": "claude", "model": "opus", "effort": "high" },
                "reviewer": { "backend": "claude", "model": "opus", "effort": "high" } }
}
JSON
export RESOLVE_TIER_ROOT="$CFG"

BIN="$WORK/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/claude"; chmod +x "$BIN/claude"
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/gh"; chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

WF="$WORK/wf"; mkdir -p "$WF"
for f in launch.sh run-env.sh run-log.sh merge-fold.sh; do cp "$REAL_WF/$f" "$WF/"; done
# The stubs print whatever the case put in these files.
cat >"$WF/scope-graph.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$STUB_SCOPE_ARGS"
cat "$STUB_GRAPH"
STUB
cat >"$WF/prd-children.sh" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_CHILDREN"
STUB
export STUB_GRAPH="$WORK/graph.json" STUB_CHILDREN="$WORK/children.txt" STUB_SCOPE_ARGS="$WORK/scope-args"

REPO="$WORK/repo"
git init -q -b dev "$REPO"
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
printf 'x\n' >"$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm init

graph() {   # graph <n:tier|null:state> ...
    local items="" sep="" n t st
    for spec in "$@"; do
        n="${spec%%:*}"; t="${spec#*:}"; st="${t#*:}"; t="${t%%:*}"
        [ "$t" = null ] || t="\"$t\""
        items="$items$sep{\"n\":$n,\"title\":\"t$n\",\"state\":\"$st\",\"labels\":[],\"tier\":$t,\"body\":\"\",\"comments\":\"\",\"blockedBy\":[]}"
        sep=,
    done
    printf '{"issues":[%s],"blockerStates":{},"mockDebtOpen":[]}\n' "$items" >"$STUB_GRAPH"
}
run() { OUT="$(cd "$REPO" && bash "$WF/launch.sh" "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }

echo "test: --issues launches: worktree, exclude, run.env, scope logged, one launch line"
graph 12:standard:open 13:trivial:open
run r1 --issues 13,12 --max 4
assert_equals "exit 0" "$RC" "0"
assert_contains "the launch line" "$OUT" "launch: run r1 base=dev@$(git -C "$REPO" rev-parse --short=7 HEAD)"
assert_contains "scope, ascending" "$OUT" "scope=12,13"
assert_contains "tiers from the graph" "$OUT" "tiers=12:standard,13:trivial"
assert_contains "the tier table source" "$OUT" "source=user"
assert_contains "no upstream" "$OUT" "upstream=none"
assert_contains "max" "$OUT" "max=4"
assert_equals "scope-graph got the allowlist" "$(cat "$STUB_SCOPE_ARGS")" "12 13"
WT="$REPO/.claude/worktrees/orchestrate-r1"
assert_contains "the worktree path is printed" "$OUT" "worktree=$WT"
assert_equals "the orchestration branch is checked out there" "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" "orchestrate-r1"
assert_equals "at the launch HEAD" "$(git -C "$WT" rev-parse HEAD)" "$(git -C "$REPO" rev-parse HEAD)"
assert_contains "local exclude covers the per-issue worktrees" "$(cat "$REPO/.git/info/exclude")" ".worktrees/"
assert_contains "and the orchestration worktree" "$(cat "$REPO/.git/info/exclude")" ".claude/worktrees/"
ENV="$CODEX_RUN_ROOT/r1/run.env"
if [ -f "$ENV" ]; then ok "run.env written"; else no "no run.env"; fi
( . "$ENV"; printf '%s|%s|%s|%s|%s\n' "$BASE_BRANCH" "$BASE_REPO" "$ORCH_BRANCH" "$MAX" "$GRAPH" ) >"$WORK/envvals"
assert_equals "run.env round-trips" "$(cat "$WORK/envvals")" "dev|$REPO|orchestrate-r1|4|$CODEX_RUN_ROOT/r1/graph.json"
assert_contains "the graph is kept in the run dir" "$(cat "$CODEX_RUN_ROOT/r1/graph.json")" '"n":12'
assert_contains "scope is in the run log" "$(cd "$REPO" && bash "$WF/run-log.sh" state r1)" "scope=12,13"

echo "test: the same runid cannot launch twice"
run r1 --issues 12
assert_equals "exit 1" "$RC" "1"
assert_contains "says so" "$ERR" "already launched"

echo "test: a missing tier exits 3 and writes nothing"
graph 12:standard:open 14:null:open 15:null:open
run r2 --issues 12,14,15
assert_equals "exit 3" "$RC" "3"
assert_equals "names the issues" "$OUT" "missing-tier: 14 15"
if [ -e "$CODEX_RUN_ROOT/r2" ] || git -C "$REPO" show-ref --quiet refs/heads/orchestrate-r2; then
    no "a missing-tier launch left state behind"; else ok "nothing written"; fi

echo "test: an unfetchable issue is an error unless --skip-unknown"
graph 12:standard:open 16:null:unknown
run r3 --issues 12,16
assert_equals "exit 1" "$RC" "1"
assert_contains "names it" "$ERR" "could not fetch: 16"
run r3 --issues 12,16 --skip-unknown
assert_equals "--skip-unknown launches" "$RC" "0"

echo "test: --prd scopes to open ready-for-agent children, never hitl or prd"
graph 21:standard:open 23:complex:open
printf '21 open ready-for-agent,tier:standard\n22 closed ready-for-agent\n23 open ready-for-agent\n24 open ready-for-agent,hitl\n25 open prd,ready-for-agent\n26 open tier:trivial\n' >"$STUB_CHILDREN"
run r4 --prd 20
assert_equals "exit 0" "$RC" "0"
assert_contains "counts the PRD's open children" "$OUT" "prd #20: 5 open children"
assert_equals "the graph is fetched for the admissible children only" "$(cat "$STUB_SCOPE_ARGS")" "21 23"

echo "test: a PRD with no open children offers the close and launches nothing"
printf '22 closed ready-for-agent\n' >"$STUB_CHILDREN"
run r5 --prd 20
assert_equals "exit 0" "$RC" "0"
assert_contains "the count" "$OUT" "prd #20: 0 open children"
assert_contains "and nothing to do" "$OUT" "nothing-to-do:"
if [ -e "$CODEX_RUN_ROOT/r5" ]; then no "launched anyway"; else ok "launched nothing"; fi

echo "test: a PRD whose children cannot be listed is an error, never a close offer"
: >"$STUB_CHILDREN"
run r5b --prd 20
assert_equals "exit 1" "$RC" "1"
assert_contains "says why" "$ERR" "could not list PRD #20's children"
assert_not_contains "no close offer" "$OUT" "0 open children"

echo "test: an issue an earlier run already merged into this branch is dropped from scope"
graph 13:standard:open
(cd "$REPO" && bash "$WF/run-log.sh" append r0 merged "{\"n\":41,\"sha\":\"$(git -C "$REPO" rev-parse HEAD)\"}" >/dev/null)
(cd "$REPO" && bash "$WF/run-log.sh" append r0 merged '{"n":13,"sha":"0123456789abcdef0123456789abcdef01234567"}' >/dev/null)
run r5c --issues 41,13
assert_equals "exit 0" "$RC" "0"
assert_contains "names it" "$OUT" "already-merged: 41"
assert_equals "and fetches only the rest" "$(cat "$STUB_SCOPE_ARGS")" "13"
assert_contains "a merge commit not in this branch does not count" "$OUT" "scope=13"

echo "test: an empty allowlist stops the run"
printf '27 open hitl\n' >"$STUB_CHILDREN"
run r6 --prd 20
assert_equals "exit 1" "$RC" "1"
assert_contains "never widened" "$ERR" "allowlist is empty"

echo "test: missing dependencies are named, all at once"
mv "$CLAUDE_BOX_ROOT/reviewer" "$WORK/reviewer-aside"
graph 12:standard:open
run r7 --issues 12
assert_equals "exit 1" "$RC" "1"
assert_contains "names the missing box" "$ERR" "worker box missing: $CLAUDE_BOX_ROOT/reviewer"
mv "$WORK/reviewer-aside" "$CLAUDE_BOX_ROOT/reviewer"
ORCH_INFRA="$WORK/nowhere" run r7 --issues 12
assert_contains "names missing infra" "$ERR" "infra scripts missing"

echo "test: a codex tier with no codex CLI fails at launch, not at the first spawn"
CFGX="$WORK/cfgx"; mkdir -p "$CFGX"
sed 's/"backend": "claude", "model": "sonnet"/"backend": "codex", "model": "gpt-6-luna"/' "$CFG/model-tiers.json" >"$CFGX/model-tiers.json"
NOCODEX="$WORK/nocodex"; mkdir -p "$NOCODEX"
IFS=: read -ra _dirs <<<"$PATH"
for d in "${_dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        n="$(basename "$f")"; [ "$n" = codex ] && continue
        [ -e "$NOCODEX/$n" ] || ln -s "$f" "$NOCODEX/$n" 2>/dev/null
    done
done
OUT="$(cd "$REPO" && PATH="$NOCODEX" RESOLVE_TIER_ROOT="$CFGX" "$(command -v bash)" "$WF/launch.sh" r8 --issues 12 2>"$WORK/err")"; RC=$?
assert_equals "exit 1" "$RC" "1"
assert_contains "names the CLI and the fix" "$(cat "$WORK/err")" "codex CLI is not installed"

echo "test: a base behind its upstream stops with exit 2 unless --allow-behind"
UP="$WORK/up.git"; git clone -q --bare "$REPO" "$UP"
git -C "$REPO" remote add origin "$UP"; git -C "$REPO" fetch -q origin
git -C "$REPO" branch -q -u origin/dev dev
OTHER="$WORK/other"; git clone -q "$UP" "$OTHER"
git -C "$OTHER" config user.email t@t.t; git -C "$OTHER" config user.name t
printf 'y\n' >"$OTHER/g"; git -C "$OTHER" add g; git -C "$OTHER" commit -qm ahead; git -C "$OTHER" push -q origin dev
run r9 --issues 12
assert_equals "exit 2" "$RC" "2"
assert_contains "says behind" "$ERR" "behind dev 1"
run r9 --issues 12 --allow-behind
assert_equals "--allow-behind launches" "$RC" "0"
assert_contains "and reports it" "$OUT" "upstream=behind:1"

echo "test: bad usage fails loud"
run ../x --issues 12; assert_equals "traversal runid" "$RC" "1"
run r10; assert_equals "no scope" "$RC" "1"
run r10 --prd 1 --issues 2; assert_equals "both scopes" "$RC" "1"
run r10 --issues 12 --max 0; assert_equals "zero max" "$RC" "1"
run r10 --issues 1x; assert_equals "junk issue" "$RC" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
