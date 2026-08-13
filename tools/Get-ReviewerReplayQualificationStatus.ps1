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
    Optional path to the run-set signing key. Supplying it together with the FULL
    plan inputs below puts the tool in parity mode: it reconstructs the exact same
    authenticated plan the reconciliation gate uses and calls the SAME shared
    readiness gate, so 'reconciliationReady' is reported true only when a Reconcile
    invocation with those exact inputs would also pass. Status and Reconcile can
    never positively disagree for the same authenticated inputs. Without the full
    plan inputs, the tool reports 'signatureUnverified' and only 'evidenceComplete'
    (the unauthenticated slot evidence), never 'reconciliationReady'.

.PARAMETER RepoPath / -ConfigFile / -OperatorAlias / -PullRequestId / -ReplayRoot / -ReplaySnapshotName / -ReplayManifestDigest / -ExpectedCommit / -RequiredRef / -SlotCount / model + timeout inputs
    The exact plan inputs Reconcile takes. When all of the mandatory ones are
    supplied together with -RunSetKeyPath, status reconstructs the authenticated
    plan (snapshot identity/digest, repo/PR, model assignments/config, SlotCount)
    and runs the shared gate. Any mismatch - wrong SlotCount, wrong snapshot, wrong
    models - makes readiness false with an explicit reason, exactly as Reconcile
    would reject it. These inputs are read-only; status still launches nothing.

.PARAMETER ReportPath
    Optional path to write the status object to as JSON. The only file written.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QualificationRoot,
    [string]$RunSetKeyPath = "",
    [string]$RepoPath = "",
    [string]$ConfigFile = "",
    [string]$OperatorAlias = "",
    [int]$PullRequestId = 0,
    [string]$ReplayRoot = "",
    [string]$ReplaySnapshotName = "",
    [string]$ReplayManifestDigest = "",
    [string]$ExpectedCommit = "",
    [string]$RequiredRef = "",
    [string]$ReviewerScriptPath = "",
    [string]$ToolkitRepositoryPath = "",
    [ValidateRange(2, 16)][int]$SlotCount = 2,
    [string]$ConventionSpecialistModel = "",
    [string]$ConventionVerifierModel = "",
    [ValidateRange(30, 7200)][int]$CycleTimeoutSeconds = 1800,
    [ValidateRange(30, 3600)][int]$ConventionSpecialistTimeoutSeconds = 900,
    [ValidateRange(30, 3600)][int]$VerificationTimeoutSeconds = 900,
    [ValidateRange(1, 14400)][int]$SlotTimeoutSeconds = 3600,
    [ValidateRange(0, 14400)][int]$ProgressTimeoutSeconds = 0,
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
# Parity mode reconstructs the same plan Reconcile builds, which validates git
# identity and loads the config/snapshot through the agent's own loaders; those
# live in the harness module and the preflight library. They are imported lazily
# only when parity inputs are present, so a plain evidence read stays lightweight.
$compareTool = Join-Path $toolkitRoot "tools\Compare-ReviewerReplayRuns.ps1"
. (Join-Path $toolkitRoot "src\Agents\reviewer\ReplayQualification.ps1")

# Parity mode requires the run-set key AND every mandatory plan input Reconcile
# takes. SlotCount is not part of this test: like the coordinator it defaults to
# a valid value, and a caller-supplied SlotCount that does not match the sealed
# declaration is caught by the shared verifier as an explicit count mismatch
# (readiness false), not silently ignored. Anything less than the full set of
# mandatory inputs is an unauthenticated evidence read that never claims
# reconciliation readiness.
$parityMode = [bool]($RunSetKeyPath -and $RepoPath -and $ConfigFile -and $OperatorAlias -and
    $PullRequestId -gt 0 -and $ReplayRoot -and $ReplaySnapshotName -and $ReplayManifestDigest -and
    $ExpectedCommit -and $RequiredRef)
if ($parityMode) {
    Import-Module (Join-Path $toolkitRoot "src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1") -Force
    . (Join-Path $toolkitRoot "src\Agents\reviewer\QualificationPreflight.ps1")
}

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
    # Slot names come from the PHYSICAL directory entries, kept case-exact. A
    # case-insensitive de-duplication would silently fold a physical 'Slot1' into
    # 'slot1'; an ordinal-unique preserves both so a case-aliased terminal is
    # surfaced as its own (unexpected) slot rather than being absorbed. The
    # terminal itself is then resolved with the SAME shared, case-exact resolver
    # the reconciliation gate uses, so status never opens 'Slot1-terminal.json'
    # where the declared set expects 'slot1' - Status and Reconcile resolve slot
    # evidence identically.
    $attemptFiles = @(Get-ChildItem -LiteralPath $runDirectory -Filter "slot*-attempt.json" -File `
            -ErrorAction SilentlyContinue)
    $terminalFiles = @(Get-ChildItem -LiteralPath $runDirectory -Filter "slot*-terminal.json" -File `
            -ErrorAction SilentlyContinue)
    $slotNames = @(
        @($attemptFiles | ForEach-Object { $_.Name -replace '-attempt\.json$', '' }) +
        @($terminalFiles | ForEach-Object { $_.Name -replace '-terminal\.json$', '' })
    ) | Sort-Object -Unique -CaseSensitive
    foreach ($slotName in $slotNames) {
        $attemptPath = Join-Path $runDirectory "$slotName-attempt.json"
        $attemptExists = Test-Path -LiteralPath $attemptPath -PathType Leaf
        $attempt = $null
        if ($attemptExists) {
            try { $attempt = Get-Content -LiteralPath $attemptPath -Raw | ConvertFrom-Json } catch {}
        }
        # Case-exact terminal resolution via the shared resolver: a physical
        # 'Slot1-terminal.json' is NOT returned for slot 'slot1'.
        $terminalPath = Resolve-ReviewerQualificationSlotTerminalPath -RunDirectory $runDirectory -SlotName $slotName
        $terminal = $null
        $terminalImmutable = $false
        if ($terminalPath) {
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

# --- Parity mode: the ONE shared reconciliation gate ----------------------
# Finding #1: status readiness must be the SAME decision Reconcile makes. When
# the caller supplies the run-set key AND every plan input Reconcile takes,
# status reconstructs the exact authenticated plan and runs the single shared
# gate (Assert-ReviewerQualificationSetReconcilable). reconciliationReady is true
# only when that gate - the same call Reconcile makes - passes; any plan mismatch
# (wrong SlotCount, snapshot, models, repo) or a corrupt/incomplete published set
# yields false with an explicit reason. Without the full plan inputs the tool
# never claims readiness; it only ever exposes the unauthenticated evidence view.
$reconciliationReason = ""
$declarationCorrupt = $false
$gateReconciliationReady = $false
if ($parityMode -and $declarationSummary -and -not $declarationSummary.PSObject.Properties["error"]) {
    if (-not $ReviewerScriptPath) {
        $ReviewerScriptPath = Join-Path $toolkitRoot "src\Agents\reviewer\Start-ReviewerAgent.ps1"
    }
    $statusPlan = $null
    try {
        $statusPlan = New-ReviewerReplayQualificationPlan -RepoPath $RepoPath -ConfigFile $ConfigFile `
            -OperatorAlias $OperatorAlias -PullRequestId $PullRequestId `
            -ReplayRoot $ReplayRoot -ReplaySnapshotName $ReplaySnapshotName `
            -ReplayManifestDigest $ReplayManifestDigest -QualificationRoot $rootFull `
            -ReviewerScriptPath $ReviewerScriptPath -ToolkitRepositoryPath $ToolkitRepositoryPath `
            -ExpectedCommit $ExpectedCommit -RequiredRef $RequiredRef -SlotCount $SlotCount `
            -ConventionSpecialistModel $ConventionSpecialistModel `
            -ConventionVerifierModel $ConventionVerifierModel `
            -CycleTimeoutSeconds $CycleTimeoutSeconds `
            -ConventionSpecialistTimeoutSeconds $ConventionSpecialistTimeoutSeconds `
            -VerificationTimeoutSeconds $VerificationTimeoutSeconds `
            -SlotTimeoutSeconds $SlotTimeoutSeconds -ProgressTimeoutSeconds $ProgressTimeoutSeconds `
            -LaunchAuthorizationHash ""
    }
    catch {
        # A plan that cannot even be reconstructed from these inputs (wrong commit,
        # dirty worktree, unresolved model, missing snapshot) is by definition a
        # mismatch: Reconcile would fail identically. Not ready, with the reason.
        $reconciliationReason = "plan reconstruction failed: $($_.Exception.Message)"
    }
    if ($statusPlan) {
        # Shared verifier: sets the informational signatureVerified flag. This is
        # the SAME verifier the gate runs, so a declaration that no longer verifies
        # (truncated/tampered) is seen identically by status and Reconcile.
        try {
            [void](Get-VerifiedRunSetDeclaration -RunSetDirectory ([string]$statusPlan.RunSetDirectory) `
                    -CompareTool $compareTool -RunSetKeyPath $RunSetKeyPath -Plan $statusPlan)
            $declarationVerified = $true
        }
        catch {
            $declarationVerified = $false
            $reconciliationReason = $_.Exception.Message
        }
        # The SAME shared readiness gate Reconcile runs. reconciliationReady is
        # exactly its verdict, so status and Reconcile cannot positively disagree
        # for the same authenticated inputs.
        try {
            [void](Assert-ReviewerQualificationSetReconcilable -Plan $statusPlan `
                    -CompareTool $compareTool -RunSetKeyPath $RunSetKeyPath)
            $gateReconciliationReady = $true
        }
        catch {
            if (-not $reconciliationReason) { $reconciliationReason = $_.Exception.Message }
        }
    }
    # A truncated/tampered declaration (signature verification failed), or a
    # published set missing/malforming its launch-authorization token inventory,
    # is classified explicitly as a CORRUPT published set: not reconcilable, not
    # launchable, never silently valid. A plan mismatch (wrong count/snapshot) or
    # a merely incomplete set (a slot not yet run) is NOT corrupt - those reasons
    # are deliberately excluded so corruption is not over-reported.
    $declarationCorrupt = [bool]($reconciliationReason -match `
            'did not verify|verification failed|no manifest|corrupt|tampered|missing its launch-authorization|token .*is malformed')
    if ($declarationSummary.PSObject.Properties["signatureVerified"]) {
        $declarationSummary.signatureVerified = $declarationVerified
    }
}

# 'evidenceComplete' is the unauthenticated slot-evidence view: every expected
# slot has a complete, immutable, bound terminal and no recorded child is live.
# It says nothing about the declaration's authenticity or plan binding.
# 'reconciliationReady' is strictly the shared gate's verdict in parity mode -
# it additionally requires a signature-verified declaration, a complete published
# inventory, and an exact plan match - so status can never positively disagree
# with Reconcile for the same authenticated inputs. Outside parity mode the tool
# has no authenticated plan to gate on, so reconciliationReady stays false.
$noLiveChild = -not (@($slotStatuses | Where-Object { [bool]$_.PSObject.Properties["recordedChildAlive"] -and
            [bool]$_.recordedChildAlive }).Count)
$evidenceComplete = $false
if ($declarationSummary -and $declarationSummary.PSObject.Properties["plannedRunCount"] -and
    -not $declarationSummary.PSObject.Properties["error"] -and $countInRange) {
    $evidenceComplete = ($readySlotCount -eq [int]$declarationSummary.plannedRunCount -and $noLiveChild)
}
$reconciliationReady = ($parityMode -and $gateReconciliationReady)

$status = [pscustomobject][ordered]@{
    kind                = "reviewer.replay-qualification.status.v1"
    generatedAtUtc      = [DateTime]::UtcNow.ToString("o")
    qualificationRoot   = $rootFull
    declaration         = $declarationSummary
    slotsAttempted      = @($slotStatuses).Count
    slotsComplete       = $completeCount
    evidenceComplete    = $evidenceComplete
    parityMode          = $parityMode
    signatureUnverified = (-not $declarationVerified)
    declarationCorrupt  = $declarationCorrupt
    reconciliationReady = $reconciliationReady
    reconciliationReason = $reconciliationReason
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
