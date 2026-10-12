#!/usr/bin/env pwsh
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ContextualToolkitRoot,
    [Parameter(Mandatory)][string]$ContextualConfigPath,
    [Parameter(Mandatory)][string]$ContextualStateRoot,
    [Parameter(Mandatory)][string]$ContextualManifestPath,
    [Parameter(Mandatory)][string]$AutomaticDeliveryRoot,
    [Parameter(Mandatory)][string]$SharedAcquisitionPath,
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$SharedAcquisitionSha256,
    [Parameter(Mandatory)][string]$AzureCliPath,
    [Parameter(Mandatory)][string]$GitPath,
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$ExpectedToolkitHead,
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$ExpectedToolkitTree
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
[Console]::OutputEncoding =
    [Text.UTF8Encoding]::new($false)

$head = (& $GitPath -C $ContextualToolkitRoot `
    rev-parse HEAD 2>$null).Trim()
$tree = (& $GitPath -C $ContextualToolkitRoot `
    show -s --format=%T HEAD 2>$null).Trim()
$status = @(& $GitPath -C $ContextualToolkitRoot `
    status --porcelain=v1 2>$null)
if ($LASTEXITCODE -ne 0 -or
    $head -cne $ExpectedToolkitHead -or
    $tree -cne $ExpectedToolkitTree -or
    @($status | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }).Count -ne 0) {
    throw 'contextual-phase-toolkit-mismatch'
}
foreach ($path in @(
        $ContextualConfigPath,
        $SharedAcquisitionPath,
        $AzureCliPath,
        $GitPath
    )) {
    if (-not [IO.Path]::IsPathFullyQualified(
            $path) -or
        -not (Test-Path -LiteralPath $path `
            -PathType Leaf)) {
        throw 'contextual-phase-required-file-missing'
    }
}
if ((Get-FileHash -LiteralPath `
        $SharedAcquisitionPath `
        -Algorithm SHA256).Hash.
        ToLowerInvariant() -cne
        $SharedAcquisitionSha256) {
    throw 'contextual-phase-shared-acquisition-mismatch'
}

$currentPrTool = Join-Path $ContextualToolkitRoot `
    'tools\Invoke-ContextualConventionsCurrentPr.ps1'
$deliveryTool = Join-Path $ContextualToolkitRoot `
    'tools\Invoke-AutomaticOwnerV2Delivery.ps1'
$policyPath = Join-Path $ContextualToolkitRoot `
    'src\DevPilot.OwnerCapability\Policy\contextual-conventions.v1.json'
foreach ($path in @(
        $currentPrTool,
        $deliveryTool,
        $policyPath
    )) {
    if (-not (Test-Path -LiteralPath $path `
            -PathType Leaf)) {
        throw 'contextual-phase-tool-missing'
    }
}
$allowedRuleIds = @(
    (Get-Content -LiteralPath $policyPath -Raw |
        ConvertFrom-Json -AsHashtable `
            -Depth 32).rules.id)
if ($allowedRuleIds.Count -ne 17 -or
    @($allowedRuleIds |
        Sort-Object -Unique).Count -ne 17) {
    throw 'contextual-phase-rule-allowset-invalid'
}

$evaluationConfig = Get-Content `
    -LiteralPath $ContextualConfigPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 64
if ($evaluationConfig.
    autoCreateContextualConventionComments `
        -isnot [bool] -or
    [bool]$evaluationConfig.
        autoCreateContextualConventionComments) {
    throw 'contextual-phase-evaluation-creation-not-false'
}
$deliveryConfigPath = Join-Path (
    Split-Path -Parent $ContextualConfigPath
) 'contextual-conventions-delivery.config.json'
$deliveryConfig = Get-Content `
    -LiteralPath $deliveryConfigPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 64
$automatic = $deliveryConfig.
    autoCreateContextualConventionComments
if ($automatic -isnot
        [Collections.IDictionary] -or
    $automatic.enabled -isnot [bool] -or
    -not [bool]$automatic.enabled -or
    [string]$automatic.policyPath -eq '' -or
    [string]$automatic.policySha256 -cnotmatch
        '^[0-9a-f]{64}$') {
    throw 'contextual-phase-delivery-policy-invalid'
}

$evaluationOutput = @(
    & $currentPrTool `
        -ConfigPath $ContextualConfigPath `
        -StateRoot $ContextualStateRoot `
        -ManifestPath $ContextualManifestPath `
        -AcquisitionPath $SharedAcquisitionPath `
        -AcquisitionSha256 `
            $SharedAcquisitionSha256 `
        -AzureCliPath $AzureCliPath `
        -MaximumHeadsThisRun 4 `
        -RepoRoot $ContextualToolkitRoot -Run)
$evaluationSucceeded = $?
$evaluation = ($evaluationOutput -join "`n") |
    ConvertFrom-Json -AsHashtable -Depth 64
if (-not $evaluationSucceeded -or
    [string]$evaluation.state -cnotin @(
        'completed',
        'partial',
        'known-empty',
        'disabled') -or
    [int]$evaluation.providerWrites -ne 0 -or
    [int]$evaluation.modelWrites -ne 0 -or
    @($evaluation.records).Count -gt 4) {
    throw 'contextual-phase-evaluation-unsafe'
}

$completed = @(
    $evaluation.records | Where-Object {
        [string]$_.state -ceq 'completed'
    })
$identities =
    [Collections.Generic.List[string]]::new()
$observations =
    [Collections.Generic.List[object]]::new()
foreach ($record in $completed) {
    $identity = [string]$record.identity
    $matches = @(
        Get-ChildItem -LiteralPath `
            $ContextualStateRoot -Recurse -File `
            -Filter "$identity.json" |
            Where-Object {
                $_.Directory.Name -ceq
                    'observations'
            })
    if ($matches.Count -ne 1) {
        throw 'contextual-phase-observation-missing'
    }
    $observation = Get-Content `
        -LiteralPath $matches[0].FullName -Raw |
        ConvertFrom-Json -AsHashtable -Depth 64
    if ([string]$observation.lifecycle.status -cne
            'completed' -or
        -not [bool]$observation.findingsComplete -or
        [int]$observation.counts.unknown -ne 0 -or
        @($observation.validationErrors).Count -ne 0 -or
        [int]$observation.effects.providerWrites -ne 0 -or
        [int]$observation.execution.modelStarts -ne 0 -or
        @($observation.findings |
            Where-Object {
                [string]$_.ruleId -cnotin
                    $allowedRuleIds
            }).Count -ne 0) {
        throw 'contextual-phase-observation-unsafe'
    }
    [void]$identities.Add($identity)
    [void]$observations.Add([ordered]@{
            identity = $identity
            findingCount =
                @($observation.findings).Count
            wouldCreate = @(
                $observation.findings |
                    Where-Object {
                        [string]$_.reconciliation.
                            classification -ceq
                            'wouldCreate'
                    }).Count
        })
}

$delivery = [ordered]@{
    schemaVersion = 1
    kind =
        'contextual-conventions-v1-automatic-delivery-batch-result'
    health = 'healthy'
    providerWrites = 0
    modelWrites = 0
    remainingCreates = 2
    remainingWouldCreate = 0
    results = @()
    deferred = @()
    events = @()
}
if ($identities.Count -gt 0) {
    $deliveryOutput = @(
        & $deliveryTool invoke-batch `
            -Delivery contextual-conventions `
            -DeliveryRoot $AutomaticDeliveryRoot `
            -StateRoot $ContextualStateRoot `
            -Identity $identities.ToArray() `
            -ToolkitConfigPath $deliveryConfigPath `
            -MaxCreatesPerRun 2 `
            -MaxCreatesPerPullRequest 5 `
            -AzureCliPath $AzureCliPath `
            -GitPath $GitPath `
            -RepoRoot $ContextualToolkitRoot)
    $delivery = ($deliveryOutput -join "`n") |
        ConvertFrom-Json -AsHashtable -Depth 64
}
if ([int]$delivery.providerWrites -lt 0 -or
    [int]$delivery.providerWrites -gt 2 -or
    [int]$delivery.modelWrites -ne 0 -or
    [string]$delivery.health -cnotin @(
        'healthy', 'partial', 'refused',
        'disabled')) {
    throw 'contextual-phase-delivery-unsafe'
}

[pscustomobject][ordered]@{
    schemaVersion = 1
    kind =
        'contextual-conventions-scheduled-phase-result'
    toolkit = [ordered]@{
        head = $head
        tree = $tree
    }
    evaluation = $evaluation
    observations = $observations.ToArray()
    delivery = $delivery
    evaluationEffects = [ordered]@{
        providerWrites =
            [int]$evaluation.providerWrites
        modelWrites =
            [int]$evaluation.modelWrites
    }
    deliveryEffects = [ordered]@{
        providerWrites =
            [int]$delivery.providerWrites
        modelWrites =
            [int]$delivery.modelWrites
    }
} | ConvertTo-Json -Depth 64
