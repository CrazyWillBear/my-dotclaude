---
name: handoff-plan
description: Capture the just-approved plan after exiting plan mode and hand it to a fresh session — write the plan to a file plus the resume pointer the workflow plugin reads, then tell me to /clear and send `go` to execute it. Use for "/handoff-plan", "hand off this plan".
argument-hint: "[optional path to an existing plan file]"
model: inherit
allowed-tools: Read, Write, Bash
---

Hand the plan you just approved to a fresh session — no rich handoff doc, the plan *is*
the doc. This is the lighter sibling of `/handoff`: it captures the approved plan to a
file and writes the same resume pointer, so after `/clear` + `go` the fresh session
reads the plan and implements it from the committed baseline. `workflow`'s `resume.sh`
re-injects the pointer, so the only manual step is one command plus a kickoff word.

**When.** Run this *right after* you exit plan mode (ExitPlanMode), while the approved
plan is still in context — Claude Code does not persist the plan to a file on its own,
so this skill writes it.

**Dirty tree — warn, don't block.** Unlike `/handoff`, this does not require committed
work (you usually haven't written code yet). But if `git status --porcelain` shows
tracked changes, **warn me** that they will be lost on `/clear` (commit them first if I
want them) — then proceed anyway. The baseline is the current `HEAD` regardless.

## Steps

1. **Resolve the plan content** (arg wins, capture by default):
   - If `$ARGUMENTS` is a path to an existing file → **Read it** and use its contents
     (the arg always wins when present).
   - Otherwise → use the **most-recently-approved plan from this conversation, copied
     verbatim** — do not paraphrase, re-summarize, or re-order it.
   - If there is **neither** a path arg **nor** an approved plan in context → **stop**,
     tell me why, and write nothing.
2. **Gather state** (Bash) — same keying as `/handoff`:
   - `branch` = `git rev-parse --abbrev-ref HEAD`
   - `toplevel` = `git rev-parse --show-toplevel` — if this is empty (not a git repo),
     **bail**: there is nothing to key a handoff to.
   - `head` = `git rev-parse HEAD`
   - `ts` = `date +%s`
   - `toplevel_key` = `printf %s "$toplevel" | sha1sum | cut -c1-16` — the per-repo key
   - `dir` = `~/.claude/handoffs/$toplevel_key`, then `mkdir -p "$dir"`
3. **Write the plan file** to `$dir/<branch-slug>-plan.md` — replace every `/` in the
   branch with `-` for the slug. Prepend a single `# Plan — <branch> — <date>` header
   line, then the resolved plan **verbatim**. The `-plan.md` suffix never collides with
   `/handoff`'s `<branch-slug>.md`; re-running overwrites the prior plan for this branch.
4. **Write the resume pointer** `$dir/.pending.json` with the **Write tool**, as JSON in
   exactly the `workflow` schema (this mirrors `save-handoff.sh` — the cross-plugin
   script path isn't install-stable, so write it inline). The keyed-dir algorithm
   **must** match `save-handoff.sh`: `~/.claude/handoffs/<sha1(toplevel)[:16]>/`
   (bash: `printf %s "$toplevel" | sha1sum | cut -c1-16`), pointer named `.pending.json`.
   A drift test enforces this, so don't diverge.
   ```json
   {
     "handoff_path": "<absolute path to the -plan.md you just wrote>",
     "branch": "<branch>",
     "git_toplevel": "<toplevel>",
     "baseline_head": "<head>",
     "session_id": null,
     "context_tokens": null,
     "ts": <ts>
   }
   ```
   `handoff_path` points at the **plan file** you just wrote (in `$dir`). `git_toplevel`
   must be the real toplevel: `resume.sh` only re-injects when the new session is in the
   same repo. This is the same `.pending.json` `/handoff` uses, so writing it here
   overwrites any pending handoff for this branch — the newest one wins.
5. **Tell me what to do**, in plain English (this is a multi-step instruction — write it
   normally even in caveman mode): run **`/clear`**, then send **`go`**. `resume.sh` will
   re-inject an order making **reading the plan file the fresh session's mandatory first
   action**, then implementing it from the committed baseline, so nothing is lost. Show
   the plan file path.
