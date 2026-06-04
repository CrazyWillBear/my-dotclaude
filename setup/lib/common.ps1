# Shared helpers for the my-dotclaude setup scripts (setup-dev.ps1 / setup-simple.ps1).
#
# Dot-source this from an entry script. Functions take what they need as parameters
# so they don't depend on the caller's variable scope.

$script:TcrRepo          = 'CrazyWillBear/my-dotclaude'
$script:TcrRawBase       = "https://raw.githubusercontent.com/$($script:TcrRepo)/main"
$script:TcrMarketplace    = 'my-dotclaude'
$script:TcrPlugin         = "my-code-review@$($script:TcrMarketplace)"
$script:TcrPersonalPlugin = "personal-tools@$($script:TcrMarketplace)"
$script:TcrCavemanRepo   = 'JuliusBrussee/caveman'
$script:TcrCavemanPlugin = 'caveman@caveman'
$script:TcrOfficialMarketplaceRepo = 'anthropics/claude-plugins-official'
$script:TcrAgentSdkPlugin          = 'agent-sdk-dev@claude-plugins-official'
$script:TcrPlaywrightMcpPkg        = '@playwright/mcp@latest'
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

function Add-TcrMarketplace {
    param([string]$Source)
    claude plugin marketplace add $Source *> $null
    if ($LASTEXITCODE -ne 0) { Write-TcrWarn "could not add marketplace '$Source' (it may already be registered)." }
}

function Install-TcrReviewPlugin {
    param([string]$LocalRoot)
    Write-TcrStep 'Installing the my-code-review plugin'
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

# Installs agent-sdk-dev from Anthropic's official marketplace (Claude Agent SDK scaffolder).
function Install-TcrAgentSdkDev {
    Write-TcrStep 'Installing the agent-sdk-dev plugin'
    Add-TcrMarketplace $script:TcrOfficialMarketplaceRepo
    claude plugin install $script:TcrAgentSdkPlugin *> $null
    if ($LASTEXITCODE -eq 0) { Write-TcrOk "enabled $($script:TcrAgentSdkPlugin)" }
    else { $script:TcrInstallFailed = $true; Write-TcrWarn "could not install automatically - run: claude plugin install $($script:TcrAgentSdkPlugin)" }
}

# Adds the Playwright MCP server (browser automation) at user scope. Idempotent.
function Install-TcrPlaywrightMcp {
    Write-TcrStep 'Adding the Playwright MCP server (user scope)'
    claude mcp get playwright *> $null
    if ($LASTEXITCODE -eq 0) { Write-TcrOk 'playwright MCP already configured'; return }
    claude mcp add playwright -s user -- npx $script:TcrPlaywrightMcpPkg --headless *> $null
    if ($LASTEXITCODE -eq 0) { Write-TcrOk 'added playwright MCP (headless)' }
    else { $script:TcrInstallFailed = $true; Write-TcrWarn "could not add the playwright MCP automatically - run: claude mcp add playwright -s user -- npx $($script:TcrPlaywrightMcpPkg) --headless" }
}

# GitHub access uses the gh CLI, not a GitHub MCP server (see README). Adds a read-only
# gh allowlist so common reads do not prompt, and checks gh is installed + authenticated.
function Set-TcrGhAccess {
    Write-TcrStep 'Configuring gh (GitHub CLI) access'
    # Read-only subcommands only. gh api is intentionally omitted - it can POST/DELETE.
    Add-TcrPermissions @(
        'Bash(gh pr view:*)', 'Bash(gh pr list:*)', 'Bash(gh pr diff:*)', 'Bash(gh pr checks:*)',
        'Bash(gh issue view:*)', 'Bash(gh issue list:*)', 'Bash(gh repo view:*)',
        'Bash(gh run view:*)', 'Bash(gh run list:*)', 'Bash(gh release view:*)',
        'Bash(gh search:*)', 'Bash(gh auth status:*)'
    )
    if (Test-TcrCommand 'gh') {
        gh auth status *> $null
        if ($LASTEXITCODE -eq 0) { Write-TcrOk 'gh is installed and authenticated' }
        else { Write-TcrWarn 'gh is installed but not logged in - run: gh auth login' }
    } else {
        Write-TcrWarn "gh (GitHub CLI) not found - install it from https://cli.github.com and run 'gh auth login'. Claude uses gh for GitHub (there is no GitHub MCP)."
    }
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
# Project-scope helper, unused by the shipped user-wide setup (retained for a future /scaffold-* skill;
# the user-wide default lives at ~/.claude via Set-TcrGlobalAudience).
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
    Merge-TcrJsonString (Get-TcrCavemanConfigPath) 'defaultMode' $Level
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

# Install-TcrGlobalClaudeMd -Source <relpath> - write a CLAUDE.md source (default
# global/CLAUDE.md; non-dev passes templates/simple/CLAUDE.md) to ~/.claude/CLAUDE.md.
# Backs up and skips an existing file unless -Force.
function Install-TcrGlobalClaudeMd {
    param([string]$LocalRoot, [string]$Source = 'global/CLAUDE.md', [switch]$Force)
    $dest = Join-Path $HOME '.claude/CLAUDE.md'
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    if ((Test-Path $dest) -and -not $Force) {
        Write-TcrWarn "$dest already exists - leaving it untouched (use -Force to overwrite)."
        return
    }
    Backup-TcrFile $dest
    $localFile = if ($LocalRoot) { Join-Path $LocalRoot $Source } else { $null }
    if ($localFile -and (Test-Path $localFile)) {
        Copy-Item -Path $localFile -Destination $dest -Force
    } else {
        try {
            Invoke-WebRequest -Uri "$($script:TcrRawBase)/$Source" -OutFile $dest -UseBasicParsing
        } catch {
            Stop-TcrError "Could not download $Source from $($script:TcrRawBase)."
        }
    }
    Write-TcrOk "wrote $dest"
}

# Set-TcrGlobalAudience <plain|technical> - write ~/.claude/review-audience, the
# user-wide review-output default (the review hook falls back to it when a project
# has no .claude/review-audience). Backs up an existing marker.
function Set-TcrGlobalAudience {
    param([string]$Audience)
    $dest = Join-Path $HOME '.claude/review-audience'
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    Backup-TcrFile $dest
    Write-TcrTextNoBom $dest "$Audience`n"
    Write-TcrOk "set user-wide review style to '$Audience' ($dest)"
}

# Merge-TcrJsonString <cfg> <key> <string-value> - merge one string key into a
# JSON object file, preserving every other key. Creates the file when absent.
# Never overwrites a non-empty file it cannot parse - it warns and leaves that
# file untouched, so it can't silently eat an existing config. Backs up before a
# successful overwrite.
function Merge-TcrJsonString {
    param([string]$Cfg, [string]$Key, [string]$Value)
    $dir = Split-Path -Parent $Cfg
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $data = [ordered]@{}
    if (Test-Path $Cfg) {
        $raw = Get-Content -Raw $Cfg
        if ($raw -and $raw.Trim()) {
            try {
                $existing = $raw | ConvertFrom-Json
            } catch {
                Write-TcrWarn "$Cfg isn't plain JSON (comments or a trailing comma?) - left it untouched; set `"$Key`": `"$Value`" in it manually."
                return
            }
            if ($existing -isnot [System.Management.Automation.PSCustomObject]) {
                Write-TcrWarn "$Cfg is not a JSON object - left it untouched; set `"$Key`": `"$Value`" in it manually."
                return
            }
            Backup-TcrFile $Cfg
            foreach ($p in $existing.PSObject.Properties) { $data[$p.Name] = $p.Value }
        }
    }
    $data[$Key] = $Value
    Write-TcrTextNoBom $Cfg (($data | ConvertTo-Json -Depth 10) + "`n")
    Write-TcrOk "set $Key = `"$Value`" ($Cfg)"
}

# Set-TcrSetting <key> <string-value> - merge a setting into ~/.claude/settings.json.
function Set-TcrSetting {
    param([string]$Key, [string]$Value)
    Merge-TcrJsonString (Join-Path $HOME '.claude/settings.json') $Key $Value
}

# Add-TcrPermissions <string[]> - merge permission strings into .permissions.allow of
# ~/.claude/settings.json, preserving every other key, the permissions object's other
# keys (deny, etc.), and existing allow entries (union, de-duped). Same safety as
# Merge-TcrJsonString: never clobbers a non-empty file it cannot parse; backs up first.
function Add-TcrPermissions {
    param([string[]]$Permissions)
    $cfg = Join-Path $HOME '.claude/settings.json'
    $dir = Split-Path -Parent $cfg
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $data = [ordered]@{}
    if (Test-Path $cfg) {
        $raw = Get-Content -Raw $cfg
        if ($raw -and $raw.Trim()) {
            try { $existing = $raw | ConvertFrom-Json }
            catch { Write-TcrWarn "$cfg isn't plain JSON (comments or a trailing comma?) - left it untouched; add these to permissions.allow manually: $($Permissions -join ', ')"; return }
            if ($existing -isnot [System.Management.Automation.PSCustomObject]) {
                Write-TcrWarn "$cfg is not a JSON object - left it untouched; add these to permissions.allow manually: $($Permissions -join ', ')"; return
            }
            Backup-TcrFile $cfg
            foreach ($p in $existing.PSObject.Properties) { $data[$p.Name] = $p.Value }
        }
    }

    # Collect existing allow entries (if any), then append the new ones, de-duped.
    $allow = [System.Collections.Generic.List[string]]::new()
    $permOut = [ordered]@{}
    if ($data.Contains('permissions') -and $data['permissions'] -is [System.Management.Automation.PSCustomObject]) {
        foreach ($pp in $data['permissions'].PSObject.Properties) {
            if ($pp.Name -eq 'allow') { if ($pp.Value) { foreach ($a in $pp.Value) { if (-not $allow.Contains($a)) { $allow.Add($a) } } } }
            else { $permOut[$pp.Name] = $pp.Value }
        }
    }
    foreach ($p in $Permissions) { if (-not $allow.Contains($p)) { $allow.Add($p) } }
    $permOut['allow'] = $allow.ToArray()
    $data['permissions'] = $permOut

    Write-TcrTextNoBom $cfg (($data | ConvertTo-Json -Depth 10) + "`n")
    Write-TcrOk "added $($Permissions.Count) gh permission(s) to permissions.allow ($cfg)"
}
