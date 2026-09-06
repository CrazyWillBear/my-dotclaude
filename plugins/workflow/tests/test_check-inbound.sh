#!/usr/bin/env bash
#
# Tests for scripts/check-inbound.sh — the pre-run cross-session message check.
#
# This exists because a live run hit the failure it detects: workers must run
# bypassPermissions, a peer message is only auto-delivered when the sender's
# permission-mode class matches the receiver's, and so every worker report was held
# for the user's approval — turning an unattended loop into one click per report.
# A paragraph in a skill file does not protect anyone; this does.
#
# Covers:
#   * accept -> ok (0); hold / refuse / unset -> degraded (1) / broken (2)
#   * a repo may only TIGHTEN, so the most restrictive source wins
#   * every message names the setting and how to fix it
#   * unreadable or malformed settings never crash and never claim "ok"
#
# Run: bash plugins/workflow/tests/test_check-inbound.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/check-inbound.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HOME_DIR="$WORK/home"; mkdir -p "$HOME_DIR/.claude"
PROJ="$WORK/proj";     mkdir -p "$PROJ/.claude"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in: $2)" ;; esac; }

# set_settings <user|project|local> <json-or-empty>
set_settings() {
    case "$1" in
        user)    f="$HOME_DIR/.claude/settings.json" ;;
        project) f="$PROJ/.claude/settings.json" ;;
        local)   f="$PROJ/.claude/settings.local.json" ;;
    esac
    if [ -z "${2:-}" ]; then rm -f "$f"; else printf '%s\n' "$2" >"$f"; fi
}
clear_all() { set_settings user ""; set_settings project ""; set_settings local ""; }
run() { HOME="$HOME_DIR" bash "$CHECK" "$PROJ" 2>&1; }
rc()  { HOME="$HOME_DIR" bash "$CHECK" "$PROJ" >/dev/null 2>&1; echo $?; }

# ---------------------------------------------------------------------------
echo "test: accept is the only value that lets the lane run unattended"
clear_all; set_settings user '{"crossSessionInbound":"accept"}'
assert_equals "exit 0" "$(rc)" "0"
assert_contains "says ok" "$(run)" "ok:"
assert_contains "names the source" "$(run)" "user settings"

echo "test: hold degrades the run without failing it"
clear_all; set_settings user '{"crossSessionInbound":"hold"}'
assert_equals "exit 1 — a WARN, not a refusal to start" "$(rc)" "1"
assert_contains "says degraded" "$(run)" "DEGRADED"
assert_contains "explains the consequence" "$(run)" "HELD for your approval"
assert_contains "gives the fix" "$(run)" '"crossSessionInbound": "accept"'
assert_contains "states the cost of that fix" "$(run)" "any local session"

echo "test: refuse breaks the session lane outright"
clear_all; set_settings user '{"crossSessionInbound":"refuse"}'
assert_equals "exit 2" "$(rc)" "2"
assert_contains "says broken" "$(run)" "BROKEN"
assert_contains "says reports never arrive" "$(run)" "NEVER arrive"
assert_contains "offers the ad-hoc lane as the way out" "$(run)" "ad-hoc lane"

echo "test: unset is NOT ok — mode parity holds a bypassPermissions worker's report"
clear_all
assert_equals "exit 1" "$(rc)" "1"
assert_contains "names mode parity" "$(run)" "mode parity"

# ---------------------------------------------------------------------------
echo "test: a repo may only TIGHTEN — the most restrictive source wins"
clear_all; set_settings user '{"crossSessionInbound":"accept"}'
set_settings project '{"crossSessionInbound":"hold"}'
assert_equals "project hold beats user accept" "$(rc)" "1"
assert_contains "names the project as the source" "$(run)" "project settings"
set_settings project '{"crossSessionInbound":"refuse"}'
assert_equals "refuse is more restrictive still" "$(rc)" "2"
clear_all; set_settings user '{"crossSessionInbound":"hold"}'
set_settings project '{"crossSessionInbound":"accept"}'
assert_equals "a project CANNOT loosen a user hold" "$(rc)" "1"
clear_all; set_settings local '{"crossSessionInbound":"refuse"}'
assert_equals "local settings are read too" "$(rc)" "2"

# ---------------------------------------------------------------------------
echo "test: bad input never crashes and never claims ok"
clear_all; set_settings user 'not json at all'
assert_equals "malformed settings fall back to unset" "$(rc)" "1"
clear_all; set_settings user '{"crossSessionInbound":"banana"}'
assert_equals "an unknown value is not treated as accept" "$(rc)" "1"
clear_all; set_settings user '[1,2,3]'
assert_equals "a non-object settings file does not crash" "$(rc)" "1"
clear_all
assert_equals "no settings files at all is still exit 1" "$(rc)" "1"

echo "test: it mentions that managed policy can override"
clear_all; set_settings user '{"crossSessionInbound":"hold"}'
assert_contains "names managed policy" "$(run)" "Managed org policy"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
