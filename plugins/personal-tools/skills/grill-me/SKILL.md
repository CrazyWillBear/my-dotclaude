---
name: grill-me
description: Interrogate me about the task before any code — surface scope, constraints, edge cases, acceptance criteria, and unknowns through rounds of pointed questions until no material ambiguity remains. Use for "/grill-me", "grill me", "interrogate the requirements".
argument-hint: "[the task or feature to pin down]"
model: inherit
effort: xhigh
allowed-tools: Read, Grep, Glob, AskUserQuestion
---

Interrogate me about the task in `$ARGUMENTS` until we share a precise understanding of what to
build and how we'll know it's done. You ask; you do **not** write code or change files. Skim
enough of the repo (Glob/Grep/Read) to ask *specific* questions, then go round after round —
prefer `AskUserQuestion` when the answer is a choice between a few options. Ask as many questions
as you can think of, covering problem & why, scope boundaries, constraints (tech, perf, compat,
deadlines), edge cases & failure modes, acceptance criteria, and unknowns/risks. Each round
chases the gaps the last round's answers opened.

Don't stop early. Keep generating new questions until you genuinely can't think of another that
would change the design — only then declare yourself done. Periodically restate what you've heard
in a line or two so I can correct a misunderstanding before the end.
