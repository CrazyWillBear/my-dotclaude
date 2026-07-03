---
name: my-review
description: Deep, security-weighted review of your changes or a PR — asks whether to run on opus or fable, then spawns the my-review agent (xhigh reasoning) on that model. Read-only, report-only. Use for "/my-review", "/my-review <PR#>".
argument-hint: "[optional PR number/URL; empty = review the local working diff]"
allowed-tools: Agent, AskUserQuestion
---

You are the main-thread launcher for the `my-review` agent. Two steps:

1. **Ask which model** with `AskUserQuestion`: **opus** (cheaper, faster) or **fable** (deepest,
   slowest). This is the only choice — the agent does the rest.
2. **Spawn the reviewer** with one `Agent` call: `subagent_type: personal-tools:my-review`,
   `model: "<pick>"`. Hand it the target — a PR number/URL if `$ARGUMENTS` is non-empty, else
   the local working diff (`git diff HEAD`). Relay its report **verbatim**.

`/pipeline` does **not** invoke this skill — there the complexity tier decides the reviewer
model. The `agents/my-review.md` frontmatter still pins `model: fable` as the fallback for any
direct spawn that omits an override.
