#!/usr/bin/env bash
#
# Integration test for PRD #104's central mechanism, end to end through the REAL scripts:
#
#   resolve-tier.sh (the chain) → spawn.sh --attempt 0 (a real background spawn against a
#   stub codex that emits real-format artifacts) → the worker ends in one of the three states
#   the PRD names (a `failed` report, a stale event log with a live pid, an over-threshold
#   rollout usage) → escalate.sh reads those artifacts and prints the reason and posts the
#   Handoff comment → spawn.sh --attempt 1 --dry-run names the NEXT chain model → and at the
#   top of the chain spawn.sh refuses, which is what the orchestrator drains on.
#
# THE DECLARED CENTRAL MOCK (docs/anti-mock-drift.md): the stub `codex` (its `--json` event
# stream and the schema'd status JSON in last-message.txt), the stub `claude` (the reviewer's
# stdout), the stub `gh` (the `--json comments` listing, and the recorded comment posts), and
# the fixture rollout (`token_count` events with `last_token_usage`). Every one is written in
# the format the real binary produces, verified against real runs in the sibling tests. The
# real `resolve-tier.sh`, `spawn.sh`, `session-status.sh`, `escalate.sh` and git run for real.
# What no stub can prove — that real luna wedges the way the fixtures say — is the PILOT
# (three standard issues, one forced escalation) that closes this mock-debt; until it runs,
# the feature is not done.
#
# Run: bash plugins/infra/tests/test_escalation-chain.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$(cd "$SCRIPT_DIR/.." && pwd)/scripts"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${WPID:-}" ] && kill -- -"$WPID" 2>/dev/null' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in '$2')" ;; esac; }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected empty, got '$2')"; fi; }
assert_arg() { if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else no "$1 (no arg line '$3')"; fi; }

# age_file <path> <minutes> — set mtime <minutes> minutes in the past, portably. GNU
# `touch -d` first; BSD/macOS `date -v` for the relative math otherwise; an arbitrarily
# old absolute stamp if neither exists. Exact minutes only matter relative to the window
# under test, and the last fallback errs generously old rather than "not stale enough".
age_file() {
    local f="$1" mins="$2"
    touch -d "${mins} minutes ago" "$f" 2>/dev/null \
        || touch -t "$(date -v-"${mins}"M +%Y%m%d%H%M 2>/dev/null || echo 200001010000)" "$f" 2>/dev/null
}

# The SHIPPED table, read through the real resolver: no fixture roster here — the chain
# under test is the one users get.
export CLAUDE_CONFIG_DIR="$WORK/nousercfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
unset RESOLVE_TIER_ROOT

BIN="$WORK/bin"; mkdir -p "$BIN"
# codex: streams real-format events, writes the schema'd final message to -o, optionally
# sleeps (a live worker) so a stale log can be arranged around it.
cat >"$BIN/codex" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"thread.started","thread_id":"%s"}\n' "${STUB_THREAD:-thr-int-1}"
printf '{"type":"turn.started"}\n'
printf '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/sh -lc '"'"'pytest -q'"'"'","aggregated_output":"3 failed"}}\n'
while [ $# -gt 0 ]; do [ "$1" = -o ] && printf '%s' "${STUB_REPORT:-}" >"$2"; shift; done
printf '{"type":"turn.completed","usage":{"input_tokens":2944876,"cached_input_tokens":2849152,"cache_write_input_tokens":0,"output_tokens":23253}}\n'
[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
exit "${STUB_EXIT:-0}"
STUB
# claude: the reviewer (only reached on built/fixed) and the agent list.
cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = agents ]; then echo "[]"; exit 0; fi
# The verdict is clean only when the prompt arrived WHOLE, as one argument: a split prompt
# (review round 2) means the real reviewer never saw its format contract.
printf '%s\n' "$#" >"${STUB_REVIEW_ARGC:-/dev/null}"
case "${@: -1}" in *"No findings."*) printf 'No findings.\n' ;; *) printf 'prompt was truncated\n' ;; esac
STUB
# gh: the thread and the posts, recorded.
cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"${STUB_GH_ARGV:-/dev/null}"
if [ "${1:-}" = issue ] && [ "${2:-}" = view ]; then
    [ -n "${STUB_GH_COMMENTS:-}" ] || STUB_GH_COMMENTS='{"comments":[{"body":"**Plan**\n\n1. add f"}]}'
    printf '%s' "$STUB_GH_COMMENTS"; exit 0
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = comment ]; then
    while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cat "$2" >>"${STUB_GH_BODY:-/dev/null}"; shift; done
fi
exit 0
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

# A real LINKED worktree — the only shape common-git-dir.sh --roots grants roots for.
ORIGIN="$WORK/origin"; mkdir -p "$ORIGIN"
git -C "$ORIGIN" init -q; git -C "$ORIGIN" config user.email t@t.t; git -C "$ORIGIN" config user.name t
printf 'x\n' >"$ORIGIN/f"; git -C "$ORIGIN" add f; git -C "$ORIGIN" commit -qm init
git -C "$ORIGIN" branch base
WT="$WORK/wt"
git -C "$ORIGIN" worktree add -q -b issue-12 "$WT" >/dev/null 2>&1
printf 'y\n' >"$WT/f"; git -C "$WT" commit -qam "step 1: add f"

CODEX_ROOT="$WORK/codexruns"; export CODEX_RUN_ROOT="$CODEX_ROOT"
SESSIONS="$WORK/sessions"; export CODEX_SESSIONS_ROOT="$SESSIONS"
RUNDIR="$CODEX_ROOT/r1/issue-12"
export STUB_GH_ARGV="$WORK/gh-argv" STUB_GH_BODY="$WORK/body" STUB_REVIEW_ARGC="$WORK/review-argc"

spawn() { bash "$INFRA/spawn.sh" r1 12 standard "$WT" base --orchestrator orch-main "$@" 2>"$WORK/err"; }
wait_exit() { for _ in $(seq 1 25); do [ -f "$RUNDIR/exit" ] && return; sleep 0.2; done; }
escalate() { rm -f "$WORK/gh-argv" "$WORK/body"; OUT="$(bash "$INFRA/escalate.sh" r1 12 standard "$WT" --base base "$@" 2>"$WORK/eerr")"; RC=$?; }
posted() { grep -qx comment "$WORK/gh-argv" 2>/dev/null && echo yes || echo no; }

# ---------------------------------------------------------------------------
echo "test: the shipped chain resolves luna → terra → opus for a standard issue"
R0="$(bash "$INFRA/resolve-tier.sh" standard 0)"; R1="$(bash "$INFRA/resolve-tier.sh" standard 1)"; R2="$(bash "$INFRA/resolve-tier.sh" standard 2)"
assert_contains "attempt 0 luna" "$R0" "implementer_model=gpt-5.6-luna"
assert_contains "attempt 1 terra" "$R1" "implementer_model=gpt-5.6-terra"
assert_contains "attempt 2 opus" "$R2" "implementer_model=opus"
assert_contains "chain length 3" "$R0" "implementer_chain=3"

echo "test: attempt 0 spawns luna for real, through codex, with the plan in its prompt"
out="$(spawn --attempt 0 --dry-run)"
assert_arg "codex" "$out" "codex"
assert_arg "luna" "$out" "gpt-5.6-luna"
assert_contains "the worker is told to follow the Plan comment" "$out" "**Plan**"
assert_contains "and to stop on a deviation" "$out" "**Deviation**"

# ---------------------------------------------------------------------------
echo "SIGNAL 1: a failed report → escalate → respawn names terra → handoff posted"
rm -rf "$CODEX_ROOT"
STUB_REPORT='{"issue":12,"status":"failed","round":0,"head":"","review":"","note":"done-check red"}' \
    spawn --attempt 0 >/dev/null
wait_exit
assert_equals "the worker ran and exited" "$(cat "$RUNDIR/exit" 2>/dev/null)" "0"
assert_contains "session-status reads it as done" "$(bash "$INFRA/session-status.sh" r1 12 2>/dev/null)" "codex done"
escalate --attempt 0
assert_equals "escalate.sh exit 0" "$RC" "0"
assert_contains "the reason is failed" "$OUT" "failed: the worker reported failed: done-check red"
assert_equals "the handoff comment was posted" "$(posted)" "yes"
assert_contains "handoff names attempt 0" "$(cat "$WORK/body")" "**Handoff** — attempt 0 replaced: failed"
assert_contains "handoff lists the branch's commit" "$(cat "$WORK/body")" "step 1: add f"
assert_contains "handoff carries the last event-log activity" "$(cat "$WORK/body")" "pytest -q"
out="$(spawn --attempt 1 --dry-run)"
assert_arg "the respawn argv names the NEXT chain model" "$out" "gpt-5.6-terra"
assert_arg "still codex" "$out" "codex"
assert_contains "and the respawn is told it is one" "$out" "**Handoff**"
assert_contains "onto the SAME worktree" "$out" "$WT"

# ---------------------------------------------------------------------------
echo "SIGNAL 2: a stale event log with a live pid → stall → respawn"
rm -rf "$CODEX_ROOT"
STUB_SLEEP=60 STUB_REPORT='{"issue":12,"status":"built","round":0,"head":"abc1234","review":"","note":""}' \
    spawn --attempt 1 >/dev/null
unset STUB_SLEEP   # `spawn` is a shell FUNCTION: on bash < 4.4 (macOS's 3.2) a var assigned
                   # in front of a function call can leak into the CURRENT shell instead of
                   # staying scoped to that call — every LATER spawn in this file would then
                   # sleep 60s it never asked for.
for _ in $(seq 1 25); do [ -s "$RUNDIR/pid" ] && [ -f "$RUNDIR/events.jsonl" ] && break; sleep 0.2; done
WPID="$(cat "$RUNDIR/pid")"
sleep 0.5   # let the stub finish streaming before the mtime is aged
assert_contains "session-status reads the live worker as busy" "$(bash "$INFRA/session-status.sh" r1 12 2>/dev/null)" "codex busy"
escalate --attempt 1
assert_empty "a fresh event log: no signal" "$OUT"
age_file "$RUNDIR/events.jsonl" 30
escalate --attempt 1
assert_contains "aged log + live pid = stall" "$OUT" "stall: no event-log activity for 30 minutes"
assert_contains "handoff names attempt 1" "$(cat "$WORK/body")" "attempt 1 replaced: stall"
out="$(spawn --attempt 2 --dry-run)"
assert_arg "the respawn tops out on claude" "$out" "--bg"
assert_arg "at opus" "$out" "opus"
kill -- -"$WPID" 2>/dev/null; WPID=""
sleep 0.3

# ---------------------------------------------------------------------------
echo "SIGNAL 3: an over-threshold occupancy in the rollout → escalate"
rm -rf "$CODEX_ROOT" "$SESSIONS"
STUB_SLEEP=60 STUB_THREAD=thr-int-occ spawn --attempt 0 >/dev/null
unset STUB_SLEEP STUB_THREAD   # same leak risk as above — the CLEAN BUILD spawn right below
                               # this signal must NOT inherit a 60s sleep or a fixed thread id
for _ in $(seq 1 25); do [ -s "$RUNDIR/pid" ] && grep -q thread.started "$RUNDIR/events.jsonl" 2>/dev/null && break; sleep 0.2; done
WPID="$(cat "$RUNDIR/pid")"
mkdir -p "$SESSIONS/2026/09/22"
printf '{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9000000},"last_token_usage":{"input_tokens":260000,"cached_input_tokens":250000,"cache_write_input_tokens":0},"model_context_window":258400}}}\n' \
    >"$SESSIONS/2026/09/22/rollout-2026-09-22T00-00-00-thr-int-occ.jsonl"
escalate --attempt 0
assert_contains "occupancy past 256K escalates" "$OUT" "occupancy: context at 260000 tokens"
assert_contains "the handoff was posted for it" "$(cat "$WORK/body")" "replaced: occupancy"
kill -- -"$WPID" 2>/dev/null; WPID=""

# ---------------------------------------------------------------------------
echo "THE TOP OF THE CHAIN: spawn.sh refuses attempt 3, so the orchestrator drains"
spawn --attempt 3 --dry-run >/dev/null
assert_equals "exit 1" "$?" "1"
assert_contains "names the chain" "$(cat "$WORK/err")" "past the top of tier 'standard' implementer chain (length 3)"

echo "A CLEAN BUILD escalates nothing — the loop must not burn tiers for free"
rm -rf "$CODEX_ROOT"
STUB_REPORT='{"issue":12,"status":"built","round":0,"head":"abc1234","review":"","note":""}' \
    spawn --attempt 0 >/dev/null
wait_exit
assert_contains "the claude reviewer ran and worker-report renders the clean verdict" \
    "$(bash "$INFRA/worker-report.sh" r1 12 --interval 1 --timeout 20 2>/dev/null)" "issue 12 built head=abc1234 review=0 high, 0 medium, 0 low"
assert_equals "the reviewer got its prompt as one argument" "$(cat "$WORK/review-argc" 2>/dev/null)" "25"
escalate --attempt 0
assert_empty "no signal" "$OUT"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
