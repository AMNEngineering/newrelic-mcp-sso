<#
.SYNOPSIS
Adds the New Relic MCP (OAuth-direct via OneLogin) to Claude Code.

.DESCRIPTION
Merges a `newrelic` MCP server entry into $HOME/.claude/.mcp.json non-destructively.
Idempotent — re-running is a no-op. Use -Check to validate + report without modifying.

For AMN engineers on the Anthropic-direct Claude Code subscription cohort. If you're
on the APIM Claude Code path (the default at AMN), install from
AMNEngineering/newrelic-mcp-apim instead.

.PARAMETER Check
Validate + report only. No modifications.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -Check
#>

[CmdletBinding()]
param(
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------ ui helpers ------
function Write-Ok    ([string]$m) { Write-Host "✓ $m" -ForegroundColor Green }
function Write-Warn2 ([string]$m) { Write-Host "! $m" -ForegroundColor Yellow }
function Write-Fail  ([string]$m) { Write-Host "✗ $m" -ForegroundColor Red }
function Write-Info  ([string]$m) { Write-Host "  $m" }
function Write-Head  ([string]$m) { Write-Host ""; Write-Host "== $m ==" -ForegroundColor Cyan }

# PowerShell 5.1 lacks ConvertFrom-Json -AsHashtable; use recursive conversion.
function ConvertTo-HashtableRecursive {
    param([Parameter(ValueFromPipeline = $true)]$Object)
    process {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
            return @($Object | ForEach-Object { ConvertTo-HashtableRecursive $_ })
        }
        if ($Object.PSObject -and $Object.PSObject.Properties -and $Object.PSObject.Properties.Count -gt 0) {
            $h = [ordered]@{}
            foreach ($p in $Object.PSObject.Properties) {
                $h[$p.Name] = ConvertTo-HashtableRecursive $p.Value
            }
            return $h
        }
        return $Object
    }
}

Write-Head "New Relic MCP — SSO / OAuth-direct install"

# ------ locate config file ------
$claudeDir = Join-Path $HOME '.claude'
$cfgFile   = Join-Path $claudeDir '.mcp.json'

if (-not (Test-Path $claudeDir)) {
    if ($Check) {
        Write-Warn2 "$claudeDir does not exist. Claude Code may not be installed for this user."
        exit 0
    }
    Write-Info "Creating $claudeDir"
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
}

# ------ prereq check: Claude Code CLI ------
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Warn2 "'claude' CLI not found on PATH. Install Claude Code first (AMNEngineering/amn-claude-code-client)."
    # Not fatal — config can still be dropped for later CLI installs / for the Desktop app.
}

# ------ current state ------
$existing = $null
$hadFile  = Test-Path $cfgFile

if ($hadFile) {
    Write-Info "Found existing $cfgFile"
    try {
        $existing = Get-Content -Raw -Path $cfgFile | ConvertFrom-Json -ErrorAction Stop | ConvertTo-HashtableRecursive
        Write-Ok "existing config is valid JSON"
    } catch {
        Write-Fail "existing $cfgFile is not valid JSON — refusing to touch it. Fix or move aside and re-run."
        exit 1
    }

    if ($existing.ContainsKey('mcpServers') -and $existing.mcpServers.ContainsKey('newrelic')) {
        Write-Warn2 "an 'newrelic' MCP entry already exists in $cfgFile."
        Write-Info "Current entry:"
        ($existing.mcpServers.newrelic | ConvertTo-Json -Depth 10) -split "`n" | ForEach-Object { Write-Info "    $_" }
        if ($Check) {
            Write-Info "Check-only: no changes made."
            exit 0
        }
        Write-Info "This installer will OVERWRITE the existing 'newrelic' entry with the SSO/OAuth-direct config."
        $resp = Read-Host "Continue? (y/N)"
        if ($resp -notmatch '^[yY]') { Write-Info "Aborted."; exit 0 }
    }
}

# ------ the SSO/OAuth-direct entry ------
$newRelicEntry = [ordered]@{
    type  = 'http'
    url   = 'https://mcp.newrelic.com/mcp/'
    oauth = [ordered]@{ scopes = 'openid profile email' }
}

if ($Check) {
    Write-Ok "Check-only mode. Would merge this into ${cfgFile}:"
    ($newRelicEntry | ConvertTo-Json -Depth 10) -split "`n" | ForEach-Object { Write-Info "    $_" }
    exit 0
}

# ------ backup ------
$backup = $null
if ($hadFile) {
    $backup = "$cfgFile.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -Path $cfgFile -Destination $backup -Force
    Write-Ok "backed up existing config → $backup"
}

# ------ merge ------
if (-not $existing) { $existing = [ordered]@{} }
if (-not $existing.ContainsKey('mcpServers') -or -not $existing.mcpServers) {
    $existing.mcpServers = [ordered]@{}
}
$existing.mcpServers.newrelic = $newRelicEntry

# UTF-8 with BOM for Windows PowerShell 5.1 rendering fidelity.
$json  = $existing | ConvertTo-Json -Depth 10
$bytes = [System.Text.UTF8Encoding]::new($true).GetBytes($json)
[System.IO.File]::WriteAllBytes($cfgFile, $bytes)

Write-Ok "newrelic MCP added to $cfgFile"

# ------ post-write validation ------
try {
    Get-Content -Raw -Path $cfgFile | ConvertFrom-Json -ErrorAction Stop | Out-Null
} catch {
    Write-Fail "post-write validation failed. Restoring backup."
    if ($backup) { Copy-Item -Path $backup -Destination $cfgFile -Force; Write-Info "restored from $backup" }
    exit 1
}

Write-Head "Next steps"
Write-Info "1. Fully quit Claude Code (Alt-F4 / File → Exit) and relaunch."
Write-Info "2. Run /mcp — 'newrelic' will show 'needs authentication'."
Write-Info "3. Run 'claude mcp login newrelic' — a browser will open."
Write-Info "4. Sign in via OneLogin. /mcp should then show 'newrelic: ✔ Connected'."
Write-Host ""
Write-Info "You must be in the AZ_JobRole_Observability_NewRelicMcp_User AD group for"
Write-Info "the OneLogin → New Relic handshake to succeed. If it fails, request the group"
Write-Info "via ServiceNow, then re-run 'claude mcp login newrelic'."
Write-Host ""
