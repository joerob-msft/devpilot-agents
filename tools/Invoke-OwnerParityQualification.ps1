#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Executes a read-only Owner v1/v2 parity qualification.

.DESCRIPTION
    Reads the frozen v1 state through OwnerObserver, runs or reads Owner v2
    replay observations in a separate state root, evaluates eight explicit
    gates, proves the v1 tree is unchanged, and writes a private report plus a
    fixed-shape sanitized aggregate summary.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$V1StateRoot,
    [Parameter(Mandatory)][string]$V2StateRoot,
    [Parameter(Mandatory)][string]$QualificationManifestPath,
    [Parameter(Mandatory)][string]$PrivateReportPath,
    [Parameter(Mandatory)][string]$SanitizedSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerParity\DevPilot.OwnerParity.psd1" -Force

Invoke-OwnerParityQualification `
    -V1StateRoot $V1StateRoot `
    -V2StateRoot $V2StateRoot `
    -QualificationManifestPath $QualificationManifestPath `
    -PrivateReportPath $PrivateReportPath `
    -SanitizedSummaryPath $SanitizedSummaryPath
