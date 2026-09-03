#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Offline checks for the Owner convention preview: the documents it authors,
    the identity it files evidence under, and the counts it reports.

.DESCRIPTION
    Three things decide whether this layer is trustworthy, and all three are
    checked here without a network, a model or a provider.

    The first is that the documents it hands to production tools are the
    documents those tools accept. They are validated against the SAME published
    schema files the tools validate against, so a drift in either is a failure
    here rather than a refusal several minutes into a live capture.

    The second is that a preview is filed under a key that actually describes it.
    A changed head, a re-pinned rule, a different model or a different toolkit
    must all produce a different subject, or one run would silently overwrite
    another run's answer to a different question.

    The third is that the capability's own vocabulary survives the trip to a
    human. The nine-declaration case is taken from the recorded corpus rather
    than from a copy of it, so this check cannot drift from the truth it claims
    to reproduce, and a marker that never parsed can never be reported as a clean
    review.
#>
[CmdletBinding()]
param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $RepoRoot 'src/DevPilot.AgentHarness/DevPilot.AgentHarness.psd1') -Force
. (Join-Path $RepoRoot 'src/Agents/reviewer/CorpusSeal.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/ConventionSpecialist.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewSubject.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewReport.ps1')

$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Checks = 0

function Assert-OwnerPreview {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    $script:Checks++
    if (-not $Condition) { [void]$script:Failures.Add($Message) }
}

function New-OwnerPreviewTestRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("owner-preview-test-" + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Force -Path $root)
    return $root
}

$testRoot = New-OwnerPreviewTestRoot
try {
    $schemaDir = Join-Path $RepoRoot 'src/Agents/reviewer/schemas'
    $acquisitionDir = Join-Path $RepoRoot 'src/Agents/reviewer/acquisition/v1'
    # The rule lives in a DIFFERENT repository from the subject on purpose: that
    # is the case v3 exists for, and a fixture that used the subject's own
    # repository would pass just as well against the defaulting behaviour v3
    # replaced.
    $ruleRepositoryId = '99999999-8888-7777-6666-555555555555'
    $ruleSections = @(
        [pscustomobject][ordered]@{
            organization = 'contoso'
            project      = 'Widgets'
            repositoryId = $ruleRepositoryId
            branch       = 'main'
            path         = '/documentation/EngineeringProcesses/Conventions/AutomatedTests.md'
            commit       = ('b' * 40)
            section      = '## Claim ownership'
            sha256       = 'bc31bfea6b378dffe4a1b28475dc1cac4cd3ee1ab793db57895446ded829ab2f'
            byteLength   = 569
        })

    # -----------------------------------------------------------------------
    # The evidence request, against the schema the builder itself reads.
    # -----------------------------------------------------------------------
    $evidenceRequest = New-OwnerPreviewEvidenceRequest -CorrelationId 'ownerprev-test0001' `
        -ToolkitRoot 'C:\toolkit' -ToolkitHead ('f' * 40) -RequiredRef 'refs/heads/main' `
        -Organization 'contoso' -Project 'Widgets' -RepositoryId '11111111-2222-3333-4444-555555555555' `
        -RepositoryName 'Widgets' -PullRequestId 4242 -TargetRefName 'refs/heads/main' `
        -ConfigPath 'C:\state\reviewer.config.json' -RepositoryPath 'C:\repo' -OperatorAlias 'owner-preview' `
        -PowerShellPath 'C:\pwsh\pwsh.exe' -RunSetKeyPath 'C:\state\run-set.key' `
        -RuleDeclarationPath 'C:\state\reviewer.config.json' -RuleDeclarationSha256 ('c' * 64) `
        -RuleSections $ruleSections -CaptureModels @('claude-sonnet-5', 'claude-opus-5') `
        -CaptureMode 'live' -AgencyPath 'copilot' `
        -OutputRoot 'C:\state\entry' -EntryId 'owner-4242' -SealKeyPath 'C:\state\seal.key'
    $evidenceJson = ConvertTo-AgentReplayCanonicalJson -Value $evidenceRequest
    $evidenceSchema = Get-Content -LiteralPath (Join-Path $schemaDir 'reviewer.cohort-entry-evidence-request.v3.json') -Raw
    $evidenceValid = $false
    try { $evidenceValid = Test-Json -Json $evidenceJson -Schema $evidenceSchema } catch { $evidenceValid = $false }
    Assert-OwnerPreview -Condition $evidenceValid `
        -Message "The authored evidence request does not satisfy reviewer.cohort-entry-evidence-request.v3.json."
    Assert-OwnerPreview -Condition ([int]$evidenceRequest.schemaVersion -eq 3) `
        -Message "The Owner preview must author a v3 request; below v3 a rule section carries no repository to be read from."
    Assert-OwnerPreview -Condition (
        [string]@($evidenceRequest.ruleBundle.sections)[0].repositoryId -ceq $ruleRepositoryId -and
        [string]@($evidenceRequest.ruleBundle.sections)[0].repositoryId -cne [string]$evidenceRequest.subject.repositoryId) `
        -Message "The authored rule section does not carry its own repository; the read would fall back to the subject's."
    Assert-OwnerPreview -Condition ([string]@($evidenceRequest.ruleBundle.sections)[0].section -ceq '## Claim ownership') `
        -Message "The authored rule section does not carry the heading its pin describes."
    Assert-OwnerPreview -Condition (
        @($evidenceRequest.capture.models) -ccontains 'claude-sonnet-5' -and
        @($evidenceRequest.capture.models) -ccontains 'claude-opus-5') `
        -Message "The authored request does not bind the specialist and discovery model identities for downstream capture."

    # The load-bearing absence. An execution plan would carry exactly two
    # generalist slots, and this preview is specialist-only.
    Assert-OwnerPreview -Condition (-not $evidenceRequest.Contains('executionPlan')) `
        -Message "The evidence request carries an executionPlan; that shape declares two generalist slots."
    Assert-OwnerPreview -Condition ($evidenceJson -notmatch '"slots"') `
        -Message "The evidence request names slots; a preparation-only request declares none."
    Assert-OwnerPreview -Condition ([string]$evidenceRequest.capture.mode -ceq 'live' -and
        [string]$evidenceRequest.capture.agencyPath -ceq 'copilot') `
        -Message "A live capture must declare the agency-wrapped session it reads through."

    $replayRequest = New-OwnerPreviewEvidenceRequest -CorrelationId 'ownerprev-test0002' `
        -ToolkitRoot 'C:\toolkit' -ToolkitHead ('f' * 40) -RequiredRef 'refs/heads/main' `
        -Organization 'contoso' -Project 'Widgets' -RepositoryId '11111111-2222-3333-4444-555555555555' `
        -RepositoryName 'Widgets' -PullRequestId 4242 -TargetRefName 'refs/heads/main' `
        -ConfigPath 'C:\state\reviewer.config.json' -RepositoryPath 'C:\repo' -OperatorAlias 'owner-preview' `
        -PowerShellPath 'C:\pwsh\pwsh.exe' -RunSetKeyPath 'C:\state\run-set.key' `
        -RuleDeclarationPath 'C:\state\reviewer.config.json' -RuleDeclarationSha256 ('c' * 64) `
        -RuleSections $ruleSections -CaptureModels @('claude-sonnet-5', 'claude-opus-5') -CaptureMode 'replay' `
        -ReplayRoot 'C:\state\replay' -ReplaySnapshotName 'synthetic-convention-pr' `
        -ReplayManifestDigest ('d' * 64) -OutputRoot 'C:\state\entry' -EntryId 'owner-4242' `
        -SealKeyPath 'C:\state\seal.key'
    Assert-OwnerPreview -Condition ($null -ne $replayRequest) `
        -Message "A replay capture request could not be authored."

    $liveWithoutAgency = $null
    try {
        $liveWithoutAgency = New-OwnerPreviewEvidenceRequest -CorrelationId 'ownerprev-test0003' `
            -ToolkitRoot 'C:\toolkit' -ToolkitHead ('f' * 40) -RequiredRef 'refs/heads/main' `
            -Organization 'contoso' -Project 'Widgets' -RepositoryId '11111111-2222-3333-4444-555555555555' `
            -RepositoryName 'Widgets' -PullRequestId 4242 -TargetRefName 'refs/heads/main' `
            -ConfigPath 'C:\c.json' -RepositoryPath 'C:\repo' -OperatorAlias 'owner-preview' `
            -PowerShellPath 'C:\pwsh\pwsh.exe' -RunSetKeyPath 'C:\k' -RuleDeclarationPath 'C:\c.json' `
            -RuleDeclarationSha256 ('c' * 64) -RuleSections $ruleSections `
            -CaptureModels @('claude-sonnet-5', 'claude-opus-5') -CaptureMode 'live' `
            -OutputRoot 'C:\state\entry' -EntryId 'owner-4242' -SealKeyPath 'C:\state\seal.key'
    }
    catch { $liveWithoutAgency = $null }
    Assert-OwnerPreview -Condition ($null -eq $liveWithoutAgency) `
        -Message "A live capture without an agency path was accepted; there would be no session to read through."

    # -----------------------------------------------------------------------
    # The sealed snapshot reader, and the seam that seeds the materializer.
    # -----------------------------------------------------------------------
    $replayRoot = Join-Path $testRoot 'replay'
    $snapshotName = 'pr4242-i1-offlinecorpusseal'
    $snapshotDir = Join-Path $replayRoot $snapshotName
    [void](New-Item -ItemType Directory -Force -Path $snapshotDir)
    $binding = [ordered]@{
        organization = 'contoso'; project = 'Widgets'
        repositoryId = '11111111-2222-3333-4444-555555555555'
        pullRequestId = 4242; iterationId = 1
        sourceCommit = ('a' * 40); commonCommit = ('b' * 40); targetCommit = ('c' * 40)
        changeSetSha256 = ('e' * 64)
    }
    $manifestValue = [ordered]@{
        schemaVersion = 3; kind = 'agent-replay-snapshot'; snapshotId = $snapshotName
        capturedUtc = '2026-09-02T00:00:00Z'; provider = 'ado'; binding = $binding
        bindings = @(); resources = @(); manifestDigest = ('d' * 64)
        classification = [ordered]@{ sealKind = 'offlineCorpusSeal'; nonPromotable = $true }
    }
    [void](Write-OwnerPreviewJsonFile -Path (Join-Path $snapshotDir 'manifest.json') -Value $manifestValue)
    $snapshot = Read-OwnerPreviewSealedSnapshot -ReplayRoot $replayRoot -SnapshotName $snapshotName `
        -RepositoryName 'Widgets'
    Assert-OwnerPreview -Condition (
        [int]$snapshot.PullRequestId -eq 4242 -and [int]$snapshot.IterationId -eq 1 -and
        [string]$snapshot.RepositoryName -ceq 'Widgets') `
        -Message "The sealed snapshot reader did not surface the bound pull request identity."

    $promotableDir = Join-Path $replayRoot 'promotable-snapshot'
    [void](New-Item -ItemType Directory -Force -Path $promotableDir)
    $promotableValue = [ordered]@{
        schemaVersion = 3; kind = 'agent-replay-snapshot'; snapshotId = 'promotable-snapshot'
        capturedUtc = '2026-09-02T00:00:00Z'; provider = 'ado'; binding = $binding
        bindings = @(); resources = @(); manifestDigest = ('d' * 64)
        classification = [ordered]@{ sealKind = 'offlineCorpusSeal'; nonPromotable = $false }
    }
    [void](Write-OwnerPreviewJsonFile -Path (Join-Path $promotableDir 'manifest.json') -Value $promotableValue)
    $promotableRefused = $false
    try {
        [void](Read-OwnerPreviewSealedSnapshot -ReplayRoot $replayRoot `
                -SnapshotName 'promotable-snapshot' -RepositoryName 'Widgets')
    }
    catch { $promotableRefused = $true }
    Assert-OwnerPreview -Condition $promotableRefused `
        -Message "A promotable snapshot was accepted; this layer consumes only permanently non-promotable evidence."

    $partialDir = Join-Path $replayRoot 'partial-snapshot'
    [void](New-Item -ItemType Directory -Force -Path $partialDir)
    $partialBinding = [ordered]@{
        organization = 'contoso'; project = 'Widgets'
        repositoryId = '11111111-2222-3333-4444-555555555555'; repositoryName = 'Widgets'
        pullRequestId = 4242; sourceCommit = ('a' * 40); targetCommit = ('c' * 40)
    }
    $partialValue = [ordered]@{
        schemaVersion = 3; kind = 'agent-replay-snapshot'; snapshotId = 'partial-snapshot'
        capturedUtc = '2026-09-02T00:00:00Z'; provider = 'ado'; binding = $partialBinding
        bindings = @(); resources = @(); manifestDigest = ('d' * 64)
        classification = [ordered]@{ sealKind = 'offlineCorpusSeal'; nonPromotable = $true }
    }
    [void](Write-OwnerPreviewJsonFile -Path (Join-Path $partialDir 'manifest.json') -Value $partialValue)
    $partialRefused = $false
    try {
        [void](Read-OwnerPreviewSealedSnapshot -ReplayRoot $replayRoot `
                -SnapshotName 'partial-snapshot' -RepositoryName 'Widgets')
    }
    catch { $partialRefused = $true }
    Assert-OwnerPreview -Condition $partialRefused `
        -Message "A snapshot missing an iteration or merge base was accepted; the seed would assert identity the seal cannot back."

    $packRoot = Join-Path $testRoot 'pack'
    $seed = New-OwnerPreviewLegacyProjection -Snapshot $snapshot -PackRoot $packRoot `
        -CorpusIndexSha256 ('1' * 64) -SealDigest ('2' * 64)
    $seedJson = Get-Content -LiteralPath $seed.Path -Raw
    $seedSchema = Get-Content -LiteralPath (Join-Path $acquisitionDir 'legacy-benchmark-projection.schema.json') -Raw
    $seedValid = $false
    try { $seedValid = Test-Json -Json $seedJson -Schema $seedSchema } catch { $seedValid = $false }
    Assert-OwnerPreview -Condition $seedValid `
        -Message "The legacy projection seed does not satisfy legacy-benchmark-projection.schema.json."

    $seedObject = $seedJson | ConvertFrom-Json -Depth 32
    Assert-OwnerPreview -Condition (
        [string]$seedObject.fixtureIndexBinding.fixtureIndexSha256 -ceq ('1' * 64) -and
        [string]$seedObject.fixtureIndexBinding.fixtureRecordHash -ceq ('2' * 64) -and
        [string]$seedObject.fixtureIndexBinding.originalFixtureFileSha256 -ceq [string]$seed.ManifestSha256) `
        -Message "The seed's fixture index binding is not derived from this subject's own corpus, seal and manifest."
    Assert-OwnerPreview -Condition (@($seedObject.resources).Count -eq 1 -and
        [string]@($seedObject.resources)[0].mediaRole -ceq 'replay-manifest') `
        -Message "The seed must seal exactly one resource: the manifest of the snapshot it was prepared from."
    Assert-OwnerPreview -Condition (Test-Path -LiteralPath $seed.SealedResourcePath -PathType Leaf) `
        -Message "The seed named a sealed resource it did not write."

    $captureRequest = New-OwnerPreviewCaptureRequest -Snapshot $snapshot -LegacyProjection $seed `
        -Model 'claude-opus-5' -ConfigSha256 ('7' * 64) -ManifestFileSha256 $seed.ManifestSha256
    $captureSchema = Get-Content -LiteralPath (Join-Path $acquisitionDir 'role-input-capture-request.schema.json') -Raw
    $captureValid = $false
    try { $captureValid = Test-Json -Json (ConvertTo-AgentReplayCanonicalJson -Value $captureRequest) -Schema $captureSchema }
    catch { $captureValid = $false }
    Assert-OwnerPreview -Condition $captureValid `
        -Message "The authored capture request does not satisfy role-input-capture-request.schema.json."
    Assert-OwnerPreview -Condition ([string]$captureRequest.role -ceq 'specialist') `
        -Message "The capture request must ask for the specialist role and nothing else."
    Assert-OwnerPreview -Condition (
        [string]@($captureRequest.resources)[0].sealedPath -ceq 'manifest.json' -and
        [string]@($captureRequest.resources)[0].sha256 -ceq [string]$seed.ManifestSha256) `
        -Message "The capture request does not bind the manifest where it exists inside the replay snapshot."

    # -----------------------------------------------------------------------
    # Subject identity. A different question must get a different key.
    # -----------------------------------------------------------------------
    $subjectKey = Get-OwnerPreviewSubjectKey -Organization 'contoso' -Project 'Widgets' `
        -RepositoryId '11111111-2222-3333-4444-555555555555' -PullRequestId 4242
    $baseArguments = @{
        SubjectKey = $subjectKey; SourceCommit = ('a' * 40); RuleSections = $ruleSections
        ReplayManifestDigest = ('d' * 64); Model = 'claude-opus-5'; ConfigSha256 = ('7' * 64)
        ToolkitHead = ('f' * 40)
    }
    $headKey = Get-OwnerPreviewHeadKey @baseArguments
    Assert-OwnerPreview -Condition ($headKey -ceq (Get-OwnerPreviewHeadKey @baseArguments)) `
        -Message "The head key is not stable for identical inputs."

    $variants = @(
        @{ Name = 'source commit'; Key = 'SourceCommit'; Value = ('9' * 40) },
        @{ Name = 'manifest digest'; Key = 'ReplayManifestDigest'; Value = ('8' * 64) },
        @{ Name = 'model'; Key = 'Model'; Value = 'gpt-5.6-sol' },
        @{ Name = 'configuration'; Key = 'ConfigSha256'; Value = ('6' * 64) },
        @{ Name = 'toolkit head'; Key = 'ToolkitHead'; Value = ('e' * 40) }
    )
    foreach ($variant in $variants) {
        $changed = @{}
        foreach ($pair in $baseArguments.GetEnumerator()) { $changed[$pair.Key] = $pair.Value }
        $changed[[string]$variant.Key] = $variant.Value
        Assert-OwnerPreview -Condition ((Get-OwnerPreviewHeadKey @changed) -cne $headKey) `
            -Message "A changed $($variant.Name) produced the same head key; one run would overwrite another run's answer."
    }
    $reRuled = @{}
    foreach ($pair in $baseArguments.GetEnumerator()) { $reRuled[$pair.Key] = $pair.Value }
    $reRuled['RuleSections'] = @([pscustomobject][ordered]@{
            organization = 'contoso'; project = 'Widgets'; repositoryId = $ruleRepositoryId; branch = 'main'
            path = '/documentation/EngineeringProcesses/Conventions/AutomatedTests.md'
            commit = ('9' * 40); section = '## Claim ownership'; sha256 = ('5' * 64); byteLength = 569
        })
    Assert-OwnerPreview -Condition ((Get-OwnerPreviewHeadKey @reRuled) -cne $headKey) `
        -Message "A re-pinned rule produced the same head key; verdicts measured against different bytes are different evidence."

    # A rule read from another repository, or a pin taken over another heading of
    # the same document, is a different rule and therefore a different preview.
    # Without these the head key would collide across materially different runs.
    $ruleRebindings = @(
        @{ Name = 'rule repository'; Property = 'repositoryId'; Value = '12121212-3434-5656-7878-909090909090' },
        @{ Name = 'rule heading'; Property = 'section'; Value = '## Claim ownership of tests' }
    )
    foreach ($rebinding in $ruleRebindings) {
        $rebound = @{}
        foreach ($pair in $baseArguments.GetEnumerator()) { $rebound[$pair.Key] = $pair.Value }
        $section = [ordered]@{
            organization = 'contoso'; project = 'Widgets'; repositoryId = $ruleRepositoryId; branch = 'main'
            path = '/documentation/EngineeringProcesses/Conventions/AutomatedTests.md'
            commit = ('b' * 40); section = '## Claim ownership'
            sha256 = 'bc31bfea6b378dffe4a1b28475dc1cac4cd3ee1ab793db57895446ded829ab2f'
            byteLength = 569
        }
        $section[[string]$rebinding.Property] = [string]$rebinding.Value
        $rebound['RuleSections'] = @([pscustomobject]$section)
        Assert-OwnerPreview -Condition ((Get-OwnerPreviewHeadKey @rebound) -cne $headKey) `
            -Message "A changed $($rebinding.Name) produced the same head key; two different rules would share one answer."
    }
    $tiedSections = @(
        [pscustomobject][ordered]@{
            repositoryId = '12121212-3434-5656-7878-909090909090'
            branch = 'main'
            path = '/documentation/EngineeringProcesses/Conventions/AutomatedTests.md'
            commit = ('b' * 40)
            section = '## Claim ownership A'
            sha256 = ('5' * 64)
        },
        [pscustomobject][ordered]@{
            repositoryId = '99999999-8888-7777-6666-555555555555'
            branch = 'main'
            path = '/documentation/EngineeringProcesses/Conventions/AutomatedTests.md'
            commit = ('b' * 40)
            section = '## Claim ownership B'
            sha256 = ('5' * 64)
        })
    $orderedRuleArgs = @{}
    foreach ($pair in $baseArguments.GetEnumerator()) { $orderedRuleArgs[$pair.Key] = $pair.Value }
    $orderedRuleArgs['RuleSections'] = $tiedSections
    $reversedRuleArgs = @{}
    foreach ($pair in $baseArguments.GetEnumerator()) { $reversedRuleArgs[$pair.Key] = $pair.Value }
    $reversedRuleArgs['RuleSections'] = [object[]]@($tiedSections[1], $tiedSections[0])
    Assert-OwnerPreview -Condition (
        (Get-OwnerPreviewHeadKey @orderedRuleArgs) -ceq (Get-OwnerPreviewHeadKey @reversedRuleArgs)) `
        -Message "The head key depends on input order when rule paths and hashes tie."

    # -----------------------------------------------------------------------
    # The nine-declaration case, taken from the recorded corpus itself.
    # -----------------------------------------------------------------------
    $corpus = Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/testdata/reviewer-owner-convention-corpus.v1.json') `
        -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
    Assert-OwnerPreview -Condition ([string]$corpus.capability -ceq 'bpm-test-ownership@1') `
        -Message "The corpus no longer describes the capability this preview reports."
    $liveCase = @($corpus.cases) | Where-Object { [string]$_.id -ceq 'pr16991680-new-test-methods' } | Select-Object -First 1
    Assert-OwnerPreview -Condition ($null -ne $liveCase) `
        -Message "The recorded live ownership case is no longer in the corpus."

    $anchors = @($liveCase.anchors)
    $expectedViolations = [int]$liveCase.expectedCount
    Assert-OwnerPreview -Condition ($anchors.Count -eq $expectedViolations) `
        -Message "The corpus case declares $expectedViolations violation(s) but carries $($anchors.Count) anchor(s)."

    $nonce = 'n' * 32
    $constructRows = [System.Collections.Generic.List[object]]::new()
    $noteRows = [System.Collections.Generic.List[object]]::new()
    foreach ($anchor in $anchors) {
        [void]$constructRows.Add([ordered]@{ constructRef = [string]$anchor.construct; verdict = 'violation' })
        # The contract caps explanatory notes at eight. Nine violations therefore
        # cannot all be annotated, and the verdicts must survive that on their
        # own - a capped note list must never cost a finding.
        if ($noteRows.Count -lt 8) {
            [void]$noteRows.Add([ordered]@{
                    constructRef = [string]$anchor.construct
                    rationale = 'The test declaration carries no owner attribute.'
                    suggestion = 'Claim ownership on the declaration.'
                })
        }
    }
    $ownerMarker = [ordered]@{
        schemaVersion = 4; prId = 16991680
        repositoryId = '11111111-2222-3333-4444-555555555555'; project = 'One'
        reviewedSourceCommit = ('a' * 40); targetCommit = ('b' * 40); changeSetDigest = ('c' * 64)
        conventionPlanSha256 = ('d' * 64); factPlanSha256 = ('e' * 64); configSha256 = ('f' * 64)
        scriptSha256 = ('0' * 64); promptSha256 = ('1' * 64)
        assessments = @([ordered]@{
                ruleRef = 'rs0'; constructs = $constructRows.ToArray(); notes = $noteRows.ToArray()
            })
        withheld = @(); residualRisks = @(); nonce = $nonce
    }
    $ownerMarkerText = 'CONVENTION_REVIEW_RESULT_V4: ' + ($ownerMarker | ConvertTo-Json -Depth 16 -Compress)
    $ownerSchema = Get-ReviewerConventionSpecialistMarkerSchema -ExpectedProject 'One' `
        -ExpectedNonce $nonce -ContractVersion 4
    $ownerOutcome = ConvertFrom-ReviewerConventionSpecialistResultMarkerOutcome -StdOutText $ownerMarkerText `
        -Schema $ownerSchema -ContractVersion 4
    Assert-OwnerPreview -Condition ([string]$ownerOutcome.Status -ceq 'success') `
        -Message "The nine-declaration marker was refused by the production version 4 parser (status '$([string]$ownerOutcome.Status)')."

    if ([string]$ownerOutcome.Status -ceq 'success') {
        $ownerCounts = Get-OwnerPreviewCapabilityCounts -Marker $ownerOutcome.Value
        Assert-OwnerPreview -Condition ([int]$ownerCounts.Violations -eq $expectedViolations) `
            -Message "The recorded live change set reports $([int]$ownerCounts.Violations) violation(s); the corpus records $expectedViolations."
        Assert-OwnerPreview -Condition ([int]$ownerCounts.Checked -eq $expectedViolations) `
            -Message "Checked declarations disagreed with the violations plus compliant total."
        Assert-OwnerPreview -Condition ([int]$ownerCounts.Unknown -eq 0) `
            -Message "The nine-declaration case reported unknowns it does not have."
        $reported = @($ownerCounts.ViolationEntries | ForEach-Object { [string]$_.constructRef })
        $expectedRefs = @($anchors | ForEach-Object { [string]$_.construct })
        Assert-OwnerPreview -Condition ((($reported | Sort-Object) -join ',') -ceq (($expectedRefs | Sort-Object) -join ',')) `
            -Message "The reported violations are not the constructs the corpus anchors name."
        $headline = Format-OwnerPreviewHeadline -Counts $ownerCounts
        Assert-OwnerPreview -Condition ($headline -ceq "bpm-test-ownership@1 - checked 9 declarations; 9 violations; 0 unknown") `
            -Message "The headline does not read in the capability's own vocabulary: '$headline'."
    }

    # -----------------------------------------------------------------------
    # Unknown is never compliant, and a refused marker is never a clean review.
    # -----------------------------------------------------------------------
    $mixedMarker = [pscustomobject]@{
        assessments = @([pscustomobject]@{
                ruleRef = 'rs0'
                constructs = @(
                    [pscustomobject]@{ constructRef = 'dc1'; verdict = 'violation' },
                    [pscustomobject]@{ constructRef = 'dc2'; verdict = 'compliant' },
                    [pscustomobject]@{ constructRef = 'dc3'; verdict = 'unknown' },
                    [pscustomobject]@{ constructRef = 'dc4'; verdict = 'somethingElse' })
                notes = @()
            })
        withheld = @(); residualRisks = @()
    }
    $mixedCounts = Get-OwnerPreviewCapabilityCounts -Marker $mixedMarker
    Assert-OwnerPreview -Condition ([int]$mixedCounts.Checked -eq 2 -and [int]$mixedCounts.Unknown -eq 1 -and
        [int]$mixedCounts.Compliant -eq 1) `
        -Message "Unknown was folded into the checked declarations; 'nobody could tell' and 'this is fine' must not look the same."
    Assert-OwnerPreview -Condition ([int]$mixedCounts.Unrecognized -eq 1) `
        -Message "A verdict outside the closed set was silently mapped onto a known one."

    $subjectDocument = [ordered]@{
        subjectKey = $subjectKey; headKey = $headKey; model = 'claude-opus-5'
        configSha256 = ('7' * 64); toolkitHead = ('f' * 40)
        subject = [ordered]@{
            organization = 'contoso'; project = 'One'; repositoryId = '11111111-2222-3333-4444-555555555555'
            repositoryName = 'Widgets'; pullRequestId = 16991680; iterationId = 1
            sourceCommit = ('a' * 40); targetCommit = ('b' * 40)
        }
        rule = [ordered]@{ sections = @($ruleSections) }
        snapshot = [ordered]@{
            snapshotId = $snapshotName; manifestDigest = ('d' * 64)
            sealKind = 'offlineCorpusSeal'; nonPromotable = $true
        }
    }

    $absentStatus = New-OwnerPreviewOutcome -Subject $subjectDocument -MarkerText '' -ExpectedNonce $nonce
    Assert-OwnerPreview -Condition ([string]$absentStatus.terminal.status -ceq 'incomplete') `
        -Message "A pass with no marker was not reported incomplete."
    Assert-OwnerPreview -Condition ([int]$absentStatus.counts.checked -eq 0) `
        -Message "A pass with no marker reported checked declarations."
    $absentReport = Format-OwnerPreviewReport -Status $absentStatus
    Assert-OwnerPreview -Condition ($absentReport -notmatch 'checked 0 declarations') `
        -Message "A failed pass rendered a 'checked 0' line, which reads like a clean result."
    Assert-OwnerPreview -Condition ($absentReport -match 'no verdicts were recorded') `
        -Message "A failed pass did not say plainly that it recorded no verdicts."

    $truncatedText = 'CONVENTION_REVIEW_RESULT_V4: {"schemaVersion":4,"prId":4242,"nonce":"' + $nonce + '"'
    $truncatedStatus = New-OwnerPreviewOutcome -Subject $subjectDocument -MarkerText $truncatedText -ExpectedNonce $nonce
    Assert-OwnerPreview -Condition ([string]$truncatedStatus.terminal.status -ceq 'incomplete') `
        -Message "A truncated marker was not reported incomplete."
    Assert-OwnerPreview -Condition ([int]$truncatedStatus.counts.violations -eq 0) `
        -Message "A truncated marker produced violation counts."

    $goodStatus = New-OwnerPreviewOutcome -Subject $subjectDocument -MarkerText $ownerMarkerText -ExpectedNonce $nonce
    Assert-OwnerPreview -Condition ([string]$goodStatus.terminal.status -ceq 'completed') `
        -Message "The nine-declaration marker did not produce a completed pass."
    Assert-OwnerPreview -Condition ([int]$goodStatus.counts.violations -eq 9) `
        -Message "The completed status did not carry the nine recorded violations."

    # -----------------------------------------------------------------------
    # Replay and forgery. A marker is only this run's answer if the run's own
    # sealed nonce accepts it AND it names this subject.
    # -----------------------------------------------------------------------
    $foreignNonceStatus = New-OwnerPreviewOutcome -Subject $subjectDocument `
        -MarkerText $ownerMarkerText -ExpectedNonce ('q' * 32)
    Assert-OwnerPreview -Condition ([string]$foreignNonceStatus.terminal.status -cne 'completed') `
        -Message "A marker carrying a different nonce than the run issued was accepted as this run's result."

    $noNonceStatus = New-OwnerPreviewOutcome -Subject $subjectDocument `
        -MarkerText $ownerMarkerText -ExpectedNonce ''
    Assert-OwnerPreview -Condition ([string]$noNonceStatus.terminal.status -ceq 'incomplete') `
        -Message "A run whose sealed package carried no nonce still reported a completed pass."

    $forgedMarker = [ordered]@{
        schemaVersion = 4; prId = 999999
        repositoryId = '99999999-9999-9999-9999-999999999999'; project = 'One'
        reviewedSourceCommit = ('9' * 40); targetCommit = ('9' * 40); changeSetDigest = ('c' * 64)
        conventionPlanSha256 = ('d' * 64); factPlanSha256 = ('e' * 64); configSha256 = ('f' * 64)
        scriptSha256 = ('0' * 64); promptSha256 = ('1' * 64)
        assessments = @([ordered]@{
                ruleRef = 'rs0'
                constructs = @([ordered]@{ constructRef = 'dc2'; verdict = 'compliant' })
                notes = @()
            })
        withheld = @(); residualRisks = @(); nonce = $nonce
    }
    $forgedText = 'CONVENTION_REVIEW_RESULT_V4: ' + ($forgedMarker | ConvertTo-Json -Depth 16 -Compress)
    $forgedStatus = New-OwnerPreviewOutcome -Subject $subjectDocument -MarkerText $forgedText -ExpectedNonce $nonce
    Assert-OwnerPreview -Condition ([string]$forgedStatus.terminal.status -ceq 'blocked') `
        -Message "A marker naming another pull request was recorded under this subject's identity."
    Assert-OwnerPreview -Condition ([int]$forgedStatus.counts.compliant -eq 0) `
        -Message "A refused marker still contributed compliant declarations."

    $mismatchDetail = Assert-OwnerPreviewMarkerBinding -Marker $forgedMarker -SubjectIdentity $subjectDocument['subject']
    Assert-OwnerPreview -Condition ($mismatchDetail -ne '') `
        -Message "The marker binding check accepted a marker bound to a different pull request."
    $boundDetail = Assert-OwnerPreviewMarkerBinding -Marker ([ordered]@{
            prId = 16991680; repositoryId = '11111111-2222-3333-4444-555555555555'
            reviewedSourceCommit = ('a' * 40); targetCommit = ('b' * 40)
        }) -SubjectIdentity $subjectDocument['subject']
    Assert-OwnerPreview -Condition ($boundDetail -eq '') `
        -Message "The marker binding check refused a marker that does name this subject."

    $statusSchema = Get-Content -LiteralPath (Join-Path $schemaDir 'reviewer.owner-preview-status.v1.json') -Raw
    foreach ($candidate in @(
            @{ Name = 'completed'; Value = $goodStatus },
            @{ Name = 'incomplete'; Value = $absentStatus })) {
        $statusJson = ConvertTo-AgentReplayCanonicalJson -Value ([System.Collections.IDictionary]$candidate.Value)
        $statusValid = $false
        try { $statusValid = Test-Json -Json $statusJson -Schema $statusSchema } catch { $statusValid = $false }
        Assert-OwnerPreview -Condition $statusValid `
            -Message "The $($candidate.Name) status does not satisfy reviewer.owner-preview-status.v1.json."
        Assert-OwnerPreview -Condition ($statusJson -notmatch '"passed"' -and $statusJson -notmatch '"recommendedVote"') `
            -Message "The $($candidate.Name) status carries a global verdict; this layer checked one convention."
    }

    # -----------------------------------------------------------------------
    # The write surface, and the configuration that scopes the run.
    # -----------------------------------------------------------------------
    $cliPath = Join-Path $RepoRoot 'tools/Invoke-OwnerPreviewCycle.ps1'
    $surfaceClean = $false
    try { $surfaceClean = [bool](Assert-OwnerPreviewNoWriteSurface -ScriptPath $cliPath) } catch { $surfaceClean = $false }
    Assert-OwnerPreview -Condition $surfaceClean `
        -Message "The Owner preview declares a write-capable parameter."

    $reviewerScript = Join-Path $RepoRoot 'src/Agents/reviewer/Start-ReviewerAgent.ps1'
    $detectsWriteSurface = $false
    try { [void](Assert-OwnerPreviewNoWriteSurface -ScriptPath $reviewerScript) }
    catch { $detectsWriteSurface = $true }
    Assert-OwnerPreview -Condition $detectsWriteSurface `
        -Message "The write-surface check did not notice a script that does declare write switches, so it proves nothing."

    $writeArgumentRefused = $false
    try { [void](Assert-OwnerPreviewNoWriteArgument -ToolArguments @('-Role', 'specialist', '-EnableApprovalVote') -Stage 'test') }
    catch { $writeArgumentRefused = $true }
    Assert-OwnerPreview -Condition $writeArgumentRefused `
        -Message "A write switch in a child argument vector was not refused."

    # PowerShell binds parameter names case-insensitively and by unambiguous
    # prefix, so these all reach the same child switch as the exact spelling.
    foreach ($spelling in @('-enableapprovalvote', '-EnableApprovalVot', '-EnableApp', '-EnableApprovalVote:$true')) {
        $variantRefused = $false
        try { [void](Assert-OwnerPreviewNoWriteArgument -ToolArguments @('-Role', 'specialist', $spelling) -Stage 'test') }
        catch { $variantRefused = $true }
        Assert-OwnerPreview -Condition $variantRefused `
            -Message "The write-switch guard let '$spelling' through; PowerShell binds it to a write switch."
    }
    $ordinaryArgumentAccepted = $false
    try {
        $ordinaryArgumentAccepted = [bool](Assert-OwnerPreviewNoWriteArgument `
                -ToolArguments @('-Role', 'specialist', '-Model', 'claude-opus-5', '-ExpectedRef', 'refs/heads/main') -Stage 'test')
    }
    catch { $ordinaryArgumentAccepted = $false }
    Assert-OwnerPreview -Condition $ordinaryArgumentAccepted `
        -Message "The write-switch guard refused an ordinary argument vector."

    $singlePackConfig = Join-Path $testRoot 'single-pack.config.json'
    [void](Write-OwnerPreviewJsonFile -Path $singlePackConfig -Value ([ordered]@{
                repoConventions = [ordered]@{
                    conventionPacks = [ordered]@{
                        schemaVersion = 1
                        packs = @([ordered]@{ name = 'bpm-test-ownership'; priority = 50 })
                    }
                }
            }))
    $singleAccepted = $false
    try { $singleAccepted = ((Assert-OwnerPreviewCapabilityOnly -ConfigFile $singlePackConfig) -ceq 'bpm-test-ownership') }
    catch { $singleAccepted = $false }
    Assert-OwnerPreview -Condition $singleAccepted `
        -Message "A configuration declaring only the ownership pack was refused."

    $twoPackConfig = Join-Path $testRoot 'two-pack.config.json'
    [void](Write-OwnerPreviewJsonFile -Path $twoPackConfig -Value ([ordered]@{
                repoConventions = [ordered]@{
                    conventionPacks = [ordered]@{
                        schemaVersion = 1
                        packs = @(
                            [ordered]@{ name = 'bpm-test-ownership'; priority = 50 },
                            [ordered]@{ name = 'csharp-core'; priority = 10 })
                    }
                }
            }))
    $twoRefused = $false
    try { [void](Assert-OwnerPreviewCapabilityOnly -ConfigFile $twoPackConfig) } catch { $twoRefused = $true }
    Assert-OwnerPreview -Condition $twoRefused `
        -Message "A configuration routing a second pack was accepted; a specialist role runs every routed pack."

    # -----------------------------------------------------------------------
    # Where evidence may live.
    # -----------------------------------------------------------------------
    $relativeRefused = $false
    try { [void](Resolve-OwnerPreviewSubjectRoot -SubjectRoot 'relative\evidence') } catch { $relativeRefused = $true }
    Assert-OwnerPreview -Condition $relativeRefused -Message "A relative subject root was accepted."

    $insideRefused = $false
    try { [void](Resolve-OwnerPreviewSubjectRoot -SubjectRoot (Join-Path $RepoRoot 'owner-evidence')) }
    catch { $insideRefused = $true }
    Assert-OwnerPreview -Condition $insideRefused `
        -Message "A subject root inside a git working tree was accepted; captured bytes must not sit where a commit could publish them."

    $outsideAccepted = $false
    try { $resolvedOutside = Resolve-OwnerPreviewSubjectRoot -SubjectRoot $testRoot; $outsideAccepted = (-not [string]::IsNullOrWhiteSpace($resolvedOutside)) }
    catch { $outsideAccepted = $false }
    Assert-OwnerPreview -Condition $outsideAccepted -Message "A valid out-of-repository subject root was refused."
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
if ($script:Failures.Count -gt 0) {
    Write-Host "Owner preview: $($script:Failures.Count) of $($script:Checks) check(s) failed." -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "Owner preview: $($script:Checks) check(s) passed." -ForegroundColor Green
exit 0
