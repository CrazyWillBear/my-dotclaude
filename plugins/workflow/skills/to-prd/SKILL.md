---
name: to-prd
description: Capture a thoroughly discussed idea — a feature, a large change, or a design decision — whole as a Product Requirements Doc (problem, goals, success, solution, every decision with its rationale) and publish it as a labeled GitHub issue via gh, for /to-issues to slice. Use for "/to-prd", "write a PRD", "turn this into a PRD issue".
argument-hint: "[task or idea; defaults to the current discussion]"
model: inherit
effort: xhigh
allowed-tools: Read, Grep, Glob, Bash, AskUserQuestion
---

Capture the idea in `$ARGUMENTS` **whole** and file it as a GitHub issue. The PRD is the
**decision record**: the one place that holds the goals, the success bar, and every decision —
technical and non-technical — so `/to-issues` and the agents building the slices share the same
context. Backend is **GitHub Issues via `gh`** — no `gh api`, no PRs.

## Steps

1. **Start from the discussion — don't interview.** Run this after `/grill-me` or any
   conversation that has thoroughly worked the idea, code or not (e.g. how to split work across
   workers). Synthesize the PRD from what was said and decided; keep decisions, don't paraphrase
   them away.
2. **Ground it in the repo when code is involved.** Learn what already exists so the Solution
   reuses it instead of reinventing. Learn the shape; don't dump files. Skip for a pure design
   decision.
3. **Close the gaps inline.** If a core section can't be written from the discussion, ask via
   `AskUserQuestion` — don't file a PRD on top of unanswered questions. Record the rationale for
   any decision you know it for. For a big decision (your judgment: costly to undo, chosen over a
   real alternative, crosses components, touches cost, security or data) with no stated reason,
   ask for it. Small decisions need no reason. Never invent a rationale.
4. **Map the testing seam — only when the PRD changes code behavior.** Identify the **highest
   sensible level** to test it (end-to-end > integration > unit — through the outermost stable
   interface) and **confirm it via `AskUserQuestion`**. That outermost real interface is the
   feature's **central mechanism**: the one load-bearing behavior that must be exercised *for
   real* by the end, not mocked. Name it in one line; `/to-issues` derives each slice's piece from
   it (see [anti-mock-drift](../../../../docs/anti-mock-drift.md)).
5. **Write the PRD.** Core sections always, in this order; optional sections **omit entirely**
   when they don't apply (no empty headings). Keep concrete names and paths when they were
   decided. Do not add a slice plan — slicing is `/to-issues`' job.
   ```
   # <title>
   ## Problem
   ## Goals
   ## Success
   ## Solution
   ## Technical Decisions
   ## Product Decisions
   ## Out of Scope
   ## User Stories        (optional)
   ## Testing Decisions   (optional)
   ## Open Questions      (optional)
   ```
   - **Problem** — what's wrong or missing, with evidence where there is any.
   - **Goals** — what we want, and why.
   - **Success** — a **checklist** of observable outcomes, each with how it's verified, plus a
     short prose description of what working looks like. `/to-issues` derives acceptance criteria
     and the e2e-gate from it.
   - **Solution** — the overall approach, in a few paragraphs.
   - **Technical Decisions / Product Decisions** — each decision stated plainly, with its
     rationale where known. Group by topic when there are many.
   - **Out of Scope** — the non-goals, explicit.
   - **User Stories** — only when distinct actors or flows are worth naming.
   - **Testing Decisions** — only when step 4 ran: the confirmed level and the **central
     mechanism**.
   - **Open Questions** — only points deliberately deferred, not gaps from step 3.
6. **Publish as a GitHub issue.**
   - Confirm `gh auth status` and the target repo (`gh repo view --json nameWithOwner`).
   - Ensure the label exists (ignore an "already exists" error):
     `gh label create prd --description "Product Requirements Doc; slice with /to-issues" 2>/dev/null || true`
   - Write the PRD body to a temp file (so markdown/headings survive), then:
     `gh issue create --title "<title>" --label prd --body-file <tmp>`
   - **Do not** label the PRD `ready-for-agent`. That label is what `/orchestrate` builds, and a
     PRD is a multi-feature tracking doc, not a single buildable slice — `/to-issues` produces the
     `ready-for-agent` slices.
7. **Report** the issue URL + number. Then point me at the next step: **`/to-issues <#>`** breaks
   the PRD into tracer-bullet vertical slices labeled `ready-for-agent` — those are what
   `/orchestrate` builds. The PRD itself stays `prd`-labeled and out of the loop.
