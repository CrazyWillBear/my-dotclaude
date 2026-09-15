#!/usr/bin/env bash
#
# roster.sh — validate a project's .claude/swarm/roster.json and answer queries on it.
#
# Usage:
#   bash roster.sh validate [project-dir]
#   bash roster.sh get <role> <field> [project-dir]
#   bash roster.sh list [kind] [project-dir]
#
#   project-dir   defaults to $PWD. Roster path: <project-dir>/.claude/swarm/roster.json
#   kind          one of orchestrator|manager|doer|worker — filters `list`. Anything
#                 else in that position is a project-dir instead (see below).
#
# roster.json, per docs/swarm-design.md § Roster: one object, keyed by role name.
#   { "<role>": { "kind": "orchestrator|manager|doer|worker", "backend": "...",
#                 "model": "...", "effort": "...",
#                 "rotate_at": <int>, "autocompact": <int>,     # optional, see below
#                 "manager": "<role>" } }                       # required iff kind == worker
#
# rotate_at/autocompact are optional — the design doc's own shipped example omits
# them — and fall back to the Rotation section's documented defaults (300000 /
# 400000) when a row doesn't set them.
#
# Every command validates the WHOLE roster before answering anything: a get/list
# against a roster with one bad row anywhere fails exactly like `validate` would,
# never silently serving from a partially-broken file. This is deliberately fail-
# CLOSED — unlike resolve-tier.sh's fail-open fallback — because roster.json is
# authored data (by /init-swarm or by hand), not a hot-path lookup a caller can't
# afford to lose; a caller silently proceeding with a broken roster could spawn a
# peer under the wrong permissions or model.
#
# Exit 0 on success. Exit 1 + "error: ..." on stderr on any usage mistake, a
# missing/unreadable/malformed roster, or a validation failure (unknown kind, or a
# worker row with no manager).
#
# `list [kind]`'s one ambiguity — is a lone positional arg a kind or a project-dir?
# — is resolved by the closed kind enum: if it matches one of the four kinds, it's a
# kind; otherwise it's a project-dir. Two positional args always mean kind then
# project-dir.

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 1; }

usage() {
    echo "error: usage: roster.sh validate|get <role> <field>|list [kind] [project-dir]" >&2
    exit 1
}

is_kind() {
    case "$1" in
        orchestrator|manager|doer|worker) return 0 ;;
        *) return 1 ;;
    esac
}

CMD="${1:-}"
[ -n "$CMD" ] || usage
shift

ROLE=""; FIELD=""; KIND=""; PROJECT_DIR="$PWD"

case "$CMD" in
    validate)
        [ $# -le 1 ] || usage
        [ $# -eq 1 ] && PROJECT_DIR="$1"
        ;;
    get)
        ROLE="${1:-}"; FIELD="${2:-}"
        [ -n "$ROLE" ] && [ -n "$FIELD" ] || usage
        [ $# -le 3 ] || usage
        [ $# -eq 3 ] && PROJECT_DIR="$3"
        ;;
    list)
        [ $# -le 2 ] || usage
        if [ $# -eq 2 ]; then
            is_kind "$1" || usage
            KIND="$1"; PROJECT_DIR="$2"
        elif [ $# -eq 1 ]; then
            if is_kind "$1"; then KIND="$1"; else PROJECT_DIR="$1"; fi
        fi
        ;;
    *)
        usage
        ;;
esac

export ROSTER_CMD="$CMD" ROSTER_ROLE="$ROLE" ROSTER_FIELD="$FIELD" ROSTER_KIND="$KIND" \
       ROSTER_PROJECT_DIR="$PROJECT_DIR"

python3 <<"PY"
import json, os, sys

cmd         = os.environ["ROSTER_CMD"]
role        = os.environ["ROSTER_ROLE"]
field       = os.environ["ROSTER_FIELD"]
kind_filter = os.environ["ROSTER_KIND"]
project_dir = os.environ["ROSTER_PROJECT_DIR"]

path = os.path.join(project_dir, ".claude", "swarm", "roster.json")

KINDS = {"orchestrator", "manager", "doer", "worker"}
DEFAULTS = {"rotate_at": 300000, "autocompact": 400000}

def fail(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(1)

try:
    with open(path) as fh:
        roster = json.load(fh)
except FileNotFoundError:
    fail("no roster at %s" % path)
except (json.JSONDecodeError, ValueError):
    fail("%s is not valid JSON" % path)

if not isinstance(roster, dict):
    fail("%s must be a JSON object of role -> row" % path)

errors = []
for name, row in roster.items():
    if not isinstance(row, dict):
        errors.append("role %r: row must be an object" % name)
        continue
    kind = row.get("kind")
    if kind not in KINDS:
        errors.append("role %r: unknown kind %r (want one of %s)"
                       % (name, kind, ", ".join(sorted(KINDS))))
        continue
    if kind == "worker" and not row.get("manager"):
        errors.append("role %r: worker row has no manager" % name)

if errors:
    for e in errors:
        print("error: " + e, file=sys.stderr)
    sys.exit(1)

if cmd == "validate":
    sys.exit(0)

if cmd == "list":
    for name, row in roster.items():
        if kind_filter and row.get("kind") != kind_filter:
            continue
        print(name)
    sys.exit(0)

if cmd == "get":
    row = roster.get(role)
    if row is None:
        fail("no such role: %s" % role)
    if field in row:
        value = row[field]
    elif field in DEFAULTS:
        value = DEFAULTS[field]
    else:
        fail("role %s has no field %s" % (role, field))
    print(value)
    sys.exit(0)
PY
