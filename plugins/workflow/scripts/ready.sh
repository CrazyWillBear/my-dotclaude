#!/usr/bin/env bash
#
# ready.sh — which scoped issues are READY to build right now.
#
# This is the scheduler's readiness check, lifted out of the old js-block-inside-
# markdown and into a script so it can be tested against real fixtures instead of
# grepped for. The rules are unchanged; they are hard-won (see #77) and the reasons
# ride along below.
#
# Usage:
#   bash ready.sh [graph.json] [--merged N]... [--held N]... [--in-flight N]... [--skip-unknown]
#
#   graph.json   scope-graph.sh's output; omitted or `-` reads stdin.
#   --merged     issue merged BY THIS RUN. Two jobs: never re-admit it (the run stays
#                convergent whether or not the `gh issue close` ever lands — the 1.84M
#                spin of #77 lacked exactly that), and satisfy its dependents' blockers.
#   --held       dependent of a capped merge — held for the rest of the run.
#   --in-flight  already has a session/subagent on it.
#   --skip-unknown  an unfetchable issue is logged and skipped instead of erroring.
#
# Output: ready issue numbers, ascending, one per line, on stdout.
#
# When NOTHING is ready, stdout is empty and ONE line goes to stderr:
#   `nothing-to-do: <why>`  + exit 0 — a DESIGNED empty (scope complete, everything
#                             held/in flight, or e2e-gate issues held by open mock-debt).
#   `error: <why>`          + exit 1 — an UNEXPLAINED empty. That is the #53/#70/#73
#                             silent-empty class: all-hitl, blocked on an unclosed
#                             out-of-scope issue, a `## Blocked by` ref aimed at a PR
#                             (never "closed", by design). Loud beats a clean empty
#                             success that reads as "all done".
#
# A ready issue is: open · not merged this run · not held · not in flight · not
# labelled hitl or prd · every `## Blocked by` ref closed or merged this run · and,
# if labelled e2e-gate, no open mock-debt (C7 — the single enforcement point of the
# anti-mock-drift design).

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 1; }

GRAPH=""
MERGED=""; HELD=""; INFLIGHT=""; SKIP_UNKNOWN=""

num() {   # accept `12`, `#12`, `12,13`
    printf '%s' "${1//,/ }" | tr -d '#'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --merged)      MERGED="$MERGED $(num "${2:-}")"; shift 2 ;;
        --held)        HELD="$HELD $(num "${2:-}")"; shift 2 ;;
        --in-flight)   INFLIGHT="$INFLIGHT $(num "${2:-}")"; shift 2 ;;
        --skip-unknown) SKIP_UNKNOWN=1; shift ;;
        -h|--help)     sed -n '3,40p' "$0"; exit 0 ;;
        -)             GRAPH=""; shift ;;
        -*)            echo "error: unknown flag $1" >&2; exit 1 ;;
        *)             GRAPH="$1"; shift ;;
    esac
done

# The graph reaches python as a PATH, never on stdin: the program itself arrives on
# python's stdin (heredoc), and never as an env var either — a graph carrying issue
# bodies and comments blows past the 128K single-env-string limit.
if [ -n "$GRAPH" ]; then
    [ -f "$GRAPH" ] || { echo "error: no such graph file: $GRAPH" >&2; exit 1; }
else
    GRAPH="$(mktemp)"
    trap 'rm -f "$GRAPH"' EXIT
    cat >"$GRAPH"
fi

export READY_GRAPH="$GRAPH" READY_MERGED="$MERGED" READY_HELD="$HELD" READY_INFLIGHT="$INFLIGHT" \
       READY_SKIP_UNKNOWN="$SKIP_UNKNOWN"

python3 <<"PY"
import json, os, sys

def nums(env):
    out = set()
    for token in os.environ.get(env, "").split():
        try:
            out.add(int(token))
        except ValueError:
            pass
    return out

merged   = nums("READY_MERGED")
held     = nums("READY_HELD")
inflight = nums("READY_INFLIGHT")
skip_unknown = bool(os.environ.get("READY_SKIP_UNKNOWN"))

try:
    with open(os.environ["READY_GRAPH"]) as fh:
        graph = json.load(fh)
except Exception:
    print("error: graph is not JSON (scope-graph.sh prints nothing when it fails)", file=sys.stderr)
    sys.exit(1)

issues = graph.get("issues") if isinstance(graph, dict) else None
if not isinstance(issues, list) or not issues:
    # The graph IS the Step-0a allowlist (#77 defect A). An absent/empty graph must
    # fail, never degrade into a repo-wide sweep — a run that picks its own work can
    # build issues nobody asked for.
    print("error: empty graph — refusing to pick work repo-wide", file=sys.stderr)
    sys.exit(1)

blocker_states = graph.get("blockerStates") or {}
mock_debt = set(graph.get("mockDebtOpen") or [])

# Launch-frozen closed set: states, not queries. A blocker whose state could not be
# read (e.g. a ref aimed at a PR, which `gh issue view` cannot resolve) is never
# "closed", so its dependent is never ready. Fail-closed, deliberately.
closed = {int(n) for n, s in blocker_states.items() if s == "closed"}
closed |= {i["n"] for i in issues if i.get("state") == "closed"}

unfetched = [i["n"] for i in issues if i.get("state") == "unknown"]
if unfetched and not skip_unknown:
    refs = ", ".join("#%d" % n for n in unfetched)
    print("error: graph fetch failed for %s — refusing to run on a partial scope "
          "(pass --skip-unknown to skip them)" % refs, file=sys.stderr)
    sys.exit(1)
if unfetched:
    print("skip-unknown: dropping unfetchable %s from the scope"
          % ", ".join("#%d" % n for n in unfetched), file=sys.stderr)

def labels(i):
    return i.get("labels") or []

def ready(i):
    return (i.get("state") == "open"
            and i["n"] not in merged
            and i["n"] not in held
            and i["n"] not in inflight
            and "hitl" not in labels(i)
            and "prd" not in labels(i)
            and all(b in closed or b in merged for b in (i.get("blockedBy") or []))
            and ("e2e-gate" not in labels(i) or not mock_debt))

ready_set = sorted(i["n"] for i in issues if ready(i))
if ready_set:
    print("\n".join(str(n) for n in ready_set))
    sys.exit(0)

# ---- nothing is ready: classify the emptiness before calling it an error --------
open_scoped = [i for i in issues if i.get("state") == "open"]
remaining   = [i for i in open_scoped if i["n"] not in merged]

# Ready but for the mock-debt gate — the gate doing exactly what it exists to do.
gate_held = [i for i in remaining
             if "e2e-gate" in labels(i) and mock_debt
             and "hitl" not in labels(i) and "prd" not in labels(i)
             and i["n"] not in held and i["n"] not in inflight
             and all(b in closed or b in merged for b in (i.get("blockedBy") or []))]

busy = [i["n"] for i in remaining if i["n"] in inflight or i["n"] in held]

# Test closedness DIRECTLY. "no open issues left" is not "everything is closed": an
# issue whose state could not be read is "unknown" — neither open nor closed — and
# --skip-unknown lets exactly that scope reach here. `.every(closed)` sends any
# unknown remnant to the error branch, where it belongs.
if all(i.get("state") == "closed" or i["n"] in merged for i in issues):
    why = "every scoped issue is closed or merged this run — the scope is complete"
elif remaining and len(gate_held) == len(remaining):
    why = ("every remaining scoped issue (%s) is e2e-gate-held by open mock-debt (%s)"
           % (", ".join("#%d" % i["n"] for i in gate_held),
              ", ".join("#%d" % n for n in sorted(mock_debt))))
elif remaining and len(busy) + len(gate_held) == len(remaining):
    why = "nothing new to admit — %s in flight or held" % ", ".join("#%d" % n for n in sorted(busy))
else:
    why = None

if why:
    print("nothing-to-do: %s" % why, file=sys.stderr)
    sys.exit(0)

# Name the parts that ARE explained: a gate hold is a designed state, and a bare
# "nothing is ready" would misattribute it as a broken scope.
msg = "error: no scoped issue is READY (open, unblocked, not hitl/prd) — refusing a silent empty success"
if gate_held:
    msg += " · e2e-gate-held by open mock-debt (BY DESIGN): " + ", ".join("#%d" % i["n"] for i in gate_held)
if unfetched:
    msg += " · unfetchable, skipped: " + ", ".join("#%d" % n for n in unfetched)
print(msg, file=sys.stderr)
sys.exit(1)
PY
