#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-ApprovedOwnerV2AzureDevOpsProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProviderConfigPath,
        [string]$AzureCliPath = 'az',
        [string]$GitPath = 'git'
    )
    $config = Get-Content -LiteralPath $ProviderConfigPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 64
    $subjectProvider = $config.subjectProvider
    $discussionProvider = $config.discussionProvider
    if ($subjectProvider -isnot [Collections.IDictionary] -or
        [string]$subjectProvider.kind -cne 'azure-devops-read-only-v1' -or
        $discussionProvider -isnot [Collections.IDictionary] -or
        [string]$discussionProvider.kind -cne
        'azure-devops-rest-owner-discussions-v1') {
        throw 'Provider config must contain the exact Owner v2 Azure DevOps contracts.'
    }
    $reviewer = $discussionProvider.reviewerIdentity
    if ($reviewer -isnot [Collections.IDictionary] -or
        [string]$reviewer.id -cnotmatch '^[0-9a-f-]{36}$' -or
        [string]$reviewer.descriptor -eq '' -or
        [string]$reviewer.uniqueName -cnotmatch '^[^@\s]+@[^@\s]+$') {
        throw 'Provider config must pin the exact reviewer GUID, descriptor, and UPN.'
    }
    $configuredIdentity = New-OwnerAzureDevOpsReviewerIdentity `
        -Id ([string]$reviewer.id) `
        -Descriptor ([string]$reviewer.descriptor) `
        -UniqueName ([string]$reviewer.uniqueName)
    $configuredAdapter = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
        -Name 'approved-owner-v2-provider-validation' `
        -ReviewerIdentity $configuredIdentity -Handler { throw 'not invoked' }
    if ([string]$discussionProvider.mappingDigest -cne
        [string]$configuredAdapter.AzureDevOpsDiscussionMappingDigest -or
        [string]$reviewer.digest -cne
        [string]$configuredAdapter.AzureDevOpsReviewerIdentityDigest) {
        throw 'Provider config mapping or reviewer identity digest is invalid.'
    }
    $organization = [string]$subjectProvider.organization
    $projectName = [string]$subjectProvider.projectName
    $projectId = [string]$subjectProvider.projectId
    $repositoryId = [string]$subjectProvider.repositoryId
    $pageSize = 100
    $providerBinding = [ordered]@{
        kind = [string]$discussionProvider.kind
        organization = $organization
        projectName = $projectName
        projectId = $projectId
        repositoryId = $repositoryId
        mappingDigest = [string]$discussionProvider.mappingDigest
        reviewerIdentity = [ordered]@{
            id = [string]$configuredIdentity.Id
            descriptor = [string]$configuredIdentity.Descriptor
            uniqueName = [string]$configuredIdentity.UniqueName
            digest = [string]$configuredAdapter.AzureDevOpsReviewerIdentityDigest
        }
    }

    $invokeAzJson = {
        param(
            [Parameter(Mandatory)][string[]]$Arguments,
            [string]$InputPath = ''
        )
        $argv = @($Arguments)
        if ($InputPath) { $argv += @('--in-file', $InputPath) }
        $output = @(& $AzureCliPath @argv 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI REST operation failed with exit code $LASTEXITCODE."
        }
        $text = $output -join "`n"
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return $text | ConvertFrom-Json -AsHashtable -Depth 64
    }.GetNewClosure()

    $getIterations = {
        param([Parameter(Mandatory)][long]$PullRequestId)
        $response = & $invokeAzJson @(
            'devops', 'invoke',
            '--organization', $organization,
            '--area', 'git',
            '--resource', 'pullRequestIterations',
            '--route-parameters',
            "project=$projectName",
            "repositoryId=$repositoryId",
            "pullRequestId=$PullRequestId",
            '--api-version', '7.1',
            '-o', 'json',
            '--only-show-errors'
        )
        $iterations = @($response.value | Sort-Object { [int]$_.id })
        if ($iterations.Count -lt 1) {
            throw "Pull request $PullRequestId has no current iteration."
        }
        return $iterations
    }.GetNewClosure()

    $getChanges = {
        param(
            [Parameter(Mandatory)][long]$PullRequestId,
            [Parameter(Mandatory)][int]$IterationId
        )
        $response = & $invokeAzJson @(
            'devops', 'invoke',
            '--organization', $organization,
            '--area', 'git',
            '--resource', 'pullRequestIterationChanges',
            '--route-parameters',
            "project=$projectName",
            "repositoryId=$repositoryId",
            "pullRequestId=$PullRequestId",
            "iterationId=$IterationId",
            '--query-parameters',
            '$top=2000',
            '$compareTo=0',
            '--api-version', '7.1',
            '-o', 'json',
            '--only-show-errors'
        )
        $entries = @($response.changeEntries)
        if ($entries.Count -ge 2000) {
            throw 'Azure DevOps change listing may be incomplete.'
        }
        return $entries
    }.GetNewClosure()

    $getItemContent = {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Commit
        )
        $apiPath = if ($Path.StartsWith('/')) { $Path } else { "/$Path" }
        $response = & $invokeAzJson @(
            'devops', 'invoke',
            '--organization', $organization,
            '--area', 'git',
            '--resource', 'items',
            '--route-parameters',
            "project=$projectName",
            "repositoryId=$repositoryId",
            '--query-parameters',
            "path=$apiPath",
            "versionDescriptor.version=$Commit",
            'versionDescriptor.versionType=commit',
            'includeContent=true',
            'includeContentMetadata=true',
            '--api-version', '7.1',
            '-o', 'json',
            '--only-show-errors'
        )
        return [string]$response.content
    }.GetNewClosure()

    $getChangedSpans = {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$ChangeType,
            [Parameter(Mandatory)][string]$SourceCommit,
            [Parameter(Mandatory)][string]$TargetCommit
        )
        $source = & $getItemContent $Path $SourceCommit
        if ($ChangeType -match '(?i)^add') {
            $count = [Math]::Max(1, [regex]::Split($source, '\r?\n').Count)
            return , @([ordered]@{ startLine = 1; endLine = $count })
        }
        if ($ChangeType -match '(?i)^delete') { return , @() }
        $target = & $getItemContent $Path $TargetCommit
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'owner-v2-diff-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot | Out-Null
        $before = Join-Path $tempRoot 'before.txt'
        $after = Join-Path $tempRoot 'after.txt'
        try {
            [IO.File]::WriteAllText($before, $target, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($after, $source, [Text.UTF8Encoding]::new($false))
            $diff = @(& $GitPath --no-pager diff --no-index --unified=0 -- $before $after 2>$null)
            if ($LASTEXITCODE -notin @(0, 1)) {
                throw "Unable to derive changed-line spans for '$Path'."
            }
            $spans = [Collections.Generic.List[object]]::new()
            foreach ($line in $diff) {
                if ([string]$line -match
                    '^@@ -\d+(?:,\d+)? \+(?<start>\d+)(?:,(?<count>\d+))? @@') {
                    $start = [int]$Matches.start
                    $count = if ($Matches.count) { [int]$Matches.count } else { 1 }
                    if ($count -gt 0) {
                        [void]$spans.Add([ordered]@{
                                startLine = $start
                                endLine = $start + $count - 1
                            })
                    }
                }
            }
            return , $spans.ToArray()
        }
        finally {
            Remove-Item -LiteralPath $before, $after -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tempRoot -Force -ErrorAction SilentlyContinue
        }
    }.GetNewClosure()

    $writeRequest = {
        param(
            [Parameter(Mandatory)][string]$Resource,
            [Parameter(Mandatory)][string]$Method,
            [Parameter(Mandatory)][string[]]$RouteParameters,
            [Parameter(Mandatory)][Collections.IDictionary]$Body
        )
        $temp = Join-Path ([IO.Path]::GetTempPath()) (
            'owner-v2-request-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            [IO.File]::WriteAllText(
                $temp,
                ($Body | ConvertTo-Json -Depth 16 -Compress),
                [Text.UTF8Encoding]::new($false))
            $arguments = @(
                'devops', 'invoke',
                '--organization', $organization,
                '--area', 'git',
                '--resource', $Resource,
                '--route-parameters'
            ) + $RouteParameters + @(
                '--http-method', $Method,
                '--api-version', '7.1',
                '-o', 'json',
                '--only-show-errors'
            )
            return & $invokeAzJson -Arguments $arguments -InputPath $temp
        }
        finally {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }.GetNewClosure()

    $handler = {
        param([string]$Action, [hashtable]$Arguments)
        $evidence = $Arguments.evidence
        $request = $evidence.Contract.Request
        $pullRequestId = [long]$request.PullRequestId
        switch ($Action) {
            'ReadCurrent' {
                $account = & $invokeAzJson @(
                    'account', 'show', '--only-show-errors', '-o', 'json')
                if ([string]$account.user.name -ine [string]$reviewer.uniqueName) {
                    throw 'Azure CLI identity does not match the configured reviewer UPN.'
                }
                $pr = & $invokeAzJson @(
                    'repos', 'pr', 'show',
                    '--id', [string]$pullRequestId,
                    '--organization', $organization,
                    '--detect', 'false',
                    '-o', 'json',
                    '--only-show-errors'
                )
                $iterations = @(& $getIterations $pullRequestId)
                $current = $iterations[-1]
                $changes = @(& $getChanges $pullRequestId ([int]$current.id))
                $rawThreads = & $invokeAzJson @(
                    'devops', 'invoke',
                    '--organization', $organization,
                    '--area', 'git',
                    '--resource', 'pullRequestThreads',
                    '--route-parameters',
                    "project=$projectName",
                    "repositoryId=$repositoryId",
                    "pullRequestId=$pullRequestId",
                    '--api-version', '7.1',
                    '-o', 'json',
                    '--only-show-errors'
                )
                $reviewerIdentity = New-OwnerAzureDevOpsReviewerIdentity `
                    -Id ([string]$reviewer.id) `
                    -Descriptor ([string]$reviewer.descriptor) `
                    -UniqueName ([string]$reviewer.uniqueName)
                $providerHandler = {
                    param($Operation, $ProviderArguments)
                    if ($Operation -cne 'GetDiscussionPage') {
                        throw "Unsupported discussion read '$Operation'."
                    }
                    return ConvertTo-OwnerAzureDevOpsDiscussionPage `
                        -Arguments $ProviderArguments `
                        -RawResponse $rawThreads `
                        -CurrentIteration ([ordered]@{
                            id = [int]$current.id
                            sourceCommit = [string]$current.sourceRefCommit.commitId
                            targetCommit = [string]$current.targetRefCommit.commitId
                        }) `
                        -ReviewerIdentity $reviewerIdentity
                }.GetNewClosure()
                $adapter = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
                    -Name 'approved-owner-v2-direct-ado-rest' `
                    -ReviewerIdentity $reviewerIdentity -Handler $providerHandler
                $snapshot = Get-OwnerDiscussionSnapshot -Contract $evidence.Contract `
                    -Provider $adapter `
                    -Limits (New-OwnerDiscussionLimits -MaximumPages 20 `
                        -PageSize $pageSize -MaximumThreads 1000 `
                        -MaximumComments 5000 -MaximumBytes 4194304) `
                    -RequireAzureDevOpsProvenance

                $anchors = [Collections.Generic.List[object]]::new()
                $selections = @($Arguments.selections)
                if ($selections.Count -lt 1 -or $selections.Count -gt 5) {
                    throw 'Live provider requires one to five exact approved selections.'
                }
                $paths = @($selections.path | Sort-Object -Unique)
                foreach ($path in $paths) {
                    $matches = @($changes | Where-Object {
                            ([string]$_.item.path).TrimStart('/') -ieq [string]$path
                        })
                    if ($matches.Count -ne 1) {
                        throw "Current iteration change for '$path' is missing or ambiguous."
                    }
                    $change = $matches[0]
                    $spans = @(& $getChangedSpans -Path ([string]$path) `
                            -ChangeType ([string]$change.changeType) `
                            -SourceCommit ([string]$pr.lastMergeSourceCommit.commitId) `
                            -TargetCommit ([string]$pr.lastMergeTargetCommit.commitId))
                    foreach ($span in $spans) {
                        [void]$anchors.Add([ordered]@{
                                path = [string]$path
                                startLine = [int]$span.startLine
                                endLine = [int]$span.endLine
                                changeTrackingId = [int]$change.changeTrackingId
                                iterationId = [int]$current.id
                            })
                    }
                }
                return [pscustomobject][ordered]@{
                    ProviderBinding = $providerBinding
                    PullRequest = [ordered]@{
                        pullRequestId = [long]$pr.pullRequestId
                        status = [string]$pr.status
                        isDraft = [bool]$pr.isDraft
                        repositoryId = [string]$pr.repository.id
                        projectId = [string]$pr.repository.project.id
                        sourceCommit = [string]$pr.lastMergeSourceCommit.commitId
                        targetCommit = [string]$pr.lastMergeTargetCommit.commitId
                        targetRef = [string]$pr.targetRefName
                    }
                    Reviewer = [ordered]@{
                        id = ([string]$reviewer.id).ToLowerInvariant()
                        descriptor = [string]$reviewer.descriptor
                        uniqueName = ([string]$reviewer.uniqueName).ToLowerInvariant()
                    }
                    Snapshot = $snapshot
                    Anchors = $anchors.ToArray()
                }
            }
            'CreateThread' {
                $selection = $Arguments.selection
                $anchor = $Arguments.anchor
                $body = [ordered]@{
                    comments = @([ordered]@{
                            parentCommentId = 0
                            content = [string]$selection.body
                            commentType = 1
                        })
                    status = 1
                    threadContext = [ordered]@{
                        filePath = '/' + ([string]$selection.path).TrimStart('/')
                        rightFileStart = [ordered]@{
                            line = [int]$selection.line
                            offset = 1
                        }
                        rightFileEnd = [ordered]@{
                            line = [int]$selection.line
                            offset = 1
                        }
                    }
                    pullRequestThreadContext = [ordered]@{
                        changeTrackingId = [int]$anchor.changeTrackingId
                        iterationContext = [ordered]@{
                            firstComparingIteration = 1
                            secondComparingIteration = [int]$anchor.iterationId
                        }
                    }
                }
                return & $writeRequest 'pullRequestThreads' 'POST' @(
                    "project=$projectName",
                    "repositoryId=$repositoryId",
                    "pullRequestId=$pullRequestId"
                ) $body
            }
            'UpdateComment' {
                $selection = $Arguments.selection
                return & $writeRequest 'pullRequestThreadComments' 'PATCH' @(
                    "project=$projectName",
                    "repositoryId=$repositoryId",
                    "pullRequestId=$pullRequestId",
                    "threadId=$([long]$Arguments.threadId)",
                    "commentId=$([long]$Arguments.commentId)"
                ) ([ordered]@{
                        content = [string]$selection.body
                        commentType = 1
                    })
            }
            default { throw "Unknown approved Owner v2 provider action '$Action'." }
        }
    }.GetNewClosure()
    return $handler
}
