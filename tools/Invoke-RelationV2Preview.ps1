#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('prepare-run', 'status')]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$StateRoot,

    [Parameter(Mandatory)]
    [string]$ManifestPath,

    [int]$MaxAttempts = 3,

    [int]$LeaseSeconds = 300,

    [switch]$EnableLiveModel,

    [string]$LiveModel,

    [ValidateSet('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')]
    [string]$LiveCredentialEnvironmentName,

    [AllowNull()][object]$LiveAcquisitionProvider,

    [AllowNull()][object]$LiveModelProvider
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [IO.Path]::IsPathFullyQualified($StateRoot)) {
    throw 'StateRoot must be an absolute path.'
}
if (-not [IO.Path]::IsPathFullyQualified($ManifestPath)) {
    throw 'ManifestPath must be an absolute path.'
}

Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1" -Force

if ($Action -ceq 'status') {
    Get-OwnerV2PreviewStatus -StateRoot $StateRoot -ManifestPath $ManifestPath
    return
}

[void](Invoke-OwnerV2PreviewPrepare -StateRoot $StateRoot -ManifestPath $ManifestPath `
        -MaxAttempts $MaxAttempts)
$arguments = @{}
if ($EnableLiveModel) { $arguments.EnableLiveModel = $true }
if ($null -ne $LiveAcquisitionProvider) {
    $arguments.LiveAcquisitionProvider = $LiveAcquisitionProvider
}
if ($null -ne $LiveModelProvider) { $arguments.LiveModelProvider = $LiveModelProvider }
if (-not [string]::IsNullOrWhiteSpace($LiveModel)) { $arguments.LiveModel = $LiveModel }
if (-not [string]::IsNullOrWhiteSpace($LiveCredentialEnvironmentName)) {
    $arguments.LiveCredentialEnvironmentName = $LiveCredentialEnvironmentName
}
Invoke-OwnerV2PreviewRun -StateRoot $StateRoot -ManifestPath $ManifestPath `
    -LeaseSeconds $LeaseSeconds @arguments
