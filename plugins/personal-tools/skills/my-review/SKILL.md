---
name: my-review
description: Deep, security-weighted review of your changes or a PR — runs inside the my-review agent (fable, xhigh reasoning). Read-only, report-only. Use for "/my-review", "/my-review <PR#>".
argument-hint: "[optional PR number/URL; empty = review the local working diff]"
agent: my-review
---

Review the target per your standing instructions, then report findings. Target (a PR
number/URL if given, else review the local working diff): `$ARGUMENTS`.
