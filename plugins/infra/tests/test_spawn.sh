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
peer --dry-run --bogus >/dev/null; assert_equals "unknown peer flag exits 1" "$?" "1"
peer --dry-run --name >/dev/null; assert_equals "a flag with no value exits 1" "$?" "1"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
