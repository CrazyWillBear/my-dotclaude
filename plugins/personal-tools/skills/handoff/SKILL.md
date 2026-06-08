---
name: handoff
description: Capture a rich handoff before /clear — write a markdown handoff doc (work done, in-flight state, next steps, key files, gotchas) plus the resume pointer the workflow plugin reads, then tell me to /clear and send `go`. Use for "/handoff", "hand this off", "save state and clear".
argument-hint: "[optional note to fold into the handoff]"
model: inherit
allowed-tools: Read, Write, Bash
---

Capture everything the next session needs, then send me into fresh context. `workflow`'s
`resume.sh` re-injects the handoff after I `/clear`, so the only manual step is one command.

**Pre-req — committed work.** The resume pointer's baseline is the current `HEAD`. If
`git status --porcelain` shows tracked changes, **stop and tell me to commit first** (or run
`/commit`) — a handoff over uncommitted work would lose it on `/clear`.

## Steps

1. **Gather state** (Bash):
   - `branch` = `git rev-parse --abbrev-ref HEAD`
   - `toplevel` = `git rev-parse --show-toplevel`
   - `head` = `git rev-parse HEAD`
   - `ts` = `date +%s`
2. **Write the handoff doc** to `~/.claude/handoffs/<branch>.md` — replace every `/` in the
   branch with `-`, and `mkdir -p ~/.claude/handoffs` first. Be concrete; this is the *only*
   memory the fresh session gets. Fold `$ARGUMENTS` in if given. Sections:
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
3. **Write the resume pointer** `~/.claude/.pending-handoff` with the **Write tool**, as JSON in
   exactly the `workflow` schema (this mirrors `save-handoff.sh` — the cross-plugin script path
   isn't install-stable, so write it inline):
   ```json
   {
     "handoff_path": "<absolute path to the handoff doc you just wrote>",
     "branch": "<branch>",
     "git_toplevel": "<toplevel>",
     "baseline_head": "<head>",
     "session_id": null,
     "context_tokens": null,
     "ts": <ts>
   }
   ```
   `handoff_path` points at the **handoff doc** you just wrote. `git_toplevel` must be the real
   toplevel: `resume.sh` only re-injects when the new session is in the same repo.
4. **Tell me what to do**, in plain English (this is a multi-step instruction — write it normally
   even in caveman mode): run **`/clear`**, then send **`go`**. `resume.sh` will re-inject
   "implement the handoff @`<handoff doc>`" into the fresh session, so nothing is lost. Show the
   handoff doc path.
