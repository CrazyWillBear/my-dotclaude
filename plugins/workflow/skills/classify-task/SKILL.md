---
name: classify-task
description: Classify one task or issue into a complexity tier — trivial, standard, or complex — and return the model routing table (planner/implementer/reviewer) that tier dictates; grounds the call by fanning out 1–3 Explore subagents over the touched codebase areas, then asks you to confirm or override. Use for "/classify-task <issue#|brief>", "classify this task".
argument-hint: "[issue# | task brief text]"
effort: high
allowed-tools: Read, Grep, Glob, Bash, Agent, AskUserQuestion
---

Classify one task into a complexity **tier** — trivial, standard, or complex — and return
the model **routing table** (planner / implementer / reviewer) that tier dictates. You run on
the **main thread** because only the main thread can spawn the Explore subagents that ground
the call. You are **read-only** apart from `gh issue view`: you inspect, classify, and emit a
contract — you never edit.

`/pipeline` invokes this at its Step 0 to pick the models for the run; you can also be invoked
directly (`/classify-task <issue#|brief>`). The **output contract** at the bottom is
load-bearing — callers parse it — so emit it verbatim.

## Tier table

| tier | planner | implementer | reviewer |
|---|---|---|---|
| trivial | sonnet | sonnet | opus |
| standard | opus | sonnet | opus |
| complex | fable | opus | fable |

The current hardwired `/pipeline` roster ≈ the **complex** tier; the two cheaper tiers sit
below it. Never mix cells across rows — a tier is one whole row.

## Step 1 — resolve the brief

- A leading integer (`12`, `#12`) in `$ARGUMENTS` → **issue mode**:
  `gh issue view <N> --json title,body,labels`. The title + body is the brief; labels are
  context.
- Otherwise `$ARGUMENTS` **is** the brief (callers pass a distilled brief, not the raw
  conversation).
- Empty `$ARGUMENTS` → ask the user for the task before classifying.

## Step 2 — ground the call (Explore fan-out)

Decide the count yourself from the brief:
- **1** `Explore` agent when the work is **clearly scoped** to a single area.
- **2–3** `Explore` agents when the brief spans multiple **distinct** components or its scope
  is ambiguous — one per area, spawned in parallel.

Spawn **Explore** agents with the `Agent` tool, `model: "sonnet"`, with targeted prompts (the
area to map, the seams/contracts to find, the brief's intent). Each returns:
- the relevant files;
- the seams / contracts / data shapes the change touches;
- whether it **fits existing infrastructure** or introduces new kinds of things;
- the downstream consumers of what it changes.

## Step 3 — classify

**Size is not the signal.** A one-line change that moves a seam or changes a data contract is
**complex**; a hundred lines of mechanical edits with no design decisions is **trivial**.

- **trivial** — mechanical, **no design decisions**: the implementer just executes (renames,
  string/config edits, format-preserving tweaks, obvious one-spot fixes).
- **standard** — real judgment **within existing seams**: reuses the current infrastructure,
  no contract moves, consequences stay local.
- **complex** — **new infrastructure**, **seams move** (a contract/interface/data shape
  changes), or there are **downstream consequences** for other components.

Reason through **four** questions before you decide:
1. Does it use existing infrastructure, or add new kinds of things?
2. Does it fit the current seams, or do **seams move**?
3. Are there embedded **design decisions** the implementer would otherwise have to make?
4. Does it have **downstream consequences** for other components?

Produce a tier plus a **1–3 sentence rationale** that names the specific signals (concrete
files/seams from the exploration, not generalities).

## Step 4 — confirm / override

Show the user the tier, the rationale, and the tier's roster row, then `AskUserQuestion`:
**trivial** / **standard** / **complex** / **proceed** (accept the classification). An
**override** substitutes that tier's **full** roster row — never a mixed row.

## Step 5 — output contract

Emit exactly these five lines (the values from the confirmed tier's row):

```
tier=trivial|standard|complex
planner=sonnet|opus|fable
implementer=sonnet|opus|fable
reviewer=sonnet|opus|fable
rationale=<one to three sentences>
```
