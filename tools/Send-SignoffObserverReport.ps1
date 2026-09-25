#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][string]$AgencyPath,
    [string]$PythonPath = 'python',
    [switch]$EnableDelivery,
    [switch]$PreviewOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$toolkit = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $toolkit 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
Import-Module (Join-Path $toolkit 'src\Agents\signoff-observer\ReportDelivery.psm1') -Force
foreach ($path in @($ConfigFile, $ReportPath)) {
    [void](Assert-AgentTrustedFile -Path ([IO.Path]::GetFullPath($path)) -Private)
}
$python = (Get-Command $PythonPath -CommandType Application -ErrorAction Stop).Source
$validation = Invoke-TimedProcess -FilePath $python -ArgumentList @('-B',
    (Join-Path $toolkit 'src\DevPilot.SignoffConfidence\report_delivery.py'), '--config', $ConfigFile, '--report', $ReportPath) `
    -CaptureStdOut -CaptureStdErr -ContainDescendants -TimeoutSeconds 30
if ($validation.TimedOut -or $validation.ExitCode -ne 0) { throw "Report delivery validation failed: $($validation.StdErr)" }
$prepared = $validation.StdOut | ConvertFrom-Json -AsHashtable
Invoke-SignoffReportDelivery -Prepared $prepared -AgencyPath $AgencyPath -EnableDelivery:$EnableDelivery -PreviewOnly:$PreviewOnly |
    ConvertTo-Json -Depth 5
