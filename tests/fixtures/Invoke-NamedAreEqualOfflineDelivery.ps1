#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$Identity,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$DeliveryRoot,
    [Parameter(Mandatory)][string]$PolicyPath,
    [Parameter(Mandatory)][string]$ProviderStatePath,
    [ValidateRange(0, 5)][int]$MaximumCreates = 2,
    [switch]$Unconfirmed,
    [switch]$SkipObservationRefresh,
    [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $RepoRoot `
    'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
Import-Module (Join-Path $RepoRoot `
    'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') -Force
Import-Module (Join-Path $RepoRoot `
    'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1') -Force
. (Join-Path $RepoRoot `
    'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')
. (Join-Path $RepoRoot `
    'src\Agents\reviewer\AutomaticOwnerV2Comments.ps1')

$evidence = Read-AutomaticNamedAreEqualEvidence `
    -StateRoot $StateRoot -Identity $Identity `
    -ToolkitConfigPath $ConfigPath -RepoRoot $RepoRoot
$key = Get-AutomaticOwnerV2ServiceKey `
    -DeliveryRoot $DeliveryRoot -Delivery named-areequal
$policy = Read-ApprovedOwnerV2SignedRecord `
    -Path $PolicyPath -Key $key

if (Test-Path -LiteralPath $ProviderStatePath -PathType Leaf) {
    $providerState = Get-Content -LiteralPath $ProviderStatePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 32
}
else {
    $snapshot = Get-ApprovedOwnerV2SourceArtifact `
        -Observation $evidence.Observation `
        -Kind 'owner-v2-discussion-snapshot'
    $providerState = [ordered]@{
        writes = 0
        nextThreadId = 100
        digest = $snapshot
        iterationId = 3
        threads = @()
    }
}

function Write-ProviderState {
    $directory = Split-Path -Parent $ProviderStatePath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = Join-Path $directory (
        '.provider-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText(
            $temporary,
            (ConvertTo-Json -InputObject $providerState -Depth 32) + "`n",
            [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $ProviderStatePath -PathType Leaf) {
            $backup = Join-Path $directory (
                '.provider-backup-' + [guid]::NewGuid().ToString('N'))
            [IO.File]::Replace(
                $temporary, $ProviderStatePath, $backup, $true)
            Remove-Item -LiteralPath $backup -Force
        }
        else {
            [IO.File]::Move($temporary, $ProviderStatePath)
        }
    }
    finally {
        Remove-Item -LiteralPath $temporary `
            -Force -ErrorAction SilentlyContinue
    }
}

$provider = {
    param([string]$Action, [hashtable]$Arguments)
    if ($Action -ceq 'ReadCurrent') {
        $threads = @($providerState.threads | ForEach-Object {
            $thread = $_ | ConvertTo-Json -Depth 16 -Compress |
                ConvertFrom-Json -AsHashtable -Depth 16
            if ([string]$thread.sourceCommit -cne
                [string]$evidence.Declaration.head.sourceCommit) {
                $thread.isOutdated = $true
                $thread.contextState = 'outdated'
            }
            $thread
        })
        if ($Unconfirmed -and [int]$providerState.writes -gt 0) {
            $threads = @()
        }
        $snapshot = [DevPilot.OwnerAdapters.OwnerDiscussionSnapshot]::new(
            'complete',
            'unknown',
            1,
            $threads.Count,
            @($threads | ForEach-Object { @($_.comments).Count } |
                Measure-Object -Sum).Sum,
            0,
            "v1:sha256:$([string]$providerState.digest)",
            [string[]]@('v1:sha256:' + ('f' * 64)),
            [object[]]$threads)
        $snapshot | Add-Member -NotePropertyName RawProvenanceDigests `
            -NotePropertyValue ([string[]]@('v1:sha256:' + ('c' * 64)))
        $snapshot | Add-Member -NotePropertyName MappingDigest `
            -NotePropertyValue ('v1:sha256:' + ('a' * 64))
        $snapshot | Add-Member -NotePropertyName ReviewerIdentityDigest `
            -NotePropertyValue ('v1:sha256:' + ('b' * 64))
        $snapshot | Add-Member -NotePropertyName CurrentIterationId `
            -NotePropertyValue ([int]$providerState.iterationId)
        return [pscustomobject]@{
            ProviderBinding = $evidence.Provider
            PullRequest = [ordered]@{
                pullRequestId =
                    [long]$evidence.Declaration.subject.pullRequestId
                status = 'active'
                isDraft = $false
                repositoryId =
                    [string]$evidence.Declaration.subject.repositoryId
                projectId =
                    [string]$evidence.Declaration.subject.projectId
                sourceCommit =
                    [string]$evidence.Declaration.head.sourceCommit
                targetCommit =
                    [string]$evidence.Declaration.target.targetCommit
                targetRef =
                    [string]$evidence.Declaration.target.targetRef
            }
            Reviewer = [ordered]@{
                id = [string]$evidence.Provider.reviewerIdentity.id
                descriptor =
                    [string]$evidence.Provider.reviewerIdentity.descriptor
                uniqueName =
                    [string]$evidence.Provider.reviewerIdentity.uniqueName
            }
            Snapshot = $snapshot
            Anchors = @($Arguments.selections | ForEach-Object {
                foreach ($line in @($_.affectedCallLines)) {
                    [ordered]@{
                        path = [string]$_.path
                        startLine = [int]$line
                        endLine = [int]$line
                        changeTrackingId = 7
                        iterationId = [int]$providerState.iterationId
                    }
                }
            })
        }
    }
    if ($Action -ceq 'CreateThread') {
        $selection = $Arguments.selection
        $threadId = [long]$providerState.nextThreadId
        $providerState.nextThreadId = $threadId + 1
        $providerState.writes = [int]$providerState.writes + 1
        $providerState.threads = @($providerState.threads) + @(
            [ordered]@{
                threadId = $threadId
                status = 'active'
                isDeleted = $false
                isOutdated = $false
                sourceCommit =
                    [string]$evidence.Declaration.head.sourceCommit
                contextState = 'current'
                anchor = [ordered]@{
                    path = [string]$selection.path
                    line = [int]$selection.line
                }
                comments = @([ordered]@{
                    commentId = $threadId + 1000
                    commentType = 'text'
                    isDeleted = $false
                    reviewerOwned = $true
                    reviewerIdentityState = 'matched'
                    body = [string]$selection.body
                    bodyDigest =
                        Get-ApprovedOwnerV2Digest $selection.body
                })
            })
        $providerState.digest = (
            Get-ApprovedOwnerV2Digest @(
                $providerState.threads.comments.body)).Substring(10)
        Write-ProviderState
        return [ordered]@{ id = $threadId }
    }
    throw "Unexpected provider action '$Action'."
}.GetNewClosure()

if (-not $SkipObservationRefresh) {
    $live = & $provider 'ReadCurrent' @{
        evidence = $evidence
        selections = @($evidence.Observation.findings | ForEach-Object {
            [ordered]@{
                path = [string]$_.anchor.path
                line = [int]$_.anchor.line
                affectedCallLines = @($_.affectedCallLines)
            }
        })
    }
    $refreshed = Resolve-OwnerV2DiscussionReconciliation `
        -Observation $evidence.Observation `
        -Contract $evidence.Contract -Snapshot $live.Snapshot
    $evidence.Observation = $refreshed
    $evidence.Record.resultDigest =
        Get-ApprovedOwnerV2Digest $refreshed
    [IO.File]::WriteAllText(
        $evidence.Paths.observation,
        (ConvertTo-ApprovedOwnerV2CanonicalJson $refreshed) + "`n",
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $evidence.Paths.record,
        (ConvertTo-ApprovedOwnerV2CanonicalJson $evidence.Record) + "`n",
        [Text.UTF8Encoding]::new($false))
}

$result = Invoke-AutomaticOwnerV2Comments `
    -Evidence $evidence -Policy $policy `
    -DeliveryRoot $DeliveryRoot -Key $key `
    -Provider $provider -MaximumCreates $MaximumCreates
Write-ProviderState
$result | ConvertTo-Json -Depth 32
exit (Get-AutomaticOwnerV2ExitCode -Health ([string]$result.health))
