<#
.SYNOPSIS
  Developer setup - installs the full user-wide Claude Code kit (user scope). Run from anywhere.

.EXAMPLE
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/CrazyWillBear/my-dotclaude/main/setup/setup-dev.ps1))) -Continue

.EXAMPLE
  pwsh -File setup/setup-dev.ps1 -Continue -Force

.DESCRIPTION
  Installs the global ~/.claude/CLAUDE.md (technical), sets model=opus, installs the plugins
  (team-code-review, personal-tools, caveman, agent-sdk-dev), the Playwright MCP server, and a
  read-only gh (GitHub CLI) allowlist. Not tied to any project. -Force overwrites an existing
  ~/.claude/CLAUDE.md (a timestamped backup is always kept either way).
#>
param([switch]$Force, [switch]$Continue)

Write-Host 'These have not been tested yet. Use at your own risk.' -ForegroundColor Yellow
if (-not $Continue) {
    Write-Host 'Nothing was changed. Re-run with -Continue once you accept the risk.' -ForegroundColor Yellow
    exit 1
}

$ErrorActionPreference = 'Stop'
$Repo = 'CrazyWillBear/my-dotclaude'
$RawBase = "https://raw.githubusercontent.com/$Repo/main"

# Resolve our location so we can run from a checkout or via `irm | iex`.
$LocalRoot = ''
$selfDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { '' }
$localLib = if ($selfDir) { Join-Path $selfDir 'lib/common.ps1' } else { '' }
if ($localLib -and (Test-Path $localLib)) {
    . $localLib
    $LocalRoot = (Resolve-Path (Join-Path $selfDir '..')).Path
} else {
    $tmp = (New-TemporaryFile).FullName
    try {
        Invoke-WebRequest -Uri "$RawBase/setup/lib/common.ps1" -OutFile $tmp -UseBasicParsing
        if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -eq 0) { Write-Error 'fetched setup library is empty'; exit 1 }
        . $tmp
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

# This path is user-scope (~/.claude), so it only needs the claude CLI.
if (-not (Test-TcrCommand 'claude')) { Stop-TcrError "Claude Code's 'claude' CLI is required but not found on PATH." }

Write-TcrStep "Developer setup into: $(Join-Path $HOME '.claude')"
Install-TcrGlobalClaudeMd -LocalRoot $LocalRoot -Force:$Force
Set-TcrSetting 'model' 'opus'
Install-TcrReviewPlugin -LocalRoot $LocalRoot   # also adds our marketplace
Install-TcrPersonalTools                        # reuses the marketplace added above
Install-TcrCaveman
Install-TcrAgentSdkDev
Install-TcrPlaywrightMcp
Set-TcrGhAccess

if ($script:TcrInstallFailed) {
    Write-TcrWarn "a plugin did not install automatically - run the 'claude plugin install' command(s) shown above, then restart Claude Code."
}

Write-Host ''
Write-Host 'Done. Next:' -ForegroundColor White
Write-Host '  1. Restart Claude Code so it loads the global CLAUDE.md and plugins.'
Write-Host '  2. Run /plugin to confirm team-code-review, personal-tools, caveman, and agent-sdk-dev are enabled.'
Write-Host '  3. Run /mcp to confirm the Playwright server, and install gh (https://cli.github.com) + run gh auth login for GitHub.'
