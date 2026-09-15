#!/usr/bin/env bash
#
# Tests for scripts/link-kit.sh — the SessionStart hook that points
# ~/.claude/kit/infra at this plugin's root, the one fixed address other plugins
# call infra's scripts through. Every case runs the real hook against a fake HOME.
#
# Run: bash plugins/infra/tests/test_link-kit.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_P="$(cd "$SCRIPT_DIR/.." && pwd -P)"
HOOK="$ROOT_P/scripts/link-kit.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
LINK="$HOME/.claude/kit/infra"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3')" ;; esac; }

# run [hook-path] — run the hook, set OUT / ERR / RC.
run() { OUT="$(bash "${1:-$HOOK}" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }

# ---------------------------------------------------------------------------
echo "test: a fresh HOME gets the link, silently"
run
assert_equals "fresh: exit 0" "$RC" "0"
assert_equals "fresh: stdout empty" "$OUT" ""
assert_equals "fresh: link targets the plugin root" "$(readlink "$LINK")" "$ROOT_P"

echo "test: running twice is safe"
run
assert_equals "twice: exit 0" "$RC" "0"
assert_equals "twice: same target" "$(readlink "$LINK")" "$ROOT_P"

echo "test: a stale link is repointed"
mkdir -p "$WORK/other"
ln -sfn "$WORK/other" "$LINK"
run
assert_equals "stale: exit 0" "$RC" "0"
assert_equals "stale: repointed" "$(readlink "$LINK")" "$ROOT_P"

echo "test: a dangling link is repointed"
ln -sfn "$WORK/gone" "$LINK"
run
assert_equals "dangling: exit 0" "$RC" "0"
assert_equals "dangling: repointed" "$(readlink "$LINK")" "$ROOT_P"

echo "test: run through the link, the target is still the real root"
run "$LINK/scripts/link-kit.sh"
assert_equals "via link: exit 0" "$RC" "0"
assert_equals "via link: not a self-link" "$(readlink "$LINK")" "$ROOT_P"

echo "test: a real directory in the way is refused, never deleted"
rm -f "$LINK"
mkdir -p "$LINK"
touch "$LINK/marker"
run
assert_equals "real dir: exit 1" "$RC" "1"
assert_contains "real dir: stderr names the path" "$ERR" "$LINK"
if [ -f "$LINK/marker" ]; then ok "real dir: contents survive"; else no "real dir: contents deleted"; fi
if [ ! -e "$LINK/infra" ]; then ok "real dir: no link nested inside"; else no "real dir: nested infra link created"; fi

echo "test: hooks.json runs the hook on SessionStart"
assert_equals "SessionStart command" \
    "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT_P/hooks/hooks.json" 2>/dev/null)" \
    'bash "${CLAUDE_PLUGIN_ROOT}/scripts/link-kit.sh"'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
