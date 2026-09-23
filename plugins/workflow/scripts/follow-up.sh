#!/usr/bin/env bash
#
# follow-up.sh — a capped merge's open findings become ONE scheduled follow-up issue.
#
# Usage:
#   bash follow-up.sh <runid> <issue> <tier> <graph.json>
#
# A merge that lands capped (findings remained at --max-cycles) leaves work behind.
# Instead of holding its dependents by hand, this files one `ready-for-agent` issue
# carrying the still-open high/medium findings verbatim, adds it to the FROZEN graph
# as a scoped node, and adds it as a blocker of every scoped issue whose `blockedBy`
# names the capped one. ready.sh then holds those dependents until the follow-up is
# `--merged` — no ready.sh change, the existing blocker rule does it. This is the ONLY
# place the run adds to its own scope (PRD #109), so it refuses a parent outside the
# frozen graph, and a second call for the same parent.
#
# Open findings: the finding lines of the NEWEST round in the run-dir ledger
# ($CODEX_RUN_ROOT/<runid>/issue-<N>/rounds, #110) — a scoped re-review restates every
# finding still open, so the last round is the open set. No ledger (claude-backed
# worker) → the last `**Review round N**` comment on the thread, parsed by infra's
# review-counts.sh --findings — the one finding parser, never a second.
# Only lows open → nothing filed, nothing touched, exit 0.
#
# Output: `follow-up: #<N> → #<child> (tier:<tier>) re-blocked #85, #95` on stdout.
#
# Seams (env): CODEX_RUN_ROOT (as spawn.sh), FOLLOWUP_INFRA (review-counts.sh's dir,
# default ~/.claude/kit/infra/scripts), HOME / CLAUDE_PROJECT_DIR (run-log keying).
# `gh` resolves the repo from cwd, like run-log.sh.

set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }

[ $# -eq 4 ] || die "usage: follow-up.sh <runid> <issue> <tier> <graph.json>"
RUNID="$1"; ISSUE="${2#\#}"; TIER="$3"; GRAPH="$4"
case "$RUNID" in .|..|''|*[!A-Za-z0-9._-]*) die "runid may only contain [A-Za-z0-9._-]" ;; esac
case "$ISSUE" in ''|*[!0-9]*) die "issue must be a number, got '$2'" ;; esac
case "$TIER" in trivial|standard|complex) ;; *) die "tier must be trivial|standard|complex, got '$TIER'" ;; esac
[ -f "$GRAPH" ] || die "no such graph file: $GRAPH"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

INFRA="${FOLLOWUP_INFRA:-${HOME:-/nonexistent}/.claude/kit/infra/scripts}"
RUNDIR="${CODEX_RUN_ROOT:-${HOME:-/nonexistent}/.claude/codex-runs}/$RUNID/issue-$ISSUE"
RUNLOG="$(dirname "$0")/run-log.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

keep_open() { awk -F'\t' -v r="$1" '$1=="finding" && $2==r && ($3=="high"||$3=="medium")'; }

# --- scope check, before anything is written -------------------------------------
TITLE="Follow-up: #$ISSUE — open review findings"
export FOLLOWUP_GRAPH="$GRAPH" FOLLOWUP_PARENT="$ISSUE" FOLLOWUP_TITLE="$TITLE" FOLLOWUP_TIER="$TIER"
PARENT_TITLE="$(python3 <<"PY"
import json, os, sys
g = json.load(open(os.environ["FOLLOWUP_GRAPH"]))
n = int(os.environ["FOLLOWUP_PARENT"])
issues = g.get("issues") or []
parent = [i for i in issues if i.get("n") == n]
if not parent:
    print("error: #%d is not in the frozen scope — refusing" % n, file=sys.stderr); sys.exit(1)
dup = [i["n"] for i in issues if (i.get("title") or "").startswith("Follow-up: #%d " % n)]
if dup:
    print("error: a follow-up for #%d is already filed (#%d)" % (n, dup[0]), file=sys.stderr); sys.exit(1)
print(parent[0].get("title") or "")
PY
)" || exit 1

# --- the open findings -----------------------------------------------------------
if [ -f "$RUNDIR/rounds" ]; then
    R="$(grep '^[0-9]' "$RUNDIR/rounds" | tail -1 | cut -d' ' -f1)"
    [ -n "$R" ] || die "no review round in $RUNDIR/rounds"
    keep_open "$R" <"$RUNDIR/rounds" >"$TMP/findings"
else
    gh issue view "$ISSUE" --json comments >"$TMP/comments.json" || die "gh issue view #$ISSUE failed"
    R="$(FOLLOWUP_COMMENTS="$TMP/comments.json" FOLLOWUP_OUT="$TMP/review.txt" python3 <<"PY"
import json, os, re
comments = json.load(open(os.environ["FOLLOWUP_COMMENTS"])).get("comments") or []
last = None
for c in comments:
    m = re.match(r"\*\*Review round (\d+)\*\*", c.get("body") or "")
    if m:
        last = (m.group(1), c["body"])
if last:
    open(os.environ["FOLLOWUP_OUT"], "w").write(last[1].split("\n", 1)[1] if "\n" in last[1] else "")
    print(last[0])
PY
)"
    [ -n "$R" ] || die "no ledger at $RUNDIR/rounds and no **Review round** comment on #$ISSUE"
    bash "$INFRA/review-counts.sh" "$TMP/review.txt" --findings "$R" >"$TMP/all" || die "cannot parse the last review comment on #$ISSUE"
    keep_open "$R" <"$TMP/all" >"$TMP/findings"
fi

if [ ! -s "$TMP/findings" ]; then
    echo "follow-up: #$ISSUE has no open high or medium findings — nothing filed" >&2
    exit 0
fi

# --- file it ------------------------------------------------------------------------
{
    echo "## What to build"
    echo "Open review findings left when #$ISSUE ($PARENT_TITLE) merged at its review cap. Fix exactly these, nothing else:"
    echo
    awk -F'\t' '{ printf "- [%s] %s", $3, $4; if ($5 != "") printf " — %s", $5; print "" }' "$TMP/findings"
    echo
    echo "Follow-up of #$ISSUE (merged; not a blocker)."
    echo
    echo "## Blocked by"
    echo "None"
} >"$TMP/body.md"

URL="$(gh issue create --title "$TITLE" --body-file "$TMP/body.md" --label "tier:$TIER" --label ready-for-agent | tail -1)" \
    || die "gh issue create failed"
CHILD="${URL##*/}"
case "$CHILD" in ''|*[!0-9]*) die "gh issue create returned no issue number (got '$URL')" ;; esac
# Printed before the graph is touched: a failed amend leaves an orphan issue, recoverable by hand.
echo "follow-up: filed #$CHILD for #$ISSUE" >&2

# --- amend the frozen graph (tmp + rename: never a torn graph) ----------------------
PAYLOAD="$(FOLLOWUP_CHILD="$CHILD" FOLLOWUP_BODY="$TMP/body.md" python3 <<"PY"
import json, os
path = os.environ["FOLLOWUP_GRAPH"]
g = json.load(open(path))
n, child, tier = int(os.environ["FOLLOWUP_PARENT"]), int(os.environ["FOLLOWUP_CHILD"]), os.environ["FOLLOWUP_TIER"]
reblocked = []
for i in g["issues"]:
    if n in (i.get("blockedBy") or []):
        if child not in i["blockedBy"]:
            i["blockedBy"].append(child)
        reblocked.append(i["n"])
g["issues"].append({"n": child, "title": os.environ["FOLLOWUP_TITLE"], "state": "open",
                    "labels": ["ready-for-agent", "tier:" + tier], "tier": tier,
                    "body": open(os.environ["FOLLOWUP_BODY"]).read(), "comments": "", "blockedBy": []})
g.setdefault("blockerStates", {})[str(child)] = "open"
with open(path + ".tmp", "w") as fh:
    json.dump(g, fh)
os.replace(path + ".tmp", path)
print(json.dumps({"n": n, "child": child, "reblocked": sorted(reblocked)}))
PY
)" || die "filed #$CHILD but could not amend $GRAPH — add it by hand"

bash "$RUNLOG" append "$RUNID" follow-up "$PAYLOAD" || die "filed #$CHILD and amended the graph, but the run-log append failed"

RB="$(printf '%s' "$PAYLOAD" | python3 -c 'import json,sys; print(", ".join("#%d" % n for n in json.load(sys.stdin)["reblocked"]) or "none")')"
echo "follow-up: #$ISSUE → #$CHILD (tier:$TIER) re-blocked $RB"
