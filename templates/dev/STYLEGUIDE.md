# STYLEGUIDE.md

Code conventions for this repo. Follow these on every change. CLAUDE.md covers
workflow; this file covers how code is written.

> Language-neutral defaults. Adapt the `<...>` bits to your stack, then delete this note.

## Naming & structure

- **Naming:** follow the conventions of the language and the surrounding code. Prefer
  descriptive names over abbreviations (`order_count`, not `ordc`). All names, comments,
  and docs in English.
- **Function length:** keep functions short (~50 lines). If one grows past that, extract a helper.
- **Files:** keep modules short and single-responsibility. A file should have one clear
  reason to exist; split when it accumulates unrelated concerns.
- **Self-documenting code:** prefer clear names and small functions over explanatory
  comments. Reach for a comment only when the code can't speak for itself.

## Comments, docs & typing

- **Comments explain WHY, not WHAT.** Don't restate the code. Comment business rules,
  non-obvious decisions, and trade-offs — things a reader can't recover from the code alone.
- **Document the public surface.** Every public/exported function, class, and module gets
  a short doc describing its contract (purpose, args, returns, errors). Internal helpers
  rely on names + types instead.
- **Type your interfaces.** Annotate public signatures where the language supports it.
  Avoid escape hatches (`any`, untyped casts); if you must, justify it in a comment.
- **No dead code.** Remove unused functions, imports, variables, and commented-out blocks
  immediately. Version control is the backup.

## Error handling & robustness

- **Be specific, never swallow.** Catch the narrowest error that fits; never catch-all and
  hide it. Don't silently ignore a caught error — handle it, re-raise, or log with context.
- **Logging:** use the project's logger, not stray prints. Log errors with enough context
  to debug (what operation, what inputs, what failed).
- **Idiomatic & lint-clean:** write code that passes `<lint command>` and the formatter
  without manual fixups. Aim for code that's already clean as written.

## Testing

- **Framework:** `<test framework>`. Run with `<test command>`.
- **Test-first:** new behavior starts with a failing test (the loop in CLAUDE.md).
- **Cover new reusable logic** with tests.
- **Test both paths:** happy path *and* error conditions (bad input, raised errors, edge
  cases) — not just success.
- **Structure:** Arrange-Act-Assert. Mock external dependencies (network, filesystem,
  services) so tests are fast and deterministic.
