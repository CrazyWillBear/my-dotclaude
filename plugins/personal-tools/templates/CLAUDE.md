<!-- Base project CLAUDE.md filled by the personal-tools init-*-project skills. The <...> placeholders are substituted per language; this header and the "Fill in the <...>" note below are stripped from the generated file. -->
# CLAUDE.md

> **Read first:** [`STYLEGUIDE.md`](./STYLEGUIDE.md) — code conventions, follow on every change.

This file is loaded every session. Keep it short. It covers *how we work*;
STYLEGUIDE.md covers *how we write code*.

> Fill in the `<...>` placeholders below for this project, then delete this note.

## Definition of done

Test-driven: write or update a failing test first, then write code until it passes.

Before calling any task done, all of these must pass:

```
<test command>          # e.g. npm test / pytest / go test ./...
<lint command>          # e.g. eslint . / ruff check . / golangci-lint run
<typecheck command>     # e.g. tsc --noEmit / mypy . (delete if not applicable)
```

A change is not "done" until the relevant tests exist and the full check above is green.

## When stuck

If requirements are unclear or you're unsure of the right design: ask a clarifying
question, propose a short plan, or make the smallest change that lets us discuss. Do
**not** push large speculative changes or invent requirements to fill the gap.

## Boundaries

**Always**
- Follow STYLEGUIDE.md.
- Keep diffs small and focused — one logical change at a time.
- Run the full done-check before declaring completion.

**Ask first**
- Installing software beyond ordinary, safe project dependencies.
- Touching files outside this workspace, or anything affecting systems outside the project.
- Adding a dependency, changing a public API, or changing data schemas.

**Never**
- Put secrets in code.
- Commit anything secret (no keys, tokens, credentials in tracked files — use env vars / untracked config).

## Maintaining this file

Treat this file like code. Keep it under ~100 lines. For every line, ask: "would
removing this cause a mistake?" If not, cut it. Code conventions go in STYLEGUIDE.md;
only universal working rules belong here.
