---
name: debug
description: Track down a bug by root cause, not symptom — reproduce, isolate, form one falsifiable hypothesis, confirm it before fixing, then verify and lock in a regression test. Use for "why is this failing", "debug this", "track down this bug".
argument-hint: "[bug description, error, or failing test]"
allowed-tools: Read, Edit, Grep, Glob, Bash
---

Track down and fix the bug in `$ARGUMENTS` (or the currently failing test) by **root
cause, not symptom**.

1. **Reproduce** — pin a reliable, minimal failing case. Prefer a failing test; write
   one (red) if none exists.
2. **Isolate** — bisect to the smallest unit that still fails (narrow inputs, comment
   out, or `git bisect`).
3. **Hypothesize** — state ONE specific, falsifiable guess at the cause. Name the
   `file:line` you suspect and why.
4. **Confirm before fixing** — prove the hypothesis with a log line, assertion, or
   experiment. If it's wrong, go back to step 3. Do **not** write the fix until confirmed.
5. **Fix the root cause** — the smallest change that addresses the confirmed cause, not
   the symptom.
6. **Verify** — the failing case now passes AND the project's full done-check is green
   (its tests, linter, type-checker — see `CLAUDE.md`).
7. **Lock it in** — keep the reproduction as a regression test so the bug can't silently
   return.

Be honest if you can't reproduce or can't confirm a cause — say so rather than guessing
a fix. Cite `file:line` as you go.
