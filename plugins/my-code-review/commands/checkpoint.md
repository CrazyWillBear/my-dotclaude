---
description: Arm a halfway checkpoint for a long plan — commit + pause for /compact, review once at the end
argument-hint: "[path to plan .md, default = newest in ~/.claude/plans]"
allowed-tools: Bash(bash:*), Read
---

Arm a mid-plan checkpoint so a LONG plan survives `/compact` and gets ONE code
review at the end instead of a nag per commit.

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/checkpoint.sh" arm $ARGUMENTS`

The line(s) above report the resolved plan, its step count N, and the halfway
step. Now execute that plan with this protocol:

1. Work through the plan in order. (For hands-off execution, toggle **Auto** mode
   yourself with shift+tab — this command cannot set the permission mode.)
2. At the halfway step reported above, at a natural boundary:
   a. Commit the work so far — run `/commit`.
   b. Check off the steps you finished in the plan file.
   c. STOP and tell me this is a clean point to run `/compact`, then to say
      "continue" to resume. You cannot run `/compact` yourself, so end your turn.
3. After `/compact`, when I say continue, finish the remaining steps, committing
   as you go.
4. When the WHOLE plan is done, BEFORE your final stop, run:
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/checkpoint.sh" done
   That re-enables the auto code-review so it fires once over the entire plan
   diff. Then commit any remainder and stop.

If the helper reported it could not find or count a plan, pick a sensible
halfway point yourself; the deferral is still armed either way.

Begin now.
