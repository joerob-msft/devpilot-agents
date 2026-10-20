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
                $IterationId.ToString('x').PadLeft(64, '0')
            complete = $Complete
        }
    }

    function New-LifecycleProvider {
        param(
            [Parameter(Mandatory)]
            [Collections.IDictionary]$EvidenceById,
            [Collections.IDictionary]$SecondEvidenceById = @{},
            [long[]]$AmbiguousWriteIds = @()
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
                        $normalizedSecondEvidence.ContainsKey($key)) {
                        return $normalizedSecondEvidence[$key]
                    }
                    return $normalizedEvidence[$key]
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
                [switch]$NoIterations
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
                switch ($resource) {
                    pullRequests {
                        return @{
                            pullRequestId = 1
                            status = 'active'
                            isDraft = $false
                            sourceRefName =
                                'refs/heads/feature-1'
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
                        return @{
                            count = 1
                            continuation_token = $null
                            value = @(@{
                                    id = 1
                                    createdDate = $PushUtc
                                    updatedDate = $PushUtc
                                    push = @{
                                        pushId = 7
                                        date = $PushUtc
                                    }
                                    sourceRefCommit = @{
                                        commitId = 'a' * 40
                                    }
                                    targetRefCommit = @{
                                        commitId = 'b' * 40
                                    }
                                })
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
                                        'refs/heads/feature-1'
                                    objectId = 'a' * 40
                                })
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
        $recentPush = New-StalePrAzureDevOpsProvider `
            -Config $config -Invoker (
                New-AzLifecycleInvoker `
                    -PushUtc '2026-01-03T00:00:00Z')
        $pushEvidence = & $recentPush ReadEvidence @{
            pullRequestId = 1
        }
        $pushEvidence.latestActivityUtc |
            Should -BeExactly '2026-01-03T00:00:00.0000000Z'

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
