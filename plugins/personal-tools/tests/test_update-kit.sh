#!/usr/bin/env bash
#
# Tests for scripts/update-kit.sh
#
# Black-box: we stub `claude` on PATH so it logs every invocation to a file and
# point HOME at a sandbox, then assert:
#   1. `claude plugin marketplace update my-dotclaude` is called first.
#   2. every plugin listed in .claude-plugin/marketplace.json is then updated
#      (derived, not hardcoded to personal-tools/workflow — a third plugin in
#      the manifest must be updated too).
#   3. The restart reminder is printed to stdout.
#   4. The script exits 0.
#   5. The status line is refreshed from the marketplace's local repo copy:
#      ~/.claude/statusline.py is written (matching global/statusline.py) and
#      the statusLine block is merged into ~/.claude/settings.json.
#   6. When the marketplace copy can't be located, the refresh is skipped
#      gracefully — the script still exits 0 and prints the restart reminder.
#
# Run: bash plugins/personal-tools/tests/test_update-kit.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/update-kit.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }

# ---------------------------------------------------------------------------
# Build a stub `claude` that appends each invocation as a line to $WORK/calls.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/claude" <<'STUB'
#!/usr/bin/env bash
# Stub claude: record each invocation (all args on one line) then exit 0 —
# except `plugin update <name>` for a name in $CLAUDE_STUB_NOT_INSTALLED,
# which fails the way the real CLI does for a plugin that isn't installed, and
# `plugin install <name>@...` for a name in $CLAUDE_STUB_INSTALL_FAILS.
printf '%s\n' "$*" >> "$CLAUDE_STUB_LOG"
for missing in ${CLAUDE_STUB_NOT_INSTALLED:-}; do
    [ "$*" = "plugin update $missing" ] && exit 1
done
for broken in ${CLAUDE_STUB_INSTALL_FAILS:-}; do
    case "$*" in "plugin install $broken@"*) exit 1 ;; esac
done
exit 0
STUB
chmod +x "$WORK/bin/claude"

export CLAUDE_STUB_LOG="$WORK/calls"

# ---------------------------------------------------------------------------
echo "test: script exists at the expected path"
if [ -f "$SCRIPT" ]; then
    ok "update-kit.sh present at scripts/update-kit.sh"
else
    no "update-kit.sh missing at $SCRIPT"
fi

# ---------------------------------------------------------------------------
echo "test: script is executable"
if [ -x "$SCRIPT" ]; then
    ok "update-kit.sh is executable"
else
    no "update-kit.sh is not executable"
fi

# ---------------------------------------------------------------------------
# A sandbox HOME whose known_marketplaces.json points the my-dotclaude
# marketplace at THIS repo checkout — so the status-line refresh copies the
# real global/statusline.py and reuses the real setup/lib/common.sh installer.
# ---------------------------------------------------------------------------
HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR/.claude/plugins"
cat > "$HOME_DIR/.claude/plugins/known_marketplaces.json" <<EOF
{
  "my-dotclaude": {
    "source": { "source": "directory", "path": "$REPO_ROOT" },
    "installLocation": "$REPO_ROOT"
  }
}
EOF

# ---------------------------------------------------------------------------
# Run the script with the stub claude on PATH and the sandbox HOME.
# ---------------------------------------------------------------------------
rm -f "$CLAUDE_STUB_LOG"
out=$(PATH="$WORK/bin:$PATH" HOME="$HOME_DIR" bash "$SCRIPT" 2>&1)
exit_code=$?

# ---------------------------------------------------------------------------
echo "test: script exits 0"
if [ "$exit_code" -eq 0 ]; then
    ok "exit code is 0"
else
    no "exit code is $exit_code (want 0)"
fi

# ---------------------------------------------------------------------------
echo "test: one marketplace-update call plus one plugin-update call per manifest plugin"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    count=$(wc -l < "$CLAUDE_STUB_LOG")
    want=$(( $(grep -c '"source": "./plugins/' "$REPO_ROOT/.claude-plugin/marketplace.json") + 1 ))
    assert_equals "marketplace call + one per real manifest plugin" "$count" "$want"
else
    no "no claude calls recorded (log missing)"
fi

# ---------------------------------------------------------------------------
echo "test: first call is 'claude plugin marketplace update my-dotclaude'"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    first=$(sed -n '1p' "$CLAUDE_STUB_LOG")
    assert_equals "first call: marketplace update" "$first" "plugin marketplace update my-dotclaude"
else
    no "cannot check first call — log missing"
fi

# ---------------------------------------------------------------------------
echo "test: context, personal-tools and workflow are each updated (order not asserted)"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    calls="$(cat "$CLAUDE_STUB_LOG")"
    assert_contains "updates context"       "$calls" "plugin update context"
    assert_contains "updates personal-tools" "$calls" "plugin update personal-tools"
    assert_contains "updates workflow"       "$calls" "plugin update workflow"
else
    no "cannot check plugin update calls — log missing"
fi

# ---------------------------------------------------------------------------
echo "test: a third plugin in the manifest is updated too — not hardcoded to personal-tools/workflow"
THIRD_HOME="$WORK/third-home"
FAKE_ROOT="$WORK/fakerepo"
mkdir -p "$THIRD_HOME/.claude/plugins" "$FAKE_ROOT/.claude-plugin" "$FAKE_ROOT/setup/lib" "$FAKE_ROOT/global"
cp "$REPO_ROOT/setup/lib/common.sh" "$FAKE_ROOT/setup/lib/common.sh"
cp "$REPO_ROOT/global/statusline.py" "$FAKE_ROOT/global/statusline.py"
cat > "$FAKE_ROOT/.claude-plugin/marketplace.json" <<'EOF'
{
  "plugins": [
    {"name": "personal-tools"},
    {"name": "workflow"},
    {"name": "context"}
  ]
}
EOF
cat > "$THIRD_HOME/.claude/plugins/known_marketplaces.json" <<EOF
{
  "my-dotclaude": {
    "source": { "source": "directory", "path": "$FAKE_ROOT" },
    "installLocation": "$FAKE_ROOT"
  }
}
EOF
rm -f "$CLAUDE_STUB_LOG"
out3=$(PATH="$WORK/bin:$PATH" HOME="$THIRD_HOME" bash "$SCRIPT" 2>&1)
rc3=$?
assert_equals "exits 0 with a third plugin in the manifest" "$rc3" "0"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    calls3="$(cat "$CLAUDE_STUB_LOG")"
    count3=$(wc -l < "$CLAUDE_STUB_LOG")
    assert_equals "four claude calls (marketplace + 3 plugins)" "$count3" "4"
    assert_contains "updates the third, unnamed plugin" "$calls3" "plugin update context"
else
    no "no claude calls recorded for the third-plugin manifest"
fi

# ---------------------------------------------------------------------------
# A plugin added to the manifest after the user installed the kit (e.g. infra)
# isn't installed yet, so `claude plugin update` fails for it. update-kit must
# install it instead, and keep going to the plugins listed after it.
# ---------------------------------------------------------------------------
echo "test: a manifest plugin that isn't installed yet gets installed, and later plugins still update"
rm -f "$CLAUDE_STUB_LOG"
outni=$(PATH="$WORK/bin:$PATH" HOME="$HOME_DIR" CLAUDE_STUB_NOT_INSTALLED=infra bash "$SCRIPT" 2>&1)
rcni=$?
assert_equals "exit 0 when a manifest plugin isn't installed yet" "$rcni" "0"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    callsni="$(cat "$CLAUDE_STUB_LOG")"
    assert_contains "installs the not-yet-installed plugin" "$callsni" "plugin install infra@my-dotclaude"
    assert_contains "still updates workflow, listed after infra" "$callsni" "plugin update workflow"
    assert_not_contains "doesn't install an already-installed plugin" "$callsni" "plugin install workflow"
else
    no "no claude calls recorded for the not-installed plugin"
fi
assert_contains "still prints restart reminder" "$outni" "Restart"

# ---------------------------------------------------------------------------
# Round-2 medium: if the fallback install fails too, update-kit must not print
# "Done" and exit 0 — the skill would report a successful update.
# ---------------------------------------------------------------------------
echo "test: update and install both fail -> non-zero exit, no 'Done', manual install command shown"
rm -f "$CLAUDE_STUB_LOG"
outif=$(PATH="$WORK/bin:$PATH" HOME="$HOME_DIR" CLAUDE_STUB_NOT_INSTALLED=infra CLAUDE_STUB_INSTALL_FAILS=infra bash "$SCRIPT" 2>&1)
rcif=$?
if [ "$rcif" -ne 0 ]; then
    ok "exits non-zero when a plugin neither updates nor installs"
else
    no "exit code is 0 (want non-zero) when a plugin neither updates nor installs"
fi
assert_not_contains "doesn't print 'Done' after a failed install" "$outif" "Done"
assert_contains "tells the user the manual install command" "$outif" "claude plugin install infra@my-dotclaude"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    assert_contains "still updates workflow, listed after the failed plugin" "$(cat "$CLAUDE_STUB_LOG")" "plugin update workflow"
else
    no "no claude calls recorded for the failed-install run"
fi

# ---------------------------------------------------------------------------
# Regression test for the round-2->3 fix: a malformed local-copy manifest
# must abort the script (bare assignment under set -e propagates tcr_die),
# not silently read zero plugin names and exit 0.
# ---------------------------------------------------------------------------
echo "test: malformed local-copy manifest aborts the script — no plugin updates, non-zero exit"
BAD_HOME="$WORK/bad-manifest-home"
BAD_ROOT="$WORK/bad-manifest-repo"
mkdir -p "$BAD_HOME/.claude/plugins" "$BAD_ROOT/.claude-plugin" "$BAD_ROOT/setup/lib" "$BAD_ROOT/global"
cp "$REPO_ROOT/setup/lib/common.sh" "$BAD_ROOT/setup/lib/common.sh"
cp "$REPO_ROOT/global/statusline.py" "$BAD_ROOT/global/statusline.py"
printf 'not valid json' > "$BAD_ROOT/.claude-plugin/marketplace.json"
cat > "$BAD_HOME/.claude/plugins/known_marketplaces.json" <<EOF
{
  "my-dotclaude": {
    "source": { "source": "directory", "path": "$BAD_ROOT" },
    "installLocation": "$BAD_ROOT"
  }
}
EOF
rm -f "$CLAUDE_STUB_LOG"
outbad=$(PATH="$WORK/bin:$PATH" HOME="$BAD_HOME" bash "$SCRIPT" 2>&1)
rcbad=$?
if [ "$rcbad" -ne 0 ]; then
    ok "exits non-zero on a malformed local-copy manifest"
else
    no "exit code is 0 (want non-zero) on a malformed local-copy manifest"
fi
if [ -f "$CLAUDE_STUB_LOG" ]; then
    assert_equals "only the marketplace-update call, no plugin updates, on malformed manifest" \
        "$(wc -l < "$CLAUDE_STUB_LOG")" "1"
else
    no "no claude calls recorded (log missing)"
fi

# ---------------------------------------------------------------------------
echo "test: output includes a restart reminder"
assert_contains "restart reminder in output" "$out" "Restart"

# ---------------------------------------------------------------------------
echo "test: restart reminder mentions Claude Code"
assert_contains "restart reminder mentions Claude Code" "$out" "Claude Code"

# ---------------------------------------------------------------------------
echo "test: status line is refreshed from the marketplace repo copy"
if [ -f "$HOME_DIR/.claude/statusline.py" ]; then
    if diff -q "$HOME_DIR/.claude/statusline.py" "$REPO_ROOT/global/statusline.py" >/dev/null; then
        ok "statusline.py installed and matches global/statusline.py"
    else
        no "statusline.py installed but differs from global/statusline.py"
    fi
else
    no "statusline.py was not written to the sandbox ~/.claude"
fi

# ---------------------------------------------------------------------------
echo "test: settings.json gets the statusLine wiring"
if [ -f "$HOME_DIR/.claude/settings.json" ]; then
    settings="$(cat "$HOME_DIR/.claude/settings.json")"
    assert_contains "settings.json has statusLine" "$settings" '"statusLine"'
    assert_contains "statusLine points at statusline.py" "$settings" "statusline.py"
else
    no "settings.json was not written to the sandbox ~/.claude"
fi

# ---------------------------------------------------------------------------
# No known_marketplaces.json + no network: must not error, and must not
# silently claim success while doing nothing dangerous — just skip.
# ---------------------------------------------------------------------------
echo "test: missing marketplace metadata and no network -> refresh skipped, still succeeds"
EMPTY_HOME="$WORK/empty-home"
mkdir -p "$EMPTY_HOME/.claude"
mkdir -p "$WORK/offline-stubs"
cat > "$WORK/offline-stubs/curl" <<'EOF'
#!/usr/bin/env bash
# Stub curl: simulate no network for the common.sh bootstrap fetch.
exit 1
EOF
chmod +x "$WORK/offline-stubs/curl"
rm -f "$CLAUDE_STUB_LOG"
out2=$(PATH="$WORK/offline-stubs:$WORK/bin:$PATH" HOME="$EMPTY_HOME" bash "$SCRIPT" 2>&1)
rc2=$?
assert_equals "exit 0 even without marketplace metadata or network" "$rc2" "0"
assert_contains "still prints restart reminder" "$out2" "Restart"
assert_not_contains "no statusline written without metadata or network" \
    "$(ls "$EMPTY_HOME/.claude" 2>/dev/null)" "statusline.py"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    assert_equals "only the marketplace-update call, no plugin updates" \
        "$(wc -l < "$CLAUDE_STUB_LOG")" "1"
else
    no "no claude calls recorded (log missing)"
fi

# ---------------------------------------------------------------------------
# Local repo copy has common.sh but no .claude-plugin/marketplace.json (e.g. a
# stale or partial checkout). tcr_our_plugin_names then falls back to a
# network fetch even though TCR_LOCAL_ROOT is set, so the script's own branch
# condition must match that fallback and treat a manifest-fetch failure here
# as non-fatal too — not take the hard-fail local-copy branch (round-4 low:
# a 429 must not kill the script after the marketplace update already ran).
# ---------------------------------------------------------------------------
echo "test: local repo copy without a manifest falls back to the non-fatal remote path"
NOMANIFEST_HOME="$WORK/no-manifest-home"
NOMANIFEST_ROOT="$WORK/no-manifest-repo"
mkdir -p "$NOMANIFEST_HOME/.claude/plugins" "$NOMANIFEST_ROOT/setup/lib" "$NOMANIFEST_ROOT/global"
cp "$REPO_ROOT/setup/lib/common.sh" "$NOMANIFEST_ROOT/setup/lib/common.sh"
cp "$REPO_ROOT/global/statusline.py" "$NOMANIFEST_ROOT/global/statusline.py"
cat > "$NOMANIFEST_HOME/.claude/plugins/known_marketplaces.json" <<EOF
{
  "my-dotclaude": {
    "source": { "source": "directory", "path": "$NOMANIFEST_ROOT" },
    "installLocation": "$NOMANIFEST_ROOT"
  }
}
EOF
rm -f "$CLAUDE_STUB_LOG"
outnm=$(PATH="$WORK/offline-stubs:$WORK/bin:$PATH" HOME="$NOMANIFEST_HOME" bash "$SCRIPT" 2>&1)
rcnm=$?
assert_equals "exit 0 when the local copy has no manifest and the network fetch fails" "$rcnm" "0"
assert_contains "still prints restart reminder" "$outnm" "Restart"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    assert_equals "only the marketplace-update call, no plugin updates" \
        "$(wc -l < "$CLAUDE_STUB_LOG")" "1"
else
    no "no claude calls recorded (log missing)"
fi

# ---------------------------------------------------------------------------
# No known_marketplaces.json, but the network is up: update-kit.sh must fall
# back to fetching setup/lib/common.sh remotely (same bootstrap setup-dev.sh
# uses) rather than silently skipping every plugin update — the round-2 fix
# for the regression where the old hardcoded two-plugin update always ran.
# ---------------------------------------------------------------------------
echo "test: missing marketplace metadata but network up -> derives plugin list via remote common.sh, still updates every plugin"
REMOTE_HOME="$WORK/remote-home"
mkdir -p "$REMOTE_HOME/.claude"
mkdir -p "$WORK/remote-stubs"
# Stub curl: cp the REAL setup/lib/common.sh, .claude-plugin/marketplace.json
# and global/statusline.py for their respective URLs, so this exercises the
# real fallback behavior (real common.sh, the second curl for
# marketplace.json inside tcr_our_plugin_names, real statusline install) —
# not a fabricated stand-in that would hide bugs in that path. Set
# FAIL_MANIFEST=1 to simulate the manifest fetch failing while common.sh
# still succeeds.
cat > "$WORK/remote-stubs/curl" <<'EOF'
#!/usr/bin/env bash
out=""
url=""
for ((i = 1; i <= $#; i++)); do
    case "${!i}" in
        -o) j=$((i + 1)); out="${!j}" ;;
        http*://*) url="${!i}" ;;
    esac
done
case "$url" in
    *setup/lib/common.sh)
        cp "$REPO_ROOT/setup/lib/common.sh" "$out"; exit 0 ;;
    *.claude-plugin/marketplace.json)
        [ "${FAIL_MANIFEST:-0}" = "1" ] && exit 1
        if [ "${THIRD_PLUGIN:-0}" = "1" ]; then
            cat > "$out" <<'MANIFEST'
{
  "plugins": [
    {"name": "personal-tools"},
    {"name": "workflow"},
    {"name": "context"}
  ]
}
MANIFEST
        else
            cp "$REPO_ROOT/.claude-plugin/marketplace.json" "$out"
        fi
        exit 0 ;;
    *global/statusline.py)
        cp "$REPO_ROOT/global/statusline.py" "$out"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$WORK/remote-stubs/curl"
rm -f "$CLAUDE_STUB_LOG"
out3r=$(PATH="$WORK/remote-stubs:$WORK/bin:$PATH" HOME="$REMOTE_HOME" REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" 2>&1)
rc3r=$?
assert_equals "exit 0 with the remote common.sh fallback" "$rc3r" "0"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    calls3r="$(cat "$CLAUDE_STUB_LOG")"
    assert_contains "remote fallback still updates context"        "$calls3r" "plugin update context"
    assert_contains "remote fallback still updates personal-tools" "$calls3r" "plugin update personal-tools"
    assert_contains "remote fallback still updates workflow"       "$calls3r" "plugin update workflow"
else
    no "no claude calls recorded for the remote-fallback path"
fi
if [ -f "$REMOTE_HOME/.claude/statusline.py" ]; then
    ok "remote fallback installs the real statusline.py"
else
    no "remote fallback did not install statusline.py"
fi

# ---------------------------------------------------------------------------
# Same remote fallback, but the fetched manifest lists a third plugin — the
# remote path must derive its list too, not just the local-copy path (round-4
# finding: reverting the remote branch to a hardcoded pair would leave the
# other remote-fallback tests green since they only ever see the real
# 2-plugin manifest).
# ---------------------------------------------------------------------------
echo "test: remote fallback with a third plugin in the fetched manifest updates it too"
REMOTE_THIRD_HOME="$WORK/remote-third-home"
mkdir -p "$REMOTE_THIRD_HOME/.claude"
rm -f "$CLAUDE_STUB_LOG"
out3rt=$(PATH="$WORK/remote-stubs:$WORK/bin:$PATH" HOME="$REMOTE_THIRD_HOME" REPO_ROOT="$REPO_ROOT" THIRD_PLUGIN=1 bash "$SCRIPT" 2>&1)
rc3rt=$?
assert_equals "exit 0 with the remote fallback third-plugin manifest" "$rc3rt" "0"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    calls3rt="$(cat "$CLAUDE_STUB_LOG")"
    assert_equals "four claude calls via remote fallback (marketplace + 3 plugins)" \
        "$(wc -l < "$CLAUDE_STUB_LOG")" "4"
    assert_contains "remote fallback updates the third, unnamed plugin" "$calls3rt" "plugin update context"
else
    no "no claude calls recorded for the remote-fallback third-plugin manifest"
fi

# ---------------------------------------------------------------------------
# Same remote fallback, but only the marketplace.json fetch fails (common.sh
# itself fetched fine) — e.g. a 429 or flaky DNS on the second curl inside
# tcr_our_plugin_names. This must be non-fatal: no plugin updates happen, but
# the marketplace update already ran, the status line still refreshes, and
# the script still prints the restart reminder and exits 0 — round-3 fix for
# tcr_die propagating through the bare assignment and killing the script.
# ---------------------------------------------------------------------------
echo "test: remote fallback, manifest fetch fails -> non-fatal, no plugin updates, still succeeds"
MANIFEST_FAIL_HOME="$WORK/manifest-fail-home"
mkdir -p "$MANIFEST_FAIL_HOME/.claude"
rm -f "$CLAUDE_STUB_LOG"
out3f=$(PATH="$WORK/remote-stubs:$WORK/bin:$PATH" HOME="$MANIFEST_FAIL_HOME" REPO_ROOT="$REPO_ROOT" FAIL_MANIFEST=1 bash "$SCRIPT" 2>&1)
rc3f=$?
assert_equals "exit 0 even when the remote manifest fetch fails" "$rc3f" "0"
assert_contains "still prints restart reminder when manifest fetch fails" "$out3f" "Restart"
if [ -f "$CLAUDE_STUB_LOG" ]; then
    assert_equals "only the marketplace-update call, no plugin updates" \
        "$(wc -l < "$CLAUDE_STUB_LOG")" "1"
else
    no "no claude calls recorded (log missing)"
fi
if [ -f "$MANIFEST_FAIL_HOME/.claude/statusline.py" ]; then
    ok "status line still refreshes when only the manifest fetch fails"
else
    no "status line was not refreshed when only the manifest fetch fails"
fi

# ---------------------------------------------------------------------------
# The skill's prose must describe the derived plugin list, not the old
# hardcoded personal-tools/workflow pair.
# ---------------------------------------------------------------------------
echo "test: the update-kit skill doc no longer hardcodes personal-tools/workflow"
SKILL_FILE="$PLUGIN_ROOT/skills/update-kit/SKILL.md"
if [ -f "$SKILL_FILE" ]; then
    skill="$(cat "$SKILL_FILE")"
    assert_not_contains "no hardcoded 'three claude CLI calls'" "$skill" "three \`claude\` CLI calls"
    assert_not_contains "no hardcoded 'both plugins' in the description" "$skill" "both plugins"
    assert_contains "documents the manifest-derived plugin list" "$skill" "marketplace.json"
else
    no "SKILL.md missing at $SKILL_FILE"
fi

# ---------------------------------------------------------------------------
# Round-4 low: AGENT_SETUP.md was missed by the doc sweep that already fixed
# the same stale claim in the two READMEs (commit 44d5f85).
# ---------------------------------------------------------------------------
echo "test: AGENT_SETUP.md no longer claims update-kit hardcodes both plugins"
AGENT_SETUP_FILE="$REPO_ROOT/AGENT_SETUP.md"
if [ -f "$AGENT_SETUP_FILE" ]; then
    assert_not_contains "AGENT_SETUP.md doesn't hardcode 'both the personal-tools and workflow plugins'" \
        "$(cat "$AGENT_SETUP_FILE")" 'both the `personal-tools` and `workflow` plugins'
else
    no "AGENT_SETUP.md missing at $AGENT_SETUP_FILE"
fi

# ---------------------------------------------------------------------------
# Review round 1 (issue #84): the manual `claude plugin install` fallback had
# fallen behind the marketplace manifest (missing the context plugin) — assert
# against the real manifest, derived the same way tcr_install_our_plugins does,
# so a future plugin addition can't drift out of this doc silently again.
# ---------------------------------------------------------------------------
echo "test: AGENT_SETUP.md's manual install fallback names every plugin in the marketplace manifest"
if [ -f "$AGENT_SETUP_FILE" ]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/setup/lib/common.sh"
    setup="$(cat "$AGENT_SETUP_FILE")"
    # Capture into a variable (not a bare here-string on the command
    # substitution) so tcr_die's `exit` inside the $(...) subshell is visible
    # as a non-zero $? here — round-2 fix: the old `done <<< "$(...)"` form
    # swallowed that exit, so a broken manifest ran zero assertions and the
    # test reported success instead of failing loud.
    names="$(TCR_LOCAL_ROOT="$REPO_ROOT" tcr_our_plugin_names)"
    names_rc=$?
    if [ "$names_rc" -eq 0 ] && [ -n "$names" ]; then
        while IFS= read -r name; do
            [ -n "$name" ] && assert_contains "installs $name@my-dotclaude" "$setup" "claude plugin install $name@my-dotclaude"
        done <<< "$names"
    else
        no "tcr_our_plugin_names returned a plugin list to check AGENT_SETUP.md against (rc=$names_rc)"
    fi
else
    no "AGENT_SETUP.md missing at $AGENT_SETUP_FILE"
fi

# ---------------------------------------------------------------------------
# Round-2 medium (issue #84): pin the contract the fix above relies on —
# tcr_our_plugin_names's tcr_die runs inside a $(...) subshell, so a broken
# manifest must surface as a non-zero $? on the captured assignment, not as
# an empty-but-"successful" list (which the old `done <<< "$(...)"` form
# above silently treated as zero plugins / zero assertions / a passing test).
# ---------------------------------------------------------------------------
echo "test: an unparseable marketplace manifest fails tcr_our_plugin_names loud, not empty"
BROKEN_ROOT="$WORK/broken-manifest-root"
mkdir -p "$BROKEN_ROOT/.claude-plugin"
printf 'not json' > "$BROKEN_ROOT/.claude-plugin/marketplace.json"
source "$REPO_ROOT/setup/lib/common.sh"
broken_names="$(TCR_LOCAL_ROOT="$BROKEN_ROOT" tcr_our_plugin_names 2>/dev/null)"
broken_rc=$?
if [ "$broken_rc" -ne 0 ] && [ -z "$broken_names" ]; then
    ok "unparseable manifest: non-zero exit, no plugin names"
else
    no "unparseable manifest: non-zero exit, no plugin names (rc=$broken_rc, names='$broken_names')"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
