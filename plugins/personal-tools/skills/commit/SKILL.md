---
name: commit
description: Review the changes since the last commit, write a detailed Conventional-Commits message, commit the tracked changes, then summarize the diff. Use for "commit my changes", "/commit".
argument-hint: "[optional extra context to fold into the message]"
agent: commit
---

Commit the current changes per your standing instructions, then report what you committed.
Extra context to fold into the commit message, if any: `$ARGUMENTS`.
