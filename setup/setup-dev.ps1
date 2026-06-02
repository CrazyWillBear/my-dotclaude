<#
.SYNOPSIS
  Developer setup for the team-code-review plugin. Run inside the project directory.

.EXAMPLE
  irm https://raw.githubusercontent.com/CrazyWillBear/code-review-plugin/main/setup/setup-dev.ps1 | iex

.EXAMPLE
  pwsh -File setup/setup-dev.ps1 -Force

.DESCRIPTION
  In the current directory: initializes git, writes technical CLAUDE.md + STYLEGUIDE.md
  (won't overwrite without -Force), installs the team-code-review and caveman plugins
  (caveman full mode), and marks the project for technical review output.
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
Write-TcrStep "Developer setup in: $((Get-Location).Path)"
Initialize-TcrGit
Copy-TcrTemplate -Rel 'dev/CLAUDE.md' -Dest 'CLAUDE.md' -LocalRoot $LocalRoot -Force:$Force
Copy-TcrTemplate -Rel 'dev/STYLEGUIDE.md' -Dest 'STYLEGUIDE.md' -LocalRoot $LocalRoot -Force:$Force
Set-TcrAudience 'technical'
Install-TcrReviewPlugin -LocalRoot $LocalRoot
Install-TcrCaveman

if ($script:TcrInstallFailed) {
    Write-TcrWarn "a plugin did not install automatically - run the 'claude plugin install' command(s) shown above, then restart Claude Code."
}

Write-Host ''
Write-Host 'Done. Next:' -ForegroundColor White
Write-Host '  1. Restart Claude Code so it loads the plugins.'
Write-Host '  2. Fill in the <...> placeholders in CLAUDE.md and STYLEGUIDE.md.'
Write-Host '  3. Edit a file and finish a turn - the code review runs automatically.'
