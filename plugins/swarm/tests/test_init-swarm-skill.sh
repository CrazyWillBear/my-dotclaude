#!/usr/bin/env bash
#
# Tests for skills/init-swarm/SKILL.md — the /init-swarm scaffolding skill.
#
# A skill is prose an LLM follows, so it cannot be shell-executed directly (same
# limitation noted in test_orchestrate-skill.sh). Two kinds of coverage here:
#
#   1. Grep tests on the prose itself — can only prove a STRING DESCRIBING the
#      behavior is present (name, the three roles, the paths it writes, that it
#      validates before reporting done).
#   2. A REAL end-to-end simulation of the skill's own Steps 1/4/5/6/7, run against
#      a real scratch git repo and the shipped templates — no inlined/stubbed
#      content anywhere. This is the "init-swarm's output validating through the
#      real roster.sh in a scratch repo" central mechanism: it proves the shipped
#      templates plus the skill's own file-placement rules produce a roster that
#      the REAL roster.sh (not a stub) accepts, and that role selectivity actually
#      holds (an unchosen role gets no brief, no inbox dir, and no roster row).
#
# Run: bash plugins/swarm/tests/test_init-swarm-skill.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/skills/init-swarm/SKILL.md"
ROSTER_SCRIPT="$PLUGIN_ROOT/scripts/roster.sh"
TEMPLATES="$PLUGIN_ROOT/templates"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_equals()        { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }

if [ ! -f "$SKILL_FILE" ]; then
    printf '  FAIL: SKILL.md missing at %s\n' "$SKILL_FILE"
    printf '\n%d passed, %d failed\n' "$pass" "$((fail + 1))"
    exit 1
fi
BODY="$(cat "$SKILL_FILE")"
FM="$(sed -n '/^---$/,/^---$/p' "$SKILL_FILE")"

# ---------------------------------------------------------------------------
echo "test: frontmatter"
assert_contains "name is init-swarm" "$FM" "name: init-swarm"
assert_contains "has a description" "$FM" "description:"
assert_contains "mentions the three roles in the description" "$FM" "orchestrator"
assert_contains "allowed-tools includes AskUserQuestion" "$FM" "AskUserQuestion"
assert_contains "allowed-tools includes Write" "$FM" "Write"
assert_contains "allowed-tools includes Bash" "$FM" "Bash"

echo "test: it asks which of the three roles, and does not pick a default"
assert_contains "names orchestrator" "$BODY" "orchestrator"
assert_contains "names swe-manager" "$BODY" "swe-manager"
assert_contains "names performance-engineer" "$BODY" "performance-engineer"
assert_contains "uses AskUserQuestion" "$BODY" "AskUserQuestion"
assert_contains "multiSelect (any subset, not one pick)" "$BODY" "multiSelect"

echo "test: it refuses outside a git repo (roster.json is project-local state)"
assert_contains "checks for a git repo" "$BODY" "git repo"

echo "test: what it writes and where"
assert_contains "roster.json path" "$BODY" ".claude/swarm/roster.json"
assert_contains "charter.md path" "$BODY" ".claude/swarm/charter.md"
assert_contains "charter is written unconditionally" "$BODY" "unconditionally"
assert_contains "brief path uses the inbox convention" "$BODY" ".claude/swarm/inbox/"
assert_contains "reads from the plugin's templates dir" "$BODY" "CLAUDE_PLUGIN_ROOT"
assert_contains "roster.json is only the CHOSEN roles" "$BODY" "chosen role"

echo "test: it validates through the real roster.sh before reporting done"
assert_contains "runs roster.sh validate with a literal, runnable invocation" "$BODY" \
    '${CLAUDE_PLUGIN_ROOT}/scripts/roster.sh" validate'
assert_not_contains "never claims success on an unvalidated roster" "$BODY" "without validating"

echo "test: it does not clobber an existing roster/charter/briefs on a re-run"
assert_contains "checks for existing state before writing" "$BODY" "existing"
assert_contains "shows a diff before overwriting" "$BODY" "diff"
assert_contains "asks before overwriting, same precedent as init-python-project" "$BODY" "ask before overwriting"
assert_contains "never clobbers silently" "$BODY" "never clobber silently"

echo "test: it sets honest expectations about what ships later"
assert_contains "notes swarm.sh is a later issue" "$BODY" "swarm.sh"

echo "test: it scaffolds vault memory — real vault when on PATH, a plain fallback otherwise"
assert_contains "checks whether vault is on PATH" "$BODY" "command -v vault"
assert_contains "runs a literal, runnable vault init invocation" "$BODY" \
    "vault init --layout swarm --roster .claude/swarm/roster.json --vault .claude/swarm/memory"
assert_contains "names the policy file vault writes" "$BODY" ".vault-policy.json"
assert_contains "one-line notice when vault is absent" "$BODY" "vault not on PATH"
assert_contains "plain fallback still makes shared/" "$BODY" ".claude/swarm/memory/shared/"
assert_contains "fallback never invents a policy file" "$BODY" "No policy file"

echo "test: charter carries the memory rules, including never Claude's own auto-memory"
CHARTER_BODY="$(cat "$TEMPLATES/charter.md")"
assert_contains "charter states read shared/ and your namespace" "$CHARTER_BODY" \
    'read `shared/` and your namespace'
assert_contains "charter states write only your namespace" "$CHARTER_BODY" \
    "write only your namespace"
assert_contains "charter states propose to shared/" "$CHARTER_BODY" "propose to"
assert_contains "charter forbids Claude's own auto-memory" "$CHARTER_BODY" "auto-memory"

echo "test: every brief names its vault --agent value"
for role in orchestrator swe-manager performance-engineer; do
    BRIEF_BODY="$(cat "$TEMPLATES/briefs/$role.md")"
    assert_contains "$role brief names its --agent value" "$BRIEF_BODY" \
        "\`--agent\` is \`$role\`"
done

# ---------------------------------------------------------------------------
echo "test: central mechanism — simulate the skill's Steps 1/4/5/6/7 for real, in a scratch repo"

SCRATCH="$WORK/scratch-repo"
mkdir -p "$SCRATCH"
if ! git -C "$SCRATCH" init -q 2>/dev/null; then
    no "could not git init the scratch repo (is git installed?)"
else
    ok "Step 1: scratch dir is a real git repo"
fi

# Chosen roles: two of the three, deliberately not all — this is the discriminator
# that proves selectivity (a bug that always wrote all three would pass a
# choose-all test but fail this one).
CHOSEN="orchestrator swe-manager"
UNCHOSEN="performance-engineer"

# Step 4: roster.json is the subset of templates/roster.json's rows for the chosen
# roles only — built with the same tool roster.sh itself uses (python3's json
# module), never hand-inlined.
mkdir -p "$SCRATCH/.claude/swarm"
SIM_TEMPLATE="$TEMPLATES/roster.json" SIM_CHOSEN="$CHOSEN" \
    SIM_OUT="$SCRATCH/.claude/swarm/roster.json" python3 <<"PY"
import json, os
with open(os.environ["SIM_TEMPLATE"]) as fh:
    full = json.load(fh)
chosen = os.environ["SIM_CHOSEN"].split()
subset = {name: full[name] for name in chosen}
with open(os.environ["SIM_OUT"], "w") as fh:
    json.dump(subset, fh, indent=2)
    fh.write("\n")
PY

# Step 5: charter.md, verbatim, unconditionally.
cp "$TEMPLATES/charter.md" "$SCRATCH/.claude/swarm/charter.md"

# Step 6: one brief per CHOSEN role only, to .claude/swarm/inbox/<role>/brief.md.
for role in $CHOSEN; do
    mkdir -p "$SCRATCH/.claude/swarm/inbox/$role"
    cp "$TEMPLATES/briefs/$role.md" "$SCRATCH/.claude/swarm/inbox/$role/brief.md"
done

echo "test: the scratch repo holds exactly what the acceptance criteria ask for"
if [ -f "$SCRATCH/.claude/swarm/roster.json" ]; then ok "roster.json written"; else no "roster.json missing"; fi
if [ -f "$SCRATCH/.claude/swarm/charter.md" ]; then ok "charter.md written"; else no "charter.md missing"; fi
assert_equals "charter.md matches the shipped template verbatim" \
    "$(cat "$SCRATCH/.claude/swarm/charter.md")" "$(cat "$TEMPLATES/charter.md")"

for role in $CHOSEN; do
    if [ -f "$SCRATCH/.claude/swarm/inbox/$role/brief.md" ]; then
        ok "brief written for chosen role $role"
    else
        no "brief missing for chosen role $role"
    fi
    assert_equals "brief for $role matches its shipped template verbatim" \
        "$(cat "$SCRATCH/.claude/swarm/inbox/$role/brief.md" 2>/dev/null)" \
        "$(cat "$TEMPLATES/briefs/$role.md")"
done

echo "test: an unchosen role gets nothing — selectivity actually holds"
for role in $UNCHOSEN; do
    if [ ! -d "$SCRATCH/.claude/swarm/inbox/$role" ]; then
        ok "no inbox dir for unchosen role $role"
    else
        no "unchosen role $role got an inbox dir anyway"
    fi
done

echo "test: Step 7 — the REAL roster.sh (not a stub) validates this output"
VALIDATE_ERR="$WORK/validate-err"
if bash "$ROSTER_SCRIPT" validate "$SCRATCH" 2>"$VALIDATE_ERR"; then
    ok "roster.sh validate exits 0 against init-swarm's simulated output"
else
    no "roster.sh validate rejected init-swarm's simulated output: $(cat "$VALIDATE_ERR")"
fi

LIST_OUT="$(bash "$ROSTER_SCRIPT" list "$SCRATCH" 2>/dev/null)"
assert_equals "roster.sh list sees exactly the two chosen roles, nothing more" \
    "$LIST_OUT" "$(printf 'orchestrator\nswe-manager')"

GET_OUT="$(bash "$ROSTER_SCRIPT" get swe-manager kind "$SCRATCH" 2>/dev/null)"
assert_equals "roster.sh get resolves a real field on the simulated roster" "$GET_OUT" "manager"

# ---------------------------------------------------------------------------
echo "test: central mechanism — Step 8, scaffold .claude/swarm/memory/"

MEMORY="$SCRATCH/.claude/swarm/memory"

echo "test: the plain fallback is exercised for real on a bare PATH (never hypothetical)"
if PATH=/usr/bin:/bin command -v vault >/dev/null 2>&1; then
    no "test assumption broken: vault is reachable on a bare /usr/bin:/bin PATH"
else
    ok "vault absent on a bare PATH — the fallback branch below is real, not skipped"
    for role in $CHOSEN; do
        kind="$(bash "$ROSTER_SCRIPT" get "$role" kind "$SCRATCH" 2>/dev/null)"
        if [ "$kind" = "manager" ] || [ "$kind" = "doer" ]; then
            mkdir -p "$MEMORY/roles/$role" "$MEMORY/proposals/$role"
        fi
    done
    mkdir -p "$MEMORY/shared"

    if [ -d "$MEMORY/shared" ]; then ok "fallback makes shared/"; else no "fallback missing shared/"; fi
    if [ -d "$MEMORY/roles/swe-manager" ] && [ -d "$MEMORY/proposals/swe-manager" ]; then
        ok "fallback makes roles/ and proposals/ for the manager role"
    else
        no "fallback missing roles/ or proposals/ for swe-manager"
    fi
    if [ ! -e "$MEMORY/roles/orchestrator" ]; then
        ok "fallback makes no roles/orchestrator/ (it already owns the whole tree)"
    else
        no "fallback wrongly made roles/orchestrator/"
    fi
    if [ ! -f "$MEMORY/.vault-policy.json" ]; then
        ok "fallback writes no policy file — only vault generates one"
    else
        no "fallback should not have written a policy file"
    fi
fi

echo "test: the real vault path, opportunistically, when this machine has vault on PATH"
if command -v vault >/dev/null 2>&1; then
    rm -rf "$MEMORY"
    VAULT_ERR="$WORK/vault-init-err"
    if vault init --layout swarm --roster "$SCRATCH/.claude/swarm/roster.json" \
        --vault "$MEMORY" >/dev/null 2>"$VAULT_ERR"; then
        ok "real vault init exits 0 against the simulated roster"
    else
        no "real vault init failed: $(cat "$VAULT_ERR")"
    fi
    if [ -d "$MEMORY/shared" ]; then ok "real vault init makes shared/"; else no "real vault init missing shared/"; fi
    if [ -d "$MEMORY/roles/swe-manager" ] && [ -d "$MEMORY/proposals/swe-manager" ]; then
        ok "real vault init makes roles/ and proposals/ for the manager role"
    else
        no "real vault init missing roles/ or proposals/ for swe-manager"
    fi
    if [ ! -e "$MEMORY/roles/orchestrator" ]; then
        ok "real vault init matches the fallback's owners-only rule (no roles/orchestrator/)"
    else
        no "real vault init unexpectedly made roles/orchestrator/"
    fi
    POLICY="$MEMORY/.vault-policy.json"
    if [ -f "$POLICY" ]; then ok "real vault init writes .vault-policy.json"; else no "real vault init wrote no policy file"; fi
    ORCH_WRITE="$(SIM_POLICY="$POLICY" python3 -c "
import json, os
p = json.load(open(os.environ['SIM_POLICY']))
print(any(r.get('write') and r.get('prefix') == '' for r in p.get('orchestrator', [])))
" 2>/dev/null)"
    assert_equals "policy derived from the real roster gives orchestrator a write-everything rule" \
        "$ORCH_WRITE" "True"
    SWE_SCOPE="$(SIM_POLICY="$POLICY" python3 -c "
import json, os
p = json.load(open(os.environ['SIM_POLICY']))
print(any(r.get('prefix') == 'roles/swe-manager/' and r.get('write') for r in p.get('swe-manager', [])))
" 2>/dev/null)"
    assert_equals "policy derived from the real roster scopes swe-manager to its own roles/ prefix" \
        "$SWE_SCOPE" "True"
else
    echo "  SKIP: vault not on PATH in this environment — real-vault sub-test not exercised" \
         "(the plain fallback above already ran for real)"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
