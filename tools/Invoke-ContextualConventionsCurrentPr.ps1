#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    Evaluates the fixed contextual convention bundle on shared current PRs.
.DESCRIPTION
    Default-off and read-only. Without -Run, or when enabled=false, validates
    configuration and returns disabled without provider reads or durable state.
    -Run consumes the prepared shared acquisition when supplied and writes V2
    observations only. It does not create policies, signing keys, delivery
    events, or Azure DevOps comments.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$AcquisitionPath = '',
    [ValidatePattern('^$|^[0-9a-f]{64}$')]
    [string]$AcquisitionSha256 = '',
    [string]$AuthenticatedHistoryPath = '',
    [ValidatePattern('^$|^[0-9a-f]{64}$')]
    [string]$AuthenticatedHistorySha256 = '',
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
    'src\DevPilot.ContextualConventionsBridge\DevPilot.ContextualConventionsBridge.psd1') -Force

$config = Get-Content -LiteralPath $ConfigPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 32
$preparedIntake = $null
$authenticatedPriorComments = @()
if ($AcquisitionPath) {
    if (-not [IO.Path]::IsPathFullyQualified(
            $AcquisitionPath) -or
        -not (Test-Path -LiteralPath $AcquisitionPath `
            -PathType Leaf) -or
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
if ($AuthenticatedHistoryPath) {
    if (-not [IO.Path]::IsPathFullyQualified(
            $AuthenticatedHistoryPath) -or
        -not (Test-Path -LiteralPath `
            $AuthenticatedHistoryPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath `
            $AuthenticatedHistoryPath -Algorithm SHA256).
            Hash.ToLowerInvariant() -cne
            $AuthenticatedHistorySha256) {
        throw 'Authenticated history path or digest is invalid.'
    }
    $history = Get-Content -LiteralPath `
        $AuthenticatedHistoryPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    if ([string]$history.kind -cne
            'owner-v2-authenticated-prior-comment-history' -or
        [int]$history.schemaVersion -ne 1 -or
        $history.comments -isnot [array]) {
        throw 'Authenticated prior-comment history is invalid.'
    }
    $authenticatedPriorComments =
        @($history.comments)
}
$provider = New-ActivePrAzureDevOpsProvider `
    -Config $config -AzureCliPath $AzureCliPath
Invoke-ContextualConventionsCurrentPrBridge `
    -Config $config -Provider $provider `
    -StateRoot $StateRoot -ManifestPath $ManifestPath `
    -RepositoryRoot $RepoRoot `
    -MaximumHeadsThisRun $MaximumHeadsThisRun `
    -PreparedIntake $preparedIntake `
    -AuthenticatedPriorComments `
        $authenticatedPriorComments `
    -Run:$Run |
    ConvertTo-Json -Depth 32
