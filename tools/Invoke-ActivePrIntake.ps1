#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Runs a bounded read-only active PR intake manually.
.DESCRIPTION
    Does not schedule execution, evaluate rules automatically, or post comments.
    Without -Run or with enabled=false, only validates and returns a disabled
    summary without ADO requests or durable writes. Explicit enabled -Run
    writes immutable private cohort generations and an atomic latest snapshot.
    Selected heads receive bounded, verified changed-line evidence when all
    exact-commit item reads succeed; unsupported or incomplete diffs stay unknown.
    ADO PR listing has no atomic snapshot token or guaranteed totalCount; intake
    reconciles two full bounded passes but cannot guarantee an atomic snapshot.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$StateRoot,
    [string]$AzureCliPath = 'az',
    [switch]$Run
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1') -Force
$config = Get-Content -LiteralPath $ConfigPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 32
$provider = New-ActivePrAzureDevOpsProvider -Config $config -AzureCliPath $AzureCliPath
Invoke-ActivePrIntake -Config $config -Provider $provider -StateRoot $StateRoot `
    -RepositoryRoot $repo -Run:$Run | ConvertTo-Json -Depth 32
