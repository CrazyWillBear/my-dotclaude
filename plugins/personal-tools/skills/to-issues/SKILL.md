---
name: to-issues
description: Break a PRD into tracer-bullet vertical-slice GitHub issues via gh — each slice cuts every layer and is demoable alone, published in dependency order so Blocked by refs resolve, labeled for the agent loop. Use for "/to-issues", "break the PRD into issues", "slice this PRD".
argument-hint: "<PRD issue number or URL>"
model: inherit
allowed-tools: Read, Grep, Glob, Bash, AskUserQuestion
---

Break the PRD named in `$ARGUMENTS` into **tracer-bullet vertical slices** and file each as a
GitHub issue. Backend is **GitHub Issues via `gh`**. **Never modify the parent PRD issue.**

## Steps

1. **Read the PRD.** `gh issue view <#>` (and `--json body`). Understand the whole before you cut
   it. This issue is read-only for you.
2. **Propose tracer-bullet slices.** Each slice **cuts all layers** (e.g. UI → API → data) and is
   **demoable on its own** — not "build the schema," but "user can do X end-to-end, minimally."
   Prefer **many thin AFK-able slices** over a few fat ones. For each, work out:
   - its **dependencies** — which other slices must land first;
   - whether it needs a **human** (a design call, a secret, an external account, a judgement) →
     mark it **HITL**.
3. **Quiz me until approved.** Use `AskUserQuestion` on granularity, slice boundaries, the
   dependency edges, and the HITL marks. Iterate until I approve the slice list. **Do not create
   any issue before approval.**
4. **Publish in dependency order.** Create blocker slices **first**, so their real `#N` numbers
   exist when you write a dependent's `## Blocked by`. Each issue body uses this template
   **verbatim**:
   ```
   ## What to build
   <the slice, at the behavior level>
   ## Acceptance criteria
   - [ ] <demoable, checkable outcome>
   ## Blocked by
   <bare #N refs, one per line — OR — None - can start immediately>
   ```
   Ensure labels exist first (ignore "already exists"):
   `gh label create ready-for-agent 2>/dev/null || true` and
   `gh label create hitl 2>/dev/null || true`.
   Label **every** slice `ready-for-agent`; **also** add `hitl` to slices that need a human
   (`/orchestrate` skips `hitl`). Create with a temp body file:
   `gh issue create --title "<title>" --label ready-for-agent [--label hitl] --body-file <tmp>`.
5. **Cross-link to the PRD** without touching it — put `Part of #<prd>` in each slice body (or a
   slice comment). Editing the PRD issue itself is off-limits.
6. **Report a table:** slice `#` → title → `Blocked by` → labels. Then confirm every `#N` in a
   `Blocked by` resolves to a real issue you created — no dangling refs.
