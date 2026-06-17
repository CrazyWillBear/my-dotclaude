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

When real code work begins in a git repo **that has a remote**, isolate it in its own
branch and worktree — never edit the base branch directly. *Lazy*: do nothing while
planning, exploring, or just talking; act on the **first edit that implements the task**.

1. **Dirty tree first.** If `git status --porcelain` is non-empty, stop and ask before
   isolating — proceed (leave the changes here), `git stash` them, or skip the worktree
   and edit in place.
2. **Base** off fresh `origin/main` (fetch first) by default, or off a branch I name.
3. **Name** the branch `issue-<N>` if the task maps to a GitHub issue, else
   `<type>/<slug>` (`feat/`, `fix/`, `chore/`, …).
4. `git worktree add ~/.claude/worktrees/<repo>/<branch> -b <branch> <base>`; work there.

Push only when I ask. Once the branch **is pushed** and the task is wrapping up, remove
the worktree (`git worktree remove` + `git worktree prune`), return to the original
checkout, and `git fetch`. If it was never pushed, leave it and warn
`worktree not cleaned up`.

Skip this entirely inside `/orchestrate` or any workflow subagent — those own their
worktrees.

## Communication

Be concise. Lead with the answer, skip the preamble, and don't pad. (caveman handles
tone when it's installed; this holds regardless.)

