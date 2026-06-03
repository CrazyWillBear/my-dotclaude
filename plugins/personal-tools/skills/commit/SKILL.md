---
name: commit
description: Review the changes since the last commit, write a detailed Conventional-Commits message, commit the tracked changes, then summarize the diff. Use for "commit my changes", "/commit".
argument-hint: "[optional extra context to fold into the message]"
agent: commit
---

Commit the current changes and report what you committed. Extra context, if any: `$ARGUMENTS`.

1. **Look at the state.** Run `git status` and `git diff HEAD` to see the tracked changes
   since the last commit. If there is no git repo, or nothing tracked has changed, say so
   and stop — do **not** create an empty commit.
2. **Stage tracked changes only.** Run `git add -u` (modifications and deletions). Do
   **not** add untracked/new files; if untracked files exist, mention them but leave them
   unstaged.
3. **Write a detailed message** in this repo's style — Conventional Commits with a scope
   (e.g. `feat(personal-tools): …`, `fix(setup): …`): a concise imperative subject
   (≤ ~50 chars), then a body explaining the *why* when it isn't obvious from the subject.
   Fold in `$ARGUMENTS` if given. Verify every claim against the actual diff — don't
   describe changes you haven't seen. End the message with the trailer:
   `Co-Authored-By: Claude <noreply@anthropic.com>`.
4. **Commit the staged index** with a quoted heredoc so multi-line messages and punctuation
   stay safe:
   ```
   git commit -F - <<"EOF"
   <subject>

   <body>

   Co-Authored-By: Claude <noreply@anthropic.com>
   EOF
   ```
5. **Summarize for me** in plain English prose (**not** caveman voice, even if caveman mode
   is active): the one-line subject, then the key changes grouped by file or area, and
   anything notable (left-unstaged untracked files, follow-ups). Show the commit hash from
   `git log -1 --oneline`.
