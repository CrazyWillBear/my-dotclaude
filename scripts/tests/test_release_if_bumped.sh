#!/usr/bin/env bash
#
# Tests for scripts/release-if-bumped.sh — creates a GitHub Release when the
# VERSION file is ahead of the latest v* git tag, no-ops otherwise.
#
# Black-box: we stub `git` and `gh` via PATH shims that log invocations to a
# file. The script is driven with REPO_ROOT pointing at a fake repo tree.
#
# Covers:
#   * VERSION ahead of latest tag -> tag created, `gh release create` called
#     with --generate-notes
#   * VERSION equal to latest tag -> no tag, no release (no-op)
#   * No existing v* tags yet -> treated as 0.0.0, so any VERSION triggers
#     a release
#   * duplicate tag guard: if the tag already exists, no duplicate is created
#
# Run: bash scripts/tests/test_release_if_bumped.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_SCRIPT="$SCRIPTS_ROOT/release-if-bumped.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in: $2)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected '$3' in: $2)" ;; *) ok "$1" ;; esac; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3' got '$2')"; fi; }
assert_exit()         { if [ "$2" -eq "$3" ]; then ok "$1"; else no "$1 (want exit $3, got $2)"; fi; }

# ---------------------------------------------------------------------------
# Stub infrastructure
# ---------------------------------------------------------------------------

STUB_BIN="$WORK/bin"
GIT_LOG="$WORK/git.log"
GH_LOG="$WORK/gh.log"
EXISTING_TAGS_FILE="$WORK/existing_tags"
CREATED_TAGS_FILE="$WORK/created_tags"

mkdir -p "$STUB_BIN"

# Build a fake `git` stub that:
#   - Responds to `git tag --list 'v*'` with the content of $EXISTING_TAGS_FILE
#   - Responds to `git tag <tagname>` by appending the tag to $CREATED_TAGS_FILE
#   - For all other git commands, logs and exits 0
make_git_stub() {
    local existing_tags="${1:-}"
    printf '%s\n' "$existing_tags" > "$EXISTING_TAGS_FILE"
    : > "$CREATED_TAGS_FILE"

    # Use a regular (double-quoted) heredoc so variables expand at write time.
    cat > "$STUB_BIN/git" <<GITSTUB
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >> "${GIT_LOG}"

if [ "\${1:-}" = "tag" ] && [ "\${2:-}" = "--list" ]; then
    cat "${EXISTING_TAGS_FILE}"
    exit 0
fi

if [ "\${1:-}" = "tag" ] && [ \$# -eq 2 ]; then
    printf '%s\n' "\$2" >> "${CREATED_TAGS_FILE}"
    exit 0
fi

exit 0
GITSTUB
    chmod +x "$STUB_BIN/git"
}

# Build a fake `gh` stub that logs all invocations and exits 0.
make_gh_stub() {
    : > "$GH_LOG"
    cat > "$STUB_BIN/gh" <<GHSTUB
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "${GH_LOG}"
exit 0
GHSTUB
    chmod +x "$STUB_BIN/gh"
}

# Set up a minimal fake repo with just a VERSION file.
setup_repo() {
    local ver="$1"
    rm -rf "$WORK/repo"
    mkdir -p "$WORK/repo"
    printf '%s\n' "$ver" > "$WORK/repo/VERSION"
}

# Run the release script with stubs on PATH.
run_release() {
    : > "$GIT_LOG"
    : > "$GH_LOG"
    out=$(REPO_ROOT="$WORK/repo" PATH="$STUB_BIN:$PATH" bash "$RELEASE_SCRIPT" 2>&1)
    rc=$?
}

# ---------------------------------------------------------------------------
echo "test: VERSION ahead of latest tag -> tag + release created"
setup_repo "0.2.0"
make_git_stub "v0.1.0"
make_gh_stub
run_release
assert_exit "exits 0 when releasing" "$rc" 0

git_calls=$(cat "$GIT_LOG")
gh_calls=$(cat "$GH_LOG")
created=$(cat "$CREATED_TAGS_FILE")

assert_contains "git tag v0.2.0 created" "$git_calls" "git tag v0.2.0"
assert_contains "gh release create called" "$gh_calls" "gh release create v0.2.0"
assert_contains "gh release has --generate-notes" "$gh_calls" "--generate-notes"
assert_equals "created_tags file has v0.2.0" "$created" "v0.2.0"

# ---------------------------------------------------------------------------
echo "test: VERSION equal to latest tag -> no-op (no tag, no release)"
setup_repo "0.1.0"
make_git_stub "v0.1.0"
make_gh_stub
run_release
assert_exit "exits 0 when no-op" "$rc" 0

git_calls=$(cat "$GIT_LOG")
gh_calls=$(cat "$GH_LOG")
created=$(cat "$CREATED_TAGS_FILE")

assert_not_contains "git tag NOT created for existing version" "$git_calls" "git tag v0.1.0"
assert_equals "gh NOT called on no-op" "$gh_calls" ""
assert_equals "no tags created" "$created" ""

# ---------------------------------------------------------------------------
echo "test: no existing v* tags -> any VERSION triggers a release"
setup_repo "0.1.0"
make_git_stub ""      # empty list -> no existing tags
make_gh_stub
run_release
assert_exit "exits 0 when first release" "$rc" 0

git_calls=$(cat "$GIT_LOG")
gh_calls=$(cat "$GH_LOG")

assert_contains "git tag v0.1.0 created (first release)" "$git_calls" "git tag v0.1.0"
assert_contains "gh release create v0.1.0" "$gh_calls" "gh release create v0.1.0"
assert_contains "gh release has --generate-notes (first release)" "$gh_calls" "--generate-notes"

# ---------------------------------------------------------------------------
echo "test: duplicate tag guard — tag already exists, no second release"
setup_repo "0.2.0"
# existing_tags already includes the target version
make_git_stub "$(printf 'v0.1.0\nv0.2.0')"
make_gh_stub
run_release
assert_exit "exits 0 when tag already exists" "$rc" 0

git_calls=$(cat "$GIT_LOG")
gh_calls=$(cat "$GH_LOG")
created=$(cat "$CREATED_TAGS_FILE")

assert_equals "no tag created when already exists" "$created" ""
assert_equals "gh NOT called when tag exists" "$gh_calls" ""

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
