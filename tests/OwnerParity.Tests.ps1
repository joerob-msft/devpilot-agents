BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:ModulePath = Join-Path $script:RepoRoot `
        'src/DevPilot.OwnerParity/DevPilot.OwnerParity.psd1'
    $script:ObservationFixture = Join-Path $PSScriptRoot `
        'fixtures/owner-observer/v2-outcome.json'
    $script:QualificationFixture = Join-Path $PSScriptRoot `
        'fixtures/owner-parity/generic-qualification.json'
    Import-Module (Join-Path $script:RepoRoot 'src/OwnerObserver/OwnerObserver.psd1') -Force
    Import-Module $script:ModulePath -Force
    Import-Module (Join-Path $script:RepoRoot `
            'src/OwnerObservationContract/OwnerObservationContract.psd1') -Force
    $script:ParityModule = Get-Module DevPilot.OwnerParity

    function Copy-TestParityValue {
        param([Parameter(Mandatory)][object]$Value)
        return ConvertFrom-Json -InputObject (
            ConvertTo-Json -InputObject $Value -Depth 64 -Compress
        ) -AsHashtable -Depth 64
    }

    function New-TestParityObservation {
        param(
            [string]$ImplementationId = 'owner-v1-test',
            [scriptblock]$Mutator
        )
        $observation = Get-Content -LiteralPath $script:ObservationFixture -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
        $observation.implementation.id = $ImplementationId
        $observation.findings = @($observation.findings | Select-Object -First 1)
        $observation.counts.violations = 1
        $observation.counts.unknown = 0
        $observation.counts.uncovered = 0
        if ($Mutator) { & $Mutator $observation }
        foreach ($finding in @($observation.findings)) {
            if ($finding.anchor -is [Collections.IDictionary]) {
                $finding.binding = New-OwnerCanonicalAnchor `
                    -Path ([string]$finding.anchor.path) `
                    -StartLine ([int]$finding.anchor.line) `
                    -EndLine ([int]$finding.anchor.line) `
                    -Symbol ([string]$finding.anchor.symbol) `
                    -ConstructIdentity ([string]$finding.constructRef)
                $finding.semanticKey = Get-OwnerSemanticFindingKey `
                    -Subject $observation.subject `
                    -Rule $observation.rule `
                    -Capability ([string]$observation.capability) `
                    -Binding $finding.binding
            }
            else {
                $finding.binding = 'unknown'
                $finding.semanticKey = 'unknown'
            }
        }
        (& $script:ParityModule {
                param($Value)
                Test-OwnerObservation -Observation $Value
            } $observation) | Should -BeTrue
        return $observation
    }

    function New-TestParityEvidence {
        param(
            [string]$Class = 'preserved-exact-bytes',
            [string]$SemanticProvenance = 'offline-replay-recorded-model',
            [string]$InputContract = 'independently-validated',
            [string]$TruthCoverage = 'complete'
        )
        return [ordered]@{
            class = $Class
            semanticProvenance = $SemanticProvenance
            inputContract = $InputContract
            truthCoverage = $TruthCoverage
        }
    }

    function New-TestParityAdjudication {
        param(
            [string]$Truth = 'violation',
            [string]$Eligibility = 'method',
            [string]$BaselineIdentity = 'test-ownership@1:rs0:dc1',
            [string]$BaselineDisposition = 'violation',
            [string]$CandidateIdentity = 'test-ownership@1:rs0:dc1',
            [string]$CandidateDisposition = 'violation'
        )
        return [ordered]@{
            key = 'unit-001'
            eligibility = $Eligibility
            truth = $Truth
            baseline = if ($BaselineIdentity) {
                [ordered]@{
                    identity = $BaselineIdentity
                    disposition = $BaselineDisposition
                }
            }
            else { $null }
            candidate = if ($CandidateIdentity) {
                [ordered]@{
                    identity = $CandidateIdentity
                    disposition = $CandidateDisposition
                }
            }
            else { $null }
        }
    }

    function Get-TestParityGate {
        param([Parameter(Mandatory)][object]$Evaluation, [Parameter(Mandatory)][string]$Name)
        return @($Evaluation.gates | Where-Object name -CEQ $Name)[0]
    }
}

Describe 'Owner parity qualification contract' {
    It 'ships a sanitized deterministic qualification fixture' {
        $fixture = Get-Content -LiteralPath $script:QualificationFixture -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32

        $fixture.kind | Should -Be 'owner-parity-qualification'
        $fixture.schemaVersion | Should -Be 2
        @($fixture.entries).Count | Should -Be 1
        ($fixture | ConvertTo-Json -Depth 32 -Compress) |
            Should -Not -Match '(?i)bearer|github_pat|ghp_|password|secret|visualstudio\.com|@microsoft\.com'
    }

    It 'rejects duplicate adjudication keys and selectors' {
        $fixture = Get-Content -LiteralPath $script:QualificationFixture -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
        $fixture.entries[0].candidate.observationPath = Join-Path $TestDrive 'candidate.json'
        $duplicate = Copy-TestParityValue -Value $fixture.entries[0].adjudication[0]
        $duplicate.key = 'method-case-002'
        $fixture.entries[0].adjudication += $duplicate
        $path = Join-Path $TestDrive 'duplicate-adjudication.json'
        Set-Content -LiteralPath $path -Value (
            ConvertTo-Json -InputObject $fixture -Depth 32) -NoNewline

        {
            & $script:ParityModule {
                param($ManifestPath)
                Read-OwnerParityManifest -Path $ManifestPath
            } $path
        } | Should -Throw '*reuses a baseline selector*'
    }

    It 'rejects duplicate baseline cohort entries' {
        $fixture = Get-Content -LiteralPath $script:QualificationFixture -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
        $fixture.entries[0].candidate.observationPath = Join-Path $TestDrive 'candidate.json'
        $duplicate = Copy-TestParityValue -Value $fixture.entries[0]
        $duplicate.id = 'generic-preserved-case-copy'
        $fixture.entries += $duplicate
        $path = Join-Path $TestDrive 'duplicate-baseline.json'
        Set-Content -LiteralPath $path -Value (
            ConvertTo-Json -InputObject $fixture -Depth 32) -NoNewline

        {
            & $script:ParityModule {
                param($ManifestPath)
                Read-OwnerParityManifest -Path $ManifestPath
            } $path
        } | Should -Throw '*baseline headKey*duplicated*'
    }

    It 'rejects duplicate candidate evidence across cohort entries' {
        $fixture = Get-Content -LiteralPath $script:QualificationFixture -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
        $fixture.entries[0].candidate.observationPath = Join-Path $TestDrive 'candidate.json'
        $duplicate = Copy-TestParityValue -Value $fixture.entries[0]
        $duplicate.id = 'generic-preserved-case-copy'
        $duplicate.baseline.headKey = 'b' * 64
        $duplicate.adjudication[0].key = 'method-case-002'
        $fixture.entries += $duplicate
        $path = Join-Path $TestDrive 'duplicate-candidate.json'
        Set-Content -LiteralPath $path -Value (
            ConvertTo-Json -InputObject $fixture -Depth 32) -NoNewline

        {
            & $script:ParityModule {
                param($ManifestPath)
                Read-OwnerParityManifest -Path $ManifestPath
            } $path
        } | Should -Throw '*candidate observation is reused*'
    }

    It 'requires read candidates to declare unknown semantic provenance' {
        $fixture = Get-Content -LiteralPath $script:QualificationFixture -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
        $fixture.entries[0].evidence.semanticProvenance = 'offline-replay-deterministic'
        $path = Join-Path $TestDrive 'read-provenance.json'
        Set-Content -LiteralPath $path -Value (
            ConvertTo-Json -InputObject $fixture -Depth 32) -NoNewline

        {
            & $script:ParityModule {
                param($ManifestPath)
                Read-OwnerParityManifest -Path $ManifestPath
            } $path
        } | Should -Throw '*failed schema or UTF-8 JSON validation*'
    }

    It 'derives deterministic provenance from the replay candidate' {
        $candidate = [ordered]@{ mode = 'run' }
        $manifest = [ordered]@{
            entries = @(
                [ordered]@{
                    model = [ordered]@{ id = 'owner-offline-deterministic-replay' }
                }
            )
        }
        $actual = & $script:ParityModule {
            param($Candidate, $Manifest)
            Get-OwnerParityCandidateProvenance -Candidate $Candidate -Manifest $Manifest
        } $candidate $manifest

        $actual | Should -Be 'offline-replay-deterministic'
        $actual | Should -Not -Be 'offline-replay-recorded-model'
    }

    It 'passes measurable retrospective gates on independently executed preserved evidence' {
        $baseline = New-TestParityObservation
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test'
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline `
            -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(New-TestParityAdjudication)

        (Get-TestParityGate $result findingRetention).status | Should -Be 'passed'
        (Get-TestParityGate $result eligibleFalsePositives).status | Should -Be 'passed'
        (Get-TestParityGate $result bindingEquivalence).status | Should -Be 'passed'
        (Get-TestParityGate $result unknownIntegrity).status | Should -Be 'notMeasured'
        (Get-TestParityGate $result writeIsolation).status | Should -Be 'passed'
        (Get-TestParityGate $result latencyAccounting).status | Should -Be 'passed'
    }

    It 'fails finding retention when a verified v1 method finding is lost' {
        $baseline = New-TestParityObservation
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.findings = @()
            $o.counts.violations = 0
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(New-TestParityAdjudication -CandidateIdentity '')

        $gate = Get-TestParityGate $result findingRetention
        $gate.status | Should -Be 'failed'
        $gate.failures | Should -Be 1
    }

    It 'blocks retention when a baseline violation is omitted from adjudication' {
        $baseline = New-TestParityObservation
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test'
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @()

        $gate = Get-TestParityGate $result findingRetention
        $gate.status | Should -Be 'blocked'
        $gate.evidenceCode | Should -Be 'baseline-findings-or-adjudication-incomplete'
    }

    It 'does not accept incomplete adjudication as baseline violation coverage' {
        $baseline = New-TestParityObservation
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.findings = @()
            $o.counts.violations = 0
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(
                New-TestParityAdjudication `
                    -Eligibility incomplete `
                    -Truth unknown `
                    -CandidateIdentity ''
            )

        $gate = Get-TestParityGate $result findingRetention
        $gate.status | Should -Be 'blocked'
        $gate.evidenceCode | Should -Be 'baseline-findings-or-adjudication-incomplete'
    }

    It 'fails eligible false positives against complete adjudicated truth' {
        $baseline = New-TestParityObservation -Mutator {
            param($o)
            $o.findings = @()
            $o.counts.violations = 0
        }
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test'
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(
                New-TestParityAdjudication -Truth compliant -BaselineIdentity ''
            )

        $gate = Get-TestParityGate $result eligibleFalsePositives
        $gate.status | Should -Be 'failed'
        $gate.failures | Should -Be 1
    }

    It 'fails exact binding and anchor mismatches' {
        $baseline = New-TestParityObservation
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.subject.headCommit = 'f' * 40
            $o.findings[0].anchor.line = 99
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(New-TestParityAdjudication)

        $gate = Get-TestParityGate $result bindingEquivalence
        $gate.status | Should -Be 'failed'
        $gate.failures | Should -Be 2
    }

    It 'separates provider-specific dedupe accounting from semantic binding' {
        $baseline = New-TestParityObservation
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.effects.dedupe.noOp = 0
            $o.effects.dedupe.unknown = 1
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(New-TestParityAdjudication)

        $gate = Get-TestParityGate $result bindingEquivalence
        $gate.status | Should -Be 'passed'
        $gate.failures | Should -Be 0
    }

    It 'regresses PR136 representation and dedupe mismatches without passing semantic gates' {
        $baseline = New-TestParityObservation -Mutator {
            param($o)
            $o.findings[0].anchor.path = '/src\WidgetTests.cs'
            $o.findings[0].providerMarker = New-OwnerProviderMarker `
                -Value 'v1-private-marker' -Integrity verified
            $o.effects.dedupe.noOp = 1
        }
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.findings[0].anchor.path = 'src/WidgetTests.cs'
            $o.findings[0].providerMarker = New-OwnerProviderMarker
            $o.effects.dedupe.noOp = 0
            $o.effects.dedupe.unknown = 1
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence `
                -SemanticProvenance offline-replay-deterministic) `
            -Adjudication @(New-TestParityAdjudication)

        (Get-TestParityGate $result bindingEquivalence).status | Should -Be 'passed'
        (Get-TestParityGate $result findingRetention).status | Should -Be 'blocked'
        (Get-TestParityGate $result eligibleFalsePositives).status | Should -Be 'blocked'
        $result.metrics.providerMarkersAvailable | Should -Be 1
        $result.metrics.providerMarkersVerified | Should -Be 1
        $result.metrics.providerMarkersInvalid | Should -Be 0
    }

    It 'compares anchors for paired unknown findings' {
        $baseline = New-TestParityObservation -Mutator {
            param($o)
            $o.findings[0].disposition = 'unknown'
            $o.findings[0].anchor.path = 'unknown'
            $o.counts.violations = 0
            $o.counts.unknown = 1
        }
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.findings[0].disposition = 'unknown'
            $o.findings[0].anchor.path = 'unknown'
            $o.findings[0].anchor.line = 99
            $o.counts.violations = 0
            $o.counts.unknown = 1
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(
                New-TestParityAdjudication `
                    -Truth unknown `
                    -BaselineDisposition unknown `
                    -CandidateDisposition unknown
            )

        $gate = Get-TestParityGate $result bindingEquivalence
        $gate.status | Should -Be 'failed'
        $gate.failures | Should -Be 1
    }

    It 'fails unknown conversion and blocks unexposed unknown outcomes' {
        $baseline = New-TestParityObservation -Mutator {
            param($o)
            $o.findings[0].disposition = 'unknown'
            $o.counts.violations = 0
            $o.counts.unknown = 1
        }
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test'
        $converted = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(
                New-TestParityAdjudication `
                    -Truth unknown `
                    -BaselineDisposition unknown `
                    -CandidateDisposition violation
            )
        (Get-TestParityGate $converted unknownIntegrity).status | Should -Be 'failed'

        $blocked = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(
                New-TestParityAdjudication `
                    -Truth unknown `
                    -BaselineDisposition unknown `
                    -CandidateIdentity ''
            )
        (Get-TestParityGate $blocked unknownIntegrity).status | Should -Be 'blocked'
    }

    It 'blocks incomplete cohorts instead of inferring uncovered units as compliant' {
        $baseline = New-TestParityObservation -Mutator {
            param($o)
            $o.lifecycle.status = 'incomplete'
            $o.lifecycle.completed = $false
            $o.lifecycle.incomplete = $true
            $o.findings = @()
            $o.findingsComplete = $false
            $o.counts.violations = 0
            $o.counts.uncovered = 3
        }
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.findings = @()
            $o.counts.violations = 0
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @()

        $gate = Get-TestParityGate $result unknownIntegrity
        $gate.status | Should -Be 'blocked'
        $gate.blocked | Should -Be 4
    }

    It 'represents unavailable exact evidence as blocked rather than successful' {
        $baseline = New-TestParityObservation -Mutator {
            param($o)
            $o.findings[0].disposition = 'unknown'
            $o.counts.violations = 0
            $o.counts.unknown = 1
        }
        $result = & $script:ParityModule {
            param($Observation, $Adjudication)
            New-OwnerParityUnavailableEvaluation `
                -Baseline $Observation `
                -Adjudication @($Adjudication) `
                -Reason 'exact-evidence-unavailable'
        } $baseline (New-TestParityAdjudication `
                -Truth unknown `
                -BaselineDisposition unknown `
                -CandidateIdentity '')

        (Get-TestParityGate $result eligibleFalsePositives).status | Should -Be 'blocked'
        (Get-TestParityGate $result bindingEquivalence).status | Should -Be 'blocked'
        (Get-TestParityGate $result unknownIntegrity).status | Should -Be 'blocked'
        (Get-TestParityGate $result writeIsolation).status | Should -Be 'blocked'
        (Get-TestParityGate $result latencyAccounting).status | Should -Be 'blocked'
        (Get-TestParityGate $result latencyAccounting).blocked | Should -Be 12
        $result.metrics.candidateCompleted | Should -Be 'unknown'
        $result.metrics.falsePositiveMeasured | Should -BeFalse
    }

    It 'blocks unknown integrity when the uncovered count is unknown' {
        $baseline = New-TestParityObservation -Mutator {
            param($o)
            $o.findings[0].disposition = 'unknown'
            $o.counts.violations = 0
            $o.counts.unknown = 1
            $o.counts.uncovered = 'unknown'
        }
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.findings[0].disposition = 'unknown'
            $o.counts.violations = 0
            $o.counts.unknown = 1
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(
                New-TestParityAdjudication `
                    -Truth unknown `
                    -BaselineDisposition unknown `
                    -CandidateDisposition unknown
            )

        (Get-TestParityGate $result unknownIntegrity).status | Should -Be 'blocked'
    }

    It 'does not let unmeasured entries erase a measured aggregate pass' {
        $status = & $script:ParityModule {
            Get-OwnerParityAggregateStatus -Statuses @('passed', 'notMeasured')
        }

        $status | Should -Be 'passed'
    }

    It 'accepts explicit unknown latency accounting without manufacturing zero' {
        $baseline = New-TestParityObservation -Mutator {
            param($o)
            $o.execution.latencyMs = 'unknown'
            $o.execution.modelStarts = 'unknown'
            $o.effects.operatorIntervention = 'unknown'
        }
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.execution.latencyMs = 'unknown'
            $o.execution.attempts = 'unknown'
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(New-TestParityAdjudication)

        (Get-TestParityGate $result latencyAccounting).status | Should -Be 'passed'
        (Get-TestParityGate $result latencyAccounting).measured | Should -Be 24
        $baseline.execution.latencyMs | Should -Be 'unknown'
        $candidate.execution.attempts | Should -Be 'unknown'
    }

    It 'requires an explicit violation-count measurement state' {
        $observation = New-TestParityObservation
        [void]$observation.measurements.counts.Remove('violations')

        $valid = & $script:ParityModule {
            param($Value)
            Test-OwnerParityObservationAccounting -Observation $Value
        } $observation

        $valid | Should -BeFalse
    }

    It 'distinguishes measured zero from unavailable and not-measured telemetry' {
        $baseline = New-TestParityObservation
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test'
        $candidate.execution.latencyMs = 0
        $candidate.execution.modelStarts = 'unknown'
        $candidate.execution.attempts = 'unknown'
        $candidate.measurements.execution.latencyMs =
            New-OwnerMeasurement -Status measured -Value 0
        $candidate.measurements.execution.modelStarts =
            New-OwnerMeasurement -Status unavailable -Reason 'launcher-unavailable'
        $candidate.measurements.execution.attempts =
            New-OwnerMeasurement -Status notMeasured -Reason 'replay-not-requested'

        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(New-TestParityAdjudication)

        (Get-TestParityGate $result latencyAccounting).status | Should -Be 'passed'
        $candidate.measurements.execution.latencyMs.value | Should -Be 0
        $candidate.measurements.execution.modelStarts.value | Should -BeNullOrEmpty
        $candidate.measurements.execution.attempts.value | Should -BeNullOrEmpty
    }

    It 'fails any candidate provider or tool write evidence' {
        $baseline = New-TestParityObservation
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.effects.providerWrites = 1
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(New-TestParityAdjudication)

        (Get-TestParityGate $result writeIsolation).status | Should -Be 'failed'
    }

    It 'does not let unknown write accounting override a proven provider write' {
        $baseline = New-TestParityObservation
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.effects.providerWrites = 1
            $o.effects.writeToolInvocations = 'unknown'
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(New-TestParityAdjudication)

        (Get-TestParityGate $result writeIsolation).status | Should -Be 'failed'
    }

    It 'blocks contradictory complete candidate violation inventories' {
        $baseline = New-TestParityObservation
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.counts.violations = 2
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(New-TestParityAdjudication)

        (Get-TestParityGate $result findingRetention).status | Should -Be 'blocked'
        (Get-TestParityGate $result eligibleFalsePositives).status | Should -Be 'blocked'
        $result.metrics.candidateViolations | Should -Be 2
    }

    It 'does not let incomplete baseline inventory hide a proven retained-finding loss' {
        $baseline = New-TestParityObservation -Mutator {
            param($o)
            $o.findingsComplete = $false
            $o.counts.uncovered = 1
        }
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.findings = @()
            $o.counts.violations = 0
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(New-TestParityAdjudication -CandidateIdentity '')

        $gate = Get-TestParityGate $result findingRetention
        $gate.status | Should -Be 'failed'
        $gate.failures | Should -Be 1
    }

    It 'does not pass retained findings or false positives from synthetic provenance alone' {
        $baseline = New-TestParityObservation
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test'
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence -Class synthetic) `
            -Adjudication @(New-TestParityAdjudication)

        (Get-TestParityGate $result findingRetention).status | Should -Be 'blocked'
        (Get-TestParityGate $result eligibleFalsePositives).status | Should -Be 'blocked'
    }

    It 'does not treat a deterministic harness oracle as semantic evidence' {
        $baseline = New-TestParityObservation
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test'
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence `
                -SemanticProvenance 'offline-replay-deterministic') `
            -Adjudication @(New-TestParityAdjudication)

        (Get-TestParityGate $result findingRetention).status | Should -Be 'blocked'
        (Get-TestParityGate $result findingRetention).evidenceCode |
            Should -Be 'deterministic-oracle-not-semantic-evidence'
        (Get-TestParityGate $result eligibleFalsePositives).status | Should -Be 'blocked'
    }

    It 'blocks missing retained findings when the candidate inventory is incomplete' {
        $baseline = New-TestParityObservation
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.findings = @()
            $o.findingsComplete = $false
            $o.counts.violations = 0
            $o.counts.uncovered = 1
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(New-TestParityAdjudication -CandidateIdentity '')

        $gate = Get-TestParityGate $result findingRetention
        $gate.status | Should -Be 'blocked'
        $gate.evidenceCode | Should -Be 'candidate-findings-incomplete'
    }

    It 'blocks false-positive claims when candidate findings are incomplete' {
        $baseline = New-TestParityObservation
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test' -Mutator {
            param($o)
            $o.findingsComplete = $false
            $o.counts.uncovered = 1
        }
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(New-TestParityAdjudication)

        (Get-TestParityGate $result eligibleFalsePositives).status | Should -Be 'blocked'
    }

    It 'uses aggregate unknown counts when finding detail is incomplete' {
        $baseline = New-TestParityObservation -Mutator {
            param($o)
            $o.findings = @()
            $o.findingsComplete = $false
            $o.counts.violations = 0
            $o.counts.unknown = 3
        }
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test'
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @()

        $gate = Get-TestParityGate $result unknownIntegrity
        $gate.status | Should -Be 'blocked'
        $gate.blocked | Should -BeGreaterOrEqual 3
    }

    It 'keeps class findings advisory-only for comment eligibility' {
        $baseline = New-TestParityObservation -Mutator {
            param($o)
            $o.findings = @()
            $o.counts.violations = 0
        }
        $candidate = New-TestParityObservation -ImplementationId 'owner-v2-test'
        $result = Invoke-OwnerParityGateEvaluation `
            -Baseline $baseline -Candidate $candidate `
            -Evidence (New-TestParityEvidence) `
            -Adjudication @(
                New-TestParityAdjudication `
                    -Truth unknown -Eligibility 'class-advisory' -BaselineIdentity ''
            )

        (Get-TestParityGate $result eligibleFalsePositives).status | Should -Be 'passed'
    }
}

Describe 'Owner parity snapshots, paths, and sanitization' {
    It 'detects rollback snapshot differences in bytes, counts, and timestamps' {
        $root = Join-Path $TestDrive 'frozen'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'state.json') -Value '{}' -NoNewline
        $before = Get-OwnerParityStateSnapshot -Root $root
        Set-Content -LiteralPath (Join-Path $root 'state.json') -Value '{"changed":true}' -NoNewline
        $after = Get-OwnerParityStateSnapshot -Root $root

        $comparison = Compare-OwnerParitySnapshots -Before $before -After $after

        $comparison.unchanged | Should -BeFalse
        $comparison.differences | Should -Contain 'byteCount'
        $comparison.differences | Should -Contain 'rootHash'
    }

    It 'fails rollback proof when v1 changed before qualification execution' {
        $expected = [ordered]@{
            fileCount = 2
            byteCount = 20
            newestWriteTicks = 100
            rootHash = 'a' * 64
        }
        $current = [ordered]@{
            fileCount = 2
            byteCount = 21
            newestWriteTicks = 101
            rootHash = 'b' * 64
        }
        $proof = & $script:ParityModule {
            param($Expected, $Before, $After)
            New-OwnerParityRollbackProof `
                -Expected $Expected -Before $Before -After $After
        } $expected $current $current

        $proof.unchanged | Should -BeFalse
        $proof.differences | Should -Contain 'preexisting:byteCount'
        $proof.differences | Should -Contain 'preexisting:newestWriteTicks'
        $proof.differences | Should -Contain 'preexisting:rootHash'
        @($proof.differences | Where-Object { $_ -like 'during:*' }).Count | Should -Be 0
    }

    It 'rejects v2 roots inside v1 or the repository and permits a separate root' {
        $v1 = Join-Path $TestDrive 'v1'
        $v2 = Join-Path $TestDrive 'v2'
        New-Item -ItemType Directory -Path $v1 -Force | Out-Null

        (Test-OwnerParityPathIsolation `
                -V1StateRoot $v1 -V2StateRoot $v2 `
                -RepositoryRoot $script:RepoRoot).isolated | Should -BeTrue
        (Test-OwnerParityPathIsolation `
                -V1StateRoot $v1 -V2StateRoot (Join-Path $v1 'candidate') `
                -RepositoryRoot $script:RepoRoot).isolated | Should -BeFalse
        (Test-OwnerParityPathIsolation `
                -V1StateRoot $v1 -V2StateRoot (Join-Path $script:RepoRoot 'state') `
                -RepositoryRoot $script:RepoRoot).isolated | Should -BeFalse
    }

    It 'rejects private replay candidate output inside v1 or the repository' {
        $v1 = Join-Path $TestDrive 'v1'
        $evidence = Join-Path $v1 'evidence'
        New-Item -ItemType Directory -Path $evidence -Force | Out-Null
        $tool = Join-Path $script:RepoRoot 'tools/New-OwnerParityReplayCandidate.ps1'
        $output = Join-Path $script:RepoRoot 'private-replay-candidate.json'

        {
                & $tool `
                    -BaselineObservationPath $script:ObservationFixture `
                    -V1StateRoot $v1 `
                    -PreservedEvidenceRoot $evidence `
                    -OutputPath $output `
                    -EntryId 'path-test'
        } | Should -Throw '*outside V1StateRoot and the repository*'
        Test-Path -LiteralPath $output | Should -BeFalse

        if ($IsWindows) {
            $deviceAlias = '\\?\' + $output
            {
                & $tool `
                    -BaselineObservationPath $script:ObservationFixture `
                    -V1StateRoot $v1 `
                    -PreservedEvidenceRoot $evidence `
                    -OutputPath $deviceAlias `
                    -EntryId 'device-alias-test'
            } | Should -Throw '*device-path alias*'

            $driveName = @('Z', 'Y', 'X', 'Q') |
                Where-Object { $null -eq (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) } |
                Select-Object -First 1
            if ($driveName) {
                New-PSDrive -Name $driveName -PSProvider FileSystem -Root $script:RepoRoot `
                    -Scope Global | Out-Null
                try {
                    $aliasedModule = Import-Module `
                        "$driveName`:\src\DevPilot.OwnerParity\DevPilot.OwnerParity.psd1" `
                        -Force -PassThru
                    $resolvedRepository = & $aliasedModule {
                        $script:OwnerParityRepositoryRoot
                    }
                    $resolvedRepository | Should -Be ([IO.Path]::GetFullPath($script:RepoRoot))
                    {
                        & $tool `
                            -BaselineObservationPath $script:ObservationFixture `
                            -V1StateRoot $v1 `
                            -PreservedEvidenceRoot $evidence `
                            -OutputPath "$driveName`:\private-replay-candidate.json" `
                            -EntryId 'provider-alias-test'
                    } | Should -Throw '*outside V1StateRoot and the repository*'
                    {
                        & "$driveName`:\tools\New-OwnerParityReplayCandidate.ps1" `
                            -BaselineObservationPath $script:ObservationFixture `
                            -V1StateRoot $v1 `
                            -PreservedEvidenceRoot $evidence `
                            -OutputPath $output `
                            -EntryId 'aliased-launch-test'
                    } | Should -Throw '*outside V1StateRoot and the repository*'
                }
                finally {
                    Remove-PSDrive -Name $driveName -Scope Global -Force
                    Import-Module $script:ModulePath -Force
                    $script:ParityModule = Get-Module DevPilot.OwnerParity
                }
            }
        }
    }

    It 'requires an exact local-byte reference manifest for replay candidate generation' {
        $v1 = Join-Path $TestDrive 'reference-v1'
        $evidence = Join-Path $v1 'evidence'
        $output = Join-Path $TestDrive 'private-output\candidate.json'
        New-Item -ItemType Directory -Path $evidence -Force | Out-Null
        $tool = Join-Path $script:RepoRoot 'tools/New-OwnerParityReplayCandidate.ps1'

        {
            & $tool `
                -BaselineObservationPath $script:ObservationFixture `
                -V1StateRoot $v1 `
                -PreservedEvidenceRoot $evidence `
                -OutputPath $output `
                -EntryId 'missing-reference-manifest'
        } | Should -Throw '*ReferenceManifestPath is required*'
    }

    It 'emits only fixed-shape aggregate fields and redacts private report detail by omission' {
        $report = [ordered]@{
            entries = @(
                [ordered]@{
                    id = 'private-pr-99999'
                    evidence = [ordered]@{
                        semanticProvenance = 'offline-replay-deterministic'
                    }
                    baseline = [ordered]@{
                        subject = [ordered]@{ repositoryId = 'secret-repository' }
                    }
                    candidateObservationPath = 'C:\private\evidence.json'
                    metrics = [ordered]@{
                        verifiedMethodFindings = 2
                        retainedMethodFindings = 2
                        retentionMeasured = $true
                        falsePositiveMeasured = $true
                        candidateViolations = 2
                        eligibleFalsePositives = 0
                        baselineCompleted = $true
                        candidateCompleted = $false
                    }
                }
            )
            gates = @(
                [ordered]@{
                    name = 'findingRetention'
                    status = 'passed'
                    evidenceCode = 'all-verified-method-findings-retained'
                    measured = 2
                    failures = 0
                    blocked = 0
                }
            )
            rollback = [ordered]@{
                unchanged = $true
                differences = @()
                before = [ordered]@{ root = 'C:\private\v1' }
            }
        }

        $summary = ConvertTo-OwnerParitySanitizedSummary -Report $report
        $json = $summary | ConvertTo-Json -Depth 32 -Compress

        $summary.sample.entries | Should -Be 1
        $summary.sample.verifiedMethodFindings | Should -Be 2
        $summary.sample.retainedMethodFindings | Should -Be 2
        $summary.sample.retentionUnmeasured | Should -Be 0
        $summary.sample.eligibleFalsePositives | Should -Be 0
        $summary.sample.falsePositiveMeasuredEntries | Should -Be 1
        $summary.sample.falsePositiveUnmeasuredEntries | Should -Be 0
        $json | Should -Not -Match 'private-pr|secret-repository|private\\evidence|private\\v1'
        @($summary.Keys | Sort-Object) |
            Should -Be @('gates', 'kind', 'prospectiveRealModel', 'rollback', 'sample', 'schemaVersion', 'scope')
    }

    It 'reports unmeasured false-positive evidence as unavailable rather than zero' {
        $report = [ordered]@{
            entries = @(
                [ordered]@{
                    metrics = [ordered]@{
                        verifiedMethodFindings = 0
                        retainedMethodFindings = 0
                        retentionMeasured = $false
                        falsePositiveMeasured = $false
                        candidateViolations = 0
                        eligibleFalsePositives = 0
                        baselineCompleted = $true
                        candidateCompleted = 'unknown'
                    }
                }
            )
            gates = @()
            rollback = [ordered]@{
                unchanged = $true
                differences = @()
                before = [ordered]@{ itemCount = 1 }
            }
        }

        $summary = ConvertTo-OwnerParitySanitizedSummary -Report $report

        $summary.sample.eligibleFalsePositives | Should -BeNullOrEmpty
        $summary.sample.falsePositiveMeasuredEntries | Should -Be 0
        $summary.sample.falsePositiveUnmeasuredEntries | Should -Be 1
    }

    It 'fails completion reliability when v2 completion is below v1' {
        $reports = @(
            [pscustomobject]@{
                metrics = [ordered]@{
                    baselineCompleted = $true
                    candidateCompleted = $false
                    verifiedMethodFindings = 2
                    retainedMethodFindings = 2
                    retentionMeasured = $true
                }
            }
        )
        $gate = & $script:ParityModule {
            param($Values)
            New-OwnerParityCompletionGate -EntryReports $Values
        } $reports

        $gate.status | Should -Be 'failed'
        $gate.evidenceCode | Should -Be 'candidate-completion-or-retention-rate-lower'
    }

    It 'blocks completion reliability when candidate completion is unavailable' {
        $reports = @(
            [pscustomobject]@{
                metrics = [ordered]@{
                    baselineCompleted = $true
                    candidateCompleted = 'unknown'
                    verifiedMethodFindings = 0
                    retainedMethodFindings = 0
                    retentionMeasured = 'unknown'
                }
            },
            [pscustomobject]@{
                metrics = [ordered]@{
                    baselineCompleted = $true
                    candidateCompleted = $true
                    verifiedMethodFindings = 1
                    retainedMethodFindings = 1
                    retentionMeasured = $true
                }
            }
        )
        $gate = & $script:ParityModule {
            param($Values)
            New-OwnerParityCompletionGate -EntryReports $Values
        } $reports

        $gate.status | Should -Be 'blocked'
        $gate.evidenceCode | Should -Be 'completion-or-retention-unavailable'
    }

    It 'does not let unavailable cohort entries override a proven completion failure' {
        $reports = @(
            [pscustomobject]@{
                metrics = [ordered]@{
                    baselineCompleted = $true
                    candidateCompleted = 'unknown'
                    verifiedMethodFindings = 0
                    retainedMethodFindings = 0
                    retentionMeasured = $false
                    retentionPopulationKnown = $false
                }
            },
            [pscustomobject]@{
                metrics = [ordered]@{
                    baselineCompleted = $true
                    candidateCompleted = $false
                    verifiedMethodFindings = 1
                    retainedMethodFindings = 0
                    retentionMeasured = $true
                    retentionPopulationKnown = $true
                }
            }
        )
        $gate = & $script:ParityModule {
            param($Values)
            New-OwnerParityCompletionGate -EntryReports $Values
        } $reports

        $gate.status | Should -Be 'failed'
        $gate.evidenceCode | Should -Be 'candidate-completion-or-retention-rate-lower'
    }

    It 'blocks completion when unknown outcomes can close the measured deficit' {
        $reports = @(
            [pscustomobject]@{
                metrics = [ordered]@{
                    baselineCompleted = $true
                    candidateCompleted = $false
                    verifiedMethodFindings = 0
                    retainedMethodFindings = 0
                    retentionMeasured = $false
                    retentionPopulationKnown = $true
                }
            },
            [pscustomobject]@{
                metrics = [ordered]@{
                    baselineCompleted = $false
                    candidateCompleted = 'unknown'
                    verifiedMethodFindings = 0
                    retainedMethodFindings = 0
                    retentionMeasured = $false
                    retentionPopulationKnown = $true
                }
            }
        )
        $gate = & $script:ParityModule {
            param($Values)
            New-OwnerParityCompletionGate -EntryReports $Values
        } $reports

        $gate.status | Should -Be 'blocked'
        $gate.evidenceCode | Should -Be 'completion-or-retention-unavailable'
    }

    It 'blocks completion reliability for an unknown zero-sized retention denominator' {
        $reports = @(
            [pscustomobject]@{
                metrics = [ordered]@{
                    baselineCompleted = $true
                    candidateCompleted = $true
                    verifiedMethodFindings = 0
                    retainedMethodFindings = 0
                    retentionMeasured = $false
                    retentionPopulationKnown = $false
                }
            }
        )
        $gate = & $script:ParityModule {
            param($Values)
            New-OwnerParityCompletionGate -EntryReports $Values
        } $reports

        $gate.status | Should -Be 'blocked'
        $gate.evidenceCode | Should -Be 'completion-or-retention-unavailable'
    }

    It 'blocks retained-unit reliability when semantic retention is blocked' {
        $reports = @(
            [pscustomobject]@{
                metrics = [ordered]@{
                    baselineCompleted = $true
                    candidateCompleted = $true
                    verifiedMethodFindings = 2
                    retainedMethodFindings = 2
                    retentionMeasured = $false
                }
            }
        )
        $gate = & $script:ParityModule {
            param($Values)
            New-OwnerParityCompletionGate -EntryReports $Values
        } $reports

        $gate.status | Should -Be 'blocked'
        $gate.evidenceCode | Should -Be 'completion-or-retention-unavailable'
    }

    It 'blocks unavailable retention when the baseline inventory is incomplete' {
        $baseline = New-TestParityObservation -Mutator {
            param($o)
            $o.findings = @()
            $o.findingsComplete = $false
            $o.counts.violations = 2
            $o.counts.uncovered = 2
        }
        $result = & $script:ParityModule {
            param($Observation)
            New-OwnerParityUnavailableEvaluation `
                -Baseline $Observation `
                -Adjudication @() `
                -Reason 'exact-evidence-unavailable' `
                -CandidateCompleted $false
        } $baseline

        (Get-TestParityGate $result findingRetention).status | Should -Be 'blocked'
        $result.metrics.candidateCompleted | Should -BeFalse
        $result.metrics.retentionPopulationKnown | Should -BeFalse
    }
}
