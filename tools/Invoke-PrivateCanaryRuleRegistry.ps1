#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Revalidates PR189's private receipts into a default-off read-only registry.
.DESCRIPTION
    -Run requires trusted external bootstrap outputs and performs only bounded
    AAD-authenticated GETs. It does not sign, run intake, evaluate, or write state.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProviderConfigPath,
    [Parameter(Mandatory)][string]$ApprovedSourcesPath,
    [string]$SourceSelectorPath,
    [string]$SourceSelectorKeyPath,
    [string]$MergedPinPath,
    [string]$MergedPinKeyPath,
    [string]$AzureCliPath = 'az',
    [ValidateSet('FourRule', 'CoverageOnly')][string]$Mode = 'FourRule',
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
        throw 'Registry receipts must be external private files.'
    }
    [void](Assert-AgentTrustedFile -Path $file -Private)
}
$providerConfig = Get-Content -LiteralPath $ProviderConfigPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 32
$approvedSources = Get-Content -LiteralPath $ApprovedSourcesPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 32
$source = if ($Run) {
    Read-CanaryPrivateSourceSelector -SelectorPath $SourceSelectorPath `
        -KeyPath $SourceSelectorKeyPath -RepositoryRoot $repo
} else { @{ selector = $null; key = $null } }
$merged = if ($Run) {
    Read-CanaryPrivateMergedPin -PinPath $MergedPinPath `
        -KeyPath $MergedPinKeyPath -RepositoryRoot $repo `
        -SourceSelector $source.selector
} else { @{ envelope = $null; key = $null } }
Invoke-PrivateCanaryRuleRegistry -ProviderConfig $providerConfig `
    -ApprovedSources $approvedSources -RepositoryRoot $repo `
    -SourceSelector $source.selector -SourceSelectorKey $source.key `
    -MergedPinEnvelope $merged.envelope -MergedPinKey $merged.key `
    -AzureCliPath $AzureCliPath -Mode $Mode -Run:$Run | ConvertTo-Json -Depth 12
