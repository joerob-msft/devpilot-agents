#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Offline self-checks for the provider layer.

.DESCRIPTION
    No network, no GitHub, no Azure DevOps. Normalization is asserted against a
    fixture captured from a real API response, because every provider bug this
    project has hit was hidden by a mock that encoded the assumed contract
    rather than the observed one.

    The live counterpart is tools/Test-GitHubProviderLive.ps1, which proves the
    fixture still matches reality.

.EXAMPLE
    ./tools/Test-Provider.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force

$failures = New-Object System.Collections.Generic.List[string]
$checkNumber = 0
function Start-Check {
    param([string]$Title)
    $script:checkNumber++
    Write-Host "[PROVIDER] Self-check $($script:checkNumber): $Title" -ForegroundColor Cyan
}
function Assert-True {
    param([bool]$Condition, [string]$What)
    if ($Condition) { Write-Host "  OK - $What" -ForegroundColor Green }
    else { Write-Host "  FAIL - $What" -ForegroundColor Red; [void]$failures.Add($What) }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$What)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $What
}

# ---------------------------------------------------------------------------
Start-Check "provider registry and fail-closed selection"
$supported = Get-AgentSupportedProvider
Assert-True ($supported -contains 'AzureDevOps' -and $supported -contains 'GitHub') "both providers are advertised"
Assert-True (Test-AgentProviderSupported -Provider 'GitHub') "GitHub is recognized"
Assert-True (-not (Test-AgentProviderSupported -Provider 'github')) "recognition is case-sensitive, so a near-miss in checked-in config is corrected rather than accepted"
Assert-True (-not (Test-AgentProviderSupported -Provider 'Gitea')) "an unknown provider is rejected"
Assert-Throws { New-AgentProviderContext -Provider 'Gitea' -Organization 'o' -RepositoryName 'r' } "an unknown provider cannot produce a context"

# ---------------------------------------------------------------------------
Start-Check "context validation per provider"
$gh = New-AgentProviderContext -Provider 'GitHub' -Organization 'contoso' -RepositoryName 'widget-service'
Assert-True ($gh.Slug -eq 'contoso/widget-service') "GitHub scope collapses to owner/repo"
Assert-Throws { New-AgentProviderContext -Provider 'GitHub' -Organization 'bad owner!' -RepositoryName 'r' } "an invalid GitHub owner is rejected"
Assert-Throws { New-AgentProviderContext -Provider 'GitHub' -Organization 'contoso' -RepositoryName 'bad/name' } "a repository name containing a path separator is rejected"
# Azure DevOps needs a project AND a transport; this layer never reimplements it.
Assert-Throws { New-AgentProviderContext -Provider 'AzureDevOps' -Organization 'o' -RepositoryName 'r' -McpInvoker { } } "AzureDevOps without a project is rejected"
Assert-Throws { New-AgentProviderContext -Provider 'AzureDevOps' -Organization 'o' -Project 'p' -RepositoryName 'r' } "AzureDevOps without an MCP invoker is rejected"
$ado = New-AgentProviderContext -Provider 'AzureDevOps' -Organization 'o' -Project 'p' -RepositoryName 'r' -McpInvoker { }
Assert-True ($ado.Provider -eq 'AzureDevOps') "a complete AzureDevOps context is accepted"

# ---------------------------------------------------------------------------
Start-Check "status normalization distinguishes merged from abandoned"
Assert-True ((ConvertTo-AgentProviderPullRequestStatus -Provider 'GitHub' -State 'open') -eq 'Active') "open maps to Active"
Assert-True ((ConvertTo-AgentProviderPullRequestStatus -Provider 'GitHub' -State 'closed' -IsMerged $true) -eq 'Completed') "closed+merged maps to Completed"
Assert-True ((ConvertTo-AgentProviderPullRequestStatus -Provider 'GitHub' -State 'closed' -IsMerged $false) -eq 'Abandoned') "closed+unmerged maps to Abandoned"
Assert-True ((ConvertTo-AgentProviderPullRequestStatus -Provider 'AzureDevOps' -State 'Active') -eq 'Active') "AzureDevOps statuses pass through unchanged"
Assert-Throws { ConvertTo-AgentProviderPullRequestStatus -Provider 'GitHub' -State 'weird' } "an unrecognized state fails closed"

# ---------------------------------------------------------------------------
Start-Check "vote normalization never invents approval"
Assert-True ((ConvertTo-AgentProviderVote -Provider 'GitHub' -State 'APPROVED') -eq 10) "APPROVED is 10"
Assert-True ((ConvertTo-AgentProviderVote -Provider 'GitHub' -State 'CHANGES_REQUESTED') -eq -10) "CHANGES_REQUESTED is -10"
Assert-True ((ConvertTo-AgentProviderVote -Provider 'GitHub' -State 'COMMENTED') -eq 0) "COMMENTED is 0, not approval"
Assert-True ((ConvertTo-AgentProviderVote -Provider 'GitHub' -State 'DISMISSED') -eq 0) "DISMISSED is 0, not approval"
Assert-Throws { ConvertTo-AgentProviderVote -Provider 'GitHub' -State 'LGTM' } "an unrecognized review state fails closed"

# ---------------------------------------------------------------------------
Start-Check "snapshot normalization against a fixture captured from a real response"
$fixturePath = Join-Path $PSScriptRoot '..\src\DevPilot.AgentHarness\testdata\github-pull-request-fixture.json'
Assert-True (Test-Path $fixturePath) "fixture is present"
$fixture = Get-Content $fixturePath -Raw | ConvertFrom-Json
$snapshot = ConvertTo-AgentProviderSnapshot -PullRequest $fixture.pullRequest -Reviews $fixture.reviews `
    -ExpectedOwner 'contoso' -ExpectedRepository 'widget-service'

Assert-True ($snapshot.status -eq $fixture.expected.status) "status matches expected ($($snapshot.status))"
Assert-True ($snapshot.targetRefName -eq $fixture.expected.targetRefName) "target ref is fully qualified"
Assert-True ($snapshot.sourceCommitId -eq $fixture.expected.sourceCommitId) "head SHA is lowercased"
Assert-True ($snapshot.authorAlias -eq $fixture.expected.authorAlias) "author alias extracted"
Assert-True ($null -eq $snapshot.authorUniqueName) "author identity is left null rather than synthesized from a login"

# The load-bearing assertion: a reviewer who requested changes and later
# approved must read as approved, or an agent would refuse to complete work
# that a human can see is signed off.
$byId = @{}
foreach ($r in @($snapshot.reviewers)) { $byId[$r.id] = $r.vote }
foreach ($name in $fixture.expected.reviewerVotes.PSObject.Properties.Name) {
    $want = [int]$fixture.expected.reviewerVotes.$name
    Assert-True ($byId.ContainsKey($name) -and $byId[$name] -eq $want) "reviewer '$name' resolves to the latest review ($want)"
}
foreach ($excluded in @($fixture.expected.excludedReviewers)) {
    Assert-True (-not $byId.ContainsKey($excluded)) "a PENDING review from '$excluded' is not counted"
}
Assert-True (@($snapshot.reviewers).Count -eq $fixture.expected.reviewerVotes.PSObject.Properties.Name.Count) "one entry per reviewer, not one per review"

# ---------------------------------------------------------------------------
Start-Check "snapshot validation rejects malformed payloads"
$bad = ($fixture.pullRequest | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
$bad.head.sha = 'nothex'
Assert-Throws { ConvertTo-AgentProviderSnapshot -PullRequest $bad -Reviews @() -ExpectedOwner 'o' -ExpectedRepository 'r' } "a non-SHA head commit is rejected"
$bad2 = ($fixture.pullRequest | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
$bad2.number = -1
Assert-Throws { ConvertTo-AgentProviderSnapshot -PullRequest $bad2 -Reviews @() -ExpectedOwner 'o' -ExpectedRepository 'r' } "a non-positive pull-request number is rejected"
$bad3 = ($fixture.pullRequest | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
$bad3.PSObject.Properties.Remove('head')
Assert-Throws { ConvertTo-AgentProviderSnapshot -PullRequest $bad3 -Reviews @() -ExpectedOwner 'o' -ExpectedRepository 'r' } "a missing required field is rejected"

# ---------------------------------------------------------------------------
Start-Check "thread status normalization keeps outdated-but-unanswered threads Active"
Assert-True ((ConvertTo-AgentProviderThreadStatus -IsResolved $true) -eq 'Closed') "a resolved thread is Closed"
Assert-True ((ConvertTo-AgentProviderThreadStatus -IsResolved $false) -eq 'Active') "an unresolved thread is Active"
Assert-True ((ConvertTo-AgentProviderThreadStatus -IsResolved $false -IsOutdated $true) -eq 'Active') "an outdated but unresolved thread stays Active: the code moved, the question was never answered"

# ---------------------------------------------------------------------------
Start-Check "API path guarding"
Assert-Throws { Invoke-AgentGitHubApi -Path 'https://evil.example/repos/x/y' } "an absolute URL cannot be passed off as an API path"
Assert-Throws { Invoke-AgentGitHubApi -Path '//evil.example/x' } "a protocol-relative URL is rejected"

# ---------------------------------------------------------------------------
Start-Check "operations refuse a context from the wrong provider"
Assert-Throws { Get-AgentProviderActivePullRequestIds -Context $ado } "a GitHub-only operation rejects an AzureDevOps context"
Assert-Throws { Get-AgentProviderValidationRun -Context $ado -HeadSha ('a' * 40) } "validation lookup rejects an AzureDevOps context"
Assert-Throws { Get-AgentProviderPullRequestSnapshot -Context $gh -PullRequestId 0 } "a non-positive pull-request id is rejected before any call"
Assert-Throws { Get-AgentProviderValidationRun -Context $gh -HeadSha 'short' } "a malformed head SHA is rejected before any call"

# ---------------------------------------------------------------------------
Start-Check "vote requests are bounded and require a body when demanding changes"
Assert-Throws { Set-AgentProviderPullRequestVote -Context $gh -PullRequestId 1 -Vote 'Merge' } "an out-of-set vote cannot be requested"
Assert-Throws { Set-AgentProviderPullRequestVote -Context $gh -PullRequestId 1 -Vote 'WaitingForAuthor' -Body '' } "requesting changes without a body is rejected before any call"

# ---------------------------------------------------------------------------
Start-Check "structured GitHub API result guards a path the same as the throwing variant"
Assert-Throws { Invoke-AgentGitHubApiResult -Path 'https://evil.example/repos/x/y' } "an absolute URL cannot be passed off as a structured-result API path"
Assert-Throws { Invoke-AgentGitHubApiResult -Path '//evil.example/x' } "a protocol-relative URL is rejected from the structured-result path"

# ---------------------------------------------------------------------------
Start-Check "review-dismissal policy normalization distinguishes known from unknown"
Assert-Throws { Get-AgentProviderReviewDismissalPolicy -Context $ado -TargetBranch 'main' } "dismissal-policy lookup rejects an AzureDevOps context"
Assert-Throws { Get-AgentProviderReviewDismissalPolicy -Context $gh -TargetBranch '' } "an empty target branch is rejected before any call"

$dismissalFixturePath = Join-Path $PSScriptRoot '..\src\DevPilot.AgentHarness\testdata\github-branch-protection-fixture.json'
Assert-True (Test-Path $dismissalFixturePath) "branch-protection fixture is present"
$dismissalFixture = Get-Content $dismissalFixturePath -Raw | ConvertFrom-Json
foreach ($caseName in @('protectedDismissesStale', 'protectedKeepsStale', 'protectedNoReviewRequirement')) {
    $case = $dismissalFixture.$caseName
    $apiResult = @{ Ok = $true; StatusCode = 200; Value = $case.response; Error = $null }
    $policy = ConvertTo-AgentProviderReviewDismissalPolicy -ApiResult $apiResult
    Assert-True ($policy.known -eq $case.expected.known) "$caseName - known matches fixture"
    Assert-True ($policy.dismissesStaleReviews -eq $case.expected.dismissesStaleReviews) "$caseName - dismissesStaleReviews matches fixture ($($policy.dismissesStaleReviews))"
    Assert-True ($policy.source -eq $case.expected.source) "$caseName - source matches fixture ($($policy.source))"
}
# A 404 is a DEFINITIVE "no rule", not an unknown - the whole point of the
# structured result over Invoke-AgentGitHubApi's collapsed exception.
$notFound = ConvertTo-AgentProviderReviewDismissalPolicy -ApiResult @{ Ok = $false; StatusCode = 404; Value = $null; Error = 'Not Found' }
Assert-True ($notFound.known -eq $true -and $notFound.dismissesStaleReviews -eq $false -and $notFound.source -eq 'none') "a 404 on branch protection is a KNOWN, definite 'no rule' rather than unknown"
# A 403 is genuinely unknown and must not be read as a plausible default.
$forbidden = ConvertTo-AgentProviderReviewDismissalPolicy -ApiResult @{ Ok = $false; StatusCode = 403; Value = $null; Error = 'Forbidden' }
Assert-True ($forbidden.known -eq $false -and $forbidden.dismissesStaleReviews -eq $false -and $forbidden.source -eq 'unknown') "a 403 on branch protection is unknown, distinct from a 404"
$serverError = ConvertTo-AgentProviderReviewDismissalPolicy -ApiResult @{ Ok = $false; StatusCode = 500; Value = $null; Error = 'boom' }
Assert-True ($serverError.known -eq $false -and $serverError.source -eq 'unknown') "any other failure is unknown, never a plausible-looking default"

# ---------------------------------------------------------------------------
Start-Check "required-checks snapshot normalization against a fixture, and unknown-vs-clean"
Assert-Throws { Get-AgentProviderRequiredChecksSnapshot -Context $ado -HeadSha ('a' * 40) } "required-checks lookup rejects an AzureDevOps context"

$checksFixturePath = Join-Path $PSScriptRoot '..\src\DevPilot.AgentHarness\testdata\github-check-runs-fixture.json'
Assert-True (Test-Path $checksFixturePath) "check-runs fixture is present"
$checksFixture = Get-Content $checksFixturePath -Raw | ConvertFrom-Json
foreach ($caseName in @('allGreen', 'oneFailed', 'inProgress', 'neutralIsNotSuccess', 'none')) {
    $case = $checksFixture.$caseName
    $validationRun = ConvertTo-AgentProviderCheckRunsSnapshot -Payload $case.response -HeadSha ('a' * 40)
    Assert-True ($validationRun.found -eq $case.expected.found) "$caseName - found matches fixture"
    Assert-True ($validationRun.state -eq $case.expected.state) "$caseName - state matches fixture ($($validationRun.state))"
    Assert-True ($validationRun.isComplete -eq $case.expected.isComplete) "$caseName - isComplete matches fixture"
    Assert-True ($validationRun.isSuccess -eq $case.expected.isSuccess) "$caseName - isSuccess matches fixture"
}
# 'none' (zero check runs) must be UNKNOWN territory for the required-checks
# gate, never "nothing required, so this passes".
$noneRun = ConvertTo-AgentProviderCheckRunsSnapshot -Payload $checksFixture.none.response -HeadSha ('a' * 40)
$noneSnapshot = ConvertTo-AgentProviderRequiredChecksSnapshot -ValidationRun $noneRun -RequiredNames @()
Assert-True ($noneSnapshot.known -eq $false) "zero check runs is unknown, not a clean pass, even with no required names configured"
$greenRun = ConvertTo-AgentProviderCheckRunsSnapshot -Payload $checksFixture.allGreen.response -HeadSha ('a' * 40)
$greenSnapshot = ConvertTo-AgentProviderRequiredChecksSnapshot -ValidationRun $greenRun -RequiredNames @('ci/build', 'ci/test')
Assert-True ($greenSnapshot.known -and $greenSnapshot.allComplete -and $greenSnapshot.allSuccess -and @($greenSnapshot.missingRequired).Count -eq 0) "every explicitly required check present and green is reported complete/successful"
$missingNameSnapshot = ConvertTo-AgentProviderRequiredChecksSnapshot -ValidationRun $greenRun -RequiredNames @('ci/build', 'ci/deploy')
Assert-True (@($missingNameSnapshot.missingRequired) -contains 'ci/deploy' -and -not $missingNameSnapshot.allComplete) "a required check name that never ran is reported missing, not silently passed"
Assert-True ($greenSnapshot.sha256 -match '^[0-9a-f]{64}$') "the checks snapshot binds a deterministic sha256"
$greenSnapshotAgain = ConvertTo-AgentProviderRequiredChecksSnapshot -ValidationRun $greenRun -RequiredNames @('ci/build', 'ci/test')
Assert-True ($greenSnapshotAgain.sha256 -ceq $greenSnapshot.sha256) "the checks snapshot sha256 is deterministic across repeated calls"

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "FAILED - $($failures.Count) provider self-check failure(s):" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "All $checkNumber provider self-checks passed." -ForegroundColor Green
exit 0
