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
# Keying: ~/.claude/handoffs/<sha1(git_toplevel)[:16]>/ holding .pending.json
# (pointer) and <branch-slug>.md (doc).
#
# Run: bash plugins/workflow/tests/test_save_handoff.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SAVE="$PLUGIN_ROOT/scripts/save-handoff.sh"
# The /handoff skill lives in the sibling personal-tools plugin.
SKILL="$PLUGIN_ROOT/../personal-tools/skills/handoff/SKILL.md"

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

# expected_dir <toplevel> — the keyed dir computed independently of the script.
expected_dir() {
    HOME="$GLOBAL_HOME" python3 - "$1" <<'PY'
import sys, hashlib, os
print(os.path.join(os.path.expanduser("~/.claude/handoffs"),
                   hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16]))
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
assert_equals "--print-dir matches the independent sha1 keying" "$dir" "$(expected_dir "$top")"
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
assert_equals "records baseline_head" "$(read_field "$PEND" baseline_head)" "$head"
assert_equals "records branch" "$(read_field "$PEND" branch)" "$branch"
assert_contains "handoff_path resolves the keyed doc" "$(read_field "$PEND" handoff_path)" "${safe}.md"
assert_contains "handoff_path is under the keyed dir" "$(read_field "$PEND" handoff_path)" "$dir"
assert_equals "pointer carries the full schema" "$(pointer_keys "$PEND")" \
    "baseline_head,branch,context_tokens,git_toplevel,handoff_path,session_id,ts"

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
assert_contains "skill names the .pending.json pointer" "$skill_txt" ".pending.json"
assert_contains "skill names the keyed handoffs dir" "$skill_txt" "~/.claude/handoffs/"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
