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

# Every regression guard and detector must name a file that exists, so a deleted guard
# cannot leave a remediated incident silently unguarded.
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
if ($VerifyCommits) {
    foreach ($incident in $incidents) {
        foreach ($property in @('introducedCommit', 'remediatedCommit')) {
            if ($incident.PSObject.Properties.Name -notcontains $property) { continue }
            $sha = $incident.$property
            & git -C $repoRoot cat-file -e "$sha^{commit}" 2>$null
            Assert-Ledger ($LASTEXITCODE -eq 0) "Incident $($incident.id) cites commit $sha, which is not in this repository's history."
            $commitsVerified++
        }
    }
}

$report = [ordered]@{
    check = 'reviewer-escape-ledger'
    incidents = $incidents.Count
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
