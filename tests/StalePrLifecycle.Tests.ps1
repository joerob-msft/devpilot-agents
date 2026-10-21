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
                [AllowNull()][ref]$PatchCalls
            )
            $handler = {
                param($Arguments, $InputPath)
                if ($Arguments[0] -ceq 'account') {
                    return @{
                        user = @{
                            name =
                                'service@example.invalid'
                        }
                    }
                }
                $resourceIndex =
                    [Array]::IndexOf(
                        [object[]]$Arguments,
                        '--resource')
                $resource = [string]$Arguments[
                    $resourceIndex + 1]
                $method = 'GET'
                $methodIndex = [Array]::IndexOf(
                    [object[]]$Arguments,
                    '--http-method')
                if ($methodIndex -ge 0) {
                    $method = [string]$Arguments[
                        $methodIndex + 1]
                }
                if ($method -ceq 'GET' -and
                    $null -ne $GetReads) {
                    $GetReads.Value++
                }
                if ($method -ceq 'PATCH' -and
                    $null -ne $PatchCalls) {
                    $PatchCalls.Value++
                }
                $pullRequestId = 1
                $routeIndex = [Array]::IndexOf(
                    [object[]]$Arguments,
                    '--route-parameters')
                if ($routeIndex -ge 0) {
                    foreach ($argument in @(
                            $Arguments |
                                Select-Object `
                                    -Skip ($routeIndex + 1))) {
                        if ([string]$argument -match
                            '^pullRequestId=(?<id>[0-9]+)$') {
                            $pullRequestId =
                                [long]$Matches.id
                            break
                        }
                    }
                }
                switch ($resource) {
                    pullRequests {
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
                    pullRequestIterations {
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
                    pullRequestThreads {
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
                    refs {
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
                    pushes {
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
                        throw "unexpected-resource:$resource"
                    }
                }
            }.GetNewClosure()
            return $handler
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

    It 'caps confirmed lifecycle writes at two per run' {
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

        $result.providerWrites | Should -Be 2
        $result.confirmedAbandonedIds | Should -Be @(1, 2)
        @($result.decisions | Where-Object {
                [string]$_.reason -ceq 'run-cap-reached'
            }) | Should -HaveCount 1
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

    It 'launches the actual subprocess with one canonical status body' {
        $fixture = Join-Path $repo `
            'tests\fixtures\StalePrFakeAzureCli.cmd'
        $log = Join-Path $TestDrive `
            'stale-pr-fake-az.json'
        $prior = [Environment]::GetEnvironmentVariable(
            'DEVPILOT_STALE_PR_FAKE_AZ_LOG',
            [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable(
            'DEVPILOT_STALE_PR_FAKE_AZ_LOG',
            $log,
            [EnvironmentVariableTarget]::Process)
        try {
            $provider = New-StalePrAzureDevOpsProvider `
                -Config $config -AzureCliPath $fixture
            $response = & $provider AbandonStatus @{
                pullRequestId = 1637334
                body = [ordered]@{
                    status = 'abandoned'
                }
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable(
                'DEVPILOT_STALE_PR_FAKE_AZ_LOG',
                $prior,
                [EnvironmentVariableTarget]::Process)
        }

        [string]$response.status |
            Should -BeExactly abandoned
        $record = Get-Content $log -Raw |
            ConvertFrom-Json -AsHashtable -Depth 16
        $arguments = @($record.arguments)
        $normalizedArguments = @($arguments)
        $inputIndex = [Array]::IndexOf(
            [object[]]$normalizedArguments,
            '--in-file')
        $inputIndex | Should -Be 19
        $normalizedArguments[$inputIndex + 1] =
            '<temp-path>'
        $normalizedArguments | Should -Be @(
            'devops',
            'invoke',
            '--organization',
            [string]$config.organization,
            '--area',
            'git',
            '--resource',
            'pullRequests',
            '--route-parameters',
            "project=$($config.projectName)",
            "repositoryId=$($config.repositoryId)",
            'pullRequestId=1637334',
            '--http-method',
            'PATCH',
            '--api-version',
            '7.1',
            '-o',
            'json',
            '--only-show-errors',
            '--in-file',
            '<temp-path>')
        [bool]$record.inputExistsDuringProcess |
            Should -BeTrue
        [int]$record.bodyLength | Should -Be 22
        $body = [Text.UTF8Encoding]::new(
            $false, $true).GetString(
            [Convert]::FromBase64String(
                [string]$record.bodyBase64))
        $body | Should -BeExactly (
            '{"status":"abandoned"}')
        [Convert]::FromBase64String(
            [string]$record.bodyBase64)[0..2] |
            Should -Not -Be @(0xEF, 0xBB, 0xBF)
        Test-Path -LiteralPath (
            [string]$record.inputPath) |
            Should -BeFalse
    }

    It 'signs only bounded diagnostics for a nonzero CLI exit' {
        $fixture = Join-Path $repo `
            'tests\fixtures\StalePrFakeAzureCli.cmd'
        $log = Join-Path $TestDrive `
            'stale-pr-fake-az-failure.json'
        $priorLog = [Environment]::GetEnvironmentVariable(
            'DEVPILOT_STALE_PR_FAKE_AZ_LOG',
            [EnvironmentVariableTarget]::Process)
        $priorExit = [Environment]::GetEnvironmentVariable(
            'DEVPILOT_STALE_PR_FAKE_AZ_EXIT',
            [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable(
            'DEVPILOT_STALE_PR_FAKE_AZ_LOG',
            $log,
            [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable(
            'DEVPILOT_STALE_PR_FAKE_AZ_EXIT',
            '23',
            [EnvironmentVariableTarget]::Process)
        $realProvider = New-StalePrAzureDevOpsProvider `
            -Config $config -AzureCliPath $fixture
        $evidence = New-LifecycleEvidence -Id 1637334
        $provider = {
            param($Operation, $Arguments)
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
                default {
                    throw "unexpected:$Operation"
                }
            }
        }.GetNewClosure()
        try {
            $result = Invoke-LifecycleCase `
                -Provider $provider `
                -Inventory @([ordered]@{
                        pullRequestId = 1637334
                        status = 'active'
                        isDraft = $false
                        targetRef = 'refs/heads/master'
                        creationUtc =
                            '2024-01-01T00:00:00Z'
                    })
        }
        finally {
            [Environment]::SetEnvironmentVariable(
                'DEVPILOT_STALE_PR_FAKE_AZ_LOG',
                $priorLog,
                [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable(
                'DEVPILOT_STALE_PR_FAKE_AZ_EXIT',
                $priorExit,
                [EnvironmentVariableTarget]::Process)
        }

        $result.providerWrites | Should -Be 1
        $result.decisions[0].reason |
            Should -BeExactly ambiguous-post-write
        $diagnostic = $result.events[0].diagnostic
        $diagnostic.kind |
            Should -BeExactly azure-cli-nonzero-exit
        $diagnostic.cliExitCode | Should -Be 23
        $serialized = ConvertTo-Json $result `
            -Depth 64 -Compress
        $serialized | Should -Not -Match 'RAW-SECRET-MARKER'
        @($diagnostic.Keys | Sort-Object) |
            Should -Be @('cliExitCode', 'kind')
        $record = Get-Content $log -Raw |
            ConvertFrom-Json -AsHashtable -Depth 16
        Test-Path -LiteralPath (
            [string]$record.inputPath) |
            Should -BeFalse
    }

    It 'ignores recent system-only events but includes recent bot comments' {
        $systemOnly = New-StalePrAzureDevOpsProvider `
            -Config $config -Invoker (
                New-AzLifecycleInvoker)
        $systemEvidence = & $systemOnly ReadEvidence @{
            pullRequestId = 1
        }
        $systemEvidence.latestActivityUtc |
            Should -BeExactly '2024-12-01T00:00:00.0000000Z'

        $botComment = New-StalePrAzureDevOpsProvider `
            -Config $config -Invoker (
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
        $recentPush = New-StalePrAzureDevOpsProvider `
            -Config $config -Invoker (
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

        $malformed = New-StalePrAzureDevOpsProvider `
            -Config $config -Invoker (
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
        $rawPush = & $invoker @(
            'devops', 'invoke',
            '--resource', 'pushes') ''
        [long]$rawPush.pushId | Should -Be 7
        [string]$rawPush.date |
            Should -BeExactly '2024-12-03T04:05:06Z'
        $rawPush.repository |
            Should -BeOfType ([Collections.IDictionary])
        [string]$rawPush.repository.id |
            Should -BeExactly ([string]$config.repositoryId)
        $rawPush.repository.project |
            Should -BeOfType ([Collections.IDictionary])
        [string]$rawPush.repository.project.id |
            Should -BeExactly ([string]$config.projectId)
        $detailReads = 0
        $provider = New-StalePrAzureDevOpsProvider `
            -Config $config -Invoker $invoker
        $evidence = & $provider ReadEvidence @{
            pullRequestId = 1
        }

        $detailReads | Should -Be 1
        $evidence.latestActivityUtc |
            Should -BeExactly '2024-12-03T04:05:06.0000000Z'
    }

    It 'deduplicates missing summary push dates by pushId' {
        $detailReads = 0
        $provider = New-StalePrAzureDevOpsProvider `
            -Config $config -Invoker (
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
            Config = $boundedConfig
            Invoker = (
                New-AzLifecycleInvoker `
                    -MissingSummaryPushDate)
        }
        if ($null -ne $clock) {
            $providerArguments.UtcNowProvider = $clock
        }
        $provider = New-StalePrAzureDevOpsProvider `
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
        $provider = New-StalePrAzureDevOpsProvider `
            -Config $boundedConfig -Invoker (
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
        @($result.decisions) | Should -HaveCount 1 `
            -Because (
                $result | ConvertTo-Json -Depth 8 -Compress)
        $result.decisions[0].pullRequestId | Should -Be 2
        $result.decisions[0].state | Should -BeExactly deferred
        $result.decisions[0].reason |
            Should -BeExactly stale-pr-read-budget-exhausted
        @($result.decisions | Where-Object {
                [long]$_.pullRequestId -eq 3
            }) | Should -HaveCount 0
        $getReads.Value | Should -Be 6
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
            if ($clockCalls.Value -lt 12) {
                return $start
            }
            return $start.AddSeconds(
                [int]$boundedConfig.limits.maxSeconds + 1)
        }.GetNewClosure()
        $provider = New-StalePrAzureDevOpsProvider `
            -Config $boundedConfig `
            -UtcNowProvider $clock -Invoker (
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
        @($result.decisions) | Should -HaveCount 1 `
            -Because (
                $result | ConvertTo-Json -Depth 8 -Compress)
        $result.decisions[0].pullRequestId | Should -Be 2
        $result.decisions[0].state | Should -BeExactly deferred
        $result.decisions[0].reason |
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
        $provider = New-StalePrAzureDevOpsProvider `
            -Config $boundedConfig `
            -UtcNowProvider $clock -Invoker (
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
        $provider = New-StalePrAzureDevOpsProvider `
            -Config $config -Invoker (
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
        $provider = New-StalePrAzureDevOpsProvider `
            -Config $config -Invoker (
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
        $snapshot = Get-Content `
            -LiteralPath $result.acquisitionPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        $snapshot.intake.lifecycleWriterEligible |
            Should -BeFalse
        $snapshot.intake.lifecycle.state |
            Should -BeExactly 'disabled'
        $snapshot.intake.lifecycle.providerWrites |
            Should -Be 0
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
