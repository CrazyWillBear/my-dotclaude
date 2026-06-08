---
name: diagnose
description: Root-cause a bug through a disciplined 6-phase loop — build a feedback loop, reproduce, rank falsifiable hypotheses, instrument, fix with a regression test, then clean up and post-mortem. Use for "/diagnose", "debug this", "find the root cause".
argument-hint: "[the bug or failing behavior]"
model: inherit
allowed-tools: Read, Edit, Write, Grep, Glob, Bash
---

Root-cause the bug in `$ARGUMENTS` by evidence, not by guessing. Work the six phases in order;
don't skip ahead to a fix before the cause is proven. Reuse the project's TDD discipline and its
done-check (its tests, linter, type-checker) rather than restating them.

## Phase 1 — Build a feedback loop
Find or establish the fastest reliable way to *observe* the bug: a failing test, a one-line
script, a single command. Everything after this rests on the loop being quick and deterministic,
so invest here first.

## Phase 2 — Reproduce
Make the bug happen on demand through that loop. If you **can't** reproduce it, say so and gather
more signal (logs, inputs, environment) — do not start fixing a bug you can't trigger.

## Phase 3 — Hypothesize
Write **3–5 ranked, falsifiable hypotheses** for the root cause. Each must predict something you
can check ("if it's X, then Y will be true"). Rank by likelihood × cheapness-to-test, cheapest
decisive check first.

## Phase 4 — Instrument
Add targeted logging / asserts / breakpoints to confirm or kill hypotheses **one at a time**,
top-ranked first. Let the evidence pick the cause; don't pattern-match to a fix. Keep going until
exactly one hypothesis survives and you've *seen* it cause the failure.

## Phase 5 — Fix + regression test
Once the cause is proven:
- If a real test seam exists, write a **failing regression test first** (it should fail for the
  proven reason), then fix until it passes — TDD.
- If there's genuinely no seam, fix first and add the closest honest test you can; say so.
Run the project's full **done-check** and don't claim success until it's green.

## Phase 6 — Cleanup + post-mortem
Remove the instrumentation you added, confirm the done-check is still green, then give a 2–3 line
post-mortem: **root cause**, **why it hid**, and **what the regression test now guards**.

**Honesty rules:** never claim a fix you haven't watched pass the loop. If the cause stays
unproven, report the surviving hypotheses and what you'd check next — don't ship a guess.
