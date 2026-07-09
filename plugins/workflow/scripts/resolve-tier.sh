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
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
CONFIG="$PLUGIN_ROOT/model-tiers.json"

# cell <tier> <role> <field> — print the cell's string value, or nothing on any
# miss. Reads the shipped one-role-per-line format; anything it can't parse
# yields empty, which the validation below turns into the standard fallback
# (fail-open). A cell is scoped to its tier: `in_tier` is set only when the
# requested tier's key opens and cleared at that tier's closing brace, so a role
# name shared across tiers never leaks the wrong tier's value.
cell() {
    awk -v tier="$1" -v role="$2" -v field="$3" '
        $0 ~ "\"" tier "\"[[:space:]]*:" { in_tier = 1; next }
        in_tier && /^[[:space:]]*}/      { in_tier = 0 }
        in_tier && $0 ~ "\"" role "\"[[:space:]]*:" {
            if (match($0, "\"" field "\"[[:space:]]*:[[:space:]]*\"[^\"]*\"")) {
                v = substr($0, RSTART, RLENGTH)
                sub(/^.*:[[:space:]]*"/, "", v); sub(/"$/, "", v)
                print v
            }
            exit
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
