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
                    'v1:sha256:9834f5ee38aefe532a9c2b5e05b90dd0f55faa8d87d743e2a650bb191c89506e'
                length = 5399
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
                    '81250040982450c3233c13954fead55c62eb7654fe85c013ca805fd6cd1a59fb'
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

    It 'recognizes only explicitly unchanged rules across an additive bundle update' {
        $case =
            New-ContextualUpgradeRecognitionCase
        $case.Proof.rule.hash =
            'v1:sha256:0f6bd9dd21df64854bba7e2ba487c2639be15fa90f068da00df20f031ef9c749'
        $case.Proof.rule.length = 3706
        $case.Proof['ruleCompatibility'] =
            [ordered]@{
                schemaVersion = 1
                kind =
                    'contextual-additive-rule-history-compatibility'
                previousRule = [ordered]@{
                    hash = $case.Proof.rule.hash
                    length = $case.Proof.rule.length
                }
                currentRule = [ordered]@{
                    hash =
                        $case.Config.
                            contextualRule.hash
                    length =
                        $case.Config.
                            contextualRule.length
                }
                unchangedRuleIds = @(
                    'explicit-string-comparison')
            }

        $result =
            Resolve-OwnerV2DiscussionReconciliation `
                -Observation $case.Observation `
                -Contract $case.Contract `
                -Snapshot $case.Snapshot `
                -AuthenticatedPriorComments @(
                    $case.Proof)

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
    }

    It 'supports exact multiple prior bundles without carrying changed rule meaning' {
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
                })
            currentRule = [ordered]@{
                hash =
                    'v1:sha256:9834f5ee38aefe532a9c2b5e05b90dd0f55faa8d87d743e2a650bb191c89506e'
                length = 5399
            }
        }
        $cases = @(
            [ordered]@{
                ruleId =
                    'explicit-string-comparison'
                prior =
                    $compatibility.
                        previousRules[0].rule
                expected = 'noOp'
            },
            [ordered]@{
                ruleId =
                    'http-client-lifetime'
                prior =
                    $compatibility.
                        previousRules[1].rule
                expected = 'noOp'
            },
            [ordered]@{
                ruleId =
                    'named-call-arguments'
                prior =
                    $compatibility.
                        previousRules[1].rule
                expected = 'unknown'
            })
        foreach ($control in $cases) {
            $case =
                New-ContextualUpgradeRecognitionCase
            $case.Observation.findings[0].
                ruleId = $control.ruleId
            $case.Proof.selection.ruleId =
                $control.ruleId
            $case.Proof.rule.hash =
                $control.prior.hash
            $case.Proof.rule.length =
                $control.prior.length
            $case.Proof['ruleCompatibility'] =
                $compatibility

            $result =
                Resolve-OwnerV2DiscussionReconciliation `
                    -Observation $case.Observation `
                    -Contract $case.Contract `
                    -Snapshot $case.Snapshot `
                    -AuthenticatedPriorComments @(
                        $case.Proof)

            $result.findings[0].
                reconciliation.classification |
                Should -BeExactly `
                    $control.expected
        }
    }

    It 'rejects every malformed sibling in schema-v2 compatibility for <Mode>' -TestCases @(
        @{ Mode = 'duplicate-prior' }
        @{ Mode = 'malformed-sibling' }
        @{ Mode = 'extra-top-key' }
        @{ Mode = 'unregistered-rule' }
    ) {
        param($Mode)
        $case =
            New-ContextualUpgradeRecognitionCase
        $case.Observation.findings[0].
            ruleId = 'http-client-lifetime'
        $case.Proof.selection.ruleId =
            'http-client-lifetime'
        $case.Proof.rule.hash =
            'v1:sha256:6a7db82e68b407af4ed19aab4517973337592e757a32d5fa7a142b63ef75d22a'
        $case.Proof.rule.length = 5205
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
                            $case.Proof.rule.hash
                        length =
                            $case.Proof.rule.length
                    }
                    unchangedRuleIds = @(
                        'http-client-lifetime')
                })
            currentRule = [ordered]@{
                hash =
                    'v1:sha256:9834f5ee38aefe532a9c2b5e05b90dd0f55faa8d87d743e2a650bb191c89506e'
                length = 5399
            }
        }
        switch ($Mode) {
            duplicate-prior {
                $compatibility.previousRules +=
                    [ordered]@{
                        rule =
                            $compatibility.
                                previousRules[1].
                                rule
                        unchangedRuleIds = @(
                            'named-call-arguments')
                    }
            }
            malformed-sibling {
                $compatibility.previousRules +=
                    'malformed'
            }
            extra-top-key {
                $compatibility['unexpected'] =
                    $true
            }
            unregistered-rule {
                $compatibility.previousRules[1].
                    unchangedRuleIds = @(
                        'not-a-registered-rule')
            }
        }
        $case.Proof['ruleCompatibility'] =
            $compatibility

        $result =
            Resolve-OwnerV2DiscussionReconciliation `
                -Observation $case.Observation `
                -Contract $case.Contract `
                -Snapshot $case.Snapshot `
                -AuthenticatedPriorComments @(
                    $case.Proof)

        $result.findings[0].
            reconciliation.classification |
            Should -BeExactly unknown
        $result.findingsComplete |
            Should -BeFalse
    }

    It 'keeps incompatible additive history unknown for <Mode>' -TestCases @(
        @{ Mode = 'changed-rule' }
        @{ Mode = 'edited-previous-bundle' }
        @{ Mode = 'edited-current-bundle' }
    ) {
        param($Mode)
        $case =
            New-ContextualUpgradeRecognitionCase
        $case.Proof.rule.hash =
            'v1:sha256:0f6bd9dd21df64854bba7e2ba487c2639be15fa90f068da00df20f031ef9c749'
        $case.Proof.rule.length = 3706
        $case.Proof['ruleCompatibility'] =
            [ordered]@{
                schemaVersion = 1
                kind =
                    'contextual-additive-rule-history-compatibility'
                previousRule = [ordered]@{
                    hash = $case.Proof.rule.hash
                    length = $case.Proof.rule.length
                }
                currentRule = [ordered]@{
                    hash =
                        $case.Config.
                            contextualRule.hash
                    length =
                        $case.Config.
                            contextualRule.length
                }
                unchangedRuleIds = @(
                    'explicit-string-comparison')
            }
        switch ($Mode) {
            changed-rule {
                $case.Proof.ruleCompatibility.
                    unchangedRuleIds =
                    @('collection-cardinality')
            }
            edited-previous-bundle {
                $case.Proof.ruleCompatibility.
                    previousRule.hash =
                    'v1:sha256:' + ('a' * 64)
            }
            edited-current-bundle {
                $case.Proof.ruleCompatibility.
                    currentRule.length++
            }
        }

        $result =
            Resolve-OwnerV2DiscussionReconciliation `
                -Observation $case.Observation `
                -Contract $case.Contract `
                -Snapshot $case.Snapshot `
                -AuthenticatedPriorComments @(
                    $case.Proof)

        $result.findings[0].
            reconciliation.classification |
            Should -BeExactly unknown
        $result.findingsComplete |
            Should -BeFalse
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
        $finding.evidence =
            'Consolidate duplicated constants ApiVersionHeaderName="x-adc-api-version", AuthorizationHeaderName="Authorization", SupportedProtocol="http", SupportedScheme="https" for shared contract adc.egress.hook/v1.'
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

    It 'withholds an unrelated human review inside a duplicate-constant range' {
        $case =
            New-ContextualUpgradeRecognitionCase
        $finding =
            $case.Observation.findings[0]
        $finding.ruleId =
            'duplicate-constant-declarations'
        $finding.anchor.line = 16
        $finding.evidence =
            'Consolidate duplicated constants ApiVersionHeaderName="x-adc-api-version", SupportedProtocol="http" for shared contract adc.egress.hook/v1.'
        $finding.binding['span'] =
            [ordered]@{
                startLine = 16
                endLine = 45
            }
        $case.Thread.anchor.line = 37
        $case.Thread.comments[0].body =
            'Typo in XML documentation summary.'
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
            Should -BeExactly unknown
        $result.findings[0].
            reconciliation.reason |
            Should -BeExactly `
                ambiguous-ranged-human-review
        $result.effects.dedupe.humanCovered |
            Should -Be 0
        $result.effects.dedupe.wouldCreate |
            Should -Be 0
    }

    It 'preserves project context and the grouped span through the capability adapter' {
        $config =
            New-ContextualTestConfig
        $candidate = @'
namespace N {
/// <summary>Wire <c>contract/v1</c>.</summary>
internal static class Candidate {
internal const string Header = "x-header";
internal const string Protocol = "http";
} }
'@
        $comparison = @'
namespace N {
/// <summary>Wire <c>contract/v1</c>.</summary>
internal static class Existing {
internal const string Header = "x-header";
internal const string Protocol = "http";
} }
'@
        $project = [ordered]@{
            state = 'complete'
            path = 'src/App.csproj'
            sourceDigest =
                'v1:sha256:' + ('1' * 64)
            content =
                '<Project><PropertyGroup><LangVersion>latest</LangVersion></PropertyGroup></Project>'
        }
        $bindingId =
            'v1:sha256:' + ('2' * 64)
        $policyPath = Join-Path $repoRoot `
            'src\DevPilot.OwnerCapability\Policy\contextual-conventions.v1.json'
        $policyText = [IO.File]::ReadAllText(
            $policyPath,
            [Text.UTF8Encoding]::new($false))
        $capabilityDigest =
            'v1:sha256:' +
            $config.capability.
                implementationSha256
        $context = [ordered]@{
            binding = [ordered]@{
                BindingId = $bindingId
            }
            evidence = [ordered]@{
                bindingId = $bindingId
                evidenceDigest =
                    'v1:sha256:' + ('3' * 64)
                evidenceUnits = @(
                    [ordered]@{
                        unitId = 'identity'
                        state = 'complete'
                        data = [ordered]@{
                            capabilityId =
                                $config.capability.id
                            capabilityDigest =
                                $capabilityDigest
                            repositoryId =
                                $config.repositoryId
                            projectId =
                                $config.projectId
                            pullRequestId = 42
                            sourceCommit = 'a' * 40
                            targetCommit = 'b' * 40
                            targetRef =
                                'refs/heads/main'
                        }
                    },
                    [ordered]@{
                        unitId = 'rule'
                        state = 'complete'
                        data = [ordered]@{
                            repositoryId =
                                $config.contextualRule.
                                    repositoryId
                            path =
                                $config.contextualRule.path
                            commit = 'c' * 40
                            section =
                                $config.contextualRule.
                                    section
                            hash =
                                $config.contextualRule.hash
                            content = $policyText
                        }
                    },
                    [ordered]@{
                        unitId = 'file:000000'
                        state = 'complete'
                        data = [ordered]@{
                            path = 'src/Candidate.cs'
                            content = $candidate
                            spans = @([ordered]@{
                                    startLine = 4
                                    endLine = 5
                                })
                            projectContext =
                                $project
                        }
                    },
                    [ordered]@{
                        unitId = 'file:000001'
                        state = 'complete'
                        data = [ordered]@{
                            path = 'src/Existing.cs'
                            content = $comparison
                            spans = @([ordered]@{
                                    startLine = 4
                                    endLine = 5
                                })
                            projectContext =
                                $project
                        }
                    })
            }
        }
        $module =
            Get-Module DevPilot.OwnerCapability
        $response = & $module {
            param($Context, $Digest)
            Invoke-ContextualConventionsCapabilityResponse `
                -Context $Context `
                -CapabilityDigest $Digest `
                -Limits (
                    New-OwnerV2CapabilityLimits)
        } $context $capabilityDigest
        $previewFindings = @(
            $response.assessments |
                ForEach-Object {
                    @($_.findings)
                } |
                Where-Object {
                    [string]$_.data.ruleId -ceq
                        'duplicate-constant-declarations'
                })
        $candidateFinding = @(
            $previewFindings |
                Where-Object {
                    [string]$_.data.anchor.path -ceq
                        'src/Candidate.cs'
                })

        $candidateFinding | Should -HaveCount 1
        $candidateFinding[0].data.anchor.line |
            Should -Be 4
        $candidateFinding[0].data.anchor.endLine |
            Should -Be 5

        $observation =
            ConvertTo-OwnerV2Observation `
                -PipelineResult ([ordered]@{
                    evidence = $context.evidence
                    validation = $response
                    preview = [ordered]@{
                        findings =
                            $previewFindings
                    }
                })
        $normalized = @(
            $observation.findings |
                Where-Object {
                    [string]$_.ruleId -ceq
                        'duplicate-constant-declarations' -and
                    [string]$_.anchor.path -ceq
                        'src/Candidate.cs'
                })

        $normalized | Should -HaveCount 1
        $normalized[0].binding.span.startLine |
            Should -Be 4
        $normalized[0].binding.span.endLine |
            Should -Be 5
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

    It 'acquires a cited unchanged constant peer as context-only evidence' {
        $config =
            New-ContextualTestConfig
        $config.enabled = $true
        $candidate = @'
namespace N {
/// <summary>Shared <c>contract/v1</c> contract.</summary>
internal static class Candidate {
internal const string Value = "wire-value";
} }
'@
        $peer = @'
namespace N {
/// <summary>Shared <c>contract/v1</c> contract.</summary>
internal static class Existing {
internal const string Value = "wire-value";
} }
'@
        $prepared =
            New-ContextualPreparedIntake `
                -Content $candidate
        $entry =
            $prepared.Intake.
                transientSnapshots['42'].
                changes.entries[0]
        $entry.path = 'src/Candidate.cs'
        $entry.spans[0].startLine = 4
        $entry.spans[0].endLine = 4
        $entry.sourceDigest =
            Get-ContextualTestTextDigest `
                $candidate
        $entry.byteLength =
            [Text.Encoding]::UTF8.
                GetByteCount($candidate)
        $projectContent =
            '<Project><PropertyGroup><LangVersion>latest</LangVersion></PropertyGroup></Project>'
        $projectContext = [ordered]@{
            state = 'complete'
            path = 'src/App.csproj'
            content = $projectContent
            byteLength =
                [Text.Encoding]::UTF8.
                    GetByteCount($projectContent)
            sourceDigest =
                Get-ContextualTestTextDigest `
                    $projectContent
        }
        $entry['projectContext'] =
            $projectContext
        $prepared.Intake.
            transientSnapshots['42'].
            discussions = [ordered]@{
                count = 1
                threads = @([ordered]@{
                        id = 100
                        status = 'active'
                        isDeleted = $false
                        threadContext = [ordered]@{
                            filePath =
                                '/src/Candidate.cs'
                            rightFileStart =
                                [ordered]@{
                                    line = 4
                                    offset = 1
                                }
                            rightFileEnd =
                                [ordered]@{
                                    line = 4
                                    offset = 10
                                }
                        }
                        pullRequestThreadContext =
                            [ordered]@{
                                changeTrackingId = 7
                                iterationContext =
                                    [ordered]@{
                                        firstComparingIteration = 3
                                        secondComparingIteration = 3
                                    }
                            }
                        comments = @([ordered]@{
                                id = 1
                                commentType = 'text'
                                content =
                                    'Duplicated constant wire-value. Reconcile to src/Existing.cs.'
                                author = [ordered]@{
                                    id =
                                        '44444444-4444-4444-4444-444444444444'
                                    descriptor =
                                        'aad.human'
                                    uniqueName =
                                        'human@example.invalid'
                                }
                            })
                    })
            }
        $peerDigest =
            Get-ContextualTestTextDigest $peer
        $providerState = [ordered]@{
            referenceCalls = 0
        }
        $provider = {
            param($Operation, $Arguments)
            if ($Operation -ceq 'Head') {
                return $prepared.Head
            }
            if ($Operation -ceq
                'ReferenceFiles') {
                $providerState.referenceCalls++
                return [ordered]@{
                    schemaVersion = 1
                    sourceCommit =
                        $prepared.Head.
                            sourceCommit
                    entries = @([ordered]@{
                            changeTrackingId =
                                2000000000
                            path =
                                'src/Existing.cs'
                            changeType = 'Edit'
                            state = 'complete'
                            spans = @()
                            unavailableReason =
                                $null
                            content = $peer
                            byteLength =
                                [Text.Encoding]::UTF8.
                                    GetByteCount(
                                        $peer)
                            sourceDigest =
                                $peerDigest
                            projectContext =
                                $projectContext
                            contextOnly = $true
                        })
                }
            }
            throw "Unexpected provider operation '$Operation'."
        }.GetNewClosure()
        $state = Join-Path $TestDrive `
            'cited-reference-state'
        $manifest = Join-Path $TestDrive `
            'cited-reference-manifest.json'

        $result =
            Invoke-ContextualConventionsCurrentPrBridge `
                -Config $config `
                -Provider $provider `
                -StateRoot $state `
                -ManifestPath $manifest `
                -RepositoryRoot $repoRoot `
                -PreparedIntake (
                    $prepared.Intake) `
                -Run
        $record = @($result.records)[0]
        $observationPath = @(
            Get-ChildItem $state -Recurse `
                -File -Filter "$($record.identity).json" |
                Where-Object {
                    $_.Directory.Name -ceq
                        'observations'
                })[0].FullName
        $observation =
            Get-Content $observationPath -Raw |
            ConvertFrom-Json `
                -AsHashtable -Depth 64
        $finding = @(
            $observation.findings |
                Where-Object {
                    [string]$_.ruleId -ceq
                        'duplicate-constant-declarations'
                })

        $providerState.referenceCalls |
            Should -Be 1
        $finding | Should -HaveCount 1
        $finding[0].binding.span.startLine |
            Should -Be 4
        $finding[0].reconciliation.
            classification |
            Should -BeExactly humanCovered
        $result.providerWrites |
            Should -Be 0
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
