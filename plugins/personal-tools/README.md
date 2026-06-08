# personal-tools

My personal Claude Code slash commands and subagents, versioned here so they come back
with the rest of my setup on any machine.

```
plugins/personal-tools/
├── .claude-plugin/plugin.json     # manifest
├── skills/
│   ├── commit/SKILL.md            # /commit — review changes, write message, commit, summarize
│   ├── diagnose/SKILL.md          # /diagnose — root-cause debugging workflow (6 phases)
│   ├── explain/SKILL.md           # /explain — whole-codebase overview
│   ├── explain-dir/SKILL.md       # /explain-dir <path> — one-directory walkthrough
│   └── init-python-project/SKILL.md  # /init-python-project — scaffold Python project docs
├── agents/
│   ├── commit.md                  # commit — isolated committer for /commit (model: inherit)
│   └── explain-dir.md             # explain-dir — isolated haiku worker for /explain-dir
├── templates/                     # language-neutral CLAUDE.md + STYLEGUIDE.md, filled by the init-* skills
└── README.md                      # this file
```

## What's here

- **`/commit [context]`** — review the changes since the last commit, write a detailed
  Conventional-Commits message, commit them, and summarize the diff. The skill is a thin
  shim whose `agent:` field runs it inside the `commit` agent (`model: inherit`), so the
  diff reading stays out of your main conversation. It stages **tracked changes only**
  (`git add -u` — untracked files are mentioned but left alone), ends the message with a
  `Co-Authored-By: Claude` trailer, and writes the message + summary in **normal English**
  (not caveman, even when caveman mode is on). No push/amend/rebase; no empty commits.
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
- **`/init-python-project [dir]`** — minimal scaffold for a Python project: drops a filled
  `CLAUDE.md`, `STYLEGUIDE.md`, and a Python `.gitignore` into the target dir, wired for a
  **uv + ruff + mypy + pytest** toolchain. It reads the language-neutral base in
  `templates/` and substitutes the Python commands; it does *not* create a
  `pyproject.toml` or venv (left to `uv init`). The base templates are shared, so a future
  `init-node` / `init-go` can fill the same files for another stack.

## How the pieces map to Claude Code

- **Skills** (`skills/<name>/SKILL.md`) become slash commands named after the directory:
  `explain-dir/` → `/explain-dir`. Frontmatter sets the description, argument hint, the
  `model` to run on, and (optionally) an `agent` to execute inside.
- **Agents** (`agents/*.md`) become subagents. Frontmatter sets the name, when-to-use
  description, allowed tools, and `model`. `explain-dir` is read-only (`Read, Grep, Glob,
  Bash`) and pinned to haiku.

Adding a tool is just dropping a file in and **restarting Claude Code** so it registers.
