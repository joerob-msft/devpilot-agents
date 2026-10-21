#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') -Force
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1') -Force
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
        $policyPath = Join-Path $repoRoot `
            'src\DevPilot.OwnerCapability\Policy\contextual-conventions.v1.json'
        $policyText = [IO.File]::ReadAllText(
            $policyPath,
            [Text.UTF8Encoding]::new($false))
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
                    Get-ContextualTestTextDigest `
                        $policyText
                length =
                    [Text.Encoding]::UTF8.
                        GetByteCount($policyText)
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
                    (Get-FileHash (
                        Join-Path $repoRoot `
                            'src\DevPilot.ContextualConventions\DevPilot.ContextualConventions.psm1') `
                        -Algorithm SHA256).Hash.
                    ToLowerInvariant()
            }
            sharedAcquisition = [ordered]@{
                kind =
                    'devpilot-shared-review-acquisition-v1'
                includePullRequestTemplateAuthority =
                    $true
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
                'using System.IO; class C { void M() { try { X(); } catch (IOException ex) when (!ex.IsFatal()) { Logger.Error(ex.Message); } } }',
            [string]$Description = @'
**Problem:**
Synthetic problem.

**Solution:**
Synthetic solution.

**Validation:**
Synthetic validation.
'@
        )
        $template = @'
**Problem:**

**Solution:**

**Validation:**
Describe what validations are needed:
- [ ] Optional full test pass

**Release Notes**
'@
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
            title = 'Synthetic PR'
            description = $Description
            descriptionDigest =
                Get-ContextualTestTextDigest `
                    $Description
            templateAuthority = [ordered]@{
                state = 'complete'
                path =
                    '/.azuredevops/pull_request_template.txt'
                configurationRef =
                    'refs/heads/master'
                configurationCommit = '1' * 40
                blob = '2' * 40
                contentDigest =
                    Get-ContextualTestTextDigest `
                        $template
                content = $template
            }
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

    function Invoke-SyntheticContextualBridge {
        param(
            [Parameter(Mandatory)]
            [Collections.IDictionary]$Config,
            [Parameter(Mandatory)]$Prepared,
            [Parameter(Mandatory)]
            [string]$Name,
            [scriptblock]$HeadProvider
        )
        $preparedValue = $Prepared
        $headCommand = $HeadProvider
        $provider = {
            param($Operation, $Arguments)
            if ($Operation -ceq 'Head') {
                if ($null -ne $headCommand) {
                    return & $headCommand `
                        $preparedValue.Head
                }
                return [ordered]@{} +
                    $preparedValue.Head
            }
            throw "unexpected:$Operation"
        }.GetNewClosure()
        return Invoke-ContextualConventionsCurrentPrBridge `
            -Config $Config -Provider $provider `
            -StateRoot (
                Join-Path $TestDrive "$Name-state") `
            -ManifestPath (
                Join-Path $TestDrive "$Name-manifest.json") `
            -RepositoryRoot $repoRoot `
            -PreparedIntake $Prepared.Intake -Run
    }

    function New-SyntheticPrTemplateReviewerComment {
        param(
            [Parameter(Mandatory)]
            [Collections.IDictionary]$Config,
            [Parameter(Mandatory)]
            [Collections.IDictionary]$Head,
            [Parameter(Mandatory)]
            [string[]]$MissingSections,
            [AllowNull()]
            [Collections.IDictionary]$TemplateAuthority =
                $null
        )
        $template = if ($null -eq
                $TemplateAuthority) {
            $Head.templateAuthority
        }
        else { $TemplateAuthority }
        $contract =
            New-OwnerAcquisitionContract `
                -RepositoryId $Head.repositoryId `
                -ProjectId $Head.projectId `
                -PullRequestId $Head.pullRequestId `
                -SourceCommit $Head.sourceCommit `
                -TargetCommit $Head.targetCommit `
                -TargetRef $Head.targetRef `
                -RuleRepositoryId (
                    $Config.contextualRule.repositoryId) `
                -RulePath $Config.contextualRule.path `
                -RuleCommit $Config.toolkit.head `
                -RuleSection (
                    $Config.contextualRule.section) `
                -RuleHash $Config.contextualRule.hash `
                -RuleLength $Config.contextualRule.length `
                -ConfigId contextual-test `
                -ConfigDigest (
                    'v1:sha256:' + ('7' * 64)) `
                -CapabilityId $Config.capability.id `
                -CapabilityDigest (
                    'v1:sha256:' +
                    $Config.capability.
                        implementationSha256)
        $constructRef =
            'construct:' + ('6' * 64)
        $finding = [ordered]@{
            disposition = 'violation'
            ruleId = 'pr-template-compliance'
            constructRef = $constructRef
            issueIdentity =
                Get-ContextualTestTextDigest (
                    @($MissingSections |
                        Sort-Object) -join ',')
            evidence =
                'Add meaningful content under the required PR description sections: ' +
                (@($MissingSections) -join ', ') +
                '.'
            missingSections =
                @($MissingSections)
            anchor = [ordered]@{
                scope = 'pull-request'
                subject = 'description'
            }
            binding = [ordered]@{
                source = [ordered]@{
                    representation =
                        [ordered]@{
                            scope =
                                'pull-request'
                            subject =
                                'description'
                            descriptionSha256 =
                                $Head.descriptionDigest.
                                    Substring(10)
                            template =
                                [ordered]@{
                                    path =
                                        ([string]$template.path).
                                            TrimStart('/')
                                    ref =
                                        [string]$template.configurationRef
                                    commit =
                                        [string]$template.configurationCommit
                                    blob =
                                        [string]$template.blob
                                    contentSha256 =
                                        ([string]$template.contentDigest).
                                            Substring(10)
                                }
                            constructIdentity =
                                $constructRef
                        }
                }
            }
        }

        $marker =
            Get-ContextualConventionMarkerKey `
                -Contract $contract `
                -Finding $finding
        return [pscustomobject]@{
            Marker = $marker
            Body =
                Format-ContextualConventionComment `
                    -Contract $contract `
                    -Finding $finding `
                    -MarkerKey $marker
        }
    }

    function Get-SyntheticDiscussionAuthor {
        param(
            [Parameter(Mandatory)]
            [Collections.IDictionary]$Config,
            [ValidateSet(
                'reviewer',
                'human',
                'ambiguous')]
            [string]$Identity
        )
        switch ($Identity) {
            reviewer {
                return [ordered]@{
                    id = $Config.expectedAccount.id
                    descriptor =
                        $Config.expectedAccount.descriptor
                    uniqueName =
                        $Config.expectedAccount.uniqueName
                }
            }
            human {
                return [ordered]@{
                    id =
                        '44444444-4444-4444-4444-444444444444'
                    descriptor = 'aad.human'
                    uniqueName = 'human@example.invalid'
                }
            }
            ambiguous {
                return [ordered]@{}
            }
        }
    }

    function Add-SyntheticDiscussion {
        param(
            [Parameter(Mandatory)]$Prepared,
            [Parameter(Mandatory)]
            [Collections.IDictionary]$Config,
            [Parameter(Mandatory)][string]$Body,
            [ValidateSet(
                'reviewer',
                'human',
                'ambiguous')]
            [string]$Identity = 'reviewer',
            [int]$ThreadId = 600,
            [int]$CommentId = 601,
            [string]$Path = '',
            [int]$Line = 0
        )
        $thread = [ordered]@{
            id = $ThreadId
            status = 'active'
            isDeleted = $false
            comments = @([ordered]@{
                    id = $CommentId
                    commentType = 'text'
                    content = $Body
                    author =
                        Get-SyntheticDiscussionAuthor `
                            -Config $Config `
                            -Identity $Identity
                })
        }
        if ($Path) {
            $thread['threadContext'] =
                [ordered]@{
                    filePath = '/' + $Path.TrimStart('/')
                    rightFileStart =
                        [ordered]@{
                            line = $Line
                            offset = 1
                        }
                    rightFileEnd =
                        [ordered]@{
                            line = $Line
                            offset = 1
                        }
                }
            $thread['pullRequestThreadContext'] =
                [ordered]@{
                    changeTrackingId = 7
                    iterationContext =
                        [ordered]@{
                            firstComparingIteration = 3
                            secondComparingIteration = 3
                        }
                }
        }
        $discussions =
            $Prepared.Intake.
                transientSnapshots['42'].discussions
        $discussions.threads =
            @($discussions.threads) + @($thread)
        $discussions.count =
            @($discussions.threads).Count
    }

    function Set-SyntheticTopLevelDiscussion {
        param(
            [Parameter(Mandatory)]$Prepared,
            [Parameter(Mandatory)]
            [Collections.IDictionary]$Config,
            [Parameter(Mandatory)][string]$Body,
            [ValidateSet(
                'reviewer',
                'human',
                'ambiguous')]
            [string]$Identity = 'reviewer'
        )
        $Prepared.Intake.
            transientSnapshots['42'].
            discussions = [ordered]@{
                count = 0
                threads = @()
            }
        Add-SyntheticDiscussion `
            -Prepared $Prepared `
            -Config $Config `
            -Body $Body `
            -Identity $Identity `
            -ThreadId 500 -CommentId 501
    }

    function Get-SyntheticCurrentPrTemplateComment {
        param(
            [Parameter(Mandatory)]
            [Collections.IDictionary]$Config,
            [Parameter(Mandatory)]$Prepared,
            [Parameter(Mandatory)][string]$Name
        )
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $Config `
                -Prepared $Prepared `
                -Name $Name
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable -Depth 64
        $contract =
            New-OwnerAcquisitionContract `
                -RepositoryId $Prepared.Head.repositoryId `
                -ProjectId $Prepared.Head.projectId `
                -PullRequestId $Prepared.Head.pullRequestId `
                -SourceCommit $Prepared.Head.sourceCommit `
                -TargetCommit $Prepared.Head.targetCommit `
                -TargetRef $Prepared.Head.targetRef `
                -RuleRepositoryId (
                    $Config.contextualRule.repositoryId) `
                -RulePath $Config.contextualRule.path `
                -RuleCommit $Config.toolkit.head `
                -RuleSection $Config.contextualRule.section `
                -RuleHash $Config.contextualRule.hash `
                -RuleLength $Config.contextualRule.length `
                -ConfigId contextual-test `
                -ConfigDigest (
                    'v1:sha256:' + ('7' * 64)) `
                -CapabilityId $Config.capability.id `
                -CapabilityDigest (
                    'v1:sha256:' +
                    $Config.capability.
                        implementationSha256)
        $finding = $observation.findings[0]
        $marker =
            Get-ContextualConventionMarkerKey `
                -Contract $contract -Finding $finding
        return [pscustomobject]@{
            Marker = $marker
            Body =
                Format-ContextualConventionComment `
                    -Contract $contract `
                    -Finding $finding `
                    -MarkerKey $marker
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
    It 'carries the generic catch rule through acquisition, exact source binding, formatter, and reviewer readback' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared = New-ContextualPreparedIntake -Content (
            'class C { void M() { try {} catch (System.Exception cleanupScheduleException) when (!cleanupScheduleException.IsFatal()) {} } }')
        $result = Invoke-SyntheticContextualBridge -Config $config `
            -Prepared $prepared -Name generic-catch
        $result.state | Should -BeExactly completed
        $configPath = Join-Path $TestDrive 'generic-catch-config.json'
        $config | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $configPath
        $evidence = Read-ApprovedOwnerV2Evidence `
            -StateRoot (Join-Path $TestDrive 'generic-catch-state') `
            -Identity $result.records[0].identity -RepoRoot $repoRoot `
            -ToolkitConfigPath $configPath -Delivery contextual-conventions
        $finding = @($evidence.Observation.findings |
            Where-Object ruleId -CEQ generic-exception-naming)[0]
        $finding.anchor.path | Should -BeExactly src/Checks.cs
        $finding.anchor.line | Should -Be 1
        $finding.anchor.symbol | Should -BeExactly cleanupScheduleException
        $finding.binding.source.representation.path |
            Should -BeExactly src/Checks.cs
        $finding.binding.source.representation.startLine | Should -Be 1
        $finding.binding.source.sha256 | Should -Match '^[0-9a-f]{64}$'
        $proposal = Get-ApprovedOwnerV2Proposal -Evidence $evidence `
            -Finding $finding -Delivery contextual-conventions
        $proposal.classification | Should -BeExactly wouldCreate
        $proposal.body | Should -Match 'System\.Exception'
        $proposal.body | Should -Match 'update its uses'
        $proposal.body | Should -Match 'generic-exception-naming'
        $proposal.scope | Should -BeExactly changed-line
        $readback = New-ContextualUpgradeRecognitionCase
        $readback.Thread.anchor.path = $finding.anchor.path
        $readback.Thread.anchor.line = $finding.anchor.line
        $readback.Thread.comments[0].body = $proposal.body
        $observation = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $evidence.Observation -Contract $evidence.Contract `
            -Snapshot $readback.Snapshot
        $current = @($observation.findings |
            Where-Object ruleId -CEQ generic-exception-naming)[0]
        $current.reconciliation.classification | Should -BeExactly noOp
        $current.reconciliation.reason | Should -BeExactly exact-current-comment
        $observation.effects.providerWrites | Should -Be 0
        $observation.execution.modelStarts | Should -Be 0
    }

    It 'requires naming-specific current human coverage for <Mode>' -TestCases @(
        @{ Mode = 'covered'; Expected = 'humanCovered' }
        @{ Mode = 'unrelated'; Expected = 'unknown' }
        @{ Mode = 'wrong-variable'; Expected = 'unknown' }
        @{ Mode = 'negated'; Expected = 'unknown' }
        @{ Mode = 'reviewer-unmarked'; Expected = 'unknown' }
        @{ Mode = 'ambiguous-author'; Expected = 'unknown' }
        @{ Mode = 'wrong-line'; Expected = 'wouldCreate' }
        @{ Mode = 'wrong-head'; Expected = 'wouldCreate' }
        @{ Mode = 'outdated'; Expected = 'wouldCreate' }
        @{ Mode = 'resolved'; Expected = 'wouldCreate' }
        @{ Mode = 'deleted'; Expected = 'wouldCreate' }
        @{ Mode = 'cross-rule-marker'; Expected = 'unknown' }
    ) {
        param($Mode, $Expected)
        $case = New-ContextualUpgradeRecognitionCase
        $case.Observation.findings[0].ruleId = 'generic-exception-naming'
        $case.Observation.findings[0].anchor.symbol = 'cleanupScheduleException'
        $comment = $case.Thread.comments[0]
        $comment.body = 'Rename the new generic catch variable cleanupScheduleException to ex and update its uses.'
        $comment.reviewerOwned = $false
        $comment.reviewerIdentityState = 'foreign'
        switch ($Mode) {
            unrelated { $comment.body = 'Log cleanupScheduleException once in this catch.' }
            wrong-variable { $comment.body = 'Rename the generic catch variable otherException to ex.' }
            negated { $comment.body = "Do not rename generic catch variable cleanupScheduleException to ex." }
            reviewer-unmarked {
                $comment.reviewerOwned = $true
                $comment.reviewerIdentityState = 'matched'
            }
            ambiguous-author { $comment.reviewerIdentityState = 'ambiguous' }
            wrong-line { $case.Thread.anchor.line++ }
            wrong-head { $case.Thread.sourceCommit = '0' * 40 }
            outdated { $case.Thread.isOutdated = $true }
            resolved { $case.Thread.status = 'fixed' }
            deleted { $case.Thread.isDeleted = $true }
            cross-rule-marker {
                $comment.body += "`n<!-- devpilot-named-areequal:v1:$('9' * 64) -->"
            }
        }
        $result = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $case.Observation -Contract $case.Contract -Snapshot $case.Snapshot
        $result.findings[0].reconciliation.classification | Should -BeExactly $Expected
        $result.effects.providerWrites | Should -Be 0
    }

    It 'does not turn unsupported catch binding into a complete compliant evaluation' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared = New-ContextualPreparedIntake -Content (
            'class C { void M() { try {} catch (UnknownException other) {} } }')
        $result = Invoke-SyntheticContextualBridge -Config $config `
            -Prepared $prepared -Name generic-catch-unknown
        $observation = Get-Content -LiteralPath $result.outcomes[0].observationPath `
            -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        @($observation.findings |
            Where-Object ruleId -CEQ generic-exception-naming) | Should -HaveCount 0
        @($observation.outcomes | Where-Object {
                $_.ruleId -ceq 'generic-exception-naming' -and $_.state -ceq 'unknown'
            }) | Should -HaveCount 1
        $observation.counts.unknown | Should -BeGreaterThan 0
        $observation.effects.providerWrites | Should -Be 0
    }

    It 'keeps independent contextual findings deliverable beside <Mode>' -TestCases @(
        @{ Mode = 'unrelated-source-condition'; Catch = $false; Helper = '' }
        @{ Mode = 'unrelated-snapshot-condition'; Catch = $true; Helper = "#if DEBUG`n#endif`nclass Helper {}" }
        @{ Mode = 'generated-snapshot-condition'; Catch = $true; Helper = "// <auto-generated>`nclass Helper { void M() {`n#if DEBUG`nSystem.Console.WriteLine(0);`n#endif`n} }" }
        @{ Mode = 'attributed-snapshot-condition'; Catch = $true; Helper = "[CompilerGenerated] class Helper { void M() {`n#if DEBUG`nSystem.Console.WriteLine(0);`n#endif`n} }" }
    ) {
        param($Mode, $Catch, $Helper)
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $content = if ($Catch) {
            'class C { void M() { try {} catch (System.Exception cleanup) when (!cleanup.IsFatal()) {} } }'
        }
        else {
            @'
class C { bool Equal(string a, string b) { return a == b; } void Trace() {
#if DEBUG
    System.Console.WriteLine(0);
#endif
} }
'@
        }
        $prepared = New-ContextualPreparedIntake -Content $content
        if ($Helper) {
            $helperDigest = Get-ContextualTestTextDigest $Helper
            $prepared.Intake.transientSnapshots['42'].changes.entries += [ordered]@{
                changeTrackingId = 8
                path = 'src/Helper.cs'
                changeType = 'edit'
                state = 'complete'
                spans = @(@{ startLine = 1; endLine = 1; state = 'complete'; sourceDigest = $helperDigest })
                content = $Helper
                byteLength = [Text.Encoding]::UTF8.GetByteCount($Helper)
                sourceDigest = $helperDigest
            }
            $prepared.Intake.transientSnapshots['42'].changes.changedFiles = 2
            $prepared.Intake.transientSnapshots['42'].changes.changedLines = 2
        }
        $result = Invoke-SyntheticContextualBridge -Config $config `
            -Prepared $prepared -Name "review-$Mode"
        $result.state | Should -BeExactly completed
        $observation = Get-Content -LiteralPath $result.outcomes[0].observationPath `
            -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        $observation.counts.unknown | Should -Be 0
        $observation.findingsComplete | Should -BeTrue
        $ruleId = if ($Catch) { 'generic-exception-naming' } else { 'explicit-string-comparison' }
        $finding = @($observation.findings | Where-Object ruleId -CEQ $ruleId)[0]
        $finding.reconciliation.classification | Should -BeExactly wouldCreate
        $observation.execution.modelStarts | Should -Be 0
        $observation.effects.providerWrites | Should -Be 0
    }

    It 'preserves binding evidence without blocking independent findings for <Mode>' -TestCases @(
        @{ Mode = 'generated-shadow'; Type = 'Exception'; Helper = 'class Exception : System.Exception {}'; Path = 'src/Helper.g.cs' }
        @{ Mode = 'generated-specialized'; Type = 'ApiException'; Helper = '[GeneratedCode("tool", "1")] class ApiException : System.Exception {}'; Path = 'src/Helper.cs' }
        @{ Mode = 'conditional-body-record'; Type = 'System.InvalidOperationException'; Helper = "class Helper { void M() {`n#if DEBUG`nvar record = 1; System.Action a = delegate {};`n#endif`n} }"; Path = 'src/Helper.cs' }
    ) {
        param($Mode, $Type, $Helper, $Path)
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $content = "using System; class C { bool Equal(string a, string b) { return a == b; } void M() { try {} catch ($Type customException) when (!customException.IsFatal()) {} } }"
        $prepared = New-ContextualPreparedIntake -Content $content
        $helperDigest = Get-ContextualTestTextDigest $Helper
        $prepared.Intake.transientSnapshots['42'].changes.entries += [ordered]@{
            changeTrackingId = 8
            path = $Path
            changeType = 'edit'
            state = 'complete'
            spans = @(@{ startLine = 1; endLine = 1; state = 'complete'; sourceDigest = $helperDigest })
            content = $Helper
            byteLength = [Text.Encoding]::UTF8.GetByteCount($Helper)
            sourceDigest = $helperDigest
        }
        $prepared.Intake.transientSnapshots['42'].changes.changedFiles = 2
        $prepared.Intake.transientSnapshots['42'].changes.changedLines = 2
        $result = Invoke-SyntheticContextualBridge -Config $config `
            -Prepared $prepared -Name "residual-$Mode"
        $result.state | Should -BeExactly completed
        $observation = Get-Content -LiteralPath $result.outcomes[0].observationPath `
            -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        $observation.counts.unknown | Should -Be 0
        $observation.findingsComplete | Should -BeTrue
        @($observation.findings | Where-Object ruleId -CEQ generic-exception-naming) |
            Should -HaveCount 0
        $finding = @($observation.findings | Where-Object ruleId -CEQ explicit-string-comparison)[0]
        $finding.reconciliation.classification | Should -BeExactly wouldCreate
        $observation.execution.modelStarts | Should -Be 0
        $observation.effects.providerWrites | Should -Be 0
    }

    It 'requires the contextual shared acquisition template authority switch to be literal true' {
        foreach ($value in @(
                $false,
                'true')) {
            $config =
                New-ContextualTestConfig
            $config.sharedAcquisition.
                includePullRequestTemplateAuthority =
                    $value
            {
                Invoke-ContextualConventionsCurrentPrBridge `
                    -Config $config `
                    -Provider {
                        throw 'not invoked'
                    } `
                    -StateRoot (
                        Join-Path $TestDrive `
                            "invalid-shared-$value") `
                    -ManifestPath (
                        Join-Path $TestDrive `
                            "invalid-shared-$value.json") `
                    -RepositoryRoot $repoRoot
            } | Should -Throw (
                '*exactly one fixed rule bundle*')
        }
    }

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
        $priorTwentyOne = @(
            (Get-Content -LiteralPath (
                Join-Path $repoRoot `
                    'src\DevPilot.OwnerCapability\Policy\contextual-conventions.v1.json') `
                -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 32).rules.id |
                    Where-Object {
                        [string]$_ -cnotin @(
                            'pr-template-compliance',
                            'generic-exception-naming')
                    })
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
                        $priorTwentyOne | Where-Object {
                            $_ -cnotin @('named-call-arguments',
                                'xml-summary-layout', 'duplicate-constant-declarations')
                        })
                },
                [ordered]@{
                    rule = [ordered]@{
                        hash =
                            'v1:sha256:6a7db82e68b407af4ed19aab4517973337592e757a32d5fa7a142b63ef75d22a'
                        length = 5205
                    }
                    unchangedRuleIds = @(
                        $priorTwentyOne | Where-Object {
                            $_ -cne 'named-call-arguments'
                        })
                },
                [ordered]@{
                    rule = [ordered]@{
                        hash =
                            'v1:sha256:9834f5ee38aefe532a9c2b5e05b90dd0f55faa8d87d743e2a650bb191c89506e'
                        length = 5399
                    }
                    unchangedRuleIds =
                        $priorTwentyOne
                },
                [ordered]@{
                    rule = [ordered]@{
                        hash =
                            'v1:sha256:e84ed0793dbabb4494a603fb445bea120af872b6df4477f2952148fc9bc3efac'
                        length = 6249
                    }
                    unchangedRuleIds = @(
                        $priorTwentyOne +
                        'pr-template-compliance')
                })
            currentRule = [ordered]@{
                hash =
                    (New-ContextualTestConfig).contextualRule.hash
                length =
                    (New-ContextualTestConfig).contextualRule.length
            }
        }
        @($compatibility.previousRules[0].unchangedRuleIds) | Should -HaveCount 18
        @($compatibility.previousRules[1].unchangedRuleIds) | Should -HaveCount 20
        @($compatibility.previousRules[2].unchangedRuleIds) | Should -HaveCount 21
        @($compatibility.previousRules[3].unchangedRuleIds) | Should -HaveCount 22
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
            },
            [ordered]@{
                ruleId =
                    'named-call-arguments'
                prior =
                    $compatibility.
                        previousRules[2].rule
                expected = 'noOp'
            },
            [ordered]@{
                ruleId =
                    'pr-template-compliance'
                prior =
                    $compatibility.
                        previousRules[2].rule
                expected = 'unknown'
            },
            [ordered]@{
                ruleId =
                    'pr-template-compliance'
                prior =
                    $compatibility.
                        previousRules[3].rule
                expected = 'noOp'
            })
        foreach ($entry in $compatibility.previousRules) {
            $cases += [ordered]@{
                ruleId = 'generic-exception-naming'
                prior = $entry.rule
                expected = 'unknown'
            }
        }
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
                    $case.Config.contextualRule.hash
                length =
                    $case.Config.contextualRule.length
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
            Should -Be @('src/Real.cs', 'src/Auto.g.cs')
        $result.entries[1].contextOnly | Should -BeTrue
        @($result.entries[1].spans) | Should -HaveCount 0
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

    It 'evaluates one synthetic PR-wide template violation with zero writes' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic change without required sections.'
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-violation
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $result.state | Should -BeExactly completed
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
        @($observation.findings) |
            Should -HaveCount 1
        $finding = $observation.findings[0]
        $finding.ruleId |
            Should -BeExactly pr-template-compliance
        $finding.anchor.scope |
            Should -BeExactly pull-request
        $finding.binding.scope |
            Should -BeExactly pull-request
        @($finding.missingSections) -join ',' |
            Should -BeExactly 'Problem,Solution,Validation'
        $finding.reconciliation.
            classification |
            Should -BeExactly wouldCreate
    }

    It 'evaluates PR-template metadata from a Named-only shared intake' {
        $namedConfig = New-ContextualTestConfig
        $namedConfig.enabled = $true
        $namedConfig.rules = @([ordered]@{
                id =
                    'bpm-named-areequal-arguments@1'
                capability =
                    'bpm-named-areequal-arguments@1'
            })
        $source =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description (
                    'Named shared acquisition missing sections.')
        $sourceValue = $source
        $namedProvider = {
            param($Operation, $Arguments)
            switch ($Operation) {
                Identity {
                    return [ordered]@{
                        id =
                            $namedConfig.expectedAccount.id
                        descriptor =
                            $namedConfig.expectedAccount.descriptor
                        uniqueName =
                            $namedConfig.expectedAccount.uniqueName
                    }
                }
                ListPage {
                    $items = if (
                        [int]$Arguments.skip -eq 0) {
                        @([ordered]@{
                                pullRequestId = 42
                                status = 'active'
                                isDraft = $false
                                targetRef =
                                    'refs/heads/master'
                            })
                    }
                    else { @() }
                    return [ordered]@{
                        items = @($items)
                        count = @($items).Count
                        totalCount = 1
                    }
                }
                Head {
                    return [ordered]@{} +
                        $sourceValue.Head
                }
                Changes {
                    return $sourceValue.Intake.
                        transientSnapshots['42'].
                        changes
                }
                Discussions {
                    return $sourceValue.Intake.
                        transientSnapshots['42'].
                        discussions
                }
                default {
                    throw "unexpected:$Operation"
                }
            }
        }.GetNewClosure()
        $shared =
            Invoke-ActivePrIntake `
                -Config $namedConfig `
                -Provider $namedProvider `
                -StateRoot (
                    Join-Path $TestDrive `
                        'named-shared-template-state') `
                -RepositoryRoot $repoRoot `
                -MaximumHeadsThisRun 1 `
                -IncludeTransientSnapshots -Run
        $sharedTemplateState =
            [string]$shared.
                transientSnapshots['42'].
                head.templateAuthority.state
        $contextualConfig =
            New-ContextualTestConfig
        $contextualConfig.enabled = $true
        $headProvider = {
            param($Head)
            return [ordered]@{} + $Head
        }
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $contextualConfig `
                -Prepared ([pscustomobject]@{
                    Intake = $shared
                    Head =
                        $source.Head
                }) `
                -Name named-shared-template-contextual `
                -HeadProvider $headProvider
        $result.state |
            Should -BeExactly completed `
                -Because (
                    $result |
                        ConvertTo-Json `
                            -Depth 16 -Compress)
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $namedConfig.rules[0].capability |
            Should -BeExactly `
                bpm-named-areequal-arguments@1
        $sharedTemplateState |
            Should -BeExactly complete
        $observation.findings[0].ruleId |
            Should -BeExactly pr-template-compliance
        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly wouldCreate
    }

    It 'reads PR-wide actionable partial evidence and exits disabled delivery with zero writes' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content (
                    'class C { void M() { try { X(); } catch (System.Exception ex) { Logger.Error(ex.Message); } } }') `
                -Description (
                    'Synthetic PR description without required sections.')
        Add-SyntheticDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body (
                "Existing other rule.`n`n" +
                "<!-- devpilot-named-areequal:v1:$('9' * 64) -->") `
            -Identity human `
            -Path src/Checks.cs -Line 1
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-approved-evidence
        $result.state |
            Should -BeExactly partial
        $identity =
            [string]$result.records[0].identity
        $configPath = Join-Path $TestDrive `
            'pr-template-approved-evidence-config.json'
        [IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json `
                -InputObject $config `
                -Depth 64),
            [Text.UTF8Encoding]::new($false))

        $evidence =
            Read-ApprovedOwnerV2Evidence `
                -StateRoot (
                    Join-Path $TestDrive `
                        'pr-template-approved-evidence-state') `
                -Identity $identity `
                -RepoRoot $repoRoot `
                -ToolkitConfigPath $configPath `
                -Delivery contextual-conventions
        $proposal =
            Get-ApprovedOwnerV2Proposal `
                -Evidence $evidence `
                -Finding (
                    @($evidence.Observation.findings |
                        Where-Object {
                            [string]$_.ruleId -ceq
                                'pr-template-compliance'
                        })[0]) `
                -Delivery contextual-conventions
        $deliveryRoot = Join-Path $TestDrive `
            'pr-template-disabled-delivery'
        $producer = Join-Path $repoRoot `
            'tools\Invoke-ContextualDeliveryBatchJson.ps1'
        $automatic = Join-Path $repoRoot `
            'tools\Invoke-AutomaticOwnerV2Delivery.ps1'
        $output = @(& $producer `
                -AutomaticDeliveryTool $automatic `
                -DeliveryRoot $deliveryRoot `
                -StateRoot (
                    Join-Path $TestDrive `
                        'pr-template-approved-evidence-state') `
                -Identity $identity `
                -ToolkitConfigPath $configPath `
                -AzureCliPath 'ignored' `
                -GitPath 'git' `
                -RepoRoot $repoRoot)
        $envelope =
            ($output -join "`n") |
                ConvertFrom-Json `
                    -AsHashtable -Depth 64

        $proposal.scope |
            Should -BeExactly pull-request
        $proposal.Contains('path') |
            Should -BeFalse
        $envelope.toolExitCode |
            Should -Be 0
        $envelope.result.health |
            Should -BeExactly disabled
        $envelope.result.providerWrites |
            Should -Be 0
        $envelope.result.modelWrites |
            Should -Be 0
        Test-Path -LiteralPath $deliveryRoot |
            Should -BeFalse
    }

    It 'withholds a PR-template finding when description metadata changes without a head change' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic missing sections.'
        $headProvider = {
            param($Head)
            $current = [ordered]@{} + $Head
            $current.description = @'
**Problem:**
Filled.
**Solution:**
Filled.
**Validation:**
Filled.
'@
            $current.descriptionDigest =
                Get-ContextualTestTextDigest `
                    $current.description
            return $current
        }
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-description-drift `
                -HeadProvider $headProvider

        $result.state | Should -BeExactly partial
        $result.providerWrites | Should -Be 0
        @($result.outcomes | Where-Object {
                [string]$_.reason -ceq
                    'post-evaluation-head-refused'
            }) | Should -HaveCount 1
    }

    It 'withholds a PR-template finding when effective template content drifts' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic missing sections.'
        $headProvider = {
            param($Head)
            $current =
                $Head | ConvertTo-Json `
                    -Depth 16 -Compress |
                    ConvertFrom-Json `
                        -AsHashtable -Depth 16
            $current.templateAuthority.content +=
                "`nSynthetic template change."
            $current.templateAuthority.contentDigest =
                Get-ContextualTestTextDigest `
                    $current.templateAuthority.content
            $current.templateAuthority.blob =
                '8' * 40
            return $current
        }
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-content-drift `
                -HeadProvider $headProvider

        $result.state | Should -BeExactly partial
        $result.providerWrites | Should -Be 0
        @($result.outcomes | Where-Object {
                [string]$_.reason -ceq
                    'post-evaluation-head-refused'
            }) | Should -HaveCount 1
    }

    It 'treats a current top-level human PR-template request as coverage' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic invalid description.'
        $prepared.Intake.
            transientSnapshots['42'].
            discussions = [ordered]@{
                count = 1
                threads = @([ordered]@{
                        id = 300
                        status = 'active'
                        isDeleted = $false
                        comments = @([ordered]@{
                                id = 301
                                commentType = 'text'
                                content =
                                    'Please complete the PR template with Problem, Solution, and Validation.'
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
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-human
        $result.state |
            Should -BeExactly completed `
                -Because (
                    $result.outcomes |
                        ConvertTo-Json `
                            -Depth 16 -Compress)
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly humanCovered `
                -Because (
                    $observation.findings[0].
                        reconciliation |
                        ConvertTo-Json -Compress)
        $result.providerWrites |
            Should -Be 0
    }

    It 'reuses one active reviewer PR-template comment when prior missing sections cover the narrowed finding' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description @'
**Problem:**
Synthetic problem is filled.
'@
        $prior =
            New-SyntheticPrTemplateReviewerComment `
                -Config $config `
                -Head $prepared.Head `
                -MissingSections @(
                    'Problem',
                    'Solution',
                    'Validation')
        Set-SyntheticTopLevelDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body $prior.Body `
            -Identity reviewer
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-prior-narrowed
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        @($observation.findings[0].
                missingSections) -join ',' |
            Should -BeExactly 'Solution,Validation'
        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly noOp
        $observation.findings[0].
            reconciliation.reason |
            Should -BeExactly `
                prior-pr-template-review-covers-current-missing-sections
        $result.providerWrites | Should -Be 0
    }

    It 'withholds a disjoint prior reviewer PR-template comment' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description @'
**Problem:**
Synthetic problem is filled.
'@
        $prior =
            New-SyntheticPrTemplateReviewerComment `
                -Config $config `
                -Head $prepared.Head `
                -MissingSections @(
                    'Problem')
        Set-SyntheticTopLevelDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body $prior.Body `
            -Identity reviewer
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-prior-disjoint
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly unknown
        $observation.findings[0].
            reconciliation.reason |
            Should -BeExactly `
                prior-pr-template-review-coverage-unproven
        $result.providerWrites | Should -Be 0
    }

    It 'withholds a prior reviewer PR-template comment from a different template blob' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description @'
**Problem:**
Synthetic problem is filled.
'@
        $priorTemplate =
            $prepared.Head.templateAuthority |
                ConvertTo-Json -Depth 16 -Compress |
                ConvertFrom-Json `
                    -AsHashtable -Depth 16
        $priorTemplate.blob = '8' * 40
        $priorTemplate.contentDigest =
            'v1:sha256:' + ('9' * 64)
        $prior =
            New-SyntheticPrTemplateReviewerComment `
                -Config $config `
                -Head $prepared.Head `
                -MissingSections @(
                    'Problem',
                    'Solution',
                    'Validation') `
                -TemplateAuthority $priorTemplate
        Set-SyntheticTopLevelDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body $prior.Body `
            -Identity reviewer
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-prior-template-drift
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly unknown
        $observation.findings[0].
            reconciliation.reason |
            Should -BeExactly `
                prior-pr-template-review-coverage-unproven
        $result.providerWrites | Should -Be 0
    }

    It 'withholds an ambiguous top-level reviewer identity without an exact marker' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic invalid description.'
        Set-SyntheticTopLevelDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body 'Synthetic ambiguous discussion.' `
            -Identity ambiguous
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-ambiguous-identity
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly unknown
        $result.providerWrites | Should -Be 0
    }

    It 'withholds partial human PR-template coverage of different missing sections' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description @'
**Problem:**
Synthetic problem is filled.
'@
        Set-SyntheticTopLevelDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body (
                'Per the PR template, please fill out the Problem section.') `
            -Identity human
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-partial-human
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        @($observation.findings[0].
                missingSections) -join ',' |
            Should -BeExactly 'Solution,Validation'
        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly unknown
        $result.providerWrites | Should -Be 0
    }

    It 'ignores an active code-anchored contextual rule comment for a new PR-template finding' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic invalid description.'
        Add-SyntheticDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body (
                "**exception-logging**`n`nExisting code review." +
                "`n`n<!-- devpilot-contextual-convention:v1:$('a' * 64) -->") `
            -Identity reviewer `
            -Path src/Checks.cs -Line 1
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-code-comment-create
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly wouldCreate
        $observation.findingsComplete |
            Should -BeTrue
    }

    It 'keeps an exact current PR-template marker no-op beside an unrelated code marker' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $first =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic invalid description.'
        $current =
            Get-SyntheticCurrentPrTemplateComment `
                -Config $config `
                -Prepared $first `
                -Name pr-template-exact-code-first
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic invalid description.'
        Set-SyntheticTopLevelDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body $current.Body `
            -Identity reviewer
        Add-SyntheticDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body (
                "**exception-logging**`n`nExisting code review." +
                "`n`n<!-- devpilot-contextual-convention:v1:$('b' * 64) -->") `
            -Identity reviewer `
            -ThreadId 610 -CommentId 611 `
            -Path src/Checks.cs -Line 1
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-exact-code-second
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly noOp
        $observation.findingsComplete |
            Should -BeTrue
    }

    It 'keeps a proven prior reviewer no-op beside an unrelated code marker' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description @'
**Problem:**
Synthetic problem is filled.
'@
        $prior =
            New-SyntheticPrTemplateReviewerComment `
                -Config $config `
                -Head $prepared.Head `
                -MissingSections @(
                    'Problem',
                    'Solution',
                    'Validation')
        Set-SyntheticTopLevelDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body $prior.Body `
            -Identity reviewer
        Add-SyntheticDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body (
                "**exception-logging**`n`nExisting code review." +
                "`n`n<!-- devpilot-contextual-convention:v1:$('c' * 64) -->") `
            -Identity reviewer `
            -ThreadId 620 -CommentId 621 `
            -Path src/Checks.cs -Line 1
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-prior-code
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly noOp
        $observation.findingsComplete |
            Should -BeTrue
    }

    It 'keeps a proven reviewer no-op despite a separate partial human comment' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $first =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic invalid description.'
        $current =
            Get-SyntheticCurrentPrTemplateComment `
                -Config $config `
                -Prepared $first `
                -Name pr-template-reviewer-partial-first
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic invalid description.'
        Set-SyntheticTopLevelDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body $current.Body `
            -Identity reviewer
        Add-SyntheticDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body (
                'Per the PR template, please fill out the Problem section.') `
            -Identity human `
            -ThreadId 630 -CommentId 631
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-reviewer-partial-second
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly noOp
    }

    It 'keeps full human coverage despite a separate partial human comment' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic invalid description.'
        Set-SyntheticTopLevelDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body (
                'Please complete the PR template with Problem, Solution, and Validation.') `
            -Identity human
        Add-SyntheticDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body (
                'Per the PR template, please fill out the Problem section.') `
            -Identity human `
            -ThreadId 640 -CommentId 641
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-human-full-partial
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly humanCovered
    }

    It 'withholds a top-level markerless reviewer-owned comment' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic invalid description.'
        Set-SyntheticTopLevelDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body 'Reviewer-owned top-level text without a marker.' `
            -Identity reviewer
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-markerless-reviewer
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly unknown
    }

    It 'withholds a top-level comment carrying another devpilot marker' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic invalid description.'
        Set-SyntheticTopLevelDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body (
                "Other automation.`n`n" +
                "<!-- devpilot-named-areequal:v1:$('d' * 64) -->") `
            -Identity human
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-other-marker
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly unknown
    }

    It 'withholds a misplaced code-anchored PR-template comment' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic invalid description.'
        $prior =
            New-SyntheticPrTemplateReviewerComment `
                -Config $config `
                -Head $prepared.Head `
                -MissingSections @(
                    'Problem',
                    'Solution',
                    'Validation')
        Add-SyntheticDiscussion `
            -Prepared $prepared `
            -Config $config `
            -Body $prior.Body `
            -Identity reviewer `
            -Path src/Checks.cs -Line 1
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-misplaced-code
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly unknown
    }

    It 'keeps one own marker across invalid description and identical-template commit changes' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $first =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic first invalid description.'
        $firstResult =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $first `
                -Name pr-template-own-first
        $firstObservation =
            Get-Content -LiteralPath (
                [string]$firstResult.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64
        $contract =
            New-OwnerAcquisitionContract `
                -RepositoryId $first.Head.repositoryId `
                -ProjectId $first.Head.projectId `
                -PullRequestId $first.Head.pullRequestId `
                -SourceCommit $first.Head.sourceCommit `
                -TargetCommit $first.Head.targetCommit `
                -TargetRef $first.Head.targetRef `
                -RuleRepositoryId (
                    $config.contextualRule.repositoryId) `
                -RulePath $config.contextualRule.path `
                -RuleCommit $config.toolkit.head `
                -RuleSection (
                    $config.contextualRule.section) `
                -RuleHash $config.contextualRule.hash `
                -RuleLength $config.contextualRule.length `
                -ConfigId contextual-test `
                -ConfigDigest (
                    'v1:sha256:' + ('7' * 64)) `
                -CapabilityId $config.capability.id `
                -CapabilityDigest (
                    'v1:sha256:' +
                    $config.capability.
                        implementationSha256)
        $firstFinding =
            $firstObservation.findings[0]
        $marker =
            Get-ContextualConventionMarkerKey `
                -Contract $contract `
                -Finding $firstFinding
        $body =
            Format-ContextualConventionComment `
                -Contract $contract `
                -Finding $firstFinding `
                -MarkerKey $marker
        $second =
            New-ContextualPreparedIntake `
                -Content 'class C { }' `
                -Description 'Synthetic second invalid description.'
        $second.Head.templateAuthority.
            configurationCommit = '9' * 40
        $second.Intake.heads[0].
            declaration = $second.Head
        $second.Intake.
            transientSnapshots['42'].head =
                $second.Head
        $second.Intake.
            transientSnapshots['42'].
            discussions = [ordered]@{
                count = 1
                threads = @([ordered]@{
                        id = 400
                        status = 'active'
                        isDeleted = $false
                        comments = @([ordered]@{
                                id = 401
                                commentType = 'text'
                                content = $body
                                author = [ordered]@{
                                    id =
                                        $config.expectedAccount.id
                                    descriptor =
                                        $config.expectedAccount.descriptor
                                    uniqueName =
                                        $config.expectedAccount.uniqueName
                                }
                            })
                    })
            }
        $secondResult =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $second `
                -Name pr-template-own-second
        $secondObservation =
            Get-Content -LiteralPath (
                [string]$secondResult.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64

        $secondObservation.findings[0].
            reconciliation.classification |
            Should -BeExactly noOp
        (Get-ContextualConventionMarkerKey `
                -Contract $contract `
                -Finding $secondObservation.findings[0]) |
            Should -BeExactly $marker
        $secondResult.providerWrites |
            Should -Be 0
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
