---
name: handoff
description: Manually save a context-flow handoff and end the session for a clean restart. Use when the context window is getting large and you want to deliberately wrap up, commit, and relaunch with fresh context instead of waiting for the automatic 150k watchdog — optionally attaching a prose summary that the resumed session will see.
---

# Handoff (manual)

context-flow normally hands off automatically once the context window crosses
~150k tokens. This skill is the **on-demand** version: it lets you wrap up now
and write a richer prose summary that the resumed session will read.

The handoff is just a file (`~/.claude/.pending-handoff`). On the next launch,
context-flow's `SessionStart` hook (`resume.sh`) reads it, re-enables code
review, and injects a resume instruction — so the only manual step is the
relaunch (`exit`, then `claude`).

## Steps

1. **Commit everything first.** The handoff records *committed* work as the
   progress record — there is no agent-authored state beyond the commits, the
   plan file, and the summary you write here. Run `/commit` (or commit yourself)
   until `git status` is clean of tracked changes. Do not hand off with
   uncommitted work.

2. **Write the handoff.** Run the shared writer (it captures the plan path,
   branch, and review baseline, defers code review across the restart with
   `--arm`, and stores your summary):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/save-handoff.sh" --arm --summary "$(cat <<'SUMMARY'
   <2–5 sentences: what you finished, what is in-flight, the next concrete step,
   and any gotcha the resumed session must know. Be specific — this is the only
   prose the next session gets.>
   SUMMARY
   )"
   ```

3. **Tell the user to relaunch.** Report in one line that the handoff is saved
   and they should `exit` then run `claude` to continue with fresh context;
   the plan and your summary will auto-resume.

## Notes

- This does not (and cannot) run `/compact` or `/clear` — no hook or agent can.
  It is a clean restart, not an in-place summary.
- If you skip the summary, the automatic handoff path produces the same result
  minus the prose — so only use this when the summary adds real value over "the
  commits + the plan file."
