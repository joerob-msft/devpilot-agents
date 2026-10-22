#requires -Version 7.0

Describe 'Copyright header bridge and create-only preflight' {
    BeforeAll {
        function New-CopyrightBridgeCase {
            param([switch]$NoCurrentSpans)
            $config = New-ContextualTestConfig
            $config.enabled = $true
            $content = "namespace Tests`n{`n    class C`n    {`n        int M() => 2;`n    }`n}"
            $prepared = New-ContextualPreparedIntake -Content $content
            $entry = $prepared.Intake.transientSnapshots['42'].changes.entries[0]
            $entry.spans[0].startLine = 5
            $entry.spans[0].endLine = 5
            $entry['fileHeader'] = Get-ContextualCopyrightHeaderEvidence `
                -Path $entry.path -ChangeType edit -Content $content `
                -TargetContent ($content.Replace('=> 2', '=> 1')) `
                -SourceCommit $prepared.Head.sourceCommit -TargetCommit $prepared.Head.targetCommit
            if ($NoCurrentSpans) {
                $entry.spans = @()
                $prepared.Intake.transientSnapshots['42'].changes.changedLines = 0
            }
            return [pscustomobject]@{ Config = $config; Prepared = $prepared }
        }

        function Get-CopyrightObservation {
            param($Case, [string]$Name)
            $prepared = [pscustomobject]@{
                Head = $Case.Prepared.Head
                Intake = $Case.Prepared.Intake | ConvertTo-Json -Depth 64 | ConvertFrom-Json -AsHashtable -Depth 64
            }
            $result = Invoke-SyntheticContextualBridge -Config $Case.Config -Prepared $prepared -Name $Name
            $result.providerWrites | Should -Be 0
            $result.modelWrites | Should -Be 0
            $result.records | Should -HaveCount 1
            return Get-Content -LiteralPath $result.outcomes[0].observationPath -Raw |
                ConvertFrom-Json -AsHashtable -Depth 64
        }
    }

    It 'carries a pre-existing header finding through the full bridge without pretending line 1 changed' {
        $case = New-CopyrightBridgeCase
        $observation = Get-CopyrightObservation $case copyright-pre-existing
        $finding = @($observation.findings | Where-Object ruleId -CEQ file-copyright-header)[0]
        $finding.anchor.scope | Should -BeExactly file-header
        $finding.anchor.line | Should -Be 1
        $finding.fileHeader.origin | Should -BeExactly pre-existing
        $finding.reconciliation.classification | Should -BeExactly wouldCreate
        $observation | ConvertTo-Json -Depth 64 |
            Test-Json -SchemaFile "$repoRoot\src\OwnerObserver\schemas\owner-observation.v1.json" |
            Should -BeTrue
        $contract = (New-ContextualUpgradeRecognitionCase).Contract
        $evidence = [pscustomobject]@{
            Contract = $contract
            Declaration = @{ capability = @{ id = 'bpm-contextual-conventions@1' } }
        }
        $proposal = Get-ApprovedOwnerV2Proposal -Evidence $evidence -Finding $finding -Delivery contextual-conventions
        $proposal.scope | Should -BeExactly file-header
        $proposal.fileHeader.origin | Should -BeExactly pre-existing
        $proposal.body | Should -Match 'pre-existing, nonblocking convention issue'
        $proposal.body | Should -Match '\*\*File-header location:\*\*'
        $proposal.body | Should -Not -Match '\*\*Changed-line occurrences:\*\*'
        $proposal.body | Should -Not -Match 'Changed code:'
        $upgrade = New-ContextualUpgradeRecognitionCase
        $evidence | Add-Member -NotePropertyName Observation -NotePropertyValue $observation
        $live = [pscustomobject]@{
            PullRequest = $case.Prepared.Head
            ProviderBinding = @{}
            Reviewer = $case.Config.expectedAccount
            Snapshot = $upgrade.Snapshot
            Anchors = @([ordered]@{
                scope = 'file-header'
                path = $proposal.path
                startLine = 1
                endLine = 1
                changeTrackingId = 7
                iterationId = $upgrade.Snapshot.CurrentIterationId
                fileHeader = $proposal.fileHeader
            })
        }
        $approval = @{
            subject = $case.Prepared.Head
            provider = @{}
            operator = $case.Config.expectedAccount
        }
        $preflight = @{
            Evidence = $evidence
            Approval = $approval
            Live = $live
            Selections = @($proposal)
            ExpectedSnapshotSha256 = $upgrade.Snapshot.Digest.Substring(10)
            Delivery = 'contextual-conventions'
        }
        { Assert-ApprovedOwnerV2LiveRead @preflight } | Should -Not -Throw
        $live.Anchors[0].fileHeader =
            $proposal.fileHeader | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable
        $live.Anchors[0].fileHeader.targetDigest = 'v1:sha256:' + ('0' * 64)
        { Assert-ApprovedOwnerV2LiveRead @preflight } | Should -Throw '*source/target header binding changed*'
        $live.Anchors = @()
        { Assert-ApprovedOwnerV2LiveRead @preflight } | Should -Throw
    }

    It 'handles a changed file with no current-line span without enabling any old rule at line 1' {
        $case = New-CopyrightBridgeCase -NoCurrentSpans
        $observation = Get-CopyrightObservation $case copyright-no-current-lines
        $observation.findings | Should -HaveCount 1
        $observation.findings[0].ruleId | Should -BeExactly file-copyright-header
        $observation.findings[0].anchor.scope | Should -BeExactly file-header
    }

    It 'treats a markerless reviewer-owned copyright request at lines 2-4 as UNKNOWN, never humanCovered or a duplicate create' {
        $case = New-CopyrightBridgeCase
        Add-SyntheticDiscussion -Prepared $case.Prepared -Config $case.Config -Identity reviewer `
            -Path src/Checks.cs -Line 2 `
            -Body 'Add the standard copyright header to this test file. This omission is pre-existing and nonblocking.'
        $observation = Get-CopyrightObservation $case copyright-markerless-reviewer
        $finding = @($observation.findings | Where-Object ruleId -CEQ file-copyright-header)[0]
        $finding.reconciliation.classification | Should -BeExactly unknown
        $observation.effects.dedupe.wouldCreate | Should -Be 0
        $observation.effects.dedupe.humanCovered | Should -Be 0
    }

    It 'recognizes a disclosed distinct human copyright request on the same changed file' {
        $case = New-CopyrightBridgeCase
        Add-SyntheticDiscussion -Prepared $case.Prepared -Config $case.Config -Identity human `
            -Path src/Checks.cs -Line 2 -Body 'Please add the standard copyright header before the namespace.'
        $observation = Get-CopyrightObservation $case copyright-distinct-human
        $finding = @($observation.findings | Where-Object ruleId -CEQ file-copyright-header)[0]
        $finding.reconciliation.classification | Should -BeExactly humanCovered `
            -Because ($finding.reconciliation | ConvertTo-Json -Depth 16 -Compress)
    }

    It 'reconciles an exact current reviewer comment as noOp without a second create' {
        $case = New-CopyrightBridgeCase
        $first = Get-CopyrightObservation $case copyright-first
        $finding = @($first.findings | Where-Object ruleId -CEQ file-copyright-header)[0]
        $contract = (New-ContextualUpgradeRecognitionCase).Contract
        $marker = Get-ContextualConventionMarkerKey -Contract $contract -Finding $finding
        $body = Format-ContextualConventionComment -Contract $contract -Finding $finding -MarkerKey $marker
        $typed = New-ContextualUpgradeRecognitionCase
        $typed.Thread.anchor.line = 1
        $typed.Thread.comments[0].body = $body
        $resolved = Resolve-OwnerV2DiscussionReconciliation -Observation $first -Contract $contract `
            -Snapshot $typed.Snapshot
        $resolved.findings[0].reconciliation.classification | Should -BeExactly noOp
        Add-SyntheticDiscussion -Prepared $case.Prepared -Config $case.Config -Identity reviewer `
            -Path src/Checks.cs -Line 1 -Body $body
        $second = Get-CopyrightObservation $case copyright-second
        $finding = @($second.findings | Where-Object ruleId -CEQ file-copyright-header)[0]
        $finding.reconciliation.classification | Should -BeExactly noOp `
            -Because ($finding.reconciliation | ConvertTo-Json -Depth 16 -Compress)
        $second.effects.dedupe.wouldCreate | Should -Be 0
    }

    It 'evaluates multiple files independently and does not scan outside the changed inventory' {
        $case = New-CopyrightBridgeCase
        $changes = $case.Prepared.Intake.transientSnapshots['42'].changes
        $second = $changes.entries[0] | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable
        $second.path = 'src/Second.cs'
        $second.changeTrackingId = 8
        $second.fileHeader.path = $second.path
        $changes.entries += $second
        $changes.changedFiles = 2
        $changes.changedLines = 2
        $observation = Get-CopyrightObservation $case copyright-multiple
        @($observation.findings | Where-Object ruleId -CEQ file-copyright-header) | Should -HaveCount 2
        @($observation.findings.anchor.path | Sort-Object -Unique) -join ',' |
            Should -BeExactly 'src/Checks.cs,src/Second.cs'
    }

    It 'refuses <Case> header marker evidence without creating a duplicate' -TestCases @(
        @{ Case = 'a foreign copied'; Identity = 'human'; Path = 'src/Checks.cs'; Suffix = '' },
        @{ Case = 'an edited reviewer'; Identity = 'reviewer'; Path = 'src/Checks.cs'; Suffix = ' edited' },
        @{ Case = 'a moved reviewer'; Identity = 'reviewer'; Path = 'src/Elsewhere.cs'; Suffix = '' }
    ) {
        param($Case, $Identity, $Path, $Suffix)
        $fixture = New-CopyrightBridgeCase
        $first = Get-CopyrightObservation $fixture "copyright-negative-first-$Identity-$($Path.GetHashCode())-$($Suffix.Length)"
        $finding = @($first.findings | Where-Object ruleId -CEQ file-copyright-header)[0]
        $contract = (New-ContextualUpgradeRecognitionCase).Contract
        $marker = Get-ContextualConventionMarkerKey -Contract $contract -Finding $finding
        $body = Format-ContextualConventionComment -Contract $contract -Finding $finding -MarkerKey $marker
        Add-SyntheticDiscussion -Prepared $fixture.Prepared -Config $fixture.Config -Identity $Identity `
            -Path $Path -Line 1 -Body ($body + $Suffix)
        $second = Get-CopyrightObservation $fixture "copyright-negative-second-$Identity-$($Path.GetHashCode())-$($Suffix.Length)"
        $finding = @($second.findings | Where-Object ruleId -CEQ file-copyright-header)[0]
        $finding.reconciliation.classification | Should -BeExactly unknown
        $second.effects.dedupe.wouldCreate | Should -Be 0
        $second.effects.dedupe.humanCovered | Should -Be 0
    }
}

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
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1') -Force
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

    function New-ReusedStringPreparedIntake {
        param([switch]$Reverse, [switch]$SameProject, [switch]$ContextOnlyPeer)
        $prepared = New-ContextualPreparedIntake
        $entries = @(
            @{ path = 'src/A/Reader.cs'; content = @'
class Reader {
    string Old(Exception ex) => ex.Data["LegacyKey"] as string;
    string Credential(Exception ex) => ex.Data["CredentialHandle"] as string;
    string Group(Exception ex) => ex.Data["GroupIdentity"] as string;
    string Endpoint(Exception ex) => ex.Data["EndpointUri"] as string;
}
'@ },
            @{ path = 'src/B/Writer.cs'; content = @'
class Writer {
    void Old(Exception ex) { ex.Data["LegacyKey"] = null; }
    void Credential(Exception ex) { ex.Data["CredentialHandle"] = null; }
    void Group(Exception ex) { ex.Data["GroupIdentity"] = null; }
    void Endpoint(Exception ex) { ex.Data["EndpointUri"] = null; }
}
'@ }
        )
        $ordinal = 0
        foreach ($entry in $entries) {
            $ordinal++
            $projectContent = '<Project><PropertyGroup><LangVersion>latest</LangVersion></PropertyGroup></Project>'
            $entry.changeTrackingId = $ordinal
            $entry.changeType = 'edit'
            $entry.state = 'complete'
            $entry.sourceDigest = Get-ContextualTestTextDigest $entry.content
            $entry.byteLength = [Text.Encoding]::UTF8.GetByteCount($entry.content)
            $entry.spans = @(@{
                    startLine = 3; endLine = 5; state = 'complete'
                    sourceDigest = $entry.sourceDigest
                })
            $entry.projectContext = @{
                state = 'complete'
                path = $(if ($SameProject) { 'src/App.csproj' } else {
                    'src/' + $(if ($ordinal -eq 1) { 'A' } else { 'B' }) + '/App.csproj'
                })
                content = $projectContent
                byteLength = [Text.Encoding]::UTF8.GetByteCount($projectContent)
                sourceDigest = Get-ContextualTestTextDigest $projectContent
            }
            $target = $(if ($ordinal -eq 1) {
                'class Reader { string Old(Exception ex) => ex.Data["LegacyKey"] as string; }'
            } else {
                'class Writer { void Old(Exception ex) { ex.Data["LegacyKey"] = null; } }'
            })
            $entry.comparison=@{
                schemaVersion=1;state='complete';path=$entry.path;targetPath=$entry.path
                sourceCommit=$prepared.Head.sourceCommit;targetCommit=$prepared.Head.targetCommit
                sourceDigest=$entry.sourceDigest;targetDigest=(Get-ContextualTestTextDigest $target)
                byteLength=[Text.Encoding]::UTF8.GetByteCount($target);content=$target;targetState='present'
            }
            if ($ContextOnlyPeer -and $ordinal -eq 2) {
                $entry.spans = @()
                $entry.contextOnly = $true
            }
        }
        if ($Reverse) { [array]::Reverse($entries) }
        $changes = $prepared.Intake.transientSnapshots['42'].changes
        $changes.entries = $entries
        $changes.changedFiles = 2
        $changes.changedLines = $(if ($ContextOnlyPeer) { 3 } else { 6 })
        return $prepared
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
        $contract | Add-Member -NotePropertyName CommentPresentation -NotePropertyValue @{
            subjectProvider = $Config.subjectProvider
            ruleReferences = $Config['commentRuleReferences']
            ruleRepository = $Config['commentRuleRepository']
        }
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
        $contract | Add-Member -NotePropertyName CommentPresentation -NotePropertyValue @{
            subjectProvider = $config.subjectProvider
            ruleReferences = $config['commentRuleReferences']
            ruleRepository = $config['commentRuleRepository']
        }
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
        $proposal.body | Should -Match 'Name proven System.Exception catch variables ex'
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
        $result.state | Should -BeExactly $(if ($Mode -ceq 'generated-snapshot-condition') { 'completed' } else { 'partial' })
        $observation = Get-Content -LiteralPath $result.outcomes[0].observationPath `
            -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        @($observation.outcomes | Where-Object {
            $_.ruleId -ceq 'generic-exception-naming' -and $_.state -ceq 'unknown'
        }) | Should -HaveCount 0
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
        $result.state | Should -BeExactly $(if ($Mode -ceq 'conditional-body-record') { 'partial' } else { 'completed' })
        $observation = Get-Content -LiteralPath $result.outcomes[0].observationPath `
            -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        @($observation.outcomes | Where-Object {
            $_.ruleId -ceq 'generic-exception-naming' -and $_.state -ceq 'unknown'
        }) | Should -HaveCount 0
        @($observation.findings | Where-Object ruleId -CEQ generic-exception-naming) |
            Should -HaveCount 0
        $finding = @($observation.findings | Where-Object ruleId -CEQ explicit-string-comparison)[0]
        $finding.reconciliation.classification | Should -BeExactly wouldCreate
        $observation.execution.modelStarts | Should -Be 0
        $observation.effects.providerWrites | Should -Be 0
    }

    It 'preserves the authenticated history conflict boundary for <Mode>' -TestCases @(
        @{ Mode = 'ranged-ambiguous'; Expected = 'unknown' },
        @{ Mode = 'ranged-cross-rule'; Expected = 'unknown' },
        @{ Mode = 'ranged-unproven-human'; Expected = 'unknown' },
        @{ Mode = 'duplicate-prior-marker'; Expected = 'unknown' },
        @{ Mode = 'foreign-prior-marker'; Expected = 'unknown' },
        @{ Mode = 'extra-signed-marker'; Expected = 'unknown' },
        @{ Mode = 'ranged-proven-human'; Expected = 'noOp' },
        @{ Mode = 'outside-range-ambiguous'; Expected = 'noOp' },
        @{ Mode = 'prior-only'; Expected = 'noOp' }
    ) {
        param($Mode, $Expected)
        $case = New-ContextualUpgradeRecognitionCase
        $finding = $case.Observation.findings[0]
        $finding.ruleId = 'duplicate-constant-declarations'
        $finding.evidence = 'Consolidate duplicated constants WriterKey="writer", ReaderKey="reader" for the proven shared contract.'
        $finding.binding['span'] = @{ startLine = 32; endLine = 40 }
        $case.Proof.selection.ruleId = $finding.ruleId
        if ($Mode -like 'ranged-*') {
            $marker = Get-ContextualConventionMarkerKey -Contract $case.Contract -Finding $finding
            $case.Proof.selection.marker = $marker
            $case.Proof.selection.body = "Legacy body.`n<!-- devpilot-contextual-convention:v1:$marker -->"
        }
        if ($Mode -ceq 'extra-signed-marker') {
            $case.Proof.selection.body += "`n<!-- devpilot-other-rule:v1:$('8' * 64) -->"
        }
        $case.Proof.selection.bodySha256 = (
            Get-ContextualTestTextDigest $case.Proof.selection.body).Substring(10)
        $case.Thread.comments[0].body = $case.Proof.selection.body
        if ($Mode -cnotin @('extra-signed-marker', 'prior-only')) {
            $copy = $case.Thread | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
            $copy.threadId = 200
            $copy.comments[0].commentId = 201
            $copy.anchor.line = $(if ($Mode -like 'ranged-*') { 36 } else { 55 })
            switch ($Mode) {
                ranged-ambiguous {
                    $copy.comments[0].body = 'Unproven current request.'
                    $copy.comments[0].reviewerIdentityState = 'ambiguous'
                }
                ranged-cross-rule { $copy.comments[0].body = "<!-- devpilot-other-rule:v1:$('8' * 64) -->" }
                ranged-unproven-human {
                    $copy.comments[0].body = 'Please consider refactoring.'
                    $copy.comments[0].reviewerOwned = $false
                    $copy.comments[0].reviewerIdentityState = 'foreign'
                }
                ranged-proven-human {
                    $copy.comments[0].body = 'Consolidate shared constant WriterKey.'
                    $copy.comments[0].reviewerOwned = $false
                    $copy.comments[0].reviewerIdentityState = 'foreign'
                }
                outside-range-ambiguous {
                    $copy.comments[0].body = 'Unrelated request.'
                    $copy.comments[0].reviewerIdentityState = 'ambiguous'
                }
                foreign-prior-marker {
                    $copy.comments[0].reviewerOwned = $false
                    $copy.comments[0].reviewerIdentityState = 'foreign'
                }
            }
            $old = $case.Snapshot
            $case.Snapshot = [DevPilot.OwnerAdapters.OwnerDiscussionSnapshot]::new(
                $old.State, $old.Reason, $old.PageCount, 2, 2, $old.ByteCount,
                $old.Digest, $old.SourceDigests, [object[]]@($case.Thread, $copy))
            foreach ($name in @('RawProvenanceDigests', 'MappingDigest', 'ReviewerIdentityDigest', 'CurrentIterationId')) {
                $case.Snapshot | Add-Member -NotePropertyName $name -NotePropertyValue $old.$name
            }
        }
        $result = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $case.Observation -Contract $case.Contract `
            -Snapshot $case.Snapshot -AuthenticatedPriorComments @($case.Proof)
        $result.findings[0].reconciliation.classification | Should -BeExactly $Expected
        $result.findings[0].providerMarker.integrity |
            Should -BeExactly $(if ($Expected -ceq 'unknown') { 'invalid' } else { 'verified' })
        $result.effects.dedupe.noOp | Should -Be $(if ($Expected -ceq 'noOp') { 1 } else { 0 })
        $result.effects.dedupe.unknown | Should -Be $(if ($Expected -ceq 'unknown') { 1 } else { 0 })
        if ($Expected -ceq 'unknown' -and $Mode -cne 'extra-signed-marker') {
            $result.findings[0].reconciliation.reason | Should -BeExactly authenticated-prior-comment-conflict
        }
        $result.effects.dedupe.wouldCreate | Should -Be 0
        $result.effects.providerWrites | Should -Be 0
    }

    It 'preserves configured citations through acquisition, completed refresh, and approved reconstruction' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $config['commentRuleReferences'] = (
            Get-Content -LiteralPath (
                Join-Path $repoRoot 'samples\contextual-conventions-current-pr.config.json') -Raw |
                ConvertFrom-Json -AsHashtable).commentRuleReferences
        $config['commentRuleRepository'] = (
            Get-Content -LiteralPath (
                Join-Path $repoRoot 'samples\contextual-conventions-current-pr.config.json') -Raw |
                ConvertFrom-Json -AsHashtable).commentRuleRepository
        $configPath = Join-Path $TestDrive 'presentation-config.json'
        [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 64))
        $bodies = @(
            foreach ($attempt in 1..2) {
                $prepared = New-ContextualPreparedIntake
                $result = Invoke-SyntheticContextualBridge -Config $config `
                    -Prepared $prepared -Name presentation-roundtrip
                @($result.records) | Should -HaveCount 1 -Because (
                    $result | ConvertTo-Json -Depth 16 -Compress)
                $evidence = Read-ApprovedOwnerV2Evidence `
                    -StateRoot (Join-Path $TestDrive 'presentation-roundtrip-state') `
                    -Identity $result.records[0].identity -RepoRoot $repoRoot `
                    -ToolkitConfigPath $configPath -Delivery contextual-conventions
                $finding = @($evidence.Observation.findings |
                    Where-Object { $_.ruleId -ceq 'exception-logging' })[0]
                $proposal = Get-ApprovedOwnerV2Proposal -Evidence $evidence `
                    -Finding $finding -Delivery contextual-conventions
                $proposal.body | Should -Match '\*\*EngHub rules:\*\* \[Log at Source or Sink\]'
                $proposal.body | Should -Match (
                    'version=GC' + $prepared.Head.sourceCommit + '&path=%2Fsrc%2FChecks.cs&line=1')
                $proposal.bodySha256 | Should -BeExactly (
                    Get-ApprovedOwnerV2TextSha256 $proposal.body)
                $proposal.body
            }
        )
        $bodies | Should -HaveCount 2
        $bodies[0] | Should -BeExactly $bodies[1]
    }

    It 'withholds the new rule but preserves old findings for a <Mode> comparison binding' -TestCases @(
        @{Mode='missing'},@{Mode='tampered'},@{Mode='wrong-source'},@{Mode='wrong-target'},
        @{Mode='wrong-path'},@{Mode='wrong-length'}
    ) {
        param($Mode)
        $config=New-ContextualTestConfig; $config.enabled=$true
        $prepared=New-ReusedStringPreparedIntake
        $entry=$prepared.Intake.transientSnapshots['42'].changes.entries[0]
        $entry.content += "`nclass Logging { void M() { try { X(); } catch (Exception ex) { Logger.Error(ex.Message); } } }"
        $entry.sourceDigest=Get-ContextualTestTextDigest $entry.content
        $entry.byteLength=[Text.Encoding]::UTF8.GetByteCount($entry.content)
        $entry.spans[0].endLine=7
        $entry.spans[0].sourceDigest=$entry.sourceDigest
        $entry.comparison.sourceDigest=$entry.sourceDigest
        switch($Mode) {
            missing {$entry.Remove('comparison')}
            tampered {$entry.comparison.content='class Other {}'}
            wrong-source {$entry.comparison.sourceCommit='a'*40}
            wrong-target {$entry.comparison.targetCommit='b'*40}
            wrong-path {$entry.comparison.path='src/Other.cs'}
            wrong-length {$entry.comparison.byteLength++}
        }
        $name="comparison-binding-$Mode"
        $result=Invoke-SyntheticContextualBridge -Config $config -Prepared $prepared -Name $name
        $result.records | Should -HaveCount 1
        $path=@(Get-ChildItem (Join-Path $TestDrive "$name-state") -Recurse -File `
            -Filter "$($result.records[0].identity).json" | Where-Object {$_.Directory.Name -ceq 'observations'})[0].FullName
        $observation=Get-Content $path -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        @($observation.findings | Where-Object ruleId -CEQ reused-string-literals) | Should -HaveCount 0
        @($observation.findings | Where-Object ruleId -CEQ exception-logging) | Should -HaveCount 1
        @($observation.outcomes | Where-Object {
            $_.Contains('ruleId') -and $_.ruleId -ceq 'reused-string-literals' -and $_.state -ceq 'unknown'
        }) | Should -HaveCount 1
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
    }

    It 'rejects a shared acquisition whose generation does not match its intake' {
        $prepared=New-ContextualPreparedIntake
        $prepared.Intake['generation']='a'*32
        $envelope=@{
            schemaVersion=1;kind='devpilot-shared-review-acquisition';generation=('b'*32)
            configDigest=('c'*64);intake=$prepared.Intake
        }
        $envelope.intake['binding']=@{configDigest=('c'*64)}
        $path=Join-Path $TestDrive 'wrong-generation.json'
        $envelope | ConvertTo-Json -Depth 100 | Set-Content $path
        $configPath=Join-Path $TestDrive 'wrong-generation-config.json'
        (New-ContextualTestConfig) | ConvertTo-Json -Depth 64 | Set-Content $configPath
        {
            & (Join-Path $repoRoot 'tools\Invoke-ContextualConventionsCurrentPr.ps1') `
                -ConfigPath $configPath -StateRoot (Join-Path $TestDrive 'wrong-generation-state') `
                -ManifestPath (Join-Path $TestDrive 'wrong-generation-manifest.json') `
                -AcquisitionPath $path -AcquisitionSha256 ((Get-FileHash $path).Hash.ToLowerInvariant()) `
                -AzureCliPath 'must-not-be-invoked' -Run
        } | Should -Throw '*Shared acquisition binding is invalid*'
    }

    It 'carries both literal contract sides through acquisition and capability in <Mode> order' -TestCases @(
        @{ Mode = 'reader-first'; Reverse = $false; SameProject = $false; ContextOnlyPeer = $false }
        @{ Mode = 'writer-first'; Reverse = $true; SameProject = $false; ContextOnlyPeer = $false }
        @{ Mode = 'same-project'; Reverse = $false; SameProject = $true; ContextOnlyPeer = $false }
        @{ Mode = 'context-only-peer'; Reverse = $false; SameProject = $false; ContextOnlyPeer = $true }
    ) {
        param($Mode, $Reverse, $SameProject, $ContextOnlyPeer)
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared = New-ReusedStringPreparedIntake -Reverse:$Reverse `
            -SameProject:$SameProject -ContextOnlyPeer:$ContextOnlyPeer
        $result = Invoke-SyntheticContextualBridge -Config $config -Prepared $prepared -Name "literal-$Mode"
        $result.records | Should -HaveCount 1 -Because ($result | ConvertTo-Json -Depth 16 -Compress)
        $observationPath = @(Get-ChildItem (Join-Path $TestDrive "literal-$Mode-state") `
            -Recurse -File -Filter "$($result.records[0].identity).json" |
            Where-Object { $_.Directory.Name -ceq 'observations' })[0].FullName
        $observation = Get-Content $observationPath -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        $findings = @($observation.findings | Where-Object ruleId -CEQ reused-string-literals)
        $findings | Should -HaveCount 3 -Because ($result.outcomes | ConvertTo-Json -Depth 8 -Compress)
        $finding = @($findings | Where-Object { 'CredentialHandle' -cin $_.literalValues })[0]
        $finding.anchor.path | Should -BeExactly 'src/A/Reader.cs'
        $finding.binding.span.startLine | Should -Be 3
        $finding.binding.span.endLine | Should -Be 3
        @($findings | ForEach-Object {$_.literalValues} | Sort-Object) |
            Should -Be @('CredentialHandle', 'EndpointUri', 'GroupIdentity')
        @($findings | ForEach-Object {$_.literalValues}) | Should -Not -Contain LegacyKey
        @($findings | ForEach-Object {$_.relatedUses}) | Should -HaveCount 6
        $finding.occurrenceCounts.source | Should -Be 2
        $finding.occurrenceCounts.target | Should -Be 0
        $finding.reconciliation.classification | Should -BeExactly wouldCreate
        $finding.evidence | Should -Match $(if ($SameProject) {
            'common Constants class for the project'
        } else { 'lowest common project dependency' })
        $finding.evidence | Should -Not -Match 'src/A/App|src/B/App'
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
        $request = & (Get-Module DevPilot.OwnerOrchestrator) {
            param($Path)
            (Read-OwnerV2Manifest -ManifestPath $Path).Entries[0].Contract
        } $result.manifestPath
        $request | Add-Member -NotePropertyName CommentPresentation -NotePropertyValue @{
            subjectProvider = $config.subjectProvider
            ruleReferences = $config['commentRuleReferences']
            ruleRepository = $config['commentRuleRepository']
        }
        $evidence = @{Declaration=@{capability=@{id=$config.capability.id}};Contract=$request}
        $proposal = Get-ApprovedOwnerV2Proposal -Evidence $evidence -Finding $finding -Delivery contextual-conventions
        $proposal.line | Should -Be 3
        $proposal.endLine | Should -Be 3
        $proposal.body | Should -Match 'Declare constants'
    }

    It 'keeps one stable marker for the same literal cluster under reversed snapshot acquisition' {
        $markers=@()
        foreach($reverse in @($false,$true)) {
            $config=New-ContextualTestConfig; $config.enabled=$true
            $prepared=New-ReusedStringPreparedIntake -Reverse:$reverse
            $name="literal-stable-$reverse"
            $result=Invoke-SyntheticContextualBridge -Config $config -Prepared $prepared -Name $name
            $result.records | Should -HaveCount 1
            $path=@(Get-ChildItem (Join-Path $TestDrive "$name-state") -Recurse -File `
                -Filter "$($result.records[0].identity).json" | Where-Object {$_.Directory.Name -ceq 'observations'})[0].FullName
            $observation=Get-Content $path -Raw | ConvertFrom-Json -AsHashtable -Depth 64
            $finding=@($observation.findings | Where-Object ruleId -CEQ reused-string-literals)
            $markers += (@($finding.providerMarker.sha256 | Sort-Object) -join '|')
        }
        $markers[0] | Should -BeExactly $markers[1]
    }

    It 'reconciles the shared literal contract with <Coverage> human evidence' -TestCases @(
        @{ Coverage = 'peer anchor'; Line = 3; Body = 'Share constants for CredentialHandle, GroupIdentity, and EndpointUri reused by writer and reader.'; Expected = 'humanCovered' }
        @{ Coverage = 'range-start with pinned use citation'; Line = 2; Body = 'Share constants for CredentialHandle, GroupIdentity, and EndpointUri reused across projects. https://example.invalid/repo?version=GC{0}&path=/src/B/Writer.cs&line=3'; Expected = 'humanCovered' }
        @{ Coverage = 'unrelated same-anchor review'; Line = 3; Body = 'Please improve error handling.'; Expected = 'unknown' }
        @{ Coverage = 'only one covered value'; Line = 3; Body = 'Declare a shared constant for CredentialHandle.'; Expected = 'humanCovered' }
        @{ Coverage = 'stale citation'; Line = 2; Body = 'Share constants for CredentialHandle, GroupIdentity, and EndpointUri reused across projects. https://example.invalid/repo?version=GC0000000000000000000000000000000000000000&path=/src/B/Writer.cs&line=3'; Expected = 'unknown' }
        @{ Coverage = 'markerless configured reviewer'; Line = 2; Body = 'Share constants for CredentialHandle, GroupIdentity, and EndpointUri reused across projects. https://example.invalid/repo?version=GC{0}&path=/src/B/Writer.cs&line=3'; Expected = 'unknown' }
    ) {
        param($Coverage, $Line, $Body, $Expected)
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared = New-ReusedStringPreparedIntake
        $prepared.Intake.transientSnapshots['42'].discussions = @{
            count = 1
            threads = @(@{
                    id = 100; status = 'active'; isDeleted = $false
                    threadContext = @{
                        filePath = '/src/B/Writer.cs'
                        rightFileStart = @{line=$Line;offset=1}
                        rightFileEnd = @{line=5;offset=1}
                    }
                    pullRequestThreadContext = @{
                        changeTrackingId = 2
                        iterationContext = @{firstComparingIteration=3;secondComparingIteration=3}
                    }
                    comments = @(@{
                            id=1;commentType='text';content=($Body -f $prepared.Head.sourceCommit)
                            author = $(if ($Coverage -ceq 'markerless configured reviewer') {
                                @{
                                    id=$config.expectedAccount.id
                                    descriptor=$config.expectedAccount.descriptor
                                    uniqueName=$config.expectedAccount.uniqueName
                                }
                            } else {
                                @{id='44444444-4444-4444-4444-444444444444';descriptor='aad.human';uniqueName='human@example.invalid'}
                            })
                        })
                })
        }
        $name = 'human-literal-' + ($Coverage -replace '[^a-z]', '-')
        $result = Invoke-SyntheticContextualBridge -Config $config -Prepared $prepared -Name $name
        $result.records | Should -HaveCount 1 -Because ($result | ConvertTo-Json -Depth 16 -Compress)
        $observationPath = @(Get-ChildItem (Join-Path $TestDrive "$name-state") `
            -Recurse -File -Filter "$($result.records[0].identity).json" |
            Where-Object { $_.Directory.Name -ceq 'observations' })[0].FullName
        $observation = Get-Content $observationPath -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        $finding = @($observation.findings | Where-Object ruleId -CEQ reused-string-literals)
        $finding | Should -HaveCount 3 -Because ($result.outcomes | ConvertTo-Json -Depth 8 -Compress)
        $credential=@($finding | Where-Object { 'CredentialHandle' -cin $_.literalValues })[0]
        $credential.reconciliation.classification | Should -BeExactly $Expected
        if ($Coverage -ceq 'markerless configured reviewer') {
            @($finding | Where-Object { $_.reconciliation.classification -cne 'unknown' }) | Should -HaveCount 0
        }
        $result.providerWrites | Should -Be 0
    }

    It 'does not deliver a reused literal for the <Control> full-PR negative' -TestCases @(
        @{Control='single occurrence'}
        @{Control='constant member references'}
        @{Control='old code'}
        @{Control='unproved project'}
    ) {
        param($Control)
        $config=New-ContextualTestConfig
        $config.enabled=$true
        $prepared=New-ReusedStringPreparedIntake
        $changes=$prepared.Intake.transientSnapshots['42'].changes
        if ($Control -ceq 'single occurrence') {
            $changes.entries=@($changes.entries[0]); $changes.changedFiles=1; $changes.changedLines=3
        }
        foreach($entry in $changes.entries) {
            switch($Control) {
                'constant member references' {
                    $entry.content=$entry.content.Replace('["CredentialHandle"]','[Keys.CredentialHandle]').
                        Replace('["GroupIdentity"]','[Keys.GroupIdentity]').Replace('["EndpointUri"]','[Keys.EndpointUri]')
                    $entry.sourceDigest=Get-ContextualTestTextDigest $entry.content
                    $entry.byteLength=[Text.Encoding]::UTF8.GetByteCount($entry.content)
                    $entry.spans[0].sourceDigest=$entry.sourceDigest
                }
                'old code' { $entry.spans[0].startLine=6; $entry.spans[0].endLine=6; $changes.changedLines=2 }
                'unproved project' { $entry.projectContext=@{state='unknown';reason='project-context-ambiguous'} }
            }
        }
        $name='negative-literal-' + ($Control -replace ' ','-')
        $result=Invoke-SyntheticContextualBridge -Config $config -Prepared $prepared -Name $name
        $result.records | Should -HaveCount 1
        $path=@(Get-ChildItem (Join-Path $TestDrive "$name-state") -Recurse -File `
            -Filter "$($result.records[0].identity).json" | Where-Object {$_.Directory.Name -ceq 'observations'})[0].FullName
        $observation=Get-Content $path -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        @($observation.findings | Where-Object ruleId -CEQ reused-string-literals) | Should -HaveCount 0
        if($Control -ceq 'unproved project') {
            @($observation.outcomes | Where-Object {
                $_.Contains('ruleId') -and $_.ruleId -ceq 'reused-string-literals' -and $_.state -ceq 'unknown'
            }) | Should -HaveCount 1
        }
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
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

    It 'recognizes a signed historical body at the unchanged current marker without rewriting it' {
        foreach ($variant in @('authentic', 'edited', 'duplicate', 'unsigned')) {
            $case = New-ContextualUpgradeRecognitionCase
            $finding = $case.Observation.findings[0]
            $marker = Get-ContextualConventionMarkerKey -Contract $case.Contract -Finding $finding
            $body = @(
                '**explicit-string-comparison**'
                ''
                'Use explicit StringComparison semantics.'
                ''
                'Changed code: `FilterByTag` at `/src/Checks.cs`:32.'
                ''
                "Rule bundle: ``/$($case.Contract.Request.RulePath)`` at ``$($case.Contract.Request.RuleCommit)`` (SHA-256 ``$($case.Contract.Request.RuleHash.Substring(10))``)."
                ''
                "<!-- devpilot-contextual-convention:v1:$marker -->"
            ) -join "`n"
            $case.Proof.selection.marker = $marker
            $case.Proof.selection.body = $body
            $case.Proof.selection.bodySha256 =
                (Get-ContextualTestTextDigest $body).Substring(10)
            $case.Thread.comments[0].body = $body
            if ($variant -ceq 'edited') { $case.Thread.comments[0].body += "`nEdited." }
            if ($variant -ceq 'duplicate') {
                $case.Thread.comments += [ordered]@{
                    commentId = 102
                    commentType = 'text'
                    isDeleted = $false
                    reviewerOwned = $true
                    reviewerIdentityState = 'matched'
                    body = $body
                }
            }
            $proofs = if ($variant -ceq 'unsigned') { @() } else { @($case.Proof) }
            $result = Resolve-OwnerV2DiscussionReconciliation `
                -Observation $case.Observation -Contract $case.Contract `
                -Snapshot $case.Snapshot -AuthenticatedPriorComments $proofs
            $result.findings[0].reconciliation.classification |
                Should -BeExactly $(if ($variant -ceq 'authentic') { 'noOp' } else { 'unknown' })
            $result.effects.dedupe.wouldCreate | Should -Be 0
            $result.effects.dedupe.wouldUpdate | Should -Be 0
            $result.effects.providerWrites | Should -Be 0
            if ($variant -ceq 'authentic') {
                $result.findings[0].reconciliation.reason |
                    Should -BeExactly authenticated-prior-reviewer-comment
                $case.Thread.comments[0].body | Should -BeExactly $body
            }
        }
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
                            'block-body-indentation',
                            'generic-exception-naming',
                            'file-copyright-header',
                            'reused-string-literals')
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
                ruleId = 'pr-template-compliance'
                prior = $compatibility.previousRules[3].rule
                expected = 'noOp'
            },
            [ordered]@{
                ruleId = 'reused-string-literals'
                prior = $compatibility.previousRules[3].rule
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
                ruleId = 'pr-template-compliance'
                prior = $compatibility.previousRules[3].rule
                expected = 'noOp'
            })
        foreach ($entry in $compatibility.previousRules) {
            $cases += [ordered]@{
                ruleId = 'block-body-indentation'
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
        @{ Mode = 'new-rule-in-prior-bundle' }
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
            new-rule-in-prior-bundle {
                $compatibility.previousRules[1].
                    unchangedRuleIds = @(
                        'block-body-indentation')
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

    It 'recognizes an indentation request on the proven block brace without changing the statement anchor' {
        $case = New-ContextualUpgradeRecognitionCase
        $finding = $case.Observation.findings[0]
        $finding.ruleId = 'block-body-indentation'
        $finding['indentationContext'] = [ordered]@{
            blockStartLine = 31
            blockEndLine = 40
            statementLine = 32
        }
        $case.Thread.anchor.line = 31
        $case.Thread.comments[0].body =
            'Indent the try body one level (four spaces).'
        $case.Thread.comments[0].reviewerOwned = $false
        $case.Thread.comments[0].reviewerIdentityState = 'foreign'
        $result = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $case.Observation -Contract $case.Contract `
            -Snapshot $case.Snapshot
        $result.findings[0].anchor.line | Should -Be 32
        $result.findings[0].reconciliation.classification |
            Should -BeExactly humanCovered
    }

    It 'recognizes the exact current indentation reviewer marker as a no-op' {
        $case = New-ContextualUpgradeRecognitionCase
        $finding = $case.Observation.findings[0]
        $finding.ruleId = 'block-body-indentation'
        $finding['indentationContext'] = [ordered]@{
            blockStartLine = 31
            blockEndLine = 40
            statementLine = 32
        }
        $marker = Get-ContextualConventionMarkerKey `
            -Contract $case.Contract -Finding $finding
        $case.Thread.comments[0].body =
            Format-ContextualConventionComment -Contract $case.Contract `
                -Finding $finding -MarkerKey $marker
        $result = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $case.Observation -Contract $case.Contract `
            -Snapshot $case.Snapshot
        $result.findings[0].reconciliation.classification |
            Should -BeExactly noOp
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

    It 'evaluates block indentation through the bridge and suppresses current coverage for <Mode>' -TestCases @(
        @{ Mode = 'uncovered'; Expected = 'wouldCreate' }
        @{ Mode = 'human-at-brace'; Expected = 'humanCovered' }
        @{ Mode = 'unrelated-at-brace'; Expected = 'unknown' }
        @{ Mode = 'reviewer-at-statement'; Expected = 'noOp' }
        @{ Mode = 'copied-marker'; Expected = 'unknown' }
        @{ Mode = 'outdated-human'; Expected = 'wouldCreate' }
        @{ Mode = 'deleted-human'; Expected = 'wouldCreate' }
        @{ Mode = 'changed-try-covered'; Expected = 'humanCovered' }
        @{ Mode = 'reviewer-markerless'; Expected = 'unknown' }
    ) {
        param($Mode, $Expected)
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $content = @'
class C
{
    void M()
    {
        try
        {
        Work();
        }
        finally { }
    }
}
'@
        $prepared = New-ContextualPreparedIntake -Content $content
        $prepared.Intake.transientSnapshots['42'].
            changes.entries[0].spans[0].startLine = 7
        $prepared.Intake.transientSnapshots['42'].
            changes.entries[0].spans[0].endLine = 7
        if ($Mode -ceq 'changed-try-covered') {
            $prepared.Intake.transientSnapshots['42'].
                changes.entries[0].spans[0].startLine = 5
            $prepared.Intake.transientSnapshots['42'].
                changes.entries[0].spans[0].endLine = 6
            $prepared.Intake.transientSnapshots['42'].changes.changedLines = 2
        }
        if ($Mode -cin @(
                'human-at-brace', 'unrelated-at-brace',
                'outdated-human', 'deleted-human', 'changed-try-covered',
                'reviewer-markerless')) {
            $body = if ($Mode -ceq 'unrelated-at-brace') {
                'Please improve the error handling.'
            }
            else {
                'Indent the new try body one level (four spaces).'
            }
            $identity = if ($Mode -ceq 'reviewer-markerless') { 'reviewer' } else { 'human' }
            Add-SyntheticDiscussion -Prepared $prepared -Config $config `
                -Body $body -Identity $identity -Path 'src/Checks.cs' -Line 6
            $thread = $prepared.Intake.transientSnapshots['42'].
                discussions.threads[0]
            $thread.threadContext.rightFileEnd.line = 8
            if ($Mode -ceq 'outdated-human') {
                $thread.pullRequestThreadContext.iterationContext.
                    secondComparingIteration = 2
            }
            if ($Mode -ceq 'deleted-human') {
                $thread.isDeleted = $true
            }
        }
        elseif ($Mode -cin @('reviewer-at-statement', 'copied-marker')) {
            $first = $prepared | ConvertTo-Json -Depth 32 |
                ConvertFrom-Json -AsHashtable -Depth 32
            $comment = Get-SyntheticCurrentPrTemplateComment `
                -Config $config -Prepared $first -Name "indentation-$Mode-first"
            $identity = if ($Mode -ceq 'copied-marker') { 'human' } else { 'reviewer' }
            Add-SyntheticDiscussion -Prepared $prepared -Config $config `
                -Body $comment.Body -Identity $identity `
                -Path 'src/Checks.cs' -Line 7
        }
        $result = Invoke-SyntheticContextualBridge `
            -Config $config -Prepared $prepared -Name "indentation-$Mode"
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
        $observation = Get-Content -LiteralPath (
            $result.outcomes[0].observationPath) -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
        @($observation.findings) | Should -HaveCount 1
        $finding = $observation.findings[0]
        $finding.ruleId | Should -BeExactly block-body-indentation
        $anchorLine = if ($Mode -ceq 'changed-try-covered') { 6 } else { 7 }
        $finding.anchor.line | Should -Be $anchorLine
        $finding.binding.span.startLine | Should -Be $anchorLine
        $finding.indentationContext.blockStartLine | Should -Be 6
        $finding.indentationContext.statementLine | Should -Be 7
        $finding.reconciliation.classification | Should -BeExactly $Expected -Because (
            $observation | ConvertTo-Json -Depth 32 -Compress)
        if ($Mode -ceq 'reviewer-markerless') {
            $finding.reconciliation.reason |
                Should -BeExactly unmarked-current-reviewer-comment
        }
        $result.state | Should -BeExactly $(if ($Expected -ceq 'unknown') {
                'partial'
            } else { 'completed' })
    }

    It 'refuses indentation evaluation on source or target drift for <Field>' -TestCases @(
        @{ Field = 'sourceCommit' }
        @{ Field = 'targetCommit' }
    ) {
        param($Field)
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared = New-ContextualPreparedIntake -Content (
            "class C`n{`n    void M()`n    {`n    Work();`n    }`n}")
        $entry = $prepared.Intake.transientSnapshots['42'].changes.entries[0]
        $entry.spans[0].startLine = 5
        $entry.spans[0].endLine = 5
        $fieldName = $Field
        $headProvider = {
            param($Head)
            $current = [ordered]@{} + $Head
            $current[$fieldName] = '9' * 40
            return $current
        }.GetNewClosure()
        $result = Invoke-SyntheticContextualBridge `
            -Config $config -Prepared $prepared `
            -Name "indentation-drift-$Field" -HeadProvider $headProvider
        $result.state | Should -BeExactly partial
        $result.providerWrites | Should -Be 0
        @($result.outcomes | Where-Object reason -CEQ post-evaluation-head-refused) |
            Should -HaveCount 1
    }

    It 'excludes deleted and generated source evidence from indentation findings' {
        foreach ($mode in @('deleted', 'generated')) {
            $config = New-ContextualTestConfig
            $config.enabled = $true
            $prepared = New-ContextualPreparedIntake -Content (
                "class C`n{`n    void M()`n    {`n    Work();`n    }`n}")
            $entry = $prepared.Intake.transientSnapshots['42'].changes.entries[0]
            $entry.spans[0].startLine = 5
            $entry.spans[0].endLine = 5
            if ($mode -ceq 'deleted') {
                $entry.changeType = 'delete'
                $entry.spans = @()
                $entry.content = ''
                $entry.sourceDigest = 'v1:sha256:' + ('0' * 64)
                $entry.byteLength = 0
            }
            else { $entry.path = 'generated/Checks.cs' }
            $result = Invoke-SyntheticContextualBridge `
                -Config $config -Prepared $prepared -Name "indentation-$mode"
            $result.state | Should -BeExactly completed -Because (
                $result | ConvertTo-Json -Depth 16 -Compress)
            $result.providerWrites | Should -Be 0
            $observation = Get-Content -LiteralPath (
                $result.outcomes[0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable -Depth 64
            @($observation.findings | Where-Object ruleId -CEQ block-body-indentation) |
                Should -HaveCount 0
        }
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

    It 'reads code-level actionable partial evidence beside an isolated PR-wide template discussion unknown' {
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
            -Body '[Dobby] Suggested PR description edit.' `
            -Identity reviewer
        $result =
            Invoke-SyntheticContextualBridge `
                -Config $config `
                -Prepared $prepared `
                -Name pr-template-unknown-code-actionable
        $result.state |
            Should -BeExactly partial
        $identity =
            [string]$result.records[0].identity
        $configPath = Join-Path $TestDrive `
            'pr-template-unknown-code-actionable-config.json'
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
                        'pr-template-unknown-code-actionable-state') `
                -Identity $identity `
                -RepoRoot $repoRoot `
                -ToolkitConfigPath $configPath `
                -Delivery contextual-conventions
        $prFinding = @(
            $evidence.Observation.findings |
                Where-Object {
                    [string]$_.ruleId -ceq
                        'pr-template-compliance'
                })[0]
        $codeFinding = @(
            $evidence.Observation.findings |
                Where-Object {
                    [string]$_.ruleId -ceq
                        'exception-logging'
                })[0]
        $proposal =
            Get-ApprovedOwnerV2Proposal `
                -Evidence $evidence `
                -Finding $codeFinding `
                -Delivery contextual-conventions
        $deliveryRoot = Join-Path $TestDrive `
            'pr-template-unknown-code-actionable-delivery'
        $producer = Join-Path $repoRoot `
            'tools\Invoke-ContextualDeliveryBatchJson.ps1'
        $automatic = Join-Path $repoRoot `
            'tools\Invoke-AutomaticOwnerV2Delivery.ps1'
        $output = @(& $producer `
                -AutomaticDeliveryTool $automatic `
                -DeliveryRoot $deliveryRoot `
                -StateRoot (
                    Join-Path $TestDrive `
                        'pr-template-unknown-code-actionable-state') `
                -Identity $identity `
                -ToolkitConfigPath $configPath `
                -AzureCliPath 'ignored' `
                -GitPath 'git' `
                -RepoRoot $repoRoot)
        $envelope =
            ($output -join "`n") |
                ConvertFrom-Json `
                    -AsHashtable -Depth 64

        $prFinding.reconciliation.classification |
            Should -BeExactly unknown
        $prFinding.reconciliation.reason |
            Should -BeExactly `
                duplicate-or-foreign-reviewer-marker
        $codeFinding.reconciliation.classification |
            Should -BeExactly wouldCreate
        $proposal.scope |
            Should -BeExactly changed-line
        $proposal.path |
            Should -BeExactly src/Checks.cs
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

Describe 'Integrated reviewed contextual rules' {
    It 'carries four new rules and an old rule together with typed linked presentation' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $sample = Get-Content (Join-Path $repoRoot 'samples\contextual-conventions-current-pr.config.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $config['commentRuleReferences'] = $sample.commentRuleReferences
        $config['commentRuleRepository'] = $sample.commentRuleRepository
        $content = @'
using System;
class C
{
    bool Equal(string left, string right) { return left == right; }
    void M()
    {
        try
        {
        Work("Shared");
        Work("Shared");
        }
        catch (System.Exception cleanup) { }
    }
}
'@
        $target = $content.Replace('Work("Shared");', 'Work("Before");')
        $prepared = New-ContextualPreparedIntake -Content $content
        $entry = $prepared.Intake.transientSnapshots['42'].changes.entries[0]
        $entry.spans[0].startLine = 2
        $entry.spans[0].endLine = 14
        $entry['projectContext'] = @{
            state = 'complete'; path = 'src/App.csproj'
            content = '<Project><PropertyGroup><LangVersion>latest</LangVersion></PropertyGroup></Project>'
        }
        $entry.projectContext['byteLength'] = [Text.Encoding]::UTF8.GetByteCount($entry.projectContext.content)
        $entry.projectContext['sourceDigest'] = Get-ContextualTestTextDigest $entry.projectContext.content
        $entry['comparison'] = @{
            schemaVersion = 1; state = 'complete'; path = $entry.path; targetPath = $entry.path
            sourceCommit = $prepared.Head.sourceCommit; targetCommit = $prepared.Head.targetCommit
            sourceDigest = $entry.sourceDigest; targetDigest = Get-ContextualTestTextDigest $target
            content = $target; byteLength = [Text.Encoding]::UTF8.GetByteCount($target); targetState = 'present'
        }
        $entry['fileHeader'] = Get-ContextualCopyrightHeaderEvidence -Path $entry.path -ChangeType edit `
            -Content $content -TargetContent $target -SourceCommit $prepared.Head.sourceCommit `
            -TargetCommit $prepared.Head.targetCommit
        $prepared.Intake.transientSnapshots['42'].changes.changedLines = 13
        $result = Invoke-SyntheticContextualBridge -Config $config -Prepared $prepared -Name integrated-four
        $result.state | Should -BeExactly completed -Because ($result | ConvertTo-Json -Depth 12 -Compress)
        $configPath = Join-Path $TestDrive 'integrated-four-config.json'
        $config | ConvertTo-Json -Depth 64 | Set-Content $configPath
        $evidence = Read-ApprovedOwnerV2Evidence -StateRoot (Join-Path $TestDrive 'integrated-four-state') `
            -Identity $result.records[0].identity -RepoRoot $repoRoot `
            -ToolkitConfigPath $configPath -Delivery contextual-conventions
        $expected = @('block-body-indentation', 'generic-exception-naming', 'reused-string-literals',
            'file-copyright-header', 'explicit-string-comparison')
        $findings = @($evidence.Observation.findings | Where-Object { $_.ruleId -cin $expected })
        $findings | Should -HaveCount 5
        foreach ($finding in $findings) {
            $finding.reconciliation.classification | Should -BeExactly wouldCreate
            $proposal = Get-ApprovedOwnerV2Proposal -Evidence $evidence -Finding $finding -Delivery contextual-conventions
            $proposal.body | Should -Not -Match 'Rule bundle:|Dobby|model discovery'
            if ($finding.ruleId -cne 'explicit-string-comparison') {
                $line = @{ 'block-body-indentation' = 18; 'generic-exception-naming' = 1225
                    'reused-string-literals' = 706; 'file-copyright-header' = 929 }[$finding.ruleId]
                $proposal.body | Should -Match "&line=$line\b"
                $proposal.body | Should -Match '\*\*EngHub rules:\*\*'
            }
            if ($finding.ruleId -ceq 'file-copyright-header') {
                $proposal.scope | Should -BeExactly file-header
                $proposal.line | Should -Be 1
                $proposal.fileHeader.origin | Should -BeExactly pre-existing
                $proposal.body | Should -Not -Match 'Changed-line occurrences'
                $proposal.body | Should -Match 'File-header location'
            }
            if ($finding.ruleId -ceq 'reused-string-literals') {
                $proposal.body | Should -Match 'Related source occurrences'
                $proposal.body | Should -Not -Match 'System.Object\[\]'
            }
        }
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
    }

    It 'derives Named header authority only from a validated <Mode> comparison' -TestCases @(
        @{Mode='complete';Expected=1},
        @{Mode='missing';Expected=0},
        @{Mode='tampered';Expected=0},
        @{Mode='wrong-target';Expected=0}
    ) {
        param($Mode, $Expected)
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared = New-ReusedStringPreparedIntake
        $reader = $prepared.Intake.transientSnapshots['42'].changes.entries[0]
        $reader.ContainsKey('fileHeader') | Should -BeFalse
        switch ($Mode) {
            missing { $reader.Remove('comparison') }
            tampered { $reader.comparison.targetDigest = 'v1:sha256:' + ('0' * 64) }
            wrong-target { $reader.comparison.targetCommit = '0' * 40 }
        }
        $result = Invoke-SyntheticContextualBridge -Config $config -Prepared $prepared -Name "header-comparison-$Mode"
        $observation = Get-Content $result.outcomes[0].observationPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        $headers = @($observation.findings | Where-Object {
            $_.ruleId -ceq 'file-copyright-header' -and $_.anchor.path -ceq $reader.path
        })
        $headers | Should -HaveCount $Expected
        if ($Expected -eq 1) {
            $headers[0].anchor.scope | Should -BeExactly file-header
            $headers[0].anchor.line | Should -Be 1
            $headers[0].fileHeader.origin | Should -BeExactly pre-existing
            $headers[0].fileHeader.targetDigest | Should -BeExactly $reader.comparison.targetDigest
            @($reader.spans | Where-Object { $_.startLine -le 1 }) | Should -HaveCount 0
        }
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
    }

    It 'applies the expanded indentation range to authenticated-current conflict checks' {
        $case = New-ContextualUpgradeRecognitionCase
        $finding = $case.Observation.findings[0]
        $finding.ruleId = 'block-body-indentation'
        $finding['indentationContext'] = @{ blockStartLine = 30; blockEndLine = 40; statementLine = 32 }
        $case.Proof.selection.ruleId = $finding.ruleId
        $marker = Get-ContextualConventionMarkerKey -Contract $case.Contract -Finding $finding
        $case.Proof.selection.marker = $marker
        $case.Proof.selection.body = "Authenticated old presentation.`n<!-- devpilot-contextual-convention:v1:$marker -->"
        $case.Proof.selection.bodySha256 = (Get-ContextualTestTextDigest $case.Proof.selection.body).Substring(10)
        $case.Thread.comments[0].body = $case.Proof.selection.body
        $copy = $case.Thread | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $copy.threadId = 200
        $copy.comments[0].commentId = 201
        $copy.anchor.line = 30
        $copy.comments[0].body = 'Please improve this unrelated detail.'
        $copy.comments[0].reviewerOwned = $false
        $copy.comments[0].reviewerIdentityState = 'foreign'
        $old = $case.Snapshot
        $snapshot = [DevPilot.OwnerAdapters.OwnerDiscussionSnapshot]::new(
            $old.State, $old.Reason, $old.PageCount, 2, 2, $old.ByteCount,
            $old.Digest, $old.SourceDigests, [object[]]@($case.Thread, $copy))
        foreach ($name in @('RawProvenanceDigests', 'MappingDigest', 'ReviewerIdentityDigest', 'CurrentIterationId')) {
            $snapshot | Add-Member -NotePropertyName $name -NotePropertyValue $old.$name
        }
        $result = Resolve-OwnerV2DiscussionReconciliation -Observation $case.Observation -Contract $case.Contract `
            -Snapshot $snapshot -AuthenticatedPriorComments @($case.Proof)
        $result.findings[0].reconciliation.classification | Should -BeExactly unknown
        $result.findings[0].reconciliation.reason | Should -BeExactly authenticated-prior-comment-conflict
        $result.effects.dedupe.wouldCreate | Should -Be 0
    }
}
