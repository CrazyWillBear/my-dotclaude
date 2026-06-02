---
description: Review code changes with the team code-reviewer subagent
argument-hint: "[files | git ref | nothing for current changes]"
allowed-tools: Task, Bash(git status:*), Bash(git diff:*), Read, Grep, Glob
---

Run a team code review by delegating to the `code-reviewer` subagent.

**Scope to review** (resolve in this order):
- If arguments were given, use them: `$ARGUMENTS`
  - file paths → review those files
  - a git ref (e.g. `main`, `HEAD~3`) → review `git diff <ref>...HEAD`
- If no arguments: review the current uncommitted changes
  (`git diff HEAD --name-only`, plus untracked files from `git status`).
- If there is no git repo and no arguments, ask me which files to review.

**Then:** launch the `code-reviewer` subagent via the Task tool. Give it:
1. The exact list of files (absolute paths) in scope.
2. This rubric path to read and apply:
   `${CLAUDE_PLUGIN_ROOT}/skills/review-rubric/SKILL.md`

When it returns, show me its verdict and findings grouped by severity. Do not
edit any files — this is review only.
