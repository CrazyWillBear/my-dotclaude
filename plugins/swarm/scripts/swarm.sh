#!/usr/bin/env bash
#
# swarm.sh — manage swarm roles: peers (standing background sessions) and workers (one-shot tasks).
#
# Usage:
#   bash swarm.sh up [project-dir]
#   bash swarm.sh down [project-dir]
#   bash swarm.sh attach <role> [project-dir]
#   bash swarm.sh brief <role> <file> [project-dir]
#
#   project-dir   defaults to $PWD. Paths, all under <project-dir>/.claude/swarm/:
#                 roster.json, charter.md, inbox/<role>/brief.md, orchestrator.session
#   role          must be present in roster.json
#   file          source file to copy into the inbox
#
# up|down|attach are docs/swarm-design.md § Lifecycle. A PEER is a roster row of kind
# `manager` or `doer`: a standing `claude --bg` session named by its role. The
# `orchestrator` row is NOT a peer — it is Will's own interactive session, the one that
# merges and relays — and `worker` rows are never sessions at all.
#
#   up      starts every peer that is not already up, then hands the terminal to the
#           orchestrator: resumed by the id in orchestrator.session, or started fresh
#           from its brief. Idempotent — re-running it skips the peers already running.
#   down    stops every one of this project's live peers, BY ID. Never the orchestrator.
#   attach  resolves a role name to its session id and opens it.
#
# "Already up" means state busy, idle or blocked. A `stopped` or `done` session is still
# in `claude agents --json` under its name, so reading it as live is how a `down` then
# `up` brings nothing back.
#
# ADDRESSING, THE ONE THING TO GET RIGHT: `claude stop` and `claude attach` take an id
# (`Usage: claude stop <id>`) and reject a session NAME outright. The name is what
# SendMessage uses; the id is what controls the process. Every id here comes from
# infra's session-status.sh, column 2.
#
# "Every peer of THIS PROJECT" is resolved by cwd, not by name: a peer carries no run
# prefix (§ Rotation — the name is the stable address a rotation reuses), so two
# projects each running a `swe-manager` share a name. session-status.sh --peers scopes
# by the session's cwd, which is why a peer is spawned FROM the project directory.
#
# swarm reaches infra only through the stable link `~/.claude/kit/infra`, refreshed by
# infra's own SessionStart hook (docs/swarm-design.md § Plugin split). Never by a
# relative path: a marketplace install caches each plugin under its own version dir.
#
# Exit 0 on success. Exit 1 + "error: ..." on stderr on usage mistakes, missing file,
# unknown role, unreadable roster.json, a missing infra link, or a peer that would not
# start. A peer that fails to spawn aborts `up` BEFORE the orchestrator: a half-built
# swarm the orchestrator cannot see is worse than no swarm at all.

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 1; }

SWARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROSTER_SH="$SWARM_DIR/roster.sh"
INFRA="$HOME/.claude/kit/infra"

die() { echo "error: $*" >&2; exit 1; }

usage() {
    cat >&2 <<'USAGE'
error: usage: swarm.sh up [project-dir]
              swarm.sh down [project-dir]
              swarm.sh attach <role> [project-dir]
              swarm.sh brief <role> <file> [project-dir]
USAGE
    exit 1
}

# ---------------------------------------------------------------------------
# brief — copy a brief file into a role's inbox and print the pointer to send.
#
# Briefs travel as files, messages are pointers: the path is stable across rotation,
# and the successor's first act after reading its handoff is to list that inbox.
# ---------------------------------------------------------------------------
cmd_brief() {
    export SWARM_CMD=brief SWARM_ROLE="$ROLE" SWARM_FILE="$FILE" SWARM_PROJECT_DIR="$PROJECT_DIR"

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
except OSError as e:
    fail("cannot read roster: %s" % e)

if role not in roster:
    fail("unknown role: %s" % role)

# Validate that the source file exists and is readable
if not os.path.isfile(file_src):
    fail("file not found: %s" % file_src)

try:
    with open(file_src, 'r') as fh:
        file_content = fh.read()
except OSError as e:
    fail("cannot read file: %s" % e)

# Create inbox directory
inbox_dir = os.path.join(project_dir, ".claude", "swarm", "inbox", role)
try:
    os.makedirs(inbox_dir, exist_ok=True)
except OSError as e:
    fail("cannot create inbox directory: %s" % e)

# Generate filename: <nanosecond-timestamp>-<slug>.md
# slug: alphanumeric + hyphens from the basename without extension
basename = os.path.basename(file_src)
name_without_ext = os.path.splitext(basename)[0]
# Keep only alphanumeric and hyphens, lowercase
slug = "".join(c.lower() if c.isalnum() or c == '-' else '-' for c in name_without_ext)
# Clean up multiple consecutive hyphens
slug = "-".join(filter(None, slug.split("-")))

# Use nanosecond precision to prevent collisions when multiple briefs
# are sent to the same role with the same basename within one second
timestamp = str(time.time_ns())
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
}

# ---------------------------------------------------------------------------
# Shared resolution. up, down and attach all ask the same two questions — which roles
# are peers, and which of them is alive — so they ask them in one place.
# ---------------------------------------------------------------------------

require_infra() {
    [ -d "$INFRA/scripts" ] || die "infra is not linked at ~/.claude/kit/infra — \
start a session with the infra plugin installed, which refreshes the link"
    command -v claude >/dev/null 2>&1 || die "claude CLI not found"
}

roster() { bash "$ROSTER_SH" "$@" "$PROJECT_DIR"; }

# peer_roles — every roster row that is a standing session, in roster order per kind.
# The orchestrator is not one of them, and neither is a worker row.
peer_roles() {
    local out
    out="$( { roster list manager && roster list doer; } )" || exit 1
    PEER_LIST=()
    [ -n "$out" ] && mapfile -t PEER_LIST <<<"$out"
    return 0
}

# peer_status <role>... — one `<role> <id> <kind> <state>` line per role, `gone` when
# this project has no session under that name.
peer_status() {
    bash "$INFRA/scripts/session-status.sh" --peers "$PROJECT_DIR" "$@"
}

is_live() { case "$1" in busy|idle|blocked) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------------------
cmd_up() {
    require_infra
    local orch_role status role id state failed=0

    orch_role="$(roster list orchestrator | head -1)" || exit 1
    [ -n "$orch_role" ] || die "roster has no orchestrator row — a peer that cannot \
name an orchestrator reports into the void"

    peer_roles
    if [ "${#PEER_LIST[@]}" -gt 0 ]; then
        status="$(peer_status "${PEER_LIST[@]}")" || exit 1
        while read -r role id _kind state; do
            [ -n "$role" ] || continue
            if is_live "$state"; then
                echo "$role already up ($id, $state)"
                continue
            fi
            spawn_peer "$role" "$orch_role" || { echo "error: could not start $role" >&2; failed=1; }
        done <<<"$status"
    fi

    # Before the orchestrator, not after: it is about to replace this process, and a
    # swarm missing a peer must not be handed over as if it were whole.
    [ "$failed" -eq 0 ] || die "one or more peers did not start — fix the above and \
re-run \`swarm.sh up\`; it skips the peers already running"

    resume_orchestrator "$orch_role"
}

# spawn_peer <role> <orchestrator-role>
spawn_peer() {
    local role="$1" orch_role="$2" model effort autocompact
    model="$(roster get "$role" model)"             || return 1
    effort="$(roster get "$role" effort)"           || return 1
    autocompact="$(roster get "$role" autocompact)" || return 1
    # FROM the project dir. `claude` has no --cwd, a peer gets no --add-dir, and
    # session-status.sh --peers finds it again by cwd — born anywhere else it is
    # invisible to every later down and attach.
    ( cd "$PROJECT_DIR" || exit 1
      bash "$INFRA/scripts/spawn.sh" peer \
          --name "$role" \
          --brief "$PROJECT_DIR/.claude/swarm/inbox/$role/brief.md" \
          --charter "$PROJECT_DIR/.claude/swarm/charter.md" \
          --model "$model" --effort "$effort" --autocompact "$autocompact" \
          --orchestrator "$orch_role" )
}

# resume_orchestrator <role> — the last thing `up` does, and it EXECS: this terminal
# becomes Will's orchestrator session.
#
# No charter here. The charter is written at a peer ("Will is not watching", "report
# with SendMessage", "escalate to the orchestrator") and every line of it is false for
# the session Will is sitting in. No --bg and no denylist either: this is the one role
# that merges.
resume_orchestrator() {
    local role="$1" sess id brief model effort
    sess="$PROJECT_DIR/.claude/swarm/orchestrator.session"
    cd "$PROJECT_DIR" || die "cannot enter $PROJECT_DIR"

    if [ -s "$sess" ]; then
        id="$(tr -d '[:space:]' <"$sess")"
        [ -z "$id" ] || exec claude --resume "$id"
    fi

    brief="$PROJECT_DIR/.claude/swarm/inbox/$role/brief.md"
    [ -f "$brief" ] && [ -s "$brief" ] \
        || die "orchestrator brief is missing or empty: $brief"
    model="$(roster get "$role" model)"   || exit 1
    effort="$(roster get "$role" effort)" || exit 1
    # `--` before the prompt, same reason as spawn.sh: never let a prompt be read as
    # the tail of an option.
    exec claude -n "$role" --model "$model" --effort "$effort" -- "$(cat "$brief")"
}

# ---------------------------------------------------------------------------
cmd_down() {
    require_infra
    local status role id state

    peer_roles
    if [ "${#PEER_LIST[@]}" -eq 0 ]; then
        echo "no peer roles in the roster — nothing to stop"
        return 0
    fi
    status="$(peer_status "${PEER_LIST[@]}")" || exit 1

    while read -r role id _kind state; do
        [ -n "$role" ] || continue
        if ! is_live "$state" || [ "$id" = "-" ]; then
            echo "$role not running ($state)"
            continue
        fi
        # BY ID. `claude stop <name>` fails with "No job matching …", which would read
        # as a clean shutdown while every peer kept running.
        if claude stop "$id" >/dev/null 2>&1; then
            echo "stopped $role ($id)"
        else
            echo "error: could not stop $role ($id)" >&2
        fi
    done <<<"$status"
}

# ---------------------------------------------------------------------------
cmd_attach() {
    require_infra
    local id
    roster get "$ROLE" kind >/dev/null || exit 1
    id="$(peer_status "$ROLE" | awk '{print $2}')" || exit 1
    [ -n "$id" ] && [ "$id" != "-" ] \
        || die "$ROLE is not running in $PROJECT_DIR — run \`swarm.sh up\` first"
    exec claude attach "$id"
}

# ---------------------------------------------------------------------------
CMD="${1:-}"
[ -n "$CMD" ] || usage
ROLE=""; FILE=""

case "$CMD" in
    brief)
        ROLE="${2:-}"; FILE="${3:-}"
        [ -n "$ROLE" ] && [ -n "$FILE" ] || usage
        PROJECT_DIR="${4:-$PWD}"
        cmd_brief
        ;;
    up|down)
        [ $# -le 2 ] || usage
        PROJECT_DIR="${2:-$PWD}"
        "cmd_$CMD"
        ;;
    attach)
        ROLE="${2:-}"
        [ -n "$ROLE" ] || usage
        [ $# -le 3 ] || usage
        PROJECT_DIR="${3:-$PWD}"
        cmd_attach
        ;;
    *)
        usage
        ;;
esac
