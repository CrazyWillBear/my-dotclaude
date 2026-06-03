---
description: Show this project's code-review history and metrics
argument-hint: "[N recent entries, default 10]"
allowed-tools: Bash(bash:*), Read
---

Show the project's code-review history.

Run:
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-history.sh" $ARGUMENTS

Present the output as-is. If it reports that there is no history yet, tell the
user reviews are recorded automatically after the team-code-review hook runs (or
after a `/review`), so there is nothing to show until then. Do not invent
entries.
