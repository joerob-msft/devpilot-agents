#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Discovers merged-master source digests for independent human review.
.DESCRIPTION
    Default-off and stateless. No private files, authority pin, intake,
    signing, evaluation, model, or provider write is created.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Organization,
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
$expected = Get-CanaryWorkAccountUpn $AzureCliPath
Invoke-CanaryMergedMasterDiscovery -Organization $Organization `
    -ExpectedAccountUniqueName $expected -RepositoryRoot $repo `
    -AzureCliPath $AzureCliPath -Run | ConvertTo-Json -Depth 8
