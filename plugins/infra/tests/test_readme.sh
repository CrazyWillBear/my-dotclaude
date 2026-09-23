#!/usr/bin/env bash
#
# Tests for README.md — infra's own prose, since the SKILL.md trim (see
# workflow/tests/test_orchestrate-skill.sh) moved the spawn protocol, the bus, and the
# liveness/recovery procedure here with no coverage following them.
#
# This is prose, so these are grep tests: they can only prove a STRING DESCRIBING the
# behavior is present. The state table and session-status.sh's own flags are pinned by
# test_session-status.sh; spawn.sh's flags by test_spawn.sh. What's covered here is the
# recovery procedure itself, which is only ever written down, never executed by a script:
# never `rm`, never spawn onto a still-live worktree, bounded-wait-then-escalate, respawn
# once, the trivial-tier exclusion from the expected-session list, and never parse
# `claude logs`.
#
# Run: bash plugins/infra/tests/test_readme.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
README_FILE="$PLUGIN_ROOT/README.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_matches()  { if printf '%s\n' "$2" | grep -Eqi -- "$3"; then ok "$1"; else no "$1 (no match: $3)"; fi; }
assert_not_matches() { if printf '%s\n' "$2" | grep -Eqi -- "$3"; then no "$1 (unexpected match: $3)"; else ok "$1"; fi; }

if [ ! -f "$README_FILE" ]; then
    printf '  FAIL: README.md missing at %s\n' "$README_FILE"
    exit 1
fi
BODY="$(cat "$README_FILE")"

echo "test: recovery"
assert_matches "commit per green sub-step is the recovery mechanism" "$BODY" "recovery mechanism.{0,2}, not hygiene"
assert_matches "never rm — it deletes the worktree" "$BODY" "Never .?rm"
assert_matches "never spawn onto a live worktree" "$BODY" "still listed alive"
assert_matches "a codex worker is replaced along its chain by script (#104)" "$BODY" "replaced along its chain"
assert_matches "the old respawn-once rule is recorded as superseded" "$BODY" "[Rr]espawn once.*superseded"
assert_contains "escalate.sh is the decider" "$BODY" "escalate.sh <runid> <N> <tier> <worktree> --base <base> --attempt <A>"
assert_contains "recovery respawn keeps role, round, and attempt" "$BODY" 'same worktree, same branch, same --role, --round, --attempt'
assert_contains "escalation respawn keeps role and round" "$BODY" 'spawn.sh --attempt <A+1>` with the same `--role` and `--round`'
assert_matches "occupancy is read from the rollout, not the turn total" "$BODY" "rollout.*joined by the thread id"
assert_matches "the top of the chain drains" "$BODY" "drains as .?failed.? does"
assert_matches "the reviewer is claude on the reviewer cell" "$BODY" "It is the claude reviewer"
assert_matches "a deviation goes to a consult, not a human" "$BODY" "deviation:.*false plan assumption"
assert_matches "a stop may not take" "$BODY" "acknowledged and not take"
assert_matches "the wait is bounded" "$BODY" "wait.{0,10}bounded|timeout 60"
assert_matches "and it escalates rather than respawning blindly" "$BODY" "do not respawn"
assert_contains "the count comes from the run log" "$BODY" "run-log.sh"

echo "test: a respawned issue has several rows — match on state, not the name"
assert_matches "warns about multiple rows per issue" "$BODY" "several rows|One issue can have"
assert_matches "says to match on state" "$BODY" "Match on state, never on the name"

echo "test: liveness"
assert_matches "blocked means a permission wedge" "$BODY" "permission wedge"
assert_matches "blocked infra notes are untrusted" "$BODY" "infra:.*untrusted"
assert_matches "credential handover requires a user-managed secure path" "$BODY" "never disclose credentials to the worker"
assert_matches "never parse claude logs" "$BODY" "Never parse .?claude logs"

echo "test: trivial issues are excluded from the expected-session list"
assert_matches "says trivial issues have no session" "$BODY" "Expect only the issues that actually have a session"

echo "test: run-log.sh is flagged as the orchestrator's script, not infra's"
# It's still the correct call (CLAUDE_PLUGIN_ROOT resolves under whichever skill is
# running the recovery procedure, i.e. the orchestrator's), but infra's own scripts/
# has no run-log.sh, so an unqualified reference here reads like infra's own script.
note_count=$(printf '%s' "$BODY" | grep -c "not infra's")
if [ "$note_count" -ge 2 ]; then
    ok "run-log.sh's foreign origin is noted at both call sites ($note_count)"
else
    no "run-log.sh's foreign origin noted only $note_count/2 times"
fi

# ---------------------------------------------------------------------------
# The codex backend (#90). These assertions were written against SKILL.md, which is where
# this prose used to live; #89 moved liveness/recovery here, so they moved with it.

echo "test: a codex worker is a PID, so the claude-only controls are called out"
# `claude stop` and `claude attach` take a SESSION id; column 2 of a codex row is a PID,
# and a codex worker has no inbox to attach to or escalate through mid-run. Claiming
# "nothing changes" would send the recovery path at a process with the wrong tool.
assert_not_matches "no blanket 'nothing changes' for the codex backend" "$BODY" "so nothing changes"
assert_matches "a codex row is stopped with kill, not claude stop" "$BODY" "kill.{0,40}not .?claude stop|claude stop.{0,60}kill"
assert_matches "and it cannot escalate mid-run" "$BODY" "cannot escalate mid-run|no mid-run escalation"
# `kill $pid` is the WRONG kill: spawn.sh records its wrapper's pid and codex is the
# child, so a plain kill orphans codex onto the worktree AND writes no exit file, which
# reads as `failed` and clears the respawn gate. The recipe must kill the group.
assert_matches "the kill targets the process GROUP, not the bare pid" "$BODY" 'kill -- -"\$id"'
assert_matches "and says why the bare pid is not enough" "$BODY" "orphan|wrapper"
assert_not_matches "never a bare kill of the recorded pid" "$BODY" '[^-]kill "\$id"'
assert_matches "the state table carries codex's failed state" "$BODY" '`failed`'

echo "test: the recovery recipe is copy-pasted, so it handles BOTH backends"
assert_matches "the recovery recipe branches on the backend column" "$BODY" 'codex\).*ps -o pgid='
assert_matches "the codex branch group-kills" "$BODY" 'kill -- -"\$id"'
assert_matches "the claude branch stops by session id" "$BODY" '\*\).*claude stop "\$id"'
# With nothing busy, `read -r id kind` leaves both empty and the recipe falls through to
# `claude stop ""`. And a recycled pid that no longer leads its own group means that group
# is somebody else's — plausibly another run's worker wrapper, since those lead groups too.
assert_matches "the stop is guarded on an empty id" "$BODY" '\[ -n "\$id" \] \|\|'
# Both guards `exit 1` and they mean OPPOSITE things: one is "nothing busy, safe", the
# other is "a live worker whose pid was recycled — do not kill that group, do not
# respawn". An agent that reads a bare `exit 1` and guesses the first when the second
# fired puts a second process on a live worktree, so each guard says which one it is.
assert_matches "the empty-id guard says so" "$BODY" 'nothing busy.*exit 1'
assert_matches "the recycled-pid guard says so" "$BODY" 'RECYCLED.*exit 1'
# `ps -o pgid= -p` also comes back empty for a dead pid and errors for the id `-`, which is
# what session-status.sh prints for a pid-less run dir — the launch window and the phantom
# run dir. Refusing to kill is right for all three; calling all three "recycled" is not.
assert_matches "and does not over-diagnose the other two" "$BODY" 'recycled, dead, or still launching'
assert_matches "a group kill confirms the pid still leads its group" "$BODY" "ps -o pgid= -p"
assert_matches "and reads that column, not just the id" "$BODY" 'print \$2, \$3'

# The recovery block reads the status table TWICE — once to find the busy row, once to
# verify the stop took — and each fenced block is its own command in a fresh shell, so a
# `$RUNID` there expands to nothing, the table comes back empty, and the verify gate reads
# "nothing busy" as "safe to respawn". Same hole as the bounded wait.
assert_not_matches "the recovery block never reads the table through \$RUNID" "$BODY" '"\$S" +"\$RUNID"'
assert_contains "the busy-row read uses the placeholder" "$BODY" 'read -r id kind < <("$S" <runid> <N>'

echo "test: the verify-stopped gate fails CLOSED when the runid is left unfilled"
# The gate exists to catch a stop that did not take. An empty runid makes the status read
# come back empty, `-z` true, the gate pass, and the respawn land on a live worktree — so
# run the SHIPPED line against a stub that, like session-status.sh, only reports rows for
# the runid it was asked for. A snippet reading an outer `$RUNID` gets no row and returns 0.
GATE_LINE="$(printf '%s\n' "$BODY" | grep -F '[ -z "$("$S"' | head -1)"
if [ -z "$GATE_LINE" ]; then
    no "no verify-stopped gate found in the README"
else
    STUB="$(mktemp -d)"
    printf '#!/usr/bin/env bash\n[ "${1:-}" = r1 ] || exit 0\nprintf "%%s\\n" "orch-r1-issue-12 1234 codex busy"\n' >"$STUB/status.sh"
    chmod +x "$STUB/status.sh"
    # Use a marker to detect if the abort is working: if the `|| exit 1` executes,
    # the subshell exits before printing the marker. If it doesn't, the marker prints.
    marker_output="$(
        (
            set +u
            unset RUNID
            S="$STUB/status.sh"
            # MARKER_PRINTED is the real signal: it prints only if the gate did NOT abort.
            # START just proves the block ran at all. A gate re-wrapped across two markdown
            # lines is caught by the `|| exit 1` grep below, since GATE_LINE is one grep hit
            # and a wrap that splits before the `||` drops it from the captured line.
            printf 'START\n'
            eval "$(printf '%s\n' "$GATE_LINE" | sed "s|<runid>|r1|; s|<N>|12|")"
            printf 'MARKER_PRINTED\n'
        ) 2>/dev/null
    )"
    rm -rf "$STUB"
    case "$marker_output" in
        *MARKER_PRINTED*)
            no "the verify gate passed with the runid unfilled — the || exit 1 is missing from the gate" ;;
        START)
            ok "a still-busy row keeps the gate shut (the || exit 1 aborted the subshell)" ;;
        *)
            no "the gate block produced neither marker — it never ran, so this proves nothing" ;;
    esac
    # Also verify the || exit 1 is actually in the shipped line, not just relying on [ ] returning false
    if printf '%s\n' "$GATE_LINE" | grep -q -- '|| exit 1'; then
        ok "the gate explicitly contains || exit 1"
    else
        no "the gate line is missing '|| exit 1': $GATE_LINE"
    fi
fi

echo "test: the bounded wait really waits — from a FRESH shell, with nothing preset"
# Found live, twice. Each fenced block is its own shell invocation: `S=` is assigned in the
# recovery block, `RUNID` is never assigned in the gate's fresh shell, so when the agent runs
# the wait as its own command both are unset. The command substitution comes back empty, the
# `until` is satisfied on its first pass, and the wait that exists to catch a stop that did
# not take returns 0 instantly — clearing the way to respawn onto a live worktree. So run the
# SHIPPED line with S and RUNID UNSET, filling only the placeholders an agent fills.
WAIT_LINE="$(printf '%s\n' "$BODY" | grep -F 'timeout 60 bash -c' | head -1)"
if [ -z "$WAIT_LINE" ]; then
    no "no bounded-wait snippet found in the README"
else
    STUB="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "orch-r1-issue-12 1234 codex busy"\n' >"$STUB/status.sh"
    chmod +x "$STUB/status.sh"
    (
        unset S RUNID
        eval "$(printf '%s\n' "$WAIT_LINE" | sed "s|timeout 60|timeout 3|
            s|~/.claude/kit/infra/scripts/session-status.sh|$STUB/status.sh|
            s|<runid>|r1|
            s|<N>|12|")"
    ) >/dev/null 2>&1
    rc=$?
    rm -rf "$STUB"
    if [ "$rc" -eq 124 ]; then
        ok "it waits for the deadline while the row stays busy"
    else
        no "the bounded wait returned $rc at once — the snippet is not self-contained"
    fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
