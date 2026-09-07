#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Validates and enumerates the private Gate 0/1 benchmark bundle in place.

.DESCRIPTION
    The bundle is never copied or written. Files are identified by content hash,
    not by a caller-controlled filename. The corrected ownership overlay is the
    authority for whether a recommended fixture may execute.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [switch]$AsJson,
    [string[]]$FixtureId = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$required = [ordered]@{
    benchmarkPlanV2 = '66e2ee2a732a3b36eb435c6d3593ffde3e4f958b591fc5e0ce479e7aa04b8fb4'
    fixtureIndex = '976d2c290686944341a5d6ec6201bec5e7d0e679908f72aef6ce8a45b6097d08'
}
$ownershipOverlaySha256 = 'e63a7c217a5ee23996b2f961abf5f71c7a33ceb73f3811ace7af4f391ae1c089'

function Get-PropertyValue {
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($property) { return $property.Value }
    }
    return $null
}

function Get-FixtureId {
    param($Value)
    if ($Value -is [string]) { return [string]$Value }
    return [string](Get-PropertyValue $Value @('fixtureId', 'id', 'name'))
}

function Find-Records {
    param($Document, [string[]]$Names)
    foreach ($name in $Names) {
        $value = Get-PropertyValue $Document @($name)
        if ($null -ne $value) { return @($value) }
    }
    foreach ($containerName in @('benchmark', 'plan', 'index', 'data', 'recommendation')) {
        $container = Get-PropertyValue $Document @($containerName)
        if ($container) {
            foreach ($name in $Names) {
                $value = Get-PropertyValue $container @($name)
                if ($null -ne $value) { return @($value) }
            }
        }
    }
    return @()
}

function Find-DigestReferences {
    param($Value, [string]$ExpectedSha256, [string]$JsonPath = '$')
    $found = [Collections.Generic.List[object]]::new()
    if ($Value -is [pscustomobject]) {
        $digest = $null
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -cmatch '(?i)(sha256|digest)$' -and
                [string]$property.Value -ceq $ExpectedSha256) {
                $digest = [string]$property.Value
                break
            }
        }
        if ($digest) {
            $referencePath = [string](Get-PropertyValue $Value @(
                    'path', 'file', 'relativePath', 'relativeFile', 'sourcePath',
                    'artifactPath', 'payloadPath', 'overlayPath', 'indexPath',
                    'source', 'correctedOwnershipOverlay', 'ownershipOverlay'
                ))
            $found.Add([pscustomobject]@{ JsonPath = $JsonPath; ReferencePath = $referencePath })
        }
        foreach ($property in $Value.PSObject.Properties) {
            foreach ($nested in @(Find-DigestReferences $property.Value $ExpectedSha256 "$JsonPath.$($property.Name)")) {
                $found.Add($nested)
            }
        }
    }
    elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        $index = 0
        foreach ($item in $Value) {
            foreach ($nested in @(Find-DigestReferences $item $ExpectedSha256 "$JsonPath[$index]")) {
                $found.Add($nested)
            }
            $index++
        }
    }
    return @($found)
}

function Test-ExecutableRecord {
    param($Record)
    $blockedValue = Get-PropertyValue $Record @('blocked', 'isBlocked')
    if ($blockedValue -is [bool] -and $blockedValue) { return $false }
    if ($blockedValue -is [string] -and $blockedValue -cmatch '^(?i:true|yes|blocked)$') { return $false }
    $executableValue = Get-PropertyValue $Record @('executable', 'isExecutable', 'executableFixture')
    if ($executableValue -is [bool]) { return $executableValue }
    if ($executableValue -is [string]) { return $executableValue -cmatch '^(?i:true|yes|executable)$' }
    $status = [string](Get-PropertyValue $Record @(
            'executionStatus', 'status', 'disposition', 'classification', 'executionClass'
        ))
    return $status -cin @('executable', 'recommended', 'ready', 'allowed')
}

$resolvedRoot = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    throw "External bundle root '$Root' is not a directory."
}
$repositoryRoot = (Resolve-Path -LiteralPath (Split-Path $PSScriptRoot -Parent)).Path
$rootWithSeparator = $repositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if ($resolvedRoot -ceq $repositoryRoot -or $resolvedRoot.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The private bundle root must be outside this repository; private benchmark data must never be copied into the working tree.'
}

$matches = @{}
foreach ($name in $required.Keys) { $matches[$name] = [Collections.Generic.List[string]]::new() }
foreach ($file in Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse -Force) {
    $digest = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach ($name in $required.Keys) {
        if ($digest -ceq $required[$name]) { $matches[$name].Add($file.FullName) }
    }
}

$documents = @{}
foreach ($name in $required.Keys) {
    if ($matches[$name].Count -ne 1) {
        throw "Mandatory $name SHA-256 $($required[$name]) matched $($matches[$name].Count) files; exactly one is required."
    }
    try {
        $documents[$name] = Get-Content -LiteralPath $matches[$name][0] -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    catch { throw "Mandatory $name is not valid JSON: $($_.Exception.Message)" }
}

$overlayReferences = @(
    Find-DigestReferences $documents.benchmarkPlanV2 $ownershipOverlaySha256
    Find-DigestReferences $documents.fixtureIndex $ownershipOverlaySha256
)
$referencedPaths = @($overlayReferences |
        Where-Object { $_.ReferencePath } |
        ForEach-Object { [string]$_.ReferencePath } |
        Sort-Object -Unique)
if ($overlayReferences.Count -eq 0) {
    throw "The mandatory corrected ownership overlay SHA-256 $ownershipOverlaySha256 is not bound by benchmark-plan-v2 or fixture-index."
}
if ($referencedPaths.Count -gt 1) {
    throw "The corrected ownership overlay digest resolves to multiple payload paths; found $($referencedPaths.Count)."
}
$overlayPath = if ($referencedPaths.Count -eq 1) {
    if ([IO.Path]::IsPathRooted($referencedPaths[0])) {
        [IO.Path]::GetFullPath($referencedPaths[0])
    } else {
        [IO.Path]::GetFullPath((Join-Path $resolvedRoot $referencedPaths[0]))
    }
} else { '' }
$bundlePrefix = $resolvedRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$overlayMaterialized = ($overlayPath -and (Test-Path -LiteralPath $overlayPath -PathType Leaf))
if (-not $overlayMaterialized) {
    throw "The digest-bound corrected ownership overlay is not materialized at its recorded path."
}
if ($overlayMaterialized) {
    $overlayDigest = (Get-FileHash -LiteralPath $overlayPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($overlayDigest -cne $ownershipOverlaySha256) {
        throw "Corrected ownership overlay payload SHA-256 mismatch: expected $ownershipOverlaySha256, got $overlayDigest."
    }
    try {
        $documents.correctedOwnershipOverlayIndex = Get-Content -LiteralPath $overlayPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    catch { throw "Corrected ownership overlay payload is not valid JSON: $($_.Exception.Message)" }
}

$recommended = @(Find-Records $documents.benchmarkPlanV2 @(
        'recommendedExecutableFixtures', 'recommendedExecutableFixtureIds',
        'recommendedFixtures', 'recommendedFixtureIds', 'recommendedFinalSet', 'recommended20', 'fixtures'
    ))
$recommendedIds = @($recommended | ForEach-Object { Get-FixtureId $_ } | Where-Object { $_ })
if ($recommended.Count -ne 20 -or $recommendedIds.Count -ne 20 -or
    @($recommendedIds | Sort-Object -Unique).Count -ne 20) {
    throw "benchmark-plan-v2 recommendedFinalSet must contain exactly 20 distinct fixture records; found $($recommended.Count)."
}
foreach ($record in $recommended) {
    if ($record -isnot [string] -and -not (Test-ExecutableRecord $record)) {
        throw "benchmark-plan-v2 recommendedFinalSet fixture '$(Get-FixtureId $record)' is not an executable record."
    }
}
$indexRecommended = @(Find-Records $documents.fixtureIndex @(
        'recommendedExecutableFixtures', 'recommendedExecutableFixtureIds',
        'recommendedFixtures', 'recommendedFixtureIds', 'recommendedFinalSet', 'recommended20'
    ))
$indexRecommendedIds = @($indexRecommended | ForEach-Object { Get-FixtureId $_ } | Where-Object { $_ })
if ($indexRecommended.Count -ne 20 -or $indexRecommendedIds.Count -ne 20 -or
    @($indexRecommendedIds | Sort-Object -Unique).Count -ne 20) {
    throw "fixture-index recommendedFinalSet must contain exactly 20 distinct fixture records; found $($indexRecommended.Count)."
}
foreach ($record in $indexRecommended) {
    if ($record -isnot [string] -and -not (Test-ExecutableRecord $record)) {
        throw "fixture-index recommendedFinalSet fixture '$(Get-FixtureId $record)' is not an executable record."
    }
}
if ((@($recommendedIds | Sort-Object) -join "`n") -cne (@($indexRecommendedIds | Sort-Object) -join "`n")) {
    throw 'benchmark-plan-v2 and fixture-index recommendedFinalSet records disagree.'
}

$indexRecords = @(Find-Records $documents.fixtureIndex @('records', 'fixtures', 'entries', 'items'))
$rows = foreach ($id in $recommendedIds) {
    $index = @($indexRecords | Where-Object { (Get-FixtureId $_) -ceq $id })
    if ($index.Count -ne 1) { throw "Recommended fixture '$id' has $($index.Count) fixture-index records; exactly one is required." }

    $blockedValue = Get-PropertyValue $index[0] @('blocked', 'isBlocked')
    $blocked = [bool]$blockedValue
    $status = [string](Get-PropertyValue $index[0] @('executionStatus', 'status', 'disposition'))
    $executableValue = Get-PropertyValue $index[0] @('executable', 'isExecutable')
    $executable = if ($null -ne $executableValue) {
        if ($executableValue -is [bool]) { $executableValue }
        elseif ($executableValue -is [string] -and $executableValue -cmatch '^(?i:true|yes|executable)$') { $true }
        elseif ($executableValue -is [string] -and $executableValue -cmatch '^(?i:false|no|blocked)$') { $false }
        else { throw "Recommended fixture '$id' has an unsupported executable value." }
    } else {
        $true
    }
    if ($blocked -or -not $executable -or $status -cin @('blocked', 'non-executable', 'nonExecutable', 'excluded')) {
        throw "Recommended fixture '$id' is blocked or non-executable under the corrected ownership overlay."
    }
    $fixtureRelative = [string](Get-PropertyValue $index[0] @('file', 'path', 'relativePath'))
    $fixtureSha256 = [string](Get-PropertyValue $index[0] @('fileSha256', 'sha256', 'digest'))
    if (-not $fixtureRelative -or $fixtureSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Recommended fixture '$id' has no bounded file path and SHA-256."
    }
    $fixturePath = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $fixtureRelative))
    if (-not $fixturePath.StartsWith($bundlePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
        throw "Recommended fixture '$id' does not resolve to a file inside the private bundle."
    }
    $actualFixtureSha256 = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualFixtureSha256 -cne $fixtureSha256) {
        throw "Recommended fixture '$id' SHA-256 mismatch."
    }
    try { $null = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100 -ErrorAction Stop }
    catch { throw "Recommended fixture '$id' is not valid JSON: $($_.Exception.Message)" }
    [pscustomobject][ordered]@{
        fixtureId = $id
        executable = $true
        ownership = Get-PropertyValue $index[0] @('owner', 'ownership', 'ownerId')
    }
}

if ($FixtureId.Count -gt 0) {
    $unknown = @($FixtureId | Where-Object { @($rows.fixtureId) -cnotcontains $_ })
    if ($unknown.Count -gt 0) {
        throw "Requested fixture(s) are not recommended executable fixtures: $($unknown -join ', ')."
    }
    $rows = @($rows | Where-Object { $FixtureId -ccontains $_.fixtureId })
}

$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    kind = 'reviewer-external-bundle-inventory'
    root = $resolvedRoot
    verifiedDigests = $required
    correctedOwnershipOverlaySha256 = $ownershipOverlaySha256
    correctedOwnershipOverlayMaterialized = [bool]$overlayMaterialized
    recommendedExecutableCount = 20
    fixtures = @($rows)
    writesPerformed = 0
}
if ($AsJson) { $result | ConvertTo-Json -Depth 8 -Compress }
else { $rows | Format-Table fixtureId, executable, ownership -AutoSize }
