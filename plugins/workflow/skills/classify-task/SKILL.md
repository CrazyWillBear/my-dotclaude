---
name: classify-task
description: Classify one task or issue into a complexity tier — trivial, standard, or complex — and emit that tier plus a rationale; consumers resolve the tier's {model, effort} roster via the plugin's resolve-tier.sh. Grounds the call by fanning out 1–3 Explore subagents over the touched codebase areas, then asks you to confirm or override. Use for "/classify-task <issue#|brief>", "classify this task".
argument-hint: "[issue# | task brief text] [--no-confirm]"
effort: high
allowed-tools: Read, Grep, Glob, Bash, Agent, AskUserQuestion
---

Classify one task into a complexity **tier** — trivial, standard, or complex — and emit that
tier plus a short rationale. The tier's `{model, effort}` roster is **not** your output —
consumers resolve it from the plugin's `resolve-tier.sh` (see **Roster resolution** below). You
run on the **main thread** because only the main thread can spawn the Explore subagents that
ground the call. You are **read-only** apart from `gh issue view`: you inspect, classify, and emit
a contract — you never edit.

`/pipeline` invokes this at its Step 0.5 to pick the tier for the run; you can also be invoked
directly (`/classify-task <issue#|brief>`). The **output contract** at the bottom is
load-bearing — callers parse it — so emit it verbatim.

## Roster resolution

The tier→`{model, effort}` mapping lives in `${CLAUDE_PLUGIN_ROOT}/model-tiers.json`, resolved by
the plugin's helper — **not** copied here. To see any tier's roster, run:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-tier.sh" <tier>
```

It prints that tier's planner / implementer / reviewer `{model, effort}` pairs (or the standard
roster plus a single warning if the config is missing or invalid). Never mix cells across rows — a
tier is one whole row. The previous hardwired `/pipeline` roster ≈ the **complex** tier; the two
cheaper tiers sit below it.

## Step 1 — resolve the brief

Strip a trailing `--no-confirm` flag first (**batch mode** — see Step 4); the rest of
`$ARGUMENTS` is the brief.

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

**Batch mode (`--no-confirm`):** **skip this step** — emit the Step-5 contract directly,
with no `AskUserQuestion`. A batch caller (e.g. `/orchestrate`'s round classify) invokes
you once per issue and runs **one** confirmation over the whole set itself, so a per-issue
confirm here would double-prompt.

Otherwise, show the user the tier, the rationale, and the classified tier's resolved roster — run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-tier.sh" <tier>` to fetch it — then `AskUserQuestion`:
**trivial** / **standard** / **complex** / **proceed** (accept the classification). An
**override** swaps to that tier wholesale (re-resolve its roster) — never a mixed row.

## Step 5 — output contract

Emit exactly these two lines (the confirmed tier plus its rationale):

```
tier=trivial|standard|complex
rationale=<one to three sentences>
```

The tier is the whole contract — callers resolve the `{model, effort}` roster themselves through
`resolve-tier.sh` (one resolution site), so this skill never emits a model or effort.
