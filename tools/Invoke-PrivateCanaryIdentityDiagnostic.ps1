#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Classifies one bounded read-only ADO Identity GET without creating state.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)][string]$ExpectedAccountUniqueName,
    [string]$AzureCliPath = 'az',
    [switch]$VerifyGraph,
    [switch]$Run
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'src\DevPilot.ActivePrCanary\PrivateCanaryIdentityOutput.ps1')
Import-Module (Join-Path $repo 'src\DevPilot.ActivePrCanary\DevPilot.ActivePrCanary.psm1')
$result = Invoke-PrivateCanaryIdentityDiagnostic -Organization $Organization `
    -ExpectedAccountUniqueName $ExpectedAccountUniqueName `
    -RepositoryRoot $repo -AzureCliPath $AzureCliPath `
    -VerifyGraph:$VerifyGraph -Run:$Run
ConvertTo-PrivateCanaryIdentityOutput `
    -Json (ConvertTo-Json -InputObject $result -Depth 4) `
    -VerifyGraph:$VerifyGraph -Run:$Run
