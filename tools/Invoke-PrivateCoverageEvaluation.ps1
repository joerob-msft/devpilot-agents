#!/usr/bin/env pwsh
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StateRoot,
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
    @{ state = 'disabled'; evaluated = $false
        providerReads = 0; providerWrites = 0
        modelToolInvocations = 0; writerEligible = $false } | ConvertTo-Json
    return
}
& (Join-Path $PSScriptRoot 'Invoke-PrivateCanaryEvaluation.ps1') `
    -StateRoot $StateRoot `
    -SourceSelectorPath $SourceSelectorPath `
    -SourceSelectorKeyPath $SourceSelectorKeyPath `
    -MergedPinPath $MergedPinPath -MergedPinKeyPath $MergedPinKeyPath `
    -AzureCliPath $AzureCliPath -Mode CoverageOnly -Run
