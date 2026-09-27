#!/usr/bin/env pwsh
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$IntakeConfigPath,
    [Parameter(Mandatory)][string]$StateRoot,
    [string]$AzureCliPath = 'az',
    [string]$SignatureKeyEnvironmentName = 'DEVPILOT_RULE_EVALUATION_KEY',
    [string]$OwnerRuleBytesPath,
    [string]$OwnerModel,
    [ValidateSet('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')]
    [string]$OwnerCredentialEnvironmentName,
    [switch]$EnableOwnerLiveModel,
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
$ownerEvaluator = $null
if ($Run -and $config.enabled -and
    @($config.rules | Where-Object {
        $_.capabilityId -ceq 'bpm-test-ownership@1' -and $_.enabled -ceq $true
    }).Count -eq 1) {
    Import-Module (Join-Path $repo `
        'src\DevPilot.ActiveOwnerEvaluation\DevPilot.ActiveOwnerEvaluation.psd1')
    $ruleBytes = $null
    if (-not [string]::IsNullOrWhiteSpace($OwnerRuleBytesPath)) {
        if (-not [IO.Path]::IsPathFullyQualified($OwnerRuleBytesPath)) {
            throw 'Owner rule bytes require an absolute external path.'
        }
        $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($repo),
            [IO.Path]::GetFullPath($OwnerRuleBytesPath))
        if ($relative -eq '.' -or
            ($relative -notmatch '^\.\.[\\/]|^\.\.$' -and
                -not [IO.Path]::IsPathFullyQualified($relative))) {
            throw 'Owner rule bytes must be external to the repository.'
        }
        if (Test-Path -LiteralPath $OwnerRuleBytesPath -PathType Leaf) {
            $file = Get-Item -LiteralPath $OwnerRuleBytesPath -Force
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Owner rule bytes cannot be a reparse point.'
            }
            if ($file.Length -gt 0 -and $file.Length -le 65536) {
                $ruleBytes = [IO.File]::ReadAllBytes($file.FullName)
            }
        }
    }
    $ownerParameters = @{
        StateRoot = $StateRoot
        RuleBytes = $ruleBytes
        IntakeConfig = $intakeConfig
        ReviewerIdentity = $intakeConfig.expectedAccount
        EnableLiveModel = [bool]$EnableOwnerLiveModel
    }
    if ($OwnerModel) { $ownerParameters.LiveModel = $OwnerModel }
    if ($OwnerCredentialEnvironmentName) {
        $ownerParameters.LiveCredentialEnvironmentName =
            $OwnerCredentialEnvironmentName
    }
    $ownerEvaluator = New-ActiveOwnerEvaluator @ownerParameters
}
Invoke-BoundedRuleEvaluation -Config $config -IntakeConfig $intakeConfig `
    -Provider $provider -StateRoot $StateRoot -RepositoryRoot $repo `
    -SignatureKey ([Environment]::GetEnvironmentVariable($SignatureKeyEnvironmentName)) `
    -OwnerEvaluator $ownerEvaluator -Run:$Run | ConvertTo-Json -Depth 32
