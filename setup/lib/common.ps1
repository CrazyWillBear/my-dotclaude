# Shared helpers for the team-code-review setup scripts (setup-dev.ps1 / setup-simple.ps1).
#
# Dot-source this from an entry script. Functions take what they need as parameters
# so they don't depend on the caller's variable scope.

$script:TcrRepo          = 'CrazyWillBear/my-dotclaude'
$script:TcrRawBase       = "https://raw.githubusercontent.com/$($script:TcrRepo)/main"
$script:TcrMarketplace    = 'my-dotclaude'
$script:TcrPlugin         = "team-code-review@$($script:TcrMarketplace)"
$script:TcrPersonalPlugin = "personal-tools@$($script:TcrMarketplace)"
$script:TcrCavemanRepo   = 'JuliusBrussee/caveman'
$script:TcrCavemanPlugin = 'caveman@caveman'
$script:TcrInstallFailed = $false

function Write-TcrStep { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Blue }
function Write-TcrOk   { param([string]$Message) Write-Host "  ok $Message" -ForegroundColor Green }
function Write-TcrWarn { param([string]$Message) Write-Host "warn $Message" -ForegroundColor Yellow }
function Stop-TcrError { param([string]$Message) Write-Host "error $Message" -ForegroundColor Red; exit 1 }

# Write text as UTF-8 *without* a BOM. caveman's config is parsed by Node's
# JSON.parse, which rejects a leading BOM; Set-Content/Out-File encodings vary
# across PowerShell 5.1 and 7, so we go through .NET to be explicit. Relative
# paths are resolved against PowerShell's location (not .NET's process cwd,
# which Set-Location does not update).
function Write-TcrTextNoBom {
    param([string]$Path, [string]$Content)
    if (-not [System.IO.Path]::IsPathRooted($Path)) { $Path = Join-Path (Get-Location).Path $Path }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-TcrCommand { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Test-TcrDeps {
    if (-not (Test-TcrCommand 'git'))    { Stop-TcrError 'git is required but not found on PATH. Install git, then re-run.' }
    if (-not (Test-TcrCommand 'claude')) { Stop-TcrError "Claude Code's 'claude' CLI is required but not found on PATH." }
}

# Copy-TcrTemplate -Rel <path under templates/> -Dest <file> -LocalRoot <root or ''> -Force
function Copy-TcrTemplate {
    param([string]$Rel, [string]$Dest, [string]$LocalRoot, [switch]$Force)
    if ((Test-Path $Dest) -and -not $Force) {
        Write-TcrWarn "$Dest already exists - leaving it untouched (use -Force to overwrite)."
        return
    }
    $destDir = Split-Path -Parent $Dest
    if ($destDir -and -not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    $localFile = if ($LocalRoot) { Join-Path $LocalRoot "templates/$Rel" } else { $null }
    if ($localFile -and (Test-Path $localFile)) {
        Copy-Item -Path $localFile -Destination $Dest -Force
    } else {
        try {
            Invoke-WebRequest -Uri "$($script:TcrRawBase)/templates/$Rel" -OutFile $Dest -UseBasicParsing
        } catch {
            Stop-TcrError "Could not download template '$Rel' from $($script:TcrRawBase)."
        }
    }
    Write-TcrOk "wrote $Dest"
}

function Initialize-TcrGit {
    git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-TcrOk 'git repository already present'
    } else {
        git init -q
        Write-TcrOk 'initialized a git repository'
    }
}

function Add-TcrMarketplace {
    param([string]$Source)
    claude plugin marketplace add $Source *> $null
    if ($LASTEXITCODE -ne 0) { Write-TcrWarn "could not add marketplace '$Source' (it may already be registered)." }
}

function Install-TcrReviewPlugin {
    param([string]$LocalRoot)
    Write-TcrStep 'Installing the team-code-review plugin'
    $localMarket = if ($LocalRoot) { Join-Path $LocalRoot '.claude-plugin/marketplace.json' } else { $null }
    if ($localMarket -and (Test-Path $localMarket)) { Add-TcrMarketplace $LocalRoot } else { Add-TcrMarketplace $script:TcrRepo }
    claude plugin install $script:TcrPlugin *> $null
    if ($LASTEXITCODE -eq 0) { Write-TcrOk "enabled $($script:TcrPlugin)" }
    else { $script:TcrInstallFailed = $true; Write-TcrWarn "could not install automatically - run: claude plugin install $($script:TcrPlugin)" }
}

function Install-TcrCaveman {
    Write-TcrStep 'Installing the caveman plugin'
    Add-TcrMarketplace $script:TcrCavemanRepo
    claude plugin install $script:TcrCavemanPlugin *> $null
    if ($LASTEXITCODE -eq 0) { Write-TcrOk "enabled $($script:TcrCavemanPlugin)" }
    else { $script:TcrInstallFailed = $true; Write-TcrWarn "could not install automatically - run: claude plugin install $($script:TcrCavemanPlugin)" }
}

# Installs personal-tools. Assumes our marketplace is already added (call
# Install-TcrReviewPlugin or Add-TcrMarketplace before this).
function Install-TcrPersonalTools {
    Write-TcrStep 'Installing the personal-tools plugin'
    claude plugin install $script:TcrPersonalPlugin *> $null
    if ($LASTEXITCODE -eq 0) { Write-TcrOk "enabled $($script:TcrPersonalPlugin)" }
    else { $script:TcrInstallFailed = $true; Write-TcrWarn "could not install automatically - run: claude plugin install $($script:TcrPersonalPlugin)" }
}

# Set-TcrAudience <plain|technical>
function Set-TcrAudience {
    param([string]$Audience)
    if (-not (Test-Path '.claude')) { New-Item -ItemType Directory -Force -Path '.claude' | Out-Null }
    Write-TcrTextNoBom '.claude/review-audience' "$Audience`n"
    Write-TcrOk "set review style to '$Audience' (.claude/review-audience)"
}

function Get-TcrCavemanConfigPath {
    if ($env:XDG_CONFIG_HOME) { return (Join-Path $env:XDG_CONFIG_HOME 'caveman/config.json') }
    # $IsWindows is PowerShell 7+ only ($null on Windows PowerShell 5.1); the
    # $env:OS check covers 5.1, so keep both clauses.
    if ($env:OS -eq 'Windows_NT' -or $IsWindows) {
        $base = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME 'AppData/Roaming' }
        return (Join-Path $base 'caveman/config.json')
    }
    return (Join-Path $HOME '.config/caveman/config.json')
}

# Set-TcrCavemanLevel <lite|full|ultra|...>
function Set-TcrCavemanLevel {
    param([string]$Level)
    $cfg = Get-TcrCavemanConfigPath
    $dir = Split-Path -Parent $cfg
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $data = [ordered]@{}
    if (Test-Path $cfg) {
        try {
            $existing = Get-Content -Raw $cfg | ConvertFrom-Json
            # Only merge when the existing config is a JSON object; an array or
            # scalar has no real properties to carry over (mirrors the shell side,
            # which resets non-dict input to {}).
            if ($existing -is [System.Management.Automation.PSCustomObject]) {
                foreach ($p in $existing.PSObject.Properties) { $data[$p.Name] = $p.Value }
            }
        } catch { $data = [ordered]@{} }
    }
    $data['defaultMode'] = $Level
    Write-TcrTextNoBom $cfg (($data | ConvertTo-Json -Depth 10) + "`n")
    Write-TcrOk "set caveman default level to '$Level' ($cfg)"
}

# --- global (~/.claude) install ----------------------------------------------

# Backup-TcrFile <path> - copy to <path>.bak.<timestamp> when it exists.
function Backup-TcrFile {
    param([string]$Path)
    if (Test-Path $Path) {
        $bak = "$Path.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item -Path $Path -Destination $bak -Force
        Write-TcrOk "backed up $Path -> $bak"
    }
}

# Install-TcrGlobalClaudeMd - write home/CLAUDE.md to ~/.claude/CLAUDE.md.
# Backs up and skips an existing file unless -Force.
function Install-TcrGlobalClaudeMd {
    param([string]$LocalRoot, [switch]$Force)
    $dest = Join-Path $HOME '.claude/CLAUDE.md'
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    if ((Test-Path $dest) -and -not $Force) {
        Write-TcrWarn "$dest already exists - leaving it untouched (use -Force to overwrite)."
        return
    }
    Backup-TcrFile $dest
    $localFile = if ($LocalRoot) { Join-Path $LocalRoot 'home/CLAUDE.md' } else { $null }
    if ($localFile -and (Test-Path $localFile)) {
        Copy-Item -Path $localFile -Destination $dest -Force
    } else {
        try {
            Invoke-WebRequest -Uri "$($script:TcrRawBase)/home/CLAUDE.md" -OutFile $dest -UseBasicParsing
        } catch {
            Stop-TcrError "Could not download home/CLAUDE.md from $($script:TcrRawBase)."
        }
    }
    Write-TcrOk "wrote $dest"
}

# Set-TcrSetting <key> <string-value> - merge one string setting into
# ~/.claude/settings.json, preserving everything else. Backs up first.
function Set-TcrSetting {
    param([string]$Key, [string]$Value)
    $cfg = Join-Path $HOME '.claude/settings.json'
    $dir = Split-Path -Parent $cfg
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Backup-TcrFile $cfg
    $data = [ordered]@{}
    if (Test-Path $cfg) {
        try {
            $existing = Get-Content -Raw $cfg | ConvertFrom-Json
            if ($existing -is [System.Management.Automation.PSCustomObject]) {
                foreach ($p in $existing.PSObject.Properties) { $data[$p.Name] = $p.Value }
            }
        } catch { $data = [ordered]@{} }
    }
    $data[$Key] = $Value
    Write-TcrTextNoBom $cfg (($data | ConvertTo-Json -Depth 10) + "`n")
    Write-TcrOk "set $Key = `"$Value`" ($cfg)"
}
