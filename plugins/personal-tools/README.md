# personal-tools

My personal Claude Code slash commands, versioned here so they come back
with the rest of my setup on any machine.

```
plugins/personal-tools/
├── .claude-plugin/plugin.json     # manifest
├── skills/
│   ├── dedup-search/SKILL.md      # /dedup-search — search for reusable code before writing new code
│   ├── diagnose/SKILL.md          # /diagnose — root-cause debugging workflow (6 phases)
│   ├── explain/SKILL.md           # /explain — whole-codebase overview
│   ├── grill-me/SKILL.md          # /grill-me — interrogate the task, emit a shared-understanding summary
│   ├── handoff/SKILL.md           # /handoff — write a handoff doc + resume pointer, then /clear
│   ├── init-python-project/SKILL.md  # /init-python-project — scaffold Python project docs
│   ├── to-issues/SKILL.md         # /to-issues <#> — slice a PRD into vertical-slice issues
│   └── to-prd/SKILL.md            # /to-prd — write a PRD, file it as a labeled GitHub issue
├── templates/                     # language-neutral CLAUDE.md + STYLEGUIDE.md, filled by the init-* skills
└── README.md                      # this file
```

## What's here

- **`/grill-me [task]`** — interrogate me about a task *before* any code: rounds of pointed
  questions (preferring `AskUserQuestion`) over scope, constraints, edge cases, and acceptance
  criteria, ending in a tight **shared-understanding summary** shaped to feed `/to-prd`.
  Read-only; runs on the main thread.
- **`/to-prd [summary]`** — turn an aligned task into a Product Requirements Doc and file it as
  a GitHub issue via `gh`: explore the repo, confirm the testing seam with me, fill the PRD
  template verbatim, and publish it labeled `prd` (a tracking doc — *not* built directly).
  `/to-issues` then slices it into the `ready-for-agent` issues the `workflow` plugin's
  `/orchestrate` loop builds.
- **`/to-issues <#>`** — break a PRD issue into **tracer-bullet vertical slices** (each cuts all
  layers, demoable alone): quiz me on granularity/dependencies/HITL, then file them in dependency
  order so each issue's `## Blocked by` carries real `#N` refs. Labels slices `ready-for-agent`
  (and `hitl` where a human is needed); never edits the parent PRD.
- **`/handoff [note]`** — capture a rich handoff before `/clear`: write the handoff doc and the
  resume pointer the `workflow` plugin reads, both under a per-repo keyed dir
  `~/.claude/handoffs/<sha1(toplevel)[:16]>/` (`<branch-slug>.md` + `.pending.json`), so concurrent
  handoffs across repos never collide. Captures work done, in-flight state, next steps, key files,
  and gotchas, then tells me to `/clear` and send `go`. Requires committed work first.
- **`/dedup-search [task]`** — search the repo for reusable or extendable code before writing
  anything new. It extracts 3–8 concrete search terms from the task description, runs the
  `scripts/dedup-search.sh` helper against the repo, and triages each candidate into
  **reuse** (call it directly), **extend** (targeted addition needed), or **none**
  (coincidental match). Emits a ranked reuse-candidate list, or an explicit
  "searched, nothing reusable" statement so the caller knows the search ran.
- **`/diagnose [bug]`** — root-cause a bug through a disciplined 6-phase loop: build a feedback
  loop → reproduce → rank falsifiable hypotheses → instrument → fix with a regression test →
  clean up + post-mortem. Runs on the main thread (your model); reuses the project's TDD +
  done-check rather than restating them.
- **`/explain`** — a plain-English architecture overview of the *whole* codebase. It runs
  on the main thread (Sonnet) and spawns the **Explore** agent to map the repo first,
  then synthesizes. It runs in the main thread on purpose: only the main thread can spawn
  Explore — subagents can't spawn subagents.
- **`/init-python-project [dir]`** — minimal scaffold for a Python project: drops a filled
  `CLAUDE.md`, `STYLEGUIDE.md`, and a Python `.gitignore` into the target dir, wired for a
  **uv + ruff + mypy + pytest** toolchain. It reads the language-neutral base in
  `templates/` and substitutes the Python commands; it does *not* create a
  `pyproject.toml` or venv (left to `uv init`). The base templates are shared, so a future
  `init-node` / `init-go` can fill the same files for another stack.

## How the pieces map to Claude Code

- **Skills** (`skills/<name>/SKILL.md`) become slash commands named after the directory:
  `diagnose/` → `/diagnose`. Frontmatter sets the description, argument hint, the
  `model` to run on, and (optionally) an `agent` to execute inside.
- **Agents** (`agents/*.md`) become subagents — frontmatter sets the name, when-to-use
  description, allowed tools, and `model`. This plugin currently ships none of its own;
  its skills run on the main thread (or spawn built-in agents like **Explore**).

Adding a tool is just dropping a file in and **restarting Claude Code** so it registers.
