#!/usr/bin/env bash
#
# escalate.sh — should this CODEX worker be replaced by the next model in its tier's
# chain, and why? Decided from artifacts that already exist. It NEVER asks the worker:
# a cheap model must not grade its own competence, and a wedged one cannot (#104).
#
# Usage:
#   bash escalate.sh <runid> <issue> <tier> <worktree> --base BRANCH [--attempt N] [--dry-run]
#
# Output: ONE line on stdout — `<reason>: <detail>` — when a signal fires, NOTHING when
# none does. Exit 0 either way. Exit 1 only when it cannot read what it needs (bad usage,
# an unreadable worktree, a thread it could not fetch). A claude-backed worker has no run
# dir and is never escalated (claude tops every chain), so that prints nothing, exit 0.
#
# On a hit it also POSTS the mechanical `**Handoff**` comment — the reason, the commits on
# the branch since base, and the worker's last activity from its event log — unless one for
# this attempt is already on the thread (this runs on every wake, and a respawn takes a
# moment). `--dry-run` prints the reason and posts nothing. The orchestrator then stops the
# worker and respawns at attempt+1 on the SAME worktree (spawn.sh --attempt); at the top of
# the chain it drains, as `failed` does today.
#
# Signals, any one sufficient, checked in this order:
#   failed         the worker reported `failed`, exited non-zero, or died with no exit code
#   deviation-cap  more `**Deviation**` comments than the consult cap allows (cap 2: the
#                  third deviation escalates rather than drawing a third consult)
#   review-cap     the latest `**Review round N**` with N >= 2 still has high or medium
#                  findings — the fix session is spawned at the next chain position
#
# THE THREAD SIGNALS ARE SCOPED TO THIS ATTEMPT. Issue comments are permanent, so a third
# deviation would otherwise fire on every wake forever and walk the whole chain in three
# wakes without the replacement ever working. Only comments after the last handoff count:
# each attempt is judged on evidence it produced. THE ANCHOR LIVES IN THE RUN DIR, not on
# the thread: when this script posts a handoff it records `{attempt, mark}` (the comment
# count at that moment) in `$RUNDIR/handoff.json`, and later wakes scan `comments[mark:]`.
# A worker may post comments (`gh issue comment` is allowed) but cannot reach the run dir,
# so it cannot post a fake `**Handoff**` to reset its own count — which is what anchoring
# on the thread would have allowed (review round 2). The same record is what stops a
# handoff being posted twice for one attempt. (`failed` needs no scoping — spawn.sh clears
# `exit` and `last-message.txt` on every respawn.)
#   occupancy      the worker's context is at or above the threshold (256K)
#   stall          the process is alive, no exit code, and the EVENT LOG has not changed
#                  for the stall window (20 min). Event-log staleness, not worktree mtime:
#                  the log is touched on every action, the worktree only on writes.
#
# WHERE OCCUPANCY COMES FROM. `events.jsonl`'s `turn.completed` usage block is the TURN'S
# CUMULATIVE input (a real run: 2.9M over one turn), not the context size, and it lands
# only when the turn ends. Codex writes the live per-request figure to the worker's own
# rollout under ~/.codex/sessions as `token_count` events carrying `last_token_usage`
# (verified against a real luna worker: last input 174,404 of a 258,400 window). The
# rollout is joined by the thread id `events.jsonl` already records. Same formula as the
# watchdog's: input + cache write (codex's `cached_input_tokens` is a SUBSET of input).
#
# Thresholds are starting values (PRD #104 § Further notes) — revisit once the run log has
# real counts:
#   ESCALATE_STALL_MINUTES=20  ESCALATE_OCCUPANCY_TOKENS=256000  ESCALATE_CONSULT_CAP=2
# Seams: CODEX_RUN_ROOT (the run dirs), CODEX_SESSIONS_ROOT (the rollouts).

set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }

USAGE="usage: escalate.sh <runid> <issue> <tier> <worktree> --base BRANCH [--attempt N] [--dry-run]"
RUNID="${1:-}"; ISSUE="${2:-}"; ISSUE="${ISSUE#\#}"; TIER="${3:-}"; WORKTREE="${4:-}"
shift 4 2>/dev/null || die "$USAGE"
BASE=""; ATTEMPT=0; DRY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --base)    [ $# -ge 2 ] || die "--base needs a value";    BASE="$2";    shift 2 ;;
        --attempt) [ $# -ge 2 ] || die "--attempt needs a value"; ATTEMPT="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) die "unknown flag $1" ;;
    esac
done
[ -n "$RUNID" ] && [ -n "$TIER" ] && [ -n "$WORKTREE" ] || die "$USAGE"
[ -n "$BASE" ] || die "--base BRANCH is required — the handoff lists the commits since it"
case "$ISSUE" in ''|*[!0-9]*) die "issue must be a number, got '$ISSUE'" ;; esac
case "$ATTEMPT" in ''|*[!0-9]*) die "attempt must be a number, got '$ATTEMPT'" ;; esac
case "$RUNID" in *[!A-Za-z0-9._-]*) die "runid may only contain [A-Za-z0-9._-], got '$RUNID'" ;; esac
[ -d "$WORKTREE" ] || die "worktree does not exist: $WORKTREE"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

RUNDIR="${CODEX_RUN_ROOT:-${HOME:-/nonexistent}/.claude/codex-runs}/$RUNID/issue-$ISSUE"
if [ ! -d "$RUNDIR" ]; then
    echo "note: no codex run dir for issue $ISSUE — a claude worker tops its chain and is never escalated" >&2
    exit 0
fi

# The thread, ONCE. Deviation count, review rounds and an existing handoff all come from
# the same read, so they can never disagree with each other.
THREAD="$(cd "$WORKTREE" && gh issue view "$ISSUE" --json comments 2>/dev/null </dev/null)" \
    || die "could not read issue #$ISSUE's comments"
COMMITS="$(git -C "$WORKTREE" log --oneline "$BASE..HEAD" 2>/dev/null)" || COMMITS=""

export ESC_RUNDIR="$RUNDIR" ESC_THREAD="$THREAD" ESC_ATTEMPT="$ATTEMPT" ESC_COMMITS="$COMMITS" ESC_DRY="$DRY" \
       ESC_SESSIONS="${CODEX_SESSIONS_ROOT:-${HOME:-/nonexistent}/.codex/sessions}" \
       ESC_STALL="${ESCALATE_STALL_MINUTES:-20}" \
       ESC_OCC="${ESCALATE_OCCUPANCY_TOKENS:-256000}" \
       ESC_CAP="${ESCALATE_CONSULT_CAP:-2}" \
       ESC_COMMENT="$RUNDIR/handoff-comment.md"

# A dry run writes NOTHING to the run dir — its stderr goes to the caller's, and the
# python block skips the comment file and the mark.
ESC_ERR="$RUNDIR/escalate-stderr.log"; [ -z "$DRY" ] || ESC_ERR=/dev/stderr
REASON="$(python3 2>"$ESC_ERR" <<'PY'
import glob, json, os, re, sys, time

rundir  = os.environ["ESC_RUNDIR"]
attempt = int(os.environ["ESC_ATTEMPT"])
stall_s = float(os.environ["ESC_STALL"]) * 60
occ_max = int(os.environ["ESC_OCC"])
cap     = int(os.environ["ESC_CAP"])

def read(name):
    try:
        with open(os.path.join(rundir, name), encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None

try:
    comments = [str(c.get("body") or "") for c in (json.loads(os.environ["ESC_THREAD"]).get("comments") or [])]
except Exception:
    print("error: the issue's comment listing is not the JSON gh returns", file=sys.stderr)
    sys.exit(2)

# --- the worker's final status ---------------------------------------------------------
status, note = "", ""
raw = (read("last-message.txt") or "").strip()
if raw:
    try:
        r = json.loads(raw)
        status = str(r.get("status", "")).strip()
        note = " ".join(str(r.get("note", "")).split())
    except Exception:
        status = "unreadable"
code = (read("exit") or "").strip()
pid = (read("pid") or "").strip()
alive = False
if pid:
    try:
        os.kill(int(pid), 0); alive = True
    except PermissionError:
        alive = True
    except (OSError, ValueError):
        alive = False

reason = None
if code not in ("", "0"):
    reason = ("failed", "the worker exited %s" % code)
elif code == "0" and status == "failed":
    reason = ("failed", "the worker reported failed: %s" % (note or "(no reason given)"))
elif code == "" and pid and not alive:
    reason = ("failed", "the worker died with no exit code (pid %s is gone)" % pid)

# --- the thread: deviations and review rounds, THIS attempt's only ------------------------
mark_path = os.path.join(rundir, "handoff.json")
mark, marked_attempt = 0, None
try:
    with open(mark_path) as fh:
        m = json.load(fh)
        mark, marked_attempt = int(m.get("mark", 0)), int(m.get("attempt", -1))
except (OSError, ValueError, TypeError):
    pass
this_attempt = comments[mark:]
if reason is None:
    devs = sum(1 for c in this_attempt if re.search(r"(?m)^\*\*Deviation\*\*", c))
    if devs > cap:
        reason = ("deviation-cap", "%d deviations on the thread; the consult cap is %d" % (devs, cap))
if reason is None:
    rounds = []
    for c in this_attempt:
        m = re.search(r"(?m)^\*\*Review round (\d+)\*\*\s*[—-]+\s*(\d+) high, (\d+) medium", c)
        if m:
            rounds.append(tuple(int(x) for x in m.groups()))
    if rounds:
        n, h, med = max(rounds)
        if n >= 2 and (h > 0 or med > 0):
            reason = ("review-cap", "review round %d still has %d high, %d medium" % (n, h, med))

# --- the rollout: live context occupancy ------------------------------------------------
if reason is None:
    ev = read("events.jsonl") or ""
    m = re.search(r'"thread_id"\s*:\s*"([^"]+)"', ev)
    if m:
        last = None
        for path in glob.glob(os.path.join(os.environ["ESC_SESSIONS"], "**", "rollout-*-%s.jsonl" % m.group(1)), recursive=True):
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if '"token_count"' not in line:
                            continue
                        try:
                            info = (json.loads(line).get("payload") or {}).get("info") or {}
                        except Exception:
                            continue
                        u = info.get("last_token_usage") or {}
                        if u:
                            last = int(u.get("input_tokens", 0) or 0) + int(u.get("cache_write_input_tokens", 0) or 0)
            except OSError:
                pass
        if last is not None and last >= occ_max:
            reason = ("occupancy", "context at %d tokens, threshold %d" % (last, occ_max))

# --- stall: alive, not finished, event log untouched ------------------------------------
if reason is None and code == "" and alive:
    try:
        age = time.time() - os.stat(os.path.join(rundir, "events.jsonl")).st_mtime
    except OSError:
        age = None
    if age is not None and age >= stall_s:
        reason = ("stall", "no event-log activity for %d minutes while pid %s is alive" % (int(age // 60), pid))

if reason is None:
    sys.exit(0)

# --- the mechanical handoff -------------------------------------------------------------
already = marked_attempt == attempt
dry = bool(os.environ.get("ESC_DRY"))
tail = []
for line in (read("events.jsonl") or "").splitlines()[-40:]:
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("type") != "item.completed":
        continue
    it = e.get("item") or {}
    what = it.get("command") or it.get("text") or it.get("path") or ""
    what = " ".join(str(what).split())[:120]
    tail.append("- %s: %s" % (it.get("type", "?"), what))
tail = tail[-3:]
commits = os.environ["ESC_COMMITS"].strip()
body = "**Handoff** — attempt %d replaced: %s: %s\n\n" % (attempt, reason[0], reason[1])
body += "Commits on the branch since base:\n%s\n\n" % ("\n".join("- " + l for l in commits.splitlines()) if commits else "- (none)")
body += "Last activity (event log):\n%s\n" % ("\n".join(tail) if tail else "- (none recorded)")
if not dry and not already:
    with open(os.environ["ESC_COMMENT"], "w", encoding="utf-8") as fh:
        fh.write(body)
    # The mark: everything on the thread up to and including the handoff about to be posted
    # belongs to the attempt being replaced. Recorded BEFORE the post so a failed post still
    # scopes the next attempt correctly (an off-by-one here only ever hides one comment).
    with open(mark_path, "w") as fh:
        json.dump({"attempt": attempt, "mark": len(comments) + 1}, fh)
print("%s: %s" % reason)
print("POSTED" if (already or dry) else "POST", file=sys.stderr)
PY
)"
RC=$?
[ "$RC" -eq 0 ] || { [ -n "$DRY" ] || cat "$RUNDIR/escalate-stderr.log" >&2; exit 1; }
[ -n "$REASON" ] || exit 0

if [ -z "$DRY" ] && ! grep -qx POSTED "$RUNDIR/escalate-stderr.log"; then
    ( cd "$WORKTREE" && gh issue comment "$ISSUE" --body-file "$RUNDIR/handoff-comment.md" ) \
        >/dev/null 2>>"$RUNDIR/escalate-stderr.log" </dev/null \
        || echo "warning: could not post the **Handoff** comment on #$ISSUE (the reason still stands)" >&2
fi
printf '%s\n' "$REASON"
