<#
.SYNOPSIS
Adds the New Relic OAuth MCP to supported GitHub Copilot clients.

.DESCRIPTION
The Copilot target configures Copilot CLI and VS Code Agent Host. The GitHub
Copilot app imports the same user-level config, but currently has known
third-party OAuth host bugs. The VS Code target writes workspace config.

.PARAMETER Target
Allowed values: All, Copilot, VSCode. Default: Copilot.

.PARAMETER Workspace
Workspace directory whose .vscode/mcp.json should be configured.

.PARAMETER Check
Validate and report without modifying files.

.PARAMETER Force
Replace a conflicting newrelic entry without prompting.
#>

[CmdletBinding()]
param(
    [ValidateSet('All', 'Copilot', 'VSCode')]
    [string]$Target = 'Copilot',
    [string]$Workspace = (Get-Location).Path,
    [switch]$Check,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ReplaceExisting = $Force.IsPresent

function Write-Ok    ([string]$Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn2 ([string]$Message) { Write-Host "! $Message" -ForegroundColor Yellow }
function Write-Info  ([string]$Message) { Write-Host "  $Message" }
function Write-Head  ([string]$Message) { Write-Host ''; Write-Host "== $Message ==" -ForegroundColor Cyan }

function ConvertTo-HashtableRecursive {
    param([Parameter(ValueFromPipeline = $true)]$Object)
    process {
        if ($null -eq $Object) { return $null }

        if ($Object -is [System.Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in $Object.Keys) {
                $result[$key] = ConvertTo-HashtableRecursive $Object[$key]
            }
            return $result
        }

        if ($Object -is [pscustomobject]) {
            $result = [ordered]@{}
            foreach ($property in $Object.PSObject.Properties) {
                $result[$property.Name] = ConvertTo-HashtableRecursive $property.Value
            }
            return $result
        }

        if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
            $items = @($Object)
            $converted = [object[]]::new($items.Count)
            for ($index = 0; $index -lt $items.Count; $index++) {
                $converted[$index] = ConvertTo-HashtableRecursive $items[$index]
            }
            return ,$converted
        }

        return $Object
    }
}

function Test-EntriesEqual {
    param(
        [Parameter(Mandatory)]$Current,
        [Parameter(Mandatory)]$Desired
    )

    $currentJson = $Current | ConvertTo-Json -Depth 20 -Compress
    $desiredJson = $Desired | ConvertTo-Json -Depth 20 -Compress
    return $currentJson -eq $desiredJson
}

function Merge-McpEntry {
    param(
        [Parameter(Mandatory)][string]$ConfigFile,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Entry,
        [Parameter(Mandatory)][string]$Label
    )

    $existing = $null
    $current = $null
    $hadFile = Test-Path -LiteralPath $ConfigFile

    if ($hadFile) {
        Write-Info "Found existing $ConfigFile"
        try {
            $existing = Get-Content -Raw -LiteralPath $ConfigFile |
                ConvertFrom-Json -ErrorAction Stop |
                ConvertTo-HashtableRecursive
        }
        catch {
            throw "existing $ConfigFile is not valid JSON - refusing to touch it."
        }

        if ($existing.Contains($Section)) {
            if ($null -ne $existing[$Section] -and
                $existing[$Section] -isnot [System.Collections.IDictionary]) {
                throw "existing '$Section' value in $ConfigFile is not an object - refusing to replace it."
            }
            if ($null -ne $existing[$Section] -and $existing[$Section].Contains('newrelic')) {
                $current = $existing[$Section]['newrelic']
            }
        }
    }

    if ($null -ne $current -and (Test-EntriesEqual -Current $current -Desired $Entry)) {
        Write-Ok "$Label is already configured in $ConfigFile"
        return
    }

    if ($Check) {
        if ($null -ne $current) {
            Write-Warn2 "$Label has a different 'newrelic' entry in $ConfigFile; install would replace it."
        }
        else {
            Write-Ok "$Label would add 'newrelic' to $ConfigFile"
        }
        return
    }

    if ($null -ne $current -and -not $ReplaceExisting) {
        if ([Console]::IsInputRedirected) {
            throw "a different 'newrelic' entry exists in $ConfigFile; re-run interactively or pass -Force."
        }
        $response = Read-Host "Replace the existing 'newrelic' entry in $ConfigFile? (y/N)"
        if ($response -notmatch '^[yY]') {
            throw "installation skipped for $ConfigFile"
        }
    }

    $parentDirectory = Split-Path -Parent $ConfigFile
    if (-not (Test-Path -LiteralPath $parentDirectory)) {
        New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
    }

    $backup = $null
    if ($hadFile) {
        $backup = "$ConfigFile.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $ConfigFile -Destination $backup -Force
        Write-Ok "backed up existing config -> $backup"
    }

    if ($null -eq $existing) {
        $existing = [ordered]@{}
    }
    if (-not $existing.Contains($Section) -or $null -eq $existing[$Section]) {
        $existing[$Section] = [ordered]@{}
    }
    $existing[$Section]['newrelic'] = $Entry

    $tempFile = "$ConfigFile.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        $json = $existing | ConvertTo-Json -Depth 20
        $bytes = [System.Text.UTF8Encoding]::new($true).GetBytes($json)
        [System.IO.File]::WriteAllBytes($tempFile, $bytes)
        Get-Content -Raw -LiteralPath $tempFile | ConvertFrom-Json -ErrorAction Stop | Out-Null
        Move-Item -LiteralPath $tempFile -Destination $ConfigFile -Force
    }
    catch {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        if ($backup) {
            Copy-Item -LiteralPath $backup -Destination $ConfigFile -Force
        }
        throw
    }

    Write-Ok "$Label added 'newrelic' to $ConfigFile"
}

$copilotHomeDirectory = if ($env:COPILOT_HOME) {
    $env:COPILOT_HOME
}
else {
    Join-Path $HOME '.copilot'
}
$copilotConfig = Join-Path $copilotHomeDirectory 'mcp-config.json'
$vscodeConfig = Join-Path (Join-Path $Workspace '.vscode') 'mcp.json'

if ($Target -in @('All', 'VSCode') -and -not (Test-Path -LiteralPath $Workspace -PathType Container)) {
    throw "VS Code workspace does not exist: $Workspace"
}

$copilotEntry = [ordered]@{
    type  = 'http'
    url   = 'https://mcp.newrelic.com/mcp/'
    tools = [object[]]@('*')
}
$vscodeEntry = [ordered]@{
    type = 'http'
    url  = 'https://mcp.newrelic.com/mcp/'
}

Write-Head 'New Relic MCP - GitHub Copilot OAuth install'

if ($Target -in @('All', 'Copilot')) {
    Merge-McpEntry -ConfigFile $copilotConfig -Section 'mcpServers' -Entry $copilotEntry -Label 'Copilot CLI/Agent Host (shared with app)'
}
if ($Target -in @('All', 'VSCode')) {
    Merge-McpEntry -ConfigFile $vscodeConfig -Section 'servers' -Entry $vscodeEntry -Label 'VS Code GitHub Copilot'
}

if ($Check) {
    Write-Info 'Check-only mode: no files changed.'
    return
}

Write-Head 'Next steps'
if ($Target -in @('All', 'Copilot')) {
    Write-Info "Copilot CLI: restart it, run 'copilot mcp get newrelic', then use a New Relic tool."
    Write-Info 'VS Code Agent Host reads this same user-level Copilot MCP configuration.'
    Write-Warn2 'Copilot app imports this entry, but active third-party OAuth host bugs may block sign-in.'
    Write-Info 'If app authorization fails, use Copilot CLI or VS Code until the host bug is fixed.'
}
if ($Target -in @('All', 'VSCode')) {
    Write-Info "VS Code: reopen $Workspace, run 'MCP: List Servers', and start newrelic."
}
Write-Info 'On first connection, complete the separate New Relic > OneLogin OAuth flow.'
Write-Info 'New Relic issues a separate New Relic OAuth token for its MCP resource.'
Write-Info 'Your GitHub/Copilot sign-in and token are not sent to or reused by New Relic.'
