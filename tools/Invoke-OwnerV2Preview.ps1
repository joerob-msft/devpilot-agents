#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('prepare', 'run', 'prepare-run', 'status')]
    [string]$Command,

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

$liveArguments = @{}
if ($EnableLiveModel) { $liveArguments.EnableLiveModel = $true }
if (-not [string]::IsNullOrWhiteSpace($LiveModel)) { $liveArguments.LiveModel = $LiveModel }
if (-not [string]::IsNullOrWhiteSpace($LiveCredentialEnvironmentName)) {
    $liveArguments.LiveCredentialEnvironmentName = $LiveCredentialEnvironmentName
}
if ($null -ne $LiveAcquisitionProvider) {
    $liveArguments.LiveAcquisitionProvider = $LiveAcquisitionProvider
}
if ($null -ne $LiveModelProvider) { $liveArguments.LiveModelProvider = $LiveModelProvider }

switch ($Command) {
    'prepare' {
        Invoke-OwnerV2PreviewPrepare -StateRoot $StateRoot -ManifestPath $ManifestPath `
            -MaxAttempts $MaxAttempts
    }
    'run' {
        Invoke-OwnerV2PreviewRun -StateRoot $StateRoot -ManifestPath $ManifestPath `
            -LeaseSeconds $LeaseSeconds @liveArguments
    }
    'prepare-run' {
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $StateRoot -ManifestPath $ManifestPath `
                -MaxAttempts $MaxAttempts)
        Invoke-OwnerV2PreviewRun -StateRoot $StateRoot -ManifestPath $ManifestPath `
            -LeaseSeconds $LeaseSeconds @liveArguments
    }
    'status' {
        Get-OwnerV2PreviewStatus -StateRoot $StateRoot -ManifestPath $ManifestPath
    }
}
