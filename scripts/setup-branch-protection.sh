#!/usr/bin/env bash
#
# setup-branch-protection.sh
#
# Applies branch protection to the kit's default branch via the GitHub REST
# API (`gh api`). It requires:
#   * a pull request before merging (0 required approvals — solo maintainer),
#     with stale approvals dismissed on new pushes;
#   * status checks to pass with the branch up to date, gating on the CI
#     workflow's check (context "check" — the bare job name GitHub Actions
#     reports as the check-run name; the PR UI shows "CI / check", but the
#     required-status-check context matches the job name, not that display
#     string, so requiring "CI / check" would never match);
#   * no force-pushes and no branch deletion.
#
# enforce_admins is FALSE so a repo admin can still administer / hotfix the
# branch directly.
#
# NOTE: this is an outward-facing, repo-admin action and `gh api` is outside
# the kit's normal allowlist, so a human runs this script. It needs admin on
# the repo and an authenticated `gh`.
#
# The external review bot is intentionally NOT required as a status check:
# it posts reviews/comments, not a required commit status, and requiring a
# context that never reports would permanently block every merge. See
# scripts/branch-protection-checklist.md to add one later.
#
# Usage:   bash scripts/setup-branch-protection.sh
# Override (env): REPO=owner/name  BRANCH=main  CI_CONTEXT="check"

set -euo pipefail

REPO="${REPO:-CrazyWillBear/my-dotclaude}"
BRANCH="${BRANCH:-main}"
CI_CONTEXT="${CI_CONTEXT:-check}"

# ---------------------------------------------------------------------------
# Build the protection payload
# ---------------------------------------------------------------------------
read -r -d '' BODY <<JSON || true
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["${CI_CONTEXT}"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON

printf 'Applying branch protection to %s on %s...\n' "$BRANCH" "$REPO"
printf '  required check: %s | PR required (0 approvals) | strict | admins exempt\n' "$CI_CONTEXT"

printf '%s' "$BODY" \
  | gh api -X PUT "repos/${REPO}/branches/${BRANCH}/protection" --input - >/dev/null

printf 'Protection applied. Reading back to verify...\n'

gh api "repos/${REPO}/branches/${BRANCH}/protection" --jq \
  '{pr_required: (.required_pull_request_reviews != null),
    required_checks: .required_status_checks.contexts,
    strict: .required_status_checks.strict,
    enforce_admins: .enforce_admins.enabled,
    allow_force_pushes: .allow_force_pushes.enabled,
    allow_deletions: .allow_deletions.enabled}'
