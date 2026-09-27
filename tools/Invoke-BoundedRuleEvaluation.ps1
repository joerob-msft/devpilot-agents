#!/usr/bin/env pwsh
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$IntakeConfigPath,
    [Parameter(Mandatory)][string]$StateRoot,
    [string]$AzureCliPath = 'az',
    [string]$SignatureKeyEnvironmentName = 'DEVPILOT_RULE_EVALUATION_KEY',
    [scriptblock]$OwnerEvaluator,
    [switch]$Run
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src\DevPilot.RuleEvaluation\DevPilot.RuleEvaluation.psd1') -Force
Import-Module (Join-Path $repo 'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1')
$config = Get-Content -LiteralPath $ConfigPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 32
$intakeConfig = Get-Content -LiteralPath $IntakeConfigPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 32
if ($Run -and $config.enabled) {
    $provider = New-ActivePrAzureDevOpsProvider -Config $intakeConfig -AzureCliPath $AzureCliPath
} else {
    $provider = { throw 'Disabled evaluation must never contact the provider.' }
}
Invoke-BoundedRuleEvaluation -Config $config -IntakeConfig $intakeConfig `
    -Provider $provider -StateRoot $StateRoot -RepositoryRoot $repo `
    -SignatureKey ([Environment]::GetEnvironmentVariable($SignatureKeyEnvironmentName)) `
    -OwnerEvaluator $OwnerEvaluator -Run:$Run | ConvertTo-Json -Depth 32
