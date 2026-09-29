#!/usr/bin/env pwsh
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProviderConfigPath,
    [Parameter(Mandatory)][string]$ApprovedSourcesPath,
    [string]$SourceSelectorPath,
    [string]$SourceSelectorKeyPath,
    [string]$MergedPinPath,
    [string]$MergedPinKeyPath,
    [string]$AzureCliPath = 'az',
    [switch]$Run
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Run) {
    @{ state = 'disabled'; providerReads = 0; providerWrites = 0
        evaluated = $false; writerEligible = $false } | ConvertTo-Json
    return
}
& (Join-Path $PSScriptRoot 'Invoke-PrivateCanaryRuleRegistry.ps1') `
    -ProviderConfigPath $ProviderConfigPath `
    -ApprovedSourcesPath $ApprovedSourcesPath `
    -SourceSelectorPath $SourceSelectorPath `
    -SourceSelectorKeyPath $SourceSelectorKeyPath `
    -MergedPinPath $MergedPinPath -MergedPinKeyPath $MergedPinKeyPath `
    -AzureCliPath $AzureCliPath -Mode CoverageOnly -Run
