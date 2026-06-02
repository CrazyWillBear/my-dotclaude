# personal-tools

My personal Claude Code slash commands and subagents, versioned here so they come back
with the rest of my setup on any machine.

```
plugins/personal-tools/
├── .claude-plugin/plugin.json     # manifest
├── skills/
│   ├── debug/SKILL.md             # /debug — root-cause debugging workflow
│   ├── explain/SKILL.md           # /explain — whole-codebase overview
│   └── explain-dir/SKILL.md       # /explain-dir <path> — one-directory walkthrough
├── agents/explain-dir.md          # explain-dir — isolated haiku worker for /explain-dir
└── README.md                      # this file
```

## What's here

- **`/debug [bug]`** — systematic root-cause debugging: reproduce → isolate →
  hypothesize → confirm-before-fix → verify → regression test. Runs on the main thread
  (your model); reuses the project's TDD + done-check rather than restating them.
- **`/explain`** — a plain-English architecture overview of the *whole* codebase. It runs
  on the main thread (Sonnet) and spawns the **Explore** agent to map the repo first,
  then synthesizes. It runs in the main thread on purpose: only the main thread can spawn
  Explore — subagents can't spawn subagents.
- **`/explain-dir <path>`** — a focused walkthrough of *one* directory. The skill is a
  thin shim whose `agent:` field runs it inside the `explain-dir` agent: a fresh,
  isolated **haiku** context. The file reading stays in that subagent, so it never floods
  your main conversation — only the summary comes back.

## How the pieces map to Claude Code

- **Skills** (`skills/<name>/SKILL.md`) become slash commands named after the directory:
  `explain-dir/` → `/explain-dir`. Frontmatter sets the description, argument hint, the
  `model` to run on, and (optionally) an `agent` to execute inside.
- **Agents** (`agents/*.md`) become subagents. Frontmatter sets the name, when-to-use
  description, allowed tools, and `model`. `explain-dir` is read-only (`Read, Grep, Glob,
  Bash`) and pinned to haiku.

Adding a tool is just dropping a file in and **restarting Claude Code** so it registers.
