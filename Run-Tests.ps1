#!/usr/bin/env pwsh
<#
.SYNOPSIS
Runs the hosted-safe Pester gate.

.DESCRIPTION
Runs local parsing and isolated installer behavior tests. No test contacts
GitHub, New Relic, OneLogin, or any other network service.
#>

[CmdletBinding()]
param(
    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'

Get-Module Pester | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Force

$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $PSScriptRoot 'tests'
$configuration.Run.Exit = $true
$configuration.Output.Verbosity = if ($Detailed) { 'Detailed' } else { 'Normal' }

Invoke-Pester -Configuration $configuration
