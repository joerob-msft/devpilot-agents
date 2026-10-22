#!/usr/bin/env pwsh
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$AcquisitionPath,
    [string]$AzureCliPath = 'az',
    [ValidateRange(1, 4)][int]$MaximumHeadsThisRun = 4,
    [ValidateRange(1, 720)]
    [int]$MaximumSecondsThisRun = 720,
    [switch]$Run,
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1') -Force
Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.PullRequestLifecycle\DevPilot.PullRequestLifecycle.psd1') `
    -Force

$config = Get-Content -LiteralPath $ConfigPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 64
$provider = New-ActivePrAzureDevOpsProvider `
    -Config $config -AzureCliPath $AzureCliPath
$lifecycleConfig =
    Get-StalePrLifecycleConfiguration -Config $config
$lifecycleEvaluator = $null
$lifecycleKey = $null
if ($lifecycleConfig.Enabled) {
    $lifecycleContext =
        Initialize-StalePrLifecycleRoot `
            -DeliveryRoot $lifecycleConfig.DeliveryRoot `
            -RepoRoot $RepoRoot
    [void](Assert-AgentTrustedFile `
        -Path $lifecycleConfig.PolicyPath `
        -AllowedRoot (
            Join-Path $lifecycleContext.Root 'policies') `
        -Private)
    if ((Get-FileHash -LiteralPath `
                $lifecycleConfig.PolicyPath -Algorithm SHA256).
            Hash.ToLowerInvariant() -cne
            $lifecycleConfig.PolicySha256) {
        throw 'Stale PR lifecycle policy digest changed.'
    }
    $lifecycleKey =
        Get-StalePrLifecycleKey `
            -LifecycleRoot $lifecycleContext.Root
    $lifecyclePolicy =
        Read-StalePrLifecyclePolicy `
            -Path $lifecycleConfig.PolicyPath `
            -Key $lifecycleKey
    Assert-StalePrLifecyclePolicy `
        -Policy $lifecyclePolicy -Config $config `
        -RepoRoot $RepoRoot
    $lifecycleProvider =
        New-StalePrAzureDevOpsProvider `
            -Config $config -Policy $lifecyclePolicy -AzureCliPath $AzureCliPath
    $cutoffUtc = [DateTime]::UtcNow.AddYears(-1)
    $lifecycleEvaluator = {
        param([object[]]$Inventory)
        Invoke-StalePrLifecycle `
            -Inventory $Inventory `
            -CutoffUtc $cutoffUtc `
            -Policy $lifecyclePolicy `
            -LifecycleRoot $lifecycleContext.Root `
            -Key $lifecycleKey `
            -Provider $lifecycleProvider
    }.GetNewClosure()
}
try {
    $intake = Invoke-ActivePrIntake `
        -Config $config -Provider $provider `
        -StateRoot $StateRoot -RepositoryRoot $RepoRoot `
        -MaximumHeadsThisRun $MaximumHeadsThisRun `
        -MaximumSecondsThisRun $MaximumSecondsThisRun `
        -LifecycleEvaluator $lifecycleEvaluator `
        -IncludeTransientSnapshots -Run:$Run
}
finally {
    if ($null -ne $lifecycleKey) {
        [Array]::Clear(
            $lifecycleKey, 0, $lifecycleKey.Length)
    }
}

$directory = Resolve-AgentTrustedRoot `
    -Path (Split-Path -Parent $AcquisitionPath) `
    -Kind durable-state -RepositoryRoot $RepoRoot -Create
$requestedPath = [IO.Path]::GetFullPath($AcquisitionPath)
if (-not (Test-AgentPathWithin `
        -Path $requestedPath -Root $directory)) {
    throw 'Shared acquisition path is outside its private root.'
}
$path = Join-Path $directory (
    '{0}-{1}{2}' -f
    [IO.Path]::GetFileNameWithoutExtension($requestedPath),
    [string]$intake.generation,
    [IO.Path]::GetExtension($requestedPath))
if (-not (Test-AgentPathWithin -Path $path -Root $directory)) {
    throw 'Shared acquisition path is outside its private root.'
}
if (Test-Path -LiteralPath $path) {
    throw 'Shared acquisition generation already exists.'
}
$snapshot = [ordered]@{
    schemaVersion = 1
    kind = 'devpilot-shared-review-acquisition'
    createdUtc = [DateTime]::UtcNow.ToString('o')
    configDigest = [string]$intake.binding.configDigest
    generation = [string]$intake.generation
    intake = $intake
}
$json = ConvertTo-Json -InputObject $snapshot -Depth 100
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
if ($bytes.Length -gt 67108864) {
    throw 'Shared acquisition exceeded its 64 MiB bound.'
}
$temporary = Join-Path $directory (
    '.shared-acquisition-' + [guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllBytes($temporary, $bytes)
    [IO.File]::Move($temporary, $path)
}
finally {
    Remove-Item -LiteralPath $temporary `
        -Force -ErrorAction SilentlyContinue
}
[void](Assert-AgentTrustedFile `
        -Path $path -AllowedRoot $directory -Private)

$transientSnapshots = if ($intake.Contains(
        'transientSnapshots') -and
    $intake.transientSnapshots -is
        [Collections.IDictionary]) {
    $intake.transientSnapshots
}
else { [ordered]@{} }
$blobKeys = @($transientSnapshots.GetEnumerator() |
    ForEach-Object {
        $entry = $_
        @($entry.Value.changes.entries | ForEach-Object {
                '{0}/{1}/{2}/{3}/{4}/{5}' -f
                [string]$config.projectId,
                [string]$config.repositoryId,
                [string]$entry.Value.head.pullRequestId,
                [string]$entry.Value.head.sourceCommit,
                [string]$entry.Value.head.targetCommit,
                [string]$_.path
            })
    } | Sort-Object -Unique)
[ordered]@{
    schemaVersion = 1
    kind = 'devpilot-shared-review-acquisition-result'
    state = [string]$intake.state
    generation = [string]$intake.generation
    configDigest = [string]$intake.binding.configDigest
    acquisitionPath = $path
    acquisitionSha256 = (Get-FileHash `
            -LiteralPath $path -Algorithm SHA256).
        Hash.ToLowerInvariant()
    selectedPrCount = @($intake.heads | Where-Object {
            $_.declaration -is [Collections.IDictionary] -and
            [string]$_.reasonCode -ceq 'rules-incomplete'
        }).Count
    totalUniquePrSnapshotCount =
        @($transientSnapshots.Keys).Count
    uniqueContentBlobCount = $blobKeys.Count
    uniqueContentBlobKeys = $blobKeys
    providerReadCount = [int]$intake.readCount +
        [int]$intake.lifecycle.providerReadCount
    intakeProviderReadCount = [int]$intake.readCount
    providerWrites = [int]$intake.lifecycle.providerWrites
    lifecycleProviderWrites =
        [int]$intake.lifecycle.providerWrites
    lifecycleStatusWrites = [int]$intake.lifecycle.statusWrites
    lifecycleExplanationWrites = [int]$intake.lifecycle.explanationWrites
    lifecycleUnconfirmedStatusWrites =
        [int]$intake.lifecycle.unconfirmedStatusWrites
    lifecycleUnconfirmedExplanationWrites =
        [int]$intake.lifecycle.unconfirmedExplanationWrites
    lifecycleProviderReadCount = $intake.lifecycle.providerReadCount
    lifecycleExplanationReadCount = $intake.lifecycle.explanationReadCount
    lifecycleHealth = [string]$intake.lifecycle.health
    lifecycleConfirmedAbandonedIds =
        @($intake.lifecycle.confirmedAbandonedIds)
    lifecycleReviewEligibleIds =
        @($intake.lifecycle.reviewEligibleIds)
    lifecycleNextPullRequestId =
        $intake.lifecycle.nextPullRequestId
    lifecycleWithheldFromAutomaticComments =
        @($intake.heads | Where-Object {
                [string]$_.reasonCode -ceq
                    'lifecycle-activity-unverified'
            } | ForEach-Object {
                [long]$_.pullRequestId
            })
    modelWrites = 0
} | ConvertTo-Json -Depth 32
