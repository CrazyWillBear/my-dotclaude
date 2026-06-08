---
name: to-prd
description: Turn an aligned task into a Product Requirements Doc and publish it as a labeled GitHub issue via gh — explore the repo, map the testing seam with me, fill the PRD template verbatim, then file it as a `prd`-labeled tracking issue (sliced later by /to-issues). Use for "/to-prd", "write a PRD", "turn this into a PRD issue".
argument-hint: "[shared-understanding summary or task; defaults to the current discussion]"
model: inherit
allowed-tools: Read, Grep, Glob, Bash, AskUserQuestion
---

Turn the task in `$ARGUMENTS` into a Product Requirements Doc and file it as a GitHub issue.
Backend is **GitHub Issues via `gh`** — no `gh api`, no PRs.

## Steps

1. **Start from the shared understanding.** If `/grill-me` produced a `## Shared understanding`
   block, use it as the spine. Otherwise interrogate just enough (prefer `AskUserQuestion`) to
   fill every PRD section — don't write a PRD on top of unanswered questions.
2. **Explore the repo to ground the solution.** Learn what already exists so the Solution reuses
   it instead of reinventing — what modules, patterns, and seams are in play. Learn the shape;
   don't dump files.
3. **Map the testing seam.** Identify the **highest sensible level** to test this behavior
   (end-to-end > integration > unit — test through the outermost stable interface that proves
   it). **Confirm the level with me via `AskUserQuestion`** before writing Testing Decisions.
4. **Fill the PRD template VERBATIM** — these sections, in this order, every one substantive. A
   PRD describes *behavior and decisions*, **not file paths** (no `src/...` — that's the issue
   layer's job):
   ```
   # <title>
   ## Problem
   ## Solution
   ## User Stories
   ## Implementation Decisions
   ## Testing Decisions
   ## Out of Scope
   ## Further Notes
   ```
   "Out of Scope" must state the non-goals explicitly; "Testing Decisions" records the level you
   confirmed in step 3.
5. **Publish as a GitHub issue.**
   - Confirm `gh auth status` and the target repo (`gh repo view --json nameWithOwner`).
   - Ensure the label exists (ignore an "already exists" error):
     `gh label create prd --description "Product Requirements Doc; slice with /to-issues" 2>/dev/null || true`
   - Write the PRD body to a temp file (so markdown/headings survive), then:
     `gh issue create --title "<title>" --label prd --body-file <tmp>`
   - **Do not** label the PRD `ready-for-agent`. That label is what `/orchestrate` builds, and a
     PRD is a multi-feature tracking doc, not a single buildable slice — `/to-issues` produces the
     `ready-for-agent` slices.
6. **Report** the issue URL + number. Then point me at the next step: **`/to-issues <#>`** breaks
   the PRD into tracer-bullet vertical slices labeled `ready-for-agent` — those are what
   `/orchestrate` builds. The PRD itself stays `prd`-labeled and out of the loop.
