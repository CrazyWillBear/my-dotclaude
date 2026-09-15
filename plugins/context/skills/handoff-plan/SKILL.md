---
name: handoff-plan
description: Capture the just-approved plan after exiting plan mode and hand it to a fresh session — write the plan to a file plus the resume pointer resume.sh reads, then tell me to /clear and send `go` to execute it. Use for "/handoff-plan", "hand off this plan".
argument-hint: "[optional path to an existing plan file]"
model: inherit
allowed-tools: Read, Write, Bash
---

Hand the plan you just approved to a fresh session — no rich handoff doc, the plan *is*
the doc. This is the lighter sibling of `/handoff`: it captures the approved plan to a
file and writes the same resume pointer, so after `/clear` + `go` the fresh session
reads the plan and implements it from the committed baseline. `resume.sh` re-injects the
pointer, so the only manual step is one command plus a kickoff word.

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
   - `dir` = `bash "${CLAUDE_PLUGIN_ROOT}/scripts/save-handoff.sh" --print-dir` — the
     per-repo keyed handoff dir; empty means you're not in a git repo — **bail**: there is
     nothing to key a handoff to. `mkdir -p "$dir"`.
3. **Write the plan file** to `$dir/<branch-slug>-plan.md` — replace every `/` in the
   branch with `-` for the slug. Prepend a single `# Plan — <branch> — <date>` header
   line, then the resolved plan **verbatim**. The `-plan.md` suffix never collides with
   `/handoff`'s `<branch-slug>.md`; re-running overwrites the prior plan for this branch.
4. **Write the resume pointer** by running
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/save-handoff.sh" --handoff-path "$dir/<branch-slug>-plan.md"`
   (after the plan file from step 3 is on disk). The explicit `--handoff-path` is required
   here: `save-handoff.sh`'s default lookup only ever matches the plain `<branch-slug>.md`
   `/handoff` writes, never the `-plan.md` shape. The script re-derives
   `branch`/`git_toplevel`/`git_common_dir`/`baseline_head` itself and writes
   `$dir/.pending.json` — the one place that schema is written. This is the same
   `.pending.json` `/handoff` uses, so writing it here overwrites any pending handoff for
   this branch — the newest one wins.
5. **Tell me what to do**, in plain English (this is a multi-step instruction — write it
   normally even if a terse output mode is active): run **`/clear`**, then send **`go`**. `resume.sh` will
   re-inject an order making **reading the plan file the fresh session's mandatory first
   action**, then implementing it from the committed baseline, so nothing is lost. Show
   the plan file path.
