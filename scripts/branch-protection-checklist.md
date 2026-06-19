# Branch protection checklist (`main`)

`main` is the release branch — every dev→main merge can cut a release. This
protects it so nothing lands without a PR and a green CI run.

`scripts/setup-branch-protection.sh` applies the protection via `gh api`. It is
**run by a human**: `gh api` is outside the kit's normal allowlist and branch
protection is an outward-facing, repo-admin action.

## What it applies

| Rule | Value |
| --- | --- |
| Pull request required before merge | yes (`required_pull_request_reviews`) |
| Required approving reviews | **0** (solo maintainer) |
| Dismiss stale approvals on new push | yes |
| Required status checks | **`CI / check`** (the `CI` workflow, job `check`) |
| Strict (branch must be up to date) | yes |
| Force pushes | blocked |
| Branch deletion | blocked |
| `enforce_admins` | **false** (an admin can still hotfix/administer) |

## Prerequisites

- Admin permission on the repo.
- An authenticated `gh` (`gh auth status`).

## Run

```bash
bash scripts/setup-branch-protection.sh
# overrides (defaults shown):
#   REPO=CrazyWillBear/my-dotclaude BRANCH=main CI_CONTEXT="CI / check" \
#     bash scripts/setup-branch-protection.sh
```

## Verify

The script reads the protection back and prints it. To re-check at any time:

```bash
gh api repos/CrazyWillBear/my-dotclaude/branches/main/protection \
  --jq '{pr_required: (.required_pull_request_reviews != null),
         required_checks: .required_status_checks.contexts,
         strict: .required_status_checks.strict,
         enforce_admins: .enforce_admins.enabled}'
```

Expect `pr_required: true`, `required_checks: ["CI / check"]`, `strict: true`,
`enforce_admins: false`.

## External review bot — intentionally not required

The original plan was to also require the external review bot's status check.
It is **not** required, by decision:

- the bot posts reviews/comments, **not** a required commit status; and
- requiring a check context that never reports would permanently block every
  merge.

**To require a bot check later:** confirm the exact context string it posts —
look at a recent PR's checks list, or:

```bash
gh api repos/CrazyWillBear/my-dotclaude/commits/<sha>/check-runs --jq '.check_runs[].name'
gh api repos/CrazyWillBear/my-dotclaude/commits/<sha>/status     --jq '.statuses[].context'
```

Then add that exact string to `CI_CONTEXT`'s array in
`scripts/setup-branch-protection.sh` (make `contexts` list both checks) and
re-run the script.

> ⚠️ Only require a check that actually reports on every PR. A required context
> that never posts leaves PRs un-mergeable.
