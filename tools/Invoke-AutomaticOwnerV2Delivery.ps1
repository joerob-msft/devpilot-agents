#!/usr/bin/env pwsh
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('initialize-key', 'authorize-policy', 'invoke')]
    [string]$Command,

    [Parameter(Mandatory)][string]$DeliveryRoot,
    [string]$StateRoot,
    [ValidatePattern('^$|^[0-9a-f]{64}$')][string]$Identity,
    [string]$ToolkitConfigPath,
    [string]$PolicyPath,
    [ValidateSet('owner', 'coverage')][string]$Delivery = 'owner',
    [ValidatePattern('^[a-z0-9][a-z0-9_.-]{2,63}$')]
    [string]$PolicyId = '',
    [ValidateRange(1, 5)][int]$MaxCreatesPerRun = 5,
    [ValidateRange(1, 50)][int]$MaxCreatesPerPullRequest = 25,
    [AllowNull()][object]$DeliveryProvider,
    [string]$AzureCliPath = 'az',
    [string]$GitPath = 'git',
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') -Force
Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1') -Force
. (Join-Path $RepoRoot 'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\AutomaticOwnerV2Comments.ps1')
. (Join-Path $RepoRoot `
    'src\Agents\reviewer\AzureDevOpsOwnerV2CommentProvider.ps1')

$context = Initialize-AutomaticOwnerV2DeliveryRoot `
    -DeliveryRoot $DeliveryRoot -RepoRoot $RepoRoot
if (-not $PolicyId) {
    $PolicyId = if ($Delivery -ceq 'coverage') {
        'coverage-v2-production'
    } else { 'owner-v2-production' }
}
if ($Command -ceq 'initialize-key') {
    [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'owner-v2-service-key-result'
        deliveryRoot = $context.Root
        keyPath = $context.KeyPath
        externalWrites = 0
    }
    exit 0
}

if ([string]::IsNullOrWhiteSpace($StateRoot) -or
    [string]::IsNullOrWhiteSpace($Identity) -or
    [string]::IsNullOrWhiteSpace($ToolkitConfigPath) -or
    -not [IO.Path]::IsPathFullyQualified($StateRoot) -or
    -not [IO.Path]::IsPathFullyQualified($ToolkitConfigPath)) {
    throw "$Command requires absolute state/config paths and an exact state identity."
}
$evidence = if ($Delivery -ceq 'coverage') {
    Read-AutomaticCoverageEvidence -StateRoot $StateRoot `
        -Identity $Identity -RepoRoot $RepoRoot `
        -ToolkitConfigPath $ToolkitConfigPath
} else {
    Read-ApprovedOwnerV2Evidence -StateRoot $StateRoot `
        -Identity $Identity -RepoRoot $RepoRoot `
        -ToolkitConfigPath $ToolkitConfigPath
}
$key = Get-AutomaticOwnerV2ServiceKey -DeliveryRoot $context.Root

if ($Command -ceq 'authorize-policy') {
    if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
        $PolicyPath = Join-Path $context.Root "policies\$PolicyId.json"
    }
    if (-not [IO.Path]::IsPathFullyQualified($PolicyPath) -or
        -not (Test-AgentPathWithin -Path $PolicyPath `
            -Root (Join-Path $context.Root 'policies'))) {
        throw 'PolicyPath must be absolute and inside the private policies root.'
    }
    $policy = New-AutomaticOwnerV2ServicePolicy -Evidence $evidence `
        -PolicyId $PolicyId -MaxCreatesPerRun $MaxCreatesPerRun `
        -MaxCreatesPerPullRequest $MaxCreatesPerPullRequest
    [void](Write-AutomaticOwnerV2ServicePolicy -Path $PolicyPath `
            -Policy $policy -Key $key)
    [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'owner-v2-service-policy-result'
        policyPath = [IO.Path]::GetFullPath($PolicyPath)
        policySha256 = Get-ApprovedOwnerV2FileSha256 $PolicyPath
        policyDigest = Get-ApprovedOwnerV2Digest $policy
        externalWrites = 0
    }
    exit 0
}

$toolkitConfig = Read-ApprovedOwnerV2Json -Path $ToolkitConfigPath
$automatic = Get-AutomaticOwnerV2Configuration -ToolkitConfig $toolkitConfig `
    -Delivery $Delivery
if (-not $automatic.Enabled) {
    [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = $(if ($Delivery -ceq 'coverage') {
                'coverage-v2-automatic-delivery-result'
            } else { 'owner-v2-automatic-delivery-result' })
        health = 'disabled'
        providerWrites = 0
        modelWrites = 0
        remainingWouldCreate = @($evidence.Observation.findings |
            Where-Object {
                [string]$_.reconciliation.classification -ceq 'wouldCreate'
            }).Count
        events = @()
    }
    exit 0
}
[void](Assert-AgentTrustedFile -Path $automatic.PolicyPath `
        -AllowedRoot (Join-Path $context.Root 'policies') -Private)
if ((Get-ApprovedOwnerV2FileSha256 $automatic.PolicyPath) -cne
    $automatic.PolicySha256) {
    throw 'Configured automatic Owner service policy file digest changed.'
}
$policy = Read-ApprovedOwnerV2SignedRecord `
    -Path $automatic.PolicyPath -Key $key
$provider = if ($null -ne $DeliveryProvider) {
    [scriptblock]$DeliveryProvider
}
else {
    New-ApprovedOwnerV2AzureDevOpsProvider `
        -ProviderConfigPath $ToolkitConfigPath `
        -AzureCliPath $AzureCliPath -GitPath $GitPath
}
$result = Invoke-AutomaticOwnerV2Comments -Evidence $evidence `
    -Policy $policy -DeliveryRoot $context.Root -Key $key `
    -Provider $provider -MaximumCreates $MaxCreatesPerRun
$result
exit (Get-AutomaticOwnerV2ExitCode -Health ([string]$result.health))
