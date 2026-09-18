#!/usr/bin/env bash
#
# Repo-wide invariant: no plugin script expands $HOME unguarded.
#
# Every one of these scripts runs under `set -u`, where a bare $HOME expansion aborts with
# "HOME: unbound variable" before the script's own error handling runs — so the caller gets
# a bash message instead of a reason. systemd units, `env -i` and some hook harnesses run
# without HOME. resolve-tier.sh was bitten by exactly this and fixed in ec8eacf; six other
# files had the same bug.
#
# This is a STATIC scan on purpose. Most of these $HOME lines sit deep behind fixtures
# (spawn.sh's is past a real linked-worktree resolution), so a runtime `env -u HOME` test
# would die at argument parsing and pass whether the guard was there or not. Grepping the
# source proves the property directly. The two sites that ARE cheaply reachable have real
# runtime tests too, in test_link-kit.sh and test_run-log.sh.
#
# Run: bash scripts/tests/test_home-guard.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

echo "test: no plugin script expands \$HOME without a :- default"
scanned=0
for script in "$REPO_ROOT"/plugins/*/scripts/*.sh; do
    [ -f "$script" ] || continue
    scanned=$((scanned + 1))
    name="${script#"$REPO_ROOT"/}"
    # Blank a comment line's content and every guarded form, KEEPING the line so the
    # reported line numbers stay true. What is left is a bare expansion. $HOME must not
    # match $HOME_DIR, which merely starts with it, so the next character has to be a
    # non-identifier one (or end of line); ${HOME} counts as bare too.
    bare="$(sed -e 's/^[[:space:]]*#.*$//' -e 's/${HOME:-/GUARDED/g' "$script" \
            | grep -nE '\$HOME([^A-Za-z0-9_]|$)|\$\{HOME\}' || true)"
    if [ -n "$bare" ]; then
        no "$name expands \$HOME unguarded: $(printf '%s' "$bare" | tr '\n' ' ')"
    else
        ok "$name"
    fi
done

# Without this the whole suite passes vacuously if the glob ever stops matching.
echo "test: the scan actually looked at something"
if [ "$scanned" -ge 10 ]; then
    ok "scanned $scanned plugin scripts"
else
    no "only scanned $scanned scripts — the glob is wrong, so the check above proved nothing"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
