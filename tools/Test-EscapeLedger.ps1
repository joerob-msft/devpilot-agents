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
$ledgerPath = Join-Path $repoRoot 'docs/escape-ledger.v2.json'
$schemaPath = Join-Path $repoRoot 'src/Agents/reviewer/schemas/reviewer.escape-ledger.v2.json'
$docPath = Join-Path $repoRoot 'docs/escape-ledger.md'

$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Checks = 0
$script:ValidatorCalls = @{}

function Register-ValidatorCall {
    <#
        .SYNOPSIS
        Records that a shared validator was entered.

        .DESCRIPTION
        Extracting each rule into one validator that production and its control both call made
        the rule bodies falsifiable, but it moved the protected surface from the predicate to
        the function body: the controls call the validator directly, so they are blind to
        whether the production loop calls it at all. Replacing a production Assert-Ledger with
        an unconditional success left every check green and did not even move the check count.
        Counting entries makes the call itself observable - a deleted production call drops the
        count below what the control invocations alone can supply, and no control can make that
        good.
    #>
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:ValidatorCalls.ContainsKey($Name)) { $script:ValidatorCalls[$Name] = 0 }
    $script:ValidatorCalls[$Name]++
}

function Assert-ValidatorInvoked {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Expected,
        [Parameter(Mandatory)][string]$Rule
    )
    $actual = 0
    if ($script:ValidatorCalls.ContainsKey($Name)) { $actual = [int]$script:ValidatorCalls[$Name] }
    Assert-Ledger ($actual -eq $Expected) `
        "The $Rule validator was entered $actual time(s), not the expected $Expected. Its controls call it directly, so a count below the expected total means the production path stopped calling it and the rule is no longer enforced on the real ledger; a count above means a call was added without recording it here."
}

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

    $budgetFindings = @()
    $countedRecordKinds = @($threshold.countedRecordKinds)
    if ($countedRecordKinds -contains 'incident') {
        $budgetFindings += @($Ledger.incidents)
    }
    if ($countedRecordKinds -contains 'integrationIncident') {
        $budgetFindings += @($Ledger.integrationIncidents)
    }
    foreach ($incident in $budgetFindings) {
        $detectedOn = [datetime]::ParseExact(
            [string]$incident.detectedOn, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $withinOrdinal = ([int]$incident.coordinatorChangeOrdinal -ge $oldestOrdinalInWindow)
        $withinDays = ($detectedOn -ge $earliestDateInWindow)
        $withinWindow = if ($window.combinator -eq 'both') { $withinOrdinal -and $withinDays }
        else { $withinOrdinal -or $withinDays }
        if (-not $withinWindow) { continue }
        $inWindow.Add([string]$incident.id)

        if ($incident.PSObject.Properties.Name -contains 'budgetEligible' -and -not [bool]$incident.budgetEligible) { continue }
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

function Test-IntegrationBudgetEligibilityConsistent {
    param(
        [Parameter(Mandatory)][object]$Incident,
        [Parameter(Mandatory)][string]$CountedCategory
    )
    Register-ValidatorCall -Name 'integrationBudgetEligibility'
    return ([bool]$Incident.budgetEligible -eq ([string]$Incident.category -eq $CountedCategory))
}

function Test-IdSetsEqual {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Left,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Right
    )
    Register-ValidatorCall -Name 'idSetEquality'
    return ((@($Left | Sort-Object) -join ',') -eq (@($Right | Sort-Object) -join ','))
}

if (-not (Test-Path -LiteralPath $ledgerPath)) { throw "Escape ledger not found at $ledgerPath." }
if (-not (Test-Path -LiteralPath $schemaPath)) { throw "Escape ledger schema not found at $schemaPath." }
if (-not (Test-Path -LiteralPath $docPath)) { throw "Escape ledger narrative not found at $docPath." }

$ledgerJson = Get-Content -LiteralPath $ledgerPath -Raw
$ledger = Get-LedgerObject -Json $ledgerJson

# --- 1. Schema ---------------------------------------------------------------------------

Assert-Ledger ([bool](Test-Json -Json $ledgerJson -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) `
    'The escape ledger does not satisfy its versioned schema.'

Assert-Ledger ($ledger.schemaVersion -eq 2) 'The escape ledger declares an unexpected schema version.'
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
$integrationIncidents = @($ledger.integrationIncidents)
Assert-Ledger ($incidents.Count -ge 1) 'The escape ledger records no incidents.'
Assert-Ledger ($integrationIncidents.Count -ge 1) 'The escape ledger records no Gate 5 integration incidents.'

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

$integrationIndex = 0
foreach ($integrationIncident in $integrationIncidents) {
    $integrationIndex++
    $expectedId = 'INT-{0:D4}' -f $integrationIndex
    Assert-Ledger ($seenIds.Add([string]$integrationIncident.id)) "The escape ledger reuses incident identifier '$($integrationIncident.id)'."
    Assert-Ledger ([string]$integrationIncident.id -eq $expectedId) `
        "Integration incident $($integrationIncident.id) is out of sequence; expected $expectedId at position $integrationIndex."
    Assert-Ledger ($declaredCategories -contains $integrationIncident.category) `
        "Integration incident $($integrationIncident.id) uses category '$($integrationIncident.category)', which the vocabulary does not define."
    Assert-Ledger ([string]$integrationIncident.executionStage -in @('shadow', 'live') -and [bool]$integrationIncident.reachedShadowOrLive) `
        "Integration incident $($integrationIncident.id) does not record a shadow/live exposure consistently."
    Assert-Ledger (Test-IntegrationBudgetEligibilityConsistent -Incident $integrationIncident -CountedCategory ([string]$ledger.budget.threshold.category)) `
        "Integration incident $($integrationIncident.id) records budgetEligible=$($integrationIncident.budgetEligible), which disagrees with its category '$($integrationIncident.category)'."
    Assert-Ledger ([string]$integrationIncident.evidence.sha256 -match '^[0-9a-f]{64}$') `
        "Integration incident $($integrationIncident.id) does not carry a public-safe evidence digest."
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
$triggerRecordKinds = @($ledger.budget.threshold.countedRecordKinds)
Assert-Ledger ($triggerRecordKinds.Count -eq 2 -and $triggerRecordKinds -contains 'incident' -and $triggerRecordKinds -contains 'integrationIncident') `
    'The registered trigger no longer counts both historical and Gate 5 integration incidents.'
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
    Register-ValidatorCall -Name 'coverageClock'
    $observed = 0
    $evaluatedOn = ''
    foreach ($incident in @(@($Ledger.incidents) + @($Ledger.integrationIncidents))) {
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
foreach ($incident in @($incidents) + @($integrationIncidents)) {
    Assert-Ledger ([int]$incident.coordinatorChangeOrdinal -le [int]$ledger.coverageWindow.coordinatorChangesObserved) `
        "Incident $($incident.id) claims coordinator change ordinal $($incident.coordinatorChangeOrdinal), beyond the $($ledger.coverageWindow.coordinatorChangesObserved) observed."
    Assert-Ledger ([string]$incident.detectedOn -le [string]$ledger.coverageWindow.evaluatedOn) `
        "Incident $($incident.id) was detected on $($incident.detectedOn), after the ledger evaluation date."
}

# An incident aged out of both windows must stop counting, or the budget is a running total
# rather than a rolling one.
$agedOut = Get-LedgerObject -Json $ledgerJson
foreach ($incident in @(@($agedOut.incidents) + @($agedOut.integrationIncidents))) {
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
foreach ($integration in @($oneEscape.integrationIncidents)) { $integration.budgetEligible = $false }
$oneEscape.incidents[0].executionStage = 'shadow'
$oneEscape.incidents[0].reachedShadowOrLive = $true
$oneMeasured = Measure-LedgerBudget -Ledger $oneEscape
Assert-Ledger ($oneMeasured.QualifyingCount -eq 1 -and -not $oneMeasured.Triggered) `
    'A single type-binding escape reaching shadow was miscounted or fired the trigger early.'

# Two qualifying escapes must fire it.
$twoEscapes = Get-LedgerObject -Json $ledgerJson
foreach ($integration in @($twoEscapes.integrationIncidents)) { $integration.budgetEligible = $false }
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
foreach ($integration in @($otherCategory.integrationIncidents)) { $integration.budgetEligible = $false }
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
foreach ($integration in @($shadowOnly.integrationIncidents)) { $integration.budgetEligible = $false }
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

$driftedEligibility = Get-LedgerObject -Json $ledgerJson
$driftedEligibility.integrationIncidents[0].budgetEligible = $false
Assert-Ledger (-not (Test-IntegrationBudgetEligibilityConsistent -Incident $driftedEligibility.integrationIncidents[0] -CountedCategory ([string]$driftedEligibility.budget.threshold.category))) `
    'A qualifying integration incident could be removed from the budget by changing budgetEligible alone.'

# --- 6. Gate observations ----------------------------------------------------------------

$gateFive = @($ledger.gateObservations | Where-Object { $_.gate -eq 'Gate 5' })
Assert-Ledger ($gateFive.Count -eq 1) 'The escape ledger does not record exactly one Gate 5 observation.'
if ($gateFive.Count -eq 1) {
    Assert-Ledger ([int]$gateFive[0].cohortSize -eq 2) 'The Gate 5 integration cohort is not the registered initial two-item cohort.'
    Assert-Ledger ([int]$gateFive[0].completedDecisions -eq 0) 'The Gate 5 cohort records a completed decision despite zero decision yield.'
    Assert-Ledger ([double]$gateFive[0].decisionYieldPercent -eq 0) 'The recorded Gate 5 decision yield is not zero per cent.'
    Assert-Ledger ([int]$gateFive[0].unauthorizedWrites -eq 0) 'The Gate 5 run records unauthorized writes.'
    Assert-Ledger ([int]$gateFive[0].externalWrites -eq 0) 'The recorded Gate 5 run performed external writes.'
    Assert-Ledger ($gateFive[0].noWriteInvariantHeld -eq $true) 'The recorded Gate 5 run did not hold the no-write invariant.'
    Assert-Ledger ([int]$gateFive[0].shadowRunsPerformed -ge 0) 'The Gate 5 observation records no shadow run count.'
    Assert-Ledger ([int]$gateFive[0].liveRunsPerformed -ge 0) 'The Gate 5 observation records no live run count.'
    $gateYield = if ([int]$gateFive[0].cohortSize -eq 0) { 0 } else {
        100 * [double]$gateFive[0].completedDecisions / [int]$gateFive[0].cohortSize
    }
    Assert-Ledger ([double]$gateFive[0].decisionYieldPercent -eq $gateYield) `
        'The Gate 5 decision yield does not equal completed decisions divided by cohort size.'
}

foreach ($observation in @($ledger.gateObservations)) {
    $writesConsistent = (([int]$observation.externalWrites -eq 0) -eq [bool]$observation.noWriteInvariantHeld)
    Assert-Ledger $writesConsistent `
        "Gate observation '$($observation.gate)' records $($observation.externalWrites) external write(s) but claims noWriteInvariantHeld=$($observation.noWriteInvariantHeld)."
    Assert-Ledger ([int]$observation.liveRunsPerformed -eq 0 -or [int]$observation.externalWrites -gt 0 -or -not $observation.noWriteInvariantHeld) `
        "Gate observation '$($observation.gate)' claims live runs while also claiming zero external writes."
}

$snapshot = $ledger.integrationSnapshot
Assert-Ledger ([string]$snapshot.status -eq 'authoritative') 'The Gate 5 integration snapshot is not authoritative.'
Assert-Ledger ([int]$snapshot.coordinatorChangeOrdinal -eq [int]$ledger.coverageWindow.coordinatorChangesObserved) `
    'The authoritative integration snapshot ordinal disagrees with the published coverage clock.'
if ($gateFive.Count -eq 1) {
    Assert-Ledger ([int]$snapshot.cohortSize -eq [int]$gateFive[0].cohortSize) 'The integration snapshot and Gate 5 observation disagree on cohort size.'
    Assert-Ledger ([int]$snapshot.completedDecisions -eq [int]$gateFive[0].completedDecisions) 'The integration snapshot and Gate 5 observation disagree on completed decisions.'
}
$snapshotYield = if ([int]$snapshot.cohortSize -eq 0) { 0 } else {
    100 * [double]$snapshot.completedDecisions / [int]$snapshot.cohortSize
}
Assert-Ledger ([double]$snapshot.decisionYieldPercent -eq $snapshotYield) `
    'The integration snapshot decision yield does not equal completed decisions divided by cohort size.'
Assert-Ledger ([double]$snapshot.decisionYieldPercent -eq 0 -and [int]$snapshot.completedDecisions -eq 0) `
    'The authoritative integration snapshot does not reproduce the initial cohort zero-percent decision yield.'
Assert-Ledger ([int]$snapshot.unauthorizedWrites -eq 0) 'The authoritative integration snapshot records unauthorized writes.'
$snapshotQualifyingIds = @($snapshot.qualifyingIncidentIds)
Assert-Ledger (Test-IdSetsEqual -Left $snapshotQualifyingIds -Right $measured.QualifyingIds) `
    'The authoritative integration snapshot qualifying incidents disagree with the recomputed budget.'
Assert-Ledger ([bool]$snapshot.triggered -eq $measured.Triggered) `
    'The authoritative integration snapshot trigger verdict disagrees with the recomputed budget.'
$incidentEvidenceDigests = @($integrationIncidents | ForEach-Object { [string]$_.evidence.sha256 } | Sort-Object -Unique)
Assert-Ledger ((@($snapshot.evidenceDigests | Sort-Object) -join ',') -eq ($incidentEvidenceDigests -join ',')) `
    'The authoritative integration snapshot evidence digest set does not equal the integration-incident evidence set.'

$driftedSnapshotIds = Get-LedgerObject -Json $ledgerJson
$driftedSnapshotIds.integrationSnapshot.qualifyingIncidentIds[0] = 'INT-9999'
Assert-Ledger (-not (Test-IdSetsEqual -Left @($driftedSnapshotIds.integrationSnapshot.qualifyingIncidentIds) -Right $measured.QualifyingIds)) `
    'A drifted authoritative snapshot qualifying-incident set was not distinguishable from the recomputed budget.'

# Only live execution contradicts the no-write invariant. Shadow execution runs the code
# and discards the output, so it writes nothing externally by construction: treating a
# shadow escape as inconsistent with the invariant would make the shadow arm of the
# registered trigger unusable, which is the opposite of what it is for.
$reachedLive = @(@($incidents) + @($integrationIncidents) | Where-Object { $_.executionStage -eq 'live' })
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

Assert-Ledger ($ledger.decision.status -eq 'taken') `
    "The typed control-plane decision is recorded as '$($ledger.decision.status)' even though the authoritative Gate 5 snapshot fired the registered trigger."

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

# --- 7a. Adoption proof coupling -----------------------------------------------------------
# Two prerequisites can be flipped to in force by editing a boolean. That is exactly the
# failure this ledger exists to prevent, so each one is coupled to a machine-readable
# artifact that only a passing run can produce. The rule reads the artifact rather than the
# claim, and is proven below to refuse a forged one.

$producerContractSchemaPath = Join-Path $repoRoot 'src/Agents/reviewer/schemas/reviewer.stage-producer-contracts.v1.json'
$producerAdoptionSuitePath = Join-Path $repoRoot 'tools/Test-ReviewerStageProducerContract.ps1'
$producerTablePath = Join-Path $repoRoot 'src/Agents/reviewer/StageProducers.ps1'
$shadowSwitchPath = Join-Path $repoRoot 'src/Agents/reviewer/StageShadow.ps1'
$shadowSuitePath = Join-Path $repoRoot 'tools/Test-ReviewerStageShadow.ps1'
$shadowRunToolPath = Join-Path $repoRoot 'tools/Invoke-ReviewerStageShadowRun.ps1'
$cardinalityMatrixPath = Join-Path $repoRoot 'tools/testdata/reviewer-collection-cardinality-matrix.v1.json'
$ciWorkflowPath = Join-Path $repoRoot '.github/workflows/ci.yml'
$expectedStageBoundaries = 12

function Test-CardinalityAdoptionProven {
    <#
        Returns $true when the recorded coverage matrix itself shows the corpus reaching
        every inventoried row through a shipping producer contract. A matrix with an
        unbound row, an uncovered producer cell, or fewer than the twelve declared stage
        boundaries does not prove the claim, whatever the ledger says.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Matrix)

    if ($null -eq $Matrix) { return $false }
    $names = @($Matrix.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names -notcontains 'summary') { return $false }
    $summaryNames = @($Matrix.summary.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($required in @('producerPathCovered', 'producerPathCensusMatched', 'producerPathCensusReshaped',
            'producerPathBoundaryRefusal', 'producerPathBoundaryOnly', 'producerPathGaps',
            'producerBoundariesInForce', 'cellsPerDimension', 'fields', 'variants')) {
        if ($summaryNames -notcontains $required) { return $false }
    }
    if ([int]$Matrix.summary.producerPathGaps -ne 0) { return $false }
    if ([int]$Matrix.summary.producerPathCovered -le 0) { return $false }
    if ([int]$Matrix.summary.producerBoundariesInForce -ne $expectedStageBoundaries) { return $false }

    # The summary is not taken on trust. Recount every cell from the per-row statuses and
    # require the totals to agree, so a matrix whose headline numbers were edited without
    # the run that produced them cannot satisfy the claim.
    $fields = @($Matrix.fields)
    if ($fields.Count -ne [int]$Matrix.summary.fields) { return $false }
    $variantNames = @($Matrix.variants)
    if ($variantNames.Count -ne [int]$Matrix.summary.variants) { return $false }
    if (($fields.Count * $variantNames.Count) -ne [int]$Matrix.summary.cellsPerDimension) { return $false }
    $tally = @{ producerCensusMatched = 0; producerCensusReshaped = 0; boundaryRefusal = 0; boundaryOnly = 0 }
    foreach ($field in $fields) {
        $fieldNames = @($field.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($required in @('producerContract', 'producerValidator', 'producerBuilder',
                'producerFunction', 'producerPath')) {
            if ($fieldNames -notcontains $required) { return $false }
        }
        if ([string]$field.producerContract -eq '' -or [string]$field.producerValidator -eq '' -or
            [string]$field.producerBuilder -eq '' -or [string]$field.producerFunction -eq '') {
            return $false
        }
        foreach ($variant in $variantNames) {
            $status = [string]$field.producerPath.$variant
            if (-not $tally.ContainsKey($status)) { return $false }
            $tally[$status]++
        }
    }
    if ($tally['producerCensusMatched'] -ne [int]$Matrix.summary.producerPathCensusMatched) { return $false }
    if ($tally['producerCensusReshaped'] -ne [int]$Matrix.summary.producerPathCensusReshaped) { return $false }
    if ($tally['boundaryRefusal'] -ne [int]$Matrix.summary.producerPathBoundaryRefusal) { return $false }
    if ($tally['boundaryOnly'] -ne [int]$Matrix.summary.producerPathBoundaryOnly) { return $false }
    if (($tally['producerCensusMatched'] + $tally['producerCensusReshaped']) -ne
        [int]$Matrix.summary.producerPathCovered) {
        return $false
    }
    return $true
}

function Get-FileContractAdoptionViolation {
    <#
        Returns the reasons the file-contract prerequisite's recorded status is not
        supported by what is on disk, or nothing when it is.

        This prerequisite has two halves adopted on two different paths, so it is
        scored on two fields and both are coupled to the tree. The in-memory half
        needs the production table and the suite that proves the producers call and
        consume it. The on-disk half is reached only through an opt-in switch, so it
        needs the switch that publishes an artifact and reads it back, the suite that
        proves the reread verdict is consumed rather than logged, the runner that
        drives all twelve stages, a CI step that runs that suite, and a note that
        states the opt-in scope.

        The load-bearing coupling is the last one: whether a shipping file
        statically calls the switch is a fact about src/, not an opinion, so the
        ledger's answer is checked against it in BOTH directions - but the two
        directions do NOT carry the same weight, and pretending they did would
        repeat the error this coupling exists to prevent. With no call site
        anywhere, an in-force claim is refused: that is sound, because no
        ordinary path can reach a command nothing names. With a call site
        present, the record is required to be re-derived rather than concluded
        in force, because a call may sit on a branch production never takes.
        A boolean edit alone satisfies none of this. What the detector can and
        cannot establish is documented on Test-ShadowSwitchStaticCallSitePresent:
        it is static call-site detection, not a reachability proof.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Prerequisite,
        [string]$ProductionRoot = (Join-Path $repoRoot 'src'))

    $violations = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Prerequisite) {
        [void]$violations.Add('The file contract prerequisite record is missing.')
        return $violations.ToArray()
    }
    if (-not (Test-Path -LiteralPath $producerTablePath)) {
        [void]$violations.Add('The file contract is declared adopted without src/Agents/reviewer/StageProducers.ps1, which is what registers the stage kinds in production code.')
    }
    if (-not (Test-Path -LiteralPath $producerAdoptionSuitePath)) {
        [void]$violations.Add('The file contract is declared adopted without tools/Test-ReviewerStageProducerContract.ps1, which is what proves the producers call and consume it.')
    }
    if (-not (Test-Path -LiteralPath $producerContractSchemaPath)) {
        [void]$violations.Add('The file contract is declared adopted without the pinned stage producer contract schema.')
    }
    else {
        $producerSchema = Get-Content -LiteralPath $producerContractSchemaPath -Raw | ConvertFrom-Json -Depth 12
        if (@($producerSchema.boundaries).Count -ne $expectedStageBoundaries) {
            [void]$violations.Add("The pinned stage producer contract schema declares $(@($producerSchema.boundaries).Count) boundaries, not $expectedStageBoundaries.")
        }
    }
    if (-not (Test-Path -LiteralPath $shadowSwitchPath)) {
        [void]$violations.Add('The file contract is declared adopted without src/Agents/reviewer/StageShadow.ps1, which is what publishes a stage artifact and reads it back.')
    }
    if (-not (Test-Path -LiteralPath $shadowSuitePath)) {
        [void]$violations.Add('The file contract is declared adopted without tools/Test-ReviewerStageShadow.ps1, which is what proves the on-disk half is consumed rather than logged.')
    }
    if (-not (Test-Path -LiteralPath $shadowRunToolPath)) {
        [void]$violations.Add('The file contract is declared adopted without tools/Invoke-ReviewerStageShadowRun.ps1, which is what produces all twelve stage artifacts in one run.')
    }
    $ciText = if (Test-Path -LiteralPath $ciWorkflowPath) { Get-Content -LiteralPath $ciWorkflowPath -Raw } else { '' }
    if ($ciText -notmatch 'Test-ReviewerStageProducerContract\.ps1') {
        [void]$violations.Add('The file contract is declared adopted but CI never runs the adoption suite that keeps it in force.')
    }
    if ($ciText -notmatch 'Test-ReviewerStageShadow\.ps1') {
        [void]$violations.Add('The file contract is declared adopted but CI never runs the shadow adoption suite that keeps the on-disk half honest.')
    }

    $scope = $Prerequisite.PSObject.Properties['adoptionScope']
    if ($null -eq $scope -or $null -eq $scope.Value) {
        [void]$violations.Add('The file contract prerequisite records no adoptionScope, so there is nothing saying which of its two halves production actually goes through.')
        return $violations.ToArray()
    }
    $scopeValue = $scope.Value
    if ([string]$scopeValue.note -notmatch 'opt-in|Enable-ReviewerStageShadowContract') {
        [void]$violations.Add('The file contract adoption scope does not record that the on-disk half is reached only through an opt-in switch, which is the scope of the claim.')
    }
    # Deliberately NOT named "enabled". A static call site is neither necessary
    # nor sufficient for the switch to actually run: a call on a dead branch is
    # present but never reached, and a dynamic invocation is reached but absent.
    # What follows uses it only in the directions where it is sound.
    $callSitePresent = Test-ShadowSwitchStaticCallSitePresent -Root $ProductionRoot
    if ([bool]$scopeValue.staticCallSiteInProduction -ne $callSitePresent) {
        $observed = if ($callSitePresent) { 'does' } else { 'does not' }
        [void]$violations.Add("The file contract adoption scope says staticCallSiteInProduction is $([bool]$scopeValue.staticCallSiteInProduction), but src/ $observed contain a static call to Enable-ReviewerStageShadowContract.")
    }
    if (-not $callSitePresent) {
        # Sound as a necessary condition, with one stated blind spot. No static
        # call site means no ordinary path reaches the switch, so an in-force
        # claim cannot stand - unless production enables it dynamically, which
        # this detector cannot see and which nothing in this repository does.
        if ([bool]$Prerequisite.inForce) {
            [void]$violations.Add('The file contract is declared in force, but no shipping file under src/ even names Enable-ReviewerStageShadowContract as a command, and this ledger defines in force as production code actually going through it today.')
        }
        if ([string]$scopeValue.scope -cne 'opt-in-offline-shadow') {
            [void]$violations.Add("The file contract adoption scope claims '$([string]$scopeValue.scope)' while no shipping file under src/ calls the switch.")
        }
    }
    else {
        # The mirror clause, and it stops short of forcing inForce true on
        # purpose: a call site that exists may still sit on a branch production
        # never takes, so this cannot conclude the switch runs. What it CAN
        # conclude is that "opt-in offline, nothing calls it" has expired as a
        # description and the record has to be re-derived from the new call site
        # rather than left standing.
        if ([string]$scopeValue.scope -ceq 'opt-in-offline-shadow') {
            [void]$violations.Add("A shipping file under src/ now contains a static call to Enable-ReviewerStageShadowContract, so the adoption scope cannot still read 'opt-in-offline-shadow' unexamined; re-derive the scope from that call site.")
        }
        if ([string]$scopeValue.note -match 'no file under src|nothing under src|no shipping file') {
            [void]$violations.Add('A shipping file under src/ now contains a static call to Enable-ReviewerStageShadowContract, but the adoption scope note still asserts that nothing calls it, so the note describes a tree that no longer exists.')
        }
    }
    return $violations.ToArray()
}

function Test-ShadowSwitchStaticCallSitePresent {
    <#
        Does any shipping file statically reference
        Enable-ReviewerStageShadowContract? The switch is inert until that
        function is called, so a tree that never names it certainly does not go
        through the on-disk half - and that, not "the switch is enabled", is the
        question this answers. The name says call site rather than enabled on
        purpose: presence is a prerequisite for enablement, not evidence of it.

        This is static reference detection, not a reachability proof, and the
        difference matters in both directions. It parses each file and looks for
        the name in TWO forms, because either one can enable the switch:

          1. A CommandAst whose command name is the function - an ordinary call.
          2. A string constant, bare or expandable, whose text contains the name
             - which is what & $name, Invoke-Expression, Get-Command and a
             runtime-built script block all need in order to reach it.

        Together those close the dynamic-invocation hole a CommandAst-only scan
        leaves open. A comment or a block comment is still not a reference,
        because comments are tokens rather than AST nodes. What remains
        undetectable is a name assembled from fragments at runtime, and a name
        that only ever exists outside the PowerShell files this scan parses - in
        JSON, in a data file, in an environment variable - since the scan reads
        the source it walks and nothing else. Nothing in this repository does
        either. In the other direction a reference it DOES
        see may sit on a branch that never executes, which is why presence never
        concludes "in force".

        Every PowerShell file type under the root is parsed, not just .ps1:
        src/ ships a .psm1 module that the reviewer entry point imports, and a
        call added there would otherwise be a silent false negative in exactly
        the direction that matters.

        -Root exists so the detector can be proven against a tree that DOES call
        it. A detector that has only ever been run where the answer is no has not
        been shown to be able to say yes.
    #>
    param([string]$Root = (Join-Path $repoRoot 'src'))

    if (-not (Test-Path -LiteralPath $shadowSwitchPath)) { return $false }
    if (-not (Test-Path -LiteralPath $Root)) { return $false }
    $powerShellExtensions = [string[]]@('.ps1', '.psm1', '.psd1')
    foreach ($file in (Get-ChildItem -LiteralPath $Root -Recurse -File)) {
        if ($powerShellExtensions -notcontains [string]$file.Extension.ToLowerInvariant()) { continue }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName, [ref]$tokens, [ref]$errors)
        if ($null -eq $ast) { continue }
        $references = $ast.FindAll({
                param($node)
                if ($node -is [System.Management.Automation.Language.CommandAst]) {
                    return ([string]$node.GetCommandName() -eq 'Enable-ReviewerStageShadowContract')
                }
                # A dynamic invocation cannot name the function without carrying
                # the name as text somewhere, so string constants count too.
                if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    return ([string]$node.Value).Contains('Enable-ReviewerStageShadowContract')
                }
                if ($node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                    return ([string]$node.Value).Contains('Enable-ReviewerStageShadowContract')
                }
                return $false
            }, $true)
        if (@($references).Count -gt 0) { return $true }
    }
    return $false
}

$cardinalityMatrix = $null
if (Test-Path -LiteralPath $cardinalityMatrixPath) {
    $cardinalityMatrix = Get-Content -LiteralPath $cardinalityMatrixPath -Raw | ConvertFrom-Json -Depth 20
}

foreach ($prerequisite in @($ledger.decision.prerequisites)) {
    if ([string]$prerequisite.id -eq 'cardinality-corpus' -and [bool]$prerequisite.inForce) {
        Assert-Ledger (Test-CardinalityAdoptionProven -Matrix $cardinalityMatrix) `
            'The cardinality corpus is declared in force, but the recorded coverage matrix does not show every inventoried row bound to a shipping producer contract with no producer-path gap across all twelve stage boundaries.'
    }
    if ([string]$prerequisite.id -eq 'file-contract') {
        foreach ($violation in (Get-FileContractAdoptionViolation -Prerequisite $prerequisite)) {
            Assert-Ledger $false $violation
        }
    }
}

# A rule that cannot fail is not a rule. Forge a matrix that reports the gaps the real one
# does not, and require the coupling to refuse it.
$forgedMatrix = Get-Content -LiteralPath $cardinalityMatrixPath -Raw | ConvertFrom-Json -Depth 20
$forgedMatrix.summary.producerPathGaps = 1
Assert-Ledger (-not (Test-CardinalityAdoptionProven -Matrix $forgedMatrix)) `
    'The adoption coupling accepted a coverage matrix that still reports producer-path gaps.'
$unboundMatrix = Get-Content -LiteralPath $cardinalityMatrixPath -Raw | ConvertFrom-Json -Depth 20
$unboundMatrix.fields[0].producerContract = ''
Assert-Ledger (-not (Test-CardinalityAdoptionProven -Matrix $unboundMatrix)) `
    'The adoption coupling accepted a coverage matrix with a row bound to no producer contract.'
$shrunkMatrix = Get-Content -LiteralPath $cardinalityMatrixPath -Raw | ConvertFrom-Json -Depth 20
$shrunkMatrix.summary.producerBoundariesInForce = 11
Assert-Ledger (-not (Test-CardinalityAdoptionProven -Matrix $shrunkMatrix)) `
    'The adoption coupling accepted a coverage matrix that drove fewer than the twelve declared stage boundaries.'
# The headline totals are the easiest thing to inflate, so a matrix whose summary no longer
# agrees with its own per-cell statuses has to be refused.
$inflatedMatrix = Get-Content -LiteralPath $cardinalityMatrixPath -Raw | ConvertFrom-Json -Depth 20
$inflatedMatrix.summary.producerPathCensusMatched = [int]$inflatedMatrix.summary.producerPathCensusMatched + 1
Assert-Ledger (-not (Test-CardinalityAdoptionProven -Matrix $inflatedMatrix)) `
    'The adoption coupling accepted a coverage matrix whose census-matched total exceeds the cells it actually records.'
$relabelledMatrix = Get-Content -LiteralPath $cardinalityMatrixPath -Raw | ConvertFrom-Json -Depth 20
$relabelledMatrix.fields[0].producerPath.nullVsMissing = 'producerCensusMatched'
Assert-Ledger (-not (Test-CardinalityAdoptionProven -Matrix $relabelledMatrix)) `
    'The adoption coupling accepted a coverage matrix that relabelled a boundary refusal as a producer-published census.'
$unbuiltMatrix = Get-Content -LiteralPath $cardinalityMatrixPath -Raw | ConvertFrom-Json -Depth 20
$unbuiltMatrix.fields[0].producerBuilder = ''
Assert-Ledger (-not (Test-CardinalityAdoptionProven -Matrix $unbuiltMatrix)) `
    'The adoption coupling accepted a coverage matrix with a row bound to no producer builder.'
Assert-Ledger (Test-CardinalityAdoptionProven -Matrix $cardinalityMatrix) `
    'The adoption coupling rejects the coverage matrix this repository actually records, so it can never be satisfied.'

# The same standard for the file contract's on-disk half. It is recorded as adopted behind
# an opt-in switch and NOT in force, and every part of that sentence has to be refusable:
# a scope note that drops the opt-in, an in-force claim while nothing enables the switch,
# and a scope record that disagrees with what src/ actually calls.
$fileContractPrerequisite = @($ledger.decision.prerequisites | Where-Object { $_.id -eq 'file-contract' })
Assert-Ledger ($fileContractPrerequisite.Count -eq 1) `
    'The decision record does not declare the file-contract prerequisite exactly once.'
if ($fileContractPrerequisite.Count -eq 1) {
    $scopelessNote = Get-LedgerObject -Json $ledgerJson
    $scopelessClaim = @($scopelessNote.decision.prerequisites | Where-Object { $_.id -eq 'file-contract' })[0]
    $scopelessClaim.adoptionScope.note = 'Adopted.'
    Assert-Ledger (@(Get-FileContractAdoptionViolation -Prerequisite $scopelessClaim).Count -gt 0) `
        'The file contract coupling accepted an adoption record that drops the opt-in scope the on-disk half is actually reached through.'

    $overclaimed = Get-LedgerObject -Json $ledgerJson
    $overclaimedClaim = @($overclaimed.decision.prerequisites | Where-Object { $_.id -eq 'file-contract' })[0]
    $overclaimedClaim.inForce = $true
    Assert-Ledger (@(Get-FileContractAdoptionViolation -Prerequisite $overclaimedClaim).Count -gt 0) `
        'The file contract coupling accepted an in-force claim while nothing under src/ enables the on-disk half.'

    $mislabelled = Get-LedgerObject -Json $ledgerJson
    $mislabelledClaim = @($mislabelled.decision.prerequisites | Where-Object { $_.id -eq 'file-contract' })[0]
    $mislabelledClaim.adoptionScope.staticCallSiteInProduction = $true
    Assert-Ledger (@(Get-FileContractAdoptionViolation -Prerequisite $mislabelledClaim).Count -gt 0) `
        'The file contract coupling accepted a claim that production enables the switch when no shipping file calls it.'

    $scopeless = Get-LedgerObject -Json $ledgerJson
    $scopelessRecord = @($scopeless.decision.prerequisites | Where-Object { $_.id -eq 'file-contract' })[0]
    $scopelessRecord.PSObject.Properties.Remove('adoptionScope')
    Assert-Ledger (@(Get-FileContractAdoptionViolation -Prerequisite $scopelessRecord).Count -gt 0) `
        'The file contract coupling accepted a prerequisite that records no adoption scope at all.'

    $absentPrerequisite = $null
    Assert-Ledger (@(Get-FileContractAdoptionViolation -Prerequisite $absentPrerequisite).Count -gt 0) `
        'The file contract coupling accepted a missing prerequisite record as proof of adoption.'
    Assert-Ledger (@(Get-FileContractAdoptionViolation -Prerequisite $fileContractPrerequisite[0]).Count -eq 0) `
        'The file contract coupling rejects the adoption this repository actually records, so it can never be satisfied.'
    Assert-Ledger (-not (Test-ShadowSwitchStaticCallSitePresent)) `
        'A file under src/ enables the stage shadow switch, so the ledger''s not-in-force record for the on-disk half is stale.'

    # The detector has to be able to answer YES, or "nothing enables it" is just
    # the only answer it knows how to give. Prove it against a tree that does.
    $detectorProof = Join-Path ([IO.Path]::GetTempPath()) ("ledger-detector-" + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $detectorProof -Force
    try {
        $callerPath = Join-Path $detectorProof 'Caller.ps1'
        [IO.File]::WriteAllText($callerPath,
            "`$state = Enable-ReviewerStageShadowContract -Directory `$dir`n",
            [Text.UTF8Encoding]::new($false))
        Assert-Ledger (Test-ShadowSwitchStaticCallSitePresent -Root $detectorProof) `
            'The shadow-switch detector cannot see a call it is looking at, so its answer for src/ proves nothing.'

        # ...and it must not count a comment or the definition itself as a call.
        [IO.File]::WriteAllText($callerPath,
            "# Enable-ReviewerStageShadowContract is described here, not called.`nfunction Enable-ReviewerStageShadowContract {`n}`n",
            [Text.UTF8Encoding]::new($false))
        Assert-Ledger (-not (Test-ShadowSwitchStaticCallSitePresent -Root $detectorProof)) `
            'The shadow-switch detector counts a comment or the function definition as a production call.'

        # A block comment is still not a reference - comments are tokens, not AST
        # nodes - and this is the reason the detector parses instead of grepping.
        [IO.File]::WriteAllText($callerPath,
            "<#`nEnable-ReviewerStageShadowContract -Directory `$d`n#>`nWrite-Output 'nothing here'`n",
            [Text.UTF8Encoding]::new($false))
        Assert-Ledger (-not (Test-ShadowSwitchStaticCallSitePresent -Root $detectorProof)) `
            'The shadow-switch detector counts a block comment as a production reference.'

        # A STRING literal, on the other hand, must count, and deliberately so:
        # & $name, Invoke-Expression and Get-Command all need the name as text,
        # so ignoring strings is exactly the dynamic-invocation hole that would
        # let production enable the switch with the ledger none the wiser.
        [IO.File]::WriteAllText($callerPath,
            "`$name = 'Enable-ReviewerStageShadowContract'`n& `$name -Directory `$d`n",
            [Text.UTF8Encoding]::new($false))
        Assert-Ledger (Test-ShadowSwitchStaticCallSitePresent -Root $detectorProof) `
            'The shadow-switch detector misses a dynamic invocation through a string-held command name.'

        # A module file counts too. src/ ships one that the reviewer entry point
        # imports, so a .ps1-only scan would miss the switch being wired in there.
        Remove-Item -LiteralPath $callerPath -Force
        $modulePath = Join-Path $detectorProof 'Caller.psm1'
        [IO.File]::WriteAllText($modulePath,
            "function Invoke-Thing {`n    `$state = Enable-ReviewerStageShadowContract -Directory `$dir`n}`n",
            [Text.UTF8Encoding]::new($false))
        Assert-Ledger (Test-ShadowSwitchStaticCallSitePresent -Root $detectorProof) `
            'The shadow-switch detector ignores .psm1 module files, so a shipping module could enable the switch without moving the ledger.'
        Remove-Item -LiteralPath $modulePath -Force

        # The mirror direction of the ledger coupling: against a tree that DOES
        # call the switch, the record this repository ships today - not in force,
        # opt-in scope - has to be refused by name, not merely by the
        # staticCallSiteInProduction mismatch.
        [IO.File]::WriteAllText($callerPath,
            "`$state = Enable-ReviewerStageShadowContract -Directory `$dir`n",
            [Text.UTF8Encoding]::new($false))
        $wiredIn = Get-LedgerObject -Json $ledgerJson
        $wiredInClaim = @($wiredIn.decision.prerequisites | Where-Object { $_.id -eq 'file-contract' })[0]
        $wiredInClaim.adoptionScope.staticCallSiteInProduction = $true
        $wiredInViolations = @(Get-FileContractAdoptionViolation -Prerequisite $wiredInClaim -ProductionRoot $detectorProof)
        Assert-Ledger (@($wiredInViolations | Where-Object { $_ -match "cannot still read 'opt-in-offline-shadow'" }).Count -eq 1) `
            'A shipping call to the shadow switch leaves the opt-in adoption scope standing unexamined.'
        Assert-Ledger (@($wiredInViolations | Where-Object { $_ -match 'still asserts that nothing calls it' }).Count -eq 1) `
            'A shipping call to the shadow switch leaves an adoption note still asserting that nothing calls it.'
        # ...and it must NOT conclude the switch is in force from a call site
        # alone. A call on a branch production never takes is still a call.
        Assert-Ledger (@($wiredInViolations | Where-Object { $_ -match 'inForce' }).Count -eq 0) `
            'A static call site alone was treated as proof the on-disk half is in force, which is the equation this coupling exists to avoid.'
    }
    finally {
        Remove-Item -LiteralPath $detectorProof -Recurse -Force -ErrorAction SilentlyContinue
    }
}

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
    param(
        [Parameter(Mandatory)][object]$Prerequisite,
        [Parameter(Mandatory)][object]$Ledger
    )
    Register-ValidatorCall -Name 'clockAuthority'
    $names = @($Prerequisite.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names -notcontains 'clockAuthority') { return $false }
    if ([string]$Prerequisite.clockAuthority -eq 'authoredOrdinals') {
        return (-not [bool]$Prerequisite.inForce -and [string]$Ledger.budget.operationalStatus -eq 'historicalSnapshot')
    }
    if ([string]$Prerequisite.clockAuthority -ne 'gate5IntegrationSnapshot') { return $false }
    $snapshot = $Ledger.integrationSnapshot
    return (
        [bool]$Prerequisite.inForce -and
        [string]$Ledger.budget.operationalStatus -eq 'inForce' -and
        [string]$snapshot.status -eq 'authoritative' -and
        [string]$snapshot.asOfCommit -eq [string]$Ledger.budget.asOfCommit -and
        [string]$snapshot.asOfCommit -eq [string]$Ledger.coverageWindow.endCommit -and
        [bool]$snapshot.triggered -and
        @($snapshot.evidenceDigests).Count -gt 0
    )
}

if ($ledgerPrerequisite.Count -eq 1) {
    $ledgerPrereqNames = @($ledgerPrerequisite[0].PSObject.Properties | ForEach-Object { $_.Name })
    Assert-Ledger ($ledgerPrereqNames -contains 'clockAuthority') `
        "The escape-ledger prerequisite does not declare a clockAuthority, so a reader cannot tell whether the window clock is authoritative."
    if ($ledgerPrereqNames -contains 'clockAuthority') {
        $clockAuthority = [string]$ledgerPrerequisite[0].clockAuthority
        Assert-Ledger ($clockAuthority -in @('authoredOrdinals', 'gate5IntegrationSnapshot')) `
            "Unknown clockAuthority '$clockAuthority'."
        Assert-Ledger (Test-ClockAuthorityConsistent -Prerequisite $ledgerPrerequisite[0] -Ledger $ledger) `
            'The escape-ledger prerequisite, budget operational status, and authoritative Gate 5 integration snapshot disagree.'
        Assert-Ledger ([string]$ledgerPrerequisite[0].inForceNote -match 'Gate 5') `
            'The escape-ledger prerequisite note does not identify Gate 5 as the authority for the in-force snapshot.'
    }

    # The rule has to be able to fail on each combination it exists to forbid, and has to
    # accept the one it exists to permit. None of that is true by construction.
    $forcedClock = (Get-LedgerObject -Json $ledgerJson).decision.prerequisites | Where-Object { $_.id -eq 'escape-ledger' }
    $forcedClock.inForce = $true
    $forcedClock.clockAuthority = 'authoredOrdinals'
    $forcedLedger = Get-LedgerObject -Json $ledgerJson
    $forcedLedger.budget.operationalStatus = 'historicalSnapshot'
    Assert-Ledger (-not (Test-ClockAuthorityConsistent -Prerequisite $forcedClock -Ledger $forcedLedger)) `
        'An escape-ledger prerequisite declared in force on an authored clock was accepted.'
    $inventedClock = (Get-LedgerObject -Json $ledgerJson).decision.prerequisites | Where-Object { $_.id -eq 'escape-ledger' }
    $inventedClock.inForce = $true
    $inventedClock.clockAuthority = 'coordinatorChangeRegistry'
    Assert-Ledger (-not (Test-ClockAuthorityConsistent -Prerequisite $inventedClock -Ledger (Get-LedgerObject -Json $ledgerJson))) `
        'The clock-authority rule accepted an in-force budget backed by an authority this schema version does not define, so the clock can be switched on by naming a registry that does not exist.'
    $restingClock = (Get-LedgerObject -Json $ledgerJson).decision.prerequisites | Where-Object { $_.id -eq 'escape-ledger' }
    $restingClock.inForce = $false
    $restingClock.clockAuthority = 'authoredOrdinals'
    $restingLedger = Get-LedgerObject -Json $ledgerJson
    $restingLedger.budget.operationalStatus = 'historicalSnapshot'
    Assert-Ledger (Test-ClockAuthorityConsistent -Prerequisite $restingClock -Ledger $restingLedger) `
        'The clock-authority rule rejects the only combination this schema version permits, so it forbids the honest state as well as the dishonest ones.'

    $driftedSnapshotLedger = Get-LedgerObject -Json $ledgerJson
    $driftedSnapshotLedger.integrationSnapshot.asOfCommit = [string]$ledger.previousSnapshot.asOfCommit
    $driftedSnapshotPrerequisite = $driftedSnapshotLedger.decision.prerequisites | Where-Object { $_.id -eq 'escape-ledger' }
    Assert-Ledger (-not (Test-ClockAuthorityConsistent -Prerequisite $driftedSnapshotPrerequisite -Ledger $driftedSnapshotLedger)) `
        'An in-force budget was accepted after its authoritative integration snapshot was moved away from the coverage-window head.'
}

# The counts and the trigger state live in the machine-readable budget, so whatever tells a
# reader they are a dated snapshot rather than a live reading has to live there too. A caveat
# that appears only in prose is not attached to the data anyone parses.
$budgetNames = @($ledger.budget.PSObject.Properties | ForEach-Object { $_.Name })
Assert-Ledger ($budgetNames -contains 'operationalStatus') `
    'The budget publishes qualifying counts and a triggered flag without an operationalStatus, so a machine reader cannot tell that its window clock is authored rather than derived.'
if ($budgetNames -contains 'operationalStatus') {
    Assert-Ledger ([string]$ledger.budget.operationalStatus -eq 'inForce') `
        "The budget declares operationalStatus '$($ledger.budget.operationalStatus)' despite the authoritative Gate 5 integration snapshot."
}
Assert-Ledger ($budgetNames -contains 'asOfCommit') `
    'The budget does not say which commit its counts were taken at, so the snapshot has no date attached to it.'
if ($budgetNames -contains 'asOfCommit') {
    Assert-Ledger ([string]$ledger.budget.asOfCommit -eq [string]$ledger.coverageWindow.endCommit) `
        "The budget is stated as of $($ledger.budget.asOfCommit) but the coverage window ends at $($ledger.coverageWindow.endCommit); the counts and the window they are drawn from must agree."
}
foreach ($incident in @($incidents) + @($integrationIncidents)) {
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
        @{ Name = 'docs/escape-ledger.v2.json'; Text = $ledgerJson },
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
foreach ($incident in $integrationIncidents) {
    Assert-Ledger ($docText -match [regex]::Escape($incident.id)) `
        "docs/escape-ledger.md does not mention integration incident $($incident.id)."
}
$documentedIds = @([regex]::Matches($docText, 'ESC-\d{4}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
foreach ($id in $documentedIds) {
    Assert-Ledger ($seenIds.Contains($id)) "docs/escape-ledger.md mentions incident $id, which the ledger does not record."
}
$documentedIntegrationIds = @([regex]::Matches($docText, 'INT-\d{4}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
$integrationIdSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($integrationIncidents | ForEach-Object { [string]$_.id }))
foreach ($id in $documentedIntegrationIds) {
    Assert-Ledger ($integrationIdSet.Contains($id)) "docs/escape-ledger.md mentions integration incident $id, which the ledger does not record."
}
Assert-Ledger ($docText -match 'Gate 5') 'docs/escape-ledger.md does not record the Gate 5 observation.'

# --- 10. Optional commit verification -----------------------------------------------------

$commitsVerified = 0
$script:CommitsBehindHead = -1
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

Assert-Ledger ([string]$ledger.previousSnapshot.asOfCommit -eq '74e476a') `
    'The v2 ledger no longer identifies the historical v1 snapshot it supersedes.'
Assert-Ledger ([string]$ledger.previousSnapshot.ledgerSha256 -eq '531bd43c8ef23b4d704b97b899f1f056bc5a2ee6d9cbfa5324e23c8707bb3b1b') `
    'The digest binding the preserved v1 historical incidents and near misses changed.'
Assert-Ledger ([string]$ledger.previousSnapshot.artifactCommit -eq '5a8f106') `
    'The v2 ledger no longer identifies the commit containing the frozen v1 artifact.'
Assert-Ledger ([string]$ledger.previousSnapshot.artifactPath -eq 'docs/escape-ledger.v1.json') `
    'The v2 ledger no longer identifies the path of the frozen v1 artifact.'
$v1Ledger = $null
if ($VerifyCommits) {
    $v1Spec = "$($ledger.previousSnapshot.artifactCommit):$($ledger.previousSnapshot.artifactPath)"
    $v1Path = Join-Path $repoRoot ([string]$ledger.previousSnapshot.artifactPath)
    Assert-Ledger (Test-Path -LiteralPath $v1Path) `
        "The frozen v1 artifact '$v1Spec' is not retained at $($ledger.previousSnapshot.artifactPath)."
    if (Test-Path -LiteralPath $v1Path) {
        $v1Text = (Get-Content -LiteralPath $v1Path -Raw).Replace("`r`n", "`n")
        $v1Bytes = [Text.Encoding]::UTF8.GetBytes($v1Text)
        $v1Digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($v1Bytes)).ToLowerInvariant()
        Assert-Ledger ($v1Digest -eq [string]$ledger.previousSnapshot.ledgerSha256) `
            "The frozen v1 artifact digest is $v1Digest, not $($ledger.previousSnapshot.ledgerSha256)."
        $v1Ledger = $v1Text | ConvertFrom-Json
    }
}

function Get-ClassificationBaselineObjection {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Incidents,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$NearMisses,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Baseline
    )
    Register-ValidatorCall -Name 'classificationBaseline'
    $records = @(
        @($Incidents | ForEach-Object {
                [pscustomobject]@{
                    id = [string]$_.id
                    recordKind = 'incident'
                    category = [string]$_.category
                    executionStage = [string]$_.executionStage
                    introducedCommit = [string]$_.introducedCommit
                }
            }) +
        @($NearMisses | ForEach-Object {
                [pscustomobject]@{
                    id = [string]$_.id
                    recordKind = 'nearMiss'
                    category = [string]$_.category
                    executionStage = [string]$_.executionStage
                    introducedCommit = [string]$_.introducedCommit
                }
            })
    )
    if ($records.Count -ne $Baseline.Count) {
        return "The classification baseline has $($Baseline.Count) record(s), but the historical incident and near-miss lists have $($records.Count). A record was added, removed, or moved without updating the visible baseline."
    }
    $baselineIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($expected in $Baseline) {
        if (-not $baselineIds.Add([string]$expected.id)) {
            return "Classification baseline identifier $($expected.id) is duplicated, leaving another historical record unpinned."
        }
        $actual = @($records | Where-Object { [string]$_.id -eq [string]$expected.id })
        if ($actual.Count -ne 1) {
            return "Classification baseline entry $($expected.id) does not identify exactly one historical record."
        }
        foreach ($field in @('recordKind', 'category', 'executionStage', 'introducedCommit')) {
            if ([string]$actual[0].$field -cne [string]$expected.$field) {
                return "Historical record $($expected.id) changed $field from '$($expected.$field)' to '$($actual[0].$field)'. The edit is classification-affecting and cannot silently move the record out of the budget."
            }
        }
    }
    foreach ($record in $records) {
        if (-not $baselineIds.Contains([string]$record.id)) {
            return "Historical record $($record.id) has no classification baseline entry."
        }
    }
    return $null
}

Assert-Ledger ($null -eq ($classificationObjection = Get-ClassificationBaselineObjection -Incidents $incidents -NearMisses $nearMisses -Baseline @($ledger.classificationBaseline))) ([string]$classificationObjection)

if ($VerifyCommits -and $null -ne $v1Ledger) {
    Assert-Ledger ($null -eq ($v1BaselineObjection = Get-ClassificationBaselineObjection -Incidents @($v1Ledger.incidents) -NearMisses @($v1Ledger.nearMisses) -Baseline @($ledger.classificationBaseline))) `
        ([string]$v1BaselineObjection)
    $driftedHistoricalBaseline = Get-LedgerObject -Json $ledgerJson
    $driftedHistoricalBaseline.classificationBaseline[0].category = 'logic'
    Assert-Ledger ($null -ne (Get-ClassificationBaselineObjection -Incidents @($v1Ledger.incidents) -NearMisses @($v1Ledger.nearMisses) -Baseline @($driftedHistoricalBaseline.classificationBaseline))) `
        'A v2 classification baseline that disagrees with the digest-verified v1 artifact was accepted.'
}

$classificationHonest = Get-LedgerObject -Json $ledgerJson
Assert-Ledger ($null -eq (Get-ClassificationBaselineObjection -Incidents @($classificationHonest.incidents) -NearMisses @($classificationHonest.nearMisses) -Baseline @($classificationHonest.classificationBaseline))) `
    'The classification baseline validator rejects the unmodified ledger.'
$classificationFalsified = Get-LedgerObject -Json $ledgerJson
$classificationFalsified.incidents[0].introducedCommit = [string]$classificationFalsified.nearMisses[0].introducedCommit
Assert-Ledger ($null -ne (Get-ClassificationBaselineObjection -Incidents @($classificationFalsified.incidents) -NearMisses @($classificationFalsified.nearMisses) -Baseline @($classificationFalsified.classificationBaseline))) `
    'Rewriting an escape introducedCommit to an unmerged branch commit did not contradict the visible classification baseline.'
$classificationMoved = Get-LedgerObject -Json $ledgerJson
$movedRecord = $classificationMoved.incidents[0]
$classificationMoved.incidents = @($classificationMoved.incidents | Where-Object { [string]$_.id -ne [string]$movedRecord.id })
$classificationMoved.nearMisses = @($classificationMoved.nearMisses) + @($movedRecord)
Assert-Ledger ($null -ne (Get-ClassificationBaselineObjection -Incidents @($classificationMoved.incidents) -NearMisses @($classificationMoved.nearMisses) -Baseline @($classificationMoved.classificationBaseline))) `
    'Moving a historical escape to nearMisses did not contradict the visible classification baseline.'
$classificationDuplicated = Get-LedgerObject -Json $ledgerJson
$classificationDuplicated.classificationBaseline[-1] = $classificationDuplicated.classificationBaseline[0]
Assert-Ledger ($null -ne (Get-ClassificationBaselineObjection -Incidents @($classificationDuplicated.incidents) -NearMisses @($classificationDuplicated.nearMisses) -Baseline @($classificationDuplicated.classificationBaseline))) `
    'Duplicating one baseline entry and dropping another left a historical record unpinned.'

# Two axes, not one. A containment escape is a defect that entered a merged coordinator
# change; a runtime exposure finding is one that reached shadow or live execution, whether
# or not it ever merged. Only the first is budget evidence, but the second is the evidence
# the typed-host decision most wants to read, and a taxonomy that cannot represent
# "reached live before merge" is a taxonomy that quietly drops it. So the near-miss schema
# no longer pins reachedShadowOrLive false, and the count is published across both lists.
$runtimeFindings = @(@($incidents) + @($nearMisses) + @($integrationIncidents))
$runtimeExposureIds = @($runtimeFindings | Where-Object { [string]$_.executionStage -in @('shadow', 'live') } | ForEach-Object { [string]$_.id })
$runtimeExposure = $runtimeExposureIds.Count
$runtimeExposureByCategory = [ordered]@{}
foreach ($category in @($declaredCategories | Sort-Object)) {
    $runtimeExposureByCategory[[string]$category] = @($runtimeFindings | Where-Object { [string]$_.executionStage -in @('shadow', 'live') -and [string]$_.category -eq [string]$category }).Count
}
$shadowRuns = 0
$liveRuns = 0
foreach ($observation in @($ledger.gateObservations)) {
    $shadowRuns += [int]$observation.shadowRunsPerformed
    $liveRuns += [int]$observation.liveRunsPerformed
}
$runsPerformed = $shadowRuns + $liveRuns
if ($runsPerformed -eq 0) {
    Assert-Ledger ($runtimeExposure -eq 0) `
        "The ledger records $runtimeExposure finding(s) that reached shadow or live execution ($($runtimeExposureIds -join ', ')), but gateObservations reports no shadow or live run has ever been performed. One of the two is wrong."
}
foreach ($exposed in $runtimeFindings | Where-Object { $true -eq $_.reachedShadowOrLive }) {
    Assert-Ledger ([string]$exposed.executionStage -in @('shadow', 'live')) `
        "Finding $($exposed.id) reached shadow or live execution but records executionStage '$($exposed.executionStage)'."
}

# ...and the other direction, on both lists. Enforcing only "true implies shadow or live"
# left the undercount open: a near miss could declare executionStage shadow with
# reachedShadowOrLive false and pass, which is precisely the finding the runtime axis exists
# to surface. The two fields are equivalent by definition, so they are checked as equivalent
# rather than as an implication in whichever direction happened to be written first. The
# predicate is a function called by both the production loop and the control below, so that
# deleting the rule also breaks the control - restating it in two places would leave the
# control green if the real check disappeared.
function Test-ExposureFieldsAgree {
    param([Parameter(Mandatory)][object]$Finding)
    Register-ValidatorCall -Name 'exposure'
    return (([bool]$Finding.reachedShadowOrLive) -eq ([string]$Finding.executionStage -in @('shadow', 'live')))
}
foreach ($finding in $runtimeFindings) {
    Assert-Ledger (Test-ExposureFieldsAgree -Finding $finding) `
        "Finding $($finding.id) records executionStage '$($finding.executionStage)' but reachedShadowOrLive is $($finding.reachedShadowOrLive). The two are the same fact; a stage of shadow or live with the flag false silently drops the finding out of the runtime exposure count."
}

# An open debt is a published count, and 'accepted' was the one status that closed it with no
# evidence at all: 'remediated' already demands a remediating commit, so flipping openDebt to
# accepted moved the number by one enum edit. Acceptance is a decision, so it has to be
# recorded as one. One validator, called by production and by the control below, so that
# deleting the rule breaks the control that is supposed to prove it.
function Get-AcceptanceObjection {
    param([Parameter(Mandatory)][object]$Finding)
    Register-ValidatorCall -Name 'acceptance'
    if ([string]$Finding.status -ne 'accepted') { return $null }
    $names = @($Finding.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names -notcontains 'acceptanceRationale' -or [string]::IsNullOrWhiteSpace([string]$Finding.acceptanceRationale)) {
        return "Finding $($Finding.id) is marked accepted but records no acceptanceRationale. Accepting a risk lowers the open-debt count, so it cannot be done by changing one enum value."
    }
    if ($names -notcontains 'acceptedOnCommit' -or [string]::IsNullOrWhiteSpace([string]$Finding.acceptedOnCommit)) {
        return "Finding $($Finding.id) is marked accepted but records no acceptedOnCommit, so the acceptance is asserted against no point in the history."
    }
    return $null
}

foreach ($finding in @(@($incidents) + @($nearMisses))) {
    Assert-Ledger ($null -eq ($acceptanceObjection = Get-AcceptanceObjection -Finding $finding)) ([string]$acceptanceObjection)
}

# The control has to run the production validator, not a restatement of it.
$acceptanceProbe = @(Get-LedgerObject -Json $ledgerJson).incidents | Where-Object { [string]$_.status -eq 'openDebt' } | Select-Object -First 1
if ($null -ne $acceptanceProbe) {
    Assert-Ledger ($null -eq (Get-AcceptanceObjection -Finding $acceptanceProbe)) `
        "The acceptance validator objects to $($acceptanceProbe.id) as filed, so it would fail on honest records."
    $acceptanceProbe.status = 'accepted'
    Assert-Ledger ($null -ne (Get-AcceptanceObjection -Finding $acceptanceProbe)) `
        "Relabelling the open-debt finding $($acceptanceProbe.id) as accepted was accepted with no evidence, so the open-debt count still moves by one enum edit."
}

# The undercount direction is the one that was open, so it is the one that gets a control.
$exposureProbe = (Get-LedgerObject -Json $ledgerJson).nearMisses | Select-Object -First 1
if ($null -ne $exposureProbe) {
    Assert-Ledger (Test-ExposureFieldsAgree -Finding $exposureProbe) `
        'The exposure-equivalence test rejects an unmutated near miss, so it would fail on honest records.'
    $exposureProbe.executionStage = 'shadow'
    Assert-Ledger (-not (Test-ExposureFieldsAgree -Finding $exposureProbe)) `
        'A finding declaring shadow execution with reachedShadowOrLive false was accepted, so a runtime exposure can be hidden by leaving one of the two fields behind.'
}

# The trigger counts type-binding escapes, so `category` is the single field with the most
# leverage over the pivot decision, and on its own it was pure assertion: changing one
# incident from typeBinding to logic walked the count down with nothing to object. It cannot
# be derived - what a defect "was" is a judgement - but it can be held consistent with the
# detector the same incident already cites. A collection-collapse rule and a control-flow
# rule are not interchangeable, so an incident detected by one and classified as the other is
# a contradiction inside the record. This raises the cost of a quiet edit from one field to
# two mutually corroborating ones; it is not proof, and docs/hardening-limitations.md says so.
$collapseRules = @('PSEN004', 'PSEN005', 'PSEN009', 'PSEN011')
$controlFlowRules = @('PSEN001', 'PSEN002', 'PSEN003', 'PSEN006', 'PSEN010')

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

$categoryDetectorConsistent = 0
$unanchoredIds = @()
$budgetCountedCategories = @('typeBinding', 'logic')
$categoryFindings = @(@($incidents) + @($integrationIncidents))
$declaredExceptions = @($ledger.categoryAnchorExceptions)
$declaredExceptionIds = @($declaredExceptions | ForEach-Object { [string]$_.id })

# One validator for both directions, called by the production loop and by the controls, so
# that removing the rule also breaks the control that is supposed to prove it. Returns the
# reason the classification is unacceptable, or $null when it is acceptable.
function Get-CategoryObjection {
    param(
        [Parameter(Mandatory)][object]$Incident,
        [Parameter(Mandatory)][string[]]$CollapseRules,
        [Parameter(Mandatory)][string[]]$ControlFlowRules,
        [Parameter(Mandatory)][string[]]$CountedCategories,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Exceptions
    )
    Register-ValidatorCall -Name 'category'
    $implied = Get-DetectorImpliedCategory -Text ([string]$Incident.detector) -CollapseRules $CollapseRules -ControlFlowRules $ControlFlowRules
    if ($null -eq $implied) {
        # The forward rule has nothing to say here, so the converse carries the weight: a
        # category the budget counts may not be asserted without a detector that implies it.
        # Without this, an unanchored incident's category was free in both directions and
        # typeBinding could be inflated by a single field edit on the one incident the anchor
        # cannot reach.
        if ([string]$Incident.category -in $CountedCategories) {
            $matchingException = @($Exceptions | Where-Object {
                    [string]$_.id -eq [string]$Incident.id -and
                    [string]$_.category -eq [string]$Incident.category
                })
            if ($matchingException.Count -eq 1) { return $null }
            return "Escape $($Incident.id) is classified '$($Incident.category)', which the budget counts, but the detector it cites implies no category. A category the trigger reads has to be corroborated by the detector family; record a detector that implies it, or classify the escape outside the counted categories."
        }
        return $null
    }
    if ([string]$Incident.category -ne $implied) {
        return "Escape $($Incident.id) is classified '$($Incident.category)' but the detector it cites is a $implied detector. A collection-collapse rule and a control-flow rule are not interchangeable, so one of the two fields is wrong; the trigger counts type-binding escapes and cannot be moved by editing the category alone."
    }
    return $null
}

foreach ($incident in $categoryFindings) {
    $implied = Get-DetectorImpliedCategory -Text ([string]$incident.detector) -CollapseRules $collapseRules -ControlFlowRules $controlFlowRules
    if ($null -eq $implied) { $unanchoredIds += [string]$incident.id } else { $categoryDetectorConsistent++ }
    Assert-Ledger ($null -eq ($objection = Get-CategoryObjection -Incident $incident -CollapseRules $collapseRules -ControlFlowRules $controlFlowRules -CountedCategories $budgetCountedCategories -Exceptions $declaredExceptions)) ([string]$objection)
}

# De-anchoring is itself an edit, so it has to be a visible one. Without this, rewriting an
# incident's detector to name nothing recognised would quietly drop it out of the anchored set
# and free its category, showing up only as a published counter falling by one.
# The set equality was asserted inline, so disabling it let an undeclared exception through
# while every control stayed green. One validator, called by production and by the control.
function Get-ExceptionSetObjection {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ComputedIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$DeclaredIds
    )
    Register-ValidatorCall -Name 'exceptionSet'
    $computed = (@($ComputedIds | Sort-Object) -join ',')
    $declared = (@($DeclaredIds | Sort-Object) -join ',')
    if ($computed -ne $declared) {
        return "The escapes whose detector implies no category ($computed) do not match the ledger's declared categoryAnchorExceptions ($declared). Removing an escape from the anchored set has to be recorded, not inferred from a counter."
    }
    return $null
}

Assert-Ledger ($null -eq ($exceptionSetObjection = Get-ExceptionSetObjection -ComputedIds @($unanchoredIds) -DeclaredIds @($declaredExceptionIds))) ([string]$exceptionSetObjection)
function Get-ExceptionObjection {
    <#
        .SYNOPSIS
        Returns the reason a categoryAnchorExceptions entry is unacceptable, or $null.
    #>
    param(
        [Parameter(Mandatory)][object]$Exception,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Incidents
    )
    Register-ValidatorCall -Name 'exceptionEntry'
    $matched = @($Incidents | Where-Object { [string]$_.id -eq [string]$Exception.id })
    if ($matched.Count -ne 1) {
        return "categoryAnchorExceptions names $($Exception.id), which is not an escape in this ledger."
    }
    # An unanchored escape's category is not constrained by any detector, so the exception
    # entry has to carry it. Without this, listing an escape as an exception is a licence to
    # give it any category at all: rewriting a detector to name nothing recognised, declaring
    # the exception, and moving the category out of a counted one lowers the published count
    # while leaving every check green. The category now has to be restated in the reviewed
    # list, so changing it is an edit to that list rather than a counter falling by one.
    if ([string]$Exception.category -ne [string]$matched[0].category) {
        return "categoryAnchorExceptions records $($Exception.id) as '$($Exception.category)' but the escape is filed as '$($matched[0].category)'. An escape no detector can anchor has its category pinned by the exception entry, and the two have to agree."
    }
    return $null
}

foreach ($exception in @($ledger.categoryAnchorExceptions)) {
    Assert-Ledger ($null -eq ($exceptionObjection = Get-ExceptionObjection -Exception $exception -Incidents $categoryFindings)) ([string]$exceptionObjection)
}

# The pin has to be able to fail, through the same validator production uses.
$exceptionProbe = @(Get-LedgerObject -Json $ledgerJson).categoryAnchorExceptions | Select-Object -First 1
if ($null -ne $exceptionProbe) {
    Assert-Ledger ($null -eq (Get-ExceptionObjection -Exception $exceptionProbe -Incidents $categoryFindings)) `
        "The exception validator objects to $($exceptionProbe.id) as filed, so it would fail on honest records."
    $exceptionProbe.category = 'external'
    Assert-Ledger ($null -ne (Get-ExceptionObjection -Exception $exceptionProbe -Incidents $categoryFindings)) `
        "The exception validator accepted a declared category that disagrees with the escape as filed, so an unanchored escape's category is still free."
}

# The anchor has to be able to fail, and has to bite on the field the budget actually reads.
# Both controls mutate a real incident and feed it through the production validator rather
# than restating the predicate, so a control cannot survive the rule it tests being deleted.
$categoryProbe = @($incidents | Where-Object { $_.category -eq 'typeBinding' -and $null -ne (Get-DetectorImpliedCategory -Text ([string]$_.detector) -CollapseRules $collapseRules -ControlFlowRules $controlFlowRules) } | Select-Object -First 1)
Assert-Ledger ($categoryProbe.Count -eq 1) `
    'No type-binding escape has a detector-anchored category, so the anchor constrains nothing the budget reads.'
if ($categoryProbe.Count -eq 1) {
    $deflated = @(Get-LedgerObject -Json $ledgerJson).incidents | Where-Object { [string]$_.id -eq [string]$categoryProbe[0].id } | Select-Object -First 1
    Assert-Ledger ($null -eq (Get-CategoryObjection -Incident $deflated -CollapseRules $collapseRules -ControlFlowRules $controlFlowRules -CountedCategories $budgetCountedCategories -Exceptions $declaredExceptions)) `
        "The category validator objects to $($categoryProbe[0].id) as filed, so it would fail on honest records."
    $deflated.category = 'logic'
    Assert-Ledger ($null -ne (Get-CategoryObjection -Incident $deflated -CollapseRules $collapseRules -ControlFlowRules $controlFlowRules -CountedCategories $budgetCountedCategories -Exceptions $declaredExceptions)) `
        "Reclassifying $($categoryProbe[0].id) as 'logic' does not contradict its cited detector, so the category anchor would not have caught it and the type-binding count could be walked down by one field."

    # De-anchoring has to be detected, and the check for it has to be able to fail. Comparing
    # the unanchored set against itself plus a known non-member is always true and proves
    # nothing; this recomputes the set after rewriting a real anchored escape's detector to
    # name nothing recognised, which is the actual move, and requires the declared exception
    # list to no longer match.
    $deAnchored = @(Get-LedgerObject -Json $ledgerJson).incidents | Where-Object { [string]$_.id -eq [string]$categoryProbe[0].id } | Select-Object -First 1
    $deAnchored.detector = 'Manual review'
    $recomputed = New-Object System.Collections.Generic.List[string]
    foreach ($retained in @($unanchoredIds | Where-Object { $_ -ne [string]$categoryProbe[0].id })) { $recomputed.Add([string]$retained) }
    if ($null -eq (Get-DetectorImpliedCategory -Text ([string]$deAnchored.detector) -CollapseRules $collapseRules -ControlFlowRules $controlFlowRules)) {
        $recomputed.Add([string]$deAnchored.id)
    }
    Assert-Ledger ($null -ne (Get-ExceptionSetObjection -ComputedIds @($recomputed) -DeclaredIds @($declaredExceptionIds))) `
        "Rewriting $($categoryProbe[0].id)'s detector to name nothing recognised leaves the computed exception set matching the declared one, so de-anchoring would pass unrecorded."
}

# The inflation path was the live one: the single incident the anchor cannot reach had a free
# category, and the budget counts typeBinding.
$unanchoredProbe = @($categoryFindings | Where-Object { $unanchoredIds -contains [string]$_.id } | Select-Object -First 1)
if ($unanchoredProbe.Count -eq 1) {
    $inflatedLedger = Get-LedgerObject -Json $ledgerJson
    $inflated = @(@($inflatedLedger.incidents) + @($inflatedLedger.integrationIncidents)) | Where-Object { [string]$_.id -eq [string]$unanchoredProbe[0].id } | Select-Object -First 1
    Assert-Ledger ($null -eq (Get-CategoryObjection -Incident $inflated -CollapseRules $collapseRules -ControlFlowRules $controlFlowRules -CountedCategories $budgetCountedCategories -Exceptions $declaredExceptions)) `
        "The category validator objects to the unanchored escape $($unanchoredProbe[0].id) as filed, so it would fail on honest records."
    $inflated.category = 'typeBinding'
    Assert-Ledger ($null -ne (Get-CategoryObjection -Incident $inflated -CollapseRules $collapseRules -ControlFlowRules $controlFlowRules -CountedCategories $budgetCountedCategories -Exceptions $declaredExceptions)) `
        "Reclassifying the unanchored escape $($unanchoredProbe[0].id) as 'typeBinding' would not be rejected, so the budget count can still be inflated by one field."
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

    # The escape-versus-near-miss split decides what the budget counts, so it cannot rest on    # a self-declared boolean alone. Git is used here as a contradiction check, not as an
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

    function Get-CommitDay {
        <#
            The committer date of a commit as yyyy-MM-dd, or an empty string when the commit
            cannot be read. Kept as a function rather than inlined so the date lookups do not
            put a redirection inside an array subexpression, which the boundary analyzer reads
            as an explicit null entering a collection.
        #>
        param([Parameter(Mandatory)][string]$Sha, [Parameter(Mandatory)][string]$RepoRoot)
        $iso = (& git -C $RepoRoot show -s --format=%cI $Sha 2>$null)
        if ([string]::IsNullOrWhiteSpace($iso)) { return '' }
        return ([datetimeoffset]$iso).ToString('yyyy-MM-dd')
    }

    function Get-CommitList {
        <#
            The commits reachable from a ref, newest first, or an empty list when the ref
            cannot be read. Kept as a function for the same reason as Get-CommitDay: the
            redirection must not sit inside an array subexpression.
        #>
        param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][int]$MaxCount, [Parameter(Mandatory)][string]$RepoRoot)
        $lines = (& git -C $RepoRoot rev-list --max-count=$MaxCount $Ref 2>$null)
        if ($null -eq $lines) { return @() }
        return @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
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

    # One validator, called by the production loop and by the sabotage control, so that
    # deleting the rule breaks the control too. An earlier form asserted the rules inline and
    # proved them separately against the window start; replacing both inline assertions with
    # unconditional success left the controls green, which makes them decoration rather than
    # controls. Returns the failure reasons, empty when the baseline is acceptable.
    function Test-NearMissBaseline {
        param(
            [Parameter(Mandatory)][object]$NearMiss,
            [Parameter(Mandatory)][string]$WindowEnd,
            [Parameter(Mandatory)][string]$ClassificationAnchor,
            [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PreservedNearMissIds,
            [Parameter(Mandatory)][string]$RepoRoot
        )
        Register-ValidatorCall -Name 'nearMissBaseline'
        $reasons = New-Object System.Collections.Generic.List[string]
        $introduced = [string]$NearMiss.introducedCommit
        $baseline = [string]$NearMiss.classifiedAgainstCommit
        $detectedOn = [string]$NearMiss.detectedOn

        if (-not (Test-CommitMerged -Sha $baseline -WindowEnd $WindowEnd -RepoRoot $RepoRoot)) {
            $reasons.Add("Near miss $($NearMiss.id) was classified against $baseline, which is not reachable from the coverage window's end commit $WindowEnd. A finding must be classified against a commit on the mainline the window describes.")
        }
        if (Test-CommitMerged -Sha $introduced -WindowEnd $baseline -RepoRoot $RepoRoot) {
            $reasons.Add("Near miss $($NearMiss.id) was introduced at $introduced, which IS reachable from the mainline commit $baseline it was classified against. A defect already on the mainline is an escape and must be counted against the budget; it cannot be reclassified out of the window by declaring mergedBeforeDetection false.")
        }
        if ((Test-CommitMerged -Sha $introduced -WindowEnd $WindowEnd -RepoRoot $RepoRoot) -and
            $PreservedNearMissIds -notcontains [string]$NearMiss.id) {
            $reasons.Add("Near miss $($NearMiss.id) is reachable from the current coverage-window end but is not preserved by the digest-verified v1 snapshot. A new finding already in the current window is an escape.")
        }

        # The baseline is not chosen, derived, or bounded: it is the snapshot's own anchor.
        # Bounding it did not work - reachability from the window end admits every commit in
        # the window, and a lower bound on its date admits every non-tip commit sharing a
        # calendar day with detectedOn. Deriving it from detectedOn did not work either,
        # because the derivation reads the window end: advancing the window to a later commit
        # on the same calendar day silently moved the expected baseline and false-failed both
        # honestly filed near misses. A derivation whose result changes when unrelated history
        # lands is the same directional defect as the date comparison it replaced.
        #
        # This ledger is a frozen historical snapshot, so the mainline a finding was judged
        # against is the one the snapshot is anchored to, and there is exactly one such commit.
        # Advancing the window is not an edit to this record; it is the authoring of a new
        # snapshot, at which point every near miss is re-judged against the new anchor.
        if (-not $ClassificationAnchor.StartsWith($baseline) -and -not $baseline.StartsWith($ClassificationAnchor)) {
            $reasons.Add("Near miss $($NearMiss.id) records a baseline of $baseline, but its preserved historical classification is anchored at $ClassificationAnchor. Choosing any other commit changes how much history the classification ignores.")
        }

        # detectedOn no longer selects a commit, but it still orders the record, and a defect
        # cannot be detected before the change that introduced it exists.
        $introducedDay = Get-CommitDay -Sha $introduced -RepoRoot $RepoRoot
        if (-not [string]::IsNullOrWhiteSpace($introducedDay) -and $detectedOn -lt $introducedDay) {
            $reasons.Add("Near miss $($NearMiss.id) records detectedOn $detectedOn but its introducing commit $introduced is dated $introducedDay. A finding cannot be detected before the change that introduced it.")
        }
        return @($reasons)
    }

    $preservedNearMissIds = @($v1Ledger.nearMisses | ForEach-Object { [string]$_.id })
    foreach ($nearMiss in $nearMisses) {
        $nearMissNames = @($nearMiss.PSObject.Properties | ForEach-Object { $_.Name })
        Assert-Ledger ($nearMissNames -contains 'introducedCommit') `
            "Near miss $($nearMiss.id) cites no introducedCommit, so its claim never to have merged cannot be checked against git."
        Assert-Ledger ($nearMissNames -contains 'classifiedAgainstCommit') `
            "Near miss $($nearMiss.id) cites no classifiedAgainstCommit, so there is no fixed mainline to test its unmerged claim against."
        if ($nearMissNames -notcontains 'introducedCommit' -or $nearMissNames -notcontains 'classifiedAgainstCommit') { continue }

        # The test runs against the commit the finding was classified against, not the live
        # window end. Using the live end would be a time bomb: merging the very change that
        # contains a near miss makes its introducing commit reachable, and the gate would
        # then fail - or, worse, demand that a correctly filed near miss be reclassified as
        # an escape - for no reason other than that time passed.
        Assert-Ledger ('' -eq ($baselineReasons = @(Test-NearMissBaseline -NearMiss $nearMiss -WindowEnd $windowEnd -ClassificationAnchor ([string]$ledger.previousSnapshot.asOfCommit) -PreservedNearMissIds $preservedNearMissIds -RepoRoot $repoRoot) -join ' ')) `
            $baselineReasons

        Assert-RemediationCommit -Finding $nearMiss -RepoRoot $repoRoot
    }

    # An acceptance has to be anchored to a real point in the history, not merely declared, and
    # it cannot predate the defect: reachability from the window end alone only proves the
    # commit exists somewhere earlier, so naming the window's own start commit closed the debt.
    function Get-AcceptanceCommitObjection {
        param(
            [Parameter(Mandatory)][object]$Finding,
            [Parameter(Mandatory)][string]$WindowEnd,
            [Parameter(Mandatory)][string]$RepoRoot
        )
        Register-ValidatorCall -Name 'acceptanceCommit'
        if ([string]$Finding.status -ne 'accepted') { return $null }
        $names = @($Finding.PSObject.Properties | ForEach-Object { $_.Name })
        if ($names -notcontains 'acceptedOnCommit') { return $null }
        $acceptedOn = [string]$Finding.acceptedOnCommit
        if (-not (Test-CommitMerged -Sha $acceptedOn -WindowEnd $WindowEnd -RepoRoot $RepoRoot)) {
            return "Finding $($Finding.id) records an acceptance at $acceptedOn, which is not reachable from the coverage window's end commit $WindowEnd."
        }
        if ($names -contains 'introducedCommit') {
            $introduced = [string]$Finding.introducedCommit
            if (-not (Test-CommitMerged -Sha $introduced -WindowEnd $acceptedOn -RepoRoot $RepoRoot)) {
                return "Finding $($Finding.id) records an acceptance at $acceptedOn, which does not descend from the introducing commit $introduced. A risk cannot be accepted at a point in the history before the defect existed."
            }
        }
        if ($names -contains 'detectedOn') {
            $acceptedDay = Get-CommitDay -Sha $acceptedOn -RepoRoot $RepoRoot
            if (-not [string]::IsNullOrWhiteSpace($acceptedDay) -and $acceptedDay -lt [string]$Finding.detectedOn) {
                return "Finding $($Finding.id) records an acceptance at $acceptedOn, dated $acceptedDay, before the finding's own detectedOn of $($Finding.detectedOn). A risk cannot be accepted before it is known."
            }
        }
        return $null
    }

    foreach ($accepted in @(@($incidents) + @($nearMisses))) {
        Assert-Ledger ($null -eq ($acceptanceCommitObjection = Get-AcceptanceCommitObjection -Finding $accepted -WindowEnd $windowEnd -RepoRoot $repoRoot)) ([string]$acceptanceCommitObjection)
    }

    # The acceptance rule exists to stop an open debt being closed by one enum edit, so it has
    # to be shown to reject exactly that edit on the finding that actually carries the debt -
    # and to reject the cheapest evidence an author could attach to it, which is a commit old
    # enough to predate the defect.
    $debtProbe = @(Get-LedgerObject -Json $ledgerJson).incidents | Where-Object { [string]$_.status -eq 'openDebt' } | Select-Object -First 1
    if ($null -ne $debtProbe) {
        Assert-Ledger ($null -eq (Get-AcceptanceObjection -Finding $debtProbe)) `
            "The acceptance validator objects to the open debt $($debtProbe.id) as filed, so it would fail on honest records."
        $debtProbe.status = 'accepted'
        Assert-Ledger ($null -ne (Get-AcceptanceObjection -Finding $debtProbe)) `
            "The open debt $($debtProbe.id) already carries acceptance evidence, so flipping its status to accepted would not be rejected and the open-debt count could still be closed by one field."
        $debtProbe | Add-Member -NotePropertyName 'acceptanceRationale' -NotePropertyValue 'Accepted because correcting it properly means changing a producer contract and all of its call sites, which is out of scope here.' -Force
        $debtProbe | Add-Member -NotePropertyName 'acceptedOnCommit' -NotePropertyValue ([string]$ledger.coverageWindow.startCommit) -Force
        Assert-Ledger ($null -eq (Get-AcceptanceObjection -Finding $debtProbe)) `
            "The acceptance validator still objects to $($debtProbe.id) once both evidence fields are present, so the commit rule below is not the thing being tested."
        Assert-Ledger ($null -ne (Get-AcceptanceCommitObjection -Finding $debtProbe -WindowEnd $windowEnd -RepoRoot $repoRoot)) `
            "The open debt $($debtProbe.id) was accepted at the coverage window's start commit, before the defect existed, and the gate allowed it. Reachability alone only proves the commit exists somewhere earlier in the history."
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

    # The baseline rule has to be shown to reject a backdated baseline, and it has to be shown
    # through the same code path production uses. Asserting facts about the window start
    # separately did not do that: replacing the production assertions with unconditional
    # success left those controls green, so they proved the reviewer's point rather than the
    # gate's. This mutates a real near miss to name the coverage window's own start commit -
    # on the mainline, reachable from the window end, and old enough to make any escape look
    # unmerged, so exactly the baseline an author would reach for - and requires the
    # production validator to reject it.
    $windowStart = [string]$ledger.coverageWindow.startCommit
    $baselineProbe = @(Get-LedgerObject -Json $ledgerJson).nearMisses | Select-Object -First 1
    if ($null -ne $baselineProbe -and -not [string]::IsNullOrWhiteSpace($windowStart)) {
        Assert-Ledger ((@(Test-NearMissBaseline -NearMiss $baselineProbe -WindowEnd $windowEnd -ClassificationAnchor ([string]$ledger.previousSnapshot.asOfCommit) -PreservedNearMissIds $preservedNearMissIds -RepoRoot $repoRoot)).Count -eq 0) `
            'The near-miss baseline validator rejects an unmutated near miss, so it would fail on honest records.'
        $honestBaseline = [string]$baselineProbe.classifiedAgainstCommit
        $baselineProbe.classifiedAgainstCommit = $windowStart
        Assert-Ledger ((@(Test-NearMissBaseline -NearMiss $baselineProbe -WindowEnd $windowEnd -ClassificationAnchor ([string]$ledger.previousSnapshot.asOfCommit) -PreservedNearMissIds $preservedNearMissIds -RepoRoot $repoRoot)).Count -gt 0) `
            "The near-miss baseline validator accepted the coverage window's start commit $windowStart as a baseline. That commit is old enough to make any merged escape look unmerged, so the escape-to-near-miss reclassification would still be available."

        # A baseline dated the same day as detection is the cheap version of the same move:
        # a lower bound on the baseline's date admits every non-tip commit sharing that day,
        # and there are several. Only the mainline as of that day may be named.
        $windowCommits = Get-CommitList -Ref $windowEnd -MaxCount 40 -RepoRoot $repoRoot
        $sameDayDecoy = @($windowCommits | Where-Object { $_ -and ((Get-CommitDay -Sha $_ -RepoRoot $repoRoot) -eq [string]$baselineProbe.detectedOn) -and -not $honestBaseline.StartsWith($_) -and -not $_.StartsWith($honestBaseline) } | Select-Object -First 1)
        if ($sameDayDecoy.Count -eq 1) {
            $baselineProbe.classifiedAgainstCommit = [string]$sameDayDecoy[0]
            Assert-Ledger ((@(Test-NearMissBaseline -NearMiss $baselineProbe -WindowEnd $windowEnd -ClassificationAnchor ([string]$ledger.previousSnapshot.asOfCommit) -PreservedNearMissIds $preservedNearMissIds -RepoRoot $repoRoot)).Count -gt 0) `
                "The near-miss baseline validator accepted $($sameDayDecoy[0]), a commit sharing the detection date but not the mainline as of it. A date bound leaves every commit on that day available, which is enough to reclassify a merged escape."
        }

        # And the date the baseline is derived from cannot itself be walked backwards to
        # choose an older mainline.
        $baselineProbe.classifiedAgainstCommit = $honestBaseline
        $baselineProbe.detectedOn = '2026-08-01'
        Assert-Ledger ((@(Test-NearMissBaseline -NearMiss $baselineProbe -WindowEnd $windowEnd -ClassificationAnchor ([string]$ledger.previousSnapshot.asOfCommit) -PreservedNearMissIds $preservedNearMissIds -RepoRoot $repoRoot)).Count -gt 0) `
            'The near-miss baseline validator accepted a backdated detectedOn. The baseline is derived from that date, so moving it moves the mainline the unmerged claim is tested against.'
    }

    $newNearMissProbe = Get-LedgerObject -Json ($nearMisses[0] | ConvertTo-Json -Depth 16)
    $newNearMissProbe.id = 'NM-9999'
    $newNearMissProbe.introducedCommit = $windowEnd
    Assert-Ledger ((@(Test-NearMissBaseline -NearMiss $newNearMissProbe -WindowEnd $windowEnd -ClassificationAnchor ([string]$ledger.previousSnapshot.asOfCommit) -PreservedNearMissIds $preservedNearMissIds -RepoRoot $repoRoot)).Count -gt 0) `
        'A newly filed near miss whose introducing commit is already in the current coverage window was accepted.'

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

        # Staleness is reported, not enforced, while the budget is not in force. Requiring a
        # frozen historical snapshot to advance is self-contradictory: advancing the window
        # moves the anchor every near miss is judged against, so it is the authoring of a new
        # snapshot rather than an edit to this one. The bound is still validated as declared,
        # so that it is already agreed when Gate 5 supplies an authoritative integration
        # snapshot and the budget goes in force - at which point it becomes a hard failure.
        $budgetInForce = $false
        foreach ($prerequisite in @($ledger.decision.prerequisites)) {
            if ([string]$prerequisite.id -eq 'escape-ledger' -and [bool]$prerequisite.inForce) { $budgetInForce = $true }
        }
        if ($budgetInForce) {
            Assert-Ledger ($behind -le $staleAfter) `
                "The coverage window ends $behind commit(s) behind HEAD, past its declared bound of $staleAfter; re-evaluate the ledger before merging further coordinator changes."
        }
        $script:CommitsBehindHead = $behind
    }
}

function Get-DiscardedValidatorVerdicts {
    param([Parameter(Mandatory)][string]$ScriptText)
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($ScriptText, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { return @('The validator-consumption probe could not parse its input.') }
    $validatorNames = @(
        'Test-IntegrationBudgetEligibilityConsistent',
        'Test-IdSetsEqual',
        'Test-ClockAuthorityConsistent',
        'Test-ExposureFieldsAgree',
        'Get-AcceptanceObjection',
        'Get-CategoryObjection',
        'Get-ExceptionSetObjection',
        'Get-ExceptionObjection',
        'Get-ClassificationBaselineObjection',
        'Test-NearMissBaseline',
        'Get-AcceptanceCommitObjection'
    )
    $objections = New-Object System.Collections.Generic.List[string]
    $calls = $ast.FindAll({
            param($node)
            if ($node -isnot [Management.Automation.Language.CommandAst]) { return $false }
            return ([string]$node.GetCommandName() -in $validatorNames)
        }, $true)
    foreach ($call in $calls) {
        $parent = $call.Parent
        $assertion = $null
        while ($null -ne $parent) {
            if ($parent -is [Management.Automation.Language.CommandAst] -and [string]$parent.GetCommandName() -eq 'Assert-Ledger') {
                $assertion = $parent
                break
            }
            if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) { break }
            $parent = $parent.Parent
        }
        if ($null -eq $assertion -or $assertion.CommandElements.Count -lt 2) {
            $objections.Add("Validator $($call.GetCommandName()) at line $($call.Extent.StartLineNumber) is not consumed by Assert-Ledger.")
            continue
        }
        $verdictExtent = $assertion.CommandElements[1].Extent
        if ($call.Extent.StartOffset -lt $verdictExtent.StartOffset -or $call.Extent.EndOffset -gt $verdictExtent.EndOffset) {
            $objections.Add("Validator $($call.GetCommandName()) at line $($call.Extent.StartLineNumber) is not part of Assert-Ledger's verdict argument.")
            continue
        }
        if ($verdictExtent.Text -match '(?i)(?:-or\s+\$true|-and\s+\$false)') {
            $objections.Add("Validator $($call.GetCommandName()) at line $($call.Extent.StartLineNumber) has its verdict discarded by a constant boolean expression.")
        }
    }
    return @($objections)
}

$selfText = Get-Content -LiteralPath $PSCommandPath -Raw
Assert-Ledger (@(Get-DiscardedValidatorVerdicts -ScriptText $selfText).Count -eq 0) `
    'A shared validator verdict is not consumed directly by Assert-Ledger.'
$discardedVerdictProbe = $selfText + [Environment]::NewLine + 'Assert-Ledger ((Test-ExposureFieldsAgree -Finding $finding) -or $true) ''discarded'''
Assert-Ledger (@(Get-DiscardedValidatorVerdicts -ScriptText $discardedVerdictProbe).Count -gt 0) `
    'The validator-consumption sabotage accepted an explicit "-or $true" that discards a validator verdict.'

# Every shared validator's entry count is asserted against the production invocations the real
# ledger requires plus the fixed number of control invocations. This is the check that survives
# call-site deletion: removing a production Assert-Ledger leaves the rule body intact and every
# control green, and does not move the check count, so nothing else in this gate notices. The
# numbers are deliberately explicit - adding or removing a control has to be recorded here.
$findingCount = @($runtimeFindings).Count
$historicalFindingCount = @($incidents).Count + @($nearMisses).Count
Assert-ValidatorInvoked -Name 'integrationBudgetEligibility' -Expected ($integrationIncidents.Count + 1) -Rule 'integration budget eligibility'
Assert-ValidatorInvoked -Name 'idSetEquality' -Expected 2 -Rule 'qualifying incident set equality'
Assert-ValidatorInvoked -Name 'coverageClock' -Expected 4 -Rule 'coverage clock derivation'
Assert-ValidatorInvoked -Name 'clockAuthority' -Expected 5 -Rule 'clock authority consistency'
Assert-ValidatorInvoked -Name 'exposure' -Expected ($findingCount + 2) -Rule 'stage/exposure equivalence'
Assert-ValidatorInvoked -Name 'category' -Expected (@($categoryFindings).Count + 4) -Rule 'category anchor'
Assert-ValidatorInvoked -Name 'exceptionSet' -Expected 2 -Rule 'exception set equality'
Assert-ValidatorInvoked -Name 'exceptionEntry' -Expected (@($ledger.categoryAnchorExceptions).Count + 2) -Rule 'exception entry'
$classificationBaselineExpected = if ($VerifyCommits) { 7 } else { 5 }
Assert-ValidatorInvoked -Name 'classificationBaseline' -Expected $classificationBaselineExpected -Rule 'historical classification baseline'
if ($VerifyCommits) {
    Assert-ValidatorInvoked -Name 'acceptance' -Expected ($historicalFindingCount + 5) -Rule 'acceptance evidence'
    Assert-ValidatorInvoked -Name 'nearMissBaseline' -Expected (@($nearMisses).Count + 5) -Rule 'near-miss baseline'
    Assert-ValidatorInvoked -Name 'acceptanceCommit' -Expected ($historicalFindingCount + 1) -Rule 'acceptance commit'
}
else {
    Assert-ValidatorInvoked -Name 'acceptance' -Expected ($historicalFindingCount + 2) -Rule 'acceptance evidence'
}

$report = [ordered]@{
    check = 'reviewer-escape-ledger'
    incidents = $incidents.Count
    integrationIncidents = $integrationIncidents.Count
    nearMisses = @($nearMisses).Count
    runtimeExposure = [ordered]@{
        findingCount = $runtimeExposure
        byCategory = $runtimeExposureByCategory
        shadowRuns = $shadowRuns
        liveRuns = $liveRuns
        observationStatus = $(if ($runsPerformed -eq 0) { 'noRuns' } else { 'observed' })
    }
    categoryDetectorConsistent = $categoryDetectorConsistent
    declaredCategoryAnchorExceptions = @($ledger.categoryAnchorExceptions).Count
    budgetEligibleCategoryAnchorExceptions = @($ledger.categoryAnchorExceptions | Where-Object {
            $id = [string]$_.id
            @($integrationIncidents | Where-Object { [string]$_.id -eq $id -and [bool]$_.budgetEligible }).Count -eq 1
        }).Count
    remediated = @($incidents | Where-Object { $_.status -eq 'remediated' }).Count
    openDebt = @($incidents | Where-Object { $_.status -eq 'openDebt' }).Count
    typeBinding = @($categoryFindings | Where-Object { $_.category -eq 'typeBinding' }).Count
    reachedShadowOrLive = @($runtimeFindings | Where-Object { $_.reachedShadowOrLive }).Count
    inWindow = $measured.InWindowIds.Count
    qualifyingCount = $measured.QualifyingCount
    triggered = $measured.Triggered
    decisionYieldPercent = [double]$snapshot.decisionYieldPercent
    unauthorizedWrites = [int]$snapshot.unauthorizedWrites
    commitsVerified = $commitsVerified
    commitsBehindHead = $script:CommitsBehindHead
    checks = $script:Checks
    failed = $script:Failures.Count
}

Write-Output ($report | ConvertTo-Json -Depth 6 -Compress)

if ($script:Failures.Count -gt 0) {
    $detail = ($script:Failures | ForEach-Object { " - $_" }) -join [Environment]::NewLine
    throw "Escape ledger validation failed $($script:Failures.Count) check(s):$([Environment]::NewLine)$detail"
}

Write-Host "PASS: escape ledger ($($incidents.Count) historical + $($integrationIncidents.Count) integration incidents, $($script:Checks) checks, trigger fired)."
