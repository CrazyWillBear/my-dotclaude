#!/usr/bin/env bash
#
# consult.sh — one-shot call on the PLANNER cell's model that reads the issue thread and
# the worktree read-only, and posts ONE comment. Two roles, one mechanism (#104):
#
#   plan     BEFORE the build worker is spawned (standard and complex): write the plan a
#            cheaper implementer executes near-mechanically, posted as `**Plan**`.
#   consult  AFTER a worker paused on a `**Deviation**` comment: decide what the worker
#            does next, with revised steps if the plan is wrong from that step on, posted
#            as `**Consult N**` — N counts the consults already on the thread, so
#            escalate.sh can cap them by reading the same heading.
#
# Usage:
#   bash consult.sh plan    <runid> <issue> <tier> <worktree> [--dry-run]
#   bash consult.sh consult <runid> <issue> <tier> <worktree> [--dry-run]
#
# Output: one line on stdout naming what was posted (`**Plan** posted on #N` /
# `**Consult N** posted on #N`). Exit 1, NOTHING posted, when the model produced no text,
# the call failed, or the comment could not be posted — an empty plan on the thread would
# read to the worker as "there is no plan", which is worse than no comment at all.
#
# WHY A SCRIPT AND NOT THE ORCHESTRATOR. A plan is prose, and prose the orchestrator reads
# is prose in its context for the rest of the run. This runs `claude -p` on the ORCHESTRATOR
# side (a codex worker's sandbox may not be able to write ~/.claude), writes the output to
# the thread, and hands the orchestrator one line. The worker reads the plan the way it reads
# everything else. The consult's decision goes back to a paused codex worker through
# worker-resume.sh --answer, which is the existing escalate-and-resume path.
#
# READ-ONLY IN THE WORKTREE, by tool denylist: no Edit/Write, no commit/push/merge, and no
# GitHub write but the one comment THIS script posts. `--permission-mode bypassPermissions`
# is what lets an unattended `-p` call run Read/Grep/Bash at all — the same reasoning as
# spawn.sh, and the same accepted limit: Bash is fenced by the denylist, not a sandbox.
# ponytail: read-only is a denylist, not a sandbox; a codex-style sandbox if a plan ever edits.
#
# The planner cell must be claude-backed: this is a `claude -p` call. A user table that
# points the planner at codex is refused here rather than half-honoured.

set -uo pipefail

INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "error: $*" >&2; exit 1; }

USAGE="usage: consult.sh plan|consult <runid> <issue> <tier> <worktree> [--dry-run]"
ROLE="${1:-}"; RUNID="${2:-}"; ISSUE="${3:-}"; ISSUE="${ISSUE#\#}"; TIER="${4:-}"; WORKTREE="${5:-}"
shift 5 2>/dev/null || die "$USAGE"
DRY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        *) die "unknown flag $1" ;;
    esac
done
case "$ROLE" in plan|consult) ;; *) die "$USAGE" ;; esac
[ -n "$RUNID" ] && [ -n "$TIER" ] && [ -n "$WORKTREE" ] || die "$USAGE"
case "$ISSUE" in ''|*[!0-9]*) die "issue must be a number, got '$ISSUE'" ;; esac
case "$RUNID" in *[!A-Za-z0-9._-]*) die "runid may only contain [A-Za-z0-9._-], got '$RUNID'" ;; esac
[ -d "$WORKTREE" ] || die "worktree does not exist: $WORKTREE"

[ -f "$INFRA/resolve-tier.sh" ] || die "missing infra sibling: $INFRA/resolve-tier.sh"
ROSTER="$(bash "$INFRA/resolve-tier.sh" "$TIER" 2>/dev/null)"
MODEL="$(printf '%s\n'   "$ROSTER" | sed -n 's/^planner_model=//p'   | head -1)"
EFFORT="$(printf '%s\n'  "$ROSTER" | sed -n 's/^planner_effort=//p'  | head -1)"
BACKEND="$(printf '%s\n' "$ROSTER" | sed -n 's/^planner_backend=//p' | head -1)"
[ -n "$MODEL" ] && [ -n "$EFFORT" ] || die "could not resolve a planner cell for tier '$TIER'"
[ "$BACKEND" = claude ] || die "tier '$TIER' planner is backend '$BACKEND' — consult.sh is a claude -p call and needs a claude planner cell"

# The consult number comes from the THREAD, never from a counter kept here: the heading is
# what escalate.sh counts, so the two can never disagree. `gh` resolves the repo from the
# worktree. A plan has no number — there is one per issue.
N=""
if [ "$ROLE" = consult ]; then
    THREAD="$(cd "$WORKTREE" && gh issue view "$ISSUE" --json comments 2>/dev/null </dev/null)" \
        || die "could not read issue #$ISSUE's comments"
    N="$(printf '%s' "$THREAD" | THREAD_STDIN=1 python3 -c '
import json, re, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(1)
n = 0
for c in doc.get("comments") or []:
    if re.search(r"(?m)^\*\*Consult \d+\*\*", str(c.get("body") or "")):
        n += 1
print(n + 1)
')" || die "could not parse issue #$ISSUE's comments"
fi

if [ "$ROLE" = plan ]; then
    HEADING="**Plan**"
    PROMPT="You are the PLANNER for issue #$ISSUE (tier $TIER), run $RUNID. You plan; you never edit.
A CHEAPER model will execute your plan near-mechanically, so make every decision it would
otherwise have to make.

1. Read the issue AND its comments: \`gh issue view $ISSUE --comments\`. If the body says
   \`Part of #M\`, read that PRD too (\`gh issue view M\`). A ruling settled in a comment
   is not in the body.
2. Read the code you are planning against, in this worktree (cwd), read-only. Every
   file path in the plan must exist or be marked NEW. Prefer extending an existing helper
   over new code, and name the helper.
3. Find the project's done-check command in its CLAUDE.md / STYLEGUIDE.md / CI config
   and quote it. If the project defines no checks, say so.

OUTPUT ONLY THE PLAN, as markdown, with exactly these sections:
- **Steps** — ordered; each names the file path(s), the function signature(s) to add or
  change, and the test to write FIRST for it.
- **## Acceptance criteria** — testable, checkable, this heading verbatim.
- **Done-check** — the command, quoted.
- **Assumptions** — every fact this plan rests on that you could not verify. The
  implementer STOPS and asks when one of these turns out false, so list them honestly.
- **Risks / unknowns**.

Smallest plan that fully satisfies the issue. No speculative scope. Post nothing yourself —
the caller posts your output to the issue."
else
    HEADING="**Consult $N**"
    PROMPT="You are CONSULT $N for issue #$ISSUE (tier $TIER), run $RUNID. A worker executing the
**Plan** on this issue hit a false plan assumption, posted a **Deviation** comment, and
paused. You decide what it does next; you never edit.

1. Read the thread: \`gh issue view $ISSUE --comments\` — the **Plan**, EVERY **Deviation**
   (the newest is the one you answer), and every earlier **Consult**.
2. Read the worktree (cwd) read-only: \`git log --oneline\` and \`git diff\` against the
   base show what has landed so far. Verify the deviation against the code, not the
   worker's summary.

OUTPUT ONLY THE DECISION, as markdown:
- **Decision** — what the worker does next, concretely, in one short paragraph.
- **Revised steps** — ONLY if the plan is wrong from this step on: the replacement steps
  in the plan's own shape (paths, signatures, tests first). Otherwise write \`none\`.
- **Assumptions** — anything this decision rests on that you could not verify.

The worker is resumed with your text as its answer and follows it. Post nothing yourself —
the caller posts your output to the issue."
fi

# `--` before the prompt: --disallowedTools is variadic and would eat it (spawn.sh has the
# full story). `-p` prints the final text to stdout, which is the whole point.
CMD=(claude -p
     --model "$MODEL" --effort "$EFFORT"
     --permission-mode bypassPermissions
     --add-dir "$WORKTREE"
     --disallowedTools Edit Write NotebookEdit
                       "Bash(git commit:*)" "Bash(git push:*)" "Bash(git merge:*)"
                       "Bash(git worktree:*)" "Bash(gh issue comment:*)"
                       "Bash(gh issue close:*)" "Bash(gh issue edit:*)" "Bash(gh pr:*)"
                       "Bash(gh api:*)" "Bash(gh repo:*)" "Bash(gh workflow:*)" "Bash(gh release:*)"
     -- "$PROMPT")

if [ -n "$DRY" ]; then
    printf '%s\n' "${CMD[@]}"
    exit 0
fi

TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

# </dev/null: an unattended -p call has nobody to answer a read on stdin.
( cd "$WORKTREE" && "${CMD[@]}" ) >"$TMP/out.md" 2>"$TMP/err.log" </dev/null
RC=$?
if [ "$RC" -ne 0 ] || [ -z "$(tr -d '[:space:]' <"$TMP/out.md")" ]; then
    die "the $ROLE call on $MODEL produced no text (exit $RC): $(tail -c 300 "$TMP/err.log" | tr '\n' ' ')"
fi

{ printf '%s\n\n' "$HEADING"; cat "$TMP/out.md"; } >"$TMP/comment.md"
( cd "$WORKTREE" && gh issue comment "$ISSUE" --body-file "$TMP/comment.md" ) \
    >/dev/null 2>>"$TMP/err.log" </dev/null \
    || die "could not post the $HEADING comment on #$ISSUE: $(tail -c 300 "$TMP/err.log" | tr '\n' ' ')"

printf '%s posted on #%s\n' "$HEADING" "$ISSUE"
