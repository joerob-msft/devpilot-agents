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

.PARAMETER KeepSandbox
    Leave the sandbox in place for inspection after the run.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$Pilot02Root = '',
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
        [bool]$WriteLog = $true
    )
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $Root 'logs'))
    $lines = [System.Collections.Generic.List[string]]::new()
    # A real cycle log is mostly records this census ignores. Including some is
    # not decoration: a census that counted lines rather than modes would pass a
    # log made only of the records it looks for.
    [void]$lines.Add((ConvertTo-Json -InputObject ([ordered]@{ mode = 'cycle-start'; cycle = 1 }) -Depth 8 -Compress))
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
        if (-not $WritePreviewFile) { return [string]([IO.Path]::GetFullPath($Root)) }
        $runs = @()
        foreach ($nonce in @($VerifierNonce)) {
            for ($index = 1; $index -le $AssignmentsPerNonce; $index++) {
                $runs += [ordered]@{
                    nonceSha256 = [string]$nonce
                    assignmentOrdinal = $index
                }
            }
        }
        $manifest = ConvertTo-Json -InputObject ([ordered]@{ verifierRuns = @($runs) }) -Depth 8 -Compress
        $envelope = ConvertTo-Json -InputObject ([ordered]@{
                kind = 'reviewer.verification.preview.v1'
                manifestJson = [string]$manifest
                signature = ('0' * 64)
            }) -Depth 8
        [IO.File]::WriteAllBytes(
            (Join-Path $previewDirectory 'preview-001.json'),
            ([Text.UTF8Encoding]::new($false)).GetBytes($envelope))
    }
    return [string]([IO.Path]::GetFullPath($Root))
}

$repo = [string]([IO.Path]::GetFullPath($RepoRoot))
$reviewerScript = Join-Path $repo 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
. (Join-Path $repo 'src\Agents\reviewer\ModelStartCensus.ps1')

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
