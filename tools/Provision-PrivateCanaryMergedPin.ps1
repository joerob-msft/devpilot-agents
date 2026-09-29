#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Prepares an unactivated private merged-source pin after fresh proof.
.DESCRIPTION
    Default-off. Requires the user-authorized signed source selector and fresh
    bounded same-bearer proof before creating an ACL-private directory.
#>
[CmdletBinding()]
param(
    [string]$StateRoot,
    [string]$SourceSelectorPath,
    [string]$SourceSelectorKeyPath,
    [string]$AzureCliPath = 'az',
    [switch]$Run
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src\DevPilot.ActivePrCanary\DevPilot.ActivePrCanary.psm1')
if (-not $Run) {
    @{ state = 'disabled'; providerReads = 0
        providerWrites = 0; privateFilesWritten = 0 } | ConvertTo-Json
    return
}
$source = Read-CanaryPrivateSourceSelector `
    -SelectorPath $SourceSelectorPath -KeyPath $SourceSelectorKeyPath `
    -RepositoryRoot $repo
Invoke-PrivateCanaryMergedPinProvision -StateRoot $StateRoot `
    -RepositoryRoot $repo -SourceSelector $source.selector `
    -SourceSelectorKey $source.key `
    -AzureCliPath $AzureCliPath -Run | ConvertTo-Json
