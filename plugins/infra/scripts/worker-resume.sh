#!/usr/bin/env bash
#
# worker-resume.sh — answer a CODEX worker's escalation by resuming its thread.
#
# A codex worker has no inbox, so it escalates by ENDING its turn: `status: escalate`
# with the question in `note`, which worker-report.sh surfaces as
# `issue <N> escalate <question>`. Its process is then gone — but its THREAD is not.
# Every `codex exec` run persists under `~/.codex/sessions/`, so the answer goes back by
# resuming, and the worker continues with everything it had rather than restarting.
#
# Usage:
#   bash worker-resume.sh <runid> <issue> <tier> <worktree> --answer TEXT [--dry-run]
#   bash worker-resume.sh <runid> <issue> <tier> <worktree> --answer-file FILE [--dry-run]
#
# Output: the resumed turn's report, in the same one line the lane already parses —
# this script hands rendering to worker-report.sh rather than keeping a second copy of
# it, so a resumed turn reports exactly like a first one. Exit codes are worker-report's:
# 0 with one line is a real result, 1 with empty stdout means we cannot say what happened.
#
# THE FLAGS ARE NOT OPTIONAL AND NOT COPIED FROM THE SPAWN BY CODEX. Verified on
# codex-cli 0.154 (2026-09-16): `resume` inherits NONE of the sandbox. The same thread,
# resumed re-passing nothing, went from `http=200` to `DNSFAIL` — an OFFLINE worker,
# which fails its own `gh` protocol silently and looks like a worker that merely finished
# badly. `resume` also takes no `-s` and no `-C`, so:
#   * the sandbox goes back through `-c` (`sandbox_mode`, verified behaviourally — a bogus
#     config key is accepted SILENTLY without --strict-config, so the proof is that the
#     network came back, not that codex declined to complain), and
#   * the resume is launched FROM the worktree, because there is no --cd to point it.
# `-m` is re-passed for the reason the design doc already records: a resumed thread
# otherwise falls back to the config default model, not the tier's.

set -uo pipefail

INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "error: $*" >&2; exit 1; }

RUNID="${1:-}"; ISSUE="${2:-}"; TIER="${3:-}"; WORKTREE="${4:-}"
shift 4 2>/dev/null || true
ANSWER=""
ANSWER_SET=0
DRY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --answer)      [ $# -ge 2 ] || die "--answer needs a value"
                       ANSWER="$2"; ANSWER_SET=1; shift 2 ;;
        --answer-file) [ $# -ge 2 ] || die "--answer-file needs a path"
                       [ -f "$2" ] || die "no such answer file: $2"
                       ANSWER="$(cat "$2")"; ANSWER_SET=1; shift 2 ;;
        --dry-run)     DRY=1; shift ;;
        *)             die "unknown flag $1" ;;
    esac
done

[ -n "$RUNID" ] && [ -n "$ISSUE" ] && [ -n "$TIER" ] && [ -n "$WORKTREE" ] \
    || die "usage: worker-resume.sh <runid> <issue> <tier> <worktree> --answer TEXT [--dry-run]"
case "$ISSUE" in ''|*[!0-9]*) die "issue must be a number, got '$ISSUE'" ;; esac
# Same guard as spawn.sh, worker-report.sh and run-log.sh: it is joined into a path.
case "$RUNID" in *[!A-Za-z0-9._-]*) die "runid may only contain [A-Za-z0-9._-], got '$RUNID'" ;; esac
[ "$ANSWER_SET" -eq 1 ] || die "an answer is required: --answer TEXT or --answer-file FILE"
[ -n "${ANSWER//[[:space:]]/}" ] || die "the answer is empty — resuming with nothing to say wastes the thread"
[ -d "$WORKTREE" ] || die "no such worktree: $WORKTREE"

RUNDIR="${CODEX_RUN_ROOT:-${HOME:-/nonexistent}/.claude/codex-runs}/$RUNID/issue-$ISSUE"
[ -d "$RUNDIR" ] || die "no codex run dir for issue $ISSUE: $RUNDIR"
[ -f "$RUNDIR/status-schema.json" ] || die "missing $RUNDIR/status-schema.json — cannot force the report shape"

# The thread id is already here: spawn.sh redirects codex's --json stream into
# events.jsonl, whose `thread.started` event carries it. Nothing extra had to be captured
# at spawn time. (If this is ever empty, the rollout whose session_meta.cwd is the
# worktree is the recovery path — see docs/swarm-design.md § Codex backend.)
[ -f "$RUNDIR/events.jsonl" ] || die "missing $RUNDIR/events.jsonl — no thread id to resume"
THREAD="$(sed -n 's/.*"thread_id":"\([^"]*\)".*/\1/p' "$RUNDIR/events.jsonl" | head -1)"
[ -n "$THREAD" ] || die "no thread_id in $RUNDIR/events.jsonl — nothing to resume"

# The tier decides the model, and it must be the SAME backend: resuming a claude-backed
# worker through codex would start a stranger on its branch.
[ -f "$INFRA/resolve-tier.sh" ] || die "missing infra sibling: $INFRA/resolve-tier.sh"
ROSTER="$(bash "$INFRA/resolve-tier.sh" "$TIER" 2>/dev/null)"
MODEL="$(printf '%s\n'   "$ROSTER" | sed -n 's/^implementer_model=//p'   | head -1)"
EFFORT="$(printf '%s\n'  "$ROSTER" | sed -n 's/^implementer_effort=//p'  | head -1)"
BACKEND="$(printf '%s\n' "$ROSTER" | sed -n 's/^implementer_backend=//p' | head -1)"
[ -n "$MODEL" ] && [ -n "$EFFORT" ] || die "could not resolve a roster for tier '$TIER'"
[ "$BACKEND" = codex ] || die "tier '$TIER' is backend '$BACKEND', not codex — a claude worker is resumed by talking to its session, not by this script"

# The SAME resolution the spawn used, from the same script — not a second copy. A resume
# that resolved this differently would hand the worker a different writable root than its
# spawn did, and the worker would not find out until it could not commit. `--roots` is the
# narrowed set: objects, refs, logs and this worktree's own git dir, never hooks/ or config.
WRITABLE_ROOTS="$(bash "$INFRA/common-git-dir.sh" --roots "$WORKTREE")" || exit 1

PROMPT="Your escalation was answered. Here is the answer:

$ANSWER

Continue the issue from exactly where you stopped — you still have your full context, so
do not start over and do not re-read what you already read.

When you are done, REPORT, THEN STOP. Your FINAL MESSAGE is the report and it must be
JSON matching the output schema you were launched with. Every field is required; send \"\"
or 0 for the ones that do not apply:
   {\"issue\": $ISSUE, \"status\": \"built\", \"round\": 0, \"head\": \"<sha>\", \"review\": \"<H high, M medium, L low>\", \"note\": \"\"}
Use \"status\": \"failed\" with the reason in \"note\" if you could not finish. If you are
STILL blocked on something only a human can answer, use \"status\": \"escalate\" again with
the new question in \"note\" — do not guess."

CMD=(codex exec resume "$THREAD"
     -m "$MODEL"
     -c "model_reasoning_effort=$EFFORT"
     -c "approval_policy=never"
     -c "sandbox_mode=workspace-write"
     -c "sandbox_workspace_write.writable_roots=$WRITABLE_ROOTS"
     -c "sandbox_workspace_write.network_access=true"
     --json
     -o "$RUNDIR/last-message.txt"
     --output-schema "$RUNDIR/status-schema.json"
     "$PROMPT")

# NEVER resume onto a worker that is still running. Checked BEFORE the dry run returns, so
# `--dry-run` is a real safety preview rather than only a command printer. Below, the first
# side effect is `rm` of the exit file, so a mis-aimed call — a wrong issue number, a stale
# escalation acted on twice — would BOTH start a second codex on a worktree the first is
# still writing AND destroy the running worker's exit code on the way in, making its
# eventual state unreadable. An `exit` file is exactly what session-status.sh treats as
# terminal, and reading it here needs no claude CLI.
[ -f "$RUNDIR/exit" ] || die "issue $ISSUE has not finished (no $RUNDIR/exit) — resuming \
now would put a second codex on a worktree the first is still writing"

if [ -n "$DRY" ]; then
    printf '%s\n' "${CMD[@]}"
    exit 0
fi

# The previous turn's report and exit code are STALE the moment we resume. Clearing them
# first matters: session-status.sh reads an exit file as terminal, so leaving the old one
# in place would make this turn look finished before it began, and leaving the old
# last-message.txt would let a crashed resume be read as the previous turn's success.
# stderr.log goes too: it is appended to below, and the no-report failure path reports its
# tail as the reason — so a resume that dies quietly would otherwise be reported with the
# reason from a turn that ran hours ago, at the exact moment a human is reading it.
rm -f "$RUNDIR/last-message.txt" "$RUNDIR/exit" "$RUNDIR/stderr.log"

# Foreground, unlike spawn.sh. An escalation is inherently synchronous — the orchestrator
# just went to a human and came back — so there is nothing to gain from backgrounding it,
# and blocking here keeps the whole wrapper/pid/process-group apparatus out of this
# script. </dev/null because codex blocks forever on an open stdin.
( cd "$WORKTREE" && "${CMD[@]}" ) >>"$RUNDIR/events.jsonl" 2>>"$RUNDIR/stderr.log" </dev/null
CODE=$?
printf '%s\n' "$CODE" >"$RUNDIR/exit"

# Rendering lives in ONE place. worker-report.sh already turns last-message.txt into the
# lane's report line and already decides what is a result and what is "we cannot tell";
# the run dir is now terminal, so it returns immediately.
# Not 60: session-status.sh gives its own `claude agents` call a 60s subprocess timeout, so
# a single slow or wedged CLI call would eat this entire budget on the FIRST poll and throw
# away a resume that had already written a perfectly good report. The run dir is terminal
# before we get here, so this budget only ever absorbs a slow status read.
exec bash "$INFRA/worker-report.sh" "$RUNID" "$ISSUE" --interval 1 --timeout 300
