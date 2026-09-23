---
name: handoff
description: Capture a rich handoff before /clear — write a markdown handoff doc (work done, in-flight state, next steps, key files, gotchas) plus the resume pointer resume.sh reads, then tell me to /clear and send `go`. Use for "/handoff", "hand this off", "save state and clear".
argument-hint: "[optional note to fold into the handoff]"
model: inherit
allowed-tools: Read, Write, Bash
---

Capture everything the next session needs, then send me into fresh context. `resume.sh`
re-injects the handoff after I `/clear`, so the only manual step is one command.

**Pre-req — committed work.** The resume pointer's baseline is the current `HEAD`. If
`git status --porcelain` shows tracked changes, **stop and tell me to commit first** —
a handoff over uncommitted work would lose it on `/clear`.

## Steps

1. **Gather state** (Bash):
   - `branch` = `git rev-parse --abbrev-ref HEAD`
   - `dir` = `bash "${CLAUDE_PLUGIN_ROOT}/scripts/save-handoff.sh" --print-dir` — the per-repo
     keyed handoff dir; `save-handoff.sh` owns that keying, so nothing here recomputes it. Empty
     output means you're not in a git repo — stop and say so. `mkdir -p "$dir"`.
2. **Write the handoff doc** to `$dir/<branch-slug>.md` — replace every `/` in the branch with
   `-` for the slug. Be concrete; this is the *only* memory the fresh session gets. Fold
   `$ARGUMENTS` in if given. Sections:
   ```
   # Handoff — <branch> — <date>
   ## Done
   <what's committed — include the relevant commit hashes>
   ## In flight
   <what's half-done or mid-decision right now>
   ## Next steps
   <the ordered actions to resume — specific enough to act on cold>
   ## Key files
   <paths that matter, each with a one-line why>
   ## Gotchas
   <traps, assumptions, things that already bit us>
   ```
3. **Write the resume pointer** by running
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/save-handoff.sh"` (no args, after the doc from step 2 is
   on disk). It re-derives `branch`/`git_toplevel`/`git_common_dir`/`baseline_head` itself,
   resolves the doc you just wrote at `$dir/<branch-slug>.md` into `handoff_path`, and writes
   `$dir/.pending.json` — the one place that schema is written, so nothing here can drift from it.
4. **Tell me what to do**, in plain English (this is a multi-step instruction — write it normally
   even if a terse output mode is active): run **`/clear`**, then send **`go`**. `resume.sh` will re-inject an
   order making **reading the handoff doc the fresh session's mandatory first action**, then
   "implement the handoff @`<handoff doc>`", so nothing is lost. Show the handoff doc path.
