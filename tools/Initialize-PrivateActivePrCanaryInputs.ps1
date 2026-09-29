#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Prepares ACL-private read-only canary inputs from verified AAD GETs.
.DESCRIPTION
    Disabled unless -Run is supplied. Preparation stops before intake,
    dispatcher execution, HMAC signing, or any provider write.
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
    [ValidateSet('FourRule', 'CoverageOnly')][string]$Mode = 'FourRule',
    [switch]$Run
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src\DevPilot.ActivePrCanary\DevPilot.ActivePrCanary.psm1')
if (-not $Run) {
    @{ state = 'disabled'; signed = $false; providerReads = 0
        providerWrites = 0 } | ConvertTo-Json
    return
}
$source = Read-CanaryPrivateSourceSelector -SelectorPath $SourceSelectorPath `
    -KeyPath $SourceSelectorKeyPath -RepositoryRoot $repo
$merged = Read-CanaryPrivateMergedPin -PinPath $MergedPinPath `
    -KeyPath $MergedPinKeyPath -RepositoryRoot $repo `
    -SourceSelector $source.selector
$expected = Get-CanaryWorkAccountUpn $AzureCliPath
Invoke-PrivateCanaryBootstrap -Organization $Organization `
    -ProjectName $ProjectName -RepositoryName $RepositoryName `
    -ExpectedAccountUniqueName $expected `
    -SourceSelector $source.selector -SourceSelectorKey $source.key `
    -MergedPinEnvelope $merged.envelope -MergedPinKey $merged.key `
    -StateRoot $StateRoot -RepositoryRoot $repo `
    -AzureCliPath $AzureCliPath -Mode $Mode -Run:$Run | ConvertTo-Json -Depth 8
