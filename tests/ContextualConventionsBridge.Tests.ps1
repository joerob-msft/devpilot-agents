#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') -Force
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.ContextualConventionsBridge\DevPilot.ContextualConventionsBridge.psd1') -Force
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1') -Force
    . (Join-Path $repoRoot `
        'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')

    function Get-ContextualTestTextDigest {
        param([Parameter(Mandatory)][string]$Text)
        return 'v1:sha256:' +
            [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes(
                        $Text))).ToLowerInvariant()
    }

    function New-ContextualTestConfig {
        $reviewer =
            New-OwnerAzureDevOpsReviewerIdentity `
                -Id '33333333-3333-3333-3333-333333333333' `
                -Descriptor 'aad.synthetic-service-account' `
                -UniqueName 'service@example.invalid'
        $adapter =
            New-OwnerAzureDevOpsReadOnlyProviderAdapter `
                -Name contextual-bridge-config `
                -ReviewerIdentity $reviewer `
                -Handler { throw 'not invoked' }
        return [ordered]@{
            schemaVersion = 1
            enabled = $false
            readOnly = $true
            dryRun = $true
            organization =
                'https://dev.azure.com/example-org'
            projectName = 'ExampleProject'
            projectId =
                '22222222-2222-2222-2222-222222222222'
            repositoryId =
                '11111111-1111-1111-1111-111111111111'
            expectedAccount = [ordered]@{
                id =
                    '33333333-3333-3333-3333-333333333333'
                descriptor =
                    'aad.synthetic-service-account'
                uniqueName =
                    'service@example.invalid'
            }
            automationMarker =
                '[DevPilot-Automation:v1]'
            rules = @([ordered]@{
                    id =
                        'bpm-contextual-conventions@1'
                    capability =
                        'bpm-contextual-conventions@1'
                })
            contextualRule = [ordered]@{
                repositoryId = 'devpilot-agents'
                path =
                    'src/DevPilot.OwnerCapability/Policy/contextual-conventions.v1.json'
                section =
                    'bpm-contextual-conventions@1'
                hash =
                    'v1:sha256:6a7db82e68b407af4ed19aab4517973337592e757a32d5fa7a142b63ef75d22a'
                length = 5205
            }
            toolkit = [ordered]@{
                ref =
                    'refs/heads/contextual-test'
                head = 'a' * 40
                tree = 'b' * 40
            }
            subjectProvider = [ordered]@{
                kind =
                    'azure-devops-read-only-v1'
                organization =
                    'https://dev.azure.com/example-org'
                projectName = 'ExampleProject'
                projectId =
                    '22222222-2222-2222-2222-222222222222'
                repositoryName =
                    'ExampleRepository'
                repositoryId =
                    '11111111-1111-1111-1111-111111111111'
                maximumFiles = 64
                maximumBytes = 16777216
                maximumReads = 128
            }
            discussionProvider = [ordered]@{
                kind =
                    'azure-devops-rest-owner-discussions-v1'
                mappingDigest =
                    $adapter.
                        AzureDevOpsDiscussionMappingDigest
                reviewerIdentity = [ordered]@{
                    id = [string]$reviewer.Id
                    descriptor =
                        [string]$reviewer.Descriptor
                    uniqueName =
                        [string]$reviewer.UniqueName
                    digest =
                        $adapter.
                            AzureDevOpsReviewerIdentityDigest
                }
            }
            capability = [ordered]@{
                id =
                    'bpm-contextual-conventions@1'
                implementationSha256 =
                    'fc312d515ec9b52389f79ea353ab6a4bc8d690cf81a1505766a0ffe7f59f710a'
            }
            sharedAcquisition = [ordered]@{
                kind =
                    'devpilot-shared-review-acquisition-v1'
                activePrIntakeSha256 =
                    (Get-FileHash (
                        Join-Path $repoRoot `
                            'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psm1') `
                        -Algorithm SHA256).Hash.
                    ToLowerInvariant()
                contextualBridgeSha256 =
                    (Get-FileHash (
                        Join-Path $repoRoot `
                            'src\DevPilot.ContextualConventionsBridge\DevPilot.ContextualConventionsBridge.psm1') `
                        -Algorithm SHA256).Hash.
                    ToLowerInvariant()
                toolSha256 =
                    (Get-FileHash (
                        Join-Path $repoRoot `
                            'tools\Invoke-SharedReviewAcquisition.ps1') `
                        -Algorithm SHA256).Hash.
                    ToLowerInvariant()
            }
            autoCreateContextualConventionComments =
                $false
            limits = [ordered]@{
                pageSize = 50
                maxPages = 8
                maxPullRequests = 20
                maxHeadsPerRun = 4
                maxReads = 128
                maxSeconds = 30
                maxChangedFiles = 64
                maxChangedLines = 100000
                maxThreads = 100
                maxComments = 500
            }
        }
    }

    function New-ContextualPreparedIntake {
        param(
            [string]$Content =
                'using System.IO; class C { void M() { try { X(); } catch (IOException ex) when (!ex.IsFatal()) { Logger.Error(ex.Message); } } }'
        )
        $head = [ordered]@{
            repositoryId =
                '11111111-1111-1111-1111-111111111111'
            projectId =
                '22222222-2222-2222-2222-222222222222'
            pullRequestId = 42
            sourceRef = 'refs/heads/feature'
            targetRef = 'refs/heads/master'
            sourceCommit = 'c' * 40
            targetCommit = 'd' * 40
            iterationId = 3
            status = 'active'
            isDraft = $false
        }
        $digest =
            Get-ContextualTestTextDigest $Content
        $changes = [ordered]@{
            changedFiles = 1
            changedLines = 1
            entries = @([ordered]@{
                    changeTrackingId = 7
                    path = 'src/Checks.cs'
                    changeType = 'edit'
                    state = 'complete'
                    spans = @([ordered]@{
                            startLine = 1
                            endLine = 1
                            state = 'complete'
                            sourceDigest = $digest
                        })
                    content = $Content
                    byteLength =
                        [Text.Encoding]::UTF8.
                            GetByteCount($Content)
                    sourceDigest = $digest
                })
        }
        $intake = [ordered]@{
            schemaVersion = 1
            kind =
                'devpilot-active-pr-intake-result'
            populationKnown = $true
            inventory = [ordered]@{
                state = 'complete'
                eligible = 1
            }
            counts = [ordered]@{
                error = 0
            }
            heads = @([ordered]@{
                    pullRequestId = 42
                    targetRef =
                        'refs/heads/master'
                    reasonCode = 'selected'
                    declaration = $head
                })
            transientSnapshots = [ordered]@{
                '42' = [ordered]@{
                    head = $head
                    changes = $changes
                    discussions = [ordered]@{
                        threads = @()
                        count = 0
                    }
                    sourceDigest = 'e' * 64
                }
            }
        }
        return [pscustomobject]@{
            Intake = $intake
            Head = $head
        }
    }

    function New-ContextualUpgradeRecognitionCase {
        $config = New-ContextualTestConfig
        $head = [ordered]@{
            repositoryId = $config.repositoryId
            projectId = $config.projectId
            pullRequestId = 42
            sourceCommit = 'c' * 40
            targetCommit = 'd' * 40
            targetRef = 'refs/heads/master'
        }
        $contract = New-OwnerAcquisitionContract `
            -RepositoryId $head.repositoryId `
            -ProjectId $head.projectId `
            -PullRequestId $head.pullRequestId `
            -SourceCommit $head.sourceCommit `
            -TargetCommit $head.targetCommit `
            -TargetRef $head.targetRef `
            -RuleRepositoryId (
                $config.contextualRule.repositoryId) `
            -RulePath $config.contextualRule.path `
            -RuleCommit ('f' * 40) `
            -RuleSection (
                $config.contextualRule.section) `
            -RuleHash $config.contextualRule.hash `
            -RuleLength (
                $config.contextualRule.length) `
            -ConfigId contextual-test `
            -ConfigDigest (
                'v1:sha256:' + ('1' * 64)) `
            -CapabilityId (
                $config.capability.id) `
            -CapabilityDigest (
                'v1:sha256:' +
                $config.capability.
                    implementationSha256) `
            -Limits (
                New-OwnerAdapterLimits `
                    -MaximumFiles 64 `
                    -MaximumBytes 16777216 `
                    -MaximumReads 128)
        $finding = [ordered]@{
            identity =
                'contextual-v1:' + ('2' * 64)
            semanticKey =
                'v1:sha256:' + ('3' * 64)
            disposition = 'violation'
            reason =
                'string-comparison-not-explicit'
            evidence =
                'Use explicit StringComparison semantics.'
            ruleId =
                'explicit-string-comparison'
            ruleRef =
                'rule:' + ('4' * 64)
            constructRef =
                'construct:' + ('5' * 64)
            anchor = [ordered]@{
                path = 'src/Checks.cs'
                line = 32
                symbol = 'FilterByTag'
            }
            binding = [ordered]@{
                constructIdentity =
                    'v1:sha256:' + ('6' * 64)
            }
        }
        $observation = [ordered]@{
            capability =
                'bpm-contextual-conventions@1'
            lifecycle =
                [ordered]@{ status = 'completed' }
            findings = @($finding)
            findingsComplete = $false
            counts = [ordered]@{
                checked = 1
                violations = 1
                unknown = 0
            }
            effects = [ordered]@{
                providerWrites = 0
                writeToolInvocations = 0
                dedupe = [ordered]@{}
            }
            sourceArtifacts = @()
        }
        $marker = '7' * 64
        $body = "Prior contextual review.`n`n" +
            "<!-- devpilot-contextual-convention:v1:$marker -->"
        $reviewer = [ordered]@{
            id = [string]$config.expectedAccount.id
            descriptor =
                [string]$config.expectedAccount.descriptor
            uniqueName =
                [string]$config.expectedAccount.uniqueName
        }
        $proof = [ordered]@{
            schemaVersion = 1
            kind =
                'owner-v2-authenticated-prior-comment'
            delivery =
                'contextual-conventions'
            capabilityId =
                'bpm-contextual-conventions@1'
            subject = $head
            rule = [ordered]@{
                repositoryId =
                    $config.contextualRule.repositoryId
                path =
                    $config.contextualRule.path
                commit = '8' * 40
                section =
                    $config.contextualRule.section
                hash =
                    $config.contextualRule.hash
                length =
                    $config.contextualRule.length
            }
            reviewerIdentity = $reviewer
            reviewerIdentityDigest =
                $config.discussionProvider.
                    reviewerIdentity.digest
            selection = [ordered]@{
                findingId =
                    'contextual-v1:' + ('9' * 64)
                marker = $marker
                body = $body
                bodySha256 =
                    [Convert]::ToHexString(
                        [Security.Cryptography.SHA256]::
                            HashData(
                                [Text.Encoding]::UTF8.
                                    GetBytes($body))).
                        ToLowerInvariant()
                constructIdentity =
                    $finding.binding.
                        constructIdentity
                constructRef =
                    'construct:' + ('a' * 64)
                semanticKey =
                    'v1:sha256:' + ('b' * 64)
                ruleId = $finding.ruleId
                path = $finding.anchor.path
                line = $finding.anchor.line
                symbol = $finding.anchor.symbol
            }
            event = [ordered]@{
                eventId = 'c' * 32
                runId = 'd' * 32
                stateIdentity = 'e' * 64
                threadId = 100
                commentId = 101
            }
        }
        $thread = [ordered]@{
            threadId = 100
            status = 'active'
            isDeleted = $false
            isOutdated = $false
            sourceCommit = $head.sourceCommit
            contextState = 'current'
            anchor = [ordered]@{
                path = $finding.anchor.path
                line = $finding.anchor.line
            }
            comments = @([ordered]@{
                    commentId = 101
                    commentType = 'text'
                    isDeleted = $false
                    reviewerOwned = $true
                    reviewerIdentityState =
                        'matched'
                    body = $body
                })
        }
        $snapshot =
            [DevPilot.OwnerAdapters.OwnerDiscussionSnapshot]::new(
                'complete',
                'unknown',
                1,
                1,
                1,
                0,
                'v1:sha256:' + ('f' * 64),
                [string[]]@(
                    'v1:sha256:' + ('0' * 64)),
                [object[]]@($thread))
        $snapshot |
            Add-Member -NotePropertyName `
                RawProvenanceDigests `
                -NotePropertyValue ([string[]]@(
                    'v1:sha256:' + ('1' * 64)))
        $snapshot |
            Add-Member -NotePropertyName `
                MappingDigest `
                -NotePropertyValue (
                    $config.discussionProvider.
                        mappingDigest)
        $snapshot |
            Add-Member -NotePropertyName `
                ReviewerIdentityDigest `
                -NotePropertyValue (
                    $config.discussionProvider.
                        reviewerIdentity.digest)
        $snapshot |
            Add-Member -NotePropertyName `
                CurrentIterationId `
                -NotePropertyValue 3
        return [pscustomobject]@{
            Config = $config
            Contract = $contract
            Observation = $observation
            Proof = $proof
            Snapshot = $snapshot
            Thread = $thread
            Head = $head
        }
    }
}

Describe 'Contextual convention current PR bridge' {
    It 'recognizes an exact signed prior reviewer comment across an upgrade and on restart' {
        $case =
            New-ContextualUpgradeRecognitionCase
        $first =
            Resolve-OwnerV2DiscussionReconciliation `
                -Observation (
                    $case.Observation |
                        ConvertTo-Json -Depth 32 |
                        ConvertFrom-Json `
                            -AsHashtable -Depth 32) `
                -Contract $case.Contract `
                -Snapshot $case.Snapshot `
                -AuthenticatedPriorComments @(
                    $case.Proof)
        $second =
            Resolve-OwnerV2DiscussionReconciliation `
                -Observation (
                    $case.Observation |
                        ConvertTo-Json -Depth 32 |
                        ConvertFrom-Json `
                            -AsHashtable -Depth 32) `
                -Contract $case.Contract `
                -Snapshot $case.Snapshot `
                -AuthenticatedPriorComments @(
                    $case.Proof)

        foreach ($result in @($first, $second)) {
            $result.findings[0].
                reconciliation.classification |
                Should -BeExactly noOp
            $result.findings[0].
                reconciliation.reason |
                Should -BeExactly `
                    authenticated-prior-reviewer-comment
            $result.effects.dedupe.noOp |
                Should -Be 1
            $result.effects.dedupe.unknown |
                Should -Be 0
            $result.findings[0].
                providerMarker.integrity |
                Should -BeExactly verified
            $result.findingsComplete |
                Should -BeTrue
        }
    }

    It 'keeps unsafe prior-review variants unknown for <Mode>' -TestCases @(
        @{ Mode = 'copied' }
        @{ Mode = 'edited' }
        @{ Mode = 'foreign-identity' }
        @{ Mode = 'ambiguous' }
        @{ Mode = 'current-marker-conflict' }
        @{ Mode = 'cross-rule-conflict' }
        @{ Mode = 'ambiguous-identity-conflict' }
        @{ Mode = 'semantic-changed' }
        @{ Mode = 'head-changed' }
        @{ Mode = 'moved' }
        @{ Mode = 'deleted' }
    ) {
        param($Mode)
        $case =
            New-ContextualUpgradeRecognitionCase
        $proofs = @($case.Proof)
        switch ($Mode) {
            copied {
                $case.Thread.comments[0].
                    reviewerOwned = $false
                $case.Thread.comments[0].
                    reviewerIdentityState =
                    'foreign'
            }
            edited {
                $case.Thread.comments[0].body +=
                    ' edited'
            }
            foreign-identity {
                $case.Proof.
                    reviewerIdentityDigest =
                    'v1:sha256:' + ('9' * 64)
            }
            ambiguous {
                $duplicateProof =
                    $case.Proof |
                    ConvertTo-Json -Depth 8 |
                    ConvertFrom-Json `
                        -AsHashtable -Depth 8
                $proofs =
                    @($case.Proof, $duplicateProof)
            }
            current-marker-conflict {
                $currentMarker = & (
                    Get-Module `
                        DevPilot.OwnerCapability) {
                    param($Contract, $Finding)
                    Get-ContextualConventionMarkerKey `
                        -Contract $Contract `
                        -Finding $Finding
                } $case.Contract `
                    $case.Observation.findings[0]
                $case.Thread.comments +=
                    [ordered]@{
                        commentId = 104
                        commentType = 'text'
                        isDeleted = $false
                        reviewerOwned = $true
                        reviewerIdentityState =
                            'matched'
                        body = (
                            'Current marker conflict.' +
                            "`n`n<!-- " +
                            'devpilot-contextual-convention:v1:' +
                            "$currentMarker -->")
                    }
            }
            cross-rule-conflict {
                $case.Thread.comments +=
                    [ordered]@{
                        commentId = 105
                        commentType = 'text'
                        isDeleted = $false
                        reviewerOwned = $true
                        reviewerIdentityState =
                            'matched'
                        body = (
                            'Other automated review.' +
                            "`n`n<!-- " +
                            'devpilot-other-rule:v1:' +
                            "$('8' * 64) -->")
                    }
            }
            ambiguous-identity-conflict {
                $case.Thread.comments +=
                    [ordered]@{
                        commentId = 106
                        commentType = 'text'
                        isDeleted = $false
                        reviewerOwned = $false
                        reviewerIdentityState =
                            'ambiguous'
                        body =
                            'Ambiguous current review.'
                    }
            }
            semantic-changed {
                $case.Proof.selection.
                    constructIdentity =
                    'v1:sha256:' + ('8' * 64)
            }
            head-changed {
                $case.Proof.subject.
                    sourceCommit = '9' * 40
            }
            moved {
                $case.Thread.anchor.line = 33
            }
            deleted {
                $case.Thread.isDeleted = $true
            }
        }
        $result =
            Resolve-OwnerV2DiscussionReconciliation `
                -Observation $case.Observation `
                -Contract $case.Contract `
                -Snapshot $case.Snapshot `
                -AuthenticatedPriorComments $proofs

        $result.findings[0].
            reconciliation.classification |
            Should -BeExactly unknown
        $result.findingsComplete |
            Should -BeFalse
    }

    It 'treats the existing ranged duplicate-constant human review as coverage' {
        $case =
            New-ContextualUpgradeRecognitionCase
        $finding =
            $case.Observation.findings[0]
        $finding.ruleId =
            'duplicate-constant-declarations'
        $finding.anchor.line = 16
        $finding.binding['span'] =
            [ordered]@{
                startLine = 16
                endLine = 45
            }
        $finding.binding.span.startLine = 16
        $finding.binding.span.endLine = 45
        $case.Thread.anchor.line = 24
        $case.Thread.comments[0].body =
            'Duplicated constants http, https, Authorization, x-adc-api-version, possibly more. Reconcile to one common declaration.'
        $case.Thread.comments[0].
            reviewerOwned = $false
        $case.Thread.comments[0].
            reviewerIdentityState = 'foreign'

        $result =
            Resolve-OwnerV2DiscussionReconciliation `
                -Observation $case.Observation `
                -Contract $case.Contract `
                -Snapshot $case.Snapshot

        $result.findings[0].
            reconciliation.classification |
            Should -BeExactly humanCovered
        $result.findings[0].
            reconciliation.reason |
            Should -BeExactly `
                current-human-review-at-anchor
        $result.effects.dedupe.humanCovered |
            Should -Be 1
        $result.effects.dedupe.wouldCreate |
            Should -Be 0
    }

    It 'excludes generated C# from the contextual line denominator' {
        $changes = [ordered]@{
            changedFiles = 2
            changedLines = 1
            entries = @(
                [ordered]@{
                    path = 'src/Auto.g.cs'
                    state = 'complete'
                    spans = @([ordered]@{
                            startLine = 1
                            endLine = 6000
                        })
                },
                [ordered]@{
                    path = 'src/Real.cs'
                    state = 'complete'
                    spans = @([ordered]@{
                            startLine = 1
                            endLine = 1
                        })
                })
        }
        $result = & (
            Get-Module DevPilot.ContextualConventionsBridge) {
            param($Changes)
            Get-ContextualBridgeRelevantChangeSet `
                -ChangeSet $Changes
        } $changes
        $result.changedFiles | Should -Be 1
        $result.changedLines | Should -Be 1
        @($result.entries.path) |
            Should -Be @('src/Real.cs')
    }

    It 'is default-off with no reads or durable state' {
        $config = New-ContextualTestConfig
        $reads =
            [Collections.Generic.List[string]]::new()
        $provider = {
            param($Operation, $Arguments)
            [void]$reads.Add($Operation)
            throw 'provider should not be read'
        }.GetNewClosure()
        $state = Join-Path $TestDrive `
            'contextual-disabled-state'
        $manifest = Join-Path $TestDrive `
            'contextual-disabled-manifest.json'

        $result =
            Invoke-ContextualConventionsCurrentPrBridge `
                -Config $config -Provider $provider `
                -StateRoot $state `
                -ManifestPath $manifest `
                -RepositoryRoot $repoRoot

        $result.state | Should -BeExactly disabled
        $reads.Count | Should -Be 0
        Test-Path -LiteralPath $state |
            Should -BeFalse
    }

    It 'consumes the prepared shared snapshot and writes one model-free finding' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared = New-ContextualPreparedIntake
        $provider = {
            param($Operation, $Arguments)
            if ($Operation -ceq 'Head') {
                return [ordered]@{} +
                    $prepared.Head
            }
            throw "unexpected:$Operation"
        }.GetNewClosure()
        $state = Join-Path $TestDrive `
            'contextual-active-state'
        $manifest = Join-Path $TestDrive `
            'contextual-active-manifest.json'

        $result =
            Invoke-ContextualConventionsCurrentPrBridge `
                -Config $config -Provider $provider `
                -StateRoot $state `
                -ManifestPath $manifest `
                -RepositoryRoot $repoRoot `
                -PreparedIntake $prepared.Intake -Run

        $result.state | Should -BeExactly completed `
            -Because (
                $result.outcomes |
                    ConvertTo-Json -Depth 16 -Compress)
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
        @($result.records) | Should -HaveCount 1
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64
        $observation.capability |
            Should -BeExactly `
                bpm-contextual-conventions@1
        $observation.execution.modelStarts |
            Should -Be 0
        @($observation.findings) |
            Should -HaveCount 1
        $observation.findings[0].ruleId |
            Should -BeExactly exception-logging
        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly wouldCreate
        $observation.findings[0].
            providerMarker.integrity |
            Should -BeExactly verified
        @($observation.sourceArtifacts.kind) |
            Should -Contain `
                owner-v2-discussion-snapshot
    }

    It 'withholds a changed head without provider writes' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared = New-ContextualPreparedIntake
        $provider = {
            param($Operation, $Arguments)
            if ($Operation -ceq 'Head') {
                $drifted =
                    [ordered]@{} +
                    $prepared.Head
                $drifted.sourceCommit = 'f' * 40
                return $drifted
            }
            throw "unexpected:$Operation"
        }.GetNewClosure()
        $state = Join-Path $TestDrive `
            'contextual-drift-state'
        $manifest = Join-Path $TestDrive `
            'contextual-drift-manifest.json'

        $result =
            Invoke-ContextualConventionsCurrentPrBridge `
                -Config $config -Provider $provider `
                -StateRoot $state `
                -ManifestPath $manifest `
                -RepositoryRoot $repoRoot `
                -PreparedIntake $prepared.Intake -Run

        $result.state | Should -BeExactly partial
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
        @($result.outcomes |
            Where-Object state -CEQ unknown).Count |
            Should -BeGreaterThan 0
    }
}
