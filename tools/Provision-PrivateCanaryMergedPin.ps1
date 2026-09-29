#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Prepares an unactivated private merged-source pin after fresh proof.
.DESCRIPTION
    Default-off. Verifies the user-accepted source route with a fresh bounded
    same-bearer proof before creating any ACL-private selector or pin files.
    Run only within an existing PowerShell process with SourceInput held in
    memory; do not pass source selectors through process arguments.
#>
[CmdletBinding()]
param(
    [string]$StateRoot,
    [object]$SourceInput,
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
if ($SourceInput -isnot [Collections.IDictionary] -or
    $SourceInput.Count -ne 5) {
    throw 'source-selector-invalid'
}
foreach ($field in @('organization', 'projectName', 'repositoryName',
        'pullRequestId', 'documentPath')) {
    if (-not $SourceInput.Contains($field)) {
        throw 'source-selector-invalid'
    }
}
$source = @{ organization = $SourceInput.organization
    projectName = $SourceInput.projectName
    repositoryName = $SourceInput.repositoryName }
Invoke-PrivateCanaryMergedPinProvision -StateRoot $StateRoot `
    -RepositoryRoot $repo -SourceSelector $source `
    -SourcePullRequestId $SourceInput.pullRequestId `
    -DocumentPath $SourceInput.documentPath `
    -AzureCliPath $AzureCliPath -Run | ConvertTo-Json
