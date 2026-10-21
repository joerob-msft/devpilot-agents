#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$LifecycleRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1') -Force
Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.PullRequestLifecycle\DevPilot.PullRequestLifecycle.psd1') `
    -Force
$config = Get-Content (Join-Path $RepoRoot `
        'samples\active-pr-intake.config.json') -Raw |
    ConvertFrom-Json -AsHashtable -Depth 64
$config.enabled = $true
$config.limits.pageSize = 50
$config.limits.maxPages = 10
$config.limits.maxPullRequests = 1000
$config.limits.maxHeadsPerRun = 4
$config.limits.maxReads = 30000
$config['subjectProvider'] = [ordered]@{
    maximumReads = 128
}
$rows = @(
    1..303 | ForEach-Object {
        [ordered]@{
            pullRequestId = $_
            status = 'active'
            isDraft = $false
            targetRef = 'refs/heads/master'
            creationUtc = $(if ($_ -eq 303) {
                    '2024-01-01T00:00:00Z'
                }
                else {
                    '2026-01-01T00:00:00Z'
                })
        }
    })
$activeProvider = {
    param($Operation, $Request)
    switch ($Operation) {
        Identity {
            return [ordered]@{} +
                $config.expectedAccount
        }
        ListPage {
            $items = @($rows |
                Select-Object -Skip ([int]$Request.skip) `
                    -First ([int]$Request.top))
            return @{
                items = $items
                count = $items.Count
                totalCount = $rows.Count
            }
        }
        Head {
            $id = [int]$Request.pullRequestId
            return @{
                pullRequestId = $id
                repositoryId = $config.repositoryId
                projectId = $config.projectId
                status = 'active'
                isDraft = $false
                sourceRef = "refs/heads/feature-$id"
                targetRef = 'refs/heads/master'
                sourceCommit = ('{0:x40}' -f $id)
                targetCommit = 'b' * 40
                iterationId = 1
            }
        }
        Changes {
            return @{
                changedFiles = 0
                changedLines = 0
            }
        }
        Discussions {
            return @{ threads = @(); count = 0 }
        }
        default {
            throw "unexpected-active:$Operation"
        }
    }
}.GetNewClosure()
$lifecycleContext =
    Initialize-StalePrLifecycleRoot `
        -DeliveryRoot $LifecycleRoot `
        -RepoRoot $RepoRoot
$key = Get-StalePrLifecycleKey `
    -LifecycleRoot $lifecycleContext.Root
$policy = New-StalePrLifecyclePolicy `
    -Config $config -RepoRoot $RepoRoot `
    -AllowDirty -MaxAbandonsPerRun 1
$fixtureWrites = [ref]0
$evidenceReads = [ref]0
$lifecycleProvider = {
    param($Operation, $Arguments)
    switch ($Operation) {
        Identity {
            return [ordered]@{} +
                $config.expectedAccount
        }
        ReadEvidence {
            $evidenceReads.Value++
            $id = [long]$Arguments.pullRequestId
            return [ordered]@{
                schemaVersion = 1
                projectId = [string]$config.projectId
                repositoryId = [string]$config.repositoryId
                pullRequestId = $id
                status = 'active'
                isDraft = $false
                sourceRef = "refs/heads/feature-$id"
                targetRef = 'refs/heads/master'
                sourceCommit = ('{0:x40}' -f $id)
                targetCommit = 'b' * 40
                iterationId = 1
                creationUtc = '2024-01-01T00:00:00Z'
                latestActivityUtc =
                    '2024-12-01T00:00:00Z'
                activityDigest =
                    'v1:sha256:' + ('c' * 64)
                complete = $true
            }
        }
        AbandonStatus {
            $fixtureWrites.Value++
            return @{ status = 'abandoned' }
        }
        ReadStatus {
            return @{
                pullRequestId =
                    [long]$Arguments.pullRequestId
                status = 'abandoned'
            }
        }
        default {
            throw "unexpected-lifecycle:$Operation"
        }
    }
}.GetNewClosure()
$capture = @{}
$lifecycleEvaluator = {
    param($Inventory)
    $capture.result = Invoke-StalePrLifecycle `
        -Inventory $Inventory `
        -CutoffUtc ([DateTime]::SpecifyKind(
            [DateTime]'2025-01-01T00:00:00',
            [DateTimeKind]::Utc)) `
        -Policy $policy `
        -LifecycleRoot $lifecycleContext.Root `
        -Key $key -Provider $lifecycleProvider
    return $capture.result
}.GetNewClosure()
try {
    $result = Invoke-ActivePrIntake `
        -Config $config -Provider $activeProvider `
        -StateRoot $StateRoot -RepositoryRoot $RepoRoot `
        -MaximumHeadsThisRun 4 `
        -LifecycleEvaluator $lifecycleEvaluator `
        -IncludeTransientSnapshots -Run
}
finally {
    [Array]::Clear($key, 0, $key.Length)
}
[ordered]@{
    schemaVersion = 1
    kind = 'native-lifecycle-active-pr-fresh-process'
    nativeResultType =
        $capture.result.GetType().FullName
    nativeNextCursorType =
        $capture.result.nextPullRequestId.
            GetType().FullName
    nativeNextPullRequestId =
        [long]$capture.result.nextPullRequestId
    nativeReviewEligibleCount =
        @($capture.result.reviewEligibleIds).Count
    nativeProviderWrites =
        [int]$capture.result.providerWrites
    nativeConfirmedAbandonedIds =
        @($capture.result.confirmedAbandonedIds)
    intakeLifecycleKind =
        [string]$result.lifecycle.kind
    intakeLifecycleDiagnostic = $(if (
        $result.lifecycle -is
            [Collections.IDictionary] -and
        $result.lifecycle.Contains(
            'diagnostic')) {
            $result.lifecycle.diagnostic
        }
        elseif ($null -ne
            $result.lifecycle.PSObject.
                Properties['diagnostic']) {
            $result.lifecycle.diagnostic
        }
        else { $null })
    intakeProviderWrites =
        [int]$result.lifecycle.providerWrites
    intakeConfirmedAbandonedIds =
        @($result.lifecycle.confirmedAbandonedIds)
    selectedPullRequestIds = @(
        $result.transientSnapshots.Keys |
            ForEach-Object { [int]$_ } |
            Sort-Object)
    fixtureStatusWrites = $fixtureWrites.Value
    fixtureEvidenceReads = $evidenceReads.Value
    externalWrites = 0
    modelWrites = 0
} | ConvertTo-Json -Depth 16
