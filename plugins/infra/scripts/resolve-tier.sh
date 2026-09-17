#!/usr/bin/env bash
#
# resolve-tier.sh — resolve a complexity tier to its {model,effort,backend} roster.
#
# Usage: bash resolve-tier.sh <tier>          # tier ∈ trivial | standard | complex
#
# Reads the roster table from, in order:
#   ${RESOLVE_TIER_ROOT}/model-tiers.json       test seam; when set, nothing else is consulted
#   ${CLAUDE_CONFIG_DIR:-~/.claude}/model-tiers.json   the USER's table, if the file exists
#   <script-dir>/../model-tiers.json            the SHIPPED table (claude in every cell)
#
# Contract: prints EXACTLY ten key=value lines to stdout and ALWAYS exits 0 —
#   tier=<tier>
#   planner_model=<m>      planner_effort=<e>      planner_backend=<b>
#   implementer_model=<m>  implementer_effort=<e>  implementer_backend=<b>
#   reviewer_model=<m>     reviewer_effort=<e>     reviewer_backend=<b>
# Callers (classify-task, /orchestrate) route the planner/implementer/
# reviewer models, efforts AND backends off these lines, so a roster must
# always come back.
#
# This script ships in the plugin and runs in-session on user machines, so it
# depends on nothing beyond POSIX awk — the config is a format we fully control,
# and a small awk extractor plus strict value-set validation of all 9 cells give
# the same safety a JSON library would, without adding a runtime dependency.
#
# Each cell's backend is claude or codex, cross-validated against its own model:
# backend claude takes a model in {haiku,sonnet,opus,fable}; backend codex takes a
# model in {gpt-5.6-luna,gpt-5.6-terra,gpt-5.6-sol}. Either paired with the other's
# model — or any other backend value — is a miss like any other bad cell.
#
# Fallback (single WARN to stderr, then the hardcoded standard roster to stdout,
# exit 0) on ANY of: a missing/unreadable config; unparseable content (including
# a wrong-shape config); a structurally incomplete config (any of the 3 tiers ×
# 3 roles missing a model/effort/backend); a model that does not match its own
# backend's allowed set; an effort outside {low,medium,high,xhigh,max}; a backend
# outside {claude,codex}; or a missing/unknown tier argument. Never exits
# non-zero and never writes anything to stderr but the one WARN line. The
# fallback roster is the hardcoded claude standard roster, always — it does not
# track whatever the shipped config's standard tier resolves to, so a codex
# rollout in the config never changes what a broken config falls back to.

set -uo pipefail

TIER="${1:-}"

# The one hardcoded roster in the script — the fallback source of truth, INDEPENDENT of
# whatever the shipped config's standard tier resolves to (see the header above): a config
# rollout that changes standard's values never changes what a broken config falls back to.
fallback() {
    printf 'WARN: model-tiers.json missing or invalid — falling back to standard tier defaults\n' >&2
    printf 'tier=standard\n'
    printf 'planner_model=sonnet\n'
    printf 'planner_effort=high\n'
    printf 'planner_backend=claude\n'
    printf 'implementer_model=sonnet\n'
    printf 'implementer_effort=max\n'
    printf 'implementer_backend=claude\n'
    printf 'reviewer_model=opus\n'
    printf 'reviewer_effort=high\n'
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

# A USER table wins over the shipped one. The shipped table is claude in every cell so a fresh
# install works with no codex CLI; anyone who wants codex workers writes their own table instead
# of editing a plugin file that the next kit update overwrites.
#
# Only when RESOLVE_TIER_ROOT is UNSET: that variable is the test seam and stays authoritative,
# so a test asking for a specific table never silently reads the developer's real ~/.claude one.
#
# EXISTENCE is the whole test. A user table that is present but malformed takes the same fallback
# any bad config takes (one WARN + the hardcoded claude standard roster) rather than quietly
# reverting to the shipped table — a typo should be loud, not invisible.
if [ -z "${RESOLVE_TIER_ROOT:-}" ]; then
    USER_CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/model-tiers.json"
    [ -f "$USER_CONFIG" ] && CONFIG="$USER_CONFIG"
fi

# cell <tier> <role> <field> — print the cell's string value, or nothing on any
# miss. The whole config is read into one buffer and parsed structurally, so
# layout does not matter. The tier's object is bounded by a STRING-AWARE
# brace-depth scan (findclose): a "{" or "}" inside a JSON string value is
# skipped, so a later tier can never bleed in — however the file is wrapped and
# whatever the string values contain. The role key is matched only inside that
# tier's block, and the role's own {...} is bounded by the same string-aware
# scan; a role body that itself contains a nested object is treated as a miss
# (hasbrace), so the flat field match only ever reads the role's own top-level
# model/effort. Anything the scanner cannot locate (missing tier/role/field,
# wrong shape, nested role object, non-JSON) yields empty, which the validation
# below turns into the standard fallback (fail-open). Since [[:space:]] matches
# newlines in awk, a "tier": spread across lines before its { parses too.
cell() {
    awk -v tier="$1" -v role="$2" -v field="$3" '
        # Index of the "}" that closes the object we are already inside (depth
        # starts at 1, just past its opening "{"), skipping any brace that falls
        # inside a JSON string. 0 if the braces never balance.
        function findclose(s,   depth, instr, esc, i, n, c) {
            depth = 1; instr = 0; esc = 0; n = length(s)
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (instr) {
                    if (esc)            esc = 0
                    else if (c == "\\") esc = 1
                    else if (c == "\"") instr = 0
                } else if (c == "\"")   instr = 1
                else if (c == "{")      depth++
                else if (c == "}")    { depth--; if (depth == 0) return i }
            }
            return 0
        }
        # 1 if s holds a "{" outside any string — i.e. a nested object in an
        # already-extracted role body, which the flat field match cannot read
        # safely, so we treat it as a miss (fail-open).
        function hasbrace(s,   instr, esc, i, n, c) {
            instr = 0; esc = 0; n = length(s)
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (instr) {
                    if (esc)            esc = 0
                    else if (c == "\\") esc = 1
                    else if (c == "\"") instr = 0
                } else if (c == "\"")   instr = 1
                else if (c == "{")      return 1
            }
            return 0
        }
        { buf = buf $0 "\n" }
        END {
            if (!match(buf, "\"" tier "\"[[:space:]]*:[[:space:]]*\\{")) exit
            rest = substr(buf, RSTART + RLENGTH)
            end = findclose(rest)
            if (end == 0) exit
            block = substr(rest, 1, end - 1)
            if (!match(block, "\"" role "\"[[:space:]]*:[[:space:]]*\\{")) exit
            rb = substr(block, RSTART + RLENGTH)
            rend = findclose(rb)
            if (rend == 0) exit
            rb = substr(rb, 1, rend - 1)
            if (hasbrace(rb)) exit
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

# Structural + value validation: every one of the 9 tier×role cells must carry an
# effort in {low,medium,high,xhigh,max}, a backend of claude or codex, and a model
# from THAT backend's set (haiku,sonnet,opus,fable for claude; gpt-5.6-luna,
# gpt-5.6-terra,gpt-5.6-sol for codex). Any miss (absent cell, unparseable content,
# wrong shape, out-of-set value, or a model/backend mismatch) → fallback.
for t in trivial standard complex; do
    for r in planner implementer reviewer; do
        m="$(cell "$t" "$r" model)"
        e="$(cell "$t" "$r" effort)"
        b="$(cell "$t" "$r" backend)"
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
    b="$(cell "$TIER" "$r" backend)"
    printf '%s_model=%s\n'   "$r" "$m"
    printf '%s_effort=%s\n'  "$r" "$e"
    printf '%s_backend=%s\n' "$r" "$b"
done
