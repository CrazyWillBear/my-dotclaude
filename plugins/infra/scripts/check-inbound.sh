#!/usr/bin/env bash
#
# check-inbound.sh — will this run's worker reports actually reach the orchestrator?
#
# Usage:
#   bash check-inbound.sh [project-dir]      # defaults to the current directory
#
# The session lane spawns workers with `--permission-mode bypassPermissions`, because
# an unattended session in `manual` or `acceptEdits` deadlocks on its first prompt.
# But a cross-session message is only auto-delivered when the SENDER'S permission-mode
# class matches the RECEIVER'S — that is the documented default, "mode parity". So a
# bypassPermissions worker reporting to a prompting orchestrator gets HELD for the
# user's approval, and every `issue <N> built …` interrupts the loop that exists to
# run unattended. Observed on a real run; this check exists so nobody rediscovers it
# the hard way, twenty slices in.
#
# `crossSessionInbound` decides it:
#   accept   deliver peer messages           -> the lane runs unattended
#   hold     park them for review            -> every report needs a click
#   refuse   opt out entirely                -> reports NEVER arrive; the lane is broken
#   unset    mode parity (see above)         -> every report needs a click
#
# Output: one line on stdout, and the exit code carries the verdict:
#   0  ok       — reports will be delivered
#   1  degraded — reports will be held for approval; the run works but stops constantly
#   2  broken   — reports are refused; the session lane cannot work at all
#
# Exit 1 is a WARN, not a failure: the user may deliberately want to review every
# message, and this check must never be the thing that refuses to start their run.
# The caller decides; this script only reports.
#
# Settings precedence: a repo may only TIGHTEN this, so the effective value is the
# most restrictive of user and project settings, and managed org policy overrides
# both (unreadable from here — hence the caveat in the messages).

set -uo pipefail

PROJECT_DIR="${1:-$PWD}"

command -v python3 >/dev/null 2>&1 || {
    echo "unknown: python3 not found — cannot read settings; if worker reports never arrive, see crossSessionInbound"
    exit 0
}

CHECK_PROJECT_DIR="$PROJECT_DIR" python3 <<"PY"
import json, os, sys

# Most restrictive wins, because a repo may only tighten a user-level value.
RANK = {"accept": 0, "unset": 1, "hold": 1, "refuse": 2}

def read(path):
    try:
        with open(os.path.expanduser(path)) as fh:
            value = json.load(fh).get("crossSessionInbound")
    except Exception:
        return None
    return value if value in RANK else None

project = os.environ["CHECK_PROJECT_DIR"]
sources = [
    ("user",    "~/.claude/settings.json"),
    ("project", os.path.join(project, ".claude/settings.json")),
    ("local",   os.path.join(project, ".claude/settings.local.json")),
]

found = [(name, value) for name, path in sources for value in [read(path)] if value]
if found:
    name, effective = max(found, key=lambda pair: RANK[pair[1]])
    where = " (from %s settings)" % name
else:
    effective, where = "unset", ""

if effective == "accept":
    print("ok: crossSessionInbound=accept%s — worker reports will be delivered" % where)
    sys.exit(0)

if effective == "refuse":
    print('BROKEN: crossSessionInbound=refuse%s — worker reports will NEVER arrive and the '
          'session lane cannot work. Set it to "accept" in ~/.claude/settings.json, or use '
          "the ad-hoc lane." % where)
    sys.exit(2)

why = ("is unset, so mode parity applies" if effective == "unset"
       else "is %s%s" % (effective, where))
print('DEGRADED: crossSessionInbound %s — workers run bypassPermissions, so every report will '
      'be HELD for your approval and the run will stop on each one. Set '
      '"crossSessionInbound": "accept" in ~/.claude/settings.json to run unattended (it '
      'delivers messages from any local session, not just this run\'s workers). Managed org '
      'policy can override it.' % why)
sys.exit(1)
PY
