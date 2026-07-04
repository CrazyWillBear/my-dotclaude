---
name: verify-plan
description: Check whether the plan(s)/PRD(s)/issue-slice(s) under discussion still match the decisions made in this session — a sonnet subagent reads the current session log, later decisions win, and reports drift read-only. Use for "/verify-plan", "does my plan still match what we decided?".
argument-hint: "[optional: which plan/PRD/issue to check; empty = infer from the conversation]"
model: inherit
allowed-tools: Read, Grep, Glob, Bash, Agent
---

Check whether the written artifacts under discussion still match the decisions made in this
session. A fresh sonnet subagent reads the session transcript and each target, then reports
contradictions and omissions. Read-only — nothing is edited.

## Step 1 — Resolve the session log path

Run this in a Bash block:

```bash
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
key="$(printf %s "$root" | sha1sum | cut -c1-16)"
stash="${TMPDIR:-/tmp}/verify-plan-session-$key.path"
[ -s "$stash" ] && cat "$stash"
```

If `$stash` is **missing or empty**: hard error, stop. Tell the user:

> The session pointer isn't set yet — this usually means the hook hasn't fired yet.
> Run `/reload-plugins`, submit one prompt (anything), then re-run `/verify-plan`.

Do nothing else until the user addresses this.

## Step 2 — Oversize guard

Read the resolved log path from the stash, then measure its size:

```bash
log="$(cat "$stash" | tr -d '\n')"
bytes="$(wc -c < "$log")"
marker="${TMPDIR:-/tmp}/verify-plan-oversize-$key"
```

- `bytes` ≤ **600000** (≈ 150k tokens): remove any stale marker (`rm -f "$marker"`),
  proceed to Step 3.
- `bytes` > 600000 and `$marker` **absent**: write the marker (`touch "$marker"`),
  then hard-stop. Report the measured size (e.g. "session log is ~410k bytes, over the
  ~150k-token cap") and tell the user that re-running `/verify-plan` once more will
  override the guard and proceed.
- `bytes` > 600000 and `$marker` **present**: remove the marker (`rm -f "$marker"`),
  then proceed to Step 3 — this is the override run.

## Step 3 — Assemble target refs

From the conversation, gather the concrete refs of the plan/PRD/issue-slices in play:
- **File paths** (e.g. `PLAN.md`, a handoff-plan file under `~/.claude/plans/`, a PRD
  markdown file in the repo)
- **GitHub issue numbers** (the `prd`-labeled tracking issue and/or its slices, read
  live with `gh issue view <n>`)

`$ARGUMENTS`, if provided, narrows or overrides what to check. Pass **refs, not pasted
content** — the subagent reads each source live so the review is never against a stale
paraphrase. If you can't identify any target from the conversation and no `$ARGUMENTS`
were given, ask the user which artifact to check rather than guess.

## Step 4 — Spawn the subagent

Call the `Agent` tool with `subagent_type: "general-purpose"` and `model: "sonnet"`.
(There is no `effort` parameter on `Agent` — don't try to pass one.)

**Keep the prompt short.** A terse prompt is both far faster (a verbose, heavily
structured prompt makes the subagent read the log in tiny chunks and crawl — ~10× slower)
*and* sharper. Use roughly this, filling in the refs from Step 3 and the path from Step 1:

> Read the target(s) `<refs assembled in Step 3 — file paths; `gh issue view <n>` for
> GitHub issues>` and the session log `<resolved transcript path>` (JSONL of the
> conversation that produced them).
>
> Does each target match the decisions made in the session? Later decisions override
> earlier ones. Report any contradictions or omissions, read-only. Lead with
> `VERDICT: ALIGNED` or `VERDICT: MISMATCHES (n)`.

## Step 5 — Relay the report

Relay the subagent's output verbatim to the user. Do not summarize, filter, or editorialize.
