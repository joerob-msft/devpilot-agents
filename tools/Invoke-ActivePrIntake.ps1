#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Runs a bounded read-only active PR intake manually.
.DESCRIPTION
    Does not schedule execution, evaluate rules automatically, or post comments.
    Writes immutable private cohort generations and an atomic latest snapshot.
    The CLI's GET-only change listing has no reliable changed-line total:
    selected heads remain unknown with the changed-line-counts capability unmet.
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
