---
name: review-rubric
description: The team's code review rubric — what to check for correctness, security, style/conventions, and performance, plus the expected output format. Use when reviewing code changes, a diff, or a set of files.
---

# Team Code Review Rubric

This is the team's shared, authoritative review standard. Edit it via pull
request — every change to *how we review* lives here, so both the automatic
hook and the manual `/review` command stay in sync.

Review the **change**, not the whole codebase. Prefer reviewing a diff. Verify
claims against the code; do not assume the author got it right.

---

## 1. Correctness & bugs  (highest priority)

- Logic errors, off-by-one, inverted conditions.
- Edge cases: empty input, zero, negative, very large, unicode, concurrent.
- Null / undefined / None handling; unwrapped optionals.
- Error handling: are failures caught at the right level? Any silently swallowed
  errors (`catch {}`)? Are errors actionable?
- Resource handling: files/sockets/locks closed on every path, including errors.
- Concurrency: shared mutable state, race conditions, missing `await`.
- Tests: do they exist for the new behavior, and do they actually assert it
  (not just run it)? Do existing tests still hold?

## 2. Security

- **Input crossing a trust boundary** is validated/escaped before use.
- Injection: SQL, shell/command, XSS, template, path traversal.
- AuthN/AuthZ: is every new endpoint/action checking who the caller is and
  whether they're allowed?
- Secrets: no API keys, tokens, passwords, or private hosts committed.
- No sensitive data (PII, tokens) written to logs or error messages.
- Safe deserialization; no `eval`/`exec` on untrusted data.
- Dependencies: new deps reputable and pinned?

## 3. Style & conventions

- Matches the patterns **already in this file and repo** — naming, file
  structure, error-handling idioms, logging style.
- Public API / function signatures are minimal and consistent with siblings.
- No dead code, commented-out blocks, stray debug prints, or leftover TODOs
  without context.
- Comments explain *why*, not *what*; the code itself is readable.

## 4. Performance & simplicity

- No obviously needless work in hot paths or loops.
- No N+1 queries / requests; batch where natural.
- No unbounded memory growth or unbounded retries.
- **Reuse over reinvention** — does a helper for this already exist?
- Not over-engineered: the simplest thing that correctly solves the problem.

---

## Output format

Start with a one-line verdict: **APPROVE** / **APPROVE WITH NITS** /
**CHANGES REQUESTED**.

Then findings grouped by severity, each line:

> **severity** — `path:line` — problem, why it matters, and a concrete fix.

Severity:
- **blocker** — bug, security issue, or breakage. Must fix before merge.
- **warning** — likely problem or meaningful smell. Should fix.
- **nit** — style/preference. Optional.

Keep it tight and specific. Cite `file:line`. A short accurate review beats a
long padded one — don't manufacture findings.

---

## Tuning this rubric (for maintainers)

Add team-specific rules under the relevant section above — e.g. "all DB access
goes through `repo/`", "no `console.log` in `packages/server`", "prefer
`Result<T>` over throwing in `core/`". Keep entries concrete and checkable so
the reviewer can actually verify them.
