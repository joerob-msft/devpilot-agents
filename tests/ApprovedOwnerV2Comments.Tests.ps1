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

Describe 'Automatic Owner v2 create-only delivery' {
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
            @{ Name = 'identity'; Arguments = @{ ForeignIdentity = $true }
                ExpectedCode = 'live-reviewer-identity-drift' }
            @{ Name = 'head'; Arguments = @{ StaleHead = $true }
                ExpectedCode = 'live-pr-binding-drift' }
            @{ Name = 'anchor'; Arguments = @{ StaleAnchor = $true }
                ExpectedCode = 'live-anchor-drift' }
        ) {
        param($Name, $Arguments, $ExpectedCode)
        $context = New-TestAutomaticOwnerV2Context
        $provider = New-TestAutomaticOwnerV2Provider `
            -Evidence $context.Evidence @Arguments
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler

        $result.health | Should -BeExactly 'refused'
        $result.effectState |
            Should -BeExactly 'known-zero-pre-intent'
        $result.diagnostic.code |
            Should -BeExactly $ExpectedCode
        $provider.State.writes | Should -Be 0
    }

    It 'refuses snapshot drift plus duplicate or foreign copied markers' `
        -TestCases @(
            @{ Name = 'snapshot'; Mode = 'snapshot'
                ExpectedCode = 'live-discussion-drift' }
            @{ Name = 'duplicate'; Mode = 'duplicate'
                ExpectedCode = 'duplicate-marker' }
            @{ Name = 'foreign'; Mode = 'foreign'
                ExpectedCode = 'foreign-marker' }
        ) {
        param($Name, $Mode, $ExpectedCode)
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
        $result.effectState |
            Should -BeExactly 'known-zero-pre-intent'
        $result.diagnostic.code |
            Should -BeExactly $ExpectedCode
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

    It 'loads native history and exercises real sibling discovery through the automatic caller for <Mode>' -TestCases @(
        @{ Mode = 'exact' },
        @{ Mode = 'quota-and-dedup' },
        @{ Mode = 'baseline-drift' },
        @{ Mode = 'body-edit' },
        @{ Mode = 'reply' },
        @{ Mode = 'status-edit' },
        @{ Mode = 'deleted' },
        @{ Mode = 'foreign-author' },
        @{ Mode = 'changed-head' },
        @{ Mode = 'changed-iteration' },
        @{ Mode = 'duplicate-thread' },
        @{ Mode = 'copied-marker' },
        @{ Mode = 'invalid-hmac' }
    ) {
        param($Mode)
        Set-StrictMode -Version Latest
        $findingCount = if ($Mode -ceq 'quota-and-dedup') { 3 } else { 1 }
        $context = New-TestAutomaticOwnerV2Context -FindingCount $findingCount
        $evidence = $context.Evidence
        $reviewer = New-OwnerAzureDevOpsReviewerIdentity `
            -Id $evidence.Provider.reviewerIdentity.id `
            -Descriptor $evidence.Provider.reviewerIdentity.descriptor `
            -UniqueName $evidence.Provider.reviewerIdentity.uniqueName
        $iteration = [ordered]@{
            id = 6
            sourceCommit = $evidence.Declaration.head.sourceCommit
            targetCommit = $evidence.Declaration.target.targetCommit
        }
        $arguments = [ordered]@{
            repositoryId = $evidence.Declaration.subject.repositoryId
            projectId = $evidence.Declaration.subject.projectId
            pullRequestId = $evidence.Declaration.subject.pullRequestId
            sourceCommit = $evidence.Declaration.head.sourceCommit
            targetCommit = $evidence.Declaration.target.targetCommit
            targetRef = $evidence.Declaration.target.targetRef
            pageOrdinal = 0
            pageSize = 100
            continuationToken = $null
        }
        $baseAuthor = [ordered]@{
            id = $reviewer.Id
            descriptor = $reviewer.Descriptor
            uniqueName = $reviewer.UniqueName
        }
        $baseThreads = @(
            [ordered]@{
                id = 100
                status = 'active'
                isDeleted = $false
                publishedDate = '2026-01-01T00:00:00.0000000Z'
                lastUpdatedDate = '2026-01-01T00:00:01.0000000Z'
                properties = [ordered]@{}
                threadContext = [ordered]@{
                    filePath = '/src/Existing.cs'
                    rightFileStart = [ordered]@{ line = 5; offset = 1 }
                    rightFileEnd = [ordered]@{ line = 5; offset = 2 }
                }
                pullRequestThreadContext = [ordered]@{
                    changeTrackingId = 1
                    iterationContext = [ordered]@{
                        firstComparingIteration = 1
                        secondComparingIteration = 6
                    }
                }
                comments = @(
                    [ordered]@{
                        id = 1
                        parentCommentId = 0
                        author = $baseAuthor
                        content = 'Existing baseline comment.'
                        commentType = 'text'
                        publishedDate = '2026-01-01T00:00:00.0000000Z'
                        lastUpdatedDate = '2026-01-01T00:00:01.0000000Z'
                        usersLiked = @()
                    }
                )
            }
        )
        if ($Mode -ceq 'quota-and-dedup') {
            $firstProposal = Get-ApprovedOwnerV2Proposal -Evidence $evidence `
                -Finding $evidence.Observation.findings[0]
            $baseThreads += [ordered]@{
                id = 101
                status = 'active'
                isDeleted = $false
                publishedDate = '2026-01-01T00:00:02.0000000Z'
                lastUpdatedDate = '2026-01-01T00:00:03.0000000Z'
                properties = [ordered]@{}
                threadContext = [ordered]@{
                    filePath = '/' + [string]$firstProposal.path
                    rightFileStart = [ordered]@{ line = [int]$firstProposal.line; offset = 1 }
                    rightFileEnd = [ordered]@{ line = [int]$firstProposal.line; offset = 2 }
                }
                pullRequestThreadContext = [ordered]@{
                    changeTrackingId = 1
                    iterationContext = [ordered]@{
                        firstComparingIteration = 1
                        secondComparingIteration = 6
                    }
                }
                comments = @(
                    [ordered]@{
                        id = 1
                        parentCommentId = 0
                        author = $baseAuthor
                        content = [string]$firstProposal.body
                        commentType = 'text'
                        publishedDate = '2026-01-01T00:00:02.0000000Z'
                        lastUpdatedDate = '2026-01-01T00:00:03.0000000Z'
                        usersLiked = @()
                    }
                )
            }
        }
        $baseRaw = [ordered]@{
            count = $baseThreads.Count
            continuation_token = $null
            value = $baseThreads
        }
        $basePage = ConvertTo-OwnerAzureDevOpsDiscussionPage `
            -Arguments $arguments -RawResponse $baseRaw `
            -CurrentIteration $iteration -ReviewerIdentity $reviewer
        $evidence.Observation.sourceArtifacts[1].sha256 = ([string]$basePage.mappingDigest).Substring(10)
        $evidence.Observation.sourceArtifacts[2].sha256 = ([string]$basePage.reviewerIdentityDigest).Substring(10)
        $evidence.Provider.mappingDigest = [string]$basePage.mappingDigest
        $evidence.Provider.reviewerIdentity.digest = [string]$basePage.reviewerIdentityDigest
        $baseProvider = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
            -Name 'base-ado' -ReviewerIdentity $reviewer -Handler {
            param($Op, $ArgsMap)
            return $basePage
        }.GetNewClosure()
        $baseSnapshot = Get-OwnerDiscussionSnapshot -Contract $evidence.Contract `
            -Provider $baseProvider -RequireAzureDevOpsProvenance
        $baseSha256 = $baseSnapshot.Digest.Substring(10)
        $evidence.Observation.sourceArtifacts[0].sha256 = $baseSha256
        foreach ($findingItem in @($evidence.Observation.findings)) {
            $findingItem.reconciliation.discussionSha256 = $baseSha256
        }
        if ($Mode -ceq 'quota-and-dedup') {
            $mini = [ordered]@{
                lifecycle = [ordered]@{ status = 'completed' }
                findings = $evidence.Observation.findings
                effects = [ordered]@{
                    dedupe = [ordered]@{}
                    providerWrites = 0
                    writeToolInvocations = 0
                }
                sourceArtifacts = @()
            }
            $resolved = Resolve-OwnerV2DiscussionReconciliation `
                -Observation $mini -Contract $evidence.Contract `
                -Snapshot $baseSnapshot
            $evidence.Observation.findings = $resolved.findings
        }
        $evidence.Record.resultDigest = Get-ApprovedOwnerV2Digest $evidence.Observation

        $ownerRoot = Initialize-AutomaticOwnerV2DeliveryRoot `
            -DeliveryRoot $context.Root -RepoRoot $repoRoot
        $namedRootInit = Initialize-AutomaticOwnerV2DeliveryRoot `
            -DeliveryRoot (Join-Path $ownerRoot.Root 'named-areequal-v1') -RepoRoot $repoRoot
        $contextualRootInit = Initialize-AutomaticOwnerV2DeliveryRoot `
            -DeliveryRoot (Join-Path $ownerRoot.Root 'contextual-conventions-v1') -RepoRoot $repoRoot
        $namedRoot = [pscustomobject]@{
            Root = $namedRootInit.Root
            KeyPath = Join-Path $namedRootInit.Root 'keys\named-areequal-service-authorization.hmac'
        }
        $contextualRoot = [pscustomobject]@{
            Root = $contextualRootInit.Root
            KeyPath = Join-Path $contextualRootInit.Root 'keys\contextual-conventions-service-authorization.hmac'
        }
        [IO.File]::WriteAllBytes($ownerRoot.KeyPath, $context.Key)
        $namedKey = [byte[]](65..96)
        $contextualKey = [byte[]](97..128)
        [IO.File]::WriteAllBytes($namedRoot.KeyPath, $namedKey)
        [IO.File]::WriteAllBytes($contextualRoot.KeyPath, $contextualKey)
        $namedRoot.Root | Should -BeExactly (Join-Path $ownerRoot.Root 'named-areequal-v1')
        $contextualRoot.Root | Should -BeExactly (Join-Path $ownerRoot.Root 'contextual-conventions-v1')
        $identity = $evidence.Identity
        $subject = [ordered]@{
            projectId = $evidence.Declaration.subject.projectId
            repositoryId = $evidence.Declaration.subject.repositoryId
            pullRequestId = 42
            sourceCommit = $evidence.Declaration.head.sourceCommit
            targetCommit = $evidence.Declaration.target.targetCommit
            targetRef = $evidence.Declaration.target.targetRef
        }
        $namedBody = "Posted named comment.`n`n<!-- devpilot-named-areequal:v1:$('b' * 64) -->"
        $ctxBody = "**Use async all the way**`n`n**Rule:** Use async all the way.`n`nAwait the Task instead of blocking on Result.`n`nChanged construct: ``CreateWorkflowWithDualManagedIdentity``.`n`n**Changed-line occurrences:**`n- [src/flow/Tests/Tests.Flow.Web/ManagedApiConnectionDynamicInvokeTests.cs:4234](https://dev.azure.com/msazure/b32aa71e-8ed2-41b2-9d77-5bc261222004/_git/92afbde6-591e-4cee-b300-ccfee7824994?version=GCaaaa2b7ccc045aef2f2b41b8ff3574a5ff1e25e2&path=%2Fsrc%2Fflow%2FTests%2FTests.Flow.Web%2FManagedApiConnectionDynamicInvokeTests.cs&line=4234)`n`n<!-- devpilot-contextual-convention:v1:70d56611d26caecabdc0f62a2a4a58a6b0e19c530facd9132248bd3e59684cab -->"
        foreach ($lane in @(
                @{
                    Root = $ownerRoot.Root
                    Key = $context.Key
                    Prefix = 'owner-v2'
                    Capability = 'bpm-test-ownership@1'
                    MarkerTag = 'devpilot-owner-comment'
                    ThreadId = 199
                    RunId = ('a' * 32)
                    EventId = ('c' + ('a' * 31))
                    FindingId = 'owner-v2:' + ('3' * 64)
                    Marker = ('a' * 64)
                    Path = 'tests/PriorOwnerTests.cs'
                    Line = 18
                    Symbol = 'PriorOwnerMethod'
                    Body = "Posted owner comment.`n`n<!-- devpilot-owner-comment:v1:$('a' * 64) -->"
                    IncludeBodySha = $false
                    RuleId = $null
                    Scope = $null
                },
                @{
                    Root = $namedRoot.Root
                    Key = $namedKey
                    Prefix = 'named-areequal-v2'
                    Capability = 'bpm-named-areequal-arguments@1'
                    MarkerTag = 'devpilot-named-areequal'
                    ThreadId = 200
                    RunId = ('b' * 32)
                    EventId = ('c' + ('b' * 31))
                    FindingId = 'named-areequal-v1:' + ('4' * 64)
                    Marker = ('b' * 64)
                    Path = 'tests/WidgetTests.cs'
                    Line = 20
                    Symbol = 'CreatesWidget'
                    Body = "Posted named comment.`n`n<!-- devpilot-named-areequal:v1:$('b' * 64) -->"
                    IncludeBodySha = $true
                    RuleId = $null
                    Scope = $null
                },
                @{
                    Root = $contextualRoot.Root
                    Key = $contextualKey
                    Prefix = 'contextual-conventions-v1'
                    Capability = 'bpm-contextual-conventions@1'
                    MarkerTag = 'devpilot-contextual-convention'
                    ThreadId = 267699657
                    RunId = 'ba458f0ba1624604aa62354740c7ed11'
                    EventId = '263885ad7a8d4d9db81e126db3fc344b'
                    FindingId = 'contextual-v1:dbd55a5d624ffa4eb8a63059d5baa9ed6d44967bc548cbf8e2a1941d257b8e21'
                    Marker = '70d56611d26caecabdc0f62a2a4a58a6b0e19c530facd9132248bd3e59684cab'
                    Path = 'src/flow/Tests/Tests.Flow.Web/ManagedApiConnectionDynamicInvokeTests.cs'
                    Line = 4234
                    Symbol = 'CreateWorkflowWithDualManagedIdentity'
                    Body = $ctxBody
                    IncludeBodySha = $true
                    RuleId = 'async-all-the-way'
                    Scope = 'changed-line'
                }
            )) {
            $laneDir = $lane.Root
            foreach ($leaf in @('events', "intents\$identity", "outcomes\$identity")) {
                New-Item -ItemType Directory -Path (Join-Path $laneDir $leaf) -Force | Out-Null
            }
            $runId = $lane.RunId
            $eventId = $lane.EventId
            $marker = $lane.Marker
            $body = $lane.Body
            $bodySha = Get-ApprovedOwnerV2TextSha256 $body
            $selection = [ordered]@{
                body = $body
                classification = 'wouldCreate'
                constructIdentity = 'v1:sha256:' + ('1' * 64)
                constructRef = 'construct:' + ('2' * 64)
                findingId = $lane.FindingId
                line = $lane.Line
                marker = $marker
                markerComment = "<!-- $($lane.MarkerTag):v1:$marker -->"
                path = $lane.Path
                rationale = 'no-current-review-at-anchor'
                semanticKey = 'v1:sha256:' + ('4' * 64)
                symbol = $lane.Symbol
            }
            if ($lane.IncludeBodySha) {
                $selection['bodySha256'] = $bodySha
            }
            if ($null -ne $lane.RuleId) {
                $selection['ruleId'] = $lane.RuleId
                $selection['scope'] = $lane.Scope
                $selection['endLine'] = $lane.Line
            }
            $intentPayload = [ordered]@{
                schemaVersion = 1
                kind = "$($lane.Prefix)-service-create-intent"
                runId = $runId
                policyDigest = 'v1:sha256:' + ('5' * 64)
                state = [ordered]@{ identity = $identity }
                subject = $subject
                currentIterationId = 6
                discussionSnapshotSha256 = $baseSha256
                rule = [ordered]@{
                    repositoryId = 'devpilot-agents'
                    path = 'docs/owner.md'
                    commit = '7' * 40
                    section = $lane.Capability
                    hash = 'v1:sha256:' + ('8' * 64)
                    length = 100
                }
                capability = [ordered]@{
                    id = $lane.Capability
                    digest = 'v1:sha256:' + ('9' * 64)
                }
                reviewerIdentity = [ordered]@{
                    id = $reviewer.Id
                    descriptor = $reviewer.Descriptor
                    uniqueName = $reviewer.UniqueName
                }
                implementation = [ordered]@{}
                selections = @($selection)
                createdUtc = '20261023T041945Z'
            }
            $findingObj = [ordered]@{
                stateIdentity = $identity
                findingId = $selection.findingId
                marker = $marker
                path = $selection.path
                line = $selection.line
                symbol = $selection.symbol
            }
            if ($lane.IncludeBodySha) {
                $findingObj['bodySha256'] = $bodySha
            }
            if ($null -ne $lane.RuleId) {
                $findingObj['ruleId'] = $lane.RuleId
                $findingObj['scope'] = $lane.Scope
            }
            $eventPayload = [ordered]@{
                schemaVersion = 1
                kind = "$($lane.Prefix)-delivery-event"
                eventId = $eventId
                runId = $runId
                occurredUtc = '20261023T042021Z'
                runHealth = 'healthy'
                capabilityId = $lane.Capability
                subject = $subject
                finding = $findingObj
                action = 'create'
                outcome = 'created'
                threadId = $lane.ThreadId
                commentId = 1
                url = 'https://example.invalid'
                modelWriteCount = 0
                providerWriteCount = 1
                providerWriteState = 'confirmed'
                diagnostic = $null
            }
            $outcomePayload = [ordered]@{
                schemaVersion = 1
                kind = "$($lane.Prefix)-service-create-outcome"
                runId = $runId
                stateIdentity = $identity
                status = 'completed'
                providerWrites = 1
                providerWritesConservative = 1
                modelWrites = 0
                eventIds = @($eventId)
                remainingWouldCreate = 0
                diagnostic = $null
                createdUtc = '20261023T042021Z'
            }
            [void](Write-ApprovedOwnerV2SignedRecord `
                -Path (Join-Path $laneDir "intents\$identity\$runId.json") `
                -Payload $intentPayload -Key $lane.Key)
            [void](Write-ApprovedOwnerV2SignedRecord `
                -Path (Join-Path $laneDir "outcomes\$identity\$runId.json") `
                -Payload $outcomePayload -Key $lane.Key)
            [void](Write-ApprovedOwnerV2SignedRecord `
                -Path (Join-Path $laneDir "events\$eventId.json") `
                -Payload $eventPayload -Key $lane.Key)
        }

        # Build live discussion response with both authenticated Named thread 200 and Contextual thread 267699657 added
        $liveRaw = $baseRaw | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32
        $liveRaw.value = @($liveRaw.value) + @(
            [ordered]@{
                id = 200
                status = 'active'
                isDeleted = $false
                publishedDate = '2026-01-01T00:01:00.0000000Z'
                lastUpdatedDate = '2026-01-01T00:01:01.0000000Z'
                properties = [ordered]@{}
                threadContext = [ordered]@{
                    filePath = '/tests/WidgetTests.cs'
                    rightFileStart = [ordered]@{ line = 20; offset = 1 }
                    rightFileEnd = [ordered]@{ line = 20; offset = 2 }
                }
                pullRequestThreadContext = [ordered]@{
                    changeTrackingId = 2
                    iterationContext = [ordered]@{
                        firstComparingIteration = 1
                        secondComparingIteration = 6
                    }
                }
                comments = @(
                    [ordered]@{
                        id = 1
                        parentCommentId = 0
                        author = $baseAuthor
                        content = $namedBody
                        commentType = 'text'
                        publishedDate = '2026-01-01T00:01:00.0000000Z'
                        lastUpdatedDate = '2026-01-01T00:01:01.0000000Z'
                        usersLiked = @()
                    }
                )
            },
            [ordered]@{
                id = 267699657
                status = 'active'
                isDeleted = $false
                publishedDate = '2026-01-01T00:01:30.0000000Z'
                lastUpdatedDate = '2026-01-01T00:01:31.0000000Z'
                properties = [ordered]@{}
                threadContext = [ordered]@{
                    filePath = '/src/flow/Tests/Tests.Flow.Web/ManagedApiConnectionDynamicInvokeTests.cs'
                    rightFileStart = [ordered]@{ line = 4234; offset = 1 }
                    rightFileEnd = [ordered]@{ line = 4234; offset = 2 }
                }
                pullRequestThreadContext = [ordered]@{
                    changeTrackingId = 3
                    iterationContext = [ordered]@{
                        firstComparingIteration = 1
                        secondComparingIteration = 6
                    }
                }
                comments = @(
                    [ordered]@{
                        id = 1
                        parentCommentId = 0
                        author = $baseAuthor
                        content = $ctxBody
                        commentType = 'text'
                        publishedDate = '2026-01-01T00:01:30.0000000Z'
                        lastUpdatedDate = '2026-01-01T00:01:31.0000000Z'
                        usersLiked = @()
                    }
                )
            }
        )
        $liveRaw.count = $liveRaw.value.Count
        $livePage = ConvertTo-OwnerAzureDevOpsDiscussionPage `
            -Arguments $arguments -RawResponse $liveRaw `
            -CurrentIteration $iteration -ReviewerIdentity $reviewer
        $liveProvider = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
            -Name 'live-ado' -ReviewerIdentity $reviewer -Handler {
            param($Op, $ArgsMap)
            return $livePage
        }.GetNewClosure()
        $liveSnapshot = Get-OwnerDiscussionSnapshot -Contract $evidence.Contract `
            -Provider $liveProvider -RequireAzureDevOpsProvenance
        $liveSnapshot.Digest.Substring(10) | Should -Not -BeExactly $baseSha256

        $approval = [ordered]@{
            state = [ordered]@{ identity = $identity }
            subject = $subject
            operator = [ordered]@{
                id = $reviewer.Id
                descriptor = $reviewer.Descriptor
                uniqueName = $reviewer.UniqueName
            }
            provider = $evidence.Provider
        }

        $providerState = [ordered]@{
            raw = $liveRaw | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32
            reads = 0
            writes = 0
            nextThreadId = 400
            staleHead = $false
            iteration = $iteration | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable -Depth 8
        }
        $ctxThreadIndex = $providerState.raw.value.Count - 1
        switch ($Mode) {
            'baseline-drift' {
                $providerState.raw.value[0].comments[0].content = 'Unexpected baseline edit.'
            }
            'body-edit' {
                $providerState.raw.value[$ctxThreadIndex].comments[0].content = $ctxBody.Replace(
                    'Await the Task instead of blocking on Result.',
                    'Edited contextual comment text.')
            }
            'reply' {
                $providerState.raw.value[$ctxThreadIndex].comments = @(
                    $providerState.raw.value[$ctxThreadIndex].comments
                ) + @(
                    [ordered]@{
                        id = 2
                        parentCommentId = 1
                        author = $baseAuthor
                        content = 'Human follow-up reply'
                        commentType = 'text'
                        publishedDate = '2026-01-01T00:02:00.0000000Z'
                        lastUpdatedDate = '2026-01-01T00:02:01.0000000Z'
                        usersLiked = @()
                    }
                )
            }
            'status-edit' {
                $providerState.raw.value[$ctxThreadIndex].status = 'closed'
            }
            'deleted' {
                $providerState.raw.value[$ctxThreadIndex].isDeleted = $true
            }
            'foreign-author' {
                $providerState.raw.value[$ctxThreadIndex].comments[0].author = [ordered]@{
                    id = '99999999-9999-9999-9999-999999999999'
                    descriptor = 'aad.foreign'
                    uniqueName = 'foreign@example.com'
                }
            }
            'changed-head' {
                $providerState.staleHead = $true
            }
            'changed-iteration' {
                $providerState.iteration.id = 7
            }
            'duplicate-thread' {
                $dupThread = $providerState.raw.value[$ctxThreadIndex] |
                    ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32
                $dupThread.id = 267699658
                $providerState.raw.value = @($providerState.raw.value) + @($dupThread)
                $providerState.raw.count = $providerState.raw.value.Count
            }
            'copied-marker' {
                $copiedThread = $providerState.raw.value[0] |
                    ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32
                $copiedThread.id = 300
                $copiedThread.comments[0].content = 'Unauthenticated extra thread.'
                $providerState.raw.value = @($providerState.raw.value) + @($copiedThread)
                $providerState.raw.count = $providerState.raw.value.Count
            }
            'invalid-hmac' {
                $eventPath = Join-Path $namedRoot.Root ("events\c" + ('b' * 31) + '.json')
                $eventPayload = Read-ApprovedOwnerV2SignedRecord -Path $eventPath -Key $namedKey
                $eventPayload.subject.sourceCommit = '0' * 40
                [void](Write-ApprovedOwnerV2SignedRecord `
                    -Path (Join-Path $namedRoot.Root 'events\unauthenticated.json') `
                    -Payload $eventPayload -Key ([byte[]](129..160)))
            }
        }
        $discussionArguments = $arguments
        $providerHandler = {
            param([string]$Action, [hashtable]$Arguments)
            if ($Action -ceq 'ReadCurrent') {
                $providerState.reads++
                $page = ConvertTo-OwnerAzureDevOpsDiscussionPage `
                    -Arguments $discussionArguments -RawResponse $providerState.raw `
                    -CurrentIteration $providerState.iteration -ReviewerIdentity $reviewer
                $adapter = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
                    -Name 'caller-ado' -ReviewerIdentity $reviewer -Handler {
                    param($Op, $ArgsMap)
                    return $page
                }.GetNewClosure()
                $anchors = foreach ($findingItem in @($evidence.Observation.findings)) {
                    $rep = $findingItem.binding.source.representation
                    [ordered]@{
                        path = [string]$rep.path
                        startLine = [int]$rep.startLine
                        endLine = [int]$rep.endLine
                        changeTrackingId = 7
                        iterationId = [int]$providerState.iteration.id
                    }
                }
                return [pscustomobject]@{
                    ProviderBinding = $evidence.Provider
                    PullRequest = [ordered]@{
                        pullRequestId = $subject.pullRequestId
                        status = 'active'
                        isDraft = $false
                        repositoryId = $subject.repositoryId
                        projectId = $subject.projectId
                        sourceCommit = $(if ($providerState.staleHead) { '0' * 40 } else { $subject.sourceCommit })
                        targetCommit = $subject.targetCommit
                        targetRef = $subject.targetRef
                    }
                    Reviewer = $approval.operator
                    Snapshot = Get-OwnerDiscussionSnapshot -Contract $evidence.Contract `
                        -Provider $adapter -RequireAzureDevOpsProvenance
                    Anchors = @($anchors)
                }
            }
            if ($Action -ceq 'CreateThread') {
                $providerState.writes++
                $threadId = [int]$providerState.nextThreadId
                $providerState.nextThreadId++
                $created = $liveRaw.value[1] | ConvertTo-Json -Depth 32 |
                    ConvertFrom-Json -AsHashtable -Depth 32
                $created.id = $threadId
                $created.comments[0].content = [string]$Arguments.selection.body
                $created.threadContext.filePath = '/' + [string]$Arguments.selection.path
                $created.threadContext.rightFileStart.line = [int]$Arguments.selection.line
                $created.threadContext.rightFileEnd.line = [int]$Arguments.selection.line
                $providerState.raw.value = @($providerState.raw.value) + @($created)
                $providerState.raw.count = $providerState.raw.value.Count
                return @{ id = $threadId }
            }
            throw "Unexpected automatic caller operation '$Action'."
        }.GetNewClosure()
        $script:loadedSiblingKeys = [Collections.Generic.List[object]]::new()
        $script:readSiblingServiceKey = ${function:Get-AutomaticOwnerV2ServiceKey}
        Mock Get-AutomaticOwnerV2ServiceKey {
            param($DeliveryRoot, $Delivery)
            [byte[]]$bytes = & $script:readSiblingServiceKey -DeliveryRoot $DeliveryRoot -Delivery $Delivery
            [void]$script:loadedSiblingKeys.Add(@{ Root = $DeliveryRoot; Bytes = $bytes })
            return ,$bytes
        }
        $maxCreatesPerRun = if ($Mode -ceq 'quota-and-dedup') { 1 } else { 5 }
        $maxCreatesPerPr = if ($Mode -ceq 'quota-and-dedup') { 2 } else { 25 }
        # Remove synthetic prior owner event 199 before invoking automatic delivery so PR quota starts at 0
        Remove-Item -LiteralPath (Join-Path $ownerRoot.Root ("events\c" + ('a' * 31) + '.json')) -Force
        $policy = New-AutomaticOwnerV2ServicePolicy -Evidence $evidence `
            -PolicyId 'native-sibling-caller' -MaxCreatesPerRun $maxCreatesPerRun `
            -MaxCreatesPerPullRequest $maxCreatesPerPr
        if ($Mode -ceq 'invalid-hmac') {
            {
                Invoke-AutomaticOwnerV2Comments -Evidence $evidence -Policy $policy `
                    -DeliveryRoot $ownerRoot.Root -Key $context.Key -Provider $providerHandler
            } | Should -Throw '*signature did not verify*'
            $script:loadedSiblingKeys | Should -HaveCount 1
            $providerState.reads | Should -Be 0
        }
        else {
            $result = Invoke-AutomaticOwnerV2Comments -Evidence $evidence -Policy $policy `
                -DeliveryRoot $ownerRoot.Root -Key $context.Key -Provider $providerHandler
            if ($Mode -ceq 'exact') {
                $result.health | Should -BeExactly healthy -Because ($result | ConvertTo-Json -Depth 16)
                $result.providerWrites | Should -Be 1
                $providerState.writes | Should -Be 1
                $providerState.reads | Should -Be 3
                $result.events | Should -HaveCount 1
                $result.events[0].outcome | Should -BeExactly created
                $result.events[0].providerWriteState | Should -BeExactly confirmed
                $signedEvent = Read-ApprovedOwnerV2SignedRecord `
                    -Path (Join-Path $ownerRoot.Root ("events\" + $result.events[0].eventId + '.json')) `
                    -Key $context.Key
                $signedEvent.threadId | Should -Be 400
                $signedEvent.commentId | Should -Be 1
                $expectedProposal = Get-ApprovedOwnerV2Proposal -Evidence $evidence `
                    -Finding $evidence.Observation.findings[0]
                $createdThread = @($providerState.raw.value | Where-Object { [int]$_.id -eq 400 })[0]
                $createdThread.comments[0].content | Should -BeExactly $expectedProposal.body
                $createdThread.comments[0].content | Should -Match ([regex]::Escape($expectedProposal.markerComment))
                $createdThread.comments[0].author.id | Should -BeExactly $reviewer.Id
                $createdThread.comments[0].author.descriptor | Should -BeExactly $reviewer.Descriptor
                $createdThread.comments[0].author.uniqueName | Should -BeExactly $reviewer.UniqueName

                $readerCmd = Get-Command Get-ApprovedOwnerV2AuthenticatedPriorComments -ErrorAction Stop
                @($readerCmd.Parameters['DeliveryRoot'].Attributes | Where-Object { $_ -is [Parameter] }).Mandatory | Should -Contain $true
                @($readerCmd.Parameters['Key'].Attributes | Where-Object { $_ -is [Parameter] }).Mandatory | Should -Contain $true
                $readerCmd.Parameters.ContainsKey('KeyPath') | Should -BeFalse

                $namedDeliveryCheck = Initialize-AutomaticOwnerV2DeliveryRoot `
                    -DeliveryRoot $context.Root -RepoRoot $repoRoot -Delivery named-areequal
                $ctxDeliveryCheck = Initialize-AutomaticOwnerV2DeliveryRoot `
                    -DeliveryRoot $context.Root -RepoRoot $repoRoot -Delivery contextual-conventions
                $namedDeliveryCheck.Root | Should -BeExactly $namedRoot.Root
                $ctxDeliveryCheck.Root | Should -BeExactly $contextualRoot.Root

                $ownerPrior = @(Get-ApprovedOwnerV2AuthenticatedPriorComments `
                    -DeliveryRoot $ownerRoot.Root -Key $context.Key -Delivery owner)
                $ownerPrior | Should -HaveCount 1
                $ownerPrior[0].currentIterationId | Should -Be 6
                $ownerPrior[0].selection.ruleId | Should -BeExactly ''
                $ownerPrior[0].selection.bodySha256 | Should -BeExactly (
                    Get-ApprovedOwnerV2TextSha256 ([string]$ownerPrior[0].selection.body))

                $namedPrior = @(Get-ApprovedOwnerV2AuthenticatedPriorComments `
                    -DeliveryRoot $namedRoot.Root -Key $namedKey -Delivery named-areequal)
                $namedPrior | Should -HaveCount 1
                $namedPrior[0].currentIterationId | Should -Be 6
                $namedPrior[0].discussionSnapshotSha256 | Should -BeExactly $baseSha256
                $namedPrior[0].selection.ruleId | Should -BeExactly ''

                $ctxPrior = @(Get-ApprovedOwnerV2AuthenticatedPriorComments `
                    -DeliveryRoot $contextualRoot.Root -Key $contextualKey -Delivery contextual-conventions)
                $ctxPrior | Should -HaveCount 1
                $ctxPrior[0].currentIterationId | Should -Be 6
                $ctxPrior[0].selection.ruleId | Should -BeExactly 'async-all-the-way'
                $ctxPrior[0].selection.bodySha256 | Should -BeExactly '5eecaa88301df5548638dc55258844c92db860e07df74e9ea9784997b80a0d25'
                $ctxPrior[0].event.threadId | Should -Be 267699657

                $combinedSiblingPrior = @($namedPrior) + @($ctxPrior)
                (Test-ApprovedOwnerV2ReconciledSnapshotDigest `
                    -Approval $approval -Evidence $evidence -Live @{ Snapshot = $liveSnapshot } `
                    -ExpectedSnapshotSha256 $baseSha256 `
                    -AuthenticatedPriorComments $combinedSiblingPrior) | Should -BeTrue
                (Test-ApprovedOwnerV2ReconciledSnapshotDigest `
                    -Approval $approval -Evidence $evidence -Live @{ Snapshot = $liveSnapshot } `
                    -ExpectedSnapshotSha256 $baseSha256 `
                    -AuthenticatedPriorComments @($namedPrior[0], $namedPrior[0], $ctxPrior[0])) | Should -BeFalse
                (Test-ApprovedOwnerV2ReconciledSnapshotDigest `
                    -Approval $approval -Evidence $evidence -Live @{ Snapshot = $liveSnapshot } `
                    -ExpectedSnapshotSha256 $baseSha256 `
                    -AuthenticatedPriorComments $namedPrior) | Should -BeFalse
                $badIterProof = $ctxPrior[0] | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable -Depth 16
                $badIterProof.currentIterationId = 5
                (Test-ApprovedOwnerV2ReconciledSnapshotDigest `
                    -Approval $approval -Evidence $evidence -Live @{ Snapshot = $liveSnapshot } `
                    -ExpectedSnapshotSha256 $baseSha256 `
                    -AuthenticatedPriorComments @($namedPrior[0], $badIterProof)) | Should -BeFalse
                $boolIterProof = $ctxPrior[0] | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable -Depth 16
                $boolIterProof.currentIterationId = $true
                (Test-ApprovedOwnerV2ReconciledSnapshotDigest `
                    -Approval $approval -Evidence $evidence -Live @{ Snapshot = $liveSnapshot } `
                    -ExpectedSnapshotSha256 $baseSha256 `
                    -AuthenticatedPriorComments @($namedPrior[0], $boolIterProof)) | Should -BeFalse
            }
            elseif ($Mode -ceq 'quota-and-dedup') {
                $result.health | Should -BeExactly partial -Because ($result | ConvertTo-Json -Depth 16)
                $result.providerWrites | Should -Be 1
                $result.remainingWouldCreate | Should -Be 1
                $result.events | Should -HaveCount 1
                $result.events[0].outcome | Should -BeExactly 'created'
                $result.events[0].finding.findingId | Should -BeExactly (
                    [string]$evidence.Observation.findings[1].identity)
            }
            elseif ($Mode -ceq 'changed-head') {
                $result.health | Should -BeExactly refused
                $result.providerWrites | Should -Be 0
                $result.diagnostic.code | Should -BeExactly live-pr-binding-drift
            }
            else {
                $result.health | Should -BeExactly refused
                $result.providerWrites | Should -Be 0
                $result.diagnostic.code | Should -BeExactly live-discussion-drift
            }
            $script:loadedSiblingKeys | Should -HaveCount 2
            @($script:loadedSiblingKeys.Root) | Should -Contain $namedRoot.Root
            @($script:loadedSiblingKeys.Root) | Should -Contain $contextualRoot.Root
        }
        foreach ($loaded in $script:loadedSiblingKeys) {
            $loaded.Bytes | Should -BeOfType ([byte])
            @($loaded.Bytes | Where-Object { $_ -ne 0 }) | Should -HaveCount 0
        }
        [Convert]::ToHexString([IO.File]::ReadAllBytes($namedRoot.KeyPath)) |
            Should -BeExactly ([Convert]::ToHexString($namedKey))
        [Convert]::ToHexString([IO.File]::ReadAllBytes($contextualRoot.KeyPath)) |
            Should -BeExactly ([Convert]::ToHexString($contextualKey))
        [Convert]::ToHexString($context.Key) |
            Should -BeExactly ([Convert]::ToHexString([byte[]](33..64)))
        if ($Mode -notin @('exact', 'quota-and-dedup')) {
            $providerState.writes | Should -Be 0
        }
    }

    It 'reconciles frozen PR 16711323 contextual thread 267699657 iteration 6 shape through Invoke-AutomaticOwnerV2Comments and refuses all nine negative mutations' {
        Set-StrictMode -Version Latest
        $context = New-TestAutomaticOwnerV2Context
        $evidence = $context.Evidence
        $frozenSubject = [ordered]@{
            projectId = 'b32aa71e-8ed2-41b2-9d77-5bc261222004'
            pullRequestId = 16711323
            repositoryId = '92afbde6-591e-4cee-b300-ccfee7824994'
            sourceCommit = 'aaaa2b7ccc045aef2f2b41b8ff3574a5ff1e25e2'
            targetCommit = 'b9c630fca6e3afa2c5c7a4a22442faa205e7be79'
            targetRef = 'refs/heads/master'
        }
        $frozenReviewer = [ordered]@{
            descriptor = 'aad.YmZiY2I0MjQtYzVjMi03NTcwLWEyNGUtYjcwODA0MTczZmRj'
            id = 'c2fde8da-b51f-4450-8f71-6c04a8364480'
            uniqueName = 'daviburg@ntdev.microsoft.com'
        }
        $evidence.Declaration.subject.projectId = $frozenSubject.projectId
        $evidence.Declaration.subject.repositoryId = $frozenSubject.repositoryId
        $evidence.Declaration.subject.pullRequestId = $frozenSubject.pullRequestId
        $evidence.Declaration.head.sourceCommit = $frozenSubject.sourceCommit
        $evidence.Declaration.target.targetCommit = $frozenSubject.targetCommit
        $evidence.Declaration.target.targetRef = $frozenSubject.targetRef
        $evidence.Contract = New-OwnerAcquisitionContract `
            -RepositoryId $frozenSubject.repositoryId `
            -ProjectId $frozenSubject.projectId `
            -PullRequestId $frozenSubject.pullRequestId `
            -SourceCommit $frozenSubject.sourceCommit `
            -TargetCommit $frozenSubject.targetCommit `
            -TargetRef $frozenSubject.targetRef `
            -RuleRepositoryId $evidence.Declaration.rule.repositoryId `
            -RulePath $evidence.Declaration.rule.path `
            -RuleCommit $evidence.Declaration.rule.commit `
            -RuleSection $evidence.Declaration.rule.section `
            -RuleHash $evidence.Declaration.rule.hash `
            -RuleLength $evidence.Declaration.rule.length `
            -ConfigId $evidence.Declaration.config.id `
            -ConfigDigest $evidence.Declaration.config.digest `
            -CapabilityId $evidence.Declaration.capability.id `
            -CapabilityDigest $evidence.Declaration.capability.digest `
            -Limits (New-OwnerAdapterLimits -MaximumFiles 64 `
                -MaximumBytes 16777216 -MaximumReads 128)
        $evidence.Declaration.facadeBinding = [ordered]@{
            bindingId = $evidence.Contract.Binding.BindingId
            subjectKey = $evidence.Contract.Binding.SubjectKey
            headKey = $evidence.Contract.Binding.HeadKey
            ruleKey = $evidence.Contract.Binding.RuleKey
            capabilityKey = $evidence.Contract.Binding.CapabilityKey
        }
        $evidence.Observation.subject.pullRequestId = $frozenSubject.pullRequestId
        $evidence.Observation.subject.repositoryId = $frozenSubject.repositoryId
        $evidence.Observation.subject.headCommit = $frozenSubject.sourceCommit
        $evidence.Observation.subject.targetCommit = $frozenSubject.targetCommit
        $evidence.Observation.subject.targetRef = $frozenSubject.targetRef
        $ownerMarker = Get-OwnerV1WriterMarkerKey -Contract $evidence.Contract `
            -Finding $evidence.Observation.findings[0]
        $ownerBody = Format-OwnerV1WriterComment -Contract $evidence.Contract `
            -Finding $evidence.Observation.findings[0] -MarkerKey $ownerMarker
        $evidence.Observation.findings[0].providerMarker.sha256 = Get-ApprovedOwnerV2TextSha256 $ownerMarker
        $evidence.Observation.findings[0].reconciliation.bodySha256 = Get-ApprovedOwnerV2TextSha256 $ownerBody
        $evidence.Provider.reviewerIdentity.id = $frozenReviewer.id
        $evidence.Provider.reviewerIdentity.descriptor = $frozenReviewer.descriptor
        $evidence.Provider.reviewerIdentity.uniqueName = $frozenReviewer.uniqueName

        $reviewer = New-OwnerAzureDevOpsReviewerIdentity `
            -Id $frozenReviewer.id `
            -Descriptor $frozenReviewer.descriptor `
            -UniqueName $frozenReviewer.uniqueName
        $iteration = [ordered]@{
            id = 6
            sourceCommit = $frozenSubject.sourceCommit
            targetCommit = $frozenSubject.targetCommit
        }
        $arguments = [ordered]@{
            repositoryId = $frozenSubject.repositoryId
            projectId = $frozenSubject.projectId
            pullRequestId = $frozenSubject.pullRequestId
            sourceCommit = $frozenSubject.sourceCommit
            targetCommit = $frozenSubject.targetCommit
            targetRef = $frozenSubject.targetRef
            pageOrdinal = 0
            pageSize = 100
            continuationToken = $null
        }
        $baseRaw = [ordered]@{
            count = 1
            continuation_token = $null
            value = @(
                [ordered]@{
                    id = 9001
                    status = 'active'
                    isDeleted = $false
                    publishedDate = '2026-10-23T04:19:00.0000000Z'
                    lastUpdatedDate = '2026-10-23T04:19:01.0000000Z'
                    properties = [ordered]@{}
                    threadContext = [ordered]@{
                        filePath = '/tests/SyntheticBaseline.cs'
                        rightFileStart = [ordered]@{ line = 1; offset = 1 }
                        rightFileEnd = [ordered]@{ line = 1; offset = 2 }
                    }
                    pullRequestThreadContext = [ordered]@{
                        changeTrackingId = 1
                        iterationContext = [ordered]@{
                            firstComparingIteration = 1
                            secondComparingIteration = 6
                        }
                    }
                    comments = @(
                        [ordered]@{
                            id = 1
                            parentCommentId = 0
                            author = [ordered]@{
                                id = '99999999-9999-9999-9999-999999999999'
                                descriptor = 'aad.foreign'
                                uniqueName = 'foreign@example.com'
                            }
                            content = 'Synthetic unchanged baseline thread; historical raw snapshot was not retained.'
                            commentType = 'text'
                            publishedDate = '2026-10-23T04:19:00.0000000Z'
                            lastUpdatedDate = '2026-10-23T04:19:01.0000000Z'
                            usersLiked = @()
                        }
                    )
                }
            )
        }
        $basePage = ConvertTo-OwnerAzureDevOpsDiscussionPage `
            -Arguments $arguments -RawResponse $baseRaw `
            -CurrentIteration $iteration -ReviewerIdentity $reviewer
        $evidence.Observation.sourceArtifacts[1].sha256 = ([string]$basePage.mappingDigest).Substring(10)
        $evidence.Observation.sourceArtifacts[2].sha256 = ([string]$basePage.reviewerIdentityDigest).Substring(10)
        $evidence.Provider.mappingDigest = [string]$basePage.mappingDigest
        $evidence.Provider.reviewerIdentity.digest = [string]$basePage.reviewerIdentityDigest
        $baseProvider = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
            -Name 'frozen-base-ado' -ReviewerIdentity $reviewer -Handler {
            param($Op, $ArgsMap)
            return $basePage
        }.GetNewClosure()
        $baseSnapshot = Get-OwnerDiscussionSnapshot -Contract $evidence.Contract `
            -Provider $baseProvider -RequireAzureDevOpsProvenance
        $baseSha256 = $baseSnapshot.Digest.Substring(10)
        $evidence.Observation.sourceArtifacts[0].sha256 = $baseSha256
        $evidence.Observation.findings[0].reconciliation.discussionSha256 = $baseSha256
        $evidence.Record.subjectDigest = Get-ApprovedOwnerV2Digest $evidence.Declaration.subject
        $evidence.Record.headDigest = Get-ApprovedOwnerV2Digest $evidence.Declaration.head
        $evidence.Record.resultDigest = Get-ApprovedOwnerV2Digest $evidence.Observation

        $ownerRoot = Initialize-AutomaticOwnerV2DeliveryRoot `
            -DeliveryRoot $context.Root -RepoRoot $repoRoot
        $contextualRoot = Initialize-AutomaticOwnerV2DeliveryRoot `
            -DeliveryRoot (Join-Path $ownerRoot.Root 'contextual-conventions-v1') -RepoRoot $repoRoot
        $contextualRootPath = $contextualRoot.Root
        $contextualKeyPath = Join-Path $contextualRootPath 'keys\contextual-conventions-service-authorization.hmac'
        [IO.File]::WriteAllBytes($ownerRoot.KeyPath, $context.Key)
        $ctxKey = [byte[]](1..32)
        [IO.File]::WriteAllBytes($contextualKeyPath, $ctxKey)

        $ctxStateIdentity = '88111bc33ed8f7ce288a40c91271b46b1f227ca32fa7204e605c56eb25553abe'
        $ctxRunId = 'ba458f0ba1624604aa62354740c7ed11'
        $ctxEventId = '263885ad7a8d4d9db81e126db3fc344b'
        $ctxMarker = '70d56611d26caecabdc0f62a2a4a58a6b0e19c530facd9132248bd3e59684cab'
        $ctxBody = "**Use async all the way**`n`n**Rule:** Use async all the way.`n`nAwait the Task instead of blocking on Result.`n`nChanged construct: ``CreateWorkflowWithDualManagedIdentity``.`n`n**Changed-line occurrences:**`n- [src/flow/Tests/Tests.Flow.Web/ManagedApiConnectionDynamicInvokeTests.cs:4234](https://dev.azure.com/msazure/b32aa71e-8ed2-41b2-9d77-5bc261222004/_git/92afbde6-591e-4cee-b300-ccfee7824994?version=GCaaaa2b7ccc045aef2f2b41b8ff3574a5ff1e25e2&path=%2Fsrc%2Fflow%2FTests%2FTests.Flow.Web%2FManagedApiConnectionDynamicInvokeTests.cs&line=4234)`n`n<!-- devpilot-contextual-convention:v1:70d56611d26caecabdc0f62a2a4a58a6b0e19c530facd9132248bd3e59684cab -->"
        $ctxBodySha = '5eecaa88301df5548638dc55258844c92db860e07df74e9ea9784997b80a0d25'
        (Get-ApprovedOwnerV2TextSha256 $ctxBody) | Should -BeExactly $ctxBodySha

        foreach ($leaf in @('events', "intents\$ctxStateIdentity", "outcomes\$ctxStateIdentity")) {
            New-Item -ItemType Directory -Path (Join-Path $contextualRootPath $leaf) -Force | Out-Null
        }
        $ctxIntentPayload = [ordered]@{
            schemaVersion = 1
            kind = 'contextual-conventions-v1-service-create-intent'
            runId = $ctxRunId
            policyDigest = 'v1:sha256:c7c79cfe93313e93476bc938ba66a552ef83de3ce87e76f327d90e8e93c1a698'
            state = [ordered]@{ identity = $ctxStateIdentity }
            subject = $frozenSubject
            currentIterationId = 6
            discussionSnapshotSha256 = '7f57a9eb046aa32b538f2569b23cb43d394dc81ea26ae55d756367935232fd24'
            rule = [ordered]@{
                commit = '4a9ba28959c6f6928b4b20f13fe7ab930f372c37'
                hash = 'v1:sha256:d89e4eb694c7df7bc45a615b693ffc9eada6fe47645c70d19505d535fb9d2d40'
                length = 13291
                path = 'src/DevPilot.OwnerCapability/Policy/contextual-conventions.v1.json'
                repositoryId = 'devpilot-agents'
                section = 'bpm-contextual-conventions@1'
            }
            capability = [ordered]@{
                digest = 'v1:sha256:13f845c3db01826e21aba0dd060bbd669c2b1b0a22e04438ab46b33a8ad14874'
                id = 'bpm-contextual-conventions@1'
            }
            reviewerIdentity = $frozenReviewer
            implementation = [ordered]@{}
            selections = @(
                [ordered]@{
                    body = $ctxBody
                    bodySha256 = $ctxBodySha
                    classification = 'wouldCreate'
                    constructIdentity = 'v1:sha256:f79fa2cbf0be598d62f7d9db9f256d3c7e304f15f5b3669ba4b6ee89f200ca9d'
                    constructRef = 'construct:619a4ae0cc8fdaa63a9267977930042b54caf2a2c4ba1dc1baa3082ae6697704'
                    endLine = 4234
                    findingId = 'contextual-v1:dbd55a5d624ffa4eb8a63059d5baa9ed6d44967bc548cbf8e2a1941d257b8e21'
                    line = 4234
                    marker = $ctxMarker
                    markerComment = "<!-- devpilot-contextual-convention:v1:$ctxMarker -->"
                    path = 'src/flow/Tests/Tests.Flow.Web/ManagedApiConnectionDynamicInvokeTests.cs'
                    rationale = 'no-current-review-at-anchor'
                    ruleId = 'async-all-the-way'
                    scope = 'changed-line'
                    semanticKey = 'v1:sha256:e1f8bb7d9f50b48726dd99c9aa3fced23c1768b9330424cdc7ff1d047861e071'
                    symbol = 'CreateWorkflowWithDualManagedIdentity'
                }
            )
            createdUtc = '20261023T041945Z'
        }
        $ctxOutcomePayload = [ordered]@{
            schemaVersion = 1
            kind = 'contextual-conventions-v1-service-create-outcome'
            runId = $ctxRunId
            stateIdentity = $ctxStateIdentity
            status = 'completed'
            providerWrites = 1
            providerWritesConservative = 1
            modelWrites = 0
            eventIds = @($ctxEventId)
            remainingWouldCreate = 0
            diagnostic = $null
            createdUtc = '20261023T042021Z'
        }
        $ctxEventPayload = [ordered]@{
            schemaVersion = 1
            kind = 'contextual-conventions-v1-delivery-event'
            eventId = $ctxEventId
            runId = $ctxRunId
            occurredUtc = '20261023T042021Z'
            runHealth = 'healthy'
            capabilityId = 'bpm-contextual-conventions@1'
            subject = $frozenSubject
            finding = [ordered]@{
                bodySha256 = $ctxBodySha
                findingId = 'contextual-v1:dbd55a5d624ffa4eb8a63059d5baa9ed6d44967bc548cbf8e2a1941d257b8e21'
                line = 4234
                marker = $ctxMarker
                path = 'src/flow/Tests/Tests.Flow.Web/ManagedApiConnectionDynamicInvokeTests.cs'
                ruleId = 'async-all-the-way'
                scope = 'changed-line'
                stateIdentity = $ctxStateIdentity
                symbol = 'CreateWorkflowWithDualManagedIdentity'
            }
            action = 'create'
            outcome = 'created'
            threadId = 267699657
            commentId = 1
            url = 'https://dev.azure.com/msazure/One/_git/92afbde6-591e-4cee-b300-ccfee7824994/pullrequest/16711323?_a=files&discussionId=267699657'
            modelWriteCount = 0
            providerWriteCount = 1
            providerWriteState = 'confirmed'
            diagnostic = $null
        }
        [void](Write-ApprovedOwnerV2SignedRecord `
            -Path (Join-Path $contextualRootPath "intents\$ctxStateIdentity\$ctxRunId.json") `
            -Payload $ctxIntentPayload -Key $ctxKey)
        [void](Write-ApprovedOwnerV2SignedRecord `
            -Path (Join-Path $contextualRootPath "outcomes\$ctxStateIdentity\$ctxRunId.json") `
            -Payload $ctxOutcomePayload -Key $ctxKey)
        [void](Write-ApprovedOwnerV2SignedRecord `
            -Path (Join-Path $contextualRootPath "events\$ctxEventId.json") `
            -Payload $ctxEventPayload -Key $ctxKey)

        $liveRaw = $baseRaw | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32
        $liveRaw.value = @($liveRaw.value) + @(
            [ordered]@{
                id = 267699657
                status = 'active'
                isDeleted = $false
                publishedDate = '2026-10-23T04:20:20.0000000Z'
                lastUpdatedDate = '2026-10-23T04:20:21.0000000Z'
                properties = [ordered]@{}
                threadContext = [ordered]@{
                    filePath = '/src/flow/Tests/Tests.Flow.Web/ManagedApiConnectionDynamicInvokeTests.cs'
                    rightFileStart = [ordered]@{ line = 4234; offset = 1 }
                    rightFileEnd = [ordered]@{ line = 4234; offset = 2 }
                }
                pullRequestThreadContext = [ordered]@{
                    changeTrackingId = 2
                    iterationContext = [ordered]@{
                        firstComparingIteration = 1
                        secondComparingIteration = 6
                    }
                }
                comments = @(
                    [ordered]@{
                        id = 1
                        parentCommentId = 0
                        author = $frozenReviewer
                        content = $ctxBody
                        commentType = 'text'
                        publishedDate = '2026-10-23T04:20:20.0000000Z'
                        lastUpdatedDate = '2026-10-23T04:20:21.0000000Z'
                        usersLiked = @()
                    }
                )
            }
        )
        $liveRaw.count = $liveRaw.value.Count
        $livePage = ConvertTo-OwnerAzureDevOpsDiscussionPage `
            -Arguments $arguments -RawResponse $liveRaw `
            -CurrentIteration $iteration -ReviewerIdentity $reviewer
        $liveSnapshot = Get-OwnerDiscussionSnapshot -Contract $evidence.Contract `
            -Provider (New-OwnerAzureDevOpsReadOnlyProviderAdapter -Name 'frozen-live-ado' -ReviewerIdentity $reviewer -Handler { return $livePage }.GetNewClosure()) `
            -RequireAzureDevOpsProvenance

        $providerState = [ordered]@{
            raw = $liveRaw | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32
            reads = 0
            writes = 0
        }
        $discussionArguments = $arguments
        $providerHandler = {
            param([string]$Action, [hashtable]$Arguments)
            if ($Action -ceq 'ReadCurrent') {
                $providerState.reads++
                $page = ConvertTo-OwnerAzureDevOpsDiscussionPage `
                    -Arguments $discussionArguments -RawResponse $providerState.raw `
                    -CurrentIteration $iteration -ReviewerIdentity $reviewer
                $adapter = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
                    -Name 'frozen-caller-ado' -ReviewerIdentity $reviewer -Handler {
                    param($Op, $ArgsMap)
                    return $page
                }.GetNewClosure()
                return [pscustomobject]@{
                    ProviderBinding = $evidence.Provider
                    PullRequest = [ordered]@{
                        pullRequestId = $frozenSubject.pullRequestId
                        status = 'active'
                        isDraft = $false
                        repositoryId = $frozenSubject.repositoryId
                        projectId = $frozenSubject.projectId
                        sourceCommit = $frozenSubject.sourceCommit
                        targetCommit = $frozenSubject.targetCommit
                        targetRef = $frozenSubject.targetRef
                    }
                    Reviewer = $frozenReviewer
                    Snapshot = Get-OwnerDiscussionSnapshot -Contract $evidence.Contract `
                        -Provider $adapter -RequireAzureDevOpsProvenance
                    Anchors = @([ordered]@{
                        path = 'tests/WidgetTests.cs'
                        startLine = 12
                        endLine = 12
                        changeTrackingId = 7
                        iterationId = 6
                    })
                }
            }
            if ($Action -ceq 'CreateThread') {
                $providerState.writes++
                $created = $liveRaw.value[1] | ConvertTo-Json -Depth 32 |
                    ConvertFrom-Json -AsHashtable -Depth 32
                $created.id = 267699900
                $created.comments[0].content = [string]$Arguments.selection.body
                $created.threadContext.filePath = '/' + [string]$Arguments.selection.path
                $created.threadContext.rightFileStart.line = [int]$Arguments.selection.line
                $created.threadContext.rightFileEnd.line = [int]$Arguments.selection.line
                $providerState.raw.value = @($providerState.raw.value) + @($created)
                $providerState.raw.count = $providerState.raw.value.Count
                return @{ id = 267699900 }
            }
            throw "Unexpected automatic caller operation '$Action'."
        }.GetNewClosure()
        $policy = New-AutomaticOwnerV2ServicePolicy -Evidence $evidence `
            -PolicyId 'frozen-16711323-caller'
        $result = Invoke-AutomaticOwnerV2Comments -Evidence $evidence -Policy $policy `
            -DeliveryRoot $ownerRoot.Root -Key $context.Key -Provider $providerHandler
        $result.health | Should -BeExactly healthy -Because ($result | ConvertTo-Json -Depth 16)
        $result.providerWrites | Should -Be 1
        $providerState.writes | Should -Be 1
        $result.events | Should -HaveCount 1
        $result.events[0].outcome | Should -BeExactly created
        $result.events[0].providerWriteState | Should -BeExactly confirmed
        $result.events[0].threadId | Should -Be 267699900

        $proofs = @(Get-ApprovedOwnerV2AuthenticatedPriorComments `
            -DeliveryRoot $contextualRootPath -Key $ctxKey -Delivery contextual-conventions)
        $proofs | Should -HaveCount 1
        $approval = [ordered]@{
            subject = $frozenSubject
            operator = $frozenReviewer
            provider = $evidence.Provider
        }
        $liveObj = [pscustomobject]@{
            PullRequest = [ordered]@{} + $frozenSubject + [ordered]@{ status = 'active'; isDraft = $false }
            ProviderBinding = $evidence.Provider
            Reviewer = $frozenReviewer
            Snapshot = [pscustomobject]@{
                State = $liveSnapshot.State
                Reason = $liveSnapshot.Reason
                Digest = $liveSnapshot.Digest
                MappingDigest = $liveSnapshot.MappingDigest
                ReviewerIdentityDigest = $liveSnapshot.ReviewerIdentityDigest
                CurrentIterationId = $liveSnapshot.CurrentIterationId
                Threads = @($liveSnapshot.Threads)
            }
            Anchors = @()
        }
        (Test-ApprovedOwnerV2ReconciledSnapshotDigest -Approval $approval `
            -Live $liveObj -ExpectedSnapshotSha256 $baseSha256 `
            -AuthenticatedPriorComments $proofs) | Should -BeTrue

        foreach ($negMode in @(
                'baseline-edit', 'reply', 'body-edit', 'closed-thread', 'deleted-thread',
                'foreign-author', 'iteration-drift', 'duplicate-proof', 'missing-proof'
            )) {
            $changed = $liveObj | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32
            $caseProofs = $proofs
            switch ($negMode) {
                'baseline-edit' { $changed.Snapshot.Threads[0].comments[0].body = 'Unexpected baseline edit.' }
                'reply' {
                    $changed.Snapshot.Threads[1].comments = @($changed.Snapshot.Threads[1].comments) + @([ordered]@{
                        commentId = 2L; commentType = 'text'; isDeleted = $false
                        reviewerOwned = $false; reviewerIdentityState = 'foreign'
                        body = 'Reply.'; bodyDigest = 'v1:sha256:' + (Get-ApprovedOwnerV2TextSha256 'Reply.')
                    })
                }
                'body-edit' { $changed.Snapshot.Threads[1].comments[0].body = "$ctxBody edited" }
                'closed-thread' { $changed.Snapshot.Threads[1].status = 'closed' }
                'deleted-thread' { $changed.Snapshot.Threads[1].isDeleted = $true }
                'foreign-author' { $changed.Snapshot.Threads[1].comments[0].reviewerOwned = $false }
                'iteration-drift' { $changed.Snapshot.CurrentIterationId = 7L }
                'duplicate-proof' { $caseProofs = @($proofs[0], $proofs[0]) }
                'missing-proof' { $caseProofs = @() }
            }
            (Test-ApprovedOwnerV2ReconciledSnapshotDigest -Approval $approval `
                -Live ([pscustomobject]$changed) -ExpectedSnapshotSha256 $baseSha256 `
                -AuthenticatedPriorComments $caseProofs) |
                Should -BeFalse -Because "negative case '$negMode' must refuse"
        }
    }
}
