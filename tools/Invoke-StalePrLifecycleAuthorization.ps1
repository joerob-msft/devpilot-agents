#!/usr/bin/env pwsh
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('initialize-key', 'authorize-policy')]
    [string]$Command,
    [Parameter(Mandatory)][string]$DeliveryRoot,
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$PolicyPath,
    [ValidateRange(1, 2)][int]$MaxAbandonsPerRun = 2,
    [string]$GitPath = 'git',
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.PullRequestLifecycle\DevPilot.PullRequestLifecycle.psd1') `
    -Force

$config = Get-Content -LiteralPath $ConfigPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 64
$context = Initialize-StalePrLifecycleRoot `
    -DeliveryRoot $DeliveryRoot -RepoRoot $RepoRoot
if ($Command -ceq 'initialize-key') {
    [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'stale-pr-lifecycle-key-result'
        lifecycleRoot = $context.Root
        keyPath = $context.KeyPath
        providerWrites = 0
    }
    exit 0
}

$key = Get-StalePrLifecycleKey `
    -LifecycleRoot $context.Root
try {
    $policy = New-StalePrLifecyclePolicy `
        -Config $config -RepoRoot $RepoRoot `
        -GitPath $GitPath `
        -MaxAbandonsPerRun $MaxAbandonsPerRun
    if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
        $PolicyPath = Join-Path $context.Root `
            'policies\azureux-bpm-stale-pr-lifecycle-v1.json'
    }
    $policiesRoot = Join-Path $context.Root 'policies'
    if (-not [IO.Path]::IsPathFullyQualified($PolicyPath) -or
        -not (Test-AgentPathWithin `
            -Path $PolicyPath -Root $policiesRoot)) {
        throw 'Lifecycle policy path must be inside its private policies root.'
    }
    [void](Write-StalePrLifecyclePolicy `
        -Path $PolicyPath -Policy $policy -Key $key)
    [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'stale-pr-lifecycle-policy-result'
        policyPath = [IO.Path]::GetFullPath($PolicyPath)
        policySha256 = (Get-FileHash `
                -LiteralPath $PolicyPath `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        policyDigest = (Get-FileHash `
                -LiteralPath $PolicyPath `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        providerWrites = 0
    }
}
finally {
    [Array]::Clear($key, 0, $key.Length)
}
