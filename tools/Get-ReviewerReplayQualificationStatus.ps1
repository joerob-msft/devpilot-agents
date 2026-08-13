#Requires -Version 7.0

<#
.SYNOPSIS
    Reports the status of an offline replay qualification from its immutable
    on-disk evidence, without polling, sleeping, or launching anything.

.DESCRIPTION
    Status is read from the artifacts a run leaves behind - the sealed run-set
    declaration, and each slot's immutable attempt and terminal records - not
    from the live process table. A slot with a terminal record is terminal by
    definition, whatever any process is doing; its recorded child PID is probed
    once, by exact id and disambiguated by start time, only to surface the
    anomaly of a terminal slot whose child somehow still lives.

    It NEVER scans the process table by command text. A status tool that
    filtered processes by a command-line substring would match its own
    inspecting shell - the exact false positive that has masqueraded as a live
    reviewer before. Liveness is only ever asserted for an exact recorded PID.

    This tool writes nothing except the report an operator explicitly asks for,
    contacts nothing, and launches no model.

.PARAMETER QualificationRoot
    The qualification root a run set was declared and run into. Its 'runset' and
    'runs' subdirectories hold the immutable evidence this tool reads.

.PARAMETER RunSetKeyPath
    Optional path to the run-set signing key. When supplied, the declaration is
    verified with the SAME shared verifier the reconciliation gate uses, so a
    positive 'reconciliationReady' is only ever reported for a signature-verified
    declaration - status and Reconcile can never positively disagree for the same
    authenticated inputs. Without a key, the tool reports 'signatureUnverified'
    and only 'evidenceComplete' (the slot evidence, unauthenticated), never
    'reconciliationReady'.

.PARAMETER ReportPath
    Optional path to write the status object to as JSON. The only file written.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QualificationRoot,
    [string]$RunSetKeyPath = "",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# The production-supported run-set size. A declaration outside this range is
# malformed or tampered; status refuses to derive slot names or claim readiness
# from it rather than letting an out-of-range count (a zero, a negative, or an
# enormous value) misgenerate slots or over-claim readiness.
$script:ReviewerQualificationMinSlots = 2
$script:ReviewerQualificationMaxSlots = 16

$toolkitRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $toolkitRoot "src\Agents\reviewer\ReplayQualification.ps1")

$rootFull = [IO.Path]::GetFullPath($QualificationRoot)
if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
    throw "Qualification root '$rootFull' does not exist."
}
$runSetDirectory = Join-Path $rootFull "runset"
$runDirectory = Join-Path $rootFull "runs"

# Attempt-owned staging directories that never completed their atomic publish.
# They are self-describing residue, never a declared or launchable set; status
# surfaces them so an operator can see an interrupted declaration, but they are
# read from nowhere else and count toward nothing.
$incompleteStaging = @()
$incompleteStaging = @(Get-ChildItem -LiteralPath $rootFull -Directory -Filter ".runset-staging-*" `
        -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

# The sealed declaration. Read as a summary always; verified with the shared
# run-set verifier only when a key is supplied, because only a verified
# declaration may authorize a positive readiness. Absence is a legitimate state
# (declared-but-not-run, or a bare root).
$declarationSummary = $null
$declarationVerified = $false
$declarationCountValid = $false
if (Test-Path -LiteralPath $runSetDirectory -PathType Container) {
    $declarationFile = @(Get-ChildItem -LiteralPath $runSetDirectory -Filter "runset-*.json" -File `
            -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*.sig" })
    if ($declarationFile.Count -gt 1) {
        # Declare refuses a second declaration in a root; more than one here is
        # a tampered set. Never pick one arbitrarily and report readiness off it.
        $declarationSummary = [pscustomobject][ordered]@{
            error = "multiple declarations present ($($declarationFile.Count)); a run set declares exactly one."
        }
    }
    elseif ($declarationFile.Count -eq 1) {
        try {
            $envelope = Get-Content -LiteralPath $declarationFile[0].FullName -Raw | ConvertFrom-Json
            $inner = if ($envelope.PSObject.Properties["manifestJson"]) {
                [string]$envelope.manifestJson | ConvertFrom-Json
            }
            else { $envelope }
            $plannedRunCount = [int]$inner.plannedRunCount
            $declarationCountValid = ($plannedRunCount -ge $script:ReviewerQualificationMinSlots -and
                $plannedRunCount -le $script:ReviewerQualificationMaxSlots)
            # A key lets status apply the SAME verifier the reconciliation gate
            # uses. Only a signature-verified declaration may authorize a positive
            # readiness; an unverified summary is reported as such and can only
            # ever reach 'evidenceComplete', never 'reconciliationReady'.
            if ($RunSetKeyPath) {
                $keyFull = [IO.Path]::GetFullPath($RunSetKeyPath)
                $compareTool = Join-Path $toolkitRoot "tools\Compare-ReviewerReplayRuns.ps1"
                if ((Test-Path -LiteralPath $keyFull -PathType Leaf) -and
                    (Test-Path -LiteralPath $compareTool -PathType Leaf)) {
                    try {
                        $verifiedOutput = & $compareTool -VerifyRunSet -RunSetPath $declarationFile[0].FullName -KeyPath $keyFull
                        $verifiedJson = @(@($verifiedOutput) |
                                Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith("{") } |
                                Select-Object -Last 1)
                        if (@($verifiedJson).Count -eq 1) {
                            $inner = [string]$verifiedJson[0] | ConvertFrom-Json
                            $plannedRunCount = [int]$inner.plannedRunCount
                            $declarationCountValid = ($plannedRunCount -ge $script:ReviewerQualificationMinSlots -and
                                $plannedRunCount -le $script:ReviewerQualificationMaxSlots)
                            $declarationVerified = $true
                        }
                    }
                    catch { $declarationVerified = $false }
                }
            }
            $declarationSummary = [pscustomobject][ordered]@{
                setId                  = [string]$inner.setId
                snapshotName           = [string]$inner.snapshotName
                snapshotManifestDigest = [string]$inner.snapshotManifestDigest
                plannedRunCount        = $plannedRunCount
                planDigest             = [string]$inner.planDigest
                promotable             = [bool]$inner.promotable
                launchTokenPresent     = (Test-Path -LiteralPath (Join-Path $runSetDirectory "launch-authorization.token") -PathType Leaf)
                signatureVerified      = $declarationVerified
                countValid             = $declarationCountValid
            }
        }
        catch {
            $declarationSummary = [pscustomobject][ordered]@{ error = "declaration present but unreadable: $($_.Exception.Message)" }
        }
    }
}

$slotStatuses = [System.Collections.Generic.List[object]]::new()
if (Test-Path -LiteralPath $runDirectory -PathType Container) {
    # Enumerate slot names from BOTH attempt and terminal evidence. A terminal
    # without a matching attempt is anomalous (a forged or orphaned terminal)
    # and must still be surfaced - reconciliation reads terminals directly, so
    # a status read that only looked at attempt files could disagree with it.
    $attemptFiles = @(Get-ChildItem -LiteralPath $runDirectory -Filter "slot*-attempt.json" -File `
            -ErrorAction SilentlyContinue)
    $terminalFiles = @(Get-ChildItem -LiteralPath $runDirectory -Filter "slot*-terminal.json" -File `
            -ErrorAction SilentlyContinue)
    $slotNames = @(
        @($attemptFiles | ForEach-Object { $_.Name -replace '-attempt\.json$', '' }) +
        @($terminalFiles | ForEach-Object { $_.Name -replace '-terminal\.json$', '' })
    ) | Sort-Object -Unique
    foreach ($slotName in $slotNames) {
        $attemptPath = Join-Path $runDirectory "$slotName-attempt.json"
        $attemptExists = Test-Path -LiteralPath $attemptPath -PathType Leaf
        $attempt = $null
        if ($attemptExists) {
            try { $attempt = Get-Content -LiteralPath $attemptPath -Raw | ConvertFrom-Json } catch {}
        }
        $terminalPath = Join-Path $runDirectory "$slotName-terminal.json"
        $terminal = $null
        $terminalImmutable = $false
        if (Test-Path -LiteralPath $terminalPath -PathType Leaf) {
            $terminalImmutable = (Get-Item -LiteralPath $terminalPath).IsReadOnly
            try { $terminal = Get-Content -LiteralPath $terminalPath -Raw | ConvertFrom-Json } catch {}
        }

        if ($terminal) {
            # Terminal evidence is authoritative. The only liveness question that
            # remains is the anomaly of a terminal slot whose exact recorded
            # child still runs - probed by id and start time, never by text.
            $recordedChildAlive = Test-ReviewerQualificationRecordedProcessAlive `
                -ProcessId ([int]$terminal.childProcessId) `
                -StartedAtUtc ([string]$terminal.startedAtUtc) -EndedAtUtc ([string]$terminal.endedAtUtc)
            # A "complete" terminal is only THIS set's proof when it is immutable
            # and names this set and plan. An unbound or writable terminal is
            # reported so, and never counts toward reconciliation readiness.
            $boundToDeclaration = $false
            if ($declarationSummary -and $declarationSummary.PSObject.Properties["setId"]) {
                $boundToDeclaration = ([string]$terminal.slot -ceq $slotName -and
                    [string]$terminal.setId -ceq [string]$declarationSummary.setId -and
                    [string]$terminal.planDigest -ceq [string]$declarationSummary.planDigest)
            }
            $slotStatuses.Add([pscustomobject][ordered]@{
                    slot               = $slotName
                    state              = "terminal"
                    terminalStatus     = [string]$terminal.status
                    exitCode           = [int]$terminal.exitCode
                    timedOut           = [bool]$terminal.timedOut
                    timeoutReason      = [string]$terminal.timeoutReason
                    childProcessId     = [int]$terminal.childProcessId
                    terminalImmutable  = $terminalImmutable
                    boundToDeclaration = $boundToDeclaration
                    recordedChildAlive = $recordedChildAlive
                }) | Out-Null
        }
        else {
            # No terminal. This is either an in-flight/aborted attempt, or a
            # slot for which only an orphan terminal was expected but is absent.
            # Liveness is deliberately NOT inferred from command text.
            $slotStatuses.Add([pscustomobject][ordered]@{
                    slot               = $slotName
                    state              = if ($attemptExists) { "attemptedWithoutTerminal" } else { "noEvidence" }
                    terminalStatus     = "none"
                    note               = "In-flight or aborted; no immutable terminal evidence. Liveness is not inferred from command text."
                    attemptImmutable   = if ($attemptExists) { (Get-Item -LiteralPath $attemptPath).IsReadOnly } else { $false }
                }) | Out-Null
        }
    }
}

$completeCount = @($slotStatuses | Where-Object { [string]$_.terminalStatus -ceq "complete" }).Count

# Reconcile reads exactly the slots the plan named - slot1..slotN for an
# N-slot declaration - and ignores anything else. Status mirrors that exact
# expected set so its evidence view can never disagree with the gate: a stray
# slot3 terminal on a two-slot set neither counts toward readiness nor lets an
# unrun slot1/slot2 be reported ready. A declaration whose count is outside the
# supported range generates NO expected slots, so `1..0` can never misgenerate a
# descending pair and an enormous count can never allocate an enormous range;
# such a declaration is simply not evidence of anything. Slot membership is
# compared case-exactly (-ccontains), matching Reconcile's case-sensitive slot
# binding, so a 'Slot1' terminal is never counted where the gate expects 'slot1'.
$expectedSlotNames = @()
$unexpectedSlots = @()
$readySlotCount = 0
$countInRange = ($declarationSummary -and $declarationSummary.PSObject.Properties["countValid"] -and
    [bool]$declarationSummary.countValid)
if ($declarationSummary -and $declarationSummary.PSObject.Properties["plannedRunCount"] -and
    -not $declarationSummary.PSObject.Properties["error"] -and $countInRange) {
    $plannedRunCount = [int]$declarationSummary.plannedRunCount
    $expectedSlotNames = @()
    for ($i = 1; $i -le $plannedRunCount; $i++) { $expectedSlotNames += "slot$i" }
    $unexpectedSlots = @($slotStatuses | Where-Object { $expectedSlotNames -cnotcontains [string]$_.slot } |
        ForEach-Object { [string]$_.slot })
    # A slot counts toward the evidence view only when it is one of the expected
    # slots and its terminal is complete, immutable, and bound to this
    # declaration - the same conditions the reconciliation gate enforces.
    $readySlotCount = @($slotStatuses | Where-Object {
            $expectedSlotNames -ccontains [string]$_.slot -and
            [string]$_.terminalStatus -ceq "complete" -and
            [bool]$_.PSObject.Properties["terminalImmutable"] -and [bool]$_.terminalImmutable -and
            [bool]$_.PSObject.Properties["boundToDeclaration"] -and [bool]$_.boundToDeclaration
        }).Count
}

# 'evidenceComplete' is the slot-evidence view: every expected slot has a
# complete, immutable, bound terminal and no recorded child is live. It says
# nothing about the declaration's authenticity. 'reconciliationReady' adds the
# one thing the gate additionally requires and the thing evidenceComplete
# cannot assert on its own: a signature-verified declaration. Without a key the
# tool never verifies, so reconciliationReady stays false and the report is
# explicit that the signature was not checked - status can never positively
# disagree with Reconcile for the same authenticated inputs.
$noLiveChild = -not (@($slotStatuses | Where-Object { [bool]$_.PSObject.Properties["recordedChildAlive"] -and
            [bool]$_.recordedChildAlive }).Count)
$evidenceComplete = $false
if ($declarationSummary -and $declarationSummary.PSObject.Properties["plannedRunCount"] -and
    -not $declarationSummary.PSObject.Properties["error"] -and $countInRange) {
    $evidenceComplete = ($readySlotCount -eq [int]$declarationSummary.plannedRunCount -and $noLiveChild)
}
$reconciliationReady = ($evidenceComplete -and $declarationVerified)

$status = [pscustomobject][ordered]@{
    kind                = "reviewer.replay-qualification.status.v1"
    generatedAtUtc      = [DateTime]::UtcNow.ToString("o")
    qualificationRoot   = $rootFull
    declaration         = $declarationSummary
    slotsAttempted      = @($slotStatuses).Count
    slotsComplete       = $completeCount
    evidenceComplete    = $evidenceComplete
    signatureUnverified = (-not $declarationVerified)
    reconciliationReady = $reconciliationReady
    unexpectedSlots     = @($unexpectedSlots)
    incompleteStaging   = @($incompleteStaging)
    slots               = @($slotStatuses)
}

if ($ReportPath) {
    $reportFull = [IO.Path]::GetFullPath($ReportPath)
    $reportDir = Split-Path -Parent $reportFull
    if ($reportDir -and -not (Test-Path -LiteralPath $reportDir -PathType Container)) {
        [void](New-Item -ItemType Directory -Force -Path $reportDir)
    }
    [IO.File]::WriteAllText($reportFull, (ConvertTo-Json -InputObject $status -Depth 8),
        [Text.UTF8Encoding]::new($false))
    Write-Host "Status report: $reportFull" -ForegroundColor DarkGray
}

Write-Output $status
