BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.RelationEvidence\DevPilot.RelationEvidence.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerModelRunner\DevPilot.OwnerModelRunner.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1" -Force

    $script:RelationCases = (
        Get-Content "$PSScriptRoot\fixtures\relation-evidence\generic-cases.json" -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
    ).cases
    $script:RuleText = 'Public responses must omit confidential values and preserve ordinary configuration.'

    function Get-TestRelationDigest {
        param([Parameter(Mandatory)][object]$Value)
        $text = ConvertTo-RelationEvidenceCanonicalJson -Value $Value
        return 'v1:sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes($text))
        ).ToLowerInvariant()
    }

    function Get-TestRelationCase {
        param([Parameter(Mandatory)][string]$Id)
        return @($script:RelationCases | Where-Object id -CEQ $Id)[0]
    }

    function New-TestRelationEvidence {
        param(
            [Parameter(Mandatory)][Collections.IDictionary]$Case,
            [string]$MissingRole = '',
            [string]$SourceCommit = ('a' * 40)
        )

        return @(
            foreach ($item in @($Case.evidence)) {
                $roles = @($item.roles | ForEach-Object { [string]$_ })
                if ($MissingRole -and $roles -ccontains $MissingRole) { continue }
                $content = [string]$item.content
                [ordered]@{
                    ref = "evidence:$($item.id)"
                    type = [string]$item.type
                    path = [string]$item.path
                    span = [ordered]@{
                        startLine = [int]$item.startLine
                        endLine = [int]$item.endLine
                    }
                    digest = Get-TestRelationDigest $content
                    provenance = [ordered]@{
                        repositoryId = 'repository-example'
                        commit = $SourceCommit
                        sourceKind = $(if ([string]$item.type -ceq 'synthetic') {
                                'synthetic'
                            }
                            else {
                                'repository'
                            })
                    }
                    roleLabels = $roles
                    state = 'complete'
                    content = $content
                }
            }
        )
    }

    function New-TestRelationSlots {
        param(
            [Parameter(Mandatory)][Collections.IDictionary]$Case,
            [string]$MissingRole = ''
        )

        return @(
            foreach ($item in @($Case.evidence)) {
                foreach ($role in @($item.roles)) {
                    [ordered]@{
                        role = [string]$role
                        evidenceRef = $(if ([string]$role -ceq $MissingRole) {
                                $null
                            }
                            else {
                                "evidence:$($item.id)"
                            })
                        required = $true
                    }
                }
            }
        )
    }

    function New-TestRelationRequest {
        param(
            [Parameter(Mandatory)][Collections.IDictionary]$Case,
            [string]$MissingRole = '',
            [object]$Limits = (New-RelationEvidenceLimits),
            [string]$SourceCommit = ('a' * 40),
            [object[]]$AdditionalClaims = @(),
            [string[]]$AnchorCandidateIds = @('response-filter'),
            [object[]]$AnchorCandidates = @()
        )

        $claims = @(
            [ordered]@{
                claimId = [string]$Case.id
                question = [string]$Case.question
                applicability = 'applicable'
                slots = New-TestRelationSlots -Case $Case -MissingRole $MissingRole
                anchorCandidateIds = $AnchorCandidateIds
                severity = 'high'
                policy = 'preview-only'
            }
        ) + @($AdditionalClaims)
        $anchors = if ($AnchorCandidates.Count -gt 0) {
            $AnchorCandidates
        }
        else {
            @(
                [ordered]@{
                    anchorId = 'response-filter'
                    path = [string](@($Case.evidence | Where-Object roles -Contains sanitizer)[0].path)
                    startLine = [int](@($Case.evidence | Where-Object roles -Contains sanitizer)[0].startLine)
                    endLine = [int](@($Case.evidence | Where-Object roles -Contains sanitizer)[0].endLine)
                    symbol = 'ApplyResponseFilter'
                }
            )
        }
        return New-RelationEvidenceRequest `
            -RepositoryId 'repository-example' `
            -ProjectId 'project-example' `
            -PullRequestId 42 `
            -SourceCommit $SourceCommit `
            -TargetCommit ('b' * 40) `
            -TargetRef 'refs/heads/main' `
            -CapabilityId 'relation-response-confidentiality-v1' `
            -CapabilityDigest (Get-TestRelationDigest 'relation-response-confidentiality-v1') `
            -RuleId 'response-confidentiality' `
            -RuleDigest (Get-TestRelationDigest $script:RuleText) `
            -RuleText $script:RuleText `
            -EvidenceRefs (New-TestRelationEvidence -Case $Case -MissingRole $MissingRole `
                -SourceCommit $SourceCommit) `
            -Claims $claims `
            -AnchorCandidates $anchors `
            -Limits $Limits
    }

    function New-TestRelationRunner {
        param(
            [Parameter(Mandatory)][Collections.IDictionary]$Verdicts,
            [Collections.IDictionary]$Modes = @{}
        )

        $requests = [Collections.Generic.List[object]]::new()
        $capturedVerdicts = $Verdicts
        $capturedModes = $Modes
        $runner = New-OwnerSemanticRunner -Name 'relation-evidence-offline-fake' -Handler {
            param($request)
            $copy = ConvertFrom-Json -InputObject (
                ConvertTo-Json -InputObject $request -Depth 32 -Compress
            ) -AsHashtable -Depth 32
            [void]$requests.Add($copy)
            $claimId = [string]$request.claim.claimId
            $mode = if ($capturedModes.Contains($claimId)) {
                [string]$capturedModes[$claimId]
            }
            else {
                'valid'
            }
            if ($mode -ceq 'malformed') {
                return [ordered]@{
                    schemaVersion = 3
                    executionUnitId = $request.executionUnitId
                    verdict = [string]$capturedVerdicts[$claimId]
                }
            }
            $verdict = [string]$capturedVerdicts[$claimId]
            return [ordered]@{
                schemaVersion = 3
                executionUnitId = $request.executionUnitId
                verdict = $verdict
                citedEvidenceRefs = $(if ($verdict -ceq 'unknown') {
                        @()
                    }
                    else {
                        @($request.evidence | Select-Object -First 3 | ForEach-Object ref)
                    })
                explanation = "The bounded evidence supports the $verdict result."
                remediation = 'Make response filtering independent of incidental prior state.'
            }
        }.GetNewClosure()
        return [pscustomobject]@{
            Runner = $runner
            Requests = $requests
        }
    }

    function Invoke-TestRelationCase {
        param(
            [Parameter(Mandatory)][Collections.IDictionary]$Case,
            [string]$MissingRole = '',
            [Collections.IDictionary]$Modes = @{},
            [object]$Limits = (New-RelationEvidenceLimits),
            [string]$SourceCommit = ('a' * 40),
            [object[]]$AdditionalClaims = @()
        )

        $request = New-TestRelationRequest -Case $Case -MissingRole $MissingRole `
            -Limits $Limits -SourceCommit $SourceCommit -AdditionalClaims $AdditionalClaims
        $verdicts = @{}
        $verdicts[[string]$Case.id] = [string]$Case.expectedVerdict
        foreach ($claim in $AdditionalClaims) {
            $verdicts[[string]$claim.claimId] = 'violation'
        }
        $runner = New-TestRelationRunner -Verdicts $verdicts -Modes $Modes
        $result = Invoke-OwnerReviewPipeline `
            -Binding $request.Binding `
            -AcquisitionAdapter (New-RelationEvidenceAcquisitionAdapter -Request $request) `
            -CapabilityAdapter (New-RelationEvidenceCapabilityAdapter `
                -Runner $runner.Runner -Limits $Limits)
        if ($null -eq $result.preview) {
            throw "Relation pipeline failed before preview: $(
                ConvertTo-Json -InputObject $result -Depth 12 -Compress)"
        }
        return [pscustomobject]@{
            Request = $request
            Runner = $runner
            Result = $result
            Observation = ConvertTo-RelationEvidenceObservation -PipelineResult $result
        }
    }
}

Describe 'Relation-evidence contextual capability' {
    It 'canonicalizes a versioned bounded wrapper-owned declaration' {
        $request = New-TestRelationRequest -Case (Get-TestRelationCase 'cold-read')
        $declaration = $request.Request.declaration

        $declaration.schemaVersion | Should -Be 1
        $declaration.semantics | Should -Be 'relation-evidence-assessment-v1'
        $declaration.bindingId | Should -Be $request.Binding.BindingId
        $declaration.budgets.evidenceBytes | Should -BeLessOrEqual 10000
        $declaration.budgets.evidenceTokenUpperBound |
            Should -Be $declaration.budgets.evidenceBytes
        $request.RequestDigest | Should -Match '^v1:sha256:[0-9a-f]{64}$'
        (ConvertTo-RelationEvidenceCanonicalJson $request.Request) |
            Should -BeExactly (ConvertTo-RelationEvidenceCanonicalJson $request.Request)
    }

    It 'rejects duplicate refs, unknown refs, and swapped role bindings' {
        $case = Get-TestRelationCase 'cold-read'
        $evidence = New-TestRelationEvidence -Case $case
        $duplicate = @($evidence) + @($evidence[0])
        {
            New-RelationEvidenceRequest `
                -RepositoryId 'repository-example' -ProjectId 'project-example' -PullRequestId 42 `
                -SourceCommit ('a' * 40) -TargetCommit ('b' * 40) -TargetRef 'refs/heads/main' `
                -CapabilityId 'relation-example' -CapabilityDigest (Get-TestRelationDigest 'relation-example') `
                -RuleId 'response-rule' -RuleDigest (Get-TestRelationDigest $script:RuleText) `
                -RuleText $script:RuleText -EvidenceRefs $duplicate `
                -Claims @([ordered]@{
                        claimId = 'cold-read'
                        question = [string]$case.question
                        applicability = 'applicable'
                        slots = New-TestRelationSlots -Case $case
                        anchorCandidateIds = @('response-filter')
                        severity = 'high'
                        policy = 'preview-only'
                    }) `
                -AnchorCandidates @([ordered]@{
                        anchorId = 'response-filter'
                        path = 'src/Example/ResponseFilter.cs'
                        startLine = 40
                        endLine = 52
                        symbol = 'ApplyResponseFilter'
                    })
        } | Should -Throw '*Duplicate evidence ref*'

        $unknownSlots = New-TestRelationSlots -Case $case
        $unknownSlots[0].evidenceRef = 'evidence:not-present'
        {
            New-RelationEvidenceRequest `
                -RepositoryId 'repository-example' -ProjectId 'project-example' -PullRequestId 42 `
                -SourceCommit ('a' * 40) -TargetCommit ('b' * 40) -TargetRef 'refs/heads/main' `
                -CapabilityId 'relation-example' -CapabilityDigest (Get-TestRelationDigest 'relation-example') `
                -RuleId 'response-rule' -RuleDigest (Get-TestRelationDigest $script:RuleText) `
                -RuleText $script:RuleText -EvidenceRefs $evidence `
                -Claims @([ordered]@{
                        claimId = 'cold-read'
                        question = [string]$case.question
                        applicability = 'applicable'
                        slots = $unknownSlots
                        anchorCandidateIds = @('response-filter')
                        severity = 'high'
                        policy = 'preview-only'
                    }) `
                -AnchorCandidates @([ordered]@{
                        anchorId = 'response-filter'
                        path = 'src/Example/ResponseFilter.cs'
                        startLine = 40
                        endLine = 52
                        symbol = 'ApplyResponseFilter'
                    })
        } | Should -Throw '*references unknown evidence*'

        $swapped = New-TestRelationSlots -Case $case
        ($swapped | Where-Object role -CEQ cache-lookup).evidenceRef = 'evidence:sanitizer'
        {
            New-RelationEvidenceRequest `
                -RepositoryId 'repository-example' -ProjectId 'project-example' -PullRequestId 42 `
                -SourceCommit ('a' * 40) -TargetCommit ('b' * 40) -TargetRef 'refs/heads/main' `
                -CapabilityId 'relation-example' -CapabilityDigest (Get-TestRelationDigest 'relation-example') `
                -RuleId 'response-rule' -RuleDigest (Get-TestRelationDigest $script:RuleText) `
                -RuleText $script:RuleText -EvidenceRefs $evidence `
                -Claims @([ordered]@{
                        claimId = 'cold-read'
                        question = [string]$case.question
                        applicability = 'applicable'
                        slots = $swapped
                        anchorCandidateIds = @('response-filter')
                        severity = 'high'
                        policy = 'preview-only'
                    }) `
                -AnchorCandidates @([ordered]@{
                        anchorId = 'response-filter'
                        path = 'src/Example/ResponseFilter.cs'
                        startLine = 40
                        endLine = 52
                        symbol = 'ApplyResponseFilter'
                    })
        } | Should -Throw '*does not match the evidence role binding*'
    }

    It 'binds evidence provenance to the declared repository, commit, and type' {
        $case = Get-TestRelationCase 'cold-read'
        $mutations = @(
            @{
                Name = 'repository'
                Expected = '*request repository binding*'
                Apply = { param($evidence) $evidence[0].provenance.repositoryId = 'other-repository' }
            },
            @{
                Name = 'commit'
                Expected = '*allowed request commit binding*'
                Apply = { param($evidence) $evidence[0].provenance.commit = 'c' * 40 }
            },
            @{
                Name = 'source kind'
                Expected = '*type provenance*'
                Apply = { param($evidence) $evidence[0].provenance.sourceKind = 'synthetic' }
            }
        )

        foreach ($mutation in $mutations) {
            $evidence = New-TestRelationEvidence -Case $case
            & $mutation.Apply $evidence
            {
                New-RelationEvidenceRequest `
                    -RepositoryId 'repository-example' -ProjectId 'project-example' `
                    -PullRequestId 42 -SourceCommit ('a' * 40) -TargetCommit ('b' * 40) `
                    -TargetRef 'refs/heads/main' -CapabilityId 'relation-example' `
                    -CapabilityDigest (Get-TestRelationDigest 'relation-example') `
                    -RuleId 'response-rule' -RuleDigest (Get-TestRelationDigest $script:RuleText) `
                    -RuleText $script:RuleText -EvidenceRefs $evidence `
                    -Claims @([ordered]@{
                            claimId = 'cold-read'
                            question = [string]$case.question
                            applicability = 'applicable'
                            slots = New-TestRelationSlots -Case $case
                            anchorCandidateIds = @('response-filter')
                            severity = 'high'
                            policy = 'preview-only'
                        }) `
                    -AnchorCandidates @([ordered]@{
                            anchorId = 'response-filter'
                            path = 'src/Example/ResponseFilter.cs'
                            startLine = 40
                            endLine = 52
                            symbol = 'ApplyResponseFilter'
                        })
            } | Should -Throw $mutation.Expected -Because $mutation.Name
        }
    }

    It 'requires one wrapper-selected anchor for each claim' {
        $case = Get-TestRelationCase 'cold-read'
        {
            New-TestRelationRequest -Case $case `
                -AnchorCandidateIds @('response-filter', 'secondary-filter') `
                -AnchorCandidates @(
                    [ordered]@{
                        anchorId = 'response-filter'
                        path = 'src/Example/ResponseFilter.cs'
                        startLine = 40
                        endLine = 52
                        symbol = 'ApplyResponseFilter'
                    },
                    [ordered]@{
                        anchorId = 'secondary-filter'
                        path = 'src/Example/PublicApi.cs'
                        startLine = 60
                        endLine = 74
                        symbol = 'SerializeResponse'
                    }
                )
        } | Should -Throw '*exactly one wrapper-owned anchor candidate*'
    }

    It 'keeps anchors, severity, policy, identity, and delivery authority wrapper-owned' {
        $run = Invoke-TestRelationCase -Case (Get-TestRelationCase 'cold-read')
        $modelRequest = $run.Runner.Requests[0]
        $finding = $run.Result.preview.findings[0]

        @($modelRequest.Keys | Sort-Object) | Should -Be @(
            'budgets', 'capability', 'claim', 'evidence', 'executionUnitId',
            'rule', 'schemaVersion', 'semantics'
        )
        @($modelRequest.evidence.ref | Sort-Object -Unique).Count |
            Should -Be @($modelRequest.evidence).Count
        @($modelRequest.evidence | Where-Object ref -CEQ 'evidence:guidance')[0].roles |
            Should -Contain 'test-expectation'
        ($modelRequest | ConvertTo-Json -Depth 32 -Compress) |
            Should -Not -Match '(?i)anchor|severity|policy|findingId|delivery|authoriz|write'
        $finding.data.anchor.path | Should -Be 'src/Example/ResponseFilter.cs'
        $finding.data.anchor.startLine | Should -Be 40
        $finding.data.severity | Should -Be 'high'
        $finding.data.policy | Should -Be 'preview-only'
        $run.Result.preview.writeAllowed | Should -BeFalse
        $run.Result.delivery.state | Should -Be 'not-authorized'
        $run.Result.delivery.writeCount | Should -Be 0
        $run.Observation.effects.providerWrites | Should -Be 0
        $run.Observation.effects.writeToolInvocations | Should -Be 0
        $run.Observation.effects.deliveryAuthorized | Should -BeFalse
    }

    It 'detects the generic cold relationship while accepting warm and corrected controls' {
        $cold = Invoke-TestRelationCase -Case (Get-TestRelationCase 'cold-read')
        $warm = Invoke-TestRelationCase -Case (Get-TestRelationCase 'warm-read')
        $corrected = Invoke-TestRelationCase -Case (Get-TestRelationCase 'corrected-read')

        $cold.Result.preview.findings.Count | Should -Be 1
        $cold.Observation.counts.violations | Should -Be 1
        $warm.Result.preview.findings.Count | Should -Be 0
        $warm.Observation.counts.compliant | Should -Be 1
        $corrected.Result.preview.findings.Count | Should -Be 0
        $corrected.Observation.counts.compliant | Should -Be 1
        ($warm.Runner.Requests[0].evidence | ConvertTo-Json -Depth 16 -Compress) |
            Should -Match 'retains publicSetting'
    }

    It 'turns removed decisive evidence into unknown without starting the runner' {
        $complete = Invoke-TestRelationCase -Case (Get-TestRelationCase 'cold-read')
        $missing = Invoke-TestRelationCase -Case (Get-TestRelationCase 'cold-read') `
            -MissingRole 'cache-lookup'

        $complete.Result.preview.findings.Count | Should -Be 1
        $complete.Runner.Requests.Count | Should -Be 1
        $missing.Result.preview.findings.Count | Should -Be 0
        $missing.Runner.Requests.Count | Should -Be 0
        $missing.Result.state | Should -Be 'unknown'
        $missing.Observation.counts.unknown | Should -Be 1
        $missing.Result.validation.assessments[0].data.reason |
            Should -Be 'required-evidence-unavailable'
    }

    It 'keeps optional unknown evidence in coverage but out of the model and citations' {
        $case = Get-TestRelationCase 'cold-read'
        $evidence = @(
            New-TestRelationEvidence -Case $case
            [ordered]@{
                ref = 'evidence:optional-context'
                type = 'discussion'
                path = 'evidence/optional-context.txt'
                span = [ordered]@{ startLine = 1; endLine = 1 }
                digest = Get-TestRelationDigest 'unavailable optional context'
                provenance = [ordered]@{
                    repositoryId = 'repository-example'
                    commit = 'a' * 40
                    sourceKind = 'discussion'
                }
                roleLabels = @('optional-context')
                state = 'unknown'
                content = $null
            }
        )
        $slots = @(
            New-TestRelationSlots -Case $case
            [ordered]@{
                role = 'optional-context'
                evidenceRef = 'evidence:optional-context'
                required = $false
            }
        )
        $request = New-RelationEvidenceRequest `
            -RepositoryId 'repository-example' -ProjectId 'project-example' `
            -PullRequestId 42 -SourceCommit ('a' * 40) -TargetCommit ('b' * 40) `
            -TargetRef 'refs/heads/main' -CapabilityId 'relation-example' `
            -CapabilityDigest (Get-TestRelationDigest 'relation-example') `
            -RuleId 'response-rule' -RuleDigest (Get-TestRelationDigest $script:RuleText) `
            -RuleText $script:RuleText -EvidenceRefs $evidence `
            -Claims @([ordered]@{
                    claimId = 'cold-read'
                    question = [string]$case.question
                    applicability = 'applicable'
                    slots = $slots
                    anchorCandidateIds = @('response-filter')
                    severity = 'high'
                    policy = 'preview-only'
                }) `
            -AnchorCandidates @([ordered]@{
                    anchorId = 'response-filter'
                    path = 'src/Example/ResponseFilter.cs'
                    startLine = 40
                    endLine = 52
                    symbol = 'ApplyResponseFilter'
                })
        $runner = New-TestRelationRunner -Verdicts @{ 'cold-read' = 'compliant' }
        $result = Invoke-OwnerReviewPipeline `
            -Binding $request.Binding `
            -AcquisitionAdapter (New-RelationEvidenceAcquisitionAdapter -Request $request) `
            -CapabilityAdapter (New-RelationEvidenceCapabilityAdapter -Runner $runner.Runner)

        @($runner.Requests[0].evidence.ref) | Should -Not -Contain 'evidence:optional-context'
        @($result.validation.assessments[0].evidenceUnitIds) |
            Should -Contain 'evidence:optional-context'
        @($result.validation.assessments[0].data.citedEvidenceRefs) |
            Should -Not -Contain 'evidence:optional-context'
        $result.validation.assessments[0].state | Should -Be 'complete'
    }

    It 'isolates a malformed claim response while preserving a valid sibling finding' {
        $case = Get-TestRelationCase 'cold-read'
        $sibling = [ordered]@{
            claimId = 'sibling-claim'
            question = 'Does the same evidence establish the sibling relationship?'
            applicability = 'applicable'
            slots = New-TestRelationSlots -Case $case
            anchorCandidateIds = @('response-filter')
            severity = 'medium'
            policy = 'preview-only'
        }
        $run = Invoke-TestRelationCase -Case $case -AdditionalClaims @($sibling) `
            -Modes @{ 'cold-read' = 'malformed' }

        $run.Result.state | Should -Be 'unknown'
        $run.Result.preview.findings.Count | Should -Be 1
        $run.Result.preview.findings[0].data.claimId | Should -Be 'sibling-claim'
        @($run.Result.validation.assessments | Where-Object state -CEQ 'unknown').Count |
            Should -Be 1
        @($run.Result.diagnostics.code) | Should -Contain 'runner-response-invalid'
    }

    It 'keeps deterministic finding IDs bound to head, evidence, claim, and anchor' {
        $case = Get-TestRelationCase 'cold-read'
        $first = Invoke-TestRelationCase -Case $case
        $second = Invoke-TestRelationCase -Case $case
        $changedHead = Invoke-TestRelationCase -Case $case -SourceCommit ('d' * 40)

        $first.Result.preview.findings[0].findingId |
            Should -BeExactly $second.Result.preview.findings[0].findingId
        $first.Result.preview.findings[0].findingId |
            Should -Not -Be $changedHead.Result.preview.findings[0].findingId
    }

    It 'enforces evidence and per-claim model packet caps' {
        $case = Get-TestRelationCase 'cold-read'
        {
            New-TestRelationRequest -Case $case -Limits (
                New-RelationEvidenceLimits -MaximumEvidenceBytes 256)
        } | Should -Throw '*evidence byte and token upper bound*'

        $run = Invoke-TestRelationCase -Case $case -Limits (
            New-RelationEvidenceLimits -MaximumModelInputBytes 1024)
        $run.Runner.Requests.Count | Should -Be 0
        $run.Result.state |         Should -Be 'unknown'
        $run.Result.validation.assessments[0].data.reason |
            Should -Be 'model-input-cap-exhausted'
    }

    It 'uses the existing contained process and parser for the relation response contract' {
        $case = Get-TestRelationCase 'cold-read'
        $request = New-TestRelationRequest -Case $case
        $child = (Resolve-Path "$PSScriptRoot\fixtures\OwnerModelChild.ps1").Path
        $provider = New-OwnerModelFakeProvider -FilePath (Get-Command pwsh).Source `
            -ArgumentList @('-NoProfile', '-File', $child, 'valid', '-')
        $runner = New-RelationEvidenceModelProcessRunner -Provider $provider `
            -Limits (New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 1)
        $result = Invoke-OwnerReviewPipeline `
            -Binding $request.Binding `
            -AcquisitionAdapter (New-RelationEvidenceAcquisitionAdapter -Request $request) `
            -CapabilityAdapter (New-RelationEvidenceCapabilityAdapter -Runner $runner)
        $telemetry = Get-OwnerModelRunnerTelemetry -Runner $runner
        $observation = ConvertTo-RelationEvidenceObservation `
            -PipelineResult $result -Runner $runner

        $result.preview.findings.Count | Should -Be 1
        $result.preview.findings[0].data.citedEvidenceRefs.Count |
            Should -BeGreaterOrEqual 1
        $telemetry.attempts | Should -Be 1
        $telemetry.modelStarts | Should -Be 0
        $telemetry.effectiveTools.Count | Should -Be 0
        $telemetry.providerWrites | Should -Be 0
        ($observation.execution.records | ConvertTo-Json -Depth 8 -Compress) |
            Should -Not -Match 'responseBytesBase64|nonce|DEV_PILOT_OWNER_RESULT_JSON'
    }
}
