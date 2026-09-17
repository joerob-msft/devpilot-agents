#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Reads Owner reviewer artifacts and emits normalized observation or parity JSON.

.DESCRIPTION
    This command is read-only. It starts no model, calls no provider, and writes
    no files. Use the v1 parameter set for external signed queue state, the
    normalized parameter set for future implementations, or compare two
    normalized observation files.
#>
[CmdletBinding(DefaultParameterSetName = 'V1')]
param(
    [Parameter(Mandatory, ParameterSetName = 'V1')][string]$V1Root,
    [Parameter(ParameterSetName = 'V1')]
    [ValidatePattern('^$|^[0-9a-f]{64}$')][string]$HeadKey = '',
    [Parameter(ParameterSetName = 'V1')][string]$KeyPath = '',
    [Parameter(ParameterSetName = 'V1')][string]$SubjectRootOverride = '',

    [Parameter(Mandatory, ParameterSetName = 'Normalized')][string]$NormalizedPath,

    [Parameter(Mandatory, ParameterSetName = 'Compare')][string]$BaselinePath,
    [Parameter(Mandatory, ParameterSetName = 'Compare')][string]$CandidatePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src/OwnerObserver/OwnerObserver.psd1') -Force

$result = switch ($PSCmdlet.ParameterSetName) {
    'V1' {
        Read-OwnerV1Observation -StateRoot $V1Root -HeadKey $HeadKey -KeyPath $KeyPath `
            -SubjectRootOverride $SubjectRootOverride
    }
    'Normalized' {
        Read-OwnerNormalizedObservation -Path $NormalizedPath
    }
    'Compare' {
        $baseline = Read-OwnerNormalizedObservation -Path $BaselinePath
        $candidate = Read-OwnerNormalizedObservation -Path $CandidatePath
        Compare-OwnerObservations -Baseline $baseline -Candidate $candidate
    }
}

$result | ConvertTo-Json -Depth 64
