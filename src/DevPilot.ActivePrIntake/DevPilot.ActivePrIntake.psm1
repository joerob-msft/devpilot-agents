#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1')
. (Join-Path $PSScriptRoot `
    '..\Agents\reviewer\AzureDevOpsOwnerV2CommentProvider.ps1')
. (Join-Path $PSScriptRoot 'DevPilot.ChangeDerivation.ps1')

function Assert-IntakeNumber {
    param($Value, [string]$Name, [int]$Minimum, [int]$Maximum)
    if ($Value -is [bool] -or $null -eq $Value -or
        [string]$Value -cnotmatch '^(0|[1-9][0-9]*)$') {
        throw "Invalid $Name."
    }
    $number = 0
    if (-not [int]::TryParse([string]$Value, [ref]$number) -or
        $number -lt $Minimum -or $number -gt $Maximum) {
        throw "Invalid $Name."
    }
    return $number
}

function Get-IntakeDigest {
    param($Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 32 -Compress
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))
    ).ToLowerInvariant()
}

function New-IntakeTransportFailure {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet(
            'command-resolution',
            'command-validation',
            'process-start',
            'process-io',
            'process-exit',
            'response-empty'
        )]
        [string]$TransportStage = 'process-exit',
        [int]$NativeExitCode = -1,
        [byte[]]$StderrBytes = [byte[]]::new(0),
        [AllowNull()][Exception]$SourceException = $null
    )
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['transportStage'] = $TransportStage
    if ($NativeExitCode -ge 0) {
        $exception.Data['nativeExitCode'] = $NativeExitCode
    }
    if ($null -ne $SourceException) {
        $diagnosticException = $SourceException
        if ($diagnosticException -is
                [Management.Automation.MethodInvocationException] -and
            $null -ne $diagnosticException.InnerException) {
            $diagnosticException = $diagnosticException.InnerException
        }
        $exception.Data['underlyingExceptionType'] = switch (
            $diagnosticException.GetType().Name) {
            'ArgumentException' { 'ArgumentException' }
            'CommandNotFoundException' { 'CommandNotFoundException' }
            'DecoderFallbackException' { 'DecoderFallbackException' }
            'IOException' { 'IOException' }
            'InvalidOperationException' { 'InvalidOperationException' }
            'NotSupportedException' { 'NotSupportedException' }
            'RuntimeException' { 'RuntimeException' }
            'UnauthorizedAccessException' { 'UnauthorizedAccessException' }
            'Win32Exception' { 'Win32Exception' }
            default { 'Other' }
        }
        $exception.Data['hResult'] = $diagnosticException.HResult
        if ($diagnosticException -is [ComponentModel.Win32Exception]) {
            $exception.Data['nativeErrorCode'] =
                $diagnosticException.NativeErrorCode
        }
    }
    $exception.Data['stderrByteCount'] = $StderrBytes.Length
    if ($StderrBytes.Length -gt 0) {
        $exception.Data['stderrSha256'] =
            [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($StderrBytes)).
            ToLowerInvariant()
        $text = [Text.UTF8Encoding]::new($false, $false).
            GetString($StderrBytes)
        $exception.Data['stderrCategory'] = if ($text -match
            '(?i)\b(?:401|unauthenticated|authentication|login|required)\b') {
            'authentication'
        }
        elseif ($text -match
            '(?i)\b(?:403|forbidden|permission|authorized|authorization)\b') {
            'authorization'
        }
        elseif ($text -match
            '(?i)\b(?:timeout|timed out|dns|network|connection|proxy|tls|ssl)\b') {
            'network'
        }
        elseif ($text -match
            '(?i)\b(?:extension|command|argument|resource|area|not found)\b') {
            'command-or-extension'
        }
        else { 'unknown' }
        $http = [regex]::Match($text, '(?<!\d)(?<status>[45]\d\d)(?!\d)')
        if ($http.Success) {
            $exception.Data['httpStatus'] =
                [int]$http.Groups['status'].Value
        }
        $externalCode = [regex]::Match(
            $text, '(?i)\b(?<code>AADSTS\d{4,10})(?!\d)')
        if ($externalCode.Success) {
            $exception.Data['externalErrorCode'] =
                $externalCode.Groups['code'].Value.ToUpperInvariant()
        }
    }
    else {
        $exception.Data['stderrSha256'] = $null
        $exception.Data['stderrCategory'] = 'none'
    }
    return $exception
}

function Copy-IntakeFailureData {
    param(
        [Parameter(Mandatory)][Exception]$Source,
        [Parameter(Mandatory)][Exception]$Destination,
        [string]$IdentityStage = ''
    )
    foreach ($key in @($Source.Data.Keys)) {
        $Destination.Data[[string]$key] = $Source.Data[$key]
    }
    if ($IdentityStage) {
        $Destination.Data['identityStage'] = $IdentityStage
    }
}

function Get-IntakeAzureCliLaunchPlan {
    param(
        [Parameter(Mandatory)][string]$ToolSource,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    if ([IO.Path]::GetExtension($ToolSource) -cne '.cmd' -or
        [IO.Path]::GetFileName($ToolSource) -cne 'az.cmd') {
        return $null
    }
    $launcher = Get-Item -LiteralPath $ToolSource -Force
    if ($launcher.Attributes -band [IO.FileAttributes]::ReparsePoint -or
        $launcher.Length -gt 4096) {
        return $null
    }
    $lines = @(Get-Content -LiteralPath $ToolSource | ForEach-Object {
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
        return $null
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ($lines[$index] -cne $expected[$index]) {
            return $null
        }
    }
    $python = Join-Path (
        Split-Path -Parent (
            Split-Path -Parent $ToolSource)
    ) 'python.exe'
    $pythonItem = Get-Item -LiteralPath $python -Force `
        -ErrorAction SilentlyContinue
    if ($null -eq $pythonItem -or
        $pythonItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) {
        return $null
    }
    return [ordered]@{
        fileName = $python
        argumentList = [string[]]@(
            '-X', 'utf8', '-I', '-B', '-m', 'azure.cli'
        ) + $Arguments
        environment = [ordered]@{
            AZ_INSTALLER = 'MSI'
        }
        environmentVariablesToRemove = [string[]]@(
            'AZURE_DEVOPS_EXT_PAT',
            'SYSTEM_ACCESSTOKEN'
        )
    }
}

function Write-IntakePrivateFailure {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Generation,
        [Parameter(Mandatory)][Exception]$Exception
    )
    $allowedKeys = @(
        'identityStage', 'transportStage', 'underlyingExceptionType',
        'providerOperation', 'providerReason',
        'nativeExitCode', 'hResult', 'nativeErrorCode',
        'httpStatus', 'stderrCategory', 'externalErrorCode',
        'stderrSha256', 'stderrByteCount'
    )
    if (@($allowedKeys | Where-Object {
                $Exception.Data.Contains($_)
            }).Count -eq 0) {
        return
    }
    $diagnostics = Resolve-AgentTrustedRoot `
        -Path (Join-Path $Root 'diagnostics') `
        -Kind durable-state -RepositoryRoot $RepositoryRoot -Create
    $record = [ordered]@{
        schemaVersion = 1
        kind = 'active-pr-intake-private-failure'
        generation = $Generation
        occurredUtc = [DateTime]::UtcNow.ToString('o')
        predicate = [string]$Exception.Message
        exceptionType = $Exception.GetType().Name
        transportStage = $Exception.Data['transportStage']
        underlyingExceptionType =
            $Exception.Data['underlyingExceptionType']
        providerOperation = $Exception.Data['providerOperation']
        providerReason = $Exception.Data['providerReason']
        hResult = $Exception.Data['hResult']
        nativeErrorCode = $Exception.Data['nativeErrorCode']
        identityStage = $Exception.Data['identityStage']
        nativeExitCode = $Exception.Data['nativeExitCode']
        httpStatus = $Exception.Data['httpStatus']
        stderrCategory = $Exception.Data['stderrCategory']
        externalErrorCode = $Exception.Data['externalErrorCode']
        stderrSha256 = $Exception.Data['stderrSha256']
        stderrByteCount = $Exception.Data['stderrByteCount']
    }
    $path = Join-Path $diagnostics "$Generation.json"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
        (ConvertTo-Json -InputObject $record -Depth 8) + "`n")
    if ($bytes.Length -gt 4096) {
        throw 'Private intake failure record exceeded its bounded size.'
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        [void](Assert-AgentTrustedFile `
            -Path $path -AllowedRoot $diagnostics -Private)
        return
    }
    $stream = [IO.File]::Open(
        $path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    [void](Assert-AgentTrustedFile `
        -Path $path -AllowedRoot $diagnostics -Private)
}

function Save-IntakePrivateFailure {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Generation,
        [Parameter(Mandatory)][Exception]$Exception
    )
    try {
        Write-IntakePrivateFailure `
            -Root $Root -RepositoryRoot $RepositoryRoot `
            -Generation $Generation -Exception $Exception
    }
    catch {
        # Private diagnostics must never mask or alter the original
        # fail-closed intake predicate.
        [Console]::Error.WriteLine(
            'private-diagnostic-capture-failed')
    }
}

function Assert-IntakeConfig {
    param([Collections.IDictionary]$Config)
    $guidPattern = '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$'
    if ($Config.schemaVersion -ne 1 -or $Config.readOnly -cne $true -or
        $Config.dryRun -cne $true -or $Config.enabled -isnot [bool] -or
        [string]$Config.organization -cnotmatch '^https://dev\.azure\.com/[A-Za-z0-9_-]+/?$' -or
        [string]$Config.projectName -cnotmatch '^[\w .-]{1,128}$' -or
        [string]$Config.projectId -cnotmatch $guidPattern -or
        [string]$Config.repositoryId -cnotmatch $guidPattern -or
        [string]$Config.expectedAccount.id -cnotmatch $guidPattern -or
        [string]$Config.expectedAccount.descriptor -cnotmatch '^\S{1,512}$' -or
        [string]$Config.expectedAccount.uniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        [string]$Config.automationMarker -cnotmatch '^\[[A-Za-z0-9_.:-]{1,64}\]$') {
        throw 'Intake requires a pinned organization/project/repository/account, dryRun and readOnly.'
    }
    foreach ($setting in @(
            @('pageSize', 1, 200), @('maxPages', 1, 1000),
            @('maxPullRequests', 1, 10000), @('maxHeadsPerRun', 1, 10000),
            @('maxReads', 1, 30000), @('maxSeconds', 1, 3600),
            @('maxChangedFiles', 1, 2000), @('maxChangedLines', 1, 100000),
            @('maxThreads', 1, 1000), @('maxComments', 1, 10000)
        )) {
        [void](Assert-IntakeNumber $Config.limits[$setting[0]] $setting[0] $setting[1] $setting[2])
    }
    if ($Config.rules -isnot [array] -or $Config.rules.Count -eq 0 -or
        $Config.rules.Count -gt 32) { throw 'A bounded generic rule registry is required.' }
    if ([int]$Config.limits.maxPullRequests * $Config.rules.Count -gt 20000) {
        throw 'The configured cohort envelope exceeds its durable size budget.'
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($rule in $Config.rules) {
        if ([string]$rule.id -cnotmatch '^[a-zA-Z0-9_.@-]{1,100}$' -or
            [string]$rule.capability -cnotmatch '^[a-zA-Z0-9_.@-]{1,100}$' -or
            -not $ids.Add([string]$rule.id)) { throw 'Invalid or repeated rule registry entry.' }
    }
    if ($Config.Contains('cursorCompatibility')) {
        $compatibility = $Config.cursorCompatibility
        if ($compatibility -isnot [Collections.IDictionary] -or
            [string]$compatibility.previousConfigDigest -cnotmatch
                '^[0-9a-f]{64}$' -or
            [string]$compatibility.previousToolkitHead -cnotmatch
                '^[0-9a-f]{40}$' -or
            [string]$compatibility.previousToolkitTree -cnotmatch
                '^[0-9a-f]{40}$' -or
            $Config.toolkit -isnot [Collections.IDictionary] -or
            [string]$Config.toolkit.head -ceq
                [string]$compatibility.previousToolkitHead -or
            [string]$Config.toolkit.tree -ceq
                [string]$compatibility.previousToolkitTree) {
            throw 'Cursor compatibility binding is invalid.'
        }
    }
}

function Invoke-IntakeRead {
    param([scriptblock]$Provider, [string]$Operation, [Collections.IDictionary]$Arguments,
        [Collections.IDictionary]$Config, [ref]$Reads, [Diagnostics.Stopwatch]$Clock,
        [long]$DeadlineMilliseconds = 0)
    if ($Operation -cnotin @('Identity', 'ListPage', 'Head', 'Changes', 'Discussions')) {
        throw 'provider-contract'
    }
    if ($Reads.Value -ge [int]$Config.limits.maxReads) { throw 'read-budget' }
    $remainingMilliseconds =
        [long]([int]$Config.limits.maxSeconds * 1000) -
        $Clock.ElapsedMilliseconds
    if ($DeadlineMilliseconds -gt 0) {
        $remainingMilliseconds = [Math]::Min(
            $remainingMilliseconds,
            $DeadlineMilliseconds - $Clock.ElapsedMilliseconds)
    }
    if ($remainingMilliseconds -le 0) { throw 'time-budget' }
    $Reads.Value++
    $Arguments.timeoutMilliseconds = [Math]::Max(
        1,
        [int][Math]::Min([int]::MaxValue, $remainingMilliseconds))
    try {
        $answer = & $Provider $Operation $Arguments
        if ($Clock.Elapsed.TotalSeconds -ge
                [int]$Config.limits.maxSeconds -or
            ($DeadlineMilliseconds -gt 0 -and
                $Clock.ElapsedMilliseconds -ge
                    $DeadlineMilliseconds)) {
            throw 'time-budget'
        }
        if ($answer -isnot [Collections.IDictionary]) {
            throw 'provider-contract'
        }
    }
    catch {
        $source = $_.Exception
        $sourceReason = [string]$source.Message
        $safeProviderReasons = @(
            'account-mismatch',
            'change-list-truncated',
            'change-page-budget',
            'comment-budget',
            'discussion-list-truncated',
            'file-budget',
            'head-inconsistent',
            'identity-read-inaccessible',
            'identity-response-invalid',
            'invalid-discussions',
            'invalid-head',
            'item-content-unavailable',
            'line-budget',
            'mutable-discussions',
            'page-count-mismatch',
            'page-response-invalid',
            'provider-contract',
            'read-budget',
            'read-inaccessible',
            'repository-mismatch',
            'response-invalid',
            'time-budget',
            'unsupported-operation'
        )
        $providerReason = if ($safeProviderReasons -ccontains
            $sourceReason) {
            $sourceReason
        }
        else {
            'unexpected'
        }
        $message = if ($providerReason -ceq 'unexpected') {
            'provider-inaccessible'
        }
        else {
            $providerReason
        }
        $failure = [InvalidOperationException]::new($message)
        Copy-IntakeFailureData `
            -Source $source -Destination $failure
        $failure.Data['providerOperation'] = $Operation
        $failure.Data['providerReason'] = $providerReason
        if (-not $failure.Data.Contains(
                'underlyingExceptionType')) {
            $failure.Data['underlyingExceptionType'] = switch (
                $source.GetType().Name) {
                'ArgumentException' { 'ArgumentException' }
                'CommandNotFoundException' {
                    'CommandNotFoundException'
                }
                'DecoderFallbackException' {
                    'DecoderFallbackException'
                }
                'IOException' { 'IOException' }
                'InvalidOperationException' {
                    'InvalidOperationException'
                }
                'NotSupportedException' {
                    'NotSupportedException'
                }
                'PropertyNotFoundException' {
                    'PropertyNotFoundException'
                }
                'RuntimeException' { 'RuntimeException' }
                'UnauthorizedAccessException' {
                    'UnauthorizedAccessException'
                }
                'Win32Exception' { 'Win32Exception' }
                default { 'Other' }
            }
        }
        throw $failure
    }
    return $answer
}

function Get-IntakePass {
    param([scriptblock]$Provider, [Collections.IDictionary]$Config,
        [ref]$Reads, [Diagnostics.Stopwatch]$Clock, [int]$Pass)
    $seen = @{}
    $duplicates = 0
    $offset = 0
    $size = [int]$Config.limits.pageSize
    $total = $null
    for ($page = 0; $page -lt [int]$Config.limits.maxPages; $page++) {
        $raw = Invoke-IntakeRead $Provider 'ListPage' @{
            pass = $Pass; skip = $offset; top = $size
        } $Config $Reads $Clock
        if ($raw.items -isnot [array] -or $null -eq $raw.count -or
            (Assert-IntakeNumber $raw.count count 0 $size) -ne $raw.items.Count) {
            throw 'invalid-page'
        }
        if ($null -ne $raw['totalCount']) {
            $declared = Assert-IntakeNumber $raw['totalCount'] totalCount 0 10000
            if ($null -ne $total -and $total -ne $declared) { throw 'mutable-page' }
            $total = $declared
            if ($total -gt [int]$Config.limits.maxPullRequests) { throw 'pr-budget' }
        }
        foreach ($item in $raw.items) {
            if ($item -isnot [Collections.IDictionary]) { throw 'invalid-page' }
            $id = Assert-IntakeNumber $item.pullRequestId pullRequestId 1 ([int]::MaxValue)
            if ([string]$item.status -cne 'active' -or $item.isDraft -isnot [bool] -or
                [string]$item.targetRef -cnotmatch '^refs/heads/[^~^:?*\[\\]+$' -or
                ([string]$item.targetRef).Length -gt 512) {
                throw 'invalid-page'
            }
            $value = [ordered]@{
                pullRequestId = $id
                status = 'active'
                isDraft = [bool]$item.isDraft
                targetRef = [string]$item.targetRef
            }
            $key = [string]$id
            $digest = Get-IntakeDigest $value
            if ($seen.ContainsKey($key)) {
                $duplicates++
                if ($seen[$key].digest -cne $digest) { throw 'mutable-page' }
            }
            else { $seen[$key] = @{ digest = $digest; value = $value } }
        }
        if ($seen.Count -gt [int]$Config.limits.maxPullRequests) { throw 'pr-budget' }
        $offset += $raw.items.Count
        if ($null -ne $total -and $offset -gt $total) { throw 'mutable-page' }
        if ($raw.items.Count -eq 0) {
            if ($duplicates -gt 0 -and $null -eq $total) { throw 'missing-page' }
            if ($null -ne $total -and ($offset -ne $total -or $seen.Count -ne $total)) {
                throw 'missing-page'
            }
            return @{ seen = $seen; duplicates = $duplicates; pages = $page + 1 }
        }
        if ($null -ne $total -and $offset -eq $total) {
            if ($seen.Count -ne $total) { throw 'missing-page' }
            return @{ seen = $seen; duplicates = $duplicates; pages = $page + 1 }
        }
    }
    throw 'page-budget'
}

function Assert-IntakeHead {
    param([Collections.IDictionary]$Head, [int]$Id, [Collections.IDictionary]$Config)
    if ((Assert-IntakeNumber $Head.pullRequestId pullRequestId 1 ([int]::MaxValue)) -ne $Id -or
        [string]$Head.repositoryId -ine [string]$Config.repositoryId -or
        [string]$Head.projectId -ine [string]$Config.projectId -or
        [string]$Head.status -cnotin @('active', 'completed', 'abandoned') -or
        $Head.isDraft -isnot [bool] -or
        [string]$Head.sourceRef -cnotmatch '^refs/heads/[^~^:?*\[\\]+$' -or
        [string]$Head.targetRef -cnotmatch '^refs/heads/[^~^:?*\[\\]+$' -or
        ([string]$Head.sourceRef).Length -gt 512 -or
        ([string]$Head.targetRef).Length -gt 512 -or
        [string]$Head.sourceCommit -cnotmatch '^[a-fA-F0-9]{40}$' -or
        [string]$Head.targetCommit -cnotmatch '^[a-fA-F0-9]{40}$') {
        throw 'invalid-head'
    }
    [void](Assert-IntakeNumber $Head.iterationId iterationId 1 ([int]::MaxValue))
    return [ordered]@{
        repositoryId = ([string]$Head.repositoryId).ToLowerInvariant()
        projectId = ([string]$Head.projectId).ToLowerInvariant()
        pullRequestId = $Id
        sourceRef = [string]$Head.sourceRef
        targetRef = [string]$Head.targetRef
        sourceCommit = ([string]$Head.sourceCommit).ToLowerInvariant()
        targetCommit = ([string]$Head.targetCommit).ToLowerInvariant()
        iterationId = [int]$Head.iterationId
        status = [string]$Head.status
        isDraft = [bool]$Head.isDraft
    }
}

function Get-IntakeDiscussionCounts {
    param([Collections.IDictionary]$Response, [Collections.IDictionary]$Config,
        [Collections.IDictionary]$Head)
    if ($Response.threads -isnot [array] -or $Response.threads.Count -gt
        [int]$Config.limits.maxThreads -or $null -eq $Response.count -or
        (Assert-IntakeNumber $Response.count threadCount 0 2000) -ne
        $Response.threads.Count) { throw 'invalid-discussions' }
    $uniqueThreads = [Collections.Generic.List[object]]::new()
    $threadIds = [Collections.Generic.HashSet[int]]::new()
    $uniqueCommentCount = 0
    foreach ($rawThread in $Response.threads) {
        if ($rawThread -isnot [Collections.IDictionary]) { throw 'invalid-discussions' }
        $threadId = Assert-IntakeNumber $rawThread.id threadId 1 ([int]::MaxValue)
        if (-not $threadIds.Add($threadId) -or $rawThread.comments -isnot [array]) {
            throw 'mutable-discussions'
        }
        $copy = [ordered]@{}
        foreach ($name in $rawThread.Keys) { $copy[[string]$name] = $rawThread[$name] }
        $distinct = [Collections.Generic.List[object]]::new()
        $commentDigests = @{}
        foreach ($comment in $rawThread.comments) {
            if ($comment -isnot [Collections.IDictionary]) { throw 'invalid-discussions' }
            $commentId = Assert-IntakeNumber $comment.id commentId 1 ([int]::MaxValue)
            $digest = Get-IntakeDigest $comment
            if ($commentDigests.ContainsKey($commentId)) {
                if ($commentDigests[$commentId] -cne $digest) {
                    throw 'mutable-discussions'
                }
                continue
            }
            $commentDigests[$commentId] = $digest
            $uniqueCommentCount++
            if ($uniqueCommentCount -gt [int]$Config.limits.maxComments) {
                throw 'comment-budget'
            }
            [void]$distinct.Add($comment)
        }
        $copy.comments = @($distinct)
        [void]$uniqueThreads.Add($copy)
    }
    $reviewer = New-OwnerAzureDevOpsReviewerIdentity `
        -Id ([string]$Config.expectedAccount.id) `
        -Descriptor ([string]$Config.expectedAccount.descriptor) `
        -UniqueName ([string]$Config.expectedAccount.uniqueName)
    $rawResponse = [ordered]@{
        count = $uniqueThreads.Count
        value = @($uniqueThreads)
    }
    $typed = @{}
    $pageSize = 200
    for ($ordinal = 0; $ordinal -lt [Math]::Max(1,
            [int][Math]::Ceiling($uniqueThreads.Count / $pageSize)); $ordinal++) {
        $page = ConvertTo-OwnerAzureDevOpsDiscussionPage `
            -Arguments ([ordered]@{
                repositoryId = $Head.repositoryId
                projectId = $Head.projectId
                pullRequestId = $Head.pullRequestId
                sourceCommit = $Head.sourceCommit
                targetCommit = $Head.targetCommit
                targetRef = $Head.targetRef
                pageOrdinal = $ordinal
                pageSize = $pageSize
                continuationToken = if ($ordinal -eq 0) { $null } else {
                    "skip:$($ordinal * $pageSize)"
                }
            }) -RawResponse $rawResponse -CurrentIteration @{
                id = $Head.iterationId
                sourceCommit = $Head.sourceCommit
                targetCommit = $Head.targetCommit
            } -ReviewerIdentity $reviewer
        foreach ($thread in $page.threads) {
            foreach ($comment in $thread.comments) {
                $typed["$($thread.threadId):$($comment.commentId)"] = @{
                    contextState = $thread.contextState
                    comment = $comment
                }
            }
        }
    }
    $keys = @{}
    $human = 0
    $automation = 0
    $ambiguous = 0
    $outdated = 0
    $currentAnchored = 0
    foreach ($thread in $Response.threads) {
        $threadId = Assert-IntakeNumber $thread.id threadId 1 ([int]::MaxValue)
        if ($thread.comments -isnot [array]) { throw 'invalid-discussions' }
        foreach ($comment in $thread.comments) {
            $commentId = Assert-IntakeNumber $comment.id commentId 1 ([int]::MaxValue)
            $key = "$threadId`:$commentId"
            $body = $comment['content']
            if ($null -ne $body -and ([string]$body).Length -gt 65536) {
                throw 'invalid-discussions'
            }
            $author = $comment['author']
            if ($author -isnot [Collections.IDictionary]) { $author = @{} }
            $marker = ([string]$body).Contains([string]$Config.automationMarker)
            $fingerprint = Get-IntakeDigest @($marker, [string]$body,
                [string]$author['id'], [string]$author['uniqueName'],
                $thread['threadContext'], $thread['pullRequestThreadContext'])
            if ($keys.ContainsKey($key)) {
                if ($keys[$key] -cne $fingerprint) { throw 'mutable-discussions' }
                continue
            }
            $keys[$key] = $fingerprint
            if ($keys.Count -gt [int]$Config.limits.maxComments) { throw 'comment-budget' }
            $mapped = $typed[$key]
            if ($null -eq $mapped) { throw 'invalid-discussions' }
            if ($mapped.comment.isDeleted -or $mapped.comment.commentType -cne 'text') {
                continue
            }
            if ($mapped.contextState -ceq 'outdated') {
                $outdated++
                $ambiguous++
                continue
            }
            $context = $thread['threadContext']
            if ($mapped.contextState -ceq 'current' -and
                $context -is [Collections.IDictionary] -and
                $context['filePath'] -and
                ($context['rightFileStart'] -isnot [Collections.IDictionary] -or
                    $context['rightFileEnd'] -isnot [Collections.IDictionary] -or
                    $null -eq $context['rightFileStart']['line'] -or
                    $context['rightFileStart']['line'] -ne
                    $context['rightFileEnd']['line'])) {
                $ambiguous++
                continue
            }
            if ($mapped.contextState -ceq 'ambiguous' -or
                $mapped.comment.reviewerIdentityState -ceq 'ambiguous' -or
                $null -eq $body -or $null -eq $author['id']) {
                $ambiguous++
                continue
            }
            if ($mapped.contextState -ceq 'current') {
                $currentAnchored++
            }
            if ($marker -and $mapped.comment.reviewerOwned) { $automation++ }
            else { $human++ }
        }
    }
    return [ordered]@{
        human = $human
        automation = $automation
        ambiguous = $ambiguous
        outdated = $outdated
        currentAnchored = $currentAnchored
    }
}

function Test-IntakeUsesFindingScopedDiscussionReconciliation {
    param([Collections.IDictionary]$Rule)

    return [string]$Rule.id -ceq 'bpm-named-areequal-arguments@1' -and
        [string]$Rule.capability -ceq 'bpm-named-areequal-arguments@1'
}

function Get-IntakePriorObservation {
    param($Previous, [int]$Id, [string]$RuleId, [string]$Capability,
        [string]$CurrentDigest, [string]$ConfigDigest)
    if ($null -eq $Previous -or
        [string]$Previous.binding.configDigest -cne $ConfigDigest) { return $null }
    foreach ($oldHead in @($Previous.heads)) {
        if ([int]$oldHead.pullRequestId -ne $Id) { continue }
        foreach ($oldRule in @($oldHead.rules)) {
            if ([string]$oldRule.id -cne $RuleId -or
                [string]$oldRule.capability -cne $Capability) { continue }
            $source = $null
            $generation = ''
            if ([string]$oldRule.state -ceq 'evaluated' -and
                [string]$oldRule.observationDigest -cmatch '^[a-f0-9]{64}$' -and
                [string]$oldHead.declarationDigest -cmatch '^[a-f0-9]{64}$') {
                $source = [string]$oldHead.declarationDigest
                $generation = [string]$Previous.generation
            }
            elseif ($oldRule['priorObservation'] -is [Collections.IDictionary] -and
                [string]$oldRule.priorObservation.declarationDigest -cmatch '^[a-f0-9]{64}$') {
                $source = [string]$oldRule.priorObservation.declarationDigest
                $generation = [string]$oldRule.priorObservation.generation
            }
            if ($null -ne $source) {
                return [ordered]@{
                    state = if ($source -cne $CurrentDigest) { 'stale' } else { 'previous-only' }
                    declarationDigest = $source
                    generation = $generation
                }
            }
        }
    }
    return $null
}

function Get-IntakeRuleIdentity {
    param([Collections.IDictionary]$Head, [string]$RuleId,
        [string]$CapabilityId, [string]$ConfigDigest)
    return Get-IntakeDigest ([ordered]@{
            schemaVersion = 1
            repositoryId = $Head.repositoryId
            projectId = $Head.projectId
            pullRequestId = $Head.pullRequestId
            sourceCommit = $Head.sourceCommit
            targetCommit = $Head.targetCommit
            targetRef = $Head.targetRef
            iterationId = $Head.iterationId
            ruleId = $RuleId
            capabilityId = $CapabilityId
            configDigest = $ConfigDigest
        })
}

function Test-IntakeStateRootReadOnly {
    param([string]$Path, [string]$RepositoryRoot)
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw 'Durable state root must be an absolute path.'
    }
    $root = [IO.Path]::GetFullPath($Path)
    $repository = [IO.Path]::GetFullPath($RepositoryRoot)
    $relative = [IO.Path]::GetRelativePath($repository, $root)
    if ($relative -eq '.' -or
        ($relative -ne '..' -and
            -not $relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)") -and
            -not [IO.Path]::IsPathFullyQualified($relative))) {
        throw 'Durable state root must be outside the repository.'
    }
    $candidate = $root
    while ($candidate) {
        $item = Get-Item -LiteralPath $candidate -Force `
            -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Durable state root path contains a link.'
            }
            if ($candidate -eq $root) {
                [void](Resolve-AgentTrustedRoot -Path $root -Kind durable-state `
                        -RepositoryRoot $repository)
            }
        }
        $parent = [IO.Path]::GetDirectoryName($candidate)
        if (-not $parent -or $parent -eq $candidate) { break }
        $candidate = $parent
    }
    return $root
}

function New-IntakeDisabledSummary {
    param([Collections.IDictionary]$Config)
    $rules = @($Config.rules | ForEach-Object {
            [ordered]@{
                capabilityId = [string]$_.capability
                ruleId = [string]$_.id
                discovered = $null
                eligible = $null
                evaluated = 0
                skipped = 0
                error = 0
                pending = 0
                gaps = @('default-off', 'inventory-unknown')
            }
        })
    return [ordered]@{
        schemaVersion = 1
        kind = 'active-pr-intake-cohort'
        generation = $null
        generationOrdinal = $null
        generationFile = $null
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        observedUtc = [DateTime]::UtcNow.ToString('o')
        binding = [ordered]@{
            organization = [string]$Config.organization
            projectId = ([string]$Config.projectId).ToLowerInvariant()
            repositoryId = ([string]$Config.repositoryId).ToLowerInvariant()
            configDigest = Get-IntakeDigest $Config
        }
        mode = 'dry-run-read-only'
        writerEligible = $false
        autoPost = $false
        state = 'disabled'
        populationKnown = $false
        inventory = [ordered]@{
            state = 'unknown'
            consistency = 'two-pass-reconciled-no-atomic-snapshot'
            active = $null
            discovered = $null
            eligible = $null
            excludedOtherTargets = $null
            nonDraftExcludedOtherTargets = $null
            draft = $null
            nonDraft = $null
            byTargetRef = $null
            gaps = @('default-off')
        }
        denominators = [ordered]@{
            active = 0; nonDraft = 0; draft = 0; eligible = 0
            outOfPolicy = 0; byTargetRef = @{}
        }
        counts = [ordered]@{
            discovered = 0; attempted = 0; evaluated = 0; evaluatedRules = 0
            skipped = 0; error = 0; deferred = 0
        }
        gaps = @('default-off', 'inventory-unknown')
        gapCounts = [ordered]@{
            enumerationUnknown = 0; duplicateEntries = 0; deferred = 0
            unknownHeads = 0; unknownRules = 0; staleRules = 0; drift = 0
        }
        pages = [ordered]@{ first = 0; second = 0 }
        cursor = [ordered]@{ nextPullRequestId = $null }
        heads = @()
        rules = $rules
        unmetCapabilities = @()
        reasonCodes = @('default-off')
        readCount = 0
    }
}

function Invoke-ActivePrIntake {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Config,
        [Parameter(Mandatory)][scriptblock]$Provider,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [ValidateRange(0, 4)][int]$MaximumHeadsThisRun = 0,
        [ValidateRange(0, 720)]
        [int]$MaximumSecondsThisRun = 0,
        [switch]$IncludeTransientSnapshots,
        [switch]$Run
    )
    Assert-IntakeConfig $Config
    $StateRoot = Test-IntakeStateRootReadOnly -Path $StateRoot `
        -RepositoryRoot $RepositoryRoot
    if (-not $Run -or -not $Config.enabled) {
        return New-IntakeDisabledSummary -Config $Config
    }
    $root = Resolve-AgentTrustedRoot -Path $StateRoot -Kind durable-state `
        -RepositoryRoot $RepositoryRoot -Create
    $root = Resolve-AgentTrustedRoot -Path (Join-Path $root 'active-pr-intake-v1') `
        -Kind durable-state -RepositoryRoot $RepositoryRoot -Create
    $generationRoot = Resolve-AgentTrustedRoot -Path (Join-Path $root 'generations') `
        -Kind durable-state -RepositoryRoot $RepositoryRoot -Create
    $fileProgressRoot = Resolve-AgentTrustedRoot `
        -Path (Join-Path $root 'file-progress') `
        -Kind durable-state `
        -RepositoryRoot $RepositoryRoot -Create
    $lock = [IO.File]::Open((Join-Path $root 'cohort.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $path = Join-Path $root 'cohort.json'
        $previous = $null
        $cursorBindingCompatible = $false
        $cursorTransitionApplied = $false
        if (Test-Path -LiteralPath $path) {
            $file = Get-Item -LiteralPath $path -Force
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint -or $file.Length -gt 8388608) {
                throw 'Untrusted previous intake state.'
            }
            $previousJson = Get-Content -LiteralPath $path -Raw
            $previous = $previousJson | ConvertFrom-Json -AsHashtable -Depth 32
            if ($previous.schemaVersion -ne 1 -or
                $previous.kind -cne 'active-pr-intake-cohort' -or
                [string]$previous.generation -cnotmatch '^[a-f0-9]{32}$' -or
                $previous.generationOrdinal -isnot [long] -and
                $previous.generationOrdinal -isnot [int] -or
                $previous.generationOrdinal -lt 1 -or
                $previous.generationOrdinal -ge [int]::MaxValue) {
                throw 'Invalid previous intake state.'
            }
            $generationName = "$($previous.generation).json"
            if ([string]$previous.generationFile -cne
                (Join-Path 'generations' $generationName)) {
                throw 'Previous intake generation binding is invalid.'
            }
            $immutable = Join-Path $generationRoot $generationName
            if (-not (Test-Path -LiteralPath $immutable -PathType Leaf)) {
                throw 'Previous immutable intake generation is missing.'
            }
            $immutableFile = Get-Item -LiteralPath $immutable -Force
            if ($immutableFile.Attributes -band [IO.FileAttributes]::ReparsePoint -or
                $immutableFile.Length -gt 8388608 -or
                (Get-Content -LiteralPath $immutable -Raw) -cne $previousJson) {
                throw 'Previous immutable intake generation differs from latest snapshot.'
            }
            if ([string]$previous.binding.organization -cne [string]$Config.organization -or
                [string]$previous.binding.projectId -ine [string]$Config.projectId -or
                [string]$previous.binding.repositoryId -ine [string]$Config.repositoryId) {
                throw 'Intake state is bound to a different repository.'
            }
            $currentConfigDigest = Get-IntakeDigest $Config
            $cursorBindingCompatible =
                [string]$previous.binding.configDigest -ceq
                    $currentConfigDigest
            if (-not $cursorBindingCompatible -and
                $Config.Contains('cursorCompatibility') -and
                $Config.cursorCompatibility -is
                    [Collections.IDictionary] -and
                [string]$previous.binding.configDigest -ceq
                    [string]$Config.cursorCompatibility.
                        previousConfigDigest) {
                $cursorBindingCompatible = $true
                $cursorTransitionApplied = $true
            }
        }
        $effectiveMaximumHeads = if ($MaximumHeadsThisRun -gt 0) {
            $MaximumHeadsThisRun
        }
        else {
            [int]$Config.limits.maxHeadsPerRun
        }
        $effectiveMaximumSeconds = if (
            $MaximumSecondsThisRun -gt 0
        ) {
            $MaximumSecondsThisRun
        }
        else {
            [int]$Config.limits.maxSeconds
        }
        $readConfig = [ordered]@{}
        foreach ($key in $Config.Keys) {
            $readConfig[$key] = $Config[$key]
        }
        $readLimits = [ordered]@{}
        foreach ($key in $Config.limits.Keys) {
            $readLimits[$key] = $Config.limits[$key]
        }
        $readLimits.maxSeconds =
            $effectiveMaximumSeconds
        $readConfig.limits = $readLimits
        $envelope = [ordered]@{
            schemaVersion = 1
            kind = 'active-pr-intake-cohort'
            generation = [guid]::NewGuid().ToString('N')
            generationOrdinal = if ($previous) {
                [int]$previous.generationOrdinal + 1
            } else { 1 }
            generationFile = $null
            createdAtUtc = [DateTime]::UtcNow.ToString('o')
            observedUtc = $null
            binding = [ordered]@{
                organization = [string]$Config.organization
                projectId = ([string]$Config.projectId).ToLowerInvariant()
                repositoryId = ([string]$Config.repositoryId).ToLowerInvariant()
                configDigest = Get-IntakeDigest $Config
                cursorSourceConfigDigest = $(if ($previous) {
                        [string]$previous.binding.configDigest
                    } else { $null })
                cursorTransitionApplied =
                    $cursorTransitionApplied
            }
            mode = 'dry-run-read-only'
            execution = [ordered]@{
                maximumHeadsThisRun = $effectiveMaximumHeads
                maximumSecondsThisRun =
                    $effectiveMaximumSeconds
            }
            writerEligible = $false
            autoPost = $false
            state = 'unknown'
            populationKnown = $false
            inventory = [ordered]@{
                state = 'unknown'
                consistency = 'two-pass-reconciled-no-atomic-snapshot'
                active = $null
                discovered = $null
                eligible = $null
                excludedOtherTargets = $null
                nonDraftExcludedOtherTargets = $null
                draft = $null
                nonDraft = $null
                byTargetRef = $null
                gaps = @()
            }
            denominators = [ordered]@{ active = 0; nonDraft = 0; draft = 0; eligible = 0; outOfPolicy = 0; byTargetRef = @{} }
            counts = [ordered]@{ discovered = 0; attempted = 0; evaluated = 0; evaluatedRules = 0; skipped = 0; error = 0; deferred = 0 }
            gaps = [ordered]@{ enumerationUnknown = 0; duplicateEntries = 0
                deferred = 0; unknownHeads = 0; unknownRules = 0
                staleRules = 0; drift = 0 }
            pages = [ordered]@{ first = 0; second = 0 }
            cursor = [ordered]@{ nextPullRequestId = $null }
            heads = @()
            rules = @()
            unmetCapabilities = @()
            reasonCodes = @()
        }
        $envelope.generationFile = Join-Path 'generations' "$($envelope.generation).json"
        if ($previous -and $cursorBindingCompatible -and
            $null -ne $previous.cursor.nextPullRequestId) {
            $envelope.cursor.nextPullRequestId =
                $previous.cursor.nextPullRequestId
        }
        $reasons = [Collections.Generic.List[string]]::new()
        $heads = [Collections.Generic.List[object]]::new()
        $transientSnapshots = [ordered]@{}
        $reads = 0
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
                $identity = Invoke-IntakeRead $Provider Identity @{} `
                    $readConfig ([ref]$reads) $clock
                if ([string]$identity.id -ine
                        [string]$Config.expectedAccount.id -or
                    [string]$identity.descriptor -cne
                        [string]$Config.expectedAccount.descriptor) {
                    throw 'account-mismatch'
                }
                $first = Get-IntakePass $Provider $readConfig `
                    ([ref]$reads) $clock 1
                $envelope.pages.first = $first.pages
                $second = Get-IntakePass $Provider $readConfig `
                    ([ref]$reads) $clock 2
                $envelope.pages.second = $second.pages
                $envelope.gaps.duplicateEntries = $first.duplicates + $second.duplicates
                if ($first.seen.Count -ne $second.seen.Count) { throw 'mutable-page' }
                foreach ($key in $first.seen.Keys) {
                    if (-not $second.seen.ContainsKey($key) -or
                        $first.seen[$key].digest -cne $second.seen[$key].digest) {
                        throw 'mutable-page'
                    }
                }
                $envelope.populationKnown = $true
                $envelope.inventory.state = 'complete'
                $envelope.inventory.gaps = @('no-atomic-snapshot-token')
                $ids = @($first.seen.Keys | ForEach-Object { [int]$_ } | Sort-Object)
                $envelope.denominators.active = $ids.Count
                foreach ($id in $ids) {
                    $item = $first.seen[[string]$id].value
                    $ref = [string]$item.targetRef
                    if (-not $envelope.denominators.byTargetRef.ContainsKey($ref)) {
                        $envelope.denominators.byTargetRef[$ref] =
                            [ordered]@{ active = 0; nonDraft = 0; draft = 0 }
                    }
                    $bucket = $envelope.denominators.byTargetRef[$ref]
                    $bucket.active++
                    if ($item.isDraft) { $bucket.draft++; $envelope.denominators.draft++ }
                    else {
                        $bucket.nonDraft++; $envelope.denominators.nonDraft++
                        if ($ref -ceq 'refs/heads/master') { $envelope.denominators.eligible++ }
                        else { $envelope.denominators.outOfPolicy++ }
                    }
                }
                $nonDraftIds = @($ids | Where-Object {
                        -not $first.seen[[string]$_].value.isDraft
                    })
                $envelope.counts.discovered = $nonDraftIds.Count
                $envelope.inventory.discovered = $nonDraftIds.Count
                $envelope.inventory.active = $envelope.denominators.active
                $envelope.inventory.eligible = $envelope.denominators.eligible
                $envelope.inventory.excludedOtherTargets = @(
                    $nonDraftIds | Where-Object {
                        $first.seen[[string]$_].value.targetRef -cne 'refs/heads/master'
                    }
                ).Count
                $envelope.inventory.nonDraftExcludedOtherTargets =
                    $envelope.denominators.outOfPolicy
                $envelope.inventory.draft = $envelope.denominators.draft
                $envelope.inventory.nonDraft = $envelope.denominators.nonDraft
                $envelope.inventory.byTargetRef = $envelope.denominators.byTargetRef
                if ($envelope.gaps.duplicateEntries -gt 0) {
                    $envelope.inventory.gaps += 'duplicate-list-entries-reconciled'
                }
                $eligible = @($ids | Where-Object {
                        $item = $first.seen[[string]$_].value
                        -not $item.isDraft -and $item.targetRef -ceq 'refs/heads/master'
                    })
                $start = 0
                if ($previous -and $cursorBindingCompatible -and
                    $null -ne $previous.cursor.nextPullRequestId -and $eligible.Count -gt 0) {
                    $target = Assert-IntakeNumber $previous.cursor.nextPullRequestId cursor 1 ([int]::MaxValue)
                    while ($start -lt $eligible.Count -and $eligible[$start] -lt $target) { $start++ }
                    if ($start -eq $eligible.Count) { $start = 0 }
                }
                $selected = [Collections.Generic.HashSet[int]]::new()
                $selectedOrder = [Collections.Generic.List[int]]::new()
                $limit = [Math]::Min(
                    $eligible.Count, $effectiveMaximumHeads)
                for ($n = 0; $n -lt $limit; $n++) {
                    $candidate = $eligible[($start + $n) % $eligible.Count]
                    [void]$selected.Add($candidate)
                    $selectedOrder.Add($candidate)
                }
                if ($eligible.Count -gt 0) {
                    $envelope.cursor.nextPullRequestId =
                        $eligible[($start + $limit) % $eligible.Count]
                }
                $processingOrder = @($selectedOrder.ToArray()) +
                    @($nonDraftIds | Where-Object { -not $selected.Contains($_) })
                $selectedOrdinal = 0
                foreach ($id in $processingOrder) {
                    $item = $first.seen[[string]$id].value
                    $entry = [ordered]@{
                        pullRequestId = $id
                        targetRef = $item.targetRef
                        declaration = $null
                        declarationDigest = $null
                        state = 'pending'
                        reasonCode = 'not-selected'
                        discussion = $null
                        rules = @($Config.rules | ForEach-Object {
                                [ordered]@{ id = [string]$_.id; capability = [string]$_.capability
                                    state = 'pending'; reasonCode = 'not-selected'
                                    observationDigest = $null; observation = $null
                                    priorObservation = $null; writerEligible = $false
                                    identityDigest = $null }
                            })
                    }
                    if ($item.targetRef -cne 'refs/heads/master') {
                        $entry.state = 'skipped'
                        $entry.reasonCode = 'target-out-of-policy'
                        foreach ($ruleResult in $entry.rules) {
                            $ruleResult.state = 'skipped'
                            $ruleResult.reasonCode = $entry.reasonCode
                        }
                        $envelope.counts.skipped++
                    }
                    elseif (-not $selected.Contains($id)) {
                        $envelope.counts.deferred++
                        $envelope.gaps.deferred++
                    }
                    else {
                        $envelope.counts.attempted++
                        $remainingSelected =
                            $selectedOrder.Count - $selectedOrdinal
                        $remainingStageMilliseconds =
                            [long]($effectiveMaximumSeconds * 1000) -
                            $clock.ElapsedMilliseconds
                        $headDeadlineMilliseconds =
                            $clock.ElapsedMilliseconds +
                            [Math]::Max(
                                1,
                                [long][Math]::Floor(
                                    $remainingStageMilliseconds /
                                    $remainingSelected))
                        $selectedOrdinal++
                        try {
                            $before = Assert-IntakeHead (
                                Invoke-IntakeRead $Provider Head @{
                                    pullRequestId = $id
                                } $readConfig ([ref]$reads) $clock `
                                    $headDeadlineMilliseconds
                            ) $id $Config
                            $entry.targetRef = $before.targetRef
                            $entry.declaration = $before
                            $entry.declarationDigest = Get-IntakeDigest $before
                            foreach ($ruleResult in $entry.rules) {
                                $ruleResult.identityDigest = Get-IntakeRuleIdentity `
                                    $before $ruleResult.id $ruleResult.capability `
                                    $envelope.binding.configDigest
                            }
                            if ($before.status -cne 'active' -or $before.isDraft -or
                                $before.targetRef -cne 'refs/heads/master') {
                                $entry.state = 'unknown'
                                $entry.reasonCode = 'head-left-policy-drift'
                                foreach ($ruleResult in $entry.rules) {
                                    $ruleResult.state = 'unknown'
                                    $ruleResult.reasonCode = 'head-left-policy-drift'
                                }
                                $envelope.counts.error++
                                $envelope.gaps.unknownHeads++
                                $envelope.gaps.unknownRules += $Config.rules.Count
                                $envelope.gaps.drift++
                            }
                            else {
                                foreach ($ruleResult in $entry.rules) {
                                    $ruleResult.priorObservation = Get-IntakePriorObservation `
                                        $previous $id $ruleResult.id $ruleResult.capability `
                                        $entry.declarationDigest $envelope.binding.configDigest
                                }
                                $progressPath = Join-Path `
                                    $fileProgressRoot "$id.json"
                                $priorProgress = $null
                                if (Test-Path -LiteralPath `
                                        $progressPath `
                                        -PathType Leaf) {
                                    $progressFile =
                                        Get-Item -LiteralPath `
                                            $progressPath -Force
                                    if ($progressFile.Attributes -band
                                            [IO.FileAttributes]::
                                                ReparsePoint -or
                                        $progressFile.Length -gt
                                            33554432) {
                                        throw 'file-progress-invalid'
                                    }
                                    [void](
                                        Assert-AgentTrustedFile `
                                            -Path $progressPath `
                                            -AllowedRoot `
                                                $fileProgressRoot `
                                            -Private)
                                    $priorProgress =
                                        Get-Content `
                                            -LiteralPath `
                                                $progressPath `
                                            -Raw |
                                        ConvertFrom-Json `
                                            -AsHashtable `
                                            -Depth 64
                                    if (
                                        [int]$priorProgress.
                                            schemaVersion -ne 2 -or
                                        [string]$priorProgress.kind -cne
                                            'active-pr-file-progress' -or
                                        [long]$priorProgress.
                                            pullRequestId -ne $id -or
                                        [string]$priorProgress.
                                            configDigest -cne
                                            [string]$envelope.
                                                binding.
                                                configDigest -or
                                        [string]$priorProgress.
                                            declarationDigest -cne
                                            [string]$entry.
                                                declarationDigest -or
                                        [int]$priorProgress.
                                            nextOrdinal -lt 1 -or
                                        [int]$priorProgress.
                                            nextOrdinal -gt 1999 -or
                                        [string]$priorProgress.
                                            evidencePlanDigest -cnotmatch
                                            '^[0-9a-f]{64}$' -or
                                        [int]$priorProgress.
                                            totalInventoryFiles -lt 1 -or
                                        $priorProgress.inventory -isnot
                                            [array] -or
                                        $priorProgress.entries -isnot
                                            [array]) {
                                        $priorProgress = $null
                                    }
                                }
                                $fileStartOrdinal = if (
                                    $null -ne $priorProgress) {
                                    [int]$priorProgress.
                                        nextOrdinal
                                }
                                else { 0 }
                                $lineBudgetConsumed = if (
                                    $null -ne $priorProgress) {
                                    [int]$priorProgress.
                                        changedLines
                                }
                                else { 0 }
                                $progressPending = $false
                                $progressRecord = $null
                                $removeProgress = $false
                                try {
                                $changes = Invoke-IntakeRead $Provider Changes @{
                                    pullRequestId = $id
                                    iterationId = $before.iterationId
                                    sourceCommit = $before.sourceCommit
                                    targetCommit = $before.targetCommit
                                    fileStartOrdinal =
                                        $fileStartOrdinal
                                    lineBudgetConsumed =
                                        $lineBudgetConsumed
                                } $readConfig ([ref]$reads) $clock `
                                    $headDeadlineMilliseconds
                                $files = Assert-IntakeNumber `
                                    $changes.changedFiles `
                                    changedFiles 0 `
                                    ([int]$Config.limits.
                                        maxChangedFiles)
                                $lines = $null
                                if ($null -ne $changes['changedLines']) {
                                    $lines = Assert-IntakeNumber $changes.changedLines changedLines 0 1000000
                                }
                                if ($null -eq $lines) {
                                    throw 'line-count-unavailable'
                                }
                                if ($changes.Contains(
                                        'fileProgress') -and
                                    $changes.fileProgress -is
                                        [Collections.IDictionary]) {
                                    $fileProgress =
                                        $changes.fileProgress
                                    if (
                                        [string]$fileProgress.
                                            inventoryDigest -cnotmatch
                                            '^[0-9a-f]{64}$' -or
                                        [string]$fileProgress.
                                            evidencePlanDigest -cnotmatch
                                            '^[0-9a-f]{64}$' -or
                                        [int]$fileProgress.
                                            totalFiles -lt 0 -or
                                        [int]$fileProgress.
                                            totalFiles -gt 2000 -or
                                        [int]$fileProgress.
                                            totalInventoryFiles -lt 1 -or
                                        [int]$fileProgress.
                                            totalInventoryFiles -gt 2000 -or
                                        $changes.inventory -isnot
                                            [array] -or
                                        @($changes.inventory).Count -ne
                                            [int]$fileProgress.
                                                totalInventoryFiles -or
                                        [int]$fileProgress.
                                            startOrdinal -ne
                                            $fileStartOrdinal -or
                                        [int]$fileProgress.
                                            nextOrdinal -ne
                                            ($fileStartOrdinal +
                                                $files)) {
                                        throw 'file-progress-invalid'
                                    }
                                    $progressComplete =
                                        $false
                                    if (-not [bool]::TryParse(
                                            [string]$fileProgress.
                                                complete,
                                            [ref]$progressComplete)) {
                                        throw 'file-progress-invalid'
                                    }
                                    if ($null -ne
                                            $priorProgress -and
                                        (
                                            [string]$priorProgress.
                                                inventoryDigest -cne
                                                [string]$fileProgress.
                                                    inventoryDigest -or
                                            [string]$priorProgress.
                                                evidencePlanDigest -cne
                                                [string]$fileProgress.
                                                    evidencePlanDigest -or
                                            [int]$priorProgress.
                                                totalFiles -ne
                                                [int]$fileProgress.
                                                    totalFiles -or
                                            [int]$priorProgress.
                                                totalInventoryFiles -ne
                                                [int]$fileProgress.
                                                    totalInventoryFiles
                                        )) {
                                        throw 'file-progress-invalid'
                                    }
                                    $accumulatedEntries = @(
                                        $(if ($null -ne
                                            $priorProgress) {
                                            @($priorProgress.entries)
                                        }) +
                                        @($changes.entries)
                                    )
                                    $progressTrackingIds =
                                        [Collections.Generic.HashSet[int]]::new()
                                    foreach ($progressEntry in
                                        $accumulatedEntries) {
                                        if (-not
                                            $progressTrackingIds.Add(
                                                [int]$progressEntry.
                                                    changeTrackingId)) {
                                            throw 'file-progress-invalid'
                                        }
                                    }
                                    $expectedEntryCount =
                                        [int]$fileProgress.
                                            nextOrdinal
                                    if ($accumulatedEntries.Count -ne
                                            $expectedEntryCount) {
                                        throw 'file-progress-invalid'
                                    }
                                    $contextByDigest =
                                        [ordered]@{}
                                    foreach ($context in @(
                                        $(if ($null -ne
                                            $priorProgress) {
                                            @($priorProgress.
                                                projectContexts)
                                        }) +
                                        @($changes.
                                            projectContexts)
                                    )) {
                                        $contextDigest =
                                            Get-IntakeDigest `
                                                $context
                                        $contextByDigest[
                                            $contextDigest] =
                                            $context
                                    }
                                    $totalBytes = 0L
                                    foreach ($progressEntry in
                                        $accumulatedEntries) {
                                        $totalBytes +=
                                            [long]$progressEntry.
                                                byteLength
                                    }
                                    if ([long]$totalBytes -gt
                                        16777216) {
                                        throw 'read-budget'
                                    }
                                    $progressRecord =
                                        [ordered]@{
                                            schemaVersion = 2
                                            kind =
                                                'active-pr-file-progress'
                                            pullRequestId = $id
                                            configDigest =
                                                [string]$envelope.
                                                    binding.
                                                    configDigest
                                            declarationDigest =
                                                [string]$entry.
                                                    declarationDigest
                                            inventoryDigest =
                                                [string]$fileProgress.
                                                    inventoryDigest
                                            evidencePlanDigest =
                                                [string]$fileProgress.
                                                    evidencePlanDigest
                                            totalFiles =
                                                [int]$fileProgress.
                                                    totalFiles
                                            totalInventoryFiles =
                                                [int]$fileProgress.
                                                    totalInventoryFiles
                                            nextOrdinal =
                                                [int]$fileProgress.
                                                    nextOrdinal
                                            changedLines =
                                                [int]$fileProgress.
                                                    cumulativeChangedLines
                                            totalBytes =
                                                [long]$totalBytes
                                            entries =
                                                $accumulatedEntries
                                            projectContexts =
                                                @($contextByDigest.
                                                    Values)
                                            inventory =
                                                @($changes.inventory)
                                        }
                                    if (-not $progressComplete) {
                                        $progressPending = $true
                                    }
                                    else {
                                        if ($accumulatedEntries.
                                                Count -ne
                                            [int]$fileProgress.
                                                totalFiles) {
                                            throw 'file-progress-invalid'
                                        }
                                        $changes =
                                            [ordered]@{
                                                changedFiles =
                                                    $accumulatedEntries.
                                                        Count
                                                changedLines =
                                                    [int]$progressRecord.
                                                        changedLines
                                                entries =
                                                    $accumulatedEntries
                                                projectContexts =
                                                    @($contextByDigest.
                                                        Values)
                                                inventory =
                                                    @($progressRecord.
                                                        inventory)
                                            }
                                        $lines =
                                            [int]$progressRecord.
                                                changedLines
                                        $removeProgress = $true
                                    }
                                }
                                if (-not $progressPending) {
                                    $discussion = Invoke-IntakeRead $Provider Discussions @{
                                        pullRequestId = $id; iterationId = $before.iterationId
                                    } $readConfig ([ref]$reads) $clock `
                                        $headDeadlineMilliseconds
                                    $entry.discussion = Get-IntakeDiscussionCounts $discussion $Config $before
                                    $entry.rules = @()
                                    foreach ($rule in $Config.rules) {
                                        $result = [ordered]@{
                                            id = [string]$rule.id
                                            capability = [string]$rule.capability
                                            state = 'pending'
                                            reasonCode = 'no-evaluator'
                                            observationDigest = $null
                                            observation = $null
                                            priorObservation = Get-IntakePriorObservation `
                                                $previous $id ([string]$rule.id) ([string]$rule.capability) `
                                                $entry.declarationDigest $envelope.binding.configDigest
                                            writerEligible = $false
                                            identityDigest = Get-IntakeRuleIdentity `
                                                $before ([string]$rule.id) ([string]$rule.capability) `
                                                $envelope.binding.configDigest
                                        }
                                        if ($result.priorObservation) {
                                            $result.reasonCode = if ($result.priorObservation.state -ceq 'stale') {
                                                'stale-observation'
                                            } else { 'no-new-observation' }
                                        }
                                        if ($entry.discussion.ambiguous -gt 0 -and
                                            -not (
                                                Test-IntakeUsesFindingScopedDiscussionReconciliation `
                                                    -Rule $rule
                                            )) {
                                            $result.state = 'unknown'
                                            $result.reasonCode = 'ambiguous-discussion'
                                        }
                                        $entry.rules += $result
                                    }
                                }
                                }
                                finally {
                                    $after = Assert-IntakeHead (
                                        Invoke-IntakeRead $Provider Head @{
                                            pullRequestId = $id
                                        } $readConfig ([ref]$reads) $clock `
                                            $headDeadlineMilliseconds
                                    ) $id $Config
                                    if ((Get-IntakeDigest $before) -cne (Get-IntakeDigest $after)) {
                                        throw 'head-drift'
                                    }
                                }
                                if ($progressPending) {
                                    $progressBytes =
                                        [Text.UTF8Encoding]::new(
                                            $false).GetBytes(
                                            (ConvertTo-Json `
                                                -InputObject `
                                                    $progressRecord `
                                                -Depth 64))
                                    if ($progressBytes.Length -gt
                                        33554432) {
                                        throw 'read-budget'
                                    }
                                    $progressTemp =
                                        "$progressPath.new-" +
                                        [guid]::NewGuid().
                                            ToString('N')
                                    try {
                                        [IO.File]::WriteAllBytes(
                                            $progressTemp,
                                            $progressBytes)
                                        [IO.File]::Move(
                                            $progressTemp,
                                            $progressPath,
                                            $true)
                                    }
                                    finally {
                                        Remove-Item `
                                            -LiteralPath `
                                                $progressTemp `
                                            -Force `
                                            -ErrorAction `
                                                SilentlyContinue
                                    }
                                    [void](
                                        Assert-AgentTrustedFile `
                                            -Path $progressPath `
                                            -AllowedRoot `
                                                $fileProgressRoot `
                                            -Private)
                                    $entry.fileProgress =
                                        [ordered]@{
                                            inventoryDigest =
                                                [string]$progressRecord.
                                                    inventoryDigest
                                            evidencePlanDigest =
                                                [string]$progressRecord.
                                                    evidencePlanDigest
                                            totalFiles =
                                                [int]$progressRecord.
                                                    totalFiles
                                            inventoryFiles =
                                                [int]$progressRecord.
                                                    totalInventoryFiles
                                            processedFiles =
                                                [int]$progressRecord.
                                                    nextOrdinal
                                            remainingFiles =
                                                [int]$progressRecord.
                                                    totalFiles -
                                                [int]$progressRecord.
                                                    nextOrdinal
                                        }
                                    $entry.state = 'unknown'
                                    $entry.reasonCode =
                                        'file-progress-pending'
                                    foreach ($ruleResult in
                                        $entry.rules) {
                                        $ruleResult.state =
                                            'unknown'
                                        $ruleResult.reasonCode =
                                            'file-progress-pending'
                                    }
                                    $envelope.counts.error++
                                    $envelope.gaps.
                                        unknownHeads++
                                    $envelope.gaps.
                                        unknownRules +=
                                        $Config.rules.Count
                                }
                                if (-not $progressPending) {
                                    if ($removeProgress -and
                                        (Test-Path -LiteralPath `
                                            $progressPath)) {
                                        Remove-Item -LiteralPath `
                                            $progressPath -Force
                                    }
                                    if ($IncludeTransientSnapshots) {
                                        $transientSnapshots[[string]$id] =
                                            [ordered]@{
                                                schemaVersion = 1
                                                kind =
                                                    'active-pr-transient-snapshot'
                                                generation =
                                                    $envelope.generation
                                                head = $before
                                                changes = $changes
                                                discussions = $discussion
                                                sourceDigest =
                                                    Get-IntakeDigest (
                                                        [ordered]@{
                                                            head = $before
                                                            changes = $changes
                                                            discussions =
                                                                $discussion
                                                        })
                                            }
                                    }
                                    $envelope.counts.evaluatedRules += @(
                                        $entry.rules | Where-Object state -eq 'evaluated'
                                    ).Count
                                    $envelope.gaps.unknownRules += @(
                                        $entry.rules | Where-Object state -eq 'unknown'
                                    ).Count
                                    $envelope.gaps.staleRules += @(
                                        $entry.rules | Where-Object {
                                            $_.priorObservation -and
                                            $_.priorObservation.state -ceq 'stale' -and
                                            $_.state -cne 'evaluated'
                                        }
                                    ).Count
                                    $entry.state = 'pending'
                                    $entry.reasonCode = 'rules-incomplete'
                                }
                            }
                        }
                        catch {
                            $failure = $_.Exception
                            Save-IntakePrivateFailure `
                                -Root $root `
                                -RepositoryRoot $RepositoryRoot `
                                -Generation $envelope.generation `
                                -Exception $failure
                            $reason = [string]$failure.Message
                            if ($reason -cnotin @('invalid-head', 'head-drift',
                                    'head-inconsistent', 'file-budget',
                                    'line-budget', 'line-count-unavailable',
                                    'change-list-truncated', 'change-page-budget', 'invalid-discussions',
                                    'mutable-discussions', 'comment-budget', 'invalid-evaluator',
                                    'invalid-observation', 'item-content-unavailable',
                                    'read-budget', 'time-budget')) {
                                $reason = 'provider-inaccessible'
                            }
                            $entry.state = 'unknown'
                            $entry.reasonCode = $reason
                            $entry.rules = @($Config.rules | ForEach-Object {
                                    [ordered]@{ id = [string]$_.id; capability = [string]$_.capability
                                        state = 'unknown'; reasonCode = $reason
                                        observationDigest = $null; observation = $null
                                        writerEligible = $false
                                        identityDigest = if ($entry.declaration) {
                                            Get-IntakeRuleIdentity $entry.declaration `
                                                ([string]$_.id) ([string]$_.capability) `
                                                $envelope.binding.configDigest
                                        } else { $null }
                                        priorObservation = if ($entry.declarationDigest) {
                                            Get-IntakePriorObservation $previous $id ([string]$_.id) `
                                                ([string]$_.capability) $entry.declarationDigest `
                                                $envelope.binding.configDigest
                                        } else { $null } }
                                })
                            $envelope.counts.error++
                            $envelope.gaps.unknownHeads++
                            $envelope.gaps.unknownRules += $Config.rules.Count
                            $envelope.gaps.staleRules += @(
                                $entry.rules | Where-Object {
                                    $_.priorObservation -and
                                    $_.priorObservation.state -ceq 'stale'
                                }
                            ).Count
                            if ($reason -ceq 'head-drift') { $envelope.gaps.drift++ }
                        }
                    }
                    [void]$heads.Add($entry)
                }
                $pendingFileProgress = @(
                    $heads |
                        Where-Object {
                            [string]$_.reasonCode -ceq
                                'file-progress-pending'
                        } |
                        Sort-Object {
                            [int]$_.pullRequestId
                        })
                if ($pendingFileProgress.Count -gt 0) {
                    $envelope.cursor.nextPullRequestId =
                        [int]$pendingFileProgress[0].
                            pullRequestId
                }
                $envelope.state = if ($envelope.counts.error -gt 0 -or
                    $envelope.counts.deferred -gt 0 -or
                    $envelope.gaps.unknownRules -gt 0 -or
                    $envelope.gaps.staleRules -gt 0) {
                    'partial'
                } else { 'enumerated' }
        }
        catch {
            $failure = $_.Exception
            $originalReason = [string]$failure.Message
            Save-IntakePrivateFailure `
                -Root $root -RepositoryRoot $RepositoryRoot `
                -Generation $envelope.generation `
                -Exception $failure
            $reason = $originalReason
            if ($reason -cnotin @('account-mismatch', 'invalid-page', 'mutable-page',
                    'missing-page', 'page-budget', 'pr-budget', 'read-budget',
                    'time-budget', 'identity-read-inaccessible',
                    'identity-response-invalid')) {
                $reason = 'page-inaccessible'
            }
            $envelope.gaps.enumerationUnknown = 1
            $envelope.counts.error = 1
            $envelope.state = 'unknown'
            [void]$reasons.Add($reason)
        }
        $envelope.reasonCodes = @($reasons)
        if ($envelope.inventory.state -ceq 'unknown') {
            $envelope.inventory.gaps = @($reasons)
        }
        foreach ($head in $heads) {
            $head.sourceCommit = if ($head.declaration) {
                [string]$head.declaration.sourceCommit
            } else { $null }
            $head.targetCommit = if ($head.declaration) {
                [string]$head.declaration.targetCommit
            } else { $null }
            $head.iterationId = if ($head.declaration) {
                [int]$head.declaration.iterationId
            } else { $null }
            $head.status = if ($head.state -ceq 'evaluated') {
                'pending'
            } else { [string]$head.state }
            $head.evaluationStatus = [string]$head.state
            $head.reason = [string]$head.reasonCode
            foreach ($rule in $head.rules) {
                $rule.ruleId = [string]$rule.id
                $rule.capabilityId = [string]$rule.capability
                $rule.status = [string]$rule.state
                $rule.observationDeclarationDigest = if ($rule.state -ceq 'evaluated') {
                    [string]$head.declarationDigest
                } else { $null }
                $rule.observationGeneration = if ($rule.state -ceq 'evaluated') {
                    [string]$envelope.generation
                } else { $null }
                $rule.observationIdentityDigest = if ($rule.state -ceq 'evaluated') {
                    [string]$rule.identityDigest
                } else { $null }
            }
        }
        $envelope.heads = @($heads | Sort-Object { [int]$_['pullRequestId'] })
        if (@($envelope.heads | Where-Object reasonCode -eq 'line-count-unavailable').Count -gt 0) {
            $envelope.unmetCapabilities = @('changed-line-counts')
        }
        $aggregate = [Collections.Generic.List[object]]::new()
        foreach ($configuredRule in $Config.rules) {
            $ruleHeads = @($envelope.heads | ForEach-Object {
                    @($_.rules | Where-Object {
                            $_.id -ceq [string]$configuredRule.id
                        })
                })
            $ruleGaps = [Collections.Generic.List[string]]::new()
            if ($envelope.inventory.state -cne 'complete') {
                [void]$ruleGaps.Add('inventory-unknown')
            }
            foreach ($ruleResult in $ruleHeads) {
                if ($ruleResult.status -cne 'evaluated' -and
                    $ruleResult.status -cne 'skipped' -and
                    -not [string]::IsNullOrEmpty([string]$ruleResult.reasonCode) -and
                    -not $ruleGaps.Contains([string]$ruleResult.reasonCode)) {
                    [void]$ruleGaps.Add([string]$ruleResult.reasonCode)
                }
                if ($ruleResult.priorObservation -and
                    $ruleResult.priorObservation.state -ceq 'stale' -and
                    $ruleResult.status -cne 'evaluated' -and
                    -not $ruleGaps.Contains('stale-observation')) {
                    [void]$ruleGaps.Add('stale-observation')
                }
            }
            [void]$aggregate.Add([ordered]@{
                    capabilityId = [string]$configuredRule.capability
                    ruleId = [string]$configuredRule.id
                    discovered = $envelope.inventory.discovered
                    eligible = $envelope.inventory.eligible
                    evaluated = @($ruleHeads | Where-Object status -eq 'evaluated').Count
                    skipped = @($ruleHeads | Where-Object status -eq 'skipped').Count
                    error = @($ruleHeads | Where-Object status -eq 'unknown').Count
                    pending = @($ruleHeads | Where-Object status -eq 'pending').Count
                    gaps = @($ruleGaps | Sort-Object -Unique)
                })
        }
        $envelope.rules = @($aggregate)
        $gapCodes = [Collections.Generic.List[string]]::new()
        foreach ($reason in @($envelope.inventory.gaps) + @($reasons)) {
            if ($reason -and -not $gapCodes.Contains([string]$reason)) {
                [void]$gapCodes.Add([string]$reason)
            }
        }
        foreach ($pair in @(
                @('enumerationUnknown', 'inventory-unknown'),
                @('duplicateEntries', 'duplicate-list-entries-reconciled'),
                @('deferred', 'deferred'),
                @('unknownHeads', 'unknown-heads'),
                @('unknownRules', 'unknown-rules'),
                @('staleRules', 'stale-observation'),
                @('drift', 'head-drift')
            )) {
            if ($envelope.gaps[$pair[0]] -gt 0 -and
                -not $gapCodes.Contains([string]$pair[1])) {
                [void]$gapCodes.Add([string]$pair[1])
            }
        }
        if (@($aggregate | Where-Object { $_.pending -gt 0 }).Count -gt 0 -and
            -not $gapCodes.Contains('pending-rules')) {
            [void]$gapCodes.Add('pending-rules')
        }
        if ($envelope.unmetCapabilities.Count -gt 0 -and
            -not $gapCodes.Contains('line-count-unavailable')) {
            [void]$gapCodes.Add('line-count-unavailable')
        }
        $envelope.gapCounts = $envelope.gaps
        $envelope.gaps = @($gapCodes | Sort-Object -Unique)
        $envelope.observedUtc = [DateTime]::UtcNow.ToString('o')
        $envelope.readCount = $reads
        $serialized = ConvertTo-Json -InputObject $envelope -Depth 32
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($serialized)
        if ($bytes.Length -gt 8388608) { throw 'Intake envelope exceeds its durable size budget.' }
        $generationPath = Join-Path $generationRoot "$($envelope.generation).json"
        $generationTemp = Join-Path $generationRoot (
            "staging-$([guid]::NewGuid().ToString('N')).json")
        try {
            $stream = [IO.File]::Open($generationTemp, 'CreateNew', 'Write', 'None')
            try {
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
            }
            finally { $stream.Dispose() }
            [IO.File]::Move($generationTemp, $generationPath)
        }
        finally {
            if (Test-Path -LiteralPath $generationTemp) {
                Remove-Item -LiteralPath $generationTemp -Force
            }
        }
        $temp = Join-Path $root ("cohort-$([guid]::NewGuid().ToString('N')).json")
        try {
            [IO.File]::WriteAllBytes($temp, $bytes)
            [IO.File]::Move($temp, $path, $true)
        }
        finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
        if ($IncludeTransientSnapshots) {
            $envelope['transientSnapshots'] =
                $transientSnapshots
        }
        return $envelope
    }
    finally { $lock.Dispose() }
}

function Resolve-ActivePrHeadSnapshot {
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$PullRequest,
        [Parameter(Mandatory)]
        [object[]]$Iterations,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$SourceRefs
    )
    if ($Iterations.Count -eq 0 -or
        $Iterations.Count -gt 200) {
        throw 'iteration-inaccessible'
    }
    $latest = $Iterations |
        Sort-Object { [int]$_.id } |
        Select-Object -Last 1
    $sourceRef = [string]$PullRequest.sourceRefName
    $sourceCommit =
        [string]$latest.sourceRefCommit.commitId
    $targetCommit =
        [string]$latest.targetRefCommit.commitId
    if ($sourceRef -cnotmatch '^refs/heads/.+' -or
        $sourceCommit -cnotmatch '^[a-fA-F0-9]{40}$' -or
        $targetCommit -cnotmatch '^[a-fA-F0-9]{40}$') {
        throw 'head-inconsistent'
    }
    $exactRefs = @($SourceRefs | Where-Object {
            $_ -is [Collections.IDictionary] -and
            [string]$_.name -ceq $sourceRef -and
            [string]$_.objectId -cmatch
                '^[a-fA-F0-9]{40}$'
        })
    if ($exactRefs.Count -ne 1 -or
        [string]$exactRefs[0].objectId -ine
            $sourceCommit) {
        throw 'head-inconsistent'
    }
    return [ordered]@{
        pullRequestId = $PullRequest.pullRequestId
        repositoryId = $PullRequest.repository.id
        projectId = $PullRequest.repository.project.id
        status = $PullRequest.status
        isDraft = $PullRequest.isDraft
        sourceRef = $sourceRef
        targetRef = $PullRequest.targetRefName
        sourceCommit = $sourceCommit
        targetCommit = $targetCommit
        iterationId = $latest.id
    }
}

function Resolve-ActivePrIterationChangePath {
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Entry
    )
    if ($Entry.item -isnot
            [Collections.IDictionary]) {
        throw 'change-list-truncated'
    }
    $changeType = [string]$Entry.changeType
    $itemPath = [string]$Entry.item.path
    $originalPath = if (
        $null -ne $Entry['originalPath']) {
        [string]$Entry.originalPath
    }
    else { '' }
    if ($itemPath -match '^/.+') {
        return $itemPath.TrimStart('/')
    }
    if ($changeType -match '(?i)^delete' -and
        $originalPath -match '^/.+') {
        return $originalPath.TrimStart('/')
    }
    throw 'change-list-truncated'
}

function Get-ActivePrSharedEvidencePlan {
    param(
        [Parameter(Mandatory)]
        [object[]]$Inventory
    )

    $plannedInventory =
        [Collections.Generic.List[object]]::new()
    $evidenceEntries =
        [Collections.Generic.List[object]]::new()
    foreach ($entry in $Inventory) {
        if ($entry -isnot [Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace(
                [string]$entry.path)) {
            throw 'change-list-truncated'
        }
        $path = ([string]$entry.path).Replace('\', '/')
        $originalPath = if (
            $null -ne $entry['originalPath']) {
            ([string]$entry.originalPath).Replace('\', '/')
        }
        else { '' }
        $paths = @($path, $originalPath | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            })
        $csharpPaths = @($paths | Where-Object {
                [IO.Path]::GetExtension($_) -ieq '.cs'
            })
        $nonGeneratedCSharp = @($csharpPaths | Where-Object {
                $_ -inotmatch (
                    '(^|/)(?:obj|generated|' +
                    'Ignore-AddedForReferenceOnly)(/|$)|' +
                    '(?:\.g|\.designer)\.cs$')
            })
        $generatedCSharp = @($csharpPaths | Where-Object {
                $_ -imatch (
                    '(^|/)(?:obj|generated|' +
                    'Ignore-AddedForReferenceOnly)(/|$)|' +
                    '(?:\.g|\.designer)\.cs$')
            })
        $metadata = @($paths | Where-Object {
                $_ -imatch (
                    '(?:\.csproj|\.props|' +
                    'packages\.config)$')
            }).Count -gt 0
        $required = $nonGeneratedCSharp.Count -gt 0 -or
            $metadata
        $reason = if ($nonGeneratedCSharp.Count -gt 0) {
            'non-generated-csharp'
        }
        elseif ($metadata) {
            'contextual-project-metadata'
        }
        elseif ($generatedCSharp.Count -gt 0) {
            'generated-source-not-applicable'
        }
        else {
            'no-enabled-lane-requires-content'
        }
        $planned = [ordered]@{
            changeTrackingId =
                [int]$entry.changeTrackingId
            path = $path
            changeType =
                [string]$entry.changeType
            originalPath = $(if ($originalPath) {
                    $originalPath
                }
                else { $null })
            evidenceDisposition = $(if ($required) {
                    'required'
                }
                else { 'not-applicable' })
            evidenceReason = $reason
        }
        [void]$plannedInventory.Add($planned)
        if ($required) {
            [void]$evidenceEntries.Add($entry)
        }
    }
    return [ordered]@{
        schemaVersion = 1
        kind = 'shared-review-evidence-plan'
        inventory = $plannedInventory.ToArray()
        evidenceEntries = $evidenceEntries.ToArray()
        inventoryCount = $plannedInventory.Count
        evidenceCount = $evidenceEntries.Count
    }
}

function Test-ActivePrEvidenceTextPath {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $normalized = $Path.Replace('\', '/')
    return [IO.Path]::GetExtension($normalized) -ieq '.cs' -or
        $normalized -imatch (
            '(?:\.csproj|\.props|' +
            'packages\.config)$')
}

function New-ActivePrAzureDevOpsProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Config,
        [string]$AzureCliPath = 'az',
        [Parameter(DontShow)][string]$ConnectionDataToolPath = '',
        [Parameter(DontShow)][scriptblock]$HttpGetInvoker
    )
    Assert-IntakeConfig $Config
    $org = [string]$Config.organization
    $project = [string]$Config.projectName
    $projectId = [string]$Config.projectId
    $repo = [string]$Config.repositoryId
    $maxFiles = [int]$Config.limits.maxChangedFiles
    $maxThreads = [int]$Config.limits.maxThreads
    $parseNumber = ${function:Assert-IntakeNumber}
    $digestCommand = ${function:Get-IntakeDigest}
    $changedSpansCommand =
        ${function:Get-ApprovedOwnerV2ChangedSpans}
    $changeDerivationCommand =
        ${function:New-DevPilotChangeDerivation}
    $newTransportFailureCommand =
        ${function:New-IntakeTransportFailure}
    $copyFailureDataCommand =
        ${function:Copy-IntakeFailureData}
    $azureCliLaunchPlanCommand =
        ${function:Get-IntakeAzureCliLaunchPlan}
    $readCeiling = [int]$Config.limits.maxReads
    $transportReads = [pscustomobject]@{ Count = 0 }
    $connectionDataCommand = @'
import json
import os
import sys

config_root = os.environ.get('AZURE_CONFIG_DIR')
if not config_root:
    config_root = os.path.join(os.path.expanduser('~'), '.azure')
extension_root = os.path.join(
    config_root, 'cliextensions', 'azure-devops')
if not os.path.isdir(extension_root):
    raise RuntimeError('azure-devops extension unavailable')
sys.path.insert(0, extension_root)
from azext_devops.dev.common.services import get_connection_data

identity = get_connection_data(sys.argv[1]).authenticated_user
print(json.dumps({
    'authenticatedUser': {
        'id': identity.id,
        'descriptor': identity.subject_descriptor
    }
}))
'@
    $invoke = {
        param([string]$Area, [string]$Resource, [string[]]$Route,
            [string[]]$Query, [DateTime]$Deadline)
        if ($transportReads.Count -ge $readCeiling) { throw 'read-budget' }
        $transportReads.Count++
        $argv = if ($Area -ceq '__account__') {
            @('account', 'show', '--only-show-errors', '-o', 'json')
        }
        elseif ($Area -ceq '__token__') {
            @(
                'account', 'get-access-token',
                '--resource',
                '499b84ac-1321-427f-aa17-267ca6975798',
                '--only-show-errors',
                '-o', 'json'
            )
        }
        elseif ($Area -ceq '__connection__') {
            @('-I', '-c', $connectionDataCommand, $org)
        }
        elseif ($Area -ceq '__pull_requests__') {
            @(
                'repos', 'pr', 'list',
                '--organization', $org,
                '--project', $project,
                '--repository', $repo,
                '--status', 'active',
                '--skip', $Query[0],
                '--top', $Query[1],
                '--detect', 'false',
                '-o', 'json',
                '--only-show-errors'
            )
        }
        else {
            $arguments = @(
                'devops', 'invoke',
                '--organization', $org,
                '--area', $Area,
                '--resource', $Resource,
                '--http-method', 'GET',
                '--api-version', '7.1',
                '-o', 'json',
                '--only-show-errors'
            )
            if ($Route.Count) {
                $arguments += @('--route-parameters') + $Route
            }
            if ($Query.Count) {
                $arguments += @('--query-parameters') + $Query
            }
            $arguments
        }
        $transportStage = 'command-resolution'
        try {
            $requestedTool = $AzureCliPath
            if ($Area -ceq '__connection__') {
                if ($ConnectionDataToolPath) {
                    $requestedTool = $ConnectionDataToolPath
                }
                else {
                    $azureTools = @(Get-Command -Name $AzureCliPath `
                        -CommandType Application,ExternalScript `
                        -ErrorAction Stop)
                    if ($azureTools.Count -ne 1 -or
                        [IO.Path]::GetExtension(
                            $azureTools[0].Source) -cnotin @('.cmd', '.bat')) {
                        throw [InvalidOperationException]::new(
                            'read-inaccessible')
                    }
                    $requestedTool = Join-Path (
                        Split-Path -Parent (
                            Split-Path -Parent $azureTools[0].Source)
                    ) 'python.exe'
                }
            }
            $tools = @(Get-Command -Name $requestedTool `
                -CommandType Application,ExternalScript -ErrorAction Stop)
            if ($tools.Count -ne 1) {
                throw [InvalidOperationException]::new(
                    'read-inaccessible')
            }
            $tool = $tools[0]
            $transportStage = 'command-validation'
            $extension = [IO.Path]::GetExtension($tool.Source)
            $azureCliPlan = & $azureCliLaunchPlanCommand `
                -ToolSource $tool.Source -Arguments $argv
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            if ($null -ne $azureCliPlan) {
                $start.FileName = [string]$azureCliPlan.fileName
                foreach ($name in
                    $azureCliPlan.environmentVariablesToRemove) {
                    [void]$start.Environment.Remove($name)
                }
                foreach ($entry in $azureCliPlan.environment.GetEnumerator()) {
                    $start.Environment[[string]$entry.Key] =
                        [string]$entry.Value
                }
                foreach ($arg in $azureCliPlan.argumentList) {
                    $start.ArgumentList.Add([string]$arg)
                }
            }
            elseif ($extension -in @('.cmd', '.bat')) {
                [void]$start.Environment.Remove(
                    'AZURE_DEVOPS_EXT_PAT')
                [void]$start.Environment.Remove(
                    'SYSTEM_ACCESSTOKEN')
                if ($tool.Source -match '[%!"&|<>^]') {
                    throw 'read-inaccessible'
                }
                $start.FileName = $env:ComSpec
                $quoted = @($argv | ForEach-Object {
                        if ($_ -match '[%!"&|<>^]') {
                            throw 'read-inaccessible'
                        }
                        '"' + $_ + '"'
                    })
                $start.Arguments = (
                    '/d /s /c ""{0}" {1}"' -f
                    $tool.Source, ($quoted -join ' '))
            }
            elseif ($extension -eq '.ps1') {
                [void]$start.Environment.Remove(
                    'AZURE_DEVOPS_EXT_PAT')
                [void]$start.Environment.Remove(
                    'SYSTEM_ACCESSTOKEN')
                $start.FileName = (Get-Command pwsh `
                    -CommandType Application -ErrorAction Stop).Source
                foreach ($arg in @(
                        '-NoProfile',
                        '-NonInteractive',
                        '-File',
                        $tool.Source
                    ) + $argv) {
                    $start.ArgumentList.Add($arg)
                }
            }
            else {
                [void]$start.Environment.Remove(
                    'AZURE_DEVOPS_EXT_PAT')
                [void]$start.Environment.Remove(
                    'SYSTEM_ACCESSTOKEN')
                $start.FileName = $tool.Source
                foreach ($arg in $argv) {
                    $start.ArgumentList.Add($arg)
                }
            }
        }
        catch {
            throw (& $newTransportFailureCommand `
                -Message 'read-inaccessible' `
                -TransportStage $transportStage `
                -SourceException $_.Exception)
        }
        $remaining = [int][Math]::Max(1, ($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        $error = $null
        $stderrBytes = [byte[]]::new(0)
        $transportStage = 'process-start'
        try {
            if (-not $process.Start()) { throw 'read-inaccessible' }
            $transportStage = 'process-io'
            $outputBuffer = [byte[]]::new(8192)
            $errorBuffer = [byte[]]::new(4096)
            $output = [IO.MemoryStream]::new()
            $error = [IO.MemoryStream]::new()
            try {
                $outputRead = $process.StandardOutput.BaseStream.ReadAsync(
                    $outputBuffer, 0, $outputBuffer.Length)
                $errorRead = $process.StandardError.BaseStream.ReadAsync(
                    $errorBuffer, 0, $errorBuffer.Length)
                $errorBytes = 0
                while ($null -ne $outputRead -or $null -ne $errorRead) {
                    if ([DateTime]::UtcNow -ge $Deadline) {
                        if (-not $process.HasExited) { $process.Kill($true) }
                        throw 'time-budget'
                    }
                    $pending = [Collections.Generic.List[Threading.Tasks.Task]]::new()
                    if ($null -ne $outputRead) { $pending.Add($outputRead) }
                    if ($null -ne $errorRead) { $pending.Add($errorRead) }
                    $remaining = [int][Math]::Max(1,
                        ($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
                    $next = [Threading.Tasks.Task]::WhenAny($pending.ToArray())
                    if (-not $next.Wait($remaining)) {
                        if (-not $process.HasExited) { $process.Kill($true) }
                        throw 'time-budget'
                    }
                    $completed = $next.GetAwaiter().GetResult()
                    if ([object]::ReferenceEquals($completed, $outputRead)) {
                        $n = $outputRead.GetAwaiter().GetResult()
                        if ($n -eq 0) { $outputRead = $null }
                        else {
                            if ($output.Length + $n -gt 16777216) {
                                if (-not $process.HasExited) { $process.Kill($true) }
                                throw 'read-budget'
                            }
                            $output.Write($outputBuffer, 0, $n)
                            $outputRead = $process.StandardOutput.BaseStream.ReadAsync(
                                $outputBuffer, 0, $outputBuffer.Length)
                        }
                    }
                    else {
                        $n = $errorRead.GetAwaiter().GetResult()
                        if ($n -eq 0) { $errorRead = $null }
                        else {
                            $errorBytes += $n
                            if ($errorBytes -gt 65536) {
                                if (-not $process.HasExited) { $process.Kill($true) }
                                throw 'read-budget'
                            }
                            $error.Write($errorBuffer, 0, $n)
                            $errorRead = $process.StandardError.BaseStream.ReadAsync(
                                $errorBuffer, 0, $errorBuffer.Length)
                        }
                    }
                }
                $text = [Text.UTF8Encoding]::new($false, $true).GetString(
                    $output.ToArray())
            }
            finally {
                $output.Dispose()
            }
            $remaining = [int][Math]::Max(1,
                ($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $transportStage = 'process-exit'
            if (-not $process.WaitForExit($remaining)) {
                if (-not $process.HasExited) { $process.Kill($true) }
                throw 'time-budget'
            }
            $stderrBytes = $error.ToArray()
            if ($process.ExitCode -ne 0) {
                throw (& $newTransportFailureCommand `
                    -Message 'read-inaccessible' `
                    -TransportStage 'process-exit' `
                    -NativeExitCode $process.ExitCode `
                    -StderrBytes $stderrBytes)
            }
        }
        catch {
            if ([string]$_.Exception.Message -cin @(
                    'time-budget', 'read-budget', 'read-inaccessible')) {
                throw
            }
            throw (& $newTransportFailureCommand `
                -Message 'read-inaccessible' `
                -TransportStage $transportStage `
                -SourceException $_.Exception)
        }
        finally {
            if ($null -ne $error) { $error.Dispose() }
            $process.Dispose()
        }
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw (& $newTransportFailureCommand `
                -Message 'read-inaccessible' `
                -TransportStage 'response-empty' `
                -NativeExitCode 0 `
                -StderrBytes $stderrBytes)
        }
        try {
            $parsed = ConvertFrom-Json -InputObject $text `
                -AsHashtable -Depth 32 -NoEnumerate
            if ($Area -ceq '__pull_requests__') {
                if ($parsed -isnot [array]) {
                    throw 'page-response-invalid'
                }
                Write-Output -NoEnumerate $parsed
                return
            }
            return $parsed
        }
        catch {
            if ([string]$_.Exception.Message -ceq
                'page-response-invalid') {
                throw
            }
            throw 'response-invalid'
        }
    }.GetNewClosure()
    $tokenState = [pscustomobject]@{
        AccessToken = $null
    }
    $getAccessToken = {
        param([DateTime]$Deadline)
        if (-not [string]::IsNullOrWhiteSpace(
                [string]$tokenState.AccessToken)) {
            return [string]$tokenState.AccessToken
        }
        $response = & $invoke '__token__' '' @() @() $Deadline
        if ($response -isnot [Collections.IDictionary] -or
            [string]$response.accessToken -cnotmatch '^\S{100,}$') {
            throw 'identity-read-inaccessible'
        }
        $tokenState.AccessToken =
            [string]$response.accessToken
        return [string]$tokenState.AccessToken
    }.GetNewClosure()
    $invokeGitJsonGet = {
        param(
            [string]$PathAndQuery,
            [DateTime]$Deadline
        )
        if ($transportReads.Count -ge $readCeiling) {
            throw 'read-budget'
        }
        $token = & $getAccessToken $Deadline
        $remainingSeconds = [int][Math]::Max(
            1,
            [Math]::Ceiling(
                ($Deadline - [DateTime]::UtcNow).
                    TotalSeconds))
        $uri = (
            $org.TrimEnd('/') + '/' +
            [Uri]::EscapeDataString($project) +
            '/_apis/git/repositories/' +
            [Uri]::EscapeDataString($repo) +
            '/' + $PathAndQuery)
        $transportReads.Count++
        try {
            $request = @{
                Uri = $uri
                Method = 'Get'
                Headers = @{
                    Authorization = ('Bearer ' + $token)
                }
                TimeoutSec = $remainingSeconds
                UseBasicParsing = $true
            }
            $response = if ($null -eq $HttpGetInvoker) {
                Invoke-WebRequest @request
            }
            else {
                & $HttpGetInvoker @request
            }
        }
        catch {
            $failure = [InvalidOperationException]::new(
                'read-inaccessible')
            $failure.Data['transportStage'] =
                'http-response'
            $failure.Data['underlyingExceptionType'] =
                $_.Exception.GetType().Name
            if ($null -ne $_.Exception.Response) {
                $failure.Data['httpStatus'] =
                    [int]$_.Exception.Response.StatusCode
            }
            throw $failure
        }
        if ([long]$response.RawContentLength -lt 0 -or
            [long]$response.RawContentLength -gt
                16777216) {
            throw 'read-budget'
        }
        try {
            $content = ([string]$response.Content).
                TrimStart([char]0xFEFF)
            return ConvertFrom-Json `
                -InputObject $content `
                -AsHashtable -Depth 32
        }
        catch {
            throw 'response-invalid'
        }
    }.GetNewClosure()
    $invokeItemsGet = {
        param(
            [string]$Path,
            [string]$Commit,
            [DateTime]$Deadline,
            [switch]$Directory
        )
        if ($transportReads.Count -ge $readCeiling) {
            throw 'read-budget'
        }
        $token = & $getAccessToken $Deadline
        $remainingSeconds = [int][Math]::Max(
            1,
            [Math]::Ceiling(
                ($Deadline - [DateTime]::UtcNow).
                    TotalSeconds))
        $apiPath = if ($Path.StartsWith('/')) {
            $Path
        }
        else { "/$Path" }
        $query = [Collections.Generic.List[string]]::new()
        $query.Add(
            'api-version=7.1')
        $query.Add(
            'versionDescriptor.version=' +
            [Uri]::EscapeDataString($Commit))
        $query.Add(
            'versionDescriptor.versionType=commit')
        if ($Directory) {
            $query.Add(
                'scopePath=' +
                [Uri]::EscapeDataString($apiPath))
            $query.Add('recursionLevel=OneLevel')
            $query.Add('includeContentMetadata=true')
        }
        else {
            $query.Add(
                'path=' +
                [Uri]::EscapeDataString($apiPath))
            $query.Add('includeContent=true')
        }
        $projectSegment =
            [Uri]::EscapeDataString($project)
        $repositorySegment =
            [Uri]::EscapeDataString($repo)
        $uri = (
            $org.TrimEnd('/') + '/' +
            $projectSegment +
            '/_apis/git/repositories/' +
            $repositorySegment +
            '/items?' +
            ($query -join '&'))
        $transportReads.Count++
        try {
            $response = Invoke-WebRequest `
                -Uri $uri -Method Get `
                -Headers @{
                    Authorization = "Bearer $token"
                } `
                -TimeoutSec $remainingSeconds `
                -UseBasicParsing
        }
        catch {
            $failure = [InvalidOperationException]::new(
                'read-inaccessible')
            $failure.Data['transportStage'] =
                'http-response'
            $failure.Data['underlyingExceptionType'] =
                $_.Exception.GetType().Name
            if ($null -ne $_.Exception.Response) {
                $failure.Data['httpStatus'] =
                    [int]$_.Exception.Response.StatusCode
            }
            throw $failure
        }
        if ([long]$response.RawContentLength -lt 0 -or
            [long]$response.RawContentLength -gt
                16777216) {
            throw 'read-budget'
        }
        $content = ([string]$response.Content).
            TrimStart([char]0xFEFF)
        if ($Directory) {
            try {
                return $content |
                    ConvertFrom-Json -AsHashtable `
                        -Depth 32
            }
            catch {
                throw 'response-invalid'
            }
        }
        $contentType = @(
            $response.Headers['Content-Type']
        )[0]
        if ([string]::IsNullOrWhiteSpace(
                [string]$contentType)) {
            $contentType = 'application/octet-stream'
        }
        return [ordered]@{
            content = $content
            contentMetadata = [ordered]@{
                contentType = (
                    [string]$contentType).
                    Split(';')[0].Trim()
            }
        }
    }.GetNewClosure()
    $getItem = {
        param(
            [string]$Path,
            [string]$Commit,
            [DateTime]$Deadline
        )
        $response = & $invokeItemsGet `
            $Path $Commit $Deadline
        if ($response -isnot [Collections.IDictionary] -or
            -not $response.Contains('content') -or
            $response.content -isnot [string] -or
            $response.contentMetadata -isnot [Collections.IDictionary] -or
            -not $response.contentMetadata.Contains('contentType') -or
            $response.contentMetadata.contentType -isnot [string] -or
            [string]::IsNullOrWhiteSpace(
                [string]$response.contentMetadata.contentType) -or
            [Text.Encoding]::UTF8.GetByteCount(
                [string]$response.content) -gt 16777216) {
            throw 'item-content-unavailable'
        }
        return $response
    }.GetNewClosure()
    $getProjectContext = {
        param(
            [string]$Path,
            [string]$Commit,
            [DateTime]$Deadline
        )
        $directory = [IO.Path]::GetDirectoryName(
            $Path.Replace('/', [IO.Path]::DirectorySeparatorChar)).
            Replace([IO.Path]::DirectorySeparatorChar, '/')
        while (-not [string]::IsNullOrWhiteSpace($directory)) {
            $apiPath = if ($directory.StartsWith('/')) {
                $directory
            }
            else { "/$directory" }
            try {
                $response = & $invokeItemsGet `
                    $apiPath $Commit $Deadline `
                    -Directory
            }
            catch {
                return [ordered]@{
                    state = 'unknown'
                    reason = 'project-context-unavailable'
                }
            }
            $items = if ($response -is [Collections.IDictionary] -and
                $response.value -is [array]) {
                @($response.value)
            }
            elseif ($response -is [array]) {
                @($response)
            }
            else {
                return [ordered]@{
                    state = 'unknown'
                    reason = 'project-context-unavailable'
                }
            }
            $projects = @($items | Where-Object {
                    $_ -is [Collections.IDictionary] -and
                    -not [bool]$_.isFolder -and
                    [string]$_.path -match '(?i)\.csproj$' -and
                    [IO.Path]::GetDirectoryName(
                        ([string]$_.path).Replace(
                            '/', [IO.Path]::DirectorySeparatorChar)).
                        Replace(
                            [IO.Path]::DirectorySeparatorChar, '/').
                        TrimStart('/') -ceq
                        $apiPath.TrimStart('/')
                })
            if ($projects.Count -gt 1) {
                return [ordered]@{
                    state = 'unknown'
                    reason = 'project-context-ambiguous'
                }
            }
            if ($projects.Count -eq 1) {
                $projectPath = ([string]$projects[0].path).TrimStart('/')
                $item = & $getItem $projectPath $Commit $Deadline
                $content = [string]$item.content
                return [ordered]@{
                    state = 'complete'
                    path = $projectPath
                    content = $content
                    byteLength =
                        [Text.Encoding]::UTF8.GetByteCount($content)
                    sourceDigest = 'v1:sha256:' +
                        [Convert]::ToHexString(
                            [Security.Cryptography.SHA256]::HashData(
                                [Text.Encoding]::UTF8.GetBytes($content))).
                            ToLowerInvariant()
                }
            }
            $parent = [IO.Path]::GetDirectoryName(
                $directory.Replace(
                    '/', [IO.Path]::DirectorySeparatorChar))
            if ([string]::IsNullOrWhiteSpace($parent) -or
                $parent -ceq $directory) {
                break
            }
            $directory = $parent.Replace(
                [IO.Path]::DirectorySeparatorChar, '/')
        }
        return [ordered]@{
            state = 'unknown'
            reason = 'project-context-missing'
        }
    }.GetNewClosure()
    $resolveHeadSnapshot =
        ${function:Resolve-ActivePrHeadSnapshot}
    $resolveChangePath =
        ${function:Resolve-ActivePrIterationChangePath}
    $getSharedEvidencePlan =
        ${function:Get-ActivePrSharedEvidencePlan}
    $testEvidenceTextPath =
        ${function:Test-ActivePrEvidenceTextPath}
    $handler = {
        param([string]$Operation, [Collections.IDictionary]$Request)
        $budget = if ($null -ne $Request['timeoutMilliseconds']) {
            [int]$Request.timeoutMilliseconds
        } else { [int]$Config.limits.maxSeconds * 1000 }
        $deadline = [DateTime]::UtcNow.AddMilliseconds($budget)
        switch -CaseSensitive ($Operation) {
            Identity {
                try {
                    $account = & $invoke '__account__' '' @() @() $deadline
                }
                catch {
                    if ([string]$_.Exception.Message -cin @(
                            'time-budget', 'read-budget')) {
                        throw [string]$_.Exception.Message
                    }
                    if ([string]$_.Exception.Message -ceq
                        'response-invalid') {
                        throw 'identity-response-invalid'
                    }
                    $failure = [InvalidOperationException]::new(
                        'identity-read-inaccessible')
                    & $copyFailureDataCommand `
                        -Source $_.Exception -Destination $failure `
                        -IdentityStage account
                    throw $failure
                }
                if ($account -isnot [Collections.IDictionary] -or
                    $account.user -isnot [Collections.IDictionary] -or
                    -not $account.user.Contains('name') -or
                    $account.user.name -isnot [string] -or
                    [string]::IsNullOrWhiteSpace(
                        [string]$account.user.name)) {
                    throw 'identity-response-invalid'
                }
                try {
                    $connection = & $invoke '__connection__' `
                        '' @() @() $deadline
                }
                catch {
                    if ([string]$_.Exception.Message -cin @(
                            'time-budget', 'read-budget')) {
                        throw [string]$_.Exception.Message
                    }
                    if ([string]$_.Exception.Message -ceq
                        'response-invalid') {
                        throw 'identity-response-invalid'
                    }
                    $failure = [InvalidOperationException]::new(
                        'identity-read-inaccessible')
                    & $copyFailureDataCommand `
                        -Source $_.Exception -Destination $failure `
                        -IdentityStage connectionData
                    throw $failure
                }
                if ($connection -isnot [Collections.IDictionary] -or
                    -not $connection.Contains('authenticatedUser')) {
                    throw 'identity-response-invalid'
                }
                $identity = $connection.authenticatedUser
                if (
                    $identity -isnot [Collections.IDictionary] -or
                    -not $identity.Contains('id') -or
                    -not $identity.Contains('descriptor') -or
                    $identity.id -isnot [string] -or
                    $identity.descriptor -isnot [string] -or
                    [string]$identity.id -cnotmatch
                        '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
                    [string]::IsNullOrWhiteSpace(
                        [string]$identity.descriptor)) {
                    throw 'identity-response-invalid'
                }
                if ([string]$identity.id -ine
                        [string]$Config.expectedAccount.id -or
                    [string]$identity.descriptor -cne
                        [string]$Config.expectedAccount.descriptor) {
                    throw 'account-mismatch'
                }
                return @{
                    id = [string]$identity.id
                    descriptor = [string]$identity.descriptor
                    uniqueName = [string]$Config.expectedAccount.uniqueName
                }
            }
            ListPage {
                $listed = & $invoke '__pull_requests__' '' @() @(
                        [string]$Request.skip,
                        [string]$Request.top
                    ) $deadline
                if ($listed -isnot [array]) {
                    throw 'page-response-invalid'
                }
                $items = @($listed | ForEach-Object {
                        if ($_ -isnot [Collections.IDictionary] -or
                            -not $_.Contains('pullRequestId') -or
                            -not $_.Contains('status') -or
                            -not $_.Contains('isDraft') -or
                            -not $_.Contains('targetRefName') -or
                            -not $_.Contains('repository') -or
                            $_.repository -isnot
                                [Collections.IDictionary] -or
                            -not $_.repository.Contains('id') -or
                            -not $_.repository.Contains('project') -or
                            $_.repository.project -isnot
                                [Collections.IDictionary] -or
                            -not $_.repository.project.Contains('id')) {
                            throw 'page-response-invalid'
                        }
                        if ([string]$_.repository.id -ine $repo -or
                            [string]$_.repository.project.id -ine
                                $projectId) {
                            throw 'repository-mismatch'
                        }
                        @{ pullRequestId = $_.pullRequestId; status = $_.status
                            isDraft = $_.isDraft; targetRef = $_.targetRefName }
                    })
                return @{ items = $items; count = $items.Count }
            }
            Head {
                $id = [int]$Request.pullRequestId
                $r = & $invokeGitJsonGet (
                    'pullRequests/' +
                    [Uri]::EscapeDataString(
                        [string]$id) +
                    '?api-version=7.1') $deadline
                $iterations = & $invokeGitJsonGet (
                    'pullRequests/' +
                    [Uri]::EscapeDataString(
                        [string]$id) +
                    '/iterations?api-version=7.1') $deadline
                $list = @($iterations.value)
                $sourceRefName = [string]$r.sourceRefName
                if ($sourceRefName -cnotmatch
                    '^refs/heads/(?<filter>.+)$') {
                    throw 'head-inconsistent'
                }
                $refs = & $invokeGitJsonGet (
                    'refs?filter=' +
                    [Uri]::EscapeDataString(
                        "heads/$($Matches.filter)") +
                    '&includeStatuses=false' +
                    '&peelTags=false' +
                    '&api-version=7.1') $deadline
                return & $resolveHeadSnapshot `
                    -PullRequest $r `
                    -Iterations $list `
                    -SourceRefs @($refs.value)
            }
            Changes {
                $id = [int]$Request.pullRequestId
                $iteration = [int]$Request.iterationId
                $sourceCommit = [string]$Request.sourceCommit
                $targetCommit = [string]$Request.targetCommit
                $fileStartOrdinal = if (
                    $null -ne $Request['fileStartOrdinal']) {
                    & $parseNumber $Request['fileStartOrdinal'] `
                        fileStartOrdinal 0 1999
                }
                else { 0 }
                $lineBudgetConsumed = if (
                    $null -ne $Request['lineBudgetConsumed']) {
                    & $parseNumber $Request[
                        'lineBudgetConsumed'] `
                        lineBudgetConsumed 0 1000000
                }
                else { 0 }
                $maximumInventoryFiles = 2000
                if ($sourceCommit -cnotmatch '^[a-fA-F0-9]{40}$' -or
                    $targetCommit -cnotmatch '^[a-fA-F0-9]{40}$') {
                    throw 'invalid-head'
                }
                $skip = 0
                $seenChanges = [Collections.Generic.HashSet[int]]::new()
                $changeEntries = [Collections.Generic.List[object]]::new()
                $declaredTotal = $null
                $pageSize = 100
                $complete = $false
                for ($page = 0; $page -lt [int]$Config.limits.maxPages; $page++) {
                    $r = & $invoke 'git' 'pullRequestIterationChanges' @(
                        "project=$project", "repositoryId=$repo",
                        "pullRequestId=$id", "iterationId=$iteration") @(
                        "`$top=$pageSize", "`$skip=$skip", '$compareTo=0') $deadline
                    if ($r['changeEntries'] -isnot [array]) {
                        throw 'change-list-truncated'
                    }
                    $entries = @($r.changeEntries)
                    if ($entries.Count -gt $pageSize) { throw 'change-list-truncated' }
                    if ($null -ne $r['count'] -and
                        (& $parseNumber $r['count'] changeCount 0 $pageSize) -ne
                        $entries.Count) { throw 'change-list-truncated' }
                    if ($null -ne $r['totalCount']) {
                        $total = & $parseNumber $r['totalCount'] totalChanges 0 100000
                        if ($null -ne $declaredTotal -and $total -ne $declaredTotal) {
                            throw 'change-list-truncated'
                        }
                        if ($total -gt $maximumInventoryFiles) {
                            throw 'file-budget'
                        }
                        $declaredTotal = $total
                    }
                    if ($entries.Count -eq 0) {
                        if (($null -ne $declaredTotal -and
                                $seenChanges.Count -ne $declaredTotal) -or
                            ($null -ne $r['nextSkip'] -and
                                (& $parseNumber $r['nextSkip'] nextSkip 0 100000) -gt
                                $skip)) {
                            throw 'change-list-truncated'
                        }
                        $complete = $true
                        break
                    }
                    foreach ($entry in $entries) {
                        if ($entry -isnot [Collections.IDictionary] -or
                            $null -eq $entry['changeTrackingId'] -or
                            $entry.item -isnot [Collections.IDictionary]) {
                            throw 'change-list-truncated'
                        }
                        $path = & $resolveChangePath -Entry $entry
                        $trackingId = & $parseNumber $entry['changeTrackingId'] `
                            changeTrackingId 1 ([int]::MaxValue)
                        if (-not $seenChanges.Add($trackingId)) {
                            throw 'change-list-truncated'
                        }
                        [void]$changeEntries.Add([ordered]@{
                                changeTrackingId = $trackingId
                                path = $path
                                changeType = [string]$entry.changeType
                                originalPath = $(if (
                                    $null -ne $entry['originalPath']
                                ) {
                                    ([string]$entry.originalPath).
                                        TrimStart('/')
                                } else { $null })
                            })
                    }
                    if ($seenChanges.Count -gt
                        $maximumInventoryFiles) {
                        throw 'file-budget'
                    }
                    $next = $skip + $entries.Count
                    if ($null -ne $r['nextSkip']) {
                        $nextSkip = & $parseNumber $r['nextSkip'] nextSkip 0 100000
                        if ($nextSkip -ne 0 -and $nextSkip -ne $next) {
                            throw 'change-list-truncated'
                        }
                    }
                    if ($null -ne $declaredTotal -and $seenChanges.Count -gt
                        $declaredTotal) { throw 'change-list-truncated' }
                    $skip = $next
                }
                if (-not $complete) { throw 'change-page-budget' }
                $orderedChangeEntries = @(
                    $changeEntries |
                        Sort-Object path, changeTrackingId)
                $evidencePlan =
                    & $getSharedEvidencePlan `
                        -Inventory $orderedChangeEntries
                $evidenceChangeEntries =
                    @($evidencePlan.evidenceEntries)
                if ($evidenceChangeEntries.Count -gt 0 -and
                    $fileStartOrdinal -ge
                        $evidenceChangeEntries.Count) {
                    throw 'file-progress-invalid'
                }
                if ($evidenceChangeEntries.Count -eq 0 -and
                    $fileStartOrdinal -ne 0) {
                    throw 'file-progress-invalid'
                }
                $chunkFileLimit =
                    [Math]::Min($maxFiles, 16)
                $selectedChangeEntries = @(
                    $evidenceChangeEntries |
                        Select-Object `
                            -Skip $fileStartOrdinal `
                            -First $chunkFileLimit)
                $inventoryDigest =
                    & $digestCommand @(
                        $orderedChangeEntries |
                            ForEach-Object {
                                [ordered]@{
                                    changeTrackingId =
                                        [int]$_.changeTrackingId
                                    path = [string]$_.path
                                    changeType =
                                        [string]$_.changeType
                                    originalPath =
                                        $_.originalPath
                                }
                            })
                $evidencePlanDigest =
                    & $digestCommand @(
                        $evidencePlan.inventory |
                            ForEach-Object {
                                [ordered]@{
                                    changeTrackingId =
                                        [int]$_.changeTrackingId
                                    path = [string]$_.path
                                    changeType =
                                        [string]$_.changeType
                                    originalPath =
                                        $_.originalPath
                                    evidenceDisposition =
                                        [string]$_.evidenceDisposition
                                    evidenceReason =
                                        [string]$_.evidenceReason
                                }
                            })
                $normalized = [Collections.Generic.List[object]]::new()
                $projectContexts = @{}
                $projectContextByDirectory = @{}
                $changedLines = $lineBudgetConsumed
                $totalBytes = 0L
                foreach ($entry in $selectedChangeEntries) {
                    $changeType = [string]$entry.changeType
                    $deleted = $changeType -match '(?i)^delete'
                    $sourceUnavailable = $false
                    $sourceItem = if ($deleted) {
                        $null
                    }
                    else {
                        try {
                            & $getItem ([string]$entry.path) `
                                $sourceCommit $deadline
                        }
                        catch {
                            if ([int]$_.Exception.Data[
                                    'httpStatus'] -eq 404) {
                                $sourceUnavailable = $true
                                $null
                            }
                            else { throw }
                        }
                    }
                    if ($sourceUnavailable) {
                        $unknownChange = [ordered]@{
                            changeTrackingId =
                                [int]$entry.changeTrackingId
                            path = [string]$entry.path
                            changeType = $changeType
                            state = 'unknown'
                            unavailableReason =
                                'source-content-unavailable'
                            spans = @()
                            content = $null
                            byteLength = 0
                            sourceDigest =
                                & $digestCommand (
                                    [ordered]@{
                                        path =
                                            [string]$entry.path
                                        sourceCommit =
                                            $sourceCommit
                                        state =
                                            'source-unavailable'
                                    })
                            derivation =
                                & $changeDerivationCommand `
                                    -ChangeType $changeType `
                                    -IsText $false `
                                    -Deleted $false `
                                    -Renamed (
                                        $changeType -match
                                            '(?i)rename') `
                                    -SourceContent '' `
                                    -TargetContent '' `
                                    -Spans @() `
                                    -SourceCommit `
                                        $sourceCommit `
                                    -TargetCommit `
                                        $targetCommit
                        }
                        if ($changeType -match
                                '(?i)rename' -and
                            $entry.originalPath) {
                            $unknownChange['oldPath'] =
                                [string]$entry.originalPath
                        }
                        [void]$normalized.Add(
                            $unknownChange)
                        continue
                    }
                    $sourceContent = if ($null -eq $sourceItem) {
                        ''
                    }
                    else { [string]$sourceItem.content }
                    $contentType = if ($null -eq $sourceItem) {
                        ''
                    }
                    else { [string]$sourceItem.contentMetadata.contentType }
                    $isCSharp = [IO.Path]::GetExtension(
                        [string]$entry.path) -ieq '.cs'
                    $evidenceTextPath =
                        & $testEvidenceTextPath `
                            -Path ([string]$entry.path)
                    if (-not $evidenceTextPath -and
                        $entry.originalPath) {
                        $evidenceTextPath =
                            & $testEvidenceTextPath `
                                -Path ([string]$entry.originalPath)
                    }
                    $isText = $deleted -or
                        $contentType.StartsWith(
                            'text/', [StringComparison]::OrdinalIgnoreCase) -or
                        $evidenceTextPath
                    if (-not $isText) {
                        $binaryChange = [ordered]@{
                                changeTrackingId =
                                    [int]$entry.changeTrackingId
                                path = [string]$entry.path
                                changeType = $changeType
                                state = 'unknown'
                                unavailableReason = 'binary'
                                spans = @()
                                content = $null
                                byteLength = 0
                                sourceDigest = & $digestCommand ([ordered]@{
                                    path = [string]$entry.path
                                    sourceCommit = $sourceCommit
                                    state = 'binary'
                                })
                                derivation =
                                    & $changeDerivationCommand `
                                        -ChangeType $changeType `
                                        -IsText $false `
                                        -Deleted $deleted `
                                        -Renamed (
                                            $changeType -match
                                                '(?i)rename') `
                                        -SourceContent '' `
                                        -TargetContent '' `
                                        -Spans @() `
                                        -SourceCommit $sourceCommit `
                                        -TargetCommit $targetCommit
                            }
                        if ($changeType -match '(?i)rename' -and
                            $entry.originalPath) {
                            $binaryChange['oldPath'] =
                                [string]$entry.originalPath
                        }
                        [void]$normalized.Add($binaryChange)
                        continue
                    }
                    $targetUnavailable = $false
                    $targetContent = if ($deleted -or
                        $changeType -match '(?i)^add') {
                        ''
                    }
                    else {
                        $targetPath = if (
                            $changeType -match '(?i)rename' -and
                            $entry.originalPath
                        ) {
                            [string]$entry.originalPath
                        }
                        else { [string]$entry.path }
                        try {
                            $targetItem = & $getItem `
                                $targetPath $targetCommit `
                                $deadline
                            [string]$targetItem.content
                        }
                        catch {
                            if ([int]$_.Exception.Data[
                                    'httpStatus'] -eq 404) {
                                $targetUnavailable =
                                    $true
                                ''
                            }
                            else { throw }
                        }
                    }
                    if ($targetUnavailable) {
                        $bytes =
                            [Text.Encoding]::UTF8.
                                GetByteCount(
                                    $sourceContent)
                        if ($totalBytes + $bytes -gt
                            16777216) {
                            if ($normalized.Count -eq 0) {
                                throw 'read-budget'
                            }
                            break
                        }
                        $totalBytes += $bytes
                        $unknownChange = [ordered]@{
                            changeTrackingId =
                                [int]$entry.changeTrackingId
                            path = [string]$entry.path
                            changeType = $changeType
                            state = 'unknown'
                            unavailableReason =
                                'target-content-unavailable'
                            spans = @()
                            content = $sourceContent
                            byteLength = $bytes
                            sourceDigest =
                                'v1:sha256:' +
                                [Convert]::ToHexString(
                                    [Security.Cryptography.SHA256]::
                                        HashData(
                                        [Text.Encoding]::UTF8.
                                            GetBytes(
                                                $sourceContent))).
                                    ToLowerInvariant()
                            derivation =
                                & $changeDerivationCommand `
                                    -ChangeType $changeType `
                                    -IsText $false `
                                    -Deleted $false `
                                    -Renamed (
                                        $changeType -match
                                            '(?i)rename') `
                                    -SourceContent '' `
                                    -TargetContent '' `
                                    -Spans @() `
                                    -SourceCommit `
                                        $sourceCommit `
                                    -TargetCommit `
                                        $targetCommit
                        }
                        if ($changeType -match
                                '(?i)rename' -and
                            $entry.originalPath) {
                            $unknownChange['oldPath'] =
                                [string]$entry.originalPath
                        }
                        [void]$normalized.Add(
                            $unknownChange)
                        continue
                    }
                    $spans = @(& $changedSpansCommand `
                            -Path ([string]$entry.path) `
                            -ChangeType $changeType `
                            -SourceContent $sourceContent `
                            -TargetContent $targetContent |
                        ForEach-Object { $_ })
                    $generated = [string]$entry.path -imatch
                        '(^|[\\/])(?:obj|generated|Ignore-AddedForReferenceOnly)([\\/]|$)|(?:\.g|\.designer)\.cs$'
                    $reviewable = (
                        $isCSharp -and -not $generated) -or
                        [string]$entry.path -imatch
                            '(?:\.csproj|\.props|packages\.config)$'
                    $entryChangedLines = 0
                    if ($reviewable) {
                        foreach ($span in $spans) {
                            $entryChangedLines +=
                                [int]$span.endLine -
                                [int]$span.startLine + 1
                        }
                    }
                    $withinLineBudget =
                        $changedLines + $entryChangedLines -le
                            [int]$Config.limits.maxChangedLines
                    if ($withinLineBudget) {
                        $changedLines += $entryChangedLines
                    }
                    $bytes = [Text.Encoding]::UTF8.GetByteCount($sourceContent)
                    if ($totalBytes + $bytes -gt
                        16777216) {
                        if ($normalized.Count -eq 0) {
                            throw 'read-budget'
                        }
                        break
                    }
                    $totalBytes += $bytes
                    $normalizedChange = [ordered]@{
                            changeTrackingId = [int]$entry.changeTrackingId
                            path = [string]$entry.path
                            changeType = $changeType
                            state = $(if ($withinLineBudget) {
                                'complete'
                            } else { 'unknown' })
                            spans = @($(if ($withinLineBudget) {
                                $spans
                            } else { @() }) | ForEach-Object {
                                [ordered]@{
                                    startLine = [int]$_.startLine
                                    endLine = [int]$_.endLine
                                    state = 'complete'
                                    sourceDigest = 'v1:sha256:' +
                                        (& $digestCommand ([ordered]@{
                                            path = [string]$entry.path
                                            startLine = [int]$_.startLine
                                            endLine = [int]$_.endLine
                                            sourceCommit = $sourceCommit
                                        }))
                                }
                            })
                            unavailableReason = $(if (
                                $withinLineBudget) {
                                $null
                            } else {
                                'cap-exhausted'
                            })
                            content = $sourceContent
                            byteLength = $bytes
                            sourceDigest = 'v1:sha256:' +
                                [Convert]::ToHexString(
                                    [Security.Cryptography.SHA256]::HashData(
                                        [Text.Encoding]::UTF8.GetBytes(
                                            $sourceContent))).
                                    ToLowerInvariant()
                        }
                    $derivationSpans =
                        [object[]]@()
                    if ($withinLineBudget) {
                        $derivationSpans =
                            [object[]]$spans
                    }
                    $normalizedChange.derivation =
                        & $changeDerivationCommand `
                            -ChangeType $changeType `
                            -IsText $true `
                            -Deleted $deleted `
                            -Renamed (
                                $changeType -match
                                    '(?i)rename') `
                            -SourceContent $sourceContent `
                            -TargetContent $targetContent `
                            -Spans $derivationSpans `
                            -SourceCommit $sourceCommit `
                            -TargetCommit $targetCommit
                    if ($isCSharp) {
                        $sourceDirectory =
                            [IO.Path]::GetDirectoryName(
                                ([string]$entry.path).Replace(
                                    '/',
                                    [IO.Path]::DirectorySeparatorChar)).
                                Replace(
                                    [IO.Path]::DirectorySeparatorChar,
                                    '/')
                        $context = if (
                            $projectContextByDirectory.ContainsKey(
                                $sourceDirectory)) {
                            $projectContextByDirectory[
                                $sourceDirectory]
                        }
                        else {
                            $resolved = & $getProjectContext `
                                ([string]$entry.path) `
                                $sourceCommit $deadline
                            $projectContextByDirectory[
                                $sourceDirectory] = $resolved
                            $resolved
                        }
                        $contextKey = if (
                            [string]$context.state -ceq 'complete') {
                            [string]$context.path
                        }
                        else {
                            ([string]$entry.path) + '|' +
                                [string]$context.reason
                        }
                        if (-not $projectContexts.ContainsKey($contextKey)) {
                            $projectContexts[$contextKey] = $context
                        }
                        $normalizedChange['projectContext'] = $context
                    }
                    if ($changeType -match '(?i)rename' -and
                        $entry.originalPath) {
                        $normalizedChange['oldPath'] =
                            [string]$entry.originalPath
                    }
                    [void]$normalized.Add($normalizedChange)
                }
                $nextFileOrdinal =
                    $fileStartOrdinal +
                    $normalized.Count
                return @{
                    changedFiles = $normalized.Count
                    changedLines =
                        $changedLines -
                        $lineBudgetConsumed
                    entries = $normalized.ToArray()
                    projectContexts = @($projectContexts.Values)
                    inventory =
                        @($evidencePlan.inventory)
                    fileProgress = [ordered]@{
                        inventoryDigest =
                            $inventoryDigest
                        evidencePlanDigest =
                            $evidencePlanDigest
                        totalFiles =
                            $evidenceChangeEntries.Count
                        totalInventoryFiles =
                            $orderedChangeEntries.Count
                        startOrdinal =
                            $fileStartOrdinal
                        nextOrdinal =
                            $nextFileOrdinal
                        complete =
                            $nextFileOrdinal -ge
                                $evidenceChangeEntries.Count
                        cumulativeChangedLines =
                            $changedLines
                    }
                }
            }
            ReferenceFiles {
                $sourceCommit =
                    [string]$Request.sourceCommit
                $paths = @($Request.paths)
                if ($sourceCommit -cnotmatch
                        '^[a-fA-F0-9]{40}$' -or
                    $paths.Count -lt 1 -or
                    $paths.Count -gt 8 -or
                    @($paths | Sort-Object -Unique).
                        Count -ne $paths.Count) {
                    throw 'reference-file-request-invalid'
                }
                $references =
                    [Collections.Generic.List[object]]::new()
                $totalBytes = 0L
                foreach ($requestedPath in $paths) {
                    $path = ([string]$requestedPath).
                        Replace('\', '/').
                        TrimStart('/')
                    if ($path -cnotmatch
                            '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*\.cs$' -or
                        $path -imatch
                            '(^|/)(?:obj|generated|Ignore-AddedForReferenceOnly)(/|$)|(?:\.g|\.designer)\.cs$') {
                        throw 'reference-file-path-invalid'
                    }
                    $item = & $getItem `
                        $path $sourceCommit $deadline
                    $content = [string]$item.content
                    $bytes =
                        [Text.Encoding]::UTF8.
                            GetByteCount($content)
                    $totalBytes += $bytes
                    if ($totalBytes -gt 2097152) {
                        throw 'reference-file-budget'
                    }
                    $context =
                        & $getProjectContext `
                            $path $sourceCommit $deadline
                    [void]$references.Add(
                        [ordered]@{
                            changeTrackingId =
                                2000000000 +
                                $references.Count
                            path = $path
                            changeType = 'Edit'
                            state = 'complete'
                            spans = @()
                            unavailableReason =
                                $null
                            content = $content
                            byteLength = $bytes
                            sourceDigest =
                                'v1:sha256:' +
                                [Convert]::ToHexString(
                                    [Security.Cryptography.SHA256]::HashData(
                                        [Text.Encoding]::UTF8.GetBytes(
                                            $content))).
                                    ToLowerInvariant()
                            projectContext =
                                $context
                            contextOnly = $true
                        })
                }
                return [ordered]@{
                    schemaVersion = 1
                    sourceCommit = $sourceCommit
                    entries =
                        $references.ToArray()
                }
            }
            Discussions {
                $id = [int]$Request.pullRequestId
                $r = & $invoke 'git' 'pullRequestThreads' @(
                    "project=$project", "repositoryId=$repo", "pullRequestId=$id") @() $deadline
                $threads = @($r.value)
                if ($threads.Count -gt $maxThreads -or
                    ($null -ne $r['count'] -and $r['count'] -ne $threads.Count)) {
                    throw 'discussion-list-truncated'
                }
                return @{ threads = $threads; count = $threads.Count }
            }
            default { throw 'unsupported-operation' }
        }
    }.GetNewClosure()
    return $handler
}

Export-ModuleMember -Function Invoke-ActivePrIntake, New-ActivePrAzureDevOpsProvider
