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
$IsWindowsPlatform = $env:OS -eq 'Windows_NT'
$StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$JsonSerializationDepth = 100

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

    $currentJson = ConvertTo-CanonicalJsonValue $Current |
        ConvertTo-Json -Depth $JsonSerializationDepth -Compress
    $desiredJson = ConvertTo-CanonicalJsonValue $Desired |
        ConvertTo-Json -Depth $JsonSerializationDepth -Compress
    return $currentJson -eq $desiredJson
}

function ConvertTo-CanonicalJsonValue {
    param($Object)

    if ($Object -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        $keys = [string[]]@($Object.Keys)
        [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
        foreach ($key in $keys) {
            $result[$key] = ConvertTo-CanonicalJsonValue $Object[$key]
        }
        return $result
    }

    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        $items = @($Object)
        $converted = [object[]]::new($items.Count)
        for ($index = 0; $index -lt $items.Count; $index++) {
            $converted[$index] = ConvertTo-CanonicalJsonValue $items[$index]
        }
        return ,$converted
    }

    return $Object
}

function Assert-JsonSerializationDepth {
    param(
        $Object,
        [int]$Depth = 0
    )

    if ($Depth -gt $JsonSerializationDepth) {
        throw "existing configuration exceeds the supported JSON nesting depth of $JsonSerializationDepth - refusing to rewrite it."
    }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($value in $Object.Values) {
            Assert-JsonSerializationDepth -Object $value -Depth ($Depth + 1)
        }
        return
    }

    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        foreach ($value in $Object) {
            Assert-JsonSerializationDepth -Object $value -Depth ($Depth + 1)
        }
    }
}

function Read-Utf8FileText {
    param([Parameter(Mandatory)][string]$Path)

    return [System.IO.File]::ReadAllText($Path, $StrictUtf8)
}

function New-UserOnlyWindowsAcl {
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [System.Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $currentUser,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
    return $acl
}

function Set-SecureFilePermissions {
    param(
        [Parameter(Mandatory)][string]$Path,
        [System.Security.AccessControl.FileSecurity]$WindowsAcl
    )

    if ($IsWindowsPlatform) {
        $acl = if ($null -ne $WindowsAcl) { $WindowsAcl } else { New-UserOnlyWindowsAcl }
        Set-Acl -LiteralPath $Path -AclObject $acl
        return
    }

    $chmod = Get-Command chmod -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    & $chmod.Source 600 $Path
    if ($LASTEXITCODE -ne 0) {
        throw "failed to restrict permissions on $Path"
    }
}

function Test-SecureWindowsAcl {
    param([Parameter(Mandatory)][string]$Path)

    $allowedSids = @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        'S-1-5-18',      # SYSTEM
        'S-1-5-32-544'   # BUILTIN\Administrators
    )
    $broadSids = @(
        'S-1-1-0',       # Everyone
        'S-1-5-11',      # Authenticated Users
        'S-1-5-32-545'   # BUILTIN\Users
    )
    $genericRead = [long]2147483648
    $genericWrite = [long]1073741824
    $genericAll = [long]268435456
    $sensitiveAccessMask = (
        [long][System.Security.AccessControl.FileSystemRights]::ReadData -bor
        [long][System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [long][System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [long][System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [long][System.Security.AccessControl.FileSystemRights]::Delete -bor
        [long][System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [long][System.Security.AccessControl.FileSystemRights]::TakeOwnership -bor
        $genericRead -bor
        $genericWrite -bor
        $genericAll
    )
    $acl = Get-Acl -LiteralPath $Path
    $ownerSid = $acl.GetOwner(
        [System.Security.Principal.SecurityIdentifier]
    ).Value
    if ($ownerSid -notin $allowedSids) {
        return $false
    }
    $rules = $acl.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]
    )

    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne
            [System.Security.AccessControl.AccessControlType]::Allow) {
            continue
        }
        $rightsMask = [long]$rule.FileSystemRights -band 4294967295
        if (($rightsMask -band $sensitiveAccessMask) -eq 0) {
            continue
        }

        $sid = $rule.IdentityReference.Value
        if ($sid -in $broadSids -or $sid -notin $allowedSids) {
            return $false
        }
    }

    return $true
}

function Test-SecureFilePermissions {
    param([Parameter(Mandatory)][string]$Path)

    if ($IsWindowsPlatform) {
        return Test-SecureWindowsAcl -Path $Path
    }

    return [int]([System.IO.File]::GetUnixFileMode($Path)) -eq 384
}

function Write-SecureFileBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [System.Security.AccessControl.FileSecurity]$WindowsAcl
    )

    $stream = $null
    $createdFile = $false
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $createdFile = $true
        $stream.Dispose()
        $stream = $null

        # Secure the empty file before any potentially sensitive config is written.
        Set-SecureFilePermissions -Path $Path -WindowsAcl $WindowsAcl
        [System.IO.File]::WriteAllBytes($Path, $Bytes)
        Set-SecureFilePermissions -Path $Path -WindowsAcl $WindowsAcl
    }
    catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if ($createdFile) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Restore-SecureFileBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [System.Security.AccessControl.FileSecurity]$WindowsAcl
    )

    $restoreFile = "$Path.restore-$([guid]::NewGuid().ToString('N'))"
    $displacedFile = "$Path.displaced-$([guid]::NewGuid().ToString('N'))"
    try {
        Write-SecureFileBytes -Path $restoreFile -Bytes $Bytes -WindowsAcl $WindowsAcl
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($restoreFile, $Path, $displacedFile)
            Remove-Item -LiteralPath $displacedFile -Force
        }
        else {
            Move-Item -LiteralPath $restoreFile -Destination $Path
        }
        Set-SecureFilePermissions -Path $Path -WindowsAcl $WindowsAcl
        if (-not (Test-SecureFilePermissions -Path $Path)) {
            throw "failed to verify restored permissions on $Path"
        }
    }
    catch {
        Remove-Item -LiteralPath $restoreFile -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $displacedFile) {
            if (Test-Path -LiteralPath $Path) {
                Remove-Item -LiteralPath $displacedFile -Force -ErrorAction SilentlyContinue
            }
            else {
                Move-Item -LiteralPath $displacedFile -Destination $Path
            }
        }
        throw
    }
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
    $permissionsSecure = $true

    if ($hadFile) {
        Write-Info "Found existing $ConfigFile"
        try {
            $existing = Read-Utf8FileText -Path $ConfigFile |
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
        $permissionsSecure = Test-SecureFilePermissions -Path $ConfigFile
        if ($Check -and -not $permissionsSecure) {
            throw "$Label is configured in $ConfigFile, but its permissions allow unapproved access or ownership."
        }
        if ($IsWindowsPlatform -and -not $Check -and -not $permissionsSecure) {
            throw "$Label config $ConfigFile grants sensitive access or ownership outside the current user, SYSTEM, or Administrators; refusing to preserve or copy that ACL."
        }
    }

    if ($null -ne $current -and (Test-EntriesEqual -Current $current -Desired $Entry)) {
        if ($Check) {
            Write-Ok "$Label is already configured securely in $ConfigFile"
            return
        }

        if (-not $permissionsSecure) {
            Set-SecureFilePermissions -Path $ConfigFile
            if (-not (Test-SecureFilePermissions -Path $ConfigFile)) {
                throw "failed to verify secure permissions on $ConfigFile"
            }
            Write-Ok "$Label was already configured; restricted $ConfigFile to mode 0600"
        }
        else {
            Write-Ok "$Label is already configured in $ConfigFile"
        }
        return
    }

    if ($null -eq $existing) {
        $existing = [ordered]@{}
    }
    if (-not $existing.Contains($Section) -or $null -eq $existing[$Section]) {
        $existing[$Section] = [ordered]@{}
    }
    $existing[$Section]['newrelic'] = $Entry
    Assert-JsonSerializationDepth -Object $existing

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
    $originalWindowsAcl = if ($hadFile -and $IsWindowsPlatform) {
        Get-Acl -LiteralPath $ConfigFile
    }
    else {
        $null
    }
    $tempFile = "$ConfigFile.tmp-$([guid]::NewGuid().ToString('N'))"
    $displacedFile = "$ConfigFile.displaced-$([guid]::NewGuid().ToString('N'))"
    $configReplaced = $false
    try {
        if ($hadFile) {
            $backup = "$ConfigFile.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')"
            $backupBytes = [System.IO.File]::ReadAllBytes($ConfigFile)
            Write-SecureFileBytes -Path $backup -Bytes $backupBytes -WindowsAcl $originalWindowsAcl
            if (-not (Test-SecureFilePermissions -Path $backup)) {
                throw "backup permissions could not be verified as secure for $backup"
            }
            Write-Ok "backed up existing config -> $backup"

            if (-not $permissionsSecure) {
                Set-SecureFilePermissions -Path $ConfigFile
                if (-not (Test-SecureFilePermissions -Path $ConfigFile)) {
                    throw "failed to verify secure permissions on $ConfigFile"
                }
            }
        }

        $json = $existing | ConvertTo-Json -Depth $JsonSerializationDepth
        $bytes = [System.Text.UTF8Encoding]::new($true).GetBytes($json)
        Write-SecureFileBytes -Path $tempFile -Bytes $bytes -WindowsAcl $originalWindowsAcl
        Read-Utf8FileText -Path $tempFile | ConvertFrom-Json -ErrorAction Stop | Out-Null
        if ($hadFile) {
            [System.IO.File]::Replace($tempFile, $ConfigFile, $displacedFile)
        }
        else {
            Move-Item -LiteralPath $tempFile -Destination $ConfigFile
        }
        $configReplaced = $true
        Set-SecureFilePermissions -Path $ConfigFile -WindowsAcl $originalWindowsAcl
        if (-not (Test-SecureFilePermissions -Path $ConfigFile)) {
            throw "failed to verify secure permissions on $ConfigFile"
        }
        if ($hadFile) {
            Remove-Item -LiteralPath $displacedFile -Force
        }
    }
    catch {
        $operationError = $_
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        if ($backup -and $configReplaced) {
            $restoreBytes = [System.IO.File]::ReadAllBytes($backup)
            try {
                Restore-SecureFileBytes -Path $ConfigFile -Bytes $restoreBytes -WindowsAcl $originalWindowsAcl
            }
            catch {
                Remove-Item -LiteralPath $displacedFile -Force -ErrorAction SilentlyContinue
                throw "installation and verified rollback failed; secure backup retained at $backup. Rollback error: $($_.Exception.Message)"
            }
        }
        elseif ($configReplaced) {
            Remove-Item -LiteralPath $ConfigFile -Force -ErrorAction SilentlyContinue
        }
        if ($backup) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $displacedFile -Force -ErrorAction SilentlyContinue
        throw $operationError
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
