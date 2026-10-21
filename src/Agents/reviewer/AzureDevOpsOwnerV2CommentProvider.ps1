#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\DevPilot.ContextualConventions\DevPilot.ContextualConventions.psd1')

function Get-ApprovedOwnerV2ProviderTextSha256 {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )
    return ([Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.UTF8Encoding]::new($false).
                GetBytes($Text)))).
        ToLowerInvariant()
}

function Get-ApprovedOwnerV2ChangedSpans {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ChangeType,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceContent,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TargetContent,
        [string]$GitPath = 'git'
    )

    if ($ChangeType -match '(?i)^add') {
        $count = [Math]::Max(
            1, [regex]::Split($SourceContent, '\r?\n').Count)
        return @([ordered]@{ startLine = 1; endLine = $count })
    }

    if ($ChangeType -match '(?i)^delete') { return @() }
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'owner-v2-diff-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $before = Join-Path $tempRoot 'before.txt'
    $after = Join-Path $tempRoot 'after.txt'
    try {
        [IO.File]::WriteAllText(
            $before, $TargetContent, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText(
            $after, $SourceContent, [Text.UTF8Encoding]::new($false))
        $diff = @(& $GitPath --no-pager diff --no-index --unified=0 -- `
                $before $after 2>$null)
        if ($LASTEXITCODE -notin @(0, 1)) {
            throw "Unable to derive changed-line spans for '$Path'."
        }
        $spans = [Collections.Generic.List[object]]::new()
        foreach ($line in $diff) {
            if ([string]$line -match
                '^@@ -\d+(?:,\d+)? \+(?<start>\d+)(?:,(?<count>\d+))? @@') {
                $start = [int]$Matches.start
                $count = if ($Matches['count']) {
                    [int]$Matches['count']
                } else { 1 }
                if ($count -gt 0) {
                    [void]$spans.Add([ordered]@{
                            startLine = $start
                            endLine = $start + $count - 1
                        })
                }
            }
        }
        return $spans.ToArray()
    }
    finally {
        Remove-Item -LiteralPath $before, $after `
            -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempRoot `
            -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-ApprovedOwnerV2LiveHead {
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$PullRequest,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Iteration,
        [Parameter(Mandatory)]
        [object[]]$SourceRefs
    )
    $sourceRef = [string](
        $PullRequest['sourceRefName'])
    $sourceCommit =
        [string](($Iteration[
            'sourceRefCommit'])['commitId'])
    $targetCommit =
        [string](($Iteration[
            'targetRefCommit'])['commitId'])
    $matchingSourceCommits = @(
        foreach ($ref in $SourceRefs) {
            if ($ref -is
                    [Collections.IDictionary] -and
                [string]($ref['name']) -ceq
                    $sourceRef -and
                [string]($ref['objectId']) -cmatch
                    '^[a-fA-F0-9]{40}$') {
                [string]($ref['objectId'])
            }
        })
    $liveSourceCommit = [string](
        $matchingSourceCommits |
            Select-Object -First 1)
    if ($sourceRef -cnotmatch '^refs/heads/.+' -or
        $sourceCommit -cnotmatch '^[a-fA-F0-9]{40}$' -or
        $targetCommit -cnotmatch '^[a-fA-F0-9]{40}$' -or
        $matchingSourceCommits.Count -ne 1 -or
        $liveSourceCommit -ine
            $sourceCommit) {
        throw 'Live pull request source ref or iteration is inconsistent.'
    }
    return [ordered]@{
        sourceCommit = $sourceCommit
        targetCommit = $targetCommit
        targetRef = [string](
            $PullRequest['targetRefName'])
        iterationId = [int](
            $Iteration['id'])
    }
}

function Get-ApprovedOwnerV2AzureCliLaunchPlan {
    param(
        [Parameter(Mandatory)][string]$AzureCliPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $commands = @(Get-Command $AzureCliPath -CommandType Application `
            -ErrorAction SilentlyContinue)
    if ($commands.Count -ne 1) {
        throw 'Azure CLI command resolution was ambiguous or unavailable.'
    }
    $tool = Get-Item -LiteralPath $commands[0].Source -Force
    if ($tool.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Azure CLI command path cannot be a reparse point.'
    }
    if ($tool.Extension -cne '.cmd') {
        return [ordered]@{
            fileName = $tool.FullName
            argumentList = $Arguments
            environment = [ordered]@{}
        }
    }
    if ($tool.Name -cne 'az.cmd' -or $tool.Length -gt 4096) {
        throw 'Azure CLI command shim was not the supported az.cmd launcher.'
    }
    $lines = @(Get-Content -LiteralPath $tool.FullName | ForEach-Object {
            ([string]$_).Trim()
        } | Where-Object {
            $_ -and -not $_.StartsWith('::')
        })
    $expected = @(
        '@IF EXIST "%~dp0\..\python.exe" (',
        'SET AZ_INSTALLER=MSI',
        '"%~dp0\..\python.exe" -IBm azure.cli %*',
        ') ELSE (',
        'echo Failed to load python executable.',
        'exit /b 1',
        ')'
    )
    if ($lines.Count -ne $expected.Count) {
        throw 'Azure CLI command shim content was not recognized.'
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ($lines[$index] -cne $expected[$index]) {
            throw 'Azure CLI command shim content was not recognized.'
        }
    }
    $python = Join-Path (
        Split-Path -Parent (
            Split-Path -Parent $tool.FullName)
    ) 'python.exe'
    $pythonItem = Get-Item -LiteralPath $python -Force `
        -ErrorAction SilentlyContinue
    if ($null -eq $pythonItem -or
        $pythonItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) {
        throw 'Azure CLI Python runtime was unavailable or unsafe.'
    }
    return [ordered]@{
        fileName = $pythonItem.FullName
        argumentList = [string[]]@(
            '-X', 'utf8', '-I', '-B', '-m', 'azure.cli'
        ) + $Arguments
        environment = [ordered]@{
            AZ_INSTALLER = 'MSI'
        }
    }
}

function Invoke-ApprovedOwnerV2AzureCliJson {
    param(
        [Parameter(Mandatory)][string]$AzureCliPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$InputPath = '',
        [ValidateRange(1, 300000)]
        [int]$TimeoutMilliseconds = 120000
    )
    $argv = @($Arguments)
    if ($InputPath) {
        $argv += @('--in-file', $InputPath)
    }
    $plan = Get-ApprovedOwnerV2AzureCliLaunchPlan `
        -AzureCliPath $AzureCliPath -Arguments $argv
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [string]$plan.fileName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @($plan.argumentList)) {
        [void]$start.ArgumentList.Add([string]$argument)
    }
    [void]$start.Environment.Remove('AZURE_DEVOPS_EXT_PAT')
    [void]$start.Environment.Remove('SYSTEM_ACCESSTOKEN')
    foreach ($entry in $plan.environment.GetEnumerator()) {
        $start.Environment[[string]$entry.Key] =
            [string]$entry.Value
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $output = [IO.MemoryStream]::new()
    $error = [IO.MemoryStream]::new()
    try {
        if (-not $process.Start()) {
            throw 'Azure CLI process did not start.'
        }
        $outputTask =
            $process.StandardOutput.BaseStream.CopyToAsync(
                $output)
        $errorTask =
            $process.StandardError.BaseStream.CopyToAsync(
                $error)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(100)) {
            if ($output.Length -gt 16777216 -or
                $error.Length -gt 65536) {
                $process.Kill($true)
                throw 'Azure CLI output exceeded its bounded size.'
            }
            if ($watch.ElapsedMilliseconds -ge
                $TimeoutMilliseconds) {
                $process.Kill($true)
                throw 'Azure CLI operation exceeded its time budget.'
            }
        }
        [Threading.Tasks.Task]::WaitAll(
            [Threading.Tasks.Task[]]@(
                $outputTask, $errorTask))
        if ($output.Length -gt 16777216 -or
            $error.Length -gt 65536) {
            throw 'Azure CLI output exceeded its bounded size.'
        }
        if ($process.ExitCode -ne 0) {
            throw (
                'Azure CLI REST operation failed with exit code ' +
                "$($process.ExitCode).")
        }
        $text = [Text.UTF8Encoding]::new(
            $false, $true).GetString(
                $output.ToArray())
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        return $text | ConvertFrom-Json `
            -AsHashtable -Depth 64
    }
    finally {
        $output.Dispose()
        $error.Dispose()
        $process.Dispose()
    }
}

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
    $invokeAzureCliJsonCommand =
        ${function:Invoke-ApprovedOwnerV2AzureCliJson}
    $resolveLiveHeadCommand =
        ${function:Resolve-ApprovedOwnerV2LiveHead}
    $getChangedSpansCommand =
        ${function:Get-ApprovedOwnerV2ChangedSpans}
    $textSha256Command =
        ${function:Get-ApprovedOwnerV2ProviderTextSha256}
    $copyrightEvidenceCommand = Get-Command Get-ContextualCopyrightHeaderEvidence -CommandType Function
    $newReviewerIdentityCommand =
        (Get-Command `
            New-OwnerAzureDevOpsReviewerIdentity `
            -CommandType Function).ScriptBlock
    $convertDiscussionPageCommand =
        (Get-Command `
            ConvertTo-OwnerAzureDevOpsDiscussionPage `
            -CommandType Function).ScriptBlock
    $newReadOnlyAdapterCommand =
        (Get-Command `
            New-OwnerAzureDevOpsReadOnlyProviderAdapter `
            -CommandType Function).ScriptBlock
    $getDiscussionSnapshotCommand =
        (Get-Command `
            Get-OwnerDiscussionSnapshot `
            -CommandType Function).ScriptBlock
    $newDiscussionLimitsCommand =
        (Get-Command `
            New-OwnerDiscussionLimits `
            -CommandType Function).ScriptBlock

    $invokeAzJson = {
        param(
            [Parameter(Mandatory)][string[]]$Arguments,
            [string]$InputPath = ''
        )
        return & $invokeAzureCliJsonCommand `
            -AzureCliPath $AzureCliPath `
            -Arguments $Arguments `
            -InputPath $InputPath
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

    $getSourceRefs = {
        param([Parameter(Mandatory)][string]$SourceRef)
        if ($SourceRef -cnotmatch
            '^refs/heads/(?<filter>.+)$') {
            throw 'Live pull request source ref is invalid.'
        }
        $response = & $invokeAzJson @(
            'devops', 'invoke',
            '--organization', $organization,
            '--area', 'git',
            '--resource', 'refs',
            '--route-parameters',
            "project=$projectName",
            "repositoryId=$repositoryId",
            '--query-parameters',
            "filter=heads/$($Matches.filter)",
            'includeStatuses=false',
            'peelTags=false',
            '--api-version', '7.1',
            '-o', 'json',
            '--only-show-errors'
        )
        return @($response.value)
    }.GetNewClosure()

    $getPullRequestTemplate = {
        $repository = & $invokeAzJson @(
            'devops', 'invoke',
            '--organization', $organization,
            '--area', 'git',
            '--resource', 'repositories',
            '--route-parameters',
            "project=$projectName",
            "repositoryId=$repositoryId",
            '--api-version', '7.1',
            '-o', 'json',
            '--only-show-errors'
        )
        $defaultRef =
            [string]$repository.defaultBranch
        if ($defaultRef -cnotmatch
                '^refs/heads/(?<filter>[^~^:?*\[\\]+)$') {
            throw 'Live repository default branch is unavailable.'
        }
        $refs = & $invokeAzJson @(
            'devops', 'invoke',
            '--organization', $organization,
            '--area', 'git',
            '--resource', 'refs',
            '--route-parameters',
            "project=$projectName",
            "repositoryId=$repositoryId",
            '--query-parameters',
            "filter=heads/$($Matches.filter)",
            'includeStatuses=false',
            'peelTags=false',
            '--api-version', '7.1',
            '-o', 'json',
            '--only-show-errors'
        )
        $refMatches = @($refs.value |
            Where-Object {
                [string]$_.name -ceq
                    $defaultRef -and
                [string]$_.objectId -cmatch
                    '^[0-9a-fA-F]{40}$'
            })
        if ($refMatches.Count -ne 1) {
            throw 'Live repository default branch commit is stale or ambiguous.'
        }
        $commit = ([string]$refMatches[0].
            objectId).ToLowerInvariant()
        $directory = & $invokeAzJson @(
            'devops', 'invoke',
            '--organization', $organization,
            '--area', 'git',
            '--resource', 'items',
            '--route-parameters',
            "project=$projectName",
            "repositoryId=$repositoryId",
            '--query-parameters',
            'scopePath=/.azuredevops',
            'recursionLevel=Full',
            'includeContentMetadata=true',
            "versionDescriptor.version=$commit",
            'versionDescriptor.versionType=commit',
            '--api-version', '7.1',
            '-o', 'json',
            '--only-show-errors'
        )
        $items = if ($directory -is
                [Collections.IDictionary] -and
            $directory.value -is [array]) {
            @($directory.value)
        }
        elseif ($directory -is [array]) {
            @($directory)
        }
        else { @() }
        $templateRelated = @($items |
            Where-Object {
                $_ -is
                    [Collections.IDictionary] -and
                -not [bool]$_.isFolder -and
                [string]$_.path -match
                    '(?i)^/\.azuredevops/(?:pull_request_template\.(?:md|txt)|pull_request_template/.+)$'
            })
        $candidates = @($templateRelated |
            Where-Object {
                [string]$_.path -match
                    '(?i)^/\.azuredevops/pull_request_template\.(?:md|txt)$'
            })
        if ($candidates.Count -ne 1 -or
            $templateRelated.Count -ne 1) {
            throw 'Live effective pull request template is unavailable or ambiguous.'
        }
        $candidate = $candidates[0]
        $blob = ([string]$candidate.objectId).
            ToLowerInvariant()
        if ($blob -cnotmatch
                '^[0-9a-f]{40}$') {
            throw 'Live effective pull request template blob is malformed.'
        }
        $contentResponse = & $invokeAzJson @(
            'devops', 'invoke',
            '--organization', $organization,
            '--area', 'git',
            '--resource', 'items',
            '--route-parameters',
            "project=$projectName",
            "repositoryId=$repositoryId",
            '--query-parameters',
            "path=$([string]$candidate.path)",
            "versionDescriptor.version=$commit",
            'versionDescriptor.versionType=commit',
            'includeContent=true',
            'includeContentMetadata=true',
            '--api-version', '7.1',
            '-o', 'json',
            '--only-show-errors'
        )
        if ($contentResponse -isnot
                [Collections.IDictionary] -or
            $contentResponse.content -isnot
                [string]) {
            throw 'Live effective pull request template content is unavailable.'
        }
        $content = [string]$contentResponse.content
        if ([Text.Encoding]::UTF8.GetByteCount(
                $content) -gt 65536) {
            throw 'Live effective pull request template is oversized.'
        }
        return [ordered]@{
            path =
                ([string]$candidate.path).
                    TrimStart('/')
            ref = $defaultRef
            commit = $commit
            blob = $blob
            contentSha256 =
                & $textSha256Command $content
        }
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
        if ($response -isnot [Collections.IDictionary] -or
            -not $response.Contains('content') -or
            $response.content -isnot [string] -or
            $response.contentMetadata -isnot [Collections.IDictionary] -or
            -not $response.contentMetadata.Contains('contentType') -or
            $response.contentMetadata.contentType -isnot [string] -or
            [string]::IsNullOrWhiteSpace(
                [string]$response.contentMetadata.contentType) -or
            (-not ([string]$response.contentMetadata.contentType).
                StartsWith(
                    'text/', [StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetExtension($Path) -ine '.cs') -or
            [Text.Encoding]::UTF8.GetByteCount(
                [string]$response.content) -gt 16777216) {
            throw "Item content for '$Path' is unavailable or incomplete."
        }
        return [string]$response.content
    }.GetNewClosure()

    $getChangedSpans = {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$ChangeType,
            [Parameter(Mandatory)][string]$SourceCommit,
            [Parameter(Mandatory)][string]$TargetCommit
        )
        $deleted = $ChangeType -match '(?i)^delete'
        $source = if ($deleted) {
            ''
        }
        else {
            & $getItemContent $Path $SourceCommit
        }
        $target = if ($ChangeType -match '(?i)^add') {
            ''
        }
        elseif ($deleted) {
            ''
        }
        else {
            & $getItemContent $Path $TargetCommit
        }
        return & $getChangedSpansCommand `
            -Path $Path -ChangeType $ChangeType `
            -SourceContent $source -TargetContent $target -GitPath $GitPath
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
                $liveHead = & $resolveLiveHeadCommand `
                    -PullRequest $pr -Iteration $current `
                    -SourceRefs @(& $getSourceRefs (
                        [string]$pr.sourceRefName))
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
                $reviewerIdentity = & $newReviewerIdentityCommand `
                    -Id ([string]$reviewer.id) `
                    -Descriptor ([string]$reviewer.descriptor) `
                    -UniqueName ([string]$reviewer.uniqueName)
                $pageConverter =
                    $convertDiscussionPageCommand
                $providerHandler = {
                    param($Operation, $ProviderArguments)
                    if ($Operation -cne 'GetDiscussionPage') {
                        throw "Unsupported discussion read '$Operation'."
                    }
                    return & $pageConverter `
                        -Arguments $ProviderArguments `
                        -RawResponse $rawThreads `
                        -CurrentIteration ([ordered]@{
                            id = [int]$current.id
                            sourceCommit = [string]$current.sourceRefCommit.commitId
                            targetCommit = [string]$current.targetRefCommit.commitId
                        }) `
                        -ReviewerIdentity $reviewerIdentity
                }.GetNewClosure()
                $adapter = & $newReadOnlyAdapterCommand `
                    -Name 'approved-owner-v2-direct-ado-rest' `
                    -ReviewerIdentity $reviewerIdentity -Handler $providerHandler
                $snapshot = & $getDiscussionSnapshotCommand `
                    -Contract $evidence.Contract `
                    -Provider $adapter `
                    -Limits (& $newDiscussionLimitsCommand `
                        -MaximumPages 20 `
                        -PageSize $pageSize -MaximumThreads 1000 `
                        -MaximumComments 5000 -MaximumBytes 4194304) `
                    -RequireAzureDevOpsProvenance

                $anchors = [Collections.Generic.List[object]]::new()
                $selections = @($Arguments.selections)
                if ($selections.Count -lt 1 -or $selections.Count -gt 5) {
                    throw 'Live provider requires one to five exact approved selections.'
                }
                $paths = @($selections |
                    Where-Object {
                        -not $_.Contains('scope') -or
                        [string]$_.scope -cne
                            'pull-request'
                    } |
                    ForEach-Object {
                        [string]$_.path
                    } |
                    Sort-Object -Unique)
                foreach ($path in $paths) {
                    $matches = @($changes | Where-Object {
                            ([string]$_.item.path).TrimStart('/') -ieq [string]$path
                        })
                    if ($matches.Count -ne 1) {
                        throw "Current iteration change for '$path' is missing or ambiguous."
                    }
                    $change = $matches[0]
                    $pathSelections = @($selections | Where-Object {
                        $_.Contains('path') -and [string]$_.path -ceq $path
                    })
                    $headerSelections = @($pathSelections | Where-Object {
                        $_.Contains('scope') -and [string]$_.scope -ceq 'file-header'
                    })
                    if ($headerSelections.Count -gt 0) {
                        if (@($headerSelections | Where-Object {
                            [string]$_.ruleId -cne 'file-copyright-header'
                        }).Count -gt 0 -or [string]$change.changeType -match '(?i)^delete') {
                            throw 'Only current copyright findings may use file-header preflight.'
                        }
                        $oldPath = if ([string]$change.changeType -match '(?i)rename') {
                            ([string]$change.originalPath).TrimStart('/')
                        } else { $null }
                        $sourceContent = & $getItemContent $path ([string]$liveHead.sourceCommit)
                        $targetContent = if ([string]$change.changeType -match '(?i)^add') { '' }
                            else {
                                & $getItemContent $(if ($oldPath) { $oldPath } else { $path }) `
                                    ([string]$liveHead.targetCommit)
                            }
                        $header = & $copyrightEvidenceCommand -Path $path -OldPath $oldPath `
                            -ChangeType ([string]$change.changeType) `
                            -Content $sourceContent -TargetContent $targetContent `
                            -SourceCommit ([string]$liveHead.sourceCommit) `
                            -TargetCommit ([string]$liveHead.targetCommit)
                        [void]$anchors.Add([ordered]@{
                            scope = 'file-header'
                            path = $path
                            startLine = 1
                            endLine = 1
                            changeTrackingId = [int]$change.changeTrackingId
                            iterationId = [int]$liveHead.iterationId
                            fileHeader = $header
                        })
                        if ($headerSelections.Count -eq $pathSelections.Count) { continue }
                    }
                    $spans = @(& $getChangedSpans -Path ([string]$path) `
                            -ChangeType ([string]$change.changeType) `
                            -SourceCommit ([string]$liveHead.sourceCommit) `
                            -TargetCommit ([string]$liveHead.targetCommit))
                    foreach ($span in $spans) {
                        [void]$anchors.Add([ordered]@{
                                path = [string]$path
                                startLine = [int]$span.startLine
                                endLine = [int]$span.endLine
                                changeTrackingId = [int]$change.changeTrackingId
                                iterationId = [int]$liveHead.iterationId
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
                        sourceCommit = [string]$liveHead.sourceCommit
                        targetCommit = [string]$liveHead.targetCommit
                        targetRef = [string]$liveHead.targetRef
                        metadata = $(if (@($selections |
                                Where-Object {
                                    $_.Contains('scope') -and
                                    [string]$_.scope -ceq
                                        'pull-request'
                                }).Count -gt 0) {
                            [ordered]@{
                                descriptionSha256 =
                                    & $textSha256Command (
                                        $(if ($null -eq
                                            $pr.description) {
                                            ''
                                        }
                                        else {
                                            [string]$pr.description
                                        }))
                                template =
                                    & $getPullRequestTemplate
                            }
                        }
                        else { $null })
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
                }
                if (-not $selection.Contains(
                        'scope') -or
                    [string]$selection.scope -cne
                        'pull-request') {
                        $body['threadContext'] =
                            [ordered]@{
                                filePath = '/' +
                                    ([string]$selection.path).
                                        TrimStart('/')
                                rightFileStart =
                                    [ordered]@{
                                        line =
                                            [int]$selection.line
                                        offset = 1
                                    }
                                rightFileEnd =
                                    [ordered]@{
                                        line =
                                            [int]$selection.line
                                        offset = 1
                                    }
                            }
                        $body['pullRequestThreadContext'] =
                            [ordered]@{
                                changeTrackingId =
                                    [int]$anchor.changeTrackingId
                                iterationContext =
                                    [ordered]@{
                                        firstComparingIteration = 1
                                        secondComparingIteration =
                                            [int]$anchor.iterationId
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
