<#
.SYNOPSIS
  Non-developer setup for the team-code-review plugin. Run inside your project folder.

.EXAMPLE
  irm https://raw.githubusercontent.com/CrazyWillBear/code-review-plugin/main/setup/setup-simple.ps1 | iex

.EXAMPLE
  pwsh -File setup/setup-simple.ps1 -Force

.DESCRIPTION
  In the current directory: initializes git, writes a plain-English CLAUDE.md,
  installs the team-code-review and caveman plugins (caveman lite mode), and marks
  the project for plain-language review summaries.
#>
param([switch]$Force, [switch]$Continue)

Write-Host 'These have not been tested yet. Use at your own risk.' -ForegroundColor Yellow
if (-not $Continue) {
    Write-Host 'Nothing was changed. Re-run with -Continue once you accept the risk.' -ForegroundColor Yellow
    exit 1
}

$ErrorActionPreference = 'Stop'
$Repo = 'CrazyWillBear/code-review-plugin'
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

Test-TcrDeps
Write-TcrStep "Setting up your project in: $((Get-Location).Path)"
Initialize-TcrGit
Copy-TcrTemplate -Rel 'simple/CLAUDE.md' -Dest 'CLAUDE.md' -LocalRoot $LocalRoot -Force:$Force
Set-TcrAudience 'plain'
Install-TcrReviewPlugin -LocalRoot $LocalRoot
Install-TcrCaveman
Set-TcrCavemanLevel 'lite'

if ($script:TcrInstallFailed) {
    Write-TcrWarn "a helper did not install automatically - run the 'claude plugin install' command(s) shown above, then restart Claude Code."
}

Write-Host ''
Write-Host 'All set! Here is what to do next:' -ForegroundColor White
Write-Host '  1. Close and reopen Claude Code so the new helpers load.'
Write-Host '  2. Just tell Claude what you want to build - in plain English.'
Write-Host '  3. Claude will handle the technical parts and check its own work for you.'
