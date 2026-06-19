#!/usr/bin/env bash
#
# notify-update.sh — SessionStart hook that surfaces an available kit update.
#
# Wired on SessionStart in plugins/personal-tools/hooks/hooks.json. On session start it
# checks whether a newer kit release exists and, if so, prints a short notice
# naming the new version and telling the user to run /update-kit.
#
# It REUSES scripts/check-update.sh for the whole version check: reading the
# installed version from plugin.json, querying the GitHub Releases API, and the
# numeric semver compare. This hook never re-implements that logic — it runs
# check-update.sh and acts on its single line of output:
#   "vX.Y.Z available — run /update-kit to upgrade"  -> newer release exists
#   "kit is up to date (vX.Y.Z)"                     -> up to date
#   (empty)                                          -> fail-open / no info
#
# Throttle: check-update.sh hits the network, so we cache its last result + a
# timestamp under a cache dir (default ${XDG_CACHE_HOME:-~/.cache}/my-dotclaude,
# overridable via NOTIFY_UPDATE_CACHE_DIR for tests). Within the throttle window
# (~24h, NOTIFY_UPDATE_TTL_SECONDS) we replay the cached result and do NOT hit the
# API again. A stale or missing cache triggers a fresh check.
#
# Fail open: SessionStart hooks run on EVERY session, so any error — missing
# script, network failure, unwritable cache, garbage response — must exit 0 with
# no alarming output and never block the session. The cached "available" notice is
# only ever emitted as a non-blocking systemMessage.
#
# Usage (hook): receives the SessionStart JSON payload on stdin (ignored).

set -uo pipefail

# Drain stdin so the hook payload can't wedge a pipe; we don't need its contents.
cat >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Locate the plugin root + the reused check-update.sh
# ---------------------------------------------------------------------------
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
CHECK_UPDATE="$PLUGIN_ROOT/scripts/check-update.sh"

# Nothing to do (and never error) if the reused checker isn't present.
[ -f "$CHECK_UPDATE" ] || exit 0

# ---------------------------------------------------------------------------
# Throttle config + cache location
# ---------------------------------------------------------------------------
TTL="${NOTIFY_UPDATE_TTL_SECONDS:-86400}"   # ~24h default
CACHE_DIR="${NOTIFY_UPDATE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/my-dotclaude}"
CACHE_FILE="$CACHE_DIR/last-check.json"

now="$(date +%s 2>/dev/null)" || now=""

# cache_mtime: epoch seconds of the cache file, or empty if absent/unstattable.
cache_mtime() {
    [ -f "$CACHE_FILE" ] || return 1
    stat -c %Y "$CACHE_FILE" 2>/dev/null \
        || stat -f %m "$CACHE_FILE" 2>/dev/null   # BSD/macOS fallback
}

# cache_fresh: succeeds when the cache exists and is younger than the TTL.
cache_fresh() {
    local m
    m="$(cache_mtime)" || return 1
    [ -n "$now" ] && [ -n "$m" ] || return 1
    [ "$(( now - m ))" -lt "$TTL" ]
}

# ---------------------------------------------------------------------------
# Obtain the checker's result line: replay a fresh cache, else run check-update.sh
# (the only path that touches the network) and cache the result.
# ---------------------------------------------------------------------------
result=""
if cache_fresh; then
    # Replay the cached result without hitting the API again (throttle respected).
    result="$(cat "$CACHE_FILE" 2>/dev/null)" || result=""
else
    # Stale or missing cache -> run the reused checker (fails open, prints a line).
    result="$(bash "$CHECK_UPDATE" 2>/dev/null)" || result=""
    # Persist the result + refresh the timestamp so the next session is throttled.
    # Only cache a NON-EMPTY result: an empty line means the checker failed open
    # (network/parse error), and caching it would suppress every check for the
    # whole TTL on a single transient blip. Leaving the cache untouched lets the
    # next session retry. An unwritable cache must not error — fail open.
    if [ -n "$result" ] && mkdir -p "$CACHE_DIR" 2>/dev/null; then
        printf '%s\n' "$result" > "$CACHE_FILE" 2>/dev/null || true
    fi
fi

# ---------------------------------------------------------------------------
# Surface a notice ONLY when the checker reports a newer release. Up-to-date,
# empty (fail-open), or any other line stays silent.
# ---------------------------------------------------------------------------
case "$result" in
    *available*"/update-kit"*)
        # Non-blocking systemMessage so the session is never wedged.
        msg="personal-tools: kit update available — $result"
        python3 - "$msg" "$result" <<'PY' 2>/dev/null && exit 0
import json, sys
msg, result = sys.argv[1], sys.argv[2]
sys.stdout.write(json.dumps({
    "systemMessage": msg,
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": (
            "A newer my-dotclaude kit release is available (" + result
            + "). Tell the user they can run /update-kit to upgrade."
        ),
    },
}))
PY
        # python3 missing or failed -> still surface a plain-text notice (fail open).
        printf '%s\n' "$msg"
        ;;
    *)
        : # up to date, empty, or unrecognized -> stay silent
        ;;
esac

exit 0
