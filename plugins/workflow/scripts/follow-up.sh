#!/usr/bin/env bash
#
# follow-up.sh — a capped merge's open findings become ONE scheduled follow-up issue.
#
# Usage:
#   bash follow-up.sh <runid> <issue> <tier> <graph.json> [--attempt N]
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
# Open findings: the source is decided by the backend resolve-tier.sh gives the issue's
# LAST attempt (--attempt, default 0) — never by round numbers on a thread anyone can write.
#   codex   the run-dir ledger ($CODEX_RUN_ROOT/<runid>/issue-<N>/rounds, #110) only: its last
#           round's finding lines — a scoped codex re-review restates every finding still open.
#   claude  the thread's `**Review round N**` comments posted in THIS attempt (past the run
#           dir's handoff.json mark, else the newest **Plan** — consult.sh's floor), every round's findings with earlier
#           rounds marked to verify, since a claude fix round reviews only its delta; plus,
#           after an escalation, the ledger's last round as the codex attempts' open set.
#           A comment with `- **high** \`path\` — text` lines is read here; one without them
#           but with `[Pn]` goes through infra's review-counts.sh --findings, and its refusal
#           is fatal.
# A round whose heading counts high/medium but lists none is refused, never read as clean.
# Only lows open → nothing filed, nothing touched, exit 0.
#
# Output: `follow-up: #<N> → #<child> (tier:<tier>) re-blocked #85, #95` on stdout.
#
# Seams (env): CODEX_RUN_ROOT (as spawn.sh), FOLLOWUP_INFRA (review-counts.sh's and
# resolve-tier.sh's dir, default ~/.claude/kit/infra/scripts), RESOLVE_TIER_ROOT, HOME / CLAUDE_PROJECT_DIR (run-log keying).
# `gh` resolves the repo from cwd, like run-log.sh.

set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }

USAGE="usage: follow-up.sh <runid> <issue> <tier> <graph.json> [--attempt N]"
[ $# -eq 4 ] || { [ $# -eq 6 ] && [ "$5" = --attempt ]; } || die "$USAGE"
RUNID="$1"; ISSUE="${2#\#}"; TIER="$3"; GRAPH="$4"; ATTEMPT="${6:-0}"
case "$ATTEMPT" in ''|*[!0-9]*) die "attempt must be a number, got '$ATTEMPT'" ;; esac
case "$RUNID" in .|..|''|*[!A-Za-z0-9._-]*) die "runid may only contain [A-Za-z0-9._-]" ;; esac
case "$ISSUE" in ''|*[!0-9]*) die "issue must be a number, got '$2'" ;; esac
case "$TIER" in trivial|standard|complex) ;; *) die "tier must be trivial|standard|complex, got '$TIER'" ;; esac
[ -f "$GRAPH" ] || die "no such graph file: $GRAPH"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

INFRA="${FOLLOWUP_INFRA:-${HOME:-/nonexistent}/.claude/kit/infra/scripts}"
export FOLLOWUP_INFRA_DIR="$INFRA"
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
BACKEND="$(bash "$INFRA/resolve-tier.sh" "$TIER" "$ATTEMPT" 2>/dev/null | sed -n 's/^implementer_backend=//p')"
LEDGER_LAST=""
if [ -f "$RUNDIR/rounds" ]; then
    LEDGER_LAST="$(grep '^[0-9]' "$RUNDIR/rounds" | tail -1)"
    [ -n "$LEDGER_LAST" ] || die "no review round in $RUNDIR/rounds"
fi
case "$BACKEND" in
codex)
    [ -n "$LEDGER_LAST" ] || die "no ledger at $RUNDIR/rounds for codex attempt $ATTEMPT of #$ISSUE"
    read -r R H _ M _ <<<"$LEDGER_LAST"
    keep_open "$R" <"$RUNDIR/rounds" >"$TMP/findings"
    ;;
claude)
    gh issue view "$ISSUE" --json comments >"$TMP/comments.json" || die "gh issue view #$ISSUE failed"
    THREAD_LAST="$(FOLLOWUP_COMMENTS="$TMP/comments.json" FOLLOWUP_OUT="$TMP/thread" \
        FOLLOWUP_RUNDIR="$RUNDIR" FOLLOWUP_ATTEMPT="$ATTEMPT" python3 <<"PY2"
import json, os, re, subprocess, sys, tempfile
comments = json.load(open(os.environ["FOLLOWUP_COMMENTS"])).get("comments") or []
# THIS attempt's comments only, consult.sh's floor: past the mark the last handoff recorded
# when it ended an earlier attempt; else past the newest **Plan** (this run's start)
mark = None
try:
    m = json.load(open(os.path.join(os.environ["FOLLOWUP_RUNDIR"], "handoff.json")))
    if 0 <= int(m.get("attempt", -1)) < int(os.environ["FOLLOWUP_ATTEMPT"]):
        mark = max(0, min(len(comments), int(m.get("mark", 0))))
except (OSError, ValueError, TypeError):
    pass
if mark is None:
    mark = max([i for i, c in enumerate(comments) if (c.get("body") or "").lstrip().startswith("**Plan**")] or [0])
rows, last = [], ""
for c in comments[mark:]:
    body = c.get("body") or ""
    m = re.match(r"\*\*Review round (\d+)\*\*[^\n]*?(\d+) high, (\d+) medium", body)
    if not m:
        continue
    r, text = m.group(1), body.split("\n", 1)[1] if "\n" in body else ""
    last = "%s %s %s" % m.groups()
    # a claude worker's own comment: - **high** `path:line` — what is wrong
    bold = re.findall(r"(?m)^[ \t]*[-*][ \t]*\*\*(high|medium|low)\*\*[ \t]*(.*)$", text)
    for sev, rest in bold:
        loc = re.match(r"`([^`]*)`[ \t]*(?:—[ \t]*)?(.*)$", rest)
        path, title = (loc.group(1), loc.group(2)) if loc else ("", rest)
        rows.append("finding\t%s\t%s\t%s\t%s" % (r, sev, " ".join(title.split()), " ".join(path.split())))
    if not bold and re.search(r"\[P[0-9]\]", text):
        # the reviewer's own [Pn] shape (codex wrapper) — infra's parser, never a second
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
            fh.write(text)
        p = subprocess.run(["bash", os.path.join(os.environ["FOLLOWUP_INFRA_DIR"], "review-counts.sh"),
                            fh.name, "--findings", r], capture_output=True, text=True)
        os.unlink(fh.name)
        if p.returncode != 0:
            print("error: review round %s on the thread is unreadable: %s" % (r, p.stderr.strip()), file=sys.stderr)
            sys.exit(1)
        rows += p.stdout.splitlines()
open(os.environ["FOLLOWUP_OUT"], "w").write("".join(l + "\n" for l in rows))
print(last)
PY2
)" || die "cannot read the review comments on #$ISSUE"
    # after an escalation the ledger holds the codex attempts' open set: carry it, marked to verify
    [ -z "$LEDGER_LAST" ] || keep_open "${LEDGER_LAST%% *}" <"$RUNDIR/rounds" >>"$TMP/thread"
    if [ -n "$THREAD_LAST" ]; then
        read -r R H M <<<"$THREAD_LAST"
    elif [ -n "$LEDGER_LAST" ]; then
        read -r R H _ M _ <<<"$LEDGER_LAST"
    else
        die "no ledger at $RUNDIR/rounds and no **Review round** comment on #$ISSUE"
    fi
    # a claude fix round reviews only its delta, so an earlier round's finding may still be
    # open unrestated: carry every round's, the earlier ones marked to verify first
    awk -F'\t' '$1=="finding" && ($3=="high"||$3=="medium")' "$TMP/thread" >"$TMP/findings"
    ;;
*) die "resolve-tier.sh gave no implementer backend for tier $TIER attempt $ATTEMPT" ;;
esac
# a count with no list is drift, never a clean round
if [ $((H + M)) -gt 0 ] && ! awk -F'\t' -v r="$R" '$2==r{f=1} END{exit !f}' "$TMP/findings"; then
    die "review round $R reports $H high, $M medium but lists none — refusing to read it as clean"
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
    awk -F'\t' -v r="$R" '{ printf "- [%s] %s", $3, $4; if ($5 != "") printf " — %s", $5
        if ($2 != r) printf " (round %s — may already be fixed; verify first)", $2; print "" }' "$TMP/findings"
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
