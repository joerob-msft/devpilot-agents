#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Publishes explicitly selected method-level Owner findings after human approval.

.DESCRIPTION
    Dry-run is the default. This command never discovers or posts all findings:
    the operator must supply one to five exact construct/finding ID pairs from a
    signed completed Owner preview and must separately opt into -Publish.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$HeadKey,
    [Parameter(Mandatory)][ValidateCount(1, 5)][string[]]$ConstructId,
    [Parameter(Mandatory)][ValidateCount(1, 5)][string[]]$FindingId,
    [Parameter(Mandatory)][switch]$Approve,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$')][string]$OperatorAlias,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason,
    [switch]$Publish,
    [switch]$DryRun,
    [switch]$ApproveUpdate,
    [string]$AgencyPath = 'agency',
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $Approve.IsPresent) { throw '-Approve is required.' }
if ($Publish -and $DryRun) { throw '-Publish and -DryRun are mutually exclusive.' }

Import-Module (Join-Path $RepoRoot 'src/DevPilot.AgentHarness/DevPilot.AgentHarness.psd1') -Force
. (Join-Path $RepoRoot 'src/Agents/reviewer/CorpusSeal.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/ConventionSpecialist.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/AcquisitionPackage.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/SourceTransport.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewSubject.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewReport.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewQueue.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/ApprovedOwnerComments.ps1')

$evidence = Read-ApprovedOwnerEvidence -StateRoot $StateRoot -HeadKey $HeadKey -RepoRoot $RepoRoot
$subject = $evidence.Subject.subject
$session = Open-AgentMcpSession -AgencyPath $AgencyPath -Server 'ado' `
    -Organization ([string]$subject.organization) -Toolsets @('repos') -TimeoutSeconds 120 `
    -EnvironmentVariablesToRemove @('GITHUB_TOKEN', 'GH_TOKEN', 'AZURE_DEVOPS_EXT_PAT')
$invokeTool = ${function:Invoke-AgentMcpTool}
$newChangeRequest = ${function:New-ReviewerChangeListRequest}
$getThreadPageSize = ${function:Get-ApprovedOwnerThreadPageSize}
$project = [string]$subject.project
$repositoryId = [string]$subject.repositoryId
$provider = {
    param([string]$Action, [hashtable]$Arguments)
    $common = @{ project = $project; repositoryId = $repositoryId }
    foreach ($key in $Arguments.Keys) { $common[$key] = $Arguments[$key] }
    switch ($Action) {
        'GetPullRequest' {
            $common.action = 'get'
            return & $invokeTool -Session $session -Name 'repo_pull_request' -Arguments $common
        }
        'GetBranch' {
            $common.action = 'get'
            $common.branchName = ([string]$common.refName) -replace '^refs/heads/', ''
            $common.Remove('refName')
            return & $invokeTool -Session $session -Name 'repo_branch' -Arguments $common
        }
        'GetChanges' {
            $request = & $newChangeRequest -Project $project -RepositoryName $repositoryId `
                -PullRequestId ([int]$common.pullRequestId) -IncludeDiffs
            return & $invokeTool -Session $session -Name $request.Name -Arguments ([hashtable]$request.Arguments)
        }
        'ListThreads' {
            $common.action = 'list'; $common.top = & $getThreadPageSize
            return @(& $invokeTool -Session $session -Name 'repo_pull_request_thread' -Arguments $common)
        }
        'CreateThread' {
            $common.action = 'create'; $common.status = 'Active'
            $common.rightFileStartLine = [int]$common.line; $common.rightFileStartOffset = 1
            $common.rightFileEndLine = [int]$common.line; $common.rightFileEndOffset = 1
            $common.Remove('line')
            return & $invokeTool -Session $session -Name 'repo_pull_request_thread_write' -RawText -Arguments $common
        }
        'UpdateStatus' {
            $common.action = 'update_status'
            return & $invokeTool -Session $session -Name 'repo_pull_request_thread_write' -RawText -Arguments $common
        }
        default { throw "Unknown approved Owner provider action '$Action'." }
    }
}.GetNewClosure()

try {
    $result = Invoke-ApprovedOwnerComment -Evidence $evidence -ConstructId $ConstructId -FindingId $FindingId `
        -Provider $provider -Reason $Reason -OperatorAlias $OperatorAlias -Publish:$Publish -ApproveUpdate:$ApproveUpdate
    Write-Output (ConvertTo-Json -InputObject $result -Depth 12 -Compress)
}
finally {
    if ($session) { Close-AgentMcpSession -Session $session }
}
