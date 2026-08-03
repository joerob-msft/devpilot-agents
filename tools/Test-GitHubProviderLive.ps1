#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Exercises the GitHub provider against the live GitHub API.

.DESCRIPTION
    Deliberately NOT part of the offline self-check suite. Every provider bug
    this project has hit was hidden by a mock that encoded the assumed
    contract, so normalization is proven here against real responses and
    pinned in the offline suite by fixtures captured from these same calls.

    Read-only. Casting a vote is a separate, explicit act and is not done here.

.EXAMPLE
    ./tools/Test-GitHubProviderLive.ps1 -Owner joerob-msft -Repository devpilot-agents -PullRequestId 11
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Owner,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][int]$PullRequestId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force

$failures = New-Object System.Collections.Generic.List[string]
function Assert-True {
    param([bool]$Condition, [string]$What)
    if ($Condition) { Write-Host "  OK   - $What" -ForegroundColor Green }
    else { Write-Host "  FAIL - $What" -ForegroundColor Red; [void]$failures.Add($What) }
}

Write-Host "Live GitHub provider check: $Owner/$Repository PR #$PullRequestId" -ForegroundColor Cyan

$context = New-AgentProviderContext -Provider 'GitHub' -Organization $Owner -RepositoryName $Repository
Assert-True ($context.Slug -eq "$Owner/$Repository") "context resolves the repository slug"

Write-Host "`n[1] Pull-request snapshot" -ForegroundColor Cyan
$snapshot = Get-AgentProviderPullRequestSnapshot -Context $context -PullRequestId $PullRequestId
Assert-True ($snapshot.prId -eq $PullRequestId) "prId matches the requested pull request"
Assert-True ($snapshot.sourceCommitId -match '^[0-9a-f]{40}$') "sourceCommitId is a lowercase 40-char SHA"
Assert-True ($snapshot.targetRefName -like 'refs/heads/*') "targetRefName is fully qualified"
Assert-True (@('Active', 'Completed', 'Abandoned') -contains $snapshot.status) "status is in the shared vocabulary ($($snapshot.status))"
Assert-True ($snapshot.authorAlias -and $snapshot.authorAlias.Length -gt 0) "authorAlias populated ($($snapshot.authorAlias))"
Assert-True ($null -eq $snapshot.authorUniqueName) "authorUniqueName is null rather than synthesized"
Assert-True ($snapshot.isDraft -is [bool]) "isDraft is a real boolean"
foreach ($reviewer in @($snapshot.reviewers)) {
    Assert-True (@(10, 5, 0, -5, -10) -contains $reviewer.vote) "reviewer '$($reviewer.id)' vote normalized to the ADO scale ($($reviewer.vote))"
}
Write-Host "    title: $($snapshot.title)"

Write-Host "`n[2] Active pull-request ids" -ForegroundColor Cyan
$ids = Get-AgentProviderActivePullRequestIds -Context $context
Assert-True ($ids -contains $PullRequestId -or $snapshot.status -ne 'Active') "an open pull request appears in the candidate list"
Write-Host "    open, non-draft: $($ids -join ', ')"

Write-Host "`n[3] Commit date" -ForegroundColor Cyan
$commitDate = Get-AgentProviderCommitDateUtc -Context $context -CommitId $snapshot.sourceCommitId
Assert-True ($commitDate -is [DateTime]) "commit date parses to a DateTime"
Assert-True ($commitDate.Kind -eq [DateTimeKind]::Utc) "commit date is UTC, not local"
Assert-True ($commitDate -lt (Get-Date).ToUniversalTime().AddMinutes(10)) "commit date is not implausibly in the future"
Write-Host "    committed: $($commitDate.ToString('u'))"

Write-Host "`n[4] Review threads (GraphQL - REST cannot express resolution)" -ForegroundColor Cyan
$threads = Get-AgentProviderPullRequestThreads -Context $context -PullRequestId $PullRequestId
Assert-True ($null -ne $threads) "threads call returned a collection"
foreach ($thread in @($threads)) {
    Assert-True (@('Active', 'Fixed', 'Closed') -contains $thread.status) "thread status normalized ($($thread.status))"
    Assert-True ($thread.commentCount -ge 1) "thread carries at least one comment"
}
Write-Host "    threads: $(@($threads).Count) ($(@($threads | Where-Object { $_.status -eq 'Active' }).Count) active)"

Write-Host "`n[5] Validation run for the head commit" -ForegroundColor Cyan
$run = Get-AgentProviderValidationRun -Context $context -HeadSha $snapshot.sourceCommitId
Assert-True (@('None', 'InProgress', 'Succeeded', 'Failed') -contains $run.state) "validation state normalized ($($run.state))"
Assert-True ($run.isSuccess -eq ($run.state -eq 'Succeeded')) "isSuccess agrees with state"
Assert-True (-not $run.isSuccess -or $run.isComplete) "a successful run is necessarily complete"
Write-Host "    checks: $(@($run.runs).Count) -> $($run.state)"

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "FAILED - $($failures.Count) live assertion(s):" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "All live GitHub provider assertions passed." -ForegroundColor Green
exit 0
