#!/usr/bin/env bash
#
# Tests for scripts/spawn.sh — the worker OR peer session command.
#
# Every assertion here is about a way an unattended session dies quietly: a name
# without the run prefix (one run stops another's workers), a permission mode that
# deadlocks on the first prompt, a denylist that lets a worker merge or close, a
# denylist so wide the worker cannot comment on its own issue, or a prompt that
# forgets to say "report with SendMessage" — after which the orchestrator waits
# forever for output that was never addressed to it.
#
# The dry-run assertions below can only prove a string is SOMEWHERE in the argv list.
# That is not enough, and it once wasn't: `--disallowedTools` is a VARIADIC option, so
# a prompt placed after it is parsed as more deny rules and the session comes up with
# no task at all — while every string assertion still passed. So the first test here
# runs the real exec path against a STUB `claude` and checks where the prompt LANDS.
#
# Run: bash plugins/infra/tests/test_spawn.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/spawn.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A fake HOME so nothing here can touch the real ~/.claude. spawn.sh now lives IN infra
# and finds resolve-tier.sh / session-status.sh beside itself, so no link is needed.
export HOME="$WORK/home"
mkdir -p "$HOME"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }
# the arg list is one-per-line, so an exact-line match is a real "this arg is present"
assert_arg() { if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else no "$1 (no arg line '$3')"; fi; }

dry() { bash "$SPAWN" "$@" --dry-run --orchestrator orch-main 2>"$WORK/err"; }
err() { cat "$WORK/err"; }

# The roster a worker resolves decides which BACKEND it spawns through, so the tests
# pin one instead of riding whatever the shipped table happens to say this week. The
# claude-path assertions below run against CFG_CLAUDE; the codex section further down
# swaps in CFG_CODEX, which is what proves a codex-routed tier reaches the codex path.
# One test deliberately uses the REAL shipped table — to pin that it is still claude.
CFG_CLAUDE="$WORK/cfg-claude"
mkdir -p "$CFG_CLAUDE"
cat >"$CFG_CLAUDE/model-tiers.json" <<'JSON'
{
  "trivial": {
    "planner":     { "backend": "claude", "model": "haiku",  "effort": "medium" },
    "implementer": { "backend": "claude", "model": "haiku",  "effort": "max" },
    "reviewer":    { "backend": "claude", "model": "sonnet", "effort": "high" }
  },
  "standard": {
    "planner":     { "backend": "claude", "model": "sonnet", "effort": "high" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "max" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "high" }
  },
  "complex": {
    "planner":     { "backend": "claude", "model": "opus",   "effort": "xhigh" },
    "implementer": { "backend": "claude", "model": "opus",   "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "xhigh" }
  }
}
JSON
CFG_CODEX="$WORK/cfg-codex"
mkdir -p "$CFG_CODEX"
cat >"$CFG_CODEX/model-tiers.json" <<'JSON'
{
  "trivial": {
    "planner":     { "backend": "claude", "model": "haiku",         "effort": "medium" },
    "implementer": { "backend": "codex",  "model": "gpt-5.6-luna",  "effort": "max" },
    "reviewer":    { "backend": "codex",  "model": "gpt-5.6-terra", "effort": "high" }
  },
  "standard": {
    "planner":     { "backend": "claude", "model": "sonnet",        "effort": "high" },
    "implementer": { "backend": "codex",  "model": "gpt-5.6-terra", "effort": "max" },
    "reviewer":    { "backend": "codex",  "model": "gpt-5.6-terra", "effort": "high" }
  },
  "complex": {
    "planner":     { "backend": "codex",  "model": "gpt-5.6-sol",   "effort": "xhigh" },
    "implementer": { "backend": "codex",  "model": "gpt-5.6-sol",   "effort": "high" },
    "reviewer":    { "backend": "codex",  "model": "gpt-5.6-sol",   "effort": "xhigh" }
  }
}
JSON
export RESOLVE_TIER_ROOT="$CFG_CLAUDE"

# A stub `claude` that dumps its argv, one per line, so the real exec path is testable.
# It also echoes its stdin: an unattended session that inherits the caller's stdin can
# block forever reading it, so the redirect is a flag-equivalent and is asserted below.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@"
printf 'STDIN:['; cat; printf ']\n'
STUB
chmod +x "$BIN/claude"

# ---------------------------------------------------------------------------
echo "test: the prompt actually LANDS as the prompt, not as a deny rule"
mkdir -p "$WORK/wt"
argv=$(PATH="$BIN:$PATH" bash "$SPAWN" r1 12 standard "$WORK/wt" base --orchestrator orch-main)
# `--` must separate the variadic deny list from the prompt, and the prompt must be
# the LAST argument, after it. Without that the session starts with no task, goes
# idle, and `idle` is this design's DONE signal for a background worker.
assert_contains "argv carries a -- terminator" "$argv" "--"
# The prompt is one multi-line argument, so compare LINE POSITIONS: its first line
# must be the line immediately after the `--`, and nothing may sit between them.
sep=$(printf '%s\n' "$argv" | grep -nxF -- "--" | tail -1 | cut -d: -f1)
prompt_line=$(printf '%s\n' "$argv" | grep -n "BUILD session for issue #12" | head -1 | cut -d: -f1)
if [ -n "$sep" ] && [ -n "$prompt_line" ] && [ "$prompt_line" -eq "$((sep + 1))" ]; then
    ok "the prompt is the argument immediately after --"
else
    no "the prompt is not fenced off from the variadic deny list (-- at line $sep, prompt at $prompt_line)"
fi
assert_contains "and the prompt survives whole" "$argv" "MUST use the SendMessage tool"
assert_contains "and it is the LAST argument" "$(printf '%s\n' "$argv" | sed -n "$((sep + 1)),\$p")" "Never merge, never open a PR"
denies=$(printf '%s\n' "$argv" | grep -cxF "Bash(git merge:*)")
assert_equals "the deny rules still land" "$denies" "1"

echo "test: the session never inherits the caller's stdin"
argv=$(PATH="$BIN:$PATH" bash "$SPAWN" r1 12 standard "$WORK/wt" base --orchestrator orch-main <<<"LEAKED")
assert_contains "stdin is empty" "$argv" "STDIN:[]"
assert_not_contains "nothing leaked through" "$argv" "LEAKED"

# ---------------------------------------------------------------------------
echo "test: the command carries the run-prefixed name and the tier's roster"
out=$(dry 20260906-101500 12 standard /w/issue-12 orchestrate-20260906)
assert_arg "background" "$out" "--bg"
assert_arg "run-prefixed session name" "$out" "orch-20260906-101500-issue-12"
assert_arg "standard tier -> sonnet implementer" "$out" "sonnet"
out_c=$(dry 20260906-101500 12 complex /w/issue-12 orchestrate-20260906)
assert_arg "complex tier -> opus implementer" "$out_c" "opus"
assert_not_contains "and not the standard model" "$(printf '%s\n' "$out_c" | grep -A1 -- '--model')" "sonnet"

echo "test: an unattended session never comes up able to prompt"
assert_arg "bypassPermissions" "$out" "bypassPermissions"
assert_arg "--add-dir the worktree" "$out" "/w/issue-12"

# `on` (the default) records the rendered system prompt on the first request and replays
# it on every resume, so a resumed session would keep a stale charter forever.
assert_arg "system prompt is re-rendered, not snapshotted" "$out" "--system-prompt-snapshot"
assert_arg "snapshot off" "$out" "off"

echo "test: the denylist keeps the irreversible writes on the main thread"
assert_arg "no git merge" "$out" "Bash(git merge:*)"
assert_arg "no git worktree" "$out" "Bash(git worktree:*)"
assert_arg "no gh pr" "$out" "Bash(gh pr:*)"
assert_arg "no gh issue close" "$out" "Bash(gh issue close:*)"
assert_arg "no gh issue edit" "$out" "Bash(gh issue edit:*)"

echo "test: push and issue comment stay ALLOWED — the thread is the bus"
assert_not_contains "push not denied" "$out" "Bash(git push"
assert_not_contains "comment not denied" "$out" "Bash(gh issue comment"

echo "test: the prompt tells the worker plain output is invisible"
assert_contains "names SendMessage" "$out" "SendMessage"
assert_contains "says output is invisible" "$out" "INVISIBLE"
assert_contains "addresses the orchestrator by name" "$out" '"orch-main"'
assert_contains "fixed-shape status line" "$out" "issue 12 built head="

echo "test: the build prompt carries the load-bearing protocol"
assert_contains "reads the issue comments first" "$out" "--comments"
assert_contains "posts the tackled comment" "$out" "Tackled #12"
assert_contains "commit per green sub-step is framed as RECOVERY" "$out" "COMMIT AFTER EVERY GREEN SUB-STEP"
assert_contains "spawns my-review itself" "$out" "personal-tools:my-review"
assert_contains "does not fix its own findings" "$out" "a fresh session does that"
assert_contains "context map is a hint" "$out" "CONTEXT-MAP.md"
assert_contains "escalation path" "$out" "escalate"

echo "test: only a complex issue is told to plan first"
out_p=$(dry 20260906-101500 12 complex /w/issue-12 orchestrate-20260906)
assert_contains "complex spawns the planner itself" "$out_p" "spawn the workflow:planner agent FIRST"
assert_contains "and keeps the plan out of the orchestrator" "$out_p" "never send it to the orchestrator"
out_s=$(dry 20260906-101500 12 standard /w/issue-12 orchestrate-20260906)
assert_not_contains "standard self-plans" "$out_s" "workflow:planner"
assert_not_contains "trivial self-plans" "$(dry r1 12 trivial /w base)" "workflow:planner"

echo "test: --role fix is a fresh session working from the review comment"
out=$(dry 20260906-101500 12 standard /w/issue-12 orchestrate-20260906 --role fix --round 2)
assert_contains "says which round" "$out" "FIX ROUND 2"
assert_contains "did not write this code" "$out" "You did not write this code"
assert_contains "reads the review comment" "$out" "Review round"
assert_contains "reports the round back" "$out" "round=2"
assert_not_contains "does not re-post the tackled comment" "$out" "Tackled #12"

echo "test: --orchestrator resolves from this session when omitted"
out=$(bash "$SPAWN" r1 12 standard /w/issue-12 base --dry-run 2>"$WORK/err"); rc=$?
if [ "$rc" -eq 0 ]; then
    assert_contains "resolved a name" "$out" "SendMessage"
else
    assert_contains "or fails LOUD — a worker with no address reports into the void" \
        "$(err)" "pass --orchestrator NAME"
fi

# ---------------------------------------------------------------------------
echo "test: bad input fails loud instead of spawning something wrong"
bash "$SPAWN" r1 >/dev/null 2>"$WORK/err"; assert_equals "too few args exits 1" "$?" "1"
assert_contains "prints usage" "$(err)" "usage:"
dry r1 twelve standard /w base >/dev/null; assert_equals "non-numeric issue exits 1" "$?" "1"
dry r1 12 standard /w base --role sideways >/dev/null; assert_equals "bad role exits 1" "$?" "1"
dry r1 12 standard /w base --bogus >/dev/null; assert_equals "unknown flag exits 1" "$?" "1"
assert_contains "names the flag" "$(err)" "unknown flag"

echo "test: an unknown tier still spawns — resolve-tier.sh falls back to standard"
out=$(dry r1 12 nonsense /w/issue-12 base); assert_arg "fallback roster" "$out" "sonnet"

echo "test: a real spawn refuses a worktree that does not exist"
bash "$SPAWN" r1 12 standard "$WORK/nope" base --orchestrator orch-main >/dev/null 2>"$WORK/err"
assert_equals "exits 1" "$?" "1"
assert_contains "says which path" "$(err)" "worktree does not exist"

echo "test: without its infra siblings, spawn fails loud instead of guessing a roster"
mkdir -p "$WORK/lone"
cp "$SPAWN" "$WORK/lone/spawn.sh"
bash "$WORK/lone/spawn.sh" r1 12 standard /w base --dry-run --orchestrator orch-main >/dev/null 2>"$WORK/err"
assert_equals "exits 1" "$?" "1"
assert_contains "names the missing script" "$(err)" "resolve-tier.sh"

# ---------------------------------------------------------------------------
# The CODEX backend. A tier whose implementer row says `backend: codex` spawns through
# `codex exec` instead of `claude --bg` (docs/swarm-design.md § Codex backend). Every
# flag below is a way that worker dies quietly:
#   -m               a resumed thread silently falls back to the config's default model
#   -s workspace-write + writable_roots
#                    workspace-write keeps .git READ-ONLY, so without the repo's common
#                    git dir listed the worker writes its files and cannot commit —
#                    and reports success. That is a whole issue built and lost.
#   approval_policy=never
#                    an unattended run that stops to ask is wedged with nobody there
#   network_access=true
#                    workspace-write is OFFLINE by default; the prompt orders gh and
#                    codex commands, and approval_policy=never cannot ask for it back
#   </dev/null       codex BLOCKS FOREVER reading an open stdin
#   --json / -o / --output-schema / pid / exit
#                    codex has no agent list, so these files ARE the session's state;
#                    session-status.sh has nothing else to read it from
CODEX_BIN="$WORK/codexbin"
mkdir -p "$CODEX_BIN"
# A stub `codex` that dumps its argv and stdin to stdout (which spawn.sh redirects into
# the events file) and, like the real one, writes its final message to the `-o` path.
cat >"$CODEX_BIN/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@"
printf 'STDIN:['; cat; printf ']\n'
while [ $# -gt 0 ]; do
    if [ "$1" = -o ]; then printf '{"issue":12,"status":"built"}\n' >"$2"; fi
    shift
done
[ -n "${STUB_CODEX_SLEEP:-}" ] && sleep "$STUB_CODEX_SLEEP"
exit "${STUB_CODEX_EXIT:-0}"
STUB
chmod +x "$CODEX_BIN/codex"

# A REAL git worktree, because the writable root is resolved with
# `git rev-parse --git-common-dir` and a fake path would make that assertion a fiction.
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
GITDIR="$(cd "$REPO/.git" && pwd -P)"
CODEX_ROOT="$WORK/codexruns"
RUNDIR="$CODEX_ROOT/r9/issue-12"

codex_dry() {
    CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_CODEX" \
        bash "$SPAWN" "$@" --dry-run --orchestrator orch-main 2>"$WORK/err"
}

echo "test: a codex-tier worker spawns through codex exec, not claude"
out=$(codex_dry r9 12 standard "$REPO" base)
assert_arg "the codex CLI" "$out" "codex"
assert_arg "exec subcommand" "$out" "exec"
assert_not_contains "no claude --bg" "$out" "--bg"
assert_arg "-C the worktree" "$out" "-C"
assert_arg "the worktree path" "$out" "$REPO"
assert_arg "-m is always passed" "$out" "-m"
assert_arg "standard tier -> terra" "$out" "gpt-5.6-terra"
assert_arg "reasoning effort from the roster" "$out" "model_reasoning_effort=max"
assert_arg "never stops to ask" "$out" "approval_policy=never"
assert_arg "sandbox mode" "$out" "-s"
assert_arg "workspace-write" "$out" "workspace-write"
assert_arg "the common git dir is writable, or the worker cannot commit" "$out" \
    "sandbox_workspace_write.writable_roots=[\"$GITDIR\"]"
# workspace-write turns the network OFF by default (verified on codex-cli 0.154), and
# this worker's own prompt orders `gh issue view`, `gh issue comment` and `codex exec
# review` — all network. With approval_policy=never it cannot even ask for it back.
assert_arg "the sandbox lets the worker reach the network" "$out" \
    "sandbox_workspace_write.network_access=true"
assert_arg "streams events as json" "$out" "--json"
assert_arg "-o the last message" "$out" "-o"
assert_arg "last-message path" "$out" "$RUNDIR/last-message.txt"
assert_arg "--output-schema" "$out" "--output-schema"
assert_arg "schema path" "$out" "$RUNDIR/status-schema.json"
assert_contains "and it carries the build protocol" "$out" "BUILD session for issue #12"
# codex exec takes the prompt as its last positional, with no `--` fence and no variadic
# option to swallow it — but it still has to BE last, or a flag lands after the prompt.
p=$(printf '%s\n' "$out" | grep -n "BUILD session for issue #12" | head -1 | cut -d: -f1)
o=$(printf '%s\n' "$out" | grep -nxF -- "--output-schema" | head -1 | cut -d: -f1)
if [ -n "$p" ] && [ -n "$o" ] && [ "$p" -gt "$o" ]; then
    ok "the prompt is the last argument, after every flag"
else
    no "the prompt at line $p is not after the flags (--output-schema at $o)"
fi

echo "test: the codex worker is told how to report — it has no SendMessage tool"
assert_contains "says outright it has no SendMessage tool" "$out" "NO SendMessage tool"
assert_not_contains "and is never told to use one" "$out" "MUST use the SendMessage tool"
assert_contains "its final message is the report" "$out" "output schema"
assert_contains "fixed-shape JSON status" "$out" '"status": "built"'
assert_contains "reviews with codex exec review" "$out" "codex exec review --base base"

echo "test: a codex dry run leaves no run dir behind"
# session-status.sh reads a run dir with a pid file as a live worker, and one without a
# pid as BUSY — the launch-window rule. A dry run that creates the dir hands it a phantom
# the orchestrator waits on forever; the claude path's dry run touches nothing, so nor
# may this one.
rm -rf "$CODEX_ROOT/dryonly"
CODEX_RUN_ROOT="$CODEX_ROOT/dryonly" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" r9 12 standard "$REPO" base --dry-run --orchestrator orch-main >/dev/null 2>&1
if [ -e "$CODEX_ROOT/dryonly" ]; then
    no "the dry run created $CODEX_ROOT/dryonly — a phantom worker session-status reads as busy"
else
    ok "a dry run creates no run dir"
fi

echo "test: a failed schema write leaves no run dir behind either"
# Same phantom, different exit: mkdir succeeds, then the schema redirect dies (read-only
# fs, ENOSPC) and the pidless dir stays. session-status.sh:241-247 reads that as BUSY
# forever, so /orchestrate's recovery gate never clears and the run stalls with no way
# out. A `status-schema.json` that is already a DIRECTORY fails the redirect the same
# way a read-only mount does, and does it for root too.
rm -rf "$CODEX_ROOT/schemafail"
mkdir -p "$CODEX_ROOT/schemafail/r9/issue-12/status-schema.json"
CODEX_RUN_ROOT="$CODEX_ROOT/schemafail" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" r9 12 standard "$REPO" base --orchestrator orch-main >/dev/null 2>&1
rc=$?
assert_equals "an unwritable schema exits non-zero" "$rc" "1"
if [ -e "$CODEX_ROOT/schemafail/r9/issue-12" ]; then
    no "the failed spawn left $CODEX_ROOT/schemafail/r9/issue-12 — a phantom session-status reads as busy"
else
    ok "the failed spawn cleans up its run dir"
fi
rm -rf "$CODEX_ROOT/schemafail"

echo "test: the codex tier is resolved per tier, not hardcoded"
assert_arg "trivial -> luna" "$(codex_dry r9 12 trivial "$REPO" base)" "gpt-5.6-luna"
assert_arg "complex -> sol" "$(codex_dry r9 12 complex "$REPO" base)" "gpt-5.6-sol"
# A codex worker has no subagents either, so "spawn the planner" is the same stranding
# bug as "use SendMessage" — it still has to PLAN, it just has to do it itself.
out_cx=$(codex_dry r9 12 complex "$REPO" base)
assert_contains "complex still plans before it builds" "$out_cx" "PLAN FIRST"
assert_not_contains "but is not told to spawn an agent it cannot spawn" \
    "$out_cx" "workflow:planner"

echo "test: a real codex spawn writes events, last-message, pid and exit files"
rm -rf "$CODEX_ROOT"
PATH="$CODEX_BIN:$PATH" CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" r9 12 standard "$REPO" base --orchestrator orch-main >/dev/null 2>"$WORK/err" <<<"LEAKED"
# the spawn returns immediately; the worker runs in the background
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$RUNDIR/exit" ] && break; sleep 0.2; done
for f in events.jsonl last-message.txt pid exit status-schema.json; do
    if [ -f "$RUNDIR/$f" ]; then ok "wrote $f"; else no "missing $RUNDIR/$f"; fi
done
assert_equals "exit 0 recorded" "$(cat "$RUNDIR/exit" 2>/dev/null)" "0"
assert_contains "the events file holds what codex streamed" "$(cat "$RUNDIR/events.jsonl")" "workspace-write"
assert_contains "codex wrote its final message" "$(cat "$RUNDIR/last-message.txt")" '"status":"built"'
assert_contains "the schema is real JSON naming the status field" \
    "$(cat "$RUNDIR/status-schema.json")" '"status"'
assert_contains "stdin is closed — codex blocks forever on an open one" \
    "$(cat "$RUNDIR/events.jsonl")" "STDIN:[]"
assert_not_contains "nothing leaked through" "$(cat "$RUNDIR/events.jsonl")" "LEAKED"

echo "test: a codex worker that dies non-zero records it"
rm -rf "$CODEX_ROOT"
PATH="$CODEX_BIN:$PATH" STUB_CODEX_EXIT=3 CODEX_RUN_ROOT="$CODEX_ROOT" \
    RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" r9 12 standard "$REPO" base --orchestrator orch-main >/dev/null 2>"$WORK/err"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$RUNDIR/exit" ] && break; sleep 0.2; done
assert_equals "the exit code is the one codex returned" "$(cat "$RUNDIR/exit" 2>/dev/null)" "3"

# THE ORPHAN TRAP. The pid in the run dir is what /orchestrate's recovery kills, and the
# process it names is the WRAPPER, not codex — codex is its child. Backgrounded with a
# bare `&` the wrapper shares spawn.sh's process group, so the only safe target is the
# wrapper alone: `kill $pid` reaps it, leaves codex running as an orphan still writing the
# worktree, and writes no exit file — which session-status.sh reads as `failed`, clearing
# the recovery gate for a respawn onto that same worktree. Two processes, one worktree,
# corruption, reached by following the recovery recipe. So spawn.sh starts the wrapper
# under job control: the recorded pid leads its own group and `kill -- -$pid` reaches
# codex with it.
#
# Spawns a long-running worker under $2 as PATH, proves the recorded pid leads its own
# group, then group-kills it and proves nothing survived. $1 labels the case.
check_group() {
    local label="$1" spath="$2" wpid pgid
    rm -rf "$CODEX_ROOT"
    PATH="$spath" STUB_CODEX_SLEEP=30 CODEX_RUN_ROOT="$CODEX_ROOT" \
        RESOLVE_TIER_ROOT="$CFG_CODEX" \
        bash "$SPAWN" r9 12 standard "$REPO" base --orchestrator orch-main >/dev/null 2>"$WORK/err"
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$RUNDIR/pid" ] && break; sleep 0.2; done
    wpid="$(cat "$RUNDIR/pid" 2>/dev/null)"
    pgid="$(ps -o pgid= -p "$wpid" 2>/dev/null | tr -d ' ')"
    # an empty wpid must not meet an empty pgid and read as a pass
    if [ -z "$wpid" ] || [ "$pgid" != "$wpid" ]; then
        # NEVER kill this group: it is the test runner's own, which is the whole finding.
        no "$label: the recorded pid ('$wpid') does not lead its own group ('$pgid') — a group kill would take the caller down"
        [ -n "$wpid" ] && kill "$wpid" 2>/dev/null
        pkill -f "$CODEX_BIN/codex" 2>/dev/null
        return
    fi
    ok "$label: the recorded pid IS its group leader"
    # wait for the stub to actually join the group, or "no orphan" passes on a group
    # codex had not reached yet
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ "$(pgrep -g "$pgid" 2>/dev/null | wc -l)" -ge 2 ] && break; sleep 0.2
    done
    assert_equals "$label: codex runs inside that group, not beside it" \
        "$([ "$(pgrep -g "$pgid" 2>/dev/null | wc -l)" -ge 2 ] && echo yes)" "yes"
    kill -- -"$pgid" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(pgrep -g "$pgid" 2>/dev/null)" ] && break; sleep 0.2; done
    if [ -z "$(pgrep -g "$pgid" 2>/dev/null)" ]; then
        ok "$label: one group kill leaves no orphan behind"
    else
        no "$label: survivors after kill -- -$pgid: $(pgrep -g "$pgid" | tr '\n' ' ')"
        pkill -9 -g "$pgid" 2>/dev/null
    fi
}

echo "test: the recorded pid leads its own process group, so a stop can reach codex"
check_group "group" "$CODEX_BIN:$PATH"

echo "test: and it does so without setsid — macOS ships none, and the kit promises macOS"
# `setsid` is util-linux, i.e. Linux-only, while README.md and AGENT_SETUP.md both promise
# macOS / Linux / WSL. So the wrapper's group comes from bash's own job control (`set -m`),
# a builtin, not from an external command. This shim fails the way a missing setsid would:
# if spawn.sh reaches for it at all, no worker comes up and the group assertions go red.
NOSETSID="$WORK/nosetsid"
mkdir -p "$NOSETSID"
printf '#!/usr/bin/env bash\necho "setsid: not found" >&2\nexit 127\n' >"$NOSETSID/setsid"
chmod +x "$NOSETSID/setsid"
check_group "no setsid" "$NOSETSID:$CODEX_BIN:$PATH"

echo "test: the spawn prints the run dir and returns — it does not hold stdout open"
# The codex path's stdout IS its return value (the run dir), so a caller reads it with
# `$(...)`. A worker that inherits stdout holds the pipe's write end for its whole run,
# and that command substitution blocks until the worker exits — the opposite of a spawn.
rm -rf "$CODEX_ROOT"
t0=$SECONDS
out=$(PATH="$CODEX_BIN:$PATH" STUB_CODEX_SLEEP=8 CODEX_RUN_ROOT="$CODEX_ROOT" \
      RESOLVE_TIER_ROOT="$CFG_CODEX" \
      bash "$SPAWN" r9 12 standard "$REPO" base --orchestrator orch-main 2>/dev/null)
assert_equals "prints the run dir" "$out" "$RUNDIR"
if [ "$((SECONDS - t0))" -lt 4 ]; then
    ok "and returns at once"
else
    no "the capture blocked $((SECONDS - t0))s — the worker inherited stdout"
fi
# no `|| echo 0` fallback: pkill reads group 0 as its OWN group, so a run that wrote no
# pid file — i.e. a red test — would SIGTERM the test runner instead of a worker.
wpid="$(cat "$RUNDIR/pid" 2>/dev/null)"
[ -n "$wpid" ] && kill -- -"$wpid" 2>/dev/null

echo "test: codex is never a peer — a peer needs an inbox and codex has none"
printf 'You are the swe-manager.\n' >"$WORK/pb.md"
printf 'CHARTER line.\n' >"$WORK/pc.md"
assert_not_contains "a peer stays claude whatever the tier table says" \
    "$(RESOLVE_TIER_ROOT="$CFG_CODEX" bash "$SPAWN" peer --name p --brief "$WORK/pb.md" \
        --charter "$WORK/pc.md" --model opus --effort high --orchestrator orch-main \
        --dry-run 2>/dev/null)" "codex"

# The codex path above is built, tested and ready; the SHIPPED roster is deliberately
# NOT on it. The session lane subscribes to a worker with SendMessage and waits for its
# report, and a codex worker's report lands in last-message.txt, which nothing reads —
# so a codex default stalls a run at its first worker. Orchestrator-side ingest is the
# prerequisite (#96). Flipping model-tiers.json before that lands trips this test.
echo "test: the SHIPPED roster still routes workers through claude — the flip is on hold"
for t in trivial standard complex; do
    out=$(CODEX_RUN_ROOT="$CODEX_ROOT" env -u RESOLVE_TIER_ROOT \
          bash "$SPAWN" r9 12 "$t" "$REPO" base --dry-run --orchestrator orch-main 2>/dev/null)
    assert_arg "shipped $t spawns claude" "$out" "--bg"
    assert_not_contains "shipped $t is not on codex yet (needs #96's report ingest)" \
        "$out" "codex exec"
done

echo "test: a runid carrying a path component is refused before it reaches mkdir -p or rm -rf"
# $RUNID is joined into the codex run dir, which spawn.sh both creates and — on a failed
# schema write — `rm -rf`s. The caller is a model assembling argv by hand, and run-log.sh
# already guards the identical value, so spawn.sh must too.
CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" "../../escape" 12 standard "$REPO" base --orchestrator orch-main --dry-run \
    >/dev/null 2>"$WORK/err"
assert_equals "exits 1 on a traversal runid" "$?" "1"
assert_contains "names the value and what is allowed" "$(err)" "runid may only contain"

echo "test: a codex worker with no resolvable git dir fails loud instead of silently not committing"
mkdir -p "$WORK/nogit"
CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" r9 12 standard "$WORK/nogit" base --orchestrator orch-main --dry-run \
    >/dev/null 2>"$WORK/err"
assert_equals "exits 1" "$?" "1"
assert_contains "says why" "$(err)" "git"

# ---------------------------------------------------------------------------
# The PEER form. A peer is a standing role session, not a one-issue worker: it is named
# by its role (the name is the stable address a rotation reuses), carries the charter in
# its system prompt, and is never tier-resolved.
echo "test: spawn.sh peer — a standing role session, not an issue worker"
printf 'You are the swe-manager. Own the build loop.\n' >"$WORK/b.md"
printf 'CHARTER: act within your role without sign-off.\n' >"$WORK/c.md"
peer() { bash "$SPAWN" peer --name swe-manager --brief "$WORK/b.md" --charter "$WORK/c.md" \
              --model opus --effort high --orchestrator orch-main "$@" 2>"$WORK/err"; }
out=$(peer --dry-run)
assert_arg "background" "$out" "--bg"
assert_arg "named by role, no run prefix" "$out" "swe-manager"
assert_arg "model" "$out" "opus"
assert_arg "effort" "$out" "high"
assert_arg "bypassPermissions" "$out" "bypassPermissions"
assert_arg "snapshot off so a rotated peer picks up the current charter" "$out" "--system-prompt-snapshot"
assert_arg "charter is appended to the system prompt" "$out" "--append-system-prompt"
assert_contains "charter text is what is appended" "$out" "CHARTER: act within your role"
assert_arg "autocompact backstop" "$out" "--autocompact"
assert_arg "default window" "$out" "400k"
assert_arg "same denylist as a worker" "$out" "Bash(git merge:*)"
assert_arg "no gh issue close" "$out" "Bash(gh issue close:*)"
assert_contains "the brief is the prompt" "$out" "You are the swe-manager"
assert_contains "report paragraph is mandatory" "$out" "SendMessage"
assert_contains "plain output is invisible" "$out" "INVISIBLE"
assert_contains "addressed to the orchestrator" "$out" '"orch-main"'
assert_not_contains "a peer is not fenced to a worktree" "$out" "--add-dir"

echo "test: a peer's prompt lands after --, like a worker's"
argv=$(PATH="$BIN:$PATH" peer)
sep=$(printf '%s\n' "$argv" | grep -nxF -- "--" | tail -1 | cut -d: -f1)
prompt_line=$(printf '%s\n' "$argv" | grep -n "You are the swe-manager" | head -1 | cut -d: -f1)
if [ -n "$sep" ] && [ -n "$prompt_line" ] && [ "$prompt_line" -eq "$((sep + 1))" ]; then
    ok "peer prompt is the argument immediately after --"
else
    no "peer prompt is not fenced from the variadic deny list (-- at $sep, prompt at $prompt_line)"
fi
assert_contains "peer stdin is closed too" "$argv" "STDIN:[]"

echo "test: --autocompact is overridable"
assert_arg "explicit window" "$(peer --dry-run --autocompact 250k)" "250k"

# Rotation is stop-then-respawn under the same name, so the successor's ONLY link to
# what its predecessor was doing is this doc. Read-it-first has to precede the brief:
# a peer that acts on its standing role before reading the handoff redoes or drops
# whatever was in flight (docs/swarm-design.md § Rotation).
echo "test: a rotated peer reads its handoff BEFORE its brief"
printf 'In flight: issue 41 awaiting review.\n' >"$WORK/h.md"
out=$(peer --dry-run --handoff "$WORK/h.md")
assert_contains "names the handoff path" "$out" "$WORK/h.md"
assert_contains "says read it first" "$out" "FIRST"
h=$(printf '%s\n' "$out" | grep -n "$WORK/h.md"              | head -1 | cut -d: -f1)
b=$(printf '%s\n' "$out" | grep -n "You are the swe-manager" | head -1 | cut -d: -f1)
if [ -n "$h" ] && [ -n "$b" ] && [ "$h" -lt "$b" ]; then
    ok "the handoff instruction precedes the brief"
else
    no "handoff at line $h is not before the brief at line $b"
fi
assert_not_contains "and a fresh peer has no handoff line" "$(peer --dry-run)" "FIRST read your handoff"
bash "$SPAWN" peer --name p --brief "$WORK/b.md" --charter "$WORK/c.md" --model opus \
     --effort high --handoff "$WORK/vanished.md" --dry-run >/dev/null 2>"$WORK/err"
assert_equals "missing handoff file exits 1" "$?" "1"
assert_contains "names the path" "$(err)" "vanished.md"

echo "test: a peer with a missing piece fails loud instead of half-spawning"
bash "$SPAWN" peer --brief "$WORK/b.md" --charter "$WORK/c.md" --model opus --effort high --dry-run >/dev/null 2>"$WORK/err"
assert_equals "no --name exits 1" "$?" "1"; assert_contains "says which" "$(err)" "--name"
bash "$SPAWN" peer --name p --brief "$WORK/nope.md" --charter "$WORK/c.md" --model opus --effort high --dry-run >/dev/null 2>"$WORK/err"
assert_equals "missing brief file exits 1" "$?" "1"; assert_contains "names the path" "$(err)" "nope.md"
bash "$SPAWN" peer --name p --brief "$WORK/b.md" --charter "$WORK/gone.md" --model opus --effort high --dry-run >/dev/null 2>"$WORK/err"
assert_equals "missing charter file exits 1" "$?" "1"
# An empty file is a present file. `-f` waves it through and the peer spawns ungoverned
# (no charter) or task-less (no brief) — the exact failure these checks exist to stop.
# Via dry(), which supplies --orchestrator: without it every spawn exits 1 on the missing
# session name and an exit-code assertion here passes no matter what the file check does.
: >"$WORK/empty.md"
dry peer --name p --brief "$WORK/b.md" --charter "$WORK/empty.md" --model opus --effort high >/dev/null
assert_equals "empty charter file exits 1" "$?" "1"; assert_contains "names the path" "$(err)" "empty.md"
dry peer --name p --brief "$WORK/empty.md" --charter "$WORK/c.md" --model opus --effort high >/dev/null
assert_equals "empty brief file exits 1" "$?" "1"; assert_contains "says it is the brief" "$(err)" "brief"
dry peer --name p --brief "$WORK/b.md" --charter "$WORK/c.md" --model opus --effort high \
    --handoff "$WORK/empty.md" >/dev/null
assert_equals "empty handoff file exits 1" "$?" "1"; assert_contains "says it is the handoff" "$(err)" "handoff"
# And a DIRECTORY is not a file: it has a nonzero size, so `-s` alone waves
# `--charter /some/dir` through, `cat` fails to stderr, and the peer spawns with an
# EMPTY system prompt — the same ungoverned session, by a different door. Both halves.
mkdir -p "$WORK/adir"
dry peer --name p --brief "$WORK/b.md" --charter "$WORK/adir" --model opus --effort high >/dev/null
assert_equals "a directory charter exits 1" "$?" "1"; assert_contains "names the path" "$(err)" "adir"
dry peer --name p --brief "$WORK/adir" --charter "$WORK/c.md" --model opus --effort high >/dev/null
assert_equals "a directory brief exits 1" "$?" "1"; assert_contains "says it is the brief" "$(err)" "brief"
dry peer --name p --brief "$WORK/b.md" --charter "$WORK/c.md" --model opus --effort high \
    --handoff "$WORK/adir" >/dev/null
assert_equals "a directory handoff exits 1" "$?" "1"; assert_contains "says it is the handoff" "$(err)" "handoff"
peer --dry-run --bogus >/dev/null; assert_equals "unknown peer flag exits 1" "$?" "1"
peer --dry-run --name >/dev/null; assert_equals "a flag with no value exits 1" "$?" "1"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
