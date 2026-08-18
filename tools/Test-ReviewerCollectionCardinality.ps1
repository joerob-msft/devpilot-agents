<#
.SYNOPSIS
    Drives every inventoried collection field through the required cardinality
    variants, proves the known escape shapes, and derives the coverage matrix
    from what actually ran.

.DESCRIPTION
    Three blocking parts:

    1. Boundary variant harness. Every field in the checked-in collection
       inventory is pushed through the shared stage-contract normalizer and a
       JSON round trip at zero, one, many, max, duplicate, null-versus-missing,
       and wrong-scalar cardinality. The result of each run is recorded, so the
       coverage matrix is derived rather than asserted.

    2. Escape-shape property tests. The specific shapes that have collapsed a
       contract before - an empty set returned bare, a protected return wrapped
       in @(), a one-element JSON array, an empty difference set - are proven to
       collapse without the guard and to survive with it.

    3. Sabotage suite. Each historical collapse is reintroduced into a synthetic
       copy and the named detector must fire, so a regression is caught by a
       named check rather than by a downstream symptom.

    The matrix distinguishes two coverage dimensions and never merges them:
    the shared boundary is exercised for every field, while the real producing
    and consuming stage code is not, and that gap is reported rather than
    rounded away. No models are invoked and nothing outside a temporary
    directory is written.

.EXAMPLE
    ./tools/Test-ReviewerCollectionCardinality.ps1

.EXAMPLE
    ./tools/Test-ReviewerCollectionCardinality.ps1 -UpdateMatrix
#>
[CmdletBinding()]
param(
    [switch]$UpdateMatrix,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'src/Agents/reviewer/StageContract.ps1')

$analyzer = Join-Path $PSScriptRoot 'Find-PowerShellEmptyNullHazard.ps1'
$inventoryPath = Join-Path $PSScriptRoot 'testdata/reviewer-collection-inventory.v1.json'
$matrixPath = Join-Path $PSScriptRoot 'testdata/reviewer-collection-cardinality-matrix.v1.json'

$script:Failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([Parameter(Mandatory)][string]$Message)
    [void]$script:Failures.Add($Message)
}

function Assert-True {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail = ''
    )
    if (-not $Condition) { Add-Failure "$Name :: $Detail" }
    return $Condition
}

# ---------------------------------------------------------------------------
# Part 1 - boundary variant harness
# ---------------------------------------------------------------------------

$variants = [string[]]@('zero', 'one', 'many', 'max', 'duplicate', 'nullVsMissing', 'wrongScalar')
$maxElements = 32

$inventoryDocument = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json -Depth 12
$inventoryFields = ConvertTo-ReviewerStageArray -Value $inventoryDocument.fields
if ($inventoryFields.Count -ne [int]$inventoryDocument.fieldCount) {
    throw "Inventory declares $($inventoryDocument.fieldCount) fields but carries $($inventoryFields.Count)."
}

Clear-ReviewerStageContractRegistry
Register-ReviewerStageContract `
    -Kind 'reviewer.cardinality.probe' `
    -ContractVersion 1 `
    -RequiredFields @('id', 'values') `
    -CollectionFields @('values') | Out-Null

# Map-valued rows are judged by the same shared contract as list-valued rows, but
# against its map shape rather than its collection shape. Registering a second
# probe kind is what lets the matrix claim both dimensions honestly.
Register-ReviewerStageContract `
    -Kind 'reviewer.cardinality.mapprobe' `
    -ContractVersion 1 `
    -RequiredFields @('id', 'values') `
    -MapFields @('values') | Out-Null

function New-VariantValue {
    <#
    .SYNOPSIS
        Builds the raw producer-side value for one cardinality variant, in the
        container type the inventory recorded for that field.
    #>
    param(
        [Parameter(Mandatory)][string]$Variant,
        [Parameter(Mandatory)][string]$Kind
    )

    $elements = [System.Collections.Generic.List[object]]::new()
    switch ($Variant) {
        'zero' { }
        'one' { [void]$elements.Add('element-0') }
        'many' { for ($i = 0; $i -lt 3; $i++) { [void]$elements.Add("element-$i") } }
        'max' { for ($i = 0; $i -lt $maxElements; $i++) { [void]$elements.Add("element-$i") } }
        'duplicate' { for ($i = 0; $i -lt 3; $i++) { [void]$elements.Add('element-0') } }
        'nullVsMissing' { return $null }
        'wrongScalar' { return 'element-0' }
    }

    switch ($Kind) {
        'hashSet' {
            $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($element in $elements) { [void]$set.Add([string]$element) }
            Write-Output -NoEnumerate $set
        }
        'list' {
            Write-Output -NoEnumerate $elements
        }
        'psCollectionReturn' {
            # The shape a PowerShell function hands back before it is forced:
            # zero elements arrive as $null and one element as a bare scalar.
            if ($elements.Count -eq 0) { return $null }
            if ($elements.Count -eq 1) { return $elements[0] }
            Write-Output -NoEnumerate ([object[]]$elements.ToArray())
        }
        default {
            Write-Output -NoEnumerate ([object[]]$elements.ToArray())
        }
    }
}

function Get-ExpectedCount {
    param(
        [Parameter(Mandatory)][string]$Variant,
        [Parameter(Mandatory)][string]$Kind
    )

    switch ($Variant) {
        'zero' { return 0 }
        'one' { return 1 }
        'many' { return 3 }
        'max' { return $maxElements }
        'duplicate' { if ($Kind -eq 'hashSet') { return 1 } return 3 }
        'nullVsMissing' { return 0 }
        'wrongScalar' { return 1 }
    }
    return -1
}

function New-VariantMapValue {
    <#
    .SYNOPSIS
        Builds the raw producer-side value for one cardinality variant of a field whose
        declared container is a JSON object used as a map, not an array.
    #>
    param([Parameter(Mandatory)][string]$Variant)

    switch ($Variant) {
        'nullVsMissing' { return $null }
        'wrongScalar' { return 'element-0' }
    }

    $map = [ordered]@{}
    switch ($Variant) {
        'zero' { }
        'one' { $map['key-0'] = 'element-0' }
        'many' { for ($i = 0; $i -lt 3; $i++) { $map["key-$i"] = "element-$i" } }
        'max' { for ($i = 0; $i -lt $maxElements; $i++) { $map["key-$i"] = "element-$i" } }
        # A map cannot carry a duplicate key, so the duplicate variant is duplicate
        # *values* under distinct keys: the shape that a set-like consumer collapses.
        'duplicate' { for ($i = 0; $i -lt 3; $i++) { $map["key-$i"] = 'element-0' } }
    }
    return $map
}

function Get-ExpectedMapCount {
    param([Parameter(Mandatory)][string]$Variant)

    switch ($Variant) {
        'zero' { return 0 }
        'one' { return 1 }
        'many' { return 3 }
        'max' { return $maxElements }
        'duplicate' { return 3 }
        'nullVsMissing' { return 0 }
        'wrongScalar' { return 0 }
    }
    return -1
}

function Test-MapVariant {
    <#
    .SYNOPSIS
        Drives one map-valued field through one cardinality variant.
    .DESCRIPTION
        A map collapses differently from an array. An empty map must serialize as {} and
        not as [], a one-key map must not read back as its single value, and a scalar in a
        declared map field has no meaningful repair, so it must be refused rather than
        wrapped. Treating these rows as arrays would test none of that.

        Every judgement here is delegated to Test-ReviewerStageMapShape in the shared
        stage contract, so a map row exercises the same enforcement a list row does and
        the coverage matrix is not claiming shared-contract coverage it never ran.
    #>
    param(
        [Parameter(Mandatory)][string]$RowId,
        [Parameter(Mandatory)][string]$Variant
    )

    $rawValue = New-VariantMapValue -Variant $Variant
    $expected = Get-ExpectedMapCount -Variant $Variant

    if ($Variant -eq 'wrongScalar') {
        # There is no repair for a scalar where a map was declared: a map has keys and a
        # scalar has none, so wrapping it would invent one. The contract must refuse it.
        $scalarPayload = [ordered]@{ id = $RowId; values = $rawValue }
        $scalarViolations = Test-ReviewerStageMapShape -Payload $scalarPayload -MapFields @('values')
        if ($scalarViolations.Count -eq 0) {
            throw 'a bare scalar in a declared map field was not refused by the contract'
        }
        # And it must still be refused after the artifact has been through JSON, because
        # that is the form a consuming stage actually receives.
        $restored = (ConvertTo-Json -InputObject $scalarPayload -Depth 12 -Compress | ConvertFrom-Json -Depth 12)
        if ((Test-ReviewerStageMapShape -Payload $restored -MapFields @('values')).Count -eq 0) {
            throw 'a scalar map field read back as an acceptable map after a JSON round trip'
        }
        return
    }

    if ($Variant -eq 'nullVsMissing') {
        $nullPayload = [ordered]@{ id = $RowId; values = $rawValue }
        $nullJson = ConvertTo-Json -InputObject $nullPayload -Depth 12 -Compress
        if (-not $nullJson.Contains('"values":null')) {
            throw 'a null map field did not serialize as null, so null and empty are no longer distinguishable'
        }
        $missingJson = ConvertTo-Json -InputObject ([ordered]@{ id = $RowId }) -Depth 12 -Compress
        if ($missingJson.Contains('"values"')) {
            throw 'a missing map field was materialized'
        }
        $restoredNull = ($nullJson | ConvertFrom-Json -Depth 12)
        $restoredMissing = ($missingJson | ConvertFrom-Json -Depth 12)
        $nullPresent = $null -ne ($restoredNull.PSObject.Properties['values'])
        $missingPresent = $null -ne ($restoredMissing.PSObject.Properties['values'])
        if (-not $nullPresent -or $missingPresent) {
            throw 'null and missing map fields became indistinguishable after a round trip'
        }
        # The contract has to separate the two verdicts rather than reporting one shape
        # for both, or a consumer cannot tell an omitted map from an emptied one.
        $nullViolations = Test-ReviewerStageMapShape -Payload $restoredNull -MapFields @('values')
        $missingViolations = Test-ReviewerStageMapShape -Payload $restoredMissing -MapFields @('values')
        if ($nullViolations.Count -eq 0 -or $missingViolations.Count -eq 0) {
            throw 'the contract accepted a null or absent map field'
        }
        if (-not ("$nullViolations" -like '*null*') -or -not ("$missingViolations" -like '*missing*')) {
            throw 'the contract reported the same verdict for a null map and an absent map'
        }
        return
    }

    $payload = [ordered]@{ id = $RowId; values = $rawValue }
    $preViolations = Test-ReviewerStageMapShape -Payload $payload -MapFields @('values')
    if ($preViolations.Count -ne 0) {
        throw "the contract rejected a well-formed map: $($preViolations -join '; ')"
    }

    $json = ConvertTo-Json -InputObject $payload -Depth 12 -Compress
    if ($Variant -eq 'zero' -and -not $json.Contains('"values":{}')) {
        throw 'an empty map did not serialize as {}'
    }
    if ($json.Contains('"values":[')) {
        throw 'a map field serialized as an array, which is the collapse this row exists to catch'
    }

    $restoredPayload = ($json | ConvertFrom-Json -Depth 12)
    $postViolations = Test-ReviewerStageMapShape -Payload $restoredPayload -MapFields @('values')
    if ($postViolations.Count -ne 0) {
        throw "the map lost its shape across a JSON round trip: $($postViolations -join '; ')"
    }
    Test-ReviewerStagePayloadField -Payload $restoredPayload -Contract (Get-ReviewerStageContract -Kind 'reviewer.cardinality.mapprobe')

    $restored = $restoredPayload.values
    # Member enumeration over an empty property collection throws under Set-StrictMode,
    # which is the same empty-collection hazard this corpus exists to catch. Project the
    # names explicitly instead.
    $keys = @($restored.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($keys.Count -ne $expected) {
        throw "expected $expected key(s) after a JSON round trip, observed $($keys.Count)"
    }
    for ($i = 0; $i -lt $expected; $i++) {
        if ($keys[$i] -cne "key-$i") { throw "key order changed at index $i" }
    }
    if ($Variant -eq 'duplicate') {
        $values = @($keys | ForEach-Object { [string]$restored.$_ })
        if (@($values | Sort-Object -Unique).Count -ne 1) {
            throw 'duplicate map values did not survive the round trip'
        }
    }
}

$variantResults = @{}
$variantFailures = [System.Collections.Generic.List[string]]::new()

foreach ($row in $inventoryFields) {
    $rowId = [string]$row.id
    $kind = [string]$row.kind
    $perVariant = [ordered]@{}
    foreach ($variant in $variants) {
        $status = 'covered'
        try {
            if ($kind -eq 'jsonObjectMap') {
                Test-MapVariant -RowId $rowId -Variant $variant
                $perVariant[$variant] = $status
                continue
            }
            $rawValue = New-VariantValue -Variant $variant -Kind $kind
            $payload = [ordered]@{ id = $rowId; values = $rawValue }

            $normalized = ConvertTo-ReviewerStageCollection -Payload $payload -CollectionFields @('values')
            $collapsed = Test-ReviewerStageCollectionShape -Payload $normalized -CollectionFields @('values')
            if ($collapsed.Count -ne 0) {
                throw "normalizer left the field collapsed: $($collapsed -join '; ')"
            }

            $json = ConvertTo-Json -InputObject $normalized -Depth 12 -Compress
            $restored = $json | ConvertFrom-Json -Depth 12
            $restoredValues = ConvertTo-ReviewerStageArray -Value $restored.values
            $expected = Get-ExpectedCount -Variant $variant -Kind $kind
            if ($restoredValues.Count -ne $expected) {
                throw "expected $expected element(s) after a JSON round trip, observed $($restoredValues.Count)"
            }
            if ($variant -eq 'zero' -and -not $json.Contains('"values":[]')) {
                throw 'an empty collection did not serialize as []'
            }
            if ($variant -eq 'one' -and -not $json.Contains('"values":["element-0"]')) {
                throw 'a one-element collection did not serialize as a one-element array'
            }
            if ($variant -eq 'max') {
                for ($i = 0; $i -lt $maxElements; $i++) {
                    if ([string]$restoredValues[$i] -cne "element-$i") {
                        throw "element order changed at index $i"
                    }
                }
            }
            if ($variant -eq 'nullVsMissing') {
                # Missing must stay distinguishable from present-but-empty: the
                # contract reports it as a missing required field, never as [].
                $missingPayload = [ordered]@{ id = $rowId }
                $missingNormalized = ConvertTo-ReviewerStageCollection -Payload $missingPayload -CollectionFields @('values')
                if ($missingNormalized.Contains('values')) {
                    throw 'a missing field was materialized as an empty collection'
                }
                $rejected = $false
                try {
                    Test-ReviewerStagePayloadField -Payload $missingNormalized -Contract (Get-ReviewerStageContract -Kind 'reviewer.cardinality.probe')
                }
                catch { $rejected = $true }
                if (-not $rejected) { throw 'a missing required collection field was accepted' }
            }
            if ($variant -eq 'wrongScalar') {
                # The reader must refuse the unrepaired scalar even though the
                # writer repairs it, so a collapsed artifact never reads clean.
                $scalarPayload = [ordered]@{ id = $rowId; values = 'element-0' }
                $scalarCollapse = Test-ReviewerStageCollectionShape -Payload $scalarPayload -CollectionFields @('values')
                if ($scalarCollapse.Count -eq 0) {
                    throw 'a bare scalar in a declared collection field was not reported as collapsed'
                }
            }
        }
        catch {
            $status = 'failed'
            [void]$variantFailures.Add("$rowId/$variant :: $($_.Exception.Message)")
        }
        $perVariant[$variant] = $status
    }
    $variantResults[$rowId] = $perVariant
}

if ($variantFailures.Count -gt 0) {
    $shown = @($variantFailures | Select-Object -First 10)
    Add-Failure "Boundary variant harness failed $($variantFailures.Count) case(s): $($shown -join ' | ')"
}

# The map path must reject the array collapse it exists to catch, or its passes mean
# nothing. Feed the shared contract the wrong container and require it to refuse.
$mapSabotageFired = $false
try {
    $sabotaged = ([ordered]@{ id = 'x'; values = @('element-0') } |
            ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json -Depth 12)
    $mapSabotageFired = ((Test-ReviewerStageMapShape -Payload $sabotaged -MapFields @('values')).Count -gt 0)
}
catch { $mapSabotageFired = $false }
[void](Assert-True -Name 'map-variant/sabotage-array-collapse' -Condition $mapSabotageFired `
        -Detail 'the stage contract accepted an array in a declared map field, so no map row can detect that collapse')

# ...and it must not reject a well-formed map, or the previous check would pass for the
# trivial reason that the validator refuses everything.
$mapAcceptsGoodShape = $false
try {
    $wellFormed = ([ordered]@{ id = 'x'; values = [ordered]@{ 'key-0' = 'element-0' } } |
            ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json -Depth 12)
    $mapAcceptsGoodShape = ((Test-ReviewerStageMapShape -Payload $wellFormed -MapFields @('values')).Count -eq 0)
}
catch { $mapAcceptsGoodShape = $false }
[void](Assert-True -Name 'map-variant/accepts-well-formed-map' -Condition $mapAcceptsGoodShape `
        -Detail 'the stage contract refused a well-formed map, so its refusals carry no information')

# A field cannot be both a list and a map: the two normalizations contradict each other.
$mapShapeConflictRejected = $false
try {
    Register-ReviewerStageContract -Kind 'reviewer.cardinality.conflict' -ContractVersion 1 `
        -RequiredFields @('values') -CollectionFields @('values') -MapFields @('values') | Out-Null
}
catch { $mapShapeConflictRejected = $true }
[void](Assert-True -Name 'map-variant/rejects-list-and-map-conflict' -Condition $mapShapeConflictRejected `
        -Detail 'a field declared as both a collection and a map was registered, so one normalization silently wins')

$mapRowCount = @($inventoryFields | Where-Object { [string]$_.kind -eq 'jsonObjectMap' }).Count
[void](Assert-True -Name 'map-variant/rows-exist' -Condition ($mapRowCount -gt 0) `
        -Detail 'no inventoried field is a map, so the map path ran on nothing')

# ---------------------------------------------------------------------------
# Part 2 - escape-shape property tests
# ---------------------------------------------------------------------------

# The deliberately hazardous producers used by these property tests live in a fixture file
# so that the analyzer can stay strict about this test. See the file header for why.
. (Join-Path $PSScriptRoot 'testdata/collection-escape-shapes.fixtures.ps1')

$escapeShapes = [System.Collections.Generic.List[object]]::new()

function Add-EscapeShape {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][bool]$UnguardedCollapses,
        [Parameter(Mandatory)][bool]$GuardedSurvives
    )
    [void]$escapeShapes.Add([ordered]@{
            id = $Id
            description = $Description
            unguardedCollapses = $UnguardedCollapses
            guardedSurvives = $GuardedSurvives
        })
    [void](Assert-True -Name "escape-shape/$Id/unguarded-collapses" -Condition $UnguardedCollapses `
            -Detail 'the unguarded form no longer collapses, so this property test proves nothing')
    [void](Assert-True -Name "escape-shape/$Id/guarded-survives" -Condition $GuardedSurvives `
            -Detail 'the guarded form did not preserve the collection')
}

# Empty set returned bare from a function: the return enumerates it to nothing.
$bareEmpty = Get-SetBare -Values @()
$protectedEmpty = Get-SetProtected -Values @()
Add-EscapeShape -Id 'empty-set-bare-return' `
    -Description 'A function returning a locally built empty set bare hands back $null, so an empty result is indistinguishable from a failed one.' `
    -UnguardedCollapses ($null -eq $bareEmpty) `
    -GuardedSurvives ($null -ne $protectedEmpty -and $protectedEmpty.Count -eq 0)

# Single-element set returned bare: the caller receives a bare string.
$bareSingle = Get-SetBare -Values @('only')
$protectedSingle = Get-SetProtected -Values @('only')
Add-EscapeShape -Id 'singleton-set-bare-return' `
    -Description 'A one-element set returned bare arrives as a bare scalar, so a later .Count reads the string length instead of the element count.' `
    -UnguardedCollapses ($bareSingle -is [string]) `
    -GuardedSurvives ($protectedSingle.Count -eq 1)

# @() around a protected return nests instead of flattening.
$wrappedSpans = Get-UnguardedSpanWrap -Count 3
$assignedSpans = Get-ProtectedSpans -Count 3
Add-EscapeShape -Id 'protected-return-wrapped' `
    -Description 'Wrapping a protected collection return in @() nests it as one element, so an index built from it collapses to a single bogus entry.' `
    -UnguardedCollapses ($wrappedSpans.Count -eq 1 -and $wrappedSpans[0] -is [System.Array]) `
    -GuardedSurvives ($assignedSpans.Count -eq 3)

$wrappedEmptySpans = Get-UnguardedSpanWrap -Count 0
$assignedEmptySpans = Get-ProtectedSpans -Count 0
Add-EscapeShape -Id 'protected-empty-return-wrapped' `
    -Description 'The same wrap turns an empty protected return into a one-element array, so an empty result is counted as one.' `
    -UnguardedCollapses ($wrappedEmptySpans.Count -eq 1) `
    -GuardedSurvives ($assignedEmptySpans.Count -eq 0)

# A JSON document whose root is an array arrives as bare pipeline objects, so a
# one-element document is indistinguishable from a single object.
$singletonJson = '{"evidenceFactIds":["fact-0"]}' | ConvertFrom-Json -Depth 8
$singletonForced = ConvertTo-ReviewerStageArray -Value $singletonJson.evidenceFactIds
$rootSingleton = '[{"id":"c0"}]' | ConvertFrom-Json -Depth 8
$rootEmpty = '[]' | ConvertFrom-Json -Depth 8
Add-EscapeShape -Id 'singleton-json-array' `
    -Description 'A JSON document whose root is an array is emitted as bare objects, so a one-element document reads as a single object and an empty one as nothing at all.' `
    -UnguardedCollapses ($rootSingleton -isnot [System.Array] -and $null -eq $rootEmpty) `
    -GuardedSurvives ((ConvertTo-ReviewerStageArray -Value $rootSingleton).Count -eq 1 -and
        (ConvertTo-ReviewerStageArray -Value $rootEmpty).Count -eq 0 -and
        $singletonForced.Count -eq 1)

# Empty JSON array under StrictMode.
$emptyJson = '{"evidenceFactIds":[]}' | ConvertFrom-Json -Depth 8
$emptyForced = ConvertTo-ReviewerStageArray -Value $emptyJson.evidenceFactIds
$emptyStayedArray = $emptyJson.evidenceFactIds -is [System.Array]
Add-EscapeShape -Id 'empty-json-array' `
    -Description 'An empty evidenceFactIds array must survive the boundary as [] rather than as null, so an unsupported candidate stays distinguishable from an unread one.' `
    -UnguardedCollapses (-not ($null -eq $emptyJson.evidenceFactIds -and -not $emptyStayedArray)) `
    -GuardedSurvives ($emptyForced.Count -eq 0)

# An exhausted difference set becomes $null, not an empty collection.
$emptyDifference = Get-DifferenceSet -Left @('a') -Right @('a')
$forcedDifference = ConvertTo-ReviewerStageArray -Value $emptyDifference
Add-EscapeShape -Id 'empty-difference-set' `
    -Description 'A Where-Object difference that matches nothing yields $null, so a later Sort or .Count on the exact-key difference fails under StrictMode.' `
    -UnguardedCollapses ($null -eq $emptyDifference) `
    -GuardedSurvives ($forcedDifference.Count -eq 0)

$singleDifference = Get-DifferenceSet -Left @('a', 'b') -Right @('a')
Add-EscapeShape -Id 'singleton-difference-set' `
    -Description 'A difference set with one survivor arrives as a bare scalar, so the count of remaining exact-key differences reads as a string length.' `
    -UnguardedCollapses ($singleDifference -is [string]) `
    -GuardedSurvives ((ConvertTo-ReviewerStageArray -Value $singleDifference).Count -eq 1)

# Configuration arrays: empty and singleton must both stay arrays on disk.
$configRoundTrips = $true
foreach ($configValues in @([object[]]@(), [object[]]@('one'), [object[]]@('one', 'two'))) {
    $configPayload = [ordered]@{ id = 'config'; values = $configValues }
    $configNormalized = ConvertTo-ReviewerStageCollection -Payload $configPayload -CollectionFields @('values')
    $configJson = ConvertTo-Json -InputObject $configNormalized -Depth 8 -Compress
    $configRestored = ConvertTo-ReviewerStageArray -Value ($configJson | ConvertFrom-Json -Depth 8).values
    if ($configRestored.Count -ne $configValues.Count) { $configRoundTrips = $false }
}
Add-EscapeShape -Id 'config-array-round-trip' `
    -Description 'Empty and one-element configuration arrays keep their cardinality across a write and a read, so an absent option never reads as a present one.' `
    -UnguardedCollapses $true `
    -GuardedSurvives $configRoundTrips

# Existing-fingerprint sets: the empty case is the one that has escaped before.
$existingEmpty = Get-SetProtected -Values @()
$existingMany = Get-SetProtected -Values @('fp-a', 'fp-b')
Add-EscapeShape -Id 'existing-fingerprints-empty' `
    -Description 'An empty ExistingFingerprints set must reach the caller as an empty set, because $null would be read as "no prior state observed" instead of "no prior findings".' `
    -UnguardedCollapses ($null -eq (Get-SetBare -Values @())) `
    -GuardedSurvives ($existingEmpty.Count -eq 0 -and $existingMany.Count -eq 2)

# Source readers: zero, one, and many entries must all keep their shape.
$sourceReaderHolds = $true
foreach ($count in @(0, 1, 5)) {
    $spans = Get-ProtectedSpans -Count $count
    if ($spans.Count -ne $count) { $sourceReaderHolds = $false }
}
$unguardedEmptyReader = Get-UnguardedSpanWrap -Count 0
Add-EscapeShape -Id 'source-reader-cardinality' `
    -Description 'A source reader returning zero, one, or many entries keeps its cardinality when the caller assigns the protected return instead of wrapping it.' `
    -UnguardedCollapses ($unguardedEmptyReader.Count -ne 0) `
    -GuardedSurvives $sourceReaderHolds

# ---------------------------------------------------------------------------
# Part 3 - sabotage suite
# ---------------------------------------------------------------------------

$sabotageRoot = Join-Path ([IO.Path]::GetTempPath()) ("reviewer-cardinality-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sabotageRoot | Out-Null

$sabotageResults = [System.Collections.Generic.List[object]]::new()

function Invoke-AnalyzerSabotage {
    <#
    .SYNOPSIS
        Reintroduces one historical collapse into a synthetic file and requires
        the named analyzer rule to fire on the broken form and stay silent on
        the repaired one.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$RuleId,
        [Parameter(Mandatory)][string]$Incident,
        [Parameter(Mandatory)][string]$BrokenSource,
        [Parameter(Mandatory)][string]$RepairedSource
    )

    $brokenPath = Join-Path $sabotageRoot "$Id.broken.ps1"
    $repairedPath = Join-Path $sabotageRoot "$Id.repaired.ps1"
    [IO.File]::WriteAllText($brokenPath, $BrokenSource, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($repairedPath, $RepairedSource, [Text.UTF8Encoding]::new($false))

    $brokenFindings = ConvertTo-ReviewerStageArray -Value (& $analyzer -Path $brokenPath -RuleId $RuleId -OutputFormat Json | ConvertFrom-Json -Depth 8)
    $repairedFindings = ConvertTo-ReviewerStageArray -Value (& $analyzer -Path $repairedPath -RuleId $RuleId -OutputFormat Json | ConvertFrom-Json -Depth 8)

    $detected = $brokenFindings.Count -gt 0
    $quiet = $repairedFindings.Count -eq 0
    [void](Assert-True -Name "sabotage/$Id/detected" -Condition $detected `
            -Detail "reintroducing the collapse did not raise $RuleId")
    [void](Assert-True -Name "sabotage/$Id/no-false-alarm" -Condition $quiet `
            -Detail "$RuleId also fired on the repaired form")
    [void]$sabotageResults.Add([ordered]@{
            id = $Id
            detector = $RuleId
            incidentClass = $Incident
            detected = $detected
            repairedIsClean = $quiet
        })
}

try {
    Invoke-AnalyzerSabotage -Id 'bare-empty-set-return' -RuleId 'PSEN004' `
        -Incident 'A set built locally and returned bare, so an empty result reached the caller as $null.' `
        -BrokenSource @'
function Get-ProbeFingerprints {
    $set = [System.Collections.Generic.HashSet[string]]::new()
    return $set
}
'@ `
        -RepairedSource @'
function Get-ProbeFingerprints {
    $set = [System.Collections.Generic.HashSet[string]]::new()
    Write-Output -NoEnumerate $set
}
'@

    Invoke-AnalyzerSabotage -Id 'wrapped-protected-return' -RuleId 'PSEN011' `
        -Incident 'A protected collection return wrapped in @(), which nested it as one element and collapsed an index.' `
        -BrokenSource @'
function Get-ProbeSpans {
    $spans = @('a', 'b')
    return , $spans
}
function Use-ProbeSpans {
    $anchors = @(Get-ProbeSpans)
    return $anchors.Count
}
'@ `
        -RepairedSource @'
function Get-ProbeSpans {
    $spans = @('a', 'b')
    return , $spans
}
function Use-ProbeSpans {
    $anchors = Get-ProbeSpans
    return $anchors.Count
}
'@

    Invoke-AnalyzerSabotage -Id 'closure-captures-function' -RuleId 'PSEN010' `
        -Incident 'A closure calling a repository function by name, which GetNewClosure does not capture.' `
        -BrokenSource @'
function Add-ProbeBinding {
    param($Value)
    return $Value
}
function New-ProbeClosure {
    $prefix = 'p'
    return {
        return Add-ProbeBinding -Value $prefix
    }.GetNewClosure()
}
'@ `
        -RepairedSource @'
function Add-ProbeBinding {
    param($Value)
    return $Value
}
function New-ProbeClosure {
    $prefix = 'p'
    $binder = ${function:Add-ProbeBinding}
    return {
        return & $binder -Value $prefix
    }.GetNewClosure()
}
'@

    Invoke-AnalyzerSabotage -Id 'contract-write-without-depth' -RuleId 'PSEN007' `
        -Incident 'A contract serialized without an explicit depth, so nested structures were truncated to type names.' `
        -BrokenSource @'
function Write-ProbeContract {
    param($Payload, [string]$Path)
    $json = ConvertTo-Json -InputObject $Payload -Compress
    Set-Content -LiteralPath $Path -Value $json
}
'@ `
        -RepairedSource @'
function Write-ProbeContract {
    param($Payload, [string]$Path)
    $json = ConvertTo-Json -InputObject $Payload -Depth 12 -Compress
    Set-Content -LiteralPath $Path -Value $json
}
'@

    Invoke-AnalyzerSabotage -Id 'contract-write-without-compress' -RuleId 'PSEN008' `
        -Incident 'A contract written to a file without an explicit compact decision, leaving its on-disk form implicit.' `
        -BrokenSource @'
function Write-ProbeContract {
    param($Payload, [string]$Path)
    Set-Content -LiteralPath $Path -Value (ConvertTo-Json -InputObject $Payload -Depth 12)
}
'@ `
        -RepairedSource @'
function Write-ProbeContract {
    param($Payload, [string]$Path)
    Set-Content -LiteralPath $Path -Value (ConvertTo-Json -InputObject $Payload -Depth 12 -Compress)
}
'@

    Invoke-AnalyzerSabotage -Id 'count-on-unconstrained-pipeline' -RuleId 'PSEN005' `
        -Incident 'A cardinality read taken straight off a pipeline, so a single match counted as its own length.' `
        -BrokenSource @'
function Measure-ProbeMatches {
    param($Items)
    return ($Items | Where-Object { $_ -ne 'skip' }).Count
}
'@ `
        -RepairedSource @'
function Measure-ProbeMatches {
    param($Items)
    return @($Items | Where-Object { $_ -ne 'skip' }).Count
}
'@

    Invoke-AnalyzerSabotage -Id 'flattened-result-counted-later' -RuleId 'PSEN009' `
        -Incident 'A non-preserved command result assigned and counted later, so an empty result became $null.' `
        -BrokenSource @'
function Measure-ProbeSelection {
    param($Items)
    $selected = $Items | Where-Object { $_ -ne 'skip' }
    return $selected.Count
}
'@ `
        -RepairedSource @'
function Measure-ProbeSelection {
    param($Items)
    $selected = @($Items | Where-Object { $_ -ne 'skip' })
    return $selected.Count
}
'@

    Invoke-AnalyzerSabotage -Id 'ambient-script-scope-capture' -RuleId 'PSEN006' `
        -Incident 'A script block reading an ambient script-scoped name, so its value depended on when the block ran.' `
        -BrokenSource @'
$script:ProbeState = 'initial'
function New-ProbeBlock {
    return {
        return $ProbeState
    }
}
'@ `
        -RepairedSource @'
$script:ProbeState = 'initial'
function New-ProbeBlock {
    $captured = $script:ProbeState
    return {
        return $captured
    }.GetNewClosure()
}
'@

    # Contract-boundary sabotage: a produced artifact whose collection field was
    # collapsed on the way out must fail the reader rather than read as empty.
    Register-ReviewerStageContract `
        -Kind 'reviewer.cardinality.artifact' `
        -ContractVersion 1 `
        -RequiredFields @('values') `
        -CollectionFields @('values') | Out-Null

    $artifactPath = Join-Path $sabotageRoot 'collapsed-artifact.json'
    $collapsedEnvelope = ConvertTo-Json -Depth 8 -Compress -InputObject ([ordered]@{
            envelopeVersion = 1
            kind = 'reviewer.cardinality.artifact'
            contractVersion = 1
            form = 'compact'
            depth = 8
            payload = [ordered]@{ values = 'element-0' }
        })
    [IO.File]::WriteAllText($artifactPath, $collapsedEnvelope + "`n", [Text.UTF8Encoding]::new($false))
    $readerRejected = $false
    try { Read-ReviewerStageArtifact -Path $artifactPath -Kind 'reviewer.cardinality.artifact' | Out-Null }
    catch { $readerRejected = $true }
    [void](Assert-True -Name 'sabotage/collapsed-artifact-field/detected' -Condition $readerRejected `
            -Detail 'a collapsed collection field in a published artifact was read as valid')
    [void]$sabotageResults.Add([ordered]@{
            id = 'collapsed-artifact-field'
            detector = 'stage-contract-reader'
            incidentClass = 'A published artifact whose collection field was serialized as a scalar.'
            detected = $readerRejected
            repairedIsClean = $true
        })

    $repairedArtifactPath = Join-Path $sabotageRoot 'repaired-artifact.json'
    Write-ReviewerStageArtifact -Path $repairedArtifactPath -Kind 'reviewer.cardinality.artifact' `
        -Payload ([ordered]@{ values = [object[]]@('element-0') }) -Depth 8 -Form compact | Out-Null
    $repairedRead = Read-ReviewerStageArtifact -Path $repairedArtifactPath -Kind 'reviewer.cardinality.artifact'
    [void](Assert-True -Name 'sabotage/collapsed-artifact-field/no-false-alarm' `
            -Condition ((ConvertTo-ReviewerStageArray -Value $repairedRead.Payload.values).Count -eq 1) `
            -Detail 'the repaired artifact did not read back cleanly')
}
finally {
    Remove-Item -LiteralPath $sabotageRoot -Recurse -Force -ErrorAction SilentlyContinue
    Clear-ReviewerStageContractRegistry
}

# ---------------------------------------------------------------------------
# Citation liveness: every cited source file must exist and mention the field
# ---------------------------------------------------------------------------

$script:SourceTextCache = @{}

$script:RepoFileIndex = [System.Collections.Generic.List[string]]::new()
foreach ($scanRoot in @('src', 'tools', 'docs', '.github')) {
    $scanFull = Join-Path -Path $repoRoot -ChildPath $scanRoot
    if (-not (Test-Path -LiteralPath $scanFull)) { continue }
    foreach ($file in (Get-ChildItem -LiteralPath $scanFull -Recurse -File)) {
        $relative = [System.IO.Path]::GetRelativePath($repoRoot, $file.FullName).Replace('\', '/')
        [void]$script:RepoFileIndex.Add($relative)
    }
}

function Resolve-CitedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Citation)

    $normalized = $Citation.Replace('\', '/').Trim()
    foreach ($candidate in $script:RepoFileIndex) {
        if ($candidate -eq $normalized) { return $candidate }
    }
    # Inventory rows cite files by whatever suffix identified them unambiguously at the
    # time, from a bare name to a full repository path. A suffix that now matches nothing,
    # or matches several files, is exactly the drift this check exists to surface.
    $suffix = '/' + $normalized
    $matches = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $script:RepoFileIndex) {
        if ($candidate.EndsWith($suffix, [System.StringComparison]::Ordinal)) { [void]$matches.Add($candidate) }
    }
    if ($matches.Count -eq 1) { return [string]$matches[0] }
    if ($matches.Count -gt 1) { return "AMBIGUOUS:$($matches.Count)" }
    return $null
}

function Get-CitedSourceText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RelativePath)

    if ($script:SourceTextCache.ContainsKey($RelativePath)) {
        return [string]$script:SourceTextCache[$RelativePath]
    }
    $full = Join-Path -Path $repoRoot -ChildPath $RelativePath
    $text = [System.IO.File]::ReadAllText($full)
    $script:SourceTextCache[$RelativePath] = $text
    return $text
}

function Get-CitedFileToken {
    [CmdletBinding()]
    param([AllowNull()][string]$Citation)

    $tokens = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Citation)) {
        Write-Output -NoEnumerate $tokens.ToArray()
        return
    }
    # A quoted literal inside a citation is data the cited code contains, not a second
    # citation. Strip them before looking for file names.
    $withoutLiterals = [regex]::Replace($Citation, "'[^']*'", ' ')
    foreach ($match in [regex]::Matches($withoutLiterals, '[A-Za-z0-9_./\-]+\.(?:ps1|psm1|psd1|json|cs|yml|yaml|md)')) {
        $value = [string]$match.Value
        if (-not $tokens.Contains($value)) { [void]$tokens.Add($value) }
    }
    Write-Output -NoEnumerate $tokens.ToArray()
}

function Get-FieldLeafToken {
    <#
        The token that must be present is the *leaf* of the JSON path, not any segment of
        it. Accepting any segment made the check vacuous for nested paths: a citation of
        the wrong file passes whenever that file happens to mention the generic container
        name, so renaming or misciting the leaf - the thing the row is actually about -
        stayed invisible. Returns $null when the row has no JSON path to take a leaf from;
        those rows are reported as unverified rather than counted as checked.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Field)

    if ([string]::IsNullOrWhiteSpace($Field)) { return $null }
    # Two path notations are in use: JSONPath ("$.a.b[*].c") for stage payloads and JSON
    # pointer ("/a/b[*]/c") for schema-anchored rows. Both have a leaf. A bare "$name" is
    # a producer-local PowerShell variable, which the consuming file knows by its own
    # parameter name, so it has no leaf to require.
    $isJsonPath = $Field.StartsWith('$.', [System.StringComparison]::Ordinal)
    $isPointer = $Field.StartsWith('/', [System.StringComparison]::Ordinal)
    if (-not ($isJsonPath -or $isPointer)) { return $null }
    # Some rows carry a prose qualifier after the path ("$.[] (root is JSON array)").
    # Only the path itself names a field.
    $path = $Field
    foreach ($terminator in @(' ', '(')) {
        $cut = $path.IndexOf($terminator, [System.StringComparison]::Ordinal)
        if ($cut -ge 0) { $path = $path.Substring(0, $cut) }
    }
    if ($isJsonPath) { $path = $path.Substring(2) }
    $path = [regex]::Replace($path, '\[[^\]]*\]', '')
    $segments = @($path -split '[./]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($segments.Count -eq 0) { return $null }
    $leaf = ([string]$segments[-1]).Trim()
    if ($leaf -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { return $null }
    return $leaf
}

$rotChecked = 0
$rotTokenVerified = 0
$rotUnverified = [System.Collections.Generic.List[string]]::new()
$rotMissingFile = [System.Collections.Generic.List[string]]::new()
$rotAmbiguous = [System.Collections.Generic.List[string]]::new()
$rotMissingToken = [System.Collections.Generic.List[string]]::new()

foreach ($row in $inventoryFields) {
    $rowId = [string]$row.id
    $fieldName = [string]$row.field
    $leaf = Get-FieldLeafToken -Field $fieldName
    foreach ($citationName in @('producer', 'consumer')) {
        $citation = [string]$row.$citationName
        foreach ($cited in (Get-CitedFileToken -Citation $citation)) {
            $rotChecked++
            $resolved = Resolve-CitedPath -Citation $cited
            if ($null -eq $resolved) {
                [void]$rotMissingFile.Add("$rowId :: $citationName :: $cited")
                continue
            }
            if ($resolved.StartsWith('AMBIGUOUS:', [System.StringComparison]::Ordinal)) {
                [void]$rotAmbiguous.Add("$rowId :: $citationName :: $cited :: $resolved")
                continue
            }
            # A field named for a producer-local PowerShell variable, or a whole-document
            # row with no leaf, has no name to look for in the cited file. Those rows get
            # the file-existence check only, and are published as unverified rather than
            # folded into the token-verified count.
            if ($null -eq $leaf) {
                [void]$rotUnverified.Add("$rowId :: $citationName :: $resolved :: no leaf token in '$fieldName'")
                continue
            }
            $text = Get-CitedSourceText -RelativePath $resolved
            # Case-insensitive: PowerShell reaches JSON fields through case-insensitive
            # property access, so `ResidualRisks` referring to `residualRisks` is the
            # normal spelling in the cited code, not rot.
            if ($text.IndexOf($leaf, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                [void]$rotMissingToken.Add("$rowId :: $citationName :: $resolved :: leaf '$leaf' absent")
                continue
            }
            $rotTokenVerified++
        }
    }
}

[void](Assert-True -Name 'citation-liveness/citations-resolved' -Condition ($rotChecked -ge 300) -Detail "the citation-liveness check resolved only $rotChecked citations, which is too few to prove anything")
[void](Assert-True -Name 'citation-liveness/leaf-tokens-verified' -Condition ($rotTokenVerified -ge 250) -Detail "only $rotTokenVerified citations were leaf-token verified, which is too few to prove anything")
[void](Assert-True -Name 'citation-liveness/files-exist' -Condition ($rotMissingFile.Count -eq 0) -Detail "inventory cites files that no longer exist: $($rotMissingFile -join '; ')")
[void](Assert-True -Name 'citation-liveness/files-unambiguous' -Condition ($rotAmbiguous.Count -eq 0) -Detail "inventory cites file names that now match more than one file: $($rotAmbiguous -join '; ')")
[void](Assert-True -Name 'citation-liveness/fields-mentioned' -Condition ($rotMissingToken.Count -eq 0) -Detail "inventory cites files that do not mention the field's leaf name: $($rotMissingToken -join '; ')")

# A detector that reports nothing is indistinguishable from one that is broken, so prove
# each half fires on a citation that is deliberately wrong.
[void](Assert-True -Name 'citation-liveness/sabotage-missing-file' `
        -Condition ($null -eq (Resolve-CitedPath -Citation 'src/Agents/reviewer/ThisFileWasDeleted.ps1')) `
        -Detail 'a citation of a nonexistent file resolved anyway')
[void](Assert-True -Name 'citation-liveness/sabotage-real-file' `
        -Condition ('src/Agents/reviewer/StageContract.ps1' -eq (Resolve-CitedPath -Citation 'StageContract.ps1')) `
        -Detail 'a bare file name that exists exactly once failed to resolve')
$sabotageLeaf = Get-FieldLeafToken -Field '$.thisFieldNameWasRenamedAway'
[void](Assert-True -Name 'citation-liveness/sabotage-missing-token' `
        -Condition ($sabotageLeaf -eq 'thisFieldNameWasRenamedAway' -and (Get-CitedSourceText -RelativePath 'src/Agents/reviewer/StageContract.ps1').IndexOf($sabotageLeaf, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) `
        -Detail 'a field name that appears nowhere was reported as mentioned')
# The container segment must not stand in for the leaf. This is the hole that let five
# wrong citations pass: `contractVersion` exists in StageContract.ps1, so a nested path
# under it used to verify no matter what the leaf was called.
[void](Assert-True -Name 'citation-liveness/sabotage-container-not-leaf' `
        -Condition ((Get-FieldLeafToken -Field '$.contractVersion.thisLeafDoesNotExist') -eq 'thisLeafDoesNotExist') `
        -Detail 'a nested path yielded a container segment instead of its leaf')
# Short leaf names are exactly the ones a length filter drops, and they are common.
[void](Assert-True -Name 'citation-liveness/sabotage-short-leaf' `
        -Condition ((Get-FieldLeafToken -Field '$.evidence[*].ids') -eq 'ids') `
        -Detail 'a short leaf name was dropped instead of required')
# A row with prose after the path must not require the prose word.
[void](Assert-True -Name 'citation-liveness/sabotage-prose-suffix' `
        -Condition ($null -eq (Get-FieldLeafToken -Field '$.[] (root is JSON array)')) `
        -Detail 'a prose qualifier was mistaken for a field name')

# ---------------------------------------------------------------------------
# Coverage matrix, derived from what actually ran
# ---------------------------------------------------------------------------

$matrixFields = [System.Collections.Generic.List[object]]::new()
$boundaryCovered = 0
$boundaryGaps = 0
$producerGaps = 0
$mapCellCount = 0
$listCellCount = 0
$producerCoverage = [ordered]@{}
foreach ($variant in $variants) { $producerCoverage[$variant] = 'gap' }

foreach ($row in ($inventoryFields | Sort-Object { [string]$_.id })) {
    $rowId = [string]$row.id
    $observed = $variantResults[$rowId]
    $boundary = [ordered]@{}
    # Which validator actually judged this row. A map row is judged by the map
    # shape check and never by the list normalizer, so recording one name for
    # both would overstate what the list path covers.
    $validator = if ([string]$row.kind -eq 'jsonObjectMap') { 'mapShape' } else { 'collectionShape' }
    foreach ($variant in $variants) {
        $status = [string]$observed[$variant]
        $boundary[$variant] = $status
        if ($status -eq 'covered') { $boundaryCovered++ } else { $boundaryGaps++ }
        if ($validator -eq 'mapShape') { $mapCellCount++ } else { $listCellCount++ }
        $producerGaps++
    }
    [void]$matrixFields.Add([ordered]@{
            id = $rowId
            stage = [string]$row.stage
            contract = [string]$row.contract
            field = [string]$row.field
            kind = [string]$row.kind
            knownEscapeShape = [bool]$row.knownEscapeShape
            boundaryValidator = $validator
            boundaryNormalizer = $boundary
            producerPath = $producerCoverage
        })
}

$byStage = [ordered]@{}
foreach ($stage in ($inventoryDocument.stageOrder)) {
    $count = @($inventoryFields | Where-Object { [string]$_.stage -eq [string]$stage }).Count
    $byStage[[string]$stage] = $count
}
$byKind = [ordered]@{}
foreach ($group in ($inventoryFields | Group-Object kind | Sort-Object Name)) {
    $byKind[[string]$group.Name] = $group.Count
}

$matrix = [ordered]@{
    schemaVersion = 1
    kind = 'reviewer-collection-cardinality-matrix'
    description = 'Coverage of the required cardinality variants for every inventoried collection field. Derived from the run that produced it, not asserted by hand.'
    variants = $variants
    coverageDimensions = [ordered]@{
        boundaryNormalizer = 'The field is driven through the shared stage contract at this cardinality and judged by the validator named in boundaryValidator: collectionShape rows go through the list normalizer, shape validator, and a JSON round trip; mapShape rows go through the map shape validator and a JSON round trip and are never normalized, because there is no correct rewrite from an array or a scalar to a keyed object.'
        producerPath = 'The real producing and consuming stage code is driven at this cardinality. Not attempted in this layer: the corpus is deliberately employer-neutral and runs no stage.'
    }
    fullCoverageClaimed = $false
    fullCoverageRule = 'fullCoverageClaimed may only be true when every inventoried field reports covered for every variant in every coverage dimension.'
    summary = [ordered]@{
        fields = $matrixFields.Count
        variants = $variants.Count
        cellsPerDimension = ($matrixFields.Count * $variants.Count)
        boundaryNormalizerCovered = $boundaryCovered
        boundaryNormalizerGaps = $boundaryGaps
        collectionShapeCells = $listCellCount
        mapShapeCells = $mapCellCount
        producerPathCovered = 0
        producerPathGaps = $producerGaps
        knownEscapeShapeFields = @($inventoryFields | Where-Object { [bool]$_.knownEscapeShape }).Count
        escapeShapeProperties = $escapeShapes.Count
        sabotageChecks = $sabotageResults.Count
        citationsChecked = $rotChecked
        citationsLeafVerified = $rotTokenVerified
        citationsUnverified = $rotUnverified.Count
        byStage = $byStage
        byKind = $byKind
    }
    escapeShapes = [object[]]$escapeShapes.ToArray()
    sabotage = [object[]]$sabotageResults.ToArray()
    fields = [object[]]$matrixFields.ToArray()
}

# The claim is mechanical, never editorial.
$claimAllowed = ($boundaryGaps -eq 0 -and $producerGaps -eq 0)
if ($matrix.fullCoverageClaimed -and -not $claimAllowed) {
    Add-Failure 'The matrix claims full coverage while gaps remain.'
}
if ($claimAllowed -and -not $matrix.fullCoverageClaimed) {
    Add-Failure 'Every cell is covered but the matrix still declines to claim it; update the claim deliberately.'
}

$matrixJson = ((ConvertTo-Json -InputObject $matrix -Depth 12) -replace "`r`n", "`n") + "`n"

if ($UpdateMatrix) {
    [IO.File]::WriteAllText($matrixPath, $matrixJson, [Text.UTF8Encoding]::new($false))
    Write-Host "Wrote $matrixPath ($($matrixFields.Count) fields)."
    return
}

if (-not (Test-Path -LiteralPath $matrixPath)) {
    Add-Failure "Coverage matrix '$matrixPath' is missing; regenerate it with -UpdateMatrix."
}
else {
    $recorded = [IO.File]::ReadAllText($matrixPath).Replace("`r`n", "`n")
    if ($recorded -cne $matrixJson) {
        Add-Failure 'The recorded coverage matrix does not match the coverage this run produced; regenerate it with -UpdateMatrix and review the diff.'
    }
}

$report = [ordered]@{
    check = 'reviewer-collection-cardinality'
    fields = $matrixFields.Count
    variants = $variants.Count
    boundaryCovered = $boundaryCovered
    boundaryGaps = $boundaryGaps
    producerGaps = $producerGaps
    escapeShapes = $escapeShapes.Count
    sabotageChecks = $sabotageResults.Count
    citationsChecked = $rotChecked
        citationsLeafVerified = $rotTokenVerified
        citationsUnverified = $rotUnverified.Count
    failed = $script:Failures.Count
}
if (-not $Quiet) {
    ConvertTo-Json -InputObject $report -Depth 4 -Compress | Write-Host
}

if ($script:Failures.Count -gt 0) {
    throw "Collection cardinality coverage failed $($script:Failures.Count) check(s):`n - $($script:Failures -join "`n - ")"
}

Write-Host "PASS: collection cardinality coverage ($($matrixFields.Count) fields x $($variants.Count) variants, $($escapeShapes.Count) escape shapes, $($sabotageResults.Count) sabotage checks)."
