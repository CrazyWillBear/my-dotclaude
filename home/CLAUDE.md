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
**not** push large speculative changes or invent requirements to fill the gap.

## Boundaries

**Always**
- Follow the project's `STYLEGUIDE.md` when it has one; otherwise match the conventions
  already in the file and repo.
- Keep diffs small and focused — one logical change at a time. Prefer editing existing
  files over adding new ones.
- Run the full done-check before declaring completion. Report failures honestly — if
  tests fail or a step was skipped, say so.

**Ask first**
- Anything destructive or hard to undo, or outward-facing — deleting, publishing,
  sending, spending, or changing something that already works. Say in plain words what
  will happen, then wait for a "yes."
- Installing software beyond ordinary, safe project dependencies.
- Touching files outside the current workspace, or anything affecting systems outside
  the project's scope.
- Adding a dependency, changing a public API, or changing data schemas.
- Changing project docs (`CLAUDE.md`, `STYLEGUIDE.md`, `PLAN.md`, …). Flag staleness or
  redundancy when a change introduces it, but update or prune only after asking.

**Never**
- Put secrets in code.
- Commit anything secret (no keys, tokens, credentials in tracked files — use env vars
  / untracked config).

## Communication

Be concise. Lead with the answer, skip the preamble, and don't pad. (caveman handles
tone when it's installed; this holds regardless.)

## Maintaining this file

Treat this file like code. Keep it under ~100 lines. For every line, ask: "would
removing this cause a mistake?" If not, cut it. Universal working rules only — anything
project-specific belongs in that project's docs.
