BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1" -Force

    $script:PolicyText = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot '..\src\DevPilot.OwnerCapability\Policy\test-class-coverage.v1.txt'),
        [Text.UTF8Encoding]::new($false))
    $script:GenericManifest = Get-Content (
        Join-Path $PSScriptRoot 'fixtures\owner-orchestrator\generic-cohort.json'
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 64

    function Get-CoverageDigest {
        param([string]$Text)
        'v1:sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))
        ).ToLowerInvariant()
    }

    function New-CoverageTestManifest {
        param(
            [string]$First = "using Microsoft.VisualStudio.TestTools.UnitTesting;`n[TestClass]`npublic class MissingTests {}",
            [string]$Second = "using Microsoft.VisualStudio.TestTools.UnitTesting;`nusing System.Diagnostics.CodeAnalysis;`n[TestClass]`n[ExcludeFromCodeCoverage]`npublic class CoveredTests {}",
            [string]$SourceCommit = ('a' * 40)
        )
        $manifest = $script:GenericManifest | ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $manifest.kind = 'coverage-v2-preview-cohort'
        $entry = $manifest.entries[0]
        $entry.id = 'coverage-test'
        $entry.head.sourceCommit = $SourceCommit
        $entry.rule.repositoryId = 'rules-example'
        $entry.rule.path = 'src/DevPilot.OwnerCapability/Policy/test-class-coverage.v1.txt'
        $entry.rule.section = 'bpm-test-class-coverage@1'
        $entry.rule.hash = Get-CoverageDigest $script:PolicyText
        $entry.rule.length = [Text.Encoding]::UTF8.GetByteCount($script:PolicyText)
        $entry.capability.id = 'bpm-test-class-coverage@1'
        $entry.capability.digest = Get-CoverageDigest 'test-class-coverage-capability-v1'
        $entry.model.id = 'none'
        $entry.model.digest = Get-CoverageDigest 'none'
        $entry.config.id = 'coverage-v1-user-approved'
        $entry.config.digest = Get-CoverageDigest 'coverage-v1-user-approved'
        $entry.replay.modelRecords = @()
        $package = $entry.acquisition.package
        foreach ($name in @('subjectBefore', 'subjectAfter', 'rule')) {
            $package[$name].sourceCommit = $SourceCommit
        }
        $package.subjectBefore.changedFileCount = 2
        $package.subjectAfter.changedFileCount = 2
        $page = $package.changePages[0]
        $page.sourceCommit = $SourceCommit
        $page.changes = @()
        $package.files = @()
        $fileIndex = 0
        foreach ($source in @(
                @{ path = 'tests/MissingTests.cs'; content = $First },
                @{ path = 'tests/CoveredTests.cs'; content = $Second }
            )) {
            $fileIndex++
            $file = $script:GenericManifest.entries[0].acquisition.package.files[0] |
                ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32
            $file.sourceCommit = $SourceCommit
            $file.path = $source.path
            $file.content = $source.content
            $file.byteLength = [Text.Encoding]::UTF8.GetByteCount($source.content)
            $file.sourceDigest = Get-CoverageDigest $source.content
            $change = $script:GenericManifest.entries[0].acquisition.package.changePages[0].changes[0] |
                ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32
            $change.path = $source.path
            $change.changeType = 'added'
            $change.sourceDigest = Get-CoverageDigest "change:$fileIndex"
            $change.spans = @([ordered]@{
                    startLine = 1
                    endLine = [regex]::Split($source.content, '\r?\n').Count
                    state = 'complete'
                    sourceDigest = Get-CoverageDigest "span:$fileIndex"
                })
            $page.changes += $change
            $package.files += $file
        }
        foreach ($key in @('ruleRepositoryId', 'rulePath', 'ruleCommit',
                'ruleSection', 'ruleHash', 'ruleLength')) {
            $entryKey = $key.Substring(4, 1).ToLowerInvariant() + $key.Substring(5)
            $package.rule[$key] = $entry.rule[$entryKey]
        }
        $package.rule.content = $script:PolicyText
        $package.rule.sourceDigest = Get-CoverageDigest 'coverage-rule-source'
        $entry.acquisition.payloadDigest =
            (New-OwnerReplayFixture -Package $package).PayloadDigest
        return $manifest
    }

    function Invoke-CoverageTestReplay {
        param([Collections.IDictionary]$Manifest)
        $path = Join-Path $TestDrive ('manifest-' + [guid]::NewGuid().ToString('N') + '.json')
        $root = Join-Path $TestDrive ('state-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($path, ($Manifest | ConvertTo-Json -Depth 64),
            [Text.UTF8Encoding]::new($false))
        $prepared = Invoke-OwnerV2PreviewPrepare -StateRoot $root -ManifestPath $path
        $run = Invoke-OwnerV2PreviewRun -StateRoot $root -ManifestPath $path
        $observationPath = Join-Path $prepared.records[0].capabilityRoot (
            "observations\$($prepared.records[0].identity).json"
        )
        $observation = Get-Content -LiteralPath $observationPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
        return [pscustomobject]@{
            Prepared = $prepared
            Run = $run
            Observation = $observation
            Manifest = $Manifest
        }
    }

    function New-CoverageTestContract {
            param([Collections.IDictionary]$Entry)
            New-OwnerAcquisitionContract `
                -RepositoryId ([string]$Entry.subject.repositoryId) `
                -ProjectId ([string]$Entry.subject.projectId) `
                -PullRequestId ([long]$Entry.subject.pullRequestId) `
                -SourceCommit ([string]$Entry.head.sourceCommit) `
                -TargetCommit ([string]$Entry.target.targetCommit) `
                -TargetRef ([string]$Entry.target.targetRef) `
                -RuleRepositoryId ([string]$Entry.rule.repositoryId) `
                -RulePath ([string]$Entry.rule.path) `
                -RuleCommit ([string]$Entry.rule.commit) `
                -RuleSection ([string]$Entry.rule.section) `
                -RuleHash ([string]$Entry.rule.hash) `
                -RuleLength ([long]$Entry.rule.length) `
                -ConfigId ([string]$Entry.config.id) `
                -ConfigDigest ([string]$Entry.config.digest) `
                -CapabilityId ([string]$Entry.capability.id) `
                -CapabilityDigest ([string]$Entry.capability.digest)
        }

        function New-CoverageTestSnapshot {
            param([object]$Contract, [object[]]$Threads)
            $request = $Contract.Request
            $page = [ordered]@{
                schemaVersion = 1
                repositoryId = $request.RepositoryId
                projectId = $request.ProjectId
                pullRequestId = $request.PullRequestId
                sourceCommit = $request.SourceCommit
                targetCommit = $request.TargetCommit
                targetRef = $request.TargetRef
                pageOrdinal = 0
                state = 'complete'
                sourceDigest = Get-CoverageDigest 'coverage-discussion-page'
                nextToken = $null
                threads = @($Threads)
            }
            $provider = New-OwnerReadOnlyProviderAdapter -Name 'coverage-discussion-fixture' `
                -Handler { param($Operation, $Arguments) return $page }.GetNewClosure()
            Get-OwnerDiscussionSnapshot -Contract $Contract -Provider $provider
        }

        function New-CoverageTestThread {
            param(
                [object]$Contract,
                [Collections.IDictionary]$Finding,
                [string]$Body,
                [int]$ThreadId = 100,
                [int]$Line = 0,
                [string]$Status = 'active',
                [bool]$Human = $true,
                [bool]$Outdated = $false,
                [bool]$Deleted = $false,
                [string]$Context = 'current'
            )
            [ordered]@{
                threadId = $ThreadId
                status = $Status
                isDeleted = $Deleted
                isOutdated = $Outdated
                sourceCommit = $(if ($Context -ceq 'current') {
                        [string]$Contract.Request.SourceCommit
                    }
                    else { $null })
                contextState = $Context
                anchor = [ordered]@{
                    path = [string]$Finding.anchor.path
                    line = $(if ($Line -gt 0) { $Line } else { [int]$Finding.anchor.line })
                }
                comments = @([ordered]@{
                        commentId = $ThreadId + 1
                        commentType = 'text'
                        isDeleted = $false
                        reviewerOwned = -not $Human
                        reviewerIdentityState = $(if ($Human) { 'foreign' } else { 'matched' })
                        body = $Body
                        bodyDigest = Get-CoverageDigest $Body
                    })
        }
    }
}

Describe 'Bound test-class coverage capability' {
    It 'finds the changed missing class and records the compliant sibling without model calls' {
        $result = Invoke-CoverageTestReplay -Manifest (New-CoverageTestManifest)
        $result.Run.records[0].state | Should -BeExactly 'completed'
        $result.Observation.capability | Should -BeExactly 'bpm-test-class-coverage@1'
        $result.Observation.counts.eligible | Should -Be 2
        $result.Observation.counts.checked | Should -Be 2
        $result.Observation.counts.violations | Should -Be 1
        $result.Observation.findings[0].identity | Should -Match '^coverage-v2:[0-9a-f]{64}$'
        $result.Observation.findings[0].anchor.symbol | Should -BeExactly 'MissingTests'
        $result.Observation.findings[0].anchor.line | Should -Be 3
        $result.Observation.outcomes[0].state | Should -BeExactly 'compliant'
        $result.Observation.execution.modelStarts | Should -Be 0
        $result.Observation.effects.providerWrites | Should -Be 0
    }

    It 'cannot substitute an Owner cohort, rule, or model for the independent policy' {
        $manifest = New-CoverageTestManifest
        $manifest.kind = 'owner-v2-preview-cohort'
        $path = Join-Path $TestDrive 'wrong-cohort.json'
        [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 64))
        { Invoke-OwnerV2PreviewPrepare -StateRoot (Join-Path $TestDrive 'wrong-state') `
                -ManifestPath $path } | Should -Throw '*separate capability*'
        $manifest.kind = 'coverage-v2-preview-cohort'
        $manifest.entries[0].rule.section = 'owner-policy'
        [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 64))
        { Invoke-OwnerV2PreviewPrepare -StateRoot (Join-Path $TestDrive 'wrong-rule') `
                -ManifestPath $path } | Should -Throw '*separate user-approved rule*'
    }

    It 'does not conclude on an unchanged class when only its method changes' {
        $first = @(
            'using Microsoft.VisualStudio.TestTools.UnitTesting;'
            '[TestClass]'
            'public class MissingTests'
            '{'
            '    [TestMethod]'
            '    public void NeedsOwner() {}'
            '}'
        ) -join "`n"
        $manifest = New-CoverageTestManifest -First $first
        $manifest.entries[0].acquisition.package.changePages[0].changes[0].changeType = 'modified'
        $manifest.entries[0].acquisition.package.changePages[0].changes[0].spans[0].startLine = 6
        $manifest.entries[0].acquisition.package.changePages[0].changes[0].spans[0].endLine = 6
        $manifest.entries[0].acquisition.payloadDigest =
            (New-OwnerReplayFixture -Package $manifest.entries[0].acquisition.package).PayloadDigest
        $result = Invoke-CoverageTestReplay -Manifest $manifest
        $result.Observation.counts.violations | Should -Be 0
        $result.Observation.counts.eligible | Should -Be 1
    }

    It 'isolates replay identities and markers across changed source heads' {
        $old = Invoke-CoverageTestReplay -Manifest (New-CoverageTestManifest)
        $new = Invoke-CoverageTestReplay -Manifest (
            New-CoverageTestManifest -SourceCommit ('d' * 40)
        )
        $old.Prepared.records[0].identity | Should -Not -BeExactly $new.Prepared.records[0].identity
        $old.Observation.subject.headCommit | Should -BeExactly ('a' * 40)
        $new.Observation.subject.headCommit | Should -BeExactly ('d' * 40)
        $oldMarker = Get-TestClassCoverageMarkerKey `
            -Contract (New-CoverageTestContract $old.Manifest.entries[0]) `
            -Finding $old.Observation.findings[0]
        $newMarker = Get-TestClassCoverageMarkerKey `
            -Contract (New-CoverageTestContract $new.Manifest.entries[0]) `
            -Finding $new.Observation.findings[0]
        $oldMarker | Should -Not -BeExactly $newMarker
    }

    It 'rejects mixed generations before preparation' {
        $manifest = New-CoverageTestManifest
        $manifest.entries[0].acquisition.package.subjectAfter.sourceCommit = 'd' * 40
        $manifest.entries[0].acquisition.payloadDigest = (
            New-OwnerReplayFixture -Package $manifest.entries[0].acquisition.package
        ).PayloadDigest
        $path = Join-Path $TestDrive 'mixed-generation.json'
        [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 64))
        { Invoke-OwnerV2PreviewPrepare -StateRoot (Join-Path $TestDrive 'mixed-state') `
                -ManifestPath $path } | Should -Throw '*subject*'
    }

    It 'does not turn unavailable authoritative rule evidence into a coverage finding' {
        $manifest = New-CoverageTestManifest
        $package = $manifest.entries[0].acquisition.package
        $package.rule.state = 'unknown'
        $package.rule.content = $null
        $package.rule.unavailableReason = 'incomplete'
        $manifest.entries[0].acquisition.payloadDigest =
            (New-OwnerReplayFixture -Package $package).PayloadDigest
        $result = Invoke-CoverageTestReplay -Manifest $manifest
        $result.Observation.counts.violations | Should -Be 0
        $result.Observation.lifecycle.status | Should -Not -BeExactly 'completed'
        $result.Observation.effects.providerWrites | Should -Be 0
    }

    It 'fails closed on an incomplete changed span rather than claiming a clean class' {
        $manifest = New-CoverageTestManifest
        $package = $manifest.entries[0].acquisition.package
        $package.changePages[0].changes[0].spans[0].state = 'incomplete'
        $manifest.entries[0].acquisition.payloadDigest =
            (New-OwnerReplayFixture -Package $package).PayloadDigest
        $result = Invoke-CoverageTestReplay -Manifest $manifest
        $result.Observation.lifecycle.status | Should -Not -BeExactly 'completed'
        $result.Observation.counts.uncovered | Should -BeGreaterThan 0
        $result.Observation.effects.providerWrites | Should -Be 0
    }

    It 'keeps a changed class unknown when string lexing cannot establish its declaration' {
        $first = @(
            'using Microsoft.VisualStudio.TestTools.UnitTesting;'
            'public class Helper { string Value() => $"pre {1 /* " */} post"; }'
            '[TestClass]'
            'public class MissingTests {}'
        ) -join "`n"
        $result = Invoke-CoverageTestReplay -Manifest (
            New-CoverageTestManifest -First $first
        )
        $result.Observation.lifecycle.status | Should -Not -BeExactly 'completed'
        $result.Observation.counts.violations | Should -Be 0
        $result.Observation.counts.unknown | Should -BeGreaterThan 0
        $result.Observation.effects.providerWrites | Should -Be 0
    }

    It 'keeps exact human coverage review separate from reviewer no-op and unrelated anchors' {
        $result = Invoke-CoverageTestReplay -Manifest (New-CoverageTestManifest)
        $contract = New-CoverageTestContract $result.Manifest.entries[0]
        $finding = $result.Observation.findings[0]
        $human = New-CoverageTestThread -Contract $contract -Finding $finding `
            -Body 'exclude from code coverage'
        $snapshot = New-CoverageTestSnapshot -Contract $contract -Threads @($human)
        $observed = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $result.Observation -Contract $contract -Snapshot $snapshot
        $observed.findings[0].reconciliation.classification | Should -BeExactly 'humanCovered'
        $observed.findings[0].reconciliation.thread.threadId | Should -Be 100
        $observed.effects.dedupe.wouldCreate | Should -Be 0
        foreach ($variant in @(
                @{ Line = 4 },
                @{ Status = 'closed' },
                @{ Context = 'outdated'; Outdated = $true },
                @{ Deleted = $true }
            )) {
            $thread = New-CoverageTestThread -Contract $contract -Finding $finding `
                -Body 'exclude from code coverage' @variant
            $fresh = $result.Observation | ConvertTo-Json -Depth 64 |
                ConvertFrom-Json -AsHashtable -Depth 64
            $state = Resolve-OwnerV2DiscussionReconciliation -Observation $fresh `
                -Contract $contract `
                -Snapshot (New-CoverageTestSnapshot -Contract $contract -Threads @($thread))
            $state.findings[0].reconciliation.classification | Should -BeExactly $(if ($variant.ContainsKey('Outdated')) {
                    'unknown'
                }
                else { 'wouldCreate' })
        }
        $ambiguous = New-CoverageTestThread -Contract $contract -Finding $finding `
            -Body 'exclude from code coverage' -Context 'ambiguous'
        $fresh = $result.Observation | ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $state = Resolve-OwnerV2DiscussionReconciliation -Observation $fresh `
            -Contract $contract `
            -Snapshot (New-CoverageTestSnapshot -Contract $contract -Threads @($ambiguous))
        $state.findings[0].reconciliation.classification | Should -BeExactly 'unknown'
    }

    It 'treats a negated class exclusion request as ambiguous human review, not coverage' {
        $result = Invoke-CoverageTestReplay -Manifest (New-CoverageTestManifest)
        $contract = New-CoverageTestContract $result.Manifest.entries[0]
        $finding = $result.Observation.findings[0]
        foreach ($body in @(
                'we should NOT exclude from code coverage this one',
                "don't exclude from code coverage",
                "I won't exclude from code coverage here",
                "there's no need to exclude from code coverage",
                "we needn't exclude from code coverage",
                'exclude from code coverage?'
            )) {
            $thread = New-CoverageTestThread -Contract $contract `
                -Finding $finding -Body $body
            $fresh = $result.Observation | ConvertTo-Json -Depth 64 |
                ConvertFrom-Json -AsHashtable -Depth 64
            $state = Resolve-OwnerV2DiscussionReconciliation `
                -Observation $fresh -Contract $contract `
                -Snapshot (New-CoverageTestSnapshot -Contract $contract -Threads @($thread))
            $state.findings[0].reconciliation.classification | Should -BeExactly 'unknown'
            $state.effects.dedupe.wouldCreate | Should -Be 0
        }
        $directive = New-CoverageTestThread -Contract $contract `
            -Finding $finding -Body 'Please exclude from code coverage.'
        $fresh = $result.Observation | ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $state = Resolve-OwnerV2DiscussionReconciliation -Observation $fresh `
            -Contract $contract `
            -Snapshot (New-CoverageTestSnapshot -Contract $contract -Threads @($directive))
        $state.findings[0].reconciliation.classification | Should -BeExactly 'humanCovered'
    }

    It 'preserves violation but blocks auto-create for a closed prior-iteration comment at a shifted class anchor' {
        $result = Invoke-CoverageTestReplay -Manifest (New-CoverageTestManifest)
        $contract = New-CoverageTestContract $result.Manifest.entries[0]
        $finding = $result.Observation.findings[0]
        $finding.anchor.line | Should -Be 3
        $oldThread = New-CoverageTestThread -Contract $contract -Finding $finding `
            -Body 'exclude from code coverage' -Line 2 -Context outdated `
            -Outdated $true -Status closed -Human $false
        $state = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $result.Observation -Contract $contract `
            -Snapshot (New-CoverageTestSnapshot -Contract $contract -Threads @($oldThread))
        $state.counts.violations | Should -Be 1
        $state.findings[0].reconciliation.classification | Should -BeExactly 'unknown'
        $state.findings[0].reconciliation.reason | Should -BeExactly 'historical-human-review-needs-review'
        $state.findings[0].reconciliation.thread.threadId | Should -Be 100
        $state.findings[0].reconciliation.thread.status | Should -BeExactly 'closed'
        $state.effects.dedupe.wouldCreate | Should -Be 0

        $currentFromSameAccount = New-CoverageTestThread -Contract $contract `
            -Finding $finding -Body 'exclude from code coverage' -Human $false
        $fresh = $result.Observation | ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $state = Resolve-OwnerV2DiscussionReconciliation -Observation $fresh `
            -Contract $contract `
            -Snapshot (New-CoverageTestSnapshot -Contract $contract -Threads @($currentFromSameAccount))
        $state.findings[0].reconciliation.classification | Should -BeExactly 'humanCovered'

        $unrelated = New-CoverageTestThread -Contract $contract -Finding $finding `
            -Body 'exclude from code coverage' -Line 10 -Context outdated `
            -Outdated $true -Status closed
        $fresh = $result.Observation | ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $state = Resolve-OwnerV2DiscussionReconciliation -Observation $fresh `
            -Contract $contract `
            -Snapshot (New-CoverageTestSnapshot -Contract $contract -Threads @($unrelated))
        $state.findings[0].reconciliation.classification | Should -BeExactly 'wouldCreate'

        $fresh = $result.Observation | ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $state = Resolve-OwnerV2DiscussionReconciliation -Observation $fresh `
            -Contract $contract `
            -Snapshot (New-CoverageTestSnapshot -Contract $contract -Threads @())
        $state.findings[0].reconciliation.classification | Should -BeExactly 'wouldCreate'
    }

    It 'treats only an exact reviewer marker/body as no-op and refuses copies or duplicates' {
        $result = Invoke-CoverageTestReplay -Manifest (New-CoverageTestManifest)
        $contract = New-CoverageTestContract $result.Manifest.entries[0]
        $finding = $result.Observation.findings[0]
        $marker = Get-TestClassCoverageMarkerKey -Contract $contract -Finding $finding
        $body = Format-TestClassCoverageComment -Contract $contract -Finding $finding `
            -MarkerKey $marker
        foreach ($case in @(
                @{ Threads = @(New-CoverageTestThread -Contract $contract -Finding $finding `
                            -Body $body -Human $false); Expected = 'noOp' },
                @{ Threads = @(New-CoverageTestThread -Contract $contract -Finding $finding `
                            -Body $body -Human $true); Expected = 'unknown' },
                @{ Threads = @(
                        (New-CoverageTestThread -Contract $contract -Finding $finding `
                                -Body $body -Human $false -ThreadId 10),
                        (New-CoverageTestThread -Contract $contract -Finding $finding `
                                -Body $body -Human $false -ThreadId 20)
                    ); Expected = 'unknown' }
            )) {
            $fresh = $result.Observation | ConvertTo-Json -Depth 64 |
                ConvertFrom-Json -AsHashtable -Depth 64
            $state = Resolve-OwnerV2DiscussionReconciliation -Observation $fresh `
                -Contract $contract `
                -Snapshot (New-CoverageTestSnapshot -Contract $contract -Threads $case.Threads)
            $state.findings[0].reconciliation.classification | Should -BeExactly $case.Expected
        }
    }
}
