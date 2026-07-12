#!/usr/bin/env bash
#
# prd-children.sh — resolve the genuine child slices of a PRD.
#
# The single source of truth for "which issues belong to PRD #N".  Two callers
# share it:
#
#   * prd-reap.sh  — to decide whether every child is closed (PRD ready to close).
#   * /orchestrate — to scope a round's ready set to the PRD being built, rather
#                    than sweeping every `ready-for-agent` issue in the repo.
#                    (#77 defect A: the repo-wide sweep built an unrelated issue
#                    into a PRD's branch.)
#
# Usage:
#   bash prd-children.sh <prd_number>
#
# Output (machine-readable, one line per child):
#   <number> <state> <labels-csv>        # labels-csv is "-" when unlabeled
#
# Callers filter from there: /orchestrate wants open + ready-for-agent + not
# hitl/prd; prd-reap wants the open/closed split and the hitl label.
#
# A "genuine" child carries a real `Part of #N` trailer on its own line.  GitHub's
# --search is tokenized full-text, so it also returns prefix collisions (a slice
# of #10 when you searched #1) and bodies that merely *quote* the convention in
# prose.  Both are dropped by re-reading each candidate's body.
#
# Backend: GitHub Issues via `gh` only — no `gh api`, no PR operations.
# Fail open: missing dependencies, a missing argument, or gh errors exit 0
# silently.  For /orchestrate an empty scope means "build nothing" (safe); for
# prd-reap it means "emit no verdict" (safe).  Both beat guessing.

command -v python3 >/dev/null 2>&1 || exit 0
command -v gh      >/dev/null 2>&1 || exit 0

[ $# -ge 1 ] || exit 0

PRD_NUMBER="${1//[[:space:]]/}"
[ -n "$PRD_NUMBER" ] || exit 0

case "$PRD_NUMBER" in
    *[!0-9]*) exit 0 ;;   # not a bare number — fail open rather than shell out with junk
esac

export INPUT_PRD="$PRD_NUMBER"

python3 <<"PY" || exit 0
import json, os, re, subprocess, sys

prd_number = os.environ.get("INPUT_PRD", "").strip()
if not prd_number:
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
    """Return an issue's body text, or None when the fetch itself failed.

    The None-vs-'' distinction matters: an empty body means "no trailer, not a
    child", while a failed fetch means "cannot tell" — and the caller keeps
    those, because silently dropping a genuine child would narrow /orchestrate's
    scope and make prd-reap claim 'ready' too early.
    """
    out = gh("issue", "view", str(issue_number), "--json", "body")
    if out is None:
        return None
    try:
        return json.loads(out).get("body") or ""
    except Exception:
        return None


# A real trailer sits on its own line.  Anchoring to the line also rules out the
# prefix collisions --search hands back (#10 / #100 when you asked for #1).
exact_pattern = re.compile(
    r"(?m)^[Pp]art\s+of\s+#" + re.escape(prd_number) + r"\s*$"
)

out = gh(
    "issue", "list",
    "--search", "Part of #%s" % prd_number,
    "--state", "all",
    "--json", "number,state,labels",
    "--limit", "200",
)
if not out:
    sys.exit(0)

try:
    candidates = json.loads(out)
except Exception:
    sys.exit(0)

for child in candidates:
    number = child.get("number")
    if number is None:
        continue

    body = get_body(number)
    if body is not None and not exact_pattern.search(body):
        # Body fetched, no genuine trailer — a --search false positive.  Drop it.
        continue
    # body is None (unverifiable) -> keep: fail open, see get_body.

    state = (child.get("state") or "").lower() or "unknown"
    names = [
        lbl.get("name")
        for lbl in (child.get("labels") or [])
        if isinstance(lbl, dict) and lbl.get("name")
    ]
    print("%d %s %s" % (number, state, ",".join(names) if names else "-"))

sys.exit(0)
PY
