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
`git status --porcelain` shows tracked changes, **stop and tell me to commit first** —
a handoff over uncommitted work would lose it on `/clear`.

## Steps

1. **Gather state** (Bash):
   - `branch` = `git rev-parse --abbrev-ref HEAD`
   - `toplevel` = `git rev-parse --show-toplevel`
   - `common_dir` = `git rev-parse --git-common-dir`, then canonicalize:
     `common_dir="$(cd "$common_dir" && pwd -P)"` — the shared `.git`, identical from the primary
     tree and every linked worktree (so a handoff written in a worktree resolves repo-wide)
   - `head` = `git rev-parse HEAD`
   - `ts` = `date +%s`
   - `repo_key` = `printf %s "$common_dir" | sha1sum | cut -c1-16` — the per-repo key
   - `dir` = `~/.claude/handoffs/$repo_key`, then `mkdir -p "$dir"`
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
3. **Write the resume pointer** `$dir/.pending.json` with the **Write tool**, as JSON in exactly
   the `workflow` schema (this mirrors `save-handoff.sh` — the cross-plugin script path isn't
   install-stable, so write it inline). The keyed-dir algorithm **must** match `save-handoff.sh`:
   `~/.claude/handoffs/<sha1(canonical --git-common-dir)[:16]>/` (bash:
   `printf %s "$common_dir" | sha1sum | cut -c1-16`), pointer named `.pending.json`. A drift test
   enforces this, so don't diverge.
   ```json
   {
     "handoff_path": "<absolute path to the handoff doc you just wrote>",
     "branch": "<branch>",
     "git_toplevel": "<toplevel>",
     "git_common_dir": "<common_dir>",
     "baseline_head": "<head>",
     "session_id": null,
     "context_tokens": null,
     "ts": <ts>
   }
   ```
   `handoff_path` points at the **handoff doc** you just wrote (in `$dir`). `git_common_dir` is the
   canonical shared `.git`; `resume.sh` re-injects only when the new session's common dir matches.
   `git_toplevel` records the working tree this handoff was written in — if that's a linked
   worktree, `resume.sh` tells the fresh session to `EnterWorktree(path=…)` it before resuming.
4. **Tell me what to do**, in plain English (this is a multi-step instruction — write it normally
   even in caveman mode): run **`/clear`**, then send **`go`**. `resume.sh` will re-inject an
   order making **reading the handoff doc the fresh session's mandatory first action**, then
   "implement the handoff @`<handoff doc>`", so nothing is lost. Show the handoff doc path.
