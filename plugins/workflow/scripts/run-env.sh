#!/usr/bin/env bash
#
# run-env.sh — SOURCED by launch.sh, admit.sh, handle-report.sh and end-run.sh. Not run.
#
# A run's state crosses many separate Bash calls, and a model carrying it between them is
# the arithmetic this design keeps out of prose. So launch.sh writes it ONCE to
# <runroot>/<runid>/run.env and every later script takes only the runid. Per-issue state
# comes from the run dir spawn.sh writes (session-name, rounds, role, env) and from
# run-log.sh, never from the model's memory.
#
# Seams (env): ORCH_INFRA (infra's scripts; default the ~/.claude/kit/infra link),
# CODEX_RUN_ROOT (the run root, as spawn.sh), CLAUDE_BOX_ROOT (as link-kit.sh).

die() { echo "error: $*" >&2; exit 1; }

WF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="${ORCH_INFRA:-${HOME:-/nonexistent}/.claude/kit/infra/scripts}"
RUNROOT="${CODEX_RUN_ROOT:-${HOME:-/nonexistent}/.claude/codex-runs}"

check_runid() {
    case "$1" in .|..|''|*[!A-Za-z0-9._-]*)
        die "runid may only contain [A-Za-z0-9._-] and may not be . or .., got '$1'" ;;
    esac
}

# load_run <runid> — RUNID BASE_SHA BASE_BRANCH BASE_REPO ORCH_BRANCH ORCH_WT GRAPH MAX PRD SKIP_UNKNOWN
load_run() {
    check_runid "$1"
    RUN_DIR="$RUNROOT/$1"
    [ -f "$RUN_DIR/run.env" ] || die "no launched run '$1' (no $RUN_DIR/run.env)"
    # shellcheck disable=SC1091
    . "$RUN_DIR/run.env"
}

runlog() { CLAUDE_PROJECT_DIR="$BASE_REPO" bash "$WF/run-log.sh" "$@"; }
run_state() { runlog state "$RUNID" 2>/dev/null | sed -n "s/^$1=//p" | tr ',' ' '; }

issue_dir() { printf '%s/issue-%s' "$RUN_DIR" "$1"; }
worktree_of() { printf '%s/.worktrees/%s/issue-%s' "$BASE_REPO" "$RUNID" "$1"; }
tier_of() { jq -r --argjson n "$1" '.issues[] | select(.n == $n) | .tier // empty' "$GRAPH"; }
has_label() { jq -e --argjson n "$1" --arg l "$2" '.issues[] | select(.n == $n) | .labels | index($l)' "$GRAPH" >/dev/null 2>&1; }
# The chain position of the issue's newest worker: the `-a<A>` in the name spawn.sh recorded.
attempt_of() {
    local name
    name="$(head -1 "$(issue_dir "$1")/session-name" 2>/dev/null)"
    case "$name" in *-a[0-9]*) name="${name##*-a}"; printf '%s\n' "${name%%-*}" ;; *) echo 0 ;; esac
}
# Review rounds so far: the ledger's round lines (finding lines do not start with a digit).
rounds_of() { grep -c '^[0-9]' "$(issue_dir "$1")/rounds" 2>/dev/null || true; }

# spawn_issue <N> <role> <round> <attempt> — the ONE place a worker is launched, so the
# provisioned env pairs (<issue dir>/env, NUL-delimited) and the needs-browser opt-in ride
# along on every build, fix round and respawn.
spawn_issue() {
    local n="$1" role="$2" round="$3" attempt="$4"
    env_args "$n"
    has_label "$n" needs-browser && ENV_ARGS+=(--browser)
    bash "$INFRA/spawn.sh" "$RUNID" "$n" "$(tier_of "$n")" "$(worktree_of "$n")" "$ORCH_BRANCH" \
        --role "$role" --round "$round" --attempt "$attempt" ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} >/dev/null 9>&-
}

# env_args <N> — ENV_ARGS=(--env K=V ...) from the issue's provisioned pairs. Values never
# leave this array: not argv of anything but the worker launch, never printed, never logged.
env_args() {
    local pair
    ENV_ARGS=()
    [ -f "$(issue_dir "$1")/env" ] || return 0
    while IFS= read -r -d '' pair; do ENV_ARGS+=(--env "$pair"); done <"$(issue_dir "$1")/env"
}

# run_lock — one admit/handle-report at a time per run. A Bash call that outlives its
# timeout keeps running in the background; without the lock the next call would admit the
# same issues again. handle-report.sh holds it and exports ORCH_LOCKED, so the admit.sh it
# calls does not wait on its own parent.
#
# The lock is fd 9. EVERY background process these scripts start — a worker, a detached
# plan, a resume — must get `9>&-`: a flock belongs to the open file, so a child that
# inherited fd 9 would hold the run's lock for its whole life.
#
# The call's wall-clock BUDGET (ORCH_DEADLINE) starts once the lock is held: a call that
# waited on the lock must not inherit a budget it spent waiting. The wait is short — the
# loser just says `waiting:` and is called again.
run_lock() {
    [ -z "${ORCH_LOCKED:-}" ] || return 0
    exec 9>"$RUN_DIR/.lock" || die "cannot open $RUN_DIR/.lock"
    if ! flock -w "${ORCH_LOCK_WAIT:-20}" 9; then
        echo "waiting: another admit.sh or handle-report.sh is still running on run $RUNID"
        exit 0
    fi
    export ORCH_LOCKED=1
    ORCH_DEADLINE=$(( $(date +%s) + ${ORCH_BUDGET:-570} ))
    export ORCH_DEADLINE
}
budget_left() { echo $(( ${ORCH_DEADLINE:-0} - $(date +%s) )); }