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
# Pointer resolution is per-repo keyed first
# (~/.claude/handoffs/<sha1(toplevel)[:16]>/.pending.json), then the legacy global
# ~/.claude/.pending-handoff (one-release migration fallback, repo-guarded). The
# hook consumes whichever it used.
#
# Covers: clear/compact/startup wording; keyed-pointer resume + consume; legacy
# global fallback; cross-repo isolation (a foreign repo's pointer never resumes
# here); the legacy wrong-repo guard; no-handoff silence; the no-handoff-path
# variant; the /compact sentinel reset proven by a re-nudge; and save-handoff's
# keyed pointer/doc writing.
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

# keyed_dir <toplevel> — the per-repo handoff dir resume.sh / save-handoff.sh
# compute: ~/.claude/handoffs/<sha1(toplevel)[:16]> (under $GLOBAL_HOME).
keyed_dir() {
    HOME="$GLOBAL_HOME" python3 - "$1" <<'PY'
import sys, hashlib, os
top = sys.argv[1]
key = hashlib.sha1(top.encode()).hexdigest()[:16]
print(os.path.join(os.path.expanduser("~/.claude/handoffs"), key))
PY
}
# pending_path <toplevel> — the keyed resume pointer path for a repo.
pending_path() { echo "$(keyed_dir "$1")/.pending.json"; }

init_repo() {
    rm -rf "$PROJECT_DIR"
    rm -f "$LEGACY"
    # Clear any keyed pointers from a previous test (the keyed dir is stable for a
    # given toplevel, which is constant for $PROJECT_DIR across tests).
    find "$GLOBAL_HOME/.claude/handoffs" -name '.pending.json' -delete 2>/dev/null || true
    mkdir -p "$PROJECT_DIR/.claude"
    g init -q
    g config user.email t@t.com
    g config user.name t
    printf 'seed\n' >"$PROJECT_DIR/.gitkeep"
    g add -A
    g commit -q -m base
}

# _pointer_json <path> <toplevel> <baseline> <branch> <handoff_path>
_pointer_json() {
    python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import sys, json, os
path, top, base, branch, hdoc = sys.argv[1:6]
obj = {"handoff_path": hdoc or None, "branch": branch, "git_toplevel": top,
       "baseline_head": base, "session_id": "old-sid",
       "context_tokens": 200000, "ts": 0}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as fh:
    json.dump(obj, fh)
PY
}

# make_handoff <toplevel> <baseline> <branch> <handoff_path> — plant the per-repo
# KEYED pointer for <toplevel> (the path resume.sh reads first).
make_handoff() { _pointer_json "$(pending_path "$1")" "$1" "$2" "$3" "$4"; }

# make_handoff_legacy <toplevel> <baseline> <branch> <handoff_path> — plant ONLY
# the legacy global ~/.claude/.pending-handoff (migration fallback).
make_handoff_legacy() { _pointer_json "$LEGACY" "$1" "$2" "$3" "$4"; }

# run_resume <source> <sid> — run the SessionStart hook with the given source.
run_resume() {
    printf '{"hook_event_name":"SessionStart","source":"%s","session_id":"%s"}' "$1" "$2" \
        | HOME="$GLOBAL_HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
            bash "$RESUME"
}

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
PEND="$(pending_path "$top")"
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
: >"$(nudged_path sid-r2)"            # pretend the 100k signal already fired this session
make_handoff "$top" "$base" "main" "$HANDOFF_DOC"
out=$(run_resume compact sid-r2)
assert_contains "uses the continue wording" "$out" "continue the handoff"
assert_nofile "resets the nudge sentinel" "$(nudged_path sid-r2)"
assert_nofile "consumes the keyed pointer" "$(pending_path "$top")"
# Proof the reset re-arms the cycle: a fresh >=NUDGE transcript re-nudges.
make_transcript "$WORK/renudge.jsonl" 200000
rout=$(run_watchdog UserPromptSubmit sid-r2 "$WORK/renudge.jsonl")
assert_contains "a later climb re-nudges after the reset" "$rout" "Context over budget"

# ---------------------------------------------------------------------------
echo "test: source=clear also resets the nudge sentinel (re-arms the wrap cycle)"
init_repo
top="$(g rev-parse --show-toplevel)"
base="$(g rev-parse HEAD)"
: >"$(nudged_path sid-r2c)"            # pretend the 100k signal already fired this session
make_handoff "$top" "$base" "main" "$HANDOFF_DOC"
out=$(run_resume clear sid-r2c)
assert_contains "uses the implement wording" "$out" "implement the handoff"
assert_nofile "clear resets the nudge sentinel" "$(nudged_path sid-r2c)"
assert_nofile "consumes the keyed pointer" "$(pending_path "$top")"
# Proof the reset re-arms the cycle: a fresh transcript re-nudges.
make_transcript "$WORK/renudge-clear.jsonl" 130000
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
make_handoff "$top" "$base" "feat/ctx" "$HANDOFF_DOC"          # keyed
make_handoff_legacy "$top" "$base" "main" ""                   # legacy, no doc
out=$(run_resume clear sid-pref)
assert_contains "resumes from the keyed pointer (has a doc path)" "$out" "feat-ctx.md"
assert_nofile "keyed pointer consumed" "$(pending_path "$top")"
assert_file "legacy pointer untouched (only the keyed one was used)" "$LEGACY"

# ---------------------------------------------------------------------------
echo "test: cross-repo isolation — a foreign repo's keyed pointer never resumes here"
init_repo
make_handoff "/some/other/repoB" "deadbeef" "main" "$HANDOFF_DOC"
out=$(run_resume clear sid-iso)
assert_empty "this repo has no pointer of its own: silent" "$out"
assert_file "the foreign repo's keyed pointer is left untouched" "$(pending_path /some/other/repoB)"

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
kd="$(keyed_dir "$top")"
mkdir -p "$kd"
# Pre-create the handoff doc in the KEYED dir so resolve_handoff() finds it.
printf '# Handoff\n## Done\n- base commit\n' >"$kd/${pc_safe}.md"
: >"$(nudged_path sid-pc)"             # 100k signal already fired this session
run_save_handoff "$PROJECT_DIR"        # simulate the PreCompact hook (no args)
PEND="$kd/.pending.json"
assert_file "PreCompact writes a keyed pointer" "$PEND"
assert_equals "pointer records this repo" "$(read_field "$PEND" git_toplevel)" "$top"
assert_contains "pointer records the keyed handoff doc" "$(read_field "$PEND" handoff_path)" "${pc_safe}.md"
out=$(run_resume compact sid-pc)
assert_contains "manual compact re-injects the handoff" "$out" "continue the handoff"
assert_nofile "manual compact consumes the keyed pointer" "$PEND"
assert_nofile "manual compact resets the nudge sentinel" "$(nudged_path sid-pc)"

# ---------------------------------------------------------------------------
echo "test: a manual /compact with NO handoff still re-arms the 100k signal (silent reset)"
init_repo
: >"$(nudged_path sid-nh)"             # 100k signal already fired this session
out=$(run_resume compact sid-nh)       # no handoff present
assert_empty "no handoff: silent" "$out"
assert_nofile "no-handoff compact resets the nudge sentinel" "$(nudged_path sid-nh)"
# Proof the reset re-armed the cycle: a fresh >=NUDGE transcript re-nudges.
make_transcript "$WORK/renudge-nh.jsonl" 200000
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
top="$(g rev-parse --show-toplevel)"
# Remove all handoff docs so the resolver finds nothing.
find "$GLOBAL_HOME/.claude/handoffs" -name '*.md' -delete 2>/dev/null || true
run_save_handoff "$PROJECT_DIR"
PEND="$(pending_path "$top")"
assert_file "pointer is written even with no handoff doc" "$PEND"
assert_equals "handoff_path is null when no handoff doc exists" \
    "$(read_field "$PEND" handoff_path)" ""

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
