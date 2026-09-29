#!/usr/bin/env pwsh
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProviderConfigPath,
    [Parameter(Mandatory)][string]$ApprovedSourcesPath,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][int[]]$CanaryPullRequestIds,
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
    @{ state = 'disabled'; signed = $false; evaluated = $false
        providerReads = 0; providerWrites = 0
        modelToolInvocations = 0; writerEligible = $false } | ConvertTo-Json
    return
}
& (Join-Path $PSScriptRoot 'Invoke-PrivateCanarySignedIntake.ps1') `
    -ProviderConfigPath $ProviderConfigPath `
    -ApprovedSourcesPath $ApprovedSourcesPath -StateRoot $StateRoot `
    -CanaryPullRequestIds $CanaryPullRequestIds `
    -SourceSelectorPath $SourceSelectorPath `
    -SourceSelectorKeyPath $SourceSelectorKeyPath `
    -MergedPinPath $MergedPinPath -MergedPinKeyPath $MergedPinKeyPath `
    -AzureCliPath $AzureCliPath -Mode CoverageOnly -Run
