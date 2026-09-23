#!/usr/bin/env bash
#
# Tests for scripts/follow-up.sh — a capped merge's open findings become scheduled work.
#
# The central mechanism is REAL: the frozen graph JSON is amended by the script, then
# ready.sh runs against it and must hold the dependents until the follow-up is merged.
# Only `gh` is stubbed (it returns a fixed new issue number).
#
# Covers:
#   * one follow-up filed, open high/medium findings verbatim, lows dropped, tier label
#   * the graph gains the node; dependents gain it as a blocker; transitive ones untouched
#   * ready.sh holds the dependents until the follow-up is --merged
#   * the run log's follow-up event
#   * only low findings open → nothing filed, nothing touched
#   * the source follows the attempt's backend: codex → ledger only; claude → its own thread rounds (+ ledger)
#   * a parent outside the frozen scope, a second call, bad usage → refused
#
# Run: bash plugins/workflow/tests/test_follow-up.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FOLLOWUP="$PLUGIN_ROOT/scripts/follow-up.sh"
READY="$PLUGIN_ROOT/scripts/ready.sh"
RUNLOG="$PLUGIN_ROOT/scripts/run-log.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in: $2)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3' in: $2)" ;; *) ok "$1" ;; esac; }

export HOME="$WORK/home"; mkdir -p "$HOME"
git init -q "$WORK/repo" && cd "$WORK/repo" || exit 1
export CODEX_RUN_ROOT="$WORK/runs"
export FOLLOWUP_INFRA="$PLUGIN_ROOT/../infra/scripts"
# The roster decides the source: complex = codex then claude (attempt 1), standard = claude only.
export RESOLVE_TIER_ROOT="$WORK/tiers"; mkdir -p "$RESOLVE_TIER_ROOT"
cat >"$RESOLVE_TIER_ROOT/model-tiers.json" <<'JSON'
{
  "trivial":  { "planner": {"backend":"claude","model":"opus","effort":"medium"},
                "implementer": {"backend":"claude","model":"opus","effort":"medium"},
                "reviewer": {"backend":"claude","model":"opus","effort":"low"} },
  "standard": { "planner": {"backend":"claude","model":"opus","effort":"medium"},
                "implementer": {"backend":"claude","model":"opus","effort":"medium"},
                "reviewer": {"backend":"claude","model":"opus","effort":"high"} },
  "complex":  { "planner": {"backend":"claude","model":"opus","effort":"medium"},
                "implementer": [ {"backend":"codex","model":"gpt-6-luna","effort":"xhigh"},
                                 {"backend":"claude","model":"opus","effort":"medium"} ],
                "reviewer": {"backend":"claude","model":"opus","effort":"xhigh"} }
}
JSON

BIN="$WORK/bin"; mkdir -p "$BIN"
cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"${STUB_GH_ARGV:-/dev/null}"
if [ "${1:-}" = issue ] && [ "${2:-}" = view ]; then
    [ -n "${STUB_GH_COMMENTS:-}" ] || STUB_GH_COMMENTS='{"comments":[]}'
    printf '%s' "$STUB_GH_COMMENTS"
    exit 0
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = create ]; then
    while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "${STUB_GH_BODY:-/dev/null}"; shift; done
    echo "https://github.com/o/r/issues/${STUB_GH_NEW:-131}"
fi
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
export STUB_GH_ARGV="$WORK/gh-argv" STUB_GH_BODY="$WORK/body"

G="$WORK/graph.json"
mkgraph() {
    cat >"$G" <<'JSON'
{"issues": [
 {"n": 84, "title": "capped thing", "state": "open", "labels": ["ready-for-agent", "tier:complex"], "tier": "complex", "body": "", "comments": "", "blockedBy": []},
 {"n": 85, "title": "t85", "state": "open", "labels": ["ready-for-agent"], "tier": "standard", "body": "", "comments": "", "blockedBy": [84]},
 {"n": 95, "title": "t95", "state": "open", "labels": ["ready-for-agent"], "tier": "standard", "body": "", "comments": "", "blockedBy": [84]},
 {"n": 88, "title": "t88", "state": "open", "labels": ["ready-for-agent"], "tier": "standard", "body": "", "comments": "", "blockedBy": [85]}
],
 "blockerStates": {"84": "open", "85": "open"},
 "mockDebtOpen": []}
JSON
}

# ledger <runid> [content] — the run-dir ledger for #84; default: round 2 has 1 high, 1 medium, 1 low
ledger() {
    local d="$CODEX_RUN_ROOT/$1/issue-84"
    mkdir -p "$d"
    if [ $# -ge 2 ]; then printf '%b' "$2" >"$d/rounds"; return; fi
    printf '%b' '1 2 high, 1 medium, 1 low\n' \
        'finding\t1\thigh\told one\tsrc/a.py:1\n' \
        'finding\t1\thigh\told two\tsrc/a.py:2\n' \
        'finding\t1\tmedium\told three\tsrc/b.py:1\n' \
        'finding\t1\tlow\told four\tsrc/c.py:9\n' \
        '2 1 high, 1 medium, 1 low\n' \
        'finding\t2\thigh\tsilent drop of rows\tsrc/a.py:10\n' \
        'finding\t2\tmedium\tunchecked return\tsrc/b.py:4\n' \
        'finding\t2\tlow\tnit\tsrc/c.py:1\n' >"$d/rounds"
}

reset() { rm -f "$WORK/gh-argv" "$WORK/body"; unset STUB_GH_COMMENTS; mkgraph; }
run() { OUT="$(bash "$FOLLOWUP" "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }
run_from() { local repo="$1"; shift; OUT="$(cd "$repo" && bash "$FOLLOWUP" "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }
creates() { cat "$WORK/gh-argv" 2>/dev/null | grep -c '^create$'; }
jq_() { python3 -c "import json,sys; g=json.load(open(sys.argv[1])); print($1)" "$G"; }

# ---------------------------------------------------------------------------
echo "test: files ONE follow-up carrying the open high and medium findings verbatim"
reset; ledger r1
run r1 84 complex "$G"
assert_equals "exits 0" "$RC" "0"
assert_equals "one gh issue create" "$(creates)" "1"
ARGV="$(cat "$WORK/gh-argv")"
assert_contains "labels the parent tier" "$ARGV" "tier:complex"
assert_contains "labels ready-for-agent" "$ARGV" "ready-for-agent"
BODY="$(cat "$WORK/body")"
assert_contains "high finding verbatim" "$BODY" "- [high] silent drop of rows — src/a.py:10"
assert_contains "medium finding verbatim" "$BODY" "- [medium] unchecked return — src/b.py:4"
assert_not_contains "no low finding" "$BODY" "nit"
assert_not_contains "no earlier-round finding" "$BODY" "old one"
assert_contains "names the parent in prose" "$BODY" "#84"
assert_contains "blocked by None" "$BODY" "## Blocked by
None"
assert_not_contains "parent is not a blocker" "$BODY" "Blocked by
#84"
assert_contains "prints parent → child" "$OUT" "#84 → #131"
assert_contains "prints what it re-blocked" "$OUT" "re-blocked #85, #95"

echo "test: the graph gains the follow-up as a scoped node and the dependents gain it as a blocker"
assert_equals "node 131 state" "$(jq_ '[i for i in g["issues"] if i["n"]==131][0]["state"]')" "open"
assert_equals "node 131 labels" "$(jq_ 'sorted([i for i in g["issues"] if i["n"]==131][0]["labels"])')" "['ready-for-agent', 'tier:complex']"
assert_equals "node 131 tier" "$(jq_ '[i for i in g["issues"] if i["n"]==131][0]["tier"]')" "complex"
assert_equals "node 131 unblocked" "$(jq_ '[i for i in g["issues"] if i["n"]==131][0]["blockedBy"]')" "[]"
assert_equals "#85 re-blocked" "$(jq_ '[i for i in g["issues"] if i["n"]==85][0]["blockedBy"]')" "[84, 131]"
assert_equals "#95 re-blocked" "$(jq_ '[i for i in g["issues"] if i["n"]==95][0]["blockedBy"]')" "[84, 131]"
assert_equals "#88 untouched" "$(jq_ '[i for i in g["issues"] if i["n"]==88][0]["blockedBy"]')" "[85]"
assert_equals "#84 untouched" "$(jq_ '[i for i in g["issues"] if i["n"]==84][0]["blockedBy"]')" "[]"
assert_equals "blockerStates knows 131" "$(jq_ 'g["blockerStates"]["131"]')" "open"

echo "test: ready.sh holds the dependents until the follow-up is merged"
assert_equals "only the follow-up is ready" "$(bash "$READY" "$G" --merged 84 2>/dev/null)" "131"
out="$(bash "$READY" "$G" --merged 84 --in-flight 131 2>"$WORK/rerr")"; rc=$?
assert_equals "designed empty: no stdout" "$out" ""
assert_equals "designed empty: exit 0" "$rc" "0"
assert_contains "designed empty: nothing-to-do" "$(cat "$WORK/rerr")" "nothing-to-do:"
assert_equals "follow-up merged releases them" "$(bash "$READY" "$G" --merged 84 --merged 131 2>/dev/null)" "85
95"

echo "test: the run log has a follow-up event naming parent, child and the re-blocked issues"
REPLAY="$(bash "$RUNLOG" replay r1)"
assert_contains "event" "$REPLAY" '"event": "follow-up"'
assert_contains "parent" "$REPLAY" '"n": 84'
assert_contains "child" "$REPLAY" '"child": 131'
assert_contains "reblocked" "$REPLAY" '"reblocked": [85, 95]'
assert_contains "state folds it" "$(bash "$RUNLOG" state r1)" "followups=84:131"

echo "test: a second call for the same parent does not file twice"
run r1 84 complex "$G"
assert_equals "exits 1" "$RC" "1"
assert_contains "says already filed" "$ERR" "already filed"
assert_equals "still one create" "$(creates)" "1"

# ---------------------------------------------------------------------------
echo "test: only low findings open files nothing and says so"
reset; ledger r2 '1 1 high, 0 medium, 0 low\nfinding\t1\thigh\tfixed later\tsrc/a.py:1\n2 0 high, 0 medium, 1 low\nfinding\t2\tlow\tnit\tsrc/c.py:1\n'
cp "$G" "$WORK/before.json"
run r2 84 complex "$G"
assert_equals "exits 0" "$RC" "0"
assert_contains "says nothing filed" "$ERR" "nothing filed"
assert_equals "no create" "$(creates)" "0"
cmp -s "$G" "$WORK/before.json" && ok "graph byte-identical" || no "graph byte-identical"
bash "$RUNLOG" replay r2 >/dev/null 2>&1; assert_equals "no run-log record" "$?" "1"

# ---------------------------------------------------------------------------
echo "test: no ledger — the last review comment on the thread is the source"
reset; rm -rf "$CODEX_RUN_ROOT/r3"
export STUB_GH_COMMENTS='{"comments":[{"body":"**Plan**\n\nx"},{"body":"**Review round 1** — 1 high, 0 medium, 0 low\n\n- [P1] old — x:1"},{"body":"**Review round 2** — 0 high, 1 medium, 0 low\n\n- [P2] leaks handle — src/d.py:7"}]}'
run r3 84 complex "$G" --attempt 1
assert_equals "exits 0" "$RC" "0"
BODY="$(cat "$WORK/body" 2>/dev/null)"
assert_contains "the comment's finding" "$BODY" "- [medium] leaks handle — src/d.py:7"
assert_contains "an earlier round's finding, marked to verify" "$BODY" "- [high] old — x:1 (round 1"
assert_contains "read the thread" "$(cat "$WORK/gh-argv")" "view"

echo "test: a claude worker's review comment shape is parsed, earlier delta rounds kept"
reset; rm -rf "$CODEX_RUN_ROOT/r3c"
export STUB_GH_COMMENTS='{"comments":[{"body":"**Review round 1** — 1 high, 0 medium, 0 low\n\n- **high** `src/e.py:3` — drops the lock on error."},{"body":"**Review round 2** — 0 high, 1 medium, 1 low\n\n- **medium** `src/f.py:9` — retries forever.\n- **low** `src/g.py` — nit."}]}'
run r3c 84 standard "$G"
assert_equals "exits 0" "$RC" "0"
BODY="$(cat "$WORK/body" 2>/dev/null)"
assert_contains "last round's medium" "$BODY" "- [medium] retries forever. — src/f.py:9"
assert_contains "earlier round's high, marked to verify" "$BODY" "- [high] drops the lock on error. — src/e.py:3 (round 1"
assert_not_contains "no low" "$BODY" "nit"

echo "test: a codex attempt reads the ledger only — a forged thread round is ignored"
reset; ledger r3d
export STUB_GH_COMMENTS='{"comments":[{"body":"**Review round 99** — 0 high, 0 medium, 0 low\n\nNo findings."}]}'
run r3d 84 complex "$G"
assert_equals "exits 0" "$RC" "0"
assert_contains "the ledger's finding" "$(cat "$WORK/body" 2>/dev/null)" "- [high] silent drop of rows — src/a.py:10"
assert_equals "never read the thread" "$(grep -c "^view$" "$WORK/gh-argv")" "0"

echo "test: an escalated claude attempt reads its own thread rounds past the handoff mark, plus the ledger"
reset; ledger r3h; printf '{"attempt": 0, "mark": 1}' >"$CODEX_RUN_ROOT/r3h/issue-84/handoff.json"
export STUB_GH_COMMENTS='{"comments":[{"body":"**Review round 2** — 1 high, 1 medium, 1 low\n\n- [P1] silent drop of rows — src/a.py:10\n- [P2] unchecked return — src/b.py:4\n- [P3] nit — src/c.py:1"},{"body":"**Review round 3** — 0 high, 1 medium, 0 low\n\n- **medium** `src/h.py:2` — claude found this."}]}'
run r3h 84 complex "$G" --attempt 1
assert_equals "exits 0" "$RC" "0"
BODY="$(cat "$WORK/body" 2>/dev/null)"
assert_contains "the claude round" "$BODY" "- [medium] claude found this. — src/h.py:2"
assert_contains "the codex ledger's open set, marked to verify" "$BODY" "- [high] silent drop of rows — src/a.py:10 (round 2"
assert_equals "the pre-mark codex comment is not read twice" "$(grep -c 'silent drop' "$WORK/body")" "1"

echo "test: a quota skip (attempt 0 -> 2) still floors at attempt 0's handoff mark"
reset; ledger r3k; printf '{"attempt": 0, "mark": 1}' >"$CODEX_RUN_ROOT/r3k/issue-84/handoff.json"
mkdir -p "$WORK/tiers3"; python3 -c 'import json,sys; t=json.load(open(sys.argv[1])); i=t["complex"]["implementer"]; t["complex"]["implementer"]=[i[0],i[0],i[1]]; json.dump(t,open(sys.argv[2],"w"))' "$RESOLVE_TIER_ROOT/model-tiers.json" "$WORK/tiers3/model-tiers.json"
export STUB_GH_COMMENTS='{"comments":[{"body":"**Review round 2** — 1 high, 1 medium, 1 low\n\n- [P1] silent drop of rows — src/a.py:10\n- [P2] unchecked return — src/b.py:4\n- [P3] nit — src/c.py:1"},{"body":"**Review round 3** — 0 high, 1 medium, 0 low\n\n- **medium** `src/h.py:2` — claude found this."}]}'
RESOLVE_TIER_ROOT="$WORK/tiers3" run r3k 84 complex "$G" --attempt 2
assert_equals "exits 0" "$RC" "0"
assert_equals "the pre-mark codex comment is not filed twice" "$(grep -c 'silent drop' "$WORK/body" 2>/dev/null)" "1"

echo "test: with no run dir the floor is the newest **Plan** — a previous run's rounds are not read"
reset; rm -rf "$CODEX_RUN_ROOT/r3l"
export STUB_GH_COMMENTS='{"comments":[{"body":"**Review round 1** — 1 high, 0 medium, 0 low\n\n- **high** `src/old.py:1` — last run."},{"body":"**Plan**\n\nx"},{"body":"**Review round 1** — 1 high, 0 medium, 0 low\n\nSomething is wrong."}]}'
run r3l 84 standard "$G"
assert_equals "this run's count-without-list is refused" "$RC" "1"
assert_contains "says lists none" "$ERR" "lists none"

echo "test: a claude comment that mentions [Pn] in prose is still read as a claude comment"
reset; rm -rf "$CODEX_RUN_ROOT/r3i"
export STUB_GH_COMMENTS='{"comments":[{"body":"**Review round 1** — 1 high, 0 medium, 0 low\n\n- **high** `src/k.py:1` — same bug as the [P1] codex flagged."}]}'
run r3i 84 standard "$G"
assert_equals "exits 0" "$RC" "0"
assert_contains "the claude finding" "$(cat "$WORK/body" 2>/dev/null)" "- [high] same bug as the [P1] codex flagged. — src/k.py:1"

echo "test: a [Pn] comment review-counts.sh refuses fails loud, never drops the round"
reset; rm -rf "$CODEX_RUN_ROOT/r3j"
export STUB_GH_COMMENTS='{"comments":[{"body":"**Review round 1** — 0 high, 0 medium, 1 low\n\nSee [P1] above, it was wrong."}]}'
run r3j 84 standard "$G"
assert_equals "exits 1" "$RC" "1"
assert_contains "names the refusal" "$ERR" "review round 1"
assert_equals "files nothing" "$(creates)" "0"

echo "test: a round that counts high/medium but lists none is refused, not read as clean"
reset; ledger r3e '1 1 high, 1 medium, 0 low\n'; cp "$G" "$WORK/before.json"
run r3e 84 complex "$G"
assert_equals "ledger: exits 1" "$RC" "1"
assert_contains "ledger: says lists none" "$ERR" "lists none"
reset; rm -rf "$CODEX_RUN_ROOT/r3f"
export STUB_GH_COMMENTS='{"comments":[{"body":"**Review round 1** — 1 high, 0 medium, 0 low\n\nSomething is wrong in the parser."}]}'
run r3f 84 complex "$G" --attempt 1
assert_equals "thread: exits 1" "$RC" "1"
assert_contains "thread: says lists none" "$ERR" "lists none"
assert_equals "neither filed anything" "$(creates)" "0"
cmp -s "$G" "$WORK/before.json" && ok "graph unchanged" || no "graph unchanged"

echo "test: no ledger and no review comment fails loud"
reset; STUB_GH_COMMENTS='{"comments":[{"body":"**Plan**\n\nx"}]}' run r3b 84 complex "$G" --attempt 1
assert_equals "exits 1" "$RC" "1"
assert_contains "names the gap" "$ERR" "no ledger"
reset; rm -rf "$CODEX_RUN_ROOT/r3g"; run r3g 84 complex "$G"
assert_equals "codex attempt, no ledger: exits 1" "$RC" "1"
assert_contains "codex attempt, no ledger: names the gap" "$ERR" "no ledger"

# ---------------------------------------------------------------------------
echo "test: end-of-run integration review runs on the detached merged head"
INTEGRATION_REPO="$WORK/integration-repo"
mkdir -p "$INTEGRATION_REPO"
git -C "$INTEGRATION_REPO" init -q
git -C "$INTEGRATION_REPO" config user.email t@t.com
git -C "$INTEGRATION_REPO" config user.name t
printf 'base\n' >"$INTEGRATION_REPO/base.txt"
git -C "$INTEGRATION_REPO" add base.txt
git -C "$INTEGRATION_REPO" commit -qm base
INTEGRATION_BASE="$(git -C "$INTEGRATION_REPO" rev-parse HEAD)"
git -C "$INTEGRATION_REPO" checkout -qb issue-1
printf 'slice one\n' >"$INTEGRATION_REPO/one.txt"
git -C "$INTEGRATION_REPO" add one.txt
git -C "$INTEGRATION_REPO" commit -qm 'issue 1'
git -C "$INTEGRATION_REPO" checkout -qb issue-2 "$INTEGRATION_BASE"
printf 'slice two\n' >"$INTEGRATION_REPO/two.txt"
git -C "$INTEGRATION_REPO" add two.txt
git -C "$INTEGRATION_REPO" commit -qm 'issue 2'
git -C "$INTEGRATION_REPO" checkout -qb run "$INTEGRATION_BASE"
git -C "$INTEGRATION_REPO" merge -q --no-ff issue-1 -m 'merge issue 1'
git -C "$INTEGRATION_REPO" merge -q --no-ff issue-2 -m 'merge issue 2'
INTEGRATION_HEAD="$(git -C "$INTEGRATION_REPO" rev-parse HEAD)"
INTEGRATION_GRAPH="$WORK/integration-graph.json"
cat >"$INTEGRATION_GRAPH" <<'JSON'
{"issues":[{"n":1,"tier":"standard"},{"n":2,"tier":"complex"}]}
JSON
export CLAUDE_LOG="$WORK/claude.log"
cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\nPWD=%s\nHEAD=%s\n' "$*" "$PWD" "$(git rev-parse HEAD)" >>"$CLAUDE_LOG"
printf '%s' "${CLAUDE_REVIEW_OUT:-}"
STUB
chmod +x "$BIN/claude"

echo "test: P1 and P3 findings file one highest-tier follow-up and log counts"
reset
export STUB_GH_NEW=900 CLAUDE_REVIEW_OUT=$'- [P1] shared contract broke — one.txt:1\n- [P3] wording nit — two.txt:1'
cp "$INTEGRATION_GRAPH" "$WORK/integration-before.json"
run_from "$INTEGRATION_REPO" --integration int_findings "$INTEGRATION_BASE" "$INTEGRATION_HEAD" "$INTEGRATION_GRAPH"
assert_equals "exits 0" "$RC" "0"
assert_equals "exactly one gh issue create" "$(creates)" "1"
ARGV="$(cat "$WORK/gh-argv")"
BODY="$(cat "$WORK/body")"
assert_contains "body has the P1 verbatim" "$BODY" "- [P1] shared contract broke — one.txt:1"
assert_not_contains "body omits the P3" "$BODY" "wording nit"
assert_contains "labels highest tier complex" "$ARGV" "tier:complex"
assert_contains "labels ready-for-agent" "$ARGV" "ready-for-agent"
assert_contains "review uses xhigh reviewer effort" "$(cat "$WORK/claude.log")" "--effort xhigh"
assert_not_contains "review cwd is outside the source repo" "$(cat "$WORK/claude.log")" "PWD=$INTEGRATION_REPO"
assert_contains "review checkout is at the frozen head" "$(cat "$WORK/claude.log")" "HEAD=$INTEGRATION_HEAD"
REPLAY="$(cd "$INTEGRATION_REPO" && HOME="$HOME" bash "$RUNLOG" replay int_findings)"
assert_contains "logs high count" "$REPLAY" '"high": 1'
assert_contains "logs medium count" "$REPLAY" '"medium": 0'
assert_contains "logs low count" "$REPLAY" '"low": 1'
assert_contains "logs the filed child" "$REPLAY" '"child": 900'
assert_contains "prints the integration counts" "$OUT" "integration-review: 1 high, 0 medium, 1 low"
cmp -s "$INTEGRATION_GRAPH" "$WORK/integration-before.json" && ok "graph byte-identical" || no "graph byte-identical"

echo "test: a clean integration review files nothing and logs null child"
reset
export CLAUDE_REVIEW_OUT='No findings.'
run_from "$INTEGRATION_REPO" --integration int_clean "$INTEGRATION_BASE" "$INTEGRATION_HEAD" "$INTEGRATION_GRAPH"
assert_equals "clean review exits 0" "$RC" "0"
assert_equals "clean review creates nothing" "$(creates)" "0"
assert_contains "clean review logs zero counts" "$(cd "$INTEGRATION_REPO" && bash "$RUNLOG" replay int_clean)" '"high": 0, "low": 0, "medium": 0'
assert_contains "clean review logs null child" "$(cd "$INTEGRATION_REPO" && bash "$RUNLOG" replay int_clean)" '"child": null'
assert_contains "clean review says nothing filed" "$OUT" "nothing filed"

echo "test: an unparseable integration review fails without a child or event"
reset
export CLAUDE_REVIEW_OUT='Looks fine to me.'
run_from "$INTEGRATION_REPO" --integration int_bad "$INTEGRATION_BASE" "$INTEGRATION_HEAD" "$INTEGRATION_GRAPH"
assert_equals "unparseable review exits non-zero" "$RC" "1"
assert_equals "unparseable review creates nothing" "$(creates)" "0"
(cd "$INTEGRATION_REPO" && bash "$RUNLOG" replay int_bad >/dev/null 2>&1); replay_rc=$?
assert_equals "unparseable review logs no event" "$replay_rc" "1"
assert_equals "unparseable review output is kept in the run dir" \
    "$(cat "$CODEX_RUN_ROOT/int_bad/integration-review.txt" 2>/dev/null)" "Looks fine to me."
assert_contains "the failure names the kept review" "$ERR" "$CODEX_RUN_ROOT/int_bad/integration-review.txt"

echo "test: integration mode refuses a graph without tiered issues and bad arg counts"
NO_TIER_GRAPH="$WORK/no-tier.json"
printf '{"issues":[{"n":1,"tier":null}]}' >"$NO_TIER_GRAPH"
run_from "$INTEGRATION_REPO" --integration int_no_tier "$INTEGRATION_BASE" "$INTEGRATION_HEAD" "$NO_TIER_GRAPH"
assert_equals "no tier exits non-zero" "$RC" "1"
run_from "$INTEGRATION_REPO" --integration int_bad_args "$INTEGRATION_BASE" "$INTEGRATION_HEAD"
assert_equals "bad arg count exits non-zero" "$RC" "1"
unset STUB_GH_NEW CLAUDE_REVIEW_OUT

# ---------------------------------------------------------------------------
echo "test: refuses anything outside the frozen scope"
reset; ledger r4; cp "$G" "$WORK/before.json"
run r4 77 complex "$G"
assert_equals "exits 1" "$RC" "1"
assert_contains "says so" "$ERR" "#77 is not in the frozen scope"
assert_equals "no create" "$(creates)" "0"
cmp -s "$G" "$WORK/before.json" && ok "graph unchanged" || no "graph unchanged"

echo "test: bad usage fails loud"
reset
run r1 84 complex; assert_equals "missing arg exits 1" "$RC" "1"; assert_contains "prints usage" "$ERR" "usage"
run r1 84 huge "$G"; assert_equals "bad tier exits 1" "$RC" "1"
run r1 abc complex "$G"; assert_equals "bad issue exits 1" "$RC" "1"
run r1 84 complex "$WORK/nope.json"; assert_equals "missing graph exits 1" "$RC" "1"
run r1 84 complex "$G" --attempt x; assert_equals "bad attempt exits 1" "$RC" "1"
ledger r5 'finding\t1\thigh\tx\ty:1\n'
run r5 84 complex "$G"; assert_equals "no round line exits 1" "$RC" "1"; assert_contains "says no review round" "$ERR" "no review round"
assert_equals "none of these filed anything" "$(creates)" "0"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
