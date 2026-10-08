#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:namedTestRoot = Join-Path $TestDrive (
        '.named-areequal-delivery-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:namedTestRoot | Out-Null
    Import-Module (Join-Path $repoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    Import-Module (Join-Path $repoRoot 'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') -Force
    Import-Module (Join-Path $repoRoot 'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1') -Force
    . (Join-Path $repoRoot 'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')
    . (Join-Path $repoRoot 'src\Agents\reviewer\AutomaticOwnerV2Comments.ps1')

    function New-NamedDeliveryContext {
        param([ValidateRange(1, 7)][int]$Count = 1)
        $capability = 'bpm-named-areequal-arguments@1'
        $rulePath = 'src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt'
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
                path = $rulePath
                commit = 'c' * 40
                section = $capability
                hash = 'v1:sha256:' + ('d' * 64)
                length = 100
            }
            capability = [ordered]@{
                id = $capability
                digest = 'v1:sha256:' + ('e' * 64)
            }
            model = [ordered]@{
                id = 'none'
                digest = 'v1:sha256:' + ('f' * 64)
            }
            config = [ordered]@{
                id = 'named-areequal-arguments-v1-user-approved'
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
        $findings = @(
            for ($i = 1; $i -le $Count; $i++) {
                $symbol = "Tests.Check$i"
                $line = 20 + $i
                $finding = [ordered]@{
                    identity = 'named-areequal-v2:' +
                        $i.ToString('x').PadLeft(64, '0')
                    semanticKey = 'v1:sha256:' + ('4' * 64)
                    disposition = 'violation'
                    constructRef = 'construct:' + $i.ToString('x').PadLeft(64, '0')
                    anchor = [ordered]@{
                        path = "tests/Check$i.cs"
                        line = $line
                        symbol = $symbol
                    }
                    binding = [ordered]@{
                        constructIdentity = 'v1:sha256:' + ('7' * 64)
                        source = [ordered]@{
                            representation = [ordered]@{
                                path = "tests/Check$i.cs"
                                startLine = $line
                                endLine = $line
                                symbol = $symbol
                                constructIdentity =
                                    'construct:' + $i.ToString('x').PadLeft(64, '0')
                            }
                        }
                    }
                    affectedCallCount = 1
                    affectedCallLines = @($line)
                    callListTruncated = $false
                }
                $marker = Get-NamedAreEqualMarkerKey `
                    -Contract $contract -Finding $finding
                $body = Format-NamedAreEqualComment `
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
                $finding
            }
        )
        $observation = [ordered]@{
            capability = $capability
            rule = [ordered]@{ section = $capability; path = $rulePath }
            lifecycle = [ordered]@{ status = 'completed' }
            findingsComplete = $true
            counts = [ordered]@{
                violations = $Count
                unknown = 0
                uncovered = 0
            }
            execution = [ordered]@{ modelStarts = 0 }
            findings = $findings
            effects = [ordered]@{
                dedupe = [ordered]@{}
                providerWrites = 0
                writeToolInvocations = 0
            }
            sourceArtifacts = @(
                [ordered]@{
                    kind = 'owner-v2-discussion-snapshot'
                    sha256 = '9' * 64
                    signature = 'not-applicable'
                },
                [ordered]@{
                    kind = 'named-areequal-parser-module'
                    sha256 = Get-ApprovedOwnerV2FileSha256 (
                        Join-Path $repoRoot `
                            'src\DevPilot.TestClassCoverage\DevPilot.TestClassCoverage.psm1')
                    signature = 'not-applicable'
                },
                [ordered]@{
                    kind = 'named-areequal-parser-manifest'
                    sha256 = Get-ApprovedOwnerV2FileSha256 (
                        Join-Path $repoRoot `
                            'src\DevPilot.TestClassCoverage\DevPilot.TestClassCoverage.psd1')
                    signature = 'not-applicable'
                }
            )
        }
        $root = Join-Path $script:namedTestRoot ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $paths = [ordered]@{}
        foreach ($name in @('declaration', 'evidence', 'record', 'observation')) {
            $paths[$name] = Join-Path $root "$name.json"
            [IO.File]::WriteAllText($paths[$name], '{}')
        }
        $paths.telemetry = Join-Path $root 'telemetry.json'
        $paths.parser = Join-Path $repoRoot `
            'src\DevPilot.TestClassCoverage\DevPilot.TestClassCoverage.psm1'
        $paths.parserManifest = Join-Path $repoRoot `
            'src\DevPilot.TestClassCoverage\DevPilot.TestClassCoverage.psd1'
        $paths.activePrIntake = Join-Path $repoRoot `
            'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psm1'
        $paths.namedBridge = Join-Path $repoRoot `
            'src\DevPilot.NamedAreEqualBridge\DevPilot.NamedAreEqualBridge.psm1'
        $paths.sharedAcquisitionTool = Join-Path $repoRoot `
            'tools\Invoke-SharedReviewAcquisition.ps1'
        $evidence = [pscustomobject]@{
            Identity = 'a' * 64
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
                parserSha256 =
                    Get-ApprovedOwnerV2FileSha256 $paths.parser
                parserManifestSha256 =
                    Get-ApprovedOwnerV2FileSha256 $paths.parserManifest
                activePrIntakeSha256 =
                    Get-ApprovedOwnerV2FileSha256 $paths.activePrIntake
                activePrIntakeManifestSha256 =
                    Get-ApprovedOwnerV2FileSha256 (
                        Join-Path $repoRoot `
                            'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1')
                namedBridgeSha256 =
                    Get-ApprovedOwnerV2FileSha256 $paths.namedBridge
                namedBridgeManifestSha256 =
                    Get-ApprovedOwnerV2FileSha256 (
                        Join-Path $repoRoot `
                            'src\DevPilot.NamedAreEqualBridge\DevPilot.NamedAreEqualBridge.psd1')
                sharedAcquisitionToolSha256 =
                    Get-ApprovedOwnerV2FileSha256 `
                        $paths.sharedAcquisitionTool
                namedCurrentPrToolSha256 =
                    Get-ApprovedOwnerV2FileSha256 (
                        Join-Path $repoRoot `
                            'tools\Invoke-NamedAreEqualCurrentPr.ps1')
            }
            Provider = [ordered]@{
                kind = 'azure-devops-rest-owner-discussions-v1'
                organization = 'https://dev.azure.com/example'
                projectName = 'Example'
                repositoryId = $declaration.subject.repositoryId
                projectId = $declaration.subject.projectId
                reviewerIdentity = [ordered]@{
                    id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                    descriptor = 'aad.test-descriptor'
                    uniqueName = 'reviewer@example.invalid'
                }
            }
        }
        $deliveryRoot = Join-Path $root 'delivery\named-areequal-v1'
        foreach ($leaf in @('intents', 'outcomes', 'events', 'locks')) {
            New-Item -ItemType Directory -Path (
                Join-Path $deliveryRoot $leaf) -Force | Out-Null
        }
        return [pscustomobject]@{
            Evidence = $evidence
            Policy = New-AutomaticOwnerV2ServicePolicy `
                -Evidence $evidence -PolicyId named-areequal-v1-production
            Root = $deliveryRoot
            Key = [byte[]](1..32)
        }
    }

    function New-NamedDeliveryProvider {
        param(
            [Parameter(Mandatory)]$Evidence,
            [string]$Drift = '',
            [switch]$Unconfirmed
        )
        $state = [ordered]@{
            threads = @()
            digest = '9' * 64
            operations = [Collections.Generic.List[string]]::new()
            writes = 0
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
                            path = $selection.path
                            line = $selection.line
                        }
                        comments = @([ordered]@{
                                commentId = 1100 + $state.writes
                                commentType = 'text'
                                isDeleted = $false
                                reviewerOwned = $true
                                reviewerIdentityState = 'matched'
                                body = $selection.body
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
                @($state.threads).Count, 0,
                "v1:sha256:$($state.digest)",
                [string[]]@('v1:sha256:' + ('f' * 64)),
                [object[]]@($state.threads))
            $snapshot | Add-Member -NotePropertyName CurrentIterationId `
                -NotePropertyValue $(if ($Drift -ceq 'iteration') { 3 } else { 2 })
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
                    isDraft = $Drift -ceq 'draft'
                    repositoryId = $Evidence.Declaration.subject.repositoryId
                    projectId = $Evidence.Declaration.subject.projectId
                    sourceCommit = $(if ($Drift -ceq 'head') { 'e' * 40 } else {
                            $Evidence.Declaration.head.sourceCommit
                        })
                    targetCommit = $(if ($Drift -ceq 'target') { 'f' * 40 } else {
                            $Evidence.Declaration.target.targetCommit
                        })
                    targetRef = $Evidence.Declaration.target.targetRef
                }
                Reviewer = [ordered]@{
                    id = $(if ($Drift -ceq 'reviewer') { 'foreign' } else {
                            $Evidence.Provider.reviewerIdentity.id
                        })
                    descriptor = $Evidence.Provider.reviewerIdentity.descriptor
                    uniqueName = $Evidence.Provider.reviewerIdentity.uniqueName
                }
                Snapshot = $snapshot
                Anchors = @(
                    foreach ($selection in @($Arguments.selections)) {
                        foreach ($line in @($selection.affectedCallLines)) {
                            if ($Drift -ceq 'later-line' -and
                                [int]$line -ne [int]$selection.line) {
                                continue
                            }
                            [ordered]@{
                                path = $selection.path
                                startLine = $(if ($Drift -ceq 'anchor') {
                                        [int]$line + 1
                                    } else { [int]$line })
                                endLine = $(if ($Drift -ceq 'anchor') {
                                        [int]$line + 1
                                    } else { [int]$line })
                                changeTrackingId = 7
                                iterationId = 2
                            }
                        }
                    }
                )
            }
        }.GetNewClosure()
        return [pscustomobject]@{ Handler = $handler; State = $state }
    }

    function Set-NamedCallLines {
        param([Parameter(Mandatory)]$Context, [int[]]$Lines)
        $finding = $Context.Evidence.Observation.findings[0]
        $finding.affectedCallCount = $Lines.Count
        $finding.affectedCallLines = $Lines
        $finding.callListTruncated = $Lines.Count -gt 12
        $marker = Get-NamedAreEqualMarkerKey `
            -Contract $Context.Evidence.Contract -Finding $finding
        $body = Format-NamedAreEqualComment `
            -Contract $Context.Evidence.Contract -Finding $finding -MarkerKey $marker
        $finding.reconciliation.bodySha256 = Get-ApprovedOwnerV2TextSha256 $body
        $Context.Evidence.Record.resultDigest =
            Get-ApprovedOwnerV2Digest $Context.Evidence.Observation
    }

    function Update-NamedDeliveryObservation {
        param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Provider)
        $live = & $Provider.Handler 'ReadCurrent' @{
            evidence = $Context.Evidence
            selections = @()
        }
        $resolved = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $Context.Evidence.Observation `
            -Contract $Context.Evidence.Contract -Snapshot $live.Snapshot
        $Context.Evidence.Observation = $resolved
        $Context.Evidence.Record.resultDigest = Get-ApprovedOwnerV2Digest $resolved
    }

    function Write-NamedDeliveryState {
        param([Parameter(Mandatory)]$Context)
        $e = $Context.Evidence
        $identity = New-OwnerAzureDevOpsReviewerIdentity `
            -Id $e.Provider.reviewerIdentity.id `
            -Descriptor $e.Provider.reviewerIdentity.descriptor `
            -UniqueName $e.Provider.reviewerIdentity.uniqueName
        $adapter = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
            -Name 'named-delivery-test-config' -ReviewerIdentity $identity `
            -Handler { throw 'not invoked' }
        $declaration = $e.Declaration
        $declaration['kind'] = 'owner-v2-preview-declaration'
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
            declarationPath = "declarations\$($e.Identity).json"
            evidencePath = "evidence\$($e.Identity).json"
            observationPath = "observations\$($e.Identity).json"
            resultDigest = Get-ApprovedOwnerV2Digest $observation
            incompleteReason = 'unknown'
            modelExecutionState = 'notAttempted'
        }
        $pin = [ordered]@{
            kind = 'owner-v2-preview-live-evidence-pin'
            acquisitionPayloadDigest = $declaration.acquisitionPayloadDigest
        }
        $stateRoot = Join-Path $script:namedTestRoot (
            [guid]::NewGuid().ToString('N'))
        $root = Get-ApprovedOwnerV2CapabilityRoot -StateRoot $stateRoot `
            -CapabilityId $declaration.capability.id `
            -CapabilityDigest $declaration.capability.digest
        foreach ($item in @(
                @{ Name = 'declarations'; Value = $declaration },
                @{ Name = 'evidence'; Value = $pin },
                @{ Name = 'records'; Value = $record },
                @{ Name = 'observations'; Value = $observation }
            )) {
            $folder = Join-Path $root $item.Name
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            [IO.File]::WriteAllText(
                (Join-Path $folder "$($e.Identity).json"),
                (ConvertTo-ApprovedOwnerV2CanonicalJson $item.Value))
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
            sharedAcquisition = [ordered]@{
                kind = 'devpilot-shared-review-acquisition-v1'
                activePrIntakeSha256 =
                    Get-ApprovedOwnerV2FileSha256 (
                        Join-Path $repoRoot `
                            'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psm1')
                namedBridgeSha256 =
                    Get-ApprovedOwnerV2FileSha256 (
                        Join-Path $repoRoot `
                            'src\DevPilot.NamedAreEqualBridge\DevPilot.NamedAreEqualBridge.psm1')
                toolSha256 =
                    Get-ApprovedOwnerV2FileSha256 (
                        Join-Path $repoRoot `
                            'tools\Invoke-SharedReviewAcquisition.ps1')
            }
        }
        $configPath = Join-Path $stateRoot 'named-config.json'
        [IO.File]::WriteAllText($configPath,
            (ConvertTo-ApprovedOwnerV2CanonicalJson $config))
        return [pscustomobject]@{
            StateRoot = $stateRoot
            ConfigPath = $configPath
        }
    }
}

Describe 'Named AreEqual automatic delivery' {
    It 'returns disabled from the CLI with no local delivery root or provider access' {
        $context = New-NamedDeliveryContext
        $state = Write-NamedDeliveryState -Context $context
        $loaded = Read-AutomaticNamedAreEqualEvidence `
            -StateRoot $state.StateRoot -Identity $context.Evidence.Identity `
            -ToolkitConfigPath $state.ConfigPath -RepoRoot $repoRoot
        $loaded.Observation.capability |
            Should -BeExactly bpm-named-areequal-arguments@1
        $loaded.Telemetry | Should -BeNullOrEmpty
        $delivery = Join-Path $script:namedTestRoot (
            'disabled-' + [guid]::NewGuid().ToString('N'))
        $tool = Join-Path $repoRoot 'tools\Invoke-AutomaticOwnerV2Delivery.ps1'
        $output = @(& (Get-Command pwsh).Source -NoProfile -File $tool `
                invoke -Delivery named-areequal -DeliveryRoot $delivery `
                -StateRoot $state.StateRoot -Identity $context.Evidence.Identity `
                -ToolkitConfigPath $state.ConfigPath -RepoRoot $repoRoot 2>&1)
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'disabled'
        Test-Path -LiteralPath $delivery | Should -BeFalse
    }

    It 'stays off independently; boolean true cannot bypass the signed policy' {
        $config = [ordered]@{
            autoCreateOwnerComments = $true
            autoCreateCoverageComments = $true
            autoCreateRedundantMethodCoverageComments = $true
        }
        (Get-AutomaticOwnerV2Configuration -ToolkitConfig $config `
                -Delivery named-areequal).Enabled | Should -BeFalse
        $config.autoCreateNamedAreEqualComments = $true
        {
            Get-AutomaticOwnerV2Configuration -ToolkitConfig $config `
                -Delivery named-areequal
        } | Should -Throw '*signed policy*'
        $config.autoCreateNamedAreEqualComments = $false
        (Get-AutomaticOwnerV2Configuration -ToolkitConfig $config `
                -Delivery named-areequal).Enabled | Should -BeFalse
    }

    It 'isolates private signed authority and rejects cross-rule policies' {
        $context = New-NamedDeliveryContext
        $base = Join-Path $script:namedTestRoot ([guid]::NewGuid().ToString('N'))
        $boundary = Join-Path $script:namedTestRoot ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $boundary | Out-Null
        $namedRoot = Initialize-AutomaticOwnerV2DeliveryRoot `
            -DeliveryRoot $base -RepoRoot $boundary -Delivery named-areequal
        $ownerRoot = Initialize-AutomaticOwnerV2DeliveryRoot `
            -DeliveryRoot (Join-Path $base 'owner') -RepoRoot $boundary
        $namedRoot.Root | Should -Not -BeExactly $ownerRoot.Root
        $key = Get-AutomaticOwnerV2ServiceKey -DeliveryRoot $namedRoot.Root `
            -Delivery named-areequal
        $otherKey = Get-AutomaticOwnerV2ServiceKey `
            -DeliveryRoot $ownerRoot.Root
        [Convert]::ToHexString($key) |
            Should -Not -BeExactly ([Convert]::ToHexString($otherKey))
        $path = Join-Path $namedRoot.Root 'policies\named-areequal-v1-production.json'
        [void](Write-AutomaticOwnerV2ServicePolicy -Path $path `
                -Policy $context.Policy -Key $key)
        $signed = Read-ApprovedOwnerV2SignedRecord -Path $path -Key $key
        $signed.kind | Should -BeExactly named-areequal-v1-service-authorization-policy
        $signed.rule.path | Should -BeExactly `
            'src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt'
        { Read-ApprovedOwnerV2SignedRecord -Path $path -Key $otherKey } |
            Should -Throw
        $signed.kind = 'redundant-coverage-v2-service-authorization-policy'
        { Assert-AutomaticOwnerV2ServicePolicy -Evidence $context.Evidence `
                -Policy $signed } | Should -Throw
        $signed.kind = 'named-areequal-v1-service-authorization-policy'
        $signed.limits.maxCreatesPerPullRequest = 6
        { Assert-AutomaticOwnerV2ServicePolicy -Evidence $context.Evidence `
                -Policy $signed } | Should -Throw '*ceilings*'
        $signed.limits.maxCreatesPerPullRequest = 5
        $signed.limits.maxCreatesPerRun = 3
        { Assert-AutomaticOwnerV2ServicePolicy -Evidence $context.Evidence `
                -Policy $signed } | Should -Throw '*ceilings*'
    }

    It 'rejects named policy construction above 2 per run or 5 per PR' {
        $context = New-NamedDeliveryContext
        $context.Policy.limits.maxCreatesPerRun | Should -Be 2
        $context.Policy.limits.maxCreatesPerPullRequest | Should -Be 5
        $exact = New-AutomaticOwnerV2ServicePolicy `
            -Evidence $context.Evidence -PolicyId named-exact-boundary `
            -MaxCreatesPerRun 2 -MaxCreatesPerPullRequest 5
        { Assert-AutomaticOwnerV2ServicePolicy `
                -Evidence $context.Evidence -Policy $exact } |
            Should -Not -Throw
        $lower = New-AutomaticOwnerV2ServicePolicy `
            -Evidence $context.Evidence -PolicyId named-lower-boundary `
            -MaxCreatesPerRun 1 -MaxCreatesPerPullRequest 1
        { Assert-AutomaticOwnerV2ServicePolicy `
                -Evidence $context.Evidence -Policy $lower } |
            Should -Not -Throw
        {
            New-AutomaticOwnerV2ServicePolicy `
                -Evidence $context.Evidence `
                -PolicyId named-too-many-per-run `
                -MaxCreatesPerRun 3 -MaxCreatesPerPullRequest 5
        } | Should -Throw '*2 per run or 5 per pull request*'
        {
            New-AutomaticOwnerV2ServicePolicy `
                -Evidence $context.Evidence `
                -PolicyId named-too-many-per-pr `
                -MaxCreatesPerRun 2 -MaxCreatesPerPullRequest 6
        } | Should -Throw '*2 per run or 5 per pull request*'
    }

    It 'rejects correctly signed named policies above the hard ceilings' {
        $context = New-NamedDeliveryContext
        foreach ($case in @(
                @{ Name = 'run'; Run = 3; Pr = 5 }
                @{ Name = 'pr'; Run = 2; Pr = 6 }
            )) {
            $policy = ConvertTo-ApprovedOwnerV2CanonicalJson `
                $context.Policy |
                ConvertFrom-Json -AsHashtable -Depth 32
            $policy.limits.maxCreatesPerRun = $case.Run
            $policy.limits.maxCreatesPerPullRequest = $case.Pr
            $path = Join-Path $context.Root (
                "policies\correctly-signed-over-$($case.Name).json")
            [void](Write-AutomaticOwnerV2ServicePolicy `
                -Path $path -Policy $policy -Key $context.Key)
            $loaded = Read-ApprovedOwnerV2SignedRecord `
                -Path $path -Key $context.Key
            { Assert-AutomaticOwnerV2ServicePolicy `
                    -Evidence $context.Evidence -Policy $loaded } |
                Should -Throw '*ceilings*'
        }
    }

    It 'rejects explicit named overlimits before creating a root or key' {
        $tool = Join-Path $repoRoot `
            'tools\Invoke-AutomaticOwnerV2Delivery.ps1'
        foreach ($case in @(
                @{ Name = 'run'; Arguments = @(
                    '-MaxCreatesPerRun', '3',
                    '-MaxCreatesPerPullRequest', '5') }
                @{ Name = 'pr'; Arguments = @(
                    '-MaxCreatesPerRun', '2',
                    '-MaxCreatesPerPullRequest', '6') }
            )) {
            $root = Join-Path $script:namedTestRoot (
                "cli-over-$($case.Name)-" + [guid]::NewGuid().ToString('N'))
            $arguments = @(
                '-NoProfile', '-NonInteractive', '-File', $tool,
                'initialize-key',
                '-Delivery', 'named-areequal',
                '-DeliveryRoot', $root,
                '-RepoRoot', $repoRoot
            ) + @($case.Arguments)
            $output = @(& (Get-Command pwsh).Source @arguments 2>&1)
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -Match `
                'cannot exceed 2 creates per run or 5 per pull request'
            Test-Path -LiteralPath $root | Should -BeFalse
        }
    }

    It 'refuses an update-authorizing or foreign rule policy without provider access' {
        foreach ($invalid in @('update', 'rule')) {
            $context = New-NamedDeliveryContext
            if ($invalid -ceq 'update') {
                $context.Policy.authority.updates = $true
            }
            else {
                $context.Policy.rule.path =
                    'src/DevPilot.OwnerCapability/Policy/redundant-method-coverage.v1.txt'
            }
            $provider = New-NamedDeliveryProvider -Evidence $context.Evidence
            $result = Invoke-AutomaticOwnerV2Comments `
                -Evidence $context.Evidence -Policy $context.Policy `
                -DeliveryRoot $context.Root -Key $context.Key `
                -Provider $provider.Handler
            $result.health | Should -BeExactly refused
            $result.diagnostic.code | Should -BeExactly policy-refused
            $provider.State.operations.Count | Should -Be 0
        }
    }

    It 'refuses parser module or manifest byte changes before intent or provider access' `
        -TestCases @(
            @{ Target = 'module' }
            @{ Target = 'manifest' }
        ) {
        param($Target)
        $context = New-NamedDeliveryContext
        $source = if ($Target -ceq 'module') {
            [string]$context.Evidence.Paths.parser
        }
        else {
            [string]$context.Evidence.Paths.parserManifest
        }
        $copy = Join-Path $script:namedTestRoot (
            "tampered-$Target-" + [guid]::NewGuid().ToString('N'))
        [IO.File]::Copy($source, $copy)
        if ($Target -ceq 'module') {
            $context.Evidence.Paths.parser = $copy
            $context.Evidence.Toolkit.parserSha256 =
                Get-ApprovedOwnerV2FileSha256 $copy
        }
        else {
            $context.Evidence.Paths.parserManifest = $copy
            $context.Evidence.Toolkit.parserManifestSha256 =
                Get-ApprovedOwnerV2FileSha256 $copy
        }
        $context.Policy = New-AutomaticOwnerV2ServicePolicy `
            -Evidence $context.Evidence `
            -PolicyId "named-parser-$Target"
        [IO.File]::AppendAllText(
            $copy, "`n# tampered", [Text.UTF8Encoding]::new($false))
        $provider = New-NamedDeliveryProvider `
            -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler

        $result.health | Should -BeExactly 'refused'
        $result.diagnostic.code | Should -BeExactly 'policy-refused'
        $provider.State.operations.Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (
                Join-Path $context.Root 'intents') -File -Recurse) |
            Should -HaveCount 0
    }

    It 'refuses malformed bounded method metadata before provider reads' `
        -TestCases @(
            @{ Invalid = 'count' }
            @{ Invalid = 'duplicate' }
            @{ Invalid = 'order' }
            @{ Invalid = 'first' }
            @{ Invalid = 'truncation' }
            @{ Invalid = 'symbol' }
        ) {
        param($Invalid)
        $context = New-NamedDeliveryContext
        $finding = $context.Evidence.Observation.findings[0]
        switch ($Invalid) {
            count { $finding.affectedCallCount = 257 }
            duplicate {
                $finding.affectedCallCount = 2
                $finding.affectedCallLines = @(21, 21)
            }
            order {
                $finding.affectedCallCount = 2
                $finding.affectedCallLines = @(21, 20)
            }
            first { $finding.affectedCallLines = @(22) }
            truncation { $finding.callListTruncated = $true }
            symbol { $finding.anchor.symbol = 'Tests.Check1 invalid' }
        }
        $context.Evidence.Record.resultDigest =
            Get-ApprovedOwnerV2Digest $context.Evidence.Observation
        $provider = New-NamedDeliveryProvider -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly refused
        $provider.State.operations.Count | Should -Be 0
    }

    It 'creates only a signed bounded method comment with isolated audit and readback' {
        $context = New-NamedDeliveryContext
        Set-NamedCallLines -Context $context -Lines @(21, 36)
        $provider = New-NamedDeliveryProvider -Evidence $context.Evidence
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly healthy `
            -Because ($result.diagnostic | ConvertTo-Json -Depth 6 -Compress)
        $result.providerWrites | Should -Be 1
        $provider.State.operations | Should -Be @(
            'ReadCurrent', 'ReadCurrent', 'CreateThread', 'ReadCurrent')
        $result.kind | Should -BeExactly named-areequal-v2-automatic-delivery-result
        $result.events[0].kind | Should -BeExactly named-areequal-v2-delivery-event
        $result.events[0].finding.symbol | Should -BeExactly Tests.Check1
        $result.events[0].finding.line | Should -Be 21
        (Read-ApprovedOwnerV2SignedRecord -Path $result.intentPath `
                -Key $context.Key).kind |
            Should -BeExactly named-areequal-v2-service-create-intent
        (Read-ApprovedOwnerV2SignedRecord -Path $result.outcomePath `
                -Key $context.Key).kind |
            Should -BeExactly named-areequal-v2-service-create-outcome
        $eventPath = Join-Path $context.Root (
            "events\$($result.events[0].eventId).json")
        $signedEvent = Read-ApprovedOwnerV2SignedRecord -Path $eventPath `
            -Key $context.Key
        $signedEvent.finding.bodySha256 | Should -BeExactly (
            $context.Evidence.Observation.findings[0].reconciliation.bodySha256)
        $signedEvent.capabilityId |
            Should -BeExactly bpm-named-areequal-arguments@1
        $again = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $again.providerWrites | Should -Be 0
        $provider.State.writes | Should -Be 1
    }

    It 'enforces independent per-run and per-PR create caps' {
        $context = New-NamedDeliveryContext -Count 3
        $context.Policy.limits.maxCreatesPerRun = 1
        $context.Policy.limits.maxCreatesPerPullRequest = 2
        $provider = New-NamedDeliveryProvider -Evidence $context.Evidence
        $first = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        Update-NamedDeliveryObservation -Context $context -Provider $provider
        $second = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        Update-NamedDeliveryObservation -Context $context -Provider $provider
        $third = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $first.providerWrites | Should -Be 1 `
            -Because ($first.diagnostic | ConvertTo-Json -Depth 6 -Compress)
        $second.providerWrites | Should -Be 1 `
            -Because ($second.diagnostic | ConvertTo-Json -Depth 6 -Compress)
        $third.health | Should -BeExactly refused
        $third.providerWrites | Should -Be 0
        $provider.State.writes | Should -Be 2
    }

    It 'refuses <Drift> before any create' -TestCases @(
        @{ Drift = 'head' }
        @{ Drift = 'target' }
        @{ Drift = 'anchor' }
        @{ Drift = 'later-line' }
        @{ Drift = 'draft' }
        @{ Drift = 'iteration' }
        @{ Drift = 'reviewer' }
    ) {
        param($Drift)
        $context = New-NamedDeliveryContext
        Set-NamedCallLines -Context $context -Lines @(21, 36)
        $provider = New-NamedDeliveryProvider -Evidence $context.Evidence `
            -Drift $Drift
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly refused
        $provider.State.operations | Should -Not -Contain CreateThread
    }

    It 'does not treat an unmarked reviewer discussion as a bot noOp' {
        $context = New-NamedDeliveryContext
        $provider = New-NamedDeliveryProvider -Evidence $context.Evidence
        $provider.State.threads = @([ordered]@{
                threadId = 90
                status = 'active'
                isDeleted = $false
                isOutdated = $false
                sourceCommit = $context.Evidence.Declaration.head.sourceCommit
                contextState = 'current'
                anchor = [ordered]@{ path = 'tests/Check1.cs'; line = 21 }
                comments = @([ordered]@{
                        commentId = 91
                        commentType = 'text'
                        isDeleted = $false
                        reviewerOwned = $true
                        reviewerIdentityState = 'matched'
                        body = 'Fixture review: name expected and actual arguments in Assert.AreEqual.'
                    })
            })
        $live = & $provider.Handler 'ReadCurrent' @{
            evidence = $context.Evidence
            selections = @([ordered]@{
                    path = 'tests/Check1.cs'
                    line = 21
                    affectedCallLines = @(21)
                })
        }
        $resolved = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $context.Evidence.Observation `
            -Contract $context.Evidence.Contract -Snapshot $live.Snapshot
        $resolved.findings[0].reconciliation.classification |
            Should -BeExactly humanCovered
        $context.Evidence.Observation = $resolved
        $context.Evidence.Record.resultDigest = Get-ApprovedOwnerV2Digest $resolved
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly refused
        $provider.State.operations | Should -Not -Contain CreateThread
    }

    It 'signs a historical-human refusal without reading or writing the provider' {
        $context = New-NamedDeliveryContext
        $provider = New-NamedDeliveryProvider -Evidence $context.Evidence
        $provider.State.threads = @([ordered]@{
                threadId = 90
                status = 'closed'
                isDeleted = $false
                isOutdated = $true
                sourceCommit = '0' * 40
                contextState = 'outdated'
                anchor = [ordered]@{ path = 'tests/Check1.cs'; line = 21 }
                comments = @([ordered]@{
                        commentId = 91
                        commentType = 'text'
                        isDeleted = $false
                        reviewerOwned = $true
                        reviewerIdentityState = 'matched'
                        body = 'Fixture review: name expected and actual arguments in Assert.AreEqual.'
                    })
            })
        Update-NamedDeliveryObservation -Context $context -Provider $provider
        $context.Evidence.Observation.findings[0].reconciliation.classification |
            Should -BeExactly unknown
        $provider.State.operations.Clear()
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly refused
        $result.providerWrites | Should -Be 0
        $provider.State.operations.Count | Should -Be 0
        $result.events[0].action | Should -BeExactly none
        $result.events[0].diagnostic.code |
            Should -BeExactly historical-human-review-needs-review
        $result.events[0].threadId | Should -Be 90
        $eventPath = Join-Path $context.Root (
            "events\$($result.events[0].eventId).json")
        (Read-ApprovedOwnerV2SignedRecord -Path $eventPath `
                -Key $context.Key).outcome | Should -BeExactly refused
    }

    It 'rejects a cross-rule marker and changed discussion before create' {
        $context = New-NamedDeliveryContext
        $provider = New-NamedDeliveryProvider -Evidence $context.Evidence
        $provider.State.threads = @([ordered]@{
                threadId = 90
                status = 'active'
                isDeleted = $false
                isOutdated = $false
                sourceCommit = $context.Evidence.Declaration.head.sourceCommit
                contextState = 'current'
                anchor = [ordered]@{ path = 'tests/Check1.cs'; line = 21 }
                comments = @([ordered]@{
                        commentId = 91
                        commentType = 'text'
                        isDeleted = $false
                        reviewerOwned = $true
                        reviewerIdentityState = 'matched'
                        body = '<!-- devpilot-test-class-coverage:v1:' +
                            ('a' * 64) + ' -->'
                    })
            })
        $result = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $result.health | Should -BeExactly refused
        $provider.State.operations | Should -Not -Contain CreateThread

        $provider.State.threads = @()
        $provider.State.operations.Clear()
        $provider.State.digest = 'a' * 64
        $changed = Invoke-AutomaticOwnerV2Comments `
            -Evidence $context.Evidence -Policy $context.Policy `
            -DeliveryRoot $context.Root -Key $context.Key `
            -Provider $provider.Handler
        $changed.health | Should -BeExactly refused
        $provider.State.operations | Should -Not -Contain CreateThread
    }

    It 'requires the exact current marker and body for a live noOp' {
        $context = New-NamedDeliveryContext
        $proposal = (New-AutomaticNamedAreEqualReviewPackage `
                -Evidence $context.Evidence).proposals[0]
        $provider = New-NamedDeliveryProvider -Evidence $context.Evidence
        [void](& $provider.Handler 'CreateThread' @{
                selection = $proposal
                evidence = $context.Evidence
            })
        $live = & $provider.Handler 'ReadCurrent' @{
            evidence = $context.Evidence
            selections = @($proposal)
        }
        { Assert-AutomaticNamedAreEqualLiveNoOp -Snapshot $live.Snapshot `
                -Selection $proposal `
                -SourceCommit $context.Evidence.Declaration.head.sourceCommit } |
            Should -Not -Throw
        $provider.State.threads[0].comments[0].body = 'Unmarked human comment'
        { Assert-AutomaticNamedAreEqualLiveNoOp -Snapshot $live.Snapshot `
                -Selection $proposal `
                -SourceCommit $context.Evidence.Declaration.head.sourceCommit } |
            Should -Throw
    }

    It 'blocks an uncertain create instead of blindly retrying' {
        $context = New-NamedDeliveryContext
        $provider = New-NamedDeliveryProvider -Evidence $context.Evidence -Unconfirmed
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
    Remove-Item -LiteralPath $script:namedTestRoot -Recurse -Force
}
