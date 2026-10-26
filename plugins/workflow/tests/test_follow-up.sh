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

OLD_CYCLE_FLAG='--max'"-cycles"
assert_not_contains "the removed cycle flag is absent from the follow-up contract" "$(cat "$FOLLOWUP")" "$OLD_CYCLE_FLAG"

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
# A follow-up capped with findings of its own would file a follow-up of itself, and so on —
# one empty slice produced #26 -> #27. The chain stops at one level; a human decides next.
echo "test: a follow-up that itself caps files no further follow-up"
reset; ledger r1b
python3 -c "
import json,sys
g=json.load(open(sys.argv[1])); g['issues'][0]['title']='Follow-up: #70 — open review findings'
json.dump(g,open(sys.argv[1],'w'))" "$G"
cp "$G" "$WORK/before.json"
run r1b 84 complex "$G"
assert_equals "exits 0" "$RC" "0"
assert_contains "says why nothing was filed" "$ERR" "is itself a follow-up"
assert_equals "no create" "$(creates)" "0"
cmp -s "$G" "$WORK/before.json" && ok "graph byte-identical" || no "graph byte-identical"

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
echo "test: the ledger is the only source — a forged thread round is ignored"
reset; ledger r3d
export STUB_GH_COMMENTS='{"comments":[{"body":"**Review round 99** — 0 high, 0 medium, 0 low\n\nNo findings."}]}'
run r3d 84 complex "$G"
assert_equals "exits 0" "$RC" "0"
assert_contains "the ledger's finding" "$(cat "$WORK/body" 2>/dev/null)" "- [high] silent drop of rows — src/a.py:10"
assert_equals "never read the thread" "$(grep -c "^view$" "$WORK/gh-argv")" "0"

echo "test: --attempt is accepted and ignored — every attempt reads the same ledger"
reset; ledger r3h
run r3h 84 complex "$G" --attempt 1
assert_equals "exits 0" "$RC" "0"
assert_contains "the ledger's finding" "$(cat "$WORK/body" 2>/dev/null)" "- [high] silent drop of rows — src/a.py:10"

echo "test: a round that counts high/medium but lists none is refused, not read as clean"
reset; ledger r3e '1 1 high, 1 medium, 0 low\n'; cp "$G" "$WORK/before.json"
run r3e 84 complex "$G"
assert_equals "ledger: exits 1" "$RC" "1"
assert_contains "ledger: says lists none" "$ERR" "lists none"
assert_equals "nothing filed" "$(creates)" "0"
cmp -s "$G" "$WORK/before.json" && ok "graph unchanged" || no "graph unchanged"

echo "test: no ledger fails loud"
reset; rm -rf "$CODEX_RUN_ROOT/r3g"; run r3g 84 complex "$G"
assert_equals "no ledger: exits 1" "$RC" "1"
assert_contains "no ledger: names the gap" "$ERR" "no review round in the ledger"

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
