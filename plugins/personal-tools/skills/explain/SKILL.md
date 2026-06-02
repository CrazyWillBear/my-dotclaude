---
name: explain
description: Explain the whole codebase in plain English — architecture overview, major components, how they fit together, and where a newcomer should start. Maps the repo with the Explore agent first, then synthesizes on the session model.
model: inherit
---

Give a plain-English architecture overview of this entire codebase.

1. Spawn the **Explore** agent (Agent tool) to map the repo broadly: top-level layout,
   major modules/packages, entry points, build/config, and how the parts reference each
   other. Ask it for a `file:area` map with short notes — not full file dumps.
2. From that map, read only the few key files needed to confirm how things connect.
   Don't read everything; that's what the Explore pass was for.
3. Synthesize:
   - **In one line:** what this codebase is.
   - **Major components:** each top-level area and its job.
   - **How it fits:** the main flow and how components talk to each other.
   - **Start here:** entry points and the first files a newcomer should open.

Cite paths / `file:line`. Read-only — do not edit, stage, or commit anything. If
`$ARGUMENTS` names a focus area, bias the overview toward it while still covering the
whole.
