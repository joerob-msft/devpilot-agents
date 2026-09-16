[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$RepositoryRoot
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force -DisableNameChecking
Resolve-AgentTrustedRoot -Path $Path -Kind durable-state -RepositoryRoot $RepositoryRoot -Create
