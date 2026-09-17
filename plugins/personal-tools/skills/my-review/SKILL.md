---
name: my-review
description: Deep, security-weighted review of your changes or a PR — routes the reviewer model to the change's complexity (opus by default; fable for the deepest complex diffs) — decided here, never asked, then spawns the my-review agent (xhigh reasoning) on that model. Read-only, report-only. Use for "/my-review", "/my-review <PR#>".
argument-hint: "[PR number/URL] [--complexity trivial|standard|complex]; empty = review the local working diff"
allowed-tools: Agent, Bash(git:*), Bash(gh:*)
---

You are the main-thread launcher for the `my-review` agent. Pick the reviewer model
**forward-or-judge** — never a prompt, blind or otherwise — then spawn the agent. Three steps:

1. **Get a tier (forward-or-judge).** In priority order:
   - **`--complexity <tier>` in `$ARGUMENTS`** wins — take that tier verbatim.
   - else a **tier already confirmed this session** (an earlier `/classify-task` or
     `/orchestrate` run in this conversation) — reuse it.
   - else **judge the tier yourself from a cheap diff peek**: `git diff HEAD --stat` for the local
     working diff, or `gh pr diff <N> --stat` for a PR — the size and spread of the change decide
     trivial / standard / complex. This skill stays **dependency-free of the workflow plugin**: do
     **not** invoke its `classify-task` skill, nor infra's `resolve-tier.sh` helper.
2. **Pick the model from the tier — decide it, never ask.** There is **no prompt** at this
   step, for any tier.
   - **complex** → **opus** by default (cheaper, faster). Reach for **fable** only when the diff
     is both large and subtle enough that depth beats turnaround.
   - **not complex** (trivial / standard) → **opus**.

   State the pick and the one-line reason as a statement, then spawn. Will's standing rule: the
   tier and the model are yours to decide.
3. **Spawn the reviewer** with one `Agent` call: `subagent_type: personal-tools:my-review`,
   `model: "<pick>"`. Hand it the target — a PR number/URL if `$ARGUMENTS` names one, else the
   local working diff (`git diff HEAD`). Relay its report **verbatim**.

`/orchestrate` does **not** invoke this skill — there the issue's complexity tier decides the
reviewer model directly, and the review is spawned by the agent that built the slice. The
`agents/my-review.md` frontmatter pins `model: opus` as the fallback for any direct spawn that
omits an override.
