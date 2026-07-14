#!/usr/bin/env bash
#
# scope-graph.sh — fetch /orchestrate's whole issue graph, once, at launch.
#
# The run's scheduler needs three things it cannot compute for itself: the scoped
# issues (bodies, comments, labels), the state of every `## Blocked by` ref they
# name, and the open `mock-debt` ledger.  A Workflow can't run `gh`, so this used
# to be a cheap "picker" agent that listed the ready set each round — a model doing
# a topological sweep over a DAG, i.e. arithmetic it could hallucinate.
#
# So the MAIN THREAD runs this once, at launch, and hands the JSON to the workflow,
# which computes readiness in plain JS.  The graph is FROZEN at launch, consistent
# with the Step-0a allowlist freeze: nothing the run files can be built by the run.
#
# Usage:
#   bash scope-graph.sh <N1> [N2 ...]        # the Step-0a issue allowlist
#
# Output (ONE JSON document on stdout):
#   {
#     "issues": [
#       { "n": 12, "title": "...", "state": "open", "labels": ["ready-for-agent","tier:standard"],
#         "tier": "standard",               // from the tier:* label; null when unlabelled
#         "body": "...", "comments": "...", // comments concatenated, author-attributed
#         "blockedBy": [10, 11] }           // bare #N refs under `## Blocked by`
#     ],
#     "blockerStates": { "10": "closed", "11": "open" },   // EVERY ref, in scope or not
#     "mockDebtOpen": [31, 34]                             // the e2e-gate's hold set
#   }
#
# Parsing rules:
#   * `## Blocked by` carries BARE `#N` refs, one per line, or the literal
#     `None - can start immediately`.  A `#N` in PROSE is NOT a blocker — matching
#     one would deadlock the scheduler on an issue that was never a dependency.
#   * the tier is a PERSISTED LABEL (`tier:trivial|standard|complex`), null when
#     absent (the caller backfills it via classify-task).  Conflicting double-labels
#     resolve to the HIGHEST tier: a mislabel must never route real work to a model
#     too cheap for it.  The full label list rides along so the caller can warn.
#   * an issue whose fetch fails is KEPT with state "unknown" — never silently
#     dropped, which would narrow the run's scope behind your back.  "unknown" is
#     not "open", so the scheduler won't build it, and the report can still see it.
#
# Backend: GitHub Issues via `gh` only — no `gh api`, no PR operations.
# Fail open: a missing dependency, a missing/junk argument, or a failed `gh issue
# list` exits 0 with NO output.  Empty output makes the workflow's empty-graph
# throw fire (loud) rather than degrading into a repo-wide query (#77 defect A).

command -v python3 >/dev/null 2>&1 || exit 0
command -v gh      >/dev/null 2>&1 || exit 0

[ $# -ge 1 ] || exit 0

SCOPE=""
for arg in "$@"; do
    n="${arg//[[:space:]]/}"
    n="${n#\#}"
    [ -n "$n" ] || continue
    case "$n" in
        *[!0-9]*) continue ;;   # not a bare number — drop it rather than shell out with junk
    esac
    SCOPE="$SCOPE $n"
done

[ -n "$SCOPE" ] || exit 0

export INPUT_SCOPE="$SCOPE"

python3 <<"PY" || exit 0
import json, os, re, subprocess, sys

seen = []
for token in os.environ.get("INPUT_SCOPE", "").split():
    number = int(token)
    if number not in seen:
        seen.append(number)
scope = seen
if not scope:
    sys.exit(0)

TIER_RANK = {"trivial": 1, "standard": 2, "complex": 3}


def gh(*args):
    """Run a gh command and return its stdout, or None on error."""
    try:
        result = subprocess.run(
            ["gh"] + list(args),
            capture_output=True, text=True, timeout=30,
        )
    except Exception:
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def gh_json(*args):
    out = gh(*args)
    if out is None:
        return None
    try:
        return json.loads(out)
    except Exception:
        return None


# `## Blocked by` (any heading level), up to the next heading or the end of body.
BLOCKED_HEADING = re.compile(r"(?mi)^\s{0,3}#{1,6}\s*Blocked\s+by\s*:?\s*$")
NEXT_HEADING = re.compile(r"(?m)^\s{0,3}#{1,6}\s+\S")
# A blocker ref is a WHOLE line: `#12`, or a list item `- #12`.  Anything else in
# the section is prose ("Waits on #98 landing first") and is NOT a dependency.
BARE_REF = re.compile(r"^\s*(?:[-*+]\s*)?#(\d+)\s*$")


def parse_blocked_by(body):
    if not body:
        return []
    heading = BLOCKED_HEADING.search(body)
    if not heading:
        return []
    rest = body[heading.end():]
    nxt = NEXT_HEADING.search(rest)
    section = rest[:nxt.start()] if nxt else rest

    refs = []
    for line in section.splitlines():
        match = BARE_REF.match(line.strip())
        if not match:
            continue           # `None - can start immediately`, blank lines, prose
        ref = int(match.group(1))
        if ref not in refs:
            refs.append(ref)
    return refs


def parse_tier(labels):
    """The persisted tier:* label.  Conflicting labels -> the HIGHEST tier."""
    tiers = [
        label.split(":", 1)[1]
        for label in labels
        if label.startswith("tier:") and label.split(":", 1)[1] in TIER_RANK
    ]
    if not tiers:
        return None
    return max(tiers, key=lambda tier: TIER_RANK[tier])


def render_comments(comments):
    """Concatenate an issue's comments, author-attributed.

    Comments are ground truth — a human's answer, a prior review's ruling — that
    the body may never absorb.  A comment-blind loop rediscovers the settled
    question and guesses at it.
    """
    rendered = []
    for comment in comments or []:
        if not isinstance(comment, dict):
            continue
        author = ((comment.get("author") or {}).get("login")) or "unknown"
        body = (comment.get("body") or "").strip()
        if not body:
            continue
        rendered.append("@%s: %s" % (author, body))
    return "\n\n---\n\n".join(rendered)


def label_names(raw):
    return [
        label.get("name")
        for label in (raw or [])
        if isinstance(label, dict) and label.get("name")
    ]


issues = []
states = {}

for number in scope:
    data = gh_json(
        "issue", "view", str(number),
        "--json", "number,title,state,labels,body,comments",
    )
    if data is None:
        # Unfetchable — keep it, visibly, as "unknown".  Dropping it would narrow
        # the run's scope silently; "unknown" is not "open", so nothing builds it.
        issues.append({
            "n": number, "title": None, "state": "unknown", "labels": [],
            "tier": None, "body": "", "comments": "", "blockedBy": [],
        })
        states[str(number)] = "unknown"
        continue

    labels = label_names(data.get("labels"))
    body = data.get("body") or ""
    state = (data.get("state") or "").lower() or "unknown"

    issues.append({
        "n": number,
        "title": data.get("title") or "",
        "state": state,
        "labels": labels,
        "tier": parse_tier(labels),
        "body": body,
        "comments": render_comments(data.get("comments")),
        "blockedBy": parse_blocked_by(body),
    })
    states[str(number)] = state

# Every blocker ref's state — INCLUDING refs outside the scope allowlist.  A scoped
# issue can be blocked by an issue nobody asked us to build; without its state the
# scheduler cannot tell whether the dependent is ready.
blocker_states = {}
for issue in issues:
    for ref in issue["blockedBy"]:
        key = str(ref)
        if key in blocker_states:
            continue
        if key in states:
            blocker_states[key] = states[key]
            continue
        data = gh_json("issue", "view", key, "--json", "number,state")
        blocker_states[key] = ((data or {}).get("state") or "").lower() or "unknown"

# The open mock-debt set IS the ledger (source of truth for the e2e-gate hold).
debt = gh_json(
    "issue", "list",
    "--label", "mock-debt", "--state", "open",
    "--json", "number", "--limit", "200",
)
mock_debt_open = sorted({
    item.get("number")
    for item in (debt or [])
    if isinstance(item, dict) and isinstance(item.get("number"), int)
})

print(json.dumps({
    "issues": issues,
    "blockerStates": blocker_states,
    "mockDebtOpen": mock_debt_open,
}, indent=2))
sys.exit(0)
PY
