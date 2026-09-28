#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Prepares an unactivated, reviewer-approved private merged-source pin.
.DESCRIPTION
    Default-off. Requires independently signed approval and fresh bounded
    same-bearer source proof before creating an external ACL-private directory.
#>
[CmdletBinding()]
param(
    [string]$StateRoot,
    [string]$SourceSelectorPath,
    [string]$SourceSelectorKeyPath,
    [string]$ReviewerApprovalPath,
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
$approval = Read-CanaryPrivateReviewerApproval `
    -ApprovalPath $ReviewerApprovalPath -RepositoryRoot $repo
Invoke-PrivateCanaryMergedPinProvision -StateRoot $StateRoot `
    -RepositoryRoot $repo -SourceSelector $source.selector `
    -SourceSelectorKey $source.key -ReviewerApproval $approval `
    -AzureCliPath $AzureCliPath -Run | ConvertTo-Json
