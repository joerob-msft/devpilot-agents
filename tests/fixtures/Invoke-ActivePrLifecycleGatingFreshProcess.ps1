#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$StateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1') -Force
$config = Get-Content (Join-Path $RepoRoot `
        'samples\active-pr-intake.config.json') -Raw |
    ConvertFrom-Json -AsHashtable -Depth 64
$config.enabled = $true
$config.limits.maxHeadsPerRun = 2
$rows = @(
    1..4 | ForEach-Object {
        [ordered]@{
            pullRequestId = $_
            status = 'active'
            isDraft = $false
            targetRef = 'refs/heads/master'
            creationUtc = '2024-01-01T00:00:00Z'
        }
    })
$provider = {
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
            throw "unexpected:$Operation"
        }
    }
}.GetNewClosure()
$capture = @{ order = @() }
$lifecycle = {
    param($Inventory)
    $capture.order = @($Inventory | ForEach-Object {
            [int]$_.pullRequestId
        })
    return [ordered]@{
        schemaVersion = 1
        kind = 'stale-pr-lifecycle-v1-run'
        runId = [guid]::NewGuid().ToString('N')
        cutoffUtc = '2025-10-21T00:00:00.0000000Z'
        health = 'healthy'
        providerWrites = 0
        modelWrites = 0
        confirmedAbandonedIds = @()
        reviewEligibleIds = @($capture.order)
        nextPullRequestId = $(if (
            $capture.order[0] -eq 1) { 3 } else { 1 })
        decisions = @()
        events = @()
    }
}.GetNewClosure()
$result = Invoke-ActivePrIntake `
    -Config $config -Provider $provider `
    -StateRoot $StateRoot -RepositoryRoot $RepoRoot `
    -LifecycleEvaluator $lifecycle `
    -IncludeTransientSnapshots -Run
[ordered]@{
    schemaVersion = 1
    kind = 'active-pr-lifecycle-gating-fresh-process'
    lifecycleOrder = @($capture.order)
    lifecycleNextPullRequestId =
        $result.lifecycle.nextPullRequestId
    acquisitionNextPullRequestId =
        $result.cursor.nextPullRequestId
    selectedPullRequestIds = @(
        $result.transientSnapshots.Keys |
            ForEach-Object { [int]$_ } |
            Sort-Object)
    withheldPullRequestIds = @(
        $result.heads | Where-Object {
            [string]$_.reasonCode -ceq
                'lifecycle-activity-unverified'
        } | ForEach-Object {
            [int]$_.pullRequestId
        })
    providerWrites =
        [int]$result.lifecycle.providerWrites
    modelWrites =
        [int]$result.lifecycle.modelWrites
} | ConvertTo-Json -Depth 16
