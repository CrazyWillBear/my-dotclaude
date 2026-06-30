---
name: orchestrate
description: Run N rounds of the autonomous issue-solving loop — pick the ready set (blockers closed, skip hitl), fan out parallel implementers in isolated git worktrees, hand the completed branches to a merger that merges in dependency order and resolves conflicts under the done-check, close finished issues, then a reviewer files blocking follow-ups. Use for "/orchestrate", "run the loop", "build the ready issues".
argument-hint: "[N rounds=1] [--max K=3]"
effort: high
allowed-tools: Read, Grep, Bash, Agent
---

Run the autonomous issue-solving loop on this repo's GitHub issues. `$ARGUMENTS` = `[N] [--max K]`
— **N** rounds (default 1); **K** = max issues built in parallel per round (default 3). You run on
the **main thread** because only the main thread can spawn subagents.

Backend is **GitHub Issues via `gh`** — no `gh api`, no PR merges. Never touch issues labeled
`hitl` (needs a human) or `prd` (a PRD tracking doc — slice it with `/to-issues` first). Never
push.

## Step 0 — enter the orchestration worktree (once, before Setup)
The **whole run executes in one worktree** so the merger writes to a linked worktree (the
`PreToolUse` guard allows that) and the **primary checkout is never touched**. Decide by where you
are now — canonicalize both with `realpath` first, since git may print a relative `.git`:
- **In the primary checkout** (`git rev-parse --git-dir` and `--git-common-dir` resolve to the
  **same** path) → call **`EnterWorktree(name: "orchestrate-<n>")`** with a unique `<n>` (e.g.
  `orchestrate-$(date +%s)`). This creates `.claude/worktrees/orchestrate-<n>` off the current
  `HEAD` (`worktree.baseRef=head`) on branch `orchestrate-<n>` and switches this session into it.
- **Already in a linked worktree** (the two **differ**) → **skip**; this worktree is already
  isolated and *is* the orchestration worktree. (`EnterWorktree(name:…)` refuses to nest a new
  worktree while you're in a worktree session anyway.)

Everything below runs **from the orchestration worktree**. The result is **left on the
orchestration branch** for you to merge into `dev`/`main` yourself — the run never merges back to
the launch branch and never removes the orchestration worktree.

## Setup (once, before round 1)
- **Base branch** = the current branch (the **orchestration branch** from Step 0):
  `git rev-parse --abbrev-ref HEAD`. Every per-issue worktree branches from it and merges back into
  it; the merged result stays on it.
- **Locally exclude worktrees** so they don't dirty the tree: append `.worktrees/` to
  `"$(git rev-parse --git-dir)"/info/exclude` if not already there (a local exclude — doesn't
  modify the tracked `.gitignore`).

## Each round
1. **Capture the round baseline:** `round_base=$(git rev-parse HEAD)` — the reviewer diffs against
   this later.
2. **Pick the ready set.**
   `gh issue list --label ready-for-agent --state open --json number,title,labels,body`.
   For each issue, parse the `## Blocked by` section (C2): bare `#N` refs, or
   `None - can start immediately`. An issue is **ready** iff **every** `#N` blocker is **closed**
   (`gh issue view <N> --json state`). **Skip** any issue also labeled `hitl` or `prd` (the
   `--label ready-for-agent` filter already excludes a correctly-labeled PRD; this is a
   belt-and-suspenders guard against a hand-added label). **Mock-debt gate (C7):** an issue
   labeled `e2e-gate` is **not ready** while **any** open `mock-debt` issue exists
   (`gh issue list --label mock-debt --state open --json number` — non-empty → hold the gate),
   even if all its `## Blocked by` refs are closed; report it as `blocked — N mock-debt open`.
   The open `mock-debt` set **is** the ledger (the source of truth). If the ready set is empty →
   report and **stop the loop**.
3. **Create worktrees.** Take up to **K** ready issues (lowest number first). For each, from the
   base branch (C4):
   `git worktree add .worktrees/issue-<N> -b issue-<N> <base>`.
4. **Fan out implementers in parallel.** In a **single assistant message**, make one **`Agent`**
   call per picked issue (`subagent_type: workflow:implementer`), each given: the issue number,
   its full body, the **absolute** worktree path, and the branch `issue-<N>`. They run
   concurrently.
5. **Merge + verify via the merger (C4).** Collect the results, then spawn the **merger** —
   one `Agent` call (`subagent_type: workflow:merger`) — passing the **absolute orchestration-worktree
   path** as this run's base repo (`git rev-parse --show-toplevel`, a linked worktree → the guard
   allows the merger's writes) and its **base branch**, the **ordered list of completed issues**
   (each: `#N`, branch `issue-<N>`,
   and its **absolute worktree path**) in **ascending issue number**, and the project's
   **done-check command**. Ascending issue number is the **deterministic** merge order; the picked
   issues' blockers were already closed, but file-level overlap can still collide — **conflicts are
   expected and the merger resolves them under the done-check**. The merger merges serially,
   **resolves conflicts by default (gated by the done-check)**, and returns per-issue results plus
   the final done-check result and any conflict-stops. Act on its result:
   - issues it merged green → `gh issue close <N>` each (comment the commit);
   - a **conflict-stop** (unresolvable conflict or a **red done-check** after resolution), or an
     implementer-reported failure → comment that issue, leave its worktree, and **stop the loop**
     with a report. **Never keep an unverified resolution** — that discipline lives in the merger.
6. **Review the round.** Spawn the **reviewer** — one `Agent` call
   (`subagent_type: workflow:reviewer`) — on the round's merged range
   (`git diff <round_base>..HEAD`) plus the merged issue numbers. It emits findings (C6), files
   `review-fix` follow-ups (wired into dependents' `## Blocked by`, C2) **and** `mock-debt`
   follow-ups for any central mock it found (audited per slice, not wired into dependents — the
   ready-rule's label query is the gate). A fix/un-mock lands before anything builds on it.
   - **Mirror the ledger (C7).** If this is a PRD run (slices carry `Part of #<prd>`), reflect the
     open `mock-debt` set into the PRD body for human visibility: rewrite **only** a delimited
     `## Mock-debt ledger` section (a checklist — `- [ ] #N — <what>` for open, `- [x]` for
     closed) from `gh issue list --label mock-debt --json number,title,state`. Touch **no other
     part** of the PRD body. The label query — not this mirror — is authoritative for the gate, so
     a stale mirror never breaks enforcement.
7. **Clean up + report.** Remove only the **per-issue child worktrees**
   (`git worktree remove .worktrees/issue-<N>` then `git worktree prune`) — **leave the
   orchestration worktree and its branch in place** (that's where the merged result lives, for you
   to merge onward). Print a **status table**: issue `#` → title → merged? / closed? → done-check →
   notes (filed `review-fix`s and `mock-debt`s, conflicts, failures). If any `mock-debt` is open,
   add a one-line **ledger summary** (`mock-debt: N open — #A, #B …`) and note any `e2e-gate` held
   by it.

Repeat for **N** rounds or until the ready set drains. The merger attempts to resolve conflicts
under the done-check; an **unresolvable conflict**, a **red done-check**, or an implementer failure
**always stops the loop** with a clear report; everything else continues to the next round.

**Where the work lives.** All merged rounds land on the **orchestration branch** inside the
orchestration worktree — never on the launch branch and never in the primary checkout. End the
final report by naming that branch + worktree path and telling me to merge it into `dev`/`main`
when I'm satisfied; if I entered it via Step 0's `EnterWorktree`, `ExitWorktree(keep)` returns me to
the original directory with the branch intact (or the session-exit prompt offers keep/remove).

## End-of-run: PRD reap

After **all rounds** finish (or the loop stops), collect every issue number closed during this
run and pass them to the reap helper. Locate the repo root with
`git rev-parse --show-toplevel`, then run:

```
bash <repo-root>/plugins/workflow/scripts/prd-reap.sh <N1> [N2 ...]
```

The helper prints one line per finding to stdout:

- `ready <prd_number>` — every child slice of that PRD is closed; the PRD is eligible
  to close.
- `blocked <prd_number> hitl <hitl_N> [hitl_N ...]` — the only open children carry the
  `hitl` label; a human must review before closing.

**If the helper prints nothing**, the final report is unchanged — do not add any prompt
or mention of PRDs. The autonomous contract is fully preserved for runs where no PRD
qualifies.

**For each `ready` PRD**, add an offer to the final report (never auto-close):

> PRD #N appears complete — all child slices are closed. Close it? (yes/no)

On **yes**: run `gh issue close <N> --comment "All child slices are closed — closing this PRD."`.
Never edit the PRD's spec content or delete the issue. (The one exception is the delimited
`## Mock-debt ledger` section the orchestrator maintains in step 6 — it owns that section only.)

**For each `blocked` PRD**, note it in the final report without offering to close:

> PRD #N is blocked — open `hitl` issue(s): #H [#H …] need human review before closing.

These PRD offers and notes appear only in the **final report** (step 7), after all rounds. They
never interrupt mid-loop rounds.
