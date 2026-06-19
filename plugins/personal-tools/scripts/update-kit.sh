#!/usr/bin/env bash
#
# update-kit.sh — apply the latest kit release on this machine.
#
# Runs three `claude` invocations in order:
#   1. claude plugin marketplace update my-dotclaude
#   2. claude plugin update personal-tools
#   3. claude plugin update workflow
#
# Then prints a clear restart reminder.
#
# `claude` is invoked from PATH so a test can shim it.
#
# Usage: bash update-kit.sh

set -euo pipefail

claude plugin marketplace update my-dotclaude
claude plugin update personal-tools
claude plugin update workflow

printf '\nDone. Restart Claude Code to apply the updated kit.\n'
