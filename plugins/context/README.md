# context

Context-window management, versioned here with the rest of my setup: the four hooks that
drive deliberate, early `/clear` and `/handoff` as a session's window fills, plus `/handoff`
and `/handoff-plan` themselves. Nothing here calls into another plugin (the star rule — see
`docs/swarm-design.md` § Plugin split), so every other plugin can lean on `context` being
installed without it becoming a circular dependency.

```
plugins/context/
├── .claude-plugin/plugin.json     # manifest
├── skills/
│   ├── handoff/SKILL.md           # /handoff — write a handoff doc + resume pointer, then /clear
│   └── handoff-plan/SKILL.md      # /handoff-plan — capture the approved plan + resume pointer, then /clear
├── hooks/hooks.json               # wires the scripts below to hook events
├── scripts/
│   ├── watchdog.sh                # UserPromptSubmit: advise /clear before /orchestrate in a full window; nudge a swarm peer past its roster rotate_at to /handoff
│   ├── resume.sh                  # SessionStart: re-inject the common-dir-keyed handoff (worktree-reuse aware) after /clear or /compact
│   ├── save-handoff.sh            # PreCompact: write a handoff before every compaction; OWNS the per-repo keyed dir
│   └── suggest-docs.sh            # Stop: soft nudge when a batch changed code but no docs
├── tests/                         # one bash test per script + skill
└── README.md                      # this file
```

## `/handoff` and `/handoff-plan`

- **`/handoff [note]`** — capture a rich handoff before `/clear`: write the handoff doc and the
  resume pointer `resume.sh` reads, both under a per-repo keyed dir
  `~/.claude/handoffs/<sha1(--git-common-dir)[:16]>/` (`<branch-slug>.md` + `.pending.json`).
  Keying by the shared common `.git` means the primary tree and all its linked worktrees share one
  pointer (a worktree handoff resumes from anywhere in the repo) while concurrent handoffs across
  *different* repos never collide. Captures work done, in-flight state, next steps, key files, and
  gotchas, then tells you to `/clear` and send `go`. Requires committed work first. The skill never
  recomputes the keying itself — it calls `save-handoff.sh` (same plugin, so `CLAUDE_PLUGIN_ROOT`
  resolves it reliably) for both the doc's directory and the pointer write.
- **`/handoff-plan [path]`** — the plan-only sibling of `/handoff`, run *right after* exiting plan
  mode: capture the just-approved plan (or the file at `[path]`, which wins when given) verbatim to
  `<branch-slug>-plan.md` in the same keyed dir, then call `save-handoff.sh --handoff-path <that
  file>` to write the same `.pending.json` resume pointer aimed at the plan doc —
  `save-handoff.sh`'s default lookup only ever matches the plain `<branch-slug>.md` `/handoff`
  writes, never this shape, so the path has to be explicit. Tells you to `/clear` and send `go` so
  a fresh session reads the plan and implements it from the committed baseline. No rich doc — the
  plan *is* the doc. Warns (not blocks) on a dirty tree.

## Inside the watchdog

`hooks.json` wires four scripts to Claude Code hook events. All of them **fail open**: a
missing `python3`/`git` or any error exits 0, so they never wedge a session.

- **`watchdog.sh`** (UserPromptSubmit) reads live context occupancy
  from the transcript — the last assistant entry's `input_tokens + cache_read +
  cache_creation` — and fires at most one advisory signal (two concatenated JSON objects
  would be invalid, so the gate wins when both would apply). No hook can type a slash
  command, so it injects instructions and tells you the one command to run.
  - **Orchestrate gate** (advisory, UserPromptSubmit only): when you type the `workflow` plugin's
    `/orchestrate` slash command (bare or with args) and context is already ≥
    `WORKFLOW_PLANGATE_TOKENS` (default **60k**), it injects a hint to run `/clear` first so
    the loop starts in a fresh window. It is **purely advisory** — never a `decision: block` —
    so `/orchestrate` still runs if you proceed. Natural-language phrasing ("please
    orchestrate") does *not* match; it requires the leading slash.

  - **Peer rotation nudge** (advisory, UserPromptSubmit only) — `docs/swarm-design.md`
    § Rotation. A swarm peer is the one session that *should* be told to wrap up: its whole
    purpose is to be rotated, and `claude agents --json` exposes no context size, so nothing
    but the peer itself can measure it. Past its roster row's `rotate_at` (default **300k**)
    the peer is told to run `/handoff` at the next natural stopping point and then
    `SendMessage` the orchestrator the doc path — the peer picks the moment, and it never
    rotates itself; the orchestrator runs `swarm.sh rotate`.

    Three gates keep it off everyone else. The session's own name — read from the
    `{"type":"agent-name"}` rows `claude -n` writes into the transcript this hook already
    opens, so there is no subprocess and no call into another plugin (§ Plugin split:
    context calls into **nothing**) — must be a `manager` or `doer` row in
    `<project>/.claude/swarm/roster.json`; the threshold is *that row's*; and the wording
    leaves the moment to the model. A session started without `-n` writes no such row, so an
    ordinary interactive window is silent at any occupancy, as is the `orchestrator` row —
    that one is the human's own seat. The roster read is fail-**open** (a malformed roster
    means silence, not an error), unlike `roster.sh`, which is deliberately fail-closed: a
    hook must never wedge the session it exists to help.

  There is otherwise deliberately **no periodic wrap-up nudge**. An earlier version fired at a
  fixed occupancy on any work and told the agent to stop, commit and `/handoff` — which
  interrupted long autonomous runs at their worst moment, and is actively wrong now that
  `/orchestrate` runs its loop on the main thread. A session that genuinely needs a handoff
  still gets one from `save-handoff.sh` on `PreCompact`, which fires on real compaction rather
  than a guess.
- **`resume.sh`** (SessionStart) re-injects the in-flight per-repo handoff after each
  `/clear` or `/compact`. The handoff dir is keyed by the repo's shared `--git-common-dir`, so a handoff
  written inside a linked worktree resumes from anywhere in the repo; when it was written in a
  worktree, the re-injected order tells the fresh session to `EnterWorktree(path=…)` that
  worktree first. Resolution is **3-tier**: the common-dir key, then the old `--show-toplevel`
  key (one release of migration), then the legacy global pointer.
- **`save-handoff.sh`** (PreCompact) writes a handoff before *every* compaction — a manual
  `/compact` or Claude Code's auto-compact — so the plan re-injects either way. It is the single
  source of the resume-pointer schema and owns the per-repo keying; `/handoff` and
  `/handoff-plan` call it rather than each duplicating that recipe.
- **`suggest-docs.sh`** (Stop) gives a soft nudge when a batch changed code but touched no
  docs (`*.md`), so usage/behavior docs land in the same commit. Advisory, deduped once per
  `HEAD`, silent the moment any `.md` is in the batch. This is the *interactive* counterpart
  to `my-review`'s stale-docs check: the Stop hook nudges you while you work; `my-review`
  is the AFK backstop that flags a stale doc in the run report when an autonomous slice leaves
  one behind.

### Thresholds & env

| Var | Default | Effect |
|---|---|---|
| `WORKFLOW_PLANGATE_TOKENS` | `60000` | orchestrate-gate floor (advisory `/clear` hint) |
| `DOCS_FILE_THRESHOLD` / `DOCS_LINE_THRESHOLD` | off | optional sensitivity for the docs nudge |

## Why nothing here calls another plugin

A marketplace install caches every plugin under its own version directory, so a relative path
from one plugin's script into a sibling's is not install-stable, and `CLAUDE_PLUGIN_ROOT` only
ever resolves the currently-executing plugin's own root. `/handoff` and `/handoff-plan` used to
live in `personal-tools` and could only reach `save-handoff.sh` (then in `workflow`) by
duplicating its keying recipe inline; moving them here next to `save-handoff.sh` deleted that
duplication for good. A plugin may still *reference* `context` in prose (a skill description, a
README pointer, like `workflow`'s does) — that's not a dependency edge, only a literal
cross-plugin script call is.

Adding a script is just dropping a file in (and wiring it into `hooks.json`), then
**restarting Claude Code** so it registers.
