---
name: review-grill
description: Check whether the plan(s)/PRD(s)/issue-slice(s) under discussion still match the decisions made in this session — a sonnet subagent reads the current session log, later decisions win, and reports drift read-only. Use for "/review-grill", "does my plan still match what we decided?".
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
stash="${TMPDIR:-/tmp}/review-grill-session-$key.path"
[ -s "$stash" ] && cat "$stash"
```

If `$stash` is **missing or empty**: hard error, stop. Tell the user:

> The session pointer isn't set yet — this usually means the hook hasn't fired yet.
> Run `/reload-plugins`, submit one prompt (anything), then re-run `/review-grill`.

Do nothing else until the user addresses this.

## Step 2 — Oversize guard

Read the resolved log path from the stash, then measure its size:

```bash
log="$(cat "$stash" | tr -d '\n')"
bytes="$(wc -c < "$log")"
marker="${TMPDIR:-/tmp}/review-grill-oversize-$key"
```

- `bytes` ≤ **600000** (≈ 150k tokens): remove any stale marker (`rm -f "$marker"`),
  proceed to Step 3.
- `bytes` > 600000 and `$marker` **absent**: write the marker (`touch "$marker"`),
  then hard-stop. Report the measured size (e.g. "session log is ~410k bytes, over the
  ~150k-token cap") and tell the user that re-running `/review-grill` once more will
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
(No `effort` parameter — communicate effort via the prompt text instead.) Use this
prompt, filling in the target refs and log path you resolved:

> Think hard / reason at high effort. You are reviewing whether some written artifacts
> still match the decisions made in a coding session. **Read-only — change nothing, edit
> nothing, comment nowhere.** Your entire job is to compare, then report.
>
> **Targets** (read each one yourself — use `Read` for file paths, `Bash(gh issue view
> <n>)` for GitHub issues):
> `<the refs assembled in Step 3>`
>
> **Session log** (read the WHOLE file — it may be large; use offset+limit to chunk
> through it): `<resolved transcript path>`
>
> The log is JSONL — one object per line. User turns have `"type":"user"`; assistant
> turns `"type":"assistant"`. Look for user choices embedded in `tool_result` blocks
> (from AskUserQuestion rounds) and in free-text user messages.
>
> A **decision** = something the user explicitly chose or changed, **plus** any proposal
> the assistant made that the user went along with or acted on. When the log records a
> decision and *later* reverses or refines it, **the later decision wins** — compare each
> target against the latest state, ignoring superseded earlier states.
>
> For each target, find:
> - **Contradictions** — the target states X but the session later chose not-X.
> - **Omissions** — the session decided Y but the target never captures Y.
>
> Output, in plain English:
> - First line: `VERDICT: ALIGNED` or `VERDICT: MISMATCHES FOUND (n)`.
> - Then one line per mismatch:
>   `<target item> — says <X> — session later decided <Y> (<pointer: who/when in log>) — <ruling: target stale / missing>`.
> - Then a short list of key decisions you DID confirm the target matches.
> - If a target is fully aligned, say so in one line. Do not manufacture findings.

## Step 5 — Relay the report

Relay the subagent's output verbatim to the user. Do not summarize, filter, or editorialize.
