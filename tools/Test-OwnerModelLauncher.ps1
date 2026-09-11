#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Model,

    [ValidateSet('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')]
    [string]$CredentialEnvironmentName,

    [string]$CopilotPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerModelRunner\DevPilot.OwnerModelRunner.psd1" -Force

$providerParameters = @{
    Model = $Model
}
if (-not [string]::IsNullOrWhiteSpace($CredentialEnvironmentName)) {
    $providerParameters.CredentialEnvironmentName = $CredentialEnvironmentName
}
if (-not [string]::IsNullOrWhiteSpace($CopilotPath)) {
    $providerParameters.FilePath = $CopilotPath
}

$provider = New-OwnerCopilotCliModelProvider @providerParameters
$result = Test-OwnerModelProviderPreflight -Provider $provider
if ($result.available -and $result.localProcessMetadataExposure -and
    [string]::IsNullOrWhiteSpace([string]$result.risk)) {
    throw '[owner-model-launch-unavailable] Prompt transport risk provenance was missing.'
}
$result | ConvertTo-Json -Depth 8
if (-not $result.available) {
    throw "[owner-model-launch-unavailable] $($result.reason)"
}
