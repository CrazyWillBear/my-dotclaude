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
# an unreadable worktree, a thread it could not fetch). A claude-backed worker (resolve-tier.sh
# says so for THIS --attempt) tops its chain and is never escalated, so that prints nothing,
# exit 0 — checked by ASKING resolve-tier.sh, never by a codex run dir's existence, which can
# survive from an earlier, codex, attempt of the same run (#104 review round 11).
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
#   deviation-cap  the worker is paused on a deviation (status `escalate`, note beginning
#                  `deviation:`) and this attempt already used its consults (cap 2): the
#                  third deviation escalates rather than drawing a third consult. Consults
#                  are counted from the thread's `**Consult N**` headings, which
#                  consult.sh posts; a worker forging one only escalates itself sooner and
#                  cannot remove one, so the thread is safe to read for THIS signal.
#   review-cap     a SECOND review round within this attempt still has high or medium
#                  findings — the fix session is spawned at the next chain position.
#                  Counted from `$RUNDIR/rounds`, the ledger the review wrappers append
#                  (`<round> <H> high, <M> medium, <L> low`), NEVER from the thread: a
#                  worker can post a comment headed `**Review round 99** — 0 high…` and
#                  cannot touch the run dir. Rounds are counted inside the attempt (the
#                  ledger position recorded at the last handoff), not off the run-wide
#                  round number, which a respawn inherits: every position gets two.
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
#   occupancy      the worker's context is at or above the threshold (256K) — only while
#                  it is running, or paused on a deviation (a resume would land in a full
#                  window). A finished worker's last figure says nothing about the FRESH
#                  session a fix round is.
#   stall          the process is alive, no exit code, and the EVENT LOG has not changed
#                  for the stall window (20 min). Event-log staleness, not worktree mtime:
#                  the log is touched on every action, the worktree only on writes. NOT
#                  while `$RUNDIR/reviewing` exists: the wrapper writes it once the worker
#                  process has exited and the sibling reviewer is running — the log is
#                  frozen then by design, and `exit` lands only after the review.
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
#   ESCALATE_REVIEW_MINUTES=45 (the post-build review's own budget — see `reviewing` below;
#   ALSO documented in plugins/infra/README.md and SKILL.md's threshold lists — keep in sync)
# Seams: CODEX_RUN_ROOT (the run dirs), CODEX_SESSIONS_ROOT (the rollouts), and — since the
# backend is now resolved, not inferred — RESOLVE_TIER_ROOT / CLAUDE_CONFIG_DIR, whose table
# decides whether this script runs at all for a given attempt.
#
# `$RUNDIR/.started` is written once by spawn.sh, at the FIRST spawn of a run, and never
# rewritten by a respawn — it floors the deviation/consult window for an issue's very first
# evaluation (no `handoff.json` yet) at when THIS run began, so `**Consult**` comments a
# PREVIOUS /orchestrate run left on the thread (permanent, unlike the run dir) cannot count
# against this one. Every later evaluation is scoped by `handoff.json`'s own mark instead.
#
# `$RUNDIR/rounds` AND `$RUNDIR/.started` are residuals, accepted: a worker able to reach the
# run dir (the non-default CODEX_RUN_ROOT threat model this script's siblings already name)
# could truncate `rounds` to hide a review's findings from review-cap, or future-date
# `.started` to make every comment on the thread read as pre-run and permanently empty the
# deviation-cap window. Neither is cleared or re-verified, unlike review.txt, because —
# unlike review.txt — both must SURVIVE across fix rounds/respawns; on the default run root
# both sit outside every writable root, the same acceptance spawn.sh's wrapper gives
# review-checkout/review-scratch's parent directory.

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
# An UNKNOWN tier must not reach resolve-tier.sh: it answers one with the claude-only
# FALLBACK roster (exit 0, its WARN discarded below), which reads here as "claude-backed,
# never escalated" — silently switching every signal off for that worker for the rest of
# the run, with only a reassuring note on stderr. `tier:standard` (the LABEL form) is the
# typo that does it. consult.sh refuses an unknown tier for a weaker reason than this.
case "$TIER" in trivial|standard|complex) ;; *) die "unknown tier '$TIER'" ;; esac
case "$RUNID" in .|..|*[!A-Za-z0-9._-]*) die "runid may only contain [A-Za-z0-9._-] and may not be . or .., got '$RUNID'" ;; esac
[ -d "$WORKTREE" ] || die "worktree does not exist: $WORKTREE"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

RUNDIR="${CODEX_RUN_ROOT:-${HOME:-/nonexistent}/.claude/codex-runs}/$RUNID/issue-$ISSUE"

# The IMPLEMENTER's backend at THIS attempt (round-11 fix): "no codex run dir" is not a valid
# proxy for "claude-backed" — a run dir left over from an earlier, codex, attempt of the SAME
# run survives (nothing deletes it), so testing the filesystem would read a healthy
# claude-backed attempt as codex-backed and subject it to signals no claude worker can ever
# clear (it never respawns, never writes a rollout, never updates the run dir again). Ask
# resolve-tier.sh, the one source of truth for what backend an attempt runs on, instead.
INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$INFRA/resolve-tier.sh" ] || die "missing infra sibling: $INFRA/resolve-tier.sh"
IMPL_BACKEND="$(bash "$INFRA/resolve-tier.sh" "$TIER" "$ATTEMPT" 2>/dev/null | sed -n 's/^implementer_backend=//p' | head -1)"
if [ "$IMPL_BACKEND" = claude ]; then
    echo "note: attempt $ATTEMPT of issue $ISSUE is claude-backed — a claude worker tops its chain and is never escalated" >&2
    exit 0
fi
# A codex attempt's run dir is spawn.sh's, and every read below — plus the stderr log the
# python block redirects into — assumes it exists. Say which dir is missing rather than
# failing later as a bare redirect error and a `cat` of a log that was never created.
[ -d "$RUNDIR" ] || die "no codex run dir for issue $ISSUE: $RUNDIR"

# TRIPWIRE (same as spawn.sh's wrapper, worker-resume.sh and consult.sh): git and gh run
# in the worker's worktree below, on every wake, while the worker may still be writing it.
# A rewritten `commondir` would also silently empty the commit list, so the handoff would
# tell the replacement that nothing landed. Refuse loudly instead.
[ -f "$INFRA/common-git-dir.sh" ] || die "missing infra sibling: $INFRA/common-git-dir.sh"
bash "$INFRA/common-git-dir.sh" --roots "$WORKTREE" >/dev/null \
    || die "containment check refused the worktree $WORKTREE — not reading it"

# The thread, ONCE. Deviation count, review rounds and an existing handoff all come from
# the same read, so they can never disagree with each other.
THREAD="$(cd "$WORKTREE" && gh issue view "$ISSUE" --json comments 2>/dev/null </dev/null)" \
    || die "could not read issue #$ISSUE's comments"
COMMITS="$(git -C "$WORKTREE" log --oneline "$BASE..HEAD" 2>/dev/null)" || COMMITS=""

export ESC_RUNDIR="$RUNDIR" ESC_THREAD="$THREAD" ESC_ATTEMPT="$ATTEMPT" ESC_COMMITS="$COMMITS" ESC_DRY="$DRY" \
       ESC_SESSIONS="${CODEX_SESSIONS_ROOT:-${HOME:-/nonexistent}/.codex/sessions}" \
       ESC_STALL="${ESCALATE_STALL_MINUTES:-20}" \
       ESC_REVIEW="${ESCALATE_REVIEW_MINUTES:-45}" \
       ESC_OCC="${ESCALATE_OCCUPANCY_TOKENS:-256000}" \
       ESC_CAP="${ESCALATE_CONSULT_CAP:-2}" \
       ESC_COMMENT="$RUNDIR/handoff-comment.md"

# A dry run writes NOTHING to the run dir — its stderr goes to the caller's, and the
# python block skips the comment file and the mark.
ESC_ERR="$RUNDIR/escalate-stderr.log"; [ -z "$DRY" ] || ESC_ERR=/dev/stderr
REASON="$(python3 2>"$ESC_ERR" <<'PY'
import datetime, glob, json, os, re, sys, time

rundir  = os.environ["ESC_RUNDIR"]
attempt = int(os.environ["ESC_ATTEMPT"])
stall_s = float(os.environ["ESC_STALL"]) * 60
review_s = float(os.environ["ESC_REVIEW"]) * 60
occ_max = int(os.environ["ESC_OCC"])
cap     = int(os.environ["ESC_CAP"])

def comment_time(c):
    # ISO-8601 UTC, as `gh issue view --json comments` prints createdAt. A comment with no
    # parseable timestamp is treated as arbitrarily old — never lets a stale comment count
    # as fresh, only the reverse (fail toward excluding it, never toward trusting it).
    try:
        return datetime.datetime.strptime(
            str(c.get("createdAt") or ""), "%Y-%m-%dT%H:%M:%SZ"
        ).replace(tzinfo=datetime.timezone.utc).timestamp()
    except ValueError:
        return 0.0

def read(name):
    try:
        with open(os.path.join(rundir, name), encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None

try:
    raw_comments = json.loads(os.environ["ESC_THREAD"]).get("comments") or []
    comments = [str(c.get("body") or "") for c in raw_comments]
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
mark, rounds_mark, marked_attempt = 0, 0, None
try:
    with open(mark_path) as fh:
        m = json.load(fh)
        mark, marked_attempt = int(m.get("mark", 0)), int(m.get("attempt", -1))
        rounds_mark = int(m.get("rounds_mark", 0))
except (OSError, ValueError, TypeError):
    pass
if marked_attempt is None:
    # No **Handoff** yet: this is the CURRENT attempt's first-ever evaluation, so there is
    # no run-dir mark to trust — comments[0:] would include anything a PREVIOUS run left on
    # this same issue. Floor the window at when THIS run started instead.
    run_started = 0.0
    try:
        with open(os.path.join(rundir, ".started")) as fh:
            run_started = float(fh.read().strip())
    except (OSError, ValueError):
        pass
    if run_started:
        mark = len(comments)
        for i, c in enumerate(raw_comments):
            if comment_time(c) >= run_started:
                mark = i
                break
this_attempt = comments[mark:]
ledger = [l for l in (read("rounds") or "").splitlines() if l.strip()]
if reason is None:
    consults = sum(1 for c in this_attempt if re.search(r"(?m)^\*\*Consult \d+\*\*", c))
    if status == "escalate" and note.lower().startswith("deviation:") and consults >= cap:
        reason = ("deviation-cap", "a deviation after %d consults this attempt; the cap is %d" % (consults, cap))
if reason is None:
    rounds = []
    for l in ledger[rounds_mark:]:
        m = re.match(r"(\d+) (\d+) high, (\d+) medium", l)
        if m:
            rounds.append(tuple(int(x) for x in m.groups()))
    if len(rounds) >= 2:
        n, h, med = rounds[-1]          # the NEWEST, not the highest number
        if h > 0 or med > 0:
            reason = ("review-cap", "review round %d (this attempt's %d) still has %d high, %d medium" % (n, len(rounds), h, med))

# --- the rollout: live context occupancy ------------------------------------------------
# The marker holds the stall signal off only for as long as a review may reasonably run:
# past the stall window a wedged `claude -p` reviewer is a stall like any other (the
# marker has no other bound, and a hung review would otherwise be invisible forever).
# ITS OWN BUDGET, not the stall window: `claude -p` spawning my-review may run the
# project's done-check, and 20 minutes is not generous for that (this repo already budgets
# 10 minutes for a single opus PLAN pass — SKILL.md). Borrowing stall_s made a slow but
# healthy review indistinguishable from a stall, and the orchestrator's response to a stall
# is a group kill — which takes the in-flight reviewer, and the build it was reviewing,
# down with it.
try:
    reviewing = time.time() - os.stat(os.path.join(rundir, "reviewing")).st_mtime < review_s
except OSError:
    reviewing = False
running = code == "" and alive and not reviewing
if reason is None and (running or status == "escalate"):
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
if reason is None and running:
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
        json.dump({"attempt": attempt, "mark": len(comments) + 1, "rounds_mark": len(ledger)}, fh)
print("%s: %s" % reason)
if not dry:
    print("POSTED" if already else "POST", file=sys.stderr)
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
