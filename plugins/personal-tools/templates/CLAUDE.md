<!-- Base project CLAUDE.md filled by the personal-tools init-*-project skills. The <...> placeholders are substituted per language; this header and the "Fill in the <...>" note below are stripped from the generated file. -->
# CLAUDE.md

> **Read first:** [`STYLEGUIDE.md`](./STYLEGUIDE.md) — code conventions, follow on every change.

Project-specific rules only. The universal working rules — boundaries, when-stuck,
secrets, done-honesty — live in the global `~/.claude/CLAUDE.md` and apply underneath
this. Only add a rule here when it differs from, or isn't covered by, the global.

> Fill in the `<...>` placeholders below for this project, then delete this note.

## Definition of done

The project's full check — the global done-rule points here for the exact commands. All
must pass before any task is "done":

```
<test command>          # e.g. npm test / pytest / go test ./...
<lint command>          # e.g. eslint . / ruff check . / golangci-lint run
<typecheck command>     # e.g. tsc --noEmit / mypy . (delete if not applicable)
```

## Keep these docs current

Treat `CLAUDE.md` and `STYLEGUIDE.md` as living docs, not write-once boilerplate. As part
of a change that makes a rule here stale, wrong, or redundant, prune or rewrite it in the
same change; add a rule when a real, recurring need shows up. Keep it tight — fewer,
sharper lines beat an accreting pile. (This project directive overrides the global
ask-first-before-editing-docs rule for these two files.)
