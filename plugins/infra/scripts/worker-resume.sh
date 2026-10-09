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
#   bash worker-resume.sh <runid> <issue> <tier> <worktree> --base BRANCH --answer TEXT \
#        [--attempt N] [--env NAME=VALUE]... [--dry-run]
#   bash worker-resume.sh <runid> <issue> <tier> <worktree> --base BRANCH --answer-file FILE \
#        [--attempt N] [--env NAME=VALUE]... [--dry-run]
#
#     --base BRANCH  REQUIRED. What the post-resume review diffs against. The resumed
#                    worker does not review itself (§ the reviewer, below), so without
#                    this there is nothing to review against and the run would be landed
#                    unreviewed.
#     --attempt N    the chain position the worker was SPAWNED at (default 0), so the
#                    re-passed `-m` is the same model — a resume on a different model is
#                    a stranger on the thread (#104). The answer is normally a consult's
#                    decision (consult.sh) to a **Deviation**.
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
BASE=""
ATTEMPT=0
ENVS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --answer)      [ $# -ge 2 ] || die "--answer needs a value"
                       ANSWER="$2"; ANSWER_SET=1; shift 2 ;;
        --answer-file) [ $# -ge 2 ] || die "--answer-file needs a path"
                       [ -f "$2" ] || die "no such answer file: $2"
                       ANSWER="$(cat "$2")"; ANSWER_SET=1; shift 2 ;;
        --base)        [ $# -ge 2 ] || die "--base needs a value"
                       BASE="$2"; shift 2 ;;
        --attempt)     [ $# -ge 2 ] || die "--attempt needs a value"
                       ATTEMPT="$2"; shift 2 ;;
        --env)         [ $# -ge 2 ] || die "--env needs NAME=VALUE"
                       ENVS+=("$2"); shift 2 ;;
        --dry-run)     DRY=1; shift ;;
        *)             die "unknown flag $1" ;;
    esac
done

USAGE="usage: worker-resume.sh <runid> <issue> <tier> <worktree> --base BRANCH --answer TEXT [--attempt N] [--env NAME=VALUE]... [--dry-run]"
[ -n "$RUNID" ] && [ -n "$ISSUE" ] && [ -n "$TIER" ] && [ -n "$WORKTREE" ] || die "$USAGE"
# --base is REQUIRED, and deliberately has no default. The resumed turn ends with an
# independent review (below) and the reviewer's commit range cannot be built without one —
# and a resume that quietly skipped the review would land an unreviewed branch wearing
# the same report shape as a reviewed one, which is the exact failure #96 caught.
# Guessing a base here (`main`, the current branch) would be the same silence with extra
# steps: wrong on any repo whose default differs, and undetectable when it is.
[ -n "$BASE" ] || die "--base BRANCH is required — the post-resume review cannot run without it"
case "$ATTEMPT" in ''|*[!0-9]*) die "--attempt must be a number, got '$ATTEMPT'" ;; esac
case "$ISSUE" in ''|*[!0-9]*) die "issue must be a number, got '$ISSUE'" ;; esac
# Same guard as spawn.sh, worker-report.sh and run-log.sh: it is joined into a path.
case "$RUNID" in .|..|*[!A-Za-z0-9._-]*) die "runid may only contain [A-Za-z0-9._-] and may not be . or .., got '$RUNID'" ;; esac
[ "$ANSWER_SET" -eq 1 ] || die "an answer is required: --answer TEXT or --answer-file FILE"
[ -n "${ANSWER//[[:space:]]/}" ] || die "the answer is empty — resuming with nothing to say wastes the thread"
[ "${#ENVS[@]}" -eq 0 ] || bash "$INFRA/env-pairs.sh" "${ENVS[@]}" || exit 1
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
ROSTER="$(bash "$INFRA/resolve-tier.sh" "$TIER" "$ATTEMPT" 2>/dev/null)"
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

Do NOT review your own diff and do NOT run \`codex exec review\` — a nested codex
invocation cannot start inside your sandbox, and your own opinion of your own work is not
a review. An independent reviewer runs automatically once you exit.

When you are done, REPORT, THEN STOP. Your FINAL MESSAGE is the report and it must be
JSON matching the output schema you were launched with. Every field is required; send \"\"
or 0 for the ones that do not apply — \"review\" is one of those, since you did not
review:
   {\"issue\": $ISSUE, \"status\": \"built\", \"round\": 0, \"head\": \"<sha>\", \"review\": \"\", \"note\": \"\"}
Use \"status\": \"failed\" with the reason in \"note\" if you could not finish. If you are
STILL blocked on something only a human can answer, use \"status\": \"escalate\" again with
the new question in \"note\" — do not guess. Missing infrastructure you cannot create (a
database, a service, a credential)? \"status\": \"blocked\" with \"note\" = \"infra: <what is missing>\"
— never an escalate deviation."

CMD=(codex exec resume "$THREAD"
     -m "$MODEL"
     -c "model_reasoning_effort=$EFFORT"
     -c "approval_policy=never"
     -c "sandbox_mode=workspace-write"
     -c "sandbox_workspace_write.writable_roots=$WRITABLE_ROOTS"
     -c "sandbox_workspace_write.network_access=true")
# Resume does not inherit the spawn's shell environment policy. Re-pass the
# name-filter override when an explicitly provisioned value needs it.
if [ "${#ENVS[@]}" -gt 0 ]; then
    _policy="$(bash "$INFRA/env-pairs.sh" --codex-policy "$WORKTREE" "${ENVS[@]}")" || exit 1
    while IFS= read -r _c; do [ -z "$_c" ] || CMD+=(-c "$_c"); done <<<"$_policy"
fi
CMD+=(--json
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
# THE REVIEWER IS BUILT BEFORE ANYTHING IS DESTROYED. review-cmd.sh can fail — a missing
# sibling, an unresolvable base — and doing that after the turn has run would exit before
# the exit file is written, leaving the run dir holding a dead pid and no exit code, which
# session-status.sh reads as `failed`: the answered escalation spent for nothing.
[ -f "$INFRA/review-cmd.sh" ] || die "missing infra sibling: $INFRA/review-cmd.sh"
# A SHA, resolved before the resumed worker runs, for the same reason spawn.sh pins one:
# `refs/` is a writable root, so a base resolved by NAME afterwards could be moved to HEAD
# by the worker, emptying its own diff and buying an honest clean verdict.
BASE_SHA="$(git -C "$WORKTREE" rev-parse --verify "$BASE^{commit}" 2>/dev/null)" \
    || die "cannot resolve base '$BASE' to a commit in $WORKTREE"
# The scratch dir a test runner inside the review may write to (#99) — see review-cmd.sh
# for why the review itself never runs from $WORKTREE, and spawn.sh's wrapper for the
# identical clone-and-cleanup this script mirrors below.
# NUL-delimited, never newline-split: the prompt is one multi-line argument, and a line
# reader would hand claude the first line of it (review round 2). An empty array is
# review-cmd.sh's failure (it prints nothing on stdout then), and its stderr passes through.
# `read -d ''`, NOT `mapfile -d ''`: mapfile is bash 4+, and macOS ships bash 3.2 while
# README.md and AGENT_SETUP.md both promise macOS (swarm.sh records the same rule).
REVIEW_CMD=()
# The role comes from the file spawn.sh wrote.
SCOPED=""; [ "$(head -1 "$RUNDIR/role" 2>/dev/null)" = fix ] && SCOPED="$RUNDIR"
while IFS= read -r -d '' _arg; do REVIEW_CMD+=("$_arg"); done \
    < <(bash "$INFRA/review-cmd.sh" "$TIER" "$BASE_SHA" "$ISSUE" ${SCOPED:+--scoped "$SCOPED"})
[ "${#REVIEW_CMD[@]}" -gt 0 ] || die "could not build the reviewer command for tier '$TIER'"

# review.txt goes too, and for the sharpest version of the same reason: it is the only
# source of the finding counts, so the previous turn's review left in place would be read
# as this turn's verdict on code the resumed worker has since changed. review-stderr.log
# with it — the missing-review error quotes its tail, and a stale one would explain this
# turn's refusal with the last one's reason.
#
# review-checkout and review-scratch are deliberately NOT cleared here. They are inputs the
# CLONE and the sandbox grant TRUST, not just files the reviewer overwrites — `mkdir -p`
# over an existing symlink-to-directory no-ops instead of failing, and `git clone` into one
# writes through it. Clearing them here, before the worker about to run, would leave the
# window between here and the clone below open for THAT SAME WORKER to plant one — the
# non-default-CODEX_RUN_ROOT threat model spawn.sh's own pre-clone cleanup already names.
# They are cleared AFTER the worker exits instead (below), mirroring spawn.sh's wrapper.
rm -f "$RUNDIR/last-message.txt" "$RUNDIR/exit" "$RUNDIR/stderr.log" "$RUNDIR/reviewing" \
      "$RUNDIR/review.txt" "$RUNDIR/review-stderr.log"


# Foreground, unlike spawn.sh. An escalation is inherently synchronous — the orchestrator
# just went to a human and came back — so there is nothing to gain from backgrounding it,
# and blocking here keeps the whole wrapper/pid/process-group apparatus out of this
# script. </dev/null because codex blocks forever on an open stdin.
(
    [ "${#ENVS[@]}" -eq 0 ] || export "${ENVS[@]}"
    cd "$WORKTREE" && "${CMD[@]}"
) >>"$RUNDIR/events.jsonl" 2>>"$RUNDIR/stderr.log" </dev/null
CODE=$?
# Anything the worker just resumed may have left at review-checkout/review-scratch is gone
# BEFORE the clone below trusts either path (#99) — same placement and reasoning as
# spawn.sh's wrapper: a worker able to reach the run dir (a non-default CODEX_RUN_ROOT) and
# left a symlink there would otherwise have `mkdir -p`/`git clone` follow it, handing the
# reviewer's sandbox grant and TMPDIR to a directory the worker chose, not this script.
rm -rf "$RUNDIR/review-checkout" "$RUNDIR/review-scratch"
# The worker is done; a frozen event log from here on is the reviewer running, not a stall
# (escalate.sh reads this marker). Removed just before `exit` lands, as in spawn.sh.
: >"$RUNDIR/reviewing"

# THE INDEPENDENT REVIEWER (claude on the reviewer cell, spawning my-review — #104),
# exactly as spawn.sh runs it and from the same builder — a resumed worker's branch is as
# unreviewed as a freshly built one, and worker-report.sh below refuses a built/fixed
# report with no review.txt. ORDER: before the exit file, which is what makes the run
# terminal and readable. Its verdict is its stdout, captured to review.txt.
#
# FAIL CLOSED: a failed review leaves NO review.txt, so the run is refused rather than
# merged on a verdict nobody produced.
# Reviewed only when the resumed turn SAYS it built or fixed something. A worker that
# escalated again, or failed, also exits 0 — reviewing that posts a "Review round" comment
# on a half-built branch, which the orchestrate lane counts as a spent cycle.
if [ "$CODE" -eq 0 ] \
   && grep -q '"status"[[:space:]]*:[[:space:]]*"\(built\|fixed\)"' \
        "$RUNDIR/last-message.txt" 2>/dev/null; then
    # TRIPWIRE, as in spawn.sh: the CLONE below is the first host process to run git in
    # this worktree after a worker that could have rewritten $OWN/commondir.
    if bash "$INFRA/common-git-dir.sh" --roots "$WORKTREE" \
            >/dev/null 2>>"$RUNDIR/review-stderr.log"; then
        # THE REVIEW NEVER RUNS FROM $WORKTREE ITSELF (#99) — see review-cmd.sh for why
        # workspace-write's unconditional grant of wherever it runs FROM made that unsafe.
        # A disposable `--shared` clone stands in: no object copy, and `--base` (a SHA)
        # diffs identically there. TMPDIR points a test runner at the same scratch dir the
        # argv was built to grant.
        mkdir -p "$RUNDIR/review-scratch" \
            && git clone --quiet --shared -- "$WORKTREE" "$RUNDIR/review-checkout" \
                >/dev/null 2>>"$RUNDIR/review-stderr.log"
        if [ -d "$RUNDIR/review-checkout" ] && ( cd "$RUNDIR/review-checkout" \
                && TMPDIR="$RUNDIR/review-scratch" "${REVIEW_CMD[@]}" ) \
                >"$RUNDIR/review.txt" 2>>"$RUNDIR/review-stderr.log" </dev/null; then
            # The heading is counted by review-counts.sh — the SAME script
            # worker-report.sh reads the verdict with, so the comment on the issue and the
            # report the merge queue acts on can never disagree.
            PRIOR=()
            [ -z "$SCOPED" ] || PRIOR=(--prior "$RUNDIR")
            # Empty arrays expand as unbound under set -u on macOS bash 3.2.
            COUNTS="$(bash "$INFRA/review-counts.sh" "$RUNDIR/review.txt" ${PRIOR[@]+"${PRIOR[@]}"} \
                2>>"$RUNDIR/review-stderr.log")"
            if [ -n "$COUNTS" ]; then
                # The run-dir ledger escalate.sh counts rounds from: round lines start
                # with a digit, finding entries do not (see spawn.sh's wrapper).
                ROUND=$(( $(cat "$RUNDIR/rounds" 2>/dev/null | grep -c '^[0-9]') + 1 ))
                printf '%s %s\n' "$ROUND" "$COUNTS" >>"$RUNDIR/rounds"
                bash "$INFRA/review-counts.sh" "$RUNDIR/review.txt" --findings "$ROUND" \
                    >>"$RUNDIR/rounds" 2>>"$RUNDIR/review-stderr.log"
                git -C "$RUNDIR/review-checkout" rev-parse HEAD \
                    >"$RUNDIR/reviewed-head" 2>>"$RUNDIR/review-stderr.log"
                { printf '**Review round %s** — %s\n\n' "$ROUND" "$COUNTS"
                  cat "$RUNDIR/review.txt"; } >"$RUNDIR/review-comment.md"
                ( cd "$WORKTREE" && gh issue comment "$ISSUE" \
                    --body-file "$RUNDIR/review-comment.md" ) \
                    >/dev/null 2>>"$RUNDIR/review-stderr.log" </dev/null \
                    || printf 'REVIEW_COMMENT_POST_FAILED\n' >>"$RUNDIR/review-stderr.log"
            else
                printf 'REVIEW_UNREADABLE\n' >>"$RUNDIR/review-stderr.log"
                rm -f "$RUNDIR/review.txt"
            fi
        else
            printf 'REVIEW_FAILED\n' >>"$RUNDIR/review-stderr.log"
            rm -f "$RUNDIR/review.txt"
        fi
        rm -rf "$RUNDIR/review-checkout" "$RUNDIR/review-scratch"
    else
        printf 'REVIEW_SKIPPED containment check refused the worktree\n' \
            >>"$RUNDIR/review-stderr.log"
        rm -f "$RUNDIR/review.txt"
    fi
fi

rm -f "$RUNDIR/reviewing"
printf '%s\n' "$CODE" >"$RUNDIR/exit"

# Rendering lives in ONE place. worker-report.sh already turns last-message.txt into the
# lane's report line and already decides what is a result and what is "we cannot tell";
# the run dir is now terminal, so it returns immediately.
# Not 60: session-status.sh gives its own `claude agents` call a 60s subprocess timeout, so
# a single slow or wedged CLI call would eat this entire budget on the FIRST poll and throw
# away a resume that had already written a perfectly good report. The run dir is terminal
# before we get here, so this budget only ever absorbs a slow status read.
exec bash "$INFRA/worker-report.sh" "$RUNID" "$ISSUE" --interval 1 --timeout 300
