#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Prepares an unactivated private merged-source pin after fresh proof.
.DESCRIPTION
    Default-off. Verifies the user-accepted source route with a fresh bounded
    same-bearer proof before creating any ACL-private selector or pin files.
#>
[CmdletBinding()]
param(
    [string]$StateRoot,
    [string]$Organization,
    [string]$SourceProjectName,
    [string]$SourceRepositoryName,
    [int]$SourcePullRequestId,
    [string]$SourceDocumentPath,
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
$source = @{ organization = $Organization
    projectName = $SourceProjectName
    repositoryName = $SourceRepositoryName }
Invoke-PrivateCanaryMergedPinProvision -StateRoot $StateRoot `
    -RepositoryRoot $repo -SourceSelector $source `
    -SourcePullRequestId $SourcePullRequestId `
    -DocumentPath $SourceDocumentPath `
    -AzureCliPath $AzureCliPath -Run | ConvertTo-Json
