#!/usr/bin/env bash
#
# Tests for scripts/memory.sh — scaffold .claude/swarm/memory/ from a project's
# roster.json (docs/swarm-design.md § Memory tiers), the central mechanism behind
# /init-swarm's Step 8.
#
# Black-box, exercised for REAL against a real roster.json in a tmpdir, same pattern
# as test_roster.sh. Two things this script must get right that a bare `command -v
# vault` + inline `mkdir -p` cannot prove:
#
#   1. vault-collision guard (review round 1, medium) — `vault` also names HashiCorp
#      Vault. A decoy `vault` on PATH whose --help does not name --layout swarm must
#      never be invoked as if it were wilcus-vault; the plain fallback runs instead,
#      and the decoy's `init` is proven never to have run.
#   2. fallback -> vault recovery (review round 1, medium) — vault init refuses a
#      directory that exists, is non-empty, and has no .vault-policy.json (exactly
#      what a previous fallback run leaves). An empty fallback tree is safe to clear
#      so vault init can adopt it for real; a fallback tree holding any real file is
#      left untouched and refused, never silently blown away.
#
# A stub `vault` (not the decoy) proves both branches deterministically in every
# environment; the real wilcus-vault run at the bottom is opportunistic, same as
# test_init-swarm-skill.sh's own central-mechanism section (CI never has vault on
# PATH, so that block is the only one exercised for real in CI).
#
# Run: bash plugins/swarm/tests/test_memory.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/memory.sh"

# Captured before any test touches PATH: decoy/stub cases need everything else (bash,
# mkdir, find, python3 for roster.sh, ...) to keep resolving normally while their fake
# `vault` takes priority; only the deliberately vault-free cases use a bare literal.
ORIG_PATH="$PATH"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_equals()        { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }

# roster <dir> <text> — write <text> as <dir>/.claude/swarm/roster.json.
roster() { mkdir -p "$1/.claude/swarm"; printf '%s' "$2" > "$1/.claude/swarm/roster.json"; }

# run <full-path> <args...> — run the real script with PATH set to exactly <full-path>
# (never prepended to the inherited PATH — a bare-PATH case must stay vault-free even
# when the machine running this test happens to have a real vault installed
# elsewhere), and set OUT/ERR/RC.
run() {
    local fullpath="$1"; shift
    local errfile="$WORK/err"
    OUT="$(PATH="$fullpath" bash "$SCRIPT" "$@" 2>"$errfile")"
    RC=$?
    ERR="$(cat "$errfile")"
}

TWOROLES='{
  "orchestrator": {"kind": "orchestrator", "backend": "claude", "model": "opus", "effort": "high"},
  "swe-manager":  {"kind": "manager",      "backend": "claude", "model": "opus", "effort": "high"},
  "performance-engineer": {"kind": "doer", "backend": "claude", "model": "opus", "effort": "high"}
}'

# ---------------------------------------------------------------------------
echo "test: script exists, is executable, and reuses roster.sh rather than re-parsing JSON"
if [ -f "$SCRIPT" ]; then ok "memory.sh present at scripts/memory.sh"; else no "memory.sh missing at $SCRIPT"; fi
if [ -x "$SCRIPT" ]; then ok "memory.sh is executable"; else no "memory.sh is not executable"; fi
SCRIPT_SRC=""
[ -f "$SCRIPT" ] && SCRIPT_SRC="$(cat "$SCRIPT")"
assert_contains "memory.sh calls into roster.sh instead of hand-parsing roster.json" "$SCRIPT_SRC" "roster.sh"

# ---------------------------------------------------------------------------
echo "test: no roster -> fails loudly, never scaffolds anything"
NOROSTER="$WORK/noroster"
mkdir -p "$NOROSTER"
run /usr/bin:/bin scaffold "$NOROSTER"
assert_equals "no roster: exit 1" "$RC" "1"
assert_contains "no roster: says so" "$ERR" "error:"
if [ -e "$NOROSTER/.claude/swarm/memory" ]; then no "no roster: memory/ should not exist"; else ok "no roster: memory/ absent"; fi

# ---------------------------------------------------------------------------
echo "test: vault absent on a bare PATH -> the plain fallback runs for real"
BARE="$WORK/bare"
roster "$BARE" "$TWOROLES"
if PATH=/usr/bin:/bin command -v vault >/dev/null 2>&1; then
    no "test assumption broken: vault is reachable on a bare /usr/bin:/bin PATH"
else
    run /usr/bin:/bin scaffold "$BARE"
    assert_equals "bare PATH: exit 0" "$RC" "0"
    assert_contains "bare PATH: prints the one-line notice" "$OUT" "vault not on PATH"
    MEMORY="$BARE/.claude/swarm/memory"
    if [ -d "$MEMORY/shared" ]; then ok "bare PATH: fallback makes shared/"; else no "bare PATH: fallback missing shared/"; fi
    if [ -d "$MEMORY/roles/swe-manager" ] && [ -d "$MEMORY/proposals/swe-manager" ]; then
        ok "bare PATH: fallback makes roles/+proposals/ for the manager role"
    else
        no "bare PATH: fallback missing roles/proposals for swe-manager"
    fi
    if [ -d "$MEMORY/roles/performance-engineer" ] && [ -d "$MEMORY/proposals/performance-engineer" ]; then
        ok "bare PATH: fallback makes roles/+proposals/ for the doer role"
    else
        no "bare PATH: fallback missing roles/proposals for performance-engineer"
    fi
    if [ ! -e "$MEMORY/roles/orchestrator" ]; then
        ok "bare PATH: fallback makes no roles/orchestrator/ (it owns the whole tree already)"
    else
        no "bare PATH: fallback wrongly made roles/orchestrator/"
    fi
    if [ ! -f "$MEMORY/.vault-policy.json" ]; then
        ok "bare PATH: fallback writes no policy file"
    else
        no "bare PATH: fallback should not have written a policy file"
    fi

    echo "test: re-running the fallback on the same tree is idempotent"
    run /usr/bin:/bin scaffold "$BARE"
    assert_equals "fallback re-run: exit 0" "$RC" "0"
    if [ -d "$MEMORY/roles/swe-manager" ]; then ok "fallback re-run: tree still intact"; else no "fallback re-run: tree damaged"; fi
fi

# ---------------------------------------------------------------------------
echo "test: a decoy 'vault' (e.g. HashiCorp Vault) on PATH is never mistaken for wilcus-vault"
DECOYBIN="$WORK/decoybin"
mkdir -p "$DECOYBIN"
DECOY_RAN_MARKER="$WORK/decoy-init-ran"
cat > "$DECOYBIN/vault" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--help" ] || [ "\${1:-}" = "-h" ]; then
    echo "Usage: vault <command> [args]"
    echo ""
    echo "Common commands:"
    echo "    server         Start a Vault server"
    echo "    operator       Perform operator-specific tasks"
    exit 0
fi
if [ "\${1:-}" = "init" ]; then
    touch "$DECOY_RAN_MARKER"
    exit 0
fi
exit 1
EOF
chmod +x "$DECOYBIN/vault"

DECOYTEST="$WORK/decoytest"
roster "$DECOYTEST" "$TWOROLES"
run "$DECOYBIN:$ORIG_PATH" scaffold "$DECOYTEST"
assert_equals "decoy vault: exit 0 (falls back, does not error out)" "$RC" "0"
assert_contains "decoy vault: gets its own notice, not the vault-absent one" "$OUT" "not wilcus-vault"
assert_not_contains "decoy vault: never claims vault is absent (one IS on PATH)" "$OUT" "vault not on PATH"
if [ -f "$DECOY_RAN_MARKER" ]; then no "decoy vault: its init was invoked (should never run)"; else ok "decoy vault: its init was never invoked"; fi
if [ -d "$DECOYTEST/.claude/swarm/memory/shared" ]; then
    ok "decoy vault: plain fallback still scaffolded shared/"
else
    no "decoy vault: plain fallback did not run"
fi

# ---------------------------------------------------------------------------
echo "test: recovery — a real (stub) wilcus-vault adopts an EMPTY prior fallback tree"
STUBBIN="$WORK/stubbin"
mkdir -p "$STUBBIN"
STUB_INIT_LOG="$WORK/stub-init-log"
cat > "$STUBBIN/vault" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--help" ] || [ "\${1:-}" = "-h" ]; then
    echo "vault <command> [options]"
    echo ""
    echo "  init --layout swarm --roster <file>"
    echo "                      set the vault up as a swarm's tiered memory"
    exit 0
fi
if [ "\${1:-}" = "init" ]; then
    # find the --vault value and build the real layout, like the real CLI would.
    root=""
    prev=""
    for a in "\$@"; do
        if [ "\$prev" = "--vault" ]; then root="\$a"; fi
        prev="\$a"
    done
    # Mimics wilcus-vault's own guard (cli/init.py cmd_init): refuse a root that
    # already exists, is non-empty (even just empty scaffold dirs — no file
    # required), and has no .vault-policy.json of its own. Without this, the
    # "recovery, empty tree" test below would pass even if memory.sh's own
    # clear-before-adopt step were deleted, since this stub would silently
    # adopt a dirty tree that the real vault would refuse.
    if [ -e "\$root" ] && [ ! -e "\$root/.vault-policy.json" ] && [ -n "\$(ls -A "\$root" 2>/dev/null)" ]; then
        echo "init: \$root is not empty and has no .vault-policy.json of its own" >&2
        exit 1
    fi
    echo "\$@" >> "$STUB_INIT_LOG"
    mkdir -p "\$root/shared" "\$root/roles/swe-manager" "\$root/proposals/swe-manager" \
             "\$root/roles/performance-engineer" "\$root/proposals/performance-engineer"
    printf '{}' > "\$root/.vault-policy.json"
    exit 0
fi
exit 1
EOF
chmod +x "$STUBBIN/vault"

RECOVER_EMPTY="$WORK/recover-empty"
roster "$RECOVER_EMPTY" "$TWOROLES"
run /usr/bin:/bin scaffold "$RECOVER_EMPTY"   # vault absent: leaves the empty fallback tree
assert_equals "recovery setup: fallback exit 0" "$RC" "0"
RMEMORY="$RECOVER_EMPTY/.claude/swarm/memory"
if [ -d "$RMEMORY/shared" ] && [ ! -f "$RMEMORY/.vault-policy.json" ]; then
    ok "recovery setup: empty fallback tree in place, no policy file yet"
else
    no "recovery setup: fallback tree not in the expected shape"
fi

run "$STUBBIN:$ORIG_PATH" scaffold "$RECOVER_EMPTY"      # vault now available
assert_equals "recovery, empty tree: exit 0 (adopts it)" "$RC" "0"
if [ -s "$STUB_INIT_LOG" ]; then ok "recovery, empty tree: stub vault init was actually run"; else no "recovery, empty tree: stub vault init never ran"; fi
if [ -f "$RMEMORY/.vault-policy.json" ]; then ok "recovery, empty tree: policy file now present"; else no "recovery, empty tree: still no policy file"; fi

# ---------------------------------------------------------------------------
echo "test: recovery — a fallback tree holding a REAL file is refused, never cleared"
: > "$STUB_INIT_LOG"
RECOVER_DIRTY="$WORK/recover-dirty"
roster "$RECOVER_DIRTY" "$TWOROLES"
run /usr/bin:/bin scaffold "$RECOVER_DIRTY"
DMEMORY="$RECOVER_DIRTY/.claude/swarm/memory"
mkdir -p "$DMEMORY/roles/swe-manager"
echo "real memory content" > "$DMEMORY/roles/swe-manager/note.md"

run "$STUBBIN:$ORIG_PATH" scaffold "$RECOVER_DIRTY"
assert_equals "recovery, dirty tree: exit 1 (refuses)" "$RC" "1"
assert_contains "recovery, dirty tree: names the problem" "$ERR" "error:"
if [ -s "$STUB_INIT_LOG" ]; then no "recovery, dirty tree: stub vault init ran (must never be called)"; else ok "recovery, dirty tree: stub vault init was never called"; fi
if [ -f "$DMEMORY/roles/swe-manager/note.md" ]; then ok "recovery, dirty tree: the real file survives untouched"; else no "recovery, dirty tree: the real file was deleted"; fi
if [ -f "$DMEMORY/.vault-policy.json" ]; then no "recovery, dirty tree: should not have written a policy file"; else ok "recovery, dirty tree: still no policy file"; fi

# ---------------------------------------------------------------------------
echo "test: the real vault path, opportunistically, when this machine has wilcus-vault on PATH"
if command -v vault >/dev/null 2>&1 && vault --help 2>&1 | grep -q -- "--layout swarm"; then
    REALVAULT="$WORK/realvault"
    roster "$REALVAULT" "$TWOROLES"
    run "$ORIG_PATH" scaffold "$REALVAULT"
    assert_equals "real vault: exit 0" "$RC" "0"
    VMEMORY="$REALVAULT/.claude/swarm/memory"
    if [ -d "$VMEMORY/shared" ]; then ok "real vault: makes shared/"; else no "real vault: missing shared/"; fi
    if [ -d "$VMEMORY/roles/swe-manager" ] && [ -d "$VMEMORY/proposals/swe-manager" ]; then
        ok "real vault: makes roles/+proposals/ for the manager role"
    else
        no "real vault: missing roles/proposals for swe-manager"
    fi
    if [ ! -e "$VMEMORY/roles/orchestrator" ]; then
        ok "real vault: makes no roles/orchestrator/"
    else
        no "real vault: wrongly made roles/orchestrator/"
    fi
    if [ -f "$VMEMORY/.vault-policy.json" ]; then ok "real vault: writes .vault-policy.json"; else no "real vault: wrote no policy file"; fi

    echo "test: the real vault path recovers a genuine prior fallback run, not just the stub"
    REALRECOVER="$WORK/realrecover"
    roster "$REALRECOVER" "$TWOROLES"
    run /usr/bin:/bin scaffold "$REALRECOVER"   # vault absent: real fallback tree, no policy
    RRMEMORY="$REALRECOVER/.claude/swarm/memory"
    run "$ORIG_PATH" scaffold "$REALRECOVER"    # vault now available for real
    assert_equals "real recovery: exit 0 (adopts the empty fallback tree)" "$RC" "0"
    if [ -f "$RRMEMORY/.vault-policy.json" ]; then
        ok "real recovery: real vault init wrote .vault-policy.json on the second run"
    else
        no "real recovery: still no policy file after the real vault run"
    fi
else
    echo "  SKIP: wilcus-vault not on PATH in this environment — real-vault sub-test not exercised" \
         "(the fallback, decoy, and recovery tests above already ran for real)"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
