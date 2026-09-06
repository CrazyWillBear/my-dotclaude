#!/usr/bin/env bash
#
# spawn.sh — start (or print) the `claude --bg` worker session for one issue.
#
# Usage:
#   bash spawn.sh <runid> <issue> <tier> <worktree> <base-branch> [options]
#
#   --role build|fix        build (default) or a fix round on an existing branch
#   --round N               fix-round number, quoted in the fix prompt (default 1)
#   --orchestrator NAME     who the worker reports to; resolved from this session
#                           when omitted (session-status.sh --self)
#   --dry-run               print the command instead of running it
#
# Why each flag is here — these are the ways an unattended session dies quietly:
#
#   -n orch-<runid>-issue-<N>   the run prefix. `claude agents --json` is global and
#                               concurrent runs are intended; without it one run can
#                               stop another run's workers.
#   --permission-mode bypassPermissions
#                               an unattended session in manual or acceptEdits mode
#                               deadlocks on its FIRST prompt with nobody to answer.
#   --add-dir <worktree>        fences the FILE tools to this issue's worktree.
#                               KNOWN LIMIT, ACCEPTED: it does not fence Bash. The
#                               containment is the denylist plus worktree isolation,
#                               not a sandbox.
#   --disallowedTools ...       the irreversible, outward-facing writes stay on the
#                               main thread (#77: a close fired from a low-context
#                               worker was killed by a safety classifier, correctly).
#                               `git push` and `gh issue comment` are deliberately
#                               ALLOWED — a comment is additive, and the issue thread
#                               is the coordination medium.
#   --model / --effort          routed by the issue's persisted tier, via resolve-tier.sh.
#
# The prompt's last section is load-bearing: a session's plain text output is
# invisible to every other agent, so the worker is told, explicitly, to report with
# SendMessage. Miss that and the orchestrator waits forever.
#
# `claude` has no --cwd, so the session is started FROM the worktree.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "error: $*" >&2; exit 1; }

[ $# -ge 5 ] || die "usage: spawn.sh <runid> <issue> <tier> <worktree> <base-branch> [--role build|fix] [--round N] [--orchestrator NAME] [--dry-run]"

RUNID="$1"; ISSUE="${2#\#}"; TIER="$3"; WORKTREE="$4"; BASE="$5"
shift 5

ROLE=build
ROUND=1
ORCH=""
DRY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --role)         ROLE="${2:-}"; shift 2 ;;
        --round)        ROUND="${2:-}"; shift 2 ;;
        --orchestrator) ORCH="${2:-}"; shift 2 ;;
        --dry-run)      DRY=1; shift ;;
        *)              die "unknown flag $1" ;;
    esac
done

case "$ISSUE" in ''|*[!0-9]*) die "issue must be a number, got '$ISSUE'" ;; esac
case "$ROLE" in build|fix) ;; *) die "role must be build or fix, got '$ROLE'" ;; esac
[ -n "$RUNID" ] || die "runid is required"
[ -n "$WORKTREE" ] || die "worktree is required"
[ -n "$BASE" ] || die "base branch is required"

# The tier's roster. resolve-tier.sh always exits 0 and always prints a roster
# (falling back to standard), so a broken model-tiers.json degrades to a working
# spawn rather than no spawn at all.
ROSTER="$(bash "$SCRIPT_DIR/resolve-tier.sh" "$TIER" 2>/dev/null)"
MODEL="$(printf '%s\n' "$ROSTER"  | sed -n 's/^implementer_model=//p'  | head -1)"
EFFORT="$(printf '%s\n' "$ROSTER" | sed -n 's/^implementer_effort=//p' | head -1)"
[ -n "$MODEL" ] && [ -n "$EFFORT" ] || die "could not resolve a roster for tier '$TIER'"

# The worker's report address. A worker that cannot name its orchestrator reports
# into the void, so this fails LOUD rather than spawning a session nobody hears.
if [ -z "$ORCH" ]; then
    ORCH="$(bash "$SCRIPT_DIR/session-status.sh" --self 2>/dev/null)" \
        || die "could not resolve this session's name — pass --orchestrator NAME"
    [ -n "$ORCH" ] || die "could not resolve this session's name — pass --orchestrator NAME"
fi

NAME="orch-$RUNID-issue-$ISSUE"
BRANCH="issue-$ISSUE"

# Only COMPLEX work plans. Trivial and standard self-plan — planning TDD-first is
# already in the implementer's contract, and a plan stage in front of an implementer
# that explores anyway was measured at 26% of all agent-minutes on a 56-agent run.
# The SESSION spawns the planner, never the orchestrator: a plan is prose, and prose
# the orchestrator reads is prose in its context for the rest of the run.
PLAN_STEP=""
if [ "$TIER" = complex ]; then
    PLAN_STEP="0. This is a COMPLEX issue: spawn the workflow:planner agent FIRST and build to the
   plan it returns. Keep the plan in YOUR context — never send it to the orchestrator.
"
fi

if [ "$ROLE" = build ]; then
    TASK="$(cat <<PROMPT
You are the BUILD session for issue #$ISSUE, run $RUNID.

Worktree: $WORKTREE — branch $BRANCH, cut from $BASE. Work ONLY here; never touch
another worktree or $BASE.

${PLAN_STEP}1. Read the issue AND its comments first: \`gh issue view $ISSUE --comments\`. The
   thread is the coordination medium — a ruling settled there is not in the body.
2. Comment on the issue: "Tackled #$ISSUE on branch $BRANCH", plus anything a later
   reader genuinely needs. Keep it short; verbose comments poison every later run.
3. If ./CONTEXT-MAP.md exists, read it. It is a HINT, not a contract — a pointer to a
   file that moved costs you one failed Read, so ignore it where it disagrees with
   reality.
4. Build it TDD-first, and COMMIT AFTER EVERY GREEN SUB-STEP. That is the recovery
   mechanism, not hygiene: if this session is killed, its replacement resumes from
   your last commit instead of restarting the issue.
5. Run the project's done-check. It must be green.
6. Spawn the my-review agent (personal-tools:my-review) on your diff against $BASE.
   It posts its own review-round comment on the issue. Do NOT fix what it finds:
   a fresh session does that, so nobody is defending their own code.
7. REPORT, THEN STOP. Your plain text output is INVISIBLE to the orchestrator. You
   MUST use the SendMessage tool, addressed to "$ORCH", with exactly:
      issue $ISSUE built head=<sha> review=<H high, M medium, L low>
   or, if you could not finish:
      issue $ISSUE failed <one short line why>

Never merge, never open a PR, never close or edit the issue. If you are stuck on
something only a human can answer, SendMessage "$ORCH" with "issue $ISSUE escalate
<question>" and wait.
PROMPT
)"
else
    TASK="$(cat <<PROMPT
You are FIX ROUND $ROUND for issue #$ISSUE, run $RUNID. You did not write this code.

Worktree: $WORKTREE — branch $BRANCH. Work ONLY here.

1. \`gh issue view $ISSUE --comments\` and read the LATEST "Review round" comment.
   Those findings are your work order; the review already names file and line.
2. Fix them, TDD-first, committing after every green sub-step.
3. Run the project's done-check. It must be green.
4. Spawn the my-review agent (personal-tools:my-review) on the delta since the last
   review. It posts the next review-round comment.
5. REPORT, THEN STOP — plain output is invisible. SendMessage to "$ORCH":
      issue $ISSUE fixed round=$ROUND head=<sha> review=<H high, M medium, L low>
   or "issue $ISSUE failed <one short line why>".

Never merge, never open a PR, never close or edit the issue.
PROMPT
)"
fi

CMD=(claude --bg -n "$NAME"
     --model "$MODEL" --effort "$EFFORT"
     --permission-mode bypassPermissions
     --add-dir "$WORKTREE"
     --disallowedTools "Bash(git merge:*)" "Bash(git worktree:*)" "Bash(gh pr:*)"
                       "Bash(gh issue close:*)" "Bash(gh issue edit:*)"
     "$TASK")

# --dry-run prints ONE ARGUMENT PER LINE, unquoted — that is what makes the flag set
# assertable (`grep -Fx 'Bash(git merge:*)'`) instead of a shell-quoting exercise. The
# prompt is the last argument, so its own newlines land after everything else.
if [ -n "$DRY" ]; then
    printf '%s\n' "${CMD[@]}"
    exit 0
fi

[ -d "$WORKTREE" ] || die "worktree does not exist: $WORKTREE"
cd "$WORKTREE" || die "cannot enter worktree: $WORKTREE"
exec "${CMD[@]}"
