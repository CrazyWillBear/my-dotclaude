---
name: adhoc
description: Build one explicit unit of work with you present, as a subagent chain on the main thread — classify, worktree, plan (complex only), implement, my-review, fresh-implementer fix rounds, fold, and an offered merge. No sessions, no run log, no PR. Use for "/adhoc", or when /orchestrate routes a single explicit task here.
argument-hint: "<what to build, where, and how you'd know it's done>"
allowed-tools: Read, Grep, Bash, Agent, Skill, AskUserQuestion
---

One unit of work, built while you watch: **What**, **Where** and **Done** are all in the message
(if one is missing, discuss — build nothing). It is a chain of subagents you spawn, and when it
ends you still hold the context.

**Claude only.** Every step spawns through the `Agent` tool, which takes only claude model names.
Resolve each roster with `bash ~/.claude/kit/infra/scripts/resolve-tier.sh <tier>`. If the
implementer cell says `backend=codex`, use the chain's **top cell** instead
(`resolve-tier.sh <tier> $((implementer_chain-1))`, always claude); a codex or fable reviewer cell
becomes `opus`.

1. **Classify** from the message alone, by the `/classify-task` rubric — no Explore fan-out:
   trivial, standard or complex. Never prompt to confirm it; say what you picked.
2. **Worktree** — `EnterWorktree(name: "adhoc-<slug>")` unless you are already in a linked worktree.
3. **Plan (complex only)** — spawn `workflow:planner` at the planner cell. Trivial and standard
   self-plan.
4. **Build** — spawn `workflow:implementer` at the implementer cell, handing it the work order:
   the plan (or the task), the absolute worktree path, the branch, and a commit-scope hint.
5. **Review** — spawn `personal-tools:my-review` at the reviewer cell on the branch's commits.
   Always a subagent you spawn: it never inherits this conversation, so the review is fresh.
6. **Fix rounds** — a **fresh** `workflow:implementer` per round, handed the review's high and
   medium findings, then review again. Never the implementer that wrote the code. Stop when a
   round does not reduce high + medium below the round before, or after 6 rounds; lows are listed,
   never fixed.
7. **Preview and offer** — from the worktree,
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-fold.sh" --preview <target>` prints `clean` or
   `conflict <paths>` against `dev`/`main` without touching anything; then **offer** the merge
   with that result in view. Offered, never taken.

Report the branch, the commits, the last review's counts, and anything left open.
