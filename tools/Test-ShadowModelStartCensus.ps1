#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Offline suite for the real model start census and the sealed model start
    bound: what a finished reviewer run cost, and the most a sealed plan could.

.DESCRIPTION
    Everything here runs offline. No model is started, no provider is contacted,
    and nothing is written outside a temporary sandbox.

    The defect this suite exists to hold shut: a cohort once budgeted against a
    per-slot figure that counted reviewer PROCESSES, so a two-slot entry whose
    reviewers each started two generalists was accounted as three rather than
    four, and would still have been accounted as three had it started forty. The
    first case below is exactly that shape and it asserts four.

    The census is taken over fabricated run artifacts, which is the whole point:
    the artifacts are the contract between the reviewer and everything that
    accounts for it, and a suite that could only test through a real run could
    not test a truncated log, a tampered preview, or a run killed mid-attempt.
    The BOUND, by contrast, is read from the shipping runner's own constants and
    the shipping verification policy, so a suite that passes while those move is
    a suite that would have let a stale ceiling through.

.PARAMETER RepoRoot
    The toolkit under test. Defaults to this script's repository.

.PARAMETER Pilot02Root
    An optional real, already-frozen preparation output root - one produced by a
    previous authorized pilot - which is read READ-ONLY and asserted against.
    Skipped when absent, because the roots live outside the repository and only
    the machine that ran the pilot holds one.

.PARAMETER FrozenSlotRoot
    An optional real, already-frozen SLOT run root - the directory holding a
    finished reviewer run's own `verification-previews` - read READ-ONLY and
    accounted in assignments. Skipped when absent.

.PARAMETER FrozenSlotExpectedAssignments
    What that slot is expected to total. Zero means "whatever it totals", which
    still proves the census reads it and that its breakdown adds up.

.PARAMETER KeepSandbox
    Leave the sandbox in place for inspection after the run.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$Pilot02Root = '',
    [string]$FrozenSlotRoot = '',
    [int]$FrozenSlotExpectedAssignments = 0,
    [switch]$KeepSandbox
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Checks = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()

function Assert-Census {
    param([Parameter(Mandatory)][AllowNull()]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:Checks++
    if (-not $Condition) {
        [void]$script:Failures.Add($Message)
        Write-Host "  FAIL - $Message" -ForegroundColor Red
    }
}

function Get-CensusRefusal {
    <#
    .SYNOPSIS
        The message a call refused with, or an empty string if it did not refuse.
    .DESCRIPTION
        A refusal is an assertion here, not an accident: every one of these paths
        exists because returning a comfortable number would be worse than
        stopping, so the suite has to be able to say which refusal it got.
    #>
    param([Parameter(Mandatory)][scriptblock]$Action)
    try {
        [void](& $Action)
        return ''
    }
    catch {
        return [string]$_.Exception.Message
    }
}

function New-CensusRunRoot {
    <#
    .SYNOPSIS
        One reviewer run's own directory, with the log and previews a run of that
        shape would have published.

    .PARAMETER GeneralistAttempts
        How many generalist attempt records to publish - one per ACTUAL attempt,
        so a retried pass publishes two.

    .PARAMETER SpecialistAttempts
        How many convention specialist attempt records to publish.

    .PARAMETER VerifierNonce
        One nonce per cross-verifier launch. Repeat a nonce to model the grouping
        the runner does: one launch serves a whole cluster of assignments.

    .PARAMETER AssignmentsPerNonce
        How many assignment records each launch's nonce is stamped onto. Forty
        assignments served by four launches is four processes, and the census has
        to say four.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$GeneralistAttempts = 0,
        [int]$GeneralistRefusedBeforeLaunch = 0,
        [int]$GeneralistIntent = 0,
        [int]$SpecialistAttempts = 0,
        [int]$SpecialistIntent = 0,
        [int]$VerifierLogRecord = 0,
        [int]$VerifierIntent = 0,
        [string[]]$VerifierNonce = @(),
        [int]$AssignmentsPerNonce = 1,
        [bool]$WritePreviewDirectory = $true,
        [bool]$WritePreviewFile = $true,
        [string[]]$ExtraLogLine = @(),
        [bool]$WriteLog = $true,
        [AllowEmptyString()][string]$RunExecutionId = '',
        [bool]$SealCensusManifest = $true
    )
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $Root 'logs'))
    # The execution this fixture run stands for, stamped on the cycle record the
    # same way the reviewer stamps its own metadata. This is the witness the
    # census corroborates a manifest against, so a fixture without it would be a
    # run whose log cannot say who wrote it.
    $fixtureExecution = Get-CensusFixtureExecutionId -Root $Root -RunExecutionId $RunExecutionId
    $lines = [System.Collections.Generic.List[string]]::new()
    # A real cycle log is mostly records this census ignores. Including some is
    # not decoration: a census that counted lines rather than modes would pass a
    # log made only of the records it looks for.
    [void]$lines.Add((ConvertTo-Json -InputObject ([ordered]@{
                    mode = 'cycle-start'
                    cycle = 1
                    session = [ordered]@{ sessionId = $fixtureExecution }
                }) -Depth 8 -Compress))
    # The record written in the last statement before a subprocess can exist.
    # Emitted first for every role so the log reads in the order a real run
    # writes it: intent, then whatever the launch came back to publish.
    foreach ($intentRole in @(
            @{ role = 'generalist'; count = $GeneralistIntent }
            @{ role = 'specialist'; count = $SpecialistIntent }
            @{ role = 'verifier'; count = $VerifierIntent })) {
        for ($index = 1; $index -le [int]$intentRole.count; $index++) {
            [void]$lines.Add((ConvertTo-Json -InputObject ([ordered]@{
                            mode = 'model-launch-intent'
                            censusRole = [string]$intentRole.role
                            model = 'opaque-model-identifier'
                        }) -Depth 8 -Compress))
        }
    }
    for ($attempt = 1; $attempt -le $GeneralistAttempts; $attempt++) {
        [void]$lines.Add((ConvertTo-Json -InputObject ([ordered]@{
                        mode = 'model-attempt-accounting'
                        attempt = $attempt
                        model = 'opaque-model-identifier'
                        processStarted = $true
                    }) -Depth 8 -Compress))
    }
    # An input refused for size returns before any subprocess exists, and the
    # runner still publishes the attempt record. Counting it would spend a budget
    # on a process that never ran.
    for ($attempt = 1; $attempt -le $GeneralistRefusedBeforeLaunch; $attempt++) {
        [void]$lines.Add((ConvertTo-Json -InputObject ([ordered]@{
                        mode = 'model-attempt-accounting'
                        attempt = $attempt
                        model = 'opaque-model-identifier'
                        rejectionClass = 'oversize'
                        processStarted = $false
                    }) -Depth 8 -Compress))
    }
    for ($attempt = 1; $attempt -le $SpecialistAttempts; $attempt++) {
        [void]$lines.Add((ConvertTo-Json -InputObject ([ordered]@{
                        mode = 'specialist-attempt-accounting'
                        attempt = $attempt
                        model = 'opaque-specialist-identifier'
                        processStarted = $true
                    }) -Depth 8 -Compress))
    }
    # The verifier's own per-launch record, written as each subprocess returns.
    # It is what makes the verifier witness monotonic, so an interrupted phase
    # hides one launch rather than every launch it made.
    for ($index = 1; $index -le $VerifierLogRecord; $index++) {
        [void]$lines.Add((ConvertTo-Json -InputObject ([ordered]@{
                        mode = 'verifier-attempt-accounting'
                        attempt = 1
                        model = 'opaque-verifier-identifier'
                        clusterId = "cluster-$index"
                        processStarted = $true
                    }) -Depth 8 -Compress))
    }
    [void]$lines.Add((ConvertTo-Json -InputObject ([ordered]@{ mode = 'cycle-end'; cycle = 1 }) -Depth 8 -Compress))
    foreach ($extra in @($ExtraLogLine)) { [void]$lines.Add([string]$extra) }
    if ($WriteLog) {
        [IO.File]::WriteAllBytes(
            (Join-Path (Join-Path $Root 'logs') 'reviewer.log.jsonl'),
            ([Text.UTF8Encoding]::new($false)).GetBytes(($lines -join "`n") + "`n"))
    }

    if ($WritePreviewDirectory) {
        $previewDirectory = Join-Path $Root 'verification-previews'
        [void](New-Item -ItemType Directory -Force -Path $previewDirectory)
        if (-not $WritePreviewFile) {
            Add-CensusSeal -Root $Root -RunExecutionId $RunExecutionId -SealCensusManifest $SealCensusManifest
            return [string]([IO.Path]::GetFullPath($Root))
        }
        $runs = @()
        foreach ($nonce in @($VerifierNonce)) {
            for ($index = 1; $index -le $AssignmentsPerNonce; $index++) {
                $runs += [ordered]@{
                    nonceSha256 = [string]$nonce
                    assignmentOrdinal = $index
                }
            }
        }
        $manifest = ConvertTo-Json -InputObject ([ordered]@{
                runExecutionId = $fixtureExecution
                verifierRuns = @($runs)
            }) -Depth 8 -Compress
        $envelope = New-CensusPreviewEnvelopeText -ManifestJson $manifest -RunExecutionId $fixtureExecution
        [IO.File]::WriteAllBytes(
            (Join-Path $previewDirectory 'preview-001.json'),
            ([Text.UTF8Encoding]::new($false)).GetBytes($envelope))
    }
    Add-CensusSeal -Root $Root -RunExecutionId $RunExecutionId -SealCensusManifest $SealCensusManifest
    return [string]([IO.Path]::GetFullPath($Root))
}

function New-CensusAssignmentRoot {
    <#
    .SYNOPSIS
        One reviewer run's sealed verification preview, written the way the
        reviewed side writes it: assignments by identity, launches by nonce.

    .DESCRIPTION
        Deliberately separate from New-CensusRunRoot. That fixture is about the
        cycle log the model start census reads; this one is about the sealed
        preview the ASSIGNMENT census reads, and the two units are confused
        often enough that sharing a fixture would invite writing one and
        asserting the other.

    .PARAMETER Cluster
        One entry per cross-verifier cluster, each with a candidate count, the
        reciprocal models required of every candidate in it, and the launch
        nonces that served it. Assignments are candidates x models; processes
        are the distinct nonces. Repeating a nonce models grouping; adding one
        models a retry.

    .PARAMETER RepublishPreview
        Seal the same manifest a second time under another file name, which is
        what a resumed phase does. The identities are unchanged, so the census
        must not double-count them.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Cluster,
        [bool]$WritePreviewDirectory = $true,
        [bool]$RepublishPreview = $false,
        [bool]$OmitAssignmentsKey = $false,
        [bool]$BlankAssignmentId = $false,
        [bool]$BlankVerifierModel = $false,
        [bool]$TruncateEnvelope = $false,
        [bool]$TamperManifestJson = $false,
        [string]$Status = 'complete',
        [bool]$EmergencySeal = $false,
        [bool]$OmitDiagnostic = $false,
        [bool]$NullAssignments = $false,
        [bool]$NullAssignmentRow = $false,
        [bool]$MalformedAssignmentId = $false,
        [string]$AssignmentIdOverride = '',
        [ValidateSet('', 'diagnostic', 'inputPath', 'digest')][string]$LossMarker = '',
        [ValidateSet('', 'diagnostic', 'inputArtifactPath', 'inputManifestSha256')][string]$NullTupleField = '',
        [bool]$NumericInputDigest = $false,
        [string]$ConflictingRepublishModel = '',
        [string]$RepublishNonceSuffix = '',
        [bool]$OmitExecutionWitnessLog = $false,
        [bool]$SealCensusManifest = $true
    )
    [void](New-Item -ItemType Directory -Force -Path $Root)
    # The assignment census reads sealed previews, not records - but it still has
    # to know WHICH execution sealed them, and the only witness a fixture without
    # a strong expectation has is the log. So every assignment fixture writes the
    # one cycle record a real run would have written, stamped with the same
    # execution its manifest is sealed under.
    if (-not $OmitExecutionWitnessLog) {
        Add-CensusExecutionWitnessLog -Root $Root
    }
    if (-not $WritePreviewDirectory) {
        Add-CensusSeal -Root $Root -SealCensusManifest $SealCensusManifest
        return [string]([IO.Path]::GetFullPath($Root))
    }
    $previewDirectory = Join-Path $Root 'verification-previews'
    [void](New-Item -ItemType Directory -Force -Path $previewDirectory)

    $assignments = [System.Collections.Generic.List[object]]::new()
    $runs = [System.Collections.Generic.List[object]]::new()
    $clusterIndex = 0
    foreach ($group in @($Cluster)) {
        $clusterIndex++
        for ($candidate = 1; $candidate -le [int]$group.Candidates; $candidate++) {
            foreach ($model in @($group.Models)) {
                # The identity the reviewed side mints: 'va1:' over a digest of
                # the cluster, the candidate and the target model. Minted here
                # for real so the fixture exercises the shape the census checks.
                $identity = 'va1:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                        [Text.Encoding]::UTF8.GetBytes("cluster-$clusterIndex|candidate-$candidate|$model"))).ToLowerInvariant()
                if ($MalformedAssignmentId) { $identity = 'va1:not-a-digest' }
                if ($AssignmentIdOverride.Length -gt 0) { $identity = $AssignmentIdOverride }
                $assignments.Add([ordered]@{
                        assignmentId = [string]$(if ($BlankAssignmentId) { '' } else { $identity })
                        verifierModel = [string]$(if ($BlankVerifierModel) { '' } else { $model })
                        clusterId = "cluster-$clusterIndex"
                    })
            }
        }
        foreach ($nonce in @($group.Nonce)) {
            $runs.Add([ordered]@{ nonceSha256 = [string]$nonce; clusterId = "cluster-$clusterIndex" })
        }
    }
    # The record fields the census judges completeness on. The reviewed side's
    # normal seal always carries a real input path and digest and an empty
    # diagnostic; its evidence-loss writer is forced to publish the opposite
    # tuple, and that - never the review's own 'degraded' conclusion - is what
    # marks a pass as unmeasured.
    $manifestBody = [ordered]@{ status = [string]$Status }
    $fixtureExecution = Get-CensusFixtureExecutionId -Root $Root
    $manifestBody['runExecutionId'] = $fixtureExecution
    if (-not $OmitDiagnostic) {
        $manifestBody['diagnostic'] = [string]$(if ($EmergencySeal -or $LossMarker -eq 'diagnostic') {
                'the cross-verification pass faulted' } else { '' })
    }
    $manifestBody['inputArtifactPath'] = [string]$(if ($EmergencySeal -or $LossMarker -eq 'inputPath') { '' } else {
            (Join-Path $Root 'verification-inputs\input.json') })
    $manifestBody['inputManifestSha256'] = [string]$(if ($EmergencySeal -or $LossMarker -eq 'digest') { '0' * 64 } else {
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes($Root))).ToLowerInvariant() })
    $manifestBody['inputArtifactSha256'] = [string]$(if ($EmergencySeal -or
            $LossMarker -eq 'inputPath' -or $LossMarker -eq 'digest') { '0' * 64 } else { '' })
    if (-not ($EmergencySeal -or $LossMarker -eq 'inputPath' -or $LossMarker -eq 'digest')) {
        # The input the preview stands on, written for real. A preview that names
        # an input nobody can produce is exactly the case the census now refuses,
        # so a fixture that omitted it would be modelling the attack rather than
        # the ordinary run these assertions are about.
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $Root 'verification-inputs'))
        $inputManifestJson = ConvertTo-Json -InputObject ([ordered]@{
                inputManifestSha256 = [string]$manifestBody['inputManifestSha256']
            }) -Depth 4 -Compress
        $inputBytesOutput = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject ([ordered]@{
                        manifestJson = $inputManifestJson
                        signatureAlg = 'HMACSHA256'
                        signature = ('0' * 64)
                    }) -Depth 4))
        [byte[]]$inputBytes = $inputBytesOutput
        [IO.File]::WriteAllBytes((Join-Path $Root 'verification-inputs\input.json'), $inputBytes)
        $manifestBody['inputArtifactSha256'] = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($inputBytes)).ToLowerInvariant()
    }
    if ($NumericInputDigest) { $manifestBody['inputManifestSha256'] = 64 }
    if ($NullTupleField.Length -gt 0) { $manifestBody[$NullTupleField] = $null }
    if (-not $OmitAssignmentsKey) {
        if ($NullAssignments) { $manifestBody['assignments'] = $null }
        elseif ($NullAssignmentRow) {
            $withNull = [System.Collections.Generic.List[object]]::new()
            $withNull.Add(@($assignments)[0])
            $withNull.Add($null)
            $manifestBody['assignments'] = $withNull.ToArray()
        }
        else { $manifestBody['assignments'] = @($assignments) }
    }
    $manifestBody['verifierRuns'] = @($runs)
    $manifestJson = ConvertTo-Json -InputObject ([pscustomobject]$manifestBody) -Depth 12 -Compress
    if ($TamperManifestJson) { $manifestJson = '{"assignments": [' }
    $envelope = New-CensusPreviewEnvelopeText -ManifestJson $manifestJson -RunExecutionId $fixtureExecution
    if ($TruncateEnvelope) { $envelope = ([string]$envelope).Substring(0, 24) }
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllBytes((Join-Path $previewDirectory 'preview-001.json'), $encoding.GetBytes($envelope))
    if ($RepublishPreview) {
        $republished = $envelope
        if ($RepublishNonceSuffix.Length -gt 0) {
            # A second pass over the same candidates: identical assignment
            # identities, freshly minted launch nonces. The identities dedupe and
            # the nonces do not, which is why no ordering between the two totals
            # can be required.
            $freshRuns = [System.Collections.Generic.List[object]]::new()
            foreach ($run in @($runs)) {
                $freshRuns.Add([ordered]@{
                        nonceSha256 = ([string]$run['nonceSha256'] + $RepublishNonceSuffix)
                        clusterId = [string]$run['clusterId']
                    })
            }
            $freshBody = [ordered]@{}
            foreach ($key in @($manifestBody.Keys)) { $freshBody[$key] = $manifestBody[$key] }
            $freshBody['verifierRuns'] = $freshRuns.ToArray()
            $republishedManifest = ConvertTo-Json -InputObject ([pscustomobject]$freshBody) -Depth 12 -Compress
            $republished = New-CensusPreviewEnvelopeText -ManifestJson $republishedManifest `
                -RunExecutionId $fixtureExecution
        }
        [IO.File]::WriteAllBytes((Join-Path $previewDirectory 'preview-002.json'), $encoding.GetBytes($republished))
    }
    if ($ConflictingRepublishModel.Length -gt 0) {
        # The same assignment identities, sealed a second time against a model
        # they were not minted for. An identity is a digest over the model, so
        # the two previews cannot both be describing the same run.
        $conflicting = [System.Collections.Generic.List[object]]::new()
        foreach ($row in @($assignments)) {
            $conflicting.Add([ordered]@{
                    assignmentId = [string]$row['assignmentId']
                    verifierModel = [string]$ConflictingRepublishModel
                    clusterId = [string]$row['clusterId']
                })
        }
        $conflictJson = ConvertTo-Json -InputObject ([pscustomobject][ordered]@{
                status = 'complete'
                diagnostic = ''
                runExecutionId = $fixtureExecution
                inputArtifactPath = [string]$manifestBody['inputArtifactPath']
                inputManifestSha256 = [string]$manifestBody['inputManifestSha256']
                inputArtifactSha256 = [string]$manifestBody['inputArtifactSha256']
                assignments = @($conflicting)
                verifierRuns = @($runs)
            }) -Depth 12 -Compress
        $conflictEnvelope = New-CensusPreviewEnvelopeText -ManifestJson $conflictJson `
            -RunExecutionId $fixtureExecution
        [IO.File]::WriteAllBytes((Join-Path $previewDirectory 'preview-003.json'), $encoding.GetBytes($conflictEnvelope))
    }
    Add-CensusSeal -Root $Root -SealCensusManifest $SealCensusManifest
    return [string]([IO.Path]::GetFullPath($Root))
}

function Get-CensusFixtureExecutionId {
    <#
    .SYNOPSIS
        The execution identity one fixture run stands for.
    .DESCRIPTION
        A fixture that does not care which execution produced it gets a stable
        one derived from its root, so the manifest AND the records under it name
        the same real execution and the tests that DO care can pass their own.
        Shared by the seal and the log writer precisely so that a fixture cannot
        accidentally seal one execution while logging another - that mismatch is
        a case the tests ask for explicitly, never one they stumble into.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyString()][string]$RunExecutionId = ''
    )
    if ([string]::IsNullOrWhiteSpace($RunExecutionId)) {
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes([string]$Root))).ToLowerInvariant().Substring(0, 32)
    }
    return [string]$RunExecutionId
}

function New-CensusPreviewEnvelopeText {
    param(
        [Parameter(Mandatory)][string]$ManifestJson,
        [Parameter(Mandatory)][string]$RunExecutionId
    )
    return ConvertTo-Json -InputObject ([ordered]@{
            kind = 'reviewer.verification.preview.v1'
            manifestJson = $ManifestJson
            signature = ('0' * 64)
            censusSignatureAlg = 'HMACSHA256'
            censusRunExecutionId = $RunExecutionId
            censusSignature = Get-ReviewerCensusPreviewSignature -ManifestJson $ManifestJson `
                -MasterKey $script:CensusTestKey -RunExecutionId $RunExecutionId
        }) -Depth 8
}

function Add-CensusExecutionWitnessLog {
    <#
    .SYNOPSIS
        The one cycle record a real run always writes, stamped with the execution
        that wrote it.
    .DESCRIPTION
        A census with no strong expectation corroborates the manifest against the
        execution named by the records under the run root. A fixture that writes
        no records is therefore a run whose log can witness nothing, which is a
        refusal in its own right - true, but not what most fixtures here are
        about. This gives them the witness a real run would have left.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyString()][string]$RunExecutionId = ''
    )
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $Root 'logs'))
    $witnessLine = ConvertTo-Json -InputObject ([ordered]@{
            mode = 'cycle-start'
            cycle = 1
            session = [ordered]@{ sessionId = (Get-CensusFixtureExecutionId -Root $Root -RunExecutionId $RunExecutionId) }
        }) -Depth 8 -Compress
    [IO.File]::WriteAllBytes(
        (Join-Path (Join-Path $Root 'logs') 'reviewer.log.jsonl'),
        ([Text.UTF8Encoding]::new($false)).GetBytes($witnessLine + "`n"))
}

function Add-CensusSeal {
    <#
    .SYNOPSIS
        Seals the census attestation a real reviewer run would have sealed.

    .DESCRIPTION
        Every fixture here stands for a run that FINISHED, and a run that
        finishes seals a manifest over the accounting artifacts it leaves. Not
        sealing would make every fixture a legacy run and every assertion below
        an assertion about legacy handling, which is one case out of many rather
        than the norm.

        Sealed here, at the end of fixture construction, for the same reason the
        reviewer seals last: the digests have to be taken over the bytes the
        assertions will read. A test that wants tampering asks for it by editing
        AFTER this, which is exactly the attack being modelled.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyString()][string]$RunExecutionId = '',
        [bool]$SealCensusManifest = $true
    )
    if (-not $SealCensusManifest) { return }
    $executionId = Get-CensusFixtureExecutionId -Root $Root -RunExecutionId $RunExecutionId
    $records = @()
    $sealLogPath = Join-Path $Root 'logs\reviewer.log.jsonl'
    if (Test-Path -LiteralPath $sealLogPath -PathType Leaf) {
        # A fixture that deliberately writes an unreadable log is still a run
        # that ended; it seals over whatever bytes are there and attests to an
        # empty record inventory, which is what the reviewer's own best-effort
        # seal does when its log cannot be re-read.
        try { $records = @(Get-ReviewerModelStartLogRecord -LogPath $sealLogPath) } catch { $records = @() }
    }
    [void](Save-ReviewerModelStartCensusManifest -RunRoot $Root -MasterKey $script:CensusTestKey `
            -RunExecutionId $executionId -Records $records)
}

$repo = [string]([IO.Path]::GetFullPath($RepoRoot))
$reviewerScript = Join-Path $repo 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
. (Join-Path $repo 'src\Agents\reviewer\ModelStartCensus.ps1')

# The key every fixture seals under. A fixed vector rather than a random one so
# that a failure is reproducible, and a literal rather than a run root read so
# that the tests below can hand the census a DIFFERENT key and watch it refuse.
$script:CensusTestKey = [byte[]]@(
    0x9c, 0x1d, 0x4e, 0x77, 0x02, 0xb5, 0x3a, 0xe8, 0x61, 0x0f, 0xd2, 0x48, 0x93, 0x7b, 0xc6, 0x15,
    0x2a, 0xf4, 0x88, 0x30, 0x5d, 0xa9, 0x11, 0xbe, 0x6c, 0x07, 0xe3, 0x52, 0xcd, 0x74, 0x19, 0xab)

# Supplied by default so that the assertions below read as they always did -
# about counting - and the authentication-specific cases pass the key, or a
# wrong key, or none, explicitly.
$PSDefaultParameterValues['Get-ReviewerModelStartCensus:MasterKey'] = $script:CensusTestKey
$PSDefaultParameterValues['Get-ReviewerVerifierAssignmentCensus:MasterKey'] = $script:CensusTestKey
# Every census must now name the witness it is trusting for run-execution
# identity. The default here is the WEAKER one - corroborate against the records
# under the run root - because that is what the production caller can supply and
# what the counting assertions below are about. The cases that model an attacker
# who can rewrite the run root pass an explicit -ExpectedRunExecutionId instead.
$PSDefaultParameterValues['Get-ReviewerModelStartCensus:CorroborateExecutionFromRecords'] = $true
$PSDefaultParameterValues['Get-ReviewerVerifierAssignmentCensus:CorroborateExecutionFromRecords'] = $true

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('shadow-census-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
[void](New-Item -ItemType Directory -Force -Path $sandbox)

# The argument vectors the census is told a run was launched with. Only the
# switches decide which roles were AUTHORIZED, which is what turns an absent
# artifact into either 'never enabled' or 'evidence missing'.
$quietArgv = @('-Model', 'a', '-SecondPassModel', 'b')
$verifyingArgv = @('-Model', 'a', '-SecondPassModel', 'b', '-EnableConventionSpecialist', '-EnableVerificationPreview')

try {
    Write-Host '1/21 two slots with a generalist pair each are four real starts, not three' -ForegroundColor Cyan
    $slotOne = New-CensusRunRoot -Root (Join-Path $sandbox 'pair\slot1') -GeneralistAttempts 2 -WritePreviewDirectory $false
    $slotTwo = New-CensusRunRoot -Root (Join-Path $sandbox 'pair\slot2') -GeneralistAttempts 2 -WritePreviewDirectory $false
    $censusOne = Get-ReviewerModelStartCensus -RunRoot $slotOne -Argv $quietArgv
    $censusTwo = Get-ReviewerModelStartCensus -RunRoot $slotTwo -Argv $quietArgv
    $entryTotal = [int]$censusOne.realModelStarts + [int]$censusTwo.realModelStarts
    Assert-Census ($entryTotal -eq 4) `
        "A two-slot entry whose reviewers each started two generalists was accounted as $entryTotal real model start(s); expected 4."
    Assert-Census ([int]$censusOne.byRole.generalist -eq 2 -and [int]$censusOne.byRole.specialist -eq 0 -and
        [int]$censusOne.byRole.verifier -eq 0) `
        'The per-role breakdown of a generalist-only run does not report two generalists and nothing else.'
    Assert-Census ([bool]$censusOne.complete -and [string]$censusOne.basis -ceq 'publishedAttemptRecords') `
        'A run that published every record it was authorized to publish was not reported as a complete census.'

    Write-Host '2/21 a convention specialist adds its own starts' -ForegroundColor Cyan
    $specialistRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'specialist') -GeneralistAttempts 2 `
        -SpecialistAttempts 1 -WritePreviewDirectory $false
    $specialistCensus = Get-ReviewerModelStartCensus -RunRoot $specialistRoot -Argv $quietArgv
    Assert-Census ([int]$specialistCensus.realModelStarts -eq 3 -and [int]$specialistCensus.byRole.specialist -eq 1) `
        "A run with a generalist pair and one specialist was accounted as $($specialistCensus.realModelStarts) start(s); expected 3."

    Write-Host '3/21 forty grouped verifier assignments are the launches that served them' -ForegroundColor Cyan
    $groupedRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'grouped') -GeneralistAttempts 2 `
        -VerifierNonce @(('a' * 64), ('b' * 64), ('c' * 64), ('d' * 64)) -AssignmentsPerNonce 10
    $groupedCensus = Get-ReviewerModelStartCensus -RunRoot $groupedRoot -Argv $verifyingArgv
    Assert-Census ([int]$groupedCensus.byRole.verifier -eq 4) `
        "Forty assignments served by four launches were accounted as $($groupedCensus.byRole.verifier) verifier start(s); expected 4."
    Assert-Census ([int]$groupedCensus.realModelStarts -eq 6) `
        "The grouped run totals $($groupedCensus.realModelStarts) real model start(s); expected 6."

    Write-Host '4/21 an assignment nobody launched for is not a start' -ForegroundColor Cyan
    $unlaunchedRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'unlaunched') -GeneralistAttempts 2 `
        -VerifierNonce @(('0' * 64), ('0' * 64), ('e' * 64)) -AssignmentsPerNonce 3
    $unlaunchedCensus = Get-ReviewerModelStartCensus -RunRoot $unlaunchedRoot -Argv $verifyingArgv
    Assert-Census ([int]$unlaunchedCensus.byRole.verifier -eq 1) `
        "Placeholder nonces were counted as launches: $($unlaunchedCensus.byRole.verifier) verifier start(s) reported; expected 1."

    Write-Host '5/21 retries add, because a retry is another process' -ForegroundColor Cyan
    $retryRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'retry') -GeneralistAttempts 3 -WritePreviewDirectory $false
    $retryCensus = Get-ReviewerModelStartCensus -RunRoot $retryRoot -Argv $quietArgv
    Assert-Census ([int]$retryCensus.realModelStarts -eq 3) `
        "A run that retried its passes was accounted as $($retryCensus.realModelStarts) start(s); expected 3."

    Write-Host '6/21 a missing log is a refusal, not a zero' -ForegroundColor Cyan
    $noLogRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'nolog') -WriteLog $false -WritePreviewDirectory $false
    $noLogRefusal = Get-CensusRefusal { Get-ReviewerModelStartCensus -RunRoot $noLogRoot -Argv $quietArgv }
    Assert-Census ($noLogRefusal -match 'does not exist') `
        "A run whose cycle log is missing was not refused; the census said '$noLogRefusal'."
    $noRootRefusal = Get-CensusRefusal {
        Get-ReviewerModelStartCensus -RunRoot (Join-Path $sandbox 'never-created') -Argv $quietArgv
    }
    Assert-Census ($noRootRefusal -match 'run root') `
        "A census over a run root that does not exist was not refused; it said '$noRootRefusal'."

    Write-Host '7/21 a truncated or edited log is a refusal' -ForegroundColor Cyan
    $tamperRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'tamper') -GeneralistAttempts 2 `
        -WritePreviewDirectory $false -ExtraLogLine @('{"mode":"model-attempt-accounting"')
    $tamperRefusal = Get-CensusRefusal { Get-ReviewerModelStartCensus -RunRoot $tamperRoot -Argv $quietArgv }
    Assert-Census ($tamperRefusal -match 'unparsable record') `
        "A log carrying a record this build cannot parse was counted anyway; it said '$tamperRefusal'."

    Write-Host '8/21 an authorized verification that published nothing is incomplete' -ForegroundColor Cyan
    $unprovenRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'unproven') -GeneralistAttempts 2 -WritePreviewDirectory $false
    $unprovenCensus = Get-ReviewerModelStartCensus -RunRoot $unprovenRoot -Argv $verifyingArgv
    Assert-Census (-not [bool]$unprovenCensus.complete -and [string]$unprovenCensus.incompleteReason -match 'cross-verify') `
        'A run authorized to cross-verify that published no preview reported a complete census.'
    $notAuthorized = Get-ReviewerModelStartCensus -RunRoot $unprovenRoot -Argv $quietArgv
    Assert-Census ([bool]$notAuthorized.complete) `
        'A run that was never authorized to cross-verify was reported as missing verification evidence.'

    Write-Host '9/21 a preview whose launches cannot be read is a refusal' -ForegroundColor Cyan
    $brokenPreviewRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'broken-preview') -GeneralistAttempts 2 `
        -VerifierNonce @(('f' * 64))
    $previewPath = Join-Path (Join-Path $brokenPreviewRoot 'verification-previews') 'preview-001.json'
    $brokenEnvelope = ConvertTo-Json -InputObject ([ordered]@{
            kind = 'reviewer.verification.preview.v1'
            manifestJson = (ConvertTo-Json -InputObject ([ordered]@{
                        verifierRuns = @([ordered]@{ assignmentOrdinal = 1 })
                    }) -Depth 8 -Compress)
        }) -Depth 8
    [IO.File]::WriteAllBytes($previewPath, ([Text.UTF8Encoding]::new($false)).GetBytes($brokenEnvelope))
    $previewRefusal = Get-CensusRefusal { Get-ReviewerModelStartCensus -RunRoot $brokenPreviewRoot -Argv $verifyingArgv }
    Assert-Census ($previewRefusal -match 'launch nonce') `
        "A verifier run record with no launch nonce was counted anyway; it said '$previewRefusal'."

    Write-Host '10/21 the bound is read from the shipping runner, not restated' -ForegroundColor Cyan
    $runnerBound = Get-ReviewerModelStartRunnerBound -ReviewerScriptPath $reviewerScript
    Assert-Census ([int]$runnerBound.generalistAttemptsPerPass -ge 1 -and [int]$runnerBound.specialistAttempts -ge 1 -and
        [int]$runnerBound.verifierAttemptsPerLaunch -ge 1 -and [int]$runnerBound.maxVerifierLaunches -ge 1) `
        'The runner bounds this build reads are not all at least one attempt.'
    Assert-Census ([int]$runnerBound.maxVerifierLaunches -le [int]$runnerBound.verifierPolicyRuns -and
        [int]$runnerBound.maxVerifierLaunches -le [int]$runnerBound.verifierCeiling) `
        'The effective verifier launch bound is wider than either of the two limits it is the smaller of.'
    $missingRunnerRefusal = Get-CensusRefusal {
        Get-ReviewerModelStartRunnerBound -ReviewerScriptPath (Join-Path $sandbox 'no-such-runner.ps1')
    }
    Assert-Census ($missingRunnerRefusal -match 'does not exist') `
        "A bound over a runner that does not exist was not refused; it said '$missingRunnerRefusal'."

    Write-Host '11/21 the bound multiplies exactly what the plan authorizes' -ForegroundColor Cyan
    $quietBound = Get-ReviewerModelStartBound -Argv $quietArgv -ReviewerScriptPath $reviewerScript
    $expectedQuiet = 2 * [int]$runnerBound.generalistAttemptsPerPass
    Assert-Census ([int]$quietBound.maxRealModelStarts -eq $expectedQuiet) `
        "A two-pass generalist-only plan bounds at $($quietBound.maxRealModelStarts); expected $expectedQuiet."
    $loudBound = Get-ReviewerModelStartBound -Argv $verifyingArgv -ReviewerScriptPath $reviewerScript
    $expectedLoud = $expectedQuiet + [int]$runnerBound.specialistAttempts +
        ([int]$runnerBound.maxVerifierLaunches * [int]$runnerBound.verifierAttemptsPerLaunch)
    Assert-Census ([int]$loudBound.maxRealModelStarts -eq $expectedLoud) `
        "A fully authorized plan bounds at $($loudBound.maxRealModelStarts); expected $expectedLoud."
    Assert-Census ([int]$loudBound.maxRealModelStarts -gt [int]$quietBound.maxRealModelStarts) `
        'Authorizing a specialist and cross-verification did not raise the bound, so a loud run would spend outside it.'
    $singlePass = Get-ReviewerModelStartBound -Argv @('-Model', 'a') -ReviewerScriptPath $reviewerScript
    Assert-Census ([int]$singlePass.maxRealModelStarts -eq [int]$runnerBound.generalistAttemptsPerPass) `
        "A single-pass plan bounds at $($singlePass.maxRealModelStarts); expected $($runnerBound.generalistAttemptsPerPass)."
    $noModelRefusal = Get-CensusRefusal {
        Get-ReviewerModelStartBound -Argv @('-SecondPassModel', 'b') -ReviewerScriptPath $reviewerScript
    }
    Assert-Census ($noModelRefusal -match 'names no -Model') `
        "A bound over a vector naming no model was taken anyway; it said '$noModelRefusal'."

    Write-Host '12/21 the bound is always at least what a run of that shape can spend' -ForegroundColor Cyan
    # The point of a bound is that the census can never exceed it. Asserted over
    # the runs this suite already built rather than argued about in a comment.
    foreach ($pair in @(
            @{ Root = $groupedRoot; Argv = $verifyingArgv; Name = 'grouped' },
            @{ Root = $retryRoot; Argv = $quietArgv; Name = 'retried' },
            @{ Root = $specialistRoot; Argv = $quietArgv; Name = 'specialist' })) {
        $measured = Get-ReviewerModelStartCensus -RunRoot ([string]$pair.Root) -Argv ([string[]]$pair.Argv)
        $bounded = Get-ReviewerModelStartBound -Argv ([string[]]$pair.Argv) -ReviewerScriptPath $reviewerScript
        Assert-Census ([int]$measured.realModelStarts -le [int]$bounded.maxRealModelStarts) `
            ("The $($pair.Name) run measured $($measured.realModelStarts) start(s) against a bound of " +
                "$($bounded.maxRealModelStarts), so the bound is not an upper bound.")
    }

    Write-Host '13/21 a killed run publishes a floor, and the caller is told so' -ForegroundColor Cyan
    # A child killed between starting a model and publishing its record leaves no
    # evidence of that start. The census reports what it can see; what makes the
    # accounting safe is that the slot cannot have ended 'complete', which is the
    # coordinator's exactness flag and the one-start-per-slot allowance it feeds.
    $killedRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'killed') -GeneralistAttempts 1 -WritePreviewDirectory $false
    $killedCensus = Get-ReviewerModelStartCensus -RunRoot $killedRoot -Argv $quietArgv
    Assert-Census ([int]$killedCensus.realModelStarts -eq 1 -and [bool]$killedCensus.complete) `
        'A run interrupted after its first attempt record did not report the one start it did publish.'
    $refusedRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'refused') -GeneralistAttempts 0 -WritePreviewDirectory $false
    $refusedCensus = Get-ReviewerModelStartCensus -RunRoot $refusedRoot -Argv $quietArgv
    Assert-Census ([int]$refusedCensus.realModelStarts -eq 0 -and [bool]$refusedCensus.complete -and
        [int]$refusedCensus.logRecordCount -gt 0) `
        'A run that refused before its first launch was not reported as a measured zero with records behind it.'

    Write-Host '14/21 a frozen real preparation is accounted the way the pilot was' -ForegroundColor Cyan
    if (-not $Pilot02Root) {
        Write-Host '  SKIP - no frozen preparation root was given.' -ForegroundColor DarkGray
    }
    elseif (-not (Test-Path -LiteralPath $Pilot02Root -PathType Container)) {
        Write-Host "  SKIP - '$Pilot02Root' is not a directory on this machine." -ForegroundColor DarkGray
    }
    else {
        # READ-ONLY over evidence that is already immutable. Nothing here writes,
        # reruns or re-signs anything: the point is that the shipping census, run
        # today, reports what that run really spent rather than what the defect
        # accounted it as.
        $slotRoots = @(Get-ChildItem -LiteralPath $Pilot02Root -Directory -Recurse -Filter 'replay' -ErrorAction SilentlyContinue |
                ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue } |
                Where-Object { Test-Path -LiteralPath (Join-Path (Join-Path $_.FullName 'logs') 'reviewer.log.jsonl') -PathType Leaf } |
                ForEach-Object { [string]$_.FullName } | Sort-Object)
        Assert-Census (@($slotRoots).Count -ge 1) `
            "The frozen preparation at '$Pilot02Root' carries no reviewer run this census can read."
        $frozenTotal = 0
        foreach ($runRoot in @($slotRoots)) {
            $frozen = Get-ReviewerModelStartCensus -RunRoot $runRoot -Argv $quietArgv
            Assert-Census ([bool]$frozen.complete) "The frozen run '$runRoot' does not report a complete census."
            $frozenTotal += [int]$frozen.realModelStarts
        }
        Assert-Census ($frozenTotal -gt @($slotRoots).Count) `
            ("The frozen preparation is accounted as $frozenTotal real model start(s) across $(@($slotRoots).Count) run(s), " +
                'which is the one-per-reviewer-process reading the defect produced rather than a census of model starts.')
        Write-Host "  Frozen preparation: $frozenTotal real model start(s) across $(@($slotRoots).Count) run(s)." -ForegroundColor DarkGray
    }

    Write-Host '15/21 an interrupted run is charged what its own plan could still have spent' -ForegroundColor Cyan
    # The allowance is the only number in this accounting that was not measured,
    # so it has to be wrong in the safe direction and it has to be bounded.
    $completeAllowance = Get-ReviewerModelStartUnmeasuredAllowance -Argv $verifyingArgv `
        -ReviewerScriptPath $reviewerScript -RunEndedComplete $true -Census $groupedCensus
    Assert-Census ([int]$completeAllowance -eq 0) `
        "A run that ended complete was charged an unmeasured allowance of $completeAllowance; expected 0."

    # A generalist attempt in flight hides exactly one start, because the record is
    # published as soon as the attempt returns.
    $inFlightAllowance = Get-ReviewerModelStartUnmeasuredAllowance -Argv $quietArgv `
        -ReviewerScriptPath $reviewerScript -RunEndedComplete $false -Census $killedCensus
    Assert-Census ([int]$inFlightAllowance -eq 1) `
        "An interrupted run with cross-verification unauthorized was charged $inFlightAllowance; expected 1."

    # A cross-verification phase killed before it seals no longer hides its
    # launches: the runner writes a per-launch record as each subprocess returns,
    # so the gap is the one launch in flight, exactly as for the other two roles.
    $unsealedRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'unsealed') -GeneralistAttempts 1 `
        -VerifierLogRecord 3 -WritePreviewDirectory $true -WritePreviewFile $false
    $unsealedCensus = Get-ReviewerModelStartCensus -RunRoot $unsealedRoot -Argv $verifyingArgv
    Assert-Census (-not [bool]$unsealedCensus.verificationSealed) `
        'A run whose preview directory exists but holds no sealed preview was reported as having sealed its verification.'
    Assert-Census ([int]$unsealedCensus.byRole.verifier -eq 3) `
        ("A phase that logged three launches and sealed no preview was accounted as $($unsealedCensus.byRole.verifier) " +
            'verifier start(s); the per-launch record is what survives an interruption.')
    $verifyingBound = Get-ReviewerModelStartBound -Argv $verifyingArgv -ReviewerScriptPath $reviewerScript
    Assert-Census ([bool]$verifyingBound.runnerBounds.verifierLaunchRecorded) `
        'The shipping runner does not publish a per-launch verifier record, so the tight allowance below is not earned.'
    $unsealedAllowance = Get-ReviewerModelStartUnmeasuredAllowance -Argv $verifyingArgv `
        -ReviewerScriptPath $reviewerScript -RunEndedComplete $false -Census $unsealedCensus
    Assert-Census ([int]$unsealedAllowance -eq 1) `
        ("An interrupted verification phase against a runner that records each launch was charged $unsealedAllowance; " +
            'expected 1, the single launch that can be in flight.')
    Assert-Census (([int]$unsealedCensus.realModelStarts + [int]$unsealedAllowance) -le [int]$verifyingBound.maxRealModelStarts) `
        'The measured starts plus the allowance exceed the bound the cohort proved before it started.'

    # And the safety valve behind that tight allowance: against a runner that does
    # NOT publish a per-launch record, the only witness is the end-of-phase seal,
    # and an interruption there hides every launch the phase made. That case is
    # charged the whole verifier bound, so the tight number above is earned by the
    # runner rather than assumed of it.
    $silentReviewerRoot = Join-Path $sandbox 'silent-runner'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $silentReviewerRoot 'verification\v1'))
    $silentReviewerScript = Join-Path $silentReviewerRoot 'Start-ReviewerAgent.ps1'
    $silentText = [IO.File]::ReadAllText($reviewerScript, [Text.UTF8Encoding]::new($false, $true)).Replace(
        'mode = "verifier-attempt-accounting"', 'mode = "verifier-launch-note"')
    [IO.File]::WriteAllBytes($silentReviewerScript, ([Text.UTF8Encoding]::new($false)).GetBytes($silentText))
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $reviewerScript) 'CrossVerification.ps1') `
        -Destination (Join-Path $silentReviewerRoot 'CrossVerification.ps1') -Force
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $reviewerScript) 'verification\v1\policy.json') `
        -Destination (Join-Path $silentReviewerRoot 'verification\v1\policy.json') -Force
    $silentBound = Get-ReviewerModelStartBound -Argv $verifyingArgv -ReviewerScriptPath $silentReviewerScript
    Assert-Census (-not [bool]$silentBound.runnerBounds.verifierLaunchRecorded) `
        'A runner with no per-launch verifier record was still reported as recording its launches.'
    $silentAllowance = Get-ReviewerModelStartUnmeasuredAllowance -Argv $verifyingArgv `
        -ReviewerScriptPath $silentReviewerScript -RunEndedComplete $false -Census $unsealedCensus
    $silentUnmeasured = 1 + ([int]$silentBound.byRole.verifier - [int]$unsealedCensus.byRole.verifier)
    Assert-Census ([int]$silentAllowance -eq $silentUnmeasured) `
        ("An interrupted phase against a runner that records no launch was charged $silentAllowance; expected " +
            "$silentUnmeasured - the in-flight attempt plus every launch that phase could have made and left unproven.")

    # And a run that sealed its previews has nothing hidden behind that zero, so
    # only the in-flight attempt is charged.
    $sealedAllowance = Get-ReviewerModelStartUnmeasuredAllowance -Argv $verifyingArgv `
        -ReviewerScriptPath $reviewerScript -RunEndedComplete $false -Census $groupedCensus
    Assert-Census ([int]$sealedAllowance -eq 1) `
        "An interrupted run that had already sealed its verification was charged $sealedAllowance; expected 1."

    Write-Host '16/21 a run whose evidence cannot be read at all is charged its whole plan' -ForegroundColor Cyan
    # This is the path a slot killed before its first log line takes. The old
    # behaviour refused the entry and blocked the cohort; the accounting one is to
    # carry the outcome and charge everything the plan admitted.
    $blindAllowance = Get-ReviewerModelStartUnmeasuredAllowance -Argv $verifyingArgv `
        -ReviewerScriptPath $reviewerScript -RunEndedComplete $false -Census $null
    Assert-Census ([int]$blindAllowance -eq [int]$verifyingBound.maxRealModelStarts) `
        ("A run that left no readable evidence was charged $blindAllowance; expected its whole sealed bound of " +
            "$($verifyingBound.maxRealModelStarts).")
    $blindComplete = Get-ReviewerModelStartUnmeasuredAllowance -Argv $verifyingArgv `
        -ReviewerScriptPath $reviewerScript -RunEndedComplete $true -Census $null
    Assert-Census ([int]$blindComplete -eq [int]$verifyingBound.maxRealModelStarts) `
        ("A run claiming to have ended complete while leaving evidence nothing could read was charged $blindComplete; " +
            "expected its whole sealed bound of $($verifyingBound.maxRealModelStarts). The two claims contradict each " +
            'other, and the contradiction is resolved against the budget rather than in its favour.')

    Write-Host '17/21 a verifier launch is counted from the log, and the seal only cross-checks it' -ForegroundColor Cyan
    # The degraded fallback seals a preview with an EMPTY run list, and the phase
    # can still return normally, so the run ends complete with an exact census. If
    # the seal were the only witness, every launch behind that empty list would be
    # accounted as zero on a SUCCESSFUL entry - the original defect through a
    # different door.
    $degradedRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'degraded') -GeneralistAttempts 2 `
        -VerifierLogRecord 5 -VerifierNonce @() -WritePreviewDirectory $true -WritePreviewFile $true
    $degradedCensus = Get-ReviewerModelStartCensus -RunRoot $degradedRoot -Argv $verifyingArgv
    Assert-Census ([int]$degradedCensus.byRole.verifier -eq 5 -and [int]$degradedCensus.realModelStarts -eq 7) `
        ("A run that sealed an empty verifier run list after five real launches was accounted as " +
            "$($degradedCensus.realModelStarts) start(s) with $($degradedCensus.byRole.verifier) verifier; expected 7 and 5.")
    Assert-Census ([bool]$degradedCensus.complete -and [bool]$degradedCensus.verificationSealed) `
        'The degraded shape was not reported as a sealed, complete census, so the test is not exercising the real hazard.'
    Assert-Census ([int]$degradedCensus.realModelStarts -le [int]$verifyingBound.maxRealModelStarts) `
        'The degraded run measured more starts than its own plan bound admits.'

    # The seal is kept as a second witness, and the larger of the two wins: a
    # build that somehow sealed launches it never logged must not read as none.
    $sealHeavyRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'seal-heavy') -GeneralistAttempts 1 `
        -VerifierLogRecord 1 -VerifierNonce @(('a' * 64), ('b' * 64), ('c' * 64)) -AssignmentsPerNonce 2
    $sealHeavyCensus = Get-ReviewerModelStartCensus -RunRoot $sealHeavyRoot -Argv $verifyingArgv
    Assert-Census ([int]$sealHeavyCensus.byRole.verifier -eq 3) `
        ("A run whose seal records three launches and whose log records one was accounted as " +
            "$($sealHeavyCensus.byRole.verifier); the larger witness must win.")

    Write-Host '18/21 an input refused before the launch is not a model start' -ForegroundColor Cyan
    # The runner publishes an attempt record for an oversize input even though it
    # returned before creating a subprocess. Counting it would spend budget on a
    # process that never existed and could retire a cohort early.
    $refusedLaunchRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'refused-launch') -GeneralistAttempts 2 `
        -GeneralistRefusedBeforeLaunch 2 -WritePreviewDirectory $false
    $refusedLaunchCensus = Get-ReviewerModelStartCensus -RunRoot $refusedLaunchRoot -Argv $quietArgv
    Assert-Census ([int]$refusedLaunchCensus.byRole.generalist -eq 2) `
        ("Two launched attempts and two pre-launch refusals were accounted as " +
            "$($refusedLaunchCensus.byRole.generalist) generalist start(s); expected 2.")

    # A record from a build that predates the field cannot prove it did not launch,
    # and the only safe direction for a ceiling is upward, so it is still counted.
    $legacyLine = ConvertTo-Json -InputObject ([ordered]@{
            mode = 'model-attempt-accounting'; attempt = 9; model = 'opaque-model-identifier'
        }) -Depth 8 -Compress
    $legacyRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'legacy-record') -GeneralistAttempts 1 `
        -ExtraLogLine @($legacyLine) -WritePreviewDirectory $false
    $legacyCensus = Get-ReviewerModelStartCensus -RunRoot $legacyRoot -Argv $quietArgv
    Assert-Census ([int]$legacyCensus.byRole.generalist -eq 2) `
        ("An attempt record carrying no 'processStarted' was accounted as " +
            "$($legacyCensus.byRole.generalist) generalist start(s) alongside one that does; expected 2.")

    Write-Host '19/21 an unmeasured verifier role stays unmeasured however the run ended' -ForegroundColor Cyan
    # The seal is not a witness of a launch. Its run list is accumulated in memory
    # and serialized once, and the degraded fallback writes it EMPTY and returns
    # normally - so against a runner with no per-launch record, 'complete with a
    # sealed zero' and 'complete having launched everything the policy allowed'
    # are the same artifact. Reading the first is what the ending says; charging
    # the second is what the budget requires.
    $silentComplete = Get-ReviewerModelStartUnmeasuredAllowance -Argv $verifyingArgv `
        -ReviewerScriptPath $silentReviewerScript -RunEndedComplete $true -Census $groupedCensus
    $silentUnproven = [int]$silentBound.byRole.verifier - [int]$groupedCensus.byRole.verifier
    Assert-Census ([int]$silentComplete -eq $silentUnproven) `
        ("A complete run against a runner that records no verifier launch was charged $silentComplete for a role its " +
            "seal could only prove $($groupedCensus.byRole.verifier) of; expected $silentUnproven.")
    Assert-Census ([int]$silentComplete -gt 0) `
        'A complete run left an unmeasured verifier role charged at nothing, which is the under-count this exists to remove.'
    # The shipping runner earns the zero, because every launch it makes leaves a
    # record whether the phase ends well, degrades or dies.
    $recordedComplete = Get-ReviewerModelStartUnmeasuredAllowance -Argv $verifyingArgv `
        -ReviewerScriptPath $reviewerScript -RunEndedComplete $true -Census $groupedCensus
    Assert-Census ([int]$recordedComplete -eq 0) `
        "A complete run against a runner that records every launch was charged $recordedComplete; expected 0."
    Assert-Census ((([int]$groupedCensus.realModelStarts) + [int]$silentComplete) -le [int]$silentBound.maxRealModelStarts) `
        'The charge for an unmeasured role took the run past the bound its own plan proved.'

    Write-Host '20/21 a runner that only mentions the record does not earn the tight allowance' -ForegroundColor Cyan
    # Read over the runner's string literals rather than its text. A comment - and
    # this change added several - names the mode too, and a raw-text match would
    # hand the tighter bound to a runner whose emitter had been deleted and merely
    # described.
    $describedRoot = Join-Path $sandbox 'described-runner'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $describedRoot 'verification\v1'))
    $describedScript = Join-Path $describedRoot 'Start-ReviewerAgent.ps1'
    $describedText = [IO.File]::ReadAllText($reviewerScript, [Text.UTF8Encoding]::new($false, $true)).Replace(
        'mode = "verifier-attempt-accounting"',
        '# mode = "verifier-attempt-accounting" is what this used to publish' + "`r`n" + '        mode = "verifier-launch-note"')
    [IO.File]::WriteAllBytes($describedScript, ([Text.UTF8Encoding]::new($false)).GetBytes($describedText))
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $reviewerScript) 'CrossVerification.ps1') `
        -Destination (Join-Path $describedRoot 'CrossVerification.ps1') -Force
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $reviewerScript) 'verification\v1\policy.json') `
        -Destination (Join-Path $describedRoot 'verification\v1\policy.json') -Force
    $describedBound = Get-ReviewerModelStartBound -Argv $verifyingArgv -ReviewerScriptPath $describedScript
    Assert-Census (-not [bool]$describedBound.runnerBounds.verifierLaunchRecorded) `
        'A runner that only names the per-launch record in a comment was credited with publishing it.'

    Write-Host '21/21 losing the record of a launch is fatal, not degradable' -ForegroundColor Cyan
    # Two of the three roles run inside handlers that turn any fault into a
    # degraded status and let the run reach 'complete' - which is exactly the
    # terminal whose census is trusted as exact. A swallowed accounting failure
    # would therefore not degrade the run, it would shrink the number the next
    # entry is authorized against.
    $reviewerAst = [System.Management.Automation.Language.Parser]::ParseFile($reviewerScript, [ref]$null, [ref]$null)
    foreach ($guarded in @(
            'Invoke-ReviewerConventionSpecialistPass',
            'Invoke-ReviewerConventionSpecialistSafely',
            'Invoke-ReviewerCrossVerificationSafely')) {
        $fn = $reviewerAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $guarded
            }, $true)
        Assert-Census ($null -ne $fn) "The reviewer no longer defines '$guarded', so its degradation boundary cannot be checked."
        if ($null -eq $fn) { continue }
        $body = $fn.Extent.Text
        Assert-Census ($body -match 'Test-ReviewerModelStartAccountingFault') `
            ("'$guarded' degrades on every fault without letting a lost model start record through, so a run that could " +
                'not record a launch it made would still report a complete, exact census.')
    }
    Assert-Census ((Get-Command -Name Write-ReviewerModelStartAccounting -CommandType Function -ErrorAction SilentlyContinue) -or
        ([IO.File]::ReadAllText($reviewerScript, [Text.UTF8Encoding]::new($false, $true)) -match
            'function Write-ReviewerModelStartAccounting')) `
        'The reviewer publishes its model start records without the writer that makes a failed write fatal.'
    $accountingWrites = @([regex]::Matches(
            [IO.File]::ReadAllText($reviewerScript, [Text.UTF8Encoding]::new($false, $true)),
            '(?m)^\s*Write-ReviewerCycleMetadata -Fields @\{\s*\r?\n\s*cycle = \$CycleNumber; mode = "(model|specialist|verifier)-attempt-accounting"'))
    Assert-Census (@($accountingWrites).Count -eq 0) `
        ("$(@($accountingWrites).Count) model start record(s) are still published through the plain cycle writer, whose " +
            'failure no handler treats as fatal.')

    # -- 22. A launch intent stands in for an accounting record that was never
    # reached ---------------------------------------------------------------
    # The harness creates the process and THEN raises telemetry, drains two
    # output streams and writes standard input, any of which can throw into a
    # handler that degrades. The accounting record is written after the harness
    # returns, so that throw loses it - and the subprocess still ran.
    Write-Host ''
    Write-Host '22. A launch intent counts a start whose accounting record was never written' -ForegroundColor Cyan
    $lostRoot = Join-Path $sandbox 'lost-after-launch'
    [void](New-CensusRunRoot -Root $lostRoot -GeneralistIntent 2 -GeneralistAttempts 1 `
            -SpecialistIntent 1 -SpecialistAttempts 0 `
            -VerifierIntent 3 -VerifierLogRecord 1 -VerifierNonce @() -WritePreviewFile $false)
    $lostCensus = Get-ReviewerModelStartCensus -RunRoot $lostRoot -Argv @('-EnableVerificationPreview')
    Assert-Census ([int]$lostCensus.byRole.generalist -eq 2) `
        "Two generalist subprocesses were intended and one came back to be accounted for; the census read $([int]$lostCensus.byRole.generalist) rather than 2."
    Assert-Census ([int]$lostCensus.byRole.specialist -eq 1) `
        "A specialist subprocess was intended and never accounted for; the census read $([int]$lostCensus.byRole.specialist) rather than 1."
    Assert-Census ([int]$lostCensus.byRole.verifier -eq 3) `
        "Three verifier subprocesses were intended and one was accounted for; the census read $([int]$lostCensus.byRole.verifier) rather than 3."
    Assert-Census ([int]$lostCensus.realModelStarts -eq 6) `
        "Six subprocesses were intended in all; the census read $([int]$lostCensus.realModelStarts)."

    # -- 23. An intent and its own accounting record are one start, not two ----
    Write-Host ''
    Write-Host '23. A launch that completed normally is counted once' -ForegroundColor Cyan
    $pairedRoot = Join-Path $sandbox 'intent-paired'
    [void](New-CensusRunRoot -Root $pairedRoot -GeneralistIntent 4 -GeneralistAttempts 4 `
            -SpecialistIntent 1 -SpecialistAttempts 1)
    $pairedCensus = Get-ReviewerModelStartCensus -RunRoot $pairedRoot -Argv @()
    Assert-Census ([int]$pairedCensus.byRole.generalist -eq 4) `
        "Four generalist launches each published both witnesses; the census read $([int]$pairedCensus.byRole.generalist) rather than 4."
    Assert-Census ([int]$pairedCensus.realModelStarts -eq 5) `
        "Five launches each published both witnesses; the census read $([int]$pairedCensus.realModelStarts) rather than 5."

    # -- 24. A refusal that happens before the create call publishes no intent -
    # This is the whole reason the intent sits below the capture and single-shot
    # guards rather than at the top of the function: a refusal must still be
    # able to report that it spent nothing.
    Write-Host ''
    Write-Host '24. A pre-launch refusal still counts zero' -ForegroundColor Cyan
    $refusedRoot = Join-Path $sandbox 'intent-refused'
    [void](New-CensusRunRoot -Root $refusedRoot -GeneralistRefusedBeforeLaunch 3)
    $refusedCensus = Get-ReviewerModelStartCensus -RunRoot $refusedRoot -Argv @()
    Assert-Census ([int]$refusedCensus.realModelStarts -eq 0) `
        "Three refusals happened before any process could exist; the census read $([int]$refusedCensus.realModelStarts) rather than 0."

    # -- 25. A build that publishes no intents is still measured ---------------
    Write-Host ''
    Write-Host '25. A log with no intent records is measured by its accounting records alone' -ForegroundColor Cyan
    $legacyIntentRoot = Join-Path $sandbox 'intent-absent'
    [void](New-CensusRunRoot -Root $legacyIntentRoot -GeneralistAttempts 4 -SpecialistAttempts 1)
    $legacyIntentCensus = Get-ReviewerModelStartCensus -RunRoot $legacyIntentRoot -Argv @()
    Assert-Census ([int]$legacyIntentCensus.realModelStarts -eq 5) `
        "A build that publishes no intents must still be counted by its accounting records; the census read $([int]$legacyIntentCensus.realModelStarts) rather than 5."

    # -- 26. The runner writes the intent before it can create a process ------
    # Structural, because this is an ORDERING and no artifact can witness it:
    # the intent has to be the last statement before the create call on every
    # branch, or the window it closes reopens.
    Write-Host ''
    Write-Host '26. Every launch branch publishes its intent before the create call' -ForegroundColor Cyan
    $subprocessFn = $reviewerAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Invoke-ReviewerModelSubprocess'
        }, $true)
    Assert-Census ($null -ne $subprocessFn) `
        'The reviewer no longer defines Invoke-ReviewerModelSubprocess, so the launch boundary cannot be checked.'
    if ($null -ne $subprocessFn) {
        $subprocessStart = $subprocessFn.Extent.StartOffset
        # Command AST nodes, not text: the function's own commentary names
        # 'Invoke-TimedProcess' when explaining what the refusals sit above, and
        # a comment is not a process.
        $launchOffsets = [System.Collections.Generic.List[int]]::new()
        $intentOffsets = [System.Collections.Generic.List[int]]::new()
        $commandNodes = $subprocessFn.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $null -ne $node.CommandElements -and
                @($node.CommandElements).Count -gt 0
            }, $true)
        foreach ($node in @($commandNodes)) {
            if ($null -eq $node) { continue }
            $name = [string]$node.CommandElements[0].Extent.Text
            $offset = [int]($node.Extent.StartOffset - $subprocessStart)
            if ($name -ceq 'Invoke-TimedProcess') { [void]$launchOffsets.Add($offset) }
            elseif ($name -ceq 'Write-ReviewerModelLaunchIntent') { [void]$intentOffsets.Add($offset) }
        }
        Assert-Census (@($launchOffsets).Count -ge 1) `
            'Invoke-ReviewerModelSubprocess creates no process at all, so the census has nothing to bound.'
        Assert-Census (@($intentOffsets).Count -eq @($launchOffsets).Count) `
            ("Invoke-ReviewerModelSubprocess makes $(@($launchOffsets).Count) create call(s) and publishes " +
                "$(@($intentOffsets).Count) launch intent(s); every branch that can create a process must publish one.")
        foreach ($offset in @($launchOffsets)) {
            $before = @(@($intentOffsets) | Where-Object { $_ -lt $offset })
            Assert-Census (@($before).Count -ge 1) `
                'A process create call in Invoke-ReviewerModelSubprocess is not preceded by a launch intent, so a throw inside the harness would lose that start.'
            if (@($before).Count -lt 1) { continue }
            $nearest = [int](@($before) | Sort-Object -Descending | Select-Object -First 1)
            $intervening = @(@($launchOffsets) | Where-Object { $_ -gt $nearest -and $_ -lt $offset })
            Assert-Census (@($intervening).Count -eq 0) `
                'A launch intent is separated from its create call by another create call, so one of the two launches is unwitnessed.'
        }
        # The refusals must stay ABOVE the first intent, or a run that refused
        # before launching would be charged for a process it never made.
        $subprocessText = $subprocessFn.Extent.Text
        $firstIntent = [int](@($intentOffsets) | Sort-Object | Select-Object -First 1)
        $captureGuard = $subprocessText.IndexOf('ReviewerRoleInputCaptureActive', [StringComparison]::Ordinal)
        $singleShotGuard = $subprocessText.IndexOf('ReviewerAcquisitionSingleShot', [StringComparison]::Ordinal)
        Assert-Census ($captureGuard -ge 0 -and $captureGuard -lt $firstIntent) `
            'The role input capture refusal no longer precedes the launch intent, so a capture run would be charged for a model it never started.'
        Assert-Census ($singleShotGuard -ge 0 -and $singleShotGuard -lt $firstIntent) `
            'The single-shot acquisition refusal no longer precedes the launch intent, so a refused second launch would be charged.'
    }

    # -- 27. The verifier ceiling is spent in assignments, not in the states a
    # run reached ------------------------------------------------------------
    # The defect this section exists for. A cohort's verifier ceiling used to be
    # compared against a count of committed verifier-backed terminal transitions
    # - a list with eight members - while the run behind it stood on forty real
    # reciprocal assignments. The census below reads the assignments themselves,
    # off the same sealed previews the run signed.
    Write-Host ''
    Write-Host '27. Forty assignments across two required models are forty, not four' -ForegroundColor Cyan
    $assignRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\forty') -Cluster @(
        @{ Candidates = 10; Models = @('verifier-alpha', 'verifier-beta'); Nonce = @('n1', 'n2') },
        @{ Candidates = 10; Models = @('verifier-alpha', 'verifier-beta'); Nonce = @('n3', 'n4') })
    $assignCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $assignRoot -Argv $verifyingArgv
    Assert-Census ([int]$assignCensus.realVerifierAssignments -eq 40) `
        "Forty sealed assignments were counted as $($assignCensus.realVerifierAssignments)."
    Assert-Census ([bool]$assignCensus.complete) 'A run whose previews are all readable reported an incomplete assignment census.'
    Assert-Census (@($assignCensus.byVerifierModel).Count -eq 2) `
        'The census did not break forty assignments down by the two reciprocal models that were required.'
    Assert-Census (((@($assignCensus.byVerifierModel) | Measure-Object -Property assignmentCount -Sum).Sum ?? 0) -eq 40) `
        'The per-model breakdown does not account for the total it is published beside.'
    # Grouping is the whole reason the two numbers are published separately: four
    # launches served all forty assignments, and neither figure may be derived
    # from the other.
    Assert-Census ([int]$assignCensus.verifierProcessStarts -eq 4) `
        "Four grouped launches were counted as $($assignCensus.verifierProcessStarts) verifier processes."

    Write-Host ''
    Write-Host '28. A retried assignment is the same assignment, and a regrouped one is not' -ForegroundColor Cyan
    # The assignment identity is candidate x required model. A launch that was
    # retried serves the same assignments again under a new nonce: the assignment
    # total is unchanged and the process total rises.
    $retryRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\retry') -Cluster @(
        @{ Candidates = 3; Models = @('verifier-alpha', 'verifier-beta'); Nonce = @('r1', 'r2', 'r3') })
    $retryCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $retryRoot -Argv $verifyingArgv
    Assert-Census ([int]$retryCensus.realVerifierAssignments -eq 6) `
        "Three candidates against two required models is six assignments; the census said $($retryCensus.realVerifierAssignments)."
    Assert-Census ([int]$retryCensus.verifierProcessStarts -eq 3) `
        "A retried group is another process; the census said $($retryCensus.verifierProcessStarts)."
    # The same assignment appearing in two previews - which is what a resumed
    # phase republishes - is one assignment, because the identity is the record.
    $dupRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\dup') -Cluster @(
        @{ Candidates = 2; Models = @('verifier-alpha'); Nonce = @('d1') }) -RepublishPreview $true
    $dupCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $dupRoot -Argv $verifyingArgv
    Assert-Census ([int]$dupCensus.realVerifierAssignments -eq 2) `
        "A republished preview double-counted its assignments as $($dupCensus.realVerifierAssignments); expected 2."

    Write-Host ''
    Write-Host '29. Nothing to verify is a reading; nothing published is not' -ForegroundColor Cyan
    $emptyRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\empty') -Cluster @()
    $emptyCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $emptyRoot -Argv $verifyingArgv
    Assert-Census ([int]$emptyCensus.realVerifierAssignments -eq 0 -and [bool]$emptyCensus.complete) `
        'A run whose sealed preview listed no assignments was not accounted at a complete zero.'
    # An authorized verification that published no preview directory at all is
    # incomplete rather than zero: the difference is a run that had nothing to do
    # against a run whose evidence is missing.
    $noneRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\none') -Cluster @() -WritePreviewDirectory $false
    $noneCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $noneRoot -Argv $verifyingArgv
    Assert-Census (-not [bool]$noneCensus.complete) `
        'An authorized verification that published no previews at all reported a complete census.'
    # A run that never authorized cross-verification is a complete zero, not a
    # gap. A specialist-only run is exactly that shape.
    $specialistOnly = Get-ReviewerVerifierAssignmentCensus -RunRoot $noneRoot -Argv @('-Model', 'a', '-EnableConventionSpecialist')
    Assert-Census ([int]$specialistOnly.realVerifierAssignments -eq 0 -and [bool]$specialistOnly.complete) `
        'A run that never enabled cross-verification was charged an unmeasured verifier gap.'

    Write-Host ''
    Write-Host '30. Evidence that cannot be trusted is a refusal, not a smaller number' -ForegroundColor Cyan
    $refusals = @(
        @{ Name = 'a preview with no assignments array'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\no-array') -Cluster @() -OmitAssignmentsKey $true) },
        @{ Name = 'an assignment with no identity'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\no-id') -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('x1') }) -BlankAssignmentId $true) },
        @{ Name = 'an assignment that names no verifier model'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\no-model') -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('x1') }) -BlankVerifierModel $true) },
        @{ Name = 'a preview whose seal cannot be parsed'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\torn') -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('x1') }) -TruncateEnvelope $true) },
        @{ Name = 'a preview whose sealed manifest was edited into nonsense'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\tamper') -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('x1') }) -TamperManifestJson $true) }
    )
    foreach ($refusal in $refusals) {
        $message = Get-CensusRefusal { Get-ReviewerVerifierAssignmentCensus -RunRoot ([string]$refusal.Root) -Argv $verifyingArgv }
        Assert-Census ($message -ne '') "Reading $($refusal.Name) returned a number instead of refusing."
    }
    $missingRoot = Get-CensusRefusal { Get-ReviewerVerifierAssignmentCensus -RunRoot (Join-Path $sandbox 'assign\does-not-exist') -Argv $verifyingArgv }
    Assert-Census ($missingRoot -ne '') 'A run root that does not exist was accounted at zero assignments.'

    Write-Host ''
    Write-Host '31. The assignment bound is the plan''s own cap, read from the shipping runner' -ForegroundColor Cyan
    $assignBound = Get-ReviewerVerifierAssignmentBound -Argv $verifyingArgv -ReviewerScriptPath $reviewerScript
    $modelBound = Get-ReviewerModelStartBound -Argv $verifyingArgv -ReviewerScriptPath $reviewerScript
    Assert-Census ([int]$assignBound.maxVerifierAssignments -gt 0) `
        'The assignment bound for an authorized verification is zero, so no ceiling derived from it could ever be crossed.'
    Assert-Census ([int]$assignBound.maxVerifierAssignments -eq [int]$modelBound.runnerBounds.maxVerifierLaunches) `
        ("The assignment bound is $($assignBound.maxVerifierAssignments) against a runner cap of " +
            "$($modelBound.runnerBounds.maxVerifierLaunches); the runner's cap IS the per-run assignment cap and must not be restated.")
    # Two slots is twice one slot, which is the arithmetic a cohort preflight
    # does - and it is the shipping bound writer, not this test, that has to do
    # it. Read back from the artifact New-ShadowModelStartBound seals so a change
    # to the runner cap moves the plan, the artifact and this expectation
    # together.
    $twoSlotBoundRoot = Join-Path $sandbox 'assign\two-slot-bound'
    [void](New-Item -ItemType Directory -Path $twoSlotBoundRoot -Force)
    $boundConfigPath = Join-Path $twoSlotBoundRoot 'reviewer.json'
    $boundConfig = [ordered]@{
        review = [ordered]@{
            targetRefName = 'refs/heads/main'
            verification = [ordered]@{ enabled = $true }
        }
    }
    [IO.File]::WriteAllText($boundConfigPath, ($boundConfig | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
    $boundConfigSha = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($boundConfigPath))).ToLowerInvariant()
    $boundRequestPath = Join-Path $twoSlotBoundRoot 'request.json'
    $boundRequest = [ordered]@{
        kind = 'shadow-run-preparation'
        contractVersion = 'devpilot.shadow-run-coordinator.request.v1'
        toolkit = [ordered]@{ repositoryRoot = $repo; head = ('0' * 40) }
        qualification = [ordered]@{ reviewerConfigPath = $boundConfigPath; plannedRunCount = 2 }
        digests = [ordered]@{ configSha256 = $boundConfigSha }
        slots = [ordered]@{
            shadowSlotsEnabled = $true
            declared = @(
                [ordered]@{ name = 'slot1'; reviewerScriptPath = $reviewerScript },
                [ordered]@{ name = 'slot2'; reviewerScriptPath = $reviewerScript })
        }
    }
    [IO.File]::WriteAllText($boundRequestPath, ($boundRequest | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
    $twoSlotBoundPath = Join-Path $twoSlotBoundRoot 'bound.json'
    $boundWriter = Join-Path $repo 'tools\New-ShadowModelStartBound.ps1'
    & $boundWriter -RequestPath $boundRequestPath -OutputPath $twoSlotBoundPath -Force
    Assert-Census ($LASTEXITCODE -eq 0) "The shipping bound writer refused a two-slot request (exit $LASTEXITCODE)."
    $twoSlotBound = [IO.File]::ReadAllText($twoSlotBoundPath, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json -Depth 32
    $perSlotSealed = [int]$twoSlotBound.slots[0].maxVerifierAssignments
    Assert-Census ([int]$twoSlotBound.maxVerifierAssignments -eq ($perSlotSealed * 2)) `
        ("The sealed two-slot bound is $($twoSlotBound.maxVerifierAssignments) against a per-slot cap of " +
            "$perSlotSealed; a cohort ceiling proved from it would not cover both slots.")
    Assert-Census ($perSlotSealed -eq [int]$assignBound.maxVerifierAssignments) `
        ("The bound writer sealed $perSlotSealed assignment(s) for a slot the census bounds at " +
            "$($assignBound.maxVerifierAssignments); the plan a cohort proves and the plan a run is given have drifted apart.")
    $quietBound = Get-ReviewerVerifierAssignmentBound -Argv $quietArgv -ReviewerScriptPath $reviewerScript
    Assert-Census ([int]$quietBound.maxVerifierAssignments -eq 0) `
        'A run that never authorized cross-verification was bounded above zero assignments.'

    Write-Host ''
    Write-Host '32. An interrupted verification is charged what its plan could still have spent' -ForegroundColor Cyan
    $allowanceComplete = Get-ReviewerVerifierAssignmentUnmeasuredAllowance -Argv $verifyingArgv `
        -ReviewerScriptPath $reviewerScript -RunEndedComplete $true -Census $assignCensus
    Assert-Census ([int]$allowanceComplete -eq 0) `
        "A complete run with a complete census was charged an allowance of $allowanceComplete."
    $allowanceKilled = Get-ReviewerVerifierAssignmentUnmeasuredAllowance -Argv $verifyingArgv `
        -ReviewerScriptPath $reviewerScript -RunEndedComplete $false -Census $assignCensus
    Assert-Census ([int]$allowanceKilled -eq ([int]$assignBound.maxVerifierAssignments - 40)) `
        "A killed run was charged $allowanceKilled unmeasured assignments; expected its plan's remainder."
    $allowanceBlind = Get-ReviewerVerifierAssignmentUnmeasuredAllowance -Argv $verifyingArgv `
        -ReviewerScriptPath $reviewerScript -RunEndedComplete $false -Census $null
    Assert-Census ([int]$allowanceBlind -eq [int]$assignBound.maxVerifierAssignments) `
        'A run whose evidence could not be read at all was charged less than its whole plan.'
    $allowanceQuiet = Get-ReviewerVerifierAssignmentUnmeasuredAllowance -Argv $quietArgv `
        -ReviewerScriptPath $reviewerScript -RunEndedComplete $false -Census $null
    Assert-Census ([int]$allowanceQuiet -eq 0) `
        'A run that never authorized cross-verification was charged an unmeasured verifier allowance anyway.'

    Write-Host ''
    Write-Host '33. A frozen real run is accounted in assignments, read-only' -ForegroundColor Cyan
    # The roots below belong to operators' machines. Each is read without being
    # written, and the scenario is skipped rather than failed when one is absent.
    $frozenRoots = @($FrozenSlotRoot) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }
    if (@($frozenRoots).Count -lt 1) {
        Write-Host '  SKIP - no frozen slot root was given.' -ForegroundColor DarkGray
    }
    else {
        foreach ($frozenSlot in @($frozenRoots)) {
            $frozenCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $frozenSlot -Argv @('-EnableVerificationPreview')
            Assert-Census ([int]$frozenCensus.realVerifierAssignments -gt 0) `
                "The frozen slot '$frozenSlot' sealed a real verification and was accounted at zero assignments."
            Assert-Census ((((@($frozenCensus.byVerifierModel) | Measure-Object -Property assignmentCount -Sum).Sum ?? 0)) -eq
                [int]$frozenCensus.realVerifierAssignments) `
                "The frozen slot '$frozenSlot' breaks its assignments down into a total it does not have."
            Assert-Census ([bool]$frozenCensus.complete) `
                "The frozen slot '$frozenSlot' sealed a real verification and was read as unmeasured."
            if ($FrozenSlotExpectedAssignments -gt 0) {
                Assert-Census ([int]$frozenCensus.realVerifierAssignments -eq $FrozenSlotExpectedAssignments) `
                    ("The frozen slot '$frozenSlot' totalled $($frozenCensus.realVerifierAssignments) assignments; " +
                        "expected $FrozenSlotExpectedAssignments.")
            }
            Write-Host ("  {0}: {1} assignment(s), {2} process start(s)" -f
                (Split-Path $frozenSlot -Leaf), $frozenCensus.realVerifierAssignments, $frozenCensus.verifierProcessStarts) -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host '34. A verification that lost its evidence is unmeasured, never a measured zero' -ForegroundColor Cyan
    # The failure this whole change exists to prevent, in its most dangerous
    # shape. The reviewed side creates the preview directory before any review
    # work happens and, when cross-verification faults, seals a preview carrying
    # an empty assignment list and returns normally - so the run still ends
    # cleanly. A census that judged completeness on the directory, or on the
    # file, would publish a confident zero for a run that may have stood on its
    # whole plan.
    $lostRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\evidence-lost') -EmergencySeal $true -Cluster @()
    $lostCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $lostRoot -Argv $verifyingArgv
    Assert-Census ([int]$lostCensus.realVerifierAssignments -eq 0) `
        'A preview that sealed no assignments was read as though it carried some.'
    Assert-Census (-not [bool]$lostCensus.complete) `
        'A run whose cross-verification lost its evidence was accounted as a complete census of zero.'
    Assert-Census ([string]$lostCensus.incompleteReason -ne '') `
        'An incomplete assignment census named no reason for being incomplete.'
    $lostAllowance = Get-ReviewerVerifierAssignmentUnmeasuredAllowance -Argv $verifyingArgv `
        -ReviewerScriptPath $reviewerScript -RunEndedComplete $true -Census $lostCensus
    Assert-Census ([int]$lostAllowance -eq [int]$assignBound.maxVerifierAssignments) `
        ("A run that ended cleanly having lost its verification evidence was charged $lostAllowance unmeasured " +
            'assignment(s); the whole of its plan is unproven and must be charged however the run ended.')
    # The inverse, and the one that matters just as much. A review can conclude
    # 'degraded' for four ordinary reasons - one verifier invocation that timed
    # out, a degraded specialist, a degraded convention plan, a withheld
    # authoritative source - and in every one of them the FULL assignment list is
    # still sealed. Reading that word as lost evidence would stop a whole cohort
    # on a run that measured perfectly.
    $degradedFullRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\degraded-full') -Status 'degraded' -Cluster @(
        @{ Candidates = 4; Models = @('verifier-alpha', 'verifier-beta'); Nonce = @('n1', 'n2') })
    $degradedFullCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $degradedFullRoot -Argv $verifyingArgv
    Assert-Census ([int]$degradedFullCensus.realVerifierAssignments -eq 8) `
        ("A degraded review that sealed all eight assignments was counted at " +
            "$($degradedFullCensus.realVerifierAssignments).")
    Assert-Census ([bool]$degradedFullCensus.complete) `
        'A review that concluded degraded while sealing its whole assignment set was called unmeasured, which would stop a cohort on an ordinary run.'
    $degradedFullAllowance = Get-ReviewerVerifierAssignmentUnmeasuredAllowance -Argv $verifyingArgv `
        -ReviewerScriptPath $reviewerScript -RunEndedComplete $true -Census $degradedFullCensus
    Assert-Census ([int]$degradedFullAllowance -eq 0) `
        "A fully measured degraded run was charged $degradedFullAllowance unmeasured assignment(s)."
    # One good pass does not cover a lost one. Completeness is a property of
    # every pass the run sealed, not of the best one.
    $mixedRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\mixed') -Cluster @(
        @{ Candidates = 2; Models = @('verifier-alpha'); Nonce = @('n1') })
    $mixedLost = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\mixed-lost') -EmergencySeal $true -Cluster @()
    Copy-Item -LiteralPath (Join-Path $mixedLost 'verification-previews\preview-001.json') `
        -Destination (Join-Path $mixedRoot 'verification-previews\preview-009.json')
    $mixedCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $mixedRoot -Argv $verifyingArgv
    Assert-Census ([int]$mixedCensus.realVerifierAssignments -eq 2) `
        'The surviving pass of a mixed run was not counted.'
    Assert-Census (-not [bool]$mixedCensus.complete) `
        'A run that sealed one good pass and lost another was called complete, so the lost pass would be scored as zero.'
    $mixedAllowance = Get-ReviewerVerifierAssignmentUnmeasuredAllowance -Argv $verifyingArgv `
        -ReviewerScriptPath $reviewerScript -RunEndedComplete $true -Census $mixedCensus
    Assert-Census ([int]$mixedAllowance -eq ([int]$assignBound.maxVerifierAssignments - 2)) `
        "A mixed run was charged $mixedAllowance unmeasured assignment(s); expected its plan's remainder above what survived."
    # Each marker of the loss tuple stands alone. The evidence-loss writer
    # publishes all three together, so a fixture that only ever sets all three
    # would pass an implementation that demanded all three - and that
    # implementation would score a partially written record as a measured zero.
    foreach ($marker in @('diagnostic', 'inputPath', 'digest')) {
        $markerRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox "assign\marker-$marker") -LossMarker $marker -Cluster @(
            @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })
        $markerCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $markerRoot -Argv $verifyingArgv
        Assert-Census (-not [bool]$markerCensus.complete) `
            "A preview carrying only the '$marker' marker of a lost cross-verification was accounted as fully measured."
    }
    # An empty preview directory witnesses nothing either: it exists before the
    # phase runs.
    $emptyDirRoot = Join-Path $sandbox 'assign\empty-directory'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $emptyDirRoot 'verification-previews'))
    Add-CensusExecutionWitnessLog -Root $emptyDirRoot
    Add-CensusSeal -Root $emptyDirRoot
    $emptyDirCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $emptyDirRoot -Argv $verifyingArgv
    Assert-Census (-not [bool]$emptyDirCensus.complete) `
        'An authorized run whose preview directory was created and never filled was accounted as a complete zero.'
    # And a run that never authorized verification is still measured at zero,
    # because the sealed vector proves it could stand on nothing.
    $quietEmpty = Get-ReviewerVerifierAssignmentCensus -RunRoot $emptyDirRoot -Argv $quietArgv
    Assert-Census ([bool]$quietEmpty.complete) `
        'A run that never authorized cross-verification was called unmeasured for publishing no preview.'

    Write-Host ''
    Write-Host '35. An assignment set this build cannot read exactly is refused, not rounded' -ForegroundColor Cyan
    $rowRefusals = @(
        @{ Name = 'a preview publishing a null assignment list'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\null-list') -NullAssignments $true -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })) },
        @{ Name = 'a preview carrying a null row among its assignments'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\null-row') -NullAssignmentRow $true -Cluster @(
                    @{ Candidates = 2; Models = @('verifier-alpha'); Nonce = @('n1') })) },
        @{ Name = 'the same assignment identity sealed against two different verifier models'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\conflict') -ConflictingRepublishModel 'verifier-omega' -Cluster @(
                    @{ Candidates = 2; Models = @('verifier-alpha'); Nonce = @('n1') })) },
        @{ Name = 'an assignment identity that is not the shape the reviewed side mints'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\malformed-id') -MalformedAssignmentId $true -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })) },
        @{ Name = 'a preview that publishes no diagnostic at all'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\no-diagnostic') -OmitDiagnostic $true -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })) },
        @{ Name = 'a single pass recording more distinct launches than assignment rows'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\over-launched') -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1', 'n2', 'n3') })) },
        @{ Name = 'an assignment identity carrying uppercase hex'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\id-upper') `
                    -AssignmentIdOverride ('va1:' + ('A' * 64)) -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })) },
        @{ Name = 'an assignment identity one hex digit short'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\id-short') `
                    -AssignmentIdOverride ('va1:' + ('a' * 63)) -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })) },
        @{ Name = 'an assignment identity one hex digit long'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\id-long') `
                    -AssignmentIdOverride ('va1:' + ('a' * 65)) -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })) },
        @{ Name = 'a preview whose input manifest digest is a number rather than a digest'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\digest-numeric') -NumericInputDigest $true -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })) },
        @{ Name = 'a preview publishing a null diagnostic'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\null-diagnostic') -NullTupleField 'diagnostic' -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })) },
        @{ Name = 'a preview publishing a null input artifact path'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\null-input-path') -NullTupleField 'inputArtifactPath' -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })) },
        @{ Name = 'a preview publishing a null input manifest digest'
            Root = (New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\null-input-digest') -NullTupleField 'inputManifestSha256' -Cluster @(
                    @{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })) }
    )
    foreach ($refusal in $rowRefusals) {
        $message = Get-CensusRefusal { Get-ReviewerVerifierAssignmentCensus -RunRoot ([string]$refusal.Root) -Argv $verifyingArgv }
        Assert-Census ($message -ne '') "Reading $($refusal.Name) returned a number instead of refusing."
    }
    # The same identity sealed twice against the SAME model is a resumed phase
    # republishing its own work, and stays a single assignment.
    $sameModelTwice = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\republish-same') -RepublishPreview $true -Cluster @(
        @{ Candidates = 3; Models = @('verifier-alpha', 'verifier-beta'); Nonce = @('n1') })
    $sameModelCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $sameModelTwice -Argv $verifyingArgv
    Assert-Census ([int]$sameModelCensus.realVerifierAssignments -eq 6) `
        "A republished preview counted $($sameModelCensus.realVerifierAssignments) assignments where six identities exist."
    # And a genuine second pass over the same candidates mints fresh launch
    # nonces while the identities dedupe, so the run's totals legitimately carry
    # more launches than assignments. No ordering between the two may be
    # required of a run root.
    $reverified = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'assign\reverified') -RepublishPreview $true `
        -RepublishNonceSuffix 'x' -Cluster @(@{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })
    $reverifiedCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $reverified -Argv $verifyingArgv
    Assert-Census ([int]$reverifiedCensus.realVerifierAssignments -eq 1) `
        "A re-verified candidate counted $($reverifiedCensus.realVerifierAssignments) assignments where one identity exists."
    Assert-Census ([int]$reverifiedCensus.verifierProcessStarts -eq 2) `
        "A re-verified candidate counted $($reverifiedCensus.verifierProcessStarts) launches where two nonces were minted."
    Assert-Census ([bool]$reverifiedCensus.complete) `
        'A legitimate second verification pass was refused or read as unmeasured.'

    Write-Host ''
    Write-Host '36. Accounting evidence is believed because it is signed, never because of its shape' -ForegroundColor Cyan
    # THE DEFECT THIS GROUP EXISTS FOR. The census used to believe any file under
    # a run root that parsed and carried the right property names. Anyone able to
    # write into that directory could move every number downstream while leaving
    # something that looked exactly like a clean measurement. Each case below is
    # an edit an attacker - or a careless replay - can make after a run ends.
    $authRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'auth\baseline') -GeneralistAttempts 2 `
        -VerifierNonce @('n1') -AssignmentsPerNonce 1
    $authBaseline = Get-ReviewerModelStartCensus -RunRoot $authRoot -Argv $verifyingArgv
    Assert-Census ([bool]$authBaseline.authenticated) `
        "A run that sealed its own census manifest read as unauthenticated ($($authBaseline.authenticationBasis))."
    Assert-Census ([string]$authBaseline.authenticationBasis -ceq 'signedCensusManifest') `
        "A signed run reported authentication basis '$($authBaseline.authenticationBasis)'."
    Assert-Census ([bool]$authBaseline.complete) 'A signed, fully witnessed run was reported incomplete.'

    # A key that is not the run's key proves nothing about the run's files, and
    # neither does no key at all. Both are refusals to certify, not findings of
    # tampering, and both block.
    $wrongKeyCensus = Get-ReviewerModelStartCensus -RunRoot $authRoot -Argv $verifyingArgv `
        -MasterKey ([byte[]]@(1..32))
    Assert-Census (-not [bool]$wrongKeyCensus.authenticated) `
        'A census manifest verified under a key that did not seal it.'
    Assert-Census ([string]$wrongKeyCensus.authenticationBasis -ceq 'censusManifestRejected') `
        "A wrong-key census reported basis '$($wrongKeyCensus.authenticationBasis)'."
    Assert-Census (-not [bool]$wrongKeyCensus.complete) 'A census that could not be authenticated was still called complete.'
    $noKeyCensus = Get-ReviewerModelStartCensus -RunRoot $authRoot -Argv $verifyingArgv -MasterKey ([byte[]]@())
    Assert-Census ([string]$noKeyCensus.authenticationBasis -ceq 'noCensusKey') `
        "A keyless census reported basis '$($noKeyCensus.authenticationBasis)'."
    Assert-Census (-not [bool]$noKeyCensus.complete) 'A keyless census was called complete.'

    # NEVER AN UNDERCOUNT. The counts a blocked census reports are still every
    # start its evidence shows. Blocking must not be a way to make a run look
    # cheaper than it was.
    Assert-Census ([int]$wrongKeyCensus.realModelStarts -eq [int]$authBaseline.realModelStarts) `
        ("An unauthenticated census reported $($wrongKeyCensus.realModelStarts) starts where the same evidence " +
        "shows $($authBaseline.realModelStarts). Authentication must block, never discount.")

    # Appending an attempt record after the fact is the cheapest forgery there
    # is, and the one that inflates a budget's denominator.
    $forgedLogRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'auth\forged-log') -GeneralistAttempts 1
    [IO.File]::AppendAllText((Join-Path $forgedLogRoot 'logs\reviewer.log.jsonl'),
        (ConvertTo-Json -InputObject ([ordered]@{
                    mode = 'model-attempt-accounting'; attempt = 2
                    model = 'opaque-model-identifier'; processStarted = $true
                }) -Depth 8 -Compress) + "`n")
    $forgedLogCensus = Get-ReviewerModelStartCensus -RunRoot $forgedLogRoot -Argv $quietArgv
    Assert-Census (-not [bool]$forgedLogCensus.authenticated) `
        'A cycle log with a record appended after the run sealed its manifest was accepted.'
    Assert-Census (-not [bool]$forgedLogCensus.complete) 'A forged cycle log produced a complete census.'
    Assert-Census ([int]$forgedLogCensus.realModelStarts -eq 2) `
        ("A forged log was counted at $($forgedLogCensus.realModelStarts) rather than at every start its own bytes " +
        'claim. A blocked census still reports the larger number.')

    # Deleting a preview is the forgery that makes a run look like it verified
    # less than it did; adding one makes it look like it verified more. Both are
    # differences from an exact inventory, which is why the inventory is exact.
    $droppedRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'auth\dropped-preview') -RepublishPreview $true `
        -Cluster @(@{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })
    Remove-Item -LiteralPath (Join-Path $droppedRoot 'verification-previews\preview-002.json') -Force
    $droppedCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $droppedRoot -Argv $verifyingArgv
    Assert-Census (-not [bool]$droppedCensus.authenticated) 'A preview removed after the seal was not detected.'
    Assert-Census (-not [bool]$droppedCensus.complete) 'An assignment census missing an attested preview was called complete.'

    $addedRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'auth\added-preview') `
        -Cluster @(@{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })
    Copy-Item -LiteralPath (Join-Path $addedRoot 'verification-previews\preview-001.json') `
        -Destination (Join-Path $addedRoot 'verification-previews\preview-009.json')
    $addedCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $addedRoot -Argv $verifyingArgv
    Assert-Census (-not [bool]$addedCensus.authenticated) 'A preview added after the seal was not detected.'
    Assert-Census (($addedCensus.authenticationObjections -join ' ') -match 'preview-009\.json') `
        'The objection about an added preview did not name it.'

    # A preview whose bytes changed under an unchanged name.
    $rewrittenRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'auth\rewritten-preview') `
        -Cluster @(@{ Candidates = 2; Models = @('verifier-alpha'); Nonce = @('n1') })
    $rewrittenPath = Join-Path $rewrittenRoot 'verification-previews\preview-001.json'
    [IO.File]::WriteAllBytes($rewrittenPath, ([IO.File]::ReadAllBytes($rewrittenPath) + [byte[]]@(0x20)))
    $rewrittenCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $rewrittenRoot -Argv $verifyingArgv
    Assert-Census (-not [bool]$rewrittenCensus.authenticated) 'A preview rewritten after the seal was not detected.'

    # THE GAP THE SIGNATURE ALONE DOES NOT CLOSE. A preview names the input it
    # stands on but does not seal that input, so a perfectly valid preview can
    # describe a file that has since been replaced. Rehashing the named input
    # against the digest the preview published is what closes it.
    $swappedRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'auth\swapped-input') `
        -Cluster @(@{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })
    [IO.File]::WriteAllBytes((Join-Path $swappedRoot 'verification-inputs\input.json'),
        [Text.Encoding]::UTF8.GetBytes('a different input entirely'))
    $swappedCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $swappedRoot -Argv $verifyingArgv
    Assert-Census (-not [bool]$swappedCensus.authenticated) `
        'A preview standing on an input that had been replaced was accepted.'
    Assert-Census (($swappedCensus.authenticationObjections -join ' ') -match 'has since been replaced') `
        'The swapped-input objection did not say what had happened.'
    # And an input that is simply gone is unknown, not innocent.
    Remove-Item -LiteralPath (Join-Path $swappedRoot 'verification-inputs\input.json') -Force
    $lostInputCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $swappedRoot -Argv $verifyingArgv
    Assert-Census (-not [bool]$lostInputCensus.authenticated) `
        'A preview standing on an input that is no longer present was accepted.'

    # A preview whose file name differs only in case is a different row in an
    # attestation even where the file system disagrees. On a case-insensitive
    # volume the rename replaces the attested name, so the attested row goes
    # missing; on a case-sensitive one it is an addition. Both are objections.
    $caseRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'auth\case-variant') `
        -Cluster @(@{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })
    $casePreview = Join-Path $caseRoot 'verification-previews\preview-001.json'
    $caseBytes = [IO.File]::ReadAllBytes($casePreview)
    Remove-Item -LiteralPath $casePreview -Force
    [IO.File]::WriteAllBytes((Join-Path $caseRoot 'verification-previews\PREVIEW-001.JSON'), $caseBytes)
    $caseCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $caseRoot -Argv $verifyingArgv
    Assert-Census (-not [bool]$caseCensus.authenticated) `
        'A preview renamed to a case variant of its attested name was accepted as that name.'

    # The forgery the manifest itself invites: rewrite the body and leave the
    # signature, or re-sign under a key of the forger's own choosing. Neither
    # verifies, and a manifest whose envelope is mangled is a refusal rather
    # than an absence.
    $tamperedManifestRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'auth\tampered-manifest') -GeneralistAttempts 1
    $manifestPath = Join-Path $tamperedManifestRoot 'model-start-census.manifest.json'
    $envelopeObject = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -Depth 16
    $bodyObject = [string]$envelopeObject.manifestJson | ConvertFrom-Json -Depth 16
    $bodyObject.logSha256 = ('f' * 64)
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject ([ordered]@{
                    manifestJson = [string](ConvertTo-Json -InputObject $bodyObject -Depth 16 -Compress)
                    signature = [string]$envelopeObject.signature
                    signatureAlg = 'HMACSHA256'
                }) -Depth 8 -Compress:$false), [Text.UTF8Encoding]::new($false))
    $tamperedCensus = Get-ReviewerModelStartCensus -RunRoot $tamperedManifestRoot -Argv $quietArgv
    Assert-Census (-not [bool]$tamperedCensus.authenticated) 'A census manifest body was rewritten under its old signature.'
    Assert-Census ([string]$tamperedCensus.authenticationBasis -ceq 'censusManifestRejected') `
        "A tampered manifest reported basis '$($tamperedCensus.authenticationBasis)'."

    # OLD ARTIFACTS. Every run sealed before this existed has no manifest. It is
    # reported for exactly what it is - unverifiable - and it blocks. It is not
    # rejected as corrupt, and it is emphatically not trusted.
    $legacyAuthRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'auth\legacy') -GeneralistAttempts 3 `
        -SealCensusManifest $false
    $legacyAuthCensus = Get-ReviewerModelStartCensus -RunRoot $legacyAuthRoot -Argv $quietArgv
    Assert-Census ([string]$legacyAuthCensus.authenticationBasis -ceq 'noCensusManifest') `
        "A run with no census manifest reported basis '$($legacyAuthCensus.authenticationBasis)'."
    Assert-Census (-not [bool]$legacyAuthCensus.complete) 'A run with no census manifest was silently trusted.'
    Assert-Census ([int]$legacyAuthCensus.realModelStarts -eq 3) `
        "A blocked legacy run was counted at $($legacyAuthCensus.realModelStarts) rather than 3."
    # 'report' publishes the same verdict without letting it decide completeness,
    # so a survey of historical runs can say how many are unverifiable instead of
    # failing to load at all. It never claims they are authentic.
    $legacyReport = Get-ReviewerModelStartCensus -RunRoot $legacyAuthRoot -Argv $quietArgv -AuthenticationMode 'report'
    Assert-Census ([bool]$legacyReport.complete) 'Report mode blocked a legacy run instead of reporting it.'
    Assert-Census (-not [bool]$legacyReport.authenticated) 'Report mode called a legacy run authentic.'

    # ZERO-CANDIDATE COMPLETE PROOF. A run authorized to verify that legitimately
    # had nothing to verify seals a manifest attesting to an empty preview
    # inventory. That is a proof of zero, and it is the one zero the census is
    # allowed to call complete.
    $zeroRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'auth\zero-candidate') -GeneralistAttempts 1 `
        -VerifierNonce @() -WritePreviewFile $false
    $zeroAssignments = Get-ReviewerVerifierAssignmentCensus -RunRoot $zeroRoot -Argv $quietArgv
    Assert-Census ([bool]$zeroAssignments.authenticated) `
        "A run that attested to an empty preview inventory read as unauthenticated ($($zeroAssignments.authenticationBasis))."
    Assert-Census ([int]$zeroAssignments.realVerifierAssignments -eq 0) `
        'A run with no previews reported assignments.'
    Assert-Census ([bool]$zeroAssignments.complete) `
        'A proven zero was not accounted as a complete zero.'
    # And dropping a preview into that run root afterwards is an addition against
    # an attested EMPTY inventory, which is the case an inventory of names alone
    # would miss entirely.
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $zeroRoot 'verification-previews'))
    Copy-Item -LiteralPath (Join-Path $addedRoot 'verification-previews\preview-001.json') `
        -Destination (Join-Path $zeroRoot 'verification-previews\preview-001.json')
    $zeroPoisoned = Get-ReviewerVerifierAssignmentCensus -RunRoot $zeroRoot -Argv $quietArgv `
        -AuthenticationMode 'report'
    Assert-Census (-not [bool]$zeroPoisoned.authenticated) `
        'A preview dropped into a run that attested to having none was accepted.'

    # -----------------------------------------------------------------------
    # A SIGNATURE IS ONLY WORTH THE KEY THAT MADE IT. The three cases below are
    # the ones where every digest matches, every inventory agrees and the
    # signature verifies - and the manifest still proves nothing about this run.
    # Each was reachable before these checks existed, and each produces an
    # UNDERCOUNT that carries a valid signature, which is strictly worse than an
    # unsigned one because it reads as proof.
    # -----------------------------------------------------------------------

    # 1. THE KEY FOUND NEXT TO THE EVIDENCE. Anything that can rewrite a run's
    # log can also write a key file beside it and re-sign over its own edits.
    # A verifier that picks that key up is checking the forger's arithmetic.
    $selfKeyRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'auth\self-sourced-key') -GeneralistAttempts 2 `
        -SealCensusManifest $false
    $forgedKey = [byte[]]@(1..32)
    # Sealed under the SAME execution the fixture's records name, so the only
    # thing wrong with this manifest is the key it was signed with. A mismatched
    # execution here would add a second objection and this case would stop being
    # about self-attested keys at all.
    [string]$selfKeyExecution = [string](@(Get-ReviewerModelStartLogRecord -LogPath (
                Join-Path $selfKeyRoot 'logs\reviewer.log.jsonl')) |
        Where-Object { $_.PSObject.Properties['session'] } |
        Select-Object -First 1).session.sessionId
    Save-ReviewerModelStartCensusManifest -RunRoot $selfKeyRoot -MasterKey $forgedKey `
        -RunExecutionId $selfKeyExecution `
        -Records @(Get-ReviewerModelStartLogRecord -LogPath (Join-Path $selfKeyRoot 'logs\reviewer.log.jsonl')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $selfKeyRoot 'artifact-signing.key'),
        'raw:' + [Convert]::ToBase64String($forgedKey))
    $selfKeyCensus = Get-ReviewerModelStartCensus -RunRoot $selfKeyRoot -Argv $quietArgv -MasterKey $null
    Assert-Census (-not [bool]$selfKeyCensus.authenticated) `
        ('A manifest signed with a key taken from the run root it attests to was reported as authenticated ' +
        "(basis '$($selfKeyCensus.authenticationBasis)').")
    Assert-Census ([string]$selfKeyCensus.authenticationBasis -ceq 'selfAttestedCensusKey') `
        "A self-sourced key reported basis '$($selfKeyCensus.authenticationBasis)' rather than naming what it is."
    Assert-Census (-not [bool]$selfKeyCensus.complete) 'A self-attested run was accounted complete.'
    # And the count itself is untouched, because blocking is the safe direction
    # and discounting never is.
    Assert-Census ([int]$selfKeyCensus.realModelStarts -eq 2) `
        "A blocked census reported $($selfKeyCensus.realModelStarts) start(s) rather than the 2 its log shows."

    # 2. THE MANIFEST BORROWED FROM A CHEAPER RUN. Every run of one operator
    # seals under the same master key, so without a run identity in the signed
    # body a correctly signed manifest travels with its evidence and reports the
    # other run's smaller number here.
    $cheapRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'auth\replay-source') -GeneralistAttempts 1
    $costlyRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'auth\replay-target') -GeneralistAttempts 1
    Copy-Item -LiteralPath (Join-Path $cheapRoot 'model-start-census.manifest.json') `
        -Destination (Join-Path $costlyRoot 'model-start-census.manifest.json') -Force
    Copy-Item -LiteralPath (Join-Path $cheapRoot 'logs\reviewer.log.jsonl') `
        -Destination (Join-Path $costlyRoot 'logs\reviewer.log.jsonl') -Force
    $replayedCensus = Get-ReviewerModelStartCensus -RunRoot $costlyRoot -Argv $quietArgv
    Assert-Census (-not [bool]$replayedCensus.authenticated) `
        ('A correctly signed census manifest sealed over a different run root verified here, so accounting is ' +
        'transferable between runs.')
    Assert-Census ((@($replayedCensus.authenticationObjections) -match 'different run root').Count -gt 0) `
        'The replayed manifest was refused without saying that it belongs to another run.'

    # 3. THE INPUT THAT LIVES SOMEWHERE ELSE. A preview names its own input, and
    # a preview is a file an attacker may have written, so an unconstrained path
    # lets the rehash be satisfied by any file on the machine carrying the
    # expected digest - including one the attacker placed outside the run root
    # precisely so that nothing auditing the run root would notice it.
    $escapeRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'auth\input-escape') `
        -Cluster @(@{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') }) -SealCensusManifest $false
    $outsideDirectory = Join-Path $sandbox 'auth\outside-the-run'
    [void](New-Item -ItemType Directory -Force -Path $outsideDirectory)
    $outsideInput = Join-Path $outsideDirectory 'input.json'
    Copy-Item -LiteralPath (Join-Path $escapeRoot 'verification-inputs\input.json') -Destination $outsideInput -Force
    $escapePreviewPath = @(Get-ChildItem -LiteralPath (Join-Path $escapeRoot 'verification-previews') -File)[0].FullName
    $escapeEnvelope = [IO.File]::ReadAllText($escapePreviewPath) | ConvertFrom-Json -Depth 32
    $escapeBody = [string]$escapeEnvelope.manifestJson | ConvertFrom-Json -Depth 32
    $escapeBody.inputArtifactPath = $outsideInput
    [IO.File]::WriteAllText($escapePreviewPath, (ConvertTo-Json -InputObject ([ordered]@{
                    manifestJson = [string](ConvertTo-Json -InputObject $escapeBody -Depth 32 -Compress)
                    signature    = [string]$escapeEnvelope.signature
                    signatureAlg = 'HMACSHA256'
                }) -Depth 8 -Compress:$false), [Text.UTF8Encoding]::new($false))
    # Sealed AFTER the edit, so the preview's own digest matches and the ONLY
    # thing left to object to is where the input lives. A fixture sealed before
    # the edit would be refused for the preview's digest and would never reach
    # the containment check at all.
    Add-CensusSeal -Root $escapeRoot
    # The input is removed from inside the run root, so the rebasing fallback
    # cannot quietly rescue the check and make the assertion vacuous.
    Remove-Item -LiteralPath (Join-Path $escapeRoot 'verification-inputs\input.json') -Force
    $escapeCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $escapeRoot -Argv $verifyingArgv
    Assert-Census (-not [bool]$escapeCensus.authenticated) `
        'A preview standing on an input artifact outside the run root was accepted as proof of this run.'
    # 3b. THE PREVIEW THAT WAS COUNTED IS THE PREVIEW THAT MUST BE VERIFIED. The
    # census parses each preview to count its assignments and then authenticates
    # the previews under the run root. If those are two separate reads, a writer
    # can show a thinner preview to the counting read and put the genuine
    # attested bytes back before the verifying read - and the result is a
    # SIGNED, self-consistent undercount, which is the one outcome this census
    # exists to make impossible.
    #
    # Driven through the authenticity function directly with the bytes a count
    # claims to have read, rather than by racing a background writer, because a
    # race would only sometimes land in the window and a check that sometimes
    # proves nothing is not a check.
    $twoReadRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'auth\counted-not-verified') `
        -Cluster @(@{ Candidates = 2; Models = @('verifier-alpha'); Nonce = @('n1') })
    $twoReadName = @(Get-ChildItem -LiteralPath (Join-Path $twoReadRoot 'verification-previews') -File)[0].Name
    $twoReadPath = Join-Path (Join-Path $twoReadRoot 'verification-previews') $twoReadName
    # The bytes a tampered counting read would have seen: the same envelope with
    # its assignment list emptied. Never written to disk - the disk keeps the
    # genuine, attested bytes throughout, which is precisely the attack.
    $thinEnvelope = [IO.File]::ReadAllText($twoReadPath) | ConvertFrom-Json -Depth 32
    $thinBody = [string]$thinEnvelope.manifestJson | ConvertFrom-Json -Depth 32
    $thinBody.assignments = @()
    [string]$thinText = ConvertTo-Json -InputObject ([ordered]@{
            manifestJson = [string](ConvertTo-Json -InputObject $thinBody -Depth 32 -Compress)
            signature    = [string]$thinEnvelope.signature
            signatureAlg = 'HMACSHA256'
        }) -Depth 8 -Compress:$false
    $thinSnapshot = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $thinSnapshot[[string]$twoReadName] = [pscustomobject][ordered]@{
        sha256 = [string]([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                    ([Text.UTF8Encoding]::new($false)).GetBytes($thinText)))).ToLowerInvariant()
        text = $thinText
    }
    # The control: with no caller bytes supplied the run root is clean, so a
    # refusal below cannot be blamed on the fixture.
    $twoReadClean = Test-ReviewerModelStartCensusAuthenticity -RunRoot $twoReadRoot `
        -MasterKey $script:CensusTestKey -ExpectedRunExecutionId (Get-CensusFixtureExecutionId -Root $twoReadRoot)
    Assert-Census ([bool]$twoReadClean.authenticated) `
        ("The two-read fixture was refused before any substitution, so the case proves nothing: " +
        "$(@($twoReadClean.objections) -join ' ')")
    $twoReadSubstituted = Test-ReviewerModelStartCensusAuthenticity -RunRoot $twoReadRoot `
        -MasterKey $script:CensusTestKey -ExpectedRunExecutionId (Get-CensusFixtureExecutionId -Root $twoReadRoot) -PreviewSnapshot $thinSnapshot
    Assert-Census (-not [bool]$twoReadSubstituted.authenticated) `
        ('A census that counted one set of preview bytes was allowed to authenticate a different set still on ' +
        'disk, which signs an undercount.')
    Assert-Census ((@($twoReadSubstituted.objections) -match 'does not hash to the digest').Count -gt 0) `
        ('The substituted preview was refused without saying that the bytes read do not match the attested ' +
        "digest: $(@($twoReadSubstituted.objections) -join ' ')")
    # And the counting census itself, taken normally, still authenticates and
    # still counts every assignment - the single-read path is not a refusal path.
    $twoReadCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $twoReadRoot -Argv $verifyingArgv
    Assert-Census ([bool]$twoReadCensus.authenticated -and [int]$twoReadCensus.realVerifierAssignments -eq 2) `
        ("A single-read assignment census reported authenticated=$($twoReadCensus.authenticated) with " +
        "$($twoReadCensus.realVerifierAssignments) assignment(s) rather than an authenticated 2.")
    # 3c. AND THE PREVIEWS THAT WERE COUNTED ARE ALL THE PREVIEWS THERE ARE.
    # Substituting a preview's CONTENT is refused by 3b; hiding a whole preview
    # from the counting enumeration is a different half of the same race. The
    # counting pass and the authenticating inventory are two separate directory
    # reads, so a writer can rename one preview aside for the count and back
    # before the check. Assignment identities are deduplicated ACROSS previews
    # precisely because different previews carry different sets - a resumed phase
    # seals in parts - so a dropped preview drops real assignments, and verifying
    # it from a second read would count it toward previewsVerified and object to
    # nothing at all.
    $hiddenRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'auth\hidden-from-the-count') `
        -Cluster @(@{ Candidates = 2; Models = @('verifier-alpha'); Nonce = @('n1') }) -RepublishPreview $true
    $hiddenDirectory = Join-Path $hiddenRoot 'verification-previews'
    $hiddenNames = @(@(Get-ChildItem -LiteralPath $hiddenDirectory -File | Sort-Object -Property Name) |
            ForEach-Object { [string]$_.Name })
    Assert-Census (@($hiddenNames).Count -eq 2) `
        "The hidden-preview fixture sealed $(@($hiddenNames).Count) preview(s) rather than the 2 the case needs."
    $fullSnapshot = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($hiddenName in $hiddenNames) {
        $hiddenBytes = [IO.File]::ReadAllBytes((Join-Path $hiddenDirectory $hiddenName))
        $fullSnapshot[[string]$hiddenName] = [pscustomobject][ordered]@{
            sha256 = [string]([Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData($hiddenBytes))).ToLowerInvariant()
            text = [string](([Text.UTF8Encoding]::new($false, $true)).GetString($hiddenBytes))
        }
    }
    # The control: the honest count read both previews, so the same fixture and
    # the same code path authenticate. A refusal below therefore cannot be blamed
    # on the fixture or on supplying a snapshot at all.
    $hiddenExecution = Get-CensusFixtureExecutionId -Root $hiddenRoot
    $hiddenControl = Test-ReviewerModelStartCensusAuthenticity -RunRoot $hiddenRoot `
        -MasterKey $script:CensusTestKey -ExpectedRunExecutionId $hiddenExecution -PreviewSnapshot $fullSnapshot
    Assert-Census ([bool]$hiddenControl.authenticated -and [int]$hiddenControl.previewsVerified -eq 2) `
        ("A census that read both previews was refused or verified $($hiddenControl.previewsVerified) of them: " +
        "$(@($hiddenControl.objections) -join ' ')")
    # The attack: the count saw one preview, the disk holds two.
    $partialSnapshot = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $partialSnapshot[[string]@($hiddenNames)[0]] = $fullSnapshot[[string]@($hiddenNames)[0]]
    $hiddenAttack = Test-ReviewerModelStartCensusAuthenticity -RunRoot $hiddenRoot `
        -MasterKey $script:CensusTestKey -ExpectedRunExecutionId $hiddenExecution -PreviewSnapshot $partialSnapshot
    Assert-Census (-not [bool]$hiddenAttack.authenticated) `
        ('A preview hidden from the counting read was authenticated from a second read of the directory, so a ' +
        'census that counted one preview signed a manifest describing two.')
    Assert-Census ((@($hiddenAttack.objections) -match 'was not read by the census').Count -gt 0) `
        ('The hidden preview was refused without saying that the census never read it: ' +
        "$(@($hiddenAttack.objections) -join ' ')")
    Assert-Census ([int]$hiddenAttack.previewsVerified -lt 2) `
        ("A preview the census never read still counted toward previewsVerified " +
        "($($hiddenAttack.previewsVerified)).")
    # 3d. THE SAME DISCIPLINE IN THE OTHER CENSUS. The model-start census counts
    # log records, but it also reads the sealed previews for their launch nonces,
    # and until now it authenticated from a SECOND read of that directory. An
    # independent review called that an inconsistent guarantee rather than a
    # demonstrated undercount - the logged and intended floors bound the number
    # either way - so this closes it and proves the plumbing rather than
    # describing it. Get-ReviewerVerifierLaunchNonce now returns the bytes it
    # counted, and the census hands exactly those to the authenticity check.
    $launchSnapshotRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'auth\launch-nonce-snapshot') `
        -Cluster @(@{ Candidates = 2; Models = @('verifier-alpha'); Nonce = @('s1') }) -RepublishPreview $true
    $launchDirectory = Join-Path $launchSnapshotRoot 'verification-previews'
    $launchNonce = Get-ReviewerVerifierLaunchNonce -RunRoot $launchSnapshotRoot
    $launchOnDisk = @(@(Get-ChildItem -LiteralPath $launchDirectory -Filter '*.json' -File) |
            ForEach-Object { [string]$_.Name })
    Assert-Census ([int]@($launchNonce.previewSnapshot.Keys).Count -eq [int]@($launchOnDisk).Count) `
        ("The launch-nonce read returned $([int]@($launchNonce.previewSnapshot.Keys).Count) preview(s) of the " +
        "$([int]@($launchOnDisk).Count) it read, so what it counted is not what it can hand on.")
    foreach ($launchName in $launchOnDisk) {
        $launchDigest = [string]([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                    [IO.File]::ReadAllBytes((Join-Path $launchDirectory $launchName))))).ToLowerInvariant()
        Assert-Census ([string]$launchNonce.previewSnapshot[$launchName].sha256 -ceq $launchDigest) `
            "The launch-nonce snapshot of '$launchName' does not digest to the bytes on disk."
    }
    # The race itself: a preview that appears after the counting read is refused
    # rather than authenticated from the later read of the directory.
    $launchExecution = Get-CensusFixtureExecutionId -Root $launchSnapshotRoot
    $launchControl = Test-ReviewerModelStartCensusAuthenticity -RunRoot $launchSnapshotRoot `
        -MasterKey $script:CensusTestKey -ExpectedRunExecutionId $launchExecution `
        -PreviewSnapshot $launchNonce.previewSnapshot
    Assert-Census ([bool]$launchControl.authenticated) `
        ('The previews the launch-nonce read counted were refused by the check it hands them to: ' +
        "$(@($launchControl.objections) -join ' ')")
    $launchPartial = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $launchPartial[[string]@($launchOnDisk)[0]] = $launchNonce.previewSnapshot[[string]@($launchOnDisk)[0]]
    $launchAttack = Test-ReviewerModelStartCensusAuthenticity -RunRoot $launchSnapshotRoot `
        -MasterKey $script:CensusTestKey -ExpectedRunExecutionId $launchExecution -PreviewSnapshot $launchPartial
    Assert-Census (-not [bool]$launchAttack.authenticated) `
        'A preview the launch-nonce read never saw was authenticated from a second read of the directory.'
    # 4. THE MANIFEST LEFT BEHIND IN THE SAME DIRECTORY. Run roots are re-used:
    # the next run lands in the same slot, under the same key, and hashes to the
    # same run-root identity. Everything case 2 relies on therefore agrees, and
    # a whole self-consistent evidence set kept from an earlier, cheaper
    # execution in this very directory reads as this run's accounting.
    $sameDirRoot = Join-Path $sandbox 'auth\same-directory-replay'
    [void](New-CensusRunRoot -Root $sameDirRoot -GeneralistAttempts 1 -RunExecutionId ('1' * 32))
    $cheapGeneration = Join-Path $sandbox 'auth\same-directory-cheap-generation'
    Copy-Item -LiteralPath $sameDirRoot -Destination $cheapGeneration -Recurse -Force
    Remove-Item -LiteralPath $sameDirRoot -Recurse -Force
    [void](New-CensusRunRoot -Root $sameDirRoot -GeneralistAttempts 4 -RunExecutionId ('2' * 32))
    # The honest run first, so the check below cannot pass by refusing everything.
    $honestExecution = Get-ReviewerModelStartCensus -RunRoot $sameDirRoot -Argv $quietArgv `
        -ExpectedRunExecutionId ('2' * 32)
    Assert-Census ([bool]$honestExecution.authenticated) `
        ('A run audited against its own execution identity was refused: ' +
        "$(@($honestExecution.authenticationObjections) -join ' ')")
    Assert-Census ([int]$honestExecution.realModelStarts -eq 4) `
        "The honest run reported $($honestExecution.realModelStarts) start(s) rather than the 4 it made."
    # Now the replay: the costly generation's evidence is replaced wholesale by
    # the cheap generation's, in place.
    Remove-Item -LiteralPath $sameDirRoot -Recurse -Force
    Copy-Item -LiteralPath $cheapGeneration -Destination $sameDirRoot -Recurse -Force
    $sameDirReplay = Get-ReviewerModelStartCensus -RunRoot $sameDirRoot -Argv $quietArgv `
        -ExpectedRunExecutionId ('2' * 32)
    Assert-Census (-not [bool]$sameDirReplay.authenticated) `
        ('An earlier execution''s evidence, replayed in the directory it was produced in, was accepted as this ' +
        'execution''s accounting.')
    Assert-Census ((@($sameDirReplay.authenticationObjections) -match 'execution this').Count -gt 0) `
        'The same-directory replay was refused without naming the execution identity as the reason.'
    Assert-Census (-not [bool]$sameDirReplay.complete) 'A same-directory replay was accounted complete.'
    # Blocking still never rewrites the counts: what the replayed log shows is
    # reported as-is, and only its right to be called this run's is withdrawn.
    Assert-Census ([int]$sameDirReplay.realModelStarts -eq 1) `
        "A blocked replay reported $($sameDirReplay.realModelStarts) start(s) rather than the 1 its log shows."
    # And the honest reason this check has to be external: with no expectation
    # handed in, the copied set is internally consistent and the census has
    # nothing left to catch it with. Asserted rather than glossed over, so the
    # limit of the weaker witness is a stated property of the design. The
    # production caller no longer relies on that weaker witness alone - the
    # coordinator child mints an execution expectation outside the run root and
    # hands it in (Test-ShadowRunExecutionNonce.ps1) - but the weaker witness is
    # still what a hand-launched run is audited under, so its limit is measured
    # here rather than assumed away.
    $sameDirUnaudited = Get-ReviewerModelStartCensus -RunRoot $sameDirRoot -Argv $quietArgv
    Assert-Census ([bool]$sameDirUnaudited.authenticated) `
        ('A census run without an expected execution identity changed its verdict on a self-consistent evidence ' +
        'set, which means this assertion is no longer describing what it was written to describe.')
    # 4b. WHAT THE WEAKER WITNESS DOES CATCH, and why it is worth having in the
    # caller that cannot know the execution it is auditing. The realistic replay
    # is not a wholesale directory swap - it is a STALE MANIFEST left beside the
    # log the current execution really did write, because the manifest is the
    # cheap thing to keep and the log is the thing the run overwrites. The
    # records then name one execution and the manifest another, and the census
    # says so without ever being handed an expectation from outside.
    #
    # Sealed IN PLACE under the earlier execution rather than copied in from
    # another directory. A copied manifest disagrees about the run root, the log
    # digest and the record inventory as well, so every assertion below would be
    # satisfied by checks that already existed and this case would prove nothing
    # about the witness it was written for. Sealing here leaves the execution
    # stamp as the ONLY disagreement.
    $staleRoot = Join-Path $sandbox 'auth\stale-manifest-live-log'
    [void](New-CensusRunRoot -Root $staleRoot -GeneralistAttempts 4 -RunExecutionId ('3' * 32))
    Add-CensusSeal -Root $staleRoot -RunExecutionId ('4' * 32)
    $staleCensus = Get-ReviewerModelStartCensus -RunRoot $staleRoot -Argv $quietArgv
    Assert-Census (-not [bool]$staleCensus.authenticated) `
        ('A manifest sealed by an earlier execution, left beside the log this execution wrote, was accepted with ' +
        'no external expectation at all.')
    Assert-Census ((@($staleCensus.authenticationObjections) -match 'wrote none of').Count -gt 0) `
        ('The stale manifest was refused for some reason other than the execution stamp, so this case is not ' +
        "measuring the record witness: $(@($staleCensus.authenticationObjections) -join ' ')")
    Assert-Census ((@($staleCensus.authenticationObjections) -match 'different run root').Count -eq 0) `
        'The stale-manifest fixture disagreed about its run root, so the execution stamp was not the only difference.'
    Assert-Census (-not [bool]$staleCensus.complete) 'A stale-manifest run was accounted complete.'
    Assert-Census ([int]$staleCensus.realModelStarts -eq 4) `
        "A blocked stale-manifest run reported $($staleCensus.realModelStarts) start(s) rather than the 4 its log shows."
    # 4c. NO WITNESS AT ALL. The record witness is only a witness while there are
    # records naming an execution. A run root whose log says nothing about who
    # wrote it must be refused, not quietly accepted the way an unchecked census
    # would accept it - otherwise deleting the log would be the cheapest way to
    # make a replay authentic.
    $mutePath = Join-Path (Join-Path $staleRoot 'logs') 'reviewer.log.jsonl'
    [string[]]$muteLines = @([IO.File]::ReadAllLines($mutePath) | Where-Object { ([string]$_).Trim().Length -gt 0 })
    [string[]]$muted = @($muteLines | ForEach-Object {
            $record = $_ | ConvertFrom-Json -Depth 32
            if ($record.PSObject.Properties['session']) { $record.PSObject.Properties.Remove('session') }
            ConvertTo-Json -InputObject $record -Depth 32 -Compress
        })
    [IO.File]::WriteAllBytes($mutePath, ([Text.UTF8Encoding]::new($false)).GetBytes(($muted -join "`n") + "`n"))
    Add-CensusSeal -Root $staleRoot -RunExecutionId ('3' * 32)
    $muteCensus = Get-ReviewerModelStartCensus -RunRoot $staleRoot -Argv $quietArgv
    Assert-Census (-not [bool]$muteCensus.authenticated) `
        ('A run root whose records name no execution was authenticated against the record witness, so a census ' +
        'can be made to pass by stripping the very field it corroborates against.')
    Assert-Census ((@($muteCensus.authenticationObjections) -match 'witness nothing').Count -gt 0) `
        'A census with no execution witness was refused without saying that the log could witness nothing.'
    # 4d. A CALLER MUST CHOOSE. Neither witness named is a programming error, not
    # a quiet acceptance: the old, replayable behaviour must not be reachable by
    # leaving a parameter off.
    $unwitnessed = Get-CensusRefusal {
        Get-ReviewerModelStartCensus -RunRoot $staleRoot -Argv $quietArgv -CorroborateExecutionFromRecords:$false
    }
    Assert-Census ($unwitnessed -match 'cannot be authenticated without saying which execution') `
        "A census with no witness named at all was taken rather than refused: $unwitnessed"
    $unwitnessedAssignmentRoot = New-CensusAssignmentRoot -Root (Join-Path $sandbox 'auth\unwitnessed-assignment') `
        -Cluster @(@{ Candidates = 1; Models = @('verifier-alpha'); Nonce = @('n1') })
    $unwitnessedAssignment = Get-CensusRefusal {
        Get-ReviewerVerifierAssignmentCensus -RunRoot $unwitnessedAssignmentRoot -Argv $verifyingArgv `
            -CorroborateExecutionFromRecords:$false
    }
    Assert-Census ($unwitnessedAssignment -match 'cannot be authenticated without saying which execution') `
        "An assignment census with no witness named at all was taken rather than refused: $unwitnessedAssignment"

    # 5. THE MANIFEST FROM BEFORE EXECUTION IDENTITY EXISTED. A v1 manifest is
    # correctly signed and internally consistent; it simply cannot say which
    # execution sealed it. It must fail closed rather than be read as a v2
    # manifest that happens to be missing the field.
    $legacyRoot = New-CensusRunRoot -Root (Join-Path $sandbox 'auth\legacy-manifest') -GeneralistAttempts 2
    $legacyManifestPath = Join-Path $legacyRoot 'model-start-census.manifest.json'
    $legacyEnvelope = [IO.File]::ReadAllText($legacyManifestPath) | ConvertFrom-Json -Depth 32
    $legacyBody = [string]$legacyEnvelope.manifestJson | ConvertFrom-Json -Depth 32
    $legacyBody.manifestVersion = 1
    $legacyBody.PSObject.Properties.Remove('runExecutionId')
    [string]$legacyBodyJson = ConvertTo-Json -InputObject $legacyBody -Depth 32 -Compress
    $legacyMac = [Security.Cryptography.HMACSHA256]::new($script:CensusTestKey)
    try {
        [string]$legacySignature = [BitConverter]::ToString(
            $legacyMac.ComputeHash(([Text.UTF8Encoding]::new($false)).GetBytes($legacyBodyJson))).Replace('-', '').ToLowerInvariant()
    }
    finally { $legacyMac.Dispose() }
    [IO.File]::WriteAllText($legacyManifestPath, (ConvertTo-Json -InputObject ([ordered]@{
                    kind = 'reviewer.model-start-census.manifest.v1'
                    manifestJson = $legacyBodyJson
                    signature = $legacySignature
                    signatureAlg = 'HMACSHA256'
                }) -Depth 8 -Compress:$false), [Text.UTF8Encoding]::new($false))
    $legacyCensus = Get-ReviewerModelStartCensus -RunRoot $legacyRoot -Argv $quietArgv -MasterKey $script:CensusTestKey
    Assert-Census (-not [bool]$legacyCensus.authenticated) `
        'A validly signed manifest from before execution identity existed was accepted as proof of a run.'
    Assert-Census ([int]$legacyCensus.realModelStarts -eq 2) `
        "A blocked legacy manifest reported $($legacyCensus.realModelStarts) start(s) rather than the 2 its log shows."

    # 6. THE SEAL MUST HAPPEN UNDER THE LOCK. The reviewer digests its own log
    # and previews to seal the manifest; if it does that after releasing the
    # agent lock, the next generation is free to start writing those same files
    # mid-digest and the attestation covers a mixture of two runs. The ordering
    # is a property of the script's terminating handler, so it is asserted
    # against the script's syntax tree rather than by racing two reviewers.
    $reviewerAst = [Management.Automation.Language.Parser]::ParseFile($reviewerScript, [ref]$null, [ref]$null)
    $sealCall = @($reviewerAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                [string]$node.GetCommandName() -ceq 'Save-ReviewerModelStartCensusManifest'
            }, $true))
    Assert-Census (@($sealCall).Count -eq 1) `
        "The reviewer seals the census manifest at $(@($sealCall).Count) site(s); this check assumes exactly one."
    if (@($sealCall).Count -eq 1) {
        # The property being asserted is structural, not positional: SOME try
        # statement must have the seal in its body and the lock release in its
        # finally. That is what makes the release happen after the seal on every
        # path, including the ones where the seal throws.
        [int]$sealStart = [int]$sealCall[0].Extent.StartOffset
        [int]$sealEnd = [int]$sealCall[0].Extent.EndOffset
        $guardingTry = @($reviewerAst.FindAll({
                    param($node)
                    if (-not ($node -is [Management.Automation.Language.TryStatementAst])) { return $false }
                    if (-not $node.Finally) { return $false }
                    if ([int]$node.Body.Extent.StartOffset -ge $sealStart) { return $false }
                    if ([int]$node.Body.Extent.EndOffset -le $sealEnd) { return $false }
                    return (@($node.Finally.FindAll({
                                    param($inner)
                                    $inner -is [Management.Automation.Language.CommandAst] -and
                                    [string]$inner.GetCommandName() -ceq 'Exit-AgentLock'
                                }, $true)).Count -gt 0)
                }, $true))
        Assert-Census (@($guardingTry).Count -gt 0) `
            ('The reviewer does not release the agent lock in the finally of a block that contains the census seal, ' +
            'so a second generation can write into the run root while its evidence is being digested.')
        # And no lock release may run BEFORE the seal inside that guarding block,
        # which is exactly the shape the defect had: release first, seal second.
        if (@($guardingTry).Count -gt 0) {
            $earlyRelease = @($guardingTry[0].Body.FindAll({
                        param($inner)
                        $inner -is [Management.Automation.Language.CommandAst] -and
                        [string]$inner.GetCommandName() -ceq 'Exit-AgentLock' -and
                        [int]$inner.Extent.StartOffset -lt $sealStart
                    }, $true))
            Assert-Census (@($earlyRelease).Count -eq 0) `
                'The agent lock is released before the census seal inside the very block that is meant to guard it.'
        }
    }
}
finally {
    if (-not $KeepSandbox -and (Test-Path -LiteralPath $sandbox)) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($script:Failures.Count -gt 0) {
    Write-Host "Model start census: $($script:Failures.Count) failure(s) across $($script:Checks) check(s)." -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "Model start census: $($script:Checks) check(s) passed." -ForegroundColor Green
exit 0
