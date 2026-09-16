#!/usr/bin/env bash
#
# spawn.sh — start (or print) one `claude --bg` session, in one of two forms.
#
# A WORKER is one-shot and owns one issue; it exits when the issue is built. A PEER is
# a standing role session that idles between briefs and is rotated by handoff. Both are
# the same command with different framing, which is why they share one builder here:
# diverging them is how the three copies this kit replaces drifted apart
# (docs/swarm-design.md § Topology, § Charter, § Lifecycle).
#
# Usage:
#   bash spawn.sh <runid> <issue> <tier> <worktree> <base-branch> [options]   # worker
#   bash spawn.sh peer --name N --brief F --charter F --model M --effort E [options]
#
#   worker:
#     --role build|fix      build (default) or a fix round on an existing branch
#     --round N             fix-round number, quoted in the fix prompt (default 1)
#   peer:
#     --name NAME           the role name. This IS the session's stable address: a
#                           rotation stops the process and respawns under the same
#                           name, so no run prefix (§ Rotation).
#     --brief FILE          the role's standing brief; its TEXT becomes the prompt
#     --charter FILE        the team charter; its TEXT is appended to the system
#                           prompt. There is no --append-system-prompt-file on the
#                           CLI, so it is read here.
#     --handoff FILE        rotating a peer: prepend a read-this-first instruction
#                           naming the predecessor's handoff doc
#     --autocompact WINDOW  compaction backstop (default 400k, § Rotation)
#   both:
#     --orchestrator NAME   who the session reports to; resolved from this session
#                           when omitted (session-status.sh --self)
#     --dry-run             print the command instead of running it
#
# On a real spawn this EXECS claude, whose stdout is a short banner CONTAINING the
# new session's id (`claude stop <id>   stop this session`) — not a bare id, so do
# not parse it. Read the id from `session-status.sh <runid>`, column 2.
#
# You need it: `claude stop` and `claude attach` take that id — `Usage: claude stop
# <id>` — and reject a session NAME outright. The name addresses SendMessage; the id
# controls the process.
#
# Why each flag is here — these are the ways an unattended session dies quietly:
#
#   -n orch-<runid>-issue-<N>   worker only: the run prefix. `claude agents --json` is
#                               global and concurrent runs are intended; without it one
#                               run can stop another run's workers. A peer is named by
#                               its role instead — see --name above.
#   --permission-mode bypassPermissions
#                               an unattended session in manual or acceptEdits mode
#                               deadlocks on its FIRST prompt with nobody to answer.
#   --system-prompt-snapshot off
#                               `on` (the default) records the rendered system prompt on
#                               the conversation's first request and replays it verbatim
#                               forever, so a rotated peer would keep the charter text it
#                               was born with. Off re-renders it every request.
#   --add-dir <worktree>        worker only: fences the FILE tools to this issue's
#                               worktree. KNOWN LIMIT, ACCEPTED: it does not fence Bash.
#                               The containment is the denylist plus worktree isolation,
#                               not a sandbox. A peer works in the caller's cwd.
#   --disallowedTools ...       the irreversible, outward-facing writes stay on the
#                               main thread (#77: a close fired from a low-context
#                               worker was killed by a safety classifier, correctly).
#                               `git push` and `gh issue comment` are deliberately
#                               ALLOWED — a comment is additive, and the issue thread
#                               is the coordination medium. IDENTICAL for both forms:
#                               a peer has more standing, not more reach.
#   --model / --effort          a worker is routed by the issue's persisted tier, via
#                               resolve-tier.sh. A PEER IS NOT TIER-ROUTED — its roster
#                               row carries the model, so it passes them explicitly.
#   </dev/null                  an unattended session has nobody to answer a read on
#                               stdin, and one blocked on it looks exactly like one
#                               working.
#
# The prompt's last section is load-bearing for both forms: a session's plain text
# output is invisible to every other agent, so it is told, explicitly, to report with
# SendMessage. Miss that and whoever spawned it waits forever.
#
# `claude` has no --cwd, so a worker's session is started FROM its worktree.

set -uo pipefail

# infra's own scripts, BESIDE this one. `~/.claude/kit/infra` is how OTHER plugins reach
# infra (docs/swarm-design.md § Plugin split); infra finds itself by its own dir, which
# removes a live dependency on the SessionStart hook having already run.
INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "error: $*" >&2; exit 1; }

# `shift 2` with one argument left FAILS WITHOUT SHIFTING under `set -u` (no `-e`),
# and the loop then re-matches the same arm forever. The caller here is a model
# assembling argv by hand, so a dropped value is a live risk — and a hung dispatcher
# is exactly the silent stall this design is organized against. Demand the value.
need() { [ "$1" -ge 2 ] || die "$2 requires a value"; }

# Each form fills these, and the tail below builds one command out of them.
NAME=""; MODEL=""; EFFORT=""; TASK=""; ORCH=""; DRY=""; WORKTREE=""
EXTRA=()   # the per-form flags; never empty, so "${EXTRA[@]}" is safe under set -u

if [ "${1:-}" = peer ]; then
# ---------------------------------------------------------------------------
# PEER — a standing role session.
# ---------------------------------------------------------------------------
shift
BRIEF=""; CHARTER=""; HANDOFF=""; AUTOCOMPACT=400k
while [ $# -gt 0 ]; do
    case "$1" in
        --name)         need $# --name;         NAME="$2";        shift 2 ;;
        --brief)        need $# --brief;        BRIEF="$2";       shift 2 ;;
        --charter)      need $# --charter;      CHARTER="$2";     shift 2 ;;
        --model)        need $# --model;        MODEL="$2";       shift 2 ;;
        --effort)       need $# --effort;       EFFORT="$2";      shift 2 ;;
        --handoff)      need $# --handoff;      HANDOFF="$2";     shift 2 ;;
        --autocompact)  need $# --autocompact;  AUTOCOMPACT="$2"; shift 2 ;;
        --orchestrator) need $# --orchestrator; ORCH="$2";        shift 2 ;;
        --dry-run)      DRY=1; shift ;;
        *)              die "unknown flag $1" ;;
    esac
done
[ -n "$NAME" ]    || die "peer requires --name"
[ -n "$MODEL" ]   || die "peer requires --model"
[ -n "$EFFORT" ]  || die "peer requires --effort"
[ -n "$BRIEF" ]   || die "peer requires --brief"
[ -n "$CHARTER" ] || die "peer requires --charter"
# Fail on a missing OR EMPTY file HERE. Past this point the next stop is a live session
# whose system prompt silently lost its charter — the peer would run ungoverned and look
# fine. An empty file reads as present, so `-s`, not `-f`: a zero-byte charter appends
# nothing and a zero-byte brief spawns a session with no task at all.
[ -s "$BRIEF" ]   || die "brief file is missing or empty: $BRIEF"
[ -s "$CHARTER" ] || die "charter file is missing or empty: $CHARTER"
[ -z "$HANDOFF" ] || [ -s "$HANDOFF" ] || die "handoff file is missing or empty: $HANDOFF"

else
# ---------------------------------------------------------------------------
# WORKER — one issue, one-shot. Unchanged: callers pass the same argv as always.
# ---------------------------------------------------------------------------
[ $# -ge 5 ] || die "usage: spawn.sh <runid> <issue> <tier> <worktree> <base-branch> [--role build|fix] [--round N] [--orchestrator NAME] [--dry-run]
       spawn.sh peer --name NAME --brief FILE --charter FILE --model M --effort E [--handoff FILE] [--autocompact WINDOW] [--orchestrator NAME] [--dry-run]"

RUNID="$1"; ISSUE="${2#\#}"; TIER="$3"; WORKTREE="$4"; BASE="$5"
shift 5

ROLE=build
ROUND=1
while [ $# -gt 0 ]; do
    case "$1" in
        --role)         need $# --role;         ROLE="$2"; shift 2 ;;
        --round)        need $# --round;        ROUND="$2"; shift 2 ;;
        --orchestrator) need $# --orchestrator; ORCH="$2"; shift 2 ;;
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
[ -f "$INFRA/resolve-tier.sh" ] || die "missing infra sibling: $INFRA/resolve-tier.sh"
ROSTER="$(bash "$INFRA/resolve-tier.sh" "$TIER" 2>/dev/null)"
MODEL="$(printf '%s\n' "$ROSTER"  | sed -n 's/^implementer_model=//p'  | head -1)"
EFFORT="$(printf '%s\n' "$ROSTER" | sed -n 's/^implementer_effort=//p' | head -1)"
[ -n "$MODEL" ] && [ -n "$EFFORT" ] || die "could not resolve a roster for tier '$TIER'"

NAME="orch-$RUNID-issue-$ISSUE"
BRANCH="issue-$ISSUE"
fi

# The session's report address, for BOTH forms. A session that cannot name who it
# reports to reports into the void, so this fails LOUD rather than spawning a session
# nobody hears.
if [ -z "$ORCH" ]; then
    ORCH="$(bash "$INFRA/session-status.sh" --self 2>/dev/null)" \
        || die "could not resolve this session's name — pass --orchestrator NAME"
    [ -n "$ORCH" ] || die "could not resolve this session's name — pass --orchestrator NAME"
fi

if [ -z "$WORKTREE" ]; then
# ---------------------------------------------------------------------------
# The peer's prompt: [handoff instruction] + the brief + the report paragraph.
# ---------------------------------------------------------------------------
HANDOFF_BLOCK=""
if [ -n "$HANDOFF" ]; then
    HANDOFF_BLOCK="You are RESUMING the $NAME role. FIRST read your handoff at $HANDOFF, in
full: it is your predecessor's state — what is in flight, what is blocked, and what was
promised to whom. Then continue from there. Your standing role follows.

"
fi
TASK="$HANDOFF_BLOCK$(cat "$BRIEF")

REPORT WITH SendMessage. Your plain text output is INVISIBLE to every other session —
anything anyone else needs MUST go through the SendMessage tool, addressed to \"$ORCH\".
Stop every worker you spawn before you go idle."

EXTRA=(--append-system-prompt "$(cat "$CHARTER")" --autocompact "$AUTOCOMPACT")

else
# ---------------------------------------------------------------------------
# The worker's prompt: the issue protocol, build or fix.
# ---------------------------------------------------------------------------
EXTRA=(--add-dir "$WORKTREE")

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
   You are the implementer: follow the contract in
   plugins/workflow/agents/implementer.md — dedup-search before writing new code,
   build the slice's central mechanism FOR REAL, and if you genuinely must defer real
   wiring, DECLARE it: "Mocked: <what>. Real wiring blocked by: #N | deferred to
   integration", in the commit body and in your review comment. An undeclared central
   mock is the drift this whole loop exists to catch.
5. Run the project's done-check. It must be green.
6. Spawn the my-review agent (personal-tools:my-review) on your diff against $BASE.
   my-review is REPORT-ONLY — it posts nothing. YOU post its findings, as a comment
   in exactly this shape (the "Review round N" heading is the run's cycle counter;
   nothing else records how many rounds this issue has had):

      **Review round 1** — 1 high, 2 medium, 3 low

      - **high** \`path/file.py:42\` — one line, what is wrong and why it matters.
      - **medium** \`path/test_file.py\` — one line.

   Lows are listed, not fixed. Keep every line short: this comment is read by every
   future run that touches this issue. Do NOT fix what the review finds:
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
   Those findings are your work order; the review already names file and line. Fix the
   highs and mediums; lows are listed, not fixed.
2. Fix them, TDD-first, committing after every green sub-step.
3. Run the project's done-check. It must be green.
4. Spawn the my-review agent (personal-tools:my-review) on the delta since the last
   review, then POST its findings YOURSELF as the next "**Review round**" comment, in
   the same shape as the previous one, incrementing the round number. my-review is
   REPORT-ONLY; it posts nothing, and that comment is the run's cycle counter.
5. REPORT, THEN STOP — plain output is invisible. SendMessage to "$ORCH":
      issue $ISSUE fixed round=$ROUND head=<sha> review=<H high, M medium, L low>
   or "issue $ISSUE failed <one short line why>".

Never merge, never open a PR, never close or edit the issue.
PROMPT
)"
fi
fi

# `--` BEFORE THE PROMPT IS LOAD-BEARING. `--disallowedTools` is a VARIADIC option:
# it consumes every following non-option token, so a prompt placed after it is
# parsed as more deny rules, word by word. An unknown deny rule is only a WARNING,
# so with --bg there is no error at all — the session starts with NO TASK, does
# nothing, and goes idle. `idle` is this design's DONE signal for a background
# worker, so the orchestrator would read every never-started worker as finished and
# merge a run that built nothing. That is the silent-empty catastrophe, delivered by
# an argv ordering. Verified against the installed CLI, both the break and the fix.
CMD=(claude --bg -n "$NAME"
     --model "$MODEL" --effort "$EFFORT"
     --permission-mode bypassPermissions
     --system-prompt-snapshot off
     "${EXTRA[@]}"
     --disallowedTools "Bash(git merge:*)" "Bash(git worktree:*)" "Bash(gh pr:*)"
                       "Bash(gh issue close:*)" "Bash(gh issue edit:*)"
     -- "$TASK")

# --dry-run prints ONE ARGUMENT PER LINE, unquoted — that is what makes the flag set
# assertable (`grep -Fx 'Bash(git merge:*)'`) instead of a shell-quoting exercise. The
# prompt is the last argument, so its own newlines land after everything else.
if [ -n "$DRY" ]; then
    printf '%s\n' "${CMD[@]}"
    exit 0
fi

# `claude` has no --cwd. A worker is started FROM its worktree; a peer stays in the
# caller's cwd, which is the project root its role works in.
if [ -n "$WORKTREE" ]; then
    [ -d "$WORKTREE" ] || die "worktree does not exist: $WORKTREE"
    cd "$WORKTREE" || die "cannot enter worktree: $WORKTREE"
fi
# </dev/null: an unattended session must never inherit the caller's stdin. It has nobody
# to answer a read, and a session blocked on one looks exactly like a session working.
exec "${CMD[@]}" </dev/null
