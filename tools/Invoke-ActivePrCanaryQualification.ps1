#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Provisions an isolated, default-off, GET-only active-PR canary.
.DESCRIPTION
    Requires an existing private provider config and separately approved
    external rule-source pins. -Run and one or two explicit PR IDs are required
    before any private state or ADO reads. No writer or live model is started.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProviderConfigPath,
    [Parameter(Mandatory)][string]$ApprovedSourcesPath,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][int[]]$CanaryPullRequestIds,
    [string]$AzureCliPath = 'az',
    [switch]$Run
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
Import-Module (Join-Path $repo 'src\DevPilot.ActivePrCanary\DevPilot.ActivePrCanary.psm1')
foreach ($file in @($ProviderConfigPath, $ApprovedSourcesPath)) {
    if (-not [IO.Path]::IsPathFullyQualified($file) -or
        (Test-AgentPathWithin -Path $file -Root $repo)) {
        throw 'Canary inputs must be external private files.'
    }
    [void](Assert-AgentTrustedFile -Path $file -Private)
}
$providerConfig = Get-Content -LiteralPath $ProviderConfigPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 32
$approvedSources = Get-Content -LiteralPath $ApprovedSourcesPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 32
Invoke-ActivePrCanaryQualification -ProviderConfig $providerConfig `
    -ApprovedSources $approvedSources -StateRoot $StateRoot `
    -RepositoryRoot $repo -CanaryPullRequestIds $CanaryPullRequestIds `
    -AzureCliPath $AzureCliPath -Run:$Run | ConvertTo-Json -Depth 16
