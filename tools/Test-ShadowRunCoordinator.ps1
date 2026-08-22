#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Offline suite for the typed shadow run coordinator: a real preparation to
    run-set-ready, restart at every transition, the child fault matrix, and the
    PowerShell rollback differential.

.DESCRIPTION
    Everything here runs offline. No model is launched, no slot is started, and
    nothing is written outside a temporary sandbox.

    The suite deliberately does NOT stub the corpus sealer or the qualification
    tools. The coordinator's entire claim is that it prepares real evidence
    without launching a model, and a suite built on stand-ins would prove only
    that the stand-ins behave.

    Faults are injected by replacing the child ADAPTER in the sandbox build,
    never by teaching the coordinator a test mode. A coordinator with a test mode
    is a coordinator whose tested path is not its shipping path.

.PARAMETER RepoRoot
    The toolkit under test. Defaults to this script's repository.

.PARAMETER KeepSandbox
    Leave the sandbox in place for inspection after the run.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$KeepSandbox
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Checks = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:PwshPath = (Get-Process -Id $PID).Path

function Assert-Coordinator {
    param([Parameter(Mandatory)][AllowNull()]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:Checks++
    if (-not $Condition) {
        [void]$script:Failures.Add($Message)
        Write-Host "  FAIL - $Message" -ForegroundColor Red
    }
}

function Get-CoordinatorState {
    param([Parameter(Mandatory)][string]$OutputRoot)
    $path = Join-Path $OutputRoot 'coordinator\state.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 24)
}

function Invoke-Coordinator {
    <#
    .SYNOPSIS
        Runs the coordinator and returns its exit code with its console text.

    .DESCRIPTION
        The console text is captured only so a refusal can be read back in an
        assertion. The coordinator's contracts are files, and this suite reads
        them as files everywhere it checks behaviour.
    #>
    param(
        [Parameter(Mandatory)][string]$RequestPath,
        [string]$HaltAfter,
        [string]$Target
    )
    $argv = [System.Collections.Generic.List[string]]::new()
    [void]$argv.Add($script:CoordinatorDll)
    [void]$argv.Add('--request'); [void]$argv.Add($RequestPath)
    if ($HaltAfter) { [void]$argv.Add('--halt-after'); [void]$argv.Add($HaltAfter) }
    if ($Target) { [void]$argv.Add('--target'); [void]$argv.Add($Target) }
    $previous = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $output = & dotnet @argv 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    finally { $PSNativeCommandUseErrorActionPreference = $previous }
}

function Invoke-CoordinatorRaw {
    <#
    .SYNOPSIS
        Runs the coordinator with arbitrary arguments, for the argument faults a
        well-formed request path cannot reach.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)
    $argv = [System.Collections.Generic.List[string]]::new()
    [void]$argv.Add($script:CoordinatorDll)
    foreach ($argument in $Arguments) { [void]$argv.Add($argument) }
    $previous = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $output = & dotnet @argv 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    finally { $PSNativeCommandUseErrorActionPreference = $previous }
}

function Get-ExchangeResult {
    <#
    .SYNOPSIS
        Reads a child result out of a run's exchange directory by step name.

    .DESCRIPTION
        Each scenario mints its own correlation id, so the file stem is not
        knowable from the fixture; the step suffix is.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Step)
    $found = @(Get-ChildItem -LiteralPath (Join-Path $Root 'coordinator\exchange') -File -Filter "*-$Step.result.json")
    if ($found.Count -ne 1) {
        throw "The exchange directory under '$Root' holds $($found.Count) results for step '$Step'; expected one."
    }
    return (Get-Content -LiteralPath $found[0].FullName -Raw | ConvertFrom-Json -Depth 16)
}

function New-CoordinatorRequestVariant {
    <#
    .SYNOPSIS
        Writes a copy of the request with one section replaced, so a refusal can
        be provoked without rebuilding the sandbox.
    #>
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Mutate,
        [switch]$AsBom,
        [switch]$AsTruncated
    )
    $request = Get-Content -LiteralPath $BasePath -Raw | ConvertFrom-Json -Depth 24
    & $Mutate $request
    # The serializer's output and the string this function may then truncate are
    # kept apart: measuring the length of a raw command result is exactly the
    # flattening hazard the boundary rules exist to prevent.
    $json = ConvertTo-Json -InputObject $request -Depth 24 -Compress:$false
    $text = [string]$json
    if ($AsTruncated) { $text = $text.Substring(0, [Math]::Max(1, [int]($text.Length / 2))) }
    $path = Join-Path (Split-Path $BasePath -Parent) "request-$Name.json"
    $encoding = [System.Text.UTF8Encoding]::new([bool]$AsBom, $true)
    $bytes = $encoding.GetPreamble() + $encoding.GetBytes($text)
    [System.IO.File]::WriteAllBytes($path, $bytes)
    return $path
}

function Set-CoordinatorOutputRoot {
    <#
    .SYNOPSIS
        Points a request at a FRESH output root.

    .DESCRIPTION
        A fresh root per scenario is not tidiness: the coordinator refuses to
        reuse a root whose state disagrees with the request, and a failed
        preparation's root must never be recycled into a passing one.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$Root)
    $Request.output.root = $Root
    # The reconciliation writes under the output root too, and a scenario whose
    # comparison landed in another scenario's directory would be reading a set
    # it never declared.
    if ($Request.PSObject.Properties['slots']) {
        $Request.slots.reconciliation.outputDirectory = [string]([IO.Path]::GetFullPath((Join-Path $Root 'reconciliation')))
        # And so does the delivery decision, when one is declared.
        if ($Request.slots.PSObject.Properties['delivery'] -or
            ($Request.slots -is [hashtable] -and $Request.slots.ContainsKey('delivery'))) {
            $Request.slots.delivery.outputDirectory = [string]([IO.Path]::GetFullPath((Join-Path $Root 'delivery')))
        }
    }
}

function Add-CoordinatorDelivery {
    <#
    .SYNOPSIS
        Declares a preview-only delivery on a request, at creation.

    .DESCRIPTION
        The declaration is written into the request BEFORE the file is sealed, so
        every case that uses it describes a set that was going to end in a
        decision from the moment it was created. There is no path in this suite
        that adds one to a request the coordinator has already read, because
        there is no such path in the coordinator either.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$Root)
    $delivery = [pscustomobject][ordered]@{
        deliveryEnabled = $true
        authorizationKind = 'PreviewOnly'
        outputDirectory = [string]([IO.Path]::GetFullPath((Join-Path $Root 'delivery')))
        requiredRunCount = 2
        launchAuthorizationTokenPath = [string]$Request.slots.reconciliation.launchAuthorizationTokenPath
        supervisionGraceSeconds = [int]$Request.slots.reconciliation.supervisionGraceSeconds
        commentsEnabled = $false
        votesEnabled = $false
        gatesEnabled = $false
        providerWriteBudget = 0
    }
    if ($Request.slots.PSObject.Properties['delivery']) {
        $Request.slots.delivery = $delivery
    }
    else {
        $Request.slots | Add-Member -NotePropertyName delivery -NotePropertyValue $delivery
    }
}

function New-FaultyChildAdapter {
    <#
    .SYNOPSIS
        Replaces the sandbox build's child adapter with one that misbehaves in a
        named way, leaving the coordinator entirely unmodified.
    #>
    param(
        [Parameter(Mandatory)][string]$ToolkitCopy,
        [Parameter(Mandatory)][ValidateSet('nonzero', 'hang', 'missing', 'malformed', 'bom',
            'truncated', 'partial', 'wrongCorrelation', 'stdoutPrologue', 'wrongStep',
            'strayDirectory', 'wrongRequestDigest', 'publishThenDie', 'mutateResult')][string]$Fault,
        [string]$StrayDirectory = '',
        [string]$RealAdapter = '',
        [string]$DieOnStep = 'corpusSeal',
        [string]$MutateStep = '',
        [string]$MutateProperty = '',
        [string]$MutateValue = ''
    )
    $path = Join-Path $ToolkitCopy 'tools\Invoke-ShadowCoordinatorChild.ps1'
    $body = @'
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath)
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$fault = '__FAULT__'
$stray = '__STRAY__'
$real = '__REAL__'
$request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json -Depth 24
$resultPath = [string]$request.resultPath
$correlationId = [string]$request.correlationId
$step = [string]$request.step
$digest = [string]$request.childRequestSha256
if ($fault -eq 'mutateResult') {
    # Everything the reviewed child would do, then a single field of the result
    # rewritten. What the coordinator sees is a genuine, correlated, correctly
    # digested result that disagrees with its own record about one fact.
    & $real -RequestPath $RequestPath
    if ($step -eq '__MUTATESTEP__') {
        $document = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 24
        $document.'__MUTATEPROPERTY__' = '__MUTATEVALUE__'
        $rewritten = (ConvertTo-Json -InputObject $document -Depth 24 -Compress:$false)
        $encoder = [System.Text.UTF8Encoding]::new($false, $true)
        [System.IO.File]::WriteAllBytes($resultPath, $encoder.GetBytes($rewritten))
    }
    exit 0
}
if ($fault -eq 'publishThenDie') {
    # Do the real work, including the durable side effect, then vanish exactly
    # the way a killed child does: no result for the coordinator to commit.
    & $real -RequestPath $RequestPath
    if ($step -eq '__DIESTEP__') {
        Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
        exit 9
    }
    # The real adapter throws on failure, so reaching here means it succeeded and
    # has already written the result the coordinator will read.
    exit 0
}
if ($fault -eq 'nonzero') { Write-Host 'child refuses'; exit 7 }
if ($fault -eq 'hang') { Start-Sleep -Seconds 600; exit 0 }
if ($fault -eq 'missing') { exit 0 }
$utf8 = [System.Text.UTF8Encoding]::new(($fault -eq 'bom'), $true)
if ($fault -eq 'wrongCorrelation') { $correlationId = 'shadow-not-this-run' }
if ($fault -eq 'wrongStep') { $step = 'someOtherStep' }
if ($fault -eq 'wrongRequestDigest') { $digest = ('0' * 64) }
$payload = [ordered]@{
    contractVersion = 'devpilot.shadow-run-coordinator.child-result.v1'
    kind = 'shadow-run-coordinator-child-result'
    correlationId = $correlationId
    step = $step
    childRequestSha256 = $digest
    ok = $true
}
if ($fault -eq 'strayDirectory') {
    # Twelve well-formed artifacts, published somewhere the request never named.
    [void](New-Item -ItemType Directory -Force -Path $stray)
    $payload['artifactDirectory'] = $stray
    $payload['publishedCount'] = 12
}
$text = ConvertTo-Json -InputObject $payload -Depth 8
if ($fault -eq 'malformed') { $text = '{ this is not json' }
if ($fault -eq 'truncated') { $text = $text.Substring(0, [int]($text.Length / 2)) }
if ($fault -eq 'stdoutPrologue') {
    Write-Output '{"contractVersion":"devpilot.shadow-run-coordinator.child-result.v1","ok":true}'
    Write-Output 'REVIEWER_QUALIFICATION_PRELAUNCH_V1 {}'
}
[void](New-Item -ItemType Directory -Force -Path (Split-Path $resultPath -Parent))
[System.IO.File]::WriteAllBytes($resultPath, ($utf8.GetPreamble() + $utf8.GetBytes($text)))
exit 0
'@
    $rendered = ((((($body -replace '__FAULT__', $Fault) -replace '__STRAY__', ($StrayDirectory -replace '\\', '\\')) `
                    -replace '__REAL__', ($RealAdapter -replace '\\', '\\')) -replace '__DIESTEP__', $DieOnStep) `
            -replace '__MUTATESTEP__', $MutateStep) -replace '__MUTATEPROPERTY__', $MutateProperty
    $rendered = $rendered -replace '__MUTATEVALUE__', $MutateValue
    Set-Content -LiteralPath $path -Encoding utf8NoBOM -Value $rendered
}

function New-SlotStubAdapter {
    <#
    .SYNOPSIS
        Replaces the sandbox build's child adapter with one that performs every
        PREPARATION step for real and synthesizes the slot and reconciliation
        steps.

    .DESCRIPTION
        The one place this suite stands something in, and the reason is that the
        alternative is not a cheaper test but a different test: a real slot runs
        the reviewer, and the reviewer calls models. What is under test here is
        the typed lifecycle - authorization, ordering, durable identity,
        supervision, restart, and the refusals - and every one of those is C#'s
        own. So the preparation steps still run through the reviewed adapter, the
        run set is still really declared and really signed, the launch token is
        still the published one, and only the execution is stood in for.

        The stub's plan is deliberately NOT a real qualification plan. It reports
        a digest of its own, so a scenario that tampered with the plan is a
        scenario the coordinator refuses on its own committed digest rather than
        on anything the qualification tools would have said.

        A fault mode names the slot it applies to. Every other slot behaves, so
        a scenario can put slot2 in a state slot1 never reached and see what the
        set does about it rather than only what a single slot does.

        What the stub never does is invoke a model, and the suite asserts that
        rather than trusting this comment: the verify step reports a census of
        attempt records, and the audit is checked for a zero model count.
    #>
    param(
        [Parameter(Mandatory)][string]$ToolkitCopy,
        [Parameter(Mandatory)][string]$RealAdapter,
        [Parameter(Mandatory)][ValidateSet('complete', 'failed', 'timedOut', 'noTerminal', 'hang',
            'nonzeroNoTerminal', 'wrongSlot', 'wrongSetId', 'contradictoryTimeout',
            'writableTerminal', 'secondAttempt', 'crossSlotTerminal',
            'reconcileNoSummary', 'reconcileWrongSummaryPath', 'reconcileTamperSummary',
            'reconcileHang', 'reconcileNonzeroNoSummary', 'reconcileUnsigned',
            'reconcilePromotable', 'reconcileShortRuns', 'reconcileEmptyCounts',
            'reconcileDuplicateCounts', 'reconcileBadCountName', 'reconcileWrongSetId',
            'reconcileNotReady', 'reconcileAttemptPresent', 'reconcileSwapArtifact',
            'reconcileRewriteReport',
            # The delivery decision. Everything a comparison can go wrong by, and
            # then the four ways a run could claim it wrote something - none of
            # which this coordinator has a transition for.
            'deliveryNoSummary', 'deliveryWrongSummaryPath', 'deliveryTamperSummary',
            'deliveryHang', 'deliveryNonzeroNoSummary', 'deliveryUnsigned',
            'deliveryPromotable', 'deliveryShortRuns', 'deliveryEmptyCounts',
            'deliveryDuplicateCounts', 'deliveryBadCountName', 'deliveryWrongSetId',
            'deliveryNotReady', 'deliveryAttemptPresent', 'deliverySwapDecision',
            'deliveryWrongReconciliation', 'deliveryWrongKind', 'deliveryVerifyWrongKind',
            'deliveryCommentCapability', 'deliveryVoteCapability', 'deliveryGateCapability',
            'deliveryVerifyCommentCapability', 'deliveryPlanPromotable',
            'deliveryPlanProviderWrite', 'deliveryProviderWrite', 'deliveryRunWriteTool',
            'deliveryVerifyProviderWrite', 'deliveryWriteTool',
            'deliveryStatusWithheld', 'deliveryStatusEligible', 'deliveryStatusDegraded')][string]$Mode,
        # The slot a slot-scoped fault mode applies to. Slots other than this one
        # always complete, so a two-slot scenario can isolate the failure.
        [ValidateRange(1, 2)][int]$ModeSlot = 1,
        [int]$SlotTimeoutSeconds = 900,
        [int]$ProgressTimeoutSeconds = 0,
        [int]$PerCallTimeoutSeconds = 300,
        # How long the stub's slot stays alive after publishing its attempt
        # record. A kill-mid-slot test needs a child that is genuinely still
        # running when its coordinator dies, and a slot that finishes in
        # milliseconds would make that a race the suite usually loses.
        [int]$RunDelaySeconds = 0
    )
    $path = Join-Path $ToolkitCopy 'tools\Invoke-ShadowCoordinatorChild.ps1'
    $body = @'
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$mode = '__MODE__'
$modeSlot = __MODESLOT__
$real = '__REAL__'
$slotTimeoutSeconds = __SLOTTIMEOUT__
$progressTimeoutSeconds = __PROGRESSTIMEOUT__
$perCallTimeoutSeconds = __PERCALLTIMEOUT__
$runDelaySeconds = __RUNDELAY__

$request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json -Depth 24
$step = [string]$request.step
$resultPath = [string]$request.resultPath
$correlationId = [string]$request.correlationId
$childRequestSha256 = [string]$request.childRequestSha256

# Preparation is not stood in for. Only the slots, the comparison and the
# delivery decision are.
if (-not ($step.StartsWith('slot') -or $step.StartsWith('reconcile') -or $step.StartsWith('delivery'))) {
    $global:LASTEXITCODE = 0
    & $real -RequestPath $RequestPath
    exit ([int]$global:LASTEXITCODE)
}

function Write-StubResult {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Fields)
    $payload = [ordered]@{
        contractVersion = 'devpilot.shadow-run-coordinator.child-result.v1'
        kind = 'shadow-run-coordinator-child-result'
        correlationId = $correlationId
        step = $step
        childRequestSha256 = $childRequestSha256
        ok = $true
    }
    foreach ($key in @($Fields.Keys)) { $payload[[string]$key] = $Fields[$key] }
    $text = ConvertTo-Json -InputObject $payload -Depth 12 -Compress:$false
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $resultPath -Parent))
    [IO.File]::WriteAllBytes($resultPath, ([Text.UTF8Encoding]::new($false, $true)).GetBytes($text))
}

function Get-StubSha256Text {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = ([Text.UTF8Encoding]::new($false, $true)).GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

$qualificationRoot = [string]$request.qualificationRoot
$stubRoot = Join-Path $qualificationRoot 'stub'

# The run set identity is taken from the coordinator's own committed
# verification result rather than re-derived, because re-deriving it means
# re-verifying a signature this stub has no business re-implementing.
$exchange = Split-Path $resultPath -Parent
$verifyResult = Join-Path $exchange "$correlationId-runSetVerify.result.json"
if (-not (Test-Path -LiteralPath $verifyResult -PathType Leaf)) {
    throw "The stub adapter found no committed run-set verification to take a set identity from."
}
$setId = [string]((Get-Content -LiteralPath $verifyResult -Raw | ConvertFrom-Json -Depth 16).setId)

# Hashed from the PUBLISHED token, not from the one the request presents, so a
# request carrying the wrong token still fails the coordinator's comparison.
$publishedToken = Join-Path (Join-Path $qualificationRoot 'runset') 'launch-authorization.token'
$launchHash = Get-StubSha256Text -Text (([IO.File]::ReadAllText($publishedToken)).Trim())
$planDigest = Get-StubSha256Text -Text "stub-plan|$setId|$mode"

# ---------------------------------------------------------------------------
# The comparison, stood in for.
# ---------------------------------------------------------------------------
if ($step.StartsWith('reconcile')) {
    $outputDirectory = [string]$request.reconciliationOutputDirectory
    $attemptPath = Join-Path $outputDirectory 'reconcile-attempt.json'
    $requiredRunCount = [int]$request.requiredRunCount
    $reconcileSetId = $(if ($mode -eq 'reconcileWrongSetId') { 'not-this-run-set' } else { $setId })

    if ($step -eq 'reconcilePlan' -or $step -eq 'reconcilePrelaunch') {
        $artifacts = 0
        foreach ($ordinal in 1..$requiredRunCount) {
            if (Test-Path -LiteralPath (Join-Path $stubRoot "slot$ordinal-terminal.json") -PathType Leaf) { $artifacts++ }
        }
        Write-StubResult -Fields ([ordered]@{
                setId = $reconcileSetId
                planDigest = $planDigest
                requiredRunCount = $requiredRunCount
                artifactCount = $artifacts
                outputDirectory = $outputDirectory
                reconciliationAttemptExists = [bool]((Test-Path -LiteralPath $attemptPath) -or ($mode -eq 'reconcileAttemptPresent'))
                reconciliationReady = [bool]($mode -ne 'reconcileNotReady')
                slotTimeoutSeconds = $(if ($mode -eq 'reconcileHang') { 1 } else { $slotTimeoutSeconds })
                progressTimeoutSeconds = $progressTimeoutSeconds
                perCallTimeoutSeconds = $(if ($mode -eq 'reconcileHang') { 1 } else { $perCallTimeoutSeconds })
                head = [string](& git -C ([string]$request.toolkitRoot) rev-parse HEAD).Trim()
                requiredRef = [string]$request.requiredRef
                headClean = $true
            })
        exit 0
    }

    if ($step -eq 'reconcileRun') {
        $inputPath = [string]$request.reconciliationRequestPath
        if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
            throw "The reconciliation input '$inputPath' does not exist."
        }
        $inputDocument = Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json -Depth 12
        $actualInputSha = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($inputPath))).ToLowerInvariant()
        if ($actualInputSha -cne [string]$request.reconciliationRequestSha256) {
            throw "The reconciliation input at '$inputPath' is not the document the caller committed."
        }
        [void](New-Item -ItemType Directory -Force -Path $outputDirectory)
        # CreateNew, exactly as the reviewed comparison adapter does it: the
        # attempt record is the single-use marker for the whole set.
        $attempt = [IO.File]::Open($attemptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try {
            $attemptBytes = ([Text.UTF8Encoding]::new($false, $true)).GetBytes("{`"setId`":`"$setId`"}")
            $attempt.Write($attemptBytes, 0, $attemptBytes.Length)
        }
        finally { $attempt.Dispose() }

        if ($mode -eq 'reconcileHang') { Start-Sleep -Seconds 600; exit 0 }
        if ($runDelaySeconds -gt 0) {
            # Touched rather than merely slept through, so a supervisor bounded by
            # an activity deadline sees the comparison working rather than idle.
            $deadline = [DateTime]::UtcNow.AddSeconds($runDelaySeconds)
            while ([DateTime]::UtcNow -lt $deadline) {
                [IO.File]::WriteAllText((Join-Path $outputDirectory 'heartbeat.json'),
                    ('{"atUtc":"' + [DateTime]::UtcNow.ToString('o') + '"}'))
                Start-Sleep -Milliseconds 500
            }
        }
        if ($mode -eq 'reconcileNonzeroNoSummary') { exit 9 }
        if ($mode -eq 'reconcileNoSummary') {
            Write-StubResult -Fields ([ordered]@{
                    summaryWritten = $false
                    summaryPath = [string]$inputDocument.summaryPath
                    summarySha256 = ('0' * 64)
                    comparisonExitCode = 0
                    setId = $reconcileSetId
                    planDigest = $planDigest
                    reportPath = (Join-Path $outputDirectory 'no-report.md')
                    reportSha256 = ('0' * 64)
                    artifactPath = (Join-Path $outputDirectory 'no-artifact.json')
                    artifactSha256 = ('0' * 64)
                })
            exit 0
        }

        $summaryPath = [string]$inputDocument.summaryPath
        if ($mode -eq 'reconcileWrongSummaryPath') {
            $summaryPath = Join-Path $outputDirectory 'somewhere-else.json'
        }
        $reportPath = Join-Path $outputDirectory 'reconciliation-stub.md'
        $artifactPath = Join-Path $outputDirectory 'reconciliation-stub.json'
        [IO.File]::WriteAllText($reportPath, "# stub reconciliation`n")
        [IO.File]::WriteAllText($artifactPath, '{"kind":"reviewer.run-reconciliation"}')
        $summary = [ordered]@{
            contractVersion = 'devpilot.shadow-run-coordinator.reconciliation-summary.v1'
            kind = 'shadow-run-coordinator-reconciliation-summary'
            correlationId = $correlationId
            reconciliationRequestSha256 = $actualInputSha
            setId = $reconcileSetId
            planDigest = $planDigest
            requiredRunCount = $requiredRunCount
            comparisonExitCode = 0
            reportPath = $reportPath
            artifactPath = $artifactPath
            generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        $summaryText = ConvertTo-Json -InputObject $summary -Depth 8
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $summaryPath -Parent))
        [IO.File]::WriteAllText($summaryPath, $summaryText, [Text.UTF8Encoding]::new($false))
        $summarySha = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($summaryPath))).ToLowerInvariant()
        if ($mode -eq 'reconcileTamperSummary') {
            # Reported honestly, then changed underneath. The coordinator rehashes
            # the file it was pointed at rather than believing the number.
            [IO.File]::WriteAllText($summaryPath, $summaryText + "`n", [Text.UTF8Encoding]::new($false))
        }
        Write-StubResult -Fields ([ordered]@{
                summaryWritten = $true
                summaryPath = $summaryPath
                summarySha256 = $summarySha
                comparisonExitCode = 0
                setId = $reconcileSetId
                planDigest = $planDigest
                reportPath = $reportPath
                reportSha256 = [Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($reportPath))).ToLowerInvariant()
                artifactPath = $artifactPath
                artifactSha256 = [Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($artifactPath))).ToLowerInvariant()
            })
        exit 0
    }

    if ($step -eq 'reconcileVerify') {
        $summaryPath = [string]$request.summaryPath
        if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
            throw "The reconciliation summary '$summaryPath' does not exist."
        }
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
        $summarySha = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($summaryPath))).ToLowerInvariant()
        $reportPath = [string]$summary.reportPath
        $artifactPath = [string]$summary.artifactPath
        if ($mode -eq 'reconcileSwapArtifact') {
            # A different sealed comparison, verifying perfectly well on its own
            # terms, offered in place of the one this run watched being produced.
            $artifactPath = Join-Path $outputDirectory 'another-reconciliation.json'
            [IO.File]::WriteAllText($artifactPath, '{"kind":"reviewer.run-reconciliation","other":true}')
        }
        if ($mode -eq 'reconcileRewriteReport') {
            # Same path, rewritten between the comparison and the verification.
            [IO.File]::WriteAllText($reportPath, "# stub reconciliation`n# and one more line`n")
        }
        $counts = @(
            [ordered]@{ name = 'runs'; value = $requiredRunCount }
            [ordered]@{ name = 'stableRows'; value = 3 }
            [ordered]@{ name = 'unstableRows'; value = 0 }
        )
        if ($mode -eq 'reconcileEmptyCounts') { $counts = @() }
        if ($mode -eq 'reconcileDuplicateCounts') {
            $counts = @(
                [ordered]@{ name = 'runs'; value = $requiredRunCount }
                [ordered]@{ name = 'runs'; value = 1 }
            )
        }
        if ($mode -eq 'reconcileBadCountName') {
            $counts = @([ordered]@{ name = 'runs-total'; value = $requiredRunCount })
        }
        Write-StubResult -Fields ([ordered]@{
                summarySha256 = $summarySha
                reconciliationStatus = 'reconciled'
                reconciliationSha256 = (Get-StubSha256Text -Text "stub-reconciliation|$setId")
                reportPath = $reportPath
                reportSha256 = [Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($reportPath))).ToLowerInvariant()
                artifactPath = $artifactPath
                artifactSha256 = [Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($artifactPath))).ToLowerInvariant()
                artifactSignatureVerified = [bool]($mode -ne 'reconcileUnsigned')
                artifactPromotable = [bool]($mode -eq 'reconcilePromotable')
                runCount = $(if ($mode -eq 'reconcileShortRuns') { 1 } else { $requiredRunCount })
                requiredRunCount = $requiredRunCount
                setId = $reconcileSetId
                planDigest = $planDigest
                counts = $counts
            })
        exit 0
    }
    throw "'$step' is not a step this stub adapter performs."
}

# ---------------------------------------------------------------------------
# The preview-only delivery decision, stood in for.
# ---------------------------------------------------------------------------
# Four outcomes travel this path - a decision that found nothing, one that let
# nothing through, one that would be eligible in preview, and one built over a
# run the comparison called unusable - and every one of them reports the same
# two zeroes. That is the point of the modes: the coordinator must reach the
# same terminal for all four, because it has no branch on which one it got.
if ($step.StartsWith('delivery')) {
    $deliveryOutput = [string]$request.deliveryOutputDirectory
    $reconcileOutput = [string]$request.reconciliationOutputDirectory
    $attemptPath = Join-Path $deliveryOutput 'delivery-attempt.json'
    $requiredRunCount = [int]$request.requiredRunCount
    $deliverySetId = $(if ($mode -eq 'deliveryWrongSetId') { 'not-this-run-set' } else { $setId })
    # The same value the comparison stub reports, so the coordinator's binding of
    # the decision to the comparison it verified is exercised rather than
    # accidentally satisfied.
    $reconciliationSha = Get-StubSha256Text -Text "stub-reconciliation|$setId"
    if ($mode -eq 'deliveryWrongReconciliation') {
        $reconciliationSha = Get-StubSha256Text -Text "some-other-reconciliation|$setId"
    }
    $reconcileArtifact = Join-Path $reconcileOutput 'reconciliation-stub.json'
    $reconcileArtifactSha = ('0' * 64)
    if (Test-Path -LiteralPath $reconcileArtifact -PathType Leaf) {
        $reconcileArtifactSha = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($reconcileArtifact))).ToLowerInvariant()
    }
    $decisionPath = Join-Path $deliveryOutput 'delivery-decision.json'

    if ($step -eq 'deliveryPlan' -or $step -eq 'deliveryPrelaunch') {
        Write-StubResult -Fields ([ordered]@{
                setId = $deliverySetId
                planDigest = $planDigest
                requiredRunCount = $requiredRunCount
                outputDirectory = $deliveryOutput
                deliveryAttemptExists = [bool]((Test-Path -LiteralPath $attemptPath) -or ($mode -eq 'deliveryAttemptPresent'))
                deliveryReady = [bool]($mode -ne 'deliveryNotReady')
                authorizationKind = $(if ($mode -eq 'deliveryWrongKind') { 'Write' } else { 'PreviewOnly' })
                commentsEnabled = [bool]($mode -eq 'deliveryCommentCapability')
                votesEnabled = [bool]($mode -eq 'deliveryVoteCapability')
                gatesEnabled = [bool]($mode -eq 'deliveryGateCapability')
                promotable = [bool]($mode -eq 'deliveryPlanPromotable')
                providerWriteCount = $(if ($mode -eq 'deliveryPlanProviderWrite') { 1 } else { 0 })
                writeToolInvocations = 0
                reconciliationSha256 = $reconciliationSha
                reconciliationArtifactPath = $reconcileArtifact
                reconciliationArtifactSha256 = $reconcileArtifactSha
                configSha256 = (Get-StubSha256Text -Text "stub-config|$setId")
                policySha256 = (Get-StubSha256Text -Text "stub-policy|$setId")
                slotTimeoutSeconds = $(if ($mode -eq 'deliveryHang') { 1 } else { $slotTimeoutSeconds })
                progressTimeoutSeconds = $progressTimeoutSeconds
                perCallTimeoutSeconds = $(if ($mode -eq 'deliveryHang') { 1 } else { $perCallTimeoutSeconds })
                head = [string](& git -C ([string]$request.toolkitRoot) rev-parse HEAD).Trim()
                requiredRef = [string]$request.requiredRef
                headClean = $true
            })
        exit 0
    }

    if ($step -eq 'deliveryRun') {
        $inputPath = [string]$request.deliveryRequestPath
        if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
            throw "The delivery input '$inputPath' does not exist."
        }
        $inputDocument = Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json -Depth 12
        $actualInputSha = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($inputPath))).ToLowerInvariant()
        if ($actualInputSha -cne [string]$request.deliveryRequestSha256) {
            throw "The delivery input at '$inputPath' is not the document the caller committed."
        }
        # The authorization is read out of the caller's own file, so a stub that
        # ran under anything but preview-only refuses exactly where the real
        # adapter does.
        if ([string]$inputDocument.authorizationKind -cne 'PreviewOnly') {
            throw "The delivery input at '$inputPath' authorizes '$([string]$inputDocument.authorizationKind)'."
        }
        [void](New-Item -ItemType Directory -Force -Path $deliveryOutput)
        $attempt = [IO.File]::Open($attemptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try {
            $attemptBytes = ([Text.UTF8Encoding]::new($false, $true)).GetBytes("{`"setId`":`"$setId`"}")
            $attempt.Write($attemptBytes, 0, $attemptBytes.Length)
        }
        finally { $attempt.Dispose() }

        if ($mode -eq 'deliveryHang') { Start-Sleep -Seconds 600; exit 0 }
        if ($runDelaySeconds -gt 0) {
            $deadline = [DateTime]::UtcNow.AddSeconds($runDelaySeconds)
            while ([DateTime]::UtcNow -lt $deadline) {
                [IO.File]::WriteAllText((Join-Path $deliveryOutput 'heartbeat.json'),
                    ('{"atUtc":"' + [DateTime]::UtcNow.ToString('o') + '"}'))
                Start-Sleep -Milliseconds 500
            }
        }
        if ($mode -eq 'deliveryNonzeroNoSummary') { exit 9 }

        [IO.File]::WriteAllText($decisionPath, '{"kind":"reviewer.gate-decision","stub":true}')
        $decisionSha = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($decisionPath))).ToLowerInvariant()

        if ($mode -eq 'deliveryNoSummary') {
            Write-StubResult -Fields ([ordered]@{
                    summaryWritten = $false
                    summaryPath = [string]$inputDocument.summaryPath
                    summarySha256 = ('0' * 64)
                    evaluationExitCode = 0
                    setId = $deliverySetId
                    planDigest = $planDigest
                    decisionPath = $decisionPath
                    decisionSha256 = $decisionSha
                    providerWriteCount = 0
                    writeToolInvocations = 0
                })
            exit 0
        }

        $summaryPath = [string]$inputDocument.summaryPath
        if ($mode -eq 'deliveryWrongSummaryPath') {
            $summaryPath = Join-Path $deliveryOutput 'somewhere-else.json'
        }
        $summary = [ordered]@{
            contractVersion = 'devpilot.shadow-run-coordinator.delivery-summary.v1'
            kind = 'shadow-run-coordinator-delivery-summary'
            correlationId = $correlationId
            deliveryRequestSha256 = $actualInputSha
            setId = $deliverySetId
            planDigest = $planDigest
            requiredRunCount = $requiredRunCount
            authorizationKind = 'PreviewOnly'
            reconciliationSha256 = $reconciliationSha
            reconciliationArtifactSha256 = $reconcileArtifactSha
            decisionPath = $decisionPath
            evaluationExitCode = 0
            providerWriteCount = 0
            writeToolInvocations = 0
            generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        $summaryText = ConvertTo-Json -InputObject $summary -Depth 8
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $summaryPath -Parent))
        [IO.File]::WriteAllText($summaryPath, $summaryText, [Text.UTF8Encoding]::new($false))
        $summarySha = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($summaryPath))).ToLowerInvariant()
        if ($mode -eq 'deliveryTamperSummary') {
            [IO.File]::WriteAllText($summaryPath, $summaryText + "`n", [Text.UTF8Encoding]::new($false))
        }
        Write-StubResult -Fields ([ordered]@{
                summaryWritten = $true
                summaryPath = $summaryPath
                summarySha256 = $summarySha
                evaluationExitCode = 0
                setId = $deliverySetId
                planDigest = $planDigest
                decisionPath = $decisionPath
                decisionSha256 = $decisionSha
                # The one number a run could report that says something happened.
                providerWriteCount = $(if ($mode -eq 'deliveryProviderWrite') { 1 } else { 0 })
                writeToolInvocations = $(if ($mode -eq 'deliveryRunWriteTool') { 1 } else { 0 })
            })
        exit 0
    }

    if ($step -eq 'deliveryVerify') {
        $summaryPath = [string]$request.summaryPath
        if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
            throw "The delivery summary '$summaryPath' does not exist."
        }
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
        $summarySha = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($summaryPath))).ToLowerInvariant()
        $verifyDecisionPath = [string]$summary.decisionPath
        if ($mode -eq 'deliverySwapDecision') {
            $verifyDecisionPath = Join-Path $deliveryOutput 'another-decision.json'
            [IO.File]::WriteAllText($verifyDecisionPath, '{"kind":"reviewer.gate-decision","other":true}')
        }
        $counts = @(
            [ordered]@{ name = 'runs'; value = $requiredRunCount }
            [ordered]@{ name = 'requiredRuns'; value = $requiredRunCount }
            [ordered]@{ name = 'candidates'; value = 0 }
            [ordered]@{ name = 'unattendedComments'; value = 0 }
        )
        if ($mode -eq 'deliveryEmptyCounts') { $counts = @() }
        if ($mode -eq 'deliveryDuplicateCounts') {
            $counts = @(
                [ordered]@{ name = 'runs'; value = $requiredRunCount }
                [ordered]@{ name = 'runs'; value = 1 }
            )
        }
        if ($mode -eq 'deliveryBadCountName') {
            $counts = @([ordered]@{ name = 'runs-total'; value = $requiredRunCount })
        }
        # Four different words, all of which the coordinator must carry without
        # acting on. The zeroes below do not move between them.
        $status = switch ($mode) {
            'deliveryStatusWithheld' { 'withheld' }
            'deliveryStatusEligible' { 'eligiblePreview' }
            'deliveryStatusDegraded' { 'degraded' }
            default { 'noFindings' }
        }
        Write-StubResult -Fields ([ordered]@{
                summarySha256 = $summarySha
                deliveryStatus = $status
                decisionPath = $verifyDecisionPath
                decisionSha256 = [Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($verifyDecisionPath))).ToLowerInvariant()
                decisionSignatureVerified = [bool]($mode -ne 'deliveryUnsigned')
                decisionPromotable = [bool]($mode -eq 'deliveryPromotable')
                authorizationKind = $(if ($mode -eq 'deliveryVerifyWrongKind') { 'Write' } else { 'PreviewOnly' })
                commentsEnabled = [bool]($mode -eq 'deliveryVerifyCommentCapability')
                votesEnabled = $false
                gatesEnabled = $false
                providerWriteCount = $(if ($mode -eq 'deliveryVerifyProviderWrite') { 1 } else { 0 })
                writeToolInvocations = $(if ($mode -eq 'deliveryWriteTool') { 1 } else { 0 })
                reconciliationSha256 = $reconciliationSha
                runCount = $(if ($mode -eq 'deliveryShortRuns') { 1 } else { $requiredRunCount })
                requiredRunCount = $requiredRunCount
                setId = $deliverySetId
                planDigest = $planDigest
                counts = $counts
            })
        exit 0
    }
    throw "'$step' is not a step this stub adapter performs."
}

# ---------------------------------------------------------------------------
# The slots, stood in for. One state root, attempt record and terminal each.
# ---------------------------------------------------------------------------
if ($step -match '^slot([0-9]+)(Plan|Prelaunch|Run|Verify)\z') {
    $ordinal = [int]$Matches[1]
    $phase = [string]$Matches[2]
}
else {
    throw "'$step' is not a step this stub adapter performs."
}
$slotName = "slot$ordinal"
if ([string]$request.slotName -cne $slotName) {
    throw "Step '$step' acts on '$slotName' and the request names slot '$([string]$request.slotName)'."
}
$stateDir = Join-Path $stubRoot "$slotName-state"
$attemptPath = Join-Path $stubRoot "$slotName-attempt.json"
$terminalPath = Join-Path $stubRoot "$slotName-terminal.json"
# A fault mode belongs to one slot. Every other slot completes, so a scenario
# sees the set's reaction to one bad slot rather than to a broken stub.
$slotMode = $(if ($ordinal -eq $modeSlot -and -not ($mode.StartsWith('reconcile') -or $mode.StartsWith('delivery'))) { $mode } else { 'complete' })

if ($phase -eq 'Plan' -or $phase -eq 'Prelaunch') {
    Write-StubResult -Fields ([ordered]@{
            setId = $setId
            planDigest = $planDigest
            launchAuthorizationHash = $launchHash
            reviewerScriptSha256 = (Get-FileHash -LiteralPath ([string]$request.reviewerScriptPath) -Algorithm SHA256).Hash.ToLowerInvariant()
            slotName = $slotName
            slotStateDir = [string]$stateDir
            slotTerminalPath = [string]$terminalPath
            slotAttemptExists = [bool](Test-Path -LiteralPath $attemptPath)
            slotTerminalExists = [bool](Test-Path -LiteralPath $terminalPath)
            slotTimeoutSeconds = $slotTimeoutSeconds
            progressTimeoutSeconds = $progressTimeoutSeconds
            perCallTimeoutSeconds = $perCallTimeoutSeconds
            head = [string](& git -C ([string]$request.toolkitRoot) rev-parse HEAD).Trim()
            requiredRef = [string]$request.requiredRef
            headClean = $true
            deliveryMode = 'PreviewOnly'
            promotable = $false
        })
    exit 0
}

if ($phase -eq 'Run') {
    [void](New-Item -ItemType Directory -Force -Path $stubRoot)
    [void](New-Item -ItemType Directory -Force -Path $stateDir)
    # CreateNew, exactly as the reviewed slot runner does it: the attempt record
    # is the single-use marker, and a second attempt has to fail on the file
    # system rather than on a check something could skip.
    $attempt = [IO.File]::Open($attemptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try {
        $attemptBytes = ([Text.UTF8Encoding]::new($false, $true)).GetBytes("{`"slot`":`"$slotName`",`"setId`":`"$setId`"}")
        $attempt.Write($attemptBytes, 0, $attemptBytes.Length)
    }
    finally { $attempt.Dispose() }
    if ($slotMode -eq 'secondAttempt') {
        # A second attempt record for this same slot appearing behind the
        # coordinator's back, which is what a hand-run of the PowerShell path
        # alongside it would leave.
        [IO.File]::WriteAllText((Join-Path $stubRoot 'slot9-attempt.json'), '{"slot":"slot9"}')
    }
    if ($slotMode -eq 'hang') { Start-Sleep -Seconds 600; exit 0 }
    if ($runDelaySeconds -gt 0) {
        # Touched rather than merely slept through, so a supervisor bounded by an
        # activity deadline sees the slot working rather than idle.
        $deadline = [DateTime]::UtcNow.AddSeconds($runDelaySeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            [IO.File]::WriteAllText((Join-Path $stateDir 'heartbeat.json'),
                ('{"atUtc":"' + [DateTime]::UtcNow.ToString('o') + '"}'))
            Start-Sleep -Milliseconds 500
        }
    }
    if ($slotMode -eq 'noTerminal') {
        Write-StubResult -Fields ([ordered]@{
                terminalWritten = $false
                terminalPath = [string]$terminalPath
                childExitCode = 0
                slotName = $slotName
                setId = $setId
                planDigest = $planDigest
            })
        exit 0
    }
    if ($slotMode -eq 'nonzeroNoTerminal') { exit 7 }

    $status = switch ($slotMode) {
        'failed' { 'failed' }
        'timedOut' { 'timedOut' }
        default { 'complete' }
    }
    $timedOut = ($status -eq 'timedOut')
    if ($slotMode -eq 'contradictoryTimeout') { $timedOut = $true }
    $terminalSlot = $slotName
    if ($slotMode -eq 'wrongSlot') { $terminalSlot = "slot$(($ordinal % 2) + 1)" }
    if ($slotMode -eq 'crossSlotTerminal') { $terminalSlot = 'slot9' }
    $terminal = [ordered]@{
        kind = 'reviewer.replay-qualification.terminal.v1'
        slot = $terminalSlot
        setId = $(if ($slotMode -eq 'wrongSetId') { 'not-this-run-set' } else { $setId })
        planDigest = $planDigest
        status = $status
        exitCode = $(if ($status -eq 'complete') { 0 } else { 3 })
        timedOut = $timedOut
        childProcessId = $PID
        startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        endedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $terminalText = ConvertTo-Json -InputObject $terminal -Depth 8 -Compress:$false
    [IO.File]::WriteAllBytes($terminalPath, ([Text.UTF8Encoding]::new($false, $true)).GetBytes($terminalText))
    if ($slotMode -ne 'writableTerminal') {
        (Get-Item -LiteralPath $terminalPath).IsReadOnly = $true
    }
    Write-StubResult -Fields ([ordered]@{
            terminalWritten = $true
            terminalPath = [string]$terminalPath
            childExitCode = [int]$terminal.exitCode
            slotName = $slotName
            setId = $setId
            planDigest = $planDigest
        })
    # The reviewed runner propagates the reviewed run's own exit code, so a
    # failed slot exits non-zero with perfectly good evidence. Mirrored here so
    # the coordinator's "exit code is data" claim is actually exercised.
    exit ([int]$terminal.exitCode)
}

if (-not (Test-Path -LiteralPath $terminalPath -PathType Leaf)) {
    throw "Slot '$slotName' has no terminal evidence under '$stubRoot'."
}
$terminal = Get-Content -LiteralPath $terminalPath -Raw | ConvertFrom-Json -Depth 8
$bytes = [IO.File]::ReadAllBytes($terminalPath)
$attempts = @(Get-ChildItem -LiteralPath $stubRoot -Filter 'slot*-attempt.json' -File -ErrorAction SilentlyContinue)
Write-StubResult -Fields ([ordered]@{
        terminalStatus = [string]$terminal.status
        terminalExitCode = [int]$terminal.exitCode
        terminalTimedOut = [bool]$terminal.timedOut
        terminalImmutable = [bool](Get-Item -LiteralPath $terminalPath).IsReadOnly
        terminalSetId = [string]$terminal.setId
        terminalPlanDigest = [string]$terminal.planDigest
        terminalSlot = [string]$terminal.slot
        terminalPath = [string]$terminalPath
        terminalSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        signatureVerified = $true
        inventoryVerified = $true
        slotAttemptCount = [int]$attempts.Count
        slotAttemptRecordCount = [int]$attempts.Count
        realModelStartCount = 0
        realModelStartsGeneralist = 0
        realModelStartsSpecialist = 0
        realModelStartsVerifier = 0
        realModelStartCensusComplete = $true
        realModelStartCensusExact = $true
        realModelStartUnmeasuredAllowance = 0
        realModelStartCensusBasis = 'stubNoModelRun'
        realModelStartCensusDetail = 'stub'
        realVerifierAssignmentCount = 0
        realVerifierAssignmentsByModel = @()
        realVerifierAssignmentCensusComplete = $true
        realVerifierAssignmentUnmeasuredAllowance = 0
        realVerifierAssignmentCensusDetail = 'stub'
        verifierProcessStartCount = 0
        deliveryMode = 'PreviewOnly'
        promotable = $false
    })
exit 0
'@
    $rendered = $body -replace '__MODE__', $Mode
    $rendered = $rendered -replace '__MODESLOT__', [string]$ModeSlot
    $rendered = $rendered -replace '__REAL__', ($RealAdapter -replace '\\', '\\')
    $rendered = $rendered -replace '__SLOTTIMEOUT__', [string]$SlotTimeoutSeconds
    $rendered = $rendered -replace '__PROGRESSTIMEOUT__', [string]$ProgressTimeoutSeconds
    $rendered = $rendered -replace '__PERCALLTIMEOUT__', [string]$PerCallTimeoutSeconds
    $rendered = $rendered -replace '__RUNDELAY__', [string]$RunDelaySeconds
    Set-Content -LiteralPath $path -Encoding utf8NoBOM -Value $rendered
}

function Restore-ChildAdapter {
    param([Parameter(Mandatory)][string]$ToolkitCopy, [Parameter(Mandatory)][string]$RepoRoot)
    Copy-Item -Force (Join-Path $RepoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1') `
        (Join-Path $ToolkitCopy 'tools\Invoke-ShadowCoordinatorChild.ps1')
}

function Initialize-SlotRunSet {
    <#
    .SYNOPSIS
        Carries one slot scenario's output root to a real, signed run-set-ready and
        hands over the launch-authorization token the declaration published.

    .DESCRIPTION
        Preparation is always done by the reviewed adapter in a clean tree, and the
        reason is not tidiness: the reviewed declaration preflight refuses a dirty
        qualification worktree, and standing the adapter in IS a dirty worktree. So
        every slot scenario reaches run-set-ready for real first, and only then is
        the slot's own execution stood in for.
    #>
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RequestPath,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$Label
    )
    Restore-ChildAdapter -ToolkitCopy $Fixture.ToolkitCopy -RepoRoot $RepositoryRoot
    $setup = Invoke-Coordinator -RequestPath $RequestPath -Target 'runSetReady'
    # A setup failure is reported with the child's own stderr, because a bare
    # exit code from a step that ran the real qualification tools names nothing
    # a reader could act on.
    $setupDetail = ''
    $logDirectory = Join-Path $OutputRoot 'coordinator\logs'
    if (Test-Path -LiteralPath $logDirectory -PathType Container) {
        foreach ($childLog in @(Get-ChildItem -LiteralPath $logDirectory -Filter '*.log' -File |
                Where-Object { $_.Length -gt 0 } | Sort-Object -Property LastWriteTimeUtc | Select-Object -Last 4)) {
            $setupDetail += "`n--- $($childLog.Name) ---`n" + [IO.File]::ReadAllText($childLog.FullName)
        }
    }
    Assert-Coordinator ($setup.ExitCode -eq 0) `
        "The $Label setup did not reach run-set-ready (exit $($setup.ExitCode)).`n$($setup.Output)$setupDetail"
    [void](Publish-ShadowCoordinatorLaunchToken `
            -RunSetDirectory (Join-Path $OutputRoot 'qualification\runset') `
            -TokenPath $Fixture.LaunchTokenPath)
}

function Get-DescendantPwshCount {

    <#
    .SYNOPSIS
        Counts PowerShell processes this suite is responsible for, which is how an
        orphaned child would show up.
    .DESCRIPTION
        Scoped by the sandbox token rather than by start time. A start-time window
        counts every unrelated shell that happened to open on a shared machine,
        which turns an orphan check into a report on whatever else the host is
        doing; the sandbox token appears only in a command line this suite
        launched, so what it counts is only ever ours.
    #>
    param([Parameter(Mandatory)][string]$SandboxToken)
    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and [string]$_.CommandLine -like "*$SandboxToken*" })
    return $processes.Count
}

# ---------------------------------------------------------------------------
# Build the coordinator offline, from the repository under test.
# ---------------------------------------------------------------------------
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("shadow-coordinator-" + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Force -Path $sandbox)
$sandboxToken = Split-Path $sandbox -Leaf
# The tree is photographed before anything runs. Asserting a clean tree instead
# would report the operator's own work in progress as damage this suite did,
# which is the one thing the check must never confuse.
$repoStatusBefore = (& git -C $RepoRoot status --porcelain -- 'src' 'docs' 'samples' 2>&1 | Out-String).Trim()

try {
    # GetNewClosure captures variables, not function definitions, so the function
    # every scenario uses to repoint a request is captured once, here, and invoked
    # through the reference. Calling it by name from inside a closure would
    # resolve against whatever scope happens to run the closure later.
    $setOutputRoot = ${function:Set-CoordinatorOutputRoot}
    $addDelivery = ${function:Add-CoordinatorDelivery}

    Write-Host '1/32 offline restore and build' -ForegroundColor Cyan
    $project = Join-Path $RepoRoot 'tools\ShadowRunCoordinator\ShadowRunCoordinator.csproj'
    Assert-Coordinator (Test-Path -LiteralPath $project -PathType Leaf) `
        'The shadow run coordinator project is missing.'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    $offlineSource = Join-Path $sandbox 'nuget-empty'
    $packages = Join-Path $sandbox 'nuget-packages'
    [void](New-Item -ItemType Directory -Force -Path $offlineSource)
    & dotnet restore $project --source $offlineSource --packages $packages -p:NuGetAudit=false `
        --nologo --verbosity quiet | Out-Null
    Assert-Coordinator ($LASTEXITCODE -eq 0) 'The coordinator did not restore from an empty offline feed.'
    & dotnet build $project --configuration Release --no-restore --nologo --verbosity quiet | Out-Null
    Assert-Coordinator ($LASTEXITCODE -eq 0) 'The coordinator did not build offline.'
    $script:CoordinatorDll = Join-Path $RepoRoot 'tools\ShadowRunCoordinator\bin\Release\net10.0\ShadowRunCoordinator.dll'
    Assert-Coordinator (Test-Path -LiteralPath $script:CoordinatorDll -PathType Leaf) `
        'The coordinator assembly was not produced.'

    # -----------------------------------------------------------------------
    Write-Host '2/32 sandbox, sealed corpus and typed request' -ForegroundColor Cyan
    Import-Module (Join-Path $RepoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    . (Join-Path $RepoRoot 'src\Agents\reviewer\SourceTransport.ps1')
    . (Join-Path $RepoRoot 'src\Agents\reviewer\CorpusSeal.ps1')
    . (Join-Path $RepoRoot 'tools\CorpusSealFixture.ps1')
    . (Join-Path $RepoRoot 'tools\ShadowCoordinatorFixture.ps1')

    $fixture = New-ShadowCoordinatorFixture -Sandbox (Join-Path $sandbox 'fixture') -ToolkitRoot $RepoRoot
    Assert-Coordinator (Test-Path -LiteralPath $fixture.RequestPath -PathType Leaf) `
        'The fixture did not write a coordinator request.'
    # The prompt binding is computed in PowerShell here and in C# inside the
    # coordinator. Agreement is a cross-implementation canonicalization check,
    # and a disagreement would surface as a refusal on the very first transition.
    Assert-Coordinator ($fixture.Request.digests.promptSha256 -cmatch '^[0-9a-f]{64}$') `
        'The request does not bind a prompt-asset digest.'

    # -----------------------------------------------------------------------
    Write-Host '3/32 restart at every transition' -ForegroundColor Cyan
    $states = @('requestValidated', 'corpusStaging', 'corpusPublished', 'corpusValidated',
        'recipePlanned', 'snapshotValidateOnly', 'snapshotSealed', 'snapshotVerified',
        'runSetDeclared', 'runSetVerified')
    $expectedSequence = 0
    foreach ($state in $states) {
        $expectedSequence++
        $halted = Invoke-Coordinator -RequestPath $fixture.RequestPath -HaltAfter $state
        Assert-Coordinator ($halted.ExitCode -eq 9) `
            "Halting after '$state' did not report a deliberate halt (exit $($halted.ExitCode))."
        $durable = Get-CoordinatorState -OutputRoot $fixture.OutputRoot
        Assert-Coordinator ($durable -and $durable.state -ceq $state) `
            "The durable state after halting at '$state' is '$(if ($durable) { $durable.state } else { 'none' })'."
        Assert-Coordinator ($durable -and [int]$durable.sequence -eq $expectedSequence) `
            "The sequence after '$state' is $(if ($durable) { $durable.sequence } else { 'none' }), not $expectedSequence."

        # Resuming to the SAME state must do nothing at all: no new sequence, no
        # second child launch. This is the property that makes a kill safe.
        $again = Invoke-Coordinator -RequestPath $fixture.RequestPath -Target $state
        Assert-Coordinator ($again.ExitCode -eq 0) `
            "Resuming to an already-reached '$state' failed (exit $($again.ExitCode))."
        Assert-Coordinator ($again.Output -match "skip $state") `
            "Resuming to an already-reached '$state' did not report it as already recorded."
        $repeat = Get-CoordinatorState -OutputRoot $fixture.OutputRoot
        Assert-Coordinator ([int]$repeat.sequence -eq $expectedSequence) `
            "Resuming to an already-reached '$state' advanced the sequence to $($repeat.sequence)."
    }

    Write-Host '4/32 preparation reaches run-set-ready' -ForegroundColor Cyan
    $final = Invoke-Coordinator -RequestPath $fixture.RequestPath
    Assert-Coordinator ($final.ExitCode -eq 0) "The preparation did not reach run-set-ready (exit $($final.ExitCode)): $($final.Output)"
    $durable = Get-CoordinatorState -OutputRoot $fixture.OutputRoot
    Assert-Coordinator ($durable.state -ceq 'runSetReady' -and [int]$durable.sequence -eq 11) `
        "The durable state is '$($durable.state)' at sequence $($durable.sequence)."
    Assert-Coordinator (@($durable.transitions).Count -eq 11) `
        "The state records $(@($durable.transitions).Count) transitions rather than eleven."

    # This fixture hands the coordinator a corpus that already exists, so the two
    # corpus-construction ranks are recorded as having built nothing. They are
    # recorded rather than skipped, which is what keeps one sequence numbering
    # for both postures.
    $stagingTransition = @($durable.transitions | Where-Object { $_.state -ceq 'corpusStaging' })
    Assert-Coordinator ($stagingTransition.Count -eq 1 -and $stagingTransition[0].evidence.staged -eq $false) `
        'A request without a corpusStage section did not record that it staged nothing.'
    Assert-Coordinator (-not (Test-Path -LiteralPath (Join-Path $fixture.OutputRoot 'coordinator\corpus-stage.journal.json'))) `
        'A request that builds no corpus opened a staging journal.'

    # A completed preparation replayed is a no-op, including the child that
    # cannot be run twice: a second declaration into the same qualification root
    # is refused by the qualification tool itself.
    $replay = Invoke-Coordinator -RequestPath $fixture.RequestPath
    Assert-Coordinator ($replay.ExitCode -eq 0) 'Replaying a completed preparation failed.'
    $afterReplay = Get-CoordinatorState -OutputRoot $fixture.OutputRoot
    Assert-Coordinator ([int]$afterReplay.sequence -eq 11) `
        "Replaying a completed preparation advanced the sequence to $($afterReplay.sequence)."

    # -----------------------------------------------------------------------
    Write-Host '5/32 audit indexes all twelve stage artifacts' -ForegroundColor Cyan
    $auditPath = Join-Path $fixture.OutputRoot 'coordinator\audit.json'
    Assert-Coordinator (Test-Path -LiteralPath $auditPath -PathType Leaf) 'The coordinator wrote no audit.'
    $audit = Get-Content -LiteralPath $auditPath -Raw | ConvertFrom-Json -Depth 32
    Assert-Coordinator ([int]$audit.preparationAttemptRecordCount -eq 0 -and [int]$audit.slotLaunchCount -eq 0) `
        'The audit does not record a preparation that launched nothing.'
    $planned = $audit.stages.recipePlanned
    Assert-Coordinator ([int]$planned.publishedCount -eq 12) `
        "The preparation published $($planned.publishedCount) stage artifacts rather than twelve."
    Assert-Coordinator ([int]$planned.rereadCount -eq 12) `
        "The coordinator re-read $($planned.rereadCount) stage artifacts rather than twelve."
    Assert-Coordinator ([int]$planned.boundaryCount -eq 12) `
        "The producer-contract schema declares $($planned.boundaryCount) boundaries rather than twelve."
    $stages = @(@($planned.artifacts) | ForEach-Object { [string]$_.stage })
    Assert-Coordinator (@($stages | Sort-Object -Unique).Count -eq 12) `
        'The audit does not index twelve distinct stages.'
    foreach ($artifact in @($planned.artifacts)) {
        Assert-Coordinator ([string]$artifact.sha256 -cmatch '^[0-9a-f]{64}$') `
            "Stage artifact '$($artifact.name)' is indexed without a digest."
        Assert-Coordinator ([int]$artifact.envelopeVersion -eq 1) `
            "Stage artifact '$($artifact.name)' is indexed at envelope version $($artifact.envelopeVersion)."
    }
    Assert-Coordinator ([int]$audit.stages.runSetReady.slotAttemptCount -eq 0) `
        'The preparation observed a slot attempt.'

    # -----------------------------------------------------------------------
    Write-Host '6/32 stage publication parity with the PowerShell path' -ForegroundColor Cyan
    # The same stage publication, driven directly through the existing PowerShell
    # entry point instead of through the coordinator's child process. Byte
    # identical artifacts are what makes the rollback switch real at THIS seam:
    # the coordinator changes who calls the producers, not what they publish.
    #
    # Deliberately not called a full rollback differential, because it is not one.
    # It compares stage publication only. It does not re-run request validation,
    # sealing, verification, declaration or readiness through a second
    # orchestrator, so it catches serialization and path-passing drift across the
    # process adapter and nothing beyond that. The residual is recorded in
    # docs/shadow-run-coordinator.md rather than papered over here.
    $rollbackRoot = Join-Path $sandbox 'rollback'
    [void](New-Item -ItemType Directory -Force -Path $rollbackRoot)
    . (Join-Path $RepoRoot 'src\Agents\reviewer\ShadowPreparation.ps1')
    # The census the coordinator planned from, read from the file the request
    # declares rather than restated here, so the two arms cannot silently drift
    # apart on the one input that decides what gets published.
    $censusDocument = [IO.File]::ReadAllText($fixture.ChangedPathsPath) | ConvertFrom-Json -Depth 8
    $preparedPaths = [string[]]@($censusDocument.changedPaths)
    $rollback = Invoke-ReviewerShadowPreparation -Directory $rollbackRoot -ChangedPath $preparedPaths
    Assert-Coordinator ([int]$rollback.PublishedCount -eq 12) `
        "The PowerShell path published $($rollback.PublishedCount) artifacts rather than twelve."
    $coordinatorArtifacts = @(Get-ChildItem -LiteralPath (Join-Path $fixture.OutputRoot 'stage-artifacts') `
            -Filter '*.stage.json' -File | Sort-Object -Property Name -CaseSensitive)
    $rollbackArtifacts = @(Get-ChildItem -LiteralPath $rollbackRoot -Filter '*.stage.json' -File |
            Sort-Object -Property Name -CaseSensitive)
    Assert-Coordinator ($coordinatorArtifacts.Count -eq $rollbackArtifacts.Count) `
        "The two paths published $($coordinatorArtifacts.Count) and $($rollbackArtifacts.Count) artifacts."
    for ($index = 0; $index -lt [Math]::Min($coordinatorArtifacts.Count, $rollbackArtifacts.Count); $index++) {
        $left = $coordinatorArtifacts[$index]
        $right = $rollbackArtifacts[$index]
        Assert-Coordinator ($left.Name -ceq $right.Name) `
            "Artifact $index is named '$($left.Name)' on the coordinator path and '$($right.Name)' on the PowerShell path."
        $leftHash = (Get-FileHash -LiteralPath $left.FullName -Algorithm SHA256).Hash
        $rightHash = (Get-FileHash -LiteralPath $right.FullName -Algorithm SHA256).Hash
        Assert-Coordinator ($leftHash -ceq $rightHash) `
            "Artifact '$($left.Name)' differs between the coordinator path and the PowerShell rollback path."
    }

    # -----------------------------------------------------------------------
    Write-Host '7/32 request boundary: unknown, missing, scalar, null, BOM, truncated' -ForegroundColor Cyan
    # Built through a list rather than an @(...) literal: the mutators set fields
    # to $null on purpose, and inside an array expression that reads as an array
    # that can carry a null element. It cannot -- the nulls are inside script
    # blocks -- but saying so in the shape of the code is better than arguing.
    $variants = [Collections.Generic.List[hashtable]]::new()
    [void]$variants.Add(@{ Name = 'unknown'; Mutate = { param($r) $r | Add-Member -NotePropertyName 'unexpected' -NotePropertyValue 'x' }; Match = 'unexpected' })
    [void]$variants.Add(@{ Name = 'unknown-nested'; Mutate = { param($r) $r.subject | Add-Member -NotePropertyName 'extra' -NotePropertyValue 1 }; Match = 'extra' })
    [void]$variants.Add(@{ Name = 'missing'; Mutate = { param($r) $r.PSObject.Properties.Remove('corpus') }; Match = 'corpus' })
    [void]$variants.Add(@{ Name = 'scalar-section'; Mutate = { param($r) $r.corpus = 'not-an-object' }; Match = 'corpus' })
    [void]$variants.Add(@{ Name = 'null-section'; Mutate = { param($r) $r.corpus = $null }; Match = 'corpus' })
    [void]$variants.Add(@{ Name = 'scalar-int'; Mutate = { param($r) $r.subject.pullRequestId = 'not-a-number' }; Match = 'pullRequestId' })
    [void]$variants.Add(@{ Name = 'null-string'; Mutate = { param($r) $r.qualification.operatorAlias = $null }; Match = 'operatorAlias' })
    [void]$variants.Add(@{ Name = 'short-hex'; Mutate = { param($r) $r.toolkit.head = 'abc' }; Match = 'head' })
    [void]$variants.Add(@{ Name = 'upper-hex'; Mutate = { param($r) $r.digests.configSha256 = ($r.digests.configSha256).ToUpperInvariant() }; Match = 'configSha256' })
    [void]$variants.Add(@{ Name = 'wrong-contract'; Mutate = { param($r) $r.contractVersion = 'devpilot.shadow-run-coordinator.request.v3' }; Match = 'contractVersion' })
    [void]$variants.Add(@{ Name = 'wrong-kind'; Mutate = { param($r) $r.kind = 'something-else' }; Match = 'kind' })
    [void]$variants.Add(@{ Name = 'run-count-low'; Mutate = { param($r) $r.qualification.plannedRunCount = 1 }; Match = 'plannedRunCount' })
    [void]$variants.Add(@{ Name = 'run-count-high'; Mutate = { param($r) $r.qualification.plannedRunCount = 17 }; Match = 'plannedRunCount' })
    [void]$variants.Add(@{ Name = 'bad-correlation'; Mutate = { param($r) $r.correlationId = 'has spaces' }; Match = 'correlationId' })
    foreach ($variant in $variants) {
        $path = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name $variant.Name -Mutate $variant.Mutate
        $result = Invoke-Coordinator -RequestPath $path
        Assert-Coordinator ($result.ExitCode -eq 2) `
            "The '$($variant.Name)' request was not refused as a contract failure (exit $($result.ExitCode))."
        Assert-Coordinator ($result.Output -match [regex]::Escape($variant.Match)) `
            "The '$($variant.Name)' refusal does not name '$($variant.Match)'."
    }
    $bomPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'bom' `
        -Mutate { param($r) } -AsBom
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $bomPath).ExitCode -eq 2) `
        'A request carrying a byte-order mark was not refused.'
    $truncatedPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'truncated' `
        -Mutate { param($r) } -AsTruncated
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $truncatedPath).ExitCode -eq 2) `
        'A truncated request was not refused.'
    $emptyPath = Join-Path (Split-Path $fixture.RequestPath -Parent) 'request-empty.json'
    [System.IO.File]::WriteAllBytes($emptyPath, [byte[]]::new(0))
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $emptyPath).ExitCode -eq 2) `
        'An empty request file was not refused.'
    $arrayPath = Join-Path (Split-Path $fixture.RequestPath -Parent) 'request-array.json'
    Set-Content -LiteralPath $arrayPath -Encoding utf8NoBOM -Value '[]'
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $arrayPath).ExitCode -eq 2) `
        'A request that is an array rather than an object was not refused.'
    Assert-Coordinator ((Invoke-Coordinator -RequestPath (Join-Path $sandbox 'no-such-request.json')).ExitCode -eq 2) `
        'A missing request file was not refused.'

    # -----------------------------------------------------------------------
    Write-Host '8/32 stale head, stale identity and tampered state' -ForegroundColor Cyan
    $staleHeadPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'stale-head' -Mutate {
        param($r)
        $r.toolkit.head = ('f' * 40)
        & $setOutputRoot -Request $r -Root (Join-Path $sandbox 'out-stale-head')
    }
    $staleHead = Invoke-Coordinator -RequestPath $staleHeadPath
    Assert-Coordinator ($staleHead.ExitCode -eq 2 -and $staleHead.Output -match 'head') `
        'A request binding a head the build is not at was accepted.'

    $staleDigestPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'stale-digest' -Mutate {
        param($r)
        $r.digests.schemaSha256 = ('1' * 64)
        & $setOutputRoot -Request $r -Root (Join-Path $sandbox 'out-stale-digest')
    }
    $staleDigest = Invoke-Coordinator -RequestPath $staleDigestPath
    Assert-Coordinator ($staleDigest.ExitCode -eq 2 -and $staleDigest.Output -match 'schema') `
        'A request binding a stale schema digest was accepted.'

    $staleCorpusPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'stale-corpus' -Mutate {
        param($r)
        $r.corpus.indexSha256 = ('2' * 64)
        & $setOutputRoot -Request $r -Root (Join-Path $sandbox 'out-stale-corpus')
    }
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $staleCorpusPath).ExitCode -ne 0) `
        'A request binding a corpus index digest the corpus does not have was accepted.'

    # A state file edited on disk must not be resumed from.
    $tamperRoot = Join-Path $sandbox 'out-tamper'
    $tamperPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'tamper' -Mutate {
        param($r) & $setOutputRoot -Request $r -Root $tamperRoot
    }
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $tamperPath -HaltAfter 'requestValidated').ExitCode -eq 9) `
        'The tamper scenario did not reach its first halt.'
    $statePath = Join-Path $tamperRoot 'coordinator\state.json'
    $stateText = Get-Content -LiteralPath $statePath -Raw
    Set-Content -LiteralPath $statePath -Encoding utf8NoBOM `
        -Value ($stateText -replace '"sequence":\s*1', '"sequence": 5')
    $tampered = Invoke-Coordinator -RequestPath $tamperPath
    Assert-Coordinator ($tampered.ExitCode -eq 2) `
        "An edited state file was resumed from (exit $($tampered.ExitCode))."

    # A state file belonging to another correlation must not be adopted.
    $foreignRoot = Join-Path $sandbox 'out-foreign'
    $foreignPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'foreign' -Mutate {
        param($r) & $setOutputRoot -Request $r -Root $foreignRoot
    }
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $foreignPath -HaltAfter 'requestValidated').ExitCode -eq 9) `
        'The foreign-correlation scenario did not reach its first halt.'
    $foreignRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'foreign-second' -Mutate {
        param($r)
        & $setOutputRoot -Request $r -Root $foreignRoot
        $r.correlationId = 'shadow-a-different-run'
    }
    $foreign = Invoke-Coordinator -RequestPath $foreignRequest
    Assert-Coordinator ($foreign.ExitCode -eq 2) `
        "A state file from another correlation was adopted (exit $($foreign.ExitCode))."

    # -----------------------------------------------------------------------
    Write-Host '9/32 single-run lease' -ForegroundColor Cyan
    $leaseRoot = Join-Path $sandbox 'out-lease'
    $leasePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'lease' -Mutate {
        param($r) & $setOutputRoot -Request $r -Root $leaseRoot
    }
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $leasePath -HaltAfter 'requestValidated').ExitCode -eq 9) `
        'The lease scenario did not reach its first halt.'
    # A lease held by a process that is demonstrably alive - this one - must stop
    # a second coordinator. Liveness is decided from the recorded identity, never
    # from what a process is running.
    $self = Get-Process -Id $PID
    $leaseFile = Join-Path $leaseRoot 'coordinator\run.lease'
    $leaseRecord = [ordered]@{
        contractVersion = 'devpilot.shadow-run-coordinator.lease.v1'
        correlationId = $fixture.CorrelationId
        processId = $PID
        processStartedAtUtc = $self.StartTime.ToUniversalTime().ToString('o')
        acquiredAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Set-Content -LiteralPath $leaseFile -Encoding utf8NoBOM `
        -Value (ConvertTo-Json -InputObject $leaseRecord -Depth 6 -Compress:$false)
    $conflict = Invoke-Coordinator -RequestPath $leasePath
    Assert-Coordinator ($conflict.ExitCode -eq 3) `
        "A coordinator ran against a root leased by a live process (exit $($conflict.ExitCode))."

    # The same lease naming a process identity that cannot be live is abandoned
    # residue, and must NOT wedge the root forever.
    $leaseRecord.processStartedAtUtc = ([DateTime]::UtcNow.AddDays(-3650)).ToString('o')
    Set-Content -LiteralPath $leaseFile -Encoding utf8NoBOM `
        -Value (ConvertTo-Json -InputObject $leaseRecord -Depth 6 -Compress:$false)
    $recovered = Invoke-Coordinator -RequestPath $leasePath -HaltAfter 'corpusValidated'
    Assert-Coordinator ($recovered.ExitCode -eq 9) `
        "An abandoned lease wedged the output root (exit $($recovered.ExitCode))."

    # -----------------------------------------------------------------------
    Write-Host '10/32 child fault matrix' -ForegroundColor Cyan
    $faults = @(
        @{ Name = 'nonzero'; Expect = 4 },
        @{ Name = 'missing'; Expect = 4 },
        @{ Name = 'malformed'; Expect = 4 },
        @{ Name = 'bom'; Expect = 4 },
        @{ Name = 'truncated'; Expect = 4 },
        @{ Name = 'partial'; Expect = 4 },
        @{ Name = 'wrongCorrelation'; Expect = 4 },
        @{ Name = 'wrongStep'; Expect = 4 }
    )
    # GetNewClosure captures variables, not function definitions, so the function
    # is captured explicitly and invoked through the reference. Calling it by name
    # from inside the closure would resolve against whatever scope runs it later.
    # GetNewClosure captures variables, not function definitions, so the function
    # is captured explicitly and invoked through the reference. Calling it by name
    # from inside the closure would resolve against whatever scope runs it later.
    foreach ($fault in $faults) {
        New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault $fault.Name
        $faultRoot = Join-Path $sandbox "out-fault-$($fault.Name)"
        $faultRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name "fault-$($fault.Name)" -Mutate {
            param($r) & $setOutputRoot -Request $r -Root $faultRoot
        }.GetNewClosure()
        $result = Invoke-Coordinator -RequestPath $faultRequest
        Assert-Coordinator ($result.ExitCode -eq $fault.Expect) `
            "The '$($fault.Name)' child fault produced exit $($result.ExitCode) rather than $($fault.Expect)."
        $durable = Get-CoordinatorState -OutputRoot $faultRoot
        # The first child is invoked by the recipePlanned transition, so the two
        # transitions before it legitimately commit first. What must never happen
        # is a state at or past the transition whose child failed: that would mean
        # a partial child result was accepted as evidence.
        $reached = if ($durable) { [string]$durable.state } else { 'none' }
        Assert-Coordinator ($reached -cin @('none', 'requestValidated', 'corpusValidated')) `
            "The '$($fault.Name)' child fault left the state at '$reached'."
    }

    # A child that writes a valid result AND chatters contract-shaped text on
    # standard output must still succeed: stdout is not a contract surface.
    New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'stdoutPrologue'
    $chatterRoot = Join-Path $sandbox 'out-fault-stdout'
    $chatterRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'fault-stdout' -Mutate {
        param($r) & $setOutputRoot -Request $r -Root $chatterRoot
    }
    $chatter = Invoke-Coordinator -RequestPath $chatterRequest
    # The stand-in answers no expected field, so it fails as a partial result -
    # NOT by having its standard output believed.
    Assert-Coordinator ($chatter.ExitCode -eq 4 -and $chatter.Output -notmatch 'REVIEWER_QUALIFICATION_PRELAUNCH_V1') `
        'A child result was taken from standard output rather than from the result file.'

    # A hanging child must be bounded, killed with its tree, and leave nothing.
    New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'hang'
    $hangRoot = Join-Path $sandbox 'out-fault-hang'
    $hangRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'fault-hang' -Mutate {
        param($r)
        & $setOutputRoot -Request $r -Root $hangRoot
        $r.children.timeoutSeconds = 5
    }
    $before = Get-DescendantPwshCount -SandboxToken $sandboxToken
    $hang = Invoke-Coordinator -RequestPath $hangRequest
    Assert-Coordinator ($hang.ExitCode -eq 4) `
        "A hanging child was not bounded by the configured timeout (exit $($hang.ExitCode))."
    Start-Sleep -Seconds 2
    $after = Get-DescendantPwshCount -SandboxToken $sandboxToken
    Assert-Coordinator ($after -le $before) `
        "A bounded child left $($after - $before) process(es) behind."
    Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot

    # -----------------------------------------------------------------------
    Write-Host '11/32 killed mid-transition' -ForegroundColor Cyan
    # A real external kill, not a cooperative halt: the coordinator is stopped
    # while a child is running, and the root must still converge.
    $killRoot = Join-Path $sandbox 'out-kill'
    $killRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'kill' -Mutate {
        param($r) & $setOutputRoot -Request $r -Root $killRoot
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'dotnet'
    foreach ($argument in @($script:CoordinatorDll, '--request', $killRequest)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $victim = [Diagnostics.Process]::Start($startInfo)
    Start-Sleep -Seconds 6
    if (-not $victim.HasExited) { $victim.Kill($true) }
    [void]$victim.WaitForExit(30000)
    $afterKill = Get-CoordinatorState -OutputRoot $killRoot
    Assert-Coordinator ($null -eq $afterKill -or $afterKill.PSObject.Properties['state']) `
        'A killed coordinator left a state file that cannot be read.'
    $resumed = Invoke-Coordinator -RequestPath $killRequest
    Assert-Coordinator ($resumed.ExitCode -eq 0) `
        "A killed preparation did not resume to run-set-ready (exit $($resumed.ExitCode)): $($resumed.Output)"
    $resumedState = Get-CoordinatorState -OutputRoot $killRoot
    Assert-Coordinator ($resumedState.state -ceq 'runSetReady' -and [int]$resumedState.sequence -eq 11) `
        "The resumed preparation ended at '$($resumedState.state)' sequence $($resumedState.sequence)."
    $killAudit = Get-Content -LiteralPath (Join-Path $killRoot 'coordinator\audit.json') -Raw | ConvertFrom-Json -Depth 32
    Assert-Coordinator ([int]$killAudit.stages.runSetReady.slotAttemptCount -eq 0) `
        'The resumed preparation observed a slot attempt.'
    $declared = @(Get-ChildItem -LiteralPath (Join-Path $killRoot 'qualification\runset') -Filter 'runset-*.json' `
            -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.sig' })
    Assert-Coordinator ($declared.Count -eq 1) `
        "The resumed preparation left $($declared.Count) declared run sets rather than one."

    # -----------------------------------------------------------------------
    Write-Host '12/32 pre-commit window: a published side effect is adopted' -ForegroundColor Cyan
    # The fault a control plane cannot test its way out of by halting: a child
    # completes a durable, NON-REPEATABLE side effect and the coordinator dies
    # before it can commit the transition. Every --halt-after case above stops
    # AFTER a commit, so none of them reach this window.
    #
    # Reproduced here in the harshest available form. The run is taken to a
    # sealed snapshot and a declared run set, and then the coordinator's entire
    # durable record is destroyed while the side effects are left standing. That
    # is strictly worse than the real window - the real one keeps its record and
    # loses only the last commit - so a run that recovers from this recovers from
    # that. Before the side effects became adoptable this wedged permanently:
    # the sealer refuses an existing snapshot id without -Force and the
    # qualification tool refuses a second declaration, so every later resume took
    # the identical path and failed identically.
    #
    # Case one is the real window, reproduced exactly: a child that completes its
    # durable side effect and then dies without leaving a result. The record
    # still says the PREVIOUS transition, so the resume re-enters a step whose
    # work is already on disk.
    $windowRoot = Join-Path $sandbox 'precommit-adopt'
    $windowPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'precommit-adopt' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $windowRoot }.GetNewClosure()
    New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'publishThenDie' `
        -RealAdapter (Join-Path $RepoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1')
    try {
        $lost = Invoke-Coordinator -RequestPath $windowPath
        Assert-Coordinator ($lost.ExitCode -eq 4) `
            "A child that published and then died was not reported as a child failure; it exited $($lost.ExitCode)."
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }
    $orphanSeal = @(Get-ChildItem -LiteralPath (Join-Path $windowRoot 'replay-root') -Directory -ErrorAction SilentlyContinue)
    Assert-Coordinator ($orphanSeal.Count -eq 1) `
        "The lost child left $($orphanSeal.Count) snapshots; the window under test needs exactly one."
    $orphanDigest = (Get-ChildItem -LiteralPath $orphanSeal[0].FullName -Recurse -File |
            Sort-Object FullName | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join '|'
    $windowState = Get-Content -LiteralPath (Join-Path $windowRoot 'coordinator\state.json') -Raw | ConvertFrom-Json -Depth 24
    Assert-Coordinator ([string]$windowState.state -ceq 'snapshotValidateOnly') `
        "The record after the lost child reads '$($windowState.state)'; the window needs the seal uncommitted."

    # The resume must reach run-set-ready over the top of that orphaned seal.
    $windowResume = Invoke-Coordinator -RequestPath $windowPath
    Assert-Coordinator ($windowResume.ExitCode -eq 0) `
        "A resume over an orphaned seal did not recover; it exited $($windowResume.ExitCode).`n$($windowResume.Output)"
    $windowAudit = Get-Content -LiteralPath (Join-Path $windowRoot 'coordinator\audit.json') -Raw | ConvertFrom-Json -Depth 24
    Assert-Coordinator ([string]$windowAudit.finalState -ceq 'runSetReady') `
        "The recovered run reached '$($windowAudit.finalState)' rather than run-set-ready."
    Assert-Coordinator ([int]$windowAudit.preparationAttemptRecordCount -eq 0) `
        'The recovered run recorded a reviewer process at readiness.'
    $sealedBefore = @(Get-ChildItem -LiteralPath (Join-Path $windowRoot 'replay-root') -Directory)
    Assert-Coordinator ($sealedBefore.Count -eq 1) `
        "The recovered run left $($sealedBefore.Count) snapshots rather than adopting the one already sealed."
    $sealedDigestParts = @(Get-ChildItem -LiteralPath $sealedBefore[0].FullName -Recurse -File |
            Sort-Object FullName | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
    $sealedDigestBefore = [string]($sealedDigestParts -join '|')
    Assert-Coordinator ($sealedDigestBefore -ceq $orphanDigest) `
        'The recovered run rewrote the orphaned snapshot instead of adopting its bytes.'
    $sealAdopt = Get-ExchangeResult -Root $windowRoot -Step 'corpusSeal'
    Assert-Coordinator ([bool]$sealAdopt.adopted) `
        'The seal child resealed rather than adopting the snapshot its lost attempt had published.'
    $declaredBefore = @(Get-ChildItem -LiteralPath (Join-Path $windowRoot 'qualification') -Recurse -File `
            -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'runset-*' -and $_.Name -notlike '*.sig*' })
    Assert-Coordinator ($declaredBefore.Count -ge 1) `
        "The recovered run published $($declaredBefore.Count) run set files rather than at least one."

    # Case two is the harsher variant: the signed record itself is destroyed. A
    # run whose record is gone must NOT quietly re-derive one over standing side
    # effects - if it could, the record would not be load-bearing. It fails
    # closed instead, and says so.
    $wipedRoot = Join-Path $sandbox 'precommit-wiped-record'
    $wipedPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'precommit-wiped-record' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $wipedRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $wipedPath -Target 'snapshotSealed').ExitCode -eq 0) `
        'The wiped-record setup did not reach a sealed snapshot.'
    # First with the signing key left in place. A key is minted with the first
    # record, so a key without a record is proof a record was removed, and that
    # is caught before anything at all is mutated - not later, by happening to
    # trip over a standing side effect.
    $wipedAuditPath = Join-Path $wipedRoot 'coordinator\audit.json'
    $wipedAuditBefore = (Get-FileHash -LiteralPath $wipedAuditPath -Algorithm SHA256).Hash
    Remove-Item -LiteralPath (Join-Path $wipedRoot 'coordinator\state.json') -Force
    $keptKey = Invoke-Coordinator -RequestPath $wipedPath
    Assert-Coordinator ($keptKey.ExitCode -eq 2) `
        "A run whose record was removed under a standing key exited $($keptKey.ExitCode) rather than refusing.`n$($keptKey.Output)"
    Assert-Coordinator ($keptKey.Output -match 'signing key and .*, but no state record') `
        "The refusal did not name the missing record.`n$($keptKey.Output)"
    Assert-Coordinator (-not (Test-Path -LiteralPath (Join-Path $wipedRoot 'coordinator\state.json'))) `
        'The refusing run wrote a fresh record over the destroyed one.'
    Assert-Coordinator ((Get-FileHash -LiteralPath $wipedAuditPath -Algorithm SHA256).Hash -ceq $wipedAuditBefore) `
        'The refusing run republished an audit for a preparation it refused to resume.'
    # Then with the key destroyed too, which is the closest an operator can get
    # to a genuinely fresh root over standing side effects. It still refuses,
    # because the snapshot the earlier attempt published is still there.
    Remove-Item -LiteralPath (Join-Path $wipedRoot 'coordinator\state.key') -Force -ErrorAction SilentlyContinue
    $wiped = Invoke-Coordinator -RequestPath $wipedPath
    Assert-Coordinator ($wiped.ExitCode -eq 2) `
        "A run whose signed record was destroyed exited $($wiped.ExitCode) rather than refusing.`n$($wiped.Output)"
    Assert-Coordinator ($wiped.Output -match 'replay-root|snapshot') `
        'The refusal did not name the standing side effect that contradicts the empty record.'

    # Case three: the same window on the OTHER non-repeatable side effect. The
    # qualification tool refuses a second declaration, so a declaration that
    # survives its coordinator has to be adoptable in its own right.
    #
    # This one is driven at the child directly rather than through a replaced
    # adapter. The qualification tool refuses to declare against a dirty
    # worktree, so swapping the adapter file - which is IN the toolkit - can
    # never reach the declaration step at all. Replaying the coordinator's own
    # child request against the pristine adapter is the faithful reproduction:
    # it is byte for byte the request the resumed coordinator would send.
    $declareRoot = Join-Path $sandbox 'precommit-declare'
    $declarePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'precommit-declare' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $declareRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $declarePath -HaltAfter 'runSetDeclared').ExitCode -eq 9) `
        'The declaration window setup did not halt after the declaration.'
    $orphanDeclared = @(Get-ChildItem -LiteralPath (Join-Path $declareRoot 'qualification\runset') -File `
            -Filter 'runset-*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.sig' })
    Assert-Coordinator ($orphanDeclared.Count -eq 1) `
        "The declaration window setup published $($orphanDeclared.Count) run sets rather than one."
    $firstDeclare = Get-ExchangeResult -Root $declareRoot -Step 'runSetDeclare'
    Assert-Coordinator (-not [bool]$firstDeclare.adopted) `
        'The first declaration reported itself as adopted; it had nothing to adopt.'

    # Replay the identical child request. A coordinator that died before its
    # commit sends exactly this again.
    $declareChildRequest = @(Get-ChildItem -LiteralPath (Join-Path $declareRoot 'coordinator\exchange') -File `
            -Filter '*-runSetDeclare.request.json')[0].FullName
    $replayResult = Join-Path $sandbox 'declare-replay.result.json'
    $replayRequest = Join-Path $sandbox 'declare-replay.request.json'
    $replayDocument = Get-Content -LiteralPath $declareChildRequest -Raw | ConvertFrom-Json -Depth 24
    $replayDocument.resultPath = $replayResult
    $replayText = (ConvertTo-Json -InputObject $replayDocument -Depth 24 -Compress:$false) + "`n"
    [IO.File]::WriteAllBytes($replayRequest, ([Text.UTF8Encoding]::new($false)).GetBytes($replayText))
    $adapter = Join-Path $fixture.ToolkitCopy 'tools\Invoke-ShadowCoordinatorChild.ps1'
    $replayOutput = & pwsh -NoProfile -File $adapter -RequestPath $replayRequest 2>&1 | Out-String
    $replayExit = $LASTEXITCODE
    Assert-Coordinator ($replayExit -eq 0) `
        "Replaying the declaration child against its own published run set exited $replayExit.`n$replayOutput"
    $replayed = Get-Content -LiteralPath $replayResult -Raw | ConvertFrom-Json -Depth 16
    Assert-Coordinator ([bool]$replayed.adopted) `
        'The declaration child declared a second run set rather than adopting the one already standing.'
    Assert-Coordinator ([string]$replayed.runSetPath -ceq [string]$firstDeclare.runSetPath) `
        'The adopted declaration is not the run set the first attempt published.'
    $declaredAfter = @(Get-ChildItem -LiteralPath (Join-Path $declareRoot 'qualification\runset') -File `
            -Filter 'runset-*.json' | Where-Object { $_.Name -notlike '*.sig' })
    Assert-Coordinator ($declaredAfter.Count -eq 1) `
        "The replayed declaration left $($declaredAfter.Count) run sets rather than adopting the single one."

    # And the coordinator itself still finishes over the top of it.
    $declareResume = Invoke-Coordinator -RequestPath $declarePath
    Assert-Coordinator ($declareResume.ExitCode -eq 0) `
        "A resume after the declaration window did not recover; it exited $($declareResume.ExitCode).`n$($declareResume.Output)"
    $declareAudit = Get-Content -LiteralPath (Join-Path $declareRoot 'coordinator\audit.json') -Raw | ConvertFrom-Json -Depth 24
    Assert-Coordinator ([string]$declareAudit.finalState -ceq 'runSetReady') `
        "The recovered declaration run reached '$($declareAudit.finalState)' rather than run-set-ready."
    Assert-Coordinator ([int]$declareAudit.slotLaunchCount -eq 0 -and [int]$declareAudit.preparationAttemptRecordCount -eq 0) `
        'The recovered declaration run recorded a slot or model launch.'
    Assert-Coordinator ($sealedDigestBefore.Length -gt 0 -and $declaredBefore.Count -ge 1) `
        'The first pre-commit window did not leave the evidence the later cases compare against.'

    # Case four: the same window on the stage publication. Its retry works by
    # sweeping the previous attempt's artifacts, and the directory it sweeps also
    # holds the ownership marker the stage switch requires. A sweep that takes the
    # marker with it makes the retry it exists to enable impossible.
    $stageRoot = Join-Path $sandbox 'precommit-stage'
    $stagePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'precommit-stage' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $stageRoot }.GetNewClosure()
    New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'publishThenDie' `
        -RealAdapter (Join-Path $RepoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1') -DieOnStep 'stagePreparation'
    try { $stageLost = Invoke-Coordinator -RequestPath $stagePath -Target 'recipePlanned' }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }
    Assert-Coordinator ($stageLost.ExitCode -ne 0) `
        'The stage window setup committed a transition whose child never returned a result.'
    $stageDirectory = Join-Path $stageRoot 'stage-artifacts'
    $orphanStage = @(Get-ChildItem -LiteralPath $stageDirectory -File -Filter '*.stage.json')
    Assert-Coordinator ($orphanStage.Count -eq 12) `
        "The lost stage attempt left $($orphanStage.Count) artifacts rather than twelve."
    Assert-Coordinator (Test-Path -LiteralPath (Join-Path $stageDirectory '.reviewer-stage-shadow.json')) `
        'The lost stage attempt left no ownership marker, so the window cannot be reproduced.'

    $stageResume = Invoke-Coordinator -RequestPath $stagePath -Target 'recipePlanned'
    Assert-Coordinator ($stageResume.ExitCode -eq 0) `
        "A resume over an orphaned stage publication exited $($stageResume.ExitCode).`n$($stageResume.Output)"
    $stageRetry = Get-ExchangeResult -Root $stageRoot -Step 'stagePreparation'
    Assert-Coordinator ([int]$stageRetry.discardedCount -eq 12) `
        "The retry discarded $($stageRetry.discardedCount) leftover artifacts rather than twelve."
    Assert-Coordinator ([int]$stageRetry.publishedCount -eq 12) `
        "The retry published $($stageRetry.publishedCount) artifacts rather than twelve."
    Assert-Coordinator (Test-Path -LiteralPath (Join-Path $stageDirectory '.reviewer-stage-shadow.json')) `
        'The retry swept away the ownership marker its own next retry would need.'
    $stageReservations = @(Get-ChildItem -LiteralPath $stageDirectory -File -Filter '*.reservation' `
            -ErrorAction SilentlyContinue)
    $orphanReservations = @($stageReservations | Where-Object {
            -not (Test-Path -LiteralPath ($_.FullName -replace '\.reservation$', '') -PathType Leaf) })
    Assert-Coordinator ($orphanReservations.Count -eq 0) `
        ("The retry left $($orphanReservations.Count) reservation(s) with no artifact: " +
        "$(($orphanReservations | ForEach-Object { $_.Name }) -join ', ')")
    Assert-Coordinator (@(Get-ChildItem -LiteralPath $stageDirectory -File -Filter '*.stage.json').Count -eq 12) `
        'The retry accumulated stage artifacts instead of replacing them.'
    # -----------------------------------------------------------------------
    Write-Host '13/32 resume integrity and the declared artifact directory' -ForegroundColor Cyan
    # A resumed run re-reads its child results from the exchange directory, which
    # carries no signature of its own. Without binding them to the digest the
    # signed record committed, a resume could adopt a snapshot or run set other
    # than the one its own record was committed against, and every downstream
    # check would be self-consistent and pass.
    $resumeRoot = Join-Path $sandbox 'resume-integrity'
    $resumePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'resume-integrity' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $resumeRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $resumePath -HaltAfter 'snapshotSealed').ExitCode -eq 9) `
        'The resume-integrity setup did not halt after the seal.'
    $sealResultPath = @(Get-ChildItem -LiteralPath (Join-Path $resumeRoot 'coordinator\exchange') -File `
            -Filter '*-corpusSeal.result.json')[0].FullName
    $sealDocument = Get-Content -LiteralPath $sealResultPath -Raw | ConvertFrom-Json -Depth 16
    $sealDocument.manifestSha256 = ('0' * 64)
    $editedText = (ConvertTo-Json -InputObject $sealDocument -Depth 16 -Compress:$false) + "`n"
    [IO.File]::WriteAllBytes($sealResultPath, ([Text.UTF8Encoding]::new($false)).GetBytes($editedText))
    $resumeTampered = Invoke-Coordinator -RequestPath $resumePath
    Assert-Coordinator ($resumeTampered.ExitCode -eq 2) `
        "A resume against an edited child result exited $($resumeTampered.ExitCode) rather than refusing.`n$($resumeTampered.Output)"
    Assert-Coordinator ($resumeTampered.Output -match 'committed record binds') `
        'The refusal did not name the committed digest it was resuming against.'

    # A stage artifact edited after it was censused must not be inherited.
    $rehashRoot = Join-Path $sandbox 'resume-rehash'
    $rehashPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'resume-rehash' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $rehashRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $rehashPath -HaltAfter 'recipePlanned').ExitCode -eq 9) `
        'The rehash setup did not halt after the plan.'
    $censused = @(Get-ChildItem -LiteralPath (Join-Path $rehashRoot 'stage-artifacts') -Filter '*.stage.json' -File)[0]
    # The stage writer publishes read-only, which is a useful speed bump but not
    # a control: anything that can reach the file can clear the attribute first.
    Set-ItemProperty -LiteralPath $censused.FullName -Name IsReadOnly -Value $false
    Add-Content -LiteralPath $censused.FullName -Value ' '
    $rehashResume = Invoke-Coordinator -RequestPath $rehashPath
    Assert-Coordinator ($rehashResume.ExitCode -eq 2) `
        "A resume against an edited stage artifact exited $($rehashResume.ExitCode) rather than refusing.`n$($rehashResume.Output)"

    # The child does not get to say where it published.
    $strayRoot = Join-Path $sandbox 'stray-directory'
    $strayRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'stray-directory' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $strayRoot }.GetNewClosure()
    $strayTarget = Join-Path $sandbox 'stray-artifacts'
    New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'strayDirectory' -StrayDirectory $strayTarget
    try {
        $stray = Invoke-Coordinator -RequestPath $strayRequest
        Assert-Coordinator ($stray.ExitCode -eq 2) `
            "A child that published outside the declared root exited $($stray.ExitCode) rather than being refused.`n$($stray.Output)"
        Assert-Coordinator ($stray.Output -match 'the request declared') `
            'The refusal did not name the directory the request declared.'
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # A child result that does not bind the request that asked for the work.
    $digestRoot = Join-Path $sandbox 'wrong-request-digest'
    $digestRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'wrong-request-digest' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $digestRoot }.GetNewClosure()
    New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'wrongRequestDigest'
    try {
        Assert-Coordinator ((Invoke-Coordinator -RequestPath $digestRequest).ExitCode -eq 4) `
            'A child result bound to the wrong request digest was accepted.'
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # A usage fault is a usage fault, not a stack trace.
    $usage = Invoke-CoordinatorRaw -Arguments @('--request')
    Assert-Coordinator ($usage.ExitCode -eq 2 -or $usage.ExitCode -eq 1) `
        "'--request' with no value exited $($usage.ExitCode), outside the documented set."
    Assert-Coordinator ($usage.Output -notmatch 'Unhandled exception') `
        'A missing option value escaped as an unhandled exception.'

    # -----------------------------------------------------------------------
    Write-Host '14/32 changed-path census boundary' -ForegroundColor Cyan
    # The census is declared by the caller and validated here, never synthesised.
    # Zero, one, many, duplicated, misordered, scalar, null and unknown all have
    # to have an answer, because the census reaches the published bytes.
    $censusCases = [Collections.Generic.List[hashtable]]::new()
    [void]$censusCases.Add(@{ Name = 'empty'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v1","kind":"shadow-run-coordinator-changed-paths","changedPaths":[]}' })
    [void]$censusCases.Add(@{ Name = 'duplicate'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v1","kind":"shadow-run-coordinator-changed-paths","changedPaths":["/a.ps1","/a.ps1"]}' })
    [void]$censusCases.Add(@{ Name = 'misordered'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v1","kind":"shadow-run-coordinator-changed-paths","changedPaths":["/b.ps1","/a.ps1"]}' })
    [void]$censusCases.Add(@{ Name = 'scalar'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v1","kind":"shadow-run-coordinator-changed-paths","changedPaths":"/a.ps1"}' })
    [void]$censusCases.Add(@{ Name = 'null'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v1","kind":"shadow-run-coordinator-changed-paths","changedPaths":null}' })
    [void]$censusCases.Add(@{ Name = 'null-element'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v1","kind":"shadow-run-coordinator-changed-paths","changedPaths":["/a.ps1",null]}' })
    [void]$censusCases.Add(@{ Name = 'unknown'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v1","kind":"shadow-run-coordinator-changed-paths","changedPaths":["/a.ps1"],"extra":1}' })
    [void]$censusCases.Add(@{ Name = 'wrong-contract'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v0","kind":"shadow-run-coordinator-changed-paths","changedPaths":["/a.ps1"]}' })
    [void]$censusCases.Add(@{ Name = 'array-root'; Body = '["/a.ps1"]' })
    foreach ($case in $censusCases) {
        $censusPath = Join-Path $sandbox "census-$($case.Name).json"
        [IO.File]::WriteAllBytes($censusPath, ([Text.UTF8Encoding]::new($false)).GetBytes([string]$case.Body))
        $censusRoot = Join-Path $sandbox "census-root-$($case.Name)"
        $censusRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name "census-$($case.Name)" `
            -Mutate {
                param($r)
                & $setOutputRoot -Request $r -Root $censusRoot
                $r.corpus.changedPathsPath = $censusPath
            }.GetNewClosure()
        $censusResult = Invoke-Coordinator -RequestPath $censusRequest
        Assert-Coordinator ($censusResult.ExitCode -eq 2) `
            "A '$($case.Name)' changed-path census exited $($censusResult.ExitCode) rather than being refused."
    }
    $missingCensusRoot = Join-Path $sandbox 'census-root-missing'
    $missingCensus = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'census-missing' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $missingCensusRoot
            $r.corpus.changedPathsPath = (Join-Path $sandbox 'no-such-census.json')
        }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $missingCensus).ExitCode -eq 2) `
        'A missing changed-path census was not refused.'

    # -----------------------------------------------------------------------
    Write-Host '15/32 a declaration must belong to this preparation' -ForegroundColor Cyan
    # A signature proves a declaration was made under this output root's key. It
    # does NOT prove the declaration is about the snapshot this run sealed - one
    # key signs every declaration in a root, so a declaration left behind by an
    # earlier subject verifies perfectly and would otherwise be adopted, verified
    # and signed off as ready under a snapshot it has never heard of.
    $foreignRoot = Join-Path $sandbox 'foreign-declaration'
    $foreignPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'foreign-declaration' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $foreignRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $foreignPath -HaltAfter 'runSetDeclared').ExitCode -eq 9) `
        'The foreign-declaration setup did not halt after its declaration.'
    $foreignRunSetDirectory = Join-Path $foreignRoot 'qualification\runset'
    $foreignRunSet = @(Get-ChildItem -LiteralPath $foreignRunSetDirectory -File -Filter 'runset-*.json' |
            Where-Object { $_.Name -notlike '*.sig' })[0]

    # Rewrite the standing declaration so it names a different snapshot, and
    # re-sign it under the same key so the signature stays genuine. This is
    # exactly the shape of a run set an earlier subject would have left behind.
    $foreignRecord = Get-Content -LiteralPath $foreignRunSet.FullName -Raw | ConvertFrom-Json -Depth 24
    $foreignManifest = [string]$foreignRecord.manifestJson | ConvertFrom-Json -Depth 24
    $foreignManifest.snapshotName = 'pr9999-i1-someoneelsesnapshot'
    $foreignManifestJson = ConvertTo-Json -InputObject $foreignManifest -Depth 24 -Compress
    $foreignKeyText = (Get-Content -LiteralPath $fixture.RunSetKeyPath -Raw).Trim()
    $foreignKeyBytes = [Convert]::FromBase64String($foreignKeyText.Substring($foreignKeyText.IndexOf(':') + 1))
    $foreignHmac = [System.Security.Cryptography.HMACSHA256]::new($foreignKeyBytes)
    try {
        $foreignSignature = ([BitConverter]::ToString(
                $foreignHmac.ComputeHash(([Text.UTF8Encoding]::new($false)).GetBytes($foreignManifestJson))) -replace '-', '').ToLowerInvariant()
    }
    finally { $foreignHmac.Dispose() }
    $foreignRecord.manifestJson = $foreignManifestJson
    $foreignRecord.signature = $foreignSignature
    $foreignText = (ConvertTo-Json -InputObject $foreignRecord -Depth 24 -Compress:$false) + "`n"
    [IO.File]::WriteAllBytes($foreignRunSet.FullName, ([Text.UTF8Encoding]::new($false)).GetBytes($foreignText))

    $foreignResume = Invoke-Coordinator -RequestPath $foreignPath
    Assert-Coordinator ($foreignResume.ExitCode -ne 0) `
        "A declaration bound to another snapshot was accepted; the run exited $($foreignResume.ExitCode)."
    $foreignState = Get-Content -LiteralPath (Join-Path $foreignRoot 'coordinator\state.json') -Raw | ConvertFrom-Json -Depth 24
    Assert-Coordinator ([string]$foreignState.state -cne 'runSetReady') `
        'A preparation signed run-set-ready over a declaration belonging to another subject.'

    # The child adapter refuses the same thing on its own, before the coordinator
    # ever sees it, so adoption is not the weak half of the pair.
    $foreignChildRequest = @(Get-ChildItem -LiteralPath (Join-Path $foreignRoot 'coordinator\exchange') -File `
            -Filter '*-runSetDeclare.request.json')[0].FullName
    $foreignReplayRequest = Join-Path $sandbox 'foreign-declare.request.json'
    $foreignReplayResult = Join-Path $sandbox 'foreign-declare.result.json'
    $foreignReplayDocument = Get-Content -LiteralPath $foreignChildRequest -Raw | ConvertFrom-Json -Depth 24
    $foreignReplayDocument.resultPath = $foreignReplayResult
    $foreignReplayText = (ConvertTo-Json -InputObject $foreignReplayDocument -Depth 24 -Compress:$false) + "`n"
    [IO.File]::WriteAllBytes($foreignReplayRequest, ([Text.UTF8Encoding]::new($false)).GetBytes($foreignReplayText))
    $foreignAdapter = Join-Path $fixture.ToolkitCopy 'tools\Invoke-ShadowCoordinatorChild.ps1'
    $foreignChildOutput = & pwsh -NoProfile -File $foreignAdapter -RequestPath $foreignReplayRequest 2>&1 | Out-String
    Assert-Coordinator ($LASTEXITCODE -ne 0) `
        "The child adopted a run set belonging to another preparation.`n$foreignChildOutput"
    Assert-Coordinator ($foreignChildOutput -match 'another preparation') `
        "The child's refusal did not say the declaration belongs elsewhere.`n$foreignChildOutput"

    # The coordinator does not take the child's word for which subject it just
    # verified. A result that is genuine in every other respect - correlated,
    # correctly digested, produced by the real child - but disagrees with the
    # record about the snapshot or the set is still refused, so the binding
    # survives a child that is merely wrong rather than hostile.
    $realAdapterPath = Join-Path $RepoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1'
    foreach ($binding in @(
            @{ Name = 'verify-snapshot'; Step = 'runSetVerify'; Property = 'snapshotName'
                Value = 'pr9999-i1-someoneelsesnapshot'; Target = 'runSetVerified'
                Expect = 'is bound to snapshot .pr9999-i1-someoneelsesnapshot.' },
            @{ Name = 'status-setid'; Step = 'runSetStatus'; Property = 'setId'
                Value = ('f' * 32); Target = 'runSetReady'
                Expect = 'status read reports run set .f{32}.' })) {
        $bindingRoot = Join-Path $sandbox ('binding-' + $binding.Name)
        $bindingRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name ('binding-' + $binding.Name) `
            -Mutate { param($r) & $setOutputRoot -Request $r -Root $bindingRoot }.GetNewClosure()
        # The declaration is made first, with the pristine adapter: the
        # qualification tool refuses a dirty worktree, and replacing the adapter
        # is itself a worktree change, so a run that starts under a replaced
        # adapter can never reach a declaration to disagree about.
        Assert-Coordinator ((Invoke-Coordinator -RequestPath $bindingRequest -HaltAfter 'runSetDeclared').ExitCode -eq 9) `
            "The $($binding.Name) setup did not halt after its declaration."
        New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'mutateResult' -RealAdapter $realAdapterPath `
            -MutateStep $binding.Step -MutateProperty $binding.Property -MutateValue $binding.Value
        try { $bindingRun = Invoke-Coordinator -RequestPath $bindingRequest -Target $binding.Target }
        finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }
        Assert-Coordinator ($bindingRun.ExitCode -eq 2) `
            ("A child result that renamed '$($binding.Property)' exited $($bindingRun.ExitCode) " +
            "rather than refusing.`n$($bindingRun.Output)")
        Assert-Coordinator ($bindingRun.Output -match $binding.Expect) `
            "The refusal did not name what it disagreed about.`n$($bindingRun.Output)"
        $bindingState = Get-Content -LiteralPath (Join-Path $bindingRoot 'coordinator\state.json') -Raw |
            ConvertFrom-Json -Depth 24
        Assert-Coordinator ([string]$bindingState.state -cne $binding.Target) `
            "The coordinator committed '$($binding.Target)' over a child result that contradicted its own record."
    }

    # A standing declaration is adopted only when it was made for THIS
    # qualification. Snapshot name, manifest digest and run count agreeing is not
    # enough: two preparations can differ in repository, config, operator, commit
    # or timeouts and still agree on all three.
    $donorRoot = Join-Path $sandbox 'plan-donor'
    $donorPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'plan-donor' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $donorRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $donorPath -HaltAfter 'runSetDeclared').ExitCode -eq 9) `
        'The plan-donor setup did not produce a declaration.'
    $borrowRoot = Join-Path $sandbox 'plan-borrower'
    $borrowPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'plan-borrower' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $borrowRoot
            # Same snapshot, same manifest, same run count - a different operator.
            $r.qualification.operatorAlias = 'someone-else'
        }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $borrowPath -Target 'snapshotVerified').ExitCode -eq 0) `
        'The plan-borrower setup did not reach a verified snapshot.'
    $donorQualification = Join-Path $donorRoot 'qualification'
    $borrowQualification = Join-Path $borrowRoot 'qualification'
    Remove-Item -Recurse -Force -LiteralPath $borrowQualification -ErrorAction SilentlyContinue
    Copy-Item -Recurse -Force -LiteralPath $donorQualification -Destination $borrowQualification
    $borrowRun = Invoke-Coordinator -RequestPath $borrowPath -Target 'runSetDeclared'
    Assert-Coordinator ($borrowRun.ExitCode -eq 4) `
        ("A declaration made for another qualification exited $($borrowRun.ExitCode) " +
        "rather than being refused.`n$($borrowRun.Output)")
    $borrowLogs = @(Get-ChildItem -LiteralPath (Join-Path $borrowRoot 'coordinator\logs') -File `
            -Filter '*-runSetDeclare.*.log')
    $borrowResults = @(Get-ChildItem -LiteralPath (Join-Path $borrowRoot 'coordinator\exchange') -File `
            -Filter '*-runSetDeclare.result.json' -ErrorAction SilentlyContinue)
    $borrowReason = (@($borrowLogs + $borrowResults | ForEach-Object {
                Get-Content -LiteralPath $_.FullName -Raw
            })) -join "`n"
    Assert-Coordinator ($borrowReason -match 'belongs to another preparation') `
        "The refusal did not say the declaration was another preparation's.`n$borrowReason"
    Assert-Coordinator ($borrowReason -match 'was made for plan') `
        "The refusal did not name the plan the declaration was sealed under.`n$borrowReason"

    # -----------------------------------------------------------------------
    Write-Host '16/32 the audit says only what the record can support' -ForegroundColor Cyan
    # An audit whose counters come from this process cannot see work an earlier
    # process did, and a null count coerces to the reassuring zero in every
    # consumer that reads it. Both are properties of the durable record here.
    $auditRoot = Join-Path $sandbox 'audit-honesty'
    $auditPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'audit-honesty' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $auditRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $auditPath -Target 'snapshotVerified').ExitCode -eq 0) `
        'The audit-honesty setup did not reach a verified snapshot.'
    $shortAudit = Get-Content -LiteralPath (Join-Path $auditRoot 'coordinator\audit.json') -Raw | ConvertFrom-Json -Depth 24
    Assert-Coordinator (-not [bool]$shortAudit.invariantCountsObserved) `
        'A run stopped short of readiness claimed it had observed the invariant counts.'
    Assert-Coordinator (-not $shortAudit.PSObject.Properties['preparationAttemptRecordCount']) `
        'A run that never observed the readiness census still published one, which reads as zero.'
    Assert-Coordinator (-not $shortAudit.PSObject.Properties['slotLaunchCount']) `
        'A run that never observed a slot census still published one, which reads as zero.'
    $shortChildCount = [int]$shortAudit.childResultTransitionCount

    $auditResume = Invoke-Coordinator -RequestPath $auditPath
    Assert-Coordinator ($auditResume.ExitCode -eq 0) `
        "The audit-honesty resume exited $($auditResume.ExitCode).`n$($auditResume.Output)"
    $resumedAudit = Get-Content -LiteralPath (Join-Path $auditRoot 'coordinator\audit.json') -Raw | ConvertFrom-Json -Depth 24
    Assert-Coordinator ([bool]$resumedAudit.invariantCountsObserved) `
        'A completed run did not record that it had observed the invariant counts.'
    Assert-Coordinator ([int]$resumedAudit.slotLaunchCount -eq 0 -and [int]$resumedAudit.preparationAttemptRecordCount -eq 0) `
        'The completed audit recorded a slot or model launch.'
    $uninterruptedAudit = Get-Content -LiteralPath (Join-Path $fixture.OutputRoot 'coordinator\audit.json') -Raw |
        ConvertFrom-Json -Depth 24
    Assert-Coordinator ([int]$resumedAudit.childResultTransitionCount -eq [int]$uninterruptedAudit.childResultTransitionCount) `
        ("A resumed run counted $($resumedAudit.childResultTransitionCount) child-backed transition(s) and an " +
        "uninterrupted one counted $($uninterruptedAudit.childResultTransitionCount); the audit is not resume-invariant.")
    Assert-Coordinator ([int]$resumedAudit.childResultTransitionCount -gt $shortChildCount) `
        'The resumed audit did not grow its child-backed transition census.'

    # -----------------------------------------------------------------------
    Write-Host '17/32 a root that has done nothing is not wedged' -ForegroundColor Cyan
    # The refusal that protects a destroyed record must not be reachable by a
    # first attempt that simply failed. A run refused at requestValidated has
    # published nothing, so the same root with a corrected request has to work -
    # otherwise a mistyped digest costs an operator their output root for ever,
    # and the earliest point of the run becomes the one place a kill is fatal.
    $freshRoot = Join-Path $sandbox 'wedge-check'
    $badFirst = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'wedge-check-bad' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $freshRoot
            $r.toolkit.head = ('b' * 40)
        }.GetNewClosure()
    $wedgeFirst = Invoke-Coordinator -RequestPath $badFirst
    Assert-Coordinator ($wedgeFirst.ExitCode -eq 2) `
        "A request naming the wrong head exited $($wedgeFirst.ExitCode) rather than refusing."
    Assert-Coordinator (-not (Test-Path -LiteralPath (Join-Path $freshRoot 'coordinator\state.json'))) `
        'A refused first attempt still wrote a state record.'
    $goodSecond = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'wedge-check-good' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $freshRoot }.GetNewClosure()
    $wedgeSecond = Invoke-Coordinator -RequestPath $goodSecond -Target 'corpusValidated'
    Assert-Coordinator ($wedgeSecond.ExitCode -eq 0) `
        ("A corrected request against a root whose first attempt was refused exited " +
        "$($wedgeSecond.ExitCode); the root is wedged.`n$($wedgeSecond.Output)")

    # The refusal still fires when the root holds work, which is the case it is
    # actually for.
    $wipedWork = Join-Path $sandbox 'wedge-check-work'
    $wipedWorkPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'wedge-check-work' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $wipedWork }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $wipedWorkPath -Target 'recipePlanned').ExitCode -eq 0) `
        'The standing-work setup did not publish any stage artifacts.'
    Remove-Item -LiteralPath (Join-Path $wipedWork 'coordinator\state.json') -Force
    $wipedWorkRun = Invoke-Coordinator -RequestPath $wipedWorkPath
    Assert-Coordinator ($wipedWorkRun.ExitCode -eq 2) `
        "A destroyed record over standing work exited $($wipedWorkRun.ExitCode) rather than refusing."
    Assert-Coordinator ($wipedWorkRun.Output -match 'signing key and .*, but no state record') `
        "The refusal did not name the work it found.`n$($wipedWorkRun.Output)"

    # The recipe is bound by content, not by path. A resume skips corpusValidated,
    # so without this the file could be rewritten between the validation that
    # blessed it and the seal that consumes it.
    $recipeRoot = Join-Path $sandbox 'recipe-binding'
    $recipeRequestPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'recipe-binding' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $recipeRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $recipeRequestPath -Target 'corpusValidated').ExitCode -eq 0) `
        'The recipe-binding setup did not validate its corpus.'
    $recipeDocument = Get-Content -LiteralPath $recipeRequestPath -Raw | ConvertFrom-Json -Depth 24
    $recipeFile = [string]$recipeDocument.corpus.recipePath
    $recipeOriginal = [IO.File]::ReadAllBytes($recipeFile)
    try {
        $recipeText = [Text.Encoding]::UTF8.GetString($recipeOriginal)
        [IO.File]::WriteAllBytes($recipeFile, ([Text.UTF8Encoding]::new($false)).GetBytes($recipeText + " `n"))
        $recipeRun = Invoke-Coordinator -RequestPath $recipeRequestPath -Target 'snapshotValidateOnly'
        Assert-Coordinator ($recipeRun.ExitCode -eq 2) `
            "A recipe rewritten after validation exited $($recipeRun.ExitCode) rather than refusing."
        Assert-Coordinator ($recipeRun.Output -match 'recipe .* now hashes to|changed under the preparation') `
            "The refusal did not name the changed recipe.`n$($recipeRun.Output)"
    }
    finally { [IO.File]::WriteAllBytes($recipeFile, $recipeOriginal) }
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $recipeRequestPath -Target 'snapshotValidateOnly').ExitCode -eq 0) `
        'The restored recipe did not let the preparation continue.'

    # A coordinator killed from outside cannot clean up after itself, so its child
    # outlives it. The next run must not write alongside that child.
    $liveRoot = Join-Path $sandbox 'live-child'
    $livePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'live-child' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $liveRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $livePath -Target 'recipePlanned').ExitCode -eq 0) `
        'The live-child setup did not reach a planned recipe.'
    $liveJournal = @(Get-ChildItem -LiteralPath (Join-Path $liveRoot 'coordinator\exchange') -File `
            -Filter '*.journal.json')[0]
    $survivor = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', "Start-Sleep -Seconds 90 # $sandboxToken")
    try {
        $survivorStart = $survivor.StartTime.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
        $liveEntry = Get-Content -LiteralPath $liveJournal.FullName -Raw | ConvertFrom-Json -Depth 16
        $liveEntry | Add-Member -NotePropertyName 'childProcessId' -NotePropertyValue $survivor.Id -Force
        $liveEntry | Add-Member -NotePropertyName 'childStartedAtUtc' -NotePropertyValue $survivorStart -Force
        $liveText = (ConvertTo-Json -InputObject $liveEntry -Depth 16 -Compress:$false) + "`n"
        [IO.File]::WriteAllBytes($liveJournal.FullName, ([Text.UTF8Encoding]::new($false)).GetBytes($liveText))
        $liveRun = Invoke-Coordinator -RequestPath $livePath
        Assert-Coordinator ($liveRun.ExitCode -eq 3) `
            "A run over a still-live recorded child exited $($liveRun.ExitCode) rather than reporting a conflict."
        Assert-Coordinator ($liveRun.Output -match 'still has a .* child') `
            "The conflict did not name the surviving child.`n$($liveRun.Output)"
    }
    finally {
        Stop-Process -Id $survivor.Id -Force -ErrorAction SilentlyContinue
        $survivor.WaitForExit(30000) | Out-Null
    }
    # And once that child is gone, the same root runs again: a liveness record is
    # a conflict while it is true and nothing at all afterwards.
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $livePath -Target 'snapshotValidateOnly').ExitCode -eq 0) `
        'The root stayed conflicted after its recorded child exited.'

    # The child hashes the recipe once on entry, and then reads it a second time
    # to decide whether an already published snapshot can be adopted. A swap in
    # between would steer adoption at bytes nothing bound, so that second read
    # carries the digest too. Exercised directly, because reproducing the window
    # end to end would mean racing the child.
    $adapterSource = Join-Path $RepoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1'
    $adapterAst = [Management.Automation.Language.Parser]::ParseFile($adapterSource, [ref]$null, [ref]$null)
    $lookupAst = $adapterAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-ShadowChildPublishedSnapshot'
        }, $true)
    Assert-Coordinator ($null -ne $lookupAst) 'The adapter no longer defines the published-snapshot lookup.'
    if ($lookupAst) {
        . ([scriptblock]::Create($lookupAst.Extent.Text))
        $script:ShadowChildUtf8 = [Text.UTF8Encoding]::new($false, $true)
        $lookupRoot = Join-Path $sandbox 'adoption-binding'
        [void](New-Item -ItemType Directory -Force -Path $lookupRoot)
        $lookupRecipe = Join-Path $lookupRoot 'recipe.json'
        $lookupText = (ConvertTo-Json -InputObject ([pscustomobject]@{ snapshotId = 'planted-snapshot' }) -Depth 8) + "`n"
        [IO.File]::WriteAllBytes($lookupRecipe, ([Text.UTF8Encoding]::new($false)).GetBytes($lookupText))
        $lookupSha = (Get-FileHash -LiteralPath $lookupRecipe -Algorithm SHA256).Hash.ToLowerInvariant()

        $lookupError = ''
        try {
            [void](Get-ShadowChildPublishedSnapshot -RecipePath $lookupRecipe -RecipeSha256 ('0' * 64) `
                    -ReplayRoot $lookupRoot -ToolkitRoot $RepoRoot)
        }
        catch { $lookupError = [string]$_ }
        Assert-Coordinator ($lookupError -match 'hashes to .* and the request bound') `
            "The adoption lookup accepted a recipe the request never bound.`n$lookupError"

        # And the bound digest is the only thing that refuses: the same recipe,
        # correctly bound, gets as far as looking for a snapshot that is not there.
        $boundError = ''
        $boundResult = 'unset'
        try {
            $boundResult = Get-ShadowChildPublishedSnapshot -RecipePath $lookupRecipe -RecipeSha256 $lookupSha `
                -ReplayRoot $lookupRoot -ToolkitRoot $RepoRoot
        }
        catch { $boundError = [string]$_ }
        Assert-Coordinator (($boundError -eq '') -and ($null -eq $boundResult)) `
            "A correctly bound recipe did not survive the adoption lookup.`n$boundError"
    }

    # -----------------------------------------------------------------------
    Write-Host '18/32 slot authorization against the real qualification plan' -ForegroundColor Cyan
    # The one slot scenario that stands NOTHING in. The plan is built by the
    # production builder, bound to the signed declaration by the production
    # assertions, and the launch token is the one the declaration published. It
    # stops at slot1Authorized, which is the last state before anything runs, so
    # the whole check costs no model and no reviewer.
    $realAdapter = Join-Path $RepoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1'

    $authRoot = Join-Path $sandbox 'slot-authorize'
    $authPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'slot-authorize' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $authRoot
            $r.slots.shadowSlotsEnabled = $true
        }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $authPath -Target 'runSetReady').ExitCode -eq 0) `
        'The slot-authorization setup did not reach run-set-ready.'
    $authRunSet = Join-Path $authRoot 'qualification\runset'

    # Refusals first, because none of them writes state: the same root serves
    # every one of them and then goes on to authorize for real.
    $noToken = Invoke-Coordinator -RequestPath $authPath -Target 'slot1Authorized'
    Assert-Coordinator ($noToken.ExitCode -eq 2) `
        "A launch authorized without a token exited $($noToken.ExitCode) rather than refusing."
    Assert-Coordinator ($noToken.Output -match 'launch-authorization token .* does not exist') `
        "The refusal did not name the missing token.`n$($noToken.Output)"

    [void](Publish-ShadowCoordinatorLaunchToken -RunSetDirectory $authRunSet `
            -TokenPath $fixture.LaunchTokenPath -Corrupt)
    $wrongToken = Invoke-Coordinator -RequestPath $authPath -Target 'slot1Authorized'
    Assert-Coordinator ($wrongToken.ExitCode -eq 2) `
        "A launch authorized on a token the set never published exited $($wrongToken.ExitCode)."
    Assert-Coordinator ($wrongToken.Output -match 'not the token the published run set carries') `
        "The refusal did not name the token mismatch.`n$($wrongToken.Output)"
    # And the refusal message publishes no digest, because a message that printed
    # both sides of a failed token comparison would be an oracle for guessing it.
    Assert-Coordinator ($wrongToken.Output -notmatch '[0-9a-f]{64}') `
        'The token refusal printed a 64-hex digest.'

    [void](Publish-ShadowCoordinatorLaunchToken -RunSetDirectory $authRunSet `
            -TokenPath $fixture.LaunchTokenPath)
    $disabledPath = New-CoordinatorRequestVariant -BasePath $authPath -Name 'slot-disabled' `
        -Mutate { param($r) $r.slots.shadowSlotsEnabled = $false }
    $disabled = Invoke-Coordinator -RequestPath $disabledPath -Target 'slot1Authorized'
    Assert-Coordinator ($disabled.ExitCode -eq 2) `
        "A slot target without the shadow flag exited $($disabled.ExitCode) rather than refusing."
    Assert-Coordinator ($disabled.Output -match "shadowSlotsEnabled") `
        "The refusal did not name the disabled shadow flag.`n$($disabled.Output)"
    # A request whose declared set is not the shape this build supervises is
    # refused before anything is authorized, and the refusal names the shape
    # rather than quietly supervising whichever slots it recognized.
    $oneSlotPath = New-CoordinatorRequestVariant -BasePath $authPath -Name 'slot-one' `
        -Mutate { param($r) $r.slots.declared = @($r.slots.declared[0]) }
    $oneSlot = Invoke-Coordinator -RequestPath $oneSlotPath -Target 'slot1Authorized'
    Assert-Coordinator ($oneSlot.ExitCode -eq 2) `
        "A request declaring one slot exited $($oneSlot.ExitCode) rather than refusing."
    Assert-Coordinator ($oneSlot.Output -match 'supervises exactly 2') `
        "The refusal did not say this build supervises exactly two slots.`n$($oneSlot.Output)"
    # Both slots are declared from creation, in order. A set whose second entry
    # calls itself slot1 would be one slot authorized twice.
    $swappedPath = New-CoordinatorRequestVariant -BasePath $authPath -Name 'slot-swapped' `
        -Mutate { param($r) $r.slots.declared[1].name = 'slot1' }
    $swapped = Invoke-Coordinator -RequestPath $swappedPath -Target 'slot1Authorized'
    Assert-Coordinator ($swapped.ExitCode -eq 2) `
        "A set naming slot1 twice exited $($swapped.ExitCode) rather than refusing."
    Assert-Coordinator ($swapped.Output -match "position reserved for 'slot2'") `
        "The refusal did not name the position.`n$($swapped.Output)"
    # Two slots that share a state root are one slot run twice into one place.
    $sharedPath = New-CoordinatorRequestVariant -BasePath $authPath -Name 'slot-shared' `
        -Mutate { param($r) $r.slots.declared[1].stateDirName = $r.slots.declared[0].stateDirName }
    $shared = Invoke-Coordinator -RequestPath $sharedPath -Target 'slot1Authorized'
    Assert-Coordinator ($shared.ExitCode -eq 2) `
        "A set sharing a state root exited $($shared.ExitCode) rather than refusing."
    Assert-Coordinator ($shared.Output -match 'two runs that share a state root are not two runs') `
        "The refusal did not name the shared state root.`n$($shared.Output)"
    $sharedTerminalPath = New-CoordinatorRequestVariant -BasePath $authPath -Name 'slot-shared-terminal' `
        -Mutate { param($r) $r.slots.declared[1].terminalName = $r.slots.declared[0].terminalName }
    $sharedTerminal = Invoke-Coordinator -RequestPath $sharedTerminalPath -Target 'slot1Authorized'
    Assert-Coordinator ($sharedTerminal.ExitCode -eq 2) `
        "A set sharing a terminal artifact exited $($sharedTerminal.ExitCode) rather than refusing."
    # One qualification plan seals one agent, so a set naming two could never
    # reproduce the plan it was declared under.
    $twoAgentPath = New-CoordinatorRequestVariant -BasePath $authPath -Name 'slot-two-agents' `
        -Mutate { param($r) $r.slots.declared[1].reviewerScriptPath = $r.slots.declared[0].reviewerScriptPath + '.other' }
    $twoAgent = Invoke-Coordinator -RequestPath $twoAgentPath -Target 'slot1Authorized'
    Assert-Coordinator ($twoAgent.ExitCode -eq 2) `
        "A set naming two agents exited $($twoAgent.ExitCode) rather than refusing."
    # A reconciliation that closes over fewer runs than were declared is closing
    # over a set nobody declared.
    $shortReconcilePath = New-CoordinatorRequestVariant -BasePath $authPath -Name 'slot-short-reconcile' `
        -Mutate { param($r) $r.slots.reconciliation.requiredRunCount = 3 }
    $shortReconcile = Invoke-Coordinator -RequestPath $shortReconcilePath -Target 'slot1Authorized'
    Assert-Coordinator ($shortReconcile.ExitCode -eq 2) `
        "A reconciliation over the wrong run count exited $($shortReconcile.ExitCode) rather than refusing."

    # The default target is unchanged, which is what makes the rollback posture
    # real: a caller that does not ask for a slot never gets one.
    $defaultTarget = Invoke-Coordinator -RequestPath $authPath
    Assert-Coordinator ($defaultTarget.ExitCode -eq 0) 'A default-target run over a ready root failed.'
    $beforeAuthorize = Get-CoordinatorState -OutputRoot $authRoot
    Assert-Coordinator ($beforeAuthorize.state -ceq 'runSetReady') `
        "A default-target run advanced to '$($beforeAuthorize.state)'; the default must never launch."

    $authorized = Invoke-Coordinator -RequestPath $authPath -Target 'slot1Authorized'
    Assert-Coordinator ($authorized.ExitCode -eq 0) `
        "Authorizing a launch against the real plan failed (exit $($authorized.ExitCode)).`n$($authorized.Output)"
    $authState = Get-CoordinatorState -OutputRoot $authRoot
    Assert-Coordinator ($authState.state -ceq 'slot1Authorized' -and [int]$authState.sequence -eq 12) `
        "The durable state is '$($authState.state)' at sequence $($authState.sequence)."
    $authEvidence = @($authState.transitions | Where-Object { $_.state -ceq 'slot1Authorized' })[0].evidence
    Assert-Coordinator ([string]$authEvidence.planDigest -cmatch '^[0-9a-f]{64}$') `
        'The authorization committed no plan digest.'
    Assert-Coordinator ([string]$authEvidence.slotName -ceq 'slot1') `
        "The authorization names slot '$([string]$authEvidence.slotName)'."
    $readySetId = [string](@($beforeAuthorize.transitions | Where-Object { $_.state -ceq 'runSetVerified' })[0].evidence.setId)
    Assert-Coordinator ([string]$authEvidence.setId -ceq $readySetId) `
        'The authorization is not bound to the run set this preparation verified.'
    # The token's TEXT must appear nowhere durable. Its digest is the binding.
    $authStateText = [IO.File]::ReadAllText((Join-Path $authRoot 'coordinator\state.json'))
    $tokenText = ([IO.File]::ReadAllText($fixture.LaunchTokenPath)).Trim()
    Assert-Coordinator (-not $authStateText.Contains($tokenText)) `
        'The launch-authorization token was written into the durable state record.'
    Assert-Coordinator (-not $authorized.Output.Contains($tokenText)) `
        'The launch-authorization token was written to the console.'
    # Nothing was launched to get here.
    Assert-Coordinator (-not (Test-Path -LiteralPath (Join-Path $authRoot 'qualification\runs'))) `
        'Authorizing a launch created a run directory.'

    # -----------------------------------------------------------------------
    Write-Host '19/32 one supervised slot, halted and resumed at every slot state' -ForegroundColor Cyan
    $slotStates = @('slot1Authorized', 'slot1Launching', 'slot1Running', 'slot1TerminalObserved')
    $lifecycleRoot = Join-Path $sandbox 'slot-lifecycle'
    $lifecyclePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'slot-lifecycle' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $lifecycleRoot
            $r.slots.shadowSlotsEnabled = $true
        }.GetNewClosure()
    Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $lifecyclePath `
        -OutputRoot $lifecycleRoot -Label 'slot-lifecycle'
    New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'complete'
    try {
        $expectedSequence = 11
        foreach ($state in $slotStates) {
            $expectedSequence++
            $halted = Invoke-Coordinator -RequestPath $lifecyclePath -HaltAfter $state -Target 'slot1TerminalVerified'
            Assert-Coordinator ($halted.ExitCode -eq 9) `
                "Halting after '$state' did not report a deliberate halt (exit $($halted.ExitCode)).`n$($halted.Output)"
            $durable = Get-CoordinatorState -OutputRoot $lifecycleRoot
            Assert-Coordinator ($durable -and $durable.state -ceq $state) `
                "The durable state after halting at '$state' is '$(if ($durable) { $durable.state } else { 'none' })'."
            Assert-Coordinator ($durable -and [int]$durable.sequence -eq $expectedSequence) `
                "The sequence after '$state' is $(if ($durable) { $durable.sequence } else { 'none' }), not $expectedSequence."

            # Resuming to a slot state already reached must not launch a second
            # time. The attempt record is single-use, so a second launch is not a
            # wasted run but an unrecoverable one.
            $again = Invoke-Coordinator -RequestPath $lifecyclePath -Target $state
            Assert-Coordinator ($again.ExitCode -eq 0) `
                "Resuming to an already-reached '$state' failed (exit $($again.ExitCode)).`n$($again.Output)"
            Assert-Coordinator ($again.Output -match "skip $state") `
                "Resuming to an already-reached '$state' did not report it as already recorded."
            $repeat = Get-CoordinatorState -OutputRoot $lifecycleRoot
            Assert-Coordinator ([int]$repeat.sequence -eq $expectedSequence) `
                "Resuming to an already-reached '$state' advanced the sequence to $($repeat.sequence)."
            $attempts = @(Get-ChildItem -LiteralPath (Join-Path $lifecycleRoot 'qualification\stub') `
                    -Filter 'slot*-attempt.json' -File -ErrorAction SilentlyContinue)
            Assert-Coordinator ($attempts.Count -le 1) `
                "After resuming at '$state' the run set carries $($attempts.Count) attempt records."
        }

        # The identity a resumed run would adopt has to be durable BEFORE the
        # wait, or a coordinator killed during an hour-long slot cannot name what
        # it left behind.
        $runningState = Get-CoordinatorState -OutputRoot $lifecycleRoot
        $runningEvidence = @($runningState.transitions | Where-Object { $_.state -ceq 'slot1Running' })[0].evidence
        Assert-Coordinator ([int]$runningEvidence.child.childProcessId -gt 0) `
            'The running record carries no child process id.'
        # Read as text, not through ConvertFrom-Json: PowerShell turns an ISO-8601
        # string into a DateTime, and what is under test here is the shape the
        # record actually carries.
        $runningRaw = [IO.File]::ReadAllText((Join-Path $lifecycleRoot 'coordinator\state.json'))
        Assert-Coordinator ($runningRaw -cmatch '"childStartedAtUtc"\s*:\s*"\d{4}-\d{2}-\d{2}T[\d:.]+Z"') `
            'The running record carries no child start time, so a recycled pid could be mistaken for the child.'
        Assert-Coordinator ([string]$runningEvidence.child.childRequestSha256 -cmatch '^[0-9a-f]{64}$') `
            'The running record carries no child request digest.'

        $verified = Invoke-Coordinator -RequestPath $lifecyclePath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($verified.ExitCode -eq 0) `
            "The supervised slot did not reach a verified terminal (exit $($verified.ExitCode)).`n$($verified.Output)"
        $finalState = Get-CoordinatorState -OutputRoot $lifecycleRoot
        Assert-Coordinator ($finalState.state -ceq 'slot1TerminalVerified' -and [int]$finalState.sequence -eq 16) `
            "The durable state is '$($finalState.state)' at sequence $($finalState.sequence)."
        Assert-Coordinator (@($finalState.transitions).Count -eq 16) `
            "The state records $(@($finalState.transitions).Count) transitions rather than sixteen."

        $slotAudit = Get-Content -LiteralPath (Join-Path $lifecycleRoot 'coordinator\audit.json') -Raw |
            ConvertFrom-Json -Depth 32
        Assert-Coordinator ([int]$slotAudit.declaredSlotCount -eq 2) `
            "The audit declares $($slotAudit.declaredSlotCount) slot(s) rather than two."
        Assert-Coordinator ([int]$slotAudit.supervisedSlotCount -eq 1) `
            "The audit reports $($slotAudit.supervisedSlotCount) supervised slot(s) after slot1 alone."
        Assert-Coordinator ([int]$slotAudit.slotLaunchCount -eq 0) `
            ("The readiness census reports $($slotAudit.slotLaunchCount) attempt records at run-set-ready; " +
                'a ready run set is one where nothing has run yet.')
        Assert-Coordinator ([int]$slotAudit.preparationAttemptRecordCount -eq 0) `
            'The readiness census claims a reviewer process had already run.'
        Assert-Coordinator ([int]$slotAudit.providerWriteCount -eq 0 -and
            [string]$slotAudit.deliveryMode -ceq 'previewOnly') `
            'The audit does not record a preview-only run with no provider writes.'
        Assert-Coordinator (-not [bool]$slotAudit.reconciliationPerformed) `
            'The audit claims a reconciliation that this run never authorized.'
        $slotOne = @($slotAudit.slots)[0]
        Assert-Coordinator ([int]$slotOne.slotOrdinal -eq 1 -and [string]$slotOne.slotName -ceq 'slot1') `
            'The audit does not index the first slot by its ordinal and name.'
        Assert-Coordinator ([string]$slotOne.slotTerminalStatus -ceq 'complete') `
            "The audit reports terminal status '$([string]$slotOne.slotTerminalStatus)'."
        Assert-Coordinator ([int]$slotOne.slotAttemptCount -eq 1) `
            "The audit reports $($slotOne.slotAttemptCount) slot attempts rather than one."
        Assert-Coordinator ([string]$slotOne.slotTerminalSha256 -cmatch '^[0-9a-f]{64}$') `
            'The audit indexes the terminal evidence without a digest.'

        # Replaying a finished lifecycle is a no-op, including its single launch.
        $slotReplay = Invoke-Coordinator -RequestPath $lifecyclePath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($slotReplay.ExitCode -eq 0) 'Replaying a completed slot lifecycle failed.'
        Assert-Coordinator ([int](Get-CoordinatorState -OutputRoot $lifecycleRoot).sequence -eq 16) `
            'Replaying a completed slot lifecycle advanced the sequence.'
        $replayAttempts = @(Get-ChildItem -LiteralPath (Join-Path $lifecycleRoot 'qualification\stub') `
                -Filter 'slot*-attempt.json' -File)
        Assert-Coordinator ($replayAttempts.Count -eq 1) `
            "Replaying a completed slot lifecycle left $($replayAttempts.Count) attempt records."

        # -------------------------------------------------------------------
        # A killed coordinator, mid-slot, is the fault the two-phase supervisor
        # exists for. The child is left alive, the record already names it, and
        # the resumed run has to adopt it rather than start a second one.
        $killRoot = Join-Path $sandbox 'slot-kill'
        $killPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'slot-kill' `
            -Mutate {
                param($r)
                & $setOutputRoot -Request $r -Root $killRoot
                $r.slots.shadowSlotsEnabled = $true
            }.GetNewClosure()
        Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $killPath `
            -OutputRoot $killRoot -Label 'slot-kill'
        New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'complete' `
            -SlotTimeoutSeconds 300 -PerCallTimeoutSeconds 300 -RunDelaySeconds 30
        Assert-Coordinator ((Invoke-Coordinator -RequestPath $killPath -HaltAfter 'slot1Launching' `
                    -Target 'slot1TerminalVerified').ExitCode -eq 9) `
            'The slot-kill setup did not halt with a launch due.'

        # Now run the launch in a process this suite can kill, and kill it while
        # the child is alive.
        $killJob = Start-Process -FilePath 'dotnet' -PassThru -WindowStyle Hidden -ArgumentList @(
            $script:CoordinatorDll, '--request', $killPath, '--target', 'slot1TerminalVerified')
        $killed = $false
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(120)
            while ([DateTime]::UtcNow -lt $deadline) {
                $probe = Get-CoordinatorState -OutputRoot $killRoot
                if ($probe -and $probe.state -ceq 'slot1Running') { break }
                Start-Sleep -Milliseconds 250
            }
            $atKill = Get-CoordinatorState -OutputRoot $killRoot
            Assert-Coordinator ($atKill -and $atKill.state -ceq 'slot1Running') `
                "The launch never recorded a running slot to kill (state '$(if ($atKill) { $atKill.state } else { 'none' })')."
            if (-not $killJob.HasExited) { Stop-Process -Id $killJob.Id -Force -ErrorAction SilentlyContinue }
            $killJob.WaitForExit(60000) | Out-Null
            $killed = $true
        }
        finally {
            if (-not $killed -and -not $killJob.HasExited) {
                Stop-Process -Id $killJob.Id -Force -ErrorAction SilentlyContinue
            }
        }
        $afterKill = Get-CoordinatorState -OutputRoot $killRoot
        Assert-Coordinator ($afterKill.state -ceq 'slot1Running') `
            "A coordinator killed mid-slot left the record at '$($afterKill.state)'."
        $resumed = Invoke-Coordinator -RequestPath $killPath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($resumed.ExitCode -eq 0) `
            "The resumed run did not finish the slot it adopted (exit $($resumed.ExitCode)).`n$($resumed.Output)"
        Assert-Coordinator ($resumed.Output -match 'resume supervising recorded slot1 child') `
            "The resumed run did not report adopting the recorded child.`n$($resumed.Output)"
        $killAttempts = @(Get-ChildItem -LiteralPath (Join-Path $killRoot 'qualification\stub') `
                -Filter 'slot*-attempt.json' -File)
        Assert-Coordinator ($killAttempts.Count -eq 1) `
            "A kill and resume left $($killAttempts.Count) attempt records; the slot was launched twice."
        $killAudit = Get-Content -LiteralPath (Join-Path $killRoot 'coordinator\audit.json') -Raw |
            ConvertFrom-Json -Depth 32
        Assert-Coordinator ([bool](@($killAudit.slots)[0].slotSupervision.observedAcrossRestart)) `
            'The audit does not record that the observation crossed a restart.'

        # A resume that finds the attempt already spent but no running record is
        # the one case where relaunching would be catastrophic, so it refuses.
        $spentRoot = Join-Path $sandbox 'slot-spent'
        $spentPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'slot-spent' `
            -Mutate {
                param($r)
                & $setOutputRoot -Request $r -Root $spentRoot
                $r.slots.shadowSlotsEnabled = $true
            }.GetNewClosure()
        Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $spentPath `
            -OutputRoot $spentRoot -Label 'spent-authorization'
        New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'complete'
        Assert-Coordinator ((Invoke-Coordinator -RequestPath $spentPath -HaltAfter 'slot1Launching' `
                    -Target 'slot1TerminalVerified').ExitCode -eq 9) `
            'The spent-authorization setup did not halt with a launch due.'
        # Something else consumes the single-use launch behind the coordinator.
        $spentStub = Join-Path $spentRoot 'qualification\stub'
        [void](New-Item -ItemType Directory -Force -Path $spentStub)
        [IO.File]::WriteAllText((Join-Path $spentStub 'slot1-attempt.json'), '{"slot":"slot1"}')
        $spentRun = Invoke-Coordinator -RequestPath $spentPath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($spentRun.ExitCode -eq 2) `
            "A launch over a spent authorization exited $($spentRun.ExitCode) rather than refusing."
        Assert-Coordinator ($spentRun.Output -match 'already been used|single-use launch') `
            "The refusal did not name the spent authorization.`n$($spentRun.Output)"
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # -----------------------------------------------------------------------
    Write-Host '20/32 slot terminal endings and the slot fault matrix' -ForegroundColor Cyan
    # Every case gets its own output root, because a slot's launch authorization
    # is single-use and a root that has spent it can never be reused.
    $slotCases = @(
        @{ Name = 'failed'; Mode = 'failed'; Exit = 5; State = 'slot1TerminalFailed'; Pattern = '' },
        @{ Name = 'timedout'; Mode = 'timedOut'; Exit = 5; State = 'slot1TerminalTimedOut'; Pattern = '' },
        @{ Name = 'noterminal'; Mode = 'noTerminal'; Exit = 2; State = 'slot1Running'
            Pattern = 'produced no terminal evidence' },
        @{ Name = 'nonzero'; Mode = 'nonzeroNoTerminal'; Exit = 4; State = 'slot1Running'
            Pattern = 'does not exist|left no result' },
        @{ Name = 'wrongslot'; Mode = 'wrongSlot'; Exit = 2; State = 'slot1TerminalObserved'
            Pattern = 'terminalSlot|is slot' },
        @{ Name = 'wrongsetid'; Mode = 'wrongSetId'; Exit = 2; State = 'slot1TerminalObserved'
            Pattern = 'terminalSetId|run set' },
        @{ Name = 'contradiction'; Mode = 'contradictoryTimeout'; Exit = 2; State = 'slot1TerminalObserved'
            Pattern = 'contradict each other' },
        @{ Name = 'writable'; Mode = 'writableTerminal'; Exit = 2; State = 'slot1TerminalObserved'
            Pattern = 'writable' },
        @{ Name = 'twoattempts'; Mode = 'secondAttempt'; Exit = 2; State = 'slot1TerminalObserved'
            Pattern = 'exactly 1 launch' }
    )
    foreach ($case in $slotCases) {
        $caseRoot = Join-Path $sandbox "slot-$($case.Name)"
        $casePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name "slot-$($case.Name)" `
            -Mutate {
                param($r)
                & $setOutputRoot -Request $r -Root $caseRoot
                $r.slots.shadowSlotsEnabled = $true
            }.GetNewClosure()
        Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $casePath `
            -OutputRoot $caseRoot -Label "'$($case.Name)'"
        New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode $case.Mode
        try {
            $run = Invoke-Coordinator -RequestPath $casePath -Target 'slot1TerminalVerified'
            Assert-Coordinator ($run.ExitCode -eq $case.Exit) `
                "The '$($case.Name)' slot exited $($run.ExitCode) rather than $($case.Exit).`n$($run.Output)"
            $state = Get-CoordinatorState -OutputRoot $caseRoot
            Assert-Coordinator ($state -and $state.state -ceq $case.State) `
                "The '$($case.Name)' slot left the record at '$(if ($state) { $state.state } else { 'none' })' rather than '$($case.State)'."
            if ($case.Pattern) {
                Assert-Coordinator ($run.Output -match $case.Pattern) `
                    "The '$($case.Name)' refusal did not explain itself.`n$($run.Output)"
            }
            # Whatever happened, exactly one launch happened.
            $caseAttempts = @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'qualification\stub') `
                    -Filter 'slot1-attempt.json' -File -ErrorAction SilentlyContinue)
            Assert-Coordinator ($caseAttempts.Count -eq 1) `
                "The '$($case.Name)' slot left $($caseAttempts.Count) slot1 attempt records."
        }
        finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }
    }

    # A child that never stops is stopped by the supervisor, and the kill leaves
    # no terminal evidence, so the run refuses rather than summarising a run it
    # ended itself. The plan's own budget is what bounds it.
    $hangRoot = Join-Path $sandbox 'slot-hang'
    $hangPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'slot-hang' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $hangRoot
            $r.slots.shadowSlotsEnabled = $true
            foreach ($declared in @($r.slots.declared)) { $declared.supervisionGraceSeconds = 30 }
            $r.slots.reconciliation.supervisionGraceSeconds = 30
        }.GetNewClosure()
    Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $hangPath `
        -OutputRoot $hangRoot -Label 'slot-hang'
    New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'hang' `
        -SlotTimeoutSeconds 1 -PerCallTimeoutSeconds 1
    try {
        $hangRun = Invoke-Coordinator -RequestPath $hangPath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($hangRun.ExitCode -eq 4) `
            "A hung slot exited $($hangRun.ExitCode) rather than reporting a stopped child.`n$($hangRun.Output)"
        Assert-Coordinator ($hangRun.Output -match 'hardDeadlineKill|activityDeadlineKill') `
            "The refusal did not name the deadline kill.`n$($hangRun.Output)"
        $hangState = Get-CoordinatorState -OutputRoot $hangRoot
        Assert-Coordinator ($hangState.state -ceq 'slot1Running') `
            "A hung slot left the record at '$($hangState.state)'."
        # The kill is a TREE kill: nothing the child started is still running.
        Start-Sleep -Seconds 2
        Assert-Coordinator ((Get-DescendantPwshCount -SandboxToken $sandboxToken) -eq 0) `
            'The deadline kill left a supervised child running.'
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # Terminal evidence rewritten between the observation and the verification.
    # The artifact is written read-only by its owner, so a changed digest is a
    # tamper rather than a race, and the run refuses on its own committed digest.
    $tamperRoot = Join-Path $sandbox 'slot-tamper'
    $tamperPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'slot-tamper' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $tamperRoot
            $r.slots.shadowSlotsEnabled = $true
        }.GetNewClosure()
    Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $tamperPath `
        -OutputRoot $tamperRoot -Label 'slot-tamper'
    New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'complete'
    try {
        Assert-Coordinator ((Invoke-Coordinator -RequestPath $tamperPath -HaltAfter 'slot1TerminalObserved' `
                    -Target 'slot1TerminalVerified').ExitCode -eq 9) `
            'The slot-tamper setup did not halt after observing terminal evidence.'
        $tamperTarget = Join-Path $tamperRoot 'qualification\stub\slot1-terminal.json'
        (Get-Item -LiteralPath $tamperTarget).IsReadOnly = $false
        $tamperText = [IO.File]::ReadAllText($tamperTarget)
        [IO.File]::WriteAllText($tamperTarget, $tamperText + ' ')
        (Get-Item -LiteralPath $tamperTarget).IsReadOnly = $true
        $tamperRun = Invoke-Coordinator -RequestPath $tamperPath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($tamperRun.ExitCode -eq 2) `
            "Rewritten terminal evidence exited $($tamperRun.ExitCode) rather than refusing.`n$($tamperRun.Output)"
        Assert-Coordinator ($tamperRun.Output -match 'digests to .* and this run observed') `
            "The refusal did not name the changed evidence.`n$($tamperRun.Output)"
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # -----------------------------------------------------------------------
    Write-Host '21/32 typed corpus staging from an immutable source' -ForegroundColor Cyan
    # A SECOND sandbox, whose corpus is built as a read-only source and whose
    # request names a corpus root that does not exist. This is the condition the
    # preparation this slice replaces died on, made ordinary.
    $stageFixture = New-ShadowCoordinatorFixture -Sandbox (Join-Path $sandbox 'stage-fixture') `
        -ToolkitRoot $RepoRoot -StageCorpus
    $stageSourceRoot = [string]$stageFixture.SourceCorpusRoot
    $stageDestinationRoot = [string]$stageFixture.CorpusRoot
    $stageParent = Split-Path $stageDestinationRoot -Parent

    $sourceFiles = @([IO.Directory]::EnumerateFiles($stageSourceRoot, '*', [IO.SearchOption]::AllDirectories))
    $writableSources = @($sourceFiles | Where-Object { -not (Get-Item -LiteralPath $_ -Force).IsReadOnly })
    Assert-Coordinator ($writableSources.Count -eq 0) `
        "$($writableSources.Count) source corpus file(s) are writable; the source is supposed to be immutable."
    Assert-Coordinator (-not (Test-Path -LiteralPath $stageDestinationRoot)) `
        'The staged corpus root existed before the coordinator built it.'
    $sourceIndexBefore = (Get-FileHash -LiteralPath (Join-Path $stageSourceRoot 'corpus-index.json') `
            -Algorithm SHA256).Hash.ToLowerInvariant()

    # Halt after staging: the corpus exists in a scratch directory and nowhere a
    # reader would look. Nothing has been published.
    $halted = Invoke-Coordinator -RequestPath $stageFixture.RequestPath -HaltAfter 'corpusStaging'
    Assert-Coordinator ($halted.ExitCode -eq 9) `
        "Halting after staging exited $($halted.ExitCode).`n$($halted.Output)"
    Assert-Coordinator (-not (Test-Path -LiteralPath $stageDestinationRoot)) `
        'The coordinator published a corpus before reaching the publish transition.'
    $stagedDirs = @(Get-ChildItem -LiteralPath $stageParent -Directory -Force |
            Where-Object { $_.Name -like '.corpus-staging-*' })
    Assert-Coordinator ($stagedDirs.Count -eq 1) `
        "The halted staging left $($stagedDirs.Count) staging directories rather than one."
    $journalPath = Join-Path $stageFixture.OutputRoot 'coordinator\corpus-stage.journal.json'
    Assert-Coordinator (Test-Path -LiteralPath $journalPath -PathType Leaf) `
        'The staging wrote no journal naming the directory it owns.'
    if ($stagedDirs.Count -eq 1) {
        # The witness is written FIRST, so a staging directory that exists at all
        # already says which subject it is for. The old path wrote it last, by
        # overwriting an inherited one, and inherited whatever it had copied.
        Assert-Coordinator (Test-Path -LiteralPath (Join-Path $stagedDirs[0].FullName 'identity.json') -PathType Leaf) `
            'The halted staging directory carries no identity witness.'
        # The index is generated last, from the declaration, and the halt is after
        # the whole staging rank - so it is here, and it is already the exact
        # bytes the declaration bound, before anything was published.
        $haltedIndex = Join-Path $stagedDirs[0].FullName 'corpus-index.json'
        Assert-Coordinator (Test-Path -LiteralPath $haltedIndex -PathType Leaf) `
            'The halted staging directory carries no generated corpus index.'
        Assert-Coordinator ((Get-FileHash -LiteralPath $haltedIndex -Algorithm SHA256).Hash.ToLowerInvariant() `
                -ceq [string]$stageFixture.CorpusIndexSha256) `
            'The staged index does not digest to what the declaration bound.'
    }

    # Resume: publish, finalize read-only, and carry on to a signed run set.
    $stageRun = Invoke-Coordinator -RequestPath $stageFixture.RequestPath
    Assert-Coordinator ($stageRun.ExitCode -eq 0) `
        "The staged preparation did not reach run-set-ready (exit $($stageRun.ExitCode)).`n$($stageRun.Output)"
    $stageState = Get-CoordinatorState -OutputRoot $stageFixture.OutputRoot
    Assert-Coordinator ($stageState.state -ceq 'runSetReady' -and [int]$stageState.sequence -eq 11) `
        "The staged preparation stands at '$($stageState.state)' at sequence $($stageState.sequence)."

    $stagedIndexPath = Join-Path $stageDestinationRoot 'corpus-index.json'
    $stagedIndexSha = (Get-FileHash -LiteralPath $stagedIndexPath -Algorithm SHA256).Hash.ToLowerInvariant()
    # The typed stager generated this index from the declaration alone; the
    # fixture derived the same digest through the toolkit's PowerShell
    # canonicalizer. Byte agreement across the two implementations is the whole
    # parity claim, and it is asserted rather than assumed.
    Assert-Coordinator ($stagedIndexSha -ceq [string]$stageFixture.CorpusIndexSha256) `
        "The staged corpus index digests to $stagedIndexSha and the declaration bound $($stageFixture.CorpusIndexSha256)."

    $publishedFiles = @([IO.Directory]::EnumerateFiles($stageDestinationRoot, '*', [IO.SearchOption]::AllDirectories))
    Assert-Coordinator ($publishedFiles.Count -eq ([int]$stageFixture.StagePayloadCount + 1)) `
        "The published corpus holds $($publishedFiles.Count) files rather than $([int]$stageFixture.StagePayloadCount + 1)."
    $writablePublished = @($publishedFiles | Where-Object { -not (Get-Item -LiteralPath $_ -Force).IsReadOnly })
    Assert-Coordinator ($writablePublished.Count -eq 0) `
        "$($writablePublished.Count) published corpus file(s) are writable after finalization."

    # The binary payload is copied, not decoded. It opens with the byte order
    # mark sequence and carries bytes no UTF-8 reader accepts, so any round trip
    # through a string would change it.
    $stagedBlob = [IO.File]::ReadAllBytes((Join-Path $stageDestinationRoot 'capture\transport-blob.bin'))
    $sourceBlob = [IO.File]::ReadAllBytes((Join-Path $stageSourceRoot 'capture\transport-blob.bin'))
    Assert-Coordinator ([Convert]::ToHexString($stagedBlob) -ceq [Convert]::ToHexString($sourceBlob)) `
        'The staged binary payload is not byte-identical to its source.'

    Assert-Coordinator (-not (Test-Path -LiteralPath $journalPath)) `
        'The staging journal survived a completed publication.'
    $residue = @(Get-ChildItem -LiteralPath $stageParent -Directory -Force |
            Where-Object { $_.Name -like '.corpus-staging-*' })
    Assert-Coordinator ($residue.Count -eq 0) `
        "A completed publication left $($residue.Count) staging director(ies) behind."
    $stageResultPath = Join-Path $stageFixture.OutputRoot 'coordinator\corpus-stage.result.json'
    Assert-Coordinator (Test-Path -LiteralPath $stageResultPath -PathType Leaf) `
        'The publication wrote no stage result.'
    $stageResult = Get-Content -LiteralPath $stageResultPath -Raw | ConvertFrom-Json -Depth 16
    Assert-Coordinator ($stageResult.contractVersion -ceq 'devpilot.shadow-run-coordinator.corpus-stage-result.v1') `
        "The stage result declares '$($stageResult.contractVersion)'."
    Assert-Coordinator ([int]$stageResult.payloadCount -eq [int]$stageFixture.StagePayloadCount) `
        "The stage result reports $($stageResult.payloadCount) payloads rather than $($stageFixture.StagePayloadCount)."

    # The source was only ever read.
    $sourceIndexAfter = (Get-FileHash -LiteralPath (Join-Path $stageSourceRoot 'corpus-index.json') `
            -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Coordinator ($sourceIndexAfter -ceq $sourceIndexBefore) `
        'The source corpus changed while it was being staged from.'
    $sourceAfter = @([IO.Directory]::EnumerateFiles($stageSourceRoot, '*', [IO.SearchOption]::AllDirectories))
    Assert-Coordinator ($sourceAfter.Count -eq $sourceFiles.Count) `
        "The source corpus holds $($sourceAfter.Count) files rather than the $($sourceFiles.Count) it started with."

    # Replayed, a published corpus is neither rebuilt nor rewritten.
    $stageReplay = Invoke-Coordinator -RequestPath $stageFixture.RequestPath
    Assert-Coordinator ($stageReplay.ExitCode -eq 0) `
        "Replaying a staged preparation failed.`n$($stageReplay.Output)"
    Assert-Coordinator ((Get-FileHash -LiteralPath $stagedIndexPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $stagedIndexSha) `
        'Replaying a staged preparation rewrote the published corpus.'

    # -----------------------------------------------------------------------
    Write-Host '22/32 corpus staging fault matrix' -ForegroundColor Cyan
    $stageInputs = Split-Path ([string]$stageFixture.StageRequestPath) -Parent
    $faultRoot = Join-Path $sandbox 'stage-faults'
    [void](New-Item -ItemType Directory -Force -Path $faultRoot)

    function New-CoordinatorStageVariant {
        <#
        .SYNOPSIS
            Writes a coordinator request and the stage declaration it binds, with
            one of the two mutated, into a fresh output root and a fresh corpus
            destination.

        .DESCRIPTION
            The declaration's digest is recomputed and rebound, because the point
            of every fault below is a declaration the coordinator ACCEPTS as
            authentic and then refuses on its content. A variant that failed the
            digest check would prove only that the digest check works.
        #>
        param(
            [Parameter(Mandatory)][string]$BasePath,
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$Root,
            [scriptblock]$MutateStage,
            [scriptblock]$MutateRequest,
            [string]$Destination = ''
        )
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $request = Get-Content -LiteralPath $BasePath -Raw | ConvertFrom-Json -Depth 32
        $stage = Get-Content -LiteralPath ([string]$request.corpusStage.requestPath) -Raw | ConvertFrom-Json -Depth 32

        $outputRoot = Join-Path $Root "$Name-output"
        $corpusRoot = $(if ($Destination) { $Destination } else { Join-Path $Root "$Name-corpus" })
        $request.output.root = $outputRoot
        $request.corpus.root = $corpusRoot
        $stage.target.outputRoot = $outputRoot
        $stage.target.corpusRoot = $corpusRoot
        if ($MutateStage) { & $MutateStage $stage }

        $stagePath = Join-Path $Root "corpus-stage-$Name.json"
        [IO.File]::WriteAllBytes($stagePath,
            $utf8.GetBytes((ConvertTo-Json -InputObject $stage -Depth 32 -Compress:$false)))
        $request.corpusStage.requestPath = $stagePath
        $request.corpusStage.requestSha256 = (Get-FileHash -LiteralPath $stagePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($MutateRequest) { & $MutateRequest $request }

        $path = Join-Path $Root "request-$Name.json"
        [IO.File]::WriteAllBytes($path,
            $utf8.GetBytes((ConvertTo-Json -InputObject $request -Depth 32 -Compress:$false)))
        return [pscustomobject][ordered]@{
            RequestPath = $path
            StagePath = $stagePath
            OutputRoot = $outputRoot
            CorpusRoot = $corpusRoot
        }
    }

    function Assert-StageRefusal {
        <#
        .SYNOPSIS
            Runs one staging fault and holds it to the same three properties
            every refusal must have: a contract exit, a refusal that names the
            fault, and nothing published or left behind.
        #>
        param(
            [Parameter(Mandatory)]$Variant,
            [Parameter(Mandatory)][string]$Match,
            [Parameter(Mandatory)][string]$Label
        )
        $run = Invoke-Coordinator -RequestPath $Variant.RequestPath -Target 'corpusValidated'
        Assert-Coordinator ($run.ExitCode -eq 2) `
            "The '$Label' staging fault exited $($run.ExitCode) rather than refusing.`n$($run.Output)"
        Assert-Coordinator ($run.Output -match $Match) `
            "The '$Label' refusal does not name the fault.`n$($run.Output)"
        Assert-Coordinator (-not (Test-Path -LiteralPath $Variant.CorpusRoot)) `
            "The '$Label' staging fault published a corpus anyway."
        $parent = Split-Path $Variant.CorpusRoot -Parent
        $left = @()
        if (Test-Path -LiteralPath $parent -PathType Container) {
            $left = @(Get-ChildItem -LiteralPath $parent -Directory -Force |
                    Where-Object { $_.Name -like '.corpus-staging-*' })
        }
        Assert-Coordinator ($left.Count -eq 0) `
            "The '$Label' staging fault left $($left.Count) staging director(ies) behind."
        return $run
    }

    # A destination that already exists is never merged into, written over, or
    # adopted. This is also the concurrency resolution: the loser of a race sees
    # exactly this.
    $collision = New-CoordinatorStageVariant -BasePath $stageFixture.RequestPath -Name 'collision' -Root $faultRoot
    [void](New-Item -ItemType Directory -Force -Path $collision.CorpusRoot)
    $collisionRun = Invoke-Coordinator -RequestPath $collision.RequestPath -Target 'corpusValidated'
    Assert-Coordinator ($collisionRun.ExitCode -eq 2) `
        "A destination collision exited $($collisionRun.ExitCode) rather than refusing.`n$($collisionRun.Output)"
    Assert-Coordinator ($collisionRun.Output -match 'already exists') `
        "The destination collision refusal does not name the collision.`n$($collisionRun.Output)"
    Assert-Coordinator (@(Get-ChildItem -LiteralPath $collision.CorpusRoot -Force).Count -eq 0) `
        'The refused staging wrote into the directory that was already there.'

    # A source rewritten after the declaration was written. The digest is
    # computed over the bytes that were actually read, so this cannot pass.
    $mutated = New-CoordinatorStageVariant -BasePath $stageFixture.RequestPath -Name 'mutated-source' -Root $faultRoot `
        -MutateStage {
            param($s)
            $copy = Join-Path $faultRoot 'mutated-alpha.txt'
            [IO.File]::WriteAllBytes($copy, ([Text.UTF8Encoding]::new($false, $true)).GetBytes('not the declared bytes'))
            foreach ($payload in $s.payloads) {
                if ($payload.path -ceq 'files/alpha.txt') { $payload.sourcePath = $copy }
            }
        }.GetNewClosure()
    [void](Assert-StageRefusal -Variant $mutated -Match 'files/alpha.txt' -Label 'source mutated after declaration')

    # A byte order mark on a payload declared textual. Refused rather than
    # stripped: stripping it would change a digest the declaration already bound.
    $bomSource = Join-Path $faultRoot 'bom-alpha.txt'
    $bomVariant = New-CoordinatorStageVariant -BasePath $stageFixture.RequestPath -Name 'bom-text' -Root $faultRoot `
        -MutateStage {
            param($s)
            foreach ($payload in $s.payloads) {
                if ($payload.path -cne 'files/alpha.txt') { continue }
                $original = [IO.File]::ReadAllBytes([string]$payload.sourcePath)
                $bytes = [byte[]]@(0xEF, 0xBB, 0xBF) + $original
                [IO.File]::WriteAllBytes($bomSource, $bytes)
                $payload.sourcePath = $bomSource
                $payload.length = $bytes.Length
                $payload.sha256 = [Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            }
        }.GetNewClosure()
    [void](Assert-StageRefusal -Variant $bomVariant -Match 'byte order mark' -Label 'byte order mark in a textual payload')

    # Bytes that are not UTF-8 at all, declared textual. The same bytes declared
    # binary are staged without complaint, which the published corpus above
    # already proved.
    $badUtf8Source = Join-Path $faultRoot 'invalid-utf8.txt'
    $badUtf8 = New-CoordinatorStageVariant -BasePath $stageFixture.RequestPath -Name 'invalid-utf8' -Root $faultRoot `
        -MutateStage {
            param($s)
            $bytes = [byte[]]@(0x68, 0x69, 0xFF, 0xFE, 0x80, 0x0A)
            [IO.File]::WriteAllBytes($badUtf8Source, $bytes)
            foreach ($payload in $s.payloads) {
                if ($payload.path -cne 'files/alpha.txt') { continue }
                $payload.sourcePath = $badUtf8Source
                $payload.length = $bytes.Length
                $payload.sha256 = [Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            }
        }.GetNewClosure()
    [void](Assert-StageRefusal -Variant $badUtf8 -Match 'not valid UTF-8' -Label 'invalid UTF-8 in a textual payload')

    # Declaration-shape faults, refused before a single byte is read.
    $shapeFaults = [Collections.Generic.List[hashtable]]::new()
    [void]$shapeFaults.Add(@{
            Name = 'missing-source'
            Match = 'does not exist'
            Mutate = { param($s) $s.payloads[0].sourcePath = (Join-Path $faultRoot 'no-such-source.json') }
        })
    [void]$shapeFaults.Add(@{
            Name = 'duplicate-path'
            Match = 'more than once'
            Mutate = { param($s) $s.payloads[2].path = [string]$s.payloads[1].path }
        })
    [void]$shapeFaults.Add(@{
            Name = 'traversal'
            Match = 'segment'
            Mutate = { param($s) $s.payloads[0].path = '../escaped.json' }
        })
    [void]$shapeFaults.Add(@{
            Name = 'index-declared'
            Match = 'corpus-index.json'
            Mutate = { param($s) $s.payloads[0].path = 'corpus-index.json' }
        })
    [void]$shapeFaults.Add(@{
            Name = 'unsorted'
            Match = 'ascending ordinal'
            Mutate = {
                param($s)
                $reordered = @($s.payloads[1], $s.payloads[0]) + @($s.payloads | Select-Object -Skip 2)
                $s.payloads = $reordered
            }
        })
    [void]$shapeFaults.Add(@{
            Name = 'witness-alias'
            Match = 'as its identity witness'
            Mutate = { param($s) $s.identity.witnessPath = 'end-identity.json' }
        })
    [void]$shapeFaults.Add(@{
            Name = 'wrong-subject'
            Match = 'identity.pullRequestId'
            Mutate = { param($s) $s.identity.pullRequestId = 424242 }
        })
    [void]$shapeFaults.Add(@{
            Name = 'wrong-commit'
            Match = 'identity.sourceCommit'
            Mutate = { param($s) $s.identity.sourceCommit = ('9' * 40) }
        })
    [void]$shapeFaults.Add(@{
            Name = 'foreign-correlation'
            Match = 'correlationId'
            Mutate = { param($s) $s.correlationId = 'shadow-someone-else' }
        })
    [void]$shapeFaults.Add(@{
            Name = 'wrong-index-digest'
            Match = 'indexSha256'
            Mutate = { param($s) $s.target.indexSha256 = ('0' * 64) }
        })
    [void]$shapeFaults.Add(@{
            Name = 'relabelled-kind'
            Match = 'corpusKind'
            Mutate = { param($s) $s.corpusKind = 'private-non-promotable-research-corpus' }
        })
    foreach ($fault in $shapeFaults) {
        $variant = New-CoordinatorStageVariant -BasePath $stageFixture.RequestPath -Name $fault.Name `
            -Root $faultRoot -MutateStage $fault.Mutate
        [void](Assert-StageRefusal -Variant $variant -Match $fault.Match -Label $fault.Name)
    }

    # A declaration whose bytes changed after the request bound their digest.
    $rebound = New-CoordinatorStageVariant -BasePath $stageFixture.RequestPath -Name 'rebound' -Root $faultRoot
    [IO.File]::AppendAllText($rebound.StagePath, ' ')
    $reboundRun = Invoke-Coordinator -RequestPath $rebound.RequestPath -Target 'corpusValidated'
    Assert-Coordinator ($reboundRun.ExitCode -eq 2) `
        "An edited stage declaration exited $($reboundRun.ExitCode) rather than refusing.`n$($reboundRun.Output)"
    Assert-Coordinator ($reboundRun.Output -match 'corpus stage request') `
        "The edited-declaration refusal does not name the declaration.`n$($reboundRun.Output)"

    # A source that cannot be read at the moment it is needed: a real IO failure
    # part way through a staging, rather than a simulated one.
    $locked = New-CoordinatorStageVariant -BasePath $stageFixture.RequestPath -Name 'locked-source' -Root $faultRoot
    $lockTarget = Join-Path $stageSourceRoot 'policy\source-v1.json'
    $lockStream = [IO.File]::Open($lockTarget, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $lockedRun = Invoke-Coordinator -RequestPath $locked.RequestPath -Target 'corpusValidated'
        Assert-Coordinator ($lockedRun.ExitCode -ne 0) `
            'A staging whose source could not be read reported success.'
        Assert-Coordinator (-not (Test-Path -LiteralPath $locked.CorpusRoot)) `
            'A staging whose source could not be read published a corpus anyway.'
        $lockedResidue = @(Get-ChildItem -LiteralPath $faultRoot -Directory -Force |
                Where-Object { $_.Name -like '.corpus-staging-*' })
        Assert-Coordinator ($lockedResidue.Count -eq 0) `
            "A failed staging left $($lockedResidue.Count) staging director(ies) behind."
    }
    finally { $lockStream.Dispose() }
    # The same request succeeds once the source is readable again, which proves
    # the failure above cleaned up after itself rather than wedging the root.
    $recovered = Invoke-Coordinator -RequestPath $locked.RequestPath -Target 'corpusValidated'
    Assert-Coordinator ($recovered.ExitCode -eq 0) `
        "The retried staging failed (exit $($recovered.ExitCode)).`n$($recovered.Output)"
    Assert-Coordinator ((Get-FileHash -LiteralPath (Join-Path $locked.CorpusRoot 'corpus-index.json') `
                -Algorithm SHA256).Hash.ToLowerInvariant() -ceq [string]$stageFixture.CorpusIndexSha256) `
        'The retried staging published a corpus with a different index.'

    # A staging directory destroyed while its owner was dead. The journal says
    # the run owns it, so a resumed run rebuilds rather than refusing forever.
    $restart = New-CoordinatorStageVariant -BasePath $stageFixture.RequestPath -Name 'restart' -Root $faultRoot
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $restart.RequestPath -HaltAfter 'corpusStaging').ExitCode -eq 9) `
        'The restart setup did not halt after staging.'
    $owned = @(Get-ChildItem -LiteralPath $faultRoot -Directory -Force |
            Where-Object { $_.Name -like '.corpus-staging-*' })
    Assert-Coordinator ($owned.Count -eq 1) `
        "The halted staging left $($owned.Count) staging directories rather than one."
    # The record still stands at corpusStaging, so the resume must find the
    # directory it committed. Removing it is a genuine loss, and the refusal says
    # so instead of quietly staging a second one.
    foreach ($directory in $owned) { Remove-Item -Recurse -Force -LiteralPath $directory.FullName }
    $lostRun = Invoke-Coordinator -RequestPath $restart.RequestPath -Target 'corpusValidated'
    Assert-Coordinator ($lostRun.ExitCode -eq 2) `
        "A resume whose staging directory was destroyed exited $($lostRun.ExitCode).`n$($lostRun.Output)"
    Assert-Coordinator ($lostRun.Output -match 'no longer holds a corpus index|is gone') `
        "The lost-staging refusal does not say what was lost.`n$($lostRun.Output)"

    # A destination that appears after staging was committed. The publish is a
    # different transition from the check, and often a different process, so the
    # window is real. Both refusals must take this run's own staging copy with
    # them: a run that has proven it will never publish has no claim on it, and
    # leaving it behind wedges the root forever because every later resume
    # re-enters the same refusal.
    $occupiedCases = [Collections.Generic.List[hashtable]]::new()
    [void]$occupiedCases.Add(@{ Name = 'occupied-no-index'; Index = ''; Match = 'holds no corpus-index.json' })
    [void]$occupiedCases.Add(@{ Name = 'occupied-other-corpus'; Index = '{"kind":"not-ours"}'; Match = 'already holds a corpus' })
    foreach ($occupied in $occupiedCases) {
        $variant = New-CoordinatorStageVariant -BasePath $stageFixture.RequestPath -Name $occupied.Name -Root $faultRoot
        Assert-Coordinator ((Invoke-Coordinator -RequestPath $variant.RequestPath -HaltAfter 'corpusStaging').ExitCode -eq 9) `
            "The $($occupied.Name) setup did not halt after staging."
        [void](New-Item -ItemType Directory -Force -Path $variant.CorpusRoot)
        if ([string]$occupied.Index -ne '') {
            [IO.File]::WriteAllBytes((Join-Path $variant.CorpusRoot 'corpus-index.json'),
                ([Text.UTF8Encoding]::new($false, $true)).GetBytes([string]$occupied.Index))
        }
        else {
            [void](New-Item -ItemType Directory -Force -Path (Join-Path $variant.CorpusRoot 'squatter'))
        }
        $blocked = Invoke-Coordinator -RequestPath $variant.RequestPath -Target 'corpusValidated'
        Assert-Coordinator ($blocked.ExitCode -eq 2) `
            "The $($occupied.Name) publish exited $($blocked.ExitCode) rather than refusing.`n$($blocked.Output)"
        Assert-Coordinator ($blocked.Output -match [regex]::Escape($occupied.Match)) `
            "The $($occupied.Name) refusal does not name what it found.`n$($blocked.Output)"
        $left = @(Get-ChildItem -LiteralPath $faultRoot -Directory -Force |
                Where-Object { $_.Name -like '.corpus-staging-*' })
        Assert-Coordinator ($left.Count -eq 0) `
            "The $($occupied.Name) refusal left $($left.Count) staging directories behind."
        Assert-Coordinator (-not (Test-Path -LiteralPath (Join-Path (Join-Path $variant.OutputRoot 'coordinator') 'corpus-stage.journal.json'))) `
            "The $($occupied.Name) refusal left its staging journal behind."
    }

    # A journal opened by somebody else is not this run's to clean up.
    $foreignJournal = New-CoordinatorStageVariant -BasePath $stageFixture.RequestPath -Name 'foreign-journal' -Root $faultRoot
    $foreignCoordinatorRoot = Join-Path $foreignJournal.OutputRoot 'coordinator'
    [void](New-Item -ItemType Directory -Force -Path $foreignCoordinatorRoot)
    $foreignDirectory = Join-Path $faultRoot 'not-ours'
    [void](New-Item -ItemType Directory -Force -Path $foreignDirectory)
    $foreignBody = [ordered]@{
        contractVersion = 'devpilot.shadow-run-coordinator.corpus-stage-journal.v1'
        kind = 'shadow-run-corpus-stage-journal'
        correlationId = 'shadow-another-run'
        requestSha256 = ('1' * 64)
        stageRequestSha256 = ('2' * 64)
        stagingDirectory = $foreignDirectory
        corpusRoot = $foreignJournal.CorpusRoot
        openedAtUtc = '20260101T000000Z'
    }
    [IO.File]::WriteAllBytes((Join-Path $foreignCoordinatorRoot 'corpus-stage.journal.json'),
        ([Text.UTF8Encoding]::new($false, $true)).GetBytes(
            (ConvertTo-Json -InputObject $foreignBody -Depth 8 -Compress:$false)))
    $foreignRun = Invoke-Coordinator -RequestPath $foreignJournal.RequestPath -Target 'corpusValidated'
    Assert-Coordinator ($foreignRun.ExitCode -eq 2) `
        "A foreign staging journal exited $($foreignRun.ExitCode) rather than refusing.`n$($foreignRun.Output)"
    Assert-Coordinator (Test-Path -LiteralPath $foreignDirectory -PathType Container) `
        'The refusal deleted a staging directory another run claimed.'

    # A destination whose parent redirects somewhere else. A corpus published
    # through a reparse point is a corpus at a path nobody declared.
    $junctionParent = Join-Path $faultRoot 'junction-parent'
    $junctionTarget = Join-Path $faultRoot 'junction-target'
    [void](New-Item -ItemType Directory -Force -Path $junctionTarget)
    $junctionMade = $true
    try { [void](New-Item -ItemType Junction -Path $junctionParent -Target $junctionTarget -ErrorAction Stop) }
    catch { $junctionMade = $false }
    if ($junctionMade) {
        $reparse = New-CoordinatorStageVariant -BasePath $stageFixture.RequestPath -Name 'reparse' -Root $faultRoot `
            -Destination (Join-Path $junctionParent 'corpus')
        $reparseRun = Invoke-Coordinator -RequestPath $reparse.RequestPath -Target 'corpusValidated'
        Assert-Coordinator ($reparseRun.ExitCode -eq 2) `
            "A reparse-point destination parent exited $($reparseRun.ExitCode).`n$($reparseRun.Output)"
        Assert-Coordinator ($reparseRun.Output -match 'reparse point') `
            "The reparse refusal does not name the reparse point.`n$($reparseRun.Output)"
    }

    # Two builders, one destination, started together. Exactly one may publish,
    # and the other must refuse rather than merge, wait or overwrite.
    $sharedDestination = Join-Path $faultRoot 'contested-corpus'
    $left = New-CoordinatorStageVariant -BasePath $stageFixture.RequestPath -Name 'race-left' `
        -Root $faultRoot -Destination $sharedDestination
    $right = New-CoordinatorStageVariant -BasePath $stageFixture.RequestPath -Name 'race-right' `
        -Root $faultRoot -Destination $sharedDestination
    $racers = @(
        (Start-Job -ScriptBlock {
                param($dll, $request)
                $out = & dotnet $dll --request $request --target 'corpusValidated' 2>&1 | Out-String
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
            } -ArgumentList $script:CoordinatorDll, $left.RequestPath),
        (Start-Job -ScriptBlock {
                param($dll, $request)
                $out = & dotnet $dll --request $request --target 'corpusValidated' 2>&1 | Out-String
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
            } -ArgumentList $script:CoordinatorDll, $right.RequestPath)
    )
    $raceResults = @($racers | Wait-Job -Timeout 300 | Receive-Job)
    $racers | Remove-Job -Force -ErrorAction SilentlyContinue
    Assert-Coordinator ($raceResults.Count -eq 2) `
        "The contested staging produced $($raceResults.Count) results rather than two."
    # Exactly one builder may CREATE the published corpus. A builder that arrives
    # to find the identical corpus already there is entitled to carry on, but it
    # is not entitled to have published it, so the move itself is what is counted.
    $movers = @($raceResults | Where-Object { $_.Output -match 'corpus-publish moved' })
    Assert-Coordinator ($movers.Count -eq 1) `
        "$($movers.Count) of two contesting builders published the same corpus."
    Assert-Coordinator ((Get-FileHash -LiteralPath (Join-Path $sharedDestination 'corpus-index.json') `
                -Algorithm SHA256).Hash.ToLowerInvariant() -ceq [string]$stageFixture.CorpusIndexSha256) `
        'The contested corpus is not the corpus either builder declared.'
    $raceResidue = @(Get-ChildItem -LiteralPath $faultRoot -Directory -Force |
            Where-Object { $_.Name -like '.corpus-staging-*' })
    Assert-Coordinator ($raceResidue.Count -eq 0) `
        "The contested staging left $($raceResidue.Count) staging director(ies) behind."

    # -----------------------------------------------------------------------
    Write-Host '23/32 two declared slots, in order, and the opaque reconciliation' -ForegroundColor Cyan
    # No model anywhere in this section. Preparation is real, the declaration is
    # real and signed, both slots are declared before either runs, and only the
    # execution and the comparison are stood in for. What is under test is the
    # ordering, the per-slot lease, and the reconciliation the set closes with.
    $setStates = @('slot1Authorized', 'slot1Launching', 'slot1Running', 'slot1TerminalObserved',
        'slot1TerminalVerified', 'slot2Authorized', 'slot2Launching', 'slot2Running',
        'slot2TerminalObserved', 'slot2TerminalVerified', 'reconciliationAuthorized',
        'reconciliationLaunching', 'reconciliationRunning', 'reconciliationTerminalObserved')
    $setRoot = Join-Path $sandbox 'slot-set'
    $setPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'slot-set' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $setRoot
            $r.slots.shadowSlotsEnabled = $true
            $r.slots.reconciliation.reconciliationEnabled = $true
        }.GetNewClosure()
    Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $setPath `
        -OutputRoot $setRoot -Label 'slot-set'
    New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'complete'
    try {
        # Ordering is proven where it can be observed: at each halt, nothing
        # later than the halted state has been launched. The set advances one
        # proven slot at a time, so slot2 has no attempt record while slot1 is
        # still in flight, and the comparison has none while either slot is.
        $slot1AttemptFile = Join-Path $setRoot 'qualification\stub\slot1-attempt.json'
        $slot2AttemptFile = Join-Path $setRoot 'qualification\stub\slot2-attempt.json'
        $reconcileAttemptFile = Join-Path $setRoot 'reconciliation\reconcile-attempt.json'
        $reconcileInputFile = Join-Path $setRoot 'coordinator\reconciliation\reconciliation-request.json'

        $expectedSequence = 11
        $stateIndex = -1
        foreach ($state in $setStates) {
            $expectedSequence++
            $stateIndex++
            $halted = Invoke-Coordinator -RequestPath $setPath -HaltAfter $state -Target 'reconciliationVerified'
            Assert-Coordinator ($halted.ExitCode -eq 9) `
                "Halting after '$state' did not report a deliberate halt (exit $($halted.ExitCode)).`n$($halted.Output)"
            $durable = Get-CoordinatorState -OutputRoot $setRoot
            Assert-Coordinator ($durable -and $durable.state -ceq $state) `
                "The durable state after halting at '$state' is '$(if ($durable) { $durable.state } else { 'none' })'."
            Assert-Coordinator ($durable -and [int]$durable.sequence -eq $expectedSequence) `
                "The sequence after '$state' is $(if ($durable) { $durable.sequence } else { 'none' }), not $expectedSequence."
            # Nothing later than the halted state has started. A launch is the one
            # thing that cannot be taken back, so each is checked on disk at every
            # point before the state that is entitled to perform it.
            if ($stateIndex -lt 2) {
                Assert-Coordinator (-not (Test-Path -LiteralPath $slot1AttemptFile)) `
                    "slot1 was launched at '$state', before the state that launches it."
            }
            if ($stateIndex -lt 7) {
                Assert-Coordinator (-not (Test-Path -LiteralPath $slot2AttemptFile)) `
                    "slot2 was launched at '$state', before slot1 finished."
            }
            if ($stateIndex -lt 11) {
                Assert-Coordinator (-not (Test-Path -LiteralPath $reconcileInputFile)) `
                    "The comparison input was published at '$state', before the set was reconcilable."
            }
            if ($stateIndex -lt 12) {
                Assert-Coordinator (-not (Test-Path -LiteralPath $reconcileAttemptFile)) `
                    "The comparison ran at '$state', before both slots were verified."
            }
            # Resuming to a state already reached must launch nothing a second
            # time. Each slot's attempt record and the set's single reconciliation
            # attempt are all one-shot, so a second launch is unrecoverable.
            $again = Invoke-Coordinator -RequestPath $setPath -Target $state
            Assert-Coordinator ($again.ExitCode -eq 0) `
                "Resuming to an already-reached '$state' failed (exit $($again.ExitCode)).`n$($again.Output)"
            Assert-Coordinator ($again.Output -match "skip $state") `
                "Resuming to an already-reached '$state' did not report it as already recorded."
            Assert-Coordinator ([int](Get-CoordinatorState -OutputRoot $setRoot).sequence -eq $expectedSequence) `
                "Resuming to an already-reached '$state' advanced the sequence."
        }

        $setVerified = Invoke-Coordinator -RequestPath $setPath -Target 'reconciliationVerified'
        Assert-Coordinator ($setVerified.ExitCode -eq 0) `
            "The two-slot set did not reconcile (exit $($setVerified.ExitCode)).`n$($setVerified.Output)"
        $setState = Get-CoordinatorState -OutputRoot $setRoot
        Assert-Coordinator ($setState.state -ceq 'reconciliationVerified' -and [int]$setState.sequence -eq 26) `
            "The durable state is '$($setState.state)' at sequence $($setState.sequence)."
        Assert-Coordinator (@($setState.transitions).Count -eq 26) `
            "The state records $(@($setState.transitions).Count) transitions rather than twenty-six."

        # Exactly one launch per slot, and exactly one comparison, counted on
        # disk rather than believed from the log.
        $setAttempts = @(Get-ChildItem -LiteralPath (Join-Path $setRoot 'qualification\stub') `
                -Filter 'slot*-attempt.json' -File)
        Assert-Coordinator ($setAttempts.Count -eq 2) `
            "The set left $($setAttempts.Count) slot attempt records rather than two."
        Assert-Coordinator ((@($setAttempts | ForEach-Object { $_.Name }) -join ',') -ceq 'slot1-attempt.json,slot2-attempt.json') `
            'The set did not launch slot1 then slot2 exactly once each.'
        $reconcileAttempts = @(Get-ChildItem -LiteralPath (Join-Path $setRoot 'reconciliation') `
                -Filter 'reconcile-attempt.json' -File)
        Assert-Coordinator ($reconcileAttempts.Count -eq 1) `
            "The set left $($reconcileAttempts.Count) reconciliation attempt records rather than one."

        # The strict versioned exchange is on disk, both halves of it.
        $reconcileExchange = Join-Path $setRoot 'coordinator\reconciliation'
        $reconcileRequestFile = Join-Path $reconcileExchange 'reconciliation-request.json'
        $reconcileSummaryFile = Join-Path $reconcileExchange 'reconciliation-summary.json'
        Assert-Coordinator (Test-Path -LiteralPath $reconcileRequestFile -PathType Leaf) `
            'The reconciliation published no versioned input.'
        Assert-Coordinator (Test-Path -LiteralPath $reconcileSummaryFile -PathType Leaf) `
            'The reconciliation produced no versioned summary.'
        $reconcileRequestDoc = Get-Content -LiteralPath $reconcileRequestFile -Raw | ConvertFrom-Json -Depth 12
        Assert-Coordinator ([string]$reconcileRequestDoc.contractVersion -ceq 'devpilot.shadow-run-coordinator.reconciliation-request.v1') `
            "The reconciliation input declares contract '$([string]$reconcileRequestDoc.contractVersion)'."
        Assert-Coordinator ([int]$reconcileRequestDoc.requiredRunCount -eq 2) `
            'The reconciliation input does not close over both declared runs.'

        $setAudit = Get-Content -LiteralPath (Join-Path $setRoot 'coordinator\audit.json') -Raw |
            ConvertFrom-Json -Depth 32
        Assert-Coordinator ([int]$setAudit.declaredSlotCount -eq 2 -and [int]$setAudit.supervisedSlotCount -eq 2) `
            "The audit reports $($setAudit.supervisedSlotCount) of $($setAudit.declaredSlotCount) slots supervised."
        Assert-Coordinator (@($setAudit.slots).Count -eq 2) `
            "The audit indexes $(@($setAudit.slots).Count) slots rather than two."
        $auditNames = @($setAudit.slots | ForEach-Object { [string]$_.slotName }) -join ','
        Assert-Coordinator ($auditNames -ceq 'slot1,slot2') `
            "The audit indexes slots '$auditNames' rather than slot1 then slot2."
        foreach ($record in @($setAudit.slots)) {
            Assert-Coordinator ([string]$record.slotTerminalStatus -ceq 'complete') `
                "The audit reports '$([string]$record.slotName)' terminal status '$([string]$record.slotTerminalStatus)'."
            Assert-Coordinator ([string]$record.slotTerminalSha256 -cmatch '^[0-9a-f]{64}$') `
                "The audit indexes '$([string]$record.slotName)' without a terminal digest."
            Assert-Coordinator ([int]$record.slotRealModelStartCount -eq 0) `
                "The audit claims '$([string]$record.slotName)' started a model."
        }
        Assert-Coordinator ([bool]$setAudit.reconciliationPerformed) `
            'The audit does not record the reconciliation this run performed.'
        Assert-Coordinator ([string]$setAudit.reconciliationStatus -ceq 'reconciled') `
            "The audit reports reconciliation status '$([string]$setAudit.reconciliationStatus)'."
        foreach ($digestField in @('reconciliationSha256', 'reconciliationReportSha256',
                'reconciliationArtifactSha256', 'reconciliationSummarySha256')) {
            Assert-Coordinator ([string]$setAudit.$digestField -cmatch '^[0-9a-f]{64}$') `
                "The audit carries no digest under '$digestField'."
        }
        Assert-Coordinator ([int]$setAudit.reconciliationRunCount -eq 2) `
            "The audit reports a comparison over $($setAudit.reconciliationRunCount) run(s)."
        Assert-Coordinator (-not [bool]$setAudit.reconciliationPromotable) `
            'The audit records a promotable reconciliation.'
        Assert-Coordinator (@($setAudit.reconciliationCounts).Count -ge 1) `
            'The audit carries an empty opaque census.'
        foreach ($count in @($setAudit.reconciliationCounts)) {
            Assert-Coordinator ([string]$count.name -cmatch '^[A-Za-z0-9]+$' -and [int]$count.value -ge 0) `
                "The opaque census carries an entry this coordinator could not have copied verbatim."
        }
        Assert-Coordinator ([int]$setAudit.providerWriteCount -eq 0 -and
            [string]$setAudit.deliveryMode -ceq 'previewOnly') `
            'A reconciled two-slot set is not recorded as a preview-only run with no provider writes.'
        Assert-Coordinator ([int]$setAudit.preparationAttemptRecordCount -eq 0) `
            'The reconciled set claims a reviewer process had already run at readiness.'
        # The two censuses are different things and the audit must publish both.
        # A stubbed set starts no model, so the real-start total is zero; what is
        # asserted here is that the total is REPORTED, that its role breakdown
        # adds up to it, and that the reviewer-process census sits beside it under
        # its own name rather than standing in for it.
        Assert-Coordinator ([bool]$setAudit.realModelStartsObserved) `
            'A set that supervised two slots did not record that it had counted their model starts.'
        Assert-Coordinator ([int]$setAudit.realModelStartCount -eq 0 -and
            ([int]$setAudit.realModelStartsGeneralist + [int]$setAudit.realModelStartsSpecialist +
                [int]$setAudit.realModelStartsVerifier) -eq [int]$setAudit.realModelStartCount) `
            'The audit does not publish a real model start census whose roles add up to its total.'
        Assert-Coordinator ([bool]$setAudit.realModelStartCensusComplete -and
            [int]$setAudit.realModelStartUnmeasuredAllowance -eq 0) `
            'A set whose slots both ended cleanly published an incomplete model start census.'
        Assert-Coordinator ([int]$setAudit.realModelStartLaunchedSlotCount -eq 2 -and
            [int]$setAudit.supervisedSlotCount -eq 2) `
            'The audit does not account for both launched slots.'
        # The THIRD census, in its own unit. A cohort's verifier ceiling is spent
        # in reciprocal ASSIGNMENTS - candidate by required model - and the
        # grouped launches that served them are a separate figure that no budget
        # is checked against. A stubbed set stands on neither, and what is
        # asserted is that both are reported rather than inferred.
        Assert-Coordinator ([bool]$setAudit.realVerifierAssignmentsObserved) `
            'A set that supervised two slots did not record that it had counted their verifier assignments.'
        Assert-Coordinator ([int]$setAudit.realVerifierAssignmentCount -eq 0 -and
            [int]$setAudit.verifierProcessStartCount -eq 0) `
            'The audit does not publish a verifier assignment census beside its grouped process count.'
        Assert-Coordinator ([bool]$setAudit.realVerifierAssignmentCensusComplete -and
            [int]$setAudit.realVerifierAssignmentUnmeasuredAllowance -eq 0) `
            'A set whose slots both ended cleanly published an incomplete verifier assignment census.'
        Assert-Coordinator (@($setAudit.realVerifierAssignmentsByModel).Count -eq 0) `
            'A set that stood on no assignment published a reciprocal breakdown anyway.'
        foreach ($record in @($setAudit.slots)) {
            Assert-Coordinator ([int]$record.slotAttemptRecordCount -eq [int]$record.slotAttemptCount) `
                "The audit does not carry '$([string]$record.slotName)' reviewer process census."
            Assert-Coordinator ([bool]$record.slotRealModelStartCensusExact) `
                "The audit reports '$([string]$record.slotName)' as ending without an exact model start census."
        }
        # This set declared no delivery, so it has no delivery transition. The
        # claim is asserted on the transition names rather than on the whole
        # record, because the reviewed plan the record carries legitimately says
        # it runs in preview-only delivery mode.
        $setStateNames = @($setState.transitions | ForEach-Object { [string]$_.state })
        Assert-Coordinator (@($setStateNames | Where-Object { $_ -match '(?i)deliver' }).Count -eq 0) `
            'A set that declared no delivery reached a delivery transition anyway.'

        # Replaying a reconciled set is a no-op, including its single comparison.
        $setReplay = Invoke-Coordinator -RequestPath $setPath -Target 'reconciliationVerified'
        Assert-Coordinator ($setReplay.ExitCode -eq 0) 'Replaying a reconciled set failed.'
        Assert-Coordinator ([int](Get-CoordinatorState -OutputRoot $setRoot).sequence -eq 26) `
            'Replaying a reconciled set advanced the sequence.'
        Assert-Coordinator (@(Get-ChildItem -LiteralPath (Join-Path $setRoot 'qualification\stub') `
                    -Filter 'slot*-attempt.json' -File).Count -eq 2) `
            'Replaying a reconciled set launched a slot again.'
        Assert-Coordinator (@(Get-ChildItem -LiteralPath (Join-Path $setRoot 'reconciliation') `
                    -Filter 'reconcile-attempt.json' -File).Count -eq 1) `
            'Replaying a reconciled set compared again.'

        # Every slot's exchange is its own. A per-slot step name is what keeps a
        # result published for one slot from being adopted as the other's answer.
        $exchangeFiles = @(Get-ChildItem -LiteralPath (Join-Path $setRoot 'coordinator\exchange') `
                -Filter '*.result.json' -File | ForEach-Object { $_.Name })
        foreach ($required in @('slot1Plan', 'slot1Run', 'slot1Verify', 'slot2Plan', 'slot2Run',
                'slot2Verify', 'reconcilePlan', 'reconcileRun', 'reconcileVerify')) {
            Assert-Coordinator (@($exchangeFiles | Where-Object { $_ -like "*-$required.result.json" }).Count -eq 1) `
                "The exchange carries no distinct result for '$required'."
        }
        # Each step's request binds to its own digest, which is what a result must
        # carry to be adopted. Two steps sharing one would be two steps that could
        # answer for each other.
        $stepDigests = @(Get-ChildItem -LiteralPath (Join-Path $setRoot 'coordinator\exchange') `
                -Filter '*.request.json' -File | ForEach-Object {
                [string]((Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 24).childRequestSha256)
            })
        Assert-Coordinator (@($stepDigests | Where-Object { $_ -cmatch '^[0-9a-f]{64}$' }).Count -eq @($stepDigests).Count) `
            'A child request was written without its binding digest.'
        Assert-Coordinator ((@($stepDigests | Sort-Object -Unique).Count) -eq @($stepDigests).Count) `
            'Two child requests share a binding digest, so one could answer for the other.'
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # -----------------------------------------------------------------------
    Write-Host '24/32 a failed slot closes the set' -ForegroundColor Cyan
    # A slot that ends unsuccessfully is a durable ending, and everything that
    # would have followed it is refused rather than skipped. Both orderings are
    # exercised: slot1 failing before slot2 is authorized, and slot2 failing
    # before the reconciliation is.
    $blockCases = @(
        @{ Name = 'slot1'; ModeSlot = 1; Mode = 'failed'; State = 'slot1TerminalFailed'
            Blocked = 'slot2Authorized'; Attempts = 1 },
        @{ Name = 'slot2'; ModeSlot = 2; Mode = 'failed'; State = 'slot2TerminalFailed'
            Blocked = 'reconciliationAuthorized'; Attempts = 2 },
        @{ Name = 'slot2timeout'; ModeSlot = 2; Mode = 'timedOut'; State = 'slot2TerminalTimedOut'
            Blocked = 'reconciliationAuthorized'; Attempts = 2 }
    )
    foreach ($case in $blockCases) {
        $blockRoot = Join-Path $sandbox "slot-block-$($case.Name)"
        $blockPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name "slot-block-$($case.Name)" `
            -Mutate {
                param($r)
                & $setOutputRoot -Request $r -Root $blockRoot
                $r.slots.shadowSlotsEnabled = $true
                $r.slots.reconciliation.reconciliationEnabled = $true
            }.GetNewClosure()
        Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $blockPath `
            -OutputRoot $blockRoot -Label "slot-block-$($case.Name)"
        New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter `
            -Mode $case.Mode -ModeSlot $case.ModeSlot
        try {
            $blockRun = Invoke-Coordinator -RequestPath $blockPath -Target 'reconciliationVerified'
            Assert-Coordinator ($blockRun.ExitCode -eq 5) `
                "A set whose $($case.Name) ended '$($case.Mode)' exited $($blockRun.ExitCode) rather than 5.`n$($blockRun.Output)"
            $blockState = Get-CoordinatorState -OutputRoot $blockRoot
            Assert-Coordinator ($blockState.state -ceq $case.State) `
                "The set stands at '$($blockState.state)' rather than '$($case.State)'."
            # And the transition that would have followed is refused on its own,
            # so the ending is a gate rather than a place the walk happened to stop.
            $blocked = Invoke-Coordinator -RequestPath $blockPath -Target $case.Blocked
            Assert-Coordinator ($blocked.ExitCode -ne 0) `
                "'$($case.Blocked)' after a $($case.Mode) slot exited 0."
            Assert-Coordinator ((Get-CoordinatorState -OutputRoot $blockRoot).state -ceq $case.State) `
                "A refused '$($case.Blocked)' advanced the record past '$($case.State)'."
            $blockAttempts = @(Get-ChildItem -LiteralPath (Join-Path $blockRoot 'qualification\stub') `
                    -Filter 'slot*-attempt.json' -File -ErrorAction SilentlyContinue)
            Assert-Coordinator ($blockAttempts.Count -eq $case.Attempts) `
                "The blocked set left $($blockAttempts.Count) attempt records rather than $($case.Attempts)."
            Assert-Coordinator (-not (Test-Path -LiteralPath (Join-Path $blockRoot 'reconciliation\reconcile-attempt.json'))) `
                'A set with an unsuccessful slot still attempted a comparison.'
            $blockAudit = Get-Content -LiteralPath (Join-Path $blockRoot 'coordinator\audit.json') -Raw |
                ConvertFrom-Json -Depth 32
            Assert-Coordinator (-not [bool]$blockAudit.reconciliationPerformed) `
                'The audit of a blocked set claims a reconciliation.'
        }
        finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }
    }

    # -----------------------------------------------------------------------
    Write-Host '25/32 reconciliation fault matrix' -ForegroundColor Cyan
    # Each case gets a fresh root, because a reconciliation is authorized once
    # and consumed when it is attempted.
    $reconcileCases = @(
        @{ Name = 'notready'; Mode = 'reconcileNotReady'; Exit = 2; State = 'slot2TerminalVerified'
            Pattern = 'readiness gate' },
        @{ Name = 'spent'; Mode = 'reconcileAttemptPresent'; Exit = 2; State = 'slot2TerminalVerified'
            Pattern = 'authorization is spent' },
        @{ Name = 'nosummary'; Mode = 'reconcileNoSummary'; Exit = 2; State = 'reconciliationRunning'
            Pattern = 'no versioned summary' },
        @{ Name = 'wrongsummary'; Mode = 'reconcileWrongSummaryPath'; Exit = 2; State = 'reconciliationRunning'
            Pattern = 'wrote its summary to' },
        # Named 'editedsummary' and not 'tampered' on purpose. The readiness tool
        # classifies a corrupt declaration by matching words against a message
        # that embeds absolute paths, so a case root containing the word
        # 'tampered' made the run set look corrupt before the case even began.
        @{ Name = 'editedsummary'; Mode = 'reconcileTamperSummary'; Exit = 2; State = 'reconciliationRunning'
            Pattern = 'summary digests to' },
        @{ Name = 'nonzero'; Mode = 'reconcileNonzeroNoSummary'; Exit = 4; State = 'reconciliationRunning'
            Pattern = 'does not exist|left no result' },
        @{ Name = 'unsigned'; Mode = 'reconcileUnsigned'; Exit = 2; State = 'reconciliationTerminalObserved'
            Pattern = 'did not verify under its key' },
        @{ Name = 'promotable'; Mode = 'reconcilePromotable'; Exit = 2; State = 'reconciliationTerminalObserved'
            Pattern = 'claims to be promotable' },
        @{ Name = 'shortruns'; Mode = 'reconcileShortRuns'; Exit = 2; State = 'reconciliationTerminalObserved'
            Pattern = 'covered 1 run' },
        @{ Name = 'emptycensus'; Mode = 'reconcileEmptyCounts'; Exit = 2; State = 'reconciliationTerminalObserved'
            Pattern = 'empty census' },
        @{ Name = 'duplicatecensus'; Mode = 'reconcileDuplicateCounts'; Exit = 2; State = 'reconciliationTerminalObserved'
            Pattern = 'twice' },
        @{ Name = 'badcountname'; Mode = 'reconcileBadCountName'; Exit = 2; State = 'reconciliationTerminalObserved'
            Pattern = 'not a plain identifier' },
        @{ Name = 'swapartifact'; Mode = 'reconcileSwapArtifact'; Exit = 2; State = 'reconciliationTerminalObserved'
            Pattern = 'artifact is at' },
        @{ Name = 'rewrittenreport'; Mode = 'reconcileRewriteReport'; Exit = 2; State = 'reconciliationTerminalObserved'
            Pattern = 'report digests to' },
        @{ Name = 'wrongsetid'; Mode = 'reconcileWrongSetId'; Exit = 2; State = 'slot2TerminalVerified'
            Pattern = 'built for run set' }
    )
    foreach ($case in $reconcileCases) {
        $caseRoot = Join-Path $sandbox "reconcile-$($case.Name)"
        $casePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name "reconcile-$($case.Name)" `
            -Mutate {
                param($r)
                & $setOutputRoot -Request $r -Root $caseRoot
                $r.slots.shadowSlotsEnabled = $true
                $r.slots.reconciliation.reconciliationEnabled = $true
            }.GetNewClosure()
        Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $casePath `
            -OutputRoot $caseRoot -Label "reconcile-$($case.Name)"
        New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode $case.Mode
        try {
            $run = Invoke-Coordinator -RequestPath $casePath -Target 'reconciliationVerified'
            Assert-Coordinator ($run.ExitCode -eq $case.Exit) `
                "The '$($case.Name)' reconciliation exited $($run.ExitCode) rather than $($case.Exit).`n$($run.Output)"
            $state = Get-CoordinatorState -OutputRoot $caseRoot
            Assert-Coordinator ($state -and $state.state -ceq $case.State) `
                "The '$($case.Name)' reconciliation left the record at '$(if ($state) { $state.state } else { 'none' })' rather than '$($case.State)'."
            if ($case.Pattern) {
                Assert-Coordinator ($run.Output -match $case.Pattern) `
                    "The '$($case.Name)' refusal did not name its cause.`n$($run.Output)"
            }
            # A refused comparison is never counted as one that happened, and it
            # never leaves a second attempt behind for a retry to trip over.
            $caseAttempts = @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'reconciliation') `
                    -Filter 'reconcile-attempt.json' -File -ErrorAction SilentlyContinue)
            Assert-Coordinator ($caseAttempts.Count -le 1) `
                "The '$($case.Name)' reconciliation left $($caseAttempts.Count) attempt records."
            $caseAuditPath = Join-Path $caseRoot 'coordinator\audit.json'
            Assert-Coordinator (Test-Path -LiteralPath $caseAuditPath -PathType Leaf) `
                "The '$($case.Name)' reconciliation wrote no audit."
            if (Test-Path -LiteralPath $caseAuditPath -PathType Leaf) {
                $caseAudit = Get-Content -LiteralPath $caseAuditPath -Raw | ConvertFrom-Json -Depth 32
                Assert-Coordinator (-not [bool]$caseAudit.reconciliationPerformed) `
                    "The '$($case.Name)' audit claims a reconciliation it refused."
                Assert-Coordinator ([int]$caseAudit.providerWriteCount -eq 0) `
                    "The '$($case.Name)' audit records a provider write."
            }
        }
        finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }
    }

    # A comparison that never returns is stopped by this coordinator on the
    # plan's own budget, and the stop leaves no summary to report.
    $reconcileHangRoot = Join-Path $sandbox 'reconcile-hang'
    $reconcileHangPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'reconcile-hang' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $reconcileHangRoot
            $r.slots.shadowSlotsEnabled = $true
            $r.slots.reconciliation.reconciliationEnabled = $true
            foreach ($declared in @($r.slots.declared)) { $declared.supervisionGraceSeconds = 30 }
            $r.slots.reconciliation.supervisionGraceSeconds = 30
        }.GetNewClosure()
    Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $reconcileHangPath `
        -OutputRoot $reconcileHangRoot -Label 'reconcile-hang'
    New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter `
        -Mode 'reconcileHang'
    try {
        $reconcileHangRun = Invoke-Coordinator -RequestPath $reconcileHangPath -Target 'reconciliationVerified'
        Assert-Coordinator ($reconcileHangRun.ExitCode -eq 4) `
            "A hung comparison exited $($reconcileHangRun.ExitCode) rather than reporting a stopped child.`n$($reconcileHangRun.Output)"
        Assert-Coordinator ($reconcileHangRun.Output -match 'HardDeadlineKill|ActivityDeadlineKill|deadline') `
            "The refusal did not name the deadline kill.`n$($reconcileHangRun.Output)"
        Assert-Coordinator ((Get-CoordinatorState -OutputRoot $reconcileHangRoot).state -ceq 'reconciliationRunning') `
            'A hung comparison advanced the durable record past the child it named.'
        Start-Sleep -Seconds 2
        Assert-Coordinator ((Get-DescendantPwshCount -SandboxToken $sandboxToken) -eq 0) `
            'The deadline kill left a comparison child running.'
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # A coordinator killed while the comparison is running has to adopt the child
    # it already named rather than start a second one.
    $reconcileKillRoot = Join-Path $sandbox 'reconcile-kill'
    $reconcileKillPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'reconcile-kill' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $reconcileKillRoot
            $r.slots.shadowSlotsEnabled = $true
            $r.slots.reconciliation.reconciliationEnabled = $true
        }.GetNewClosure()
    Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $reconcileKillPath `
        -OutputRoot $reconcileKillRoot -Label 'reconcile-kill'
    New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'complete'
    try {
        Assert-Coordinator ((Invoke-Coordinator -RequestPath $reconcileKillPath `
                    -HaltAfter 'reconciliationLaunching' -Target 'reconciliationVerified').ExitCode -eq 9) `
            'The reconcile-kill setup did not halt with a comparison due.'
        # Killed and resumed. The comparison is fast, so what this proves is that
        # a resumed run never mints a second attempt record.
        $resumedReconcile = Invoke-Coordinator -RequestPath $reconcileKillPath -Target 'reconciliationVerified'
        Assert-Coordinator ($resumedReconcile.ExitCode -eq 0) `
            "The resumed reconciliation failed (exit $($resumedReconcile.ExitCode)).`n$($resumedReconcile.Output)"
        Assert-Coordinator (@(Get-ChildItem -LiteralPath (Join-Path $reconcileKillRoot 'reconciliation') `
                    -Filter 'reconcile-attempt.json' -File).Count -eq 1) `
            'A resumed reconciliation left more than one attempt record.'
        # Re-running the whole target now that the set is consumed must not start
        # a second comparison either.
        $secondReconcile = Invoke-Coordinator -RequestPath $reconcileKillPath -Target 'reconciliationVerified'
        Assert-Coordinator ($secondReconcile.ExitCode -eq 0) 'Replaying a consumed reconciliation failed.'
        Assert-Coordinator (@(Get-ChildItem -LiteralPath (Join-Path $reconcileKillRoot 'reconciliation') `
                    -Filter 'reconcile-attempt.json' -File).Count -eq 1) `
            'Replaying a consumed reconciliation compared a second time.'
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # The window that matters: the comparison has already minted its single-use
    # attempt record, so a run that came back and re-derived the plan would find
    # the authorization spent and refuse forever. This kills the coordinator while
    # the comparison child is genuinely still running, which puts the run set
    # exactly there, and the resume must adopt the child it named rather than
    # conclude somebody else consumed the one attempt.
    $reconcileAdoptRoot = Join-Path $sandbox 'reconcile-adopt'
    $reconcileAdoptPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'reconcile-adopt' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $reconcileAdoptRoot
            $r.slots.shadowSlotsEnabled = $true
            $r.slots.reconciliation.reconciliationEnabled = $true
        }.GetNewClosure()
    Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $reconcileAdoptPath `
        -OutputRoot $reconcileAdoptRoot -Label 'reconcile-adopt'
    New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'complete' `
        -SlotTimeoutSeconds 300 -PerCallTimeoutSeconds 300 -RunDelaySeconds 20
    try {
        Assert-Coordinator ((Invoke-Coordinator -RequestPath $reconcileAdoptPath `
                    -HaltAfter 'reconciliationLaunching' -Target 'reconciliationVerified').ExitCode -eq 9) `
            'The reconcile-adopt setup did not halt with a comparison due.'
        $adoptJob = Start-Process -FilePath 'dotnet' -PassThru -WindowStyle Hidden -ArgumentList @(
            $script:CoordinatorDll, '--request', $reconcileAdoptPath, '--target', 'reconciliationVerified')
        $adoptKilled = $false
        try {
            $adoptDeadline = [DateTime]::UtcNow.AddSeconds(120)
            while ([DateTime]::UtcNow -lt $adoptDeadline) {
                $adoptProbe = Get-CoordinatorState -OutputRoot $reconcileAdoptRoot
                if ($adoptProbe -and $adoptProbe.state -ceq 'reconciliationRunning') { break }
                Start-Sleep -Milliseconds 250
            }
            $atAdoptKill = Get-CoordinatorState -OutputRoot $reconcileAdoptRoot
            Assert-Coordinator ($atAdoptKill -and $atAdoptKill.state -ceq 'reconciliationRunning') `
                "The comparison never recorded a running child to kill (state '$(if ($atAdoptKill) { $atAdoptKill.state } else { 'none' })')."
            if (-not $adoptJob.HasExited) { Stop-Process -Id $adoptJob.Id -Force -ErrorAction SilentlyContinue }
            $adoptJob.WaitForExit(60000) | Out-Null
            $adoptKilled = $true
        }
        finally {
            if (-not $adoptKilled -and -not $adoptJob.HasExited) {
                Stop-Process -Id $adoptJob.Id -Force -ErrorAction SilentlyContinue
            }
        }
        Assert-Coordinator ((Get-CoordinatorState -OutputRoot $reconcileAdoptRoot).state -ceq 'reconciliationRunning') `
            'A coordinator killed mid-comparison did not leave the record naming its child.'
        # The single-use attempt record is spent by now. Without the running
        # record this is precisely the state that could never be resumed. The
        # child outlives the coordinator that started it, so this waits for the
        # record rather than reading the instant the parent died.
        $adoptAttemptFile = Join-Path $reconcileAdoptRoot 'reconciliation\reconcile-attempt.json'
        $attemptDeadline = [DateTime]::UtcNow.AddSeconds(60)
        while ([DateTime]::UtcNow -lt $attemptDeadline -and
            -not (Test-Path -LiteralPath $adoptAttemptFile -PathType Leaf)) {
            Start-Sleep -Milliseconds 250
        }
        Assert-Coordinator (Test-Path -LiteralPath $adoptAttemptFile -PathType Leaf) `
            'The killed comparison never minted the attempt record this case exists to survive.'
        $adoptResume = Invoke-Coordinator -RequestPath $reconcileAdoptPath -Target 'reconciliationVerified'
        Assert-Coordinator ($adoptResume.ExitCode -eq 0) `
            "A reconciliation resumed over a spent attempt record failed (exit $($adoptResume.ExitCode)).`n$($adoptResume.Output)"
        Assert-Coordinator ($adoptResume.Output -match 'resume supervising recorded reconciliation child') `
            "The resumed reconciliation did not adopt the child it had named.`n$($adoptResume.Output)"
        Assert-Coordinator (@(Get-ChildItem -LiteralPath (Join-Path $reconcileAdoptRoot 'reconciliation') `
                    -Filter 'reconcile-attempt.json' -File).Count -eq 1) `
            'An adopted reconciliation minted a second attempt record.'
        Assert-Coordinator ((Get-CoordinatorState -OutputRoot $reconcileAdoptRoot).state -ceq 'reconciliationVerified') `
            'An adopted reconciliation did not reach its verified terminal.'
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # -----------------------------------------------------------------------
    Write-Host '26/32 the declared preview-only delivery, end to end' -ForegroundColor Cyan
    # The whole set, declared with a delivery from creation, walked one transition
    # at a time to its decision. What is under test is the ordering - nothing may
    # be evaluated before both slots are verified AND the comparison is - the
    # single authorization, and the two numbers that say the decision wrote
    # nowhere.
    $deliveryStates = @('reconciliationVerified', 'deliveryAuthorized', 'deliveryLaunching',
        'deliveryRunning', 'deliveryTerminalObserved')
    $deliverRoot = Join-Path $sandbox 'delivery-set'
    $deliverPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'delivery-set' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $deliverRoot
            $r.slots.shadowSlotsEnabled = $true
            $r.slots.reconciliation.reconciliationEnabled = $true
            & $addDelivery -Request $r -Root $deliverRoot
        }.GetNewClosure()
    Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $deliverPath `
        -OutputRoot $deliverRoot -Label 'delivery-set'
    New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'complete'
    try {
        $deliverAttemptFile = Join-Path $deliverRoot 'delivery\delivery-attempt.json'
        $deliverInputFile = Join-Path $deliverRoot 'coordinator\delivery\delivery-request.json'
        $deliverSummaryFile = Join-Path $deliverRoot 'coordinator\delivery\delivery-summary.json'

        # A delivery is not reachable before the comparison it closes over.
        $tooEarly = Invoke-Coordinator -RequestPath $deliverPath -HaltAfter 'slot2TerminalVerified' `
            -Target 'deliveryTerminalVerified'
        Assert-Coordinator ($tooEarly.ExitCode -eq 9) `
            "The delivery walk did not halt at the verified second slot (exit $($tooEarly.ExitCode)).`n$($tooEarly.Output)"
        Assert-Coordinator (-not (Test-Path -LiteralPath $deliverInputFile)) `
            'A delivery input was published before the set was reconciled.'
        Assert-Coordinator (-not (Test-Path -LiteralPath $deliverAttemptFile)) `
            'A delivery was evaluated before the set was reconciled.'

        $expectedSequence = 25
        $deliveryIndex = -1
        foreach ($state in $deliveryStates) {
            $expectedSequence++
            $deliveryIndex++
            $halted = Invoke-Coordinator -RequestPath $deliverPath -HaltAfter $state -Target 'deliveryTerminalVerified'
            Assert-Coordinator ($halted.ExitCode -eq 9) `
                "Halting after '$state' did not report a deliberate halt (exit $($halted.ExitCode)).`n$($halted.Output)"
            $durable = Get-CoordinatorState -OutputRoot $deliverRoot
            Assert-Coordinator ($durable -and $durable.state -ceq $state) `
                "The durable state after halting at '$state' is '$(if ($durable) { $durable.state } else { 'none' })'."
            Assert-Coordinator ($durable -and [int]$durable.sequence -eq $expectedSequence) `
                "The sequence after '$state' is $(if ($durable) { $durable.sequence } else { 'none' }), not $expectedSequence."
            # The input is published by the launching transition and not before;
            # the evaluation runs at the running transition and not before.
            if ($deliveryIndex -lt 2) {
                Assert-Coordinator (-not (Test-Path -LiteralPath $deliverInputFile)) `
                    "The delivery input was published at '$state', before the transition that publishes it."
            }
            if ($deliveryIndex -lt 3) {
                Assert-Coordinator (-not (Test-Path -LiteralPath $deliverAttemptFile)) `
                    "The delivery was evaluated at '$state', before the transition that evaluates it."
            }
            # Resuming to a state already reached must evaluate nothing a second
            # time: the delivery authorization is one-shot exactly as the
            # comparison's is.
            $again = Invoke-Coordinator -RequestPath $deliverPath -Target $state
            Assert-Coordinator ($again.ExitCode -eq 0) `
                "Resuming to an already-reached '$state' failed (exit $($again.ExitCode)).`n$($again.Output)"
            Assert-Coordinator ([int](Get-CoordinatorState -OutputRoot $deliverRoot).sequence -eq $expectedSequence) `
                "Resuming to an already-reached '$state' advanced the sequence."
        }

        $delivered = Invoke-Coordinator -RequestPath $deliverPath -Target 'deliveryTerminalVerified'
        Assert-Coordinator ($delivered.ExitCode -eq 0) `
            "The declared delivery did not verify (exit $($delivered.ExitCode)).`n$($delivered.Output)"
        $deliverState = Get-CoordinatorState -OutputRoot $deliverRoot
        Assert-Coordinator ($deliverState.state -ceq 'deliveryTerminalVerified' -and [int]$deliverState.sequence -eq 31) `
            "The durable state is '$($deliverState.state)' at sequence $($deliverState.sequence)."
        Assert-Coordinator (@($deliverState.transitions).Count -eq 31) `
            "The state records $(@($deliverState.transitions).Count) transitions rather than thirty-one."
        $deliverNames = @($deliverState.transitions | ForEach-Object { [string]$_.state })
        foreach ($required in @('deliveryAuthorized', 'deliveryLaunching', 'deliveryRunning',
                'deliveryTerminalObserved', 'deliveryTerminalVerified')) {
            Assert-Coordinator (@($deliverNames | Where-Object { $_ -ceq $required }).Count -eq 1) `
                "The durable record does not carry exactly one '$required'."
        }
        # Exactly one evaluation, counted on disk.
        Assert-Coordinator (@(Get-ChildItem -LiteralPath (Join-Path $deliverRoot 'delivery') `
                    -Filter 'delivery-attempt.json' -File).Count -eq 1) `
            'The delivery left other than one attempt record.'

        # Both halves of the strict versioned exchange, with the authorization and
        # the budget written into the file the child reads.
        Assert-Coordinator (Test-Path -LiteralPath $deliverInputFile -PathType Leaf) `
            'The delivery published no versioned input.'
        Assert-Coordinator (Test-Path -LiteralPath $deliverSummaryFile -PathType Leaf) `
            'The delivery produced no versioned summary.'
        $deliverInputDoc = Get-Content -LiteralPath $deliverInputFile -Raw | ConvertFrom-Json -Depth 12
        Assert-Coordinator ([string]$deliverInputDoc.contractVersion -ceq 'devpilot.shadow-run-coordinator.delivery-request.v1') `
            "The delivery input declares contract '$([string]$deliverInputDoc.contractVersion)'."
        Assert-Coordinator ([string]$deliverInputDoc.authorizationKind -ceq 'PreviewOnly') `
            "The delivery input authorizes '$([string]$deliverInputDoc.authorizationKind)'."
        Assert-Coordinator (-not [bool]$deliverInputDoc.commentsEnabled -and -not [bool]$deliverInputDoc.votesEnabled -and
            -not [bool]$deliverInputDoc.gatesEnabled -and [int]$deliverInputDoc.providerWriteBudget -eq 0) `
            'The delivery input authorizes a write capability or a write budget.'
        Assert-Coordinator ([string]$deliverInputDoc.reconciliationSha256 -cmatch '^[0-9a-f]{64}$') `
            'The delivery input does not bind the comparison it closes over.'

        $deliverAudit = Get-Content -LiteralPath (Join-Path $deliverRoot 'coordinator\audit.json') -Raw |
            ConvertFrom-Json -Depth 32
        Assert-Coordinator ([bool]$deliverAudit.deliveryPerformed) `
            'The audit does not record the delivery this run performed.'
        Assert-Coordinator ([string]$deliverAudit.deliveryAuthorizationKind -ceq 'PreviewOnly') `
            "The audit records authorization '$([string]$deliverAudit.deliveryAuthorizationKind)'."
        Assert-Coordinator ([int]$deliverAudit.providerWriteCount -eq 0 -and
            [int]$deliverAudit.writeToolInvocations -eq 0) `
            'A completed delivery is not recorded as having written nowhere.'
        Assert-Coordinator (-not [bool]$deliverAudit.deliveryPromotable -and
            -not [bool]$deliverAudit.deliveryCommentsEnabled -and
            -not [bool]$deliverAudit.deliveryVotesEnabled -and
            -not [bool]$deliverAudit.deliveryGatesEnabled) `
            'The audit records a promotable or write-capable delivery.'
        foreach ($digestField in @('deliveryDecisionSha256', 'deliverySummarySha256',
                'deliveryReconciliationSha256')) {
            Assert-Coordinator ([string]$deliverAudit.$digestField -cmatch '^[0-9a-f]{64}$') `
                "The audit carries no digest under '$digestField'."
        }
        Assert-Coordinator (@($deliverAudit.deliveryCounts).Count -ge 1) `
            'The audit carries an empty opaque delivery census.'
        foreach ($count in @($deliverAudit.deliveryCounts)) {
            Assert-Coordinator ([string]$count.name -cmatch '^[A-Za-z0-9]+$' -and [int]$count.value -ge 0) `
                'The opaque delivery census carries an entry this coordinator could not have copied verbatim.'
        }
        Assert-Coordinator ([int]$deliverAudit.preparationAttemptRecordCount -eq 0) `
            'The delivered set claims a reviewer process had already run at readiness.'
        Assert-Coordinator ([string]$deliverAudit.deliveryStatus -cmatch '^[A-Za-z]+$') `
            'The audit carries no delivery status word.'

        # Replaying a delivered set is a no-op, including its single evaluation.
        $deliverReplay = Invoke-Coordinator -RequestPath $deliverPath -Target 'deliveryTerminalVerified'
        Assert-Coordinator ($deliverReplay.ExitCode -eq 0) 'Replaying a delivered set failed.'
        Assert-Coordinator ([int](Get-CoordinatorState -OutputRoot $deliverRoot).sequence -eq 31) `
            'Replaying a delivered set advanced the sequence.'
        Assert-Coordinator (@(Get-ChildItem -LiteralPath (Join-Path $deliverRoot 'delivery') `
                    -Filter 'delivery-attempt.json' -File).Count -eq 1) `
            'Replaying a delivered set evaluated a second decision.'

        # A distinct exchange file per delivery step, for the reason each slot has
        # one: a result published for the probe must never be adopted as the
        # committed plan's answer.
        $deliverExchange = @(Get-ChildItem -LiteralPath (Join-Path $deliverRoot 'coordinator\exchange') `
                -Filter '*.result.json' -File | ForEach-Object { $_.Name })
        foreach ($required in @('deliveryPlan', 'deliveryPrelaunch', 'deliveryRun', 'deliveryVerify')) {
            Assert-Coordinator (@($deliverExchange | Where-Object { $_ -like "*-$required.result.json" }).Count -eq 1) `
                "The exchange carries no distinct result for '$required'."
        }
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # -----------------------------------------------------------------------
    Write-Host '27/32 the four delivery outcomes are one code path' -ForegroundColor Cyan
    # A decision that found nothing, one that let nothing through, one that would
    # be eligible in preview, and one built over a run the comparison called
    # unusable. The coordinator must reach the same terminal for all four and
    # record the same two zeroes, because it has no branch on which one it got.
    foreach ($outcome in @(
            @{ Name = 'nofindings'; Mode = 'complete'; Status = 'noFindings' },
            @{ Name = 'nothingthrough'; Mode = 'deliveryStatusWithheld'; Status = 'withheld' },
            @{ Name = 'eligible'; Mode = 'deliveryStatusEligible'; Status = 'eligiblePreview' },
            @{ Name = 'unusable'; Mode = 'deliveryStatusDegraded'; Status = 'degraded' })) {
        $outcomeRoot = Join-Path $sandbox "delivery-outcome-$($outcome.Name)"
        $outcomePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath `
            -Name "delivery-outcome-$($outcome.Name)" -Mutate {
                param($r)
                & $setOutputRoot -Request $r -Root $outcomeRoot
                $r.slots.shadowSlotsEnabled = $true
                $r.slots.reconciliation.reconciliationEnabled = $true
                & $addDelivery -Request $r -Root $outcomeRoot
            }.GetNewClosure()
        Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $outcomePath `
            -OutputRoot $outcomeRoot -Label "delivery-outcome-$($outcome.Name)"
        New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode $outcome.Mode
        try {
            $outcomeRun = Invoke-Coordinator -RequestPath $outcomePath -Target 'deliveryTerminalVerified'
            Assert-Coordinator ($outcomeRun.ExitCode -eq 0) `
                "The '$($outcome.Name)' delivery exited $($outcomeRun.ExitCode).`n$($outcomeRun.Output)"
            Assert-Coordinator ((Get-CoordinatorState -OutputRoot $outcomeRoot).state -ceq 'deliveryTerminalVerified') `
                "The '$($outcome.Name)' delivery did not reach the same terminal as the others."
            $outcomeAudit = Get-Content -LiteralPath (Join-Path $outcomeRoot 'coordinator\audit.json') -Raw |
                ConvertFrom-Json -Depth 32
            Assert-Coordinator ([string]$outcomeAudit.deliveryStatus -ceq $outcome.Status) `
                "The '$($outcome.Name)' audit carries status '$([string]$outcomeAudit.deliveryStatus)' rather than '$($outcome.Status)'."
            Assert-Coordinator ([int]$outcomeAudit.providerWriteCount -eq 0 -and
                [int]$outcomeAudit.writeToolInvocations -eq 0) `
                "The '$($outcome.Name)' delivery is not recorded as having written nowhere."
            Assert-Coordinator (-not [bool]$outcomeAudit.deliveryPromotable) `
                "The '$($outcome.Name)' delivery is recorded as promotable."
        }
        finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }
    }

    # -----------------------------------------------------------------------
    Write-Host '28/32 delivery fault matrix, and every write refused' -ForegroundColor Cyan
    # A delivery is authorized once and consumed when it is attempted, so each
    # case gets a fresh root. The write cases are the point of the slice: a
    # capability reported anywhere, or a count reported anywhere, stops the run
    # rather than being recorded.
    $deliveryCases = @(
        @{ Name = 'notready'; Mode = 'deliveryNotReady'; Exit = 2; State = 'reconciliationVerified'
            Pattern = 'readiness gate' },
        @{ Name = 'spent'; Mode = 'deliveryAttemptPresent'; Exit = 2; State = 'reconciliationVerified'
            Pattern = 'authorization is spent' },
        @{ Name = 'wrongsetid'; Mode = 'deliveryWrongSetId'; Exit = 2; State = 'reconciliationVerified'
            Pattern = 'built for run set' },
        @{ Name = 'wrongcomparison'; Mode = 'deliveryWrongReconciliation'; Exit = 2; State = 'reconciliationVerified'
            Pattern = 'reconciliation' },
        # Any write capability present blocks before the child that would run.
        @{ Name = 'wrongkind'; Mode = 'deliveryWrongKind'; Exit = 2; State = 'reconciliationVerified'
            Pattern = 'authorization' },
        @{ Name = 'commentcapability'; Mode = 'deliveryCommentCapability'; Exit = 2; State = 'reconciliationVerified'
            Pattern = 'write capability' },
        @{ Name = 'votecapability'; Mode = 'deliveryVoteCapability'; Exit = 2; State = 'reconciliationVerified'
            Pattern = 'write capability' },
        @{ Name = 'gatecapability'; Mode = 'deliveryGateCapability'; Exit = 2; State = 'reconciliationVerified'
            Pattern = 'write capability' },
        @{ Name = 'planpromotable'; Mode = 'deliveryPlanPromotable'; Exit = 2; State = 'reconciliationVerified'
            Pattern = 'promotable' },
        @{ Name = 'planwrote'; Mode = 'deliveryPlanProviderWrite'; Exit = 2; State = 'reconciliationVerified'
            Pattern = 'write' },
        @{ Name = 'nosummary'; Mode = 'deliveryNoSummary'; Exit = 2; State = 'deliveryRunning'
            Pattern = 'no versioned summary' },
        @{ Name = 'wrongsummary'; Mode = 'deliveryWrongSummaryPath'; Exit = 2; State = 'deliveryRunning'
            Pattern = 'wrote its summary to' },
        @{ Name = 'editedsummary'; Mode = 'deliveryTamperSummary'; Exit = 2; State = 'deliveryRunning'
            Pattern = 'summary digests to' },
        @{ Name = 'nonzero'; Mode = 'deliveryNonzeroNoSummary'; Exit = 4; State = 'deliveryRunning'
            Pattern = 'does not exist|left no result' },
        # The zero-write faults: an evaluation that came back claiming it wrote to
        # a provider is a fault in what was supervised, not a result to record.
        @{ Name = 'runwrote'; Mode = 'deliveryProviderWrite'; Exit = 2; State = 'deliveryRunning'
            Pattern = 'write' },
        @{ Name = 'runwritetool'; Mode = 'deliveryRunWriteTool'; Exit = 2; State = 'deliveryRunning'
            Pattern = 'write' },
        @{ Name = 'unsigned'; Mode = 'deliveryUnsigned'; Exit = 2; State = 'deliveryTerminalObserved'
            Pattern = 'did not verify under its key' },
        @{ Name = 'promotable'; Mode = 'deliveryPromotable'; Exit = 2; State = 'deliveryTerminalObserved'
            Pattern = 'promotable' },
        @{ Name = 'verifywrongkind'; Mode = 'deliveryVerifyWrongKind'; Exit = 2; State = 'deliveryTerminalObserved'
            Pattern = 'authorization' },
        @{ Name = 'verifycapability'; Mode = 'deliveryVerifyCommentCapability'; Exit = 2; State = 'deliveryTerminalObserved'
            Pattern = 'write capability' },
        @{ Name = 'verifywrote'; Mode = 'deliveryVerifyProviderWrite'; Exit = 2; State = 'deliveryTerminalObserved'
            Pattern = 'write' },
        @{ Name = 'verifywritetool'; Mode = 'deliveryWriteTool'; Exit = 2; State = 'deliveryTerminalObserved'
            Pattern = 'write' },
        @{ Name = 'shortruns'; Mode = 'deliveryShortRuns'; Exit = 2; State = 'deliveryTerminalObserved'
            Pattern = 'covered 1 run' },
        @{ Name = 'emptycensus'; Mode = 'deliveryEmptyCounts'; Exit = 2; State = 'deliveryTerminalObserved'
            Pattern = 'empty census' },
        @{ Name = 'duplicatecensus'; Mode = 'deliveryDuplicateCounts'; Exit = 2; State = 'deliveryTerminalObserved'
            Pattern = 'twice' },
        @{ Name = 'badcountname'; Mode = 'deliveryBadCountName'; Exit = 2; State = 'deliveryTerminalObserved'
            Pattern = 'not a plain identifier' },
        @{ Name = 'swapdecision'; Mode = 'deliverySwapDecision'; Exit = 2; State = 'deliveryTerminalObserved'
            Pattern = 'decision is at' }
    )
    foreach ($case in $deliveryCases) {
        $caseRoot = Join-Path $sandbox "delivery-$($case.Name)"
        $casePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name "delivery-$($case.Name)" `
            -Mutate {
                param($r)
                & $setOutputRoot -Request $r -Root $caseRoot
                $r.slots.shadowSlotsEnabled = $true
                $r.slots.reconciliation.reconciliationEnabled = $true
                & $addDelivery -Request $r -Root $caseRoot
            }.GetNewClosure()
        Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $casePath `
            -OutputRoot $caseRoot -Label "delivery-$($case.Name)"
        New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode $case.Mode
        try {
            $run = Invoke-Coordinator -RequestPath $casePath -Target 'deliveryTerminalVerified'
            Assert-Coordinator ($run.ExitCode -eq $case.Exit) `
                "The '$($case.Name)' delivery exited $($run.ExitCode) rather than $($case.Exit).`n$($run.Output)"
            $state = Get-CoordinatorState -OutputRoot $caseRoot
            Assert-Coordinator ($state -and $state.state -ceq $case.State) `
                "The '$($case.Name)' delivery left the record at '$(if ($state) { $state.state } else { 'none' })' rather than '$($case.State)'."
            if ($case.Pattern) {
                Assert-Coordinator ($run.Output -match $case.Pattern) `
                    "The '$($case.Name)' refusal did not name its cause.`n$($run.Output)"
            }
            $caseAttempts = @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'delivery') `
                    -Filter 'delivery-attempt.json' -File -ErrorAction SilentlyContinue)
            Assert-Coordinator ($caseAttempts.Count -le 1) `
                "The '$($case.Name)' delivery left $($caseAttempts.Count) attempt records."
            $caseAuditPath = Join-Path $caseRoot 'coordinator\audit.json'
            Assert-Coordinator (Test-Path -LiteralPath $caseAuditPath -PathType Leaf) `
                "The '$($case.Name)' delivery wrote no audit."
            if (Test-Path -LiteralPath $caseAuditPath -PathType Leaf) {
                $caseAudit = Get-Content -LiteralPath $caseAuditPath -Raw | ConvertFrom-Json -Depth 32
                Assert-Coordinator (-not [bool]$caseAudit.deliveryPerformed) `
                    "The '$($case.Name)' audit claims a delivery it refused."
                # The claim the whole slice exists to make holds on every refusal
                # too, including the ones provoked by a reported write.
                Assert-Coordinator ([int]$caseAudit.providerWriteCount -eq 0 -and
                    [int]$caseAudit.writeToolInvocations -eq 0) `
                    "The '$($case.Name)' audit records a write."
            }
        }
        finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }
    }

    # An evaluation that never returns is stopped by this coordinator on the
    # plan's own budget, and the stop leaves no decision to report.
    $deliveryHangRoot = Join-Path $sandbox 'delivery-hang'
    $deliveryHangPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'delivery-hang' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $deliveryHangRoot
            $r.slots.shadowSlotsEnabled = $true
            $r.slots.reconciliation.reconciliationEnabled = $true
            foreach ($declared in @($r.slots.declared)) { $declared.supervisionGraceSeconds = 30 }
            $r.slots.reconciliation.supervisionGraceSeconds = 30
            & $addDelivery -Request $r -Root $deliveryHangRoot
            $r.slots.delivery.supervisionGraceSeconds = 30
        }.GetNewClosure()
    Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $deliveryHangPath `
        -OutputRoot $deliveryHangRoot -Label 'delivery-hang'
    New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'deliveryHang'
    try {
        $deliveryHangRun = Invoke-Coordinator -RequestPath $deliveryHangPath -Target 'deliveryTerminalVerified'
        Assert-Coordinator ($deliveryHangRun.ExitCode -eq 4) `
            "A hung delivery exited $($deliveryHangRun.ExitCode) rather than reporting a stopped child.`n$($deliveryHangRun.Output)"
        Assert-Coordinator ($deliveryHangRun.Output -match 'HardDeadlineKill|ActivityDeadlineKill|deadline') `
            "The refusal did not name the deadline kill.`n$($deliveryHangRun.Output)"
        Assert-Coordinator ((Get-CoordinatorState -OutputRoot $deliveryHangRoot).state -ceq 'deliveryRunning') `
            'A hung delivery advanced the durable record past the child it named.'
        Start-Sleep -Seconds 2
        Assert-Coordinator ((Get-DescendantPwshCount -SandboxToken $sandboxToken) -eq 0) `
            'The deadline kill left a delivery child running.'
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # A coordinator killed while the evaluation is running has to adopt the child
    # it already named. The single-use attempt record is spent by then, so without
    # the running record this is the state that could never be resumed.
    $deliveryAdoptRoot = Join-Path $sandbox 'delivery-adopt'
    $deliveryAdoptPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'delivery-adopt' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $deliveryAdoptRoot
            $r.slots.shadowSlotsEnabled = $true
            $r.slots.reconciliation.reconciliationEnabled = $true
            & $addDelivery -Request $r -Root $deliveryAdoptRoot
        }.GetNewClosure()
    Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $deliveryAdoptPath `
        -OutputRoot $deliveryAdoptRoot -Label 'delivery-adopt'
    New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'complete' `
        -SlotTimeoutSeconds 300 -PerCallTimeoutSeconds 300 -RunDelaySeconds 20
    try {
        Assert-Coordinator ((Invoke-Coordinator -RequestPath $deliveryAdoptPath `
                    -HaltAfter 'deliveryLaunching' -Target 'deliveryTerminalVerified').ExitCode -eq 9) `
            'The delivery-adopt setup did not halt with an evaluation due.'
        $deliveryJob = Start-Process -FilePath 'dotnet' -PassThru -WindowStyle Hidden -ArgumentList @(
            $script:CoordinatorDll, '--request', $deliveryAdoptPath, '--target', 'deliveryTerminalVerified')
        $deliveryKilled = $false
        try {
            $deliveryDeadline = [DateTime]::UtcNow.AddSeconds(120)
            while ([DateTime]::UtcNow -lt $deliveryDeadline) {
                $deliveryProbe = Get-CoordinatorState -OutputRoot $deliveryAdoptRoot
                if ($deliveryProbe -and $deliveryProbe.state -ceq 'deliveryRunning') { break }
                Start-Sleep -Milliseconds 250
            }
            $atDeliveryKill = Get-CoordinatorState -OutputRoot $deliveryAdoptRoot
            Assert-Coordinator ($atDeliveryKill -and $atDeliveryKill.state -ceq 'deliveryRunning') `
                "The delivery never recorded a running child to kill (state '$(if ($atDeliveryKill) { $atDeliveryKill.state } else { 'none' })')."
            if (-not $deliveryJob.HasExited) { Stop-Process -Id $deliveryJob.Id -Force -ErrorAction SilentlyContinue }
            $deliveryJob.WaitForExit(60000) | Out-Null
            $deliveryKilled = $true
        }
        finally {
            if (-not $deliveryKilled -and -not $deliveryJob.HasExited) {
                Stop-Process -Id $deliveryJob.Id -Force -ErrorAction SilentlyContinue
            }
        }
        Assert-Coordinator ((Get-CoordinatorState -OutputRoot $deliveryAdoptRoot).state -ceq 'deliveryRunning') `
            'A coordinator killed mid-delivery did not leave the record naming its child.'
        $deliveryAttemptFile = Join-Path $deliveryAdoptRoot 'delivery\delivery-attempt.json'
        $deliveryAttemptDeadline = [DateTime]::UtcNow.AddSeconds(60)
        while ([DateTime]::UtcNow -lt $deliveryAttemptDeadline -and
            -not (Test-Path -LiteralPath $deliveryAttemptFile -PathType Leaf)) {
            Start-Sleep -Milliseconds 250
        }
        Assert-Coordinator (Test-Path -LiteralPath $deliveryAttemptFile -PathType Leaf) `
            'The killed delivery never minted the attempt record this case exists to survive.'
        $deliveryResume = Invoke-Coordinator -RequestPath $deliveryAdoptPath -Target 'deliveryTerminalVerified'
        Assert-Coordinator ($deliveryResume.ExitCode -eq 0) `
            "A delivery resumed over a spent attempt record failed (exit $($deliveryResume.ExitCode)).`n$($deliveryResume.Output)"
        Assert-Coordinator ($deliveryResume.Output -match 'resume supervising recorded delivery child') `
            "The resumed delivery did not adopt the child it had named.`n$($deliveryResume.Output)"
        Assert-Coordinator (@(Get-ChildItem -LiteralPath (Join-Path $deliveryAdoptRoot 'delivery') `
                    -Filter 'delivery-attempt.json' -File).Count -eq 1) `
            'An adopted delivery minted a second attempt record.'
        Assert-Coordinator ((Get-CoordinatorState -OutputRoot $deliveryAdoptRoot).state -ceq 'deliveryTerminalVerified') `
            'An adopted delivery did not reach its verified terminal.'
        $adoptAudit = Get-Content -LiteralPath (Join-Path $deliveryAdoptRoot 'coordinator\audit.json') -Raw |
            ConvertFrom-Json -Depth 32
        Assert-Coordinator ([int]$adoptAudit.providerWriteCount -eq 0 -and
            [int]$adoptAudit.writeToolInvocations -eq 0) `
            'An adopted delivery is not recorded as having written nowhere.'
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # -----------------------------------------------------------------------
    Write-Host '29/32 the reconciliation reads a slot run where the reviewer writes it' -ForegroundColor Cyan
    # The comparison is stubbed everywhere else in this suite, which is exactly
    # how a reconciliation shipped that looked for each slot's sealed run loose
    # in the slot state directory. The reviewer does not write it there: a
    # replayed run lands under 'replay/<snapshot>', so the set that had both
    # runs complete was refused for offering zero artifacts. Two independent
    # readers must agree on that layout, and this asserts they do rather than
    # trusting one of them.
    $exactPathTool = Join-Path $RepoRoot 'tools\Test-ReviewerExactPath.ps1'
    $childAdapterPath = Join-Path $RepoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1'
    Assert-Coordinator (Test-Path -LiteralPath $exactPathTool -PathType Leaf) `
        'The exact-path test, which is the other reader of a replayed run layout, is missing.'
    $exactPathText = [IO.File]::ReadAllText($exactPathTool)
    $adapterText = [IO.File]::ReadAllText($childAdapterPath)
    Assert-Coordinator ($exactPathText -match 'replay\\synthetic-pr') `
        'The exact-path test no longer pins a replayed run under replay/<snapshot>; the layout this section guards has moved.'
    Assert-Coordinator ($adapterText -match [regex]::Escape("Join-Path (Join-Path ([string]`$slot.StateDir) 'replay') ([string]`$plan.Snapshot.Name)")) `
        'The reconciliation no longer derives a slot run root from the plan-sealed snapshot under replay/.'
    Assert-Coordinator ($adapterText -notmatch [regex]::Escape("Join-Path ([string]`$slot.StateDir) 'convention-specialist-previews'")) `
        'The reconciliation reads a slot artifact directly out of a state directory, where the reviewer never writes one.'
    Assert-Coordinator ($adapterText -notmatch [regex]::Escape("Join-Path ([string]`$slot.StateDir) 'artifact-signing.key'")) `
        'The reconciliation reads a slot signing key directly out of a state directory, where the reviewer never writes one.'
    # The layout is not just asserted in prose: build the shape the reviewer
    # produces and the shape it does not, and require the adapter's own
    # expression to select the first and reject the second.
    $layoutRoot = Join-Path $sandbox 'reconcile-layout'
    $layoutState = Join-Path $layoutRoot 'slot1-state'
    $layoutRun = Join-Path (Join-Path $layoutState 'replay') 'snap-a'
    $layoutDecoy = Join-Path (Join-Path $layoutState 'replay') 'snap-b'
    foreach ($directory in @((Join-Path $layoutRun 'convention-specialist-previews'),
            (Join-Path $layoutDecoy 'convention-specialist-previews'))) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $layoutRun 'convention-specialist-previews\run.json') -Value '{}' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $layoutRun 'artifact-signing.key') -Value 'raw:AAAA' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $layoutDecoy 'convention-specialist-previews\run.json') -Value '{}' -Encoding utf8NoBOM
    $slot = [pscustomobject]@{ Name = 'slot1'; StateDir = $layoutState }
    $plan = [pscustomobject]@{ Snapshot = [pscustomobject]@{ Name = 'snap-a' } }
    $selectedRoot = Join-Path (Join-Path ([string]$slot.StateDir) 'replay') ([string]$plan.Snapshot.Name)
    $selected = @(Get-ChildItem -LiteralPath (Join-Path $selectedRoot 'convention-specialist-previews') `
            -Filter '*.json' -File | ForEach-Object { $_.FullName })
    Assert-Coordinator (@($selected).Count -eq 1) `
        "The plan-sealed snapshot did not select exactly one slot run artifact (found $(@($selected).Count))."
    Assert-Coordinator (@($selected)[0] -clike "*snap-a*") `
        'The plan-sealed snapshot selected a run belonging to a different snapshot.'
    Assert-Coordinator (Test-Path -LiteralPath (Join-Path $selectedRoot 'artifact-signing.key') -PathType Leaf) `
        'The signing key does not sit beside the run the reconciliation opens.'
    Assert-Coordinator (-not (Test-Path -LiteralPath (Join-Path $layoutState 'convention-specialist-previews'))) `
        'The layout this case builds is not the layout the defect assumed, so it would not have caught it.'

    # -----------------------------------------------------------------------
    Write-Host '30/32 the launch intent journal accounts for every child' -ForegroundColor Cyan
    # The window this case exists for is the one between Process.Start and the
    # record naming what was started. It is microseconds wide and it is the only
    # window in which a coordinator can die holding a child nothing can name.
    # Killing a real coordinator inside it is not reproducible, so the window's
    # RESULT is reproduced instead: an intent that is on disk and unaccountable.
    # A truncated intent is exactly that - it is what a coordinator killed while
    # committing the intent, or after starting but before recording the pid,
    # leaves behind - and the ledger is required to read it as the open case.
    $intentRoot = Join-Path $sandbox 'intent-journal'
    $intentPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'intent-journal' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $intentRoot
            $r.slots.shadowSlotsEnabled = $true
        }.GetNewClosure()
    Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $intentPath `
        -OutputRoot $intentRoot -Label 'intent-journal'
    New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'complete'
    try {
        $intentDirectory = Join-Path $intentRoot 'coordinator\intents'
        Assert-Coordinator (Test-Path -LiteralPath $intentDirectory -PathType Container) `
            'A preparation that launched children left no launch intent journal.'
        $intentFiles = @(Get-ChildItem -LiteralPath $intentDirectory -Filter '*.intent.json' -File)
        Assert-Coordinator ($intentFiles.Count -gt 0) 'The launch intent journal is empty.'
        $intents = @($intentFiles | ForEach-Object {
                Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 16
            })
        $openPhases = @($intents | Where-Object { [string]$_.phase -cne 'closed' })
        Assert-Coordinator ($openPhases.Count -eq 0) `
            "A completed preparation left $($openPhases.Count) launch intent(s) unclosed."
        foreach ($intent in $intents) {
            Assert-Coordinator ([string]$intent.contractVersion -ceq 'devpilot.shadow-run-coordinator.launch-intent.v1') `
                "A launch intent carries contract version '$([string]$intent.contractVersion)'."
            Assert-Coordinator ([string]$intent.signature.value -cmatch '^[0-9a-f]{64}$') `
                "The launch intent for step '$([string]$intent.step)' is not signed."
            Assert-Coordinator ([string]$intent.transition -cmatch '^\S') `
                "The launch intent for step '$([string]$intent.step)' names no transition."
            Assert-Coordinator ([string]$intent.childSpecSha256 -cmatch '^[0-9a-f]{64}$' -and
                [string]$intent.childRequestSha256 -cmatch '^[0-9a-f]{64}$') `
                "The launch intent for step '$([string]$intent.step)' does not bind the child it intended to start."
            Assert-Coordinator ([string]$intent.expectedResultPath -cmatch '\S' -and [string]$intent.leasePath -cmatch '\S') `
                "The launch intent for step '$([string]$intent.step)' names no expected output or lease."
            Assert-Coordinator ([int]$intent.leaseProcessId -gt 0 -and [string]$intent.correlationId -cmatch '\S') `
                "The launch intent for step '$([string]$intent.step)' cannot be tied back to the run that wrote it."
        }
        # One intent per step, and a dense launch sequence: two intents sharing a
        # sequence, or a step holding two, is a second launch of a single-use step.
        $sequences = @($intents | ForEach-Object { [long]$_.launchSequence } | Sort-Object -Unique)
        Assert-Coordinator ($sequences.Count -eq $intents.Count) `
            "The journal holds $($intents.Count) intents across $($sequences.Count) distinct launch sequences."
        Assert-Coordinator ($sequences[0] -eq 1 -and $sequences[-1] -eq $intents.Count) `
            "The launch sequence runs $($sequences[0])..$($sequences[-1]) over $($intents.Count) intents rather than densely from one."
        $steps = @($intents | ForEach-Object { [string]$_.step } | Sort-Object -Unique)
        Assert-Coordinator ($steps.Count -eq $intents.Count) `
            "The journal records $($intents.Count) launches across only $($steps.Count) distinct steps, so a step was launched twice."

        # The open case, planted on the one step where a duplicate launch is
        # unrecoverable rather than merely wasteful.
        $correlationId = [string]$intents[0].correlationId
        $plantedIntent = Join-Path $intentDirectory "$correlationId-slot1Run-0001.intent.json"
        Assert-Coordinator (-not (Test-Path -LiteralPath $plantedIntent)) `
            'The slot run step already holds an intent before the slot has ever been launched.'
        $donor = [IO.File]::ReadAllText($intentFiles[0].FullName)
        [IO.File]::WriteAllText($plantedIntent, $donor.Substring(0, [int]($donor.Length / 2)))
        $refused = Invoke-Coordinator -RequestPath $intentPath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($refused.ExitCode -eq 6) `
            "An unaccounted-for launch did not report an unresolved launch (exit $($refused.ExitCode)).`n$($refused.Output)"
        Assert-Coordinator ($refused.Output -match 'no record of what that launch became') `
            "The refusal does not name the ambiguity it is refusing over.`n$($refused.Output)"
        $refusedState = Get-CoordinatorState -OutputRoot $intentRoot
        Assert-Coordinator (@($refusedState.transitions | Where-Object { $_.state -ceq 'slot1Running' }).Count -eq 0) `
            "The refused run committed a running record for a launch it must not have made ('$($refusedState.state)')."
        $plantedAttempts = @(Get-ChildItem -LiteralPath (Join-Path $intentRoot 'qualification\stub') `
                -Filter 'slot*-attempt.json' -File -ErrorAction SilentlyContinue)
        Assert-Coordinator ($plantedAttempts.Count -eq 0) `
            "The refused run started $($plantedAttempts.Count) slot child(ren) over an unaccounted-for launch."
        # The refusal is itself an exit, so it is audited like any other.
        $refusedAudit = Get-Content -LiteralPath (Join-Path $intentRoot 'coordinator\audit.json') -Raw |
            ConvertFrom-Json -Depth 32
        Assert-Coordinator ([string]$refusedAudit.terminalReason -ceq 'unresolvedLaunch') `
            "The refused run's audit reports terminal reason '$([string]$refusedAudit.terminalReason)'."
        Assert-Coordinator (@($refusedAudit.launchIntents.unresolvedSteps) -ccontains 'slot1Run') `
            'The audit census does not name the step whose launch is unaccounted for.'
        # And it is a refusal, not a brick: the ambiguity removed, the same root
        # runs the step exactly once.
        Remove-Item -LiteralPath $plantedIntent -Force
        $recovered = Invoke-Coordinator -RequestPath $intentPath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($recovered.ExitCode -eq 0) `
            "The root did not resume once the ambiguity was removed (exit $($recovered.ExitCode)).`n$($recovered.Output)"
        $recoveredAttempts = @(Get-ChildItem -LiteralPath (Join-Path $intentRoot 'qualification\stub') `
                -Filter 'slot*-attempt.json' -File -ErrorAction SilentlyContinue)
        Assert-Coordinator ($recoveredAttempts.Count -eq 1) `
            "The resumed run left $($recoveredAttempts.Count) slot attempt records rather than one."
        $slotIntentFile = Join-Path $intentDirectory "$correlationId-slot1Run-0001.intent.json"
        Assert-Coordinator (Test-Path -LiteralPath $slotIntentFile -PathType Leaf) `
            'The supervised slot launch left no intent behind.'
        $slotIntent = Get-Content -LiteralPath $slotIntentFile -Raw | ConvertFrom-Json -Depth 16
        Assert-Coordinator ([string]$slotIntent.phase -ceq 'closed') `
            "The supervised slot's intent is left at phase '$([string]$slotIntent.phase)'."
        Assert-Coordinator ([int]$slotIntent.childProcessId -gt 0) `
            'The supervised slot intent records no process id, so a coordinator killed here could not name the child.'
        # Read as text: ConvertFrom-Json turns the timestamp into a DateTime and
        # what is under test is the shape the record carries.
        $slotIntentRaw = [IO.File]::ReadAllText($slotIntentFile)
        Assert-Coordinator ($slotIntentRaw -cmatch '"childStartedAtUtc"\s*:\s*"\d{4}-\d{2}-\d{2}T[\d:.]+Z"') `
            'The supervised slot intent records no start time, so a recycled pid could pass for the child.'
        Assert-Coordinator ([string]$slotIntent.slotName -ceq 'slot1' -and [string]$slotIntent.setId -cmatch '\S') `
            'The supervised slot intent does not bind the slot and set it was launched for.'
        # Resuming a reached state must not open a second intent for the step.
        $before = @(Get-ChildItem -LiteralPath $intentDirectory -Filter '*-slot1Run-*.intent.json' -File).Count
        $again = Invoke-Coordinator -RequestPath $intentPath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($again.ExitCode -eq 0) `
            "Resuming a verified slot terminal failed (exit $($again.ExitCode)).`n$($again.Output)"
        $after = @(Get-ChildItem -LiteralPath $intentDirectory -Filter '*-slot1Run-*.intent.json' -File).Count
        Assert-Coordinator ($after -eq $before) `
            "Resuming a verified slot terminal opened $($after - $before) further launch intent(s)."
        $finalAttempts = @(Get-ChildItem -LiteralPath (Join-Path $intentRoot 'qualification\stub') `
                -Filter 'slot*-attempt.json' -File -ErrorAction SilentlyContinue)
        Assert-Coordinator ($finalAttempts.Count -eq 1) `
            "Resuming a verified slot terminal left $($finalAttempts.Count) attempt records rather than one."
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # -----------------------------------------------------------------------
    Write-Host '31/32 the audit is written on every exit, and never leads the state' -ForegroundColor Cyan
    # Two claims. The audit is published on the unsuccessful exits as well as the
    # successful one, so it never lags the record it describes; and a failure to
    # publish it cannot cost the run its work, because the record is what is
    # authoritative and the next run rebuilds the report from it.
    $auditRoot = Join-Path $sandbox 'audit-exits'
    $auditRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'audit-exits' -Mutate {
        param($r) & $setOutputRoot -Request $r -Root $auditRoot
    }.GetNewClosure()
    $auditFile = Join-Path $auditRoot 'coordinator\audit.json'
    $haltedRun = Invoke-Coordinator -RequestPath $auditRequest -HaltAfter 'corpusPublished'
    Assert-Coordinator ($haltedRun.ExitCode -eq 9) `
        "The halted run did not report a deliberate halt (exit $($haltedRun.ExitCode)).`n$($haltedRun.Output)"
    Assert-Coordinator (Test-Path -LiteralPath $auditFile -PathType Leaf) `
        'A halted run published no audit, so the audit lags the state it describes.'
    $haltAudit = Get-Content -LiteralPath $auditFile -Raw | ConvertFrom-Json -Depth 32
    Assert-Coordinator ([string]$haltAudit.terminalReason -ceq 'deliberateHalt') `
        "The halted run's audit reports terminal reason '$([string]$haltAudit.terminalReason)'."
    Assert-Coordinator ([string]$haltAudit.finalState -ceq 'corpusPublished') `
        "The halted run's audit reports final state '$([string]$haltAudit.finalState)'."
    Assert-Coordinator ([string]$haltAudit.terminalDetail -match 'corpusPublished') `
        'The halted audit does not say where the run stopped.'
    Assert-Coordinator ([string]$haltAudit.signature -cmatch '^[0-9a-f]{64}$' -and
        [string]$haltAudit.auditSha256 -cmatch '^[0-9a-f]{64}$') `
        'The audit is not signed and self-hashed.'
    # The digest binds the audit to the exact record it was derived from, so a
    # report kept from an earlier run cannot pass for this one's.
    $statePath = Join-Path $auditRoot 'coordinator\state.json'
    $stateDigest = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Coordinator ([string]$haltAudit.stateSha256 -ceq $stateDigest) `
        'The audit does not carry the digest of the state record it describes.'
    Assert-Coordinator ([int]$haltAudit.sequence -eq [int](Get-CoordinatorState -OutputRoot $auditRoot).sequence) `
        'The audit sequence disagrees with the durable record.'

    $finishedRun = Invoke-Coordinator -RequestPath $auditRequest -Target 'runSetReady'
    Assert-Coordinator ($finishedRun.ExitCode -eq 0) `
        "The resumed run did not reach run-set-ready (exit $($finishedRun.ExitCode)).`n$($finishedRun.Output)"
    $doneAudit = Get-Content -LiteralPath $auditFile -Raw | ConvertFrom-Json -Depth 32
    Assert-Coordinator ([string]$doneAudit.terminalReason -ceq 'completed' -and
        [string]$doneAudit.finalState -ceq 'runSetReady') `
        "The completed run's audit reports '$([string]$doneAudit.terminalReason)' at '$([string]$doneAudit.finalState)'."
    $doneDigest = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Coordinator ([string]$doneAudit.stateSha256 -ceq $doneDigest) `
        'The completed run left an audit bound to an older state record.'

    # A refusal is an exit too. A child that fails after the root already holds a
    # real record is the ordinary unsuccessful ending, and it has to be audited
    # like any other, or the report on disk describes the last run that happened
    # to succeed rather than the one that just failed.
    $refuseAuditRoot = Join-Path $sandbox 'audit-refusal'
    $refuseAuditRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'audit-refusal' -Mutate {
        param($r) & $setOutputRoot -Request $r -Root $refuseAuditRoot
    }.GetNewClosure()
    $refusePrepared = Invoke-Coordinator -RequestPath $refuseAuditRequest -HaltAfter 'corpusPublished'
    Assert-Coordinator ($refusePrepared.ExitCode -eq 9) `
        "The refusal fixture did not reach its halt (exit $($refusePrepared.ExitCode)).`n$($refusePrepared.Output)"
    $refuseAuditFile = Join-Path $refuseAuditRoot 'coordinator\audit.json'
    $auditBeforeFailure = (Get-FileHash -LiteralPath $refuseAuditFile -Algorithm SHA256).Hash
    New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'nonzero'
    try {
        $failedWalk = Invoke-Coordinator -RequestPath $refuseAuditRequest -Target 'runSetReady'
        Assert-Coordinator ($failedWalk.ExitCode -eq 4) `
            "A failing child did not report a child failure (exit $($failedWalk.ExitCode)).`n$($failedWalk.Output)"
        $auditAfterFailure = (Get-FileHash -LiteralPath $refuseAuditFile -Algorithm SHA256).Hash
        Assert-Coordinator ($auditAfterFailure -cne $auditBeforeFailure) `
            'A failed run left the audit written by the previous successful exit standing.'
        $walkAudit = Get-Content -LiteralPath $refuseAuditFile -Raw | ConvertFrom-Json -Depth 32
        Assert-Coordinator ([string]$walkAudit.terminalReason -ceq 'childFailure') `
            "A failed run published an audit claiming terminal reason '$([string]$walkAudit.terminalReason)'."
        Assert-Coordinator ([string]$walkAudit.terminalDetail -cmatch '\S') `
            'The failed run published an audit that does not say why the run ended.'
        Assert-Coordinator ([string]$walkAudit.finalState -ceq [string](Get-CoordinatorState -OutputRoot $refuseAuditRoot).state) `
            'The failed run published an audit that disagrees with the durable state.'
        $walkDigest = (Get-FileHash -LiteralPath (Join-Path $refuseAuditRoot 'coordinator\state.json') `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-Coordinator ([string]$walkAudit.stateSha256 -ceq $walkDigest) `
            'The failed run published an audit bound to a different record than the one on disk.'
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # The audit write itself is faulted, at every transition of a whole run, by
    # standing a directory where the file belongs. No product hook is involved:
    # this is a storage fault the coordinator has to survive, not a test seam.
    $auditFaultRoot = Join-Path $sandbox 'audit-fault'
    $auditFaultRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'audit-fault' -Mutate {
        param($r) & $setOutputRoot -Request $r -Root $auditFaultRoot
    }.GetNewClosure()
    $auditFaultFile = Join-Path $auditFaultRoot 'coordinator\audit.json'
    New-Item -ItemType Directory -Path $auditFaultFile -Force | Out-Null
    $faulted = Invoke-Coordinator -RequestPath $auditFaultRequest -Target 'runSetReady'
    Assert-Coordinator ($faulted.ExitCode -eq 0) `
        ("A run whose every audit write failed did not complete (exit $($faulted.ExitCode)). " +
            "A report that cannot be written must not cost the run its work.`n$($faulted.Output)")
    Assert-Coordinator ($faulted.Output -match 'audit not written') `
        'The run absorbed the audit failures without saying so.'
    Assert-Coordinator (Test-Path -LiteralPath $auditFaultFile -PathType Container) `
        'The audit path is no longer the directory that was faulting the writes, so the fault did not hold.'
    $faultedState = Get-CoordinatorState -OutputRoot $auditFaultRoot
    Assert-Coordinator ($faultedState.state -ceq 'runSetReady' -and [int]$faultedState.sequence -eq 11) `
        "The faulted run's durable state is '$($faultedState.state)' at sequence $($faultedState.sequence)."
    $faultedDeclared = @(Get-ChildItem -LiteralPath (Join-Path $auditFaultRoot 'qualification\runset') `
            -Filter 'runset-*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.sig' })
    Assert-Coordinator ($faultedDeclared.Count -eq 1) `
        "The faulted run declared $($faultedDeclared.Count) run sets rather than one."

    # The fault removed, the very next run repairs the report from the record
    # alone: no child is launched, nothing is re-declared, and the state does not
    # move. That is what makes the audit safe to lose.
    Remove-Item -LiteralPath $auditFaultFile -Recurse -Force
    $exchangeBefore = @(Get-ChildItem -LiteralPath (Join-Path $auditFaultRoot 'coordinator\exchange') `
            -Filter '*.result.json' -File | Sort-Object -Property Name |
        ForEach-Object { $_.Name + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join '|'
    $repair = Invoke-Coordinator -RequestPath $auditFaultRequest -Target 'runSetReady'
    Assert-Coordinator ($repair.ExitCode -eq 0) `
        "The repairing run failed (exit $($repair.ExitCode)).`n$($repair.Output)"
    Assert-Coordinator (Test-Path -LiteralPath $auditFaultFile -PathType Leaf) `
        'The next run over the root did not rebuild the audit that could not be written.'
    $repaired = Get-Content -LiteralPath $auditFaultFile -Raw | ConvertFrom-Json -Depth 32
    $repairedDigest = (Get-FileHash -LiteralPath (Join-Path $auditFaultRoot 'coordinator\state.json') `
            -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Coordinator ([string]$repaired.stateSha256 -ceq $repairedDigest -and
        [string]$repaired.finalState -ceq 'runSetReady' -and [int]$repaired.sequence -eq 11) `
        'The rebuilt audit does not describe the record that was already on disk.'
    $repairedState = Get-CoordinatorState -OutputRoot $auditFaultRoot
    Assert-Coordinator ([int]$repairedState.sequence -eq 11) `
        "Repairing the audit advanced the durable sequence to $($repairedState.sequence)."
    $exchangeAfter = @(Get-ChildItem -LiteralPath (Join-Path $auditFaultRoot 'coordinator\exchange') `
            -Filter '*.result.json' -File | Sort-Object -Property Name |
        ForEach-Object { $_.Name + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join '|'
    Assert-Coordinator ($exchangeAfter -ceq $exchangeBefore) `
        'Repairing the audit relaunched a child.'
    $repairedIntents = @(Get-ChildItem -LiteralPath (Join-Path $auditFaultRoot 'coordinator\intents') `
            -Filter '*.intent.json' -File -ErrorAction SilentlyContinue)
    $repairedOpen = @($repairedIntents | Where-Object {
            [string](Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 16).phase -cne 'closed'
        })
    Assert-Coordinator ($repairedOpen.Count -eq 0) `
        "Repairing the audit left $($repairedOpen.Count) launch intent(s) unaccounted for."

    # -----------------------------------------------------------------------
    Write-Host '32/32 no orphans, no external writes' -ForegroundColor Cyan
    Start-Sleep -Seconds 2
    $orphans = Get-DescendantPwshCount -SandboxToken $sandboxToken
    Assert-Coordinator ($orphans -eq 0) "The suite left $orphans PowerShell process(es) running."
    $repoStatusAfter = (& git -C $RepoRoot status --porcelain -- 'src' 'docs' 'samples' 2>&1 | Out-String).Trim()
    Assert-Coordinator ($repoStatusAfter -ceq $repoStatusBefore) `
        "The suite modified tracked toolkit content. Before:`n$repoStatusBefore`nAfter:`n$repoStatusAfter"
}
finally {
    if ($KeepSandbox) { Write-Host "sandbox retained at $sandbox" -ForegroundColor DarkGray }
    else { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue }
}

Write-Host ""
if ($script:Failures.Count -gt 0) {
    Write-Host "Shadow run coordinator: $($script:Failures.Count) of $($script:Checks) check(s) failed." -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "Shadow run coordinator: $($script:Checks) check(s) passed." -ForegroundColor Green
exit 0









