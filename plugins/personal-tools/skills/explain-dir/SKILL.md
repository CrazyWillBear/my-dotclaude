---
name: explain-dir
description: Explain one directory in plain English — what it does, how the pieces fit, and gotchas. Runs in an isolated haiku subagent so the file reading never floods the main context.
argument-hint: "<path to a directory (or file)>"
agent: explain-dir
---

Explain `$ARGUMENTS` for someone about to work in it.

1. List the path (Glob), find the key symbols (Grep), and read the files that matter
   (Read). Trace the real control/data flow, not names.
2. If something depends on code outside `$ARGUMENTS`, note it rather than guessing.

Report:

- **In one line:** what this directory is for.
- **Walkthrough:** the key files/pieces in order, in plain language; define a jargon term
  the first time you use it.
- **Gotchas:** edge cases, surprising behavior, or assumptions that could bite an editor.

Cite `file:line`. Read-only — do not edit, stage, or commit anything.
