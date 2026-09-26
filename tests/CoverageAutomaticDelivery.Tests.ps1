#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:coverageTestRoot = Join-Path $repoRoot (
        '.coverage-delivery-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:coverageTestRoot | Out-Null
    Import-Module (Join-Path $repoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    Import-Module (Join-Path $repoRoot 'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') -Force
    Import-Module (Join-Path $repoRoot 'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1') -Force
    . (Join-Path $repoRoot 'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')
    . (Join-Path $repoRoot 'src\Agents\reviewer\AutomaticOwnerV2Comments.ps1')

    function New-CoverageDeliveryContext {
        param([ValidateRange(1, 9)][int]$Count = 1)
        $id = 'a' * 64
        $declaration = [ordered]@{
            mode = 'live'
            subject = [ordered]@{
                projectId = '22222222-2222-2222-2222-222222222222'
                repositoryId = '11111111-1111-1111-1111-111111111111'
                pullRequestId = 42
            }
            head = [ordered]@{ sourceCommit = 'a' * 40 }
            target = [ordered]@{
                targetCommit = 'b' * 40
                targetRef = 'refs/heads/main'
            }
            rule = [ordered]@{
                repositoryId = '33333333-3333-3333-3333-333333333333'
                path = 'src/DevPilot.OwnerCapability/Policy/test-class-coverage.v1.txt'
                commit = 'c' * 40
                section = 'bpm-test-class-coverage@1'
                hash = 'v1:sha256:' + ('d' * 64)
                length = 100
            }
            capability = [ordered]@{
                id = 'bpm-test-class-coverage@1'
                digest = 'v1:sha256:' + ('e' * 64)
            }
            model = [ordered]@{
                id = 'none'
                digest = 'v1:sha256:' + ('f' * 64)
            }
            config = [ordered]@{
                id = 'coverage-v1-user-approved'
                digest = 'v1:sha256:' + ('1' * 64)
            }
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
        $findings = [Collections.Generic.List[object]]::new()
        for ($i = 1; $i -le $Count; $i++) {
            $symbol = "MissingTests$i"
            $finding = [ordered]@{
                identity = 'coverage-v2:' + $i.ToString('x').PadLeft(64, '0')
                semanticKey = 'v1:sha256:' + ('4' * 64)
                disposition = 'violation'
                constructRef = 'construct:' + $i.ToString('x').PadLeft(64, '0')
                anchor = [ordered]@{
                    path = "tests/$symbol.cs"
                    line = 25
                    symbol = $symbol
                }
                binding = [ordered]@{
                    constructIdentity = 'v1:sha256:' + ('7' * 64)
                    source = [ordered]@{
                        representation = [ordered]@{
                            path = "tests/$symbol.cs"
                            startLine = 25
                            endLine = 25
                            symbol = $symbol
                            constructIdentity = 'construct:' + $i.ToString('x').PadLeft(64, '0')
                        }
                    }
                }
            }
            $marker = Get-TestClassCoverageMarkerKey `
                -Contract $contract -Finding $finding
            $body = Format-TestClassCoverageComment `
                -Contract $contract -Finding $finding -MarkerKey $marker
            $finding['providerMarker'] = [ordered]@{
                integrity = 'verified'
                sha256 = Get-ApprovedOwnerV2TextSha256 $marker
            }
            $finding['reconciliation'] = [ordered]@{
                classification = 'wouldCreate'
                reason = 'reviewer-marker-not-found'
                bodySha256 = Get-ApprovedOwnerV2TextSha256 $body
            }
            [void]$findings.Add($finding)
        }
        $observation = [ordered]@{
            capability = 'bpm-test-class-coverage@1'
            rule = [ordered]@{
                section = $declaration.rule.section
                path = $declaration.rule.path
            }
            lifecycle = [ordered]@{ status = 'completed' }
            findingsComplete = $true
            counts = [ordered]@{
                violations = $Count
                unknown = 0
                uncovered = 0
            }
            execution = [ordered]@{ modelStarts = 0 }
            findings = $findings.ToArray()
            effects = [ordered]@{
                dedupe = [ordered]@{}
                providerWrites = 0
                writeToolInvocations = 0
            }
            sourceArtifacts = @([ordered]@{
                    kind = 'owner-v2-discussion-snapshot'
                    sha256 = '9' * 64
                })
        }
        $root = Join-Path $script:coverageTestRoot ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $paths = [ordered]@{}
        foreach ($name in @(
                'declaration', 'evidence', 'record', 'observation'
            )) {
            $path = Join-Path $root "$name.json"
            [IO.File]::WriteAllText($path, '{}')
            $paths[$name] = $path
        }
        $paths.telemetry = Join-Path $root 'telemetry.json'
        $evidence = [pscustomobject]@{
            Identity = $id
            Declaration = $declaration
            Observation = $observation
            Contract = $contract
            Record = [ordered]@{
                kind = 'owner-v2-preview-record'
                schemaVersion = 2
                mode = 'live'
                state = 'completed'
                modelExecutionState = 'notAttempted'
                resultDigest = Get-ApprovedOwnerV2Digest $observation
            }
            Paths = $paths
            Toolkit = [ordered]@{
                head = 'd' * 40
                tree = 'e' * 40
                formatterSha256 = '2' * 64
                formatterManifestSha256 = '3' * 64
                writerSha256 = '3' * 64
                providerSha256 = '4' * 64
                automaticWriterSha256 = '6' * 64
                schedulerSha256 = '7' * 64
            }
            Provider = [ordered]@{
                kind = 'azure-devops-rest-owner-discussions-v1'
                organization = 'https://dev.azure.com/example'
                projectName = 'Example'
                repositoryId = $declaration.subject.repositoryId
                projectId = $declaration.subject.projectId
                mappingDigest = 'v1:sha256:' + ('a' * 64)
                reviewerIdentity = [ordered]@{
                    id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                    descriptor = 'aad.test-descriptor'
                    uniqueName = 'operator@example.com'
                    digest = 'v1:sha256:' + ('b' * 64)
                }
            }
        }
        $deliveryRoot = Join-Path $root 'delivery'
        foreach ($leaf in @('intents', 'outcomes', 'events', 'locks')) {
            New-Item -ItemType Directory `
                -Path (Join-Path $deliveryRoot $leaf) -Force | Out-Null
        }
        $policy = New-AutomaticOwnerV2ServicePolicy -Evidence $evidence `
            -PolicyId coverage-v2-production
        return [pscustomobject]@{
            Evidence = $evidence
            Policy = $policy
            Root = $deliveryRoot
            Key = [byte[]](1..32)
        }
    }

    function New-CoverageDeliveryProvider {
        param(
            [Parameter(Mandatory)]$Evidence,
            [switch]$ForeignReviewer,
            [switch]$StaleAnchor,
            [switch]$StaleHead,
            [switch]$Unconfirmed
        )
        $state = [ordered]@{
            threads = @()
            digest = '9' * 64
            writes = 0
            operations = [Collections.Generic.List[string]]::new()
        }
        $handler = {
            param([string]$Action, [hashtable]$Arguments)
            [void]$state.operations.Add($Action)
            if ($Action -ceq 'CreateThread') {
                $state.writes++
                if (-not $Unconfirmed) {
                    $selection = $Arguments.selection
                    $state.threads += [ordered]@{
                        threadId = 100 + $state.writes
                        status = 'active'
                        isDeleted = $false
                        isOutdated = $false
                        sourceCommit = $Evidence.Declaration.head.sourceCommit
                        contextState = 'current'
                        anchor = [ordered]@{
                            path = [string]$selection.path
                            line = [int]$selection.line
                        }
                        comments = @([ordered]@{
                                commentId = 1100 + $state.writes
                                commentType = 'text'
                                isDeleted = $false
                                reviewerOwned = $true
                                reviewerIdentityState = 'matched'
                                body = [string]$selection.body
                                bodyDigest = 'v1:sha256:' + ('f' * 64)
                            })
                    }
                    $state.digest = $state.writes.ToString('x').PadLeft(64, '8')
                }
                return [ordered]@{ id = 100 + $state.writes }
            }
            if ($Action -cne 'ReadCurrent') {
                throw "Unexpected provider operation '$Action'."
            }
            $snapshot = [DevPilot.OwnerAdapters.OwnerDiscussionSnapshot]::new(
                'complete', 'unknown', 1, @($state.threads).Count,
                @($state.threads).Count, 0, "v1:sha256:$($state.digest)",
                [string[]]@('v1:sha256:' + ('f' * 64)),
                [object[]]@($state.threads))
            $snapshot | Add-Member -NotePropertyName CurrentIterationId `
                -NotePropertyValue 2
            $snapshot | Add-Member -NotePropertyName RawProvenanceDigests `
                -NotePropertyValue ([string[]]@('v1:sha256:' + ('c' * 64)))
            $snapshot | Add-Member -NotePropertyName MappingDigest `
                -NotePropertyValue ('v1:sha256:' + ('a' * 64))
            $snapshot | Add-Member -NotePropertyName ReviewerIdentityDigest `
                -NotePropertyValue ('v1:sha256:' + ('b' * 64))
            return [pscustomobject]@{
                ProviderBinding = $Evidence.Provider
                PullRequest = [ordered]@{
                    pullRequestId = 42
                    status = 'active'
                    isDraft = $false
                    repositoryId = $Evidence.Declaration.subject.repositoryId
                    projectId = $Evidence.Declaration.subject.projectId
                    sourceCommit = $(if ($StaleHead) { 'e' * 40 } else {
                            $Evidence.Declaration.head.sourceCommit
                        })
                    targetCommit = $Evidence.Declaration.target.targetCommit
                    targetRef = $Evidence.Declaration.target.targetRef
                }
                Reviewer = [ordered]@{
                    id = $(if ($ForeignReviewer) { 'foreign' } else {
                            $Evidence.Provider.reviewerIdentity.id
                        })
                    descriptor = $Evidence.Provider.reviewerIdentity.descriptor
                    uniqueName = $Evidence.Provider.reviewerIdentity.uniqueName
                }
                Snapshot = $snapshot
                Anchors = @($Arguments.selections | ForEach-Object {
                        [ordered]@{
                            path = $_.path
                            startLine = $(if ($StaleAnchor) { 26 } else { 25 })
                            endLine = $(if ($StaleAnchor) { 26 } else { 25 })
                            changeTrackingId = 7
                            iterationId = 2
                        }
                    })
            }
        }.GetNewClosure()
        return [pscustomobject]@{ Handler = $handler; State = $state }
    }

    function Update-CoverageDeliveryObservation {
        param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Provider)
        $live = & $Provider.Handler 'ReadCurrent' @{
            evidence = $Context.Evidence
            selections = @()
        }
        $resolved = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $Context.Evidence.Observation `
            -Contract $Context.Evidence.Contract -Snapshot $live.Snapshot
        $Context.Evidence.Observation.findings = @($resolved.findings)
        $Context.Evidence.Observation.sourceArtifacts[0].sha256 =
            ([string]$live.Snapshot.Digest).Substring(10)
        $Context.Evidence.Record.resultDigest =
            Get-ApprovedOwnerV2Digest $Context.Evidence.Observation
    }

    function Write-CoverageDeliveryState {
        param([Parameter(Mandatory)]$Context)
        $e = $Context.Evidence
        $identity = New-OwnerAzureDevOpsReviewerIdentity `
            -Id $e.Provider.reviewerIdentity.id `
            -Descriptor $e.Provider.reviewerIdentity.descriptor `
            -UniqueName $e.Provider.reviewerIdentity.uniqueName
        $adapter = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
            -Name 'coverage-test-config' -ReviewerIdentity $identity `
            -Handler { throw 'not invoked' }
        $declaration = $e.Declaration
        $declaration['kind'] = 'owner-v2-preview-declaration'
        $declaration['mode'] = 'live'
        $declaration['stateDigest'] = "v1:sha256:$($e.Identity)"
        $declaration['acquisitionPayloadDigest'] = 'v1:sha256:' + ('2' * 64)
        $declaration['facadeBinding'] = [ordered]@{
            bindingId = $e.Contract.Binding.BindingId
            subjectKey = $e.Contract.Binding.SubjectKey
            headKey = $e.Contract.Binding.HeadKey
            ruleKey = $e.Contract.Binding.RuleKey
            capabilityKey = $e.Contract.Binding.CapabilityKey
        }
        $observation = $e.Observation
        $observation['schemaVersion'] = 2
        $observation['kind'] = 'owner-observation'
        $observation['findingsComplete'] = $true
        $observation['execution'] = [ordered]@{ modelStarts = 0 }
        $observation.counts['uncovered'] = 0
        $observation['subject'] = [ordered]@{
            pullRequestId = $declaration.subject.pullRequestId
            repositoryId = $declaration.subject.repositoryId
            headCommit = $declaration.head.sourceCommit
            targetCommit = $declaration.target.targetCommit
            targetRef = $declaration.target.targetRef
        }
        $observation['rule'] = [ordered]@{
            commit = $declaration.rule.commit
            sha256 = $declaration.rule.hash.Substring(10)
            section = $declaration.rule.section
            path = $declaration.rule.path
        }
        $record = [ordered]@{
            schemaVersion = 2
            kind = 'owner-v2-preview-record'
            identity = $e.Identity
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
            attempts = 1
            maxAttempts = 3
            lease = $null
            createdUtc = 'utc:2026-01-01T00:00:00Z'
            updatedUtc = 'utc:2026-01-01T00:00:00Z'
            declarationPath = "declarations/$($e.Identity).json"
            evidencePath = "evidence/$($e.Identity).json"
            observationPath = "observations/$($e.Identity).json"
            resultDigest = Get-ApprovedOwnerV2Digest $observation
            incompleteReason = 'unknown'
            modelExecutionState = 'notAttempted'
        }
        $pin = [ordered]@{
            kind = 'owner-v2-preview-live-evidence-pin'
            acquisitionPayloadDigest = $declaration.acquisitionPayloadDigest
        }
        $stateRoot = Join-Path $script:coverageTestRoot ([guid]::NewGuid().ToString('N'))
        $root = Get-ApprovedOwnerV2CapabilityRoot -StateRoot $stateRoot `
            -CapabilityId $declaration.capability.id `
            -CapabilityDigest $declaration.capability.digest
        foreach ($item in @(
                @{ Name = 'declarations'; Value = $declaration },
                @{ Name = 'evidence'; Value = $pin },
                @{ Name = 'records'; Value = $record },
                @{ Name = 'observations'; Value = $observation },
                @{ Name = 'telemetry'; Value = $null }
            )) {
            $folder = Join-Path $root $item.Name
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            if ($null -ne $item.Value) {
                $path = Join-Path $folder "$($e.Identity).json"
                [IO.File]::WriteAllText($path,
                    (ConvertTo-ApprovedOwnerV2CanonicalJson $item.Value))
            }
        }
        $config = [ordered]@{
            capability = [ordered]@{
                id = $declaration.capability.id
                implementationSha256 = $declaration.capability.digest.Substring(10)
            }
            toolkit = [ordered]@{
                head = $e.Toolkit.head
                tree = $e.Toolkit.tree
                ref = 'refs/heads/main'
            }
            subjectProvider = [ordered]@{
                kind = 'azure-devops-read-only-v1'
                organization = $e.Provider.organization
                projectName = $e.Provider.projectName
                projectId = $e.Provider.projectId
                repositoryId = $e.Provider.repositoryId
            }
            discussionProvider = [ordered]@{
                kind = $e.Provider.kind
                mappingDigest = $adapter.AzureDevOpsDiscussionMappingDigest
                reviewerIdentity = [ordered]@{
                    id = $identity.Id
                    descriptor = $identity.Descriptor
                    uniqueName = $identity.UniqueName
                    digest = $adapter.AzureDevOpsReviewerIdentityDigest
                }
            }
        }
        $configPath = Join-Path $stateRoot 'coverage-config.json'
        [IO.File]::WriteAllText($configPath,
            (ConvertTo-ApprovedOwnerV2CanonicalJson $config))
        return [pscustomobject]@{
            StateRoot = $stateRoot
            ConfigPath = $configPath
        }
    }
}

Describe 'Independent automatic class coverage delivery' {
    It 'gates coverage cohorts on explicit independent config before preparing state' {
        $root = Join-Path $script:coverageTestRoot ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $state = Join-Path $root 'state'
        $delivery = Join-Path $root 'delivery'
        $manifestPath = Join-Path $root 'cohort.json'
        $configPath = Join-Path $root 'config.json'
        $tool = Join-Path $repoRoot 'tools\Invoke-OwnerV2ScheduledDelivery.ps1'
        [IO.File]::WriteAllText($manifestPath,
            '{"kind":"coverage-v2-preview-cohort"}')

        foreach ($case in @(
                @{ Config = '{"autoCreateOwnerComments":false}';
                    Error = 'requires an explicit autoCreateCoverageComments' },
                @{ Config = '{"autoCreateCoverageComments":true}';
                    Error = 'requires an exact signed policy binding' }
            )) {
            [IO.File]::WriteAllText($configPath, $case.Config)
            $output = @(& (Get-Command pwsh).Source -NoProfile `
                    -File $tool -StateRoot $state `
                    -ManifestPath $manifestPath `
                    -ToolkitConfigPath $configPath `
                    -DeliveryRoot $delivery -RepoRoot $repoRoot 2>&1)
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -Match $case.Error
            Test-Path -LiteralPath $state | Should -BeFalse
            Test-Path -LiteralPath $delivery | Should -BeFalse
        }

        [IO.File]::WriteAllText($configPath,
            '{"autoCreateCoverageComments":false}')
        $output = @(& (Get-Command pwsh).Source -NoProfile `
                -File $tool -StateRoot $state `
                -ManifestPath $manifestPath `
                -ToolkitConfigPath $configPath `
                -DeliveryRoot $delivery -RepoRoot $repoRoot 2>&1)
        $LASTEXITCODE | Should -Not -Be 0
        ($output -join "`n") | Should -Not -Match `
            'requires an explicit autoCreateCoverageComments|requires an exact signed policy binding'
        Test-Path -LiteralPath $delivery | Should -BeFalse
    }

    It 'authorizes a separate signed coverage policy with no external writes' {
        $context = New-CoverageDeliveryContext
        $state = Write-CoverageDeliveryState -Context $context
        $deliveryRoot = Join-Path $script:coverageTestRoot ([guid]::NewGuid().ToString('N'))
        $testBoundary = Join-Path $script:coverageTestRoot (
            'trusted-boundary-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testBoundary | Out-Null
        $service = Initialize-AutomaticOwnerV2DeliveryRoot `
            -DeliveryRoot $deliveryRoot -RepoRoot $testBoundary
        $evidence = Read-AutomaticCoverageEvidence `
            -StateRoot $state.StateRoot -Identity $context.Evidence.Identity `
            -ToolkitConfigPath $state.ConfigPath -RepoRoot $repoRoot
        $policy = New-AutomaticOwnerV2ServicePolicy `
            -Evidence $evidence -PolicyId coverage-v2-production
        $policyPath = Join-Path $service.Root `
            'policies\coverage-v2-production.json'
        [void](Write-ApprovedOwnerV2SignedRecord `
                -Path $policyPath -Payload $policy `
                -Key (Get-AutomaticOwnerV2ServiceKey -DeliveryRoot $service.Root))
        $signed = Read-ApprovedOwnerV2SignedRecord `
            -Path $policyPath `
            -Key (Get-AutomaticOwnerV2ServiceKey -DeliveryRoot $deliveryRoot)
        $signed.kind | Should -BeExactly coverage-v2-service-authorization-policy
        $signed.repository.organization | Should -BeExactly `
            'https://dev.azure.com/example'
        $signed.authority.construct | Should -BeExactly changed-mstest-class
    }

    It 'reads only a completed live no-model coverage state with exact config' {
        $context = New-CoverageDeliveryContext
        $state = Write-CoverageDeliveryState -Context $context
        $loaded = Read-ApprovedOwnerV2Evidence `
            -StateRoot $state.StateRoot -Identity $context.Evidence.Identity `
            -RepoRoot $repoRoot -ToolkitConfigPath $state.ConfigPath `
            -Delivery coverage
        $loaded.Observation.capability | Should -BeExactly bpm-test-class-coverage@1
        $loaded.Telemetry | Should -BeNullOrEmpty
        $loaded.Toolkit.automaticWriterSha256 | Should -Match '^[0-9a-f]{64}$'
        $proposal = Get-ApprovedOwnerV2Proposal -Evidence $loaded `
            -Finding $loaded.Observation.findings[0] -Delivery coverage
        $proposal.symbol | Should -BeExactly MissingTests1
        $proposal.markerComment | Should -Match 'devpilot-test-class-coverage:v1'
        { New-ApprovedOwnerV2ReviewPackage -Evidence $loaded } |
            Should -Throw '*does not authorize coverage*'
        $recordPath = Join-Path $loaded.CapabilityRoot `
            "records\$($loaded.Identity).json"
        $record = Read-ApprovedOwnerV2Json $recordPath
        $record.modelExecutionState = 'attempted'
        [IO.File]::WriteAllText($recordPath,
            (ConvertTo-ApprovedOwnerV2CanonicalJson $record))
        {
            Read-ApprovedOwnerV2Evidence `
                -StateRoot $state.StateRoot -Identity $context.Evidence.Identity `
                -RepoRoot $repoRoot -ToolkitConfigPath $state.ConfigPath `
                -Delivery coverage
        } | Should -Throw '*model execution state*'
    }

    It 'preserves class capability identity in both live reconciliation preflights' {
        $context = New-CoverageDeliveryContext
        $proposal = (New-AutomaticCoverageReviewPackage `
                -Evidence $context.Evidence).proposals[0]
        $provider = New-CoverageDeliveryProvider -Evidence $context.Evidence
        $live = & $provider.Handler 'ReadCurrent' @{
            evidence = $context.Evidence
            selections = @($proposal)
        }
        $authorization = [ordered]@{
            subject = [ordered]@{
                projectId = $context.Evidence.Declaration.subject.projectId
                repositoryId = $context.Evidence.Declaration.subject.repositoryId
                pullRequestId = $context.Evidence.Declaration.subject.pullRequestId
                sourceCommit = $context.Evidence.Declaration.head.sourceCommit
                targetCommit = $context.Evidence.Declaration.target.targetCommit
                targetRef = $context.Evidence.Declaration.target.targetRef
            }
            provider = $context.Evidence.Provider
            operator = [ordered]@{
                id = $context.Evidence.Provider.reviewerIdentity.id
                descriptor = $context.Evidence.Provider.reviewerIdentity.descriptor
                uniqueName = $context.Evidence.Provider.reviewerIdentity.uniqueName
            }
        }
        $shared = Assert-ApprovedOwnerV2LiveRead `
            -Evidence $context.Evidence -Approval $authorization `
            -Live $live -Selections @($proposal) `
            -ExpectedSnapshotSha256 ('9' * 64)
        $automatic = Assert-AutomaticOwnerV2LiveRead `
            -Evidence $context.Evidence -Approval $authorization `
            -Live $live -Selections @($proposal) `
            -ExpectedSnapshotSha256 ('9' * 64)
        $shared.Classifications[$proposal.findingId] |
            Should -BeExactly wouldCreate
        $automatic.Classifications[$proposal.findingId] |
            Should -BeExactly wouldCreate
        $provider.State.writes | Should -Be 0
    }

    It 'refuses an incomplete coverage record or non-model-free observation at proposal and delivery' `
        -TestCases @(
            @{ Invalid = 'record-state' }
            @{ Invalid = 'observation-status' }
            @{ Invalid = 'model-state' }
            @{ Invalid = 'model-starts' }
            @{ Invalid = 'unknown-count' }
            @{ Invalid = 'incomplete-findings' }
        ) {
        param($Invalid)
        $context = New-CoverageDeliveryContext
        switch ($Invalid) {
            record-state { $context.Evidence.Record.state = 'pending' }
            observation-status {
                $context.Evidence.Observation.lifecycle.status = 'partial'
            }
            model-state {
                $context.Evidence.Record.modelExecutionState = 'attempted'
            }
            model-starts {
                $context.Evidence.Observation.execution.modelStarts = 1
            }
            unknown-count {
                $context.Evidence.Observation.counts.unknown = 1
            }
            incomplete-findings {
                $context.Evidence.Observation.findingsComplete = $false
            }
        }
        $context.Evidence.Record.resultDigest =
            Get-ApprovedOwnerV2Digest $context.Evidence.Observation
        {
            Get-ApprovedOwnerV2Proposal -Evidence $context.Evidence `
                -Finding $context.Evidence.Observation.findings[0] `
                -Delivery coverage
        } | Should -Throw '*coverage*'
        $provider = New-CoverageDeliveryProvider -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly refused
        $provider.State.writes | Should -Be 0
        $result.events.Count | Should -Be 0
    }

    It 'refuses an incomplete zero-finding coverage batch before any delivery read' {
        $context = New-CoverageDeliveryContext
        $context.Evidence.Observation.findings = @()
        $context.Evidence.Observation.counts.violations = 0
        $context.Evidence.Record.state = 'pending'
        $context.Evidence.Record.resultDigest =
            Get-ApprovedOwnerV2Digest $context.Evidence.Observation
        $provider = New-CoverageDeliveryProvider -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly refused
        $provider.State.operations.Count | Should -Be 0
    }

    It 'rejects model telemetry and an observation with a foreign coverage rule' {
        $context = New-CoverageDeliveryContext
        $state = Write-CoverageDeliveryState -Context $context
        $loaded = Read-ApprovedOwnerV2Evidence `
            -StateRoot $state.StateRoot -Identity $context.Evidence.Identity `
            -RepoRoot $repoRoot -ToolkitConfigPath $state.ConfigPath `
            -Delivery coverage
        [IO.File]::WriteAllText($loaded.Paths.telemetry, '{}')
        {
            Get-ApprovedOwnerV2Proposal -Evidence $loaded `
                -Finding $loaded.Observation.findings[0] `
                -Delivery coverage
        } | Should -Throw '*coverage*'
        {
            Read-ApprovedOwnerV2Evidence -StateRoot $state.StateRoot `
                -Identity $context.Evidence.Identity -RepoRoot $repoRoot `
                -ToolkitConfigPath $state.ConfigPath -Delivery coverage
        } | Should -Throw '*must not contain model telemetry*'
        Remove-Item -LiteralPath $loaded.Paths.telemetry

        $observation = Read-ApprovedOwnerV2Json $loaded.Paths.observation
        $observation.rule.section = 'bpm-test-ownership@1'
        [IO.File]::WriteAllText($loaded.Paths.observation,
            (ConvertTo-ApprovedOwnerV2CanonicalJson $observation))
        $record = Read-ApprovedOwnerV2Json $loaded.Paths.record
        $record.resultDigest = Get-ApprovedOwnerV2Digest $observation
        [IO.File]::WriteAllText($loaded.Paths.record,
            (ConvertTo-ApprovedOwnerV2CanonicalJson $record))
        {
            Read-ApprovedOwnerV2Evidence -StateRoot $state.StateRoot `
                -Identity $context.Evidence.Identity -RepoRoot $repoRoot `
                -ToolkitConfigPath $state.ConfigPath -Delivery coverage
        } | Should -Throw '*rule binding is stale*'
    }

    It 'does not allow the manual Owner signer to approve coverage selections' {
        $context = New-CoverageDeliveryContext
        $reviewPath = Join-Path $script:coverageTestRoot (
            [guid]::NewGuid().ToString('N') + '.json')
        $approvalPath = Join-Path $script:coverageTestRoot (
            [guid]::NewGuid().ToString('N') + '.json')
        $proposal = (New-AutomaticCoverageReviewPackage `
                -Evidence $context.Evidence).proposals[0]
        $review = [ordered]@{
            kind = 'owner-v2-comment-review-package'
            authorization = 'none'
            capability = $context.Evidence.Declaration.capability
        }
        [IO.File]::WriteAllText($reviewPath,
            (ConvertTo-ApprovedOwnerV2CanonicalJson $review))
        {
            Approve-OwnerV2ReviewPackage -ReviewPackagePath $reviewPath `
                -ApprovalPath $approvalPath -FindingId @($proposal.findingId) `
                -OperatorId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' `
                -OperatorDescriptor 'aad.test-descriptor' `
                -OperatorUpn 'operator@example.com' -Reason 'test' `
                -Key $context.Key
        } | Should -Throw '*Only an unsigned Owner v2 review package*'
        Test-Path -LiteralPath $approvalPath | Should -BeFalse
    }

    It 'is default-off independently of the Owner switch and refuses unbound true' {
        (Get-AutomaticOwnerV2Configuration -ToolkitConfig ([ordered]@{
                    autoCreateOwnerComments = [ordered]@{
                        enabled = $true
                        policyPath = 'C:\private\owner-policy.json'
                        policySha256 = 'a' * 64
                    }
                }) -Delivery coverage).Enabled | Should -BeFalse
        {
            Get-AutomaticOwnerV2Configuration -ToolkitConfig ([ordered]@{
                    autoCreateCoverageComments = $true
                }) -Delivery coverage
        } | Should -Throw '*signed policy*'
    }

    It 'binds separate signed coverage authority to class construct and reviewer' {
        $context = New-CoverageDeliveryContext
        $context.Policy.kind | Should -BeExactly 'coverage-v2-service-authorization-policy'
        $context.Policy.authority.construct | Should -BeExactly 'changed-mstest-class'
        { Assert-AutomaticOwnerV2ServicePolicy -Evidence $context.Evidence `
                -Policy $context.Policy } | Should -Not -Throw
        $context.Policy.reviewerIdentity.id = 'foreign'
        { Assert-AutomaticOwnerV2ServicePolicy -Evidence $context.Evidence `
                -Policy $context.Policy } | Should -Throw '*binding*'
    }

    It 'refuses foreign rule, capability, organization, repository, or Owner policy' `
        -TestCases @(
            @{ Field = 'rule'; Value = 'foreign' }
            @{ Field = 'capability'; Value = 'foreign' }
            @{ Field = 'organization'; Value = 'https://dev.azure.com/other' }
            @{ Field = 'repository'; Value = 'foreign' }
            @{ Field = 'kind'; Value = 'owner-v2-service-authorization-policy' }
        ) {
        param($Field, $Value)
        $context = New-CoverageDeliveryContext
        switch ($Field) {
            rule { $context.Policy.rule.section = $Value }
            capability { $context.Policy.capability.id = $Value }
            organization { $context.Policy.repository.organization = $Value }
            repository { $context.Policy.repository.repositoryId = $Value }
            kind { $context.Policy.kind = $Value }
        }
        $provider = New-CoverageDeliveryProvider -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly refused
        $provider.State.writes | Should -Be 0
    }

    It 'creates one class thread and persists a signed event with class identity' {
        $context = New-CoverageDeliveryContext
        $provider = New-CoverageDeliveryProvider -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly healthy
        $result.kind | Should -BeExactly coverage-v2-automatic-delivery-result
        $result.providerWrites | Should -Be 1
        $provider.State.operations | Should -Not -Contain UpdateComment
        $provider.State.operations | Should -Not -Contain UpdateStatus
        $result.events[0].kind | Should -BeExactly coverage-v2-delivery-event
        $result.events[0].ruleId | Should -BeExactly bpm-test-class-coverage@1
        $result.events[0].capabilityId | Should -BeExactly bpm-test-class-coverage@1
        $result.events[0].finding.symbol | Should -BeExactly MissingTests1
        $eventPath = Join-Path $context.Root (
            "events\$($result.events[0].eventId).json")
        (Read-ApprovedOwnerV2SignedRecord -Path $eventPath `
                -Key $context.Key).finding.symbol | Should -BeExactly MissingTests1
    }

    It 'caps nine eligible classes at five then four with no further writes' {
        $context = New-CoverageDeliveryContext -Count 9
        $provider = New-CoverageDeliveryProvider -Evidence $context.Evidence
        $results = @()
        foreach ($run in 1..3) {
            $results += Invoke-AutomaticOwnerV2Comments `
                -Evidence $context.Evidence -Policy $context.Policy `
                -DeliveryRoot $context.Root -Key $context.Key `
                -Provider $provider.Handler
            Update-CoverageDeliveryObservation `
                -Context $context -Provider $provider
        }
        @($results.providerWrites) | Should -Be @(5, 4, 0)
        $provider.State.writes | Should -Be 9
    }

    It 'enforces the separately signed coverage per-PR ceiling' {
        $context = New-CoverageDeliveryContext -Count 2
        $context.Policy = New-AutomaticOwnerV2ServicePolicy `
            -Evidence $context.Evidence -PolicyId coverage-v2-production `
            -MaxCreatesPerRun 1 -MaxCreatesPerPullRequest 1
        $provider = New-CoverageDeliveryProvider -Evidence $context.Evidence
        $first = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        Update-CoverageDeliveryObservation -Context $context -Provider $provider
        $second = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $first.providerWrites | Should -Be 1
        $second.health | Should -BeExactly refused
        $second.providerWrites | Should -Be 0
        $provider.State.writes | Should -Be 1
    }

    It 'does not recreate an exact current class comment' {
        $context = New-CoverageDeliveryContext
        $provider = New-CoverageDeliveryProvider -Evidence $context.Evidence
        $proposal = (New-AutomaticCoverageReviewPackage `
                -Evidence $context.Evidence).proposals[0]
        [void](& $provider.Handler 'CreateThread' @{
                selection = $proposal
                anchor = [ordered]@{
                    path = $proposal.path
                    startLine = $proposal.line
                    endLine = $proposal.line
                    changeTrackingId = 7
                    iterationId = 2
                }
            })
        Update-CoverageDeliveryObservation -Context $context -Provider $provider
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly healthy
        $result.providerWrites | Should -Be 0
        $provider.State.writes | Should -Be 1
    }

    It 'requires an exact reviewer marker and body for coverage noOp, not a same-account human comment' {
        $context = New-CoverageDeliveryContext
        $selection = (New-AutomaticCoverageReviewPackage `
                -Evidence $context.Evidence).proposals[0]
        $provider = New-CoverageDeliveryProvider -Evidence $context.Evidence
        $provider.State.threads = @([ordered]@{
                threadId = 1001
                status = 'active'
                isDeleted = $false
                isOutdated = $false
                sourceCommit = $context.Evidence.Declaration.head.sourceCommit
                contextState = 'current'
                anchor = [ordered]@{
                    path = $selection.path
                    line = $selection.line
                }
                comments = @([ordered]@{
                        commentId = 1002
                        commentType = 'text'
                        isDeleted = $false
                        reviewerOwned = $true
                        reviewerIdentityState = 'matched'
                        body = 'Exclude from code coverage.'
                    })
            })
        $live = & $provider.Handler 'ReadCurrent' @{
            evidence = $context.Evidence
            selections = @($selection)
        }
        $observationCopy = ConvertTo-ApprovedOwnerV2CanonicalJson `
            $context.Evidence.Observation |
            ConvertFrom-Json -AsHashtable -Depth 64
        $resolved = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $observationCopy `
            -Contract $context.Evidence.Contract -Snapshot $live.Snapshot
        $resolved.findings[0].reconciliation.classification |
            Should -BeExactly humanCovered
        {
            Assert-AutomaticCoverageLiveNoOp -Snapshot $live.Snapshot `
                -Selection $selection `
                -SourceCommit $context.Evidence.Declaration.head.sourceCommit
        } | Should -Throw '*marker*'
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.providerWrites | Should -Be 0
        $provider.State.writes | Should -Be 0
        @($result.events | Where-Object { $_.outcome -ceq 'noOp' }).Count |
            Should -Be 0

        $provider.State.threads[0].comments[0].body = $selection.body
        $marked = & $provider.Handler 'ReadCurrent' @{
            evidence = $context.Evidence
            selections = @($selection)
        }
        {
            Assert-AutomaticCoverageLiveNoOp -Snapshot $marked.Snapshot `
                -Selection $selection `
                -SourceCommit $context.Evidence.Declaration.head.sourceCommit
        } | Should -Not -Throw
    }

    It 'rejects a noOp claim without the exact current marker-thread reconciliation' {
        $context = New-CoverageDeliveryContext
        $finding = $context.Evidence.Observation.findings[0]
        $finding.reconciliation.classification = 'noOp'
        $context.Evidence.Record.resultDigest =
            Get-ApprovedOwnerV2Digest $context.Evidence.Observation
        {
            Get-ApprovedOwnerV2Proposal -Evidence $context.Evidence `
                -Finding $finding -Delivery coverage
        } | Should -Throw '*coverage*'
        $provider = New-CoverageDeliveryProvider -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.providerWrites | Should -Be 0
        $provider.State.operations.Count | Should -Be 0
        @($result.events | Where-Object { $_.outcome -ceq 'noOp' }).Count |
            Should -Be 0
    }

    It 'refuses a historical closed/outdated human coverage decision rather than creating' {
        $context = New-CoverageDeliveryContext
        $finding = $context.Evidence.Observation.findings[0]
        $finding.anchor.line = 26
        $finding.binding.source.representation.startLine = 26
        $finding.binding.source.representation.endLine = 26
        $marker = Get-TestClassCoverageMarkerKey `
            -Contract $context.Evidence.Contract -Finding $finding
        $body = Format-TestClassCoverageComment `
            -Contract $context.Evidence.Contract -Finding $finding `
            -MarkerKey $marker
        $finding.providerMarker.integrity = 'invalid'
        $finding.reconciliation.classification = 'unknown'
        $finding.reconciliation.reason =
            'historical-human-review-needs-review'
        $finding.reconciliation.bodySha256 =
            Get-ApprovedOwnerV2TextSha256 $body
        $finding.reconciliation.thread = [ordered]@{
            availability = 'available'
            threadId = 1001
            commentId = 1002
            status = 'closed'
        }
        $context.Evidence.Observation.counts.unknown | Should -Be 0
        $context.Evidence.Record.resultDigest =
            Get-ApprovedOwnerV2Digest $context.Evidence.Observation
        $state = Write-CoverageDeliveryState -Context $context
        $loaded = Read-ApprovedOwnerV2Evidence `
            -StateRoot $state.StateRoot -Identity $context.Evidence.Identity `
            -RepoRoot $repoRoot -ToolkitConfigPath $state.ConfigPath `
            -Delivery coverage
        $policy = New-AutomaticOwnerV2ServicePolicy `
            -Evidence $loaded -PolicyId coverage-v2-production
        $probe = New-AutomaticCoverageHistoricalRefusalEvent `
            -RunId 'coverage-test-refusal' -Evidence $loaded `
            -Finding $loaded.Observation.findings[0]
        $probe.diagnostic.code | Should -BeExactly `
            historical-human-review-needs-review
        $provider = New-CoverageDeliveryProvider -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $loaded -Policy $policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly refused
        $result.providerWrites | Should -Be 0
        $provider.State.writes | Should -Be 0
        $provider.State.operations.Count | Should -Be 0
        $result.events.Count | Should -Be 1
        $event = $result.events[0]
        $event.action | Should -BeExactly none
        $event.outcome | Should -BeExactly refused
        $event.ruleId | Should -BeExactly bpm-test-class-coverage@1
        $event.capabilityId | Should -BeExactly bpm-test-class-coverage@1
        $event.finding.symbol | Should -BeExactly MissingTests1
        $event.finding.line | Should -Be 26
        $event.diagnostic.code | Should -BeExactly `
            historical-human-review-needs-review
        $event.threadId | Should -Be 1001
        $event.commentId | Should -Be 1002
        $event.url | Should -Match 'discussionId=1001&commentId=1002'
        $signedPath = Join-Path $context.Root "events\$($event.eventId).json"
        $signed = Read-ApprovedOwnerV2SignedRecord `
            -Path $signedPath -Key $context.Key
        $signed.diagnostic.code | Should -BeExactly `
            historical-human-review-needs-review
        $signed.providerWriteCount | Should -Be 0
    }

    It 'refuses current active human coverage rather than counting it as a no-op' {
        $context = New-CoverageDeliveryContext
        $context.Evidence.Observation.findings[0].reconciliation.classification =
            'humanCovered'
        $context.Evidence.Record.resultDigest =
            Get-ApprovedOwnerV2Digest $context.Evidence.Observation
        $provider = New-CoverageDeliveryProvider -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly refused
        $result.providerWrites | Should -Be 0
        $provider.State.writes | Should -Be 0
    }

    It 'blocks other create candidates in a batch awaiting historical human review' {
        $context = New-CoverageDeliveryContext -Count 2
        $finding = $context.Evidence.Observation.findings[0]
        $finding.providerMarker.integrity = 'invalid'
        $finding.reconciliation.classification = 'unknown'
        $finding.reconciliation.reason =
            'historical-human-review-needs-review'
        $finding.reconciliation.thread = [ordered]@{
            availability = 'ambiguous'
            threadId = 'unknown'
            commentId = 'unknown'
            status = 'unknown'
        }
        $context.Evidence.Observation.counts.unknown | Should -Be 0
        $context.Evidence.Record.resultDigest =
            Get-ApprovedOwnerV2Digest $context.Evidence.Observation
        $provider = New-CoverageDeliveryProvider -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly refused
        $result.remainingWouldCreate | Should -Be 1
        $result.events.Count | Should -Be 1
        $result.events[0].threadId | Should -BeNullOrEmpty
        $result.events[0].url | Should -BeNullOrEmpty
        $provider.State.operations.Count | Should -Be 0
    }

    It 'refuses a line-25 to line-26 class anchor shift or changed PR source head' `
        -TestCases @(
            @{ Drift = 'anchor' }
            @{ Drift = 'head' }
        ) {
        param($Drift)
        $context = New-CoverageDeliveryContext
        $provider = New-CoverageDeliveryProvider `
            -Evidence $context.Evidence `
            -StaleAnchor:($Drift -ceq 'anchor') `
            -StaleHead:($Drift -ceq 'head')
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly refused
        $result.diagnostic.code | Should -BeExactly live-preflight-refused
        $provider.State.writes | Should -Be 0
    }

    It 'recovers a signed interrupted class intent without creating twice' {
        $context = New-CoverageDeliveryContext
        $provider = New-CoverageDeliveryProvider -Evidence $context.Evidence
        $first = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $first.providerWrites | Should -Be 1
        Remove-Item -LiteralPath $first.outcomePath
        $recovered = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $recovered.providerWrites | Should -Be 0
        $provider.State.writes | Should -Be 1
        @($recovered.events | Where-Object {
                $_.outcome -ceq 'recovered-confirmed'
            }).Count | Should -Be 1
        (Read-ApprovedOwnerV2SignedRecord `
                -Path $first.outcomePath -Key $context.Key).kind |
            Should -BeExactly coverage-v2-service-create-outcome
    }

    It 'refuses a wrong class construct, update classification, or foreign reviewer' `
        -TestCases @('method', 'update', 'reviewer') {
        param($Kind)
        $context = New-CoverageDeliveryContext
        $providerArgs = @{ Evidence = $context.Evidence }
        if ($Kind -ceq 'method') {
            $context.Evidence.Observation.findings[0].binding.source.representation.endLine = 4
        }
        elseif ($Kind -ceq 'update') {
            $context.Evidence.Observation.findings[0].reconciliation.classification =
                'wouldUpdate'
        }
        else { $providerArgs.ForeignReviewer = $true }
        $context.Evidence.Record.resultDigest =
            Get-ApprovedOwnerV2Digest $context.Evidence.Observation
        $provider = New-CoverageDeliveryProvider @providerArgs
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly refused
        $provider.State.writes | Should -Be 0
    }

    It 'blocks blind retry after an unconfirmed create' {
        $context = New-CoverageDeliveryContext
        $provider = New-CoverageDeliveryProvider `
            -Evidence $context.Evidence -Unconfirmed
        $first = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $second = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $first.events[0].outcome | Should -BeExactly ambiguous-post-write
        $second.health | Should -BeExactly refused
        $provider.State.writes | Should -Be 1
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:coverageTestRoot -Recurse -Force
}
