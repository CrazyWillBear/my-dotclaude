#!/usr/bin/env bash
#
# Tests for scripts/setup-branch-protection.sh — applies branch protection to
# the default branch via `gh api`.
#
# Black-box: we stub `gh` via a PATH shim that logs invocations and captures
# the PUT request body (read from stdin via `--input -`). A read-back GET
# returns canned JSON so the script's verification step succeeds.
#
# Covers:
#   * a `gh api -X PUT .../branches/main/protection` is issued
#   * the payload requires a PR (required_pull_request_reviews present,
#     0 approvals), strict status checks, the CI context, and admins exempt
#   * REPO / BRANCH / CI_CONTEXT env overrides flow into the request
#
# Run: bash scripts/tests/test_setup_branch_protection.sh  (non-zero on fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROT_SCRIPT="$SCRIPTS_ROOT/setup-branch-protection.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()  { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in: $2)" ;; esac; }
assert_exit()      { if [ "$2" -eq "$3" ]; then ok "$1"; else no "$1 (want exit $3, got $2)"; fi; }

STUB_BIN="$WORK/bin"
GH_LOG="$WORK/gh.log"
BODY_FILE="$WORK/put_body.json"
mkdir -p "$STUB_BIN"

# Stub `gh`: log args; if the call sends a body (`--input`), capture stdin to
# BODY_FILE; otherwise (the read-back GET) emit canned protection JSON.
make_gh_stub() {
    : > "$GH_LOG"
    : > "$BODY_FILE"
    cat > "$STUB_BIN/gh" <<GHSTUB
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "${GH_LOG}"
if printf '%s ' "\$@" | grep -q -- '--input'; then
    cat > "${BODY_FILE}"
    exit 0
fi
cat <<'JSON'
{"required_status_checks":{"strict":true,"contexts":["check"]},
 "enforce_admins":{"enabled":false},
 "required_pull_request_reviews":{"dismiss_stale_reviews":true,"required_approving_review_count":0},
 "allow_force_pushes":{"enabled":false},
 "allow_deletions":{"enabled":false}}
JSON
exit 0
GHSTUB
    chmod +x "$STUB_BIN/gh"
}

run_setup() {
    out=$(PATH="$STUB_BIN:$PATH" env "$@" bash "$PROT_SCRIPT" 2>&1)
    rc=$?
}

# ---------------------------------------------------------------------------
echo "test: defaults -> PUT protection on CrazyWillBear/my-dotclaude main"
make_gh_stub
run_setup
assert_exit "exits 0 on success" "$rc" 0

gh_calls=$(cat "$GH_LOG")
body=$(cat "$BODY_FILE")

assert_contains "issues a PUT" "$gh_calls" "-X PUT"
assert_contains "targets main protection endpoint" "$gh_calls" "repos/CrazyWillBear/my-dotclaude/branches/main/protection"
assert_contains "body requires PR reviews block" "$body" "required_pull_request_reviews"
assert_contains "body sets 0 required approvals" "$body" "\"required_approving_review_count\": 0"
assert_contains "body dismisses stale reviews" "$body" "\"dismiss_stale_reviews\": true"
assert_contains "body sets strict status checks" "$body" "\"strict\": true"
assert_contains "body requires the bare job-name context" "$body" "\"contexts\": [\"check\"]"
assert_contains "body leaves admins exempt" "$body" "\"enforce_admins\": false"
assert_contains "body forbids force pushes" "$body" "\"allow_force_pushes\": false"

# ---------------------------------------------------------------------------
echo "test: env overrides flow into the request"
make_gh_stub
run_setup REPO="acme/widgets" BRANCH="release" CI_CONTEXT="Tests / unit"
assert_exit "exits 0 with overrides" "$rc" 0

gh_calls=$(cat "$GH_LOG")
body=$(cat "$BODY_FILE")

assert_contains "targets overridden repo+branch" "$gh_calls" "repos/acme/widgets/branches/release/protection"
assert_contains "body uses overridden CI context" "$body" "Tests / unit"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
