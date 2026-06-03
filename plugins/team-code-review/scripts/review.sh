#!/usr/bin/env bash
#
# Stop hook for the team-code-review plugin.
#
# Commit-gated code review. Fires only AFTER a commit lands: when the work tree
# is clean of tracked changes and HEAD has advanced past the last commit we
# reviewed this session, it emits a "block" decision asking the main agent to
# hand the new commit(s) to the `code-reviewer` subagent. While tracked changes
# are still uncommitted it stays silent, so it never races the commit gate
# (suggest-commit.sh): commit first, then review.
#
# Design notes:
#   * Hooks are plain shell commands; they cannot call the Task tool. So instead
#     of reviewing here, we hand the main agent an instruction.
#   * Fail open: any error / missing dependency exits 0 so we never wedge the
#     user's session.
#   * Loop safety is the per-session reviewed-HEAD marker, NOT stop_hook_active.
#     In the commit->review chain the review stop IS a stop-hook continuation
#     (the commit gate blocked first), so bailing on stop_hook_active would mean
#     the review never runs. Instead we record each HEAD we review and stay
#     silent until a new commit moves HEAD — that bounds us to one nudge per
#     commit without suppressing the post-commit review.

# Capture the hook JSON into an env var (avoids stdin/quoting headaches in python).
export HOOK_INPUT="$(cat)"

# Need python3 and git; without either, bow out quietly (never wedge the session).
command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Quoted heredoc so literal punctuation/apostrophes in the body can never break
# shell quoting. HOOK_INPUT travels via the environment, so stdin stays free.
python3 <<"PY" || exit 0
import os, json, sys, re, tempfile, hashlib, posixpath, subprocess

raw = os.environ.get("HOOK_INPUT", "")
try:
    data = json.loads(raw) if raw else {}
except Exception:
    sys.exit(0)

project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()

def git(*args):
    # Run a git command in the project dir; return stripped stdout, or None on
    # any failure (not a repo, git error, etc.). Never raises.
    try:
        out = subprocess.run(
            ["git", "-C", project_dir, *args],
            capture_output=True, text=True, timeout=10,
        )
    except Exception:
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip()

# Must be a work tree with at least one commit.
if git("rev-parse", "--is-inside-work-tree") != "true":
    sys.exit(0)
current_head = git("rev-parse", "HEAD")
if not current_head:
    sys.exit(0)

# Per-session state: the last commit we reviewed. Seeded on first sight to the
# session's starting HEAD so we never review pre-session history.
session_id = str(data.get("session_id") or "default")
key = hashlib.sha1(session_id.encode()).hexdigest()[:16]
state_path = os.path.join(tempfile.gettempdir(), "team-code-review-head-" + key + ".json")

state = {}
try:
    with open(state_path) as fh:
        loaded = json.load(fh)
    if isinstance(loaded, dict):
        state = loaded
except Exception:
    state = {}

def save_state():
    try:
        with open(state_path, "w") as fh:
            json.dump(state, fh)
    except Exception:
        pass

# First sight this session: record the baseline HEAD and bow out. Commits that
# predate the session are not ours to review. (Edge: if the very first stop of
# the session already sits on a fresh post-work commit, that one batch is not
# auto-reviewed — we cannot know the pre-session HEAD.)
if "reviewed" not in state:
    state["reviewed"] = current_head
    save_state()
    sys.exit(0)

# Defer to the commit gate while tracked changes are still uncommitted: review
# only ever runs on a clean tree, so the two stop hooks never block the same
# stop. `git diff --quiet HEAD` exits nonzero when tracked changes differ from
# HEAD (staged or unstaged); untracked files are ignored, matching /commit.
try:
    dirty = subprocess.run(
        ["git", "-C", project_dir, "diff", "--quiet", "HEAD"],
        capture_output=True, timeout=10,
    ).returncode != 0
except Exception:
    sys.exit(0)
if dirty:
    sys.exit(0)

reviewed = state.get("reviewed")
if reviewed == current_head:
    sys.exit(0)  # nothing new committed since the last review

# Files touched by the new commit(s), reviewed..HEAD. If the old marker is no
# longer reachable (a rebase / amend / gc rewrote history out from under us),
# fall back to just HEAD's own change. diff-tree --root keeps that working even
# when HEAD is the repo's very first commit, where HEAD~1 has no parent.
names = git("diff", "--name-only", str(reviewed) + ".." + current_head)
if names is None:
    names = git("diff-tree", "--no-commit-id", "--name-only", "-r", "--root", current_head) or ""
changed = [p for p in names.splitlines() if p.strip()]

# Drop files that are not worth a code review: documentation, dependency
# lockfiles, and machine-generated code. We never want to nag about these.
_LOCKFILES = {
    "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
    "bun.lockb", "composer.lock", "poetry.lock", "pdm.lock", "pipfile.lock",
    "cargo.lock", "go.sum", "go.work.sum", "flake.lock", "packages.lock.json",
    "podfile.lock", "mix.lock", "pubspec.lock", "gradle.lockfile",
}
_DOC_EXTS = {".md", ".mdx", ".markdown", ".rst", ".adoc", ".txt"}
_GENERATED_NAME = re.compile(
    r"(\.min\.(js|css)|\.bundle\.js|_pb2(_grpc)?\.py|\.pb\.go|\.g\.dart"
    r"|\.freezed\.dart|\.generated\.[^.]+)$",
    re.IGNORECASE,
)
_GENERATED_DIRS = {
    "node_modules", "vendor", "dist", "build", ".next", "__generated__",
    "generated",
}

def looks_generated(path):
    # Cheap, reliable marker emitted by many codegen tools (protobuf, Go,
    # thrift, etc.): an "@generated" or "DO NOT EDIT" line near the top.
    try:
        with open(path, "r", errors="ignore") as fh:
            head = fh.read(4096).lower()
    except Exception:
        return False
    return "@generated" in head or "do not edit" in head

def skip(path):
    norm = path.replace("\\", "/")
    base = posixpath.basename(norm).lower()
    if base in _LOCKFILES:
        return True
    if posixpath.splitext(base)[1] in _DOC_EXTS:
        return True
    if _GENERATED_NAME.search(base):
        return True
    if set(norm.split("/")) & _GENERATED_DIRS:
        return True
    return looks_generated(path)

# git paths are repo-relative; make them absolute for the reviewer and the
# content-sniffing filter. Deletions (path no longer on disk) are not reviewable.
abs_changed = [os.path.join(project_dir, p) for p in changed]
reviewable = [p for p in abs_changed if os.path.exists(p) and not skip(p)]

# Mark this commit reviewed up front, BEFORE we emit the block. This bounds us
# to one nudge per commit (even when every file was filtered out), and it is a
# deliberate no-retry trade-off: if the agent ignores or drops the block, or the
# session ends right after this stop, the commit stays recorded as reviewed and
# is never re-flagged. We accept that over advancing the marker only after a
# successful record-review.sh, which would couple the marker to the agent and
# could wedge the session if recording never lands.
state["reviewed"] = current_head
save_state()

if not reviewable:
    sys.exit(0)

plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
if plugin_root:
    rubric = os.path.join(plugin_root, "skills", "review-rubric", "SKILL.md")
    recorder = os.path.join(plugin_root, "scripts", "record-review.sh")
else:
    rubric = "the team review rubric (skills/review-rubric/SKILL.md in this plugin)"
    recorder = "scripts/record-review.sh (in the team-code-review plugin)"

record_note = (
    "\n\nAfter you report, record the result so this project keeps a review "
    "history (view it later with /review-history). Pipe a compact JSON object "
    "to the recorder using a quoted heredoc, which keeps the quoting simple:\n\n"
    "bash \"" + recorder + "\" <<\"REVIEW\"\n"
    "{\"verdict\": \"APPROVE\", \"files\": [\"/abs/path\"], \"findings\": "
    "[{\"severity\": \"blocker\", \"path\": \"/abs/path\", \"line\": 0, "
    "\"note\": \"one sentence\"}]}\n"
    "REVIEW\n\n"
    "Use the real verdict (APPROVE / APPROVE WITH NITS / CHANGES REQUESTED), "
    "one findings entry per issue (empty array if none), keep each note to one "
    "sentence, and omit \"line\" if you do not have it."
)

file_list = "\n".join("  - " + p for p in reviewable)

# Review output can be plain-language ("plain") or technical (the default,
# severity-grouped report aimed at developers). Resolution order, first hit wins:
#   1. <project>/.claude/review-audience   (per-project override)
#   2. ~/.claude/review-audience           (user-wide default; non-developer setup writes this)
#   3. "technical"                          (fallback)
def read_audience(base):
    try:
        with open(os.path.join(base, ".claude", "review-audience")) as fh:
            marker = fh.read().strip().lower()
    except Exception:
        return None
    return marker if marker in ("plain", "technical") else None

audience = (
    read_audience(project_dir)
    or read_audience(os.path.expanduser("~"))
    or "technical"
)

if audience == "plain":
    reason = (
        "Automatic code review (team-code-review plugin). These file(s) were "
        "just committed and have not been reviewed yet:\n"
        + file_list
        + "\n\nUse the Task tool to launch the `code-reviewer` subagent. Give it "
        "the exact file paths above and tell it to apply the team rubric at:\n  "
        + rubric
        + "\n\nThe person you are helping is NOT a programmer. The technical "
        "findings from the subagent are for you, not for them: use them to fix "
        "any real problems it reports (bugs, security issues, breakage). Then give a "
        "short, friendly, plain-English summary of what you did — what was "
        "wrong, what you changed, and why it matters to them. No jargon, no "
        "severity labels, no file:line references. If nothing needed fixing, "
        "say so in one reassuring sentence."
        + record_note
    )
else:
    reason = (
        "Auto code-review (team-code-review plugin). These file(s) were just "
        "committed and have not been reviewed yet:\n"
        + file_list
        + "\n\nUse the Task tool to launch the `code-reviewer` subagent. Give it "
        "the exact file paths above and tell it to apply the team rubric at:\n  "
        + rubric
        + "\n\nWhen the subagent reports back, summarize its findings for me "
        "grouped by severity (blocker / warning / nit). If the changes are "
        "trivial (docs, comments, formatting) you may note that briefly and stop."
        + record_note
    )

print(json.dumps({"decision": "block", "reason": reason}))
sys.exit(0)
PY
