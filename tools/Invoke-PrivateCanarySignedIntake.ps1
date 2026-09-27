#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Signs a verified, read-only four-rule canary intake without evaluating it.
.DESCRIPTION
    Default-off. Requires PR189 private receipts, fresh PR190 verification,
    complete two-pass active-PR intake and one or two explicit eligible heads.
    Produces only ACL-private external files; the signed config cannot run the
    legacy @1 dispatcher or authorize a writer or model.
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
        (Test-AgentPathWithin -Path $file -Root $repo) -or
        (Test-AgentPathWithin -Path $StateRoot -Root (Split-Path $file -Parent)) -or
        (Test-AgentPathWithin -Path $file -Root $StateRoot)) {
        throw 'Canary inputs must be external and disjoint from new state.'
    }
    [void](Assert-AgentTrustedFile -Path $file -Private)
}
$providerConfig = Get-Content -LiteralPath $ProviderConfigPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 32
$approvedSources = Get-Content -LiteralPath $ApprovedSourcesPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 32
Invoke-PrivateCanarySignedIntake -ProviderConfig $providerConfig `
    -ApprovedSources $approvedSources -StateRoot $StateRoot `
    -RepositoryRoot $repo -CanaryPullRequestIds $CanaryPullRequestIds `
    -AzureCliPath $AzureCliPath -Run:$Run | ConvertTo-Json -Depth 16
