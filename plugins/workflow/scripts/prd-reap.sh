#!/usr/bin/env bash
#
# prd-reap.sh — detect fully-closed PRDs from a set of closed slice issues.
#
# Given the issue numbers that /orchestrate closed during a run, determines
# which parent PRDs are now fully done (ready-to-close) and which are still
# blocked (by hitl children).
#
# Usage:
#   bash prd-reap.sh <N> [<N> ...]    # issue numbers as arguments
#   echo "N1\nN2" | bash prd-reap.sh  # or via stdin (one per line)
#
# Output (machine-readable, one line per finding):
#   ready <prd_number>
#   blocked <prd_number> hitl <hitl_issue_number> [<hitl_issue_number> ...]
#
# A PRD with any open non-hitl child produces no output line (not yet done,
# not a clean hitl-blocked situation).
#
# Backend: GitHub Issues via `gh` only — no `gh api`, no PR operations.
# Fail open: missing dependencies or gh errors exit 0 silently.

command -v python3 >/dev/null 2>&1 || exit 0
command -v gh     >/dev/null 2>&1 || exit 0

# Collect issue numbers: from arguments, then from stdin if no arguments given.
NUMBERS=""
if [ $# -gt 0 ]; then
    for n in "$@"; do
        NUMBERS="$NUMBERS $n"
    done
else
    while IFS= read -r line; do
        line="${line//[[:space:]]/}"
        [ -n "$line" ] && NUMBERS="$NUMBERS $line"
    done
fi

[ -z "$NUMBERS" ] && exit 0

export INPUT_NUMBERS="$NUMBERS"

# The PRD -> children resolution (and its `Part of #N` trailer matching) lives in
# prd-children.sh, which /orchestrate also uses to scope its ready set. Share it
# rather than keeping a second copy of the matcher here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CHILDREN_HELPER="$SCRIPT_DIR/prd-children.sh"

python3 <<"PY" || exit 0
import os, json, subprocess, sys, re

numbers_str = os.environ.get("INPUT_NUMBERS", "")
numbers = [n.strip() for n in numbers_str.split() if n.strip()]
if not numbers:
    sys.exit(0)


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


def get_body(issue_number):
    """Return the body text of an issue.

    Returns:
        str  — the body (may be '' if the issue genuinely has no body).
        None — the fetch failed (network error, timeout, rate-limit, etc.).

    Callers that need to distinguish "empty body" from "could not fetch" should
    check for None explicitly; callers that only care about the text can treat
    None as '' (fail-open).
    """
    out = gh("issue", "view", str(issue_number), "--json", "body")
    if out is None:
        # gh returned non-zero — fetch failed; signal that distinctly from an empty body.
        return None
    try:
        return json.loads(out).get("body") or ""
    except Exception:
        return None


def get_children(prd_number):
    """Return list of {number, state, labels} dicts for PRD <prd_number>'s child slices.

    Delegates to prd-children.sh — the shared resolver that /orchestrate also uses
    to scope its ready set.  It owns the `Part of #N` trailer matching (own-line
    anchored, so it drops both the prefix collisions GitHub's tokenized --search
    returns and bodies that merely quote the convention in prose) and its
    fail-open behaviour on an unverifiable candidate.

    Its output is one line per child: "<number> <state> <labels-csv>", labels-csv
    being "-" when unlabeled.  Re-inflate that into the dict shape this script's
    callers expect.
    """
    helper = os.environ.get("CHILDREN_HELPER", "")
    if not helper:
        return []
    try:
        result = subprocess.run(
            ["bash", helper, str(prd_number)],
            capture_output=True, text=True, timeout=120,
        )
    except Exception:
        return []
    if result.returncode != 0:
        return []

    children = []
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        number, state, labels_csv = parts
        try:
            number = int(number)
        except ValueError:
            continue
        names = [] if labels_csv == "-" else labels_csv.split(",")
        children.append({
            "number": number,
            "state": state,
            "labels": [{"name": n} for n in names],
        })
    return children


def parse_prd_refs(body):
    """Extract PRD numbers from real 'Part of #N' trailer lines in a body string.

    Matches only references on their own line (anchored with re.MULTILINE), not the
    substring quoted inside prose — a slice body that *quotes* `Part of #1` while
    explaining the convention must not be read as a reference to PRD 1.
    """
    return [int(m) for m in re.findall(r"(?m)^[Pp]art\s+of\s+#(\d+)\s*$", body)]


def has_label(issue, name):
    """Check whether an issue dict carries a specific label name."""
    for lbl in (issue.get("labels") or []):
        if isinstance(lbl, dict) and lbl.get("name") == name:
            return True
    return False


# Step 1: collect candidate PRD numbers from the closed slices, deduped.
# If get_body returns None (fetch error), treat as empty — no refs to parse.
candidate_prds = set()
for n in numbers:
    body = get_body(n) or ""
    for prd in parse_prd_refs(body):
        candidate_prds.add(prd)

# Step 2: evaluate each candidate PRD.
for prd in sorted(candidate_prds):
    children = get_children(prd)
    if not children:
        # No children found — skip; can't determine status.
        continue

    open_hitl     = []   # open children that ARE hitl-labeled
    open_non_hitl = []   # open children that are NOT hitl-labeled

    for child in children:
        state = (child.get("state") or "").lower()
        if state != "closed":
            if has_label(child, "hitl"):
                open_hitl.append(child["number"])
            else:
                open_non_hitl.append(child["number"])

    if open_non_hitl:
        # Not done yet (real work remaining) — emit nothing.
        continue

    if open_hitl:
        # The only blockers are hitl issues — report as blocked.
        hitl_list = " ".join(str(h) for h in sorted(open_hitl))
        print("blocked %d hitl %s" % (prd, hitl_list))
    else:
        # Every child is closed — the PRD is ready to close.
        print("ready %d" % prd)

sys.exit(0)
PY
