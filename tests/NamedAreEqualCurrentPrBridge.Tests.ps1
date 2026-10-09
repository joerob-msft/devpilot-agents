#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') -Force
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.NamedAreEqualBridge\DevPilot.NamedAreEqualBridge.psd1') -Force
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1') -Force
    . (Join-Path $repoRoot `
        'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')
    . (Join-Path $repoRoot `
        'src\Agents\reviewer\AutomaticOwnerV2Comments.ps1')

    function Get-BridgeDigest {
        param([object]$Value)
        'v1:sha256:' + (Get-AgentCanonicalDigest -InputObject $Value)
    }

    function Get-BridgeTextDigest {
        param([string]$Value)
        'v1:sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes($Value))).
            ToLowerInvariant()
    }

    function New-BridgeConfig {
        $reviewer = New-OwnerAzureDevOpsReviewerIdentity `
            -Id '33333333-3333-3333-3333-333333333333' `
            -Descriptor 'aad.synthetic-service-account' `
            -UniqueName 'service@example.invalid'
        $adapter = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
            -Name 'named-bridge-config' -ReviewerIdentity $reviewer `
            -Handler { throw 'not invoked' }
        [ordered]@{
            schemaVersion = 1
            enabled = $false
            readOnly = $true
            dryRun = $true
            organization = 'https://dev.azure.com/example-org'
            projectName = 'ExampleProject'
            projectId = '22222222-2222-2222-2222-222222222222'
            repositoryId = '11111111-1111-1111-1111-111111111111'
            expectedAccount = [ordered]@{
                id = '33333333-3333-3333-3333-333333333333'
                descriptor = 'aad.synthetic-service-account'
                uniqueName = 'service@example.invalid'
            }
            automationMarker = '[DevPilot-Automation:v1]'
            rules = @([ordered]@{
                    id = 'bpm-named-areequal-arguments@1'
                    capability = 'bpm-named-areequal-arguments@1'
                })
            namedRule = [ordered]@{
                repositoryId = 'devpilot-agents'
                path = 'src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt'
                section = 'bpm-named-areequal-arguments@1'
                hash = 'v1:sha256:8b9fa35bd2bc96e9f0dbfc878806b540603ab4f255ddf41bf120311913b831f4'
                length = 653
            }
            toolkit = [ordered]@{
                ref = 'refs/heads/named-test'
                head = 'a' * 40
                tree = 'b' * 40
            }
            subjectProvider = [ordered]@{
                kind = 'azure-devops-read-only-v1'
                organization = 'https://dev.azure.com/example-org'
                projectName = 'ExampleProject'
                projectId = '22222222-2222-2222-2222-222222222222'
                repositoryName = 'ExampleRepository'
                repositoryId = '11111111-1111-1111-1111-111111111111'
                maximumFiles = 64
                maximumBytes = 16777216
                maximumReads = 128
            }
            discussionProvider = [ordered]@{
                kind = 'azure-devops-rest-owner-discussions-v1'
                mappingDigest = $adapter.AzureDevOpsDiscussionMappingDigest
                reviewerIdentity = [ordered]@{
                    id = [string]$reviewer.Id
                    descriptor = [string]$reviewer.Descriptor
                    uniqueName = [string]$reviewer.UniqueName
                    digest = $adapter.AzureDevOpsReviewerIdentityDigest
                }
            }
            capability = [ordered]@{
                id = 'bpm-named-areequal-arguments@1'
                implementationSha256 =
                    '7ed3583591b43dbb351292ea9a37a53fc32fc9f0fd3403c821e3209310598e3a'
            }
            sharedAcquisition = [ordered]@{
                kind = 'devpilot-shared-review-acquisition-v1'
                activePrIntakeSha256 =
                    (Get-FileHash (Join-Path $repoRoot `
                        'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psm1') `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                namedBridgeSha256 =
                    (Get-FileHash (Join-Path $repoRoot `
                        'src\DevPilot.NamedAreEqualBridge\DevPilot.NamedAreEqualBridge.psm1') `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                toolSha256 =
                    (Get-FileHash (Join-Path $repoRoot `
                        'tools\Invoke-SharedReviewAcquisition.ps1') `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            autoCreateNamedAreEqualComments = $false
            limits = [ordered]@{
                pageSize = 50
                maxPages = 8
                maxPullRequests = 20
                maxHeadsPerRun = 2
                maxReads = 128
                maxSeconds = 30
                maxChangedFiles = 64
                maxChangedLines = 5000
                maxThreads = 100
                maxComments = 500
            }
        }
    }

    function New-BridgeProvider {
        param(
            [Collections.IDictionary]$Config,
            [string]$SourceCommit = ('c' * 40),
            [ValidateRange(1, 8)][int]$MethodCount = 1,
            [string]$ChangeFailure = '',
            [bool]$IsDraft = $false,
            [switch]$NonCSharpUnknown,
            [switch]$CSharpUnknown,
            [switch]$InvalidCSharpDigest,
            [ValidateSet('', 'null', 'whitespace')]
            [string]$InvalidPathMode = '',
            [ValidateSet(
                '', 'zero', 'nonnumeric',
                'out-of-range')]
            [string]$MalformedCSharpSpan = '',
            [object[]]$DiscussionThreads = @(),
            [AllowNull()][Collections.IDictionary]$IdentityOverride = $null
        )
        $calls = [Collections.Generic.List[string]]::new()
        $lines = [Collections.Generic.List[string]]::new()
        [void]$lines.Add(
            'using Microsoft.VisualStudio.TestTools.UnitTesting;')
        [void]$lines.Add('[TestClass]')
        [void]$lines.Add('class Checks {')
        $callLines = [Collections.Generic.List[int]]::new()
        foreach ($index in 1..$MethodCount) {
            [void]$lines.Add('    [TestMethod]')
            [void]$lines.Add("    void Verify$index() {")
            [void]$lines.Add(
                "        Assert.AreEqual($index, items.Count);")
            [void]$callLines.Add($lines.Count)
            [void]$lines.Add('    }')
        }
        [void]$lines.Add('}')
        $content = $lines -join "`n"
        $head = [ordered]@{
            repositoryId = $Config.repositoryId
            projectId = $Config.projectId
            pullRequestId = 42
            sourceRef = 'refs/heads/feature'
            targetRef = 'refs/heads/master'
            sourceCommit = $SourceCommit
            targetCommit = 'd' * 40
            iterationId = 3
            status = 'active'
            isDraft = $IsDraft
        }
        $spanDigest = Get-BridgeDigest 'span'
        $contentDigest = Get-BridgeTextDigest $content
        $unknownContentDigest =
            Get-BridgeTextDigest 'unknown-yaml'
        $unknownCSharpDigest =
            Get-BridgeTextDigest 'unknown-csharp'
        $malformedSpanContent = 'class Span {}'
        $malformedSpanDigest =
            Get-BridgeTextDigest $malformedSpanContent
        $provider = {
            param($Operation, $Request)
            [void]$calls.Add([string]$Operation)
            switch ($Operation) {
                'Identity' {
                    return [ordered]@{} + $(if ($null -ne $IdentityOverride) {
                        $IdentityOverride
                    } else { $Config.expectedAccount })
                }
                'ListPage' {
                    if ([int]$Request.skip -eq 0) {
                        return @{
                            items = @([ordered]@{
                                    pullRequestId = 42
                                    status = 'active'
                                    isDraft = $IsDraft
                                    targetRef = 'refs/heads/master'
                                })
                            count = 1
                        }
                    }
                    return @{ items = @(); count = 0 }
                }
                'Head' {
                    return [ordered]@{} + $head
                }
                'Changes' {
                    if ($ChangeFailure) { throw $ChangeFailure }
                    if ($InvalidPathMode) {
                        return @{
                            changedFiles = 1
                            changedLines = 0
                            entries = @([ordered]@{
                                    changeTrackingId = 11
                                    path = $(if (
                                        $InvalidPathMode -ceq
                                            'null'
                                        ) { $null } else { '   ' })
                                    changeType = 'edit'
                                    state = 'unknown'
                                    spans = @()
                                    content = $null
                                    byteLength = 0
                                    sourceDigest =
                                        $unknownContentDigest
                                })
                        }
                    }
                    if ($MalformedCSharpSpan) {
                        $start = switch (
                            $MalformedCSharpSpan) {
                            zero { 0 }
                            nonnumeric { 'bad' }
                            'out-of-range' {
                                [long]::MaxValue
                            }
                        }
                        $end = switch (
                            $MalformedCSharpSpan) {
                            zero { 0 }
                            nonnumeric { 'worse' }
                            'out-of-range' {
                                [long]::MaxValue
                            }
                        }
                        return @{
                            changedFiles = 1
                            changedLines = 1
                            entries = @([ordered]@{
                                    changeTrackingId = 12
                                    path =
                                        'tests/MalformedSpan.cs'
                                    changeType = 'edit'
                                    state = 'complete'
                                    spans = @([ordered]@{
                                            startLine = $start
                                            endLine = $end
                                            state = 'complete'
                                            sourceDigest =
                                                $malformedSpanDigest
                                        })
                                    content =
                                        $malformedSpanContent
                                    byteLength =
                                        [Text.Encoding]::UTF8.
                                            GetByteCount(
                                                $malformedSpanContent)
                                    sourceDigest =
                                        $malformedSpanDigest
                                })
                        }
                    }
                    if ($InvalidCSharpDigest) {
                        return @{
                            changedFiles = 1
                            changedLines = 1
                            entries = @([ordered]@{
                                    changeTrackingId = 10
                                    path = 'tests/Invalid.cs'
                                    changeType = 'edit'
                                    state = 'complete'
                                    spans = @([ordered]@{
                                            startLine = 1
                                            endLine = 1
                                            state = 'complete'
                                            sourceDigest = 'invalid'
                                        })
                                    content = 'class Invalid {}'
                                    byteLength = 16
                                    sourceDigest = 'invalid'
                                })
                        }
                    }
                    if ($CSharpUnknown) {
                        return @{
                            changedFiles = 1
                            changedLines = 1
                            entries = @([ordered]@{
                                    changeTrackingId = 9
                                    path = 'tests/Unknown.cs'
                                    changeType = 'edit'
                                    state = 'unknown'
                                    spans = @([ordered]@{
                                            startLine = 1
                                            endLine = 1
                                            state = 'unknown'
                                            sourceDigest =
                                                $unknownCSharpDigest
                                        })
                                    content = $null
                                    byteLength = 0
                                    sourceDigest =
                                        $unknownCSharpDigest
                                })
                        }
                    }
                    if ($NonCSharpUnknown) {
                        return @{
                            changedFiles = 1
                            changedLines = 0
                            entries = @([ordered]@{
                                    changeTrackingId = 8
                                    path = 'settings/app.yaml'
                                    changeType = 'edit'
                                    state = 'unknown'
                                    spans = @()
                                    content = $null
                                    byteLength = 0
                                    sourceDigest =
                                        $unknownContentDigest
                                })
                        }
                    }
                    return @{
                        changedFiles = 1
                        changedLines = $callLines.Count
                        entries = @([ordered]@{
                                changeTrackingId = 7
                                path = 'tests/Checks.cs'
                                changeType = 'edit'
                                state = 'complete'
                                spans = @($callLines | ForEach-Object {
                                    [ordered]@{
                                        startLine = [int]$_
                                        endLine = [int]$_
                                        state = 'complete'
                                        sourceDigest = $spanDigest
                                    }
                                })
                                content = $content
                                byteLength =
                                    [Text.Encoding]::UTF8.GetByteCount($content)
                                sourceDigest = $contentDigest
                            })
                    }
                }
                'Discussions' {
                    return @{
                        threads = @($DiscussionThreads)
                        count = @($DiscussionThreads).Count
                    }
                }
                default { throw "unexpected:$Operation" }
            }
        }.GetNewClosure()
        return [pscustomobject]@{
            Handler = $provider
            Calls = $calls
            Head = $head
        }
    }
}

Describe 'Named AreEqual current PR bridge' {
    It 'completes in a fresh process with only bridge imports' `
        -TestCases @(
            @{ Mode = 'empty'; ExpectedExit = 0
                ExpectedState = 'completed' }
            @{ Mode = 'human'; ExpectedExit = 0
                ExpectedState = 'completed' }
            @{ Mode = 'drift'; ExpectedExit = 0
                ExpectedState = 'partial' }
        ) {
        param($Mode, $ExpectedExit, $ExpectedState)
        $config = New-BridgeConfig
        $config.enabled = $true
        $configPath = Join-Path $TestDrive `
            "fresh-$Mode-config.json"
        [IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $config -Depth 32) + "`n",
            [Text.UTF8Encoding]::new($false))
        $state = Join-Path $TestDrive "fresh-$Mode-state"
        $manifest = Join-Path $TestDrive `
            "fresh-$Mode-manifest.json"
        $fixture = Join-Path $PSScriptRoot `
            'fixtures\Invoke-NamedAreEqualBridgeFreshProcess.ps1'
        $pwsh = (Get-Command pwsh -CommandType Application |
            Select-Object -First 1).Source
        $output = @(& $pwsh -NoProfile -NonInteractive `
            -File $fixture -ConfigPath $configPath `
            -StateRoot $state -ManifestPath $manifest `
            -RepoRoot $repoRoot -DiscussionMode $Mode 2>&1)
        $LASTEXITCODE | Should -Be $ExpectedExit `
            -Because ($output -join "`n")
        $result = ($output -join "`n") |
            ConvertFrom-Json -AsHashtable -Depth 32
        $result.state | Should -BeExactly $ExpectedState
        if ($ExpectedExit -eq 0) {
            $result.providerWrites | Should -Be 0
            $result.modelWrites | Should -Be 0
            $result.recordCount | Should -Be 1
            $result.recordState | Should -BeExactly $(if (
                    $Mode -ceq 'drift'
                ) { 'unknown' } else { 'completed' })
            $result.calls | Should -Contain 'Discussions'
            $result.observation.lifecycle.status |
                Should -BeExactly 'completed'
            $result.observation.capability |
                Should -BeExactly `
                'bpm-named-areequal-arguments@1'
            $result.observation.execution.modelStarts |
                Should -Be 0
            $result.observation.effects.providerWrites |
                Should -Be 0
            $finding = @(
                $result.observation.findings |
                    Select-Object -First 1)
            $finding | Should -HaveCount 1
            $finding[0].anchor.path |
                Should -BeExactly 'tests/Checks.cs'
            $finding[0].anchor.line | Should -Be 6
            if ($Mode -ceq 'human') {
                $artifactKinds = @(
                    $result.observation.sourceArtifacts.kind)
                $artifactKinds | Should -Contain `
                    'owner-v2-discussion-snapshot'
                $artifactKinds | Should -Contain `
                    'owner-v2-discussion-mapping'
                $artifactKinds | Should -Contain `
                    'owner-v2-discussion-reviewer-identity'
                $artifactKinds | Should -Contain `
                    'owner-v2-discussion-raw-page'
                $result.observation.effects.dedupe.wouldCreate |
                    Should -Be 1
                $finding[0].reconciliation.discussionSha256 |
                    Should -Match '^[0-9a-f]{64}$'
            }
        }
        if ($Mode -ceq 'drift') {
            @($result.outcomes | Where-Object {
                    $_ -is [Collections.IDictionary] -and
                    $_.Contains('stage') -and
                    [string]$_['stage'] -ceq 'post-head' -and
                    [string]$_['state'] -ceq 'unknown'
                }) | Should -HaveCount 1
        }
    }

    It 'is default-off with no reads or durable state' {
        $config = New-BridgeConfig
        $provider = New-BridgeProvider -Config $config
        $state = Join-Path $TestDrive 'disabled-state'
        $manifest = Join-Path $TestDrive 'disabled-manifest.json'
        $result = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $provider.Handler `
            -StateRoot $state -ManifestPath $manifest `
            -RepositoryRoot $repoRoot

        $result.state | Should -BeExactly 'disabled'
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
        $provider.Calls.Count | Should -Be 0
        Test-Path -LiteralPath $state | Should -BeFalse
        Test-Path -LiteralPath $manifest | Should -BeFalse
    }

    It 'discovers a current head and writes one completed model-free observation' {
        $config = New-BridgeConfig
        $config.enabled = $true
        $provider = New-BridgeProvider -Config $config
        $state = Join-Path $TestDrive 'active-state'
        $manifest = Join-Path $TestDrive 'named-manifest.json'
        $result = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $provider.Handler `
            -StateRoot $state -ManifestPath $manifest `
            -RepositoryRoot $repoRoot -Run

        $result.state | Should -BeExactly 'completed' `
            -Because (($result.intake | ConvertTo-Json -Depth 12 -Compress) +
                '; calls=' + ($provider.Calls -join ','))
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
        @($result.records) | Should -HaveCount 1
        $result.records[0].state | Should -BeExactly 'completed'
        $cohort = Get-Content -LiteralPath $manifest -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
        $cohort.kind | Should -BeExactly `
            'named-areequal-v2-preview-cohort'
        $cohort.entries[0].subject.pullRequestId | Should -Be 42
        $identity = [string]$result.records[0].identity
        $observation = Get-ChildItem -LiteralPath $state -Recurse -File `
            -Filter "$identity.json" |
            Where-Object { $_.Directory.Name -ceq 'observations' } |
            Select-Object -First 1 |
            ForEach-Object {
                Get-Content -LiteralPath $_.FullName -Raw |
                    ConvertFrom-Json -AsHashtable -Depth 32
            }
        $observation.capability | Should -BeExactly `
            'bpm-named-areequal-arguments@1'
        $observation.lifecycle.status | Should -BeExactly 'completed'
        $observation.counts.violations | Should -Be 1
        $observation.effects.dedupe.wouldCreate | Should -Be 1
        $observation.execution.modelStarts | Should -Be 0
        $observation.effects.providerWrites | Should -Be 0
        $provider.Calls | Should -Contain 'ListPage'
        $provider.Calls | Should -Contain 'Changes'
        $provider.Calls | Should -Contain 'Discussions'
    }

    It 'ignores unrelated outdated discussion but retains relevant discussion ambiguity' {
        $config = New-BridgeConfig
        $config.enabled = $true
        $human = [ordered]@{
            id = '44444444-4444-4444-4444-444444444444'
            descriptor = 'aad.human'
            uniqueName = 'human@example.invalid'
        }
        $newThread = {
            param(
                [string]$Path,
                [int]$Line,
                [string]$Body,
                [int]$Iteration,
                [AllowNull()][Collections.IDictionary]$Author
            )
            [ordered]@{
                id = 9
                status = 'active'
                isDeleted = $false
                threadContext = [ordered]@{
                    filePath = $Path
                    rightFileStart = [ordered]@{
                        line = $Line
                        offset = 1
                    }
                    rightFileEnd = [ordered]@{
                        line = $Line
                        offset = 1
                    }
                }
                pullRequestThreadContext = [ordered]@{
                    changeTrackingId = 7
                    iterationContext = [ordered]@{
                        firstComparingIteration = 1
                        secondComparingIteration = $Iteration
                    }
                }
                comments = @([ordered]@{
                        id = 10
                        parentCommentId = 0
                        commentType = 1
                        isDeleted = $false
                        content = $Body
                        author = $Author
                    })
            }
        }

        $unrelatedProvider = New-BridgeProvider -Config $config `
            -DiscussionThreads @(& $newThread `
                '/docs/legacy.md' 1 'Unrelated historical review.' 2 $human)
        $unrelatedState = Join-Path $TestDrive 'unrelated-outdated-state'
        $unrelated = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $unrelatedProvider.Handler `
            -StateRoot $unrelatedState `
            -ManifestPath (Join-Path $TestDrive 'unrelated-outdated-manifest.json') `
            -RepositoryRoot $repoRoot -Run
        $unrelated.intake.heads[0].discussion.outdated | Should -Be 1
        $unrelated.intake.heads[0].rules[0].state | Should -BeExactly 'pending'
        $unrelated.intake.gapCounts.unknownRules | Should -Be 0
        $unrelatedObservation = Get-ChildItem -LiteralPath $unrelatedState `
            -Recurse -File -Filter "$($unrelated.records[0].identity).json" |
            Where-Object { $_.Directory.Name -ceq 'observations' } |
            Select-Object -First 1 |
            ForEach-Object {
                Get-Content -LiteralPath $_.FullName -Raw |
                    ConvertFrom-Json -AsHashtable -Depth 32
            }
        $unrelatedObservation.effects.dedupe.wouldCreate | Should -Be 1
        $unrelatedObservation.effects.dedupe.unknown | Should -Be 0

        $historicalProvider = New-BridgeProvider -Config $config `
            -DiscussionThreads @(& $newThread `
                '/tests/Checks.cs' 6 `
                'Use named arguments for Assert.AreEqual.' 2 $human)
        $historicalState = Join-Path $TestDrive 'relevant-outdated-state'
        $historical = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $historicalProvider.Handler `
            -StateRoot $historicalState `
            -ManifestPath (Join-Path $TestDrive 'relevant-outdated-manifest.json') `
            -RepositoryRoot $repoRoot -Run
        $historical.intake.heads[0].rules[0].state | Should -BeExactly 'pending'
        $historicalObservation = Get-ChildItem -LiteralPath $historicalState `
            -Recurse -File -Filter "$($historical.records[0].identity).json" |
            Where-Object { $_.Directory.Name -ceq 'observations' } |
            Select-Object -First 1 |
            ForEach-Object {
                Get-Content -LiteralPath $_.FullName -Raw |
                    ConvertFrom-Json -AsHashtable -Depth 32
            }
        $historicalObservation.effects.dedupe.wouldCreate | Should -Be 0
        $historicalObservation.effects.dedupe.unknown | Should -Be 1
        $historicalObservation.findings[0].reconciliation.reason |
            Should -BeExactly 'historical-human-review-needs-review'

        $ambiguousIdentityProvider = New-BridgeProvider -Config $config `
            -DiscussionThreads @(& $newThread `
                '/tests/Checks.cs' 6 `
                'Use named arguments for Assert.AreEqual.' 3 @{})
        $ambiguousState = Join-Path $TestDrive 'ambiguous-identity-state'
        $ambiguous = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $ambiguousIdentityProvider.Handler `
            -StateRoot $ambiguousState `
            -ManifestPath (Join-Path $TestDrive 'ambiguous-identity-manifest.json') `
            -RepositoryRoot $repoRoot -Run
        $ambiguousObservation = Get-ChildItem -LiteralPath $ambiguousState `
            -Recurse -File -Filter "$($ambiguous.records[0].identity).json" |
            Where-Object { $_.Directory.Name -ceq 'observations' } |
            Select-Object -First 1 |
            ForEach-Object {
                Get-Content -LiteralPath $_.FullName -Raw |
                    ConvertFrom-Json -AsHashtable -Depth 32
            }
        $ambiguousObservation.effects.dedupe.wouldCreate | Should -Be 0
        $ambiguousObservation.effects.dedupe.unknown | Should -Be 1
        $ambiguousObservation.findings[0].reconciliation.reason |
            Should -BeExactly 'human-reviewer-identity-ambiguous'
    }

    It 'does not qualify or create when required Item content is unavailable' {
        $config = New-BridgeConfig
        $config.enabled = $true
        $provider = New-BridgeProvider `
            -Config $config -ChangeFailure 'item-content-unavailable'
        $state = Join-Path $TestDrive 'missing-item-state'
        $manifest = Join-Path $TestDrive 'missing-item-manifest.json'
        $result = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $provider.Handler `
            -StateRoot $state -ManifestPath $manifest `
            -RepositoryRoot $repoRoot -Run

        $result.state | Should -BeExactly 'partial'
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
        @($result.records) | Should -HaveCount 0
        @($result.outcomes | Where-Object {
                [string]$_.stage -ceq 'snapshot' -and
                [string]$_.state -ceq 'unknown'
            }) | Should -HaveCount 1
        Test-Path -LiteralPath $manifest | Should -BeFalse
        @(Get-ChildItem -LiteralPath $state -Recurse -File `
                -ErrorAction SilentlyContinue |
            Where-Object { $_.Directory.Name -ceq 'observations' }) |
            Should -HaveCount 0
    }

    It 'completes when only an unknown non-CSharp file changed' {
        $config = New-BridgeConfig
        $config.enabled = $true
        $provider = New-BridgeProvider `
            -Config $config -NonCSharpUnknown
        $state = Join-Path $TestDrive `
            'non-csharp-state'
        $manifest = Join-Path $TestDrive `
            'non-csharp-manifest.json'
        $result = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $provider.Handler `
            -StateRoot $state -ManifestPath $manifest `
            -RepositoryRoot $repoRoot -Run

        $result.state | Should -BeExactly 'completed' `
            -Because (
                $result |
                    ConvertTo-Json -Depth 16 -Compress)
        @($result.records) | Should -HaveCount 1
        $result.records[0].state |
            Should -BeExactly 'completed'
        $identity = [string]$result.records[0].identity
        $observation = Get-ChildItem `
            -LiteralPath $state -Recurse -File `
            -Filter "$identity.json" |
            Where-Object {
                $_.Directory.Name -ceq
                    'observations'
            } | Select-Object -First 1 |
            ForEach-Object {
                Get-Content -LiteralPath $_.FullName `
                    -Raw |
                    ConvertFrom-Json -AsHashtable `
                        -Depth 64
            }
        $observation.lifecycle.status |
            Should -BeExactly 'completed'
        $observation.findingsComplete |
            Should -BeTrue
        $observation.counts.unknown | Should -Be 0
        @($observation.findings) | Should -HaveCount 0
        $observation.effects.providerWrites |
            Should -Be 0
        $observation.execution.modelStarts |
            Should -Be 0
    }

    It 'retains a bounded diagnostic for unknown CSharp evidence' {
        $config = New-BridgeConfig
        $config.enabled = $true
        $provider = New-BridgeProvider `
            -Config $config -CSharpUnknown
        $state = Join-Path $TestDrive `
            'unknown-csharp-state'
        $manifest = Join-Path $TestDrive `
            'unknown-csharp-manifest.json'
        $result = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $provider.Handler `
            -StateRoot $state -ManifestPath $manifest `
            -RepositoryRoot $repoRoot -Run

        $result.state | Should -BeExactly 'partial'
        @($result.records) | Should -HaveCount 1
        $result.records[0].state |
            Should -BeExactly 'unknown'
        $failure = @($result.outcomes |
            Where-Object {
                [string]$_.stage -ceq
                    'evaluation'
            })
        $failure | Should -HaveCount 1
        $failure[0].state | Should -BeExactly 'unknown'
        $failure[0].validationErrors |
            Should -Contain (
                'file-evidence-unknown: File evidence for ordinal 0 was incomplete or unknown.')
    }

    It 'retains a bounded package-preflight diagnostic' {
        $config = New-BridgeConfig
        $config.enabled = $true
        $provider = New-BridgeProvider `
            -Config $config -InvalidCSharpDigest
        $state = Join-Path $TestDrive `
            'invalid-csharp-state'
        $manifest = Join-Path $TestDrive `
            'invalid-csharp-manifest.json'
        $result = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $provider.Handler `
            -StateRoot $state -ManifestPath $manifest `
            -RepositoryRoot $repoRoot -Run

        $result.state | Should -BeExactly 'partial'
        @($result.records) | Should -HaveCount 0
        $failure = @($result.outcomes |
            Where-Object {
                [string]$_.stage -ceq
                    'package-preflight'
            })
        $failure | Should -HaveCount 1
        $failure[0].state | Should -BeExactly 'unknown'
        $failure[0].diagnostic.category |
            Should -BeExactly 'invalid-evidence'
        $failure[0].diagnostic.operation |
            Should -BeExactly 'package-preflight'
        $failure[0].diagnostic.fileOrdinal |
            Should -BeNullOrEmpty
        $failure[0].diagnostic.messageSha256 |
            Should -Match '^[0-9a-f]{64}$'
        $failure[0].diagnostic.Keys |
            Should -Not -Contain 'message'
        $failure[0].diagnostic.Keys |
            Should -Not -Contain 'path'
    }

    It 'keeps malformed changed paths UNKNOWN for <Mode>' `
        -TestCases @(
            @{ Mode = 'null' },
            @{ Mode = 'whitespace' }
        ) {
        param($Mode)
        $config = New-BridgeConfig
        $config.enabled = $true
        $provider = New-BridgeProvider `
            -Config $config -InvalidPathMode $Mode
        $state = Join-Path $TestDrive `
            "invalid-path-$Mode-state"
        $manifest = Join-Path $TestDrive `
            "invalid-path-$Mode-manifest.json"
        $result = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $provider.Handler `
            -StateRoot $state -ManifestPath $manifest `
            -RepositoryRoot $repoRoot -Run

        $result.state | Should -BeExactly 'partial'
        @($result.records) | Should -HaveCount 0
        $failure = @($result.outcomes |
            Where-Object {
                [string]$_.stage -ceq 'snapshot'
            })
        $failure | Should -HaveCount 1
        $failure[0].state | Should -BeExactly 'unknown'
        $failure[0].reason |
            Should -BeExactly 'acquisition-incomplete'
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
    }

    It 'keeps malformed CSharp spans UNKNOWN for <Mode>' `
        -TestCases @(
            @{ Mode = 'zero' },
            @{ Mode = 'nonnumeric' },
            @{ Mode = 'out-of-range' }
        ) {
        param($Mode)
        $config = New-BridgeConfig
        $config.enabled = $true
        $provider = New-BridgeProvider `
            -Config $config `
            -MalformedCSharpSpan $Mode
        $state = Join-Path $TestDrive `
            "malformed-span-$Mode-state"
        $manifest = Join-Path $TestDrive `
            "malformed-span-$Mode-manifest.json"
        $result = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $provider.Handler `
            -StateRoot $state -ManifestPath $manifest `
            -RepositoryRoot $repoRoot -Run

        $result.state | Should -BeExactly 'partial'
        @($result.records) | Should -HaveCount 0
        $failure = @($result.outcomes |
            Where-Object {
                [string]$_.state -ceq 'unknown'
            })
        $failure | Should -HaveCount 1
        $failure[0].stage |
            Should -BeExactly 'package-preflight'
        $failure[0].reason |
            Should -BeExactly 'acquisition-incomplete'
        $failure[0].diagnostic.messageSha256 |
            Should -Match '^[0-9a-f]{64}$'
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
    }

    It 'uses known-empty only for a complete inventory with zero eligible heads' {
        $config = New-BridgeConfig
        $config.enabled = $true
        $provider = New-BridgeProvider -Config $config -IsDraft $true
        $state = Join-Path $TestDrive 'known-empty-state'
        $manifest = Join-Path $TestDrive 'known-empty-manifest.json'
        $result = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $provider.Handler `
            -StateRoot $state -ManifestPath $manifest `
            -RepositoryRoot $repoRoot -Run

        $result.state | Should -BeExactly 'known-empty'
        $result.intake.populationKnown | Should -BeTrue
        $result.intake.inventory.state | Should -BeExactly 'complete'
        $result.intake.inventory.eligible | Should -Be 0
        Test-Path -LiteralPath $manifest | Should -BeFalse
    }

    It 'keeps local-profile A plus actual ADO principal B unknown' {
        $config = New-BridgeConfig
        $config.enabled = $true
        $provider = New-BridgeProvider -Config $config `
            -IdentityOverride ([ordered]@{
                id = '99999999-9999-9999-9999-999999999999'
                descriptor = 'aad.other-principal'
                uniqueName = [string]$config.expectedAccount.uniqueName
            })
        $state = Join-Path $TestDrive 'identity-mismatch-state'
        $manifest = Join-Path $TestDrive 'identity-mismatch-manifest.json'
        $result = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $provider.Handler `
            -StateRoot $state -ManifestPath $manifest `
            -RepositoryRoot $repoRoot -Run

        $result.state | Should -BeExactly 'unknown'
        $result.intake.reasonCodes | Should -Contain 'account-mismatch'
        $result.intake.counts.attempted | Should -Be 0
        @($result.records) | Should -HaveCount 0
        Test-Path -LiteralPath $manifest | Should -BeFalse
    }

    It 'preserves 2/5 quota across changed heads and fresh processes' {
        $config = New-BridgeConfig
        $config.enabled = $true
        $configPath = Join-Path $TestDrive 'named-config.json'
        [IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $config -Depth 32) + "`n",
            [Text.UTF8Encoding]::new($false))

        $stateA = Join-Path $TestDrive 'head-a-state'
        $manifestA = Join-Path $TestDrive 'head-a-manifest.json'
        $providerA = New-BridgeProvider `
            -Config $config -SourceCommit ('c' * 40) -MethodCount 3
        $bridgeA = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $providerA.Handler `
            -StateRoot $stateA -ManifestPath $manifestA `
            -RepositoryRoot $repoRoot -Run
        $identityA = [string]$bridgeA.records[0].identity

        $deliveryBase = Join-Path $TestDrive 'quota-delivery'
        $boundary = Join-Path $TestDrive 'quota-boundary'
        New-Item -ItemType Directory -Path $boundary | Out-Null
        $delivery = Initialize-AutomaticOwnerV2DeliveryRoot `
            -DeliveryRoot $deliveryBase -RepoRoot $boundary `
            -Delivery named-areequal
        $key = Get-AutomaticOwnerV2ServiceKey `
            -DeliveryRoot $delivery.Root -Delivery named-areequal
        $evidenceA = Read-AutomaticNamedAreEqualEvidence `
            -StateRoot $stateA -Identity $identityA `
            -ToolkitConfigPath $configPath -RepoRoot $repoRoot
        $policy = New-AutomaticOwnerV2ServicePolicy `
            -Evidence $evidenceA -PolicyId 'named-quota-test' `
            -MaxCreatesPerRun 2 -MaxCreatesPerPullRequest 5 `
            -CreatedUtc '20261006T000000Z'
        $policyPath = Join-Path $delivery.Root `
            'policies\named-quota-test.json'
        [void](Write-AutomaticOwnerV2ServicePolicy `
            -Path $policyPath -Policy $policy -Key $key)
        $providerStateA = Join-Path $TestDrive 'quota-provider-a.json'
        $providerStateB = Join-Path $TestDrive 'quota-provider-b.json'
        $fixture = Join-Path $PSScriptRoot `
            'fixtures\Invoke-NamedAreEqualOfflineDelivery.ps1'
        $pwsh = (Get-Command pwsh).Source

        $firstOutput = @(& $pwsh -NoProfile -NonInteractive -File $fixture `
            -StateRoot $stateA -Identity $identityA `
            -ConfigPath $configPath -DeliveryRoot $delivery.Root `
            -PolicyPath $policyPath -ProviderStatePath $providerStateA `
            -RepoRoot $repoRoot 2>&1)
        $LASTEXITCODE | Should -Be 2 `
            -Because ($firstOutput -join "`n")
        $first = ($firstOutput -join "`n") |
            ConvertFrom-Json -AsHashtable -Depth 32
        $first.providerWrites | Should -Be 2

        $stateB = Join-Path $TestDrive 'head-b-state'
        $manifestB = Join-Path $TestDrive 'head-b-manifest.json'
        $providerB = New-BridgeProvider `
            -Config $config -SourceCommit ('e' * 40) -MethodCount 4
        $bridgeB = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $providerB.Handler `
            -StateRoot $stateB -ManifestPath $manifestB `
            -RepositoryRoot $repoRoot -Run
        $identityB = [string]$bridgeB.records[0].identity

        $secondOutput = @(& $pwsh -NoProfile -NonInteractive -File $fixture `
            -StateRoot $stateB -Identity $identityB `
            -ConfigPath $configPath -DeliveryRoot $delivery.Root `
            -PolicyPath $policyPath -ProviderStatePath $providerStateB `
            -RepoRoot $repoRoot 2>&1)
        $LASTEXITCODE | Should -Be 2 `
            -Because ($secondOutput -join "`n")
        $second = ($secondOutput -join "`n") |
            ConvertFrom-Json -AsHashtable -Depth 32
        $second.providerWrites | Should -Be 2

        $thirdOutput = @(& $pwsh -NoProfile -NonInteractive -File $fixture `
            -StateRoot $stateB -Identity $identityB `
            -ConfigPath $configPath -DeliveryRoot $delivery.Root `
            -PolicyPath $policyPath -ProviderStatePath $providerStateB `
            -RepoRoot $repoRoot 2>&1)
        $LASTEXITCODE | Should -Be 2 `
            -Because ($thirdOutput -join "`n")
        $third = ($thirdOutput -join "`n") |
            ConvertFrom-Json -AsHashtable -Depth 32
        $third.providerWrites | Should -Be 1

        $fourthOutput = @(& $pwsh -NoProfile -NonInteractive -File $fixture `
            -StateRoot $stateB -Identity $identityB `
            -ConfigPath $configPath -DeliveryRoot $delivery.Root `
            -PolicyPath $policyPath -ProviderStatePath $providerStateB `
            -RepoRoot $repoRoot 2>&1)
        $LASTEXITCODE | Should -Be 3
        $fourth = ($fourthOutput -join "`n") |
            ConvertFrom-Json -AsHashtable -Depth 32
        $fourth.providerWrites | Should -Be 0
        $providerLedgerA = Get-Content -LiteralPath $providerStateA -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
        $providerLedgerB = Get-Content -LiteralPath $providerStateB -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
        ([int]$providerLedgerA.writes + [int]$providerLedgerB.writes) |
            Should -Be 5
    }

    It 'preserves an ambiguous-write block across a fresh process' {
        $config = New-BridgeConfig
        $config.enabled = $true
        $configPath = Join-Path $TestDrive 'ambiguous-config.json'
        [IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $config -Depth 32) + "`n",
            [Text.UTF8Encoding]::new($false))
        $state = Join-Path $TestDrive 'ambiguous-state'
        $manifest = Join-Path $TestDrive 'ambiguous-manifest.json'
        $provider = New-BridgeProvider -Config $config -MethodCount 1
        $bridge = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $provider.Handler `
            -StateRoot $state -ManifestPath $manifest `
            -RepositoryRoot $repoRoot -Run
        $identity = [string]$bridge.records[0].identity

        $deliveryBase = Join-Path $TestDrive 'ambiguous-delivery'
        $boundary = Join-Path $TestDrive 'ambiguous-boundary'
        New-Item -ItemType Directory -Path $boundary | Out-Null
        $delivery = Initialize-AutomaticOwnerV2DeliveryRoot `
            -DeliveryRoot $deliveryBase -RepoRoot $boundary `
            -Delivery named-areequal
        $key = Get-AutomaticOwnerV2ServiceKey `
            -DeliveryRoot $delivery.Root -Delivery named-areequal
        $evidence = Read-AutomaticNamedAreEqualEvidence `
            -StateRoot $state -Identity $identity `
            -ToolkitConfigPath $configPath -RepoRoot $repoRoot
        $policy = New-AutomaticOwnerV2ServicePolicy `
            -Evidence $evidence -PolicyId 'named-ambiguous-test' `
            -MaxCreatesPerRun 2 -MaxCreatesPerPullRequest 5 `
            -CreatedUtc '20261006T000000Z'
        $policyPath = Join-Path $delivery.Root `
            'policies\named-ambiguous-test.json'
        [void](Write-AutomaticOwnerV2ServicePolicy `
            -Path $policyPath -Policy $policy -Key $key)
        $providerState = Join-Path $TestDrive 'ambiguous-provider.json'
        $fixture = Join-Path $PSScriptRoot `
            'fixtures\Invoke-NamedAreEqualOfflineDelivery.ps1'
        $pwsh = (Get-Command pwsh).Source

        $firstOutput = @(& $pwsh -NoProfile -NonInteractive -File $fixture `
            -StateRoot $state -Identity $identity `
            -ConfigPath $configPath -DeliveryRoot $delivery.Root `
            -PolicyPath $policyPath -ProviderStatePath $providerState `
            -RepoRoot $repoRoot -Unconfirmed 2>&1)
        $LASTEXITCODE | Should -Be 3
        $first = ($firstOutput -join "`n") |
            ConvertFrom-Json -AsHashtable -Depth 32
        $first.events[0].outcome | Should -BeExactly `
            'ambiguous-post-write'

        $secondOutput = @(& $pwsh -NoProfile -NonInteractive -File $fixture `
            -StateRoot $state -Identity $identity `
            -ConfigPath $configPath -DeliveryRoot $delivery.Root `
            -PolicyPath $policyPath -ProviderStatePath $providerState `
            -RepoRoot $repoRoot -SkipObservationRefresh 2>&1)
        $LASTEXITCODE | Should -Be 3
        $second = ($secondOutput -join "`n") |
            ConvertFrom-Json -AsHashtable -Depth 32
        $second.providerWrites | Should -Be 0
        $providerLedger = Get-Content -LiteralPath $providerState -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
        $providerLedger.writes | Should -Be 1
    }
}
