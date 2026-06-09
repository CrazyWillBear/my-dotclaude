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
    """Return the body text of an issue, or '' on error."""
    out = gh("issue", "view", str(issue_number), "--json", "body")
    if not out:
        return ""
    try:
        return json.loads(out).get("body") or ""
    except Exception:
        return ""


def get_children(prd_number):
    """Return list of {number, state, labels} dicts for issues that genuinely reference 'Part of #<prd>'.

    GitHub's --search is tokenized full-text, so searching 'Part of #1' may return
    issues whose bodies contain 'Part of #10' or 'Part of #100'.  We re-verify each
    candidate by fetching its body and requiring an exact-number match (the digit
    sequence after # must equal prd_number, with no further digits following).
    """
    search = "Part of #%s" % prd_number
    out = gh(
        "issue", "list",
        "--search", search,
        "--state", "all",
        "--json", "number,state,labels",
        "--limit", "200",
    )
    if not out:
        return []
    try:
        candidates = json.loads(out)
    except Exception:
        return []

    # Build a regex that matches the exact PRD number — not a prefix of a larger one.
    # e.g. for prd_number=1: matches '#1' but not '#10' or '#100'.
    exact_pattern = re.compile(
        r"[Pp]art\s+of\s+#" + re.escape(str(prd_number)) + r"(?!\d)"
    )

    verified = []
    for child in candidates:
        child_body = get_body(child["number"])
        if exact_pattern.search(child_body):
            verified.append(child)
    return verified


def parse_prd_refs(body):
    """Extract all PRD numbers from 'Part of #N' references in a body string."""
    return [int(m) for m in re.findall(r"[Pp]art\s+of\s+#(\d+)", body)]


def has_label(issue, name):
    """Check whether an issue dict carries a specific label name."""
    for lbl in (issue.get("labels") or []):
        if isinstance(lbl, dict) and lbl.get("name") == name:
            return True
    return False


# Step 1: collect candidate PRD numbers from the closed slices, deduped.
candidate_prds = set()
for n in numbers:
    body = get_body(n)
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
