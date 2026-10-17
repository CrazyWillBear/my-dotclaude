#!/usr/bin/env bash
#
# follow-up.sh — a capped merge's open findings become ONE scheduled follow-up issue.
#
# Usage:
#   bash follow-up.sh <runid> <issue> <tier> <graph.json> [--attempt N]
#   bash follow-up.sh --integration <runid> <base-sha> <head-sha> <graph.json>
#
# A merge that lands capped (no-progress or the round backstop left findings open) leaves work behind.
# Instead of holding its dependents by hand, this files one `ready-for-agent` issue
# carrying the still-open high/medium findings verbatim, adds it to the FROZEN graph
# as a scoped node, and adds it as a blocker of every scoped issue whose `blockedBy`
# names the capped one. ready.sh then holds those dependents until the follow-up is
# `--merged` — no ready.sh change, the existing blocker rule does it. This is the ONLY
# place the run adds to its own scope (PRD #109), so it refuses a parent outside the
# frozen graph, and a second call for the same parent.
#
# Open findings: the run-dir ledger ($CODEX_RUN_ROOT/<runid>/issue-<N>/rounds, #110) only —
# its last round's finding lines. Every worker, either backend, is reviewed by the same
# wrapper, and a scoped re-review restates every finding still open, so the last round is
# the open set. Never the thread: anyone can write a comment there. `--attempt` is accepted
# for old callers and ignored.
# A round whose heading counts high/medium but lists none is refused, never read as clean.
# Only lows open → nothing filed, nothing touched, exit 0.
#
# Output: `follow-up: #<N> → #<child> (tier:<tier>) re-blocked #85, #95` on stdout.
# The end-of-run integration mode (#121) reviews the folded SHA range, files one
# high/medium cross-issue follow-up on the highest graph tier, and leaves the graph alone.
# Its raw review is kept at $CODEX_RUN_ROOT/<runid>/integration-review.txt.
#
# Seams (env): CODEX_RUN_ROOT (as spawn.sh), FOLLOWUP_INFRA (review-counts.sh's and
# resolve-tier.sh's dir, default ~/.claude/kit/infra/scripts), RESOLVE_TIER_ROOT, HOME / CLAUDE_PROJECT_DIR (run-log keying).
# `gh` resolves the repo from cwd, like run-log.sh.

set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }

USAGE="usage: follow-up.sh <runid> <issue> <tier> <graph.json> [--attempt N] | --integration <runid> <base-sha> <head-sha> <graph.json>"
MODE=cap
if [ "${1:-}" = --integration ]; then
    MODE=integration
    [ "$#" -eq 5 ] || die "$USAGE"
    RUNID="$2"; BASE="$3"; HEAD="$4"; GRAPH="$5"
    ISSUE=""; TIER=""; ATTEMPT=0
else
    [ $# -eq 4 ] || { [ $# -eq 6 ] && [ "$5" = --attempt ]; } || die "$USAGE"
    RUNID="$1"; ISSUE="${2#\#}"; TIER="$3"; GRAPH="$4"; ATTEMPT="${6:-0}"
    case "$ATTEMPT" in ''|*[!0-9]*) die "attempt must be a number, got '$ATTEMPT'" ;; esac
fi
case "$RUNID" in .|..|''|*[!A-Za-z0-9._-]*) die "runid may only contain [A-Za-z0-9._-]" ;; esac
if [ "$MODE" = cap ]; then
    case "$ISSUE" in ''|*[!0-9]*) die "issue must be a number, got '$2'" ;; esac
    case "$TIER" in trivial|standard|complex) ;; *) die "tier must be trivial|standard|complex, got '$TIER'" ;; esac
else
    need_sha() {
        local label="$1" value="$2"
        case "$value" in *[!0-9a-f]*|"") die "$label must be a resolved SHA, not a ref: '$value'" ;; esac
        [ "${#value}" -ge 7 ] || die "$label sha is too short to be unambiguous: '$value'"
    }
    need_sha base "$BASE"
    need_sha head "$HEAD"
fi
[ -f "$GRAPH" ] || die "no such graph file: $GRAPH"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

INFRA="${FOLLOWUP_INFRA:-${HOME:-/nonexistent}/.claude/kit/infra/scripts}"
export FOLLOWUP_INFRA_DIR="$INFRA"
RUNROOT="${CODEX_RUN_ROOT:-${HOME:-/nonexistent}/.claude/codex-runs}/$RUNID"
RUNDIR="$RUNROOT/issue-$ISSUE"
RUNLOG="$(dirname "$0")/run-log.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

keep_open() { awk -F'\t' -v r="$1" '$1=="finding" && $2==r && ($3=="high"||$3=="medium")'; }

file_issue() {
    local title="$1" intro="$2" tier="$3" round="$4"
    {
        echo "## What to build"
        echo "$intro"
        echo
        if [ "$MODE" = integration ]; then
            cat "$TMP/body-findings"
        else
            awk -F'\t' -v r="$round" '{ printf "- [%s] %s", $3, $4; if ($5 != "") printf " — %s", $5
                if ($2 != r) printf " (round %s — may already be fixed; verify first)", $2; print "" }' "$TMP/findings"
        fi
        echo
        if [ "$MODE" = integration ]; then
            echo "End-of-run integration review (no dependents)."
        else
            echo "Follow-up of #$ISSUE (merged; not a blocker)."
        fi
        echo
        echo "## Blocked by"
        echo "None"
    } >"$TMP/body.md"

    URL="$(gh issue create --title "$title" --body-file "$TMP/body.md" \
        --label "tier:$tier" --label ready-for-agent | tail -1)" \
        || die "gh issue create failed"
    CHILD="${URL##*/}"
    case "$CHILD" in ''|*[!0-9]*) die "gh issue create returned no issue number (got '$URL')" ;; esac
}

integration_review() {
    local a counts h m l payload
    # kept in the run dir, not $TMP: a failed whole-run review must stay diagnosable
    local review="$RUNROOT/integration-review.txt"
    local -a argv=()

    export FOLLOWUP_GRAPH="$GRAPH"
    TIER="$(FOLLOWUP_GRAPH="$GRAPH" python3 <<'PY'
import json, os, sys

rank = {"trivial": 1, "standard": 2, "complex": 3}
try:
    graph = json.load(open(os.environ["FOLLOWUP_GRAPH"]))
except Exception as exc:
    print("error: cannot read graph JSON: %s" % exc, file=sys.stderr)
    sys.exit(1)
tiers = []
for issue in graph.get("issues") or []:
    tier = issue.get("tier")
    if tier is not None:
        if tier not in rank:
            print("error: unknown issue tier %r" % tier, file=sys.stderr)
            sys.exit(1)
        tiers.append(tier)
if not tiers:
    print("error: graph has no tiered issues", file=sys.stderr)
    sys.exit(1)
print(max(tiers, key=rank.get))
PY
)" || die "cannot choose a reviewer tier from $GRAPH"

    while IFS= read -r -d '' a; do argv+=("$a"); done \
        < <(bash "$INFRA/review-cmd.sh" integration "$BASE" "$HEAD" "$TIER" \
            2>"$TMP/review-cmd-stderr")
    [ "${#argv[@]}" -gt 0 ] || die "could not build integration review command: $(cat "$TMP/review-cmd-stderr")"

    mkdir -p "$TMP/scratch" "$RUNROOT" \
        || die "could not create an integration review scratch directory"
    git clone --quiet --shared -- "$PWD" "$TMP/checkout" \
        || die "could not clone the run branch for integration review"
    git -C "$TMP/checkout" checkout --quiet --detach "$HEAD" \
        || die "could not detach the integration review checkout at $HEAD"
    (cd "$TMP/checkout" && TMPDIR="$TMP/scratch" "${argv[@]}") \
        >"$review" </dev/null \
        || die "integration reviewer failed (output kept in $review)"

    counts="$(bash "$INFRA/review-counts.sh" "$review")" \
        || die "integration review verdict could not be parsed (review kept in $review)"
    read -r h _ m _ l _ <<<"$counts"
    bash "$INFRA/review-counts.sh" "$review" --findings 1 \
        | keep_open 1 >"$TMP/findings" \
        || die "integration review findings could not be parsed"

    CHILD=""
    if [ -s "$TMP/findings" ]; then
        # review-counts.sh has validated and classified the review; retain its original
        # P0/P1/P2 lines in the issue body while excluding low-severity findings.
        awk '/^[ \t]*[-*][ \t]*\[P[012]\][ \t]*/ { print }' "$review" >"$TMP/body-findings"
        file_issue "Follow-up: run $RUNID — integration review findings" \
            "Cross-issue findings from the end-of-run integration review of $BASE..$HEAD. Fix exactly these, nothing else:" \
            "$TIER" 1
    fi

    payload="$(FOLLOWUP_BASE="$BASE" FOLLOWUP_HEAD="$HEAD" FOLLOWUP_TIER="$TIER" \
        FOLLOWUP_HIGH="$h" FOLLOWUP_MEDIUM="$m" FOLLOWUP_LOW="$l" \
        FOLLOWUP_CHILD="$CHILD" python3 <<'PY'
import json, os

child = os.environ["FOLLOWUP_CHILD"]
print(json.dumps({"base": os.environ["FOLLOWUP_BASE"],
                  "head": os.environ["FOLLOWUP_HEAD"],
                  "tier": os.environ["FOLLOWUP_TIER"],
                  "high": int(os.environ["FOLLOWUP_HIGH"]),
                  "medium": int(os.environ["FOLLOWUP_MEDIUM"]),
                  "low": int(os.environ["FOLLOWUP_LOW"]),
                  "child": int(child) if child else None}))
PY
    )" || die "could not build integration-review log payload"
    bash "$RUNLOG" append "$RUNID" integration-review "$payload" \
        || die "integration review finished, but the run-log append failed"

    if [ -n "$CHILD" ]; then
        echo "integration-review: $h high, $m medium, $l low → #$CHILD"
    else
        echo "integration-review: $h high, $m medium, $l low → nothing filed"
    fi
}

if [ "$MODE" = integration ]; then
    integration_review
    exit $?
fi

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
LEDGER_LAST="$(grep '^[0-9]' "$RUNDIR/rounds" 2>/dev/null | tail -1)"
[ -n "$LEDGER_LAST" ] || die "no review round in the ledger at $RUNDIR/rounds for #$ISSUE"
read -r R H _ M _ <<<"$LEDGER_LAST"
keep_open "$R" <"$RUNDIR/rounds" >"$TMP/findings"
# a count with no list is drift, never a clean round
if [ $((H + M)) -gt 0 ] && ! awk -F'\t' -v r="$R" '$2==r{f=1} END{exit !f}' "$TMP/findings"; then
    die "review round $R reports $H high, $M medium but lists none — refusing to read it as clean"
fi

if [ ! -s "$TMP/findings" ]; then
    echo "follow-up: #$ISSUE has no open high or medium findings — nothing filed" >&2
    exit 0
fi

# --- file it ------------------------------------------------------------------------
file_issue "$TITLE" \
    "Open review findings left when #$ISSUE ($PARENT_TITLE) merged at its review cap. Fix exactly these, nothing else:" \
    "$TIER" "$R"
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
