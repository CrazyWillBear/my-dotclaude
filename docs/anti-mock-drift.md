# Anti-mock-drift: keeping the build loop honest

This is the design behind a set of guards woven through the `/to-prd` → `/to-issues` →
`/orchestrate` (implementer → merger → my-review) workflow. Their one job: stop a slice from
being marked **done** while the thing it exists to build is **mocked, not wired**.

The pattern is portable. The second half of this doc is how to adopt it in a project that
doesn't use this exact toolchain (e.g. `the-retinue`).

## The failure it prevents

A slice's acceptance test can pass two ways: because the behavior works, or because the
behavior was *mocked out* and the test asserts against the mock. The second is invisible to a
green test suite — and it compounds. The next slice builds on the mocked seam, also mocks, and
by the time anyone runs the real path (usually the final hand-off-to-human end-to-end test) the
codebase is several layers of fiction deep and expensive to unwind.

**Case study — `the-retinue`, issue #6** ("build a single ready slice"). The slice existed to
prove the real loop: clone → implementer edits in a worktree → done-check runs *on those edits*
→ push `issue-<N>` → merge. The implementation mocked the Docker container and all git ops. The
unit suite went green (414 passing) while *nothing was ever cloned, built, pushed, or merged*.
Three later slices built on that mock. The result was three disconnected filesystems and a
band-aid "merge container" that tried to `git fetch` a branch nobody ever pushed. The final
smoke test (#17) literally could not start until #6's "done" work was actually built.

That is mock-drift. None of the loop's gates — blockers-closed, project-done-check-green,
my-review-finds-no-bugs — caught it, because all three trust whatever the project's test suite
says, and the suite was satisfied by mocks.

## The key concept: the central mechanism

**The central mechanism of a slice is the real thing that slice exists to make work** — the
load-bearing behavior its acceptance criterion is supposed to demonstrate. Not a side detail;
the point.

**Litmus test:** *if I mock this, does the acceptance criterion still prove what the slice
promised?* If mocking X makes the test pass while proving nothing, X is the central mechanism.

Mocks that are **fine** (boundary mocks — not the point of the slice):

- a clock, so a timeout test runs fast
- an LLM's text reply, when you're testing your *handling* of the reply, not the model
- a third-party API's rate-limit header

Mocks that are **drift** (central mocks — the point of the slice):

- the DB write, in a slice whose promise is "the row lands in the database"
- the container + git ops, in `the-retinue` #6 above

### Two scopes

- **Per-PRD central mechanism** — the one outermost real behavior the *whole feature* must
  exercise by the end. `the-retinue`'s = the disposable-container `clone → build → push → merge`
  loop. Stated once, in the PRD.
- **Per-slice central mechanism** — the load-bearing thing *one slice* proves; almost always its
  slice of the PRD's. `#6` → the single-issue build loop; `#4` → done-check in a real container
  with secrets; a pure-logic slice ("parse `## Blocked by`") → the parser, no container needed.

They compose: build each slice's piece real (or declare debt), and by the final gate the whole
mechanism is real.

## The two guards

### 1. Per-slice — my-review audit (catch it the round it happens)

Every slice carries a `## Central mechanism` line (derived from the PRD). The implementer is
expected to build it **real** (thin is fine — a tracer bullet, not a full implementation). If it
genuinely must defer the real wiring, it **declares mock-debt** rather than hiding it.

`my-review` audits each built slice on its branch diff: *is the named central mechanism actually
exercised, or mocked?*

- **Declared** mock → confirm it, file a `mock-debt` follow-up issue to wire it real later.
- **Undeclared** central mock (the `the-retinue` #6 failure) → auto-convert: treat it as
  mock-debt, file the follow-up itself. Hiding it and declaring it end up the same place — the
  ledger — so there's no incentive to hide.

### 2. Per-PRD — the mock-debt ledger + e2e-gate (catch the deferred)

Deferred mocks are allowed, but **tracked**, and they **block staging**:

- Each declared/auto-converted mock becomes a `mock-debt`-labelled follow-up issue ("wire real
  X"). The set of **open `mock-debt` issues is the ledger** (source of truth = the label query;
  a mirror lives in the PRD issue body for humans).
- The final end-to-end / staging slice is labelled **`e2e-gate`**. The orchestrator's ready-rule:
  **an `e2e-gate` issue is never ready while any open `mock-debt` issue exists**, even if its
  `## Blocked by` refs are all closed. The whole central mechanism must be real before the gate
  goes green.

This is why per-slice mocking is OK to *close* on: nothing dies in the ledger silently, and the
gate can't be reached with debt outstanding.

### Why a mock-debt follow-up isn't phantom work

Un-mocking X = wiring the slice to the **real** X — which can't happen until real X exists. So
the follow-up isn't ready-now; it's `## Blocked by` whatever slice builds real X. The implementer
that wrote the mock knows what it was waiting on (it mocked X *because* X wasn't ready), so it
records that blocker at declaration time. The loop simply won't pick the follow-up up until X is
real — automatically "much later." If no slice ever builds real X, the follow-up *is* the slice
that builds it, just deferred. Either way it's schedulable, never a phantom.

> **Default thin-real, mock as a rare escape hatch.** Mocking the central mechanism in *every*
> early slice and deferring all un-mocking to one big end-phase recreates exactly the
> `the-retinue` big-bang. A long ledger is a slicing smell, not a normal state.

## End-to-end flow

| Stage | Role in the guard |
| --- | --- |
| `/to-prd` | Names the **per-PRD central mechanism** (the outermost real interface) in the PRD body — extends the existing "highest test level" step. |
| `/to-issues` | Derives a `## Central mechanism` line per slice; default = build it thin-real; allows a `## Mock-debt` escape hatch. Labels the final e2e/staging slice `e2e-gate`. Ensures the `mock-debt` + `e2e-gate` labels exist. |
| `implementer` | Builds its slice's central mechanism real. If it must mock it, writes a `## Mock-debt` declaration (`Mocked: <X>. Real wiring blocked by: #N \| deferred`) — declare-only; it's sandboxed and never edits the cross-issue graph. |
| `my-review` | Reviews each built slice on its branch diff and audits its central mechanism vs its test. Declared mock → confirm + file `mock-debt` follow-up. Undeclared central mock → auto-convert + file. Gains a narrow, audit-scoped `gh issue create` for mock-debt (its general review stays report-only). |
| `orchestrator` | Maintains the ledger mirror in the PRD body; enforces the ready-rule (`e2e-gate` blocked while any open `mock-debt`); reports debt each round. |

## The mock-debt issue lifecycle

1. **Declare** — implementer mocks the central mechanism and writes a `## Mock-debt` note naming
   the mock and its real-wiring blocker.
2. **File** — my-review files a `mock-debt` + `ready-for-agent` follow-up ("wire real X, from
   #N"), `## Blocked by` the declared blocker (or "None - integration" if deferred to the end).
3. **Block** — the `e2e-gate` slice is held not-ready while this issue is open (ready-rule, via
   the label query — no per-ref wiring needed).
4. **Burn down** — a later round builds the follow-up once its blocker closes; closing it removes
   it from the ledger. When the ledger empties, the `e2e-gate` can finally be ready.

## Labels

- `mock-debt` — on each un-mock follow-up issue. Open set = the ledger; the e2e-gate ready-rule
  queries it.
- `e2e-gate` — on the final end-to-end / staging slice the ledger must be empty before.

(Existing labels `ready-for-agent`, `hitl`, `review-fix`, `prd` are unchanged.)

## Adopting this in another project (e.g. `the-retinue`)

The toolchain-specific pieces above are just an implementation. The portable rules:

1. **Name the central mechanism, per feature and per slice.** Write it down. "The outermost real
   interface this proves" is the test.
2. **Default to a thin *real* tracer, never a mock of the central mechanism.** A tracer bullet
   is allowed to be minimal; it is *not* allowed to fake the thing it exists to prove. (This one
   rule alone would have stopped `the-retinue` #6.)
3. **If you must defer the real wiring, make the debt a tracked, blocking work-item** — not a
   comment, not a TODO. It blocks the staging/e2e gate until paid.
4. **Have a reviewer (human or agent) audit "is the central mechanism mocked?"** as a first-class
   review question, separate from "are there bugs?". A passing test suite is not evidence the
   central mechanism is wired.
5. **Make the test suite exercise the real central mechanism at least once**, end-to-end, before
   anything ships. If that's expensive, it's the *one* place to spend the cost — the cheap unit
   tests can keep mocking boundaries.

For `the-retinue` specifically: the open PRD (#1) already names the central mechanism (the
single disposable-container clone→build→push→merge loop). The drift is that #6 was closed with it
mocked. Applying rule 3 retroactively = file the mock-debt follow-ups (real container worktree,
real push, real fetch-against-pushed-branch) and block the smoke slice (#17) on them — which is
already true in practice, since #17 cannot run until they exist.
