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
    . (Join-Path $repoRoot 'src\Agents\reviewer\AutomaticOwnerV2Comments.ps1')

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
                automaticWriterSha256 = '6' * 64
                schedulerSha256 = '7' * 64
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

    function Expand-TestOwnerV2Evidence {
        param(
            [Parameter(Mandatory)]$Evidence,
            [ValidateRange(1, 12)][int]$Count
        )
        $base = $Evidence.Observation.findings[0]
        $findings = [Collections.Generic.List[object]]::new()
        for ($index = 1; $index -le $Count; $index++) {
            $finding = $base | ConvertTo-Json -Depth 32 -Compress |
                ConvertFrom-Json -AsHashtable -Depth 32
            $hex = $index.ToString('x64')
            $constructHex = ($index + 100).ToString('x64')
            $line = 11 + $index
            $finding.identity = "owner-v2:$hex"
            $finding.semanticKey = "v1:sha256:$hex"
            $finding.constructRef = "construct:$constructHex"
            $finding.anchor.line = $line
            $finding.anchor.symbol = "CreatesWidget$index"
            $finding.binding.span.startLine = $line
            $finding.binding.span.endLine = $line
            $finding.binding.symbol = $finding.anchor.symbol
            $finding.binding.constructIdentity =
                "v1:sha256:$constructHex"
            $finding.binding.source.representation.startLine = $line
            $finding.binding.source.representation.endLine = $line
            $finding.binding.source.representation.symbol =
                $finding.anchor.symbol
            $finding.binding.source.representation.constructIdentity =
                $finding.constructRef
            $marker = Get-OwnerV1WriterMarkerKey `
                -Contract $Evidence.Contract -Finding $finding
            $body = Format-OwnerV1WriterComment `
                -Contract $Evidence.Contract -Finding $finding `
                -MarkerKey $marker
            $finding.providerMarker.sha256 =
                Get-ApprovedOwnerV2TextSha256 $marker
            $finding.reconciliation.bodySha256 =
                Get-ApprovedOwnerV2TextSha256 $body
            [void]$findings.Add($finding)
        }
        $Evidence.Observation.findings = $findings.ToArray()
        $Evidence.Observation.counts.checked = $Count
        $Evidence.Observation.counts.eligible = $Count
        $Evidence.Observation.counts.violations = $Count
        $Evidence.Observation.effects.dedupe.wouldCreate = $Count
        $Evidence.Record.resultDigest =
            Get-ApprovedOwnerV2Digest $Evidence.Observation
        return $Evidence
    }

    function New-TestAutomaticOwnerV2Provider {
        param(
            [Parameter(Mandatory)]$Evidence,
            [switch]$ForeignIdentity,
            [switch]$StaleHead,
            [switch]$StaleAnchor,
            [switch]$FailCreateAfterWrite,
            [switch]$FailCreateBeforeWrite,
            [switch]$FailReadback,
            [switch]$DuplicateReadback
        )
        $state = [ordered]@{
            threads = @()
            digest = '9' * 64
            writes = 0
            nextThreadId = 100
            readCount = 0
            failReadback = [bool]$FailReadback
            duplicateReadback = [bool]$DuplicateReadback
        }
        $newSnapshot = ${function:New-TestOwnerV2Snapshot}
        $provider = {
            param([string]$Action, [hashtable]$Arguments)
            if ($Action -ceq 'ReadCurrent') {
                $state.readCount++
                if ([bool]$state.failReadback -and $state.writes -gt 0) {
                    throw 'readback unavailable'
                }
                $anchors = @($Arguments.selections | ForEach-Object {
                        [ordered]@{
                            path = [string]$_.path
                            startLine = $(if ($StaleAnchor) {
                                    [int]$_.line + 10
                                }
                                else { [int]$_.line })
                            endLine = $(if ($StaleAnchor) {
                                    [int]$_.line + 10
                                }
                                else { [int]$_.line })
                            changeTrackingId = 7
                            iterationId = 2
                        }
                    })
                $snapshotThreads = @($state.threads)
                if ([bool]$state.duplicateReadback -and
                    $state.writes -gt 0 -and $snapshotThreads.Count -gt 0) {
                    $duplicate = $snapshotThreads[0] |
                        ConvertTo-Json -Depth 16 -Compress |
                        ConvertFrom-Json -AsHashtable -Depth 16
                    $duplicate.threadId = 999
                    $duplicate.comments[0].commentId = 1999
                    $snapshotThreads += $duplicate
                }
                return [pscustomobject]@{
                    ProviderBinding = $Evidence.Provider
                    PullRequest = [ordered]@{
                        pullRequestId = 42
                        status = 'active'
                        isDraft = $false
                        repositoryId =
                            $Evidence.Declaration.subject.repositoryId
                        projectId = $Evidence.Declaration.subject.projectId
                        sourceCommit = $(if ($StaleHead) { '0' * 40 }
                            else { $Evidence.Declaration.head.sourceCommit })
                        targetCommit =
                            $Evidence.Declaration.target.targetCommit
                        targetRef = $Evidence.Declaration.target.targetRef
                    }
                    Reviewer = [ordered]@{
                        id = $(if ($ForeignIdentity) {
                                'ffffffff-ffff-ffff-ffff-ffffffffffff'
                            }
                            else {
                                'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                            })
                        descriptor = 'aad.test-descriptor'
                        uniqueName = 'operator@example.com'
                    }
                    Snapshot = & $newSnapshot -Evidence $Evidence `
                        -Threads $snapshotThreads -Digest $state.digest
                    Anchors = $anchors
                }
            }
            if ($Action -ceq 'CreateThread') {
                if ($FailCreateBeforeWrite) {
                    throw 'provider rejected create'
                }
                $selection = $Arguments.selection
                $threadId = $state.nextThreadId
                $state.nextThreadId++
                $state.writes++
                $bodyBytes = [Text.UTF8Encoding]::new($false).GetBytes(
                    [string]$selection.body)
                $bodySha256 = ([Convert]::ToHexString(
                        [Security.Cryptography.SHA256]::HashData(
                            $bodyBytes))).ToLowerInvariant()
                $state.threads += [ordered]@{
                    threadId = $threadId
                    status = 'active'
                    isDeleted = $false
                    isOutdated = $false
                    sourceCommit =
                        $Evidence.Declaration.head.sourceCommit
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
                            bodyDigest = "v1:sha256:$bodySha256"
                        })
                }
                $digestBytes = [Text.UTF8Encoding]::new($false).GetBytes(
                    (@($state.threads.comments.body) -join "`n"))
                $state.digest = ([Convert]::ToHexString(
                        [Security.Cryptography.SHA256]::HashData(
                            $digestBytes))).ToLowerInvariant()
                if ($FailCreateAfterWrite) {
                    throw 'provider response lost after create'
                }
                return [ordered]@{ id = $threadId }
            }
            throw "Unexpected provider action '$Action'."
        }.GetNewClosure()
        return [pscustomobject]@{ Handler = $provider; State = $state }
    }

    function New-TestAutomaticOwnerV2Context {
        param([ValidateRange(1, 12)][int]$FindingCount = 1)
        $evidence = Expand-TestOwnerV2Evidence `
            -Evidence (New-TestOwnerV2Evidence) -Count $FindingCount
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($leaf in @(
                'keys', 'policies', 'intents', 'outcomes', 'events', 'locks'
            )) {
            New-Item -ItemType Directory -Path (Join-Path $root $leaf) -Force |
                Out-Null
        }
        $key = [byte[]](33..64)
        $policy = New-AutomaticOwnerV2ServicePolicy -Evidence $evidence `
            -PolicyId 'owner-v2-test-policy' `
            -MaxCreatesPerRun 5 -MaxCreatesPerPullRequest 25 `
            -CreatedUtc '20260101T000000Z'
        return [pscustomobject]@{
            Evidence = $evidence
            Root = $root
            Key = $key
            Policy = $policy
        }
    }

    function Update-TestAutomaticOwnerV2Discussion {
        param(
            [Parameter(Mandatory)]$Context,
            [Parameter(Mandatory)]$Provider
        )
        $snapshot = & ${function:New-TestOwnerV2Snapshot} `
            -Evidence $Context.Evidence `
            -Threads $Provider.State.threads `
            -Digest $Provider.State.digest
        $mini = [ordered]@{
            lifecycle = [ordered]@{ status = 'completed' }
            findings = $Context.Evidence.Observation.findings
            effects = [ordered]@{
                dedupe = [ordered]@{}
                providerWrites = 0
                writeToolInvocations = 0
            }
            sourceArtifacts = @()
        }
        $resolved = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $mini -Contract $Context.Evidence.Contract `
            -Snapshot $snapshot
        $Context.Evidence.Observation.findings = $resolved.findings
        foreach ($artifact in $Context.Evidence.Observation.sourceArtifacts) {
            if ([string]$artifact.kind -ceq 'owner-v2-discussion-snapshot') {
                $artifact.sha256 = $Provider.State.digest
            }
        }
        $Context.Evidence.Record.resultDigest =
            Get-ApprovedOwnerV2Digest $Context.Evidence.Observation
    }

    function New-TestAuthenticatedContextualHistory {
        $root = Join-Path $TestDrive (
            'prior-history-' +
            [guid]::NewGuid().ToString('N'))
        $identity = 'a' * 64
        foreach ($leaf in @(
                'events',
                "intents\$identity",
                "outcomes\$identity")) {
            New-Item -ItemType Directory `
                -Path (Join-Path $root $leaf) `
                -Force | Out-Null
        }
        $key = [byte[]](1..32)
        $runId = 'b' * 32
        $eventId = 'c' * 32
        $marker = 'd' * 64
        $body =
            "Prior contextual review.`n`n" +
            "<!-- devpilot-contextual-convention:v1:$marker -->"
        $bodySha =
            Get-ApprovedOwnerV2TextSha256 $body
        $subject = [ordered]@{
            projectId =
                '22222222-2222-2222-2222-222222222222'
            repositoryId =
                '11111111-1111-1111-1111-111111111111'
            pullRequestId = 42
            sourceCommit = 'e' * 40
            targetCommit = 'f' * 40
            targetRef = 'refs/heads/master'
        }
        $selection = [ordered]@{
            body = $body
            bodySha256 = $bodySha
            classification = 'wouldCreate'
            constructIdentity =
                'v1:sha256:' + ('1' * 64)
            constructRef =
                'construct:' + ('2' * 64)
            findingId =
                'contextual-v1:' + ('3' * 64)
            line = 32
            marker = $marker
            markerComment =
                "<!-- devpilot-contextual-convention:v1:$marker -->"
            path = 'src/Checks.cs'
            rationale =
                'no-current-review-at-anchor'
            ruleId =
                'explicit-string-comparison'
            semanticKey =
                'v1:sha256:' + ('4' * 64)
            symbol = 'FilterByTag'
        }
        $intent = [ordered]@{
            schemaVersion = 1
            kind =
                'contextual-conventions-v1-service-create-intent'
            runId = $runId
            policyDigest =
                'v1:sha256:' + ('5' * 64)
            state = [ordered]@{
                identity = $identity
            }
            subject = $subject
            currentIterationId = 3
            discussionSnapshotSha256 =
                '6' * 64
            rule = [ordered]@{
                repositoryId =
                    'devpilot-agents'
                path =
                    'src/DevPilot.OwnerCapability/Policy/contextual-conventions.v1.json'
                commit = '7' * 40
                section =
                    'bpm-contextual-conventions@1'
                hash =
                    'v1:sha256:' + ('8' * 64)
                length = 4815
            }
            capability = [ordered]@{
                id =
                    'bpm-contextual-conventions@1'
                digest =
                    'v1:sha256:' + ('9' * 64)
            }
            reviewerIdentity = [ordered]@{
                id =
                    '33333333-3333-3333-3333-333333333333'
                descriptor =
                    'aad.synthetic-service-account'
                uniqueName =
                    'service@example.invalid'
            }
            implementation = [ordered]@{}
            selections = @($selection)
            createdUtc = '20261018T000000Z'
        }
        $event = [ordered]@{
            schemaVersion = 1
            kind =
                'contextual-conventions-v1-delivery-event'
            eventId = $eventId
            runId = $runId
            occurredUtc = '20261018T000100Z'
            runHealth = 'healthy'
            capabilityId =
                'bpm-contextual-conventions@1'
            subject = $subject
            finding = [ordered]@{
                stateIdentity = $identity
                findingId =
                    $selection.findingId
                marker = $marker
                bodySha256 = $bodySha
                path = $selection.path
                line = $selection.line
                symbol = $selection.symbol
                ruleId = $selection.ruleId
            }
            action = 'create'
            outcome = 'created'
            threadId = 100
            commentId = 101
            url = 'https://example.invalid'
            modelWriteCount = 0
            providerWriteCount = 1
            providerWriteState = 'confirmed'
            diagnostic = $null
        }
        $outcome = [ordered]@{
            schemaVersion = 1
            kind =
                'contextual-conventions-v1-service-create-outcome'
            runId = $runId
            stateIdentity = $identity
            status = 'completed'
            providerWrites = 1
            providerWritesConservative = 1
            modelWrites = 0
            eventIds = @($eventId)
            remainingWouldCreate = 0
            diagnostic = $null
            createdUtc = '20261018T000100Z'
        }
        [void](Write-ApprovedOwnerV2SignedRecord `
                -Path (Join-Path $root `
                    "intents\$identity\$runId.json") `
                -Payload $intent -Key $key)
        [void](Write-ApprovedOwnerV2SignedRecord `
                -Path (Join-Path $root `
                    "outcomes\$identity\$runId.json") `
                -Payload $outcome -Key $key)
        $eventPath = Join-Path $root `
            "events\$eventId.json"
        [void](Write-ApprovedOwnerV2SignedRecord `
                -Path $eventPath `
                -Payload $event -Key $key)
        return [pscustomobject]@{
            Root = $root
            Key = $key
            EventPath = $eventPath
            Event = $event
        }
    }
}

Describe 'Approved Owner v2 review and approval packages' {
    It 'reconstructs exact authenticated prior comments after restart' {
        $history =
            New-TestAuthenticatedContextualHistory
        $first =
            @(Get-ApprovedOwnerV2AuthenticatedPriorComments `
                -DeliveryRoot $history.Root `
                -Key $history.Key `
                -Delivery contextual-conventions)
        $second =
            @(Get-ApprovedOwnerV2AuthenticatedPriorComments `
                -DeliveryRoot $history.Root `
                -Key $history.Key `
                -Delivery contextual-conventions)

        $first | Should -HaveCount 1
        ($first | ConvertTo-Json -Depth 16 -Compress) |
            Should -BeExactly (
                $second |
                    ConvertTo-Json -Depth 16 -Compress)
        $first[0].selection.bodySha256 |
            Should -BeExactly (
                $history.Event.finding.bodySha256)
        $first[0].event.threadId |
            Should -Be 100
    }

    It 'attaches only an exact validated additive rule compatibility proof' {
        $history =
            New-TestAuthenticatedContextualHistory
        $compatibility = [ordered]@{
            schemaVersion = 1
            kind =
                'contextual-additive-rule-history-compatibility'
            previousRule = [ordered]@{
                hash =
                    'v1:sha256:' + ('8' * 64)
                length = 4815
            }
            currentRule = [ordered]@{
                hash =
                    'v1:sha256:6a7db82e68b407af4ed19aab4517973337592e757a32d5fa7a142b63ef75d22a'
                length = 5205
            }
            unchangedRuleIds = @(
                'explicit-string-comparison')
        }
        $proofs =
            @(Get-ApprovedOwnerV2AuthenticatedPriorComments `
                -DeliveryRoot $history.Root `
                -Key $history.Key `
                -Delivery contextual-conventions `
                -RuleCompatibility $compatibility)

        $proofs | Should -HaveCount 1
        (Get-ApprovedOwnerV2Digest `
                $proofs[0].ruleCompatibility) |
            Should -BeExactly (
                Get-ApprovedOwnerV2Digest `
                    $compatibility)

        $invalid = $compatibility |
            ConvertTo-Json -Depth 16 |
            ConvertFrom-Json -AsHashtable -Depth 16
        $invalid.unchangedRuleIds =
            @('not-in-current-roster')
        {
            Assert-ApprovedOwnerV2RuleCompatibility `
                -Compatibility $invalid `
                -CurrentRule $compatibility.currentRule `
                -AllowedRuleIds @(
                    'explicit-string-comparison')
        } | Should -Throw '*is invalid*'
    }

    It 'reads authenticated history with schema-v2 compatibility under StrictMode' {
        $history =
            New-TestAuthenticatedContextualHistory
        $compatibility = [ordered]@{
            schemaVersion = 2
            kind =
                'contextual-additive-rule-history-compatibility'
            previousRules = @(
                [ordered]@{
                    rule = [ordered]@{
                        hash =
                            'v1:sha256:' +
                            ('8' * 64)
                        length = 4815
                    }
                    unchangedRuleIds = @(
                        'explicit-string-comparison')
                },
                [ordered]@{
                    rule = [ordered]@{
                        hash =
                            'v1:sha256:6a7db82e68b407af4ed19aab4517973337592e757a32d5fa7a142b63ef75d22a'
                        length = 5205
                    }
                    unchangedRuleIds = @(
                        'http-client-lifetime')
                },
                [ordered]@{
                    rule = [ordered]@{
                        hash =
                            'v1:sha256:9834f5ee38aefe532a9c2b5e05b90dd0f55faa8d87d743e2a650bb191c89506e'
                        length = 5399
                    }
                    unchangedRuleIds = @(
                        'named-call-arguments')
                })
            currentRule = [ordered]@{
                hash =
                    'v1:sha256:e84ed0793dbabb4494a603fb445bea120af872b6df4477f2952148fc9bc3efac'
                length = 6249
            }
        }

        $proofs =
            @(Get-ApprovedOwnerV2AuthenticatedPriorComments `
                -DeliveryRoot $history.Root `
                -Key $history.Key `
                -Delivery contextual-conventions `
                -RuleCompatibility $compatibility)

        $proofs | Should -HaveCount 1
        [int]$proofs[0].
            ruleCompatibility.schemaVersion |
            Should -Be 2
        @($proofs[0].
                ruleCompatibility.previousRules) |
            Should -HaveCount 3
    }

    It 'binds additive history compatibility into the signed contextual policy' {
        $evidence =
            New-TestOwnerV2Evidence
        $evidence.Declaration.capability.id =
            'bpm-contextual-conventions@1'
        $evidence.Declaration.rule.path =
            'src/DevPilot.OwnerCapability/Policy/contextual-conventions.v1.json'
        $evidence.Declaration.rule.section =
            'bpm-contextual-conventions@1'
        $evidence.Declaration.rule.hash =
            'v1:sha256:e84ed0793dbabb4494a603fb445bea120af872b6df4477f2952148fc9bc3efac'
        $evidence.Declaration.rule.length = 6249
        $implementationPaths = [ordered]@{
            parser = Join-Path $repoRoot `
                'src\DevPilot.ContextualConventions\DevPilot.ContextualConventions.psm1'
            parserManifest = Join-Path $repoRoot `
                'src\DevPilot.ContextualConventions\DevPilot.ContextualConventions.psd1'
            activePrIntake = Join-Path $repoRoot `
                'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psm1'
            contextualBridge = Join-Path $repoRoot `
                'src\DevPilot.ContextualConventionsBridge\DevPilot.ContextualConventionsBridge.psm1'
            sharedAcquisitionTool = Join-Path $repoRoot `
                'tools\Invoke-SharedReviewAcquisition.ps1'
        }
        foreach ($name in $implementationPaths.Keys) {
            $evidence.Paths[$name] =
                [string]$implementationPaths[$name]
        }
        $evidence.Toolkit.analyzerSha256 =
            Get-ApprovedOwnerV2FileSha256 `
                $evidence.Paths.parser
        $evidence.Toolkit.analyzerManifestSha256 =
            Get-ApprovedOwnerV2FileSha256 `
                $evidence.Paths.parserManifest
        $evidence.Toolkit.activePrIntakeSha256 =
            Get-ApprovedOwnerV2FileSha256 `
                $evidence.Paths.activePrIntake
        $evidence.Toolkit.contextualBridgeSha256 =
            Get-ApprovedOwnerV2FileSha256 `
                $evidence.Paths.contextualBridge
        $evidence.Toolkit.sharedAcquisitionToolSha256 =
            Get-ApprovedOwnerV2FileSha256 `
                $evidence.Paths.sharedAcquisitionTool
        $evidence.Toolkit.activePrIntakeManifestSha256 =
            'c' * 64
        $evidence.Toolkit.contextualBridgeManifestSha256 =
            'd' * 64
        $evidence.Toolkit.contextualCurrentPrToolSha256 =
            'e' * 64
        $compatibility = [ordered]@{
            schemaVersion = 1
            kind =
                'contextual-additive-rule-history-compatibility'
            previousRule = [ordered]@{
                hash =
                    'v1:sha256:0f6bd9dd21df64854bba7e2ba487c2639be15fa90f068da00df20f031ef9c749'
                length = 3706
            }
            currentRule = [ordered]@{
                hash =
                    $evidence.Declaration.
                        rule.hash
                length =
                    $evidence.Declaration.
                        rule.length
            }
            unchangedRuleIds = @(
                'explicit-string-comparison')
        }

        $policy =
            New-AutomaticOwnerV2ServicePolicy `
                -Evidence $evidence `
                -PolicyId contextual-test-policy `
                -MaxCreatesPerRun 2 `
                -MaxCreatesPerPullRequest 5 `
                -HistoryCompatibility `
                    $compatibility `
                -CreatedUtc '20261019T000000Z'

        $policy.historyCompatibility.
            previousRule.hash |
            Should -BeExactly (
                $compatibility.previousRule.hash)
        $policy.historyCompatibility.
            unchangedRuleIds |
            Should -BeExactly @(
                'explicit-string-comparison')
        $policy.limits.maxCreatesPerRun |
            Should -Be 2
        $policy.limits.maxCreatesPerPullRequest |
            Should -Be 5
        {
            Assert-AutomaticOwnerV2ServicePolicy `
                -Evidence $evidence `
                -Policy $policy
        } | Should -Not -Throw
    }

    It 'validates multiple exact prior bundles with rule-specific unchanged sets' {
        $compatibility = [ordered]@{
            schemaVersion = 2
            kind =
                'contextual-additive-rule-history-compatibility'
            previousRules = @(
                [ordered]@{
                    rule = [ordered]@{
                        hash =
                            'v1:sha256:0f6bd9dd21df64854bba7e2ba487c2639be15fa90f068da00df20f031ef9c749'
                        length = 3706
                    }
                    unchangedRuleIds = @(
                        'explicit-string-comparison')
                },
                [ordered]@{
                    rule = [ordered]@{
                        hash =
                            'v1:sha256:6a7db82e68b407af4ed19aab4517973337592e757a32d5fa7a142b63ef75d22a'
                        length = 5205
                    }
                    unchangedRuleIds = @(
                        'http-client-lifetime')
                },
                [ordered]@{
                    rule = [ordered]@{
                        hash =
                            'v1:sha256:9834f5ee38aefe532a9c2b5e05b90dd0f55faa8d87d743e2a650bb191c89506e'
                        length = 5399
                    }
                    unchangedRuleIds = @(
                        'named-call-arguments')
                })
            currentRule = [ordered]@{
                hash =
                    'v1:sha256:e84ed0793dbabb4494a603fb445bea120af872b6df4477f2952148fc9bc3efac'
                length = 6249
            }
        }
        $validated =
            Assert-ApprovedOwnerV2RuleCompatibility `
                -Compatibility $compatibility `
                -CurrentRule (
                    $compatibility.currentRule) `
                -AllowedRuleIds @(
                    'explicit-string-comparison',
                    'http-client-lifetime',
                    'named-call-arguments')
        @($validated.previousRules) |
            Should -HaveCount 3

        $duplicate = $compatibility |
            ConvertTo-Json -Depth 16 |
            ConvertFrom-Json `
                -AsHashtable -Depth 16
        $duplicate.previousRules[1].rule =
            $duplicate.previousRules[0].rule
        {
            Assert-ApprovedOwnerV2RuleCompatibility `
                -Compatibility $duplicate `
                -CurrentRule (
                    $duplicate.currentRule) `
                -AllowedRuleIds @(
                    'explicit-string-comparison',
                    'http-client-lifetime',
                    'named-call-arguments')
        } | Should -Throw '*duplicate or current*'
    }

    It 'refuses prior history signed by a foreign key' {
        $history =
            New-TestAuthenticatedContextualHistory
        {
            Get-ApprovedOwnerV2AuthenticatedPriorComments `
                -DeliveryRoot $history.Root `
                -Key ([byte[]](33..64)) `
                -Delivery contextual-conventions
        } | Should -Throw '*signature did not verify*'
    }

    It 'refuses a signed foreign event kind in contextual history' {
        $history =
            New-TestAuthenticatedContextualHistory
        $foreign = [ordered]@{} +
            $history.Event
        $foreign.kind =
            'owner-v2-delivery-event'
        [void](Write-ApprovedOwnerV2SignedRecord `
                -Path (Join-Path $history.Root `
                    'events\ffffffffffffffffffffffffffffffff.json') `
                -Payload $foreign `
                -Key $history.Key)

        {
            Get-ApprovedOwnerV2AuthenticatedPriorComments `
                -DeliveryRoot $history.Root `
                -Key $history.Key `
                -Delivery contextual-conventions
        } | Should -Throw '*is foreign*'
    }

    It 'allows only isolated contextual discussion unknowns beside actionable findings' {
        $observation = [ordered]@{
            findingsComplete = $false
            counts = [ordered]@{
                unknown = 0
                uncovered = 0
            }
            validationErrors = @()
            effects = [ordered]@{
                dedupe = [ordered]@{
                    unknown = 1
                }
            }
            findings = @(
                [ordered]@{
                    anchor = [ordered]@{
                        path = 'src/Test.cs'
                        line = 10
                    }
                    constructRef = 'construct:unknown'
                    reconciliation = [ordered]@{
                        classification = 'unknown'
                        reason = 'other-review-at-anchor'
                    }
                },
                [ordered]@{
                    anchor = [ordered]@{
                        path = 'src/Test.cs'
                        line = 20
                    }
                    constructRef = 'construct:actionable'
                    reconciliation = [ordered]@{
                        classification = 'wouldCreate'
                        reason = 'no-current-review-at-anchor'
                    }
                })
        }

        Test-ApprovedContextualActionablePartial `
            -Observation $observation |
            Should -BeTrue
        $observation.findings[0].
            reconciliation.reason =
            'duplicate-reviewer-markers'
        Test-ApprovedContextualActionablePartial `
            -Observation $observation |
            Should -BeFalse
        $observation.findings[0].
            reconciliation.reason =
            'other-review-at-anchor'
        $observation.findings[1].anchor.line = 10
        Test-ApprovedContextualActionablePartial `
            -Observation $observation |
            Should -BeFalse
        $observation.findings[1].anchor.line = 20
        $observation.findings[1].constructRef =
            'construct:unknown'
        Test-ApprovedContextualActionablePartial `
            -Observation $observation |
            Should -BeFalse
        $observation.findings[1].constructRef =
            'construct:actionable'
        $observation.counts.unknown = 1
        Test-ApprovedContextualActionablePartial `
            -Observation $observation |
            Should -BeFalse
    }

    It 'validates PR-wide actionable partials without a file anchor' {
        $prUnknown = [ordered]@{
            ruleId =
                'pr-template-compliance'
            issueIdentity =
                'v1:sha256:' + ('1' * 64)
            anchor = [ordered]@{
                scope = 'pull-request'
                subject = 'description'
            }
            constructRef =
                'construct:' + ('2' * 64)
            reconciliation = [ordered]@{
                classification = 'unknown'
                reason = 'other-review-at-anchor'
            }
        }
        $codeActionable = [ordered]@{
            ruleId =
                'exception-logging'
            anchor = [ordered]@{
                path = 'src/Test.cs'
                line = 20
            }
            constructRef =
                'construct:' + ('3' * 64)
            reconciliation = [ordered]@{
                classification = 'wouldCreate'
                reason = 'no-current-review-at-anchor'
            }
        }
        $observation = [ordered]@{
            findingsComplete = $false
            counts = [ordered]@{
                unknown = 0
                uncovered = 0
            }
            validationErrors = @()
            effects = [ordered]@{
                dedupe = [ordered]@{
                    unknown = 1
                }
            }
            findings = @(
                $prUnknown,
                $codeActionable)
        }

        Test-ApprovedContextualActionablePartial `
            -Observation $observation |
            Should -BeTrue

        $prActionable =
            $prUnknown |
                ConvertTo-Json -Depth 16 -Compress |
                ConvertFrom-Json `
                    -AsHashtable -Depth 16
        $prActionable.reconciliation.
            classification = 'wouldCreate'
        $observation.findings = @(
            $prUnknown,
            $prActionable)
        Test-ApprovedContextualActionablePartial `
            -Observation $observation |
            Should -BeFalse

        $prActionable.issueIdentity =
            'v1:sha256:' + ('4' * 64)
        $prActionable.constructRef =
            'construct:' + ('5' * 64)
        $observation.findings = @(
            $prUnknown,
            $prActionable)
        Test-ApprovedContextualActionablePartial `
            -Observation $observation |
            Should -BeTrue
    }

    It 'reconstructs plain and linked Owner presentation without requiring existing providers to opt in' {
        foreach ($linked in @($false, $true)) {
            $evidence = New-TestOwnerV2Evidence
            $config = [ordered]@{ subjectProvider = $evidence.Provider }
            if ($linked) {
                $evidence.Contract | Add-Member -NotePropertyName CommentPresentation `
                    -NotePropertyValue ([ordered]@{ subjectProvider = $evidence.Provider; ruleReferences = $null })
            }
            $evidence.Observation = Resolve-OwnerV2DiscussionReconciliation `
                -Observation $evidence.Observation -Contract $evidence.Contract `
                -Snapshot (New-TestOwnerV2Snapshot -Evidence $evidence)
            $evidence.Contract = New-ApprovedOwnerV2Contract -Declaration $evidence.Declaration
            Set-ApprovedOwnerV2CommentPresentation -Contract $evidence.Contract `
                -Observation $evidence.Observation -ToolkitConfig $config
            $proposal = Get-ApprovedOwnerV2Proposal -Evidence $evidence `
                -Finding $evidence.Observation.findings[0]
            $proposal.body | Should -Match '\*\*Changed-line occurrences:\*\*'
            if ($linked) {
                $proposal.body | Should -Match '\[tests/WidgetTests.cs:12\]\(https://'
            } else {
                $proposal.body | Should -Match '- `/tests/WidgetTests.cs:12`'
                $proposal.body | Should -Not -Match 'https://'
            }
            $proposal.bodySha256 | Should -BeExactly (
                Get-ApprovedOwnerV2TextSha256 $proposal.body)
        }
    }

    It 'rejects unknown or duplicate persisted presentation modes' {
        foreach ($variant in @('unknown', 'duplicate')) {
            $evidence = New-TestOwnerV2Evidence
            $mode = [ordered]@{
                kind = 'owner-v2-comment-presentation'
                sha256 = Get-ApprovedOwnerV2TextSha256 'owner-v2-comment-presentation:subject-provider-links-v1'
                signature = 'not-applicable'
            }
            if ($variant -ceq 'unknown') { $mode.sha256 = '0' * 64 }
            $evidence.Observation.sourceArtifacts += $mode
            if ($variant -ceq 'duplicate') { $evidence.Observation.sourceArtifacts += $mode }
            {
                Set-ApprovedOwnerV2CommentPresentation -Contract $evidence.Contract `
                    -Observation $evidence.Observation -ToolkitConfig @{
                        subjectProvider = $evidence.Provider
                    }
            } | Should -Throw '*unknown or ambiguous comment presentation mode*'
        }
    }

    It 'exports the unchanged V1 marker and anchor with the exact current body digest' {
        $evidence = New-TestOwnerV2Evidence
        $package = New-ApprovedOwnerV2ReviewPackage -Evidence $evidence

        @($package.proposals) | Should -HaveCount 1
        $proposal = $package.proposals[0]
        $proposal.markerComment | Should -BeExactly (
            "<!-- devpilot-owner-comment:v1:$($proposal.marker) -->")
        $proposal.body | Should -Match '\*\*Add an Owner attribute to this changed test method\*\*'
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
        $automaticTool = Get-Command (
            Join-Path $repoRoot `
                'tools\Invoke-AutomaticOwnerV2Delivery.ps1')
        $automaticTool.Parameters.Keys |
            Should -Contain ThirdPreviousRuleHash
        $automaticTool.Parameters.Keys |
            Should -Contain ThirdPreviousRuleLength
        $automaticTool.Parameters.Keys |
            Should -Contain ThirdUnchangedRuleId
    }
}

Describe 'Automatic Owner v2 create-only delivery' {
    It 'preserves the existing Owner 5 per run and 50 per PR ceiling' {
        $context = New-TestAutomaticOwnerV2Context
        $policy = New-AutomaticOwnerV2ServicePolicy `
            -Evidence $context.Evidence -PolicyId owner-existing-ceiling `
            -MaxCreatesPerRun 5 -MaxCreatesPerPullRequest 50 `
            -CreatedUtc '20260101T000000Z'
        $policy.limits.maxCreatesPerRun | Should -Be 5
        $policy.limits.maxCreatesPerPullRequest | Should -Be 50
        { Assert-AutomaticOwnerV2ServicePolicy `
                -Evidence $context.Evidence -Policy $policy } |
            Should -Not -Throw
    }

    It 'is disabled by default and fails closed on an unbound true value' {
        $disabled = Get-AutomaticOwnerV2Configuration -ToolkitConfig ([ordered]@{})
        $disabled.Enabled | Should -BeFalse

        {
            Get-AutomaticOwnerV2Configuration -ToolkitConfig ([ordered]@{
                    autoCreateOwnerComments = $true
                })
        } | Should -Throw '*signed policy*'
        {
            Get-AutomaticOwnerV2Configuration -ToolkitConfig ([ordered]@{
                    autoCreateOwnerComments = [ordered]@{
                        enabled = 'false'
                        policyPath = 'C:\private\policy.json'
                        policySha256 = 'a' * 64
                    }
                })
        } | Should -Throw '*exact JSON boolean*'
    }

    It 'creates only the exact allowed Owner method violation' {
        $context = New-TestAutomaticOwnerV2Context
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler

        $result.health | Should -BeExactly 'healthy'
        $result.providerWrites | Should -Be 1
        $result.modelWrites | Should -Be 0
        (Get-ApprovedOwnerV2Value $result.events[0] 'action' '') |
            Should -BeExactly 'create'
        (Get-ApprovedOwnerV2Value $result.events[0] 'outcome' '') |
            Should -BeExactly 'created'
        (Get-ApprovedOwnerV2Value $result.events[0] 'url' '') |
            Should -Match 'discussionId=100$'
        $provider.State.writes | Should -Be 1
    }

    It 'refuses stale rule, capability, identity, and implementation policies' `
        -TestCases @(
            @{ Name = 'rule'; Path = 'rule.hash' }
            @{ Name = 'capability'; Path = 'capability.id' }
            @{ Name = 'identity'; Path = 'reviewerIdentity.id' }
            @{ Name = 'implementation'; Path = 'implementation.providerSha256' }
        ) {
        param($Name, $Path)
        $context = New-TestAutomaticOwnerV2Context
        $parts = $Path.Split('.')
        $cursor = $context.Policy
        for ($index = 0; $index -lt $parts.Count - 1; $index++) {
            $cursor = $cursor[$parts[$index]]
        }
        $cursor[$parts[-1]] = 'tampered'
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler

        $result.health | Should -BeExactly 'refused'
        $result.diagnostic.code | Should -BeExactly 'policy-refused'
        $provider.State.writes | Should -Be 0
    }

    It 'refuses wrong construct, disposition, and update classification' `
        -TestCases @(
            @{ Name = 'construct'; Mutation = 'construct' }
            @{ Name = 'disposition'; Mutation = 'disposition' }
            @{ Name = 'update'; Mutation = 'update' }
        ) {
        param($Name, $Mutation)
        $context = New-TestAutomaticOwnerV2Context
        $finding = $context.Evidence.Observation.findings[0]
        if ($Mutation -ceq 'construct') {
            $finding.binding.source.representation.endLine++
        }
        elseif ($Mutation -ceq 'disposition') {
            $finding.disposition = 'advisory'
        }
        else {
            $finding.reconciliation.classification = 'wouldUpdate'
            $finding.reconciliation.reason = 'reviewer-marker-body-stale'
        }
        $context.Evidence.Record.resultDigest =
            Get-ApprovedOwnerV2Digest $context.Evidence.Observation
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler

        $result.health | Should -BeExactly 'refused'
        $provider.State.writes | Should -Be 0
    }

    It 'fails closed on live identity, head, and anchor drift' `
        -TestCases @(
            @{
                Name = 'identity'
                Arguments = @{ ForeignIdentity = $true }
                Code = 'live-reviewer-identity-drift'
            }
            @{
                Name = 'head'
                Arguments = @{ StaleHead = $true }
                Code = 'live-pr-binding-drift'
            }
            @{
                Name = 'anchor'
                Arguments = @{ StaleAnchor = $true }
                Code = 'live-anchor-drift'
            }
        ) {
        param($Name, $Arguments, $Code)
        $context = New-TestAutomaticOwnerV2Context
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence @Arguments
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler

        $result.health | Should -BeExactly 'refused'
        $result.diagnostic.code | Should -BeExactly $Code
        $provider.State.writes | Should -Be 0
    }

    It 'reports a typed digest for an unexpected preflight exception' {
        $context = New-TestAutomaticOwnerV2Context
        $provider = {
            param([string]$Action, [hashtable]$Arguments)
            throw 'simulated provider transport failure'
        }
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider

        $result.health | Should -BeExactly 'refused'
        $result.diagnostic.code |
            Should -BeExactly 'live-preflight-exception'
        $result.diagnostic.message |
            Should -Match '^Preflight threw RuntimeException; messageSha256=[0-9a-f]{64}$'
    }

    It 'refuses snapshot drift plus duplicate or foreign copied markers' `
        -TestCases @(
            @{ Name = 'snapshot'; Mode = 'snapshot' }
            @{ Name = 'duplicate'; Mode = 'duplicate' }
            @{ Name = 'foreign'; Mode = 'foreign' }
        ) {
        param($Name, $Mode)
        $context = New-TestAutomaticOwnerV2Context
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence
        if ($Mode -ceq 'snapshot') {
            $artifact = @($context.Evidence.Observation.sourceArtifacts |
                Where-Object kind -EQ 'owner-v2-discussion-snapshot')[0]
            $artifact.sha256 = '0' * 64
            $context.Evidence.Record.resultDigest =
                Get-ApprovedOwnerV2Digest $context.Evidence.Observation
        }
        else {
            $proposal = (New-ApprovedOwnerV2ReviewPackage `
                    -Evidence $context.Evidence).proposals[0]
            $first = New-TestOwnerV2Thread -Evidence $context.Evidence `
                -Body ([string]$proposal.body) `
                -ReviewerOwned:($Mode -cne 'foreign') `
                -ReviewerIdentityState $(if ($Mode -ceq 'foreign') {
                        'foreign'
                    }
                    else { 'matched' })
            $provider.State.threads = @($first)
            if ($Mode -ceq 'duplicate') {
                $provider.State.threads += New-TestOwnerV2Thread `
                    -Evidence $context.Evidence `
                    -Body ([string]$proposal.body) `
                    -ThreadId 20 -CommentId 21
            }
        }
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler

        $result.health | Should -BeExactly 'refused'
        $provider.State.writes | Should -Be 0
    }

    It 'delivers nine findings as five then four and then no-ops' {
        $context = New-TestAutomaticOwnerV2Context -FindingCount 9
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence

        $first = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $first.providerWrites | Should -Be 5
        $first.health | Should -BeExactly 'partial'
        $first.remainingWouldCreate | Should -Be 4

        Update-TestAutomaticOwnerV2Discussion `
            -Context $context -Provider $provider
        $second = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $second.providerWrites | Should -Be 4
        $second.health | Should -BeExactly 'healthy'
        $second.remainingWouldCreate | Should -Be 0

        Update-TestAutomaticOwnerV2Discussion `
            -Context $context -Provider $provider
        $third = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $third.providerWrites | Should -Be 0
        $third.health | Should -BeExactly 'healthy'
        $provider.State.writes | Should -Be 9
    }

    It 'enforces the signed per-PR create ceiling across runs' {
        $context = New-TestAutomaticOwnerV2Context -FindingCount 2
        $context.Policy = New-AutomaticOwnerV2ServicePolicy `
            -Evidence $context.Evidence -PolicyId 'owner-v2-test-policy' `
            -MaxCreatesPerRun 1 -MaxCreatesPerPullRequest 1 `
            -CreatedUtc '20260101T000000Z'
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence
        $first = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $first.providerWrites | Should -Be 1

        Update-TestAutomaticOwnerV2Discussion `
            -Context $context -Provider $provider
        $second = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $second.health | Should -BeExactly 'refused'
        $second.providerWrites | Should -Be 0
        $provider.State.writes | Should -Be 1
    }

    It 'does not write an existing exact noOp comment' {
        $context = New-TestAutomaticOwnerV2Context
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence
        $selection = (New-ApprovedOwnerV2ReviewPackage `
                -Evidence $context.Evidence).proposals[0]
        [void](& $provider.Handler 'CreateThread' @{
                evidence = $context.Evidence
                selection = $selection
                anchor = [ordered]@{}
            })
        Update-TestAutomaticOwnerV2Discussion `
            -Context $context -Provider $provider
        $before = $provider.State.writes
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler

        $result.health | Should -BeExactly 'healthy'
        $result.providerWrites | Should -Be 0
        $provider.State.writes | Should -Be $before
    }

    It 'confirms a successful create after a lost provider response' {
        $context = New-TestAutomaticOwnerV2Context
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence -FailCreateAfterWrite
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler

        $result.health | Should -BeExactly 'healthy'
        $result.providerWrites | Should -Be 1
        (Get-ApprovedOwnerV2Value $result.events[0] 'outcome' '') |
            Should -BeExactly 'created-confirmed-after-error'
        $provider.State.writes | Should -Be 1
    }

    It 'blocks blind retries when post-write readback is unavailable' {
        $context = New-TestAutomaticOwnerV2Context
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence -FailReadback
        $first = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler

        $first.health | Should -BeExactly 'refused'
        $first.events[-1].outcome | Should -BeExactly 'ambiguous-post-write'
        $first.providerWrites | Should -Be 1
        (Get-ApprovedOwnerV2Value `
            $first.events[-1] 'providerWriteState' '') |
            Should -BeExactly 'unknown'
        $writes = $provider.State.writes
        $second = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $second.health | Should -BeExactly 'refused'
        $provider.State.writes | Should -Be $writes
    }

    It 'charges an ambiguous write against the whole PR ceiling' {
        $context = New-TestAutomaticOwnerV2Context -FindingCount 2
        $context.Policy = New-AutomaticOwnerV2ServicePolicy `
            -Evidence $context.Evidence -PolicyId 'owner-v2-test-policy' `
            -MaxCreatesPerRun 1 -MaxCreatesPerPullRequest 1 `
            -CreatedUtc '20260101T000000Z'
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence -FailCreateAfterWrite -FailReadback
        $first = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $first.health | Should -BeExactly 'refused'
        $first.providerWrites | Should -Be 1
        $provider.State.failReadback = $false
        $writes = $provider.State.writes

        $second = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $second.health | Should -BeExactly 'refused'
        $second.providerWrites | Should -Be 0
        $provider.State.writes | Should -Be $writes
    }

    It 'treats duplicate post-write readback as ambiguous and blocks retry' {
        $context = New-TestAutomaticOwnerV2Context
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence -DuplicateReadback
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler

        $result.health | Should -BeExactly 'refused'
        $result.providerWrites | Should -Be 1
        (Get-ApprovedOwnerV2Value $result.events[-1] 'outcome' '') |
            Should -BeExactly 'ambiguous-post-write'
        (Get-ApprovedOwnerV2Value `
            $result.events[-1] 'providerWriteState' '') |
            Should -BeExactly 'unknown'
    }

    It 'recovers an interrupted signed intent without duplicating the comment' {
        $context = New-TestAutomaticOwnerV2Context
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence
        $selection = (New-ApprovedOwnerV2ReviewPackage `
                -Evidence $context.Evidence).proposals[0]
        [void](& $provider.Handler 'CreateThread' @{
                evidence = $context.Evidence
                selection = $selection
                anchor = [ordered]@{}
            })
        $intent = [ordered]@{
            schemaVersion = 1
            kind = 'owner-v2-service-create-intent'
            runId = 'interrupted-run'
            state = [ordered]@{ identity = $context.Evidence.Identity }
            subject = [ordered]@{ pullRequestId = 42 }
            reviewerIdentity = $context.Policy.reviewerIdentity
            selections = @($selection)
        }
        [void](Write-ApprovedOwnerV2SignedRecord -Path (
                Join-Path $context.Root (
                    "intents\$($context.Evidence.Identity)\interrupted-run.json")
            ) -Payload $intent -Key $context.Key)
        $before = $provider.State.writes
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler

        @($result.events | Where-Object {
                (Get-ApprovedOwnerV2Value $_ 'outcome' '') -ceq
                    'recovered-confirmed'
            }) |
            Should -HaveCount 1
        $provider.State.writes | Should -Be $before
    }

    It 'binds each repaired outcome only to that interrupted intent events' {
        $context = New-TestAutomaticOwnerV2Context -FindingCount 2
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence
        $proposals = (New-ApprovedOwnerV2ReviewPackage `
                -Evidence $context.Evidence).proposals
        for ($index = 0; $index -lt 2; $index++) {
            [void](& $provider.Handler 'CreateThread' @{
                    evidence = $context.Evidence
                    selection = $proposals[$index]
                    anchor = [ordered]@{}
                })
            $runId = "interrupted-$index"
            $intent = [ordered]@{
                schemaVersion = 1
                kind = 'owner-v2-service-create-intent'
                runId = $runId
                state = [ordered]@{ identity = $context.Evidence.Identity }
                subject = [ordered]@{ pullRequestId = 42 }
                reviewerIdentity = $context.Policy.reviewerIdentity
                selections = @($proposals[$index])
            }
            [void](Write-ApprovedOwnerV2SignedRecord -Path (
                    Join-Path $context.Root (
                        "intents\$($context.Evidence.Identity)\$runId.json")
                ) -Payload $intent -Key $context.Key)
        }
        [void](Invoke-AutomaticOwnerV2Comments `
                -Evidence $context.Evidence -Policy $context.Policy `
                -DeliveryRoot $context.Root -Key $context.Key `
                -Provider $provider.Handler)
        $outcomes = @(Get-ChildItem -LiteralPath (
                Join-Path $context.Root "outcomes\$($context.Evidence.Identity)"
            ) -Filter 'interrupted-*.json' -File | ForEach-Object {
                Read-ApprovedOwnerV2SignedRecord `
                    -Path $_.FullName -Key $context.Key
            })
        $outcomes | Should -HaveCount 2
        foreach ($outcome in $outcomes) {
            @($outcome.eventIds) | Should -HaveCount 1
            $eventPath = Join-Path $context.Root (
                "events\$($outcome.eventIds[0]).json")
            $event = Read-ApprovedOwnerV2SignedRecord `
                -Path $eventPath -Key $context.Key
            $event.runId | Should -BeExactly $outcome.runId
        }
    }

    It 'uses a distinct private key and emits signed dashboard-ready events' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $initialized = Initialize-AutomaticOwnerV2DeliveryRoot `
            -DeliveryRoot $root -RepoRoot $repoRoot
        $key = Get-AutomaticOwnerV2ServiceKey `
            -DeliveryRoot $initialized.Root
        $key | Should -HaveCount 32
        $initialized.KeyPath | Should -Match 'service-authorization'

        $context = New-TestAutomaticOwnerV2Context
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $eventPath = Get-ChildItem -LiteralPath (
            Join-Path $context.Root 'events') -Filter '*.json' -File |
            Select-Object -First 1
        $event = Read-ApprovedOwnerV2SignedRecord `
            -Path $eventPath.FullName -Key $context.Key
        $event.kind | Should -BeExactly 'owner-v2-delivery-event'
        $event.modelWriteCount | Should -Be 0
        $event.providerWriteCount | Should -Be 1
        $event.url | Should -Match '^https://dev.azure.com/'
        $finding = Get-ApprovedOwnerV2Value $result.events[0] 'finding'
        (Get-ApprovedOwnerV2Value $finding 'path' '') |
            Should -BeExactly 'tests/WidgetTests.cs'
    }

    It 'keeps model tools empty and relation delivery isolated' {
        $automatic = Get-Content -LiteralPath (
            Join-Path $repoRoot `
                'src\Agents\reviewer\AutomaticOwnerV2Comments.ps1') -Raw
        $scheduled = Get-Content -LiteralPath (
            Join-Path $repoRoot 'tools\Invoke-OwnerV2ScheduledDelivery.ps1') -Raw
        $modelRunner = Get-Content -LiteralPath (
            Join-Path $repoRoot `
                'src\DevPilot.OwnerModelRunner\DevPilot.OwnerModelRunner.psm1') -Raw

        $automatic | Should -Not -Match 'Open-AgentMcpSession|UpdateComment'
        $scheduled | Should -Match "owner-v2-preview-cohort"
        $scheduled | Should -Not -Match 'relation-v2-preview-cohort'
        $modelRunner | Should -Match 'effectiveTools'
        $modelRunner | Should -Match '@\(\)'
        (Get-AutomaticOwnerV2ExitCode -Health healthy) | Should -Be 0
        (Get-AutomaticOwnerV2ExitCode -Health disabled) | Should -Be 0
        (Get-AutomaticOwnerV2ExitCode -Health partial) | Should -Be 2
        (Get-AutomaticOwnerV2ExitCode -Health refused) | Should -Be 3
        (Get-AutomaticOwnerV2ExitCode -Health unexpected) | Should -Be 1
        (Get-AutomaticOwnerV2RunLimit `
            -PolicyMaximum 1 -RequestedMaximum 5) | Should -Be 1
        (Get-AutomaticOwnerV2RunLimit `
            -PolicyMaximum 5 -RequestedMaximum 3) | Should -Be 3
        {
            Get-AutomaticOwnerV2RunLimit `
                -PolicyMaximum 6 -RequestedMaximum 5
        } | Should -Throw '*per-run create ceiling*'
        (Get-AutomaticOwnerV2ScheduledHealth `
            -FailedCount 0 -CompletedCount 1 -AutomaticEnabled $true `
            -DeliveryResults @([pscustomobject]@{ health = 'healthy' }) `
            -RemainingRunCreates 0 -ProcessedRecords 1) |
            Should -BeExactly 'healthy'
        (Get-AutomaticOwnerV2ScheduledHealth `
            -FailedCount 0 -CompletedCount 2 -AutomaticEnabled $true `
            -DeliveryResults @([pscustomobject]@{ health = 'healthy' }) `
            -RemainingRunCreates 0 -ProcessedRecords 1) |
            Should -BeExactly 'partial'
        (Get-AutomaticOwnerV2ScheduledHealth `
            -FailedCount 0 -CompletedCount 2 -AutomaticEnabled $true `
            -DeliveryResults @(
                [pscustomobject]@{ health = 'refused' },
                [pscustomobject]@{ health = 'healthy' }
            ) -RemainingRunCreates 4 -ProcessedRecords 2) |
            Should -BeExactly 'partial'
        (Get-AutomaticOwnerV2ScheduledHealth `
            -FailedCount 0 -CompletedCount 1 -AutomaticEnabled $true `
            -DeliveryResults @([pscustomobject]@{ health = 'refused' }) `
            -RemainingRunCreates 5 -ProcessedRecords 1) |
            Should -BeExactly 'refused'
    }

    It 'runs the scheduler wrapper disabled with zero delivery state or writes' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $state = Join-Path $root 'state'
        $delivery = Join-Path $root 'delivery'
        $manifestPath = Join-Path $root 'cohort.json'
        $configPath = Join-Path $root 'config.json'
        [IO.File]::WriteAllText(
            $manifestPath,
            [IO.File]::ReadAllText((Join-Path $repoRoot `
                    'tests\fixtures\owner-orchestrator\generic-cohort.json')),
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText(
            $configPath,
            [IO.File]::ReadAllText((Join-Path $repoRoot `
                    'samples\owner-v2-auto-delivery.config.json')),
            [Text.UTF8Encoding]::new($false))
        $output = @(& (Get-Command pwsh).Source -NoProfile -File (
                Join-Path $repoRoot 'tools\Invoke-OwnerV2ScheduledDelivery.ps1'
            ) -StateRoot $state -ManifestPath $manifestPath `
            -ToolkitConfigPath $configPath -DeliveryRoot $delivery 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Disabled scheduler exited $LASTEXITCODE`: $($output -join "`n")"
        }
        ($output -join "`n") | Should -Match 'disabled'
        Test-Path -LiteralPath $delivery | Should -BeFalse
    }
}
