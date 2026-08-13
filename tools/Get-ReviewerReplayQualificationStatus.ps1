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

.PARAMETER ReportPath
    Optional path to write the status object to as JSON. The only file written.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QualificationRoot,
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$toolkitRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $toolkitRoot "src\Agents\reviewer\ReplayQualification.ps1")

$rootFull = [IO.Path]::GetFullPath($QualificationRoot)
if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
    throw "Qualification root '$rootFull' does not exist."
}
$runSetDirectory = Join-Path $rootFull "runset"
$runDirectory = Join-Path $rootFull "runs"

# The sealed declaration, read as evidence only - not verified here, because a
# status read makes no decision a signature would need to authorize. Absence is
# a legitimate state (declared-but-not-run, or a bare root).
$declarationSummary = $null
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
            $declarationSummary = [pscustomobject][ordered]@{
                setId                  = [string]$inner.setId
                snapshotName           = [string]$inner.snapshotName
                snapshotManifestDigest = [string]$inner.snapshotManifestDigest
                plannedRunCount        = [int]$inner.plannedRunCount
                planDigest             = [string]$inner.planDigest
                promotable             = [bool]$inner.promotable
                launchTokenPresent     = (Test-Path -LiteralPath (Join-Path $runSetDirectory "launch-authorization.token") -PathType Leaf)
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
# expected set so its readiness can never disagree with the gate: a stray
# slot3 terminal on a two-slot set neither counts toward readiness nor lets an
# unrun slot1/slot2 be reported ready. Slots outside the expected set are
# surfaced separately as an anomaly, never as evidence.
$expectedSlotNames = @()
$unexpectedSlots = @()
$readySlotCount = 0
if ($declarationSummary -and $declarationSummary.PSObject.Properties["plannedRunCount"] -and
    -not $declarationSummary.PSObject.Properties["error"]) {
    $plannedRunCount = [int]$declarationSummary.plannedRunCount
    $expectedSlotNames = @(1..$plannedRunCount | ForEach-Object { "slot$_" })
    $unexpectedSlots = @($slotStatuses | Where-Object { $expectedSlotNames -notcontains [string]$_.slot } |
        ForEach-Object { [string]$_.slot })
    # A slot counts toward readiness only when it is one of the expected slots
    # and its terminal is complete, immutable, and bound to this declaration -
    # the same conditions the reconciliation gate enforces.
    $readySlotCount = @($slotStatuses | Where-Object {
            $expectedSlotNames -contains [string]$_.slot -and
            [string]$_.terminalStatus -ceq "complete" -and
            [bool]$_.PSObject.Properties["terminalImmutable"] -and [bool]$_.terminalImmutable -and
            [bool]$_.PSObject.Properties["boundToDeclaration"] -and [bool]$_.boundToDeclaration
        }).Count
}
$reconciliationReady = $false
if ($declarationSummary -and $declarationSummary.PSObject.Properties["plannedRunCount"] -and
    -not $declarationSummary.PSObject.Properties["error"]) {
    $reconciliationReady = ($readySlotCount -eq [int]$declarationSummary.plannedRunCount -and
        -not (@($slotStatuses | Where-Object { [bool]$_.PSObject.Properties["recordedChildAlive"] -and
                    [bool]$_.recordedChildAlive }).Count))
}

$status = [pscustomobject][ordered]@{
    kind                = "reviewer.replay-qualification.status.v1"
    generatedAtUtc      = [DateTime]::UtcNow.ToString("o")
    qualificationRoot   = $rootFull
    declaration         = $declarationSummary
    slotsAttempted      = @($slotStatuses).Count
    slotsComplete       = $completeCount
    reconciliationReady = $reconciliationReady
    unexpectedSlots     = @($unexpectedSlots)
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
