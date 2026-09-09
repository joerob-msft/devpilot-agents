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

    [int]$LeaseSeconds = 300
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

switch ($Command) {
    'prepare' {
        Invoke-OwnerV2PreviewPrepare -StateRoot $StateRoot -ManifestPath $ManifestPath `
            -MaxAttempts $MaxAttempts
    }
    'run' {
        Invoke-OwnerV2PreviewRun -StateRoot $StateRoot -ManifestPath $ManifestPath `
            -LeaseSeconds $LeaseSeconds
    }
    'prepare-run' {
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $StateRoot -ManifestPath $ManifestPath `
                -MaxAttempts $MaxAttempts)
        Invoke-OwnerV2PreviewRun -StateRoot $StateRoot -ManifestPath $ManifestPath `
            -LeaseSeconds $LeaseSeconds
    }
    'status' {
        Get-OwnerV2PreviewStatus -StateRoot $StateRoot -ManifestPath $ManifestPath
    }
}
