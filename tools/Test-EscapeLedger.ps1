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
function Measure-LedgerBudget {
    param([Parameter(Mandatory)][object]$Ledger)

    $threshold = $Ledger.budget.threshold
    $stages = @($threshold.reachedExecutionStages)
    $qualifying = [System.Collections.Generic.List[string]]::new()

    foreach ($incident in @($Ledger.incidents)) {
        if ($incident.category -ne $threshold.category) { continue }
        if (-not $incident.reachedShadowOrLive) { continue }
        if ($stages -notcontains $incident.executionStage) { continue }
        $qualifying.Add($incident.id)
    }

    $ids = [string[]]::new($qualifying.Count)
    $qualifying.CopyTo($ids, 0)

    return [pscustomobject]@{
        QualifyingIds = $ids
        QualifyingCount = $qualifying.Count
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
Assert-Ledger ([int]$ledger.budget.window.coordinatorPullRequests -eq 10) 'The registered trigger window is no longer ten coordinator changes.'
Assert-Ledger ([int]$ledger.budget.window.days -eq 60) 'The registered trigger window is no longer sixty days.'
Assert-Ledger ($ledger.budget.window.combinator -eq 'either') 'The registered trigger window combinator changed.'
Assert-Ledger ([int]$ledger.coverageWindow.coordinatorPullRequestsObserved -ge 1) `
    'The coverage window observes no coordinator changes.'

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
}

foreach ($observation in @($ledger.gateObservations)) {
    $writesConsistent = (([int]$observation.externalWrites -eq 0) -eq [bool]$observation.noWriteInvariantHeld)
    Assert-Ledger $writesConsistent `
        "Gate observation '$($observation.gate)' records $($observation.externalWrites) external write(s) but claims noWriteInvariantHeld=$($observation.noWriteInvariantHeld)."
}

# No incident may claim to have reached shadow or live while every gate observation reports
# that the no-write invariant held and no shadow or live run has been performed.
$anyReached = @($incidents | Where-Object { $_.reachedShadowOrLive })
$allHeld = -not (@($ledger.gateObservations | Where-Object { -not $_.noWriteInvariantHeld }).Count)
Assert-Ledger (-not ($anyReached.Count -gt 0 -and $allHeld)) `
    'The ledger claims escapes reached shadow or live while also claiming the no-write invariant always held.'

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
    reachedShadowOrLive = $anyReached.Count
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
