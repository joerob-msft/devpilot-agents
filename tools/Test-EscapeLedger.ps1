<#
.SYNOPSIS
    Validates the reviewer escape ledger, its recorded counts, and its registered budget trigger.

.DESCRIPTION
    The escape ledger records every defect that escaped review into a merged coordinator
    change since Gate 0, classified by category and by the execution stage it reached. It
    also carries the budget whose breach makes the conditional typed control-plane pivot
    mandatory.

    A ledger that is only written by hand rots: counts drift from the incident list and the
    trigger stops meaning anything. This check recomputes every derived number from the
    incident list, re-evaluates the trigger, proves with sabotage copies that a qualifying
    escape would fire it, and asserts that the ledger stays employer-neutral and free of
    private review identifiers.

.NOTES
    Deterministic. No models, no network, no writes outside the temporary directory.
#>
[CmdletBinding()]
param(
    [switch]$VerifyCommits
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$ledgerPath = Join-Path $repoRoot 'docs/escape-ledger.v1.json'
$schemaPath = Join-Path $repoRoot 'src/Agents/reviewer/schemas/reviewer.escape-ledger.v1.json'
$docPath = Join-Path $repoRoot 'docs/escape-ledger.md'

$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Checks = 0

function Assert-Ledger {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Condition,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )

    $script:Checks++
    if (-not $Condition) {
        $script:Failures.Add($Message)
    }
}

function Get-LedgerObject {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

    return ($Json | ConvertFrom-Json -Depth 32)
}

# Recomputes every derived number in the ledger from the incident list. The ledger is only
# trustworthy if the numbers it publishes are the numbers its own contents imply.
#
# The registered trigger is a rolling window, so it has to be computed as one. The
# combinator is deliberately "either": an incident qualifies when it falls inside the last
# N coordinator changes OR inside the last D days. A safety trigger that only fires when
# both windows agree can be silenced by going quiet (no new changes ages nothing out of
# the ordinal window) or by shipping quickly (many changes push incidents out of the
# ordinal window while they are still days old). Firing on either window removes both
# ways of waiting out the budget.
function Measure-LedgerBudget {
    param([Parameter(Mandatory)][object]$Ledger)

    $threshold = $Ledger.budget.threshold
    $window = $Ledger.budget.window
    $stages = @($threshold.reachedExecutionStages)
    $evaluatedOn = [datetime]::ParseExact(
        [string]$Ledger.coverageWindow.evaluatedOn, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $observed = [int]$Ledger.coverageWindow.coordinatorChangesObserved
    $oldestOrdinalInWindow = $observed - [int]$window.coordinatorChanges + 1
    $earliestDateInWindow = $evaluatedOn.AddDays(-[int]$window.days)

    $qualifying = [System.Collections.Generic.List[string]]::new()
    $inWindow = [System.Collections.Generic.List[string]]::new()

    foreach ($incident in @($Ledger.incidents)) {
        $detectedOn = [datetime]::ParseExact(
            [string]$incident.detectedOn, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $withinOrdinal = ([int]$incident.coordinatorChangeOrdinal -ge $oldestOrdinalInWindow)
        $withinDays = ($detectedOn -ge $earliestDateInWindow)
        $withinWindow = if ($window.combinator -eq 'both') { $withinOrdinal -and $withinDays }
        else { $withinOrdinal -or $withinDays }
        if (-not $withinWindow) { continue }
        $inWindow.Add([string]$incident.id)

        if ($incident.category -ne $threshold.category) { continue }
        if (-not $incident.reachedShadowOrLive) { continue }
        if ($stages -notcontains $incident.executionStage) { continue }
        $qualifying.Add([string]$incident.id)
    }

    $ids = [string[]]::new($qualifying.Count)
    $qualifying.CopyTo($ids, 0)
    $inWindowIds = [string[]]::new($inWindow.Count)
    $inWindow.CopyTo($inWindowIds, 0)

    return [pscustomobject]@{
        QualifyingIds = $ids
        QualifyingCount = $qualifying.Count
        InWindowIds = $inWindowIds
        OldestOrdinalInWindow = $oldestOrdinalInWindow
        EarliestDateInWindow = $earliestDateInWindow.ToString('yyyy-MM-dd')
        Triggered = ($qualifying.Count -ge [int]$threshold.count)
    }
}

if (-not (Test-Path -LiteralPath $ledgerPath)) { throw "Escape ledger not found at $ledgerPath." }
if (-not (Test-Path -LiteralPath $schemaPath)) { throw "Escape ledger schema not found at $schemaPath." }
if (-not (Test-Path -LiteralPath $docPath)) { throw "Escape ledger narrative not found at $docPath." }

$ledgerJson = Get-Content -LiteralPath $ledgerPath -Raw
$ledger = Get-LedgerObject -Json $ledgerJson

# --- 1. Schema ---------------------------------------------------------------------------

Assert-Ledger ([bool](Test-Json -Json $ledgerJson -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) `
    'The escape ledger does not satisfy its versioned schema.'

Assert-Ledger ($ledger.schemaVersion -eq 1) 'The escape ledger declares an unexpected schema version.'
Assert-Ledger ($ledger.kind -eq 'reviewer-escape-ledger') 'The escape ledger declares an unexpected kind.'

# The schema is closed, so an unknown field must be rejected rather than ignored.
$unknownField = Get-LedgerObject -Json $ledgerJson
$unknownField | Add-Member -NotePropertyName 'unexpectedField' -NotePropertyValue 'x'
Assert-Ledger (-not (Test-Json -Json ($unknownField | ConvertTo-Json -Depth 32) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) `
    'The escape ledger schema accepted an unknown top-level field.'

$missingBudget = Get-LedgerObject -Json $ledgerJson
$missingBudget.PSObject.Properties.Remove('budget')
Assert-Ledger (-not (Test-Json -Json ($missingBudget | ConvertTo-Json -Depth 32) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) `
    'The escape ledger schema accepted a ledger with no budget.'

$badCategory = Get-LedgerObject -Json $ledgerJson
$badCategory.incidents[0].category = 'somethingElse'
Assert-Ledger (-not (Test-Json -Json ($badCategory | ConvertTo-Json -Depth 32) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) `
    'The escape ledger schema accepted an incident category outside the vocabulary.'

$badId = Get-LedgerObject -Json $ledgerJson
$badId.incidents[0].id = 'incident-one'
Assert-Ledger (-not (Test-Json -Json ($badId | ConvertTo-Json -Depth 32) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) `
    'The escape ledger schema accepted an incident identifier outside the neutral form.'

# --- 2. Vocabulary completeness ----------------------------------------------------------

$requiredCategories = @('typeBinding', 'logic', 'modelProtocol', 'supervision', 'external')
$requiredStages = @('deterministic', 'shadow', 'live')
$declaredCategories = @($ledger.vocabulary.categories | ForEach-Object { $_.id })
$declaredStages = @($ledger.vocabulary.executionStages | ForEach-Object { $_.id })
$declaredStatuses = @($ledger.vocabulary.statuses | ForEach-Object { $_.id })

foreach ($category in $requiredCategories) {
    Assert-Ledger ($declaredCategories -contains $category) `
        "The escape ledger does not define the required category '$category'."
}
foreach ($stage in $requiredStages) {
    Assert-Ledger ($declaredStages -contains $stage) `
        "The escape ledger does not define the required execution stage '$stage'."
}
Assert-Ledger ($declaredStatuses.Count -ge 1) 'The escape ledger defines no incident statuses.'

# --- 3. Incident integrity ---------------------------------------------------------------

$incidents = @($ledger.incidents)
Assert-Ledger ($incidents.Count -ge 1) 'The escape ledger records no incidents.'

$seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$index = 0
foreach ($incident in $incidents) {
    $index++
    Assert-Ledger ($seenIds.Add($incident.id)) "The escape ledger reuses incident identifier '$($incident.id)'."
    $expectedId = 'ESC-{0:D4}' -f $index
    Assert-Ledger ($incident.id -eq $expectedId) `
        "Incident $($incident.id) is out of sequence; expected $expectedId at position $index."
    Assert-Ledger ($declaredCategories -contains $incident.category) `
        "Incident $($incident.id) uses category '$($incident.category)', which the vocabulary does not define."
    Assert-Ledger ($declaredStages -contains $incident.executionStage) `
        "Incident $($incident.id) uses execution stage '$($incident.executionStage)', which the vocabulary does not define."
    Assert-Ledger ($declaredStatuses -contains $incident.status) `
        "Incident $($incident.id) uses status '$($incident.status)', which the vocabulary does not define."

    $shouldHaveReached = ($incident.executionStage -eq 'shadow' -or $incident.executionStage -eq 'live')
    Assert-Ledger ($incident.reachedShadowOrLive -eq $shouldHaveReached) `
        "Incident $($incident.id) records execution stage '$($incident.executionStage)' but reachedShadowOrLive is $($incident.reachedShadowOrLive)."

    if ($incident.status -eq 'remediated') {
        Assert-Ledger ($incident.PSObject.Properties.Name -contains 'remediatedCommit') `
            "Incident $($incident.id) is marked remediated but records no remediating commit."
    }
}

# --- 4. Budget recomputation and the registered trigger ----------------------------------

$measured = Measure-LedgerBudget -Ledger $ledger
$recordedIds = @($ledger.budget.state.qualifyingIncidentIds)

Assert-Ledger ($ledger.budget.state.qualifyingCount -eq $measured.QualifyingCount) `
    "The escape ledger records $($ledger.budget.state.qualifyingCount) qualifying escape(s) but its incident list implies $($measured.QualifyingCount)."
Assert-Ledger ($recordedIds.Count -eq $measured.QualifyingIds.Count) `
    'The recorded qualifying incident list does not match the incident list.'
foreach ($id in $measured.QualifyingIds) {
    Assert-Ledger ($recordedIds -contains $id) "Incident $id qualifies for the budget but is not recorded in the budget state."
}
Assert-Ledger ($ledger.budget.state.triggered -eq $measured.Triggered) `
    "The escape ledger records triggered=$($ledger.budget.state.triggered) but its incident list implies $($measured.Triggered)."

# The trigger registered by the coordinator programme, asserted literally so that weakening
# it is a reviewed diff rather than a silent edit.
Assert-Ledger ($ledger.budget.threshold.category -eq 'typeBinding') 'The registered trigger no longer watches type-binding escapes.'
Assert-Ledger ([int]$ledger.budget.threshold.count -eq 2) 'The registered trigger no longer fires at two escapes.'
$triggerStages = @($ledger.budget.threshold.reachedExecutionStages)
Assert-Ledger ($triggerStages.Count -eq 2 -and $triggerStages -contains 'shadow' -and $triggerStages -contains 'live') `
    'The registered trigger no longer watches shadow and live execution.'
Assert-Ledger ([int]$ledger.budget.window.coordinatorChanges -eq 10) 'The registered trigger window is no longer ten coordinator changes.'
Assert-Ledger ([int]$ledger.budget.window.days -eq 60) 'The registered trigger window is no longer sixty days.'
Assert-Ledger ($ledger.budget.window.combinator -eq 'either') 'The registered trigger window combinator changed.'
Assert-Ledger ([int]$ledger.coverageWindow.coordinatorChangesObserved -ge 1) `
    'The coverage window observes no coordinator changes.'

# Both clocks the rolling window turns on used to be hand-authored, so the ledger could sit
# frozen while real changes landed and every check still passed. They are derived here and
# the published values only confirm the derivation.
function Measure-LedgerCoverageClock {
    param([Parameter(Mandatory)][object]$Ledger)
    $observed = 0
    $evaluatedOn = ''
    foreach ($incident in @($Ledger.incidents)) {
        if ([int]$incident.coordinatorChangeOrdinal -gt $observed) { $observed = [int]$incident.coordinatorChangeOrdinal }
        if ([string]$incident.detectedOn -gt $evaluatedOn) { $evaluatedOn = [string]$incident.detectedOn }
    }
    return [pscustomobject]@{
        DerivedObserved       = $observed
        DerivedEvaluatedOn    = $evaluatedOn
        PublishedObserved     = [int]$Ledger.coverageWindow.coordinatorChangesObserved
        PublishedEvaluatedOn  = [string]$Ledger.coverageWindow.evaluatedOn
        ObservedAgrees        = ([int]$Ledger.coverageWindow.coordinatorChangesObserved -eq $observed)
        EvaluatedOnAgrees     = ([string]$Ledger.coverageWindow.evaluatedOn -eq $evaluatedOn)
    }
}

$clock = Measure-LedgerCoverageClock -Ledger $ledger
$derivedObserved = $clock.DerivedObserved
$derivedEvaluatedOn = $clock.DerivedEvaluatedOn
Assert-Ledger ($clock.ObservedAgrees) `
    "The coverage window claims $($clock.PublishedObserved) coordinator change(s) but the incidents record $derivedObserved; the window is not being advanced with the ledger."
Assert-Ledger ($clock.EvaluatedOnAgrees) `
    "The coverage window is evaluated on $($clock.PublishedEvaluatedOn) but the newest incident was detected on $derivedEvaluatedOn; the evaluation date is not being advanced with the ledger."

# ...and the derivation has to be able to fail, or it is decoration. Freeze each clock on a
# copy and require the SAME derivation, re-run on the mutated ledger, to report disagreement.
# Asserting only that the mutated value differs from the derived one would be a tautology:
# it must be the comparison above that changes verdict.
$frozenClock = Get-LedgerObject -Json $ledgerJson
$frozenClock.coverageWindow.coordinatorChangesObserved = [int]$derivedObserved + 1
Assert-Ledger (-not (Measure-LedgerCoverageClock -Ledger $frozenClock).ObservedAgrees) `
    'A coordinator-change count that disagrees with the incidents was not distinguishable from the derived one.'
$frozenDate = Get-LedgerObject -Json $ledgerJson
$frozenDate.coverageWindow.evaluatedOn = '2000-01-01'
Assert-Ledger (-not (Measure-LedgerCoverageClock -Ledger $frozenDate).EvaluatedOnAgrees) `
    'An evaluation date that disagrees with the newest incident was not distinguishable from the derived one.'
# The negative controls must be genuinely negative: the same derivation on the unmutated
# ledger has to agree, or the two checks above would pass on anything.
Assert-Ledger ((Measure-LedgerCoverageClock -Ledger (Get-LedgerObject -Json $ledgerJson)).ObservedAgrees) `
    'The coverage-clock derivation disagrees with the unmutated ledger, so its sabotage checks prove nothing.'

# The window is only meaningful if it is computed. Every incident carries the date it was
# detected and the coordinator change it was detected under, and the recorded in-window set
# must be the set those two facts imply.
$recordedInWindow = @($ledger.budget.state.inWindowIncidentIds)
Assert-Ledger ($recordedInWindow.Count -eq $measured.InWindowIds.Count) `
    "The ledger records $($recordedInWindow.Count) in-window incident(s) but the window implies $($measured.InWindowIds.Count)."
foreach ($id in $measured.InWindowIds) {
    Assert-Ledger ($recordedInWindow -contains $id) "Incident $id falls inside the budget window but is not recorded in the budget state."
}
foreach ($incident in $incidents) {
    Assert-Ledger ([int]$incident.coordinatorChangeOrdinal -le [int]$ledger.coverageWindow.coordinatorChangesObserved) `
        "Incident $($incident.id) claims coordinator change ordinal $($incident.coordinatorChangeOrdinal), beyond the $($ledger.coverageWindow.coordinatorChangesObserved) observed."
    Assert-Ledger ([string]$incident.detectedOn -le [string]$ledger.coverageWindow.evaluatedOn) `
        "Incident $($incident.id) was detected on $($incident.detectedOn), after the ledger evaluation date."
}

# An incident aged out of both windows must stop counting, or the budget is a running total
# rather than a rolling one.
$agedOut = Get-LedgerObject -Json $ledgerJson
foreach ($incident in @($agedOut.incidents)) {
    $incident.detectedOn = '2020-01-01'
    $incident.coordinatorChangeOrdinal = 1
}
$agedOut.coverageWindow.coordinatorChangesObserved = 400
$agedMeasured = Measure-LedgerBudget -Ledger $agedOut
Assert-Ledger ($agedMeasured.InWindowIds.Count -eq 0) `
    'Incidents outside both the ordinal and the day window were still counted as in-window.'

# --- 5. Sabotage: the trigger must actually fire -----------------------------------------

# One qualifying escape is below the threshold.
$oneEscape = Get-LedgerObject -Json $ledgerJson
$oneEscape.incidents[0].executionStage = 'shadow'
$oneEscape.incidents[0].reachedShadowOrLive = $true
$oneMeasured = Measure-LedgerBudget -Ledger $oneEscape
Assert-Ledger ($oneMeasured.QualifyingCount -eq 1 -and -not $oneMeasured.Triggered) `
    'A single type-binding escape reaching shadow was miscounted or fired the trigger early.'

# Two qualifying escapes must fire it.
$twoEscapes = Get-LedgerObject -Json $ledgerJson
$typeBindingIndexes = @()
for ($i = 0; $i -lt $twoEscapes.incidents.Count; $i++) {
    if ($twoEscapes.incidents[$i].category -eq 'typeBinding') { $typeBindingIndexes += $i }
}
Assert-Ledger ($typeBindingIndexes.Count -ge 2) 'The ledger has fewer than two type-binding incidents to sabotage.'
if ($typeBindingIndexes.Count -ge 2) {
    foreach ($i in $typeBindingIndexes[0..1]) {
        $twoEscapes.incidents[$i].executionStage = 'live'
        $twoEscapes.incidents[$i].reachedShadowOrLive = $true
    }
    $twoMeasured = Measure-LedgerBudget -Ledger $twoEscapes
    Assert-Ledger ($twoMeasured.QualifyingCount -eq 2 -and $twoMeasured.Triggered) `
        'Two type-binding escapes reaching live did not fire the registered trigger.'
}

# Escapes in another category must not fire it.
$otherCategory = Get-LedgerObject -Json $ledgerJson
foreach ($incident in @($otherCategory.incidents)) {
    if ($incident.category -eq 'logic') {
        $incident.executionStage = 'live'
        $incident.reachedShadowOrLive = $true
    }
}
$otherMeasured = Measure-LedgerBudget -Ledger $otherCategory
Assert-Ledger (-not $otherMeasured.Triggered) 'Logic escapes reaching live incorrectly fired the type-binding trigger.'

# Shadow is not a lesser arm of the trigger. A shadow run discards its output, so it
# preserves the no-write invariant while still exercising the code under test - which is
# exactly why an escape that reaches shadow has to count. Two shadow escapes must fire.
$shadowOnly = Get-LedgerObject -Json $ledgerJson
$shadowIndexes = @()
for ($i = 0; $i -lt $shadowOnly.incidents.Count; $i++) {
    if ($shadowOnly.incidents[$i].category -eq 'typeBinding') { $shadowIndexes += $i }
}
if ($shadowIndexes.Count -ge 2) {
    foreach ($i in $shadowIndexes[0..1]) {
        $shadowOnly.incidents[$i].executionStage = 'shadow'
        $shadowOnly.incidents[$i].reachedShadowOrLive = $true
    }
    foreach ($observation in @($shadowOnly.gateObservations)) {
        $observation.externalWrites = 0
        $observation.noWriteInvariantHeld = $true
    }
    $shadowMeasured = Measure-LedgerBudget -Ledger $shadowOnly
    Assert-Ledger ($shadowMeasured.QualifyingCount -eq 2 -and $shadowMeasured.Triggered) `
        'Two type-binding escapes reaching shadow did not fire the registered trigger.'
}

# A drifted count must be caught rather than believed.
$driftedCount = Get-LedgerObject -Json $ledgerJson
$driftedCount.budget.state.qualifyingCount = 7
$driftedMeasured = Measure-LedgerBudget -Ledger $driftedCount
Assert-Ledger ($driftedCount.budget.state.qualifyingCount -ne $driftedMeasured.QualifyingCount) `
    'A deliberately drifted qualifying count was not distinguishable from the recomputed one.'

# --- 6. Gate observations ----------------------------------------------------------------

$gateFive = @($ledger.gateObservations | Where-Object { $_.gate -eq 'Gate 5' })
Assert-Ledger ($gateFive.Count -eq 1) 'The escape ledger does not record exactly one Gate 5 observation.'
if ($gateFive.Count -eq 1) {
    Assert-Ledger ([double]$gateFive[0].decisionYieldPercent -eq 0) 'The recorded Gate 5 decision yield is not zero per cent.'
    Assert-Ledger ([int]$gateFive[0].externalWrites -eq 0) 'The recorded Gate 5 run performed external writes.'
    Assert-Ledger ($gateFive[0].noWriteInvariantHeld -eq $true) 'The recorded Gate 5 run did not hold the no-write invariant.'
    Assert-Ledger ([int]$gateFive[0].shadowRunsPerformed -ge 0) 'The Gate 5 observation records no shadow run count.'
    Assert-Ledger ([int]$gateFive[0].liveRunsPerformed -ge 0) 'The Gate 5 observation records no live run count.'
}

foreach ($observation in @($ledger.gateObservations)) {
    $writesConsistent = (([int]$observation.externalWrites -eq 0) -eq [bool]$observation.noWriteInvariantHeld)
    Assert-Ledger $writesConsistent `
        "Gate observation '$($observation.gate)' records $($observation.externalWrites) external write(s) but claims noWriteInvariantHeld=$($observation.noWriteInvariantHeld)."
    Assert-Ledger ([int]$observation.liveRunsPerformed -eq 0 -or [int]$observation.externalWrites -gt 0 -or -not $observation.noWriteInvariantHeld) `
        "Gate observation '$($observation.gate)' claims live runs while also claiming zero external writes."
}

# Only live execution contradicts the no-write invariant. Shadow execution runs the code
# and discards the output, so it writes nothing externally by construction: treating a
# shadow escape as inconsistent with the invariant would make the shadow arm of the
# registered trigger unusable, which is the opposite of what it is for.
$reachedLive = @($incidents | Where-Object { $_.executionStage -eq 'live' })
$allHeld = -not (@($ledger.gateObservations | Where-Object { -not $_.noWriteInvariantHeld }).Count)
Assert-Ledger (-not ($reachedLive.Count -gt 0 -and $allHeld)) `
    'The ledger claims escapes reached live execution while also claiming the no-write invariant always held.'

# Abstention is not evidence. Never running shadow keeps the escape rate at zero for ever,
# so the ledger has to state the shadow exposure the decision is conditional on and report
# honestly how much of it has been performed.
$obligation = $ledger.decision.exposureObligation
Assert-Ledger ([int]$obligation.requiredShadowRuns -ge 1) `
    'The decision records no required shadow exposure, so a zero escape rate could be produced by never running.'
$performed = 0
foreach ($observation in @($ledger.gateObservations)) { $performed += [int]$observation.shadowRunsPerformed }
Assert-Ledger ([int]$obligation.shadowRunsPerformed -eq $performed) `
    "The decision records $($obligation.shadowRunsPerformed) shadow run(s) but the gate observations total $performed."
Assert-Ledger ([bool]$obligation.satisfied -eq ($performed -ge [int]$obligation.requiredShadowRuns)) `
    "The decision claims the exposure obligation is satisfied=$($obligation.satisfied) with $performed of $($obligation.requiredShadowRuns) required shadow run(s)."
Assert-Ledger ([int]$obligation.byCoordinatorChange -gt [int]$ledger.coverageWindow.coordinatorChangesObserved) `
    'The exposure obligation is not due after the coordinator changes already observed, so it records no future commitment.'

# --- 7. Decision status and prerequisite completion --------------------------------------

Assert-Ledger ($ledger.decision.status -eq 'conditional') `
    "The typed control-plane decision is recorded as '$($ledger.decision.status)'; this change may only record it as conditional."

$prerequisiteIds = @('cardinality-corpus', 'file-contract', 'boundary-analyzer', 'escape-ledger')
$declaredPrerequisites = @($ledger.decision.prerequisites | ForEach-Object { $_.id })
foreach ($id in $prerequisiteIds) {
    Assert-Ledger ($declaredPrerequisites -contains $id) "The decision record omits prerequisite '$id'."
}

# Every prerequisite claimed complete must point at evidence that exists on disk.
foreach ($prerequisite in @($ledger.decision.prerequisites)) {
    if (-not $prerequisite.complete) { continue }
    $referenced = [regex]::Matches($prerequisite.evidence, '(?<path>(?:src|tools|docs)/[A-Za-z0-9_./-]+\.(?:ps1|json|md))')
    Assert-Ledger ($referenced.Count -ge 1) `
        "Prerequisite '$($prerequisite.id)' is marked complete but cites no evidence file."
    foreach ($match in $referenced) {
        $candidate = Join-Path $repoRoot $match.Groups['path'].Value
        Assert-Ledger (Test-Path -LiteralPath $candidate) `
            "Prerequisite '$($prerequisite.id)' cites '$($match.Groups['path'].Value)', which does not exist."
    }
}

# The budget is only "in force" if something other than the ledger's own authors advances
# its clock. coordinatorChangesObserved moves only when an incident carries a higher
# ordinal, so an incident-free coordinator change - the common case - does not move it, and
# evaluatedOn tracks the newest incident rather than the present. A clock with that
# authority can lag arbitrarily, so declaring the trigger in force on top of it would be
# the same failure mode as a detector that fails open. The gate refuses the combination.
$ledgerPrerequisite = @($ledger.decision.prerequisites | Where-Object { $_.id -eq 'escape-ledger' })
Assert-Ledger ($ledgerPrerequisite.Count -eq 1) 'The decision record does not declare the escape-ledger prerequisite exactly once.'

function Test-ClockAuthorityConsistent {
    <#
        Returns $true when the escape-ledger prerequisite's in-force claim is compatible
        with the authority of the clock underneath it.

        Only one authority is legal in this schema version. An earlier form of this rule
        accepted any authority other than authoredOrdinals and blessed the in-force claim
        on sight, which meant two string edits - name an authority that does not exist,
        set inForce true - produced a green but still authority-free clock. A rule that can
        be satisfied by asserting the thing it is meant to verify is not a rule.
    #>
    param([Parameter(Mandatory)][object]$Prerequisite)
    $names = @($Prerequisite.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names -notcontains 'clockAuthority') { return $false }
    if ([string]$Prerequisite.clockAuthority -ne 'authoredOrdinals') { return $false }
    return (-not [bool]$Prerequisite.inForce)
}

if ($ledgerPrerequisite.Count -eq 1) {
    $ledgerPrereqNames = @($ledgerPrerequisite[0].PSObject.Properties | ForEach-Object { $_.Name })
    Assert-Ledger ($ledgerPrereqNames -contains 'clockAuthority') `
        "The escape-ledger prerequisite does not declare a clockAuthority, so a reader cannot tell whether the window clock is authoritative."
    if ($ledgerPrereqNames -contains 'clockAuthority') {
        $clockAuthority = [string]$ledgerPrerequisite[0].clockAuthority
        Assert-Ledger ($clockAuthority -eq 'authoredOrdinals') `
            "Unknown clockAuthority '$clockAuthority'. Only authoredOrdinals is defined in this schema version; a new authority may be named only in the change that also adds the data it reads and the checks that establish that data is current."
        Assert-Ledger (Test-ClockAuthorityConsistent -Prerequisite $ledgerPrerequisite[0]) `
            'The escape-ledger prerequisite is declared in force while its window clock advances only from authored incident ordinals. An incident-free coordinator change does not move that clock, so the trigger cannot be treated as current. Leave inForce false until a coordinator-change registry and the checks that read it exist.'
        Assert-Ledger ([string]$ledgerPrerequisite[0].inForceNote -match 'Gate 5') `
            'The escape-ledger prerequisite runs on an authored clock but its note does not state what Gate 5 must require before reading the trigger as current.'
    }

    # The rule has to be able to fail on each combination it exists to forbid, and has to
    # accept the one it exists to permit. None of that is true by construction.
    $forcedClock = (Get-LedgerObject -Json $ledgerJson).decision.prerequisites | Where-Object { $_.id -eq 'escape-ledger' }
    $forcedClock.inForce = $true
    $forcedClock.clockAuthority = 'authoredOrdinals'
    Assert-Ledger (-not (Test-ClockAuthorityConsistent -Prerequisite $forcedClock)) `
        'An escape-ledger prerequisite declared in force on an authored clock was accepted.'
    $inventedClock = (Get-LedgerObject -Json $ledgerJson).decision.prerequisites | Where-Object { $_.id -eq 'escape-ledger' }
    $inventedClock.inForce = $true
    $inventedClock.clockAuthority = 'coordinatorChangeRegistry'
    Assert-Ledger (-not (Test-ClockAuthorityConsistent -Prerequisite $inventedClock)) `
        'The clock-authority rule accepted an in-force budget backed by an authority this schema version does not define, so the clock can be switched on by naming a registry that does not exist.'
    $restingClock = (Get-LedgerObject -Json $ledgerJson).decision.prerequisites | Where-Object { $_.id -eq 'escape-ledger' }
    $restingClock.inForce = $false
    $restingClock.clockAuthority = 'authoredOrdinals'
    Assert-Ledger (Test-ClockAuthorityConsistent -Prerequisite $restingClock) `
        'The clock-authority rule rejects the only combination this schema version permits, so it forbids the honest state as well as the dishonest ones.'
}

# The counts and the trigger state live in the machine-readable budget, so whatever tells a
# reader they are a dated snapshot rather than a live reading has to live there too. A caveat
# that appears only in prose is not attached to the data anyone parses.
$budgetNames = @($ledger.budget.PSObject.Properties | ForEach-Object { $_.Name })
Assert-Ledger ($budgetNames -contains 'operationalStatus') `
    'The budget publishes qualifying counts and a triggered flag without an operationalStatus, so a machine reader cannot tell that its window clock is authored rather than derived.'
if ($budgetNames -contains 'operationalStatus') {
    Assert-Ledger ([string]$ledger.budget.operationalStatus -eq 'historicalSnapshot') `
        "The budget declares operationalStatus '$($ledger.budget.operationalStatus)'. While clockAuthority is authoredOrdinals the only defensible status is historicalSnapshot."
}
Assert-Ledger ($budgetNames -contains 'asOfCommit') `
    'The budget does not say which commit its counts were taken at, so the snapshot has no date attached to it.'
if ($budgetNames -contains 'asOfCommit') {
    Assert-Ledger ([string]$ledger.budget.asOfCommit -eq [string]$ledger.coverageWindow.endCommit) `
        "The budget is stated as of $($ledger.budget.asOfCommit) but the coverage window ends at $($ledger.coverageWindow.endCommit); the counts and the window they are drawn from must agree."
}
foreach ($incident in $incidents) {
    $cited = [regex]::Matches("$($incident.detector) $($incident.regressionGuard)", '(?<path>(?:src|tools|docs)/[A-Za-z0-9_./-]+\.(?:ps1|json|md))')
    foreach ($match in $cited) {
        $candidate = Join-Path $repoRoot $match.Groups['path'].Value
        Assert-Ledger (Test-Path -LiteralPath $candidate) `
            "Incident $($incident.id) cites '$($match.Groups['path'].Value)', which does not exist."
    }
}

# --- 8. Neutrality ------------------------------------------------------------------------

$forbidden = @(
    @{ Pattern = '(?m)#\d+'; Reason = 'a pull request or issue number' },
    @{ Pattern = '(?i)\bPR[-\s]?\d+\b'; Reason = 'a pull request reference' },
    @{ Pattern = '(?i)\b(?:pull|issues)/\d+'; Reason = 'a pull request or issue URL fragment' },
    @{ Pattern = '(?i)\bAB#\d+\b'; Reason = 'a work item reference' },
    @{ Pattern = '(?i)@[A-Za-z0-9._-]+\.(?:com|net|org)\b'; Reason = 'an email address' },
    @{ Pattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'; Reason = 'a globally unique identifier' }
)

$docText = Get-Content -LiteralPath $docPath -Raw
foreach ($target in @(
        @{ Name = 'docs/escape-ledger.v1.json'; Text = $ledgerJson },
        @{ Name = 'docs/escape-ledger.md'; Text = $docText })) {
    foreach ($rule in $forbidden) {
        $hit = [regex]::Match($target.Text, $rule.Pattern)
        Assert-Ledger (-not $hit.Success) `
            "$($target.Name) contains $($rule.Reason) ('$($hit.Value)'); the ledger must stay employer-neutral."
    }
}

# --- 9. The narrative must stay in step with the data ------------------------------------

foreach ($incident in $incidents) {
    Assert-Ledger ($docText -match [regex]::Escape($incident.id)) `
        "docs/escape-ledger.md does not mention incident $($incident.id)."
}
$documentedIds = @([regex]::Matches($docText, 'ESC-\d{4}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
foreach ($id in $documentedIds) {
    Assert-Ledger ($seenIds.Contains($id)) "docs/escape-ledger.md mentions incident $id, which the ledger does not record."
}
Assert-Ledger ($docText -match 'Gate 5') 'docs/escape-ledger.md does not record the Gate 5 observation.'

# --- 10. Optional commit verification -----------------------------------------------------

$commitsVerified = 0
# A near miss was introduced and detected inside the same unmerged change, so it never
# entered a merged coordinator change and is not an escape. Keeping the two collections
# separate is load-bearing: the budget decision reads escape category totals, and a
# self-referential pre-merge finding counted as a type-binding escape would bias that
# evidence toward the very pivot it is supposed to inform.
$nearMisses = @()
if ($ledger.PSObject.Properties.Name -contains 'nearMisses') { $nearMisses = @($ledger.nearMisses) }
$incidentIdSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($incidents | ForEach-Object { [string]$_.id }))
$nearMissIndex = 0
foreach ($nearMiss in $nearMisses) {
    $nearMissIndex++
    $expectedId = 'NM-{0:d4}' -f $nearMissIndex
    Assert-Ledger ([string]$nearMiss.id -eq $expectedId) `
        "Near miss $($nearMiss.id) is out of sequence; expected $expectedId at position $nearMissIndex."
    Assert-Ledger (-not $incidentIdSet.Contains([string]$nearMiss.id)) `
        "Near miss $($nearMiss.id) also appears in the incident list; a finding is one or the other."
    Assert-Ledger ($false -eq $nearMiss.mergedBeforeDetection) `
        "Near miss $($nearMiss.id) records mergedBeforeDetection true, which makes it an escape and not a near miss."
    Assert-Ledger (-not [string]::IsNullOrWhiteSpace([string]$nearMiss.whyNotAnEscape)) `
        "Near miss $($nearMiss.id) does not state why it is not an escape."
    Assert-Ledger ($recordedInWindow -notcontains [string]$nearMiss.id) `
        "Near miss $($nearMiss.id) is recorded in the budget window; near misses are not budget evidence."
    if ($docText) {
        Assert-Ledger ($docText -match [regex]::Escape([string]$nearMiss.id)) `
            "docs/escape-ledger.md does not mention near miss $($nearMiss.id)."
    }
}

# Two axes, not one. A containment escape is a defect that entered a merged coordinator
# change; a runtime exposure finding is one that reached shadow or live execution, whether
# or not it ever merged. Only the first is budget evidence, but the second is the evidence
# the typed-host decision most wants to read, and a taxonomy that cannot represent
# "reached live before merge" is a taxonomy that quietly drops it. So the near-miss schema
# no longer pins reachedShadowOrLive false, and the count is published across both lists.
$runtimeExposureIds = @(@(@($incidents) + @($nearMisses)) | Where-Object { $true -eq $_.reachedShadowOrLive } | ForEach-Object { [string]$_.id })
$runtimeExposure = $runtimeExposureIds.Count
$runsPerformed = [int]$ledger.gateObservations.shadowRunsPerformed + [int]$ledger.gateObservations.liveRunsPerformed
if ($runsPerformed -eq 0) {
    Assert-Ledger ($runtimeExposure -eq 0) `
        "The ledger records $runtimeExposure finding(s) that reached shadow or live execution ($($runtimeExposureIds -join ', ')), but gateObservations reports no shadow or live run has ever been performed. One of the two is wrong."
}
foreach ($exposed in @(@($incidents) + @($nearMisses)) | Where-Object { $true -eq $_.reachedShadowOrLive }) {
    Assert-Ledger ([string]$exposed.executionStage -in @('shadow', 'live')) `
        "Finding $($exposed.id) reached shadow or live execution but records executionStage '$($exposed.executionStage)'."
}

# The trigger counts type-binding escapes, so `category` is the single field with the most
# leverage over the pivot decision, and on its own it was pure assertion: changing one
# incident from typeBinding to logic walked the count down with nothing to object. It cannot
# be derived - what a defect "was" is a judgement - but it can be held consistent with the
# detector the same incident already cites. A collection-collapse rule and a control-flow
# rule are not interchangeable, so an incident detected by one and classified as the other is
# a contradiction inside the record. This raises the cost of a quiet edit from one field to
# two mutually corroborating ones; it is not proof, and docs/hardening-limitations.md says so.
$collapseRules = @('PSEN004', 'PSEN009', 'PSEN011')
$controlFlowRules = @('PSEN003', 'PSEN006', 'PSEN010')

function Get-DetectorImpliedCategory {
    <#
        Returns 'typeBinding', 'logic', or $null when the cited detector does not imply a
        category - either because it names rules from both families or because it names no
        recognised detector at all. A null is not a pass by default; it means this particular
        anchor has nothing to say, which the caller records rather than hides.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string[]]$CollapseRules,
        [Parameter(Mandatory)][string[]]$ControlFlowRules
    )
    $named = @([regex]::Matches($Text, 'PSEN\d{3}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    $collapse = @($named | Where-Object { $CollapseRules -contains $_ })
    $controlFlow = @($named | Where-Object { $ControlFlowRules -contains $_ })
    if ($Text -match '(?i)boundary variant harness|Test-ReviewerCollectionCardinality') { $collapse = @($collapse) + @('cardinality') }
    if ($collapse.Count -gt 0 -and $controlFlow.Count -eq 0) { return 'typeBinding' }
    if ($controlFlow.Count -gt 0 -and $collapse.Count -eq 0) { return 'logic' }
    return $null
}

$categoryAnchored = 0
foreach ($incident in $incidents) {
    $implied = Get-DetectorImpliedCategory -Text ([string]$incident.detector) -CollapseRules $collapseRules -ControlFlowRules $controlFlowRules
    if ($null -eq $implied) { continue }
    $categoryAnchored++
    Assert-Ledger ([string]$incident.category -eq $implied) `
        "Escape $($incident.id) is classified '$($incident.category)' but the detector it cites is a $implied detector. A collection-collapse rule and a control-flow rule are not interchangeable, so one of the two fields is wrong; the trigger counts type-binding escapes and cannot be moved by editing the category alone."
}

# The anchor has to be able to fail, and has to bite on the field the budget actually reads.
$categoryProbe = @($incidents | Where-Object { $_.category -eq 'typeBinding' -and $null -ne (Get-DetectorImpliedCategory -Text ([string]$_.detector) -CollapseRules $collapseRules -ControlFlowRules $controlFlowRules) } | Select-Object -First 1)
Assert-Ledger ($categoryProbe.Count -eq 1) `
    'No type-binding escape has a detector-anchored category, so the anchor constrains nothing the budget reads.'
if ($categoryProbe.Count -eq 1) {
    $reclassified = 'logic'
    Assert-Ledger ((Get-DetectorImpliedCategory -Text ([string]$categoryProbe[0].detector) -CollapseRules $collapseRules -ControlFlowRules $controlFlowRules) -ne $reclassified) `
        "Reclassifying $($categoryProbe[0].id) as '$reclassified' does not contradict its cited detector, so the category anchor would not have caught it."
}

if ($VerifyCommits) {
    foreach ($incident in (@($incidents) + @($nearMisses))) {
        foreach ($property in @('introducedCommit', 'remediatedCommit')) {
            if ($incident.PSObject.Properties.Name -notcontains $property) { continue }
            $sha = [string]$incident.$property
            & git -C $repoRoot cat-file -e "$sha^{commit}" 2>$null
            Assert-Ledger ($LASTEXITCODE -eq 0) "Incident $($incident.id) cites commit $sha, which is not in this repository's history."
            $commitsVerified++
        }
    }

    # The escape-versus-near-miss split decides what the budget counts, so it cannot rest on
    # a self-declared boolean alone. Git is used here as a contradiction check, not as an
    # oracle: reachability establishes that a commit is in a history, not that the defective
    # state entered an integrated coordinator revision before it was detected. It is one-way
    # useful. An escape claimed to be merged whose introducing commit is not reachable from
    # the window end is provably misfiled, and a near miss claimed never to have merged whose
    # introducing commit was already on the mainline it was classified against is provably
    # misfiled. Neither direction proves the honest case; both catch the dishonest one.
    #
    # Known limits, recorded in docs/hardening-limitations.md rather than papered over: a
    # squash or cherry-pick lands the same defect under a different hash, a non-squash merge
    # of a branch that introduced and fixed a defect makes both commits reachable, and a
    # defect on an operational side branch is reachable from neither.
    $windowEnd = [string]$ledger.coverageWindow.endCommit

    function Test-CommitMerged {
        param([Parameter(Mandatory)][string]$Sha, [Parameter(Mandatory)][string]$WindowEnd, [Parameter(Mandatory)][string]$RepoRoot)
        & git -C $RepoRoot merge-base --is-ancestor $Sha $WindowEnd 2>$null
        return ($LASTEXITCODE -eq 0)
    }

    # Applied to escapes and near misses alike. Filing this only on the near-miss side left
    # the escape side able to name one commit as both the cause and the cure.
    function Assert-RemediationCommit {
        param([Parameter(Mandatory)][object]$Finding, [Parameter(Mandatory)][string]$RepoRoot)
        $names = @($Finding.PSObject.Properties | ForEach-Object { $_.Name })
        if ($names -notcontains 'remediatedCommit' -or $names -notcontains 'introducedCommit') { return }
        $introduced = [string]$Finding.introducedCommit
        $remediated = [string]$Finding.remediatedCommit
        Assert-Ledger ($remediated -ne $introduced) `
            "Finding $($Finding.id) cites $remediated as both its introducing and its remediating commit. One commit cannot do both; if the remediation ships in a commit whose hash does not exist yet, omit remediatedCommit and let status plus the regression guard carry it."
        & git -C $RepoRoot merge-base --is-ancestor $introduced $remediated 2>$null
        Assert-Ledger ($LASTEXITCODE -eq 0) `
            "Finding $($Finding.id) claims remediation at $remediated, which does not descend from the introducing commit $introduced, so it cannot contain the fix."
    }

    # The ancestry rule must not be opt-out. An earlier form skipped an incident that simply
    # omitted introducedCommit, so an author could take a finding out of the git check - in
    # either direction - by deleting one optional field rather than by asserting a false
    # fact. The field is required by the schema and its absence is a failure here too.
    foreach ($incident in $incidents) {
        $incidentNames = @($incident.PSObject.Properties | ForEach-Object { $_.Name })
        Assert-Ledger ($incidentNames -contains 'introducedCommit') `
            "Escape $($incident.id) cites no introducedCommit, so its claim to have entered a merged coordinator change cannot be checked against git and it would be counted against the budget unexamined."
        if ($incidentNames -notcontains 'introducedCommit') { continue }
        Assert-Ledger (Test-CommitMerged -Sha ([string]$incident.introducedCommit) -WindowEnd $windowEnd -RepoRoot $repoRoot) `
            "Escape $($incident.id) was introduced at $($incident.introducedCommit), which is not reachable from the coverage window's end commit $windowEnd. An escape is a defect that entered a merged coordinator change; if this one never merged it belongs in nearMisses."
        Assert-RemediationCommit -Finding $incident -RepoRoot $repoRoot
    }

    foreach ($nearMiss in $nearMisses) {
        $nearMissNames = @($nearMiss.PSObject.Properties | ForEach-Object { $_.Name })
        Assert-Ledger ($nearMissNames -contains 'introducedCommit') `
            "Near miss $($nearMiss.id) cites no introducedCommit, so its claim never to have merged cannot be checked against git."
        Assert-Ledger ($nearMissNames -contains 'classifiedAgainstCommit') `
            "Near miss $($nearMiss.id) cites no classifiedAgainstCommit, so there is no fixed mainline to test its unmerged claim against."
        if ($nearMissNames -notcontains 'introducedCommit' -or $nearMissNames -notcontains 'classifiedAgainstCommit') { continue }
        $introduced = [string]$nearMiss.introducedCommit
        $classifiedAgainst = [string]$nearMiss.classifiedAgainstCommit

        # The test runs against the commit the finding was classified against, not the live
        # window end. Using the live end would be a time bomb: merging the very change that
        # contains a near miss makes its introducing commit reachable, and the gate would
        # then fail - or, worse, demand that a correctly filed near miss be reclassified as
        # an escape - for no reason other than that time passed.
        Assert-Ledger (Test-CommitMerged -Sha $classifiedAgainst -WindowEnd $windowEnd -RepoRoot $repoRoot) `
            "Near miss $($nearMiss.id) was classified against $classifiedAgainst, which is not reachable from the coverage window's end commit $windowEnd. A finding must be classified against a commit on the mainline the window describes."
        Assert-Ledger (-not (Test-CommitMerged -Sha $introduced -WindowEnd $classifiedAgainst -RepoRoot $repoRoot)) `
            "Near miss $($nearMiss.id) was introduced at $introduced, which IS reachable from the mainline commit $classifiedAgainst it was classified against. A defect already on the mainline is an escape and must be counted against the budget; it cannot be reclassified out of the window by declaring mergedBeforeDetection false."

        Assert-RemediationCommit -Finding $nearMiss -RepoRoot $repoRoot
    }

    # The two rules must be able to fail, and must fail in opposite directions. Feed each
    # the other's commits, against the same reference each rule actually uses.
    $mergedProbe = @($incidents | Where-Object { $_.PSObject.Properties.Name -contains 'introducedCommit' } | Select-Object -First 1)
    $unmergedProbe = @($nearMisses | Where-Object { $_.PSObject.Properties.Name -contains 'classifiedAgainstCommit' } | Select-Object -First 1)
    if ($mergedProbe.Count -eq 1 -and $unmergedProbe.Count -eq 1) {
        $probeBaseline = [string]$unmergedProbe[0].classifiedAgainstCommit
        Assert-Ledger (Test-CommitMerged -Sha ([string]$mergedProbe[0].introducedCommit) -WindowEnd $windowEnd -RepoRoot $repoRoot) `
            'The merged-commit test does not recognise a commit the ledger records as merged, so the escape rule proves nothing.'
        Assert-Ledger (-not (Test-CommitMerged -Sha ([string]$unmergedProbe[0].introducedCommit) -WindowEnd $probeBaseline -RepoRoot $repoRoot)) `
            'The merged-commit test reports an unmerged commit as merged, so the near-miss rule proves nothing.'
        Assert-Ledger (Test-CommitMerged -Sha ([string]$mergedProbe[0].introducedCommit) -WindowEnd $probeBaseline -RepoRoot $repoRoot) `
            'A commit the ledger records as merged is not reachable from the mainline commit the near misses were classified against, so the near-miss rule is being applied against a baseline that would accept a genuine escape.'
    }

    # The reason the near-miss rule reads classifiedAgainstCommit rather than the live
    # window end is not decorative, and this proves it: every near miss's introducing commit
    # IS reachable from HEAD - it is in this branch - while being unreachable from the
    # mainline it was classified against. A rule anchored to a moving reference would
    # therefore flip these findings to "merged" the moment the change containing them lands,
    # reclassifying correctly filed near misses as escapes purely because time passed.
    foreach ($nearMiss in $nearMisses) {
        $nearMissNames = @($nearMiss.PSObject.Properties | ForEach-Object { $_.Name })
        if ($nearMissNames -notcontains 'introducedCommit' -or $nearMissNames -notcontains 'classifiedAgainstCommit') { continue }
        $introduced = [string]$nearMiss.introducedCommit
        Assert-Ledger (Test-CommitMerged -Sha $introduced -WindowEnd 'HEAD' -RepoRoot $repoRoot) `
            "Near miss $($nearMiss.id) cites an introducing commit $introduced that is not reachable from HEAD, so this branch does not contain the change it describes."
        Assert-Ledger (-not (Test-CommitMerged -Sha $introduced -WindowEnd ([string]$nearMiss.classifiedAgainstCommit) -RepoRoot $repoRoot)) `
            "Near miss $($nearMiss.id) is reachable from its own classification baseline, so the baseline distinguishes nothing."
    }

    # The window closes at a named commit, so its evaluation date is that commit's date and
    # nothing else. Deriving it from git is what stops the ledger from being re-dated by hand
    # without the window actually moving.
    $endCommit = [string]$ledger.coverageWindow.endCommit
    & git -C $repoRoot cat-file -e "$endCommit^{commit}" 2>$null
    Assert-Ledger ($LASTEXITCODE -eq 0) "The coverage window ends at commit $endCommit, which is not in this repository's history."
    if ($LASTEXITCODE -eq 0) {
        $commitsVerified++
        $endCommitDate = (& git -C $repoRoot show -s --format=%cs $endCommit).Trim()
        Assert-Ledger ([string]$ledger.coverageWindow.evaluatedOn -eq $endCommitDate) `
            "The coverage window is evaluated on $($ledger.coverageWindow.evaluatedOn) but its end commit $endCommit was committed on $endCommitDate."

        & git -C $repoRoot merge-base --is-ancestor $endCommit HEAD 2>$null
        Assert-Ledger ($LASTEXITCODE -eq 0) `
            "The coverage window ends at commit $endCommit, which is not an ancestor of HEAD; the ledger is describing a history this branch does not have."

        # A rolling budget that is never re-evaluated is a running total. Once the head has
        # moved further than the declared bound, the ledger has to be brought forward before
        # anything else merges.
        #
        # The bound is not a free number. coordinatorChangesObserved is derived from incident
        # ordinals, so a run of incident-free coordinator changes does not advance it - the
        # clock can only lag, never race. Bounding that lag in commits requires knowing what a
        # coordinator change costs in commits, which the window itself supplies: the commits
        # it spans divided by the changes it observed. The declared bound must stay inside two
        # coordinator changes at that observed rate, so the clock can never fall behind by a
        # fifth of the ten-change budget window.
        $behind = [int]((& git -C $repoRoot rev-list --count "$endCommit..HEAD").Trim())
        $staleAfter = [int]$ledger.coverageWindow.staleAfterCommitsBehindHead
        Assert-Ledger ($staleAfter -ge 1) 'The coverage window declares no staleness bound, so it can never be forced forward.'

        $startCommit = [string]$ledger.coverageWindow.startCommit
        & git -C $repoRoot cat-file -e "$startCommit^{commit}" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $commitsVerified++
            $windowCommits = [int]((& git -C $repoRoot rev-list --count "$startCommit..$endCommit").Trim())
            $observedChanges = [int]$ledger.coverageWindow.coordinatorChangesObserved
            if ($observedChanges -gt 0) {
                $commitsPerChange = [math]::Max(1, [math]::Floor($windowCommits / $observedChanges))
                $maxStaleAfter = $commitsPerChange * 2
                Assert-Ledger ($staleAfter -le $maxStaleAfter) `
                    "The coverage window allows the clock to fall $staleAfter commit(s) behind HEAD, but $windowCommits commit(s) across $observedChanges coordinator change(s) put a change at about $commitsPerChange commit(s), so the bound may not exceed $maxStaleAfter."
                Assert-Ledger ($staleAfter -ge $commitsPerChange) `
                    "The coverage window's staleness bound of $staleAfter commit(s) is under one coordinator change (about $commitsPerChange commits), so it would demand re-evaluation mid-change."
            }
        }

        Assert-Ledger ($behind -le $staleAfter) `
            "The coverage window ends $behind commit(s) behind HEAD, past its declared bound of $staleAfter; re-evaluate the ledger before merging further coordinator changes."
    }
}

$report = [ordered]@{
    check = 'reviewer-escape-ledger'
    incidents = $incidents.Count
    nearMisses = @($nearMisses).Count
    runtimeExposure = $runtimeExposure
    categoryAnchored = $categoryAnchored
    remediated = @($incidents | Where-Object { $_.status -eq 'remediated' }).Count
    openDebt = @($incidents | Where-Object { $_.status -eq 'openDebt' }).Count
    typeBinding = @($incidents | Where-Object { $_.category -eq 'typeBinding' }).Count
    reachedShadowOrLive = @($incidents | Where-Object { $_.reachedShadowOrLive }).Count
    inWindow = $measured.InWindowIds.Count
    qualifyingCount = $measured.QualifyingCount
    triggered = $measured.Triggered
    commitsVerified = $commitsVerified
    checks = $script:Checks
    failed = $script:Failures.Count
}

Write-Output ($report | ConvertTo-Json -Depth 4 -Compress)

if ($script:Failures.Count -gt 0) {
    $detail = ($script:Failures | ForEach-Object { " - $_" }) -join [Environment]::NewLine
    throw "Escape ledger validation failed $($script:Failures.Count) check(s):$([Environment]::NewLine)$detail"
}

Write-Host "PASS: escape ledger ($($incidents.Count) incidents, $($script:Checks) checks, trigger not fired)."
