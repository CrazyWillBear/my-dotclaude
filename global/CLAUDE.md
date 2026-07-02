# CLAUDE.md (global)

My machine-wide config, loaded in every project. It covers *how I work* across all
projects. A project's own `CLAUDE.md` / `STYLEGUIDE.md` layers on top of this and wins
on any conflict. Keep this short — universal working rules only; project facts and
code conventions live in the project, not here.

## Definition of done

Test-driven by default: write or update a failing test first, then write code until it
passes.

A change is not "done" until the relevant tests exist and the project's full check is
green — its tests, linter, and type-checker (see the project's `CLAUDE.md` /
`STYLEGUIDE.md`, or its config, for the exact commands). If a project has no checks
defined, say so rather than silently skipping them.

## When stuck

If requirements are unclear or the right design is uncertain: ask a clarifying
question, propose a short plan, or make the smallest change that lets us discuss. Do
**not** push speculative changes or invent requirements to fill the gap. Stay within 
your scope.

## Boundaries

**Always**
- Follow the project's `STYLEGUIDE.md` when it has one; it's worth reading docs to 
  see if they have a guide by a different name. Otherwise, match the conventions
  already in the file and repo.
- Prefer editing existing files over adding new ones.
- Never duplicate code. Before writing new code, search the repo for an existing
  function, helper, or pattern that already does it and reuse or extend that. If you
  find near-duplicate logic, factor out the shared part instead of copy-pasting.
- Run the full done-check before declaring completion. Report failures honestly — if
  tests fail or a step was skipped, say so.
- Commit your work before ending a turn — don't leave edits uncommitted when the Stop
  hook fires. Use a clear message. (Push only when asked.)

**Ask first**
- Anything destructive or hard to undo, or outward-facing — deleting, publishing,
  sending, spending, or changing something that already works. Say in plain words what
  will happen, then wait for a "yes."
- Installing software beyond ordinary, safe project dependencies.
- Touching files outside the current workspace, or anything affecting systems outside
  the project's scope.
- Adding a dependency, changing a public API, or changing data schemas.
- Touching prod AT ALL.

**Never**
- Put secrets in code.
- Commit anything secret (no keys, tokens, credentials in tracked files — use env vars
  / untracked config).

## Worktree per coding task

The **primary checkout is off-limits for writing.** Before the **first edit that
implements a task** in any git repo, move this session into a worktree by calling the
**`EnterWorktree`** tool — then do all writing there. This keeps parallel sessions from
colliding in one checkout. *Lazy*: do nothing while planning, exploring, or just talking;
act on the first implementing edit. (A `PreToolUse` guard enforces this — writes to the
primary tree are denied with a reminder.)

1. **Dirty tree first.** If `git status --porcelain` is non-empty, stop and ask before
   isolating — the worktree branches off your current `HEAD` (`worktree.baseRef=head`), so
   uncommitted changes won't come along. Commit them, stash them, or tell me to proceed.
2. **Enter.** Call `EnterWorktree` (creates a worktree off `HEAD` on a fresh branch and
   switches this session into it). To continue earlier work, call
   `EnterWorktree(path=<existing worktree>)` instead — e.g. when a handoff points at one.
3. **Work** entirely inside the worktree. Commit there as normal; push only when I ask.
4. **Cleanup.** When the task is done, `ExitWorktree(remove)` (or keep it to come back);
   on session exit you'll be prompted to keep or remove. A leftover empty, clean worktree
   is garbage-collected on a later session start.

**Conflict resolution is exempt:** while a merge/rebase is in progress, editing the
primary tree is allowed.

`/orchestrate` runs the **whole loop in one worktree** — it calls `EnterWorktree` at the
start, and its parallel implementer subagents each get their own nested worktree. Don't
stack another worktree on top inside an orchestrate run or any workflow subagent.

## Communication

Be concise. Lead with the answer, skip the preamble, and don't pad. (caveman handles
tone when it's installed; this holds regardless.)

