---
name: to-issues
description: Slice a feature into tracer-bullet vertical-slice GitHub issues via gh — each slice cuts every layer and is demoable alone, published in dependency order so Blocked by refs resolve, labeled for the agent loop. Works from a PRD issue, a .md spec, or the current discussion. Use for "/to-issues", "break the PRD into issues", "slice this".
argument-hint: "[PRD issue number/URL, or .md file path; empty = current discussion]"
model: inherit
effort: xhigh
allowed-tools: Read, Grep, Glob, Bash, AskUserQuestion
---

Break a feature into **tracer-bullet vertical slices** and file each as a GitHub issue.
Backend is **GitHub Issues via `gh`**.

## Input mode (by `$ARGUMENTS` shape)

- **Number / URL** → **PRD mode**: the arg is a PRD issue — `gh issue view <#> --json body`,
  read-only, **never modify it**. Understand the whole before you cut it.
- **`.md` path** → **file mode**: read and slice that spec.
- **Empty** → **discussion mode**: slice the shared understanding already in context. If it's
  too thin to slice (no `/grill-me` ran, nothing concrete), **stop and tell me to run
  `/grill-me` first** — don't invent slices.
- **Inline prose** → **reject**: tell me to pass a `.md` file or run `/grill-me`, then stop.

**File + discussion are "no-PRD"** — no grounding doc, so they also do steps 1–2. PRD mode
trusts the PRD and starts at step 3.

## Steps

1. **(no-PRD) Ground in the repo** — learn the modules, patterns, and seams slices should reuse
   instead of reinventing. Learn the shape; don't dump files.
2. **(no-PRD) Map the testing seam up front** (`AskUserQuestion`): the **highest sensible level**
   to prove this behavior (e2e > integration > unit — through the outermost stable interface).
   Decide it **before** cutting, so it shapes the slices.
3. **Propose tracer-bullet slices.** Each **cuts all layers** (e.g. UI → API → data) and is
   **demoable on its own** — not "build the schema," but "user can do X end-to-end, minimally."
   Prefer **many thin AFK-able slices** over a few fat ones. Per slice: its **dependencies**
   (which slices land first) and whether it needs a **human** (a design call, a secret, an
   external account, a judgement) → mark it **HITL**.
4. **Quiz me until approved** (`AskUserQuestion`): granularity, slice boundaries, dependency
   edges, HITL marks. Iterate until I approve. **Create no issue before approval.**
5. **Publish in dependency order** — blocker slices **first**, so their real `#N` exist when you
   write a dependent's `## Blocked by`. Each body uses this template **verbatim**:
   ```
   ## What to build
   <the slice, at the behavior level>
   ## Acceptance criteria
   - [ ] <demoable, checkable outcome>
   ## Blocked by
   <bare #N refs, one per line — OR — None - can start immediately>
   ```
   Ensure labels exist (ignore "already exists"):
   `gh label create ready-for-agent 2>/dev/null || true` and
   `gh label create hitl 2>/dev/null || true`.
   Label **every** slice `ready-for-agent`; **also** add `hitl` to slices that need a human
   (`/orchestrate` skips `hitl`). Create with a temp body file:
   `gh issue create --title "<title>" --label ready-for-agent [--label hitl] --body-file <tmp>`.
   **PRD mode only:** also put `Part of #<prd>` in each slice body, without touching the PRD.
   No-PRD modes have no parent — omit it.
6. **(no-PRD) File the testing-seam issue last** — a minimal issue stating the step-2 seam (what
   to test, at what level) for me to set up myself. Labels `ready-for-agent` **and** `hitl`; its
   `## Blocked by` lists **every** functional slice, so it surfaces only after the feature is built.
7. **Report a table:** slice `#` → title → `Blocked by` → labels. Then confirm every `#N` in a
   `Blocked by` resolves to a real issue you created — no dangling refs.
