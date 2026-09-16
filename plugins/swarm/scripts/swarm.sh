#!/usr/bin/env bash
#
# swarm.sh — manage swarm roles: peers (standing background sessions) and workers (one-shot tasks).
#
# Usage:
#   bash swarm.sh brief <role> <file> [project-dir]
#
#   project-dir   defaults to $PWD. Paths:
#                 Roster: <project-dir>/.claude/swarm/roster.json
#                 Inbox: <project-dir>/.claude/swarm/inbox/<role>/
#   role          must be present in the roster.json
#   file          source file to copy into the inbox
#
# swarm.sh brief copies a brief file into the inbox and prints a one-line SendMessage
# text carrying the path to the copied brief. Briefs travel as files, messages are
# pointers: the path is stable across rotation, and the successor's first act after
# reading its handoff is to list that inbox.
#
# Exit 0 on success. Exit 1 + "error: ..." on stderr on usage mistakes, missing file,
# unknown role, or unreadable roster.json.

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 1; }

usage() {
    echo "error: usage: swarm.sh brief <role> <file> [project-dir]" >&2
    exit 1
}

CMD="${1:-}"
[ -n "$CMD" ] || usage

case "$CMD" in
    brief)
        ROLE="${2:-}"
        FILE="${3:-}"
        [ -n "$ROLE" ] && [ -n "$FILE" ] || usage
        PROJECT_DIR="${4:-$PWD}"
        ;;
    *)
        usage
        ;;
esac

# Validate that the role exists in roster.json, then execute the brief verb.
export SWARM_CMD="$CMD" SWARM_ROLE="$ROLE" SWARM_FILE="$FILE" SWARM_PROJECT_DIR="$PROJECT_DIR"

python3 <<"PY"
import json, os, sys, shutil, time

cmd = os.environ["SWARM_CMD"]
role = os.environ["SWARM_ROLE"]
file_src = os.environ["SWARM_FILE"]
project_dir = os.environ["SWARM_PROJECT_DIR"]

roster_path = os.path.join(project_dir, ".claude", "swarm", "roster.json")

def fail(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(1)

# Read and validate roster
try:
    with open(roster_path) as fh:
        roster = json.load(fh)
except FileNotFoundError:
    fail("no roster at %s" % roster_path)
except (json.JSONDecodeError, ValueError):
    fail("%s is not valid JSON" % roster_path)

if role not in roster:
    fail("unknown role: %s" % role)

# Validate that the source file exists and is readable
if not os.path.isfile(file_src):
    fail("file not found: %s" % file_src)

try:
    with open(file_src, 'r') as fh:
        file_content = fh.read()
except IOError as e:
    fail("cannot read file: %s" % e)

# Create inbox directory
inbox_dir = os.path.join(project_dir, ".claude", "swarm", "inbox", role)
try:
    os.makedirs(inbox_dir, exist_ok=True)
except OSError as e:
    fail("cannot create inbox directory: %s" % e)

# Generate filename: <timestamp>-<slug>.md
# slug: alphanumeric + hyphens from the basename without extension
basename = os.path.basename(file_src)
name_without_ext = os.path.splitext(basename)[0]
# Keep only alphanumeric and hyphens, lowercase
slug = "".join(c.lower() if c.isalnum() or c == '-' else '-' for c in name_without_ext)
# Clean up multiple consecutive hyphens
slug = "-".join(filter(None, slug.split("-")))

timestamp = str(int(time.time()))
filename = "%s-%s.md" % (timestamp, slug)
dest_path = os.path.join(inbox_dir, filename)

# Write the file
try:
    with open(dest_path, 'w') as fh:
        fh.write(file_content)
except IOError as e:
    fail("cannot write to inbox: %s" % e)

# Compute absolute path
abs_path = os.path.abspath(dest_path)

# Print the one-line SendMessage text carrying the absolute path
print("Brief stored at %s" % abs_path)
PY
