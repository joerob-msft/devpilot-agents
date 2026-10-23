#requires -Version 7.0

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo `
            'src\DevPilot.PullRequestLifecycle\DevPilot.PullRequestLifecycle.psd1') `
        -Force
    Import-Module (Join-Path $repo `
            'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1') `
        -Force
    $config = Get-Content (Join-Path $repo `
            'samples\active-pr-intake.config.json') -Raw |
        ConvertFrom-Json -AsHashtable -Depth 64
    $config.enabled = $true
    $config['subjectProvider'] = [ordered]@{
        maximumReads = 128
    }
    $policy = New-StalePrLifecyclePolicy `
        -Config $config -RepoRoot $repo -AllowDirty
    $script:roots = [Collections.Generic.List[string]]::new()

    function New-LifecycleRoot {
        $root = Join-Path $env:USERPROFILE (
            '.copilot\stale-pr-lifecycle-pester-' +
            [guid]::NewGuid().ToString('N'))
        [void]$script:roots.Add($root)
        $context = Initialize-StalePrLifecycleRoot `
            -DeliveryRoot $root -RepoRoot $repo
        return [pscustomobject]@{
            Context = $context
            Key = Get-StalePrLifecycleKey `
                -LifecycleRoot $context.Root
        }
    }

    function New-LifecycleEvidence {
        param(
            [long]$Id = 1,
            [string]$CreationUtc = '2024-01-01T00:00:00Z',
            [string]$ActivityUtc = '2024-12-01T00:00:00Z',
            [string]$Status = 'active',
            [bool]$Complete = $true,
            [int]$IterationId = 1,
            [string]$SourceCommit = ('a' * 40)
        )
        return [ordered]@{
            schemaVersion = 1
            projectId = [string]$config.projectId
            repositoryId = [string]$config.repositoryId
            pullRequestId = $Id
            status = $Status
            isDraft = $false
            sourceRef = "refs/heads/feature-$Id"
            targetRef = 'refs/heads/master'
            sourceCommit = $SourceCommit
            targetCommit = 'b' * 40
            iterationId = $IterationId
            creationUtc = $CreationUtc
            latestActivityUtc = $ActivityUtc
            activityDigest =
                'v1:sha256:' +
                $IterationId.ToString('x').PadLeft(64, '0')
            complete = $Complete
        }
    }

    function New-LifecycleProvider {
        param(
            [Parameter(Mandatory)]
            [Collections.IDictionary]$EvidenceById,
            [Collections.IDictionary]$SecondEvidenceById = @{},
            [long[]]$AmbiguousWriteIds = @(),
            [Collections.IDictionary]$EvidenceFailureById = @{},
            [Collections.IDictionary]$SecondEvidenceFailureById = @{}
        )
        $calls = [Collections.Generic.List[string]]::new()
        $reads = @{}
        $statuses = @{}
        $normalizedEvidence = @{}
        foreach ($key in $EvidenceById.Keys) {
            $normalizedEvidence[[string]$key] =
                $EvidenceById[$key]
        }
        $normalizedSecondEvidence = @{}
        foreach ($key in $SecondEvidenceById.Keys) {
            $normalizedSecondEvidence[[string]$key] =
                $SecondEvidenceById[$key]
        }
        $normalizedFailure = @{}
        foreach ($key in $EvidenceFailureById.Keys) {
            $normalizedFailure[[string]$key] =
                [string]$EvidenceFailureById[$key]
        }
        $normalizedSecondFailure = @{}
        foreach ($key in $SecondEvidenceFailureById.Keys) {
            $normalizedSecondFailure[[string]$key] =
                [string]$SecondEvidenceFailureById[$key]
        }
        $ambiguous = [Collections.Generic.HashSet[long]]::new()
        foreach ($id in $AmbiguousWriteIds) {
            [void]$ambiguous.Add($id)
        }
        $handler = {
            param($Operation, $Arguments)
            $id = [long]$Arguments.pullRequestId
            [void]$calls.Add("$Operation`:$id")
            switch ($Operation) {
                Identity {
                    return [ordered]@{
                        id =
                            '33333333-3333-3333-3333-333333333333'
                        descriptor =
                            'aad.synthetic-service-account'
                        uniqueName =
                            'service@example.invalid'
                    }
                }
                ReadEvidence {
                    $key = [string]$id
                    if (-not $reads.ContainsKey($key)) {
                        $reads[$key] = 0
                    }
                    $reads[$key]++
                    if ($reads[$key] -gt 1 -and
                        $normalizedSecondFailure.ContainsKey($key)) {
                        throw $normalizedSecondFailure[$key]
                    }
                    if ($reads[$key] -eq 1 -and
                        $normalizedFailure.ContainsKey($key)) {
                        throw $normalizedFailure[$key]
                    }
                    if ($reads[$key] -gt 1 -and
                        $normalizedSecondEvidence.ContainsKey($key)) {
                        $second =
                            $normalizedSecondEvidence[$key]
                        if ($second -is [Exception]) {
                            throw $second
                        }
                        return $second
                    }
                    $current = $normalizedEvidence[$key]
                    if ($current -is [Exception]) {
                        throw $current
                    }
                    return $current
                }
                AbandonStatus {
                    if (-not $ambiguous.Contains($id)) {
                        $statuses[$id] = 'abandoned'
                    }
                    else {
                        throw 'synthetic-timeout-after-send'
                    }
                    return @{ status = 'abandoned' }
                }
                ReadStatus {
                    return @{
                        pullRequestId = $id
                        status = $(if ($statuses.ContainsKey($id)) {
                                [string]$statuses[$id]
                            } else { 'active' })
                    }
                }
                default { throw "unexpected:$Operation" }
            }
        }.GetNewClosure()
        return [pscustomobject]@{
            Handler = $handler
            Calls = $calls
        }
    }

    function Invoke-LifecycleCase {
        param(
            [Parameter(Mandatory)][object[]]$Inventory,
            [Parameter(Mandatory)][scriptblock]$Provider,
            [DateTime]$CutoffUtc =
                ([DateTime]::SpecifyKind(
                    [DateTime]'2025-01-01T00:00:00',
                    [DateTimeKind]::Utc)),
            [Collections.IDictionary]$InputPolicy = $policy
        )
        $root = New-LifecycleRoot
        try {
            return Invoke-StalePrLifecycle `
                -Inventory $Inventory `
                -CutoffUtc $CutoffUtc `
                -Policy $InputPolicy `
                -LifecycleRoot $root.Context.Root `
                -Key $root.Key -Provider $Provider
        }
        finally {
            [Array]::Clear($root.Key, 0, $root.Key.Length)
        }
    }

    function New-AzLifecycleInvoker {
            param(
                [string]$PushUtc = '2024-12-01T00:00:00Z',
                [string]$SystemUtc = '2026-01-01T00:00:00Z',
                [string]$ActualCommentUtc = '',
                [switch]$MalformedComment,
                [switch]$NoIterations,
                [switch]$DuplicatePushId,
                [switch]$MissingSummaryPushDate,
                [ValidateSet(
                    'valid', 'missing', 'malformed',
                    'mismatched-id', 'mismatched-repository',
                    'mismatched-project')]
                [string]$PushDetail = 'valid',
                [AllowNull()][ref]$PushDetailReads,
                [AllowNull()][ref]$GetReads,
                [AllowNull()][ref]$PatchCalls,
                [AllowNull()]
                [Collections.Generic.List[object]]$RequestLog,
                [string]$SyntheticToken = ('t' * 120)
            )
            $handler = {
                param($Request)
                $uri = [uri]$Request.Uri
                $path = $uri.AbsolutePath
                $method = [string]$Request.Method
                if ($null -ne $RequestLog) {
                    [void]$RequestLog.Add([ordered]@{
                            uri = $uri.AbsoluteUri
                            method = $method
                            authorizationExact =
                                $Request.Headers.Contains(
                                    'Authorization') -and
                                [string]$Request.Headers.Authorization -ceq
                                    ('Bearer ' + $SyntheticToken)
                            authorizationWasPlaceholder =
                                [string]$Request.Headers.Authorization -ceq
                                    ('*' * 6)
                            contentType = $(if (
                                $Request.Contains('ContentType')
                            ) {
                                [string]$Request.ContentType
                            } else { $null })
                            bodyBase64 = $(if (
                                $Request.Contains('Body')
                            ) {
                                [Convert]::ToBase64String(
                                    [byte[]]$Request.Body)
                            } else { $null })
                        })
                }
                if ($path -clike '*/_apis/connectionData') {
                    return @{
                        authenticatedUser = @{
                            id = '33333333-3333-3333-3333-333333333333'
                            subjectDescriptor =
                                'aad.synthetic-service-account'
                        }
                        authorizedUser = @{
                            id = '33333333-3333-3333-3333-333333333333'
                            subjectDescriptor =
                                'aad.synthetic-service-account'
                        }
                    }
                }
                if ($method -ceq 'GET' -and
                    $null -ne $GetReads) {
                    $GetReads.Value++
                }
                if ($method -ceq 'PATCH' -and
                    $null -ne $PatchCalls) {
                    $PatchCalls.Value++
                }
                $pullRequestId = 1L
                if ($path -match
                    '/pullrequests/(?<id>[0-9]+)') {
                    $pullRequestId =
                        [long]$Matches.id
                }
                if ($method -ceq 'PATCH') {
                    return @{ status = 'abandoned' }
                }
                switch -Regex ($path) {
                    '/pullrequests/[0-9]+$' {
                        return @{
                            pullRequestId = $pullRequestId
                            status = 'active'
                            isDraft = $false
                            sourceRefName =
                                "refs/heads/feature-$pullRequestId"
                            targetRefName =
                                'refs/heads/master'
                            creationDate =
                                '2024-01-01T00:00:00Z'
                            lastMergeSourceCommit = @{
                                commitId = 'a' * 40
                            }
                            lastMergeTargetCommit = @{
                                commitId = 'b' * 40
                            }
                            repository = @{
                                id =
                                    '11111111-1111-1111-1111-111111111111'
                                project = @{
                                    id =
                                        '22222222-2222-2222-2222-222222222222'
                                }
                            }
                        }
                    }
                    '/pullrequests/[0-9]+/iterations$' {
                        if ($NoIterations) {
                            return @{
                                count = 0
                                continuation_token = $null
                                value = @()
                            }
                        }
                        $iterationRows = @(@{
                                id = 1
                                createdDate = $PushUtc
                                updatedDate = $PushUtc
                                push = @{
                                    pushId = 7
                                    date = $(if (
                                        $MissingSummaryPushDate
                                    ) { $null } else {
                                        $PushUtc
                                    })
                                }
                                sourceRefCommit = @{
                                    commitId = 'a' * 40
                                }
                                targetRefCommit = @{
                                    commitId = 'b' * 40
                                }
                            })
                        if ($DuplicatePushId) {
                            $iterationRows += @{
                                id = 2
                                createdDate = $PushUtc
                                updatedDate = $PushUtc
                                push = @{
                                    pushId = 7
                                    date = $null
                                }
                                sourceRefCommit = @{
                                    commitId = 'a' * 40
                                }
                                targetRefCommit = @{
                                    commitId = 'b' * 40
                                }
                            }
                        }
                        return @{
                            count = $iterationRows.Count
                            continuation_token = $null
                            value = $iterationRows
                        }
                    }
                    '/pullrequests/[0-9]+/threads$' {
                        $comments = @(@{
                                id = 1
                                parentCommentId = 0
                                commentType = 'system'
                                publishedDate = $SystemUtc
                                lastUpdatedDate = $SystemUtc
                                lastContentUpdatedDate =
                                    $SystemUtc
                            })
                        if ($ActualCommentUtc) {
                            $comments += @{
                                id = 2
                                parentCommentId = 0
                                commentType = 'text'
                                author = @{
                                    id = 'bot'
                                }
                                publishedDate =
                                    $ActualCommentUtc
                                lastUpdatedDate =
                                    $ActualCommentUtc
                                lastContentUpdatedDate =
                                    $(if ($MalformedComment) {
                                        $null
                                    } else {
                                        $ActualCommentUtc
                                    })
                            }
                        }
                        return @{
                            count = 1
                            continuation_token = $null
                            value = @(@{
                                    id = 10
                                    comments = $comments
                                })
                        }
                    }
                    '/refs$' {
                        return @{
                            count = 1
                            continuation_token = $null
                            value = @(@{
                                    name =
                                        "refs/heads/feature-$pullRequestId"
                                    objectId = 'a' * 40
                                })
                        }
                    }
                    '/pushes/[0-9]+$' {
                        if ($null -ne $PushDetailReads) {
                            $PushDetailReads.Value++
                        }
                        switch ($PushDetail) {
                            missing {
                                throw 'synthetic-push-missing'
                            }
                            malformed {
                                return @{
                                    pushId = 7
                                    date = 'not-a-date'
                                    repository = @{
                                        id = '11111111-1111-1111-1111-111111111111'
                                        project = @{
                                            id = '22222222-2222-2222-2222-222222222222'
                                        }
                                    }
                                }
                            }
                            'mismatched-id' {
                                return @{
                                    pushId = 8
                                    date = $PushUtc
                                    repository = @{
                                        id = '11111111-1111-1111-1111-111111111111'
                                        project = @{
                                            id = '22222222-2222-2222-2222-222222222222'
                                        }
                                    }
                                }
                            }
                            'mismatched-repository' {
                                return @{
                                    pushId = 7
                                    date = $PushUtc
                                    repository = @{
                                        id = '9' * 36
                                        project = @{
                                            id = '22222222-2222-2222-2222-222222222222'
                                        }
                                    }
                                }
                            }
                            'mismatched-project' {
                                return @{
                                    pushId = 7
                                    date = $PushUtc
                                    repository = @{
                                        id = '11111111-1111-1111-1111-111111111111'
                                        project = @{
                                            id = '9' * 36
                                        }
                                    }
                                }
                            }
                            default {
                                return @{
                                    pushId = 7
                                    date = $PushUtc
                                    repository = @{
                                        id = '11111111-1111-1111-1111-111111111111'
                                        project = @{
                                            id = '22222222-2222-2222-2222-222222222222'
                                        }
                                    }
                                }
                            }
                        }
                    }
                    default {
                        throw "unexpected-http:$method $uri"
                    }
                }
            }.GetNewClosure()
            return $handler
    }

    function New-TestAzureDevOpsLifecycleProvider {
        param(
            [Collections.IDictionary]$InputConfig = $config,
            [Parameter(Mandatory)]
            [scriptblock]$HttpInvoker,
            [AllowNull()][scriptblock]$UtcNowProvider
        )
        $arguments = @{
            Config = $InputConfig
            TokenInvoker = {
                @{ accessToken = 't' * 120 }
            }
            HttpInvoker = $HttpInvoker
        }
        if ($null -ne $UtcNowProvider) {
            $arguments.UtcNowProvider = $UtcNowProvider
        }
        return New-StalePrAzureDevOpsProvider @arguments
    }

    function New-ExplanationCase {
        param(
            [string]$Mode = 'confirmed',
            [int]$MaximumReads = 128,
            [switch]$StatusOnly,
            [string]$RecentActivity = ''
        )
        $caseConfig = $config | ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $caseConfig.subjectProvider.maximumReads = $MaximumReads
        $policyArguments = @{
            Config = $caseConfig
            RepoRoot = $repo
            AllowDirty = $true
            MaxAbandonsPerRun = 1
        }
        if ((Get-Command New-StalePrLifecyclePolicy).
            Parameters.ContainsKey('EnableAbandonmentExplanation')) {
            $policyArguments.EnableAbandonmentExplanation = -not $StatusOnly
        }
        $casePolicy = New-StalePrLifecyclePolicy @policyArguments
        $state = [pscustomobject]@{
            Status = 'active'
            StatusWrites = 0
            Posts = 0
            ExplanationReads = 0
            Body = ''
            Threads = @()
            Mode = $Mode
            Clock = [DateTime]::SpecifyKind(
                [DateTime]'2026-01-01T00:00:00', [DateTimeKind]::Utc)
            Requests = [Collections.Generic.List[object]]::new()
        }
        $baseHttp = New-AzLifecycleInvoker `
            -ActualCommentUtc $RecentActivity
        $http = {
            param($Request)
            $uri = [uri]$Request.Uri
            $path = $uri.AbsolutePath
            $method = [string]$Request.Method
            [void]$state.Requests.Add(@{
                    method = $method; path = $path
                })
            if ($method -ceq 'PATCH') {
                $state.StatusWrites++
                if ($state.Mode -ceq 'status-failed') {
                    throw 'synthetic-status-failure'
                }
                if ($state.Mode -cne 'status-unconfirmed') {
                    $state.Status = 'abandoned'
                }
                return @{ status = $state.Status }
            }
            if ($method -ceq 'POST') {
                $state.Posts++
                $body = [Text.Encoding]::UTF8.GetString(
                    [byte[]]$Request.Body) |
                    ConvertFrom-Json -AsHashtable
                @($body.Keys) | Should -HaveCount 1
                @($body.comments) | Should -HaveCount 1
                $body.comments[0].parentCommentId | Should -Be 0
                $body.comments[0].commentType | Should -Be 1
                $state.Body = [string]$body.comments[0].content
                $comment = @{
                    id = 1; parentCommentId = 0
                    commentType = 'text'
                    author = @{ id = $caseConfig.expectedAccount.id }
                    content = $state.Body
                    publishedDate = '2026-01-01T00:00:00Z'
                    lastUpdatedDate = '2026-01-01T00:00:00Z'
                    lastContentUpdatedDate = '2026-01-01T00:00:00Z'
                }
                if ($state.Mode -ceq 'wrong-body') {
                    $comment.content += ' altered'
                }
                if ($state.Mode -ceq 'wrong-author') {
                    $comment.author.id = '44444444-4444-4444-4444-444444444444'
                }
                if ($state.Mode -cnotin @('post-unknown', 'post-rejected')) {
                    $state.Threads = @(@{ id = 81; comments = @($comment) })
                }
                if ($state.Mode -ceq 'duplicate') {
                    $state.Threads += @{ id = 82; comments = @($comment) }
                }
                if ($state.Mode -ceq 'deadline-post') {
                    $state.Clock = $state.Clock.AddSeconds(241)
                }
                if ($state.Mode -cin @('post-unknown', 'post-accepted-error',
                        'post-rejected')) {
                    throw 'synthetic-comment-send-failure'
                }
                return @{ id = 81 }
            }
            $response = & $baseHttp $Request
            if ($method -ceq 'GET' -and
                $path -match '/pullrequests/[0-9]+$') {
                $response.status = $state.Status
            }
            if ($method -ceq 'GET' -and
                $path -match '/pullrequests/[0-9]+/threads$' -and
                $state.Status -ceq 'active' -and $state.Threads.Count -gt 0) {
                $response.value = @($response.value) + @($state.Threads)
                $response.count = @($response.value).Count
            }
            if ($method -ceq 'GET' -and
                $path -match '/pullrequests/[0-9]+/threads$' -and
                $state.Status -ceq 'abandoned') {
                $state.ExplanationReads++
                if ($state.Mode -ceq 'deadline-preflight') {
                    $state.Clock = $state.Clock.AddSeconds(241)
                }
                if ($state.Mode -ceq 'oversized-readback' -and
                    $state.Posts -gt 0) {
                    return [pscustomobject]@{
                        RawContentLength = 16777217L
                        Content = '{}'
                    }
                }
                if ($state.Mode -ceq 'readback-failed' -and
                    $state.Posts -gt 0) {
                    throw 'synthetic-comment-readback-failure'
                }
                return @{
                    count = $state.Threads.Count
                    continuation_token = $(if (
                        $state.Mode -ceq 'incomplete'
                    ) { 'more' } else { $null })
                    value = $state.Threads
                }
            }
            return $response
        }.GetNewClosure()
        $providerArguments = @{
            Config = $caseConfig
            TokenInvoker = { @{ accessToken = 't' * 120 } }
            HttpInvoker = $http
            UtcNowProvider = { $state.Clock }.GetNewClosure()
        }
        if ((Get-Command New-StalePrAzureDevOpsProvider).
            Parameters.ContainsKey('Policy')) {
            $providerArguments.Policy = $casePolicy
        }
        $nativeProvider = New-StalePrAzureDevOpsProvider @providerArguments
        $root = New-LifecycleRoot
        return @{
            Config = $caseConfig
            Policy = $casePolicy
            State = $state
            Root = $root
            Arguments = @{
                Inventory = @([ordered]@{
                        pullRequestId = 1
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc = '2024-01-01T00:00:00Z'
                    })
                CutoffUtc = [DateTime]::SpecifyKind(
                    [DateTime]'2025-01-01T00:00:00',
                    [DateTimeKind]::Utc)
                Policy = $casePolicy
                LifecycleRoot = $root.Context.Root
                Key = $root.Key
                Provider = $nativeProvider
            }
        }
    }
}

AfterAll {
    foreach ($root in $script:roots) {
        Remove-Item -LiteralPath $root -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}

Describe 'Stale PR lifecycle decision and transition' {
    It 'round-trips the separate signed lifecycle policy' {
        $root = New-LifecycleRoot
        try {
            $path = Join-Path $root.Context.Root `
                'policies\test-policy.json'
            [void](Write-StalePrLifecyclePolicy `
                -Path $path -Policy $policy `
                -Key $root.Key)
            $read = Read-StalePrLifecyclePolicy `
                -Path $path -Key $root.Key
        }
        finally {
            [Array]::Clear(
                $root.Key, 0, $root.Key.Length)
        }

        $read.kind | Should -BeExactly (
            'stale-pr-lifecycle-v1-service-' +
            'authorization-policy')
        $read.authority.action |
            Should -BeExactly 'status:abandoned'
    }

    It 'uses strict creation and inclusive activity boundaries' {
        $equalCreation = New-LifecycleEvidence `
            -CreationUtc '2025-01-01T00:00:00Z'
        $equalActivity = New-LifecycleEvidence -Id 2 `
            -ActivityUtc '2025-01-01T00:00:00Z'
        $provider = New-LifecycleProvider -EvidenceById @{
            1 = $equalCreation
            2 = $equalActivity
        }

        $result = Invoke-LifecycleCase -Provider $provider.Handler `
            -Inventory @(
                [ordered]@{
                    pullRequestId = 1
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2025-01-01T00:00:00Z'
                },
                [ordered]@{
                    pullRequestId = 2
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                })

        $result.providerWrites | Should -Be 1
        $result.confirmedAbandonedIds | Should -Be @(2)
        @($provider.Calls | Where-Object {
                $_ -ceq 'ReadEvidence:1'
            }) | Should -HaveCount 0
    }

    It 'uses UTC calendar-year subtraction across leap day' {
        $clock = [DateTime]::SpecifyKind(
            [DateTime]'2028-02-29T12:00:00',
            [DateTimeKind]::Utc)
        $clock.AddYears(-1).ToString('o') |
            Should -BeExactly '2027-02-28T12:00:00.0000000Z'
    }

    It 'does not let excluded metadata vote or system events refresh activity' {
        $evidence = New-LifecycleEvidence
        $evidence['excludedRecentEvents'] = @(
            'title-edit', 'description-edit',
            'reviewer-vote', 'system-vote-thread')
        $provider = New-LifecycleProvider -EvidenceById @{
            1 = $evidence
        }
        $result = Invoke-LifecycleCase -Provider $provider.Handler `
            -Inventory @([ordered]@{
                    pullRequestId = 1
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                })

        $result.confirmedAbandonedIds | Should -Be @(1)
    }

    It 'withholds recent push iteration comment reply and edit activity' `
        -TestCases @(
            @{ Kind = 'bot-comment' }
            @{ Kind = 'push' }
            @{ Kind = 'iteration' }
            @{ Kind = 'reply' }
            @{ Kind = 'comment-edit' }
        ) {
        param($Kind)
        $evidence = New-LifecycleEvidence `
            -ActivityUtc '2025-01-02T00:00:00Z'
        $evidence['activityKind'] = $Kind
        $provider = New-LifecycleProvider -EvidenceById @{
            1 = $evidence
        }
        $result = Invoke-LifecycleCase -Provider $provider.Handler `
            -Inventory @([ordered]@{
                    pullRequestId = 1
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                })

        $result.providerWrites | Should -Be 0
        $result.confirmedAbandonedIds | Should -BeNullOrEmpty
    }

    It 'returns UNKNOWN for incomplete missing or malformed evidence' `
        -TestCases @(
            @{ EvidenceKind = 'incomplete' }
            @{ EvidenceKind = 'missing' }
            @{ EvidenceKind = 'malformed' }
        ) {
        param($EvidenceKind)
        $evidence = switch ($EvidenceKind) {
            incomplete {
                New-LifecycleEvidence -Complete $false
                break
            }
            missing { $null; break }
            malformed {
                [ordered]@{ pullRequestId = 1 }
                break
            }
        }
        $provider = New-LifecycleProvider -EvidenceById @{
            1 = $evidence
        }
        $result = Invoke-LifecycleCase -Provider $provider.Handler `
            -Inventory @([ordered]@{
                    pullRequestId = 1
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                })

        $result.health | Should -BeExactly unknown
        $result.providerWrites | Should -Be 0
        $result.confirmedAbandonedIds | Should -BeNullOrEmpty
    }

    It 'withholds when relevant evidence changes immediately before write' {
        $first = New-LifecycleEvidence
        $second = New-LifecycleEvidence `
            -ActivityUtc '2025-01-02T00:00:00Z' `
            -IterationId 2 -SourceCommit ('c' * 40)
        $provider = New-LifecycleProvider `
            -EvidenceById @{ 1 = $first } `
            -SecondEvidenceById @{ 1 = $second }
        $result = Invoke-LifecycleCase -Provider $provider.Handler `
            -Inventory @([ordered]@{
                    pullRequestId = 1
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                })

        $result.providerWrites | Should -Be 0
        $result.decisions[0].reason |
            Should -BeExactly prewrite-race-withheld
    }

    It 'defers and stops scanning when read bounds are exhausted' `
        -TestCases @(
            @{
                Stage = 'decision'
                Reason = 'stale-pr-read-budget-exhausted'
            }
            @{
                Stage = 'decision'
                Reason = 'stale-pr-deadline-exhausted'
            }
            @{
                Stage = 'prewrite'
                Reason = 'stale-pr-read-budget-exhausted'
            }
            @{
                Stage = 'prewrite'
                Reason = 'stale-pr-deadline-exhausted'
            }
        ) {
        param($Stage, $Reason)
        $providerCalls =
            [Collections.Generic.List[string]]::new()
        $providerState =
            [pscustomobject]@{ Reads = 0 }
        $firstEvidence =
            New-LifecycleEvidence -Id 1
        $secondCandidateEvidence =
            New-LifecycleEvidence -Id 2
        $providerHandler = {
            param($Operation, $Arguments)
            $id = [long]$Arguments.pullRequestId
            [void]$providerCalls.Add(
                "$Operation`:$id")
            switch ($Operation) {
                Identity {
                    return [ordered]@{
                        id =
                            '33333333-3333-3333-3333-333333333333'
                        descriptor =
                            'aad.synthetic-service-account'
                        uniqueName =
                            'service@example.invalid'
                    }
                }
                ReadEvidence {
                    if ($id -eq 1) {
                        $providerState.Reads++
                        if (($Stage -ceq 'decision' -and
                                $providerState.Reads -eq 1) -or
                            ($Stage -ceq 'prewrite' -and
                                $providerState.Reads -eq 2)) {
                            throw $Reason
                        }
                        return $firstEvidence
                    }
                    return $secondCandidateEvidence
                }
                AbandonStatus {
                    throw 'exhaustion-test-write-forbidden'
                }
                ReadStatus {
                    throw 'exhaustion-test-readback-forbidden'
                }
                default {
                    throw "unexpected:$Operation"
                }
            }
        }.GetNewClosure()
        $result = Invoke-LifecycleCase `
            -Provider $providerHandler `
            -Inventory @(
                [ordered]@{
                    pullRequestId = 1
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                },
                [ordered]@{
                    pullRequestId = 2
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                })

        @($result.decisions) | Should -HaveCount 1 `
            -Because (
                $result | ConvertTo-Json -Depth 8 -Compress)
        $result.decisions[0].state |
            Should -BeExactly deferred
        $result.decisions[0].reason |
            Should -BeExactly $Reason
        $result.providerWrites | Should -Be 0
        @($providerCalls | Where-Object {
                $_ -ceq 'ReadEvidence:2'
            }) | Should -HaveCount 0
        @($providerCalls | Where-Object {
                $_ -like 'AbandonStatus:*'
            }) | Should -HaveCount 0
    }

    It 'treats an already abandoned reread as an idempotent no-op' {
        $provider = New-LifecycleProvider -EvidenceById @{
            1 = New-LifecycleEvidence -Status abandoned
        }
        $result = Invoke-LifecycleCase -Provider $provider.Handler `
            -Inventory @([ordered]@{
                    pullRequestId = 1
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                })

        $result.providerWrites | Should -Be 0
        $result.decisions[0].state | Should -BeExactly no-op
        $result.decisions[0].reason |
            Should -BeExactly already-abandoned
    }

    It 'does not retry an ambiguous PATCH or exclude it as abandoned' {
        $provider = New-LifecycleProvider `
            -EvidenceById @{
                1 = New-LifecycleEvidence
            } -AmbiguousWriteIds @(1)
        $result = Invoke-LifecycleCase -Provider $provider.Handler `
            -Inventory @([ordered]@{
                    pullRequestId = 1
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                })

        @($provider.Calls | Where-Object {
                $_ -ceq 'AbandonStatus:1'
            }) | Should -HaveCount 1
        $result.providerWrites | Should -Be 1
        $result.confirmedAbandonedIds | Should -BeNullOrEmpty
        $result.decisions[0].reason |
            Should -BeExactly ambiguous-post-write
    }

    It 'blocks later runs on a signed ambiguous prior write' {
        $provider = New-LifecycleProvider `
            -EvidenceById @{
                1 = New-LifecycleEvidence
            } -AmbiguousWriteIds @(1)
        $root = New-LifecycleRoot
        try {
            $arguments = @{
                Inventory = @([ordered]@{
                        pullRequestId = 1
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc = '2024-01-01T00:00:00Z'
                    })
                CutoffUtc = [DateTime]::SpecifyKind(
                    [DateTime]'2025-01-01T00:00:00',
                    [DateTimeKind]::Utc)
                Policy = $policy
                LifecycleRoot = $root.Context.Root
                Key = $root.Key
                Provider = $provider.Handler
            }
            $first = Invoke-StalePrLifecycle @arguments
            $directBlock = & (
                Get-Module DevPilot.PullRequestLifecycle) {
                param($Root, $Id, $InputKey)
                Get-StalePrPriorWriteBlock `
                    -LifecycleRoot $Root `
                    -PullRequestId $Id `
                    -Key $InputKey
            } $root.Context.Root 1 $root.Key
            $second = Invoke-StalePrLifecycle @arguments
        }
        finally {
            [Array]::Clear(
                $root.Key, 0, $root.Key.Length)
        }

        @($provider.Calls | Where-Object {
                $_ -ceq 'AbandonStatus:1'
            }) | Should -HaveCount 1
        $first.decisions[0].reason |
            Should -BeExactly ambiguous-post-write
        $directBlock |
            Should -BeExactly prior-ambiguous-write
        $second.providerWrites | Should -Be 0
        $second.decisions[0].reason |
            Should -BeExactly prior-ambiguous-write
    }

    It 'caps attempted lifecycle status writes at one per run' {
        $evidence = @{}
        $inventory = @(
            1..3 | ForEach-Object {
                $evidence[$_] = New-LifecycleEvidence -Id $_
                [ordered]@{
                    pullRequestId = $_
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                }
            })
        $provider = New-LifecycleProvider -EvidenceById $evidence
        $result = Invoke-LifecycleCase -Provider $provider.Handler `
            -Inventory $inventory

        $result.providerWrites | Should -Be 1
        $result.confirmedAbandonedIds | Should -Be @(1)
        @($result.decisions | Where-Object {
                [string]$_.reason -ceq 'run-cap-reached'
            }) | Should -HaveCount 2
    }

    It 'consumes actual-provider-shaped canonical evidence through prewrite' {
        $eligible = New-LifecycleEvidence `
            -Id 1637334 `
            -CreationUtc '2019-04-30T22:06:23Z' `
            -ActivityUtc '2020-01-01T00:00:00Z'
        $recent118 = New-LifecycleEvidence `
            -Id 1182097 `
            -CreationUtc '2018-10-25T00:30:22Z' `
            -ActivityUtc '2026-10-20T18:30:22Z'
        $recent120 = New-LifecycleEvidence `
            -Id 1200303 `
            -CreationUtc '2018-11-01T18:36:27Z' `
            -ActivityUtc '2026-10-20T18:45:00Z'
        $provider = New-LifecycleProvider -EvidenceById @{
            1637334 = $eligible
            1182097 = $recent118
            1200303 = $recent120
        }
        $result = Invoke-LifecycleCase `
            -Provider $provider.Handler `
            -CutoffUtc ([DateTime]::SpecifyKind(
                [DateTime]'2025-10-20T16:45:00',
                [DateTimeKind]::Utc)) `
            -Inventory @(
                [ordered]@{
                    pullRequestId = 1182097
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2018-10-25T00:30:22Z'
                },
                [ordered]@{
                    pullRequestId = 1200303
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2018-11-01T18:36:27Z'
                },
                [ordered]@{
                    pullRequestId = 1637334
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2019-04-30T22:06:23Z'
                })

        $eligible.activityDigest |
            Should -Match '^v1:sha256:[0-9a-f]{64}$'
        $result.providerWrites | Should -Be 1
        $result.confirmedAbandonedIds | Should -Be @(1637334)
        @($provider.Calls | Where-Object {
                $_ -ceq 'ReadEvidence:1637334'
            }) | Should -HaveCount 2
        @($provider.Calls | Where-Object {
                $_ -ceq 'AbandonStatus:1637334'
            }) | Should -HaveCount 1
        @($provider.Calls | Where-Object {
                $_ -like 'AbandonStatus:1182097' -or
                $_ -like 'AbandonStatus:1200303'
            }) | Should -HaveCount 0
    }

    It 'fails closed for a missing or malformed canonical activity prefix' `
        -TestCases @(
            @{ Digest = 'a' * 64 }
            @{ Digest = 'sha256:' + ('a' * 64) }
            @{ Digest = $null }
        ) {
        param($Digest)
        $evidence = New-LifecycleEvidence -Id 1637334
        $evidence.activityDigest = $Digest
        $provider = New-LifecycleProvider -EvidenceById @{
            1637334 = $evidence
        }
        $result = Invoke-LifecycleCase `
            -Provider $provider.Handler `
            -Inventory @([ordered]@{
                    pullRequestId = 1637334
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2019-04-30T22:06:23Z'
                })

        $result.providerWrites | Should -Be 0
        @($result.decisions) | Should -HaveCount 1
        $result.decisions[0].state | Should -BeExactly unknown
        $result.decisions[0].reason |
            Should -BeExactly activity-evidence-unknown
    }
}

Describe 'Stale lifecycle acquisition ordering' {
    It 'excludes only confirmed abandoned IDs before review head acquisition' {
        $caseConfig = Get-Content (Join-Path $repo `
                'samples\active-pr-intake.config.json') -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
        $caseConfig.enabled = $true
        $caseConfig.limits.pageSize = 10
        $caseConfig.limits.maxHeadsPerRun = 2
        $caseConfig.limits.maxReads = 100
        $calls = [Collections.Generic.List[string]]::new()
        $rows = @(1..2 | ForEach-Object {
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
            [void]$calls.Add("$Operation`:$($Request.pullRequestId)")
            switch ($Operation) {
                Identity {
                    return [ordered]@{} +
                        $caseConfig.expectedAccount
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
                        repositoryId =
                            $caseConfig.repositoryId
                        projectId = $caseConfig.projectId
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
                default { throw "unexpected:$Operation" }
            }
        }.GetNewClosure()
        $lifecycle = {
            param($Inventory)
            return [ordered]@{
                schemaVersion = 1
                kind = 'stale-pr-lifecycle-v1-run'
                health = 'healthy'
                providerWrites = 1
                modelWrites = 0
                confirmedAbandonedIds = @(1)
                reviewEligibleIds = @(2)
                nextPullRequestId = 2
                decisions = @()
                events = @()
            }
        }
        $root = Join-Path $env:USERPROFILE (
            '.copilot\stale-pr-intake-pester-' +
            [guid]::NewGuid().ToString('N'))
        [void]$script:roots.Add($root)
        $result = Invoke-ActivePrIntake `
            -Config $caseConfig -Provider $provider `
            -StateRoot $root -RepositoryRoot $repo `
            -MaximumHeadsThisRun 2 `
            -LifecycleEvaluator $lifecycle -Run

        @($calls | Where-Object {
                $_ -ceq 'Head:1'
            }) | Should -HaveCount 0
        @($calls | Where-Object {
                $_ -ceq 'Head:2'
            }).Count | Should -BeGreaterThan 0
        $result.lifecycle.confirmedAbandonedIds |
            Should -Be @(1)
    }

    It 'withholds old PR comments until lifecycle proves recent activity' {
        $caseConfig = $config |
            ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $caseConfig.limits.maxHeadsPerRun = 4
        $calls = [Collections.Generic.List[string]]::new()
        $rows = @(
            [ordered]@{
                pullRequestId = 1
                status = 'active'
                isDraft = $false
                targetRef = 'refs/heads/master'
                creationUtc = '2023-01-01T00:00:00Z'
            },
            [ordered]@{
                pullRequestId = 2
                status = 'active'
                isDraft = $false
                targetRef = 'refs/heads/master'
                creationUtc = '2023-01-01T00:00:00Z'
            },
            [ordered]@{
                pullRequestId = 3
                status = 'active'
                isDraft = $false
                targetRef = 'refs/heads/master'
                creationUtc = '2026-01-01T00:00:00Z'
            },
            [ordered]@{
                pullRequestId = 4
                status = 'active'
                isDraft = $false
                targetRef = 'refs/heads/master'
                creationUtc = '2023-01-01T00:00:00Z'
            },
            [ordered]@{
                pullRequestId = 5
                status = 'active'
                isDraft = $false
                targetRef = 'refs/heads/master'
                creationUtc = '2023-01-01T00:00:00Z'
            })
        $provider = {
            param($Operation, $Request)
            [void]$calls.Add(
                "$Operation`:$($Request.pullRequestId)")
            switch ($Operation) {
                Identity {
                    return [ordered]@{} +
                        $caseConfig.expectedAccount
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
                        repositoryId =
                            $caseConfig.repositoryId
                        projectId = $caseConfig.projectId
                        status = 'active'
                        isDraft = $false
                        sourceRef =
                            "refs/heads/feature-$id"
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
        $lifecycle = {
            param($Inventory)
            return [ordered]@{
                schemaVersion = 1
                kind = 'stale-pr-lifecycle-v1-run'
                runId = 'fixture'
                cutoffUtc = '2025-10-21T00:00:00.0000000Z'
                health = 'unknown'
                providerWrites = 1
                modelWrites = 0
                confirmedAbandonedIds = @(5)
                reviewEligibleIds = @(2, 3)
                nextPullRequestId = 4
                decisions = @(
                    [ordered]@{
                        pullRequestId = 1
                        state = 'unknown'
                        reason = 'prior-ambiguous-write'
                        providerWrites = 0
                    },
                    [ordered]@{
                        pullRequestId = 2
                        state = 'no-op'
                        reason = 'recent-activity'
                        providerWrites = 0
                    },
                    [ordered]@{
                        pullRequestId = 4
                        state = 'deferred'
                        reason =
                            'stale-pr-read-budget-exhausted'
                        providerWrites = 0
                    },
                    [ordered]@{
                        pullRequestId = 5
                        state = 'abandoned'
                        reason = 'readback-confirmed'
                        providerWrites = 1
                    })
                events = @()
            }
        }
        $root = Join-Path $env:USERPROFILE (
            '.copilot\stale-pr-gating-pester-' +
            [guid]::NewGuid().ToString('N'))
        [void]$script:roots.Add($root)
        $result = Invoke-ActivePrIntake `
            -Config $caseConfig -Provider $provider `
            -StateRoot $root -RepositoryRoot $repo `
            -MaximumHeadsThisRun 4 `
            -LifecycleEvaluator $lifecycle `
            -IncludeTransientSnapshots -Run

        @($calls | Where-Object {
                $_ -like 'Head:*'
            }) | Should -Be @('Head:2', 'Head:2',
                'Head:3', 'Head:3') -Because (
                $result | ConvertTo-Json -Depth 20 -Compress)
        $result.lifecycle.reviewEligibleIds |
            Should -Be @(2, 3) -Because (
                $result.lifecycle |
                    ConvertTo-Json -Depth 16 -Compress)
        $result.lifecycle.nextPullRequestId |
            Should -Be 4
        @($result.heads | Where-Object {
                [string]$_.reasonCode -ceq
                    'lifecycle-activity-unverified'
            }).pullRequestId | Should -Be @(1, 4)
        @($result.transientSnapshots.Keys |
            Sort-Object) | Should -Be @('2', '3')
        @($result.heads | Where-Object {
                [long]$_.pullRequestId -eq 5
            }) | Should -HaveCount 0
        $artifact = [ordered]@{
            schemaVersion = 1
            kind = 'devpilot-shared-review-acquisition'
            generation = $result.generation
            configDigest =
                [string]$result.binding.configDigest
            intake = $result
        } | ConvertTo-Json -Depth 100 |
            ConvertFrom-Json -AsHashtable -Depth 100
        @($artifact.intake.transientSnapshots.Keys |
            Sort-Object) | Should -Be @('2', '3')
        @($artifact.intake.heads | Where-Object {
                [string]$_.reasonCode -ceq
                    'lifecycle-activity-unverified'
            }).pullRequestId | Should -Be @(1, 4)
    }

    It 'discards partial lifecycle eligibility when the cursor is invalid' {
        $caseConfig = $config |
            ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $calls = [Collections.Generic.List[string]]::new()
        $rows = @(
            1..2 | ForEach-Object {
                [ordered]@{
                    pullRequestId = $_
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc =
                        '2023-01-01T00:00:00Z'
                }
            })
        $provider = {
            param($Operation, $Request)
            [void]$calls.Add(
                "$Operation`:$($Request.pullRequestId)")
            switch ($Operation) {
                Identity {
                    return [ordered]@{} +
                        $caseConfig.expectedAccount
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
                default {
                    throw "unexpected:$Operation"
                }
            }
        }.GetNewClosure()
        $lifecycle = {
            param($Inventory)
            return [pscustomobject][ordered]@{
                schemaVersion = 1
                kind = 'stale-pr-lifecycle-v1-run'
                health = 'healthy'
                providerWrites = 1
                modelWrites = 0
                confirmedAbandonedIds = @(2)
                reviewEligibleIds = @(1)
                nextPullRequestId = 999
                decisions = @()
                events = @()
            }
        }
        $root = Join-Path $env:USERPROFILE (
            '.copilot\stale-pr-invalid-cursor-' +
            [guid]::NewGuid().ToString('N'))
        [void]$script:roots.Add($root)
        $result = Invoke-ActivePrIntake `
            -Config $caseConfig -Provider $provider `
            -StateRoot $root -RepositoryRoot $repo `
            -LifecycleEvaluator $lifecycle -Run

        $result.lifecycle.reason |
            Should -BeExactly 'lifecycle-phase-failed'
        $result.lifecycle.diagnostic |
            Should -BeExactly 'lifecycle-cursor-invalid'
        $result.lifecycle.providerWrites |
            Should -Be 1
        $result.lifecycle.confirmedAbandonedIds |
            Should -Be @(2)
        $result.lifecycle.unknownPossibleEffect |
            Should -BeFalse
        $result.heads[0].reasonCode |
            Should -BeExactly 'lifecycle-activity-unverified'
        @($result.heads | Where-Object {
                [long]$_.pullRequestId -eq 2
            }) | Should -HaveCount 0
        @($calls | Where-Object {
                $_ -like 'Head:*'
            }) | Should -HaveCount 0
    }
}

Describe 'Stale lifecycle provider authority source' {
    It 'uses iteration push times and excludes system comments' {
        $source = Get-Content -LiteralPath (Join-Path $repo `
                'src\DevPilot.PullRequestLifecycle\DevPilot.PullRequestLifecycle.psm1') `
            -Raw
        $source | Should -Match 'iteration\.push\.date'
        $source | Should -Match (
            "if \(\`$type -ceq 'system'\) \{ continue \}")
        $source | Should -Not -Match (
            'sourceRefCommit\.(author|committer)')
    }

    It 'constructs exact direct identity GET and status PATCH requests' {
        $requests =
            [Collections.Generic.List[object]]::new()
        $http = New-AzLifecycleInvoker `
            -RequestLog $requests
        $provider = New-StalePrAzureDevOpsProvider `
            -Config $config `
            -TokenInvoker {
                @{ accessToken = 't' * 120 }
            } `
            -HttpInvoker $http

        $identity = & $provider Identity @{}
        $response = & $provider AbandonStatus @{
            pullRequestId = 1637334
            body = [ordered]@{
                status = 'abandoned'
            }
        }

        $identity.id | Should -BeExactly (
            [string]$config.expectedAccount.id)
        $response.status | Should -BeExactly abandoned
        @($requests) | Should -HaveCount 2
        $requests[0].uri | Should -BeExactly (
            'https://dev.azure.com/example-org/' +
            '_apis/connectionData?connectOptions=1&' +
            'api-version=7.1-preview.1')
        $requests[0].method | Should -BeExactly GET
        $requests[0].authorizationExact | Should -BeTrue
        $requests[0].authorizationWasPlaceholder | Should -BeFalse
        $requests[0].bodyBase64 | Should -BeNullOrEmpty
        $requests[1].uri | Should -BeExactly (
            'https://dev.azure.com/example-org/' +
            'ExampleProject/_apis/git/repositories/' +
            '11111111-1111-1111-1111-111111111111/' +
            'pullrequests/1637334?api-version=7.1')
        $requests[1].method | Should -BeExactly PATCH
        $requests[1].authorizationExact | Should -BeTrue
        $requests[1].authorizationWasPlaceholder | Should -BeFalse
        $requests[1].contentType |
            Should -BeExactly 'application/json'
        $bodyBytes = [Convert]::FromBase64String(
            [string]$requests[1].bodyBase64)
        $bodyBytes.Length | Should -Be 22
        [Text.UTF8Encoding]::new(
            $false, $true).GetString($bodyBytes) |
            Should -BeExactly '{"status":"abandoned"}'
        $bodyBytes[0..2] |
            Should -Not -Be @(0xEF, 0xBB, 0xBF)
        (ConvertTo-Json $requests -Depth 16) |
            Should -Not -Match ('t' * 120)
        $source = Get-Content -LiteralPath (
            Join-Path $repo `
                'src\DevPilot.PullRequestLifecycle\DevPilot.PullRequestLifecycle.psm1') `
            -Raw
        $placeholderPattern =
            'Authorization\s*=\s*"' +
            [regex]::Escape(('*' * 6)) + '"'
        $source | Should -Not -Match $placeholderPattern
    }

    It 'does not dispatch HTTP when token acquisition exhausts deadline' {
        $boundedConfig = $config |
            ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $boundedConfig.limits.maxSeconds = 1
        $httpCalls = [ref]0
        $provider = New-StalePrAzureDevOpsProvider `
            -Config $boundedConfig `
            -TokenInvoker {
                param($DeadlineUtc, $TimeoutMilliseconds)
                Start-Sleep -Seconds 3
                @{ accessToken = 't' * 120 }
            } `
            -HttpInvoker {
                param($Request)
                $httpCalls.Value++
                throw 'HTTP must not be dispatched.'
            }.GetNewClosure()

        $watch = [Diagnostics.Stopwatch]::StartNew()
        {
            & $provider Identity @{}
        } | Should -Throw '*stale-pr-deadline-exhausted*'
        $watch.Stop()
        $watch.Elapsed.TotalSeconds |
            Should -BeLessThan 2.5
        $httpCalls.Value | Should -Be 0
    }

    It 'terminates the native token process tree at the shared deadline' {
        $sdkRoot = Join-Path $TestDrive 'fake-azure-cli'
        $wbin = Join-Path $sdkRoot 'wbin'
        New-Item -ItemType Directory -Path $wbin `
            -Force | Out-Null
        $python = Join-Path $sdkRoot 'python.exe'
        $project = Join-Path $repo `
            'tests\fixtures\StalePrSlowTokenProcess.csproj'
        $build = @(& dotnet build $project `
            -o $sdkRoot -nologo `
            --verbosity quiet 2>&1)
        $LASTEXITCODE | Should -Be 0 `
            -Because ($build -join "`n")
        Test-Path -LiteralPath $python `
            -PathType Leaf | Should -BeTrue
        $az = Join-Path $wbin 'az.cmd'
        [IO.File]::WriteAllLines(
            $az,
            @(
                '@IF EXIST "%~dp0\..\python.exe" (',
                'SET AZ_INSTALLER=MSI',
                '"%~dp0\..\python.exe" -IBm azure.cli %*',
                ') ELSE (',
                'echo Failed to load python executable.',
                'exit /b 1',
                ')'
            ),
            [Text.ASCIIEncoding]::new())
        $pidLog = Join-Path $TestDrive 'token-pids.txt'
        $prior = [Environment]::GetEnvironmentVariable(
            'DEVPILOT_STALE_PR_TOKEN_PID_LOG',
            [EnvironmentVariableTarget]::Process)
        $priorMode = [Environment]::GetEnvironmentVariable(
            'DEVPILOT_STALE_PR_TOKEN_MODE',
            [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable(
            'DEVPILOT_STALE_PR_TOKEN_PID_LOG',
            $pidLog,
            [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable(
            'DEVPILOT_STALE_PR_TOKEN_MODE',
            'descendant-holds-pipes',
            [EnvironmentVariableTarget]::Process)
        $boundedConfig = $config |
            ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $boundedConfig.limits.maxSeconds = 1
        $httpCalls = [ref]0
        $pids = @()
        try {
            $provider = New-StalePrAzureDevOpsProvider `
                -Config $boundedConfig `
                -AzureCliPath $az `
                -HttpInvoker {
                    param($Request)
                    $httpCalls.Value++
                    throw 'HTTP must not be dispatched.'
                }.GetNewClosure()
            $watch = [Diagnostics.Stopwatch]::StartNew()
            {
                & $provider Identity @{}
            } | Should -Throw '*stale-pr-deadline-exhausted*'
            $watch.Stop()
            $watch.Elapsed.TotalSeconds |
                Should -BeLessThan 3
            $httpCalls.Value | Should -Be 0
            $deadline = [DateTime]::UtcNow.AddSeconds(3)
            while (-not (Test-Path $pidLog) -and
                [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 25
            }
            $pids = @(Get-Content $pidLog |
                ForEach-Object {
                    [int]($_.Split('=')[1])
                })
            $pids | Should -HaveCount 2
            foreach ($processId in $pids) {
                Get-Process -Id $processId `
                    -ErrorAction SilentlyContinue |
                    Should -BeNullOrEmpty
            }
        }
        finally {
            foreach ($processId in $pids) {
                $remainingProcess = Get-Process -Id $processId `
                    -ErrorAction SilentlyContinue
                if ($null -ne $remainingProcess) {
                    Stop-Process -Id $processId -Force `
                        -ErrorAction SilentlyContinue
                }
            }
            [Environment]::SetEnvironmentVariable(
                'DEVPILOT_STALE_PR_TOKEN_PID_LOG',
                $prior,
                [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable(
                'DEVPILOT_STALE_PR_TOKEN_MODE',
                $priorMode,
                [EnvironmentVariableTarget]::Process)
        }
    }

    It 'hard-bounds native token stdout and stderr' `
        -TestCases @(
            @{ Mode = 'stdout-overrun' }
            @{ Mode = 'stderr-overrun' }
        ) {
        param($Mode)
        $sdkRoot = Join-Path $TestDrive "fake-azure-cli-$Mode"
        $wbin = Join-Path $sdkRoot 'wbin'
        New-Item -ItemType Directory -Path $wbin `
            -Force | Out-Null
        $project = Join-Path $repo `
            'tests\fixtures\StalePrSlowTokenProcess.csproj'
        $build = @(& dotnet build $project `
            -o $sdkRoot -nologo `
            --verbosity quiet 2>&1)
        $LASTEXITCODE | Should -Be 0 `
            -Because ($build -join "`n")
        $az = Join-Path $wbin 'az.cmd'
        [IO.File]::WriteAllLines(
            $az,
            @(
                '@IF EXIST "%~dp0\..\python.exe" (',
                'SET AZ_INSTALLER=MSI',
                '"%~dp0\..\python.exe" -IBm azure.cli %*',
                ') ELSE (',
                'echo Failed to load python executable.',
                'exit /b 1',
                ')'
            ),
            [Text.ASCIIEncoding]::new())
        $pidLog = Join-Path $TestDrive "$Mode-pids.txt"
        $priorLog = [Environment]::GetEnvironmentVariable(
            'DEVPILOT_STALE_PR_TOKEN_PID_LOG',
            [EnvironmentVariableTarget]::Process)
        $priorMode = [Environment]::GetEnvironmentVariable(
            'DEVPILOT_STALE_PR_TOKEN_MODE',
            [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable(
            'DEVPILOT_STALE_PR_TOKEN_PID_LOG',
            $pidLog,
            [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable(
            'DEVPILOT_STALE_PR_TOKEN_MODE',
            $Mode,
            [EnvironmentVariableTarget]::Process)
        $httpCalls = [ref]0
        $pids = @()
        try {
            $provider = New-StalePrAzureDevOpsProvider `
                -Config $config -AzureCliPath $az `
                -HttpInvoker {
                    param($Request)
                    $httpCalls.Value++
                    throw 'HTTP must not be dispatched.'
                }.GetNewClosure()
            $watch = [Diagnostics.Stopwatch]::StartNew()
            {
                & $provider Identity @{}
            } | Should -Throw '*stale-pr-token-response-too-large*'
            $watch.Stop()
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 5
            $httpCalls.Value | Should -Be 0
            $pids = @(Get-Content $pidLog |
                ForEach-Object {
                    [int]($_.Split('=')[1])
                })
            $pids | Should -HaveCount 1
            Get-Process -Id $pids[0] `
                -ErrorAction SilentlyContinue |
                Should -BeNullOrEmpty
        }
        finally {
            foreach ($processId in $pids) {
                $remainingProcess = Get-Process -Id $processId `
                    -ErrorAction SilentlyContinue
                if ($null -ne $remainingProcess) {
                    Stop-Process -Id $processId -Force `
                        -ErrorAction SilentlyContinue
                }
            }
            [Environment]::SetEnvironmentVariable(
                'DEVPILOT_STALE_PR_TOKEN_PID_LOG',
                $priorLog,
                [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable(
                'DEVPILOT_STALE_PR_TOKEN_MODE',
                $priorMode,
                [EnvironmentVariableTarget]::Process)
        }
    }

    It 'keeps token stream caps fixed and checks them before writes' {
        $source = Get-Content (Join-Path $repo `
                'src\DevPilot.PullRequestLifecycle\DevPilot.PullRequestLifecycle.psm1') `
            -Raw
        $source | Should -Match (
            '\$outputBuffer\s*=\s*\[byte\[\]\]::new\(8192\)')
        $source | Should -Match (
            '\$errorBuffer\s*=\s*\[byte\[\]\]::new\(4096\)')
        $source | Should -Match (
            '(?s)if \(\$output\.Length \+ \$count -gt 1048576\) ' +
            '\{.*?throw ''stale-pr-token-response-too-large''\s*' +
            '\}\s*\$output\.Write\(\$outputBuffer, 0, \$count\)')
        $source | Should -Match (
            '(?s)if \(\$error\.Length \+ \$count -gt 65536\) ' +
            '\{.*?throw ''stale-pr-token-response-too-large''\s*' +
            '\}\s*\$error\.Write\(\$errorBuffer, 0, \$count\)')
        $source | Should -Not -Match 'CopyToAsync'
        $source | Should -Not -Match (
            '(?:\[Threading\.Tasks\.Task\]|Task)\.WaitAll')
    }

    It 'constructs every lifecycle GET URI with one cached token' {
        $requests =
            [Collections.Generic.List[object]]::new()
        $provider = New-StalePrAzureDevOpsProvider `
            -Config $config `
            -TokenInvoker {
                param($DeadlineUtc, $TimeoutMilliseconds)
                @{ accessToken = 't' * 120 }
            } `
            -HttpInvoker (
                New-AzLifecycleInvoker `
                    -MissingSummaryPushDate `
                    -RequestLog $requests)

        [void](& $provider Identity @{})
        $evidence = & $provider ReadEvidence @{
            pullRequestId = 1
        }

        $evidence.complete | Should -BeTrue
        $actualUris = @($requests | ForEach-Object {
                [string]$_.uri
            })
        $expectedUris = @(
            (
            'https://dev.azure.com/example-org/' +
                '_apis/connectionData?connectOptions=1&' +
                'api-version=7.1-preview.1'),
            (
            'https://dev.azure.com/example-org/' +
                'ExampleProject/_apis/git/repositories/' +
                '11111111-1111-1111-1111-111111111111/' +
                'pullRequests/1?api-version=7.1'),
            (
            'https://dev.azure.com/example-org/' +
                'ExampleProject/_apis/git/repositories/' +
                '11111111-1111-1111-1111-111111111111/' +
                'pullRequests/1/iterations?api-version=7.1'),
            (
            'https://dev.azure.com/example-org/' +
                'ExampleProject/_apis/git/repositories/' +
                '11111111-1111-1111-1111-111111111111/' +
                'pullRequests/1/threads?api-version=7.1'),
            (
            'https://dev.azure.com/example-org/' +
                'ExampleProject/_apis/git/repositories/' +
                '11111111-1111-1111-1111-111111111111/' +
                'refs?filter=heads%2Ffeature-1&' +
                'includeStatuses=false&peelTags=false&' +
                'api-version=7.1'),
            (
            'https://dev.azure.com/example-org/' +
                'ExampleProject/_apis/git/repositories/' +
                '11111111-1111-1111-1111-111111111111/' +
                'pushes/7?includeRefUpdates=false&' +
                'includeCommits=false&api-version=7.1'))
        $actualUris | Should -HaveCount $expectedUris.Count
        for ($index = 0;
            $index -lt $expectedUris.Count;
            $index++) {
            $actualUris[$index] |
                Should -BeExactly $expectedUris[$index]
        }
        @($requests | Where-Object {
                [string]$_.method -cne 'GET' -or
                -not [bool]$_.authorizationExact -or
                [bool]$_.authorizationWasPlaceholder -or
                $null -ne $_.bodyBase64
            }) | Should -HaveCount 0
    }

    It 'fails closed when either direct connection identity mismatches' `
        -TestCases @(
            @{ Field = 'authenticatedUser' }
            @{ Field = 'authorizedUser' }
        ) {
        param($Field)
        $http = {
            param($Request)
            $response = @{
                authenticatedUser = @{
                    id = '33333333-3333-3333-3333-333333333333'
                    subjectDescriptor =
                        'aad.synthetic-service-account'
                }
                authorizedUser = @{
                    id = '33333333-3333-3333-3333-333333333333'
                    subjectDescriptor =
                        'aad.synthetic-service-account'
                }
            }
            $response[$Field].id =
                '99999999-9999-9999-9999-999999999999'
            return $response
        }
        $provider = New-StalePrAzureDevOpsProvider `
            -Config $config `
            -TokenInvoker {
                @{ accessToken = 't' * 120 }
            } `
            -HttpInvoker $http
        {
            & $provider Identity @{}
        } | Should -Throw '*identity-mismatch*'
    }

    It 'sanitizes direct HTTP write failures in signed records' {
        $evidence = New-LifecycleEvidence -Id 1637334
        $http = {
            param($Request)
            if ([string]$Request.Method -ceq 'PATCH') {
                $failure = [InvalidOperationException]::new(
                    'RAW-SECRET-MARKER')
                $failure.Data['serverErrorCode'] =
                    'InvalidArgumentValueException'
                $response = [pscustomobject]@{
                    StatusCode = 400
                }
                $failure | Add-Member `
                    -MemberType NoteProperty `
                    -Name Response -Value $response
                throw $failure
            }
            return @{
                authenticatedUser = @{
                    id = '33333333-3333-3333-3333-333333333333'
                    subjectDescriptor =
                        'aad.synthetic-service-account'
                }
                authorizedUser = @{
                    id = '33333333-3333-3333-3333-333333333333'
                    subjectDescriptor =
                        'aad.synthetic-service-account'
                }
            }
        }
        $realProvider = New-StalePrAzureDevOpsProvider `
            -Config $config `
            -TokenInvoker {
                @{ accessToken = 't' * 120 }
            } `
            -HttpInvoker $http
        $provider = {
            param($Operation, $Arguments)
            switch ($Operation) {
                Identity {
                    return & $realProvider Identity @{}
                }
                ReadEvidence {
                    return $evidence
                }
                AbandonStatus {
                    return & $realProvider `
                        $Operation $Arguments
                }
                ReadStatus {
                    return @{
                        pullRequestId =
                            [long]$Arguments.pullRequestId
                        status = 'active'
                    }
                }
            }
        }.GetNewClosure()
        $result = Invoke-LifecycleCase `
            -Provider $provider `
            -Inventory @([ordered]@{
                    pullRequestId = 1637334
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                })

        $diagnostic = $result.events[0].diagnostic
        $diagnostic.kind |
            Should -BeExactly http-request-failed
        $diagnostic.httpStatus | Should -Be 400
        $diagnostic.serverErrorCode |
            Should -BeExactly InvalidArgumentValueException
        @($diagnostic.Keys | Sort-Object) |
            Should -Be @(
                'httpStatus', 'kind', 'serverErrorCode')
        (ConvertTo-Json $result -Depth 64) |
            Should -Not -Match 'RAW-SECRET-MARKER'
    }

    It 'ignores recent system-only events but includes recent bot comments' {
        $systemOnly = New-TestAzureDevOpsLifecycleProvider `
            -InputConfig $config -HttpInvoker (
                New-AzLifecycleInvoker)
        $systemEvidence = & $systemOnly ReadEvidence @{
            pullRequestId = 1
        }
        $systemEvidence.latestActivityUtc |
            Should -BeExactly '2024-12-01T00:00:00.0000000Z'

        $botComment = New-TestAzureDevOpsLifecycleProvider `
            -InputConfig $config -HttpInvoker (
                New-AzLifecycleInvoker `
                    -ActualCommentUtc '2026-01-02T00:00:00Z')
        $botEvidence = & $botComment ReadEvidence @{
            pullRequestId = 1
        }
        $botEvidence.latestActivityUtc |
            Should -BeExactly '2026-01-02T00:00:00.0000000Z'
    }

    It 'uses push occurrence time and rejects malformed comment evidence' {
        $summaryPushReads = 0
        $recentPush = New-TestAzureDevOpsLifecycleProvider `
            -InputConfig $config -HttpInvoker (
                New-AzLifecycleInvoker `
                    -PushUtc '2026-01-03T00:00:00Z' `
                    -PushDetailReads (
                        [ref]$summaryPushReads))
        $pushEvidence = & $recentPush ReadEvidence @{
            pullRequestId = 1
        }
        $pushEvidence.latestActivityUtc |
            Should -BeExactly '2026-01-03T00:00:00.0000000Z'
        $summaryPushReads | Should -Be 0

        $malformed = New-TestAzureDevOpsLifecycleProvider `
            -InputConfig $config -HttpInvoker (
                New-AzLifecycleInvoker `
                    -ActualCommentUtc '2024-12-02T00:00:00Z' `
                    -MalformedComment)
        {
            & $malformed ReadEvidence @{
                pullRequestId = 1
            }
        } | Should -Throw '*comment-time-unknown*'
    }

    It 'loads an authoritative push date when the iteration summary omits it' {
        $detailReads = 0
        $invoker = New-AzLifecycleInvoker `
            -PushUtc '2024-12-03T04:05:06Z' `
            -MissingSummaryPushDate `
            -PushDetailReads ([ref]$detailReads)
        $provider = New-TestAzureDevOpsLifecycleProvider `
            -InputConfig $config -HttpInvoker $invoker
        $evidence = & $provider ReadEvidence @{
            pullRequestId = 1
        }

        $detailReads | Should -Be 1
        $evidence.latestActivityUtc |
            Should -BeExactly '2024-12-03T04:05:06.0000000Z'
    }

    It 'deduplicates missing summary push dates by pushId' {
        $detailReads = 0
        $provider = New-TestAzureDevOpsLifecycleProvider `
            -InputConfig $config -HttpInvoker (
                New-AzLifecycleInvoker `
                    -PushUtc '2024-12-03T04:05:06Z' `
                    -MissingSummaryPushDate `
                    -DuplicatePushId `
                    -PushDetailReads ([ref]$detailReads))
        $evidence = & $provider ReadEvidence @{
            pullRequestId = 1
        }

        $detailReads | Should -Be 1
        $evidence.iterationId | Should -Be 2
        $evidence.latestActivityUtc |
            Should -BeExactly '2024-12-03T04:05:06.0000000Z'
    }

    It 'preserves read and deadline exhaustion from push detail' `
        -TestCases @(
            @{ Bound = 'read' }
            @{ Bound = 'deadline' }
        ) {
        param($Bound)
        $boundedConfig = $config |
            ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $clock = $null
        if ($Bound -ceq 'read') {
            $boundedConfig['subjectProvider'] =
                [ordered]@{ maximumReads = 4 }
            $expected = 'stale-pr-read-budget-exhausted'
        }
        else {
            $expected = 'stale-pr-deadline-exhausted'
            $start = [DateTime]::SpecifyKind(
                [DateTime]'2026-01-01T00:00:00',
                [DateTimeKind]::Utc)
            $clockCalls = [ref]0
            $clock = {
                $clockCalls.Value++
                if ($clockCalls.Value -lt 10) {
                    return $start
                }
                return $start.AddSeconds(
                    [int]$boundedConfig.limits.maxSeconds + 1)
            }.GetNewClosure()
        }
        $providerArguments = @{
            InputConfig = $boundedConfig
            HttpInvoker = (
                New-AzLifecycleInvoker `
                    -MissingSummaryPushDate)
        }
        if ($null -ne $clock) {
            $providerArguments.UtcNowProvider = $clock
        }
        $provider = New-TestAzureDevOpsLifecycleProvider `
            @providerArguments

        {
            & $provider ReadEvidence @{
                pullRequestId = 1
            }
        } | Should -Throw "*$expected*"
    }

    It 'shares one read budget across candidates and stops the second' {
        $boundedConfig = $config |
            ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $boundedConfig.subjectProvider.maximumReads = 6
        $boundedConfig.limits.maxReads = 100
        $getReads = [ref]0
        $provider = New-TestAzureDevOpsLifecycleProvider `
            -InputConfig $boundedConfig -HttpInvoker (
                New-AzLifecycleInvoker `
                    -ActualCommentUtc '2026-01-02T00:00:00Z' `
                    -GetReads $getReads)
        $root = New-LifecycleRoot
        try {
            $result = Invoke-StalePrLifecycle `
                -Inventory @(
                    [ordered]@{
                        pullRequestId = 1
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc = '2024-01-01T00:00:00Z'
                    },
                    [ordered]@{
                        pullRequestId = 2
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc = '2024-01-01T00:00:00Z'
                    },
                    [ordered]@{
                        pullRequestId = 3
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc = '2024-01-01T00:00:00Z'
                    }) `
                -CutoffUtc ([DateTime]::SpecifyKind(
                    [DateTime]'2025-01-01T00:00:00',
                    [DateTimeKind]::Utc)) `
                -Policy $policy `
                -LifecycleRoot $root.Context.Root `
                -Key $root.Key -Provider $provider
        }
        finally {
            [Array]::Clear(
                $root.Key, 0, $root.Key.Length)
        }

        $result.providerWrites | Should -Be 0
        @($result.decisions) | Should -HaveCount 2 `
            -Because (
                $result | ConvertTo-Json -Depth 8 -Compress)
        $result.reviewEligibleIds | Should -Be @(1)
        $deferred = @($result.decisions |
            Where-Object pullRequestId -eq 2)
        $deferred | Should -HaveCount 1
        $deferred[0].state | Should -BeExactly deferred
        $deferred[0].reason |
            Should -BeExactly stale-pr-read-budget-exhausted
        $deferred[0].diagnostic.kind |
            Should -BeExactly 'read-count'
        $deferred[0].diagnostic.readCount |
            Should -Be 6
        $deferred[0].diagnostic.readCeiling |
            Should -Be 6
        @($result.decisions | Where-Object {
                [long]$_.pullRequestId -eq 3
            }) | Should -HaveCount 0
        $getReads.Value | Should -Be 5
    }

    It 'distinguishes an oversized response without changing the read bound' {
        $http = {
            param($Request)
            if ([string]$Request.Uri -match
                '/_apis/connectionData\?') {
                return [ordered]@{
                    authenticatedUser = [ordered]@{
                        id =
                            '33333333-3333-3333-3333-333333333333'
                        subjectDescriptor =
                            'aad.synthetic-service-account'
                    }
                    authorizedUser = [ordered]@{
                        id =
                            '33333333-3333-3333-3333-333333333333'
                        subjectDescriptor =
                            'aad.synthetic-service-account'
                    }
                }
            }
            return [pscustomobject]@{
                RawContentLength = 16777217
                Content = '{}'
            }
        }
        $provider = New-TestAzureDevOpsLifecycleProvider `
            -InputConfig $config -HttpInvoker $http
        $root = New-LifecycleRoot
        try {
            $result = Invoke-StalePrLifecycle `
                -Inventory @([ordered]@{
                        pullRequestId = 1
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc =
                            '2024-01-01T00:00:00Z'
                    }) `
                -CutoffUtc ([DateTime]::SpecifyKind(
                    [DateTime]'2025-01-01T00:00:00',
                    [DateTimeKind]::Utc)) `
                -Policy $policy `
                -LifecycleRoot $root.Context.Root `
                -Key $root.Key -Provider $provider
        }
        finally {
            [Array]::Clear(
                $root.Key, 0, $root.Key.Length)
        }

        $result.providerWrites | Should -Be 0
        $result.decisions[0].reason |
            Should -BeExactly 'stale-pr-read-budget-exhausted'
        $result.decisions[0].diagnostic.kind |
            Should -BeExactly 'response-size'
        $result.decisions[0].diagnostic.responseBytes |
            Should -Be 16777217
        $result.decisions[0].diagnostic.
            responseByteCeiling | Should -Be 16777216
    }

    It 'resumes after a budget-deferred candidate without retrying it first' {
        $provider = New-LifecycleProvider `
            -EvidenceById @{
                1 = New-LifecycleEvidence -Id 1
                2 = New-LifecycleEvidence -Id 2 `
                    -ActivityUtc '2025-12-01T00:00:00Z'
                3 = New-LifecycleEvidence -Id 3 `
                    -ActivityUtc '2025-12-02T00:00:00Z'
            } `
            -EvidenceFailureById @{
                1 = 'stale-pr-read-budget-exhausted'
            } `
            -SecondEvidenceFailureById @{
                1 = 'stale-pr-read-budget-exhausted'
            }
        $inventory = @(
            1..3 | ForEach-Object {
                [ordered]@{
                    pullRequestId = $_
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                }
            })
        $root = New-LifecycleRoot
        try {
            $first = Invoke-StalePrLifecycle `
                -Inventory $inventory `
                -CutoffUtc ([DateTime]::SpecifyKind(
                    [DateTime]'2025-01-01T00:00:00',
                    [DateTimeKind]::Utc)) `
                -Policy $policy `
                -LifecycleRoot $root.Context.Root `
                -Key $root.Key -Provider $provider.Handler
            $rotated = @(
                $inventory | Where-Object {
                    [long]$_.pullRequestId -ge
                        [long]$first.nextPullRequestId
                }
            ) + @(
                $inventory | Where-Object {
                    [long]$_.pullRequestId -lt
                        [long]$first.nextPullRequestId
                }
            )
            $second = Invoke-StalePrLifecycle `
                -Inventory $rotated `
                -CutoffUtc ([DateTime]::SpecifyKind(
                    [DateTime]'2025-01-01T00:00:00',
                    [DateTimeKind]::Utc)) `
                -Policy $policy `
                -LifecycleRoot $root.Context.Root `
                -Key $root.Key -Provider $provider.Handler
        }
        finally {
            [Array]::Clear(
                $root.Key, 0, $root.Key.Length)
        }

        $first.decisions[0].pullRequestId | Should -Be 1
        $first.decisions[0].reason |
            Should -BeExactly 'stale-pr-read-budget-exhausted'
        $first.nextPullRequestId | Should -Be 2
        $second.reviewEligibleIds | Should -Be @(2, 3)
        @($second.decisions.pullRequestId) |
            Should -Be @(2, 3, 1)
        @($provider.Calls | Where-Object {
                $_ -ceq 'ReadEvidence:1'
            }) | Should -HaveCount 2
    }

    It 'shares one elapsed deadline across candidates' {
        $boundedConfig = $config |
            ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $start = [DateTime]::SpecifyKind(
            [DateTime]'2026-01-01T00:00:00',
            [DateTimeKind]::Utc)
        $clockCalls = [ref]0
        $clock = {
            $clockCalls.Value++
            if ($clockCalls.Value -lt 20) {
                return $start
            }
            return $start.AddSeconds(
                [int]$boundedConfig.limits.maxSeconds + 1)
        }.GetNewClosure()
        $provider = New-TestAzureDevOpsLifecycleProvider `
            -InputConfig $boundedConfig `
            -UtcNowProvider $clock -HttpInvoker (
                New-AzLifecycleInvoker `
                    -ActualCommentUtc '2026-01-02T00:00:00Z')
        $root = New-LifecycleRoot
        try {
            $result = Invoke-StalePrLifecycle `
                -Inventory @(
                    [ordered]@{
                        pullRequestId = 1
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc = '2024-01-01T00:00:00Z'
                    },
                    [ordered]@{
                        pullRequestId = 2
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc = '2024-01-01T00:00:00Z'
                    },
                    [ordered]@{
                        pullRequestId = 3
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc = '2024-01-01T00:00:00Z'
                    }) `
                -CutoffUtc ([DateTime]::SpecifyKind(
                    [DateTime]'2025-01-01T00:00:00',
                    [DateTimeKind]::Utc)) `
                -Policy $policy `
                -LifecycleRoot $root.Context.Root `
                -Key $root.Key -Provider $provider
        }
        finally {
            [Array]::Clear(
                $root.Key, 0, $root.Key.Length)
        }

        $result.providerWrites | Should -Be 0
        @($result.decisions) | Should -HaveCount 2 `
            -Because (
                $result | ConvertTo-Json -Depth 8 -Compress)
        $result.reviewEligibleIds | Should -Be @(1)
        $deferred = @($result.decisions |
            Where-Object pullRequestId -eq 2)
        $deferred | Should -HaveCount 1
        $deferred[0].state | Should -BeExactly deferred
        $deferred[0].reason |
            Should -BeExactly stale-pr-deadline-exhausted
        @($result.decisions | Where-Object {
                [long]$_.pullRequestId -eq 3
            }) | Should -HaveCount 0
    }

    It 'keeps readback exhaustion ambiguous with one PATCH and no retry' {
        $boundedConfig = $config |
            ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $boundedConfig.subjectProvider.maximumReads = 128
        $patchCalls = [ref]0
        $start = [DateTime]::SpecifyKind(
            [DateTime]'2026-01-01T00:00:00',
            [DateTimeKind]::Utc)
        $clock = {
            if ($patchCalls.Value -eq 0) {
                return $start
            }
            return $start.AddSeconds(
                [int]$boundedConfig.limits.maxSeconds + 1)
        }.GetNewClosure()
        $provider = New-TestAzureDevOpsLifecycleProvider `
            -InputConfig $boundedConfig `
            -UtcNowProvider $clock -HttpInvoker (
                New-AzLifecycleInvoker `
                    -PatchCalls $patchCalls)
        $root = New-LifecycleRoot
        try {
            $result = Invoke-StalePrLifecycle `
                -Inventory @([ordered]@{
                        pullRequestId = 1
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc = '2024-01-01T00:00:00Z'
                    }) `
                -CutoffUtc ([DateTime]::SpecifyKind(
                    [DateTime]'2025-01-01T00:00:00',
                    [DateTimeKind]::Utc)) `
                -Policy $policy `
                -LifecycleRoot $root.Context.Root `
                -Key $root.Key -Provider $provider
        }
        finally {
            [Array]::Clear(
                $root.Key, 0, $root.Key.Length)
        }

        $result.providerWrites | Should -Be 1
        @($result.decisions) | Should -HaveCount 1
        $result.decisions[0].reason |
            Should -BeExactly ambiguous-post-write
        $result.confirmedAbandonedIds |
            Should -BeNullOrEmpty
        @($result.events) | Should -HaveCount 1
        $result.events[0].providerWriteCount | Should -Be 1
        $result.events[0].providerWriteState |
            Should -BeExactly unknown
    }

    It 'fails closed for unavailable malformed or mismatched push detail' `
        -TestCases @(
            @{ Mode = 'missing' }
            @{ Mode = 'malformed' }
            @{ Mode = 'mismatched-id' }
            @{ Mode = 'mismatched-repository' }
            @{ Mode = 'mismatched-project' }
        ) {
        param($Mode)
        $detailReads = 0
        $provider = New-TestAzureDevOpsLifecycleProvider `
            -InputConfig $config -HttpInvoker (
                New-AzLifecycleInvoker `
                    -MissingSummaryPushDate `
                    -PushDetail $Mode `
                    -PushDetailReads ([ref]$detailReads))

        {
            & $provider ReadEvidence @{
                pullRequestId = 1
            }
        } | Should -Throw '*stale-pr-push-time-unknown*'
        $detailReads | Should -Be 1
    }

    It 'accepts complete empty counted-activity histories using creation' {
        $provider = New-TestAzureDevOpsLifecycleProvider `
            -InputConfig $config -HttpInvoker (
                New-AzLifecycleInvoker -NoIterations)
        $evidence = & $provider ReadEvidence @{
            pullRequestId = 1
        }

        $evidence.iterationId | Should -Be 0
        $evidence.latestActivityUtc |
            Should -BeExactly '2024-01-01T00:00:00.0000000Z'
        $evidence.complete | Should -BeTrue
    }
}

Describe 'Named shared acquisition lifecycle route' {
    It 'keeps the actual Named host lifecycle disabled with zero writes by default' {
        $namedConfigPath = Join-Path $repo `
            'samples\named-areequal-current-pr.config.json'
        $namedConfig = Get-Content `
            -LiteralPath $namedConfigPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
        $namedConfig.stalePullRequestLifecycle |
            Should -BeOfType [bool]
        $namedConfig.stalePullRequestLifecycle |
            Should -BeFalse
        $lifecycleConfig =
            Get-StalePrLifecycleConfiguration `
                -Config $namedConfig
        $lifecycleConfig.Enabled |
            Should -BeFalse

        $root = Join-Path $env:USERPROFILE (
            '.copilot\named-lifecycle-route-pester-' +
            [guid]::NewGuid().ToString('N'))
        [void]$script:roots.Add($root)
        $result = & (Join-Path $repo `
                'tools\Invoke-SharedReviewAcquisition.ps1') `
            -ConfigPath $namedConfigPath `
            -StateRoot (Join-Path $root 'state') `
            -AcquisitionPath (
                Join-Path $root 'acquisition.json') `
            -AzureCliPath 'unused-az' `
            -RepoRoot $repo |
            ConvertFrom-Json -AsHashtable -Depth 64

        $result.providerWrites | Should -Be 0
        $result.lifecycleProviderWrites |
            Should -Be 0
        $result.lifecycleHealth |
            Should -BeExactly 'disabled'
        $result.lifecycleConfirmedAbandonedIds |
            Should -HaveCount 0
        $result.lifecycleReviewEligibleIds |
            Should -HaveCount 0
        $result.lifecycleNextPullRequestId |
            Should -BeNullOrEmpty
        $result.
            lifecycleWithheldFromAutomaticComments |
            Should -HaveCount 0
        $snapshot = Get-Content `
            -LiteralPath $result.acquisitionPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        $snapshot.intake.lifecycleWriterEligible |
            Should -BeFalse
        $snapshot.intake.lifecycle.state |
            Should -BeExactly 'disabled'
        $snapshot.intake.lifecycle.providerWrites |
            Should -Be 0
        $snapshot.intake.lifecycle.reviewEligibleIds |
            Should -HaveCount 0
    }

    Describe 'Native stale abandonment explanations' {
        It 'confirms one transition then one deterministic same-PR explanation' {
            $case = New-ExplanationCase
            $arguments = $case.Arguments
            $result = Invoke-StalePrLifecycle @arguments

            $result.health | Should -BeExactly healthy
            $case.State.StatusWrites | Should -Be 1
            $case.State.Status | Should -BeExactly abandoned
            $result.providerWrites | Should -Be 2
            $result.statusWrites | Should -Be 1
            $result.explanationWrites | Should -Be 1
            $result.unconfirmedStatusWrites | Should -Be 0
            $result.unconfirmedExplanationWrites | Should -Be 0
            $result.confirmedAbandonedIds | Should -Be @(1)
            $result.explanationReadCount | Should -Be 2
            $result.providerReadCount | Should -Be 12
            $case.State.StatusWrites | Should -Be 1
            $case.State.Posts | Should -Be 1
            $case.State.Body | Should -Match 'automatically abandoned'
            $case.State.Body | Should -Match 'created more than one year ago'
            $case.State.Body | Should -Match '2025-01-01T00:00:00.0000000Z'
            $case.State.Body | Should -Match '2024-12-01T00:00:00.0000000Z'
            $case.State.Body | Should -Match '<!-- devpilot-stale-abandonment:v1:[0-9a-f]{32} -->'
            @($result.events) | Should -HaveCount 1
            $result.events[0].action | Should -BeExactly 'status:abandoned'
            @($result.explanationEvents) | Should -HaveCount 1
            $result.explanationEvents[0].action |
                Should -BeExactly 'comment:create-after-confirmed-abandonment'
            $result.explanationEvents[0].readback.threadId | Should -Be 81
            $result.explanationEvents[0].readback.markerMatchCount | Should -Be 1
            $result.explanationEvents[0].readback.bodyDigest |
                Should -BeExactly $result.explanationEvents[0].bodyDigest
            $signedEvents = @(Get-ChildItem -LiteralPath (
                    Join-Path $case.Root.Context.Root 'explanations\events') -File)
            $signedEvents | Should -HaveCount 1
            $signed = Read-StalePrLifecyclePolicy -Path $signedEvents[0].FullName `
                -Key $case.Root.Key
            $signed.bodyDigest | Should -BeExactly (
                $result.explanationEvents[0].bodyDigest)
            $second = Invoke-StalePrLifecycle @arguments
            $second.providerWrites | Should -Be 0
            $case.State.Posts | Should -Be 1
            $case.State.StatusWrites | Should -Be 1
            {
                & $arguments.Provider CreateExplanation @{
                    pullRequestId = 1
                    statusIntentId = $result.explanationEvents[0].statusIntentId
                    content = $case.State.Body
                }
            } | Should -Throw '*stale-pr-explanation-not-authorized*'
            $case.State.Posts | Should -Be 1
        }

        It 'round-trips the signed additive explanation grant using the existing lifecycle key' {
            $case = New-ExplanationCase
            $path = Join-Path $case.Root.Context.Root 'policies\explanation.json'
            [void](Write-StalePrLifecyclePolicy -Path $path `
                -Policy $case.Policy -Key $case.Root.Key)
            $signed = Read-StalePrLifecyclePolicy -Path $path -Key $case.Root.Key
            $signed.authority.commentsOrThreads | Should -BeFalse
            $signed.authority.abandonmentExplanation.action |
                Should -BeExactly 'comment:create-after-confirmed-abandonment'
            $signed.authority.abandonmentExplanation.maxPerRun | Should -Be 1
        }

        It 'preserves status-only authority without a new explanation grant' {
            $case = New-ExplanationCase -StatusOnly
            $arguments = $case.Arguments
            $result = Invoke-StalePrLifecycle @arguments
            $result.statusWrites | Should -Be 1
            $result.explanationWrites | Should -Be 0
            $result.providerWrites | Should -Be 1
            $case.State.Posts | Should -Be 0
            $case.State.ExplanationReads | Should -Be 0
        }

        It 'independently rejects malformed confirmed readback (<Mutation>)' `
            -TestCases @(
                @{ Mutation = 'wrong-pr' }
                @{ Mutation = 'wrong-digest' }
                @{ Mutation = 'wrong-actor' }
                @{ Mutation = 'duplicate-marker-count' }
                @{ Mutation = 'zero-marker-count' }
                @{ Mutation = 'boolean-marker-count' }
                @{ Mutation = 'zero-thread-id' }
                @{ Mutation = 'negative-thread-id' }
                @{ Mutation = 'zero-comment-id' }
                @{ Mutation = 'negative-comment-id' }
                @{ Mutation = 'boolean-pr-id' }
                @{ Mutation = 'boolean-thread-id' }
                @{ Mutation = 'fractional-comment-id' }
                @{ Mutation = 'missing-field' }
                @{ Mutation = 'extra-field' }
                @{ Mutation = 'state-only-dictionary' }
                @{ Mutation = 'state-only-pscustomobject' }
                @{ Mutation = 'full-pscustomobject' }
            ) {
            param($Mutation)
            $case = New-ExplanationCase
            $arguments = $case.Arguments
            $nativeProvider = $arguments.Provider
            $injectedProvider = {
                param($Operation, $Request)
                $response = & $nativeProvider $Operation $Request
                if ($Operation -ceq 'ReadExplanation' -and $case.State.Posts -gt 0) {
                    switch ($Mutation) {
                        wrong-pr { $response.pullRequestId = 999L }
                        wrong-digest { $response.bodyDigest = 'v1:sha256:' + ('0' * 64) }
                        wrong-actor { $response.authorId = '44444444-4444-4444-4444-444444444444' }
                        duplicate-marker-count { $response.markerMatchCount = 2 }
                        zero-marker-count { $response.markerMatchCount = 0 }
                        boolean-marker-count { $response.markerMatchCount = $true }
                        zero-thread-id { $response.threadId = 0L }
                        negative-thread-id { $response.threadId = -1L }
                        zero-comment-id { $response.commentId = 0L }
                        negative-comment-id { $response.commentId = -1L }
                        boolean-pr-id { $response.pullRequestId = $true }
                        boolean-thread-id { $response.threadId = $true }
                        fractional-comment-id { $response.commentId = 1.5 }
                        missing-field { $response.Remove('bodyDigest') }
                        extra-field { $response['unexpected'] = 'outside-the-contract' }
                        state-only-dictionary { $response = @{ state = 'confirmed' } }
                        state-only-pscustomobject { $response = [pscustomobject]@{ state = 'confirmed' } }
                        full-pscustomobject { $response = [pscustomobject]$response }
                        default { throw 'Unexpected readback mutation.' }
                    }
                }
                return $response
            }.GetNewClosure()
            $arguments.Provider = $injectedProvider
            $result = Invoke-StalePrLifecycle @arguments

            $result.health | Should -BeExactly unknown
            $result.providerWrites | Should -Be 2
            $result.statusWrites | Should -Be 1
            $result.explanationWrites | Should -Be 1
            $result.unconfirmedStatusWrites | Should -Be 0
            $result.unconfirmedExplanationWrites | Should -Be 1
            $result.confirmedAbandonedIds | Should -Be @(1)
            $result.decisions[0].explanation.state | Should -BeExactly unknown
            $event = $result.explanationEvents[0]
            $event.state | Should -BeExactly unknown
            $event.providerWriteCount | Should -Be 1
            $event.readback | Should -BeNullOrEmpty
            $signed = Read-StalePrLifecyclePolicy -Key $case.Root.Key -Path (
                Join-Path $case.Root.Context.Root "explanations\events\$($event.eventId).json")
            $signed.state | Should -BeExactly unknown
            $signed.providerWriteState | Should -BeExactly unknown
            $signed.providerWriteCount | Should -Be 1
            $signed.readback | Should -BeNullOrEmpty
            $outcome = Read-StalePrLifecyclePolicy -Key $case.Root.Key -Path (
                Join-Path $case.Root.Context.Root (
                    "explanations\outcomes\1\$($event.statusIntentId).json"))
            $outcome.state | Should -BeExactly unknown
            $outcome.providerWriteCount | Should -Be 1
            $outcome.retryAuthorized | Should -BeFalse

            $second = Invoke-StalePrLifecycle @arguments
            $second.providerWrites | Should -Be 0
            $second.decisions[0].reason | Should -BeExactly prior-ambiguous-explanation
            $resolved = Resolve-StalePrLifecycleExplanation `
                -LifecycleRoot $case.Root.Context.Root -PullRequestId 1 `
                -StatusIntentId $event.statusIntentId -Policy $case.Policy `
                -Key $case.Root.Key -Provider $injectedProvider
            $resolved.state | Should -BeExactly unknown
            $resolved.providerWrites | Should -Be 0
            $resolved.event.providerWriteState | Should -BeExactly unknown
            $case.State.StatusWrites | Should -Be 1
            $case.State.Posts | Should -Be 1
        }

        It 'never posts after a failed unconfirmed or absent transition (<Mode>)' `
            -TestCases @(
                @{ Mode = 'status-failed' }
                @{ Mode = 'status-unconfirmed' }
                @{ Mode = 'already-abandoned' }
                @{ Mode = 'recent' }
            ) {
            param($Mode)
            $case = New-ExplanationCase -Mode $Mode `
                -RecentActivity $(if ($Mode -ceq 'recent') {
                    '2026-01-01T00:00:00Z'
                } else { '' })
            if ($Mode -ceq 'already-abandoned') {
                $case.State.Status = 'abandoned'
            }
            $arguments = $case.Arguments
            $result = Invoke-StalePrLifecycle @arguments
            $result.explanationWrites | Should -Be 0
            $case.State.Posts | Should -Be 0
        }

        It 'retains confirmed status and locks uncertain explanation (<Mode>)' `
            -TestCases @(
                @{ Mode = 'post-unknown' }
                @{ Mode = 'post-rejected' }
                @{ Mode = 'readback-failed' }
                @{ Mode = 'wrong-body' }
                @{ Mode = 'wrong-author' }
                @{ Mode = 'duplicate' }
            ) {
            param($Mode)
            $case = New-ExplanationCase -Mode $Mode
            $arguments = $case.Arguments
            $result = Invoke-StalePrLifecycle @arguments
            $result.health | Should -BeExactly unknown
            $result.providerWrites | Should -Be 2
            $result.statusWrites | Should -Be 1
            $result.explanationWrites | Should -Be 1
            $result.unconfirmedStatusWrites | Should -Be 0
            $result.unconfirmedExplanationWrites | Should -Be 1
            $result.confirmedAbandonedIds | Should -Be @(1)
            $result.decisions[0].explanation.state | Should -BeExactly unknown
            $event = $result.explanationEvents[0]
            $case.State.Status = 'active'
            $second = Invoke-StalePrLifecycle @arguments
            $second.providerWrites | Should -Be 0
            $second.decisions[0].reason | Should -BeExactly prior-ambiguous-explanation
            $case.State.Status = 'abandoned'
            $reconcile = @{
                LifecycleRoot = $case.Root.Context.Root
                PullRequestId = 1
                StatusIntentId = $event.statusIntentId
                Policy = $case.Policy
                Key = $case.Root.Key
                Provider = $arguments.Provider
            }
            $resolved = Resolve-StalePrLifecycleExplanation @reconcile
            $resolved.state | Should -BeExactly unknown
            $resolved.providerWrites | Should -Be 0
            $case.State.Posts | Should -Be 1
            $case.State.StatusWrites | Should -Be 1
        }

        It 'reconciles accepted POST errors only by exact body and actor readback' {
            $case = New-ExplanationCase -Mode post-accepted-error
            $arguments = $case.Arguments
            $result = Invoke-StalePrLifecycle @arguments
            $result.health | Should -BeExactly healthy
            $result.providerWrites | Should -Be 2
            $result.unconfirmedExplanationWrites | Should -Be 0
            $result.decisions[0].explanation.state | Should -BeExactly confirmed
            $case.State.Posts | Should -Be 1
        }

        It 'does not POST when complete duplicate checking cannot be proven' {
            $case = New-ExplanationCase -Mode incomplete
            $arguments = $case.Arguments
            $result = Invoke-StalePrLifecycle @arguments
            $result.health | Should -BeExactly unknown
            $result.statusWrites | Should -Be 1
            $result.explanationWrites | Should -Be 0
            $result.confirmedAbandonedIds | Should -Be @(1)
            $case.State.Posts | Should -Be 0
        }

        It 'keeps additional explanation reads inside the original shared budget (<Reads>)' `
            -TestCases @(
                @{ Reads = 10; ExpectedPosts = 0 }
                @{ Reads = 11; ExpectedPosts = 1 }
            ) {
            param($Reads, $ExpectedPosts)
            $case = New-ExplanationCase -MaximumReads $Reads
            $arguments = $case.Arguments
            $result = Invoke-StalePrLifecycle @arguments
            $result.health | Should -BeExactly unknown
            $result.providerReadCount | Should -Be $Reads
            $result.statusWrites | Should -Be 1
            $result.explanationWrites | Should -Be $ExpectedPosts
            $result.confirmedAbandonedIds | Should -Be @(1)
            $case.State.Posts | Should -Be $ExpectedPosts
        }

        It 'does not widen elapsed or response-size bounds for explanations (<Mode>)' `
            -TestCases @(
                @{ Mode = 'deadline-preflight'; ExpectedPosts = 0 }
                @{ Mode = 'deadline-post'; ExpectedPosts = 1 }
                @{ Mode = 'oversized-readback'; ExpectedPosts = 1 }
            ) {
            param($Mode, $ExpectedPosts)
            $case = New-ExplanationCase -Mode $Mode
            $arguments = $case.Arguments
            $result = Invoke-StalePrLifecycle @arguments
            $result.health | Should -BeExactly unknown
            $result.confirmedAbandonedIds | Should -Be @(1)
            $result.statusWrites | Should -Be 1
            $result.explanationWrites | Should -Be $ExpectedPosts
            $case.State.Posts | Should -Be $ExpectedPosts
            $case.State.StatusWrites | Should -Be 1
        }

        It 'retains the 128-GET and 240-second hard ceilings under broader config' {
            $case = New-ExplanationCase
            $case.Config.subjectProvider.maximumReads = 1000
            $case.Config.limits.maxReads = 1000
            $case.Config.limits.maxSeconds = 720
            $clock = [ref]([DateTime]::UtcNow)
            $provider = New-StalePrAzureDevOpsProvider `
                -Config $case.Config -Policy $case.Policy `
                -TokenInvoker { @{ accessToken = 't' * 120 } } `
                -UtcNowProvider { $clock.Value }.GetNewClosure() `
                -HttpInvoker (New-AzLifecycleInvoker)
            1..128 | ForEach-Object { [void](& $provider Identity @{}) }
            { & $provider Identity @{} } |
                Should -Throw '*stale-pr-read-budget-exhausted*'
            $provider.StalePrBudget.Count | Should -Be 128
            ($provider.StalePrBudget.DeadlineUtc - $clock.Value).TotalSeconds |
                Should -Be 240
        }

        It 'keeps old-candidate scans bounded at 200 with continuation' {
            $casePolicy = New-StalePrLifecyclePolicy -Config $config `
                -RepoRoot $repo -AllowDirty -EnableAbandonmentExplanation
            $evidence = @{}
            $inventory = @(1..201 | ForEach-Object {
                    $evidence[$_] = New-LifecycleEvidence -Id $_ `
                        -ActivityUtc '2026-01-01T00:00:00Z'
                    [ordered]@{
                        pullRequestId = $_; status = 'active'; isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc = '2024-01-01T00:00:00Z'
                    }
                })
            $provider = New-LifecycleProvider -EvidenceById $evidence
            $result = Invoke-LifecycleCase -Provider $provider.Handler `
                -Inventory $inventory -InputPolicy $casePolicy
            @($result.decisions) | Should -HaveCount 200
            $result.nextPullRequestId | Should -Be 201
            $result.providerWrites | Should -Be 0
            @($provider.Calls | Where-Object { $_ -ceq 'ReadEvidence:201' }) |
                Should -HaveCount 0
        }

        It 'never lets its own explanation bootstrap a later stale decision' {
            $case = New-ExplanationCase
            $arguments = $case.Arguments
            $first = Invoke-StalePrLifecycle @arguments
            $first.confirmedAbandonedIds | Should -Be @(1)
            $case.State.Status = 'active'
            $second = Invoke-StalePrLifecycle @arguments
            $second.providerWrites | Should -Be 0
            $second.decisions[0].reason | Should -BeExactly recent-activity
            $case.State.StatusWrites | Should -Be 1
            $case.State.Posts | Should -Be 1
        }

        It 'reconciles a later visible exact comment without repeating either write' {
            $case = New-ExplanationCase -Mode readback-failed
            $arguments = $case.Arguments
            $first = Invoke-StalePrLifecycle @arguments
            $first.unconfirmedExplanationWrites | Should -Be 1
            $case.State.Mode = 'confirmed'
            $resolved = Resolve-StalePrLifecycleExplanation `
                -LifecycleRoot $case.Root.Context.Root -PullRequestId 1 `
                -StatusIntentId $first.explanationEvents[0].statusIntentId `
                -Policy $case.Policy -Key $case.Root.Key `
                -Provider $arguments.Provider
            $resolved.state | Should -BeExactly confirmed -Because (
                $resolved | ConvertTo-Json -Depth 16 -Compress)
            $resolved.providerWrites | Should -Be 0
            $resolved.event.operation | Should -BeExactly reconcile
            $resolved.event.providerWriteCount | Should -Be 0
            $case.State.Posts | Should -Be 1
            $case.State.StatusWrites | Should -Be 1
        }

        It 'retains a missing original outcome as uncertain attempt accounting during reconciliation' {
            $case = New-ExplanationCase -Mode readback-failed
            $arguments = $case.Arguments
            $first = Invoke-StalePrLifecycle @arguments
            $transition = $first.explanationEvents[0].statusIntentId
            Remove-Item -LiteralPath (
                Join-Path $case.Root.Context.Root (
                    "explanations\outcomes\1\$transition.json")) -Force
            $case.State.Mode = 'confirmed'
            $resolved = Resolve-StalePrLifecycleExplanation `
                -LifecycleRoot $case.Root.Context.Root -PullRequestId 1 `
                -StatusIntentId $transition -Policy $case.Policy `
                -Key $case.Root.Key -Provider $arguments.Provider
            $resolved.state | Should -BeExactly confirmed
            $resolved.providerWrites | Should -Be 0
            $resolved.event.originalAttemptCount | Should -BeNullOrEmpty
            $resolved.event.originalAttemptCeiling | Should -Be 1
            $case.State.Posts | Should -Be 1
        }

        It 'refuses to reconcile under a different policy identity' {
            $case = New-ExplanationCase -Mode post-unknown
            $arguments = $case.Arguments
            $first = Invoke-StalePrLifecycle @arguments
            $case.Policy.authority.maxCandidatesPerRun = 199
            {
                Resolve-StalePrLifecycleExplanation `
                    -LifecycleRoot $case.Root.Context.Root -PullRequestId 1 `
                    -StatusIntentId $first.explanationEvents[0].statusIntentId `
                    -Policy $case.Policy -Key $case.Root.Key `
                    -Provider $arguments.Provider
            } | Should -Throw '*reconciliation-binding-changed*'
            $case.State.Posts | Should -Be 1
        }

        It 'rejects widened or malformed explanation authority (<Field>)' `
            -TestCases @(
                @{ Field = 'maxPerRun'; Value = 2 }
                @{ Field = 'maxPerTransition'; Value = $true }
                @{ Field = 'retryAmbiguousPost'; Value = $true }
                @{ Field = 'exactReadbackRequired'; Value = $false }
                @{ Field = 'action'; Value = 'comment:any' }
            ) {
            param($Field, $Value)
            $case = New-ExplanationCase
            $case.Policy.authority.abandonmentExplanation[$Field] = $Value
            $arguments = $case.Arguments
            { Invoke-StalePrLifecycle @arguments } |
                Should -Throw '*explanation authority is invalid*'
            $case.State.StatusWrites | Should -Be 0
            $case.State.Posts | Should -Be 0
        }

        It 'rejects partial lifecycle action protocols (<Shape>, <Mutation>)' `
            -TestCases @(
                foreach ($shape in @('native', 'dictionary')) {
                    foreach ($mutation in @(
                            'orphan-status', 'orphan-comment', 'orphan-null',
                            'partial-missing', 'null-attempts', 'boolean-status',
                            'boolean-comment', 'boolean-unconfirmed-status',
                            'boolean-unconfirmed-comment', 'total-mismatch',
                            'unconfirmed-status-exceeds', 'unconfirmed-comment-exceeds')) {
                        @{ Shape = $shape; Mutation = $mutation }
                    }
                }
            ) {
            param($Shape, $Mutation)
            $case = New-ExplanationCase
            $arguments = $case.Arguments
            $arguments.Inventory += [ordered]@{
                pullRequestId = 2; status = 'active'; isDraft = $false
                targetRef = 'refs/heads/master'
                creationUtc = '2024-01-01T00:00:00Z'
            }
            $headCalls = [Collections.Generic.List[int]]::new()
            $activeProvider = {
                param($Operation, $Request)
                switch ($Operation) {
                    Identity { return $case.Config.expectedAccount }
                    ListPage {
                        $items = if ([int]$Request.skip -eq 0) {
                            @($arguments.Inventory)
                        } else { @() }
                        return @{ items = @($items); count = @($items).Count; totalCount = 2 }
                    }
                    Head {
                        [void]$headCalls.Add([int]$Request.pullRequestId)
                        throw 'Unverified lifecycle eligibility must not reach acquisition.'
                    }
                    default { throw "Unexpected counter-protocol operation: $Operation" }
                }
            }.GetNewClosure()
            $capture = @{}
            $evaluator = {
                param($Inventory)
                $native = Invoke-StalePrLifecycle @arguments
                $capture.native = $native
                $value = [ordered]@{}
                foreach ($property in $native.PSObject.Properties) {
                    $value[$property.Name] = $property.Value
                }
                $value.reviewEligibleIds = @(2)
                switch ($Mutation) {
                    { $_ -cin @('orphan-status', 'orphan-comment', 'orphan-null') } {
                        foreach ($name in @('statusWrites', 'explanationWrites',
                                'unconfirmedStatusWrites', 'unconfirmedExplanationWrites')) {
                            $value.Remove($name)
                        }
                        if ($Mutation -ceq 'orphan-comment') {
                            $value['unconfirmedExplanationWrites'] = 1
                        }
                        else {
                            $value['unconfirmedStatusWrites'] = $(if (
                                $Mutation -ceq 'orphan-null'
                            ) { $null } else { 1 })
                        }
                    }
                    partial-missing { $value.Remove('unconfirmedExplanationWrites') }
                    null-attempts { $value.statusWrites = $null; $value.explanationWrites = $null }
                    boolean-status { $value.statusWrites = $true }
                    boolean-comment { $value.explanationWrites = $true }
                    boolean-unconfirmed-status { $value.unconfirmedStatusWrites = $false }
                    boolean-unconfirmed-comment { $value.unconfirmedExplanationWrites = $false }
                    total-mismatch { $value.explanationWrites = 0 }
                    unconfirmed-status-exceeds { $value.statusWrites = 0; $value.unconfirmedStatusWrites = 1 }
                    unconfirmed-comment-exceeds { $value.explanationWrites = 0; $value.unconfirmedExplanationWrites = 1 }
                }
                if ($Shape -ceq 'native') { return [pscustomobject]$value }
                return $value
            }.GetNewClosure()
            $result = Invoke-ActivePrIntake -Config $case.Config `
                -Provider $activeProvider -RepositoryRoot $repo `
                -StateRoot (Join-Path $case.Root.Context.Root 'intake') `
                -LifecycleEvaluator $evaluator -IncludeTransientSnapshots -Run
            $capture.native.GetType().FullName |
                Should -BeExactly 'System.Management.Automation.PSCustomObject'
            $result.lifecycle.diagnostic | Should -BeExactly lifecycle-result-invalid
            $result.lifecycle.health | Should -BeExactly unknown
            $result.lifecycle.providerWrites | Should -Be 2
            $result.lifecycle.statusWrites | Should -BeNullOrEmpty
            $result.lifecycle.explanationWrites | Should -BeNullOrEmpty
            $result.lifecycle.unconfirmedStatusWrites | Should -BeNullOrEmpty
            $result.lifecycle.unconfirmedExplanationWrites | Should -BeNullOrEmpty
            $result.lifecycle.unknownPossibleEffect | Should -BeTrue
            $result.lifecycle.confirmedAbandonedIds | Should -HaveCount 0
            $result.lifecycle.reviewEligibleIds | Should -HaveCount 0
            @($result.transientSnapshots.Keys) | Should -HaveCount 0
            $headCalls | Should -HaveCount 0
            $case.State.StatusWrites | Should -Be 1
            $case.State.Posts | Should -Be 1
            $tokens = $null
            $parseErrors = $null
            $toolAst = [Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $repo 'tools\Invoke-SharedReviewAcquisition.ps1'),
                [ref]$tokens, [ref]$parseErrors)
            $parseErrors | Should -HaveCount 0
            $summaryAst = @($toolAst.FindAll({
                        param($node)
                        $node -is [Management.Automation.Language.HashtableAst] -and
                        @($node.KeyValuePairs | Where-Object {
                                $_.Item1.Extent.Text -ceq 'lifecycleStatusWrites'
                            }).Count -eq 1
                    }, $true))
            $summaryAst | Should -HaveCount 1
            $intake = $result
            $generationFiles = @(Get-ChildItem -LiteralPath (
                    Join-Path $case.Root.Context.Root 'intake') -Recurse -File `
                    -Filter "$($result.generation).json")
            $generationFiles | Should -HaveCount 1
            $path = $generationFiles[0].FullName
            $transientSnapshots = @{}
            $blobKeys = @()
            $summary = & ([scriptblock]::Create($summaryAst[0].Parent.Extent.Text)) |
                ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32
            $summary.providerWrites | Should -Be 2
            $summary.lifecycleProviderWrites | Should -Be 2
            foreach ($name in @('lifecycleStatusWrites', 'lifecycleExplanationWrites',
                    'lifecycleUnconfirmedStatusWrites', 'lifecycleUnconfirmedExplanationWrites')) {
                $summary.Contains($name) | Should -BeTrue
                $summary[$name] | Should -BeNullOrEmpty
            }
            $summary.lifecycleReviewEligibleIds | Should -HaveCount 0
        }

        It 'keeps both native result shapes truthful on consumer failure (<Shape>, <Mode>, <BadCursor>)' `
            -TestCases @(
                @{ Shape = 'native'; Mode = 'confirmed'; BadCursor = $false }
                @{ Shape = 'dictionary'; Mode = 'confirmed'; BadCursor = $false }
                @{ Shape = 'native'; Mode = 'confirmed'; BadCursor = $true }
                @{ Shape = 'dictionary'; Mode = 'confirmed'; BadCursor = $true }
                @{ Shape = 'native'; Mode = 'post-unknown'; BadCursor = $true }
                @{ Shape = 'dictionary'; Mode = 'post-unknown'; BadCursor = $true }
            ) {
            param($Shape, $Mode, $BadCursor)
            $case = New-ExplanationCase -Mode $Mode
            $arguments = $case.Arguments
            $activeProvider = {
                param($Operation, $Request)
                switch ($Operation) {
                    Identity { return $case.Config.expectedAccount }
                    ListPage {
                        $items = if ([int]$Request.skip -eq 0) {
                            @($arguments.Inventory)
                        } else { @() }
                        return @{
                            items = @($items)
                            count = @($items).Count
                            totalCount = 1
                        }
                    }
                    default { throw "Unexpected acquisition after abandonment: $Operation" }
                }
            }.GetNewClosure()
            $capture = @{}
            $evaluator = {
                param($Inventory)
                $native = Invoke-StalePrLifecycle @arguments
                $capture.native = $native
                $result = if ($Shape -ceq 'dictionary') {
                    $dictionary = [ordered]@{}
                    foreach ($property in $native.PSObject.Properties) {
                        $dictionary[$property.Name] = $property.Value
                    }
                    $dictionary
                } else { $native }
                if ($BadCursor) { $result.nextPullRequestId = 999L }
                return $result
            }.GetNewClosure()
            $result = Invoke-ActivePrIntake -Config $case.Config `
                -Provider $activeProvider `
                -StateRoot (Join-Path $case.Root.Context.Root 'intake') `
                -RepositoryRoot $repo -LifecycleEvaluator $evaluator `
                -IncludeTransientSnapshots -Run
            $capture.native.GetType().FullName |
                Should -BeExactly 'System.Management.Automation.PSCustomObject'
            $result.lifecycle.providerWrites | Should -Be 2
            $result.lifecycle.statusWrites | Should -Be 1
            $result.lifecycle.explanationWrites | Should -Be 1
            $result.lifecycle.unconfirmedStatusWrites | Should -Be 0
            $result.lifecycle.unconfirmedExplanationWrites |
                Should -Be ([int]($Mode -ceq 'post-unknown'))
            $result.lifecycle.confirmedAbandonedIds | Should -Be @(1)
            $result.lifecycle.unknownPossibleEffect |
                Should -Be ($Mode -ceq 'post-unknown')
            @($result.transientSnapshots.Keys) | Should -HaveCount 0
            if ($BadCursor) {
                $result.lifecycle.diagnostic |
                    Should -BeExactly lifecycle-cursor-invalid
                $result.lifecycle.events | Should -HaveCount 1
                $result.lifecycle.explanationEvents | Should -HaveCount 1
            }
        }
    }

    It 'fails the actual Named host closed for a bare true lifecycle switch' {
        $root = Join-Path $env:USERPROFILE (
            '.copilot\named-lifecycle-config-pester-' +
            [guid]::NewGuid().ToString('N'))
        [void]$script:roots.Add($root)
        [void](New-Item -ItemType Directory `
                -Path $root -Force)
        $namedConfig = Get-Content -LiteralPath (
            Join-Path $repo `
                'samples\named-areequal-current-pr.config.json') `
            -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
        $namedConfig.stalePullRequestLifecycle =
            $true
        $configPath = Join-Path $root `
            'named-invalid-lifecycle.json'
        [IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $namedConfig `
                -Depth 64),
            [Text.UTF8Encoding]::new($false))

        {
            & (Join-Path $repo `
                    'tools\Invoke-SharedReviewAcquisition.ps1') `
                -ConfigPath $configPath `
                -StateRoot (Join-Path $root 'state') `
                -AcquisitionPath (
                    Join-Path $root 'acquisition.json') `
                -AzureCliPath 'unused-az' `
                -RepoRoot $repo
        } | Should -Throw (
            '*requires an exact signed policy binding*')
    }
}

Describe 'Signed lifecycle push-date and recent-activity proof persistence' {
    It 'preserves exact read-count diagnostic when push-detail GET exhausts the read budget' {
        $boundedConfig = $config | ConvertTo-Json -Depth 32 |
            ConvertFrom-Json -AsHashtable -Depth 32
        $boundedConfig.subjectProvider.maximumReads = 5
        $detailReads = 0
        $provider = New-TestAzureDevOpsLifecycleProvider `
            -InputConfig $boundedConfig -HttpInvoker (
                New-AzLifecycleInvoker `
                    -MissingSummaryPushDate `
                    -PushDetailReads ([ref]$detailReads))

        $result = Invoke-LifecycleCase `
            -Provider $provider -InputPolicy $policy `
            -Inventory @([ordered]@{
                    pullRequestId = 1
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                })

        $detailReads | Should -Be 0
        $result.health | Should -BeExactly partial
        $result.providerReadCount | Should -Be 5
        @($result.decisions) | Should -HaveCount 1
        $result.decisions[0].pullRequestId | Should -Be 1
        $result.decisions[0].state | Should -BeExactly deferred
        $result.decisions[0].reason |
            Should -BeExactly 'stale-pr-read-budget-exhausted'
        $result.decisions[0].diagnostic | Should -Not -BeNullOrEmpty
        $result.decisions[0].diagnostic.kind |
            Should -BeExactly 'read-count'
        $result.decisions[0].diagnostic.readCount | Should -Be 5
        $result.decisions[0].diagnostic.readCeiling | Should -Be 5
        $result.decisions[0].diagnostic.responseByteCeiling |
            Should -Be 16777216
        $result.decisions[0].diagnostic.deadlineUtc |
            Should -Not -BeNullOrEmpty
    }

    It 'completes a 62-push PR in 1 run when the newest push is recent and resumes across 2 runs via write-once signed push dates when only the oldest push is recent' {
        $boundedConfig = $config | ConvertTo-Json -Depth 32 |
            ConvertFrom-Json -AsHashtable -Depth 32
        $boundedConfig.subjectProvider.maximumReads = 40
        $iterations = @(1..62 | ForEach-Object {
                @{
                    id = [int]$_
                    createdDate = '2024-02-01T00:00:00Z'
                    updatedDate = '2024-02-01T00:00:00Z'
                    push = @{
                        pushId = [long]$_
                        date = $null
                    }
                    sourceRefCommit = @{ commitId = ('a' * 40) }
                    targetRefCommit = @{ commitId = ('b' * 40) }
                }
            })
        $recentPushId = [ref]62L
        $pushReads = [Collections.Generic.List[long]]::new()
        $invoker = {
            param($Request)
            $uri = [Uri]$Request.Uri
            $path = $uri.AbsolutePath
            $query = $uri.Query
            $method = [string]$Request.Method
            if ($path -clike '*/_apis/connectionData') {
                return @{
                    authenticatedUser = @{
                        id = '33333333-3333-3333-3333-333333333333'
                        subjectDescriptor = 'aad.synthetic-service-account'
                    }
                    authorizedUser = @{
                        id = '33333333-3333-3333-3333-333333333333'
                        subjectDescriptor = 'aad.synthetic-service-account'
                    }
                }
            }
            if ($path -match '/pullRequests/8453745$' -and $method -ceq 'GET') {
                return @{
                    pullRequestId = 8453745L
                    status = 'active'
                    isDraft = $false
                    creationDate = '2024-01-01T00:00:00Z'
                    sourceRefName = 'refs/heads/feature/8453745'
                    targetRefName = 'refs/heads/master'
                    lastMergeSourceCommit = @{ commitId = ('a' * 40) }
                    lastMergeTargetCommit = @{ commitId = ('b' * 40) }
                    repository = @{
                        id = '11111111-1111-1111-1111-111111111111'
                        project = @{ id = '22222222-2222-2222-2222-222222222222' }
                    }
                }
            }
            if ($path -match '/pullRequests/8453745/iterations$') {
                return @{
                    value = $iterations
                    count = $iterations.Count
                    continuation_token = $null
                }
            }
            if ($path -match '/pullRequests/8453745/threads$') {
                return @{
                    value = @()
                    count = 0
                    continuation_token = $null
                }
            }
            if ($path -match '/refs$' -and $query -match 'heads%2Ffeature%2F8453745') {
                return @{
                    value = @(@{
                            name = 'refs/heads/feature/8453745'
                            objectId = ('a' * 40)
                        })
                    count = 1
                    continuation_token = $null
                }
            }
            if ($path -match '/pushes/(?<pushId>\d+)$') {
                $pushId = [long]$Matches.pushId
                [void]$pushReads.Add($pushId)
                return @{
                    pushId = $pushId
                    date = $(if ($pushId -eq $recentPushId.Value) {
                            '2026-02-01T00:00:00Z'
                        } else {
                            '2024-03-01T00:00:00Z'
                        })
                    repository = @{
                        id = '11111111-1111-1111-1111-111111111111'
                        project = @{ id = '22222222-2222-2222-2222-222222222222' }
                    }
                }
            }
            throw "Unexpected request: $method $($uri.AbsoluteUri)"
        }.GetNewClosure()

        # Subcase A: newest iteration push (pushId=62) is recent -> completes in 1 run with 1 push GET
        $rootNewest = New-LifecycleRoot
        try {
            $inventory = @([ordered]@{
                    pullRequestId = 8453745
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                })
            $cutoff = [DateTime]::SpecifyKind(
                [DateTime]'2025-01-01T00:00:00',
                [DateTimeKind]::Utc)
            $providerNewest = New-TestAzureDevOpsLifecycleProvider `
                -InputConfig $boundedConfig -HttpInvoker $invoker
            $runNewest = Invoke-StalePrLifecycle `
                -Inventory $inventory -CutoffUtc $cutoff `
                -Policy $policy -LifecycleRoot $rootNewest.Context.Root `
                -Key $rootNewest.Key -Provider $providerNewest

            $runNewest.health | Should -BeExactly healthy
            $runNewest.providerReadCount | Should -Be 6
            $runNewest.decisions[0].state | Should -BeExactly 'no-op'
            $runNewest.decisions[0].reason | Should -BeExactly 'recent-activity'
            $runNewest.reviewEligibleIds | Should -Be @(8453745)
            @($pushReads) | Should -Be @(62L)
        }
        finally {
            [Array]::Clear($rootNewest.Key, 0, $rootNewest.Key.Length)
        }

        # Subcase B: only the oldest push (pushId=1) is recent while 62..2 are stale -> resumes across 2 runs under 40-GET ceiling
        $pushReads.Clear()
        $recentPushId.Value = 1L
        $rootResume = New-LifecycleRoot
        try {
            $inventory = @([ordered]@{
                    pullRequestId = 8453745
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                })
            $cutoff = [DateTime]::SpecifyKind(
                [DateTime]'2025-01-01T00:00:00',
                [DateTimeKind]::Utc)
            $provider1 = New-TestAzureDevOpsLifecycleProvider `
                -InputConfig $boundedConfig -HttpInvoker $invoker
            $run1 = Invoke-StalePrLifecycle `
                -Inventory $inventory -CutoffUtc $cutoff `
                -Policy $policy -LifecycleRoot $rootResume.Context.Root `
                -Key $rootResume.Key -Provider $provider1

            $run1.health | Should -BeExactly partial
            $run1.providerReadCount | Should -Be 40
            $run1.decisions[0].state | Should -BeExactly deferred
            $run1.decisions[0].reason |
                Should -BeExactly 'stale-pr-read-budget-exhausted'
            $run1.decisions[0].diagnostic.kind |
                Should -BeExactly 'read-count'
            $run1.decisions[0].diagnostic.readCount | Should -Be 40
            $run1.decisions[0].diagnostic.readCeiling | Should -Be 40
            $pushReads.Count | Should -Be 35
            $cachedFiles = @(Get-ChildItem -LiteralPath (
                    Join-Path $rootResume.Context.Root 'pushes\8453745') `
                    -Filter '*.json' -File)
            $cachedFiles | Should -HaveCount 35
            $firstSigned = Read-StalePrLifecyclePolicy `
                -Path $cachedFiles[0].FullName -Key $rootResume.Key
            $firstSigned.kind | Should -BeExactly 'stale-pr-push-date-v1'

            $provider2 = New-TestAzureDevOpsLifecycleProvider `
                -InputConfig $boundedConfig -HttpInvoker $invoker
            $run2 = Invoke-StalePrLifecycle `
                -Inventory $inventory -CutoffUtc $cutoff `
                -Policy $policy -LifecycleRoot $rootResume.Context.Root `
                -Key $rootResume.Key -Provider $provider2

            $run2.health | Should -BeExactly healthy
            $run2.providerReadCount | Should -Be 32
            $run2.decisions[0].state | Should -BeExactly 'no-op'
            $run2.decisions[0].reason | Should -BeExactly 'recent-activity'
            $run2.reviewEligibleIds | Should -Be @(8453745)
            $pushReads.Count | Should -Be 62
            @(Get-ChildItem -LiteralPath (
                    Join-Path $rootResume.Context.Root 'pushes\8453745') `
                    -Filter '*.json' -File) | Should -HaveCount 62
            @(Get-ChildItem -LiteralPath (
                    Join-Path $rootResume.Context.Root 'activity-proofs\8453745') `
                    -Filter '*.json' -File) | Should -HaveCount 1
        }
        finally {
            [Array]::Clear($rootResume.Key, 0, $rootResume.Key.Length)
        }
    }

    It 'reproduces and resolves both parent 8960 review blockers (refuses 5-key inventory items without current head/iteration/activity identity and fails closed on directory-blocked invalidation)' {
        $root = New-LifecycleRoot
        try {
            $cutoff = [DateTime]::SpecifyKind(
                [DateTime]'2025-01-01T00:00:00',
                [DateTimeKind]::Utc)
            $policyDigest = InModuleScope DevPilot.PullRequestLifecycle {
                param($Pol)
                Get-StalePrDigest $Pol
            } -Parameters @{ Pol = $policy }

            $evidence = [ordered]@{
                projectId = '22222222-2222-2222-2222-222222222222'
                repositoryId = '11111111-1111-1111-1111-111111111111'
                pullRequestId = 42L
                status = 'active'
                isDraft = $false
                sourceRef = 'refs/heads/feature-42'
                targetRef = 'refs/heads/master'
                sourceCommit = ('a' * 40)
                targetCommit = ('b' * 40)
                iterationId = 3
                creationUtc = '2024-01-01T00:00:00.0000000Z'
                latestActivityUtc = '2026-03-01T00:00:00.0000000Z'
                activityDigest = 'v1:sha256:' + ('c' * 64)
            }

            InModuleScope DevPilot.PullRequestLifecycle {
                param($RootPath, $KeyBytes, $Ev, $PolDigest)
                Write-StalePrActivityProof `
                    -LifecycleRoot $RootPath `
                    -PullRequestId 42L `
                    -Evidence $Ev `
                    -PolicyDigest $PolDigest `
                    -Key $KeyBytes
            } -Parameters @{
                RootPath = $root.Context.Root
                KeyBytes = $root.Key
                Ev = $evidence
                PolDigest = $policyDigest
            }

            # Real 5-key normalized inventory shape from Discover-ActivePrInventory MUST be refused
            $fiveKeyInventoryItem = [ordered]@{
                pullRequestId = 42L
                status = 'active'
                isDraft = $false
                targetRef = 'refs/heads/master'
                creationUtc = '2024-01-01T00:00:00.0000000Z'
            }
            $fiveKeyProof = InModuleScope DevPilot.PullRequestLifecycle {
                param($RootPath, $KeyBytes, $Item, $Cut, $Pol, $PolDigest)
                Get-StalePrCachedActivityProof `
                    -LifecycleRoot $RootPath `
                    -PullRequestId 42L `
                    -Item $Item `
                    -CutoffUtc $Cut `
                    -Policy $Pol `
                    -PolicyDigest $PolDigest `
                    -Key $KeyBytes
            } -Parameters @{
                RootPath = $root.Context.Root
                KeyBytes = $root.Key
                Item = $fiveKeyInventoryItem
                Cut = $cutoff
                Pol = $policy
                PolDigest = $policyDigest
            }
            $fiveKeyProof | Should -BeNullOrEmpty

            # Full 13-key current identity item succeeds when all 13 fields match
            $fullIdentityProof = InModuleScope DevPilot.PullRequestLifecycle {
                param($RootPath, $KeyBytes, $Item, $Cut, $Pol, $PolDigest)
                Get-StalePrCachedActivityProof `
                    -LifecycleRoot $RootPath `
                    -PullRequestId 42L `
                    -Item $Item `
                    -CutoffUtc $Cut `
                    -Policy $Pol `
                    -PolicyDigest $PolDigest `
                    -Key $KeyBytes
            } -Parameters @{
                RootPath = $root.Context.Root
                KeyBytes = $root.Key
                Item = $evidence
                Cut = $cutoff
                Pol = $policy
                PolDigest = $policyDigest
            }
            $fullIdentityProof | Should -Not -BeNullOrEmpty

            # Explicit different head control refuses
            $differentHead = [ordered]@{} + $evidence
            $differentHead['sourceCommit'] = ('d' * 40)
            $differentHeadProof = InModuleScope DevPilot.PullRequestLifecycle {
                param($RootPath, $KeyBytes, $Item, $Cut, $Pol, $PolDigest)
                Get-StalePrCachedActivityProof `
                    -LifecycleRoot $RootPath `
                    -PullRequestId 42L `
                    -Item $Item `
                    -CutoffUtc $Cut `
                    -Policy $Pol `
                    -PolicyDigest $PolDigest `
                    -Key $KeyBytes
            } -Parameters @{
                RootPath = $root.Context.Root
                KeyBytes = $root.Key
                Item = $differentHead
                Cut = $cutoff
                Pol = $policy
                PolDigest = $policyDigest
            }
            $differentHeadProof | Should -BeNullOrEmpty

            # Blocker 2: directory collision at seq-00000002-withheld.json must surface error AND fail closed
            $blockingDirectory = Join-Path $root.Context.Root (
                'activity-proofs\42\seq-00000002-withheld.json')
            [void](New-Item -ItemType Directory -Path $blockingDirectory -Force)

            $invalidationError = $null
            try {
                InModuleScope DevPilot.PullRequestLifecycle {
                    param($RootPath, $KeyBytes, $PolDigest)
                    Disable-StalePrCachedActivityProof `
                        -LifecycleRoot $RootPath `
                        -PullRequestId 42L `
                        -PolicyDigest $PolDigest `
                        -Key $KeyBytes
                } -Parameters @{
                    RootPath = $root.Context.Root
                    KeyBytes = $root.Key
                    PolDigest = $policyDigest
                }
            }
            catch {
                $invalidationError = $_.Exception.Message
            }
            $invalidationError |
                Should -BeExactly 'stale-pr-activity-proof-invalidation-failed'

            $proofAfterFailedInvalidation = InModuleScope DevPilot.PullRequestLifecycle {
                param($RootPath, $KeyBytes, $Item, $Cut, $Pol, $PolDigest)
                Get-StalePrCachedActivityProof `
                    -LifecycleRoot $RootPath `
                    -PullRequestId 42L `
                    -Item $Item `
                    -CutoffUtc $Cut `
                    -Policy $Pol `
                    -PolicyDigest $PolDigest `
                    -Key $KeyBytes
            } -Parameters @{
                RootPath = $root.Context.Root
                KeyBytes = $root.Key
                Item = $evidence
                Cut = $cutoff
                Pol = $policy
                PolDigest = $policyDigest
            }
            $proofAfterFailedInvalidation | Should -BeNullOrEmpty
        }
        finally {
            [Array]::Clear($root.Key, 0, $root.Key.Length)
        }
    }

    It 'wires Discover-ActivePrInventory -> Invoke-ActivePrIntake -> Invoke-StalePrLifecycle safely on 5-key items and detects comment deletion, bot comment edits, new pushes, head drift, and cutoff drift' {
        $intakeManifest = Join-Path $PSScriptRoot (
            '..\src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1')
        Import-Module $intakeManifest -Force

        $root = New-LifecycleRoot
        try {
            $cutoff = [DateTime]::SpecifyKind(
                [DateTime]'2025-01-01T00:00:00',
                [DateTimeKind]::Utc)
            $pr8453745PushCount = [ref]62
            $pr8453745NewestPushUtc = [ref]'2026-02-01T00:00:00Z'
            $pr8453745SourceCommit = [ref]('a' * 40)
            $pr8453745RefCommit = [ref]('a' * 40)
            $pr8453745Threads = [ref]@()
            $pr8453745Status = [ref]'active'
            $patchCalls = [ref]0
            $pushReads = [Collections.Generic.List[long]]::new()

            $httpInvoker = {
                param($Request)
                $uri = [Uri]$Request.Uri
                $path = $uri.AbsolutePath
                $query = $uri.Query
                $method = [string]$Request.Method
                if ($path -clike '*/_apis/connectionData') {
                    return @{
                        authenticatedUser = @{
                            id = '33333333-3333-3333-3333-333333333333'
                            subjectDescriptor = 'aad.synthetic-service-account'
                        }
                        authorizedUser = @{
                            id = '33333333-3333-3333-3333-333333333333'
                            subjectDescriptor = 'aad.synthetic-service-account'
                        }
                    }
                }
                if ($path -match '/pullRequests/8453745$' -and $method -ceq 'PATCH') {
                    $patchCalls.Value++
                    $pr8453745Status.Value = 'abandoned'
                    return @{
                        pullRequestId = 8453745L
                        status = 'abandoned'
                    }
                }
                if ($path -match '/pullRequests/8453745$' -and $method -ceq 'GET') {
                    return @{
                        pullRequestId = 8453745L
                        status = [string]$pr8453745Status.Value
                        isDraft = $false
                        creationDate = '2024-01-01T00:00:00Z'
                        sourceRefName = 'refs/heads/feature/8453745'
                        targetRefName = 'refs/heads/master'
                        lastMergeSourceCommit = @{
                            commitId = [string]$pr8453745SourceCommit.Value
                        }
                        lastMergeTargetCommit = @{ commitId = ('b' * 40) }
                        repository = @{
                            id = '11111111-1111-1111-1111-111111111111'
                            project = @{ id = '22222222-2222-2222-2222-222222222222' }
                        }
                    }
                }
                if ($path -match '/pullRequests/8453745/iterations$') {
                    $count = [int]$pr8453745PushCount.Value
                    $iters = @(1..$count | ForEach-Object {
                            @{
                                id = [int]$_
                                createdDate = '2024-02-01T00:00:00Z'
                                updatedDate = '2024-02-01T00:00:00Z'
                                push = @{
                                    pushId = [long]$_
                                    date = $null
                                }
                                sourceRefCommit = @{
                                    commitId = [string]$pr8453745SourceCommit.Value
                                }
                                targetRefCommit = @{ commitId = ('b' * 40) }
                            }
                        })
                    return @{
                        value = $iters
                        count = $iters.Count
                        continuation_token = $null
                    }
                }
                if ($path -match '/pullRequests/8453745/threads$') {
                    $threadsVal = @($pr8453745Threads.Value)
                    return @{
                        value = $threadsVal
                        count = $threadsVal.Count
                        continuation_token = $null
                    }
                }
                if ($path -match '/refs$' -and $query -match 'heads%2Ffeature%2F8453745') {
                    return @{
                        value = @(@{
                                name = 'refs/heads/feature/8453745'
                                objectId = [string]$pr8453745RefCommit.Value
                            })
                        count = 1
                        continuation_token = $null
                    }
                }
                if ($path -match '/pushes/(?<pushId>\d+)$') {
                    $pushId = [long]$Matches.pushId
                    [void]$pushReads.Add($pushId)
                    return @{
                        pushId = $pushId
                        date = $(if ($pushId -eq [long]$pr8453745PushCount.Value) {
                                [string]$pr8453745NewestPushUtc.Value
                            } else {
                                '2024-03-01T00:00:00Z'
                            })
                        repository = @{
                            id = '11111111-1111-1111-1111-111111111111'
                            project = @{ id = '22222222-2222-2222-2222-222222222222' }
                        }
                    }
                }
                throw "Unexpected request: $method $($uri.AbsoluteUri)"
            }.GetNewClosure()

            $discoverProvider = {
                param($Verb, $Request)
                if ([string]$Verb -cne 'ListPage') {
                    throw "Unexpected verb: $Verb"
                }
                if ([int]$Request.skip -gt 0) {
                    return @{ items = @(); count = 0; totalCount = 2 }
                }
                return @{
                    items = @(
                        [ordered]@{
                            pullRequestId = 8453745
                            status = 'active'
                            isDraft = $false
                            targetRef = 'refs/heads/master'
                            creationUtc = '2024-01-01T00:00:00Z'
                        }
                        [ordered]@{
                            pullRequestId = 13826052
                            status = 'active'
                            isDraft = $false
                            targetRef = 'refs/heads/master'
                            creationUtc = '2026-06-01T00:00:00Z'
                        }
                    )
                    count = 2
                    totalCount = 2
                }
            }.GetNewClosure()

            $intakeReadConfig = [ordered]@{
                limits = [ordered]@{
                    maxPages = 5
                    pageSize = 50
                    maxPullRequests = 200
                    maxReads = 64
                    maxSeconds = 120
                }
            }
            $readsRef = [ref]0
            $pass1 = InModuleScope DevPilot.ActivePrIntake {
                param($Prov, $Cfg, $Reads)
                Get-IntakePass $Prov $Cfg $Reads ([Diagnostics.Stopwatch]::StartNew()) 1
            } -Parameters @{
                Prov = $discoverProvider
                Cfg = $intakeReadConfig
                Reads = $readsRef
            }
            $normalizedInventory = @($pass1.seen.Keys |
                ForEach-Object { [int]$_ } |
                Sort-Object |
                ForEach-Object { $pass1.seen[[string]$_].value })
            $normalizedInventory | Should -HaveCount 2
            @($normalizedInventory[0].Keys) |
                Should -Be @('pullRequestId', 'status', 'isDraft', 'targetRef', 'creationUtc')

            $localConfig = $config
            $localPolicy = $policy
            $localCutoff = $cutoff
            $localRoot = $root.Context.Root
            $localKey = $root.Key
            $lifecycleEvaluator = {
                param($InventoryItems)
                $lcProvider = New-StalePrAzureDevOpsProvider `
                    -Config $localConfig `
                    -TokenInvoker { @{ accessToken = 't' * 120 } } `
                    -HttpInvoker $httpInvoker
                return Invoke-StalePrLifecycle `
                    -Inventory $InventoryItems `
                    -CutoffUtc $localCutoff `
                    -Policy $localPolicy `
                    -LifecycleRoot $localRoot `
                    -Key $localKey `
                    -Provider $lcProvider
            }.GetNewClosure()

            # Cold run with normalized 5-key Get-IntakePass items -> Invoke-StalePrLifecycle
            $lcCold = & $lifecycleEvaluator $normalizedInventory
            $lcCold.health | Should -BeExactly healthy
            $lcCold.providerReadCount | Should -Be 6
            $lcCold.reviewEligibleIds | Should -Be @(8453745, 13826052)
            @($pushReads) | Should -Be @(62L)

            # Warm run with normalized 5-key Get-IntakePass items still refreshes live PR/iterations/threads/refs (5 GETs, 0 push GETs)
            $pushReads.Clear()
            $lcWarm = & $lifecycleEvaluator $normalizedInventory
            $lcWarm.health | Should -BeExactly healthy
            $lcWarm.providerReadCount | Should -Be 5
            @($pushReads) | Should -HaveCount 0
            $lcWarm.reviewEligibleIds | Should -Be @(8453745, 13826052)

            # Drift 1: bot comment edit after cutoff when pushes are all stale -> counted live in 5 GETs (0 push GETs needed)
            $pr8453745NewestPushUtc.Value = '2024-03-01T00:00:00Z'
            $pr8453745Threads.Value = @(@{
                    id = 10
                    isDeleted = $false
                    comments = @(@{
                            id = 1
                            commentType = 'text'
                            isDeleted = $false
                            content = 'automated bot update'
                            publishedDate = '2024-05-01T00:00:00Z'
                            lastUpdatedDate = '2026-04-01T00:00:00Z'
                            lastContentUpdatedDate = '2026-04-01T00:00:00Z'
                        })
                })
            $lcBot = & $lifecycleEvaluator $normalizedInventory
            $lcBot.health | Should -BeExactly healthy
            $lcBot.providerReadCount | Should -Be 5
            $lcBot.reviewEligibleIds | Should -Contain 8453745L
            @($pushReads) | Should -HaveCount 0

            # Drift 2: new iteration/push (iterationId=63, pushId=63) -> fetched live
            $pr8453745Threads.Value = @()
            $pr8453745PushCount.Value = 63
            $pr8453745NewestPushUtc.Value = '2026-05-01T00:00:00Z'
            $lcNewPush = & $lifecycleEvaluator $normalizedInventory
            $lcNewPush.health | Should -BeExactly healthy
            $lcNewPush.providerReadCount | Should -Be 6
            @($pushReads) | Should -Be @(63L)

            # Drift 3: branch head mismatch (ref commit != sourceCommit) -> fails closed as unknown and withholds review eligibility
            $pushReads.Clear()
            $pr8453745RefCommit.Value = ('f' * 40)
            $lcHeadDrift = & $lifecycleEvaluator $normalizedInventory
            $lcHeadDrift.health | Should -BeExactly unknown
            $lcHeadDrift.reviewEligibleIds | Should -Not -Contain 8453745L

            # Drift 4: comment deleted / all activity <= cutoff -> re-verifies all pushes live during qualification and prewrite before abandoning
            $pr8453745RefCommit.Value = ('a' * 40)
            $pr8453745PushCount.Value = 2
            $pr8453745NewestPushUtc.Value = '2024-03-01T00:00:00Z'
            $pushReads.Clear()
            $lcAbandoned = & $lifecycleEvaluator $normalizedInventory
            $lcAbandoned.confirmedAbandonedIds | Should -Be @(8453745L)
            $patchCalls.Value | Should -Be 1
            $pushReads.Count | Should -BeGreaterOrEqual 2
        }
        finally {
            [Array]::Clear($root.Key, 0, $root.Key.Length)
        }
    }

    It 'evaluates the 5 pinned production slices and model-based 60-old-PR cohort within the 128-GET ceiling while preserving historical locks and unknowns' {
        # Exact 60 old-PR IDs and 5 slices pinned in gemini-success-rate-evidence-f995-20261023T0457Z-v1 (ordinals 1036..1046).
        # Note: The 65-file evidence pack does not retain raw historic push HTTP bodies or complete head snapshots for all 60 old PRs;
        # non-pinned iteration counts below are a model-based simulation.
        $lockedStatusIds = @(1637334L, 2681697L)
        $lockedExplanationId = 2691719L
        $unknownIds = @(8592483L, 8602037L, 8743173L, 10262620L, 11307914L)
        $pinnedHeavyIterationsById = @{
            8453745L = 62
            10729576L = 83
            13069676L = 19
            1934663L = 16
            5443375L = 50
        }
        $pinnedSlices = @(
            , @(5510240L, 5748312L, 5791276L, 6174720L, 6232728L, 6587852L, 6759995L, 7058383L, 7194717L, 7251290L, 7829407L, 7984870L, 8125622L, 8388259L, 8453745L)
            , @(8592483L, 8602037L, 8743173L, 9188004L, 9897505L, 10020985L, 10183659L, 10184215L, 10262620L, 10512716L, 10729576L)
            , @(11182973L, 11307914L, 11313610L, 11316921L, 12397422L, 12624309L, 12783849L, 12821666L, 13017193L, 13069676L)
            , @(13224986L, 13405394L, 13410658L, 13586598L, 13710511L, 13723428L, 1182097L, 1200303L, 1208434L, 1323955L, 1637334L, 1879239L, 1934663L)
            , @(2612864L, 2681697L, 2691719L, 2822925L, 2943955L, 3834300L, 4335646L, 4980658L, 5411877L, 5430231L, 5443375L)
        )
        $sortedCohortIds = @($pinnedSlices | ForEach-Object { $_ } | Sort-Object -Unique)
        $sortedCohortIds | Should -HaveCount 60
        $pushCountById = @{}
        foreach ($id in $sortedCohortIds) {
            if ($pinnedHeavyIterationsById.ContainsKey($id)) {
                $pushCountById[$id] = [int]$pinnedHeavyIterationsById[$id]
            }
            elseif ($id -in $lockedStatusIds -or
                $id -eq $lockedExplanationId -or
                $id -in $unknownIds) {
                $pushCountById[$id] = 1
            }
            else {
                $pushCountById[$id] = 4
            }
        }
        $invoker = {
            param($Request)
            $uri = [Uri]$Request.Uri
            $path = $uri.AbsolutePath
            $query = $uri.Query
            $method = [string]$Request.Method
            if ($path -clike '*/_apis/connectionData') {
                return @{
                    authenticatedUser = @{
                        id = '33333333-3333-3333-3333-333333333333'
                        subjectDescriptor = 'aad.synthetic-service-account'
                    }
                    authorizedUser = @{
                        id = '33333333-3333-3333-3333-333333333333'
                        subjectDescriptor = 'aad.synthetic-service-account'
                    }
                }
            }
            if ($path -match '/pullRequests/(?<prId>\d+)$' -and $method -ceq 'GET') {
                $prId = [long]$Matches.prId
                return @{
                    pullRequestId = $prId
                    status = 'active'
                    isDraft = $false
                    creationDate = '2024-01-01T00:00:00Z'
                    sourceRefName = "refs/heads/feature/$prId"
                    targetRefName = 'refs/heads/master'
                    lastMergeSourceCommit = @{ commitId = ('a' * 40) }
                    lastMergeTargetCommit = @{ commitId = ('b' * 40) }
                    repository = @{
                        id = '11111111-1111-1111-1111-111111111111'
                        project = @{ id = '22222222-2222-2222-2222-222222222222' }
                    }
                }
            }
            if ($path -match '/pullRequests/(?<prId>\d+)/iterations$') {
                $prId = [long]$Matches.prId
                $count = [int]$pushCountById[$prId]
                $iters = @(1..$count | ForEach-Object {
                        @{
                            id = [int]$_
                            createdDate = '2024-02-01T00:00:00Z'
                            updatedDate = $(if ($_ -eq $count) {
                                    '2026-02-01T00:00:00Z'
                                } else {
                                    '2024-02-01T00:00:00Z'
                                })
                            push = @{
                                pushId = ($prId * 100L) + [long]$_
                                date = $null
                            }
                            sourceRefCommit = @{ commitId = ('a' * 40) }
                            targetRefCommit = @{ commitId = ('b' * 40) }
                        }
                    })
                return @{
                    value = $iters
                    count = $iters.Count
                    continuation_token = $null
                }
            }
            if ($path -match '/pullRequests/(?<prId>\d+)/threads$') {
                $prId = [long]$Matches.prId
                if ($prId -in $unknownIds) {
                    return @{
                        value = @()
                        count = 0
                        continuation_token = 'more-threads'
                    }
                }
                return @{
                    value = @()
                    count = 0
                    continuation_token = $null
                }
            }
            if ($path -match '/refs$' -and
                $query -match 'heads%2Ffeature%2F(?<prId>\d+)') {
                $prId = [long]$Matches.prId
                return @{
                    value = @(@{
                            name = "refs/heads/feature/$prId"
                            objectId = ('a' * 40)
                        })
                    count = 1
                    continuation_token = $null
                }
            }
            if ($path -match '/pushes/(?<pushId>\d+)$') {
                $pushId = [long]$Matches.pushId
                return @{
                    pushId = $pushId
                    date = '2026-02-01T00:00:00Z'
                    repository = @{
                        id = '11111111-1111-1111-1111-111111111111'
                        project = @{ id = '22222222-2222-2222-2222-222222222222' }
                    }
                }
            }
            throw "Unexpected cohort request: $method $($uri.AbsoluteUri)"
        }.GetNewClosure()

        $root = New-LifecycleRoot
        try {
            foreach ($lockedId in $lockedStatusIds) {
                $intentDir = Join-Path $root.Context.Root "intents\$lockedId"
                [void](New-Item -ItemType Directory -Path $intentDir -Force)
                [void](Write-StalePrLifecyclePolicy `
                    -Path (Join-Path $intentDir ('a' * 32 + '.json')) `
                    -Key $root.Key `
                    -Policy ([ordered]@{
                            schemaVersion = 1
                            kind = 'stale-pr-lifecycle-v1-intent'
                            action = 'status:abandoned'
                            runId = ('b' * 32)
                            intentId = ('a' * 32)
                        }))
                $lockDir = Join-Path $root.Context.Root "outcomes\$lockedId"
                [void](New-Item -ItemType Directory -Path $lockDir -Force)
                [void](Write-StalePrLifecyclePolicy `
                    -Path (Join-Path $lockDir ('a' * 32 + '.json')) `
                    -Key $root.Key `
                    -Policy ([ordered]@{
                            schemaVersion = 1
                            kind = 'stale-pr-lifecycle-v1-outcome'
                            action = 'status:abandoned'
                            runId = ('b' * 32)
                            intentId = ('a' * 32)
                            completedUtc = '20260101T0000000000000Z'
                            eventId = ('c' * 32)
                            outcome = 'ambiguous-post-write'
                            diagnostic = $null
                            providerWriteCount = 1
                            providerWriteState = 'unknown'
                            retryAuthorized = $false
                        }))
            }
            $expIntentDir = Join-Path $root.Context.Root (
                "explanations\intents\$lockedExplanationId")
            [void](New-Item -ItemType Directory -Path $expIntentDir -Force)
            [void](Write-StalePrLifecyclePolicy `
                -Path (Join-Path $expIntentDir ('d' * 32 + '.json')) `
                -Key $root.Key `
                -Policy ([ordered]@{
                        schemaVersion = 1
                        kind = 'stale-pr-abandonment-explanation-v1-intent'
                        action = 'comment:create-after-confirmed-abandonment'
                        identity = 'v1:sha256:' + ('e' * 64)
                        statusIntentId = ('d' * 32)
                    }))
            $expLockDir = Join-Path $root.Context.Root (
                "explanations\outcomes\$lockedExplanationId")
            [void](New-Item -ItemType Directory -Path $expLockDir -Force)
            [void](Write-StalePrLifecyclePolicy `
                -Path (Join-Path $expLockDir ('d' * 32 + '.json')) `
                -Key $root.Key `
                -Policy ([ordered]@{
                        schemaVersion = 1
                        kind = 'stale-pr-abandonment-explanation-v1-outcome'
                        action = 'comment:create-after-confirmed-abandonment'
                        identity = 'v1:sha256:' + ('e' * 64)
                        statusIntentId = ('d' * 32)
                        policyDigest = 'v1:sha256:' + ('0' * 64)
                        bodyDigest = 'v1:sha256:' + ('f' * 64)
                        intentDigest = 'v1:sha256:' + ('1' * 64)
                        eventId = ('2' * 32)
                        state = 'unknown'
                        providerWriteCount = 1
                        providerWriteState = 'unknown'
                        retryAuthorized = $false
                    }))

            $cutoff = [DateTime]::SpecifyKind(
                [DateTime]'2025-01-01T00:00:00',
                [DateTimeKind]::Utc)

            # Part 1: Each of the 5 pinned production slices completes in a single run under the 128-GET ceiling with 0 deferrals
            foreach ($slice in $pinnedSlices) {
                $sliceInventory = @($slice | ForEach-Object {
                        [ordered]@{
                            pullRequestId = [long]$_
                            status = 'active'
                            isDraft = $false
                            targetRef = 'refs/heads/master'
                            creationUtc = '2024-01-01T00:00:00Z'
                        }
                    })
                $sliceProvider = New-TestAzureDevOpsLifecycleProvider `
                    -InputConfig $config -HttpInvoker $invoker
                $sliceRun = Invoke-StalePrLifecycle `
                    -Inventory $sliceInventory -CutoffUtc $cutoff `
                    -Policy $policy -LifecycleRoot $root.Context.Root `
                    -Key $root.Key -Provider $sliceProvider
                $sliceRun.providerReadCount | Should -BeLessOrEqual 128
                @($sliceRun.decisions) | Should -HaveCount $slice.Count
                @($sliceRun.decisions | Where-Object {
                        [string]$_.state -ceq 'deferred'
                    }) | Should -HaveCount 0
                $heavyId = [long]$slice[-1]
                $sliceRun.reviewEligibleIds | Should -Contain $heavyId
            }

            # Part 2: Across the full 60-old-PR cohort using 5-key inventory items, 3 cursor-rotated runs evaluate all 60 PRs live (57 non-locked PRs * 4 GETs = 228 GETs across runs of <= 128 GETs)
            $baseInventory = @($sortedCohortIds | ForEach-Object {
                    [ordered]@{
                        pullRequestId = [long]$_
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc = '2024-01-01T00:00:00Z'
                    }
                })
            $cursor = 5510240L
            $twoRunDecisions = [Collections.Generic.List[object]]::new()
            $twoRunEligible = [Collections.Generic.List[long]]::new()
            for ($runIdx = 1; $runIdx -le 3; $runIdx++) {
                $startIndex = 0
                for ($i = 0; $i -lt $baseInventory.Count; $i++) {
                    if ([long]$baseInventory[$i].pullRequestId -ge $cursor) {
                        $startIndex = $i
                        break
                    }
                }
                $rotatedInventory = if ($startIndex -gt 0) {
                    @($baseInventory[$startIndex..($baseInventory.Count - 1)]) +
                    @($baseInventory[0..($startIndex - 1)])
                }
                else {
                    $baseInventory
                }
                $provider = New-TestAzureDevOpsLifecycleProvider `
                    -InputConfig $config -HttpInvoker $invoker
                $runResult = Invoke-StalePrLifecycle `
                    -Inventory $rotatedInventory -CutoffUtc $cutoff `
                    -Policy $policy -LifecycleRoot $root.Context.Root `
                    -Key $root.Key -Provider $provider
                $runResult.providerReadCount | Should -BeLessOrEqual 128
                $runResult.providerWrites | Should -Be 0
                $runResult.unknownPossibleEffect | Should -BeFalse
                foreach ($d in $runResult.decisions) {
                    if ([string]$d.state -cne 'deferred') {
                        [void]$twoRunDecisions.Add($d)
                    }
                }
                foreach ($eligId in $runResult.reviewEligibleIds) {
                    [void]$twoRunEligible.Add([long]$eligId)
                }
                $cursor = [long]$runResult.nextPullRequestId
            }
            $uniqueCompletedIds = @($twoRunDecisions |
                ForEach-Object { [long]$_.pullRequestId } |
                Sort-Object -Unique)
            $uniqueCompletedIds | Should -HaveCount 60
            $uniqueEligibleIds = @($twoRunEligible | Sort-Object -Unique)
            $uniqueEligibleIds | Should -HaveCount 52
            foreach ($heavyId in $pinnedHeavyIterationsById.Keys) {
                $uniqueEligibleIds | Should -Contain ([long]$heavyId)
            }
            foreach ($lockedId in $lockedStatusIds) {
                $decision = @($twoRunDecisions | Where-Object {
                        [long]$_.pullRequestId -eq $lockedId
                    })[0]
                $decision.state | Should -BeExactly unknown
                $decision.reason | Should -BeExactly 'prior-ambiguous-write'
            }
            $expDecision = @($twoRunDecisions | Where-Object {
                    [long]$_.pullRequestId -eq $lockedExplanationId
                })[0]
            $expDecision.state | Should -BeExactly unknown
            $expDecision.reason |
                Should -BeExactly 'prior-ambiguous-explanation'
            foreach ($unknownId in $unknownIds) {
                $unkDecision = @($twoRunDecisions | Where-Object {
                        [long]$_.pullRequestId -eq $unknownId
                    })[0]
                $unkDecision.state | Should -BeExactly unknown
                $unkDecision.reason |
                    Should -BeExactly 'activity-evidence-unknown'
            }
        }
        finally {
            [Array]::Clear($root.Key, 0, $root.Key.Length)
        }
    }

    It 'never authorizes abandonment from cached push dates and re-verifies pushes live when activity is at or before cutoff' {
        $root = New-LifecycleRoot
        try {
            $cutoff = [DateTime]::SpecifyKind(
                [DateTime]'2025-01-01T00:00:00',
                [DateTimeKind]::Utc)
            # Pre-seed a valid signed push-date record with a STALE timestamp (2024-06-01)
            $stalePushPayload = [ordered]@{
                schemaVersion = 1
                kind = 'stale-pr-push-date-v1'
                projectId = '22222222-2222-2222-2222-222222222222'
                repositoryId = '11111111-1111-1111-1111-111111111111'
                pullRequestId = 1L
                iterationId = 1
                pushId = 7L
                sourceCommit = ('a' * 40)
                targetCommit = ('b' * 40)
                occurredUtc = '20240601T0000000000000Z'
            }
            $pushDir = Join-Path $root.Context.Root 'pushes\1'
            [void](New-Item -ItemType Directory -Path $pushDir -Force)
            [void](Write-StalePrLifecyclePolicy `
                -Path (Join-Path $pushDir 'push-7-iter-1.json') `
                -Policy $stalePushPayload `
                -Key $root.Key)

            # Case A: live /pushes/7 returns a conflicting timestamp (2026-03-01) for the same immutable pushId=7 -> fails closed with cache-write-failed
            $livePushReadsA = 0
            $baseInvokerA = New-AzLifecycleInvoker `
                -MissingSummaryPushDate `
                -PushUtc '2024-06-01T00:00:00Z' `
                -PushDetailReads ([ref]$livePushReadsA)
            $invokerA = {
                param($Request)
                $response = & $baseInvokerA $Request
                if ([string]$Request.Uri.AbsolutePath -match '/pushes/7$') {
                    $response.date = '2026-03-01T00:00:00Z'
                }
                return $response
            }.GetNewClosure()
            $providerA = New-TestAzureDevOpsLifecycleProvider `
                -InputConfig $config -HttpInvoker $invokerA
            $resultA = Invoke-StalePrLifecycle `
                -Inventory @([ordered]@{
                        pullRequestId = 1
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc = '2024-01-01T00:00:00Z'
                    }) `
                -CutoffUtc $cutoff -Policy $policy `
                -LifecycleRoot $root.Context.Root `
                -Key $root.Key -Provider $providerA

            $livePushReadsA | Should -Be 1
            $resultA.providerWrites | Should -Be 0
            $resultA.decisions[0].state | Should -BeExactly 'unknown'
            $resultA.decisions[0].reason |
                Should -BeExactly 'activity-evidence-unknown'
            $resultA.decisions[0].diagnostic.kind |
                Should -BeExactly 'cache-write-failed'
            $resultA.decisions[0].diagnostic.reason |
                Should -BeExactly 'stale-pr-push-cache-write-failed'
        }
        finally {
            [Array]::Clear($root.Key, 0, $root.Key.Length)
        }

        $rootB = New-LifecycleRoot
        try {
            $cutoff = [DateTime]::SpecifyKind(
                [DateTime]'2025-01-01T00:00:00',
                [DateTimeKind]::Utc)
            $pushDirB = Join-Path $rootB.Context.Root 'pushes\1'
            [void](New-Item -ItemType Directory -Path $pushDirB -Force)
            [void](Write-StalePrLifecyclePolicy `
                -Path (Join-Path $pushDirB 'push-7-iter-1.json') `
                -Policy $stalePushPayload `
                -Key $rootB.Key)

            # Case B: live /pushes/7 is also stale -> both decision AND prewrite must read /pushes/7 live
            $livePushReadsB = [ref]0
            $patchCallsB = [ref]0
            $baseInvokerB = New-AzLifecycleInvoker `
                -MissingSummaryPushDate `
                -PushUtc '2024-06-01T00:00:00Z' `
                -PushDetailReads $livePushReadsB `
                -PatchCalls $patchCallsB
            $invokerB = {
                param($Request)
                $resp = & $baseInvokerB $Request
                if ([string]$Request.Method -ceq 'GET' -and
                    ([uri]$Request.Uri).AbsolutePath -match '/pullrequests/[0-9]+$' -and
                    $patchCallsB.Value -gt 0) {
                    $resp.status = 'abandoned'
                }
                return $resp
            }.GetNewClosure()
            $providerB = New-TestAzureDevOpsLifecycleProvider `
                -InputConfig $config -HttpInvoker $invokerB
            $resultB = Invoke-StalePrLifecycle `
                -Inventory @([ordered]@{
                        pullRequestId = 1
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc = '2024-01-01T00:00:00Z'
                    }) `
                -CutoffUtc $cutoff -Policy $policy `
                -LifecycleRoot $rootB.Context.Root `
                -Key $rootB.Key -Provider $providerB

            $livePushReadsB.Value | Should -Be 2
            $patchCallsB.Value | Should -Be 1
            $resultB.confirmedAbandonedIds | Should -Be @(1)
        }
        finally {
            [Array]::Clear($rootB.Key, 0, $rootB.Key.Length)
        }
    }

    It 'enforces bounded file counts, byte ceilings, caller-wired deadlines, 65+ head changes without permanent review block, non-bool integer guards, and idempotent activity proof writes' {
        $root = New-LifecycleRoot
        try {
            $cutoff = [DateTime]::SpecifyKind(
                [DateTime]'2025-01-01T00:00:00',
                [DateTimeKind]::Utc)
            $policyDigest = InModuleScope DevPilot.PullRequestLifecycle {
                param($Pol)
                Get-StalePrDigest $Pol
            } -Parameters @{ Pol = $policy }

            $evidence = [ordered]@{
                projectId = '22222222-2222-2222-2222-222222222222'
                repositoryId = '11111111-1111-1111-1111-111111111111'
                pullRequestId = 77L
                status = 'active'
                isDraft = $false
                sourceRef = 'refs/heads/feature-77'
                targetRef = 'refs/heads/master'
                sourceCommit = ('a' * 40)
                targetCommit = ('b' * 40)
                iterationId = 1
                creationUtc = '2024-01-01T00:00:00.0000000Z'
                latestActivityUtc = '2026-03-01T00:00:00.0000000Z'
                activityDigest = 'v1:sha256:' + ('c' * 64)
            }

            # Repeated identical recent-activity writes are idempotent and do not append extra seq files
            for ($i = 0; $i -lt 3; $i++) {
                InModuleScope DevPilot.PullRequestLifecycle {
                    param($RootPath, $KeyBytes, $Ev, $PolDigest)
                    Write-StalePrActivityProof `
                        -LifecycleRoot $RootPath `
                        -PullRequestId 77L `
                        -Evidence $Ev `
                        -PolicyDigest $PolDigest `
                        -Key $KeyBytes
                } -Parameters @{
                    RootPath = $root.Context.Root
                    KeyBytes = $root.Key
                    Ev = $evidence
                    PolDigest = $policyDigest
                }
            }
            @(Get-ChildItem -LiteralPath (
                    Join-Path $root.Context.Root 'activity-proofs\77') `
                    -Filter '*.json' -File) | Should -HaveCount 1

            # Expired deadline throws stale-pr-deadline-exhausted when reading cached proof
            $expiredError = $null
            try {
                [void](InModuleScope DevPilot.PullRequestLifecycle {
                        param($RootPath, $KeyBytes, $Item, $Cut, $Pol, $PolDigest)
                        Get-StalePrCachedActivityProof `
                            -LifecycleRoot $RootPath `
                            -PullRequestId 77L `
                            -Item $Item `
                            -CutoffUtc $Cut `
                            -Policy $Pol `
                            -PolicyDigest $PolDigest `
                            -Key $KeyBytes `
                            -DeadlineUtc ([DateTime]::SpecifyKind([DateTime]'2020-01-01T00:00:00', [DateTimeKind]::Utc)) `
                            -UtcNowProvider { [DateTime]::SpecifyKind([DateTime]'2026-01-01T00:00:00', [DateTimeKind]::Utc) }
                    } -Parameters @{
                        RootPath = $root.Context.Root
                        KeyBytes = $root.Key
                        Item = $evidence
                        Cut = $cutoff
                        Pol = $policy
                        PolDigest = $policyDigest
                    })
            }
            catch {
                $expiredError = $_.Exception.Message
            }
            $expiredError | Should -BeExactly 'stale-pr-deadline-exhausted'

            # Boolean passed as integer field (iterationId = $true) is rejected by static type guard
            $boolIterationItem = [ordered]@{} + $evidence
            $boolIterationItem['iterationId'] = $true
            $boolProof = InModuleScope DevPilot.PullRequestLifecycle {
                param($RootPath, $KeyBytes, $Item, $Cut, $Pol, $PolDigest)
                Get-StalePrCachedActivityProof `
                    -LifecycleRoot $RootPath `
                    -PullRequestId 77L `
                    -Item $Item `
                    -CutoffUtc $Cut `
                    -Policy $Pol `
                    -PolicyDigest $PolDigest `
                    -Key $KeyBytes
            } -Parameters @{
                RootPath = $root.Context.Root
                KeyBytes = $root.Key
                Item = $boolIterationItem
                Cut = $cutoff
                Pol = $policy
                PolDigest = $policyDigest
            }
            $boolProof | Should -BeNullOrEmpty

            # 65+ head changes through Invoke-StalePrLifecycle retire the cached proof to withheld at sequence 65 and keep the live-recent PR reviewEligible without throwing proof-write-failed
            $headIndex = [ref]1
            $headChangeInvoker = {
                param($Request)
                $uri = [Uri]$Request.Uri
                $path = $uri.AbsolutePath
                $query = $uri.Query
                $commitHex = ('{0:x40}' -f [int]$headIndex.Value)
                if ($path -clike '*/_apis/connectionData') {
                    return @{
                        authenticatedUser = @{
                            id = '33333333-3333-3333-3333-333333333333'
                            subjectDescriptor = 'aad.synthetic-service-account'
                        }
                        authorizedUser = @{
                            id = '33333333-3333-3333-3333-333333333333'
                            subjectDescriptor = 'aad.synthetic-service-account'
                        }
                    }
                }
                if ($path -match '/pullRequests/88$') {
                    return @{
                        pullRequestId = 88L
                        status = 'active'
                        isDraft = $false
                        creationDate = '2024-01-01T00:00:00Z'
                        sourceRefName = 'refs/heads/feature-88'
                        targetRefName = 'refs/heads/master'
                        lastMergeSourceCommit = @{ commitId = $commitHex }
                        lastMergeTargetCommit = @{ commitId = ('b' * 40) }
                        repository = @{
                            id = '11111111-1111-1111-1111-111111111111'
                            project = @{ id = '22222222-2222-2222-2222-222222222222' }
                        }
                    }
                }
                if ($path -match '/pullRequests/88/iterations$') {
                    return @{
                        value = @(@{
                                id = [int]$headIndex.Value
                                createdDate = '2026-03-01T00:00:00Z'
                                updatedDate = '2026-03-01T00:00:00Z'
                                push = @{
                                    pushId = [long]$headIndex.Value
                                }
                                sourceRefCommit = @{ commitId = $commitHex }
                                targetRefCommit = @{ commitId = ('b' * 40) }
                            })
                        count = 1
                        continuation_token = $null
                    }
                }
                if ($path -match '/pushes/(?<pushId>\d+)$') {
                    return @{
                        pushId = [long]$Matches.pushId
                        date = '2026-03-01T00:00:00Z'
                        repository = @{
                            id = '11111111-1111-1111-1111-111111111111'
                            project = @{ id = '22222222-2222-2222-2222-222222222222' }
                        }
                    }
                }
                if ($path -match '/pullRequests/88/threads$') {
                    return @{
                        value = @()
                        count = 0
                        continuation_token = $null
                    }
                }
                if ($path -match '/refs$' -and $query -match 'heads%2Ffeature-88') {
                    return @{
                        value = @(@{
                                name = 'refs/heads/feature-88'
                                objectId = $commitHex
                            })
                        count = 1
                        continuation_token = $null
                    }
                }
                throw "Unexpected request: $path"
            }.GetNewClosure()

            for ($iter = 1; $iter -le 66; $iter++) {
                $headIndex.Value = $iter
                $iterProvider = New-TestAzureDevOpsLifecycleProvider `
                    -InputConfig $config -HttpInvoker $headChangeInvoker
                $iterRun = Invoke-StalePrLifecycle `
                    -Inventory @([ordered]@{
                            pullRequestId = 88L
                            status = 'active'
                            isDraft = $false
                            targetRef = 'refs/heads/master'
                            creationUtc = '2024-01-01T00:00:00Z'
                        }) `
                    -CutoffUtc $cutoff -Policy $policy `
                    -LifecycleRoot $root.Context.Root `
                    -Key $root.Key -Provider $iterProvider
                $iterRun.health | Should -BeExactly healthy
                $iterRun.reviewEligibleIds | Should -Be @(88)
                $iterRun.decisions[0].state | Should -BeExactly 'no-op'
                $iterRun.decisions[0].reason | Should -BeExactly 'recent-activity'
            }
            $pr88Files = @(Get-ChildItem -LiteralPath (
                    Join-Path $root.Context.Root 'activity-proofs\88') `
                    -Filter '*.json' -File | Sort-Object Name)
            $pr88Files | Should -HaveCount 65
            $lastPr88Record = Read-StalePrLifecyclePolicy `
                -Path $pr88Files[-1].FullName -Key $root.Key
            $lastPr88Record.sequence | Should -Be 65L
            $lastPr88Record.state | Should -BeExactly 'withheld'

            # Caller-level shared provider clock deadline wired through Invoke-StalePrLifecycle -> Get-StalePrCachedActivityProof (and ReadEvidence -> Read-StalePrCachedPushDate)
            $callerTicks = [ref]0
            $callerHttpGetCount = [ref]0
            $callerClock = {
                $callerTicks.Value++
                # Tick 1 = provider init, Ticks 2..4 = Identity GET; advance past 240s on Tick 8 (end of PR GET #1) so provider clock is expired when Read-StalePrCachedPushDate runs
                if ($callerTicks.Value -ge 8) {
                    return [DateTime]::SpecifyKind(
                        [DateTime]'2026-01-01T00:05:00',
                        [DateTimeKind]::Utc)
                }
                return [DateTime]::SpecifyKind(
                    [DateTime]'2026-01-01T00:00:00',
                    [DateTimeKind]::Utc)
            }.GetNewClosure()
            $baseClockInvoker = New-AzLifecycleInvoker -PushUtc '2026-03-01T00:00:00Z' -MissingSummaryPushDate
            $clockInvoker = {
                param($Request)
                $callerHttpGetCount.Value++
                return (& $baseClockInvoker $Request)
            }.GetNewClosure()
            $clockProvider = New-TestAzureDevOpsLifecycleProvider `
                -InputConfig $config `
                -HttpInvoker $clockInvoker `
                -UtcNowProvider $callerClock
            $clockRun = Invoke-StalePrLifecycle `
                -Inventory @(
                    [ordered]@{
                        pullRequestId = 88L
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc = '2024-01-01T00:00:00Z'
                    },
                    $evidence
                ) `
                -CutoffUtc $cutoff -Policy $policy `
                -LifecycleRoot $root.Context.Root `
                -Key $root.Key -Provider $clockProvider
            $clockRun.decisions | Should -HaveCount 1
            $clockRun.decisions[0].state | Should -BeExactly deferred
            $clockRun.decisions[0].reason | Should -BeExactly 'stale-pr-deadline-exhausted'

            # Unexpected non-json file in activity-proofs\77 invalidates cache state
            $strayFile = Join-Path $root.Context.Root 'activity-proofs\77\unexpected.txt'
            [IO.File]::WriteAllText($strayFile, 'stray')
            $strayProof = InModuleScope DevPilot.PullRequestLifecycle {
                param($RootPath, $KeyBytes, $Item, $Cut, $Pol, $PolDigest)
                Get-StalePrCachedActivityProof `
                    -LifecycleRoot $RootPath `
                    -PullRequestId 77L `
                    -Item $Item `
                    -CutoffUtc $Cut `
                    -Policy $Pol `
                    -PolicyDigest $PolDigest `
                    -Key $KeyBytes
            } -Parameters @{
                RootPath = $root.Context.Root
                KeyBytes = $root.Key
                Item = $evidence
                Cut = $cutoff
                Pol = $policy
                PolDigest = $policyDigest
            }
            $strayProof | Should -BeNullOrEmpty
        }
        finally {
            [Array]::Clear($root.Key, 0, $root.Key.Length)
        }
    }

    It 'fails closed and forces live evaluation on stale, tampered, drifted, or superseded cache state (<Mode>)' `
        -TestCases @(
            @{ Mode = 'tampered-activity-proof' }
            @{ Mode = 'sequence-gap-activity-proof' }
            @{ Mode = 'source-commit-drift-dictionary' }
            @{ Mode = 'source-commit-drift-pscustomobject' }
            @{ Mode = 'target-commit-drift' }
            @{ Mode = 'iteration-id-drift' }
            @{ Mode = 'cutoff-drift' }
            @{ Mode = 'policy-digest-drift' }
            @{ Mode = 'superseded-by-unknown' }
        ) {
        param($Mode)
        $root = New-LifecycleRoot
        try {
            $cutoff = [DateTime]::SpecifyKind(
                [DateTime]'2025-01-01T00:00:00',
                [DateTimeKind]::Utc)
            $baseInventory = @(
                [ordered]@{
                    pullRequestId = 1L
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                }
                [ordered]@{
                    pullRequestId = 2L
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                    creationUtc = '2024-01-01T00:00:00Z'
                }
            )
            $multiPrBase = New-AzLifecycleInvoker -PushUtc '2026-03-01T00:00:00Z'
            $multiPrInvoker = {
                param($Request)
                $response = & $multiPrBase $Request
                $uri = [Uri]$Request.Uri
                if ($uri.AbsolutePath -match '/refs$' -and
                    $uri.Query -match 'heads%2Ffeature-(?<id>\d+)') {
                    $response.value[0].name = "refs/heads/feature-$($Matches.id)"
                }
                return $response
            }.GetNewClosure()
            $warmProvider = New-TestAzureDevOpsLifecycleProvider `
                -InputConfig $config -HttpInvoker $multiPrInvoker
            $warmRun = Invoke-StalePrLifecycle `
                -Inventory $baseInventory -CutoffUtc $cutoff `
                -Policy $policy -LifecycleRoot $root.Context.Root `
                -Key $root.Key -Provider $warmProvider
            $warmRun.reviewEligibleIds | Should -Be @(1, 2)

            $pr1Signed = Read-StalePrLifecyclePolicy `
                -Path (@(Get-ChildItem -LiteralPath (Join-Path $root.Context.Root 'activity-proofs\1') -Filter '*.json' -File)[0].FullName) `
                -Key $root.Key
            $pr2Signed = Read-StalePrLifecyclePolicy `
                -Path (@(Get-ChildItem -LiteralPath (Join-Path $root.Context.Root 'activity-proofs\2') -Filter '*.json' -File)[0].FullName) `
                -Key $root.Key

            # Supply full 13-key identity items so unmodified PR 2 tests cached proof acceptance while PR 1 tests drift/tampering
            $testInventory = @(
                ([ordered]@{} + $pr1Signed.subject)
                ([ordered]@{} + $pr2Signed.subject)
            )
            $testCutoff = $cutoff
            $testPolicy = $policy | ConvertTo-Json -Depth 32 |
                ConvertFrom-Json -AsHashtable -Depth 32

            switch ($Mode) {
                'tampered-activity-proof' {
                    $proofFile = @(Get-ChildItem -LiteralPath (
                            Join-Path $root.Context.Root 'activity-proofs\1') `
                            -Filter '*.json' -File)[0]
                    $raw = [IO.File]::ReadAllText($proofFile.FullName)
                    [IO.File]::WriteAllText(
                        $proofFile.FullName,
                        ($raw -replace '"signature"\s*:\s*"[0-9a-f]{64}"', ('"signature": "' + ('0' * 64) + '"')))
                }
                'sequence-gap-activity-proof' {
                    $proofDir = Join-Path $root.Context.Root 'activity-proofs\1'
                    $proofFile = @(Get-ChildItem -LiteralPath $proofDir `
                            -Filter '*.json' -File)[0]
                    $existing = Read-StalePrLifecyclePolicy `
                        -Path $proofFile.FullName -Key $root.Key
                    $gapPayload = [ordered]@{
                        schemaVersion = 1
                        kind = 'stale-pr-activity-proof-v1'
                        sequence = 3L
                        pullRequestId = 1L
                        state = 'recent-activity'
                        policyDigest = [string]$existing.policyDigest
                        evidenceDigest = [string]$existing.evidenceDigest
                        subject = [ordered]@{} + $existing.subject
                    }
                    [void](Write-StalePrLifecyclePolicy `
                        -Path (Join-Path $proofDir 'seq-00000003-gap.json') `
                        -Policy $gapPayload -Key $root.Key)
                }
                'source-commit-drift-dictionary' {
                    $testInventory[0]['sourceCommit'] = ('c' * 40)
                }
                'source-commit-drift-pscustomobject' {
                    $customSubject = [ordered]@{} + $pr1Signed.subject
                    $customSubject['sourceCommit'] = ('c' * 40)
                    $testInventory[0] = [pscustomobject]$customSubject
                }
                'target-commit-drift' {
                    $testInventory[0]['targetCommit'] = ('d' * 40)
                }
                'iteration-id-drift' {
                    $testInventory[0]['iterationId'] = 99
                }
                'cutoff-drift' {
                    $testCutoff = [DateTime]::SpecifyKind(
                        [DateTime]'2026-06-01T00:00:00',
                        [DateTimeKind]::Utc)
                }
                'policy-digest-drift' {
                    $testPolicy.authority.maxCandidatesPerRun = 150
                }
                'superseded-by-unknown' {
                    $unknownInvoker = {
                        param($Request)
                        $response = & $multiPrInvoker $Request
                        if ([string]$Request.Uri.AbsolutePath -match '/threads$') {
                            $response.continuation_token = 'more'
                        }
                        return $response
                    }.GetNewClosure()
                    $unknownProvider = New-TestAzureDevOpsLifecycleProvider `
                        -InputConfig $config -HttpInvoker $unknownInvoker
                    $unkRun = Invoke-StalePrLifecycle `
                        -Inventory @($baseInventory[0]) -CutoffUtc $cutoff `
                        -Policy $policy -LifecycleRoot $root.Context.Root `
                        -Key $root.Key -Provider $unknownProvider
                    $unkRun.decisions[0].reason |
                        Should -BeExactly 'activity-evidence-unknown'
                    @(Get-ChildItem -LiteralPath (
                            Join-Path $root.Context.Root 'activity-proofs\1') `
                            -Filter '*.json' -File) | Should -HaveCount 2
                }
            }

            $tightConfig = $config | ConvertTo-Json -Depth 32 |
                ConvertFrom-Json -AsHashtable -Depth 32
            $tightConfig.subjectProvider.maximumReads = 5
            $verifyBase = New-AzLifecycleInvoker -PushUtc '2026-07-01T00:00:00Z'
            $verifyInvoker = {
                param($Request)
                $response = & $verifyBase $Request
                $uri = [Uri]$Request.Uri
                if ($uri.AbsolutePath -match '/refs$' -and
                    $uri.Query -match 'heads%2Ffeature-(?<id>\d+)') {
                    $response.value[0].name = "refs/heads/feature-$($Matches.id)"
                }
                return $response
            }.GetNewClosure()
            $tightProvider = New-TestAzureDevOpsLifecycleProvider `
                -InputConfig $tightConfig -HttpInvoker $verifyInvoker
            $verifyRun = Invoke-StalePrLifecycle `
                -Inventory $testInventory -CutoffUtc $testCutoff `
                -Policy $testPolicy -LifecycleRoot $root.Context.Root `
                -Key $root.Key -Provider $tightProvider

            $verifyRun.providerReadCount | Should -Be 5
            $pr1Decision = @($verifyRun.decisions | Where-Object {
                    [long]$_.pullRequestId -eq 1L
                })[0]
            $pr2Decision = @($verifyRun.decisions | Where-Object {
                    [long]$_.pullRequestId -eq 2L
                })[0]
            if ($Mode -cin @('cutoff-drift', 'policy-digest-drift')) {
                $pr2Decision.state | Should -BeExactly deferred
                $pr2Decision.reason |
                    Should -BeExactly 'stale-pr-read-budget-exhausted'
            }
            elseif ($Mode -cin @('tampered-activity-proof', 'sequence-gap-activity-proof')) {
                $pr1Decision.state | Should -BeExactly 'unknown'
                $pr1Decision.reason |
                    Should -BeExactly 'activity-evidence-unknown'
                $pr1Decision.diagnostic.kind |
                    Should -BeExactly 'cache-write-failed'
                $pr1Decision.diagnostic.reason |
                    Should -BeExactly 'stale-pr-activity-proof-write-failed'
                $verifyRun.reviewEligibleIds | Should -Be @(2)
            }
            else {
                $verifyRun.reviewEligibleIds | Should -Be @(1, 2)
            }
        }
        finally {
            [Array]::Clear($root.Key, 0, $root.Key.Length)
        }
    }
}
