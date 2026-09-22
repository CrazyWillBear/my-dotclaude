#!/usr/bin/env bash
#
# resolve-tier.sh — resolve a complexity tier to its {model,effort,backend} roster.
#
# Usage: bash resolve-tier.sh <tier> [attempt]   # tier ∈ trivial | standard | complex
#
# Reads the roster table from, in order:
#   ${RESOLVE_TIER_ROOT}/model-tiers.json       test seam; when set, nothing else is consulted
#   ${CLAUDE_CONFIG_DIR:-~/.claude}/model-tiers.json   the USER's table, if the file exists
#   <script-dir>/../model-tiers.json            the SHIPPED table
#
# THE IMPLEMENTER CELL IS AN ORDERED CHAIN (#104). A tier's `implementer` is either one
# {model,effort,backend} object (a chain of one) or a JSON array of them, cheapest first.
# `attempt` (default 0) selects the chain position: the orchestrator spawns attempt 0 and,
# when escalate.sh says the worker is out of its depth, respawns at attempt+1 on the same
# worktree. `planner` and `reviewer` are always single cells — an array there is a miss.
#
# Contract: prints EXACTLY twelve key=value lines to stdout and ALWAYS exits 0 —
#   tier=<tier>
#   planner_model=<m>      planner_effort=<e>      planner_backend=<b>
#   implementer_model=<m>  implementer_effort=<e>  implementer_backend=<b>
#   implementer_attempt=<attempt>   implementer_chain=<chain length>
#   reviewer_model=<m>     reviewer_effort=<e>     reviewer_backend=<b>
# Callers (classify-task, /orchestrate, spawn.sh) route the planner/implementer/
# reviewer models, efforts AND backends off these lines, so a roster must always
# come back. `implementer_chain` is how a caller knows attempt+1 exists.
#
# This script ships in the plugin and runs in-session on user machines, so it
# depends on nothing beyond POSIX awk — the config is a format we fully control,
# and a small awk extractor plus strict value-set validation of every cell give
# the same safety a JSON library would, without adding a runtime dependency.
#
# Each cell's backend is claude or codex, cross-validated against its own model:
# backend claude takes a model in {haiku,sonnet,opus,fable}; backend codex takes a
# model in {gpt-5.6-luna,gpt-5.6-terra,gpt-5.6-sol}. Either paired with the other's
# model — or any other backend value — is a miss like any other bad cell. Sonnet is
# gone from the shipped table but stays VALID so a user table can still name it.
#
# Fallback (single WARN to stderr, then the hardcoded claude-only roster to stdout,
# exit 0) on ANY of: a missing/unreadable config; unparseable content (including
# a wrong-shape config); a structurally incomplete config (any of the 3 tiers ×
# 3 roles missing a model/effort/backend, an empty chain, or a chain cell that is
# bad); a model that does not match its own backend's allowed set; an effort
# outside {low,medium,high,xhigh,max}; a backend outside {claude,codex}; a
# missing/unknown tier argument; or an attempt outside the tier's chain (its own
# WARN, naming the attempt and the chain length, so a caller bug is loud). Never
# exits non-zero and never writes anything to stderr but the one WARN line. The
# fallback roster NEVER names a codex model: the shipped table does, and a broken
# user table must not be allowed to depend on a CLI that may not be installed.

set -uo pipefail

TIER="${1:-}"
ATTEMPT="${2:-0}"

# The one hardcoded roster in the script — the fallback source of truth, INDEPENDENT of
# the shipped config (see the header above): opus medium in every role, claude only, a
# chain of one. A codex model here would make a broken table fail on machines without codex.
fallback() {
    printf '%s\n' "${1:-WARN: model-tiers.json missing or invalid — falling back to standard tier defaults}" >&2
    printf 'tier=standard\n'
    printf 'planner_model=opus\n'
    printf 'planner_effort=medium\n'
    printf 'planner_backend=claude\n'
    printf 'implementer_model=opus\n'
    printf 'implementer_effort=medium\n'
    printf 'implementer_backend=claude\n'
    printf 'implementer_attempt=0\n'
    printf 'implementer_chain=1\n'
    printf 'reviewer_model=opus\n'
    printf 'reviewer_effort=medium\n'
    printf 'reviewer_backend=claude\n'
    exit 0
}

# ---------------------------------------------------------------------------
# Locate the plugin root and the config (mirrors scripts/check-update.sh).
# ---------------------------------------------------------------------------
# Not CLAUDE_PLUGIN_ROOT: other plugins call this script, and theirs is the caller's root.
PLUGIN_ROOT="${RESOLVE_TIER_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)"
fi
CONFIG="$PLUGIN_ROOT/model-tiers.json"

# A USER table wins over the shipped one. The shipped table is codex-first (#104); a machine
# without the codex CLI writes its own claude-only table instead of editing a plugin file that
# the next kit update overwrites (spawn.sh refuses a codex spawn with no CLI and says so).
#
# Only when RESOLVE_TIER_ROOT is UNSET: that variable is the test seam and stays authoritative,
# so a test asking for a specific table never silently reads the developer's real ~/.claude one.
#
# EXISTENCE is the whole test. A user table that is present but malformed takes the same fallback
# any bad config takes (one WARN + the hardcoded claude standard roster) rather than quietly
# reverting to the shipped table — a typo should be loud, not invisible.
if [ -z "${RESOLVE_TIER_ROOT:-}" ]; then
    # $HOME is NOT guaranteed: systemd units, `env -i` and some hook harnesses run without
    # it, and an unbound expansion under `set -u` would abort with no roster at all —
    # breaking the "always exits 0" contract both callers depend on (spawn.sh:181).
    USER_CONFIG="${CLAUDE_CONFIG_DIR:-${HOME:-/nonexistent}/.claude}/model-tiers.json"
    [ -f "$USER_CONFIG" ] && CONFIG="$USER_CONFIG"
fi

# cell <tier> <role> <field> [idx] — print the cell's string value, or nothing on any
# miss. The whole config is read into one buffer and parsed structurally, so
# layout does not matter. The tier's object is bounded by a STRING-AWARE
# bracket-depth scan (findclose): a "{" or "}" inside a JSON string value is
# skipped, so a later tier can never bleed in — however the file is wrapped and
# whatever the string values contain. The role key is matched only inside that
# tier's block. A role's value is either ONE object or an ARRAY of objects (the
# implementer chain, #104): an array is bounded by the same scan on "[" / "]",
# split into its objects, and `idx` picks one; an object answers only idx 0. A
# cell that itself contains a nested object is treated as a miss (hasbrace), so
# the flat field match only ever reads the cell's own top-level model/effort.
# Anything the scanner cannot locate (missing tier/role/field, wrong shape,
# nested object, idx past the end, non-JSON) yields empty, which the validation
# below turns into the fallback (fail-open). Since [[:space:]] matches newlines
# in awk, a "tier": spread across lines before its { parses too.
#
# chainlen <tier> <role> — the number of cells: 1 for an object, N for an array
# (0 for an empty array), nothing on a miss. kind <tier> <role> — `obj` or `arr`.
cell()     { extract "$1" "$2" field "$3" "${4:-0}"; }
chainlen() { extract "$1" "$2" len "" 0; }
kind()     { extract "$1" "$2" kind "" 0; }
extract() {
    awk -v tier="$1" -v role="$2" -v mode="$3" -v field="$4" -v idx="$5" '
        # Index of the close bracket matching the open one we are already inside
        # (depth starts at 1, just past it), skipping any bracket inside a JSON
        # string. `o`/`c` are the bracket pair. 0 if they never balance.
        function findclose(s, o, c,   depth, instr, esc, i, n, ch) {
            depth = 1; instr = 0; esc = 0; n = length(s)
            for (i = 1; i <= n; i++) {
                ch = substr(s, i, 1)
                if (instr) {
                    if (esc)             esc = 0
                    else if (ch == "\\") esc = 1
                    else if (ch == "\"") instr = 0
                } else if (ch == "\"")   instr = 1
                else if (ch == o)        depth++
                else if (ch == c)      { depth--; if (depth == 0) return i }
            }
            return 0
        }
        # 1 if s holds a "{" outside any string — a nested object in an
        # already-extracted cell, which the flat field match cannot read safely.
        function hasbrace(s,   instr, esc, i, n, ch) {
            instr = 0; esc = 0; n = length(s)
            for (i = 1; i <= n; i++) {
                ch = substr(s, i, 1)
                if (instr) {
                    if (esc)             esc = 0
                    else if (ch == "\\") esc = 1
                    else if (ch == "\"") instr = 0
                } else if (ch == "\"")   instr = 1
                else if (ch == "{")      return 1
            }
            return 0
        }
        { buf = buf $0 "\n" }
        END {
            if (!match(buf, "\"" tier "\"[[:space:]]*:[[:space:]]*\\{")) exit
            rest = substr(buf, RSTART + RLENGTH)
            end = findclose(rest, "{", "}")
            if (end == 0) exit
            block = substr(rest, 1, end - 1)
            if (!match(block, "\"" role "\"[[:space:]]*:[[:space:]]*[\\{\\[]")) exit
            open = substr(block, RSTART + RLENGTH - 1, 1)
            rb = substr(block, RSTART + RLENGTH)
            n = 0
            if (open == "{") {
                rend = findclose(rb, "{", "}")
                if (rend == 0) exit
                cells[0] = substr(rb, 1, rend - 1); n = 1
                if (mode == "kind") { print "obj"; exit }
            } else {
                aend = findclose(rb, "[", "]")
                if (aend == 0) exit
                arr = substr(rb, 1, aend - 1)
                if (mode == "kind") { print "arr"; exit }
                # Every "{" at depth 0 of the array opens one cell; the array
                # body is chain cells only, so nothing else may sit between them.
                while (match(arr, "\\{")) {
                    body = substr(arr, RSTART + 1)
                    cend = findclose(body, "{", "}")
                    if (cend == 0) exit
                    cells[n++] = substr(body, 1, cend - 1)
                    arr = substr(body, cend + 1)
                }
            }
            if (mode == "len") { print n; exit }
            if (idx !~ /^[0-9]+$/ || idx + 0 >= n) exit
            c = cells[idx + 0]
            if (hasbrace(c)) exit
            if (match(c, "\"" field "\"[[:space:]]*:[[:space:]]*\"[^\"]*\"")) {
                v = substr(c, RSTART, RLENGTH)
                sub(/^.*:[[:space:]]*"/, "", v); sub(/"$/, "", v)
                print v
            }
        }
    ' "$CONFIG" 2>/dev/null
}

# Config must exist.
[ -f "$CONFIG" ] || fallback

# Structural + value validation: EVERY cell of every tier×role — every chain position
# included — must carry an effort in {low,medium,high,xhigh,max}, a backend of claude or
# codex, and a model from THAT backend's set (haiku,sonnet,opus,fable for claude;
# gpt-5.6-luna,gpt-5.6-terra,gpt-5.6-sol for codex). Any miss (absent cell, empty chain,
# an array where a single cell is required, unparseable content, wrong shape, out-of-set
# value, or a model/backend mismatch) → fallback.
for t in trivial standard complex; do
    for r in planner implementer reviewer; do
        n="$(chainlen "$t" "$r")"
        case "$n" in ''|0|*[!0-9]*) fallback ;; esac
        [ "$r" = implementer ] || [ "$(kind "$t" "$r")" = obj ] || fallback
        i=0
        while [ "$i" -lt "$n" ]; do
            m="$(cell "$t" "$r" model "$i")"
            e="$(cell "$t" "$r" effort "$i")"
            b="$(cell "$t" "$r" backend "$i")"
            case "$e" in
                low|medium|high|xhigh|max) ;;
                *) fallback ;;
            esac
            case "$b" in
                claude)
                    case "$m" in
                        haiku|sonnet|opus|fable) ;;
                        *) fallback ;;
                    esac
                    ;;
                codex)
                    case "$m" in
                        gpt-5.6-luna|gpt-5.6-terra|gpt-5.6-sol) ;;
                        *) fallback ;;
                    esac
                    ;;
                *) fallback ;;
            esac
            i=$((i + 1))
        done
    done
done

# The requested tier must be one of the three known tiers.
case "$TIER" in
    trivial|standard|complex) ;;
    *) fallback ;;
esac

# The attempt must sit inside the tier's chain. Past the top is a CALLER bug (the
# orchestrator drains instead of respawning there), so its WARN names the numbers.
CHAIN="$(chainlen "$TIER" implementer)"
case "$ATTEMPT" in ''|*[!0-9]*) fallback "WARN: attempt '$ATTEMPT' is not a number — falling back to standard tier defaults" ;; esac
[ "$ATTEMPT" -lt "$CHAIN" ] || fallback "WARN: attempt $ATTEMPT is past the top of tier $TIER's implementer chain (length $CHAIN) — falling back to standard tier defaults"

# Emit the confirmed roster for the requested tier.
printf 'tier=%s\n' "$TIER"
for r in planner implementer reviewer; do
    i=0; [ "$r" = implementer ] && i="$ATTEMPT"
    m="$(cell "$TIER" "$r" model "$i")"
    e="$(cell "$TIER" "$r" effort "$i")"
    b="$(cell "$TIER" "$r" backend "$i")"
    printf '%s_model=%s\n'   "$r" "$m"
    printf '%s_effort=%s\n'  "$r" "$e"
    printf '%s_backend=%s\n' "$r" "$b"
    if [ "$r" = implementer ]; then
        printf 'implementer_attempt=%s\n' "$ATTEMPT"
        printf 'implementer_chain=%s\n'   "$CHAIN"
    fi
done
