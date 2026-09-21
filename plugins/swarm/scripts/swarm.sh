#!/usr/bin/env bash
#
# swarm.sh — manage swarm roles: peers (standing background sessions) and workers (one-shot tasks).
#
# Usage:
#   bash swarm.sh up [project-dir]
#   bash swarm.sh down [project-dir]
#   bash swarm.sh rotate <role> <handoff-path> [project-dir]
#   bash swarm.sh attach <role> [project-dir]
#   bash swarm.sh brief <role> <file> [project-dir]
#
#   project-dir   defaults to $PWD. Paths, all under <project-dir>/.claude/swarm/:
#                 roster.json, charter.md, inbox/<role>/brief.md, orchestrator.session
#   role          must be present in roster.json
#   file          source file to copy into the inbox
#   handoff-path  the doc the peer named in its own "ready to rotate" reply
#
# up|down|rotate|attach are docs/swarm-design.md § Lifecycle. A PEER is a roster row of kind
# `manager` or `doer`: a standing `claude --bg` session named by its role. The
# `orchestrator` row is NOT a peer — it is Will's own interactive session, the one that
# merges and relays — and `worker` rows are never sessions at all.
#
#   up      starts every peer that is not already up, then hands the terminal to the
#           orchestrator: resumed by the id in orchestrator.session, or started fresh
#           from its brief. Idempotent — re-running it skips the peers already running.
#   down    stops every one of this project's live peers, BY ID. Never the orchestrator.
#   rotate  replaces ONE peer's process, keeping its name: wait for idle, stop by id,
#           respawn with the predecessor's handoff prepended (§ Rotation). This is the
#           peer version of `/clear` then `go`. Nothing here measures context — the peer
#           nudges itself from its own transcript (the context plugin's watchdog) and the
#           orchestrator runs this only once the peer has replied that it is ready.
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
INFRA="${HOME:-/nonexistent}/.claude/kit/infra"

die() { echo "error: $*" >&2; exit 1; }

usage() {
    cat >&2 <<'USAGE'
error: usage: swarm.sh up [project-dir]
              swarm.sh down [project-dir]
              swarm.sh rotate <role> <handoff-path> [project-dir]
              swarm.sh attach <role> [project-dir]
              swarm.sh brief <role> <file> [project-dir]
USAGE
    exit 1
}

# How long rotate waits for a peer to reach a natural stopping point, and how often it
# looks. A peer mid-turn on a real task can easily take minutes, and the alternative to
# waiting is killing that turn.
: "${SWARM_ROTATE_TIMEOUT:=600}"
: "${SWARM_ROTATE_INTERVAL:=5}"

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
# Shared resolution. up, down, rotate and attach all ask the same two questions — which
# roles are peers, and which of them is alive — so they ask them in one place.
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
    local out role
    out="$( { roster list manager && roster list doer; } )" || exit 1
    PEER_LIST=()
    # NOT `mapfile`: it is bash 4+, and macOS ships bash 3.2 while README.md and
    # AGENT_SETUP.md both promise macOS. A missing builtin fails SILENTLY here — there is
    # no `set -e` and the explicit `return 0` swallows it — leaving PEER_LIST empty, which
    # `up` reads as "every peer is already live" (it execs the orchestrator into an empty
    # swarm, reporting success) and `down` reads as "nothing to stop" (it returns 0 while
    # every peer keeps running, and the next `up` then treats each survivor as live).
    # Same portable loop as tcr_install_our_plugins in setup/lib/common.sh.
    while IFS= read -r role; do
        [ -n "$role" ] && PEER_LIST+=("$role")
    done <<<"$out"
    return 0
}

# peer_status <role>... — one `<role> <id> <kind> <state>` line per role, `gone` when
# this project has no session under that name.
peer_status() {
    bash "$INFRA/scripts/session-status.sh" --peers "$PROJECT_DIR" "$@"
}

is_live() { case "$1" in busy|idle|blocked) return 0 ;; *) return 1 ;; esac; }

# is_peer <kind> — only a manager or doer row is a session. Rotating the orchestrator
# row would `claude stop` the terminal Will is sitting in.
is_peer() { case "$1" in manager|doer) return 0 ;; *) return 1 ;; esac; }

# orchestrator_role — the name every peer reports to. Both up and rotate need it, and a
# peer spawned without one reports into the void.
orchestrator_role() {
    local role
    role="$(roster list orchestrator | head -1)" || exit 1
    [ -n "$role" ] || die "roster has no orchestrator row — a peer that cannot name an \
orchestrator reports into the void"
    printf '%s\n' "$role"
}

# ---------------------------------------------------------------------------
cmd_up() {
    require_infra
    local orch_role status role id state failed=0

    orch_role="$(orchestrator_role)" || exit 1

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

# spawn_peer <role> <orchestrator-role> [handoff-path]
#
# With a handoff this is a rotation's second half; without one it is a fresh peer. Same
# builder either way — spawn.sh already prepends the read-this-first instruction, so the
# only difference here is whether the flag is passed at all.
spawn_peer() {
    local role="$1" orch_role="$2" handoff="${3:-}" model effort autocompact
    local -a hand=()
    [ -z "$handoff" ] || hand=(--handoff "$handoff")
    model="$(roster get "$role" model)"             || return 1
    effort="$(roster get "$role" effort)"           || return 1
    autocompact="$(roster get "$role" autocompact)" || return 1
    # FROM the project dir. `claude` has no --cwd, a peer gets no --add-dir, and
    # session-status.sh --peers finds it again by cwd — born anywhere else it is
    # invisible to every later down and attach.
    #
    # ${hand[@]+...}: a fresh peer leaves the array EMPTY, and a bare "${hand[@]}" is an
    # unbound-variable error under `set -u` on bash before 4.4.
    ( cd "$PROJECT_DIR" || exit 1
      bash "$INFRA/scripts/spawn.sh" peer \
          --name "$role" \
          --brief "$PROJECT_DIR/.claude/swarm/inbox/$role/brief.md" \
          --charter "$PROJECT_DIR/.claude/swarm/charter.md" \
          --model "$model" --effort "$effort" --autocompact "$autocompact" \
          ${hand[@]+"${hand[@]}"} \
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
    local status role id state err failed=0

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
        # Keep claude's own words: "No job matching ..." is the difference between a
        # stale id and a stop that was refused.
        if err="$(claude stop "$id" 2>&1 >/dev/null)"; then
            echo "stopped $role ($id)"
        else
            echo "error: could not stop $role ($id): $err" >&2
            failed=1
        fi
    done <<<"$status"

    # Every peer is tried before this: a down that gives up on the first failure leaves
    # the rest running too. Exiting 0 here would be worse still — the next `up` reads a
    # survivor as already live and never replaces it.
    [ "$failed" -eq 0 ] || die "one or more peers did not stop and are still running \
in $PROJECT_DIR — check \`claude agents\` and re-run \`swarm.sh down\`"
}

# ---------------------------------------------------------------------------
# rotate — replace one peer's process, keeping its name (docs/swarm-design.md § Rotation).
#
# THE ORDER IS THE SAFETY ARGUMENT, and every step of it is there because the name is
# the address every other session sends to. Leave it unclaimed and the team is talking
# to nobody.
#
#   1. Refuse a non-peer row. `claude stop` on the orchestrator row would kill the
#      terminal Will is sitting in.
#   2. Validate the handoff FIRST. spawn.sh validates it too, but it only gets to look
#      after the predecessor is already dead — and by then a bad path means the role has
#      no session and its state is gone.
#   3. Wait for idle, and require it TWICE IN A ROW. The second read is the design's
#      re-check: a brief delivered between the peer's "ready" reply and the stop puts it
#      back to busy, and stopping it there loses a turn nobody will redo. The gap between
#      that read and the stop is the residual race § Rotation accepts — briefs are files
#      and messages are pointers, so what is lost is a nudge, never work.
#   4. Stop BY ID, like `down`: `claude stop <name>` fails with "No job matching …",
#      which would read as a clean stop while the predecessor kept running under the
#      name its successor is about to claim.
#
# A `blocked` peer is refused outright: it is wedged on a permission prompt nobody
# answered, holding unsaved state, and the answer is to clear it, not to kill it. Any
# state the CLI grows that this does not know goes the same way — refusing costs a
# re-run, guessing costs the turn.
#
# `gone` — no entry at all for this name+cwd, even with `--all` — is respawned with no
# stop at all: `up` would bring it back from its brief alone; the orchestrator asked
# for a rotation ONTO this handoff, and that doc is the only record of what the
# predecessor was doing.
#
# `stopped`/`done` is NOT taken on its word (#101): a real gate run had
# `session-status.sh --peers` report a genuinely idle peer as `done`, and this branch
# respawned a duplicate right alongside it — two sessions, one memory file, both
# writing. A peer is a `claude --bg` session, and a background session never carries a
# pid in `agents --json` (verified against a live agent list: every `interactive` row
# had one, zero `background` rows did), so there is no per-session
# `/run/user/*/cc-socks/<pid>.sock` or other OS-level signal to cross-check against —
# that upstream gap is not fixable here. What IS available is infra's own
# worker-recovery move (infra/README.md § Recovery): attempt `claude stop`, then
# RE-READ status rather than trust either the old label or the stop's own exit code
# (that README also notes a stop can be "acknowledged and not take"). Only a fresh read
# that again lands on stopped/done/gone earns the respawn; still-live or anything
# outside that vocabulary refuses instead, loud, per this task's conservative default.
# ponytail: a fresh read right after `stop` is evidence, not proof — it closes a
# stale-label lie but not one that stays stuck. Upgrade path if that surfaces: a
# session backend that exposes a real per-peer pid/socket to check independently.
cmd_rotate() {
    require_infra
    local kind orch_role line id state idles=0 deadline err recheck restate

    kind="$(roster get "$ROLE" kind)" || exit 1
    is_peer "$kind" || die "$ROLE is a $kind row, not a peer — only manager and doer \
rows are sessions that rotate"

    [ -f "$HANDOFF" ] && [ -s "$HANDOFF" ] \
        || die "handoff doc is missing or empty: $HANDOFF — nothing was stopped"

    orch_role="$(orchestrator_role)" || exit 1

    deadline=$((SECONDS + SWARM_ROTATE_TIMEOUT))
    while :; do
        line="$(peer_status "$ROLE")" || exit 1
        read -r _role id _kind state <<<"$line"
        case "$state" in
            idle)
                # `-` is session-status's filler for a missing id, and the dead branch
                # below sets it on purpose. Reaching the stop with it on a LIVE peer
                # would skip the stop and respawn the name on top of a session still
                # holding it — two peers, one inbox.
                [ -n "$id" ] && [ "$id" != "-" ] || die "$ROLE is idle in \
$PROJECT_DIR but the agent list gives it no id, and \`claude stop\` takes an id, not a \
name. Nothing was stopped."
                idles=$((idles + 1))
                ;;
            busy)
                idles=0
                ;;
            gone)
                echo "$ROLE not running (gone) — respawning it on the handoff"
                id="-"
                break
                ;;
            stopped|done)
                # The label just lied once in production (#101) — do not act on it a
                # second time. `id` is real here (checked below), so ask `claude stop`
                # to actually try, then re-read state fresh instead of trusting either
                # that call's exit code or the original label.
                [ -n "$id" ] && [ "$id" != "-" ] || die "$ROLE is $state in \
$PROJECT_DIR but the agent list gives it no id, so there is nothing to confirm its \
death against before the name would be reused. Nothing was stopped."
                claude stop "$id" >/dev/null 2>&1
                recheck="$(peer_status "$ROLE")" || exit 1
                read -r _role _id _kind restate <<<"$recheck"
                case "$restate" in
                    stopped|done|gone) ;;
                    *) die "$ROLE was reported $state but a fresh read after \
\`claude stop $id\` says $restate, not stopped/done/gone — the label cannot be \
trusted either way. Nothing was respawned; run \`swarm.sh attach $ROLE\` to check by \
hand, or stop it yourself and re-run rotate." ;;
                esac
                echo "$ROLE not running ($state, confirmed $restate after \
\`claude stop $id\`) — respawning it on the handoff"
                id="-"
                break
                ;;
            *)
                die "$ROLE is $state in $PROJECT_DIR — refusing to rotate. A blocked \
peer is wedged on a prompt nobody answered and is holding unsaved state; clear it with \
\`swarm.sh attach $ROLE\`, then rotate. Nothing was stopped."
                ;;
        esac
        # Two in a row, with the interval BETWEEN them: window 2 of § Rotation is a
        # span of time, so a confirming read taken back to back covers the same instant
        # the first one did and confirms nothing.
        [ "$idles" -ge 2 ] && break
        # A peer that has gone idle once gets its confirming read regardless of the
        # deadline — it has settled, and timing out here refuses a rotation that is ready.
        [ "$idles" -eq 1 ] || [ "$SECONDS" -lt "$deadline" ] || die "$ROLE did not go idle within \
${SWARM_ROTATE_TIMEOUT}s — still $state. Nothing was stopped; re-run rotate once it \
settles, or raise SWARM_ROTATE_TIMEOUT."
        sleep "$SWARM_ROTATE_INTERVAL"
    done

    if [ "$id" != "-" ]; then
        if err="$(claude stop "$id" 2>&1 >/dev/null)"; then
            echo "stopped $ROLE ($id)"
        else
            die "could not stop $ROLE ($id): $err — nothing was respawned, so the \
predecessor still holds the name"
        fi
    fi

    # Past this point the name is UNCLAIMED, so the failure message has to say how to
    # get it back — and that verb is `rotate`, not `up`. `up` would exec the
    # orchestrator over this terminal and respawn the peer from its brief alone,
    # dropping the handoff that was the whole point; `rotate` against the now-dead peer
    # is the same command again, and it respawns ON the handoff.
    spawn_peer "$ROLE" "$orch_role" "$HANDOFF" \
        || die "$ROLE was stopped but its successor did not start — fix the above and \
re-run this same \`swarm.sh rotate $ROLE $HANDOFF\`; it respawns a dead peer on the \
handoff. The handoff is still at $HANDOFF."
    echo "rotated $ROLE on $HANDOFF"
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
ROLE=""; FILE=""; HANDOFF=""

case "$CMD" in
    brief)
        ROLE="${2:-}"; FILE="${3:-}"
        [ -n "$ROLE" ] && [ -n "$FILE" ] || usage
        RAW_DIR="${4:-$PWD}"
        ;;
    up|down)
        [ $# -le 2 ] || usage
        RAW_DIR="${2:-$PWD}"
        ;;
    rotate)
        ROLE="${2:-}"; HANDOFF="${3:-}"
        [ -n "$ROLE" ] && [ -n "$HANDOFF" ] || usage
        [ $# -le 4 ] || usage
        RAW_DIR="${4:-$PWD}"
        ;;
    attach)
        ROLE="${2:-}"
        [ -n "$ROLE" ] || usage
        [ $# -le 3 ] || usage
        RAW_DIR="${3:-$PWD}"
        ;;
    *)
        usage
        ;;
esac

# Absolute from here on. `up` cds into the project twice — once per spawn, once for the
# exec that replaces this process — and a path still relative at that point re-resolves
# against the new cwd, so every brief, charter and roster read after it points at
# nothing. Also the earliest place a bad directory can be named in the error.
PROJECT_DIR="$(cd "$RAW_DIR" 2>/dev/null && pwd)" || die "no such directory: $RAW_DIR"

# The handoff path too, and for the same reason: spawn_peer cds into the project, and a
# path still relative at that point points at nothing from there.
if [ -n "$HANDOFF" ]; then
    HANDOFF_DIR="$(cd "$(dirname "$HANDOFF")" 2>/dev/null && pwd)" \
        || die "handoff doc is missing or empty: $HANDOFF — nothing was stopped"
    HANDOFF="$HANDOFF_DIR/$(basename "$HANDOFF")"
fi

"cmd_$CMD"
