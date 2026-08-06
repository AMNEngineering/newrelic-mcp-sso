#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeDiscovery {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:BashInstaller = Join-Path $script:RepoRoot 'install-copilot.sh'
    $script:PowerShellInstaller = Join-Path $script:RepoRoot 'install-copilot.ps1'
    $script:IsWindowsHost = $env:OS -eq 'Windows_NT'
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:BashInstaller = Join-Path $script:RepoRoot 'install-copilot.sh'
    $script:PowerShellInstaller = Join-Path $script:RepoRoot 'install-copilot.ps1'
    $script:IsWindowsHost = $env:OS -eq 'Windows_NT'

    function New-TestRoot {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) "newrelic-mcp-sso-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        return $path
    }

    function Set-TestSafeWindowsAcl {
        param([Parameter(Mandatory)][string]$Path)

        $acl = [System.Security.AccessControl.FileSecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
        $allow = [System.Security.AccessControl.AccessControlType]::Allow
        $sids = @(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
            [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
            [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        )
        foreach ($sid in $sids) {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                $fullControl,
                $allow
            )
            [void]$acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
}

Describe 'Source hygiene' {
    It '<Name> parses without PowerShell syntax errors' -ForEach @(
        @{ Name = 'install.ps1'; Path = (Join-Path $script:RepoRoot 'install.ps1') }
        @{ Name = 'install-copilot.ps1'; Path = $script:PowerShellInstaller }
        @{ Name = 'Run-Tests.ps1'; Path = (Join-Path $script:RepoRoot 'Run-Tests.ps1') }
    ) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $Path,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null
        $parseErrors | Should -BeNullOrEmpty
    }

    It 'both Bash installers pass syntax validation' {
        if ($script:IsWindowsHost) {
            Set-ItResult -Skipped -Because 'Bash behavior runs in the Linux hosted-safe job'
            return
        }
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) {
            Set-ItResult -Skipped -Because 'bash is not installed'
            return
        }

        & $bash.Source -n (Join-Path $script:RepoRoot 'install.sh')
        $LASTEXITCODE | Should -Be 0
        & $bash.Source -n $script:BashInstaller
        $LASTEXITCODE | Should -Be 0
    }

    It 'uses atomic replacement and an explicit Windows ACL allowlist' {
        $source = [System.IO.File]::ReadAllText($script:PowerShellInstaller)

        $source | Should -Match '\[System\.IO\.File\]::Replace\(\$tempFile, \$ConfigFile, \$displacedFile\)'
        $source | Should -Not -Match '(?m)^\s*Move-Item .*\$tempFile.*-Force'
        foreach ($sid in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-18', 'S-1-5-32-544')) {
            $source | Should -Match ([regex]::Escape($sid))
        }
    }
}

Describe 'PowerShell Copilot installer' {
    BeforeEach {
        $script:TempRoot = New-TestRoot
        $script:CopilotHome = Join-Path $script:TempRoot 'copilot-home'
        $script:Workspace = Join-Path $script:TempRoot 'workspace'
        New-Item -ItemType Directory -Path $script:Workspace -Force | Out-Null
        $script:PreviousCopilotHome = $env:COPILOT_HOME
        $env:COPILOT_HOME = $script:CopilotHome
    }

    AfterEach {
        if ($null -eq $script:PreviousCopilotHome) {
            Remove-Item Env:COPILOT_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:COPILOT_HOME = $script:PreviousCopilotHome
        }
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
    }

    It 'merges app/CLI and VS Code schemas without secrets' {
        New-Item -ItemType Directory -Path $script:CopilotHome -Force | Out-Null
        @'
{
  "theme": "dark",
  "mcpServers": {
    "other": {
      "type": "stdio",
      "command": "other"
    }
  }
}
'@ | Set-Content -LiteralPath (Join-Path $script:CopilotHome 'mcp-config.json') -Encoding utf8

        & $script:PowerShellInstaller -Target All -Workspace $script:Workspace -Force

        $copilot = Get-Content -Raw -LiteralPath (Join-Path $script:CopilotHome 'mcp-config.json') | ConvertFrom-Json
        $vscode = Get-Content -Raw -LiteralPath (Join-Path $script:Workspace '.vscode/mcp.json') | ConvertFrom-Json

        $copilot.theme | Should -Be 'dark'
        $copilot.mcpServers.other.command | Should -Be 'other'
        $copilot.mcpServers.newrelic.type | Should -Be 'http'
        $copilot.mcpServers.newrelic.url | Should -Be 'https://mcp.newrelic.com/mcp/'
        @($copilot.mcpServers.newrelic.tools) | Should -Be @('*')
        $vscode.servers.newrelic.type | Should -Be 'http'
        $vscode.servers.newrelic.url | Should -Be 'https://mcp.newrelic.com/mcp/'
        $copilot.mcpServers.newrelic.PSObject.Properties.Name | Should -Not -Contain 'headers'
        $vscode.servers.newrelic.PSObject.Properties.Name | Should -Not -Contain 'headers'
    }

    It 'does not create files in check mode' {
        & $script:PowerShellInstaller -Target All -Workspace $script:Workspace -Check

        Test-Path -LiteralPath (Join-Path $script:CopilotHome 'mcp-config.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Workspace '.vscode/mcp.json') | Should -BeFalse
    }

    It 'preserves BOM-less UTF-8 config content' {
        New-Item -ItemType Directory -Path $script:CopilotHome -Force | Out-Null
        $copilotConfig = Join-Path $script:CopilotHome 'mcp-config.json'
        $inputJson = @'
{
  "displayName": "München 東京",
  "mcpServers": {
    "other": {
      "command": "preserve"
    }
  }
}
'@
        [System.IO.File]::WriteAllText(
            $copilotConfig,
            $inputJson,
            [System.Text.UTF8Encoding]::new($false)
        )

        & $script:PowerShellInstaller -Target Copilot -Force

        $written = [System.IO.File]::ReadAllText(
            $copilotConfig,
            [System.Text.UTF8Encoding]::new($false, $true)
        ) | ConvertFrom-Json
        $written.displayName | Should -Be 'München 東京'
        $written.mcpServers.other.command | Should -Be 'preserve'
    }

    It 'preserves unrelated JSON nested beyond the previous depth limit' {
        New-Item -ItemType Directory -Path $script:CopilotHome -Force | Out-Null
        $copilotConfig = Join-Path $script:CopilotHome 'mcp-config.json'
        $deepValue = [ordered]@{ value = 'preserve-deep-value' }
        for ($level = 34; $level -ge 0; $level--) {
            $deepValue = [ordered]@{ "level$level" = $deepValue }
        }
        $inputDocument = [ordered]@{
            unrelated = $deepValue
            mcpServers = [ordered]@{
                other = [ordered]@{ command = 'preserve' }
            }
        }
        [System.IO.File]::WriteAllText(
            $copilotConfig,
            ($inputDocument | ConvertTo-Json -Depth 100),
            [System.Text.UTF8Encoding]::new($false)
        )
        if ($script:IsWindowsHost) {
            Set-TestSafeWindowsAcl -Path $copilotConfig
        }
        else {
            & chmod 600 $copilotConfig
            $LASTEXITCODE | Should -Be 0
        }

        & $script:PowerShellInstaller -Target Copilot -Force

        $written = Get-Content -Raw -LiteralPath $copilotConfig | ConvertFrom-Json
        $cursor = $written.unrelated
        for ($level = 0; $level -le 34; $level++) {
            $cursor = $cursor."level$level"
        }
        $cursor.value | Should -Be 'preserve-deep-value'
    }

    It 'refuses JSON deeper than the supported serialization limit' {
        New-Item -ItemType Directory -Path $script:CopilotHome -Force | Out-Null
        $copilotConfig = Join-Path $script:CopilotHome 'mcp-config.json'
        $deepJson = '"preserve-too-deep"'
        for ($level = 0; $level -le 101; $level++) {
            $deepJson = "{`"level$level`":$deepJson}"
        }
        $inputJson = "{`"unrelated`":$deepJson}"
        [System.IO.File]::WriteAllText(
            $copilotConfig,
            $inputJson,
            [System.Text.UTF8Encoding]::new($false)
        )
        if ($script:IsWindowsHost) {
            Set-TestSafeWindowsAcl -Path $copilotConfig
        }
        else {
            & chmod 600 $copilotConfig
            $LASTEXITCODE | Should -Be 0
        }

        { & $script:PowerShellInstaller -Target Copilot -Check } |
            Should -Throw '*supported JSON nesting depth*'
        { & $script:PowerShellInstaller -Target Copilot -Force } |
            Should -Throw '*supported JSON nesting depth*'
        [System.IO.File]::ReadAllText($copilotConfig) | Should -Be $inputJson
        @(Get-ChildItem -LiteralPath $script:CopilotHome -Filter 'mcp-config.json.bak-*').Count |
            Should -Be 0
    }

    It 'reports and fixes unsafe permissions on an idempotent Unix install' {
        if ($script:IsWindowsHost) {
            Set-ItResult -Skipped -Because 'Unix mode checks do not apply on Windows'
            return
        }

        New-Item -ItemType Directory -Path $script:CopilotHome -Force | Out-Null
        $copilotConfig = Join-Path $script:CopilotHome 'mcp-config.json'
        @'
{
  "mcpServers": {
    "newrelic": {
      "tools": ["*"],
      "url": "https://mcp.newrelic.com/mcp/",
      "type": "http"
    }
  }
}
'@ | Set-Content -LiteralPath $copilotConfig -Encoding utf8
        & chmod 644 $copilotConfig
        $LASTEXITCODE | Should -Be 0

        $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop |
            Select-Object -First 1).Source
        $checkOutput = (& $pwsh -NoProfile -File $script:PowerShellInstaller `
            -Target Copilot -Check 2>&1) | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $checkOutput | Should -Match 'permissions allow unapproved read access'
        [int]([System.IO.File]::GetUnixFileMode($copilotConfig)) | Should -Be 420

        & $script:PowerShellInstaller -Target Copilot
        [int]([System.IO.File]::GetUnixFileMode($copilotConfig)) | Should -Be 384
    }

    It 'rejects broad Windows read ACLs without changing or copying them' {
        if (-not $script:IsWindowsHost) {
            Set-ItResult -Skipped -Because 'Windows ACL checks only apply on Windows'
            return
        }

        New-Item -ItemType Directory -Path $script:CopilotHome -Force | Out-Null
        $copilotConfig = Join-Path $script:CopilotHome 'mcp-config.json'
        @'
{
  "mcpServers": {
    "newrelic": {
      "type": "http",
      "url": "https://mcp.newrelic.com/mcp/",
      "tools": ["*"]
    }
  }
}
'@ | Set-Content -LiteralPath $copilotConfig -Encoding utf8
        Set-TestSafeWindowsAcl -Path $copilotConfig
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $acl = [System.Security.AccessControl.FileSecurity]::new()
        $acl.SetSecurityDescriptorSddlForm(
            "D:P(A;;FA;;;$currentSid)(A;;FA;;;SY)(A;;FA;;;BA)(A;;GR;;;WD)"
        )
        Set-Acl -LiteralPath $copilotConfig -AclObject $acl
        $originalSddl = (Get-Acl -LiteralPath $copilotConfig).Sddl

        { & $script:PowerShellInstaller -Target Copilot -Check } |
            Should -Throw '*permissions allow unapproved read access*'
        (Get-Acl -LiteralPath $copilotConfig).Sddl | Should -Be $originalSddl

        { & $script:PowerShellInstaller -Target Copilot -Force } |
            Should -Throw '*grants read access outside*'
        (Get-Acl -LiteralPath $copilotConfig).Sddl | Should -Be $originalSddl
        @(Get-ChildItem -LiteralPath $script:CopilotHome -Filter 'mcp-config.json.bak-*').Count |
            Should -Be 0
    }

    It 'protects new files and backups without weakening existing Windows ACLs' {
        New-Item -ItemType Directory -Path $script:CopilotHome -Force | Out-Null
        $copilotConfig = Join-Path $script:CopilotHome 'mcp-config.json'
        @'
{
  "mcpServers": {
    "other": {
      "type": "http",
      "url": "https://example.invalid/mcp",
      "headers": {
        "Authorization": "preserve-but-protect"
      }
    }
  }
}
'@ | Set-Content -LiteralPath $copilotConfig -Encoding utf8

        if ($script:IsWindowsHost) {
            Set-TestSafeWindowsAcl -Path $copilotConfig
            $originalSddl = (Get-Acl -LiteralPath $copilotConfig).Sddl
        }
        else {
            & chmod 600 $copilotConfig
            $LASTEXITCODE | Should -Be 0
        }

        & $script:PowerShellInstaller -Target All -Workspace $script:Workspace -Force

        $backup = @(Get-ChildItem -LiteralPath $script:CopilotHome -Filter 'mcp-config.json.bak-*')
        $backup.Count | Should -Be 1
        $vscodeConfig = Join-Path $script:Workspace '.vscode/mcp.json'

        if ($script:IsWindowsHost) {
            (Get-Acl -LiteralPath $copilotConfig).Sddl | Should -Be $originalSddl
            (Get-Acl -LiteralPath $backup[0].FullName).Sddl | Should -Be $originalSddl

            $newFileAcl = Get-Acl -LiteralPath $vscodeConfig
            $newFileAcl.AreAccessRulesProtected | Should -BeTrue
            @($newFileAcl.Access).Count | Should -Be 1
        }
        else {
            foreach ($path in @($copilotConfig, $backup[0].FullName, $vscodeConfig)) {
                [int]([System.IO.File]::GetUnixFileMode($path)) |
                    Should -Be 384 -Because "$path must be mode 0600"
            }
        }
    }

    It 'removes empty artifacts when Unix permission hardening fails' {
        if ($script:IsWindowsHost) {
            Set-ItResult -Skipped -Because 'This failure path uses the Unix chmod implementation'
            return
        }

        New-Item -ItemType Directory -Path $script:CopilotHome -Force | Out-Null
        $copilotConfig = Join-Path $script:CopilotHome 'mcp-config.json'
        '{"mcpServers":{"other":{"headers":{"Authorization":"preserve-me"}}}}' |
            Set-Content -LiteralPath $copilotConfig -Encoding utf8
        $originalContent = Get-Content -Raw -LiteralPath $copilotConfig

        $realChmod = (Get-Command chmod -CommandType Application -ErrorAction Stop).Source
        $fakeBin = Join-Path $script:TempRoot 'fake-bin'
        $fakeChmod = Join-Path $fakeBin 'chmod'
        New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
        "#!/bin/sh`nexit 1`n" | Set-Content -LiteralPath $fakeChmod -Encoding utf8
        & $realChmod +x $fakeChmod
        $LASTEXITCODE | Should -Be 0

        $previousPath = $env:PATH
        try {
            $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$previousPath"
            { & $script:PowerShellInstaller -Target Copilot -Force } |
                Should -Throw '*failed to restrict permissions*'
        }
        finally {
            $env:PATH = $previousPath
        }

        (Get-Content -Raw -LiteralPath $copilotConfig) | Should -Be $originalContent
        @(Get-ChildItem -LiteralPath $script:CopilotHome -Filter 'mcp-config.json.bak-*').Count |
            Should -Be 0
        @(Get-ChildItem -LiteralPath $script:CopilotHome -Filter 'mcp-config.json.tmp-*').Count |
            Should -Be 0
    }

    It 'atomically restores the live Unix config when final hardening fails' {
        if ($script:IsWindowsHost) {
            Set-ItResult -Skipped -Because 'This failure path uses the Unix chmod implementation'
            return
        }

        New-Item -ItemType Directory -Path $script:CopilotHome -Force | Out-Null
        $copilotConfig = Join-Path $script:CopilotHome 'mcp-config.json'
        '{"mcpServers":{"other":{"headers":{"Authorization":"restore-me"}}}}' |
            Set-Content -LiteralPath $copilotConfig -Encoding utf8
        $originalContent = Get-Content -Raw -LiteralPath $copilotConfig
        & chmod 600 $copilotConfig
        $LASTEXITCODE | Should -Be 0

        $realChmod = (Get-Command chmod -CommandType Application -ErrorAction Stop).Source
        $fakeBin = Join-Path $script:TempRoot 'fake-bin'
        $fakeChmod = Join-Path $fakeBin 'chmod'
        New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
        @"
#!/bin/sh
if [ "`$(basename "`$2")" = "mcp-config.json" ]; then
  exit 1
fi
exec "$realChmod" "`$@"
"@ | Set-Content -LiteralPath $fakeChmod -Encoding utf8
        & $realChmod +x $fakeChmod
        $LASTEXITCODE | Should -Be 0

        $previousPath = $env:PATH
        try {
            $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$previousPath"
            { & $script:PowerShellInstaller -Target Copilot -Force } |
                Should -Throw '*verified rollback failed*'
        }
        finally {
            $env:PATH = $previousPath
        }

        Test-Path -LiteralPath $copilotConfig | Should -BeTrue
        (Get-Content -Raw -LiteralPath $copilotConfig) | Should -Be $originalContent
        [int]([System.IO.File]::GetUnixFileMode($copilotConfig)) | Should -Be 384
        $backups = @(Get-ChildItem -LiteralPath $script:CopilotHome -Filter 'mcp-config.json.bak-*')
        $backups.Count | Should -Be 1
        [int]([System.IO.File]::GetUnixFileMode($backups[0].FullName)) | Should -Be 384
        @(Get-ChildItem -LiteralPath $script:CopilotHome -Filter 'mcp-config.json.restore-*').Count |
            Should -Be 0
        @(Get-ChildItem -LiteralPath $script:CopilotHome -Filter 'mcp-config.json.displaced-*').Count |
            Should -Be 0
    }

    It 'refuses to replace a non-object MCP section' {
        New-Item -ItemType Directory -Path $script:CopilotHome -Force | Out-Null
        '{"mcpServers":"preserve-me"}' |
            Set-Content -LiteralPath (Join-Path $script:CopilotHome 'mcp-config.json') -Encoding utf8

        { & $script:PowerShellInstaller -Target Copilot -Workspace $script:Workspace -Force } |
            Should -Throw '*is not an object*'

        $written = Get-Content -Raw -LiteralPath (Join-Path $script:CopilotHome 'mcp-config.json') |
            ConvertFrom-Json
        $written.mcpServers | Should -Be 'preserve-me'
    }

    It 'rejects a nonexistent VS Code workspace' {
        $missingWorkspace = Join-Path $script:TempRoot 'missing'

        { & $script:PowerShellInstaller -Target VSCode -Workspace $missingWorkspace -Check } |
            Should -Throw '*workspace does not exist*'
    }
}

Describe 'Bash Copilot installer' {
    BeforeEach {
        $script:TempRoot = New-TestRoot
        $script:CopilotHome = Join-Path $script:TempRoot 'copilot-home'
        $script:Workspace = Join-Path $script:TempRoot 'workspace'
        New-Item -ItemType Directory -Path $script:Workspace -Force | Out-Null
        $script:PreviousCopilotHome = $env:COPILOT_HOME
        $env:COPILOT_HOME = $script:CopilotHome
    }

    AfterEach {
        if ($null -eq $script:PreviousCopilotHome) {
            Remove-Item Env:COPILOT_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:COPILOT_HOME = $script:PreviousCopilotHome
        }
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
    }

    It 'merges app/CLI and VS Code schemas without secrets' {
        if ($script:IsWindowsHost) {
            Set-ItResult -Skipped -Because 'Bash behavior runs in the Linux hosted-safe job'
            return
        }
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) {
            Set-ItResult -Skipped -Because 'bash is not installed'
            return
        }

        New-Item -ItemType Directory -Path $script:CopilotHome -Force | Out-Null
        '{"theme":"dark","mcpServers":{"other":{"type":"stdio","command":"other"}}}' |
            Set-Content -LiteralPath (Join-Path $script:CopilotHome 'mcp-config.json') -Encoding utf8

        & $bash.Source $script:BashInstaller --target all --workspace $script:Workspace --force
        $LASTEXITCODE | Should -Be 0

        $copilot = Get-Content -Raw -LiteralPath (Join-Path $script:CopilotHome 'mcp-config.json') | ConvertFrom-Json
        $vscode = Get-Content -Raw -LiteralPath (Join-Path $script:Workspace '.vscode/mcp.json') | ConvertFrom-Json

        $copilot.theme | Should -Be 'dark'
        $copilot.mcpServers.other.command | Should -Be 'other'
        $copilot.mcpServers.newrelic.type | Should -Be 'http'
        $copilot.mcpServers.newrelic.url | Should -Be 'https://mcp.newrelic.com/mcp/'
        @($copilot.mcpServers.newrelic.tools) | Should -Be @('*')
        $vscode.servers.newrelic.type | Should -Be 'http'
        $vscode.servers.newrelic.url | Should -Be 'https://mcp.newrelic.com/mcp/'
        $copilot.mcpServers.newrelic.PSObject.Properties.Name | Should -Not -Contain 'headers'
        $vscode.servers.newrelic.PSObject.Properties.Name | Should -Not -Contain 'headers'
    }

    It 'does not create files in check mode' {
        if ($script:IsWindowsHost) {
            Set-ItResult -Skipped -Because 'Bash behavior runs in the Linux hosted-safe job'
            return
        }
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) {
            Set-ItResult -Skipped -Because 'bash is not installed'
            return
        }

        & $bash.Source $script:BashInstaller --target all --workspace $script:Workspace --check
        $LASTEXITCODE | Should -Be 0

        Test-Path -LiteralPath (Join-Path $script:CopilotHome 'mcp-config.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Workspace '.vscode/mcp.json') | Should -BeFalse
    }

    It 'fails check and fixes unsafe permissions on an idempotent install' {
        if ($script:IsWindowsHost) {
            Set-ItResult -Skipped -Because 'Bash behavior runs in the Linux hosted-safe job'
            return
        }
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) {
            Set-ItResult -Skipped -Because 'bash is not installed'
            return
        }

        New-Item -ItemType Directory -Path $script:CopilotHome -Force | Out-Null
        $copilotConfig = Join-Path $script:CopilotHome 'mcp-config.json'
        @'
{
  "mcpServers": {
    "newrelic": {
      "tools": ["*"],
      "url": "https://mcp.newrelic.com/mcp/",
      "type": "http"
    }
  }
}
'@ | Set-Content -LiteralPath $copilotConfig -Encoding utf8
        & chmod 644 $copilotConfig
        $LASTEXITCODE | Should -Be 0

        $checkOutput = (& $bash.Source $script:BashInstaller `
            --target copilot --check 2>&1) | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $checkOutput | Should -Match 'permissions are not user-only'
        [int]([System.IO.File]::GetUnixFileMode($copilotConfig)) | Should -Be 420

        & $bash.Source $script:BashInstaller --target copilot
        $LASTEXITCODE | Should -Be 0
        [int]([System.IO.File]::GetUnixFileMode($copilotConfig)) | Should -Be 384
    }

    It 'creates exclusive mode 0600 backups without predictable overwrite' {
        if ($script:IsWindowsHost) {
            Set-ItResult -Skipped -Because 'Bash behavior runs in the Linux hosted-safe job'
            return
        }
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) {
            Set-ItResult -Skipped -Because 'bash is not installed'
            return
        }

        New-Item -ItemType Directory -Path $script:CopilotHome -Force | Out-Null
        $copilotConfig = Join-Path $script:CopilotHome 'mcp-config.json'
        '{"mcpServers":{"other":{"headers":{"Authorization":"preserve-me"}}}}' |
            Set-Content -LiteralPath $copilotConfig -Encoding utf8

        $realChmod = (Get-Command chmod -CommandType Application -ErrorAction Stop).Source
        $fakeBin = Join-Path $script:TempRoot 'fake-bin'
        $fakeDate = Join-Path $fakeBin 'date'
        New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
        "#!/bin/sh`nprintf '%s\n' '20260806-180000'`n" |
            Set-Content -LiteralPath $fakeDate -Encoding utf8
        & $realChmod +x $fakeDate
        $LASTEXITCODE | Should -Be 0

        $previousPath = $env:PATH
        try {
            $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$previousPath"
            & $bash.Source $script:BashInstaller --target copilot --force
            $LASTEXITCODE | Should -Be 0

            $document = Get-Content -Raw -LiteralPath $copilotConfig | ConvertFrom-Json
            $document.mcpServers.newrelic.url = 'https://conflict.invalid/mcp'
            [System.IO.File]::WriteAllText(
                $copilotConfig,
                ($document | ConvertTo-Json -Depth 20),
                [System.Text.UTF8Encoding]::new($false)
            )

            & $bash.Source $script:BashInstaller --target copilot --force
            $LASTEXITCODE | Should -Be 0
        }
        finally {
            $env:PATH = $previousPath
        }

        $backups = @(Get-ChildItem -LiteralPath $script:CopilotHome -Filter 'mcp-config.json.bak-*')
        $backups.Count | Should -Be 2
        foreach ($backup in $backups) {
            [int]([System.IO.File]::GetUnixFileMode($backup.FullName)) |
                Should -Be 384 -Because "$($backup.FullName) must be mode 0600"
        }
    }

    It 'refuses to replace a non-object MCP section' {
        if ($script:IsWindowsHost) {
            Set-ItResult -Skipped -Because 'Bash behavior runs in the Linux hosted-safe job'
            return
        }
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) {
            Set-ItResult -Skipped -Because 'bash is not installed'
            return
        }

        New-Item -ItemType Directory -Path $script:CopilotHome -Force | Out-Null
        '{"mcpServers":"preserve-me"}' |
            Set-Content -LiteralPath (Join-Path $script:CopilotHome 'mcp-config.json') -Encoding utf8

        & $bash.Source $script:BashInstaller --target copilot --workspace $script:Workspace --force
        $LASTEXITCODE | Should -Not -Be 0

        $written = Get-Content -Raw -LiteralPath (Join-Path $script:CopilotHome 'mcp-config.json') |
            ConvertFrom-Json
        $written.mcpServers | Should -Be 'preserve-me'
    }

    It 'rejects a nonexistent VS Code workspace' {
        if ($script:IsWindowsHost) {
            Set-ItResult -Skipped -Because 'Bash behavior runs in the Linux hosted-safe job'
            return
        }
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) {
            Set-ItResult -Skipped -Because 'bash is not installed'
            return
        }

        $missingWorkspace = Join-Path $script:TempRoot 'missing'
        & $bash.Source $script:BashInstaller --target vscode --workspace $missingWorkspace --check
        $LASTEXITCODE | Should -Not -Be 0
    }
}

Describe 'OAuth security contract' {
    It 'does not put GitHub tokens, New Relic API keys, or authorization headers in Copilot config' {
        $source = @(
            Get-Content -Raw -LiteralPath $script:BashInstaller
            Get-Content -Raw -LiteralPath $script:PowerShellInstaller
        ) -join "`n"

        $source | Should -Not -Match 'NRAK-'
        $source | Should -Not -Match 'COPILOT_GITHUB_TOKEN'
        $source | Should -Not -Match 'Authorization\s*='
        $source | Should -Match 'separate New Relic'
        $source | Should -Match 'separate New Relic OAuth token'
        $source | Should -Match 'third-party OAuth host bugs'
    }
}
