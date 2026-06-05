---
name: handoff
description: Manually save a context-flow handoff so the in-flight plan auto-resumes after you run /clear or /compact. Use when the context window is getting large and you want to deliberately wrap up now — committing first and optionally attaching a prose summary the resumed session will read — instead of waiting for the automatic 160k wrap nudge.
---

# Handoff (manual)

context-flow normally drives the flow automatically: a plan-start gate
(`/clear`), a mid-plan wrap nudge, and a post-wrap `/compact` prompt. This skill
is the **on-demand** version: it lets you wrap up *now* and write a richer prose
summary that the resumed session will read.

The handoff is just a file (`~/.claude/.pending-handoff`). On the next `/clear`
or `/compact`, context-flow's `SessionStart` hook (`resume.sh`) reads it and
re-injects the plan — so the only manual step is the one command (plus a kickoff
word).

## Steps

1. **Commit everything first.** The handoff records *committed* work as the
   progress record — there is no agent-authored state beyond the commits, the
   plan file, and the summary you write here. Run `/commit` (or commit yourself)
   until `git status` is clean of tracked changes. Do not hand off with
   uncommitted work.

2. **Write the handoff.** Run the shared writer (it captures the plan path,
   branch, and baseline, and stores your summary):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/save-handoff.sh" --summary "$(cat <<'SUMMARY'
   <2–5 sentences: what you finished, what is in-flight, the next concrete step,
   and any gotcha the resumed session must know. Be specific — this is the only
   prose the next session gets.>
   SUMMARY
   )"
   ```

3. **Tell the user the one command.** Report in one line that the handoff is
   saved and they should run **`/clear`** to continue in fully fresh context (or
   **`/compact`** to keep the thread, compacted), then send a kickoff word —
   `go` after `/clear`, `continue` after `/compact`. The plan and your summary
   auto-resume either way.

## Notes

- This does not (and cannot) run `/compact` or `/clear` — no hook or agent can.
  It only writes the handoff; you type the command.
- If you skip the summary, the automatic flow produces the same resume minus the
  prose — so only use this when the summary adds real value over "the commits +
  the plan file."
