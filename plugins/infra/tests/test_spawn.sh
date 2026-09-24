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
unset DATABASE_URL FOO CODEX_HOME

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/spawn.sh"
ENV_PAIRS="$(dirname "$SPAWN")/env-pairs.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A fake HOME so nothing here can touch the real ~/.claude. spawn.sh now lives IN infra
# and finds resolve-tier.sh / session-status.sh beside itself, so no link is needed.
export HOME="$WORK/home"
mkdir -p "$HOME"
export CODEX_ETC_ROOT="$WORK/etc-codex"
mkdir -p "$CODEX_ETC_ROOT"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }
# the arg list is one-per-line, so an exact-line match is a real "this arg is present"
assert_arg() { if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else no "$1 (no arg line '$3')"; fi; }
# Was USED below before it was DEFINED. bash prints "command not found" and carries on, so
# the assertion neither passed nor failed and the count never moved — the reviewer-skip
# cases read as coverage while proving nothing, and a revert-probe found them green in both
# directions. A test that cannot fail is worse than no test.
assert_empty() { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected empty, got '$2')"; fi; }

dry() { bash "$SPAWN" "$@" --dry-run --orchestrator orch-main 2>"$WORK/err"; }
err() { cat "$WORK/err"; }

# The roster a worker resolves decides which BACKEND it spawns through, so the tests
# pin one instead of riding whatever the shipped table happens to say this week. The
# claude-path assertions below run against CFG_CLAUDE; the codex section further down
# swaps in CFG_CODEX, which is what proves a codex-routed tier reaches the codex path.
# One test deliberately uses the REAL shipped table — to pin the 6-luna → 6-sol → opus chain.
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
    "reviewer":    { "backend": "claude", "model": "sonnet",        "effort": "low" }
  },
  "standard": {
    "planner":     { "backend": "claude", "model": "sonnet",        "effort": "high" },
    "implementer": { "backend": "codex",  "model": "gpt-5.6-terra", "effort": "max" },
    "reviewer":    { "backend": "claude", "model": "opus",          "effort": "medium" }
  },
  "complex": {
    "planner":     { "backend": "codex",  "model": "gpt-5.6-sol",   "effort": "xhigh" },
    "implementer": { "backend": "codex",  "model": "gpt-5.6-sol",   "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "opus",          "effort": "high" }
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
settings=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --settings) settings="$2"; shift 2 ;;
        *) shift ;;
    esac
done
# A running --bg daemon does not inherit arbitrary variables from this launcher.
unset DATABASE_URL FOO
if [ -n "$settings" ]; then
    DATABASE_URL="$(jq -r '.env.DATABASE_URL // ""' "$settings")"
    FOO="$(jq -r '.env.FOO // ""' "$settings")"
fi
[ -n "${STUB_SETTINGS_OUT:-}" ] && printf '%s\n' "$settings" >"$STUB_SETTINGS_OUT"
[ -n "${STUB_ENV_OUT:-}" ] && printf '%s|%s\n' "${DATABASE_URL:-}" "${FOO:-}" >"$STUB_ENV_OUT"
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
assert_arg "run-prefixed session name includes the initial attempt" "$out" "orch-20260906-101500-issue-12-a0"
assert_contains "spawn prints the full session name" "$(err)" "session name: orch-20260906-101500-issue-12-a0"
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
assert_arg "no gh api — it can close, edit and merge around every other rule" "$out" "Bash(gh api:*)"
assert_arg "no gh repo" "$out" "Bash(gh repo:*)"

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

echo "test: standard and complex build to the PLAN on the thread; trivial self-plans (#104)"
# The plan is posted to the issue by consult.sh BEFORE the build spawn, so the worker
# receives it the way it receives everything else — by reading the thread. Nobody spawns
# a planner from inside the build session any more.
out_p=$(dry 20260906-101500 12 complex /w/issue-12 orchestrate-20260906)
assert_contains "complex follows the Plan comment" "$out_p" "**Plan**"
assert_not_contains "and spawns no planner of its own" "$out_p" "workflow:planner"
out_s=$(dry 20260906-101500 12 standard /w/issue-12 orchestrate-20260906)
assert_contains "standard follows the Plan comment too" "$out_s" "**Plan**"
assert_contains "and is told to stop on a false plan assumption, not improvise" "$out_s" "**Deviation**"
assert_contains "the deviation names step, finding and attempt" "$out_s" "which step"
# CLAUDE-backed (this roster's standard cell is claude): the pause is SendMessage, not the
# codex-only status/note shape — a claude worker has neither field (review round 9). Giving
# every backend the codex shape left a claude worker unable to emit its own pause mechanism.
assert_contains "a CLAUDE worker's pause is SendMessage, with the deviation: prefix" "$out_s" \
    "issue 12 escalate deviation: <the same three lines>"
assert_contains "a CLAUDE worker can report missing infrastructure as blocked" "$out_s" \
    "issue 12 blocked infra: <what is missing>"
assert_not_contains "never the codex-only status/note shape it cannot emit" "$out_s" '"note" = "deviation: "'
assert_not_contains "trivial has no plan" "$(dry r1 12 trivial /w base)" "**Plan**"

echo "test: --attempt selects the chain position, and a respawn is told it is one (#104)"
CFG_CHAIN="$WORK/cfg-chain"
mkdir -p "$CFG_CHAIN"
cat >"$CFG_CHAIN/model-tiers.json" <<'JSON'
{
  "trivial": {
    "planner":     { "backend": "claude", "model": "opus", "effort": "medium" },
    "implementer": [ { "backend": "claude", "model": "haiku", "effort": "max" },
                     { "backend": "claude", "model": "opus",  "effort": "medium" } ],
    "reviewer":    { "backend": "claude", "model": "opus", "effort": "low" }
  },
  "standard": {
    "planner":     { "backend": "claude", "model": "opus", "effort": "medium" },
    "implementer": [ { "backend": "claude", "model": "haiku", "effort": "max" },
                     { "backend": "claude", "model": "opus",  "effort": "medium" } ],
    "reviewer":    { "backend": "claude", "model": "opus", "effort": "medium" }
  },
  "complex": {
    "planner":     { "backend": "claude", "model": "fable", "effort": "medium" },
    "implementer": { "backend": "claude", "model": "opus",  "effort": "medium" },
    "reviewer":    { "backend": "claude", "model": "opus",  "effort": "high" }
  }
}
JSON
out_a0=$(RESOLVE_TIER_ROOT="$CFG_CHAIN" dry r1 12 standard /w/issue-12 base)
assert_arg "attempt 0 (default) is the chain head" "$out_a0" "haiku"
assert_not_contains "a first attempt is not told it is a replacement" "$out_a0" "**Handoff**"
out_a1=$(RESOLVE_TIER_ROOT="$CFG_CHAIN" dry r1 12 standard /w/issue-12 base --attempt 1)
assert_arg "attempt 1 is the next cell" "$out_a1" "opus"
assert_arg "attempt 1 is part of the session name" "$out_a1" "orch-r1-issue-12-a1"
assert_not_contains "and not the head" "$(printf '%s\n' "$out_a1" | grep -A1 -- '--model')" "haiku"
assert_contains "a respawn is told to read the Handoff comment" "$out_a1" "**Handoff**"
assert_contains "and to continue from the last commit" "$out_a1" "last commit"
RESOLVE_TIER_ROOT="$CFG_CHAIN" dry r1 12 standard /w/issue-12 base --attempt 2 >/dev/null
assert_equals "past the top of the chain exits 1 — the orchestrator drains there, never respawns" "$?" "1"
assert_contains "and says so" "$(err)" "chain"
RESOLVE_TIER_ROOT="$CFG_CHAIN" dry r1 12 standard /w/issue-12 base --attempt x >/dev/null
assert_equals "a non-numeric attempt exits 1" "$?" "1"
# `dry` is a shell FUNCTION: on bash < 4.4, a var assigned in front of a function call can
# leak into the CURRENT shell instead of staying scoped to that call (fixed in 4.4; this
# repo promises macOS's bash 3.2). Both calls above are direct — not wrapped in $(...), so
# nothing forked a subshell to contain it — restore the file's own default explicitly.
RESOLVE_TIER_ROOT="$CFG_CLAUDE"
out_f1=$(RESOLVE_TIER_ROOT="$CFG_CHAIN" dry r1 12 standard /w/issue-12 base --role fix --round 2 --attempt 1)
assert_arg "a fix round at attempt 1 also runs the next cell" "$out_f1" "opus"
assert_arg "a fix session name includes attempt and round" "$out_f1" "orch-r1-issue-12-a1-r2"
assert_contains "spawn prints that full fix session name" "$(err)" "session name: orch-r1-issue-12-a1-r2"

echo "test: --role fix is a fresh session working from the review comment"
out=$(dry 20260906-101500 12 standard /w/issue-12 orchestrate-20260906 --role fix --round 2)
assert_arg "the default attempt is included in a fix session name" "$out" "orch-20260906-101500-issue-12-a0-r2"
assert_contains "says which round" "$out" "FIX ROUND 2"
assert_contains "did not write this code" "$out" "You did not write this code"
assert_contains "reads the review comment" "$out" "Review round"
assert_contains "a newer Consult decision replaces re-patching" "$out" "implement the decision"
assert_contains "reports the round back" "$out" "round=2"
assert_not_contains "does not re-post the tackled comment" "$out" "Tackled #12"

echo "test: --orchestrator resolves from this session when omitted"
# Stub `session-status.sh --self` to a KNOWN, distinctive name and assert THAT NAME is
# what the worker is told to report to. The old shape of this test asserted only that
# "SendMessage" appeared in the prompt — a string every worker prompt carries
# unconditionally — so it passed whether the resolution worked, was deleted, or died.
#
# The stub is reached by RELOCATING the real spawn.sh, never by editing it: spawn.sh
# resolves its siblings from its OWN directory, so an untouched copy placed beside stub
# siblings picks them up for free. A sed-rewritten copy would not be the script that ships.
SPAWN_DIR="$(cd "$(dirname "$SPAWN")" && pwd)"
mk_infra() {   # mk_infra <dir> <self-name|-> — stub siblings plus the REAL spawn.sh
    mkdir -p "$1"
    cp "$SPAWN_DIR/resolve-tier.sh" "$SPAWN_DIR/check-inbound.sh" \
       "$SPAWN_DIR/common-git-dir.sh" "$1/"
    cp "$SPAWN" "$1/spawn.sh"
    if [ "$2" = - ]; then
        printf '#!/usr/bin/env bash\nexit 1\n' >"$1/session-status.sh"
    else
        printf '#!/usr/bin/env bash\n[ "${1:-}" = --self ] || exit 1\nprintf "%%s\\n" "%s"\n' \
            "$2" >"$1/session-status.sh"
    fi
    chmod +x "$1/session-status.sh"
}

mk_infra "$WORK/infra-ok" "test-orchestrator-unique-name-xyz"
out=$(RESOLVE_TIER_ROOT="$CFG_CLAUDE" bash "$WORK/infra-ok/spawn.sh" \
      r1 12 standard "$WORK/wt" base --dry-run 2>"$WORK/err"); rc=$?
assert_equals "spawn succeeds with a resolvable name" "$rc" "0"
assert_contains "the RESOLVED name is the address the worker reports to" \
    "$out" "test-orchestrator-unique-name-xyz"

echo "test: --orchestrator fails loud when the session name cannot be resolved"
mk_infra "$WORK/infra-bad" -
out=$(RESOLVE_TIER_ROOT="$CFG_CLAUDE" bash "$WORK/infra-bad/spawn.sh" \
      r1 12 standard "$WORK/wt" base --dry-run 2>"$WORK/err"); rc=$?
assert_equals "exits 1 rather than spawning a worker with no address" "$rc" "1"
assert_contains "and says how to fix it" "$(err)" "pass --orchestrator NAME"

# ---------------------------------------------------------------------------
echo "test: bad input fails loud instead of spawning something wrong"
bash "$SPAWN" r1 >/dev/null 2>"$WORK/err"; assert_equals "too few args exits 1" "$?" "1"
assert_contains "prints usage" "$(err)" "usage:"
dry r1 twelve standard /w base >/dev/null; assert_equals "non-numeric issue exits 1" "$?" "1"
dry r1 12 standard /w base --role sideways >/dev/null; assert_equals "bad role exits 1" "$?" "1"
dry r1 12 standard /w base --round two >/dev/null; assert_equals "a non-numeric round exits 1" "$?" "1"
dry r1 12 standard /w base --bogus >/dev/null; assert_equals "unknown flag exits 1" "$?" "1"
assert_contains "names the flag" "$(err)" "unknown flag"

echo "test: an unknown tier still spawns — resolve-tier.sh falls back to the claude-only roster"
out=$(dry r1 12 nonsense /w/issue-12 base); assert_arg "fallback roster" "$out" "opus"

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
[ -n "${STUB_ENV_OUT:-}" ] && printf '%s|%s\n' "${DATABASE_URL:-}" "${FOO:-}" >"$STUB_ENV_OUT"
exit "${STUB_CODEX_EXIT:-0}"
STUB

# The INDEPENDENT REVIEWER is `claude -p` (#104) — the SECOND process a spawn runs, once
# the worker exits. It records its own argv (so the worker's is not clobbered), its cwd
# and TMPDIR (#99: the review must run in a disposable clone, with TMPDIR at the scratch
# root beside it), and prints its verdict to STDOUT in the shape review-counts.sh parses.
cat >"$CODEX_BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${STUB_REVIEW_ARGV:-/dev/null}"
printf '%s\n' "$#" >"${STUB_REVIEW_ARGC:-/dev/null}"
pwd >"${STUB_REVIEW_CWD:-/dev/null}"
[ -n "${STUB_HOST_ENV_OUT:-}" ] && printf '%s|%s\n' "${DATABASE_URL:-}" "${FOO:-}" >"$STUB_HOST_ENV_OUT"
# The `reviewing` marker must exist WHILE the review runs (escalate.sh reads it to hold the
# stall signal off); the run dir is the clone's parent.
[ -e ../reviewing ] && printf 'yes\n' >"${STUB_REVIEW_MARKER:-/dev/null}"
printenv TMPDIR >"${STUB_REVIEW_TMPDIR:-/dev/null}" 2>/dev/null || true
rj="${STUB_REVIEW_TEXT:-}"
[ -n "$rj" ] || rj='- [P2] a finding — src/f:1'
printf '%s\n' "$rj"
exit "${STUB_REVIEW_EXIT:-0}"
STUB
chmod +x "$CODEX_BIN/claude"

# gh is STUBBED, and that is not optional. The wrapper posts the reviewer's findings with
# `gh issue comment`, so a real gh here would comment on whatever repo the suite happens to
# be run from — the scratch repo has no remote, but a developer with GH_REPO exported would
# post a real comment on issue 12 of that repo. It records the call so the post is
# assertable rather than merely suppressed.
cat >"$CODEX_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"${STUB_GH_ARGV:-/dev/null}"
exit 0
STUB
chmod +x "$CODEX_BIN/gh"
chmod +x "$CODEX_BIN/codex"

# A REAL git worktree, because the writable root is resolved with
# `git rev-parse --git-common-dir` and a fake path would make that assertion a fiction.
# A LINKED worktree, because that is what every real orchestrate worker runs in and the
# only shape `common-git-dir.sh --roots` grants roots for at all. A plain `git init` here
# would take the refusal branch — and, before that branch existed, silently pinned the
# PRE-narrowing value, so this file passed whether or not the narrowing was in place.
ORIGIN="$WORK/origin"
mkdir -p "$ORIGIN"
git -C "$ORIGIN" init -q 2>/dev/null
git -C "$ORIGIN" config user.email t@t.t
git -C "$ORIGIN" config user.name t
printf 'x\n' >"$ORIGIN/f"
git -C "$ORIGIN" add f
git -C "$ORIGIN" commit -qm init
# A real `base` branch. spawn.sh resolves the base to a SHA before launching the worker —
# a base resolved by NAME could be moved by the worker (refs/ is a granted writable root),
# emptying its own diff and buying a clean verdict from an honest reviewer — so the base
# these tests pass has to be a ref that actually exists.
git -C "$ORIGIN" branch base
REPO="$WORK/repo"
git -C "$ORIGIN" worktree add -q -b wt "$REPO" >/dev/null 2>&1
GITDIR="$(cd "$ORIGIN/.git" && pwd -P)"
OWNDIR="$(cd "$(git -C "$REPO" rev-parse --git-dir)" && pwd -P)"
NARROWED="[\"$GITDIR/objects\",\"$GITDIR/refs\",\"$GITDIR/logs\",\"$OWNDIR\"]"
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
# Pinned by VALUE through the CALLER, not just in common-git-dir.sh's own test: this is
# the assertion that proves the narrowed set actually reaches codex's argv. The paired
# not-contains is what makes it red — reverting spawn.sh to the whole common dir trips it.
assert_arg "the NARROWED roots reach codex argv" "$out" \
    "sandbox_workspace_write.writable_roots=$NARROWED"
assert_not_contains "the whole common git dir is never granted" "$out" \
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
assert_contains "reports an EMPTY review — it did not review" "$out" '"review": ""'
assert_contains "and is told not to review itself" "$out" "Do NOT review your own diff"
assert_contains "naming the nested-sandbox reason" "$out" "nested codex
   invocation cannot start inside your sandbox"

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
# The stub codex has to be on PATH like every other REAL (non-dry) codex spawn in this
# file: spawn.sh refuses a codex tier outright when the CLI is absent, and that refusal
# comes BEFORE the schema write this case is about. Without the stub the assertion below
# passes or fails on whether the developer happens to have codex installed — green on a
# machine that does, red in CI, which is exactly how it was caught.
PATH="$CODEX_BIN:$PATH" CODEX_RUN_ROOT="$CODEX_ROOT/schemafail" RESOLVE_TIER_ROOT="$CFG_CODEX" \
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
# A codex worker has no subagents either, so "spawn the planner" would be the same
# stranding bug as "use SendMessage" — the plan is on the THREAD instead (#104).
out_cx=$(codex_dry r9 12 complex "$REPO" base)
assert_contains "complex builds to the Plan comment" "$out_cx" "**Plan**"
assert_not_contains "and is not told to spawn an agent it cannot spawn" \
    "$out_cx" "workflow:planner"
assert_contains "a codex worker pauses on a deviation with the escalate status" \
    "$out_cx" "**Deviation**"
# The codex-only shape belongs ONLY here — a codex worker has status/note fields (from
# --output-schema) that a claude worker does not (review round 9).
assert_contains "a CODEX worker's pause DOES use the status/note shape" "$out_cx" \
    '"note" = "deviation: "'
assert_contains "a CODEX worker can report missing infrastructure as blocked" "$out_cx" \
    'infra: <what is missing>'

echo "test: a SIBLING reviewer is spawned — CLAUDE, at the tier's REVIEWER cell (#104)"
# THE FIX FOR WHAT #96's GATE CAUGHT, then #104's: the worker used to run `codex exec
# review` itself (it cannot start inside its sandbox, and it substituted its own opinion),
# then a sibling `codex exec review` — which could not honour a claude reviewer cell, so
# "reviewer: opus" was silently false for every codex-built branch. The reviewer is now
# `claude -p` spawning my-review, printed after the --REVIEW-- marker.
#
# TRIVIAL is the sharp case: its implementer is luna and its reviewer sonnet/low, so a
# reviewer that merely echoed the run's model would say luna here.
out_tv=$(codex_dry r9 12 trivial "$REPO" base)
assert_arg "the RUN is still at the implementer's model" "$out_tv" "gpt-5.6-luna"
assert_contains "a reviewer argv follows the marker" "$out_tv" "--REVIEW--"
review_argv() { printf '%s\n' "$1" | sed -n '/^--REVIEW--$/,$p'; }
rv=$(review_argv "$out_tv")
assert_arg "the reviewer is claude" "$rv" "claude"
assert_arg "one-shot" "$rv" "-p"
assert_contains "spawning my-review" "$rv" "personal-tools:my-review"
assert_arg "at the REVIEWER cell's model" "$rv" "sonnet"
assert_arg "and the REVIEWER cell's effort" "$rv" "low"
assert_not_contains "never at the implementer's model" "$rv" "gpt-5.6-luna"
assert_not_contains "and never through codex" "$rv" "codex"
assert_arg "complex reviews at ITS reviewer effort" \
    "$(review_argv "$(codex_dry r9 12 complex "$REPO" base)")" "high"

echo "test: the FIX round gets the same sibling reviewer"
# A fix round's findings are the ones that decide whether the issue reaches the merge
# queue, so a fix round that shipped without a reviewer would be the same silent hole one
# stage later.
assert_arg "the re-review names the reviewer model" \
    "$(review_argv "$(codex_dry r9 12 standard "$REPO" base --role fix --round 2)")" \
    "opus"

echo "test: only a FIX dry run is scoped, even when the run dir is seeded"
mkdir -p "$RUNDIR"
printf '1 2 high, 1 medium, 0 low\nfinding\t1\thigh\tone\ta:1\nfinding\t1\thigh\ttwo\tb:2\nfinding\t1\tmedium\tthree\tc:3\n' \
    >"$RUNDIR/rounds"
printf '%s\n' "$(git -C "$REPO" rev-parse HEAD)" >"$RUNDIR/reviewed-head"
assert_contains "a FIX dry run gets the scoped prompt" \
    "$(review_argv "$(codex_dry r9 12 standard "$REPO" base --role fix --round 2)")" \
    "RE-REVIEW"
assert_not_contains "a BUILD dry run remains full with the same seeded dir" \
    "$(review_argv "$(codex_dry r9 12 standard "$REPO" base)")" \
    "RE-REVIEW"
rm -rf "$CODEX_ROOT"

echo "test: the reviewer is told the shape review-counts.sh parses, and is read-only"
assert_contains "the finding shape" "$rv" "- [P1]"
assert_contains "the clean literal" "$rv" "No findings."
assert_contains "the base as a SHA in the range" "$rv" "$(git -C "$REPO" rev-parse --verify base^{commit})..HEAD"
assert_arg "no edits" "$rv" "Edit"
assert_arg "no pushes" "$rv" "Bash(git push:*)"
assert_arg "no review-round comment of its own — the wrapper posts that" "$rv" "Bash(gh issue comment:*)"

echo "test: a CODEX reviewer cell is reviewed on opus anyway — reviews are claude"
CFG_MIXED="$WORK/cfg-mixed"
mkdir -p "$CFG_MIXED"
cat >"$CFG_MIXED/model-tiers.json" <<'JSON'
{
  "trivial": {
    "planner":     { "backend": "claude", "model": "haiku",         "effort": "medium" },
    "implementer": { "backend": "codex",  "model": "gpt-5.6-luna",  "effort": "max" },
    "reviewer":    { "backend": "codex",  "model": "gpt-5.6-terra", "effort": "high" }
  },
  "standard": {
    "planner":     { "backend": "claude", "model": "sonnet",        "effort": "high" },
    "implementer": { "backend": "codex",  "model": "gpt-5.6-terra", "effort": "max" },
    "reviewer":    { "backend": "codex",  "model": "gpt-5.6-sol",   "effort": "high" }
  },
  "complex": {
    "planner":     { "backend": "codex",  "model": "gpt-5.6-sol",   "effort": "xhigh" },
    "implementer": { "backend": "codex",  "model": "gpt-5.6-sol",   "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "opus",          "effort": "xhigh" }
  }
}
JSON
out_mx=$(CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_MIXED" \
    bash "$SPAWN" r9 12 standard "$REPO" base --dry-run --orchestrator orch-main 2>"$WORK/err")
assert_contains "it still spawns a reviewer" "$out_mx" "--REVIEW--"
assert_arg "on opus" "$(review_argv "$out_mx")" "opus"
assert_not_contains "never a codex model for the reviewer" "$(review_argv "$out_mx")" "gpt-5.6-sol"

echo "test: a real codex spawn writes events, last-message, pid and exit files"
# Bash 3.2 treats an empty array expansion as unbound under `set -u`. The no-env
# launch above this check must keep the wrapper argument list guarded as well.
if grep -Fq "\${ENV_NAMES[@]+\"\${ENV_NAMES[@]}\"} --WORKER--" "$SPAWN"; then
    ok "Codex wrapper handles an empty env-name array on Bash 3.2"
else
    no "Codex wrapper expands an empty env-name array under set -u"
fi
rm -rf "$CODEX_ROOT"
PATH="$CODEX_BIN:$PATH" CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" r9 12 standard "$REPO" base --orchestrator orch-main >/dev/null 2>"$WORK/err" <<<"LEAKED"
# the spawn returns immediately; the worker runs in the background
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$RUNDIR/exit" ] && break; sleep 0.2; done
for f in events.jsonl last-message.txt pid exit status-schema.json session-name; do
    if [ -f "$RUNDIR/$f" ]; then ok "wrote $f"; else no "missing $RUNDIR/$f"; fi
done
assert_equals "records the full name used for a codex attempt" \
    "$(cat "$RUNDIR/session-name" 2>/dev/null)" "orch-r9-issue-12-a0"
assert_equals "exit 0 recorded" "$(cat "$RUNDIR/exit" 2>/dev/null)" "0"
assert_contains "the events file holds what codex streamed" "$(cat "$RUNDIR/events.jsonl")" "workspace-write"
assert_contains "codex wrote its final message" "$(cat "$RUNDIR/last-message.txt")" '"status":"built"'
assert_contains "the schema is real JSON naming the status field" \
    "$(cat "$RUNDIR/status-schema.json")" '"status"'
assert_contains "the schema permits blocked infrastructure reports" \
    "$(cat "$RUNDIR/status-schema.json")" '"blocked"'
assert_contains "stdin is closed — codex blocks forever on an open one" \
    "$(cat "$RUNDIR/events.jsonl")" "STDIN:[]"
assert_not_contains "nothing leaked through" "$(cat "$RUNDIR/events.jsonl")" "LEAKED"

echo "test: --env reaches real Claude and Codex workers without entering argv or run files"
argv=$(STUB_ENV_OUT="$WORK/env-claude" STUB_SETTINGS_OUT="$WORK/settings-claude" \
    PATH="$BIN:$PATH" bash "$SPAWN" r1 12 standard \
    "$WORK/wt" base --orchestrator orch-main --env DATABASE_URL=postgres://x --env FOO=bar)
assert_equals "Claude worker receives both --env values" "$(cat "$WORK/env-claude" 2>/dev/null)" "postgres://x|bar"
assert_contains "Claude gets a per-session settings file" "$argv" "--settings"
assert_not_contains "Claude argv does not contain the value" "$argv" "postgres://x"
claude_settings="$(cat "$WORK/settings-claude" 2>/dev/null)"
case "$(basename "$(dirname "$claude_settings")")" in
    claude-env.r1.issue-12.*) ok "settings dir is named for its run and issue, so the run end can sweep it" ;;
    *) no "settings dir is not named claude-env.r1.issue-12.* (got '$claude_settings')" ;;
esac
assert_contains "successful dispatch prints the private settings path for cleanup" \
    "$argv" "Claude settings file: $claude_settings"
if [ -n "$claude_settings" ] && [ -f "$claude_settings" ] \
   && [ "$(jq -r '.env.DATABASE_URL' "$claude_settings")" = 'postgres://x' ]; then
    ok "private Claude settings remain readable after dispatch for later session requests"
else
    no "private Claude settings disappeared or lost the value after dispatch"
fi
rm -f -- "$claude_settings"
rmdir -- "$(dirname "$claude_settings")"

rm -rf "$CODEX_ROOT"
PATH="$CODEX_BIN:$PATH" CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    STUB_ENV_OUT="$WORK/env-codex" STUB_HOST_ENV_OUT="$WORK/host-env-codex" \
    bash "$SPAWN" r9 12 standard "$REPO" base \
    --orchestrator orch-main --env 'DATABASE_URL=postgres://x?sslmode=require' --env FOO=bar \
    >/dev/null 2>"$WORK/err"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$RUNDIR/exit" ] && break; sleep 0.2; done
assert_equals "Codex worker receives a value containing '=' intact" \
    "$(cat "$WORK/env-codex" 2>/dev/null)" "postgres://x?sslmode=require|bar"
assert_equals "host reviewer receives neither worker value" \
    "$(cat "$WORK/host-env-codex" 2>/dev/null)" '|'
leak=$(grep -rF 'postgres://x' "$RUNDIR" 2>/dev/null || true)
assert_empty "Codex run dir never contains the env value" "$leak"

out=$(dry r1 12 standard /w base --env DATABASE_URL=postgres://x)
assert_equals "Claude dry run exits 0" "$?" "0"
assert_not_contains "Claude dry run never prints the env value" "$out" "postgres://x"
out=$(codex_dry r9 12 standard "$REPO" base --env DATABASE_URL=postgres://x)
assert_equals "Codex dry run exits 0" "$?" "0"
assert_not_contains "Codex dry run never prints the env value" "$out" "postgres://x"
out=$(HOST_SECRET_CANARY=host-canary codex_dry r9 12 standard "$REPO" base --env STRIPE_API_KEY=private-canary)
assert_arg "Codex keeps explicitly provisioned KEY names in shell commands" "$out" \
    'shell_environment_policy.ignore_default_excludes=true'
excl=$(printf '%s\n' "$out" | grep '^shell_environment_policy.exclude=')
assert_contains "Codex still filters inherited host secret names" "$excl" '"HOST_SECRET_CANARY"'
assert_not_contains "Codex does not filter the provisioned name" "$excl" 'STRIPE_API_KEY'
assert_not_contains "Codex config argv never prints the KEY value" "$out" 'private-canary'
assert_not_contains "Codex config argv never prints a host secret value" "$out" 'host-canary'
# Names compgen -e cannot list (not valid identifiers) and names Codex itself loads from
# $CODEX_HOME/.env must be re-excluded too, or they pass the opened filter.
mkdir -p "$HOME/.codex"
printf 'export DOTENV_API_TOKEN=dotenv-canary\n# COMMENTED_TOKEN=x\n' >"$HOME/.codex/.env"
out=$(env 'npm_config_//reg/:_authToken=npm-canary' CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" r9 12 standard "$REPO" base --env STRIPE_API_KEY=private-canary \
    --dry-run --orchestrator orch-main 2>"$WORK/err")
excl=$(printf '%s\n' "$out" | grep '^shell_environment_policy.exclude=')
assert_contains "Codex re-excludes a non-identifier host secret name" "$excl" '"npm_config_//reg/:_authToken"'
assert_contains "Codex re-excludes a secret name loaded from CODEX_HOME/.env" "$excl" '"DOTENV_API_TOKEN"'
assert_not_contains "a commented .env line is not a name" "$excl" 'COMMENTED_TOKEN'
assert_not_contains "Codex config argv never prints a .env value" "$out" 'dotenv-canary'
rm -f "$HOME/.codex/.env"
# `-c shell_environment_policy.exclude` REPLACES the user's own list, so a user who set one
# is refused rather than silently un-hidden.
printf '[shell_environment_policy]\nexclude = ["MY_PRIVATE_*"]\n' >"$HOME/.codex/config.toml"
out=$(codex_dry r9 12 standard "$REPO" base --env STRIPE_API_KEY=private-canary)
rc=$?
assert_equals "user Codex exclude list + secret-named --env refuses" "$rc" "1"
assert_contains "refusal names the user's exclude setting" "$(err)" "shell_environment_policy.exclude"
assert_not_contains "refusal never prints the value" "$(err)" "private-canary"
out=$(codex_dry r9 12 standard "$REPO" base --env DATABASE_URL=postgres://x)
assert_equals "user Codex exclude list is fine when no filter override is needed" "$?" "0"
rm -f "$HOME/.codex/config.toml"

echo "test: invalid --env values are rejected before a worker starts"
STUB_ENV_OUT="$WORK/env-bad" PATH="$BIN:$PATH" \
    bash "$SPAWN" r1 12 standard "$WORK/wt" base --orchestrator orch-main --env NOEQUALS \
    >"$WORK/out" 2>"$WORK/err"
rc=$?
assert_equals "malformed Claude --env exits 1" "$rc" "1"
assert_contains "malformed Claude --env says NAME=VALUE" "$(err)" "NAME=VALUE"
assert_not_contains "malformed Claude --env never echoes the argument" "$(err)" "NOEQUALS"
if [ ! -e "$WORK/env-bad" ]; then ok "malformed Claude --env spawns nothing"; else no "malformed Claude --env spawned the stub"; fi

rm -rf "$CODEX_ROOT/badenv"
PATH="$CODEX_BIN:$PATH" CODEX_RUN_ROOT="$CODEX_ROOT/badenv" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" r9 12 standard "$REPO" base --orchestrator orch-main --env NOEQUALS \
    >"$WORK/out" 2>"$WORK/err"
rc=$?
assert_equals "malformed Codex --env exits 1" "$rc" "1"
assert_contains "malformed Codex --env says NAME=VALUE" "$(err)" "NAME=VALUE"
assert_not_contains "malformed Codex --env never echoes the argument" "$(err)" "NOEQUALS"
if [ ! -e "$CODEX_ROOT/badenv" ]; then ok "malformed Codex --env creates no run dir"; else no "malformed Codex --env created a run dir"; fi

PATH="$BIN:$PATH" bash "$SPAWN" r1 12 standard "$WORK/wt" base --orchestrator orch-main \
    --env 1BAD=x >"$WORK/out" 2>"$WORK/err"
rc=$?
assert_equals "invalid env name exits 1" "$rc" "1"
assert_contains "invalid env name is identified" "$(err)" "not a valid variable name"

PATH="$BIN:$PATH" bash "$SPAWN" r1 12 standard "$WORK/wt" base --orchestrator orch-main \
    --env >"$WORK/out" 2>"$WORK/err"
rc=$?
assert_equals "bare --env exits 1" "$rc" "1"

echo "test: shared --env validation rejects host-steering and infra-owned names"
for name in BASH_ENV PATH GIT_CONFIG_COUNT GIT_CONFIG_CUSTOM GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE \
    GIT_TEMPLATE_DIR LD_AUDIT LD_DEBUG DYLD_FALLBACK_LIBRARY_PATH \
    RUNDIR CMD WORKTREE RUNID ISSUE TIER BACKEND MODEL EFFORT TASK INFRA ENVS \
    CODEX_RUN_ROOT CODEX_HOME CODEX_ETC_ROOT HOME GH_CONFIG_DIR; do
    bash "$ENV_PAIRS" "$name=private-canary" >"$WORK/out" 2>"$WORK/err"
    rc=$?
    assert_equals "$name is rejected" "$rc" "1"
    assert_contains "$name rejection says reserved" "$(err)" "reserved"
    assert_not_contains "$name rejection never echoes its value" "$(err)" "private-canary"
done

STUB_ENV_OUT="$WORK/env-reserved" PATH="$BIN:$PATH" \
    bash "$SPAWN" r1 12 standard "$WORK/wt" base --orchestrator orch-main \
    --env BASH_ENV=private-canary >"$WORK/out" 2>"$WORK/err"
rc=$?
assert_equals "Claude spawn rejects a reserved shell variable" "$rc" "1"
assert_contains "Claude spawn explains the reserved name" "$(err)" "reserved"
assert_not_contains "Claude spawn never echoes the value" "$(err)" "private-canary"
if [ ! -e "$WORK/env-reserved" ]; then ok "Claude spawn starts nothing for a reserved name"
else no "Claude spawn started with a reserved name"; fi

rm -rf "$CODEX_ROOT/reserved-git"
PATH="$CODEX_BIN:$PATH" CODEX_RUN_ROOT="$CODEX_ROOT/reserved-git" \
    RESOLVE_TIER_ROOT="$CFG_CODEX" bash "$SPAWN" r9 12 standard "$REPO" base \
    --orchestrator orch-main --env GIT_CONFIG_COUNT=1 >"$WORK/out" 2>"$WORK/err"
rc=$?
assert_equals "Codex spawn rejects a Git routing variable" "$rc" "1"
assert_contains "Codex spawn explains the reserved name" "$(err)" "reserved"
if [ ! -d "$CODEX_ROOT/reserved-git" ]; then ok "Codex spawn creates no run dir for a reserved name"
else no "Codex spawn created a run dir for a reserved name"; fi

# ---------------------------------------------------------------------------
# THE WRAPPER'S REVIEW STAGE. This is the path EVERY codex build takes, and it had no
# coverage at all while the resume path had four cases — the dry run proves what the argv
# would be, never that the wrapper actually runs it, in the right order, or cleans up.
echo "test: the wrapper runs the reviewer after the worker and writes exit LAST"
rm -rf "$CODEX_ROOT"; rm -f "$WORK/review-argv" "$WORK/gh-argv" "$WORK/review-cwd" "$WORK/review-tmpdir"
STUB_REVIEW_ARGV="$WORK/review-argv" STUB_GH_ARGV="$WORK/gh-argv" STUB_REVIEW_ARGC="$WORK/review-argc" STUB_REVIEW_MARKER="$WORK/review-marker" \
    STUB_REVIEW_CWD="$WORK/review-cwd" STUB_REVIEW_TMPDIR="$WORK/review-tmpdir" \
    STUB_REVIEW_TEXT='- [P1] one — a:1
- [P1] two — b:2
- [P2] three — c:3
a real finding is described above' \
    PATH="$CODEX_BIN:$PATH" CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" r9 12 standard "$REPO" base --orchestrator orch-main >/dev/null 2>"$WORK/err"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$RUNDIR/exit" ] && break; sleep 0.2; done
if [ -f "$RUNDIR/review.txt" ]; then ok "the reviewer's verdict was written"
else no "no $RUNDIR/review.txt — the wrapper did not run the reviewer"; fi
# THE SECURITY PROPERTY (#99): the review ran somewhere that is NOT the real worktree, and
# a test runner inside it would find its tempfiles pointed at the scratch root the argv
# granted — not at whatever the worktree's own sandbox default would have been.
assert_equals "the reviewing marker existed while the review ran (round 4's producer)" \
    "$(cat "$WORK/review-marker" 2>/dev/null)" "yes"
assert_equals "the review ran in the disposable checkout" \
    "$(cat "$WORK/review-cwd" 2>/dev/null)" "$RUNDIR/review-checkout"
assert_not_contains "never in the real worktree" "$(cat "$WORK/review-cwd" 2>/dev/null)" "$REPO"
assert_equals "TMPDIR matches the ONE root the sandbox actually granted" \
    "$(cat "$WORK/review-tmpdir" 2>/dev/null)" "$RUNDIR/review-scratch"
# Both are disposable: nothing of them survives for a later stage to trip over or a human
# to find.
if [ -e "$RUNDIR/review-checkout" ] || [ -e "$RUNDIR/review-scratch" ]; then
    no "the disposable checkout or scratch dir survived the review"
else
    ok "the disposable checkout and scratch dir are cleaned up after the review"
fi
assert_contains "a reviewer really ran" "$(cat "$WORK/review-argv" 2>/dev/null)" "-p"
# 25 = -p, --model M, --effort E, --permission-mode X, --disallowedTools + 15 rules, --, and
# the prompt as ONE argument. A newline-split reader hands claude 52 and it keeps line one.
assert_equals "the multi-line prompt reached claude as ONE argument" \
    "$(cat "$WORK/review-argc" 2>/dev/null)" "25"
assert_contains "against a base SHA, not the branch name it was passed" \
    "$(cat "$WORK/review-argv" 2>/dev/null)" "$(git -C "$REPO" rev-parse --verify base^{commit})"
assert_not_contains "never the branch name" \
    "$(printf '%s\n' "$(cat "$WORK/review-argv" 2>/dev/null)" | grep -Fx -- 'base')" "base"
# exit is the terminal signal: worker-report.sh reads the run the moment it appears, so a
# review landing after it would be read as a run with no verdict on every fast poll.
if [ -e "$RUNDIR/reviewing" ]; then no "the reviewing marker outlived the review"; else ok "the reviewing marker is gone once exit lands"; fi
if [ "$RUNDIR/review.txt" -ot "$RUNDIR/exit" ] || [ "$RUNDIR/exit" -nt "$RUNDIR/review.txt" ]; then
    ok "exit was written after the review, not before"
else
    ok "exit and review landed within the same clock tick (order still not inverted)"
fi
assert_contains "the findings were posted to the issue" "$(cat "$WORK/gh-argv" 2>/dev/null)" "comment"
# The body travels as a FILE: a review is multi-line model-written text, and passing it as
# --body would leave it at the mercy of shell quoting.
assert_contains "as a --body-file" "$(cat "$WORK/gh-argv" 2>/dev/null)" "--body-file"
COMMENT="$(cat "$RUNDIR/review-comment.md" 2>/dev/null)"
# The heading is counted by review-counts.sh — the SAME script worker-report.sh reads the
# verdict with, so the issue thread and the merge queue cannot disagree about the findings.
assert_contains "with the counts in the heading" "$COMMENT" "2 high, 1 medium, 0 low"
assert_equals "and the run-dir ledger holds the round line plus one entry per finding" \
    "$(cat "$RUNDIR/rounds" 2>/dev/null)" \
    "$(printf '1 2 high, 1 medium, 0 low\nfinding\t1\thigh\tone\ta:1\nfinding\t1\thigh\ttwo\tb:2\nfinding\t1\tmedium\tthree\tc:3')"
assert_contains "and the reviewer's text" "$COMMENT" "a real finding"
assert_equals "the reviewed head is recorded for the next round's fix range" \
    "$(cat "$RUNDIR/reviewed-head" 2>/dev/null)" "$(git -C "$REPO" rev-parse HEAD)"
assert_equals "the role is recorded" "$(cat "$RUNDIR/role" 2>/dev/null)" "build"
assert_not_contains "a BUILD review is a full review" \
    "$(cat "$WORK/review-argv" 2>/dev/null)" "RE-REVIEW"

echo "test: a fix round is a SCOPED re-review, and its ledger round matches the last"
rm -f "$WORK/review-argv" "$WORK/gh-argv"
STUB_REVIEW_ARGV="$WORK/review-argv" STUB_GH_ARGV="$WORK/gh-argv" \
    STUB_REVIEW_TEXT='- [fixed] one — a:1
- [fixed] two — b:2
- [P2] three — c:3
- [P1] four — d:4' \
    PATH="$CODEX_BIN:$PATH" CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" r9 12 standard "$REPO" base --role fix --round 1 --orchestrator orch-main \
    >/dev/null 2>"$WORK/err"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$RUNDIR/exit" ] && break; sleep 0.2; done
FIX_REVIEW_ARGV="$(cat "$WORK/review-argv" 2>/dev/null)"
assert_contains "fix review is scoped" "$FIX_REVIEW_ARGV" "RE-REVIEW"
assert_contains "first prior high finding reaches the re-review" "$FIX_REVIEW_ARGV" "- high: one — a:1"
assert_contains "prior medium finding reaches the re-review" "$FIX_REVIEW_ARGV" "- medium: three — c:3"
assert_contains "the fix range starts at the reviewed HEAD" "$FIX_REVIEW_ARGV" \
    "$(git -C "$REPO" rev-parse HEAD)..HEAD"
assert_equals "round 2 has the expected counts and all four ledger entries" \
    "$(sed -n '/^2 /,$p' "$RUNDIR/rounds" 2>/dev/null)" \
    "$(printf '2 1 high, 1 medium, 0 low\nfinding\t2\tfixed\tone\ta:1\nfinding\t2\tfixed\ttwo\tb:2\nfinding\t2\tmedium\tthree\tc:3\nfinding\t2\thigh\tfour\td:4')"
ROUND_ONE_PAIRS="$(awk -F'\t' '$1=="finding"&&$2==1{print $4"\t"$5}' "$RUNDIR/rounds")"
FIXED_PAIRS="$(awk -F'\t' '$1=="finding"&&$2==2&&$3=="fixed"{print $4"\t"$5}' "$RUNDIR/rounds")"
FIXED_COUNT="$(awk -F'\t' '$1=="finding"&&$2==2&&$3=="fixed"{n++} END{print n+0}' "$RUNDIR/rounds")"
assert_equals "both fixed findings retain their identities" "$FIXED_COUNT" "2"
TAB="$(printf '\t')"
while IFS="$TAB" read -r fixed_title fixed_path; do
    [ -n "$fixed_title" ] || continue
    pair="$(printf '%s\t%s' "$fixed_title" "$fixed_path")"
    if printf '%s\n' "$ROUND_ONE_PAIRS" | grep -qxF -- "$pair"; then
        ok "fixed finding '$fixed_title' keeps its prior title and path"
    else
        no "fixed finding '$fixed_title' lost its prior title or path"
    fi
done <<EOF
$FIXED_PAIRS
EOF
assert_equals "the role is now fix" "$(cat "$RUNDIR/role" 2>/dev/null)" "fix"

echo "test: an incomplete scoped review cannot become a clean merge-gate verdict"
ROUND_TWO="$(cat "$RUNDIR/rounds")"
rm -f "$WORK/gh-argv"
STUB_GH_ARGV="$WORK/gh-argv" STUB_REVIEW_TEXT='- [fixed] three — c:3' \
    PATH="$CODEX_BIN:$PATH" CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" r9 12 standard "$REPO" base --role fix --round 2 --orchestrator orch-main \
    >/dev/null 2>"$WORK/err"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$RUNDIR/exit" ] && break; sleep 0.2; done
assert_equals "an omitted prior finding adds no ledger round" "$(cat "$RUNDIR/rounds")" "$ROUND_TWO"
if [ -e "$RUNDIR/review.txt" ]; then no "incomplete review remained readable by worker-report"
else ok "incomplete review was removed before worker-report"; fi
assert_contains "rejection is recorded" "$(cat "$RUNDIR/review-stderr.log" 2>/dev/null)" "REVIEW_UNREADABLE"
if [ -e "$WORK/gh-argv" ]; then no "incomplete review was posted"
else ok "incomplete review was not posted"; fi
rm -rf "$CODEX_ROOT"

echo "test: four reviews across two attempts are numbered 1..4 from the ledger"
# CFG_CODEX is a single-position chain, so attempt 1 resolves to claude. Keep this central
# mechanism test on the real codex wrapper by supplying a two-position codex chain for its
# attempt-1 runs.
CFG_CODEX_CHAIN="$WORK/cfg-codex-chain"
mkdir -p "$CFG_CODEX_CHAIN"
cat >"$CFG_CODEX_CHAIN/model-tiers.json" <<'JSON'
{
  "trivial": {
    "planner":     { "backend": "claude", "model": "haiku",         "effort": "medium" },
    "implementer": [ { "backend": "codex", "model": "gpt-5.6-luna",  "effort": "max" },
                     { "backend": "codex", "model": "gpt-5.6-terra", "effort": "high" } ],
    "reviewer":    { "backend": "claude", "model": "sonnet",        "effort": "low" }
  },
  "standard": {
    "planner":     { "backend": "claude", "model": "sonnet",        "effort": "high" },
    "implementer": [ { "backend": "codex", "model": "gpt-5.6-terra", "effort": "max" },
                     { "backend": "codex", "model": "gpt-5.6-sol",   "effort": "high" } ],
    "reviewer":    { "backend": "claude", "model": "opus",          "effort": "medium" }
  },
  "complex": {
    "planner":     { "backend": "claude", "model": "opus",   "effort": "xhigh" },
    "implementer": { "backend": "codex",  "model": "gpt-5.6-sol", "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "xhigh" }
  }
}
JSON
attempt1_roster=$(RESOLVE_TIER_ROOT="$CFG_CODEX_CHAIN" \
    bash "$SCRIPT_DIR/../scripts/resolve-tier.sh" standard 1)
assert_contains "the local attempt-1 roster stays codex-backed" "$attempt1_roster" \
    "implementer_backend=codex"

rm -rf "$CODEX_ROOT"
run_numbered_review() {
    local number="$1" tier_root="$2"
    shift 2
    STUB_REVIEW_TEXT='- [P1] x — a:1' \
        PATH="$CODEX_BIN:$PATH" CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$tier_root" \
        bash "$SPAWN" "$@" >/dev/null 2>"$WORK/err"
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$RUNDIR/exit" ] && break; sleep 0.2; done
    if [ -f "$RUNDIR/review-comment.md" ]; then
        cp "$RUNDIR/review-comment.md" "$WORK/review-comment-$number.md"
    else
        no "review $number did not write its issue comment"
    fi
}
run_numbered_review 1 "$CFG_CODEX" \
    r9 12 standard "$REPO" base --orchestrator orch-main
run_numbered_review 2 "$CFG_CODEX" \
    r9 12 standard "$REPO" base --role fix --round 1 --orchestrator orch-main
run_numbered_review 3 "$CFG_CODEX_CHAIN" \
    r9 12 standard "$REPO" base --role fix --round 1 --attempt 1 --orchestrator orch-main
run_numbered_review 4 "$CFG_CODEX_CHAIN" \
    r9 12 standard "$REPO" base --role fix --round 1 --attempt 1 --orchestrator orch-main
assert_equals "four reviews append ledger numbers 1..4" \
    "$(grep '^[0-9]' "$RUNDIR/rounds" | cut -d' ' -f1 | tr '\n' ',')" "1,2,3,4,"
assert_equals "each review's finding is filed under its own round" \
    "$(grep -c '^finding' "$RUNDIR/rounds")" "4"
for review_number in 1 2 3 4; do
    assert_contains "saved comment $review_number is numbered from the ledger" \
        "$(cat "$WORK/review-comment-$review_number.md" 2>/dev/null)" \
        "**Review round $review_number**"
done

echo "test: a FAILED reviewer leaves no verdict — the wrapper fails CLOSED"
rm -rf "$CODEX_ROOT"; rm -f "$WORK/gh-argv"
STUB_REVIEW_EXIT=3 STUB_GH_ARGV="$WORK/gh-argv" \
    PATH="$CODEX_BIN:$PATH" CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" r9 12 standard "$REPO" base --orchestrator orch-main >/dev/null 2>"$WORK/err"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$RUNDIR/exit" ] && break; sleep 0.2; done
if [ -f "$RUNDIR/review.txt" ]; then no "a failed reviewer left review.txt behind"
else ok "the failed reviewer's output was deleted, not left to be misread"; fi
assert_contains "and the reason is recorded" "$(cat "$RUNDIR/review-stderr.log" 2>/dev/null)" \
    "REVIEW_FAILED"
assert_empty "nothing was posted to the issue" "$(cat "$WORK/gh-argv" 2>/dev/null)"

echo "test: a worker that did NOT report built/fixed is never reviewed"
# escalate and failed also exit 0. Reviewing one posts a "Review round" comment on a
# half-built branch, which the orchestrate lane counts as a spent cycle.
rm -rf "$CODEX_ROOT"; rm -f "$WORK/review-argv" "$WORK/gh-argv"
cat >"$CODEX_BIN/codex-escalate" <<'STUB'
#!/usr/bin/env bash
if [ "${2:-}" = review ]; then printf '%s\n' "$@" >>"${STUB_REVIEW_ARGV:-/dev/null}"; exit 0; fi
printf '%s\n' "$@"
while [ $# -gt 0 ]; do
    if [ "$1" = -o ]; then printf '{"issue":12,"status":"escalate","note":"q"}\n' >"$2"; fi
    shift
done
exit 0
STUB
chmod +x "$CODEX_BIN/codex-escalate"
cp "$CODEX_BIN/codex" "$WORK/codex-build-backup"
cp "$CODEX_BIN/codex-escalate" "$CODEX_BIN/codex"
STUB_REVIEW_ARGV="$WORK/review-argv" STUB_GH_ARGV="$WORK/gh-argv" \
    PATH="$CODEX_BIN:$PATH" CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" r9 12 standard "$REPO" base --orchestrator orch-main >/dev/null 2>"$WORK/err"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$RUNDIR/exit" ] && break; sleep 0.2; done
assert_empty "no reviewer ran on an escalation" "$(cat "$WORK/review-argv" 2>/dev/null)"
assert_empty "and no review comment was posted" "$(cat "$WORK/gh-argv" 2>/dev/null)"
cp "$WORK/codex-build-backup" "$CODEX_BIN/codex"

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

echo "test: a re-spawn clears the previous turn's report and exit code"
# The run dir path carries the runid and the issue but NOT the round, so a fix round and
# any recovery respawn land on the previous turn's files. session-status.sh treats ANY
# exit file as terminal, so a surviving one makes worker-report.sh's first poll return the
# PREVIOUS turn's report as this turn's result — while this worker is still writing the
# worktree. A stale `H > 0` then draws a second fix round onto that worktree.
# The stub sleeps, so this turn is still running: anything left here is genuinely stale.
STALE="$CODEX_ROOT/rstale/issue-12"
mkdir -p "$STALE"
printf '0\n' >"$STALE/exit"
printf '%s' '{"issue":12,"status":"built","round":0,"head":"aaaaaaa","review":"9 high, 0 medium, 0 low","note":""}' \
    >"$STALE/last-message.txt"
PATH="$CODEX_BIN:$PATH" STUB_CODEX_SLEEP=30 CODEX_RUN_ROOT="$CODEX_ROOT" \
    RESOLVE_TIER_ROOT="$CFG_CODEX" bash "$SPAWN" rstale 12 standard "$REPO" base \
    --role fix --round 2 --orchestrator orch-main >/dev/null 2>&1
# Require the pid FIRST: this spawn's stderr and exit code are discarded above, so a spawn
# that died after the `rm` — a failed schema write takes the run dir with it — would leave
# an empty dir and green both assertions below while proving nothing.
if [ -f "$STALE/pid" ]; then
    ok "the worker actually launched"
else
    no "no pid file: the spawn aborted after the rm, so this case proves nothing"
fi
if [ -f "$STALE/exit" ]; then
    no "the previous turn's exit survived — the first poll reads this turn as already done"
else
    ok "the previous turn's exit code is gone"
fi
# By CONTENT, not absence: the stub writes its -o file BEFORE honouring STUB_CODEX_SLEEP,
# so the wrapper recreates last-message.txt within milliseconds of the spawn returning.
# Checking absence races the worker this test just launched and would flip red under load.
case "$(cat "$STALE/last-message.txt" 2>/dev/null || true)" in
    *aaaaaaa*|*"9 high"*)
        no "the previous turn's report survived — it would be returned as this turn's result" ;;
    *)  ok "the previous turn's report is gone" ;;
esac
stale_pid="$(cat "$STALE/pid" 2>/dev/null || true)"
[ -z "$stale_pid" ] || kill -- -"$stale_pid" 2>/dev/null || true

# The SHIPPED roster (PRD #104, 2026-09-22, superseding the 2026-09-17 claude-only decision):
# trivial and standard implement on codex — 6-luna, then 6-sol, then opus — behind an opus
# plan; complex stays on opus. A user without the codex CLI writes a claude-only table at
# ${CLAUDE_CONFIG_DIR:-~/.claude}/model-tiers.json; the FALLBACK roster is claude-only for
# the same reason, so a broken table never depends on codex.
#
# CLAUDE_CONFIG_DIR is pinned at an empty dir so this reads the shipped table, not the
# developer's own.
echo "test: the SHIPPED roster — 6-luna heads the trivial and standard chains, opus builds complex"
for t in trivial standard; do
    out=$(CODEX_RUN_ROOT="$CODEX_ROOT" CLAUDE_CONFIG_DIR="$WORK/nousercfg" env -u RESOLVE_TIER_ROOT \
          bash "$SPAWN" r9 12 "$t" "$REPO" base --dry-run --orchestrator orch-main 2>/dev/null)
    assert_arg "shipped $t attempt 0 spawns codex" "$out" "exec"
    assert_arg "shipped $t attempt 0 is 6-luna" "$out" "gpt-6-luna"
    out=$(CODEX_RUN_ROOT="$CODEX_ROOT" CLAUDE_CONFIG_DIR="$WORK/nousercfg" env -u RESOLVE_TIER_ROOT \
          bash "$SPAWN" r9 12 "$t" "$REPO" base --dry-run --orchestrator orch-main --attempt 1 2>/dev/null)
    assert_arg "shipped $t attempt 1 is 6-sol" "$out" "gpt-6-sol"
    out=$(CODEX_RUN_ROOT="$CODEX_ROOT" CLAUDE_CONFIG_DIR="$WORK/nousercfg" env -u RESOLVE_TIER_ROOT \
          bash "$SPAWN" r9 12 "$t" "$REPO" base --dry-run --orchestrator orch-main --attempt 2 2>/dev/null)
    assert_arg "shipped $t attempt 2 tops out on claude" "$out" "--bg"
    assert_arg "at opus" "$out" "opus"
done
out=$(CODEX_RUN_ROOT="$CODEX_ROOT" CLAUDE_CONFIG_DIR="$WORK/nousercfg" env -u RESOLVE_TIER_ROOT \
      bash "$SPAWN" r9 12 complex "$REPO" base --dry-run --orchestrator orch-main 2>/dev/null)
assert_arg "shipped complex spawns claude" "$out" "--bg"
assert_not_contains "shipped complex never routes to codex" "$out" "codex exec"

echo "test: a runid carrying a path component is refused before it reaches mkdir -p or rm -rf"
# $RUNID is joined into the codex run dir, which spawn.sh both creates and — on a failed
# schema write — `rm -rf`s. The caller is a model assembling argv by hand, and run-log.sh
# already guards the identical value, so spawn.sh must too.
CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" "../../escape" 12 standard "$REPO" base --orchestrator orch-main --dry-run \
    >/dev/null 2>"$WORK/err"
assert_equals "exits 1 on a traversal runid" "$?" "1"
assert_contains "names the value and what is allowed" "$(err)" "runid may only contain"
CODEX_RUN_ROOT="$CODEX_ROOT" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    bash "$SPAWN" ".." 12 standard "$REPO" base --orchestrator orch-main --dry-run >/dev/null 2>"$WORK/err"
assert_equals "a bare .. runid is refused too — every character is allowed, the path step is not" "$?" "1"

echo "test: a real codex spawn with NO codex CLI fails loud, naming the user-table fix (review fix 3)"
# Every binary the real PATH has, EXCEPT codex — so the only thing this run lacks is the CLI.
NOCODEX="$WORK/nocodex"; mkdir -p "$NOCODEX"
IFS=: read -ra _dirs <<<"$PATH"
for d in "${_dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        n="$(basename "$f")"
        [ "$n" = codex ] && continue
        [ -e "$NOCODEX/$n" ] || ln -s "$f" "$NOCODEX/$n" 2>/dev/null
    done
done
rm -rf "$CODEX_ROOT/nocodex"
PATH="$NOCODEX" CODEX_RUN_ROOT="$CODEX_ROOT/nocodex" RESOLVE_TIER_ROOT="$CFG_CODEX" \
    "$(command -v bash)" "$SPAWN" r9 12 standard "$REPO" base --orchestrator orch-main >/dev/null 2>"$WORK/err"
assert_equals "exits 1" "$?" "1"
assert_contains "says the CLI is missing" "$(err)" "codex CLI is not installed"
assert_contains "and how to route around it" "$(err)" "model-tiers.json"
if [ -e "$CODEX_ROOT/nocodex" ]; then no "left a run dir behind"; else ok "and leaves no run dir behind"; fi

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
