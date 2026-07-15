// Behavior harness for the orchestrate scheduler's js block (skills/orchestrate/SKILL.md).
//
// WHY THIS EXISTS. Every other assertion about that block is a grep: it proves a STRING is present
// — a string that *describes* the behavior. The block once shipped with three unguarded spawns
// under a fully green suite, because a grep cannot execute anything. This harness EXTRACTS the real
// block and RUNS it against a stubbed agent(), so the assertions are about what the scheduler DOES.
//
// The method: a dead agent returns NULL (it does not throw), so an unguarded spawn does not crash —
// it degrades, silently, into a wrong answer. Kill each spawn in turn and assert the run DRAINS.
// (It caught the one that matters: a dead reviewer merged an unreviewed slice AND let its dependent
// build on top of it. No grep in the suite noticed.)
//
// Run it directly (`node orchestrate-block.harness.js`) or via test_orchestrate-block-behavior.sh.
// Exits non-zero on any failure. Pure node — no deps.
const fs = require("fs");
const path = require("path");

const SKILL = path.resolve(__dirname, "../skills/orchestrate/SKILL.md");

// ---- extract the block: the FIRST ```js fence in the skill is the scheduler ----
const lines = fs.readFileSync(SKILL, "utf8").split("\n");
const out = [];
let inBlock = false, done = false;
for (const l of lines) {
  if (done) break;
  if (!inBlock && l === "```js") { inBlock = true; continue; }
  if (inBlock && l === "```") { inBlock = false; done = true; continue; }
  if (inBlock) out.push(l);
}
if (!out.length) { console.error(`no \`\`\`js block found in ${SKILL}`); process.exit(1); }

// The Workflow runtime runs the block as an ASYNC FUNCTION BODY — that is the only shape in which
// its top-level `return`, top-level `await` and `export const meta` all coexist. Reproduce that:
// drop the `export` keyword, then compile the rest as an async function body taking (args, agent).
const body = out.join("\n").replace(/^export const meta/m, "const meta");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const run = new AsyncFunction("args", "agent", body);

// ---- fixtures ----
const baseRepo = "/base";
const mkIssue = (n, over = {}) => ({
  n, title: `t${n}`, state: "open", labels: ["ready-for-agent"], tier: "standard",
  body: `body ${n}`, comments: "", blockedBy: [], ...over,
});
const mkArgs = (issues, over = {}) => ({
  baseRepo, baseBranch: "orchestrate-1", maxParallel: 2, maxCycles: 2, doneCheck: "make check",
  skipUnknown: false,
  ...over,
  graph: { issues, blockerStates: {}, mockDebtOpen: [], ...(over.graph || {}) },
});

// The issue number a prompt is about. The setup prompt carries no "#N" — only `-b issue-<N>` — so
// fall back to that.
const numsIn = p => {
  const hash = [...p.matchAll(/#(\d+)/g)].map(m => Number(m[1]));
  if (hash.length) return hash;
  return [...p.matchAll(/issue-(\d+)/g)].map(m => Number(m[1]));
};

// ---- the stub agent ----
// A stub whose spawns all succeed — except `kill`, which returns null (a dead agent).
//
// CLASSIFYING A SPAWN — deliberately NOT keyed on prose. Keying on prompt wording ("Bookkeeping",
// "worktree add", "verify each prior finding") would make an innocent REWORD of the skill silently
// reclassify a spawn, and the harness would then be testing a fiction. So key on STRUCTURE only:
//   * agentType            → planner / implementer / my-review / merger  (the block sets it)
//   * schema identity      → setup (worktree, no head) vs bookkeeper (filed)
//   * per-issue call ORDER → the 1st implementer of a chain is the BUILD, the rest are FIXES;
//                            the 1st my-review is the REVIEW, the rest are RE-REVIEWS.
// An unrecognized spawn THROWS (see `default:`) — it never silently degrades into a pass.
const makeAgent = (kill, findings = [], tweak = {}) => {
  const calls = [];
  const impls = new Map();      // issue → implementer spawns so far (1st = build, 2nd+ = fix)
  const revs  = new Map();      // issue → my-review spawns so far (1st = review, 2nd+ = re-review)
  const nth = (m, n) => { const c = (m.get(n) || 0) + 1; m.set(n, c); return c; };

  const classify = (prompt, opts) => {
    const n = numsIn(prompt)[0];
    if (opts.agentType === "workflow:planner")  return "planner";
    if (opts.agentType === "workflow:merger")   return "merger";
    if (opts.agentType === "workflow:implementer")     return nth(impls, n) === 1 ? "build" : "fix";
    if (opts.agentType === "personal-tools:my-review") return nth(revs,  n) === 1 ? "review" : "rereview";
    const props = opts.schema?.properties || {};
    if (props.filed) return "bookkeeper";
    if (props.worktree && !props.head) return "setup";
    return "unclassified";
  };

  return [calls, async (prompt, opts = {}) => {
    const kind = classify(prompt, opts);
    calls.push(kind);
    if (kind === kill) return null;                       // the dead agent
    const n = numsIn(prompt)[0];
    switch (kind) {
      case "setup":
        return tweak.setup
          ? tweak.setup(n)
          : { n, worktree: `${baseRepo}/.worktrees/issue-${n}`, branch: `issue-${n}`, failed: false };
      case "planner": return "PLAN TEXT";
      case "build":
      case "fix": {
        const built = { n, worktree: `${baseRepo}/.worktrees/issue-${n}`, branch: `issue-${n}`,
                        head: "deadbeef", failed: false };
        return tweak.build ? tweak.build(built, kind) : built;
      }
      case "review":   return { verdict: "v", findings, mockDebtFiled: [] };
      case "rereview": return { verdict: "v2", findings: [], mockDebtFiled: [] };
      case "merger": {
        const batch = [...prompt.matchAll(/^\s*- #(\d+) ·/gm)].map(m => Number(m[1]));
        return tweak.merger
          ? tweak.merger(batch)
          : { mergedIssues: batch.map(x => ({ n: x, mergeCommit: `sha${x}` })),
              conflictStops: [], doneCheckRed: false };
      }
      case "bookkeeper": return { filed: [900 + n] };
      default: throw new Error(`unclassified spawn (agentType=${opts.agentType} `
        + `schema=${JSON.stringify(Object.keys(opts.schema?.properties || {}))}): ${prompt.slice(0, 60)}`);
    }
  }];
};

let pass = 0, fail = 0;
const check = (name, cond, detail = "") => {
  if (cond) { pass++; console.log(`  PASS ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${detail}`); }
};
(async () => {
  const MED = [{ severity: "medium", path: "a.js", summary: "m" }];

  // 0. control: nothing dies → the issue merges clean
  {
    const [, agent] = makeAgent(null);
    const r = await run(mkArgs([mkIssue(1)]), agent);
    check("control: a healthy run merges the issue",
      r.mergedIssues.length === 1 && r.stopReason === null, JSON.stringify(r));
  }

  // 1-7. each spawn dies in turn → the run must DRAIN and merge nothing
  //      The planner case must ride a COMPLEX issue — it is the only tier that still has a plan
  //      stage, so it is the only tier on which a dead planner is even reachable.
  const cases = [
    ["setup",    [],  /worktree setup failed/,   {}],
    ["planner",  [],  /planner failed/,          { tier: "complex" }],
    ["build",    [],  /implementer failure/,     {}],
    ["review",   [],  /review failed/,           {}],
    ["fix",      MED, /fix implementer failure/, {}],
    ["rereview", MED, /re-review failed/,        {}],
    ["merger",   [],  /merger returned nothing/, {}],
  ];
  for (const [kill, findings, wantStop, over] of cases) {
    const [calls, agent] = makeAgent(kill, findings);
    let r, threw = null;
    try { r = await run(mkArgs([mkIssue(1, over)]), agent); } catch (e) { threw = e; }
    if (threw) { check(`${kill} dies → drains`, false, `THREW: ${threw.message}`); continue; }
    check(`${kill} dies → run drains with a reason`, wantStop.test(r.stopReason || ""),
      `stopReason=${JSON.stringify(r.stopReason)} calls=${calls}`);
    check(`${kill} dies → NOTHING is merged`, r.mergedIssues.length === 0,
      JSON.stringify(r.mergedIssues));
  }

  // 8. bookkeeper dies: the issue still merges (fire-and-forget), but the failure is VISIBLE.
  //    A LOW finding, so there is something to file — bookkeeping only spawns when there is.
  {
    const LOW = [{ severity: "low", path: "a.js", summary: "nit" }];
    const [calls, agent] = makeAgent("bookkeeper", LOW);
    const r = await run(mkArgs([mkIssue(1)]), agent);
    check("bookkeeper dies → it was actually spawned", calls.includes("bookkeeper"), `calls=${calls}`);
    check("bookkeeper dies → the merge still stands", r.mergedIssues.length === 1);
    check("bookkeeper dies → recorded in bookkeepingFailures",
      r.bookkeepingFailures.length === 1 && /returned nothing/.test(r.bookkeepingFailures[0].reason),
      JSON.stringify(r.bookkeepingFailures));
  }

  // 9. THE REGRESSION THIS EXISTS FOR: a dead reviewer must NOT merge an unreviewed slice,
  //    and must not leave a dependent free to build on it.
  {
    const [, agent] = makeAgent("review");
    const r = await run(mkArgs([mkIssue(1), mkIssue(2, { blockedBy: [1] })]), agent);
    check("dead reviewer: the unreviewed slice is NOT merged", r.mergedIssues.length === 0);
    check("dead reviewer: its dependent is never built",
      !r.perIssue.some(p => p.n === 2), JSON.stringify(r.perIssue));
  }

  // 10. a dead planner on a COMPLEX issue must not degrade into "self-planning tier → self-plan"
  {
    const [calls, agent] = makeAgent("planner");
    const r = await run(mkArgs([mkIssue(1, { tier: "complex" })]), agent);
    check("dead planner: never reaches the implementer", !calls.includes("build"), `calls=${calls}`);
    check("dead planner: drains", /planner failed/.test(r.stopReason || ""), r.stopReason);
  }

  // 11. trivial AND standard skip the plan stage entirely (the guard must not over-fire), and
  //     complex is the ONLY tier that still spawns a planner. The standard case is the 26%-of-work
  //     saving — if a planner ever reappears there, this test is the thing that catches it.
  for (const tier of ["trivial", "standard"]) {
    const [calls, agent] = makeAgent(null);
    const r = await run(mkArgs([mkIssue(1, { tier })]), agent);
    check(`${tier}: no planner spawn, and it still merges`,
      !calls.includes("planner") && r.mergedIssues.length === 1, `calls=${calls}`);
  }
  {
    const [calls, agent] = makeAgent(null);
    const r = await run(mkArgs([mkIssue(1, { tier: "complex" })]), agent);
    check("complex: DOES spawn a planner, and it still merges",
      calls.includes("planner") && r.mergedIssues.length === 1, `calls=${calls}`);
  }

  // 12. setup reports a worktree we never asked for → drain. verifyTree is an IMPROVISATION
  //     DETECTOR: the agent that invents its own path never gets a git command pointed at it.
  {
    const [calls, agent] = makeAgent(null, [], {
      setup: n => ({ n, worktree: "/tmp/somewhere-else", branch: "main", failed: false }),
    });
    const r = await run(mkArgs([mkIssue(1)]), agent);
    check("a wrong worktree/branch from setup drains before any build",
      /reported worktree/.test(r.stopReason || "") && !calls.includes("build"),
      `stop=${r.stopReason} calls=${calls}`);
  }

  // 13. the merger hallucinates a conflict-stop on an out-of-scope issue → dropped, never commented
  {
    const [, agent] = makeAgent(null, [], {
      merger: batch => ({ mergedIssues: batch.map(x => ({ n: x, mergeCommit: `sha${x}` })),
                          conflictStops: [{ n: 4242, reason: "r", worktree: "/w" }],
                          doneCheckRed: false }),
    });
    const r = await run(mkArgs([mkIssue(1)]), agent);
    check("an out-of-allowlist conflict-stop is dropped (no outward comment on #4242)",
      r.conflictStops.length === 0 && r.log.some(l => /dropping conflict-stop #4242/.test(l)),
      JSON.stringify(r.conflictStops) + JSON.stringify(r.log));
  }

  // 14. an all-closed scope: a clean empty, NOT a throw
  {
    const [, agent] = makeAgent(null);
    let r, threw = null;
    try { r = await run(mkArgs([mkIssue(1, { state: "closed" })]), agent); } catch (e) { threw = e; }
    check("an all-closed scope returns a clean empty, never a throw",
      !threw && r && r.stopReason === null && r.mergedIssues.length === 0,
      threw ? `THREW: ${threw.message}` : "");
    check("...and it says why", !threw && r.log.some(l => /already closed/.test(l)),
      threw ? "" : JSON.stringify(r?.log));
  }

  // 15. an e2e-gate held by open mock-debt: also a clean empty, NOT a throw
  {
    const [, agent] = makeAgent(null);
    let r, threw = null;
    try {
      r = await run(mkArgs([mkIssue(1, { labels: ["e2e-gate"] })],
                           { graph: { mockDebtOpen: [55] } }), agent);
    } catch (e) { threw = e; }
    check("a mock-debt-held e2e-gate scope returns a clean empty, never a throw",
      !threw && r && r.stopReason === null && r.unbuilt.includes(1),
      threw ? `THREW: ${threw.message}` : JSON.stringify(r?.unbuilt));
  }

  // 16. an UNEXPLAINED empty (all hitl) still throws — the guard must not go soft
  {
    const [, agent] = makeAgent(null);
    let threw = null;
    try { await run(mkArgs([mkIssue(1, { labels: ["hitl"] })]), agent); } catch (e) { threw = e; }
    check("an all-hitl scope STILL throws (unexplained empty)",
      !!threw && /no scoped issue is READY/.test(threw.message), threw && threw.message);
  }

  // 17. THE UNKNOWN-STATE HOLE. `openScoped.length === 0` is NOT a proxy for "every scoped issue is
  //     closed": an `unknown` issue (gh unauthenticated / rate-limited / ref deleted) is neither
  //     open NOR closed. With --skip-unknown the launch throw is downgraded to a log, so a scope of
  //     nothing but unknowns reaches the classifier — and must NOT be certified "complete".
  {
    const [, agent] = makeAgent(null);
    let r, threw = null;
    try {
      r = await run(mkArgs([mkIssue(1, { state: "unknown" }), mkIssue(2, { state: "unknown" })],
                           { skipUnknown: true }), agent);
    } catch (e) { threw = e; }
    check("an ALL-UNKNOWN scope (--skip-unknown) throws, never a clean empty",
      !!threw, threw ? "" : `returned clean: ${JSON.stringify(r?.log)}`);
    check("...and it never claims the scope is complete",
      !!threw && !(r?.log || []).some(l => /scope is complete/.test(l)),
      JSON.stringify(r?.log));
  }

  // 18. same hole, mixed: one genuinely closed issue + unknowns. openScoped is STILL empty, so the
  //     old proxy fired and reported a partially-unreadable scope as fully complete.
  {
    const [, agent] = makeAgent(null);
    let r, threw = null;
    try {
      r = await run(mkArgs([mkIssue(1, { state: "closed" }), mkIssue(2, { state: "unknown" })],
                           { skipUnknown: true }), agent);
    } catch (e) { threw = e; }
    check("closed + UNKNOWN (--skip-unknown) throws — the scope is not 'complete'",
      !!threw && !(r?.log || []).some(l => /scope is complete/.test(l)),
      threw ? "" : `returned clean: ${JSON.stringify(r?.log)}`);
  }

  // 19. a gate-held e2e-gate PLUS an unrelated non-ready issue is NOT a clean empty (the gate holds
  //     only part of the scope) — so it throws, correctly. But the throw must NAME the gate hold,
  //     or a DESIGNED state reads as a broken scope.
  {
    const [, agent] = makeAgent(null);
    let threw = null;
    try {
      await run(mkArgs([mkIssue(1, { labels: ["e2e-gate"] }), mkIssue(2, { labels: ["hitl"] })],
                       { graph: { mockDebtOpen: [55] } }), agent);
    } catch (e) { threw = e; }
    check("a partially gate-held scope throws (loud over silent)",
      !!threw && /no scoped issue is READY/.test(threw.message), threw && threw.message);
    check("...and the throw NAMES the e2e-gate hold, so a designed state is not misread as broken",
      !!threw && /e2e-gate/.test(threw.message) && /#1\b/.test(threw.message),
      threw && threw.message);
  }

  // 20. a build that omits `head` (optional in BUILT_SCHEMA) degrades the re-review delta to the
  //     whole branch. That is SAFE (a superset of the delta) but it must not be SILENT.
  {
    const [, agent] = makeAgent(null, MED, {
      build: (built, kind) => (kind === "build" ? { ...built, head: undefined } : built),
    });
    const r = await run(mkArgs([mkIssue(1)]), agent);
    check("a headless build still merges (degrade, never drain)", r.mergedIssues.length === 1,
      JSON.stringify(r.stopReason));
    check("a headless build is LOGGED — the widened re-review is visible in the report",
      r.log.some(l => /#1: build reported no head/.test(l) && /widened/.test(l)),
      JSON.stringify(r.log));
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})();
