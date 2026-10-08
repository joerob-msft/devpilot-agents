#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Discovers bounded current PR heads and evaluates the named AreEqual rule.
.DESCRIPTION
    Default-off and read-only. Without -Run, or when enabled=false, validates
    configuration and returns disabled without provider reads or durable state.
    -Run performs bounded active/non-draft/master-target discovery, derives
    exact changed spans, and writes named-rule V2 observations only. It never
    creates signing keys, policies, delivery events, or Azure DevOps comments.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$AcquisitionPath = '',
    [ValidatePattern('^$|^[0-9a-f]{64}$')]
    [string]$AcquisitionSha256 = '',
    [string]$AzureCliPath = 'az',
    [ValidateRange(0, 4)][int]$MaximumHeadsThisRun = 0,
    [switch]$Run,
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $RepoRoot `
    'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1') -Force
Import-Module (Join-Path $RepoRoot `
    'src\DevPilot.NamedAreEqualBridge\DevPilot.NamedAreEqualBridge.psd1') -Force

$config = Get-Content -LiteralPath $ConfigPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 32
$preparedIntake = $null
if ($AcquisitionPath) {
    if (-not [IO.Path]::IsPathFullyQualified($AcquisitionPath) -or
        -not (Test-Path -LiteralPath $AcquisitionPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $AcquisitionPath `
            -Algorithm SHA256).Hash.ToLowerInvariant() -cne
            $AcquisitionSha256) {
        throw 'Shared acquisition path or digest is invalid.'
    }
    $acquisition = Get-Content -LiteralPath $AcquisitionPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    if ([string]$acquisition.kind -cne
            'devpilot-shared-review-acquisition' -or
        [string]$acquisition.configDigest -cne
            [string]$acquisition.intake.binding.configDigest) {
        throw 'Shared acquisition binding is invalid.'
    }
    $preparedIntake = $acquisition.intake
}
$provider = New-ActivePrAzureDevOpsProvider `
    -Config $config -AzureCliPath $AzureCliPath
Invoke-NamedAreEqualCurrentPrBridge `
    -Config $config -Provider $provider `
    -StateRoot $StateRoot -ManifestPath $ManifestPath `
    -RepositoryRoot $RepoRoot `
    -MaximumHeadsThisRun $MaximumHeadsThisRun `
    -PreparedIntake $preparedIntake -Run:$Run |
    ConvertTo-Json -Depth 32
