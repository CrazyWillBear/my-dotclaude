#!/usr/bin/env bash
#
# spawn.sh — start (or print) one background agent, in one of two forms.
#
# A worker's TIER decides its BACKEND. `backend: claude` (and every peer) is a
# `claude --bg` session; `backend: codex` is a `codex exec` process instead — same
# contract, different everything else. See § CODEX below and docs/swarm-design.md
# § Codex backend. The shipped table routes trivial and standard through codex first
# (PRD #104); a user table at ${CLAUDE_CONFIG_DIR:-~/.claude}/model-tiers.json overrides it.
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
#     --attempt N           chain position (default 0). The tier's implementer cell is an
#                           ORDERED CHAIN (resolve-tier.sh, #104); escalate.sh decides a
#                           worker is out of its depth and the orchestrator respawns at
#                           attempt+1 on the SAME worktree. Past the top of the chain this
#                           script refuses — the orchestrator drains there, it never wraps.
#                           A respawn is told it is one: the **Handoff** comment on the
#                           thread and the branch's commits are its whole inheritance.
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
# On a real CLAUDE spawn this EXECS claude, whose stdout is a short banner CONTAINING
# the new session's id (`claude stop <id>   stop this session`) — not a bare id, so do
# not parse it. Read the id from `session-status.sh <runid>`, column 2.
#
# You need it: `claude stop` and `claude attach` take that id — `Usage: claude stop
# <id>` — and reject a session NAME outright. The name addresses SendMessage; the id
# controls the process. A CODEX spawn instead backgrounds the process, prints its run
# dir, and returns: column 2 is then a PID, which `claude stop` does not take. It is the
# WRAPPER's pid and its group leader, so stop it with a group kill — `kill -- -<pid>` —
# which takes codex with it; a plain `kill` orphans codex onto the worktree.
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
#                               is the coordination medium. `gh api` / `gh repo` /
#                               `gh workflow` / `gh release` are denied too: `gh api`
#                               can close, edit and merge, so denying `gh pr` alone
#                               fenced nothing. IDENTICAL for both forms: a peer has
#                               more standing, not more reach.
#   --model / --effort          a worker is routed by the issue's persisted tier, via
#                               resolve-tier.sh. A PEER IS NOT TIER-ROUTED — its roster
#                               row carries the model, so it passes them explicitly.
#   </dev/null                  an unattended session has nobody to answer a read on
#                               stdin, and one blocked on it looks exactly like one
#                               working.
#
# The prompt's last section is load-bearing for every form: an agent's plain text output
# is invisible to everyone else, so it is told, explicitly, how to report. A claude
# session reports with SendMessage. A codex worker HAS NO SendMessage — its report is
# the schema'd final message in `last-message.txt`, and its prompt says so instead.
# Miss that and whoever spawned it waits forever.
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

# Each form fills these, and the tail below builds one command out of them. BACKEND is
# claude unless a WORKER's tier row says codex — a peer needs an inbox and codex has none
# (docs/swarm-design.md § Deliberately not built), so the peer form never touches it.
NAME=""; MODEL=""; EFFORT=""; TASK=""; ORCH=""; DRY=""; WORKTREE=""; BACKEND=claude
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
# Fail on anything `cat` cannot turn into text HERE. Past this point the next stop is a
# live session whose system prompt silently lost its charter — the peer would run
# ungoverned and look fine. BOTH predicates, because each waves the other's case through:
# `-f` alone passes a zero-byte charter (appends nothing, empty brief = no task), and
# `-s` alone passes a DIRECTORY (nonzero size, `cat` fails to stderr, same empty prompt).
usable() { [ -f "$2" ] && [ -s "$2" ] || die "$1 file is missing or empty: $2"; }
usable brief   "$BRIEF"
usable charter "$CHARTER"
[ -z "$HANDOFF" ] || usable handoff "$HANDOFF"

else
# ---------------------------------------------------------------------------
# WORKER — one issue, one-shot. Unchanged: callers pass the same argv as always.
# ---------------------------------------------------------------------------
[ $# -ge 5 ] || die "usage: spawn.sh <runid> <issue> <tier> <worktree> <base-branch> [--role build|fix] [--round N] [--attempt N] [--orchestrator NAME] [--dry-run]
       spawn.sh peer --name NAME --brief FILE --charter FILE --model M --effort E [--handoff FILE] [--autocompact WINDOW] [--orchestrator NAME] [--dry-run]"

RUNID="$1"; ISSUE="${2#\#}"; TIER="$3"; WORKTREE="$4"; BASE="$5"
shift 5

ROLE=build
ROUND=1
ATTEMPT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --role)         need $# --role;         ROLE="$2"; shift 2 ;;
        --round)        need $# --round;        ROUND="$2"; shift 2 ;;
        --attempt)      need $# --attempt;      ATTEMPT="$2"; shift 2 ;;
        --orchestrator) need $# --orchestrator; ORCH="$2"; shift 2 ;;
        --dry-run)      DRY=1; shift ;;
        *)              die "unknown flag $1" ;;
    esac
done

case "$ISSUE" in ''|*[!0-9]*) die "issue must be a number, got '$ISSUE'" ;; esac
case "$ROLE" in build|fix) ;; *) die "role must be build or fix, got '$ROLE'" ;; esac
case "$ATTEMPT" in ''|*[!0-9]*) die "attempt must be a number, got '$ATTEMPT'" ;; esac
[ -n "$RUNID" ] || die "runid is required"
# Not just non-empty: $RUNID is joined into the codex run dir below, a path that reaches
# both `mkdir -p` and `rm -rf`, and the caller is a model assembling argv by hand. A `..`
# component would put both outside the run root. run-log.sh guards the identical value
# with this same case.
case "$RUNID" in .|..|*[!A-Za-z0-9._-]*) die "runid may only contain [A-Za-z0-9._-] and may not be . or .., got '$RUNID'" ;; esac
[ -n "$WORKTREE" ] || die "worktree is required"
[ -n "$BASE" ] || die "base branch is required"

# The tier's roster, at this attempt's chain position. resolve-tier.sh always exits 0 and
# always prints a roster (falling back to the claude-only one), so a broken
# model-tiers.json degrades to a working spawn rather than no spawn at all. An attempt
# PAST THE TOP is the one thing that does not degrade: the resolver falls back with
# chain=1, and 1 <= attempt is refused here — a wrapped chain would quietly rebuild on the
# cheapest model the exact issue that just defeated the strongest one.
[ -f "$INFRA/resolve-tier.sh" ] || die "missing infra sibling: $INFRA/resolve-tier.sh"
ROSTER="$(bash "$INFRA/resolve-tier.sh" "$TIER" "$ATTEMPT" 2>/dev/null)"
MODEL="$(printf '%s\n' "$ROSTER"  | sed -n 's/^implementer_model=//p'  | head -1)"
EFFORT="$(printf '%s\n' "$ROSTER" | sed -n 's/^implementer_effort=//p' | head -1)"
BACKEND="$(printf '%s\n' "$ROSTER" | sed -n 's/^implementer_backend=//p' | head -1)"
CHAIN="$(printf '%s\n' "$ROSTER"   | sed -n 's/^implementer_chain=//p'   | head -1)"
[ -n "$MODEL" ] && [ -n "$EFFORT" ] || die "could not resolve a roster for tier '$TIER'"
if [ "$ATTEMPT" -ge "${CHAIN:-1}" ]; then
    # The refused resolve fell back (chain=1); name the REAL length from the chain head.
    REAL="$(bash "$INFRA/resolve-tier.sh" "$TIER" 0 2>/dev/null | sed -n 's/^implementer_chain=//p' | head -1)"
    die "attempt $ATTEMPT is past the top of tier '$TIER' implementer chain (length ${REAL:-1}) — drain, do not respawn"
fi
# resolve-tier.sh validates the backend against the model and falls back rather than
# emit an unknown one, so anything that is not codex is the claude path.
[ "$BACKEND" = codex ] || BACKEND=claude

# The reviewer cell is resolved by review-cmd.sh, at the point the reviewer is built —
# not here. It used to be read here to interpolate `-m` into the worker's own review
# step, and that step is gone (§ CODEX below): the worker no longer reviews anything.

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

# STANDARD and COMPLEX build to a PLAN that is already on the thread (#104): consult.sh
# runs the planner as a one-shot call on the planner cell's model BEFORE this spawn and
# posts a **Plan** comment, so a cheap implementer executes a plan a smart one wrote, and
# the plan reaches the worker the way everything does — by reading the issue. The
# orchestrator never reads it. Trivial self-plans. The one rule that makes the split safe:
# a false plan assumption is a STOP, never an improvisation — the worker posts a
# **Deviation** comment and pauses (status escalate), a consult on the planner's model
# answers it, and the worker is resumed with the decision.
PLAN_STEP=""
if [ "$TIER" != trivial ]; then
    PLAN_STEP="0. A \"**Plan**\" comment is on the thread. FOLLOW IT step by step — it was written on a
   stronger model so that executing it is near-mechanical. If a plan assumption turns out
   FALSE, do NOT improvise: post a comment headed \"**Deviation**\" (which step, what you
   found, what you tried) and STOP with status \"escalate\" and \"note\" = \"deviation: \"
   followed by the same three lines — the \"deviation: \" prefix is how the orchestrator
   tells a deviation from a question. A \"**Consult**\" answers it; follow that decision
   when you are resumed.
"
fi
# A RESPAWN (attempt > 0) replaces a worker escalate.sh judged out of its depth. It is
# told so: the thread's **Handoff** comment says why and what landed, and the branch
# carries every committed sub-step. It never restarts the issue.
HANDOFF_STEP=""
if [ "$ATTEMPT" -gt 0 ]; then
    HANDOFF_STEP="You are ATTEMPT $((ATTEMPT + 1)) on this issue: a previous worker was replaced. The
thread carries a \"**Handoff**\" comment (why, the commits landed, its last activity) plus
the plan, every deviation and every consult. Read them, then continue from the branch's
last commit — never restart the issue.

"
fi

# How the worker REVIEWS and how it REPORTS are the two steps the backend changes, and
# they are the two that strand the run when they are wrong. A codex worker has no
# SendMessage tool and no subagents: telling it to use either produces a session that
# finishes the work and then reports into nothing, which reads to the orchestrator
# exactly like a worker still thinking. Its final message IS its report (`--output-schema`
# forces the shape), and the claude reviewer is run FOR it as a sibling process after it
# exits (review-cmd.sh; docs/swarm-design.md § Codex backend).
if [ "$BACKEND" = codex ]; then
    # DO NOT tell the worker to review itself. It was told exactly that until #96's e2e
    # gate caught what happens: `codex exec review` NESTED inside this worker's own
    # sandbox always fails ("failed to initialize in-process app-server client: Read-only
    # file system") because ~/.codex is not among its writable_roots — and the worker,
    # holding a required `review` field it had to fill, substituted its OWN judgement of
    # its OWN diff and reported "0 high, 0 medium, 0 low" as though the independent
    # reviewer had run. Nothing downstream could tell the difference.
    #
    # The review now runs as a SIBLING process after this worker exits (REVIEW_CMD
    # below), which fixes both halves: a top-level codex invocation is not inside anyone's
    # sandbox, and the verdict never passes through the thing that wrote the code. The
    # worker therefore reports an EMPTY review — worker-report.sh takes the counts from
    # the reviewer's own output file and ignores this field entirely.
    REVIEW_STEP="6. Do NOT review your own diff, and do NOT run \`codex exec review\` — a nested codex
   invocation cannot start inside your sandbox, and your own opinion of your own work is
   not a review. An INDEPENDENT reviewer runs automatically once you exit and posts the
   \"**Review round**\" comment itself. Skip straight to reporting"
    REPORT_STEP="7. REPORT, THEN STOP. You have NO SendMessage tool and your prose reaches nobody.
   Your FINAL MESSAGE is the report, and it must be JSON matching the output schema you
   were launched with. EVERY field is required — send \"\" or 0 for the ones that do
   not apply. \"review\" is one of those: you did not review, so send \"\" and never a
   count you made up:
      {\"issue\": $ISSUE, \"status\": \"built\", \"round\": 0, \"head\": \"<sha>\", \"review\": \"\", \"note\": \"\"}
   or, if you could not finish, \"status\": \"failed\" with the reason in \"note\". Stuck
   on something only a human can answer? \"status\": \"escalate\", question in \"note\"."
    FIX_REVIEW_STEP="4. Do NOT re-review the delta yourself. The independent reviewer runs again after
   you exit and posts the next round's comment"
    FIX_REPORT_STEP="5. REPORT, THEN STOP. You have NO SendMessage tool — your FINAL MESSAGE is the
   report, as JSON matching the output schema you were launched with. Every field is
   required; send \"\" for any that does not apply, \"review\" included — the reviewer
   fills that in, not you:
      {\"issue\": $ISSUE, \"status\": \"fixed\", \"round\": $ROUND, \"head\": \"<sha>\", \"review\": \"\", \"note\": \"\"}
   or the same shape with \"status\": \"failed\" and the reason in \"note\"."
else
    REVIEW_STEP="6. Spawn the my-review agent (personal-tools:my-review) on your diff against $BASE.
   my-review is REPORT-ONLY — it posts nothing. YOU post its findings, as a comment
   in exactly this shape (the \"Review round N\" heading is the run's cycle counter;
   nothing else records how many rounds this issue has had):

      **Review round 1** — 1 high, 2 medium, 3 low

      - **high** \`path/file.py:42\` — one line, what is wrong and why it matters.
      - **medium** \`path/test_file.py\` — one line.

   Lows are listed, not fixed. Keep every line short: this comment is read by every
   future run that touches this issue. Do NOT fix what the review finds:
   a fresh session does that, so nobody is defending their own code."
    REPORT_STEP="7. REPORT, THEN STOP. Your plain text output is INVISIBLE to the orchestrator. You
   MUST use the SendMessage tool, addressed to \"$ORCH\", with exactly:
      issue $ISSUE built head=<sha> review=<H high, M medium, L low>
   or, if you could not finish:
      issue $ISSUE failed <one short line why>

Never merge, never open a PR, never close or edit the issue. If you are stuck on
something only a human can answer, SendMessage \"$ORCH\" with \"issue $ISSUE escalate
<question>\" and wait."
    FIX_REVIEW_STEP="4. Spawn the my-review agent (personal-tools:my-review) on the delta since the last
   review, then POST its findings YOURSELF as the next \"**Review round**\" comment, in
   the same shape as the previous one, incrementing the round number. The reviewer
   POSTS NOTHING itself, and that comment is the run's cycle counter."
    FIX_REPORT_STEP="5. REPORT, THEN STOP — plain output is invisible. SendMessage to \"$ORCH\":
      issue $ISSUE fixed round=$ROUND head=<sha> review=<H high, M medium, L low>
   or \"issue $ISSUE failed <one short line why>\"."
fi

if [ "$ROLE" = build ]; then
    TASK="$(cat <<PROMPT
You are the BUILD session for issue #$ISSUE, run $RUNID.

${HANDOFF_STEP}Worktree: $WORKTREE — branch $BRANCH, cut from $BASE. Work ONLY here; never touch
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
$REVIEW_STEP
$REPORT_STEP

Never merge, never open a PR, never close or edit the issue.
PROMPT
)"
else
    TASK="$(cat <<PROMPT
You are FIX ROUND $ROUND for issue #$ISSUE, run $RUNID. You did not write this code.

${HANDOFF_STEP}Worktree: $WORKTREE — branch $BRANCH. Work ONLY here.

1. \`gh issue view $ISSUE --comments\` and read the LATEST "Review round" comment.
   Those findings are your work order; the review already names file and line. Fix the
   highs and mediums; lows are listed, not fixed.
2. Fix them, TDD-first, committing after every green sub-step. If a finding names a
   fact that's true anywhere else in the codebase too — not a mistake local to this
   line — grep the repo for other instances of the same pattern and fix those in the
   same round. If that fact isn't already written down where the project's CLAUDE.md
   says such facts live (a schema doc, a \`## Decisions\` section), add a one-line note
   there in the same commit, so the next issue that touches it doesn't relearn it. If
   CLAUDE.md names no such place, skip the doc note — don't invent a new doc for it.
3. Run the project's done-check. It must be green.
$FIX_REVIEW_STEP
$FIX_REPORT_STEP

Never merge, never open a PR, never close or edit the issue.
PROMPT
)"
fi
fi

if [ "$BACKEND" = codex ]; then
# ---------------------------------------------------------------------------
# CODEX — a one-shot worker through `codex exec`. Worker form only; verified against
# codex-cli 0.154 (docs/swarm-design.md § Codex backend).
#
# Codex has NO agent list, so unlike a claude session there is nothing to ask about its
# state afterwards. These four files ARE the session: the `--json` event stream, the `-o`
# final message (shaped by --output-schema), the pid, and the exit code.
# session-status.sh reads exactly this layout.
# ---------------------------------------------------------------------------
[ -d "$WORKTREE" ] || die "worktree does not exist: $WORKTREE"

# THE SHIPPED TABLE IS CODEX-FIRST (#104), and this kit installs on other machines. Without
# this check a missing CLI surfaces as a generic `failed` worker with no hint why. On the
# real path only: a dry run must build its argv without the binary, as the tests do.
if [ -z "$DRY" ] && ! command -v codex >/dev/null 2>&1; then
    die "tier '$TIER' attempt $ATTEMPT routes to codex but the codex CLI is not installed — write a claude-only table at \${CLAUDE_CONFIG_DIR:-~/.claude}/model-tiers.json"
fi

# Workspace-write keeps `.git` READ-ONLY. For a linked worktree the objects and refs
# live in the MAIN repo's common git dir, so without it listed the worker does the whole
# issue and then cannot commit — and says so only in its final message. Fail here
# instead: a worker that cannot commit has nothing to hand back.
# One script, not two copies: worker-resume.sh needs the IDENTICAL value, and a resume
# that computes it even slightly differently hands the worker a different writable root
# than its spawn did. `--roots` prints the NARROWED set — objects, refs, logs and this
# worktree's own git dir, but NOT hooks/ or config, the two things git executes — or dies
# loudly. See common-git-dir.sh for why the whole common dir is not granted.
WRITABLE_ROOTS="$(bash "$INFRA/common-git-dir.sh" --roots "$WORKTREE")" || exit 1

# Nothing is CREATED here — only named. A dry run must leave no trace: a run dir with
# no pid in it is a worker session-status.sh reports as BUSY (the launch-window rule —
# session-status.sh:238-247), so the phantom a dry run left behind is waited on forever.
RUNDIR="${CODEX_RUN_ROOT:-${HOME:-/nonexistent}/.claude/codex-runs}/$RUNID/issue-$ISSUE"

# `-m` is not optional: without it a resumed thread silently falls back to the config's
# default model, which is not the tier's. Scalar `-c` values are bare (that is what the
# verified shell command delivered); writable_roots is a TOML array and keeps its
# brackets and quotes.
#
# network_access is not optional either: workspace-write is OFFLINE by default, and this
# worker's prompt orders `gh issue view`, `gh issue comment`, `git push` and the done-check.
# Every one of them may need the network, and `approval_policy=never` means the worker
# cannot ask for it back — it would fail its whole protocol silently.
CMD=(codex exec
     -C "$WORKTREE"
     -m "$MODEL"
     -c "model_reasoning_effort=$EFFORT"
     -c "approval_policy=never"
     -s workspace-write
     -c "sandbox_workspace_write.writable_roots=$WRITABLE_ROOTS"
     -c "sandbox_workspace_write.network_access=true"
     --json
     -o "$RUNDIR/last-message.txt"
     --output-schema "$RUNDIR/status-schema.json"
     "$TASK")

# THE INDEPENDENT REVIEWER. A SIBLING of the worker, never its child: the wrapper below
# runs it only after the worker's process has exited, so it starts on the host with a
# normal filesystem instead of inside the worker's read-only sandbox — which is the whole
# reason the worker's own review step could never work (#96). It is CLAUDE, at the tier's
# reviewer cell, spawning my-review (#104) — `codex exec review` could not honour a claude
# reviewer cell, so "reviewer: opus" was silently false for every codex worker.
#
# Built by review-cmd.sh, not here, for the reason common-git-dir.sh --roots is shared:
# worker-resume.sh must run the IDENTICAL reviewer, and a second copy that drifted would
# still produce a confident, well-formatted verdict at the wrong model.
[ -f "$INFRA/review-cmd.sh" ] || die "missing infra sibling: $INFRA/review-cmd.sh"

# THE BASE IS PINNED TO A COMMIT, HERE, BEFORE THE WORKER RUNS. `refs/` is one of the
# writable roots the worker is granted, so a worker that ran `git branch -f $BASE HEAD`
# would empty its own diff and an honest reviewer would return a clean verdict on it —
# the same "graded its own work" outcome as the self-review, reached through git instead.
# A SHA resolved before the worker starts cannot be moved by anything the worker does.
BASE_SHA="$(git -C "$WORKTREE" rev-parse --verify "$BASE^{commit}" 2>/dev/null)" \
    || die "cannot resolve base branch '$BASE' to a commit in $WORKTREE"

# The reviewer prints its verdict to STDOUT; the wrapper below captures it to review.txt
# and points TMPDIR at a scratch dir beside the disposable checkout (#99) — both created
# only on the non-dry-run path, so a dry run still touches no disk.
# NUL-delimited, never newline-split: the prompt is one multi-line argument, and a line
# reader would hand claude the first line of it (review round 2). An empty array is
# review-cmd.sh's failure (it prints nothing on stdout then), and its stderr passes through.
# `read -d ''`, NOT `mapfile -d ''`: mapfile is bash 4+, and macOS ships bash 3.2 while
# README.md and AGENT_SETUP.md both promise macOS (swarm.sh records the same rule).
REVIEW_CMD=()
while IFS= read -r -d '' _arg; do REVIEW_CMD+=("$_arg"); done \
    < <(bash "$INFRA/review-cmd.sh" "$TIER" "$BASE_SHA" "$ISSUE")
[ "${#REVIEW_CMD[@]}" -gt 0 ] || die "could not build the reviewer command for tier '$TIER'"

# One argument per line, and the reviewer's argv after a `--REVIEW--` marker: the review
# is now half of what a codex spawn DOES, so a dry run that showed only the worker would
# stop proving what this script runs.
if [ -n "$DRY" ]; then
    printf '%s\n' "${CMD[@]}"
    printf '%s\n' --REVIEW--
    printf '%s\n' "${REVIEW_CMD[@]}"
    exit 0
fi

mkdir -p "$RUNDIR" || die "cannot create codex run dir: $RUNDIR"

# THE RUN DIR IS REUSED. Its path carries the runid and the issue but NOT the round, so a
# fix round — and any recovery respawn — lands on the previous turn's `exit` and
# `last-message.txt`. The wrapper below truncates events.jsonl and stderr.log with `>`,
# but these two survive, and they are exactly what the orchestrator reads: session-status.sh
# treats any `exit` file as terminal, so worker-report.sh's FIRST poll would return the
# PREVIOUS turn's report, instantly, as this turn's result — while this worker is still
# writing the worktree. A stale `H > 0` then draws a second fix round onto the same
# worktree; a stale clean one sends the issue to the merge queue mid-build.
# `pid` goes too. Between here and the `printf … >"$RUNDIR/pid"` below, the dir would
# otherwise hold the PREVIOUS turn's dead pid with no exit file — which session-status.sh
# reads as `failed`, inventing a failure for a worker that is merely still launching.
# With it gone the same window has no pid at all, which is the launch-window case that
# already reads `busy` — the safe direction, and the one this script argues for elsewhere.
# `review.txt` goes with them, and for the sharpest version of the same reason: it is now
# the ONLY source of the finding counts, and worker-report.sh reads it the moment `exit`
# appears. A fix round that left the previous round's review in place would be handed the
# verdict on the code it was spawned to CHANGE — a stale "0 high" sending a branch whose
# fixes were never looked at straight to the merge queue. review-stderr.log goes too: the
# missing-review error quotes its tail, and a stale one would explain this run's refusal
# with the previous round's reason.
rm -f "$RUNDIR/last-message.txt" "$RUNDIR/exit" "$RUNDIR/pid" "$RUNDIR/reviewing" \
      "$RUNDIR/review.txt" "$RUNDIR/review-stderr.log"

# The worker's fixed-shape status report. `--output-schema` is what turns the final
# message from prose into something a caller can read without a model in the loop.
# EVERY property is required and additionalProperties is false: that is strict
# structured-output shape, and a schema that leaves a property optional is rejected
# outright rather than relaxed. Unused fields come back empty — the prompt says so.
# On failure the dir goes with it: a pidless run dir is BUSY forever to session-status.sh,
# so leaving one behind stalls /orchestrate's recovery gate with no way out.
cat >"$RUNDIR/status-schema.json" <<'SCHEMA' || { rm -rf "$RUNDIR"; die "cannot write $RUNDIR/status-schema.json"; }
{
  "type": "object",
  "properties": {
    "issue":  { "type": "integer" },
    "status": { "type": "string", "enum": ["built", "fixed", "failed", "escalate"] },
    "round":  { "type": "integer" },
    "head":   { "type": "string" },
    "review": { "type": "string" },
    "note":   { "type": "string" }
  },
  "required": ["issue", "status", "round", "head", "review", "note"],
  "additionalProperties": false
}
SCHEMA


# Wrapped so the recorded pid stays alive until the exit code is written:
# session-status.sh reads "pid alive" as busy, and a gap between the process ending and
# the exit file appearing would read as a worker that died without a code.
#
# `set -m`, not a bare `&`, because THE RECORDED PID MUST BE KILLABLE. It names the
# WRAPPER; codex is its child. `kill $pid` on its own reaps the wrapper, orphans codex
# onto the worktree, and writes no exit file — which session-status.sh reads as `failed`,
# clearing /orchestrate's respawn gate for a second worker on a worktree the orphan is
# still writing. And a bare `&` leaves the wrapper in SPAWN.SH'S OWN process group, so
# the obvious fix — kill the group — would take the orchestrator down with it. Job control
# puts a background job in a NEW group led by the pid `$!` reports, so `kill -- -$pid`
# reaches codex and nothing else.
#
# `set -m` is a bash builtin and deliberately NOT `setsid`, which is util-linux: macOS
# ships none, and README.md and AGENT_SETUP.md both promise macOS. A non-interactive
# shell prints no job-control notification, and test_spawn.sh proves the group — with
# setsid shimmed out — rather than trusting either claim.
#
# Its own stdout/stderr go to /dev/null: a background worker holding the caller's `$( )`
# pipe open for its whole run turns this spawn into a blocking wait.
# </dev/null because codex BLOCKS FOREVER on an open stdin.
#
# The wrapper runs TWO processes in sequence: the worker, then the independent reviewer.
# ORDER IS THE CONTRACT. `exit` is what session-status.sh calls terminal and what makes
# worker-report.sh read the run, so it is written LAST — after the review has landed.
# Writing it between the two would hand the orchestrator a report whose review file does
# not exist yet, which worker-report.sh correctly refuses, turning every healthy run into
# a failure.
#
# The review runs only when the worker exited 0. A crashed worker has no branch worth
# reviewing, and `exit` still carries its real code.
#
# FAIL CLOSED: if the reviewer itself fails, its half-written output is DELETED rather
# than left behind. worker-report.sh reads a missing review.txt as "no review happened"
# and refuses the run — which is the whole point of this change. A truncated review left
# in place could carry a COUNTS line from the middle of an aborted run.
#
# `gh issue comment` posts the reviewer's findings verbatim, from the worktree so gh
# resolves the repo. This keeps the issue thread as the coordination medium exactly as
# before — the fix-round worker still reads the latest "**Review round**" comment and
# cannot tell that a different process wrote it. A failed POST is recorded but does not
# fail the run: the counts still reached worker-report.sh, and a lost comment costs the
# fix round its detail, not its correctness.
set -m
bash -c '
    rundir=$1; worktree=$2; issue=$3; round=$4; roots=$5; counter=$6; shift 6
    worker=()
    while [ $# -gt 0 ] && [ "$1" != "--REVIEW--" ]; do worker+=("$1"); shift; done
    [ $# -eq 0 ] || shift
    review=("$@")
    "${worker[@]}" >"$rundir/events.jsonl" 2>"$rundir/stderr.log" </dev/null
    rc=$?
    # Anything the worker may have left at the reviewer path is gone before the reviewer
    # writes: with a non-default CODEX_RUN_ROOT the run dir can land somewhere the worker
    # could reach, and a planted verdict must never outlive the worker that planted it. The
    # disposable checkout and scratch dir go too, for the same reason and for a crashed
    # PREVIOUS round of the same reused run dir (#99) — a worker-planted checkout would be
    # a repo the reviewer is fooled into trusting.
    rm -rf "$rundir/review.txt" "$rundir/review-checkout" "$rundir/review-scratch"
    # THE WORKER IS DONE; THE REVIEW MAY TAKE A WHILE. `reviewing` tells escalate.sh that a
    # frozen event log from here on is not a stall — the worker process is gone and the
    # sibling reviewer is what the live pid is doing. Removed just before `exit` lands.
    : >"$rundir/reviewing"
    # Reviewed only when the worker SAYS it built or fixed something. `escalate` and
    # `failed` also exit 0, and reviewing those posts a "Review round" comment on a
    # half-built branch — which the orchestrate lane counts as a spent cycle.
    built=""
    grep -q "\"status\"[[:space:]]*:[[:space:]]*\"\\(built\\|fixed\\)\"" \
        "$rundir/last-message.txt" 2>/dev/null && built=1
    if [ "$rc" -eq 0 ] && [ -n "$built" ] && [ "${#review[@]}" -gt 0 ]; then
        # TRIPWIRE. The worker could rewrite $OWN/commondir (the accepted residual in
        # common-git-dir.sh) to point git at a config it controls. The CLONE below is now
        # the FIRST host process to run git in that worktree afterwards, unattended —
        # `core.fsmonitor` in a planted config fires on the clone'\''s first read.
        # Re-running --roots re-checks the containment and refuses a worktree that no
        # longer passes, before any git runs there.
        if bash "$roots" --roots "$worktree" >/dev/null 2>>"$rundir/review-stderr.log"; then
            # THE REVIEW NEVER RUNS FROM $worktree ITSELF (#99): the reviewer may run the
            # project'\''s done-check, and it is fenced by a prefix-pattern tool denylist and
            # its prompt, NOT a sandbox (an accepted gap — docs/swarm-design.md § Roster), so
            # it runs in a DISPOSABLE clone instead — `--shared` costs no object copy, and the
            # commit range diffs identically there. TMPDIR points a test runner at the
            # scratch dir beside it. The verdict is the reviewer'\''s STDOUT, captured to
            # review.txt; its stderr is the diagnostic worker-report.sh quotes on a refusal.
            mkdir -p "$rundir/review-scratch" \
                && git clone --quiet --shared -- "$worktree" "$rundir/review-checkout" \
                    >/dev/null 2>>"$rundir/review-stderr.log"
            if [ -d "$rundir/review-checkout" ] && (cd "$rundir/review-checkout" \
                    && TMPDIR="$rundir/review-scratch" "${review[@]}") \
                    >"$rundir/review.txt" 2>>"$rundir/review-stderr.log" </dev/null; then
                # The heading is counted by review-counts.sh — the SAME script
                # worker-report.sh reads the verdict with, so the comment on the issue and
                # the report the merge queue acts on can never disagree.
                counts="$(bash "$counter" "$rundir/review.txt" 2>>"$rundir/review-stderr.log")"
                if [ -n "$counts" ]; then
                    { printf "**Review round %s** — %s\n\n" "$round" "$counts"
                      cat "$rundir/review.txt"; } >"$rundir/review-comment.md"
                    (cd "$worktree" && gh issue comment "$issue" \
                        --body-file "$rundir/review-comment.md") \
                        >/dev/null 2>>"$rundir/review-stderr.log" </dev/null \
                        || printf "REVIEW_COMMENT_POST_FAILED\n" >>"$rundir/review-stderr.log"
                else
                    printf "REVIEW_UNREADABLE\n" >>"$rundir/review-stderr.log"
                fi
            else
                printf "REVIEW_FAILED rc=%s\n" "$?" >>"$rundir/review-stderr.log"
                rm -f "$rundir/review.txt"
            fi
            rm -rf "$rundir/review-checkout" "$rundir/review-scratch"
        else
            printf "REVIEW_SKIPPED containment check refused the worktree\n" \
                >>"$rundir/review-stderr.log"
            rm -f "$rundir/review.txt"
        fi
    fi
    rm -f "$rundir/reviewing"
    printf "%s\n" "$rc" >"$rundir/exit"' \
    _ "$RUNDIR" "$WORKTREE" "$ISSUE" "$ROUND" "$INFRA/common-git-dir.sh" \
       "$INFRA/review-counts.sh" \
    "${CMD[@]}" --REVIEW-- "${REVIEW_CMD[@]}" \
    >/dev/null 2>&1 &
set +m
printf '%s\n' "$!" >"$RUNDIR/pid"
printf '%s\n' "$RUNDIR"
exit 0
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
                       "Bash(gh api:*)" "Bash(gh repo:*)" "Bash(gh workflow:*)" "Bash(gh release:*)"
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
