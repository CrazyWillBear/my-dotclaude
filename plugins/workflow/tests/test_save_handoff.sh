#!/usr/bin/env bash
#
# Tests for scripts/save-handoff.sh — the per-repo keyed handoff writer.
#
# Black-box: we drive a real git repo, run the actual script, and assert on the
# keyed dir it prints (--print-dir), the keyed pointer it writes (no args), and
# the doc it resolves into handoff_path. A drift guard cross-checks that the
# /handoff skill documents the SAME keying recipe the script implements, so the
# skill's inline pointer writer can't silently diverge.
#
# Keying: ~/.claude/handoffs/<sha1(canonical --git-common-dir)[:16]>/ holding
# .pending.json (pointer) and <branch-slug>.md (doc). Keyed by the shared common
# .git so the primary tree and all its linked worktrees share one pointer.
#
# Run: bash plugins/workflow/tests/test_save_handoff.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SAVE="$PLUGIN_ROOT/scripts/save-handoff.sh"
# The /handoff skill lives in the sibling personal-tools plugin.
SKILL="$PLUGIN_ROOT/../personal-tools/skills/handoff/SKILL.md"
# /handoff-plan writes the same keyed pointer inline, so it carries the same drift risk.
SKILL_PLAN="$PLUGIN_ROOT/../personal-tools/skills/handoff-plan/SKILL.md"
# /pipeline writes the same keyed pointer inline for its resume state, so it too.
SKILL_PIPE="$PLUGIN_ROOT/skills/pipeline/SKILL.md"

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
echo "test: no-args falls back to the /pipeline state doc when no plain doc exists"
init_repo
branch="$(g rev-parse --abbrev-ref HEAD)"
safe="${branch//\//-}"
dir="$(print_dir "$PROJECT_DIR")"
mkdir -p "$dir"
rm -f "$dir"/*.md 2>/dev/null || true
printf '# Pipeline state\nphase: built\n' >"$dir/${safe}-pipeline.md"
run_save_handoff "$PROJECT_DIR"
assert_contains "handoff_path resolves the pipeline state doc" \
    "$(read_field "$dir/.pending.json" handoff_path)" "${safe}-pipeline.md"

echo "test: the plain /handoff doc wins over the pipeline state doc when both exist"
printf '# Handoff\n## Done\n- work\n' >"$dir/${safe}.md"
run_save_handoff "$PROJECT_DIR"
hp="$(read_field "$dir/.pending.json" handoff_path)"
case "$hp" in
    *"${safe}-pipeline.md") no "plain doc should win over pipeline doc ($hp)" ;;
    *"${safe}.md")          ok "plain doc wins over pipeline doc" ;;
    *)                      no "handoff_path resolved neither doc ($hp)" ;;
esac
rm -f "$dir"/*.md 2>/dev/null || true

# ---------------------------------------------------------------------------
echo "test: drift guard — SKILL.md documents the same keyed recipe as the script"
init_repo
dir="$(print_dir "$PROJECT_DIR")"
case "$dir" in
    */.claude/handoffs/????????????????) ok "script print-dir is the documented shape" ;;
    *) no "script print-dir shape mismatch ($dir)" ;;
esac
assert_file "SKILL.md exists" "$SKILL"
skill_txt="$(cat "$SKILL")"
assert_contains "skill documents sha1 keying" "$skill_txt" "sha1"
assert_contains "skill documents the cut -c1-16 key length" "$skill_txt" "cut -c1-16"
assert_contains "skill keys by the common dir" "$skill_txt" "--git-common-dir"
assert_contains "skill names the .pending.json pointer" "$skill_txt" ".pending.json"
assert_contains "skill names the keyed handoffs dir" "$skill_txt" "~/.claude/handoffs/"

# /handoff-plan writes the same keyed pointer inline, so the same recipe must be
# documented there too or its inline writer could silently diverge.
assert_file "handoff-plan SKILL.md exists" "$SKILL_PLAN"
plan_txt="$(cat "$SKILL_PLAN")"
assert_contains "plan skill documents sha1 keying" "$plan_txt" "sha1"
assert_contains "plan skill documents the cut -c1-16 key length" "$plan_txt" "cut -c1-16"
assert_contains "plan skill keys by the common dir" "$plan_txt" "--git-common-dir"
assert_contains "plan skill names the .pending.json pointer" "$plan_txt" ".pending.json"
assert_contains "plan skill names the keyed handoffs dir" "$plan_txt" "~/.claude/handoffs/"

# /pipeline's step-9 resume state writes the same keyed pointer inline, so the same
# recipe must be documented there too or its inline writer could silently diverge.
assert_file "pipeline SKILL.md exists" "$SKILL_PIPE"
pipe_txt="$(cat "$SKILL_PIPE")"
assert_contains "pipeline skill documents sha1 keying" "$pipe_txt" "sha1"
assert_contains "pipeline skill documents the cut -c1-16 key length" "$pipe_txt" "cut -c1-16"
assert_contains "pipeline skill keys by the common dir" "$pipe_txt" "--git-common-dir"
assert_contains "pipeline skill names the .pending.json pointer" "$pipe_txt" ".pending.json"
assert_contains "pipeline skill names the keyed handoffs dir" "$pipe_txt" "~/.claude/handoffs/"
assert_contains "pipeline skill names its -pipeline.md state doc" "$pipe_txt" "-pipeline.md"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
