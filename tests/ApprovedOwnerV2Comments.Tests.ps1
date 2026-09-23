#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot `
            'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    Import-Module (Join-Path $repoRoot `
            'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') -Force
    Import-Module (Join-Path $repoRoot `
            'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1') -Force
    . (Join-Path $repoRoot 'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')

    function New-TestOwnerV2Evidence {
        param(
            [string]$Classification = 'wouldCreate',
            [string]$Identity = ('a' * 64)
        )
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $declaration = [ordered]@{
            schemaVersion = 1
            kind = 'owner-v2-preview-declaration'
            mode = 'live'
            subject = [ordered]@{
                repositoryId = '11111111-1111-1111-1111-111111111111'
                projectId = '22222222-2222-2222-2222-222222222222'
                pullRequestId = 42
            }
            head = [ordered]@{ sourceCommit = 'a' * 40 }
            target = [ordered]@{
                targetCommit = 'b' * 40
                targetRef = 'refs/heads/main'
            }
            rule = [ordered]@{
                repositoryId = '33333333-3333-3333-3333-333333333333'
                path = 'docs/owner.md'
                commit = 'c' * 40
                section = 'Ownership'
                hash = 'v1:sha256:' + ('d' * 64)
                length = 100
            }
            capability = [ordered]@{
                id = 'bpm-test-ownership@1'
                digest = 'v1:sha256:' + ('e' * 64)
            }
            model = [ordered]@{
                id = 'model-one'
                digest = 'v1:sha256:' + ('f' * 64)
            }
            config = [ordered]@{
                id = 'owner-config'
                digest = 'v1:sha256:' + ('1' * 64)
            }
            acquisitionPayloadDigest = 'v1:sha256:' + ('2' * 64)
            replay = $null
            stateDigest = "v1:sha256:$Identity"
            facadeBinding = $null
        }
        $contract = New-OwnerAcquisitionContract `
            -RepositoryId $declaration.subject.repositoryId `
            -ProjectId $declaration.subject.projectId `
            -PullRequestId $declaration.subject.pullRequestId `
            -SourceCommit $declaration.head.sourceCommit `
            -TargetCommit $declaration.target.targetCommit `
            -TargetRef $declaration.target.targetRef `
            -RuleRepositoryId $declaration.rule.repositoryId `
            -RulePath $declaration.rule.path `
            -RuleCommit $declaration.rule.commit `
            -RuleSection $declaration.rule.section `
            -RuleHash $declaration.rule.hash `
            -RuleLength $declaration.rule.length `
            -ConfigId $declaration.config.id `
            -ConfigDigest $declaration.config.digest `
            -CapabilityId $declaration.capability.id `
            -CapabilityDigest $declaration.capability.digest `
            -Limits (New-OwnerAdapterLimits -MaximumFiles 64 `
                -MaximumBytes 16777216 -MaximumReads 128)
        $declaration.facadeBinding = [ordered]@{
            bindingId = $contract.Binding.BindingId
            subjectKey = $contract.Binding.SubjectKey
            headKey = $contract.Binding.HeadKey
            ruleKey = $contract.Binding.RuleKey
            capabilityKey = $contract.Binding.CapabilityKey
        }
        $finding = [ordered]@{
            identity = 'owner-v2:' + ('3' * 64)
            semanticKey = 'v1:sha256:' + ('4' * 64)
            providerMarker = $null
            disposition = 'violation'
            ruleRef = 'rule:' + ('5' * 64)
            constructRef = 'construct:' + ('6' * 64)
            anchor = [ordered]@{
                path = 'tests/WidgetTests.cs'
                line = 12
                symbol = 'CreatesWidget'
            }
            binding = [ordered]@{
                schemaVersion = 1
                repositoryPath = 'tests/WidgetTests.cs'
                span = [ordered]@{
                    startLine = 12
                    endLine = 12
                    startColumn = 'unknown'
                    endColumn = 'unknown'
                }
                symbol = 'CreatesWidget'
                constructIdentity = 'v1:sha256:' + ('7' * 64)
                source = [ordered]@{
                    representation = [ordered]@{
                        path = 'tests/WidgetTests.cs'
                        startLine = 12
                        endLine = 12
                        startColumn = 'unknown'
                        endColumn = 'unknown'
                        symbol = 'CreatesWidget'
                        constructIdentity = 'construct:' + ('6' * 64)
                    }
                    sha256 = '8' * 64
                }
            }
        }
        $marker = Get-OwnerV1WriterMarkerKey -Contract $contract -Finding $finding
        $body = Format-OwnerV1WriterComment -Contract $contract `
            -Finding $finding -MarkerKey $marker
        $finding.providerMarker = [ordered]@{
            availability = 'available'
            integrity = 'verified'
            sha256 = Get-ApprovedOwnerV2TextSha256 $marker
        }
        $finding['reconciliation'] = [ordered]@{
            classification = $Classification
            reason = $(if ($Classification -ceq 'wouldUpdate') {
                    'reviewer-marker-body-stale'
                }
                elseif ($Classification -ceq 'noOp') {
                    'reviewer-marker-body-current'
                }
                else { 'reviewer-marker-not-found' })
            bodySha256 = Get-ApprovedOwnerV2TextSha256 $body
            discussionSha256 = '9' * 64
            thread = [ordered]@{
                availability = 'none'
                threadId = 'unknown'
                commentId = 'unknown'
                status = 'unknown'
            }
        }
        $observation = [ordered]@{
            schemaVersion = 2
            kind = 'owner-observation'
            implementation = [ordered]@{
                id = 'owner-v2-preview-orchestrator'
                version = 'test'
            }
            capability = 'bpm-test-ownership@1'
            subject = [ordered]@{
                pullRequestId = 42
                repositoryId = $declaration.subject.repositoryId
                headCommit = $declaration.head.sourceCommit
                targetCommit = $declaration.target.targetCommit
                targetRef = $declaration.target.targetRef
            }
            rule = [ordered]@{
                identity = 'rule:' + ('5' * 64)
                path = $declaration.rule.path
                section = $declaration.rule.section
                commit = $declaration.rule.commit
                sha256 = $declaration.rule.hash.Substring(10)
            }
            lifecycle = [ordered]@{ status = 'completed' }
            counts = [ordered]@{
                checked = 1
                eligible = 1
                advisory = 0
                violations = 1
                unknown = 0
                uncovered = 0
            }
            findingsComplete = $true
            findings = @($finding)
            execution = [ordered]@{
                attempts = 1
                modelStarts = 1
                latencyMs = 1
                refusalReason = 'none'
                incompleteReason = 'unknown'
            }
            effects = [ordered]@{
                providerWrites = 0
                writeToolInvocations = 0
                dedupe = [ordered]@{
                    created = 0
                    updated = 0
                    noOp = $(if ($Classification -ceq 'noOp') { 1 } else { 0 })
                    wouldCreate = $(if ($Classification -ceq 'wouldCreate') { 1 } else { 0 })
                    wouldUpdate = $(if ($Classification -ceq 'wouldUpdate') { 1 } else { 0 })
                    unknown = 0
                }
            }
            sourceArtifacts = @(
                [ordered]@{
                    kind = 'owner-v2-discussion-snapshot'
                    sha256 = '9' * 64
                    signature = 'not-applicable'
                },
                [ordered]@{
                    kind = 'owner-v2-discussion-mapping'
                    sha256 = 'a' * 64
                    signature = 'not-applicable'
                },
                [ordered]@{
                    kind = 'owner-v2-discussion-reviewer-identity'
                    sha256 = 'b' * 64
                    signature = 'not-applicable'
                },
                [ordered]@{
                    kind = 'owner-v2-discussion-raw-page'
                    sha256 = 'c' * 64
                    signature = 'not-applicable'
                }
            )
        }
        $record = [ordered]@{
            schemaVersion = 2
            kind = 'owner-v2-preview-record'
            identity = $Identity
            stateDigest = $declaration.stateDigest
            mode = 'live'
            capabilityId = $declaration.capability.id
            capabilityDigest = $declaration.capability.digest
            subjectDigest = Get-ApprovedOwnerV2Digest $declaration.subject
            headDigest = Get-ApprovedOwnerV2Digest $declaration.head
            ruleDigest = Get-ApprovedOwnerV2Digest $declaration.rule
            modelDigest = Get-ApprovedOwnerV2Digest $declaration.model
            configDigest = Get-ApprovedOwnerV2Digest $declaration.config
            acquisitionPayloadDigest = $declaration.acquisitionPayloadDigest
            state = 'completed'
            modelExecutionState = 'attempted'
            attempts = 1
            maxAttempts = 3
            lease = $null
            createdUtc = 'utc:2026-01-01T00:00:00Z'
            updatedUtc = 'utc:2026-01-01T00:00:00Z'
            declarationPath = "declarations/$Identity.json"
            evidencePath = "evidence/$Identity.json"
            observationPath = "observations/$Identity.json"
            resultDigest = Get-ApprovedOwnerV2Digest $observation
            incompleteReason = 'unknown'
        }
        $paths = [ordered]@{}
        foreach ($name in @('declaration', 'evidence', 'record', 'observation', 'telemetry')) {
            $path = Join-Path $caseRoot "$name.json"
            [IO.File]::WriteAllText($path, "{}", [Text.UTF8Encoding]::new($false))
            $paths[$name] = $path
        }
        $paths['toolkitConfig'] = Join-Path $caseRoot 'toolkit.json'
        [IO.File]::WriteAllText(
            $paths.toolkitConfig, "{}", [Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{
            Identity = $Identity
            Declaration = $declaration
            Record = $record
            Observation = $observation
            Telemetry = [ordered]@{ attempts = 1 }
            Contract = $contract
            Paths = $paths
            Toolkit = [ordered]@{
                head = 'd' * 40
                tree = 'e' * 40
                ref = 'refs/heads/owner-v2'
                configSha256 = '1' * 64
                formatterSha256 = '2' * 64
                formatterManifestSha256 = '3' * 64
                writerSha256 = '3' * 64
                providerSha256 = '4' * 64
                cliSha256 = '5' * 64
            }
            Provider = [ordered]@{
                kind = 'azure-devops-rest-owner-discussions-v1'
                organization = 'https://dev.azure.com/example'
                projectName = 'Example'
                projectId = $declaration.subject.projectId
                repositoryId = $declaration.subject.repositoryId
                mappingDigest = 'v1:sha256:' + ('a' * 64)
                reviewerIdentity = [ordered]@{
                    id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                    descriptor = 'aad.test-descriptor'
                    uniqueName = 'operator@example.com'
                    digest = 'v1:sha256:' + ('b' * 64)
                }
            }
        }
    }

    function New-TestOwnerV2Snapshot {
        param(
            [Parameter(Mandatory)]$Evidence,
            [object[]]$Threads = @(),
            [string]$Digest = ('9' * 64)
        )
        $snapshot = [DevPilot.OwnerAdapters.OwnerDiscussionSnapshot]::new(
            'complete',
            'unknown',
            1,
            @($Threads).Count,
            @($Threads | ForEach-Object { @($_.comments).Count } |
                    Measure-Object -Sum).Sum,
            0,
            "v1:sha256:$Digest",
            [string[]]@('v1:sha256:' + ('f' * 64)),
            [object[]]$Threads)
        $snapshot | Add-Member -NotePropertyName RawProvenanceDigests `
            -NotePropertyValue ([string[]]@('v1:sha256:' + ('c' * 64)))
        $snapshot | Add-Member -NotePropertyName MappingDigest `
            -NotePropertyValue ('v1:sha256:' + ('a' * 64))
        $snapshot | Add-Member -NotePropertyName ReviewerIdentityDigest `
            -NotePropertyValue ('v1:sha256:' + ('b' * 64))
        $snapshot | Add-Member -NotePropertyName CurrentIterationId `
            -NotePropertyValue 2
        return $snapshot
    }

    function New-TestOwnerV2Thread {
        param(
            [Parameter(Mandatory)]$Evidence,
            [Parameter(Mandatory)][string]$Body,
            [bool]$ReviewerOwned = $true,
            [string]$ReviewerIdentityState = 'matched',
            [string]$Status = 'active',
            [bool]$Deleted = $false,
            [bool]$Outdated = $false,
            [long]$ThreadId = 10,
            [long]$CommentId = 11
        )
        $finding = $Evidence.Observation.findings[0]
        return [ordered]@{
            threadId = $ThreadId
            status = $Status
            isDeleted = $Deleted
            isOutdated = $Outdated
            sourceCommit = $(if ($Outdated) { $null } else {
                    [string]$Evidence.Declaration.head.sourceCommit
                })
            contextState = $(if ($Outdated) { 'outdated' } else { 'current' })
            anchor = [ordered]@{
                path = [string]$finding.anchor.path
                line = [int]$finding.anchor.line
            }
            comments = @([ordered]@{
                    commentId = $CommentId
                    commentType = 'text'
                    isDeleted = $false
                    reviewerOwned = $ReviewerOwned
                    reviewerIdentityState = $ReviewerIdentityState
                    body = $Body
                    bodyDigest = Get-ApprovedOwnerV2Digest $Body
                })
        }
    }

    function New-TestOwnerV2ApprovalContext {
        param(
            [string]$Classification = 'wouldCreate',
            [switch]$ApproveUpdate
        )
        $evidence = New-TestOwnerV2Evidence -Classification $Classification
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($leaf in @('reviews', 'approvals', 'intents', 'outcomes')) {
            New-Item -ItemType Directory -Path (Join-Path $root $leaf) -Force |
                Out-Null
        }
        $review = New-ApprovedOwnerV2ReviewPackage -Evidence $evidence
        $reviewPath = Join-Path $root 'reviews\review.json'
        [IO.File]::WriteAllText(
            $reviewPath,
            (ConvertTo-ApprovedOwnerV2CanonicalJson $review) + "`n",
            [Text.UTF8Encoding]::new($false))
        $key = [byte[]](1..32)
        $approvalPath = Join-Path $root 'approvals\approved.json'
        [void](Approve-OwnerV2ReviewPackage `
                -ReviewPackagePath $reviewPath `
                -ApprovalPath $approvalPath `
                -FindingId @([string]$review.proposals[0].findingId) `
                -OperatorId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' `
                -OperatorDescriptor 'aad.test-descriptor' `
                -OperatorUpn 'operator@example.com' `
                -Reason 'Reviewed exact proposed Owner comment.' `
                -Key $key -ApproveUpdate:$ApproveUpdate)
        return [pscustomobject]@{
            Evidence = $evidence
            Root = $root
            Key = $key
            Review = $review
            Approval = Read-ApprovedOwnerV2SignedRecord `
                -Path $approvalPath -Key $key
        }
    }

    function New-TestOwnerV2Provider {
        param(
            [Parameter(Mandatory)]$Context,
            [object[]]$InitialThreads = @(),
            [string]$HeadCommit = '',
            [string]$TargetCommit = '',
            [string]$TargetRef = '',
            [switch]$StaleAnchor,
            [switch]$ForeignIdentity,
            [switch]$FailRead
        )
        $evidence = $Context.Evidence
        $state = [ordered]@{
            threads = @($InitialThreads)
            digest = '9' * 64
            writes = 0
            readSelectionCounts = [Collections.Generic.List[int]]::new()
        }
        $newSnapshot = ${function:New-TestOwnerV2Snapshot}
        $newThread = ${function:New-TestOwnerV2Thread}
        $provider = {
            param([string]$Action, [hashtable]$Arguments)
            if ($Action -ceq 'ReadCurrent') {
                if ($FailRead) { throw 'discussion pagination incomplete' }
                [void]$state.readSelectionCounts.Add(@($Arguments.selections).Count)
                return [pscustomobject]@{
                    ProviderBinding = $evidence.Provider
                    PullRequest = [ordered]@{
                        pullRequestId = 42
                        status = 'active'
                        isDraft = $false
                        repositoryId = $evidence.Declaration.subject.repositoryId
                        projectId = $evidence.Declaration.subject.projectId
                        sourceCommit = $(if ($HeadCommit) { $HeadCommit } else {
                                $evidence.Declaration.head.sourceCommit
                            })
                        targetCommit = $(if ($TargetCommit) { $TargetCommit } else {
                                $evidence.Declaration.target.targetCommit
                            })
                        targetRef = $(if ($TargetRef) { $TargetRef } else {
                                $evidence.Declaration.target.targetRef
                            })
                    }
                    Reviewer = [ordered]@{
                        id = $(if ($ForeignIdentity) {
                                'ffffffff-ffff-ffff-ffff-ffffffffffff'
                            }
                            else { 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' })
                        descriptor = 'aad.test-descriptor'
                        uniqueName = 'operator@example.com'
                    }
                    Snapshot = & $newSnapshot -Evidence $evidence `
                        -Threads $state.threads -Digest $state.digest
                    Anchors = @([ordered]@{
                            path = 'tests/WidgetTests.cs'
                            startLine = $(if ($StaleAnchor) { 20 } else { 12 })
                            endLine = $(if ($StaleAnchor) { 20 } else { 12 })
                            changeTrackingId = 7
                            iterationId = 2
                        })
                }
            }
            if ($Action -ceq 'CreateThread') {
                $state.writes++
                $state.threads = @(& $newThread -Evidence $evidence `
                        -Body ([string]$Arguments.selection.body)
                )
                $state.digest = '8' * 64
                return [ordered]@{ id = 10 }
            }
            if ($Action -ceq 'UpdateComment') {
                $state.writes++
                $state.threads = @(& $newThread -Evidence $evidence `
                        -Body ([string]$Arguments.selection.body)
                )
                $state.digest = '8' * 64
                return [ordered]@{ id = 11 }
            }
            throw "Unexpected provider action '$Action'."
        }.GetNewClosure()
        return [pscustomobject]@{ Handler = $provider; State = $state }
    }
}

Describe 'Approved Owner v2 review and approval packages' {
    It 'exports the exact V1-compatible marker, body, anchor, and body digest' {
        $evidence = New-TestOwnerV2Evidence
        $package = New-ApprovedOwnerV2ReviewPackage -Evidence $evidence

        @($package.proposals) | Should -HaveCount 1
        $proposal = $package.proposals[0]
        $proposal.markerComment | Should -BeExactly (
            "<!-- devpilot-owner-comment:v1:$($proposal.marker) -->")
        $proposal.body | Should -Match '\*\*Owner attribute missing\*\*'
        $proposal.path | Should -BeExactly 'tests/WidgetTests.cs'
        $proposal.line | Should -Be 12
        (Get-ApprovedOwnerV2TextSha256 $proposal.body) |
            Should -BeExactly $proposal.bodySha256
        $package.authorization | Should -BeExactly 'none'
    }

    It 'rejects relation, advisory, unknown, and non-method findings' {
        $evidence = New-TestOwnerV2Evidence
        $finding = $evidence.Observation.findings[0]
        $finding.identity = 'relation-v2:' + ('1' * 64)
        { Get-ApprovedOwnerV2Proposal -Evidence $evidence -Finding $finding } |
            Should -Throw '*method-level*'

        $finding.identity = 'owner-v2:' + ('3' * 64)
        $finding.disposition = 'unknown'
        { Get-ApprovedOwnerV2Proposal -Evidence $evidence -Finding $finding } |
            Should -Throw '*method-level*'

        $finding.disposition = 'violation'
        $finding.binding.source.representation.endLine = 13
        { Get-ApprovedOwnerV2Proposal -Evidence $evidence -Finding $finding } |
            Should -Throw '*method-level anchor*'
    }

    It 'rejects selection batches larger than five' {
        $context = New-TestOwnerV2ApprovalContext
        $reviewPath = Join-Path $context.Root 'reviews\review.json'
        {
            Approve-OwnerV2ReviewPackage -ReviewPackagePath $reviewPath `
                -ApprovalPath (Join-Path $context.Root 'approvals\too-many.json') `
                -FindingId @('1', '2', '3', '4', '5', '6') `
                -OperatorId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' `
                -OperatorDescriptor 'aad.test-descriptor' `
                -OperatorUpn 'operator@example.com' -Reason 'reviewed' `
                -Key $context.Key
        } | Should -Throw '*one to five*'
    }

    It 'detects signed-envelope tampering' {
        $context = New-TestOwnerV2ApprovalContext
        $path = Join-Path $context.Root 'approvals\tampered.json'
        $payload = [ordered]@{} + $context.Approval
        $payload.reason = 'tampered'
        [IO.File]::WriteAllText(
            $path,
            (($payload | ConvertTo-Json -Depth 32 -Compress)),
            [Text.UTF8Encoding]::new($false))
        {
            Read-ApprovedOwnerV2SignedRecord -Path $path -Key $context.Key
        } | Should -Throw
    }

    It 'rejects tampering of every durable approval binding' -TestCases @(
        @{ Name = 'identity'; Path = 'state.identity' }
        @{ Name = 'declaration'; Path = 'state.declarationSha256' }
        @{ Name = 'evidence'; Path = 'state.evidenceSha256' }
        @{ Name = 'record'; Path = 'state.recordSha256' }
        @{ Name = 'observation'; Path = 'state.observationSha256' }
        @{ Name = 'telemetry'; Path = 'state.telemetrySha256' }
        @{ Name = 'result'; Path = 'state.resultDigest' }
        @{ Name = 'record schema'; Path = 'state.recordSchemaVersion' }
        @{ Name = 'attempts'; Path = 'state.attempts' }
        @{ Name = 'execution state'; Path = 'state.modelExecutionState' }
        @{ Name = 'head'; Path = 'subject.sourceCommit' }
        @{ Name = 'target'; Path = 'subject.targetCommit' }
        @{ Name = 'target ref'; Path = 'subject.targetRef' }
        @{ Name = 'rule'; Path = 'rule.commit' }
        @{ Name = 'capability'; Path = 'capability.digest' }
        @{ Name = 'model'; Path = 'model.digest' }
        @{ Name = 'config'; Path = 'config.digest' }
        @{ Name = 'acquisition'; Path = 'acquisitionPayloadDigest' }
        @{ Name = 'discussion'; Path = 'discussion.snapshotSha256' }
        @{ Name = 'raw discussion page'; Path = 'discussion.rawPageSha256.0' }
        @{ Name = 'provider'; Path = 'provider.reviewerIdentity.id' }
        @{ Name = 'toolkit'; Path = 'toolkit.head' }
        @{ Name = 'implementation'; Path = 'observationImplementation.version' }
        @{ Name = 'selection'; Path = 'selections.0.bodySha256' }
    ) {
        param($Name, $Path)
        $context = New-TestOwnerV2ApprovalContext
        $approval = $context.Approval |
            ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32
        $parts = $Path.Split('.')
        $cursor = $approval
        for ($index = 0; $index -lt $parts.Count - 1; $index++) {
            $part = $parts[$index]
            if ($part -match '^\d+$') { $cursor = $cursor[[int]$part] }
            else { $cursor = $cursor[$part] }
        }
        $leaf = $parts[-1]
        if ($leaf -match '^\d+$') { $cursor[[int]$leaf] = 'tampered' }
        elseif ($cursor[$leaf] -is [int] -or $cursor[$leaf] -is [long]) {
            $cursor[$leaf] = [long]$cursor[$leaf] + 1
        }
        else { $cursor[$leaf] = 'tampered' }

        {
            Assert-ApprovedOwnerV2ApprovalCurrent `
                -Evidence $context.Evidence -Approval $approval
        } | Should -Throw
    }
}

Describe 'Approved Owner v2 live safety boundary' {
    It 'dry-runs wouldCreate findings with zero provider writes' {
        $context = New-TestOwnerV2ApprovalContext
        $provider = New-TestOwnerV2Provider -Context $context
        $result = Invoke-ApprovedOwnerV2Comments `
            -Evidence $context.Evidence -Approval $context.Approval `
            -ApprovalRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler

        $result.mode | Should -BeExactly 'dryRun'
        $result.providerWrites | Should -Be 0
        $result.results[0].outcome | Should -BeExactly 'wouldCreate'
        $provider.State.writes | Should -Be 0
        @($provider.State.readSelectionCounts | Select-Object -Unique) |
            Should -Be @(1)
    }

    It 'returns noOp for the exact current reviewer comment' {
        $context = New-TestOwnerV2ApprovalContext
        $proposal = $context.Approval.selections[0]
        $thread = New-TestOwnerV2Thread -Evidence $context.Evidence `
            -Body ([string]$proposal.body)
        $provider = New-TestOwnerV2Provider -Context $context `
            -InitialThreads @($thread)
        $result = Invoke-ApprovedOwnerV2Comments `
            -Evidence $context.Evidence -Approval $context.Approval `
            -ApprovalRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler

        $result.results[0].outcome | Should -BeExactly 'noOp'
        $provider.State.writes | Should -Be 0
    }

    It 'refuses duplicate and foreign copied markers' -TestCases @(
        @{ Name = 'foreign'; Foreign = $true; Duplicate = $false }
        @{ Name = 'duplicate'; Foreign = $false; Duplicate = $true }
    ) {
        param($Name, $Foreign, $Duplicate)
        $context = New-TestOwnerV2ApprovalContext
        $proposal = $context.Approval.selections[0]
        $first = New-TestOwnerV2Thread -Evidence $context.Evidence `
            -Body ([string]$proposal.body) -ReviewerOwned:(-not $Foreign) `
            -ReviewerIdentityState $(if ($Foreign) { 'foreign' } else { 'matched' })
        $threads = @($first)
        if ($Duplicate) {
            $threads += New-TestOwnerV2Thread -Evidence $context.Evidence `
                -Body ([string]$proposal.body) -ThreadId 20 -CommentId 21
        }
        $provider = New-TestOwnerV2Provider -Context $context `
            -InitialThreads $threads
        {
            Invoke-ApprovedOwnerV2Comments `
                -Evidence $context.Evidence -Approval $context.Approval `
                -ApprovalRoot $context.Root -Key $context.Key `
                -Provider $provider.Handler
        } | Should -Throw
        $provider.State.writes | Should -Be 0
    }

    It 'fails closed on stale head, target, ref, anchor, identity, snapshot, and incomplete reads' -TestCases @(
        @{ Name = 'head'; Arguments = @{ HeadCommit = ('0' * 40) }; Snapshot = $false }
        @{ Name = 'target'; Arguments = @{ TargetCommit = ('0' * 40) }; Snapshot = $false }
        @{ Name = 'target ref'; Arguments = @{ TargetRef = 'refs/heads/other' }; Snapshot = $false }
        @{ Name = 'anchor'; Arguments = @{ StaleAnchor = $true }; Snapshot = $false }
        @{ Name = 'identity'; Arguments = @{ ForeignIdentity = $true }; Snapshot = $false }
        @{ Name = 'snapshot'; Arguments = @{}; Snapshot = $true }
        @{ Name = 'incomplete'; Arguments = @{ FailRead = $true }; Snapshot = $false }
    ) {
        param($Name, $Arguments, $Snapshot)
        $context = New-TestOwnerV2ApprovalContext
        if ($Snapshot) { $context.Approval.discussion.snapshotSha256 = '0' * 64 }
        $provider = New-TestOwnerV2Provider -Context $context @Arguments
        {
            Invoke-ApprovedOwnerV2Comments `
                -Evidence $context.Evidence -Approval $context.Approval `
                -ApprovalRoot $context.Root -Key $context.Key `
                -Provider $provider.Handler
        } | Should -Throw
        $provider.State.writes | Should -Be 0
    }

    It 'requires both signed and runtime update approval' {
        $context = New-TestOwnerV2ApprovalContext `
            -Classification wouldUpdate -ApproveUpdate
        $proposal = $context.Approval.selections[0]
        $thread = New-TestOwnerV2Thread -Evidence $context.Evidence `
            -Body ("stale`n$($proposal.markerComment)")
        $provider = New-TestOwnerV2Provider -Context $context `
            -InitialThreads @($thread)
        {
            Invoke-ApprovedOwnerV2Comments `
                -Evidence $context.Evidence -Approval $context.Approval `
                -ApprovalRoot $context.Root -Key $context.Key `
                -Provider $provider.Handler -Publish
        } | Should -Throw '*runtime -ApproveUpdate*'
        $provider.State.writes | Should -Be 0
    }

    It 'publishes one create and confirms it by readback' {
        $context = New-TestOwnerV2ApprovalContext
        $provider = New-TestOwnerV2Provider -Context $context
        $result = Invoke-ApprovedOwnerV2Comments `
            -Evidence $context.Evidence -Approval $context.Approval `
            -ApprovalRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler -Publish

        $result.providerWrites | Should -Be 1
        $result.results[0].outcome | Should -BeExactly 'created'
        $provider.State.writes | Should -Be 1
    }

    It 'repairs interrupted confirmation without creating a duplicate' {
        $context = New-TestOwnerV2ApprovalContext
        $proposal = $context.Approval.selections[0]
        $thread = New-TestOwnerV2Thread -Evidence $context.Evidence `
            -Body ([string]$proposal.body)
        $provider = New-TestOwnerV2Provider -Context $context `
            -InitialThreads @($thread)
        $intent = [ordered]@{
            schemaVersion = 1
            kind = 'owner-v2-comment-intent'
            invocationId = 'interrupted'
            stateIdentity = [string]$context.Approval.state.identity
            selections = @($proposal)
        }
        [void](Write-ApprovedOwnerV2SignedRecord `
                -Path (Join-Path $context.Root (
                    "intents\$($context.Approval.state.identity)\interrupted.json")) `
                -Payload $intent -Key $context.Key)

        $result = Invoke-ApprovedOwnerV2Comments `
            -Evidence $context.Evidence -Approval $context.Approval `
            -ApprovalRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler -Publish

        @($result.repairedAudits) | Should -HaveCount 1
        $result.repairedAudits[0].status |
            Should -BeExactly 'recovered-confirmed'
        $result.repairedAudits[0].providerWrites |
            Should -BeExactly 'unknown'
        $result.repairedAudits[0].recoveryProviderWrites | Should -Be 0
        $result.results[0].outcome | Should -BeExactly 'noOp'
        $provider.State.writes | Should -Be 0
    }

    It 'keeps the writer outside scheduler, model, MCP, vote, and status authority' {
        $cli = Get-Content -LiteralPath (
            Join-Path $repoRoot 'tools\Invoke-ApprovedOwnerV2Comment.ps1') -Raw
        $provider = Get-Content -LiteralPath (
            Join-Path $repoRoot `
                'src\Agents\reviewer\AzureDevOpsOwnerV2CommentProvider.ps1') -Raw
        $cli | Should -Not -Match 'EnableLiveModel|Open-AgentMcpSession|Task Scheduler'
        $provider | Should -Not -Match 'Open-AgentMcpSession|vote|status update|notification'
        $provider | Should -Match "'CreateThread'"
        $provider | Should -Match "'UpdateComment'"
    }
}
