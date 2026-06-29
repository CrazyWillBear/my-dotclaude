# personal-tools

My personal Claude Code slash commands, versioned here so they come back
with the rest of my setup on any machine.

```
plugins/personal-tools/
├── .claude-plugin/plugin.json     # manifest
├── skills/
│   ├── check-updates/SKILL.md     # /check-updates — report whether a newer kit release is available
│   ├── dedup-search/SKILL.md      # /dedup-search — search for reusable code before writing new code
│   ├── diagnose/SKILL.md          # /diagnose — root-cause debugging workflow (6 phases)
│   ├── explain/SKILL.md           # /explain — whole-codebase overview
│   ├── grill-me/SKILL.md          # /grill-me — interrogate the task, emit a shared-understanding summary
│   ├── handoff/SKILL.md           # /handoff — write a handoff doc + resume pointer, then /clear
│   ├── handoff-plan/SKILL.md      # /handoff-plan — capture the approved plan + resume pointer, then /clear
│   ├── init-python-project/SKILL.md  # /init-python-project — scaffold Python project docs
│   ├── my-review/SKILL.md         # /my-review [PR#] — deep, security-weighted code review
│   ├── to-issues/SKILL.md         # /to-issues <#> — slice a PRD into vertical-slice issues
│   ├── to-prd/SKILL.md            # /to-prd — write a PRD, file it as a labeled GitHub issue
│   ├── update-kit/SKILL.md        # /update-kit — apply the latest kit release
│   └── verify-plan/SKILL.md       # /verify-plan — check plan/PRD/issues vs session decisions
├── agents/
│   └── my-review.md               # my-review — the reviewer brain (inherit model, max reasoning)
├── hooks/
│   └── hooks.json                 # SessionStart + UserPromptSubmit hook wiring
├── scripts/
│   ├── check-update.sh            # backing script for /check-updates — compares installed vs latest release
│   ├── notify-update.sh           # SessionStart hook — surfaces an available update (reuses check-update.sh, throttled, fail-open)
│   └── stash-session.sh           # UserPromptSubmit hook — stashes transcript_path for /verify-plan (fail-open)
├── templates/                     # language-neutral CLAUDE.md + STYLEGUIDE.md, filled by the init-* skills
└── README.md                      # this file
```

## What's here

- **`/grill-me [task]`** — interrogate me about a task *before* any code: rounds of pointed
  questions (preferring `AskUserQuestion`) over scope, constraints, edge cases, and acceptance
  criteria, ending in a tight **shared-understanding summary** shaped to feed `/to-prd`.
  Read-only; runs on the main thread.
- **`/verify-plan [target]`** — point a sonnet subagent at the current session log and ask
  whether the plan/PRD/issue-slices under discussion still match what was decided (later
  decisions win). Reports drift — contradictions and omissions — read-only. A `UserPromptSubmit`
  hook (`stash-session.sh`) stashes the transcript path on every prompt; the skill reads it back
  since skill bodies never receive the session path directly. Pairs with `/grill-me` → `/to-prd`
  → `/to-issues`.
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
- **`/handoff-plan [path]`** — the plan-only sibling of `/handoff`, run *right after* exiting plan
  mode: capture the just-approved plan (or the file at `[path]`, which wins when given) verbatim to
  `<branch-slug>-plan.md` in the same keyed dir, write the same `.pending.json` resume pointer, then
  tell me to `/clear` and send `go` so a fresh session reads the plan and implements it from the
  committed baseline. No rich doc — the plan *is* the doc. Warns (not blocks) on a dirty tree.
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
- **`/my-review [PR#]`** — a deep, **security-weighted** code review of your local working diff
  (no arg) or a named **PR** (`/my-review 42`). Runs inside the `my-review` agent at **max
  reasoning** on the session model: a dedicated security pass first (injection, authn/authz,
  secrets, unsafe deserialization, SSRF, crypto misuse, …), then a general correctness/quality
  pass driven by the repo's own `STYLEGUIDE.md` / `CLAUDE.md`. **Read-only, report-only** — emits
  a verdict plus findings grouped blocker/warning/nit; never edits, posts, or comments. For a PR
  it checks the tree is clean, checks out, reviews, then restores your original branch.
- **`/check-updates`** — report whether a newer kit release is available. Runs
  `scripts/check-update.sh`, which reads the installed plugin version from `plugin.json`,
  queries the GitHub Releases API, and prints either `kit is up to date (vX.Y.Z)` or
  `vX.Y.Z available — run /update-kit to upgrade`. Fails open (silent) on any network or API
  error. No arguments needed.
- **SessionStart update notice** (`scripts/notify-update.sh`, wired in `hooks/hooks.json`) — on session
  start, proactively tells you when a newer kit release is available. It **reuses**
  `check-update.sh` for the whole version check/compare (no duplicated logic), throttles the
  GitHub API to at most ~once per day via a cache file
  (`${XDG_CACHE_HOME:-~/.cache}/my-dotclaude/last-check.json`; TTL `NOTIFY_UPDATE_TTL_SECONDS`,
  default 86400), and **fails open** — any network/parse error or unwritable cache exits cleanly
  and silently so it can never block a session. When a newer release exists it surfaces a short
  non-blocking notice naming the version and telling you to run `/update-kit`.
- **`/update-kit`** — apply the latest kit release on this machine. Runs
  `claude plugin marketplace update my-dotclaude`, then updates both the `personal-tools` and
  `workflow` plugins via `claude plugin update`, then prints a reminder to restart Claude Code.
  No arguments needed; works for both developer and simple-setup audiences.

## How the pieces map to Claude Code

- **Skills** (`skills/<name>/SKILL.md`) become slash commands named after the directory:
  `diagnose/` → `/diagnose`. Frontmatter sets the description, argument hint, the
  `model` to run on, and (optionally) an `agent` to execute inside.
- **Agents** (`agents/*.md`) become subagents — frontmatter sets the name, when-to-use
  description, allowed tools, `model`, and reasoning `effort`. This plugin ships **`my-review`**
  (the reviewer behind `/my-review`); its other skills run on the main thread (or spawn built-in
  agents like **Explore**).

Adding a tool is just dropping a file in and **restarting Claude Code** so it registers.
