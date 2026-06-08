---
name: orchestrate
description: Run N rounds of the autonomous issue-solving loop — pick the ready set (blockers closed, skip hitl), fan out parallel sonnet implementers in isolated git worktrees, merge in dependency order, run the done-check, close finished issues, then an opus reviewer files blocking follow-ups. Use for "/orchestrate", "run the loop", "build the ready issues".
argument-hint: "[N rounds=1] [--max K=3]"
model: opus
allowed-tools: Read, Grep, Bash, Agent
---

Run the autonomous issue-solving loop on this repo's GitHub issues. `$ARGUMENTS` = `[N] [--max K]`
— **N** rounds (default 1); **K** = max issues built in parallel per round (default 3). You run on
the **main thread** because only the main thread can spawn subagents.

Backend is **GitHub Issues via `gh`** — no `gh api`, no PR merges. Never touch issues labeled
`hitl` (needs a human) or `prd` (a PRD tracking doc — slice it with `/to-issues` first). Never
push.

## Setup (once, before round 1)
- **Base branch** = the current branch: `git rev-parse --abbrev-ref HEAD`. Every worktree branches
  from it and merges back into it.
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
   belt-and-suspenders guard against a hand-added label). If the ready set is empty → report and
   **stop the loop**.
3. **Create worktrees.** Take up to **K** ready issues (lowest number first). For each, from the
   base branch (C4):
   `git worktree add .worktrees/issue-<N> -b issue-<N> <base>`.
4. **Fan out implementers in parallel.** In a **single assistant message**, make one **`Agent`**
   call per picked issue (`subagent_type: workflow:implementer`), each given: the issue number,
   its full body, the **absolute** worktree path, and the branch `issue-<N>`. They run
   concurrently.
5. **Merge + verify in dependency order (C4).** Collect the results, then merge each completed
   `issue-<N>` into the base branch. The picked issues are **mutually independent** (every
   member's blockers were already closed), so merge them in ascending issue number. On **any merge
   conflict**: **STOP** — leave the worktree for inspection, `gh issue comment` the issue, and
   report. **Never auto-resolve.** After the merges, run the project's **done-check** on the base
   branch:
   - green → `gh issue close <N>` each merged issue (comment the commit);
   - implementer-reported failure or a **red done-check** → stop that issue, comment it, leave its
     worktree, and report.
6. **Review the round.** Spawn the **opus reviewer** — one `Agent` call
   (`subagent_type: workflow:reviewer`) — on the round's merged range
   (`git diff <round_base>..HEAD`) plus the merged issue numbers. It emits findings (C6), files
   `review-fix` follow-ups, and wires them into dependents' `## Blocked by` (C2) — so a fix lands
   before anything built on it does.
7. **Clean up + report.** Remove merged worktrees
   (`git worktree remove .worktrees/issue-<N>` then `git worktree prune`). Print a **status
   table**: issue `#` → title → merged? / closed? → done-check → notes (filed `review-fix`s,
   conflicts, failures).

Repeat for **N** rounds or until the ready set drains. Conflicts and test failures **always stop
the loop** with a clear report; everything else continues to the next round.
