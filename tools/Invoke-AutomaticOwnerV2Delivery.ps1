#!/usr/bin/env pwsh
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet(
        'initialize-key', 'authorize-policy', 'invoke', 'invoke-batch')]
    [string]$Command,

    [Parameter(Mandatory)][string]$DeliveryRoot,
    [string]$StateRoot,
    [ValidatePattern('^$|^[0-9a-f]{64}$')][string[]]$Identity,
    [string]$ToolkitConfigPath,
    [string]$PolicyPath,
    [ValidateSet('owner', 'named-areequal', 'contextual-conventions')]
    [string]$Delivery = 'owner',
    [ValidatePattern('^[a-z0-9][a-z0-9_.-]{2,63}$')]
    [string]$PolicyId = '',
    [ValidateRange(1, 5)][int]$MaxCreatesPerRun = 5,
    [ValidateRange(1, 50)][int]$MaxCreatesPerPullRequest = 25,
    [ValidatePattern('^$|^v1:sha256:[0-9a-f]{64}$')]
    [string]$PreviousRuleHash = '',
    [long]$PreviousRuleLength = 0,
    [string[]]$UnchangedRuleId = @(),
    [ValidatePattern('^$|^v1:sha256:[0-9a-f]{64}$')]
    [string]$AdditionalPreviousRuleHash = '',
    [long]$AdditionalPreviousRuleLength = 0,
    [string[]]$AdditionalUnchangedRuleId = @(),
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

if ($Delivery -cin @(
        'named-areequal',
        'contextual-conventions')) {
    if (-not $PSBoundParameters.ContainsKey('MaxCreatesPerRun')) {
        $MaxCreatesPerRun = 2
    }
    if (-not $PSBoundParameters.ContainsKey('MaxCreatesPerPullRequest')) {
        $MaxCreatesPerPullRequest = 5
    }
    if ($MaxCreatesPerRun -gt 2 -or
        $MaxCreatesPerPullRequest -gt 5) {
        throw 'Deterministic rule policy limits cannot exceed 2 creates per run or 5 per pull request.'
    }
}

$identities = @($Identity | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
if ($Command -ceq 'invoke' -and $identities.Count -ne 1) {
    throw 'invoke requires exactly one state identity.'
}
if ($Command -ceq 'invoke-batch' -and (
        $Delivery -cnotin @(
            'named-areequal',
            'contextual-conventions') -or
        $identities.Count -lt 1 -or
        $identities.Count -gt 4 -or
        @($identities | Sort-Object -Unique).Count -ne
            $identities.Count)) {
    throw 'invoke-batch requires one to four unique deterministic rule identities.'
}

$toolkitConfig = $null
if ($Command -cin @('invoke', 'invoke-batch') -and
    $Delivery -cin @(
        'named-areequal',
        'contextual-conventions')) {
    if ([string]::IsNullOrWhiteSpace($StateRoot) -or
        [string]::IsNullOrWhiteSpace($ToolkitConfigPath) -or
        -not [IO.Path]::IsPathFullyQualified($StateRoot) -or
        -not [IO.Path]::IsPathFullyQualified($ToolkitConfigPath)) {
        throw 'invoke requires absolute state/config paths and an exact state identity.'
    }
    $toolkitConfig = Read-ApprovedOwnerV2Json -Path $ToolkitConfigPath
    $configured = Get-AutomaticOwnerV2Configuration `
        -ToolkitConfig $toolkitConfig -Delivery $Delivery
    if (-not $configured.Enabled) {
        $disabledResults = @($identities | ForEach-Object {
                $disabledEvidence = Read-ApprovedOwnerV2Evidence `
                    -StateRoot $StateRoot -Identity $_ `
                    -RepoRoot $RepoRoot `
                    -ToolkitConfigPath $ToolkitConfigPath `
                    -Delivery $Delivery
                [ordered]@{
                    identity = $_
                    result = [ordered]@{
                        schemaVersion = 1
                        kind =
                            $(if ($Delivery -ceq
                                'contextual-conventions') {
                                'contextual-conventions-v1-automatic-delivery-result'
                            } else {
                                'named-areequal-v2-automatic-delivery-result'
                            })
                        health = 'disabled'
                        providerWrites = 0
                        modelWrites = 0
                        remainingWouldCreate = @(
                            $disabledEvidence.Observation.findings |
                            Where-Object {
                                [string]$_.reconciliation.
                                    classification -ceq 'wouldCreate'
                            }).Count
                        events = @()
                    }
                }
            })
        if ($Command -ceq 'invoke') {
            [pscustomobject]$disabledResults[0].result
        }
        else {
            [pscustomobject][ordered]@{
                schemaVersion = 1
                kind =
                    $(if ($Delivery -ceq
                        'contextual-conventions') {
                        'contextual-conventions-v1-automatic-delivery-batch-result'
                    } else {
                        'named-areequal-v2-automatic-delivery-batch-result'
                    })
                batchRunId = 'disabled'
                health = 'disabled'
                providerWrites = 0
                modelWrites = 0
                remainingCreates = $MaxCreatesPerRun
                remainingWouldCreate = @($disabledResults |
                    ForEach-Object {
                        [int]$_.result.remainingWouldCreate
                    } | Measure-Object -Sum).Sum
                results = $disabledResults
                deferred = @()
                events = @()
            }
        }
        exit 0
    }
}

$context = Initialize-AutomaticOwnerV2DeliveryRoot `
    -DeliveryRoot $DeliveryRoot -RepoRoot $RepoRoot -Delivery $Delivery
if (-not $PolicyId) {
    $PolicyId = if ($Delivery -ceq 'named-areequal') {
        'named-areequal-v1-production'
    } elseif ($Delivery -ceq 'contextual-conventions') {
        'contextual-conventions-v1-production'
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
    [string]::IsNullOrWhiteSpace($ToolkitConfigPath) -or
    -not [IO.Path]::IsPathFullyQualified($StateRoot) -or
    -not [IO.Path]::IsPathFullyQualified($ToolkitConfigPath)) {
    throw "$Command requires absolute state/config paths and an exact state identity."
}
$evidenceList = @($identities | ForEach-Object {
        Read-ApprovedOwnerV2Evidence -StateRoot $StateRoot `
            -Identity $_ -RepoRoot $RepoRoot `
            -ToolkitConfigPath $ToolkitConfigPath -Delivery $Delivery
    })
$evidence = if ($evidenceList.Count -gt 0) {
    $evidenceList[0]
}
else { $null }
$key = Get-AutomaticOwnerV2ServiceKey `
    -DeliveryRoot $context.Root -Delivery $Delivery

if ($Command -ceq 'authorize-policy') {
    if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
        $PolicyPath = Join-Path $context.Root "policies\$PolicyId.json"
    }
    if (-not [IO.Path]::IsPathFullyQualified($PolicyPath) -or
        -not (Test-AgentPathWithin -Path $PolicyPath `
            -Root (Join-Path $context.Root 'policies'))) {
        throw 'PolicyPath must be absolute and inside the private policies root.'
    }
    $compatibilitySpecified =
        -not [string]::IsNullOrWhiteSpace(
            $PreviousRuleHash) -or
        $PreviousRuleLength -ne 0 -or
        $UnchangedRuleId.Count -ne 0
    $additionalCompatibilitySpecified =
        -not [string]::IsNullOrWhiteSpace(
            $AdditionalPreviousRuleHash) -or
        $AdditionalPreviousRuleLength -ne 0 -or
        $AdditionalUnchangedRuleId.Count -ne 0
    if ($compatibilitySpecified -and (
            $Delivery -cne
                'contextual-conventions' -or
            [string]::IsNullOrWhiteSpace(
                $PreviousRuleHash) -or
            $PreviousRuleLength -lt 1 -or
            $UnchangedRuleId.Count -lt 1)) {
        throw 'Additive rule history compatibility requires one exact prior contextual rule and unchanged rule IDs.'
    }
    if ($additionalCompatibilitySpecified -and (
            -not $compatibilitySpecified -or
            [string]::IsNullOrWhiteSpace(
                $AdditionalPreviousRuleHash) -or
            $AdditionalPreviousRuleLength -lt 1 -or
            $AdditionalUnchangedRuleId.Count -lt 1)) {
        throw 'Additional additive history compatibility requires a second exact prior contextual rule and unchanged rule IDs.'
    }
    $policyArguments = @{
        Evidence = $evidence
        PolicyId = $PolicyId
        MaxCreatesPerRun = $MaxCreatesPerRun
        MaxCreatesPerPullRequest =
            $MaxCreatesPerPullRequest
    }
    if ($compatibilitySpecified) {
        $currentRule = [ordered]@{
            hash =
                [string]$evidence.
                    Declaration.rule.hash
            length =
                [long]$evidence.
                    Declaration.rule.length
        }
        $policyArguments.HistoryCompatibility = if (
            $additionalCompatibilitySpecified) {
            [ordered]@{
                schemaVersion = 2
                kind =
                    'contextual-additive-rule-history-compatibility'
                previousRules = @(
                    [ordered]@{
                        rule = [ordered]@{
                            hash =
                                $PreviousRuleHash
                            length =
                                $PreviousRuleLength
                        }
                        unchangedRuleIds =
                            @($UnchangedRuleId)
                    },
                    [ordered]@{
                        rule = [ordered]@{
                            hash =
                                $AdditionalPreviousRuleHash
                            length =
                                $AdditionalPreviousRuleLength
                        }
                        unchangedRuleIds =
                            @($AdditionalUnchangedRuleId)
                    })
                currentRule = $currentRule
            }
        }
        else {
            [ordered]@{
                schemaVersion = 1
                kind =
                    'contextual-additive-rule-history-compatibility'
                previousRule = [ordered]@{
                    hash = $PreviousRuleHash
                    length = $PreviousRuleLength
                }
                currentRule = $currentRule
                unchangedRuleIds =
                    @($UnchangedRuleId)
            }
        }
    }
    $policy =
        New-AutomaticOwnerV2ServicePolicy `
            @policyArguments
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

if ($null -eq $toolkitConfig) {
    $toolkitConfig = Read-ApprovedOwnerV2Json -Path $ToolkitConfigPath
}
$automatic = Get-AutomaticOwnerV2Configuration `
    -ToolkitConfig $toolkitConfig -Delivery $Delivery
if (-not $automatic.Enabled) {
    [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = $(if ($Delivery -ceq 'named-areequal') {
                'named-areequal-v2-automatic-delivery-result'
            } elseif ($Delivery -ceq
                'contextual-conventions') {
                'contextual-conventions-v1-automatic-delivery-result'
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
$result = if ($Command -ceq 'invoke-batch') {
    if ($Delivery -ceq 'contextual-conventions') {
        Invoke-AutomaticContextualConventionsBatch `
            -Evidence $evidenceList -Policy $policy `
            -DeliveryRoot $context.Root -Key $key `
            -Provider $provider `
            -MaximumCreates $MaxCreatesPerRun
    }
    else {
        Invoke-AutomaticNamedAreEqualBatch `
            -Evidence $evidenceList -Policy $policy `
            -DeliveryRoot $context.Root -Key $key `
            -Provider $provider `
            -MaximumCreates $MaxCreatesPerRun
    }
}
else {
    Invoke-AutomaticOwnerV2Comments -Evidence $evidence `
        -Policy $policy -DeliveryRoot $context.Root -Key $key `
        -Provider $provider -MaximumCreates $MaxCreatesPerRun
}
$result
exit (Get-AutomaticOwnerV2ExitCode -Health ([string]$result.health))
