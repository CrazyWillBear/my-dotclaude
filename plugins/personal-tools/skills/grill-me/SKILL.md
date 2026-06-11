---
name: grill-me
description: Interrogate me about the task before any code — surface scope, constraints, edge cases, acceptance criteria, and unknowns through rounds of pointed questions, then emit a tight shared-understanding summary shaped to feed /to-prd. Use for "/grill-me", "grill me", "interrogate the requirements".
argument-hint: "[the task or feature to pin down]"
model: inherit
effort: xhigh
allowed-tools: Read, Grep, Glob, AskUserQuestion
---

Interrogate me about the task in `$ARGUMENTS` until we share a precise understanding of what
to build and how we'll know it's done. You ask; you do **not** write code or change files here
— this is the alignment step *before* `/to-prd`.

## How to work

1. **Ground yourself first.** Skim enough of the repo (Glob/Grep/Read) to ask *specific*
   questions instead of generic ones — what already exists, what would be reused, where this
   fits. Don't over-read; a few minutes of orientation, not a full audit.
2. **Interrogate in rounds.** Prefer **`AskUserQuestion`** whenever the answer is a choice
   between a few options (it's faster for me than free text). Across rounds, cover:
   - **Problem & why** — what's actually wrong / wanted, and why now.
   - **Scope boundaries** — what's in, what's explicitly out.
   - **Constraints** — tech, performance, compatibility, deadlines, things that can't change.
   - **Edge cases & failure modes** — empty/huge/concurrent/error inputs; what happens when it
     breaks.
   - **Acceptance criteria** — the concrete, checkable signals that say "done."
   - **Unknowns & risks** — what neither of us is sure about yet.
   Each round should chase the *gaps the last round's answers opened*. Keep going until no
   material ambiguity remains — but stop once we're aligned. Don't interrogate for its own sake.
3. **Reflect back.** Periodically restate what you've heard in one or two lines so I can correct
   a misunderstanding early rather than at the end.

## Output — the shared-understanding summary

When aligned, emit this block verbatim (it's the handoff to `/to-prd`). Tight and declarative —
no hedging, no restating the questions:

```
## Shared understanding
**Problem:** <the core problem in 1-2 lines>
**Goals:** <the outcomes that define success>
**Constraints:** <hard limits — tech, compat, perf, deadlines>
**Non-goals:** <what we are deliberately NOT doing>
**Open risks:** <unknowns still worth flagging>
```

Close by pointing me at the next step: `/to-prd` to turn this into a PRD issue.
