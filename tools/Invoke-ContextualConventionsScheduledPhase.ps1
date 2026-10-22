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

function Get-ContextualScheduledObservationDisposition {
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Observation,
        [Parameter(Mandatory)][string[]]$AllowedRuleIds
    )

    $unexpectedValidationErrors = @(
        $Observation.validationErrors |
            Where-Object {
                [string]$_ -cnotmatch
                    '^file-evidence-unknown: '
            })
    if ([string]$Observation.lifecycle.status -cne
            'completed' -or
        $unexpectedValidationErrors.Count -ne 0 -or
        [int]$Observation.effects.providerWrites -ne 0 -or
        [int]$Observation.execution.modelStarts -ne 0 -or
        @($Observation.findings |
            Where-Object {
                [string]$_.ruleId -cnotin
                    $AllowedRuleIds
            }).Count -ne 0) {
        throw 'contextual-phase-observation-unsafe'
    }
    $semanticUnknown = [int]$Observation.counts.unknown
    $reconciliationUnknown =
        [int]$Observation.effects.dedupe.unknown
    $actionablePartial =
        Test-ApprovedContextualActionablePartial `
            -Observation $Observation
    if (-not [bool]$Observation.findingsComplete -or
        $semanticUnknown -gt 0 -or
        $reconciliationUnknown -gt 0) {
        if ($actionablePartial) {
            return [ordered]@{
                deliverable = $true
                reason =
                    'actionable-with-isolated-discussion-unknown'
                semanticUnknown = 0
                reconciliationUnknown =
                    $reconciliationUnknown
            }
        }
        return [ordered]@{
            deliverable = $false
            reason = $(if ($reconciliationUnknown -gt 0) {
                    'discussion-reconciliation-unknown'
                }
                elseif ($semanticUnknown -gt 0) {
                    'semantic-or-evidence-unknown'
                }
                else {
                    'findings-incomplete'
                })
            semanticUnknown = $semanticUnknown
            reconciliationUnknown =
                $reconciliationUnknown
        }
    }
    return [ordered]@{
        deliverable = $true
        reason = 'complete'
        semanticUnknown = 0
        reconciliationUnknown = 0
    }
}

$head = (& $GitPath --no-optional-locks `
    -c core.longpaths=true `
    -C $ContextualToolkitRoot `
    rev-parse HEAD 2>$null).Trim()
$tree = (& $GitPath --no-optional-locks `
    -c core.longpaths=true `
    -C $ContextualToolkitRoot `
    show -s --format=%T HEAD 2>$null).Trim()
$status = @(& $GitPath --no-optional-locks `
    -c core.longpaths=true `
    -C $ContextualToolkitRoot `
    status --porcelain=v1 2>$null)
if ($LASTEXITCODE -ne 0 -or
    $head -cne $ExpectedToolkitHead -or
    $tree -cne $ExpectedToolkitTree -or
    @($status | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }).Count -ne 0) {
    throw 'contextual-phase-toolkit-mismatch'
}
$agentHarnessModule = Join-Path `
    $ContextualToolkitRoot `
    'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'
$approvedCommentsTool = Join-Path $ContextualToolkitRoot `
    'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1'
if (-not (Test-Path -LiteralPath $agentHarnessModule `
        -PathType Leaf) -or
    -not (Test-Path -LiteralPath $approvedCommentsTool `
        -PathType Leaf)) {
    throw 'contextual-phase-approved-comments-missing'
}
Import-Module $agentHarnessModule -Force
. $approvedCommentsTool
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
$deliveryProducer = Join-Path `
    $ContextualToolkitRoot `
    'tools\Invoke-ContextualDeliveryBatchJson.ps1'
$policyPath = Join-Path $ContextualToolkitRoot `
    'src\DevPilot.OwnerCapability\Policy\contextual-conventions.v1.json'
foreach ($path in @(
        $currentPrTool,
        $deliveryTool,
        $deliveryProducer,
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
if ($allowedRuleIds.Count -ne 27 -or
    @($allowedRuleIds |
        Sort-Object -Unique).Count -ne 27) {
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
$deliveryEnabled = $false
if ($automatic -is [bool]) {
    if ([bool]$automatic) {
        throw 'contextual-phase-delivery-policy-missing'
    }
}
elseif ($automatic -is
        [Collections.IDictionary] -and
    $automatic.enabled -is [bool] -and
    [bool]$automatic.enabled -and
    [string]$automatic.policyPath -ne '' -and
    [string]$automatic.policySha256 -cmatch
        '^[0-9a-f]{64}$') {
    $deliveryEnabled = $true
}
else {
    throw 'contextual-phase-delivery-policy-invalid'
}

$contextualDeliveryRoot =
    Join-Path $AutomaticDeliveryRoot `
        'contextual-conventions-v1'
$historyKeyPath =
    Join-Path $contextualDeliveryRoot `
        'keys\contextual-conventions-service-authorization.hmac'
if (-not (Test-Path -LiteralPath $historyKeyPath `
        -PathType Leaf)) {
    throw 'contextual-phase-history-key-missing'
}
$historyKey = [IO.File]::ReadAllBytes(
    $historyKeyPath)
try {
    if ($historyKey.Length -ne 32) {
        throw 'contextual-phase-history-key-invalid'
    }
    $ruleCompatibility = $null
    if ($deliveryEnabled) {
        [void](Assert-AgentTrustedFile `
                -Path ([string]$automatic.policyPath) `
                -AllowedRoot (
                    Join-Path $contextualDeliveryRoot `
                        'policies') `
                -Private)
        if ((Get-ApprovedOwnerV2FileSha256 `
                    ([string]$automatic.policyPath)) -cne
                [string]$automatic.policySha256) {
            throw 'contextual-phase-delivery-policy-digest-changed'
        }
        $servicePolicy =
            Read-ApprovedOwnerV2SignedRecord `
                -Path (
                    [string]$automatic.policyPath) `
                -Key $historyKey
        if ([string]$servicePolicy.kind -cne
                'contextual-conventions-v1-service-authorization-policy' -or
            -not [bool]$servicePolicy.enabled -or
            [string]$servicePolicy.capability.id -cne
                [string]$evaluationConfig.capability.id -or
            [string]$servicePolicy.rule.path -cne
                [string]$evaluationConfig.contextualRule.path -or
            [string]$servicePolicy.rule.section -cne
                [string]$evaluationConfig.contextualRule.section -or
            [string]$servicePolicy.rule.hash -cne
                [string]$evaluationConfig.contextualRule.hash -or
            [long]$servicePolicy.rule.length -ne
                [long]$evaluationConfig.contextualRule.length) {
            throw 'contextual-phase-delivery-policy-binding-invalid'
        }
        if ($servicePolicy.Contains(
                'historyCompatibility')) {
            $ruleCompatibility =
                Assert-ApprovedOwnerV2RuleCompatibility `
                    -Compatibility (
                        $servicePolicy.
                            historyCompatibility) `
                    -CurrentRule (
                        $evaluationConfig.
                            contextualRule) `
                    -AllowedRuleIds $allowedRuleIds
        }
    }
    $authenticatedPriorComments =
        @(Get-ApprovedOwnerV2AuthenticatedPriorComments `
            -DeliveryRoot $contextualDeliveryRoot `
            -Key $historyKey `
            -Delivery contextual-conventions `
            -RuleCompatibility $ruleCompatibility)
}
finally {
    if ($null -ne $historyKey) {
        [Array]::Clear(
            $historyKey, 0, $historyKey.Length)
    }
}
$historyRoot = Join-Path $ContextualStateRoot `
    'authenticated-history'
[IO.Directory]::CreateDirectory($historyRoot) |
    Out-Null
$historyPath = Join-Path $historyRoot `
    'contextual-prior-comments.json'
$historyPayload = [ordered]@{
    schemaVersion = 1
    kind =
        'owner-v2-authenticated-prior-comment-history'
    comments = $authenticatedPriorComments
}
$historyJson =
    ConvertTo-ApprovedOwnerV2CanonicalJson `
        $historyPayload
$historyTempPath =
    "$historyPath.$([guid]::NewGuid().ToString('N')).tmp"
[IO.File]::WriteAllText(
    $historyTempPath,
    $historyJson,
    [Text.UTF8Encoding]::new($false))
[IO.File]::Move(
    $historyTempPath, $historyPath, $true)
$historySha256 =
    (Get-FileHash -LiteralPath $historyPath `
        -Algorithm SHA256).Hash.
        ToLowerInvariant()

$evaluationOutput = @(
    & $currentPrTool `
        -ConfigPath $ContextualConfigPath `
        -StateRoot $ContextualStateRoot `
        -ManifestPath $ContextualManifestPath `
        -AcquisitionPath $SharedAcquisitionPath `
        -AcquisitionSha256 `
            $SharedAcquisitionSha256 `
        -AuthenticatedHistoryPath $historyPath `
        -AuthenticatedHistorySha256 `
            $historySha256 `
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
$withheldObservations =
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
    $disposition =
        Get-ContextualScheduledObservationDisposition `
            -Observation $observation `
            -AllowedRuleIds $allowedRuleIds
    if (-not [bool]$disposition.deliverable) {
        [void]$withheldObservations.Add([ordered]@{
                identity = $identity
                pullRequestId =
                    [long]$observation.subject.pullRequestId
                reason = [string]$disposition.reason
                semanticUnknown =
                    [int]$disposition.semanticUnknown
                reconciliationUnknown =
                    [int]$disposition.reconciliationUnknown
                findingCount =
                    @($observation.findings).Count
            })
        continue
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

$deliveryEnvelope = $null
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
if (-not $deliveryEnabled) {
    $delivery.health = 'disabled'
}
if ($identities.Count -gt 0) {
    if ($deliveryEnabled) {
        $deliveryOutput = @(
            & $deliveryProducer `
                -AutomaticDeliveryTool $deliveryTool `
                -DeliveryRoot $AutomaticDeliveryRoot `
                -StateRoot $ContextualStateRoot `
                -Identity $identities.ToArray() `
                -ToolkitConfigPath $deliveryConfigPath `
                -AzureCliPath $AzureCliPath `
                -GitPath $GitPath `
                -RepoRoot $ContextualToolkitRoot)
        $producerExit = $LASTEXITCODE
        $deliveryEnvelope =
            ($deliveryOutput -join "`n") |
            ConvertFrom-Json -AsHashtable `
                -Depth 64
        if ($producerExit -ne 0 -or
            [string]$deliveryEnvelope.kind -cne
                'contextual-conventions-delivery-producer-result' -or
            [int]$deliveryEnvelope.toolExitCode -notin @(
                0, 2, 3) -or
            $deliveryEnvelope.result -isnot
                [Collections.IDictionary]) {
            throw 'contextual-phase-delivery-producer-unsafe'
        }
        $delivery = $deliveryEnvelope.result
    }
    else {
        $delivery.remainingWouldCreate = @(
            $observations | ForEach-Object {
                [int]$_.wouldCreate
            } | Measure-Object -Sum).Sum
    }
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
    withheldObservations =
        $withheldObservations.ToArray()
    withheldCount = $withheldObservations.Count
    withheldHeadCount = $(if ($evaluation.Contains('withheldHeadCount')) {
            [int]$evaluation.withheldHeadCount
        }
        else { 0 })
    coverage = [ordered]@{
        selectedHeadCount = $(if ($evaluation.Contains('selectedCount')) {
                [int]$evaluation.selectedCount
            }
            else {
                @($evaluation.records).Count
            })
        completedHeadCount = $(if ($evaluation.Contains('completedCount')) {
                [int]$evaluation.completedCount
            }
            else {
                $completed.Count
            })
        incompleteHeadCount = $(if ($evaluation.Contains('incompleteCount')) {
                [int]$evaluation.incompleteCount
            }
            else { 0 })
        withheldHeadCount = $(if ($evaluation.Contains('withheldHeadCount')) {
                [int]$evaluation.withheldHeadCount
            }
            else { 0 })
        withheldObservationCount = $withheldObservations.Count
    }
    delivery = $delivery
    deliveryEnvelope = $deliveryEnvelope
    deliveryEnabled = $deliveryEnabled
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
