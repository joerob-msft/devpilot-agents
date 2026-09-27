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
Import-Module (Join-Path $repo 'src\DevPilot.ActivePrCanary\DevPilot.ActivePrCanary.psm1')
Invoke-PrivateCanaryIdentityDiagnostic -Organization $Organization `
    -ExpectedAccountUniqueName $ExpectedAccountUniqueName `
    -RepositoryRoot $repo -AzureCliPath $AzureCliPath `
    -VerifyGraph:$VerifyGraph -Run:$Run |
    ConvertTo-Json -Depth 4
