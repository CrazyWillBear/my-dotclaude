---
description: Recap the work in progress in this repo — what changed and what's left
argument-hint: "[nothing | a path or area to focus on]"
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git log:*), Read, Grep, Glob
---

Give me a short, plain recap of the uncommitted work in this repository so I can pick
up where I left off.

1. Run `git status --short` and `git diff --stat`. If `$ARGUMENTS` names a path or
   area, scope the diff to it; otherwise cover the whole working tree.
2. Skim the actual changes (`git diff`, and `git diff --staged`) enough to describe
   *what* changed, not just which files.
3. If there are recent commits on this branch, glance at `git log --oneline -5` for
   context on what was already finished.

Then report:
- **Changed** — 3–6 bullets, each "<file or area>: <what changed, in plain terms>".
- **Likely unfinished** — anything that looks half-done (TODOs, a test without its
  implementation, a function added but not called).
- **Suggested next step** — one concrete thing to do next.

This is read-only: do not edit, stage, or commit anything.
