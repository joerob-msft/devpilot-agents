#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Verifies the reviewed merged master source without creating state.
.DESCRIPTION
    Disabled without -Run. A reviewed repository-owned immutable source pin
    must exist before any ADO request is made. No private root is used.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Organization,
    [string]$SourceSelectorPath,
    [string]$SourceSelectorKeyPath,
    [string]$MergedPinPath,
    [string]$MergedPinKeyPath,
    [string]$AzureCliPath = 'az',
    [switch]$Run
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src\DevPilot.ActivePrCanary\DevPilot.ActivePrCanary.psm1')
if (-not $Run) {
    @{ state = 'disabled'; providerReads = 0; providerWrites = 0 } |
        ConvertTo-Json
    return
}
$source = Read-CanaryPrivateSourceSelector -SelectorPath $SourceSelectorPath `
    -KeyPath $SourceSelectorKeyPath -RepositoryRoot $repo
$merged = Read-CanaryPrivateMergedPin -PinPath $MergedPinPath `
    -KeyPath $MergedPinKeyPath -RepositoryRoot $repo `
    -SourceSelector $source.selector
$expected = Get-CanaryWorkAccountUpn $AzureCliPath
Invoke-CanaryMergedMasterPreflight -Organization $Organization `
    -ExpectedAccountUniqueName $expected -RepositoryRoot $repo `
    -SourceSelector $source.selector -SourceSelectorKey $source.key `
    -MergedPinEnvelope $merged.envelope -MergedPinKey $merged.key `
    -AzureCliPath $AzureCliPath -Run | ConvertTo-Json -Depth 8
