#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$RepoRoot,
    [ValidateSet('empty', 'human', 'drift')]
    [string]$DiscussionMode = 'empty',
    [ValidateRange(1, 4)][int]$HeadCount = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $RepoRoot `
    'src\DevPilot.NamedAreEqualBridge\DevPilot.NamedAreEqualBridge.psd1') `
    -Force

$config = Get-Content -LiteralPath $ConfigPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 32
$content = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
[TestClass]
class Checks {
    [TestMethod]
    void Verify() {
        Assert.AreEqual(1, items.Count);
    }
}
'@
$targetCommit = 'd' * 40
$getSourceCommit = {
    param([int]$PullRequestId)
    return $PullRequestId.ToString('x8') + ('c' * 32)
}
$textDigest = {
    param([string]$Value)
    'v1:sha256:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($Value))).
        ToLowerInvariant()
}
$contentDigest = & $textDigest $content
$spanDigest = & $textDigest 'span'
$calls = [Collections.Generic.List[string]]::new()
$provider = {
    param($Operation, $Request)
    [void]$calls.Add([string]$Operation)
    switch ($Operation) {
        'Identity' {
            return [ordered]@{} + $config.expectedAccount
        }
        'ListPage' {
            if ([int]$Request.skip -eq 0) {
                return @{
                    items = @(for ($offset = 0;
                            $offset -lt $HeadCount; $offset++) {
                        [ordered]@{
                            pullRequestId = 42 + $offset
                            status = 'active'
                            isDraft = $false
                            targetRef = 'refs/heads/master'
                        }
                    })
                    count = $HeadCount
                }
            }
            return @{ items = @(); count = 0 }
        }
        'Head' {
            $pullRequestId = [int]$Request.pullRequestId
            $live = [ordered]@{
                repositoryId = [string]$config.repositoryId
                projectId = [string]$config.projectId
                pullRequestId = $pullRequestId
                sourceRef = "refs/heads/feature-$pullRequestId"
                targetRef = 'refs/heads/master'
                sourceCommit =
                    & $getSourceCommit $pullRequestId
                targetCommit = $targetCommit
                iterationId = 3
                status = 'active'
                isDraft = $false
            }
            if ($DiscussionMode -ceq 'drift' -and
                @($calls | Where-Object { $_ -ceq 'Head' }).Count -gt 2) {
                $live.sourceCommit = 'e' * 40
            }
            return $live
        }
        'Changes' {
            return @{
                changedFiles = 1
                changedLines = 1
                entries = @([ordered]@{
                        changeTrackingId = 7
                        path = 'tests/Checks.cs'
                        changeType = 'edit'
                        state = 'complete'
                        spans = @([ordered]@{
                                startLine = 6
                                endLine = 6
                                state = 'complete'
                                sourceDigest = $spanDigest
                            })
                        content = $content
                        byteLength =
                            [Text.Encoding]::UTF8.GetByteCount($content)
                        sourceDigest = $contentDigest
                        derivation = [ordered]@{
                            schemaVersion = 1
                            kind =
                                'devpilot-current-line-derivation-v1'
                            producer =
                                'active-pr-intake-v1'
                            state = 'complete'
                            classification =
                                'current-lines'
                            changeType = 'modified'
                            pathRelation = 'same-path'
                            sourceCommit =
                                [string]$Request.sourceCommit
                            targetCommit = $targetCommit
                            sourceContentState =
                                'available'
                            targetContentState =
                                'available'
                            sourceContentSha256 =
                                $contentDigest
                            targetContentSha256 =
                                & $textDigest 'target'
                            sourceByteLength =
                                [Text.Encoding]::UTF8.
                                    GetByteCount($content)
                            targetByteLength = 6
                            spanCount = 1
                            currentLineCount = 1
                        }
                    })
            }
        }
        'Discussions' {
            if ($DiscussionMode -ceq 'human') {
                return @{
                    threads = @([ordered]@{
                            id = 9
                            status = 'active'
                            isDeleted = $false
                            threadContext = [ordered]@{
                                filePath = '/tests/Checks.cs'
                                rightFileStart = [ordered]@{
                                    line = 6
                                    offset = 1
                                }
                                rightFileEnd = [ordered]@{
                                    line = 6
                                    offset = 1
                                }
                            }
                            pullRequestThreadContext =
                                [ordered]@{
                                    iterationContext =
                                        [ordered]@{
                                            firstComparingIteration = 1
                                            secondComparingIteration = 3
                                        }
                                }
                            comments = @([ordered]@{
                                    id = 10
                                    parentCommentId = 0
                                    commentType = 1
                                    isDeleted = $false
                                    content = 'Please use the three-argument overload.'
                                    author = [ordered]@{
                                        id = '44444444-4444-4444-4444-444444444444'
                                        descriptor = 'aad.human'
                                        uniqueName = 'human@example.invalid'
                                    }
                                })
                        })
                    count = 1
                }
            }
            return @{ threads = @(); count = 0 }
        }
        default { throw "unexpected:$Operation" }
    }
}.GetNewClosure()

try {
    $result = Invoke-NamedAreEqualCurrentPrBridge `
        -Config $config -Provider $provider `
        -StateRoot $StateRoot -ManifestPath $ManifestPath `
        -RepositoryRoot $RepoRoot -Run
    $record = @($result.records | Select-Object -First 1)
    $observation = $null
    if ($record.Count -eq 1) {
        $observationPath = Get-ChildItem -LiteralPath $StateRoot `
            -Recurse -File -Filter "$($record[0].identity).json" |
            Where-Object { $_.Directory.Name -ceq 'observations' } |
            Select-Object -First 1 -ExpandProperty FullName
        if ($observationPath) {
            $observation = Get-Content -LiteralPath $observationPath -Raw |
                ConvertFrom-Json -AsHashtable -Depth 32
        }
    }
    [ordered]@{
        state = [string]$result.state
        providerWrites = [int]$result.providerWrites
        modelWrites = [int]$result.modelWrites
        recordCount = @($result.records).Count
        recordState = if ($record.Count) {
            [string]$record[0].state
        } else { $null }
        calls = @($calls)
        outcomes = @($result.outcomes)
        observation = $observation
    } | ConvertTo-Json -Depth 32
}
catch {
    [ordered]@{
        state = 'threw'
        message = [string]$_.Exception.Message
        calls = @($calls)
    } | ConvertTo-Json -Depth 12
    exit 1
}
