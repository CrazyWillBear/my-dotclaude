#!/usr/bin/env bash
#
# Tests for scripts/resume.sh — the SessionStart auto-resume hook.
#
# Black-box: we plant a resume pointer, run the actual hook in a real git repo,
# and assert on the resume instruction it injects, the pointer it removes, and
# (on a /compact resume) the nudge sentinel it resets. The hook is source-aware:
# /clear -> "implement the handoff" wording (fresh context), /compact -> "continue
# the handoff" wording + sentinel reset (so a later climb can re-nudge), and any
# other source falls back to "continue".
#
# Pointer resolution is 3-tier, in priority order: the new per-repo COMMON-DIR key
# (~/.claude/handoffs/<sha1(realpath(--git-common-dir))[:16]>/.pending.json), then
# the OLD per-repo TOPLEVEL key (one-release migration), then the legacy global
# ~/.claude/.pending-handoff. The hook consumes whichever it used. Identity is
# guarded per pointer: a pointer carrying git_common_dir matches on the common dir;
# an older one matches on git_toplevel.
#
# Covers: clear/compact/startup wording; common-dir keyed resume + consume;
# resume of the SAME shared pointer from a linked worktree; worktree-reuse
# (handoff written in a worktree, resumed from the primary tree -> EnterWorktree
# injection); old toplevel-keyed pointer migration; legacy global fallback;
# cross-repo isolation; the legacy wrong-repo guard; no-handoff silence; the
# no-handoff-path variant; the /compact sentinel reset proven by a re-nudge; and
# save-handoff's keyed pointer/doc writing.
#
# Run: bash plugins/workflow/tests/test_resume.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESUME="$PLUGIN_ROOT/scripts/resume.sh"
WATCHDOG="$PLUGIN_ROOT/scripts/watchdog.sh"
SAVE="$PLUGIN_ROOT/scripts/save-handoff.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
GLOBAL_HOME="$WORK/home"
mkdir -p "$GLOBAL_HOME/.claude/handoffs"
printf '# Handoff\n## Done\n- committed work\n## Next steps\n- resume\n' >"$GLOBAL_HOME/.claude/handoffs/feat-ctx.md"
HANDOFF_DOC="$GLOBAL_HOME/.claude/handoffs/feat-ctx.md"
# Legacy global pointer (migration fallback) — only planted by the legacy tests.
LEGACY="$GLOBAL_HOME/.claude/.pending-handoff"

PROJECT_DIR="$WORK/proj"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_empty() { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected silence, got: $2)"; fi; }
assert_equals() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_file() { if [ -f "$2" ]; then ok "$1"; else no "$1 (missing file $2)"; fi; }
assert_nofile() { if [ -f "$2" ]; then no "$1 (unexpected file $2)"; else ok "$1"; fi; }

g() { git -C "$PROJECT_DIR" "$@"; }

# common_dir_of <project_dir> — canonical --git-common-dir (realpath), exactly as
# resume.sh / save-handoff.sh compute it (the new per-repo key source).
common_dir_of() {
    HOME="$GLOBAL_HOME" python3 - "$1" <<'PY'
import sys, os, subprocess
pd = sys.argv[1]
raw = subprocess.run(["git", "-C", pd, "rev-parse", "--git-common-dir"],
                     capture_output=True, text=True).stdout.strip()
print(os.path.realpath(os.path.join(pd, raw)) if raw else "")
PY
}
# keyed_dir <key_src> — ~/.claude/handoffs/<sha1(key_src)[:16]>. key_src is a
# common dir (new keying) or a toplevel (old/migration keying).
keyed_dir() {
    HOME="$GLOBAL_HOME" python3 - "$1" <<'PY'
import sys, hashlib, os
key = hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16]
print(os.path.join(os.path.expanduser("~/.claude/handoffs"), key))
PY
}
# pending_path <key_src> — the keyed resume pointer path for a key source.
pending_path() { echo "$(keyed_dir "$1")/.pending.json"; }

# Convenience for the CURRENT repo (keyed by its common dir, the new scheme).
cur_common() { common_dir_of "$PROJECT_DIR"; }
cur_keyed() { keyed_dir "$(cur_common)"; }
cur_pending() { echo "$(cur_keyed)/.pending.json"; }

init_repo() {
    rm -rf "$PROJECT_DIR"
    rm -f "$LEGACY"
    # Clear any keyed pointers from a previous test (the keyed dir is stable for a
    # given common dir, which is constant for $PROJECT_DIR across tests).
    find "$GLOBAL_HOME/.claude/handoffs" -name '.pending.json' -delete 2>/dev/null || true
    mkdir -p "$PROJECT_DIR/.claude"
    g init -q
    g config user.email t@t.com
    g config user.name t
    printf 'seed\n' >"$PROJECT_DIR/.gitkeep"
    g add -A
    g commit -q -m base
}

# _pointer_json <path> <toplevel> <common_dir> <baseline> <branch> <handoff_path>
# An empty <common_dir> omits git_common_dir, simulating an OLD (pre-common-dir)
# pointer for the migration / legacy tiers.
_pointer_json() {
    python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import sys, json, os
path, top, cdir, base, branch, hdoc = sys.argv[1:7]
obj = {"handoff_path": hdoc or None, "branch": branch, "git_toplevel": top,
       "baseline_head": base, "session_id": "old-sid",
       "context_tokens": 200000, "ts": 0}
if cdir:
    obj["git_common_dir"] = cdir
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as fh:
    json.dump(obj, fh)
PY
}

# make_handoff <toplevel> <baseline> <branch> <handoff_path> — plant the NEW
# common-dir-keyed pointer for the CURRENT repo (git_common_dir set), recording
# <toplevel> as the working tree it was written in.
make_handoff() {
    local cdir
    cdir="$(cur_common)"
    _pointer_json "$(pending_path "$cdir")" "$1" "$cdir" "$2" "$3" "$4"
}

# make_handoff_foreign <key_src> <toplevel> <baseline> <branch> <handoff_path> —
# plant a pointer for ANOTHER repo, keyed by that repo's common dir (<key_src>), so
# resume from the current repo never reads it.
make_handoff_foreign() {
    _pointer_json "$(pending_path "$1")" "$2" "$1" "$3" "$4" "$5"
}

# make_handoff_legacy <toplevel> <baseline> <branch> <handoff_path> — plant ONLY
# the legacy global ~/.claude/.pending-handoff (migration fallback, no common dir).
make_handoff_legacy() { _pointer_json "$LEGACY" "$1" "" "$2" "$3" "$4"; }

# run_resume_in <project_dir> <source> <sid> — run the SessionStart hook with the
# given working dir + source.
run_resume_in() {
    printf '{"hook_event_name":"SessionStart","source":"%s","session_id":"%s"}' "$2" "$3" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
            bash "$RESUME"
}
# run_resume <source> <sid> — run from the primary $PROJECT_DIR.
run_resume() { run_resume_in "$PROJECT_DIR" "$1" "$2"; }

# run_save_handoff <project_dir> — run the shared writer the way the PreCompact
# hook does: no stdin, no args.
run_save_handoff() {
    HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        bash "$SAVE"
}

# make_transcript <file> <total> — last assistant entry sums to <total> tokens.
make_transcript() {
    python3 - "$1" "$2" <<'PY'
import sys, json
path, total = sys.argv[1], int(sys.argv[2])
rows = [
    {"type": "assistant", "message": {"role": "assistant", "usage": {
        "input_tokens": total, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 5}}},
]
with open(path, "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
}

run_watchdog() {
    printf '{"hook_event_name":"%s","session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$1" "$2" "$3" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
            bash "$WATCHDOG"
}

sentinel_path() {
    python3 - "$1" "$2" <<'PY'
import sys, hashlib, tempfile, os
prefix, sid = sys.argv[1], sys.argv[2]
key = hashlib.sha1(sid.encode()).hexdigest()[:16]
print(os.path.join(tempfile.gettempdir(), prefix + key + ".json"))
PY
}
nudged_path() { sentinel_path "workflow-nudged-" "$1"; }

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

# ---------------------------------------------------------------------------
echo "test: source=clear injects the 'implement' wording and consumes the keyed pointer"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
make_handoff "$top" "$base" "feat/ctx" "$HANDOFF_DOC"
PEND="$(cur_pending)"
assert_file "keyed pointer planted" "$PEND"
out=$(run_resume clear sid-r1)
assert_contains "emits a SessionStart additionalContext" "$out" '"hookEventName": "SessionStart"'
assert_contains "uses the implement wording" "$out" "implement the handoff"
assert_contains "names the handoff doc to resume" "$out" "feat-ctx.md"
assert_contains "names the branch" "$out" "feat/ctx"
assert_contains "tells the agent not to redo work" "$out" "do not redo"
assert_nofile "consumes the keyed pointer (resume once)" "$PEND"

# ---------------------------------------------------------------------------
echo "test: source=compact injects the 'continue' wording and resets the nudge sentinel"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
: >"$(nudged_path sid-r2)"            # pretend the 250k signal already fired this session
make_handoff "$top" "$base" "main" "$HANDOFF_DOC"
out=$(run_resume compact sid-r2)
assert_contains "uses the continue wording" "$out" "continue the handoff"
assert_nofile "resets the nudge sentinel" "$(nudged_path sid-r2)"
assert_nofile "consumes the keyed pointer" "$(cur_pending)"
# Proof the reset re-arms the cycle: a fresh >=NUDGE transcript re-nudges.
make_transcript "$WORK/renudge.jsonl" 260000
rout=$(run_watchdog UserPromptSubmit sid-r2 "$WORK/renudge.jsonl")
assert_contains "a later climb re-nudges after the reset" "$rout" "Context over budget"

# ---------------------------------------------------------------------------
echo "test: source=clear also resets the nudge sentinel (re-arms the wrap cycle)"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
: >"$(nudged_path sid-r2c)"            # pretend the 250k signal already fired this session
make_handoff "$top" "$base" "main" "$HANDOFF_DOC"
out=$(run_resume clear sid-r2c)
assert_contains "uses the implement wording" "$out" "implement the handoff"
assert_nofile "clear resets the nudge sentinel" "$(nudged_path sid-r2c)"
assert_nofile "consumes the keyed pointer" "$(cur_pending)"
# Proof the reset re-arms the cycle: a fresh transcript re-nudges.
make_transcript "$WORK/renudge-clear.jsonl" 260000
rout=$(run_watchdog UserPromptSubmit sid-r2c "$WORK/renudge-clear.jsonl")
assert_contains "a later climb re-nudges after the clear reset" "$rout" "Context over budget"

# ---------------------------------------------------------------------------
echo "test: an unknown source falls back to the 'continue' wording"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
make_handoff "$top" "$base" "main" "$HANDOFF_DOC"
out=$(run_resume startup sid-r3)
assert_contains "fallback uses the continue wording" "$out" "continue the handoff"

# ---------------------------------------------------------------------------
echo "test: the SAME shared pointer resumes from a linked worktree (common-dir keyed)"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
cdir="$(cur_common)"
WT="$WORK/wt-share"
g worktree add -q -b wt-share-br "$WT" >/dev/null 2>&1
# Pointer was written for this repo (common-dir keyed); git_toplevel is the worktree.
_pointer_json "$(pending_path "$cdir")" "$WT" "$cdir" "$base" "wt-share-br" "$HANDOFF_DOC"
out=$(run_resume_in "$WT" clear sid-wtshare)     # resume FROM the worktree
assert_contains "worktree resume finds the shared pointer" "$out" "implement the handoff"
assert_not_contains "no reuse injection (already in the worktree)" "$out" "EnterWorktree"
assert_nofile "shared pointer consumed from the worktree" "$(pending_path "$cdir")"

# ---------------------------------------------------------------------------
echo "test: worktree-reuse — a handoff written in a worktree, resumed from primary, injects EnterWorktree"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
cdir="$(cur_common)"
WT="$WORK/wt-reuse"
g worktree add -q -b wt-reuse-br "$WT" >/dev/null 2>&1
_pointer_json "$(pending_path "$cdir")" "$WT" "$cdir" "$base" "wt-reuse-br" "$HANDOFF_DOC"
out=$(run_resume clear sid-reuse)                # resume from the PRIMARY tree
assert_contains "reuse injects the EnterWorktree directive" "$out" "EnterWorktree(path=$WT)"
assert_contains "reuse names the worktree" "$out" "$WT"
assert_contains "reuse still points at the handoff doc" "$out" "feat-ctx.md"
assert_contains "reuse still implements the handoff" "$out" "implement the handoff"
assert_nofile "reuse consumes the shared pointer" "$(pending_path "$cdir")"

# ---------------------------------------------------------------------------
echo "test: migration — an OLD toplevel-keyed pointer (no git_common_dir) still resumes once"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
# Old kit: keyed by sha1(toplevel), pointer has no git_common_dir field.
_pointer_json "$(pending_path "$top")" "$top" "" "$base" "feat/ctx" "$HANDOFF_DOC"
assert_file "old toplevel-keyed pointer planted" "$(pending_path "$top")"
out=$(run_resume clear sid-mig)
assert_contains "migration: old pointer resumes" "$out" "implement the handoff"
assert_contains "migration: names the handoff doc" "$out" "feat-ctx.md"
assert_nofile "migration: old pointer consumed" "$(pending_path "$top")"

# ---------------------------------------------------------------------------
echo "test: legacy global fallback — only the legacy pointer present still resumes once"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
make_handoff_legacy "$top" "$base" "feat/ctx" "$HANDOFF_DOC"
assert_file "legacy global pointer planted" "$LEGACY"
out=$(run_resume clear sid-legacy)
assert_contains "legacy fallback resumes" "$out" "implement the handoff"
assert_nofile "legacy global pointer consumed" "$LEGACY"

# ---------------------------------------------------------------------------
echo "test: keyed pointer wins over a stale legacy pointer (keyed read first)"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
make_handoff "$top" "$base" "feat/ctx" "$HANDOFF_DOC"          # keyed (common-dir)
make_handoff_legacy "$top" "$base" "main" ""                   # legacy, no doc
out=$(run_resume clear sid-pref)
assert_contains "resumes from the keyed pointer (has a doc path)" "$out" "feat-ctx.md"
assert_nofile "keyed pointer consumed" "$(cur_pending)"
assert_file "legacy pointer untouched (only the keyed one was used)" "$LEGACY"

# ---------------------------------------------------------------------------
echo "test: cross-repo isolation — a foreign repo's keyed pointer never resumes here"
init_repo
make_handoff_foreign "/some/other/repoB/.git" "/some/other/repoB" "deadbeef" "main" "$HANDOFF_DOC"
out=$(run_resume clear sid-iso)
assert_empty "this repo has no pointer of its own: silent" "$out"
assert_file "the foreign repo's keyed pointer is left untouched" "$(pending_path "/some/other/repoB/.git")"

# ---------------------------------------------------------------------------
echo "test: legacy wrong-repo guard — a legacy pointer from another repo is a no-op"
init_repo
base="$(g rev-parse HEAD)"
make_handoff_legacy "/some/other/repo" "$base" "main" ""
out=$(run_resume clear sid-r4)
assert_empty "wrong repo: silent" "$out"
assert_file "wrong repo: legacy pointer preserved" "$LEGACY"

# ---------------------------------------------------------------------------
echo "test: no handoff present stays silent"
init_repo
out=$(run_resume clear sid-r5)
assert_empty "no handoff: silent" "$out"

# ---------------------------------------------------------------------------
echo "test: a handoff without a plan path uses the no-plan phrasing"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
make_handoff "$top" "$base" "main" ""
out=$(run_resume clear sid-r6)
assert_contains "uses the no-plan resume phrasing" "$out" "continue the prior in-progress work"

# ---------------------------------------------------------------------------
echo "test: a PreCompact-written handoff makes a manual /compact re-inject the handoff + re-arm"
init_repo
top="$(g rev-parse --show-toplevel)"
pc_branch="$(g rev-parse --abbrev-ref HEAD)"
pc_safe="${pc_branch//\//-}"
kd="$(cur_keyed)"
mkdir -p "$kd"
# Pre-create the handoff doc in the KEYED dir so resolve_handoff() finds it.
printf '# Handoff\n## Done\n- base commit\n' >"$kd/${pc_safe}.md"
: >"$(nudged_path sid-pc)"             # 250k signal already fired this session
run_save_handoff "$PROJECT_DIR"        # simulate the PreCompact hook (no args)
PEND="$kd/.pending.json"
assert_file "PreCompact writes a keyed pointer" "$PEND"
assert_equals "pointer records this repo" "$(read_field "$PEND" git_toplevel)" "$top"
assert_equals "pointer records the common dir" "$(read_field "$PEND" git_common_dir)" "$(cur_common)"
assert_contains "pointer records the keyed handoff doc" "$(read_field "$PEND" handoff_path)" "${pc_safe}.md"
out=$(run_resume compact sid-pc)
assert_contains "manual compact re-injects the handoff" "$out" "continue the handoff"
assert_nofile "manual compact consumes the keyed pointer" "$PEND"
assert_nofile "manual compact resets the nudge sentinel" "$(nudged_path sid-pc)"

# ---------------------------------------------------------------------------
echo "test: a manual /compact with NO handoff still re-arms the 250k signal (silent reset)"
init_repo
: >"$(nudged_path sid-nh)"             # 250k signal already fired this session
out=$(run_resume compact sid-nh)       # no handoff present
assert_empty "no handoff: silent" "$out"
assert_nofile "no-handoff compact resets the nudge sentinel" "$(nudged_path sid-nh)"
# Proof the reset re-armed the cycle: a fresh >=NUDGE transcript re-nudges.
make_transcript "$WORK/renudge-nh.jsonl" 260000
rout=$(run_watchdog UserPromptSubmit sid-nh "$WORK/renudge-nh.jsonl")
assert_contains "a later climb re-nudges after the no-handoff reset" "$rout" "Context over budget"

# ---------------------------------------------------------------------------
echo "test: save-handoff in a non-git dir writes no pointer (PreCompact junk guard)"
init_repo
NONREPO="$WORK/nonrepo"
mkdir -p "$NONREPO"
before="$(find "$GLOBAL_HOME/.claude/handoffs" -name '.pending.json' 2>/dev/null | wc -l)"
run_save_handoff "$NONREPO"
after="$(find "$GLOBAL_HOME/.claude/handoffs" -name '.pending.json' 2>/dev/null | wc -l)"
assert_equals "no pointer is written outside a git repo" "$after" "$before"
assert_nofile "no legacy pointer either" "$LEGACY"

# ---------------------------------------------------------------------------
echo "test: save-handoff resolves handoff_path to null when no handoff doc exists"
init_repo
# Remove all handoff docs so the resolver finds nothing.
find "$GLOBAL_HOME/.claude/handoffs" -name '*.md' -delete 2>/dev/null || true
run_save_handoff "$PROJECT_DIR"
PEND="$(cur_pending)"
assert_file "pointer is written even with no handoff doc" "$PEND"
assert_equals "handoff_path is null when no handoff doc exists" \
    "$(read_field "$PEND" handoff_path)" ""

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
