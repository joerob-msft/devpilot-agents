#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Prepares exactly two ACL-private coverage-only merged-source receipts.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)][string]$ProjectName,
    [Parameter(Mandatory)][string]$RepositoryName,
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
    @{ state = 'disabled'; signed = $false; providerReads = 0
        providerWrites = 0 } | ConvertTo-Json
    return
}
& (Join-Path $PSScriptRoot 'Initialize-PrivateActivePrCanaryInputs.ps1') `
    -Organization $Organization -ProjectName $ProjectName `
    -RepositoryName $RepositoryName -StateRoot $StateRoot `
    -SourceSelectorPath $SourceSelectorPath `
    -SourceSelectorKeyPath $SourceSelectorKeyPath `
    -MergedPinPath $MergedPinPath -MergedPinKeyPath $MergedPinKeyPath `
    -AzureCliPath $AzureCliPath -Mode CoverageOnly -Run
