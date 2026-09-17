#!/usr/bin/env bash
#
# Tests for scripts/resolve-tier.sh — the tier→roster resolver (central mechanism).
#
# Black-box, exercised for REAL: every assertion drives the shipped resolver
# end-to-end — against the REAL shipped config (the BASH_SOURCE fallback resolves
# the plugin root) and against REAL temp configs we write into a tmpdir pointed
# at by RESOLVE_TIER_ROOT. There is NO inlined/stubbed roster table anywhere in
# this test; the roster only ever comes out of the script reading a config.
#
#   1. Script exists + is executable, and carries no `jq` dependency (the plugin
#      runtime must not require jq — it parses the config with awk instead).
#   2. Each shipped tier resolves to its full {model,effort,backend} roster;
#      stderr empty (no WARN); exit 0; exactly ten key=value lines. A codex
#      cell's model is one of gpt-5.6-luna/terra/sol; a claude cell's is one of
#      haiku/sonnet/opus/fable.
#   3. Missing config → the single WARN line on stderr (exact equality) + the
#      standard roster on stdout, backend=claude on every role; exit 0.
#   4. Malformed configs (invalid JSON, a missing role, a bad model, a bad
#      effort, a bad backend, a backend/model mismatch in either direction —
#      all literal heredocs, no jq transforms) and a wrong-JSON-type config each
#      → the exact WARN line + standard fallback; exit 0. The wrong-type case
#      absorbs #55's intent (a wrong shape leaks nothing but the one WARN line).
#      Also covers a brace-in-a-string tier value paired with a missing role, and
#      a role object holding a nested object — both must fall back rather than
#      return a chimera roster or nested values (#70).
#   5. Reformatted-but-valid configs (a mixed single-line tier, two roles on one
#      line, and a fully minified config) resolve to the correct roster with no
#      WARN — the extractor is layout-independent, not fooled by whitespace.
#   6. Bad/missing tier arg against a good shipped config → the exact WARN line +
#      standard fallback; exit 0.
#   7. The shipped config is structurally complete: 9 tier×role cells resolve
#      through the REAL helper to a backend of claude paired with a model in
#      {haiku,sonnet,opus,fable}, or codex paired with a model in
#      {gpt-5.6-luna,gpt-5.6-terra,gpt-5.6-sol}, and an effort in
#      {low,medium,high,xhigh,max} — checked via the helper, not a re-parse.
#   8. Fallback is pinned literally to the hardcoded claude standard roster
#      (sonnet/sonnet/opus, backend=claude on every role) — independent of
#      whatever the shipped config's standard tier resolves to, so a future
#      codex rollout in the config can never change what a broken config
#      falls back to.
#   9. A `cd` failure inside the BASH_SOURCE fallback (the SCRIPT_DIR/PLUGIN_ROOT
#      lines, exercised when RESOLVE_TIER_ROOT is unset) is fully suppressed —
#      stderr is EXACTLY the one WARN line, never that plus a leaked
#      `cd: ...: No such file or directory`. Reproduced by running the REAL,
#      unmodified fallback lines against a directory that is removed out from
#      under them mid-run (a synchronization barrier line is spliced in only to
#      pause execution at that exact point — the tested lines themselves are
#      byte-identical to the shipped script).
#
# Run: bash plugins/infra/tests/test_resolve-tier.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/resolve-tier.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }

# val <output> <key> — echo the value of a single key=value line from stdout.
val() { printf '%s\n' "$1" | grep "^$2=" | head -n1 | cut -d= -f2-; }

# The single warning the resolver is allowed to emit — asserted for EXACT
# equality everywhere a fallback fires (nothing else may ever reach stderr).
WARN='WARN: model-tiers.json missing or invalid — falling back to standard tier defaults'

# write_cfg <dir> — read a config heredoc from stdin into <dir>/model-tiers.json.
write_cfg() { mkdir -p "$1"; cat > "$1/model-tiers.json"; }

# A CLAUDE_CONFIG_DIR with no model-tiers.json in it. Every run below points at this, so the
# shipped-table assertions cannot start reading the developer's OWN ~/.claude/model-tiers.json
# and passing or failing by machine. The user-override tests opt out of it deliberately.
NOUSERCFG="$WORK/nousercfg"
mkdir -p "$NOUSERCFG"

# run_tier <tier> [plugin_root] — run the real script and set OUT / ERR / RC.
# With no plugin_root, run with RESOLVE_TIER_ROOT unset so the BASH_SOURCE
# fallback resolves the REAL shipped config.
run_tier() {
    local tier="$1" root="${2-__REAL__}" errfile="$WORK/err"
    if [ "$root" = "__REAL__" ]; then
        OUT="$(CLAUDE_CONFIG_DIR="$NOUSERCFG" env -u RESOLVE_TIER_ROOT bash "$SCRIPT" "$tier" 2>"$errfile")"
    else
        OUT="$(CLAUDE_CONFIG_DIR="$NOUSERCFG" RESOLVE_TIER_ROOT="$root" bash "$SCRIPT" "$tier" 2>"$errfile")"
    fi
    RC=$?
    ERR="$(cat "$errfile")"
}

# ---------------------------------------------------------------------------
echo "test: script exists, is executable, and has no jq dependency"
if [ -f "$SCRIPT" ]; then ok "resolve-tier.sh present at scripts/resolve-tier.sh"; else no "resolve-tier.sh missing at $SCRIPT"; fi
if [ -x "$SCRIPT" ]; then ok "resolve-tier.sh is executable"; else no "resolve-tier.sh is not executable"; fi
SCRIPT_SRC=""
[ -f "$SCRIPT" ] && SCRIPT_SRC="$(cat "$SCRIPT")"
assert_not_contains "helper has no jq dependency" "$SCRIPT_SRC" "jq"

# ---------------------------------------------------------------------------
echo "test: shipped config resolves each tier's full roster (stderr clean, exit 0)"

run_tier trivial
assert_equals "trivial: exit 0" "$RC" "0"
assert_equals "trivial: stderr empty (no WARN)" "$ERR" ""
assert_equals "trivial: exactly 10 key=value lines" "$(printf '%s\n' "$OUT" | grep -c '=')" "10"
assert_equals "trivial: tier echoed" "$(val "$OUT" tier)" "trivial"
assert_equals "trivial: planner_model haiku" "$(val "$OUT" planner_model)" "haiku"
assert_equals "trivial: planner_effort medium" "$(val "$OUT" planner_effort)" "medium"
assert_equals "trivial: planner_backend claude" "$(val "$OUT" planner_backend)" "claude"
assert_equals "trivial: implementer_model haiku" "$(val "$OUT" implementer_model)" "haiku"
assert_equals "trivial: implementer_effort max" "$(val "$OUT" implementer_effort)" "max"
assert_equals "trivial: implementer_backend claude" "$(val "$OUT" implementer_backend)" "claude"
assert_equals "trivial: reviewer_model sonnet" "$(val "$OUT" reviewer_model)" "sonnet"
assert_equals "trivial: reviewer_effort high" "$(val "$OUT" reviewer_effort)" "high"
assert_equals "trivial: reviewer_backend claude" "$(val "$OUT" reviewer_backend)" "claude"

run_tier standard
assert_equals "standard: exit 0" "$RC" "0"
assert_equals "standard: stderr empty (no WARN)" "$ERR" ""
assert_equals "standard: tier echoed" "$(val "$OUT" tier)" "standard"
assert_equals "standard: planner_model sonnet" "$(val "$OUT" planner_model)" "sonnet"
assert_equals "standard: planner_effort high" "$(val "$OUT" planner_effort)" "high"
assert_equals "standard: planner_backend claude" "$(val "$OUT" planner_backend)" "claude"
assert_equals "standard: implementer_model sonnet" "$(val "$OUT" implementer_model)" "sonnet"
assert_equals "standard: implementer_effort max" "$(val "$OUT" implementer_effort)" "max"
assert_equals "standard: implementer_backend claude" "$(val "$OUT" implementer_backend)" "claude"
assert_equals "standard: reviewer_model opus" "$(val "$OUT" reviewer_model)" "opus"
assert_equals "standard: reviewer_effort high" "$(val "$OUT" reviewer_effort)" "high"
assert_equals "standard: reviewer_backend claude" "$(val "$OUT" reviewer_backend)" "claude"

run_tier complex
assert_equals "complex: exit 0" "$RC" "0"
assert_equals "complex: stderr empty (no WARN)" "$ERR" ""
assert_equals "complex: tier echoed" "$(val "$OUT" tier)" "complex"
assert_equals "complex: planner_model opus" "$(val "$OUT" planner_model)" "opus"
assert_equals "complex: planner_effort xhigh" "$(val "$OUT" planner_effort)" "xhigh"
assert_equals "complex: planner_backend claude" "$(val "$OUT" planner_backend)" "claude"
assert_equals "complex: implementer_model opus" "$(val "$OUT" implementer_model)" "opus"
assert_equals "complex: implementer_effort high" "$(val "$OUT" implementer_effort)" "high"
assert_equals "complex: implementer_backend claude" "$(val "$OUT" implementer_backend)" "claude"
assert_equals "complex: reviewer_model opus" "$(val "$OUT" reviewer_model)" "opus"
assert_equals "complex: reviewer_effort xhigh" "$(val "$OUT" reviewer_effort)" "xhigh"
assert_equals "complex: reviewer_backend claude" "$(val "$OUT" reviewer_backend)" "claude"

# ---------------------------------------------------------------------------
echo "test: missing config → the exact WARN line + standard roster, exit 0"
EMPTY="$WORK/empty"
mkdir -p "$EMPTY"
echo "test: a caller's CLAUDE_PLUGIN_ROOT is ignored — the table is the script's own"
OUT="$(CLAUDE_PLUGIN_ROOT="$EMPTY" env -u RESOLVE_TIER_ROOT bash "$SCRIPT" complex 2>"$WORK/err")"
assert_equals "foreign plugin root: no WARN" "$(cat "$WORK/err")" ""
assert_equals "foreign plugin root: resolves complex from the shipped table" "$(val "$OUT" tier)" "complex"

run_tier complex "$EMPTY"
assert_equals "missing: exit 0" "$RC" "0"
assert_equals "missing: stderr is exactly the WARN line" "$ERR" "$WARN"
assert_equals "missing: tier fell back to standard" "$(val "$OUT" tier)" "standard"
assert_equals "missing: planner_model sonnet" "$(val "$OUT" planner_model)" "sonnet"
assert_equals "missing: implementer_model sonnet" "$(val "$OUT" implementer_model)" "sonnet"
assert_equals "missing: reviewer_model opus" "$(val "$OUT" reviewer_model)" "opus"
assert_equals "missing: planner_effort high" "$(val "$OUT" planner_effort)" "high"
assert_equals "missing: implementer_effort max" "$(val "$OUT" implementer_effort)" "max"
assert_equals "missing: reviewer_effort high" "$(val "$OUT" reviewer_effort)" "high"
assert_equals "missing: planner_backend claude" "$(val "$OUT" planner_backend)" "claude"
assert_equals "missing: implementer_backend claude" "$(val "$OUT" implementer_backend)" "claude"
assert_equals "missing: reviewer_backend claude" "$(val "$OUT" reviewer_backend)" "claude"

# ---------------------------------------------------------------------------
echo "test: malformed configs each fall back to standard with the exact WARN line"

# (a) not JSON at all
write_cfg "$WORK/mal-a" <<'JSON'
{not json
JSON
run_tier standard "$WORK/mal-a"
assert_equals "malformed(invalid JSON): exit 0" "$RC" "0"
assert_equals "malformed(invalid JSON): exact WARN" "$ERR" "$WARN"
assert_equals "malformed(invalid JSON): standard fallback" "$(val "$OUT" tier)" "standard"

# (b) structurally incomplete — the shipped config minus standard's "reviewer" line
write_cfg "$WORK/mal-b" <<'JSON'
{
  "trivial": {
    "planner":     { "backend": "claude", "model": "sonnet", "effort": "medium" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "medium" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "high" }
  },
  "standard": {
    "planner":     { "backend": "claude", "model": "opus",   "effort": "high" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "high" }
  },
  "complex": {
    "planner":     { "backend": "claude", "model": "fable",  "effort": "xhigh" },
    "implementer": { "backend": "claude", "model": "opus",   "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "fable",  "effort": "xhigh" }
  }
}
JSON
run_tier standard "$WORK/mal-b"
assert_equals "malformed(missing role): exit 0" "$RC" "0"
assert_equals "malformed(missing role): exact WARN" "$ERR" "$WARN"
assert_equals "malformed(missing role): standard fallback" "$(val "$OUT" tier)" "standard"
assert_equals "malformed(missing role): implementer_model sonnet" "$(val "$OUT" implementer_model)" "sonnet"

# (c) a model outside the allowed set
write_cfg "$WORK/mal-c" <<'JSON'
{
  "trivial": {
    "planner":     { "backend": "claude", "model": "sonnet", "effort": "medium" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "medium" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "high" }
  },
  "standard": {
    "planner":     { "backend": "claude", "model": "gpt",    "effort": "high" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "high" }
  },
  "complex": {
    "planner":     { "backend": "claude", "model": "fable",  "effort": "xhigh" },
    "implementer": { "backend": "claude", "model": "opus",   "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "fable",  "effort": "xhigh" }
  }
}
JSON
run_tier standard "$WORK/mal-c"
assert_equals "malformed(bad model): exit 0" "$RC" "0"
assert_equals "malformed(bad model): exact WARN" "$ERR" "$WARN"
assert_equals "malformed(bad model): standard fallback" "$(val "$OUT" tier)" "standard"

# (d) an effort outside the allowed set
write_cfg "$WORK/mal-d" <<'JSON'
{
  "trivial": {
    "planner":     { "backend": "claude", "model": "sonnet", "effort": "medium" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "turbo" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "high" }
  },
  "standard": {
    "planner":     { "backend": "claude", "model": "opus",   "effort": "high" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "high" }
  },
  "complex": {
    "planner":     { "backend": "claude", "model": "fable",  "effort": "xhigh" },
    "implementer": { "backend": "claude", "model": "opus",   "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "fable",  "effort": "xhigh" }
  }
}
JSON
run_tier standard "$WORK/mal-d"
assert_equals "malformed(bad effort): exit 0" "$RC" "0"
assert_equals "malformed(bad effort): exact WARN" "$ERR" "$WARN"
assert_equals "malformed(bad effort): standard fallback" "$(val "$OUT" tier)" "standard"

# (d2) a backend outside {claude,codex}
write_cfg "$WORK/mal-d2" <<'JSON'
{
  "trivial": {
    "planner":     { "backend": "claude", "model": "sonnet", "effort": "medium" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "medium" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "high" }
  },
  "standard": {
    "planner":     { "backend": "openai", "model": "sonnet", "effort": "high" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "high" }
  },
  "complex": {
    "planner":     { "backend": "claude", "model": "fable",  "effort": "xhigh" },
    "implementer": { "backend": "claude", "model": "opus",   "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "fable",  "effort": "xhigh" }
  }
}
JSON
run_tier standard "$WORK/mal-d2"
assert_equals "malformed(bad backend): exit 0" "$RC" "0"
assert_equals "malformed(bad backend): exact WARN" "$ERR" "$WARN"
assert_equals "malformed(bad backend): standard fallback" "$(val "$OUT" tier)" "standard"

# (d3) a codex cell wearing a claude model name — acceptance criterion: falls back
write_cfg "$WORK/mal-d3" <<'JSON'
{
  "trivial": {
    "planner":     { "backend": "claude", "model": "haiku",  "effort": "medium" },
    "implementer": { "backend": "codex",  "model": "sonnet", "effort": "max" },
    "reviewer":    { "backend": "codex",  "model": "gpt-5.6-terra", "effort": "high" }
  },
  "standard": {
    "planner":     { "backend": "claude", "model": "sonnet", "effort": "high" },
    "implementer": { "backend": "codex",  "model": "gpt-5.6-terra", "effort": "max" },
    "reviewer":    { "backend": "codex",  "model": "gpt-5.6-terra", "effort": "high" }
  },
  "complex": {
    "planner":     { "backend": "codex",  "model": "gpt-5.6-sol", "effort": "xhigh" },
    "implementer": { "backend": "codex",  "model": "gpt-5.6-sol", "effort": "high" },
    "reviewer":    { "backend": "codex",  "model": "gpt-5.6-sol", "effort": "xhigh" }
  }
}
JSON
run_tier trivial "$WORK/mal-d3"
assert_equals "malformed(codex backend, claude model): exit 0" "$RC" "0"
assert_equals "malformed(codex backend, claude model): exact WARN" "$ERR" "$WARN"
assert_equals "malformed(codex backend, claude model): standard fallback" "$(val "$OUT" tier)" "standard"

# (d4) a claude cell wearing a codex model name — the other direction
write_cfg "$WORK/mal-d4" <<'JSON'
{
  "trivial": {
    "planner":     { "backend": "claude", "model": "haiku",         "effort": "medium" },
    "implementer": { "backend": "codex",  "model": "gpt-5.6-luna",  "effort": "max" },
    "reviewer":    { "backend": "codex",  "model": "gpt-5.6-terra", "effort": "high" }
  },
  "standard": {
    "planner":     { "backend": "claude", "model": "gpt-5.6-terra", "effort": "high" },
    "implementer": { "backend": "codex",  "model": "gpt-5.6-terra", "effort": "max" },
    "reviewer":    { "backend": "codex",  "model": "gpt-5.6-terra", "effort": "high" }
  },
  "complex": {
    "planner":     { "backend": "codex",  "model": "gpt-5.6-sol",   "effort": "xhigh" },
    "implementer": { "backend": "codex",  "model": "gpt-5.6-sol",   "effort": "high" },
    "reviewer":    { "backend": "codex",  "model": "gpt-5.6-sol",   "effort": "xhigh" }
  }
}
JSON
run_tier standard "$WORK/mal-d4"
assert_equals "malformed(claude backend, codex model): exit 0" "$RC" "0"
assert_equals "malformed(claude backend, codex model): exact WARN" "$ERR" "$WARN"
assert_equals "malformed(claude backend, codex model): standard fallback" "$(val "$OUT" tier)" "standard"

# (e) wrong JSON type — tiers are strings, not objects (absorbs #55's intent:
#     a wrong shape leaks NOTHING to stderr but the single WARN line).
write_cfg "$WORK/mal-e" <<'JSON'
{"trivial": "x", "standard": "y", "complex": "z"}
JSON
run_tier standard "$WORK/mal-e"
assert_equals "wrong-type: exit 0" "$RC" "0"
assert_equals "wrong-type: stderr is exactly the WARN line" "$ERR" "$WARN"
assert_equals "wrong-type: standard fallback" "$(val "$OUT" tier)" "standard"

# (i) brace-in-string tier value AND a missing role — the extra "note" string
#     carries a "{"; the OLD scan counted it, ran trivial's block into standard,
#     and let `cell trivial reviewer *` silently borrow standard's reviewer
#     (chimera roster, clean stderr). String-aware, trivial's block is bounded
#     correctly, its missing reviewer yields empty → the single-WARN fallback.
write_cfg "$WORK/mal-i" <<'JSON'
{
  "trivial": {
    "note": "has { brace",
    "planner":     { "backend": "claude", "model": "sonnet", "effort": "medium" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "medium" }
  },
  "standard": {
    "planner":     { "backend": "claude", "model": "opus",   "effort": "high" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "high" }
  },
  "complex": {
    "planner":     { "backend": "claude", "model": "fable",  "effort": "xhigh" },
    "implementer": { "backend": "claude", "model": "opus",   "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "fable",  "effort": "xhigh" }
  }
}
JSON
run_tier trivial "$WORK/mal-i"
assert_equals "brace-in-string+missing-role: exit 0" "$RC" "0"
assert_equals "brace-in-string+missing-role: stderr is exactly the WARN line" "$ERR" "$WARN"
assert_equals "brace-in-string+missing-role: standard fallback (no chimera)" "$(val "$OUT" tier)" "standard"
assert_equals "brace-in-string+missing-role: reviewer_model opus (from fallback, not borrowed)" "$(val "$OUT" reviewer_model)" "opus"

# (j) a role whose object holds a NESTED object — the OLD first-"}" cut returned
#     the nested fable/max silently. String-aware, the nested object is detected
#     and the role reads as a miss → the single-WARN fallback (never the nested
#     values, and never a clean-stderr success claiming tier=trivial).
write_cfg "$WORK/mal-j" <<'JSON'
{
  "trivial": {
    "planner":     { "meta": { "model": "fable", "effort": "max" }, "backend": "claude", "model": "sonnet", "effort": "medium" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "medium" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "high" }
  },
  "standard": {
    "planner":     { "backend": "claude", "model": "opus",   "effort": "high" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "high" }
  },
  "complex": {
    "planner":     { "backend": "claude", "model": "fable",  "effort": "xhigh" },
    "implementer": { "backend": "claude", "model": "opus",   "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "fable",  "effort": "xhigh" }
  }
}
JSON
run_tier trivial "$WORK/mal-j"
assert_equals "nested-role-object: exit 0" "$RC" "0"
assert_equals "nested-role-object: stderr is exactly the WARN line" "$ERR" "$WARN"
assert_equals "nested-role-object: standard fallback (not nested values)" "$(val "$OUT" tier)" "standard"
assert_equals "nested-role-object: planner_effort high (fallback, not nested max)" "$(val "$OUT" planner_effort)" "high"

# ---------------------------------------------------------------------------
echo "test: reformatted-but-valid configs resolve correctly with no WARN (layout-independent)"

# (f) mixed layout — trivial's WHOLE block on one line; standard/complex multi-line.
#     Every value is exactly as shipped; only whitespace differs. The old extractor
#     let `trivial` steal standard's roster (opus/high) with clean stderr — the
#     planner_model=sonnet / planner_effort=medium asserts are the discriminators.
write_cfg "$WORK/fmt-f" <<'JSON'
{
  "trivial": { "planner": { "backend": "claude", "model": "sonnet", "effort": "medium" }, "implementer": { "backend": "claude", "model": "sonnet", "effort": "medium" }, "reviewer": { "backend": "claude", "model": "opus", "effort": "high" } },
  "standard": {
    "planner":     { "backend": "claude", "model": "opus",   "effort": "high" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "high" }
  },
  "complex": {
    "planner":     { "backend": "claude", "model": "fable",  "effort": "xhigh" },
    "implementer": { "backend": "claude", "model": "opus",   "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "fable",  "effort": "xhigh" }
  }
}
JSON
run_tier trivial "$WORK/fmt-f"
assert_equals "mixed-layout: exit 0" "$RC" "0"
assert_equals "mixed-layout: stderr empty (no WARN)" "$ERR" ""
assert_equals "mixed-layout: tier echoed trivial" "$(val "$OUT" tier)" "trivial"
assert_equals "mixed-layout: planner_model sonnet (not stolen opus)" "$(val "$OUT" planner_model)" "sonnet"
assert_equals "mixed-layout: planner_effort medium (not stolen high)" "$(val "$OUT" planner_effort)" "medium"
assert_equals "mixed-layout: implementer_model sonnet" "$(val "$OUT" implementer_model)" "sonnet"
assert_equals "mixed-layout: implementer_effort medium" "$(val "$OUT" implementer_effort)" "medium"
assert_equals "mixed-layout: reviewer_model opus" "$(val "$OUT" reviewer_model)" "opus"
assert_equals "mixed-layout: planner_backend claude" "$(val "$OUT" planner_backend)" "claude"
run_tier standard "$WORK/fmt-f"
assert_equals "mixed-layout: standard planner_model opus" "$(val "$OUT" planner_model)" "opus"
assert_equals "mixed-layout: standard stderr empty (no WARN)" "$ERR" ""

# (g) two roles on one line — standard's planner+implementer share a single line.
#     The old extractor grabbed the FIRST "model" on the line (planner's) as the
#     implementer's; the fix must scope the field to the role's own {...}.
write_cfg "$WORK/fmt-g" <<'JSON'
{
  "trivial": {
    "planner":     { "backend": "claude", "model": "sonnet", "effort": "medium" },
    "implementer": { "backend": "claude", "model": "sonnet", "effort": "medium" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "high" }
  },
  "standard": {
    "planner": { "backend": "claude", "model": "opus", "effort": "high" }, "implementer": { "backend": "claude", "model": "sonnet", "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "opus",   "effort": "high" }
  },
  "complex": {
    "planner":     { "backend": "claude", "model": "fable",  "effort": "xhigh" },
    "implementer": { "backend": "claude", "model": "opus",   "effort": "high" },
    "reviewer":    { "backend": "claude", "model": "fable",  "effort": "xhigh" }
  }
}
JSON
run_tier standard "$WORK/fmt-g"
assert_equals "two-roles-one-line: exit 0" "$RC" "0"
assert_equals "two-roles-one-line: stderr empty (no WARN)" "$ERR" ""
assert_equals "two-roles-one-line: implementer_model sonnet (not planner's opus)" "$(val "$OUT" implementer_model)" "sonnet"
assert_equals "two-roles-one-line: implementer_effort high" "$(val "$OUT" implementer_effort)" "high"
assert_equals "two-roles-one-line: planner_model opus" "$(val "$OUT" planner_model)" "opus"
assert_equals "two-roles-one-line: reviewer_model opus" "$(val "$OUT" reviewer_model)" "opus"

# (h) fully minified — the whole config on ONE line, zero whitespace (jq -c shape).
write_cfg "$WORK/fmt-h" <<'JSON'
{"trivial":{"planner":{"backend":"claude","model":"sonnet","effort":"medium"},"implementer":{"backend":"claude","model":"sonnet","effort":"medium"},"reviewer":{"backend":"claude","model":"opus","effort":"high"}},"standard":{"planner":{"backend":"claude","model":"opus","effort":"high"},"implementer":{"backend":"claude","model":"sonnet","effort":"high"},"reviewer":{"backend":"claude","model":"opus","effort":"high"}},"complex":{"planner":{"backend":"claude","model":"fable","effort":"xhigh"},"implementer":{"backend":"claude","model":"opus","effort":"high"},"reviewer":{"backend":"claude","model":"fable","effort":"xhigh"}}}
JSON
run_tier trivial "$WORK/fmt-h"
assert_equals "minified: trivial stderr empty (no WARN)" "$ERR" ""
assert_equals "minified: trivial planner_effort medium" "$(val "$OUT" planner_effort)" "medium"
assert_equals "minified: trivial exactly 10 key=value lines" "$(printf '%s\n' "$OUT" | grep -c '=')" "10"
run_tier standard "$WORK/fmt-h"
assert_equals "minified: standard planner_model opus" "$(val "$OUT" planner_model)" "opus"
run_tier complex "$WORK/fmt-h"
assert_equals "minified: complex reviewer_model fable" "$(val "$OUT" reviewer_model)" "fable"
assert_equals "minified: complex reviewer_backend claude" "$(val "$OUT" reviewer_backend)" "claude"
assert_equals "minified: complex stderr empty (no WARN)" "$ERR" ""

# ---------------------------------------------------------------------------
echo "test: bad/missing tier arg against a good shipped config → exact WARN + standard fallback"

run_tier bogus
assert_equals "bogus tier: exit 0" "$RC" "0"
assert_equals "bogus tier: exact WARN" "$ERR" "$WARN"
assert_equals "bogus tier: standard fallback" "$(val "$OUT" tier)" "standard"

NOARG_ERR="$WORK/noarg-err"
NOARG_OUT="$(env -u RESOLVE_TIER_ROOT bash "$SCRIPT" 2>"$NOARG_ERR")"
NOARG_RC=$?
assert_equals "no arg: exit 0" "$NOARG_RC" "0"
assert_equals "no arg: exact WARN" "$(cat "$NOARG_ERR")" "$WARN"
assert_equals "no arg: standard fallback" "$(val "$NOARG_OUT" tier)" "standard"

# ---------------------------------------------------------------------------
echo "test: a cd failure inside the BASH_SOURCE fallback leaks no stderr but the one WARN"

CDFAIL_DIR="$WORK/cdfail-dir"
CDFAIL_BARRIER="$WORK/cdfail-barrier"
mkdir -p "$CDFAIL_DIR"
mkfifo "$CDFAIL_BARRIER"

# Splice a synchronization barrier immediately before the `if [ -z "$PLUGIN_ROOT" ]`
# line so the background run below can pause execution right at the SCRIPT_DIR/
# PLUGIN_ROOT lines and delete their target directory out from under them. Every
# other line — including the two fixed `cd ... 2>/dev/null` lines themselves — is
# copied byte-for-byte from the shipped script; nothing under test is duplicated
# or reworded.
SPLIT_AT="$(grep -n '^if \[ -z "\$PLUGIN_ROOT" \]; then$' "$SCRIPT" | head -n1 | cut -d: -f1)"
if [ -z "$SPLIT_AT" ]; then
    no "cdfail: could not locate the PLUGIN_ROOT fallback line to splice a barrier into"
else
    {
        head -n "$((SPLIT_AT - 1))" "$SCRIPT"
        printf 'read -r _ < "%s"\n' "$CDFAIL_BARRIER"
        tail -n "+${SPLIT_AT}" "$SCRIPT"
    } > "$CDFAIL_DIR/resolve-tier.sh"
    chmod +x "$CDFAIL_DIR/resolve-tier.sh"

    CDFAIL_OUTFILE="$WORK/cdfail-out"
    CDFAIL_ERRFILE="$WORK/cdfail-err"
    env -u RESOLVE_TIER_ROOT bash "$CDFAIL_DIR/resolve-tier.sh" trivial >"$CDFAIL_OUTFILE" 2>"$CDFAIL_ERRFILE" &
    CDFAIL_PID=$!

    # Block here (not a timed sleep) until the background script has actually
    # opened the barrier fifo for reading, i.e. it is parked exactly before the
    # cd lines — this is what makes the removal below race-free.
    exec 8>"$CDFAIL_BARRIER"

    rm -rf "$CDFAIL_DIR"

    # Release the barrier: the open above already satisfied the reader's blocking
    # open, so closing fd 8 delivers EOF and lets the script resume straight into
    # the now-missing-directory cd.
    exec 8>&-

    wait "$CDFAIL_PID"
    CDFAIL_RC=$?
    CDFAIL_OUT="$(cat "$CDFAIL_OUTFILE")"
    CDFAIL_ERR="$(cat "$CDFAIL_ERRFILE")"

    assert_equals "cdfail: exit 0" "$CDFAIL_RC" "0"
    assert_equals "cdfail: stderr is exactly the WARN line (no leaked cd error)" "$CDFAIL_ERR" "$WARN"
    assert_equals "cdfail: standard fallback" "$(val "$CDFAIL_OUT" tier)" "standard"
fi

# ---------------------------------------------------------------------------
echo "test: shipped config is structurally complete (9 cells resolve via the REAL helper)"
complete=1
for t in trivial standard complex; do
    run_tier "$t"
    [ "$RC" -eq 0 ] || complete=0
    [ -z "$ERR" ]   || complete=0     # a clean shipped tier must emit no WARN
    for r in planner implementer reviewer; do
        m="$(val "$OUT" "${r}_model")"
        e="$(val "$OUT" "${r}_effort")"
        b="$(val "$OUT" "${r}_backend")"
        case "$e" in low|medium|high|xhigh|max) ;; *) complete=0 ;; esac
        case "$b" in
            claude) case "$m" in haiku|sonnet|opus|fable) ;; *) complete=0 ;; esac ;;
            codex)  case "$m" in gpt-5.6-luna|gpt-5.6-terra|gpt-5.6-sol) ;; *) complete=0 ;; esac ;;
            *) complete=0 ;;
        esac
    done
done
assert_equals "shipped config: all 9 tier×role cells resolve to a valid model/effort/backend" "$complete" "1"

# ---------------------------------------------------------------------------
echo "test: fallback is pinned literally to the hardcoded claude standard roster"
# Deliberately NOT derived from resolving `standard` against the shipped config:
# the fallback is a fixed roster independent of whatever the config's standard
# tier currently resolves to, so a future codex rollout there can't change what
# a broken config falls back to — even though both happen to match today.
EXPECTED_FALLBACK="tier=standard
planner_model=sonnet
planner_effort=high
planner_backend=claude
implementer_model=sonnet
implementer_effort=max
implementer_backend=claude
reviewer_model=opus
reviewer_effort=high
reviewer_backend=claude"
run_tier complex "$EMPTY"   # missing config → fallback, whatever tier was asked
assert_equals "fallback output matches the pinned claude standard roster" "$OUT" "$EXPECTED_FALLBACK"

# ---------------------------------------------------------------------------
echo "test: a USER table at CLAUDE_CONFIG_DIR overrides the shipped one"
# The point of the whole mechanism: the shipped table is claude so a fresh install works with no
# codex CLI, and a person opts into codex for themselves without editing a plugin file that the
# next kit update overwrites.
USERCFG="$WORK/usercfg"
write_cfg "$USERCFG" <<'JSON'
{
  "trivial":  { "planner": { "backend": "codex", "model": "gpt-5.6-luna", "effort": "low" },
                "implementer": { "backend": "codex", "model": "gpt-5.6-luna", "effort": "max" },
                "reviewer": { "backend": "codex", "model": "gpt-5.6-terra", "effort": "high" } },
  "standard": { "planner": { "backend": "codex", "model": "gpt-5.6-terra", "effort": "high" },
                "implementer": { "backend": "codex", "model": "gpt-5.6-terra", "effort": "max" },
                "reviewer": { "backend": "codex", "model": "gpt-5.6-terra", "effort": "high" } },
  "complex":  { "planner": { "backend": "codex", "model": "gpt-5.6-sol", "effort": "xhigh" },
                "implementer": { "backend": "codex", "model": "gpt-5.6-sol", "effort": "high" },
                "reviewer": { "backend": "codex", "model": "gpt-5.6-sol", "effort": "xhigh" } }
}
JSON
UOUT="$(CLAUDE_CONFIG_DIR="$USERCFG" env -u RESOLVE_TIER_ROOT bash "$SCRIPT" standard 2>"$WORK/uerr")"
assert_equals "user table: no WARN" "$(cat "$WORK/uerr")" ""
assert_equals "user table: implementer routes to codex" "$(val "$UOUT" implementer_backend)" "codex"
assert_equals "user table: implementer model is the user's" "$(val "$UOUT" implementer_model)" "gpt-5.6-terra"

echo "test: with no user table the SHIPPED table is used, and it is claude"
run_tier standard
assert_equals "shipped: no WARN" "$ERR" ""
assert_equals "shipped: implementer stays claude" "$(val "$OUT" implementer_backend)" "claude"

echo "test: RESOLVE_TIER_ROOT wins over a user table — the test seam stays authoritative"
# Without this, every test that pins a specific table would silently read the developer's own
# ~/.claude table instead, and the suite would pass or fail by machine.
SEAM="$WORK/seamcfg"
write_cfg "$SEAM" <<'JSON'
{
  "trivial":  { "planner": { "backend": "claude", "model": "haiku", "effort": "low" },
                "implementer": { "backend": "claude", "model": "haiku", "effort": "max" },
                "reviewer": { "backend": "claude", "model": "sonnet", "effort": "high" } },
  "standard": { "planner": { "backend": "claude", "model": "fable", "effort": "high" },
                "implementer": { "backend": "claude", "model": "fable", "effort": "max" },
                "reviewer": { "backend": "claude", "model": "opus", "effort": "high" } },
  "complex":  { "planner": { "backend": "claude", "model": "opus", "effort": "xhigh" },
                "implementer": { "backend": "claude", "model": "opus", "effort": "high" },
                "reviewer": { "backend": "claude", "model": "opus", "effort": "xhigh" } }
}
JSON
SOUT="$(CLAUDE_CONFIG_DIR="$USERCFG" RESOLVE_TIER_ROOT="$SEAM" bash "$SCRIPT" standard 2>/dev/null)"
assert_equals "seam wins: backend from RESOLVE_TIER_ROOT, not the user table" \
    "$(val "$SOUT" implementer_backend)" "claude"
assert_equals "seam wins: model from RESOLVE_TIER_ROOT" "$(val "$SOUT" implementer_model)" "fable"

echo "test: a MALFORMED user table is loud, not a silent revert to the shipped table"
# A typo in your own table must not look like the shipped roster quietly winning.
BADUSER="$WORK/baduser"
write_cfg "$BADUSER" <<'JSON'
{ "trivial": { "implementer": { "backend": "codex", "model": "haiku", "effort": "max" } } }
JSON
BOUT="$(CLAUDE_CONFIG_DIR="$BADUSER" env -u RESOLVE_TIER_ROOT bash "$SCRIPT" standard 2>"$WORK/berr")"
assert_equals "bad user table: the exact WARN line" "$(cat "$WORK/berr")" "$WARN"
assert_equals "bad user table: falls back to the standard roster" "$(val "$BOUT" tier)" "standard"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
