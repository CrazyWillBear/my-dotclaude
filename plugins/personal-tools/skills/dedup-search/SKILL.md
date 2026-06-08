---
name: dedup-search
description: Search the repo for reusable or extendable code before writing new code — extracts search terms from the task, runs the dedup-search helper, and triages each candidate into reuse | extend | none. Emits a reuse-candidate list or an explicit "searched, nothing reusable" statement. Use before any implementation: "/dedup-search", "search for duplicates", "find reusable code".
argument-hint: "[task description, issue body, or feature name to search for]"
model: inherit
allowed-tools: Read, Bash
---

Run a duplicate-code search for the task in `$ARGUMENTS` before writing any new code.
The goal is to surface existing helpers, functions, or modules that can be reused or
extended — so nothing gets reinvented. When nothing reusable exists, say so explicitly
so the caller knows the search ran.

## Step 1 — Extract search terms

Read `$ARGUMENTS` (the task description, issue body, or feature name) and pull out
3–8 concrete search terms. Prefer:

- **function / helper names** the feature would likely define or call
  (e.g. `parse_args`, `format_output`, `run_search`)
- **domain nouns** central to the task (e.g. `dedup`, `candidate`, `triage`)
- **file-name fragments** you'd expect a relevant module to carry
  (e.g. `search`, `utils`, `helper`)
- **dependency names** the feature would import (e.g. `ripgrep`, `ctags`)

Keep terms short (1–2 words). Avoid stop-words (`the`, `a`, `is`). If `$ARGUMENTS`
is sparse, infer terms from the natural vocabulary of the task domain.

## Step 2 — Run the helper

The helper is at `plugins/personal-tools/scripts/dedup-search.sh` relative to the
repo root. Locate the repo root with `git rev-parse --show-toplevel`, then run:

```
bash <repo-root>/plugins/personal-tools/scripts/dedup-search.sh <repo-root> <term1> [term2 ...]
```

Pass all extracted terms as separate positional arguments. The helper emits a
tab-separated candidate table to stdout — one row per match:

```
<angle>   <file>:<line>   <snippet>
```

Angles include `keyword`, `file-loc`, `literal`, `dep`, `def`, and `ctags-sym`
(when universal-ctags is installed). All rows are already de-duplicated by the helper.

If the helper exits non-zero (bad args, missing `rg`), report the error and stop.

## Step 3 — Triage each candidate

For every row in the helper output, decide:

- **reuse** — the existing code already does exactly what is needed. The caller
  should call or import it directly without modification.
- **extend** — the existing code does something adjacent; a targeted addition,
  parameter, or subclass would make it fit. Less work than writing from scratch.
- **none** — the match is coincidental (the term appears in an unrelated context,
  a comment, or a test fixture). Ignore it.

Apply these criteria in order:

1. Read the matched snippet and, if needed, a few lines of surrounding context
   (use `Read` at the reported `file:line` ± a small window) to understand what
   the code actually does.
2. Compare it against what the task needs. A `reuse` verdict requires a real
   behavioral overlap — not just a name match.
3. If several rows point to the same underlying function or module, consolidate
   them into one entry in the output.
4. Rows whose only match is inside a test fixture, a comment, or a string literal
   with no behavioral relevance default to `none`.

Do **not** encode triage logic in the helper. All judgment lives here.

## Step 4 — Emit the reuse-candidate list

### When candidates exist (any `reuse` or `extend` verdicts)

Emit a markdown list. One row per distinct candidate:

```
- `<file>:<line>` — <what it does in one line> — **reuse** | **extend**
  <one sentence on how to reuse or what extension is needed>
```

Group `reuse` rows before `extend` rows. Omit `none` rows entirely.

### When nothing is reusable

State this explicitly — never emit empty output:

> Searched `<repo-root>` for: `<term1>`, `<term2>`, … — no reusable or extendable
> code found. Proceed with a new implementation.

This explicit statement lets the caller distinguish "search ran, found nothing"
from "search was skipped."

## Honesty rules

- Never claim reuse without reading the code. A name match is not a behavior match.
- If the helper emits no rows at all, that is a valid result — emit the explicit
  "searched, nothing reusable" statement.
- If the task already names a file to modify, still run the search: there may be
  helpers elsewhere that the named file should call instead of reimplementing.
