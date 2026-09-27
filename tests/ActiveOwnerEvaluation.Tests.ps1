#requires -Version 7.0
BeforeAll {
    $script:RepositoryRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:RepositoryRoot `
        'src\DevPilot.ActiveOwnerEvaluation\DevPilot.ActiveOwnerEvaluation.psd1') -Force
    Import-Module (Join-Path $script:RepositoryRoot `
        'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1')
    Import-Module (Join-Path $script:RepositoryRoot `
        'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1')
    Import-Module (Join-Path $script:RepositoryRoot `
        'src\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1')
    Import-Module (Join-Path $script:RepositoryRoot `
        'src\DevPilot.OwnerModelRunner\DevPilot.OwnerModelRunner.psd1')
    $script:EvaluatorModule = Get-Module DevPilot.ActiveOwnerEvaluation
    $script:OrchestratorModule = Get-Module DevPilot.OwnerOrchestrator
    $script:StateRoots = [Collections.Generic.List[string]]::new()

    function New-TestOwnerRoot {
        $root = Join-Path $env:USERPROFILE (
            '.copilot\active-owner-test-' + [guid]::NewGuid().ToString('N'))
        $script:StateRoots.Add($root)
        return $root
    }

    function New-TestOwnerCase {
        $intakeConfig = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot `
            'samples\active-pr-intake.config.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $declaration = [ordered]@{
            repositoryId = $intakeConfig.repositoryId
            projectId = $intakeConfig.projectId
            pullRequestId = 42
            sourceRef = 'refs/heads/feature'
            targetRef = 'refs/heads/master'
            sourceCommit = 'a' * 40
            targetCommit = 'b' * 40
            commonCommit = 'c' * 40
            iterationId = 1
            status = 'active'
            isDraft = $false
        }
        $file = [ordered]@{
            path = '/Example.cs'; content = '[TestMethod] public void Example() {}'
            spans = @([ordered]@{ startLine = 1; endLine = 1 })
        }
        $generation = 'a' * 32
        $headDigest = (& $script:EvaluatorModule {
                param($Value) (Get-ActiveOwnerJsonHash $Value).Substring(10)
            } $declaration)
        $pathDigest = (& $script:EvaluatorModule {
                param($Value) (Get-ActiveOwnerJsonHash $Value).Substring(10)
            } $file.path)
        $lineEvidence = [ordered]@{
            generation = $generation; declarationDigest = $headDigest
            changedFiles = 1; changedLines = 1
            files = @([ordered]@{ pathDigest = $pathDigest
                    changeType = 'add'; spans = $file.spans })
        }
        $binding = [ordered]@{
            ruleRepositoryId = 'enghub-example'
            rulePath = 'documentation/EngineeringProcesses/Conventions/AutomatedTests.md'
            ruleSection = '## Claim ownership'
            ruleCommit = 'f6db83436b48f48a8521095a888d79f67823bbb2'
            ruleHash = 'v1:sha256:bc31bfea6b378dffe4a1b28475dc1cac4cd3ee1ab793db57895446ded829ab2f'
            ruleLength = 10
            capabilityDigest = 'v1:sha256:' + ('e' * 64)
        }
        $config = [ordered]@{
            capabilityId = 'bpm-test-ownership@1'
            ruleId = 'mstest-owner'
            binding = $binding
            model = [ordered]@{
                id = 'deterministic-fake-process'
                digest = (& $script:EvaluatorModule {
                        Get-ActiveOwnerTextHash 'deterministic-fake-process'
                    })
            }
            maxFindingsPerHead = 4
        }
        $ruleDeclaration = [ordered]@{
            generation = $generation; intakeGeneration = $generation
            intakeDeclarationDigest = $headDigest
            lineEvidenceDigest = (& $script:EvaluatorModule {
                    param($Value) (Get-ActiveOwnerJsonHash $Value).Substring(10)
                } $lineEvidence)
            sourceCommit = $declaration.sourceCommit
            targetCommit = $declaration.targetCommit
            targetRef = $declaration.targetRef
            pullRequestId = $declaration.pullRequestId
            iterationId = 1
            configDigest = 'f' * 64
            ruleId = 'mstest-owner'
            capabilityId = 'bpm-test-ownership@1'
            ruleBinding = $binding
            model = $config.model
        }
        $declarationDigest = (& $script:EvaluatorModule {
                param($Value)
                (Get-ActiveOwnerTextHash (
                    ConvertTo-Json -InputObject $Value -Depth 16)).Substring(10)
            } $ruleDeclaration)
        return @{
            declaration = $declaration; files = @($file)
            discussion = [ordered]@{ human = 0; automation = 0
                ambiguous = 0; outdated = 0; currentAnchored = 0 }
            rawDiscussions = @{ count = 0; threads = @() }
            lineEvidence = $lineEvidence; generation = $generation
            ruleConfig = $config; ruleDeclaration = $ruleDeclaration
            declarationDigest = $declarationDigest
        }
    }
}

AfterAll {
    foreach ($root in $script:StateRoots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

Describe 'Concrete read-only Owner evaluator' {
    It 'exports a dispatcher-compatible nine-argument scriptblock with model off by default' {
        $case = New-TestOwnerCase
        $root = New-TestOwnerRoot
        $evaluator = New-ActiveOwnerEvaluator -StateRoot $root
        $result = & $evaluator $case.declaration $case.files $case.discussion `
            $case.lineEvidence $case.generation $case.ruleConfig `
            $case.ruleDeclaration $case.declarationDigest $case.rawDiscussions
        $result.state | Should -Be 'unknown'
        $result.reason | Should -Be 'owner-rule-bytes-unavailable'
        $result.completed | Should -BeFalse
        $result.providerWrites | Should -Be 0
        $result.writeToolInvocations | Should -Be 0
        $result.modelToolInvocations | Should -Be 0
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'rejects mismatched pinned bytes without a provider read or state write' {
        $case = New-TestOwnerCase
        $root = New-TestOwnerRoot
        $bytes = [Text.Encoding]::UTF8.GetBytes('not pinned')
        $result = Invoke-ActiveOwnerEvaluation @case -StateRoot $root `
            -RuleBytes $bytes -EnableLiveModel -LiveModel 'deterministic-fake-process' `
            -LiveCredentialEnvironmentName GH_TOKEN `
            -ReviewerIdentity @{ id = '11111111-2222-3333-4444-555555555555'
                descriptor = 'aad.synthetic'; uniqueName = 'reviewer@example.invalid' }
        $result.state | Should -Be 'unknown'
        $result.reason | Should -Be 'owner-rule-bytes-unavailable'
        $result.providerWrites | Should -Be 0
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'refuses a changed rule declaration or head even without a live model' {
        $case = New-TestOwnerCase
        $root = New-TestOwnerRoot
        $case.ruleConfig.binding.ruleCommit = 'd' * 40
        $result = Invoke-ActiveOwnerEvaluation @case -StateRoot $root
        $result.reason | Should -Be 'owner-rule-binding-unavailable'
        $case = New-TestOwnerCase
        $case.declaration.sourceCommit = 'd' * 40
        $result = Invoke-ActiveOwnerEvaluation @case -StateRoot $root
        $result.reason | Should -Be 'owner-head-binding-mismatch'
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'constructs a fresh exact-head package from dispatcher evidence without persisting source' {
        $case = New-TestOwnerCase
        $binding = [ordered]@{
            ruleRepositoryId = 'rules-example'; rulePath = 'rules/owner-policy.md'
            ruleCommit = 'c' * 40; ruleSection = 'test'
            ruleHash = 'v1:sha256:' + ('a' * 64); ruleLength = 4
        }
        $package = & $script:EvaluatorModule {
            param($Declaration, $Files, $Evidence, $Binding)
            New-ActiveOwnerPackage -Declaration $Declaration -Files $Files `
                -LineEvidence $Evidence -Binding $Binding -RuleText 'test'
        } $case.declaration $case.files $case.lineEvidence $binding
        $package.subjectBefore.sourceCommit | Should -Be $case.declaration.sourceCommit
        $package.subjectAfter.sourceDigest | Should -Be $package.subjectBefore.sourceDigest
        $package.changePages[0].changes[0].spans[0].startLine | Should -Be 1
        $package.files[0].content | Should -Be $case.files[0].content
        (New-OwnerReplayFixture -Package $package).PayloadDigest |
            Should -Match '^v1:sha256:[a-f0-9]{64}$'
        $case.files[0].spans = @(@{ startLine = 1; endLine = 2 })
        { & $script:EvaluatorModule {
                param($Declaration, $Files, $Evidence, $Binding)
                New-ActiveOwnerPackage -Declaration $Declaration -Files $Files `
                    -LineEvidence $Evidence -Binding $Binding -RuleText 'test'
            } $case.declaration $case.files $case.lineEvidence $binding } |
            Should -Throw '*changed-lines-mismatch*'
    }

    It 'runs a synthetic exact-head live manifest with a no-tools fake model and zero writes' {
        $case = New-TestOwnerCase
        $case.declaration.iterationId = 2
        $case.ruleDeclaration.iterationId = 2
        $case.lineEvidence.declarationDigest = (& $script:EvaluatorModule {
                param($Value) (Get-ActiveOwnerJsonHash $Value).Substring(10)
            } $case.declaration)
        $case.ruleDeclaration.intakeDeclarationDigest =
            $case.lineEvidence.declarationDigest
        $root = New-TestOwnerRoot
        $ruleText = 'Changed MSTest methods require an Owner attribute.'
        $bytes = [Text.Encoding]::UTF8.GetBytes($ruleText)
        $hash = & $script:EvaluatorModule {
            param($Bytes) Get-ActiveOwnerHash $Bytes
        } $bytes
        $case.ruleConfig.binding.ruleLength = $bytes.Length
        $case.ruleConfig.binding.ruleHash = $hash
        $case.ruleDeclaration.ruleBinding = $case.ruleConfig.binding
        $case.declarationDigest = (& $script:EvaluatorModule {
                param($Value)
                (Get-ActiveOwnerTextHash (
                    ConvertTo-Json -InputObject $Value -Depth 16)).Substring(10)
            } $case.ruleDeclaration)
        $case.files[0].content = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
[TestClass]
public class WidgetTests {
    [TestMethod]
    public void NeedsOwner() {}
}
'@
        $case.files[0].spans = @(@{ startLine = 1; endLine = 6 })
        $case.lineEvidence.files[0].spans = $case.files[0].spans
        $case.ruleDeclaration.lineEvidenceDigest = (& $script:EvaluatorModule {
                param($Value) (Get-ActiveOwnerJsonHash $Value).Substring(10)
            } $case.lineEvidence)
        $case.declarationDigest = (& $script:EvaluatorModule {
                param($Value)
                (Get-ActiveOwnerTextHash (
                    ConvertTo-Json -InputObject $Value -Depth 16)).Substring(10)
            } $case.ruleDeclaration)
        $modelCount = Join-Path $root 'model-count.txt'
        $model = New-OwnerModelFakeProvider -FilePath (Get-Command pwsh).Source `
            -ArgumentList @('-NoProfile', '-File', (Join-Path $script:RepositoryRoot `
                'tests\fixtures\OwnerModelChild.ps1'), 'count-valid', $modelCount)
        $intakeConfig = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot `
            'samples\active-pr-intake.config.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $reviewer = $intakeConfig.expectedAccount
        $previous = & $script:EvaluatorModule {
            param($Digest)
            $old = $script:OwnerRuleHash
            $script:OwnerRuleHash = $Digest
            return $old
        } $hash
        try {
            $savedModel = $case.ruleConfig.model
            $case.ruleConfig.model = $null
            $unbound = Invoke-ActiveOwnerEvaluation @case -StateRoot $root `
                -RuleBytes $bytes -EnableLiveModel -LiveModelProvider $model `
                -ReviewerIdentity $reviewer -IntakeConfig $intakeConfig
            $unbound.reason | Should -Be 'owner-model-binding-unavailable'
            $case.ruleConfig.model = @{
                id = 'gpt-5.6-sol'
                digest = (& $script:EvaluatorModule {
                        Get-ActiveOwnerTextHash 'gpt-5.6-sol'
                    })
            }
            $mismatchedModel = Invoke-ActiveOwnerEvaluation @case -StateRoot $root `
                -RuleBytes $bytes -EnableLiveModel -LiveModelProvider $model `
                -ReviewerIdentity $reviewer -IntakeConfig $intakeConfig
            $mismatchedModel.reason | Should -Be 'owner-model-binding-unavailable'
            $case.ruleConfig.model = $savedModel
            Test-Path -LiteralPath $root | Should -BeFalse
            $disabled = Invoke-ActiveOwnerEvaluation @case -StateRoot $root `
                -RuleBytes $bytes -ReviewerIdentity $reviewer `
                -IntakeConfig $intakeConfig
            $disabled.reason | Should -Be 'live-model-disabled-or-unavailable'
            $case.rawDiscussions = $null
            $noDiscussion = Invoke-ActiveOwnerEvaluation @case -StateRoot $root `
                -RuleBytes $bytes -EnableLiveModel -LiveModelProvider $model `
                -ReviewerIdentity $reviewer -IntakeConfig $intakeConfig
            $noDiscussion.reason | Should -Be 'discussion-evidence-unavailable'
            $case.rawDiscussions = @{ count = 0; threads = @() }
            Test-Path -LiteralPath $root | Should -BeFalse
            $case.discussion.human = 1
            $mismatched = Invoke-ActiveOwnerEvaluation @case -StateRoot $root `
                -RuleBytes $bytes -EnableLiveModel -LiveModelProvider $model `
                -ReviewerIdentity $reviewer -IntakeConfig $intakeConfig
            $mismatched.state | Should -Be 'unknown'
            Test-Path -LiteralPath $root | Should -BeFalse
            $case.discussion.human = 0
            $evaluator = New-ActiveOwnerEvaluator -StateRoot $root `
                -RuleBytes $bytes -EnableLiveModel -LiveModelProvider $model `
                -ReviewerIdentity $reviewer -IntakeConfig $intakeConfig
            $result = & $evaluator $case.declaration $case.files $case.discussion `
                $case.lineEvidence $case.generation $case.ruleConfig `
                $case.ruleDeclaration $case.declarationDigest $case.rawDiscussions
            $result.state | Should -Be 'evaluated' -Because $result.reason
            $result.completed | Should -BeTrue
            $result.manifestEntryCount | Should -Be 1
            $result.manifestDigest | Should -Match '^v1:sha256:[a-f0-9]{64}$'
            $result.providerWrites | Should -Be 0
            $result.writeToolInvocations | Should -Be 0
            $result.modelToolInvocations | Should -Be 0
            $result.discussionDigest | Should -Match '^[a-f0-9]{64}$'
            $result.findings | Should -Be $result.findingOutcomes.Count
            $result.findings | Should -BeGreaterThan 0
            $result.findingOutcomes[0].classification | Should -Be 'wouldCreate'
            $proof = $result.durableProof
            $proof.identity | Should -Match '^[a-f0-9]{64}$'
            $proof.stateDigest | Should -Be "v1:sha256:$($proof.identity)"
            $proof.observationDigest | Should -Match '^v1:sha256:[a-f0-9]{64}$'
            $persistedRecord = Get-Content -LiteralPath $proof.recordPath -Raw |
                ConvertFrom-Json -AsHashtable
            $persistedRecord.state | Should -Be 'completed'
            $persistedRecord.resultDigest | Should -Be $proof.observationDigest
            $persistedRecord.acquisitionPayloadDigest |
                Should -Be $proof.acquisitionPayloadDigest
            (& $script:EvaluatorModule {
                    param($Bytes) Get-ActiveOwnerHash $Bytes
                } ([IO.File]::ReadAllBytes($proof.recordPath))) |
                Should -Be $proof.recordFileDigest
            [IO.File]::ReadAllText($modelCount) | Should -Be '1'
            $manifestFile = @(Get-ChildItem -LiteralPath (Join-Path $root `
                'active-owner-evaluation-v1\manifests') -Filter '*.json')
            $manifestFile.Count | Should -Be 1
            $manifest = Get-Content -LiteralPath $manifestFile[0].FullName -Raw |
                ConvertFrom-Json -AsHashtable
            $manifest.entries.Count | Should -Be 1
            $manifest.entries[0].mode | Should -Be 'live'
            $manifest.entries[0].head.sourceCommit |
                Should -Be $case.declaration.sourceCommit
            $manifest.entries[0].rule.hash | Should -Be $hash
            $manifest.entries[0].acquisition.payloadDigest |
                Should -Match '^v1:sha256:[a-f0-9]{64}$'
            (Get-Content -LiteralPath $manifestFile[0].FullName -Raw) |
                Should -Not -Match 'WidgetTests'
            $again = Invoke-ActiveOwnerEvaluation @case -StateRoot $root `
                -RuleBytes $bytes -EnableLiveModel -LiveModelProvider $model `
                -ReviewerIdentity $reviewer -IntakeConfig $intakeConfig
            $again.state | Should -Be 'evaluated' -Because $again.reason
            $again.manifestDigest | Should -Be $result.manifestDigest
            [IO.File]::ReadAllText($modelCount) | Should -Be '1'
            $currentObservation = Get-Content -LiteralPath $proof.observationPath -Raw |
                ConvertFrom-Json -AsHashtable -Depth 64
            $anchor = $currentObservation.findings[0].anchor
            $thread = @{
                id = 120; status = 'active'
                comments = @(@{
                        id = 1; author = $reviewer; commentType = 'text'
                        content = 'Please add an Owner attribute.'
                    })
                threadContext = @{
                    filePath = '/' + ([string]$anchor.path).TrimStart('/')
                    rightFileStart = @{ line = [int]$anchor.line }
                    rightFileEnd = @{ line = [int]$anchor.line }
                }
                pullRequestThreadContext = @{
                    changeTrackingId = 1
                    iterationContext = @{
                        firstComparingIteration = 2; secondComparingIteration = 2
                    }
                }
            }
            $case.rawDiscussions = @{ count = 1; threads = @($thread) }
            $case.discussion = Get-ActivePrDiscussionCounts `
                -Response $case.rawDiscussions -Config $intakeConfig `
                -Head $case.declaration
            $human = Invoke-ActiveOwnerEvaluation @case -StateRoot $root `
                -RuleBytes $bytes -EnableLiveModel -LiveModelProvider $model `
                -ReviewerIdentity $reviewer -IntakeConfig $intakeConfig
            $human.state | Should -Be 'evaluated' -Because $human.reason
            $human.findingOutcomes[0].classification | Should -Be 'humanCovered'
            $human.findingOutcomes[0].reason |
                Should -Be 'matching-human-review-present'
            $human.discussionDigest | Should -Not -Be $result.discussionDigest
            [IO.File]::ReadAllText($modelCount) | Should -Be '1'
            $thread.pullRequestThreadContext.iterationContext.firstComparingIteration = 1
            $thread.pullRequestThreadContext.iterationContext.secondComparingIteration = 1
            $case.discussion = Get-ActivePrDiscussionCounts `
                -Response $case.rawDiscussions -Config $intakeConfig `
                -Head $case.declaration
            $historical = Invoke-ActiveOwnerEvaluation @case -StateRoot $root `
                -RuleBytes $bytes -EnableLiveModel -LiveModelProvider $model `
                -ReviewerIdentity $reviewer -IntakeConfig $intakeConfig
            $historical.state | Should -Be 'evaluated' -Because $historical.reason
            $historical.findingOutcomes[0].classification | Should -Be 'unknown'
            $historical.findingOutcomes[0].reason |
                Should -Be 'historical-human-review-needs-review'
            [IO.File]::ReadAllText($modelCount) | Should -Be '1'
            $originalObservation = [IO.File]::ReadAllBytes($proof.observationPath)
            $tampered = Get-Content -LiteralPath $proof.observationPath -Raw |
                ConvertFrom-Json -AsHashtable -Depth 64
            $tampered.findings[0].reconciliation.classification = 'wouldCreate'
            [IO.File]::WriteAllText($proof.observationPath,
                (ConvertTo-Json -InputObject $tampered -Depth 64 -Compress))
            $refused = Invoke-ActiveOwnerEvaluation @case -StateRoot $root `
                -RuleBytes $bytes -EnableLiveModel -LiveModelProvider $model `
                -ReviewerIdentity $reviewer -IntakeConfig $intakeConfig
            $refused.state | Should -Be 'unknown'
            $refused.completed | Should -BeFalse
            [IO.File]::ReadAllText($modelCount) | Should -Be '1'
            [IO.File]::WriteAllBytes($proof.observationPath, $originalObservation)
            $alteredRecord = Get-Content -LiteralPath $proof.recordPath -Raw |
                ConvertFrom-Json -AsHashtable -Depth 64
            $alteredRecord.stateDigest = 'v1:sha256:' + ('0' * 64)
            [IO.File]::WriteAllText($proof.recordPath,
                (ConvertTo-Json -InputObject $alteredRecord -Depth 64 -Compress))
            $refusedRecord = Invoke-ActiveOwnerEvaluation @case -StateRoot $root `
                -RuleBytes $bytes -EnableLiveModel -LiveModelProvider $model `
                -ReviewerIdentity $reviewer -IntakeConfig $intakeConfig
            $refusedRecord.state | Should -Be 'unknown'
            $refusedRecord.completed | Should -BeFalse
            [IO.File]::ReadAllText($modelCount) | Should -Be '1'
        }
        finally {
            & $script:EvaluatorModule {
                param($Digest) $script:OwnerRuleHash = $Digest
            } $previous
        }
    }

    It 'leaves crashed model reservations bounded and does not retry an active lease' {
        $fixture = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot `
            'tests\fixtures\owner-orchestrator\generic-cohort.json') -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
        $entry = $fixture.entries[0]
        $entry.mode = 'live'
        $entry.Remove('replay')
        $entry.acquisition.Remove('package')
        $root = New-TestOwnerRoot
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $manifest = Join-Path $root 'cohort.json'
        [IO.File]::WriteAllText($manifest, (ConvertTo-Json -InputObject $fixture -Depth 64))
        $state = Join-Path $root 'orchestrator'
        $prepared = Invoke-OwnerV2PreviewPrepare -StateRoot $state -ManifestPath $manifest
        $prepared.records.Count | Should -Be 1
        try {
            & $script:OrchestratorModule {
                $script:OwnerV2TestCheckpoint = 'run-after-reservation'
            }
            { Invoke-OwnerV2PreviewRun -StateRoot $state -ManifestPath $manifest } |
                Should -Throw '*run-after-reservation*'
        }
        finally {
            & $script:OrchestratorModule { $script:OwnerV2TestCheckpoint = $null }
        }
        $recordPath = Join-Path $prepared.records[0].capabilityRoot `
            "records\$($prepared.records[0].identity).json"
        $record = Get-Content -LiteralPath $recordPath -Raw |
            ConvertFrom-Json -AsHashtable
        $record.state | Should -Be 'running'
        $record.modelExecutionState | Should -Be 'notAttempted'
        $second = Invoke-OwnerV2PreviewRun -StateRoot $state -ManifestPath $manifest
        $second.records[0].reason | Should -Be 'lease-active'
        $after = Get-Content -LiteralPath $recordPath -Raw |
            ConvertFrom-Json -AsHashtable
        $after.attempts | Should -Be 1
        $after.modelExecutionState | Should -Be 'notAttempted'
    }
}
