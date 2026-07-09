#!/usr/bin/env bash
#
# resolve-tier.sh — resolve a complexity tier to its {model,effort} roster.
#
# Usage: bash resolve-tier.sh <tier>          # tier ∈ trivial | standard | complex
#
# Reads the roster table from:
#   ${CLAUDE_PLUGIN_ROOT}/model-tiers.json     (falls back to <script-dir>/..)
#
# Contract: prints EXACTLY seven key=value lines to stdout and ALWAYS exits 0 —
#   tier=<tier>
#   planner_model=<m>      planner_effort=<e>
#   implementer_model=<m>  implementer_effort=<e>
#   reviewer_model=<m>     reviewer_effort=<e>
# Callers (classify-task, /pipeline, /orchestrate) route the planner/implementer/
# reviewer models AND efforts off these lines, so a roster must always come back.
#
# This script ships in the plugin and runs in-session on user machines, so it
# depends on nothing beyond POSIX awk — the config is a format we fully control,
# and a small awk extractor plus strict value-set validation of all 9 cells give
# the same safety a JSON library would, without adding a runtime dependency.
#
# Fallback (single WARN to stderr, then the hardcoded standard roster to stdout,
# exit 0) on ANY of: a missing/unreadable config; unparseable content (including
# a wrong-shape config); a structurally incomplete config (any of the 3 tiers ×
# 3 roles missing a model/effort); a model outside {sonnet,opus,fable}; an effort
# outside {low,medium,high,xhigh,max}; or a missing/unknown tier argument. Never
# exits non-zero and never writes anything to stderr but the one WARN line.

set -uo pipefail

TIER="${1:-}"

# The one hardcoded roster in the script — the fallback source of truth. A
# missing/broken-config fallback is byte-identical to resolving `standard` from a
# healthy shipped config (a test pins this lockstep).
fallback() {
    printf 'WARN: model-tiers.json missing or invalid — falling back to standard tier defaults\n' >&2
    printf 'tier=standard\n'
    printf 'planner_model=opus\n'
    printf 'planner_effort=high\n'
    printf 'implementer_model=sonnet\n'
    printf 'implementer_effort=high\n'
    printf 'reviewer_model=opus\n'
    printf 'reviewer_effort=high\n'
    exit 0
}

# ---------------------------------------------------------------------------
# Locate the plugin root and the config (mirrors scripts/check-update.sh).
# ---------------------------------------------------------------------------
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" 2>/dev/null
    PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" 2>/dev/null
fi
CONFIG="$PLUGIN_ROOT/model-tiers.json"

# cell <tier> <role> <field> — print the cell's string value, or nothing on any
# miss. The whole config is read into one buffer, then parsed structurally rather
# than line-by-line, so layout does not matter: the tier's object is bounded by a
# brace-depth scan (a later tier can never bleed in, however the file is wrapped),
# the role key is matched only inside that tier's block, and the field is matched
# only inside the role's own {...}. One-line, multi-line, and mixed formattings
# resolve identically. Anything the scanner cannot locate (missing tier/role/
# field, wrong shape, non-JSON) yields empty, which the validation below turns
# into the standard fallback (fail-open). Since [[:space:]] matches newlines in
# awk, a "tier": spread across lines before its { parses too.
cell() {
    awk -v tier="$1" -v role="$2" -v field="$3" '
        { buf = buf $0 "\n" }
        END {
            if (!match(buf, "\"" tier "\"[[:space:]]*:[[:space:]]*\\{")) exit
            rest = substr(buf, RSTART + RLENGTH)
            depth = 1; end = 0; n = length(rest)
            for (i = 1; i <= n; i++) {
                c = substr(rest, i, 1)
                if (c == "{") depth++
                else if (c == "}") { depth--; if (depth == 0) { end = i; break } }
            }
            if (end == 0) exit
            block = substr(rest, 1, end - 1)
            if (!match(block, "\"" role "\"[[:space:]]*:[[:space:]]*\\{")) exit
            rb = substr(block, RSTART + RLENGTH)
            if (!match(rb, /}/)) exit
            rb = substr(rb, 1, RSTART - 1)
            if (match(rb, "\"" field "\"[[:space:]]*:[[:space:]]*\"[^\"]*\"")) {
                v = substr(rb, RSTART, RLENGTH)
                sub(/^.*:[[:space:]]*"/, "", v); sub(/"$/, "", v)
                print v
            }
        }
    ' "$CONFIG" 2>/dev/null
}

# Config must exist.
[ -f "$CONFIG" ] || fallback

# Structural + value validation: every one of the 9 tier×role cells must carry a
# model in {sonnet,opus,fable} and an effort in {low,medium,high,xhigh,max}. Any
# miss (absent cell, unparseable content, wrong shape, out-of-set value) → fallback.
for t in trivial standard complex; do
    for r in planner implementer reviewer; do
        m="$(cell "$t" "$r" model)"
        e="$(cell "$t" "$r" effort)"
        case "$m" in
            sonnet|opus|fable) ;;
            *) fallback ;;
        esac
        case "$e" in
            low|medium|high|xhigh|max) ;;
            *) fallback ;;
        esac
    done
done

# The requested tier must be one of the three known tiers.
case "$TIER" in
    trivial|standard|complex) ;;
    *) fallback ;;
esac

# Emit the confirmed roster for the requested tier.
printf 'tier=%s\n' "$TIER"
for r in planner implementer reviewer; do
    m="$(cell "$TIER" "$r" model)"
    e="$(cell "$TIER" "$r" effort)"
    printf '%s_model=%s\n'  "$r" "$m"
    printf '%s_effort=%s\n' "$r" "$e"
done
