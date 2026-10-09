BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1" -Force
    . "$PSScriptRoot\..\src\Agents\reviewer\ApprovedOwnerV2Comments.ps1"

    function Get-NamedTestDigest {
        param([string]$Text)
        'v1:sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))
        ).ToLowerInvariant()
    }

    function New-NamedTestManifest {
        param(
            [string]$Content = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
[TestClass]
class Checks {
    [TestMethod]
    void Verify() {
        Assert.AreEqual(0, items.Count);
        Assert.AreEqual(1, other.Count);
    }
    [TestMethod]
    void Other() {
        Assert.AreEqual(expected: 0, actual: items.Count);
    }
}
'@,
            [int]$First = 6,
            [int]$Last = 11
        )
        $manifest = Get-Content (
            Join-Path $PSScriptRoot 'fixtures\owner-orchestrator\generic-cohort.json'
        ) -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        $manifest.kind = 'named-areequal-v2-preview-cohort'
        $entry = $manifest.entries[0]
        $entry.id = 'named-areequal-test'
        $entry.capability.id = 'bpm-named-areequal-arguments@1'
        $entry.capability.digest = Get-NamedTestDigest 'named-areequal-arguments-capability-v1'
        $entry.rule.repositoryId = 'rules-example'
        $entry.rule.path = 'src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt'
        $entry.rule.section = $entry.capability.id
        $policy = [IO.File]::ReadAllText((Join-Path $PSScriptRoot `
            '..\src\DevPilot.OwnerCapability\Policy\named-areequal-arguments.v1.txt'),
            [Text.UTF8Encoding]::new($false))
        $entry.rule.hash = Get-NamedTestDigest $policy
        $entry.rule.length = [Text.Encoding]::UTF8.GetByteCount($policy)
        $entry.model.id = 'none'
        $entry.model.digest = Get-NamedTestDigest 'none'
        $entry.config.id = 'named-areequal-arguments-v1-user-approved'
        $entry.config.digest = Get-NamedTestDigest $entry.config.id
        $entry.replay.modelRecords = @()
        $package = $entry.acquisition.package
        $package.rule.ruleRepositoryId = $entry.rule.repositoryId
        $package.rule.rulePath = $entry.rule.path
        $package.rule.ruleSection = $entry.rule.section
        $package.rule.ruleHash = $entry.rule.hash
        $package.rule.ruleLength = $entry.rule.length
        $package.rule.content = $policy
        $package.files[0].content = $Content
        $package.files[0].byteLength = [Text.Encoding]::UTF8.GetByteCount($Content)
        $package.files[0].sourceDigest = Get-NamedTestDigest $Content
        $package.files[0].path = 'tests/Checks.cs'
        $package.changePages[0].changes[0].path = 'tests/Checks.cs'
        $package.changePages[0].changes[0].changeType = 'modified'
        $package.changePages[0].changes[0].spans = @([ordered]@{
                startLine = $First
                endLine = $Last
                state = 'complete'
                sourceDigest = Get-NamedTestDigest 'named-span'
            })
        $entry.acquisition.payloadDigest = (New-OwnerReplayFixture -Package $package).PayloadDigest
        return $manifest
    }

    function Invoke-NamedTestReplay {
        param([Collections.IDictionary]$Manifest)
        $path = Join-Path $TestDrive ('named-' + [guid]::NewGuid().ToString('N') + '.json')
        $root = Join-Path $TestDrive ('named-state-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($path, ($Manifest | ConvertTo-Json -Depth 64),
            [Text.UTF8Encoding]::new($false))
        $prepared = Invoke-OwnerV2PreviewPrepare -StateRoot $root -ManifestPath $path
        $run = Invoke-OwnerV2PreviewRun -StateRoot $root -ManifestPath $path
        $observationPath = Join-Path $prepared.records[0].capabilityRoot (
            "observations\$($prepared.records[0].identity).json"
        )
        return [pscustomobject]@{
            Prepared = $prepared
            Run = $run
            Observation = Get-Content -LiteralPath $observationPath -Raw |
                ConvertFrom-Json -AsHashtable -Depth 64
            Entry = $Manifest.entries[0]
        }
    }

    function New-NamedTestContract {
        param($Entry)
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

    function New-NamedTestDiscussion {
        param($Contract, [object[]]$Threads)
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
            sourceDigest = Get-NamedTestDigest 'discussion-page'
            nextToken = $null
            threads = $Threads
        }
        $provider = New-OwnerReadOnlyProviderAdapter -Name 'named-discussion-fixture' `
            -Handler { param($Operation, $Arguments) return $page }.GetNewClosure()
        Get-OwnerDiscussionSnapshot -Contract $Contract -Provider $provider
    }

    function New-NamedTestThread {
        param($Contract, $Finding, [string]$Body, [bool]$Outdated = $false,
            [bool]$ReviewerOwned = $true)
        [ordered]@{
            threadId = 101
            status = 'active'
            isDeleted = $false
            isOutdated = $Outdated
            sourceCommit = $(if ($Outdated) { $null } else { $Contract.Request.SourceCommit })
            contextState = $(if ($Outdated) { 'outdated' } else { 'current' })
            anchor = [ordered]@{
                path = [string]$Finding.anchor.path
                line = [int]$Finding.affectedCallLines[-1]
            }
            comments = @([ordered]@{
                    commentId = 102
                    commentType = 'text'
                    isDeleted = $false
                    reviewerOwned = $ReviewerOwned
                    reviewerIdentityState = $(if ($ReviewerOwned) { 'matched' } else { 'foreign' })
                    body = $Body
                    bodyDigest = Get-NamedTestDigest $Body
                })
        }
    }
}

Describe 'Bound named Assert.AreEqual method capability' {
    It 'emits one grouped violation per method with changed call lines and no model or writes' {
        $result = Invoke-NamedTestReplay -Manifest (New-NamedTestManifest)
        $result.Run.records[0].state | Should -BeExactly 'completed' `
            -Because ($result.Observation.validationErrors -join '; ')
        $result.Observation.capability | Should -BeExactly 'bpm-named-areequal-arguments@1'
        $result.Observation.counts.violations | Should -Be 1
        $result.Observation.findings[0].identity | Should -Match '^named-areequal-v2:[0-9a-f]{64}$'
        $result.Observation.findings[0].anchor.symbol | Should -BeExactly 'Checks.Verify'
        $result.Observation.findings[0].anchor.line | Should -Be 6
        $result.Observation.findings[0].affectedCallCount | Should -Be 2
        $result.Observation.findings[0].affectedCallLines | Should -Be @(6, 7)
        $result.Observation.execution.modelStarts | Should -Be 0
        $result.Observation.effects.providerWrites | Should -Be 0
    }

    It 'refuses another cohort or policy identity' {
        $manifest = New-NamedTestManifest
        $manifest.kind = 'owner-v2-preview-cohort'
        $path = Join-Path $TestDrive 'foreign-cohort.json'
        [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 64))
        { Invoke-OwnerV2PreviewPrepare -StateRoot (Join-Path $TestDrive 'wrong-cohort') `
                -ManifestPath $path } | Should -Throw '*separate capability*'
        $manifest.kind = 'named-areequal-v2-preview-cohort'
        $manifest.entries[0].rule.section = 'bpm-test-ownership@1'
        [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 64))
        { Invoke-OwnerV2PreviewPrepare -StateRoot (Join-Path $TestDrive 'wrong-rule') `
                -ManifestPath $path } | Should -Throw '*exact source-backed rule*'
        $manifest = New-NamedTestManifest
        $manifest.entries[0].rule.hash = Get-NamedTestDigest 'substituted-policy'
        $manifest.entries[0].acquisition.package.rule.ruleHash =
            $manifest.entries[0].rule.hash
        [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 64))
        { Invoke-OwnerV2PreviewPrepare -StateRoot (Join-Path $TestDrive 'wrong-digest') `
                -ManifestPath $path } | Should -Throw '*exact source-backed rule*'
    }

    It 'keeps a shadowed Assert receiver unknown and non-actionable' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
class Assert { public static void AreEqual(int expected, int actual) {} }
[TestClass]
class Checks {
    [TestMethod]
    void Verify() { Assert.AreEqual(0, 1); }
}
'@
        $result = Invoke-NamedTestReplay -Manifest (
            New-NamedTestManifest -Content $source -First 6 -Last 6)
        $result.Observation.lifecycle.status | Should -BeExactly incomplete
        $result.Observation.counts.unknown | Should -Be 1
        @($result.Observation.findings).Count | Should -Be 0
        $result.Observation.effects.providerWrites | Should -Be 0
    }

    It 'keeps an expression-bodied Assert property unknown and non-actionable' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
class Foreign { public void AreEqual(int expected, int actual) {} }
[TestClass]
class Checks {
    private Foreign Assert => new Foreign();
    [TestMethod]
    void Verify() { Assert.AreEqual(0, 1); }
}
'@
        $result = Invoke-NamedTestReplay -Manifest (
            New-NamedTestManifest -Content $source -First 7 -Last 7)
        $result.Observation.lifecycle.status | Should -BeExactly incomplete
        $result.Observation.counts.unknown | Should -Be 1
        @($result.Observation.findings).Count | Should -Be 0
        $result.Observation.effects.providerWrites | Should -Be 0
    }

    It 'treats a current unmarked same-account human request as method coverage, not bot no-op' {
        $result = Invoke-NamedTestReplay -Manifest (New-NamedTestManifest)
        $contract = New-NamedTestContract -Entry $result.Entry
        $finding = $result.Observation.findings[0]
        $thread = New-NamedTestThread -Contract $contract -Finding $finding `
            -Body 'Please use named parameters for Assert.AreEqual: expected and actual.' `
            -ReviewerOwned $true
        $snapshot = New-NamedTestDiscussion -Contract $contract -Threads @($thread)
        $observation = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $result.Observation -Contract $contract -Snapshot $snapshot
        $observation.findings[0].reconciliation.classification | Should -BeExactly humanCovered
        $observation.effects.dedupe.wouldCreate | Should -Be 0
        $observation.effects.providerWrites | Should -Be 0
    }

    It 'recognizes a short imperative named-parameters request on a changed call' {
        $result = Invoke-NamedTestReplay -Manifest (New-NamedTestManifest)
        $contract = New-NamedTestContract -Entry $result.Entry
        $thread = New-NamedTestThread -Contract $contract `
            -Finding $result.Observation.findings[0] `
            -Body 'Please use named parameters.' -ReviewerOwned $true
        $snapshot = New-NamedTestDiscussion -Contract $contract -Threads @($thread)
        $observation = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $result.Observation -Contract $contract -Snapshot $snapshot
        $observation.findings[0].reconciliation.classification | Should -BeExactly humanCovered
        $observation.effects.dedupe.wouldCreate | Should -Be 0
    }

    It 'keeps a covered method separate from five other changed method groups' {
        $lines = [Collections.Generic.List[string]]::new()
        foreach ($import in @('using System;', 'using System.Collections.Generic;',
                'using Example.First;', 'using Example.Second;',
                'using Microsoft.VisualStudio.TestTools.UnitTesting;')) {
            [void]$lines.Add($import)
        }
        [void]$lines.Add('[TestClass] class Checks {')
        $index = 0
        foreach ($callCount in @(6, 11, 1, 6, 1, 1)) {
            $index++
            [void]$lines.Add("    [TestMethod] void Check$index() {")
            foreach ($call in 1..$callCount) {
                [void]$lines.Add("        Assert.AreEqual($call, value);")
            }
            [void]$lines.Add('    }')
        }
        [void]$lines.Add('}')
        $manifest = New-NamedTestManifest -Content ($lines -join "`n") `
            -First 1 -Last $lines.Count
        $result = Invoke-NamedTestReplay -Manifest $manifest
        $result.Observation.lifecycle.status | Should -BeExactly completed
        $result.Observation.counts.violations | Should -Be 6
        @($result.Observation.findings | Measure-Object -Property affectedCallCount -Sum)[0].Sum |
            Should -Be 26
        $covered = @($result.Observation.findings | Where-Object {
                $_.anchor.symbol -ceq 'Checks.Check6'
            })
        $covered.Count | Should -Be 1
        $covered[0].affectedCallCount | Should -Be 1
        $contract = New-NamedTestContract -Entry $result.Entry
        $thread = New-NamedTestThread -Contract $contract -Finding $covered[0] `
            -Body 'Please use named parameters.' -ReviewerOwned $true
        $snapshot = New-NamedTestDiscussion -Contract $contract -Threads @($thread)
        $observation = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $result.Observation -Contract $contract -Snapshot $snapshot
        $covered = @($observation.findings | Where-Object {
                $_.anchor.symbol -ceq 'Checks.Check6'
            })
        $covered[0].reconciliation.classification | Should -BeExactly humanCovered
        $observation.effects.dedupe.humanCovered | Should -Be 1
        $observation.effects.dedupe.wouldCreate | Should -Be 5
        $observation.effects.dedupe.unknown | Should -Be 0
        $observation.effects.providerWrites | Should -Be 0
    }

    It 'keeps historical unmarked human discussion unknown instead of creating again' {
        $result = Invoke-NamedTestReplay -Manifest (New-NamedTestManifest)
        $contract = New-NamedTestContract -Entry $result.Entry
        $thread = New-NamedTestThread -Contract $contract `
            -Finding $result.Observation.findings[0] `
            -Body 'Use named arguments for Assert.AreEqual.' -Outdated $true
        $snapshot = New-NamedTestDiscussion -Contract $contract -Threads @($thread)
        $observation = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $result.Observation -Contract $contract -Snapshot $snapshot
        $observation.findings[0].reconciliation.classification | Should -BeExactly unknown
        $observation.effects.dedupe.wouldCreate | Should -Be 0
    }

    It 'requires the exact bot marker, current body, and first changed anchor for noOp' {
        $result = Invoke-NamedTestReplay -Manifest (New-NamedTestManifest)
        $contract = New-NamedTestContract -Entry $result.Entry
        $finding = $result.Observation.findings[0]
        $marker = Get-NamedAreEqualMarkerKey -Contract $contract -Finding $finding
        $body = Format-NamedAreEqualComment -Contract $contract `
            -Finding $finding -MarkerKey $marker
        $thread = New-NamedTestThread -Contract $contract -Finding $finding `
            -Body $body -ReviewerOwned $true
        $thread.anchor.line = [int]$finding.anchor.line
        $snapshot = New-NamedTestDiscussion -Contract $contract -Threads @($thread)
        $observation = Resolve-OwnerV2DiscussionReconciliation `
            -Observation $result.Observation -Contract $contract -Snapshot $snapshot
        $observation.findings[0].reconciliation.classification | Should -BeExactly noOp
        $observation.effects.dedupe.wouldCreate | Should -Be 0
    }

    It 'keeps duplicate, foreign, and badly anchored exact markers unknown' {
        $result = Invoke-NamedTestReplay -Manifest (New-NamedTestManifest)
        $contract = New-NamedTestContract -Entry $result.Entry
        $finding = $result.Observation.findings[0]
        $marker = Get-NamedAreEqualMarkerKey -Contract $contract -Finding $finding
        $body = Format-NamedAreEqualComment -Contract $contract `
            -Finding $finding -MarkerKey $marker

        $foreign = New-NamedTestThread -Contract $contract -Finding $finding `
            -Body $body -ReviewerOwned $false
        $foreignObservation = Resolve-OwnerV2DiscussionReconciliation `
            -Observation ($result.Observation | ConvertTo-Json -Depth 64 |
                ConvertFrom-Json -AsHashtable -Depth 64) `
            -Contract $contract `
            -Snapshot (New-NamedTestDiscussion -Contract $contract -Threads @($foreign))
        $foreignObservation.effects.dedupe.unknown | Should -Be 1
        $foreignObservation.findings[0].reconciliation.reason |
            Should -BeExactly 'duplicate-or-foreign-reviewer-marker'

        $first = New-NamedTestThread -Contract $contract -Finding $finding `
            -Body $body -ReviewerOwned $true
        $second = New-NamedTestThread -Contract $contract -Finding $finding `
            -Body $body -ReviewerOwned $true
        $second.threadId = 202
        $second.comments[0].commentId = 203
        $duplicateObservation = Resolve-OwnerV2DiscussionReconciliation `
            -Observation ($result.Observation | ConvertTo-Json -Depth 64 |
                ConvertFrom-Json -AsHashtable -Depth 64) `
            -Contract $contract `
            -Snapshot (New-NamedTestDiscussion -Contract $contract `
                -Threads @($first, $second))
        $duplicateObservation.effects.dedupe.unknown | Should -Be 1
        $duplicateObservation.findings[0].reconciliation.reason |
            Should -BeExactly 'duplicate-or-foreign-reviewer-marker'

        $badAnchor = New-NamedTestThread -Contract $contract -Finding $finding `
            -Body $body -ReviewerOwned $true
        $badAnchor.anchor.line = [int]$finding.anchor.line + 1
        $anchorObservation = Resolve-OwnerV2DiscussionReconciliation `
            -Observation ($result.Observation | ConvertTo-Json -Depth 64 |
                ConvertFrom-Json -AsHashtable -Depth 64) `
            -Contract $contract `
            -Snapshot (New-NamedTestDiscussion -Contract $contract `
                -Threads @($badAnchor))
        $anchorObservation.effects.dedupe.unknown | Should -Be 1
        $anchorObservation.findings[0].reconciliation.reason |
            Should -BeExactly 'reviewer-marker-generation-unknown'
    }
}
