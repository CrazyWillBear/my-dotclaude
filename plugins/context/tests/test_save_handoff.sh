#!/usr/bin/env bash
#
# Tests for scripts/save-handoff.sh — the per-repo keyed handoff writer.
#
# Black-box: we drive a real git repo, run the actual script, and assert on the
# keyed dir it prints (--print-dir), the keyed pointer it writes (no args or
# --handoff-path), and the doc it resolves into handoff_path. A drift guard
# confirms the /handoff + /handoff-plan skills (same plugin) call this script via
# CLAUDE_PLUGIN_ROOT instead of reimplementing the keying inline.
#
# Keying: ~/.claude/handoffs/<sha1(canonical --git-common-dir)[:16]>/ holding
# .pending.json (pointer) and <branch-slug>.md (doc). Keyed by the shared common
# .git so the primary tree and all its linked worktrees share one pointer.
#
# Run: bash plugins/context/tests/test_save_handoff.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SAVE="$PLUGIN_ROOT/scripts/save-handoff.sh"
# /handoff and /handoff-plan live in this SAME plugin now (that's the whole point —
# CLAUDE_PLUGIN_ROOT resolves reliably within one plugin, unlike across plugins).
SKILL="$PLUGIN_ROOT/skills/handoff/SKILL.md"
SKILL_PLAN="$PLUGIN_ROOT/skills/handoff-plan/SKILL.md"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
GLOBAL_HOME="$WORK/home"
mkdir -p "$GLOBAL_HOME/.claude/handoffs"

PROJECT_DIR="$WORK/proj"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_empty() { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected empty, got: $2)"; fi; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_file() { if [ -f "$2" ]; then ok "$1"; else no "$1 (missing file $2)"; fi; }

g() { git -C "$PROJECT_DIR" "$@"; }

init_repo() {
    rm -rf "$PROJECT_DIR"
    find "$GLOBAL_HOME/.claude/handoffs" -name '.pending.json' -delete 2>/dev/null || true
    mkdir -p "$PROJECT_DIR/.claude"
    g init -q
    g config user.email t@t.com
    g config user.name t
    printf 'seed\n' >"$PROJECT_DIR/.gitkeep"
    g add -A
    g commit -q -m base
}

run_save_handoff() {
    HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        bash "$SAVE"
}
print_dir() {
    HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        bash "$SAVE" --print-dir
}
# run_save_handoff_hp <project_dir> <handoff_path> — the way /handoff-plan calls it.
run_save_handoff_hp() {
    HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        bash "$SAVE" --handoff-path "$2"
}

# expected_dir <project_dir> — the keyed dir computed independently of the script,
# mirroring its recipe: sha1(realpath(join(project_dir, --git-common-dir)))[:16].
expected_dir() {
    HOME="$GLOBAL_HOME" python3 - "$1" <<'PY'
import sys, hashlib, os, subprocess
pd = sys.argv[1]
raw = subprocess.run(["git", "-C", pd, "rev-parse", "--git-common-dir"],
                     capture_output=True, text=True).stdout.strip()
cd = os.path.realpath(os.path.join(pd, raw))
print(os.path.join(os.path.expanduser("~/.claude/handoffs"),
                   hashlib.sha1(cd.encode()).hexdigest()[:16]))
PY
}
# expected_common_dir <project_dir> — canonical --git-common-dir for the repo.
expected_common_dir() {
    HOME="$GLOBAL_HOME" python3 - "$1" <<'PY'
import sys, os, subprocess
pd = sys.argv[1]
raw = subprocess.run(["git", "-C", pd, "rev-parse", "--git-common-dir"],
                     capture_output=True, text=True).stdout.strip()
print(os.path.realpath(os.path.join(pd, raw)))
PY
}

read_field() {
    python3 - "$1" "$2" <<'PY'
import sys, json
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
    print(v if v is not None else "")
except Exception:
    print("")
PY
}

pointer_keys() {
    python3 - "$1" <<'PY'
import sys, json
print(",".join(sorted(json.load(open(sys.argv[1])).keys())))
PY
}

# ---------------------------------------------------------------------------
echo "test: --print-dir prints the per-repo keyed dir"
init_repo
top="$(g rev-parse --show-toplevel)"
dir="$(print_dir "$PROJECT_DIR")"
assert_equals "--print-dir matches the independent sha1 keying" "$dir" "$(expected_dir "$PROJECT_DIR")"
case "$dir" in
    */.claude/handoffs/????????????????) ok "keyed dir is 16 hex under handoffs/" ;;
    *) no "keyed dir shape unexpected ($dir)" ;;
esac

# ---------------------------------------------------------------------------
echo "test: --print-dir is empty outside a git repo"
NONREPO="$WORK/nonrepo"
mkdir -p "$NONREPO"
out="$(print_dir "$NONREPO")"
assert_empty "--print-dir empty outside a repo" "$out"

# ---------------------------------------------------------------------------
echo "test: distinct repos get distinct keyed dirs"
init_repo
dirA="$(print_dir "$PROJECT_DIR")"
PROJECT_DIR2="$WORK/proj2"
mkdir -p "$PROJECT_DIR2"
git -C "$PROJECT_DIR2" init -q
git -C "$PROJECT_DIR2" config user.email t@t.com
git -C "$PROJECT_DIR2" config user.name t
printf 'seed\n' >"$PROJECT_DIR2/.gitkeep"
git -C "$PROJECT_DIR2" add -A
git -C "$PROJECT_DIR2" commit -q -m base
dirB="$(print_dir "$PROJECT_DIR2")"
if [ "$dirA" != "$dirB" ]; then ok "two repos -> two distinct keyed dirs"; else no "keyed dirs collided ($dirA)"; fi

# ---------------------------------------------------------------------------
echo "test: no-args writes the keyed pointer with the full schema and resolves the keyed doc"
init_repo
top="$(g rev-parse --show-toplevel)"
head="$(g rev-parse HEAD)"
branch="$(g rev-parse --abbrev-ref HEAD)"
safe="${branch//\//-}"
dir="$(print_dir "$PROJECT_DIR")"
mkdir -p "$dir"
printf '# Handoff\n## Done\n- work\n' >"$dir/${safe}.md"
run_save_handoff "$PROJECT_DIR"
PEND="$dir/.pending.json"
assert_file "writes the keyed pointer" "$PEND"
assert_equals "records git_toplevel" "$(read_field "$PEND" git_toplevel)" "$top"
assert_equals "records git_common_dir" "$(read_field "$PEND" git_common_dir)" "$(expected_common_dir "$PROJECT_DIR")"
assert_equals "records baseline_head" "$(read_field "$PEND" baseline_head)" "$head"
assert_equals "records branch" "$(read_field "$PEND" branch)" "$branch"
assert_contains "handoff_path resolves the keyed doc" "$(read_field "$PEND" handoff_path)" "${safe}.md"
assert_contains "handoff_path is under the keyed dir" "$(read_field "$PEND" handoff_path)" "$dir"
assert_equals "pointer carries the full schema" "$(pointer_keys "$PEND")" \
    "baseline_head,branch,context_tokens,git_common_dir,git_toplevel,handoff_path,session_id,ts"

# ---------------------------------------------------------------------------
echo "test: no-args resolves handoff_path to null when no keyed doc exists"
init_repo
top="$(g rev-parse --show-toplevel)"
dir="$(print_dir "$PROJECT_DIR")"
# Clear any doc a prior test left in this repo's (stable) keyed dir.
rm -f "$dir"/*.md 2>/dev/null || true
run_save_handoff "$PROJECT_DIR"
assert_file "pointer written without a doc present" "$dir/.pending.json"
assert_equals "handoff_path is null with no doc" "$(read_field "$dir/.pending.json" handoff_path)" ""

# ---------------------------------------------------------------------------
# The old `-pipeline.md` fallback went with /pipeline itself. Nothing writes that
# doc any more, so a resolver that still looked for it could only point a resume
# order at a stale file.
echo "test: only the plain /handoff doc resolves — no second doc shape"
init_repo
branch="$(g rev-parse --abbrev-ref HEAD)"
safe="${branch//\//-}"
dir="$(print_dir "$PROJECT_DIR")"
mkdir -p "$dir"
rm -f "$dir"/*.md 2>/dev/null || true
printf '# Stale\nphase: built\n' >"$dir/${safe}-pipeline.md"
run_save_handoff "$PROJECT_DIR"
assert_equals "a -pipeline.md doc is NOT resolved" \
    "$(read_field "$dir/.pending.json" handoff_path)" ""
printf '# Handoff\n## Done\n- work\n' >"$dir/${safe}.md"
run_save_handoff "$PROJECT_DIR"
assert_contains "the plain doc resolves" \
    "$(read_field "$dir/.pending.json" handoff_path)" "${safe}.md"
rm -f "$dir"/*.md 2>/dev/null || true

# ---------------------------------------------------------------------------
# /handoff-plan writes <branch-slug>-plan.md, a shape the default lookup above
# never matches (by design — it's the /handoff shape). It passes --handoff-path
# instead of relying on resolution.
echo "test: --handoff-path uses that doc verbatim — the shape /handoff-plan writes"
init_repo
branch="$(g rev-parse --abbrev-ref HEAD)"
safe="${branch//\//-}"
dir="$(print_dir "$PROJECT_DIR")"
mkdir -p "$dir"
rm -f "$dir"/*.md 2>/dev/null || true
printf '# Plan\n- step one\n' >"$dir/${safe}-plan.md"
run_save_handoff_hp "$PROJECT_DIR" "$dir/${safe}-plan.md"
assert_contains "handoff_path is the explicit -plan.md path" \
    "$(read_field "$dir/.pending.json" handoff_path)" "${safe}-plan.md"

echo "test: --handoff-path to a file that doesn't exist resolves to null, not a fallback"
run_save_handoff_hp "$PROJECT_DIR" "$dir/${safe}-nonexistent.md"
assert_equals "handoff_path is null for a missing explicit path" \
    "$(read_field "$dir/.pending.json" handoff_path)" ""

echo "test: --handoff-path wins over an existing plain doc (/handoff-plan run after an earlier /handoff)"
printf '# Handoff\n## Done\n- work\n' >"$dir/${safe}.md"
run_save_handoff_hp "$PROJECT_DIR" "$dir/${safe}-plan.md"
assert_contains "explicit path wins even though the plain doc also exists" \
    "$(read_field "$dir/.pending.json" handoff_path)" "${safe}-plan.md"
rm -f "$dir"/*.md 2>/dev/null || true

# ---------------------------------------------------------------------------
# The star rule (docs/swarm-design.md § Plugin split): /handoff + /handoff-plan now
# live in the SAME plugin as save-handoff.sh, so CLAUDE_PLUGIN_ROOT resolves it
# reliably and neither skill has an excuse to reimplement the keying inline any
# more. This is the acceptance-criteria grep test — it pins the ABSENCE of the old
# inline recipe, not its presence.
echo "test: drift guard — /handoff calls save-handoff.sh instead of reimplementing the keying"
init_repo
dir="$(print_dir "$PROJECT_DIR")"
case "$dir" in
    */.claude/handoffs/????????????????) ok "script print-dir is the documented shape" ;;
    *) no "script print-dir shape mismatch ($dir)" ;;
esac
assert_file "SKILL.md exists" "$SKILL"
skill_txt="$(cat "$SKILL")"
assert_not_contains "skill has no inline sha1 reimplementation" "$skill_txt" "sha1"
assert_not_contains "skill has no inline cut -c1-16 reimplementation" "$skill_txt" "cut -c1-16"
assert_contains "skill calls save-handoff.sh" "$skill_txt" "save-handoff.sh"
assert_contains "skill calls it via CLAUDE_PLUGIN_ROOT" "$skill_txt" "CLAUDE_PLUGIN_ROOT"
assert_contains "skill uses --print-dir to find the keyed dir" "$skill_txt" "--print-dir"

echo "test: drift guard — /handoff-plan calls save-handoff.sh --handoff-path instead of reimplementing the keying"
assert_file "handoff-plan SKILL.md exists" "$SKILL_PLAN"
plan_txt="$(cat "$SKILL_PLAN")"
assert_not_contains "plan skill has no inline sha1 reimplementation" "$plan_txt" "sha1"
assert_not_contains "plan skill has no inline cut -c1-16 reimplementation" "$plan_txt" "cut -c1-16"
assert_contains "plan skill calls save-handoff.sh" "$plan_txt" "save-handoff.sh"
assert_contains "plan skill calls it via CLAUDE_PLUGIN_ROOT" "$plan_txt" "CLAUDE_PLUGIN_ROOT"
assert_contains "plan skill passes --handoff-path (resolve_handoff() can't match its -plan.md shape)" \
    "$plan_txt" "--handoff-path"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
