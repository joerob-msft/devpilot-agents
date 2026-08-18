#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Measures the boundary-hardening analyzer rules and gates newly introduced
    violations against a reviewed baseline.

.DESCRIPTION
    Two independent checks, both blocking:

      1. Fixture measurement. Every labeled fixture in
         tools/testdata/boundary-hardening-analyzer.fixtures.ps1 must be
         classified as its label says. A rule that stops detecting its own
         hazard, or starts reporting its own counterexample, fails here.

      2. Repository gate. The analyzer runs over src/ and tools/, and every
         finding is fingerprinted by rule, file, and normalized snippet. A
         fingerprint that is not in tools/testdata/powershell-boundary-baseline.v1.json,
         or that occurs more often than the baseline records, is a NEW
         violation and fails the run. Findings already in the baseline are
         reported as explicit, quantified debt and do not fail.

    The baseline is a record of debt, not an approval of it. Regenerate it with
    -UpdateBaseline only alongside a reviewed explanation of what changed.

.EXAMPLE
    ./tools/Test-PowerShellBoundaryHardening.ps1

.EXAMPLE
    ./tools/Test-PowerShellBoundaryHardening.ps1 -UpdateBaseline
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$UpdateBaseline
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$analyzer = Join-Path $PSScriptRoot 'Find-PowerShellEmptyNullHazard.ps1'
$fixture = Join-Path $PSScriptRoot 'testdata\boundary-hardening-analyzer.fixtures.ps1'
$baselinePath = Join-Path $PSScriptRoot 'testdata\powershell-boundary-baseline.v1.json'
$utf8 = [Text.UTF8Encoding]::new($false)

# Fixture files exist to contain the hazards, so scanning them would record
# every deliberate counterexample as repository debt.
$excludedRelativePaths = @(
    'tools/testdata/empty-null-analyzer.fixtures.ps1',
    'tools/testdata/boundary-hardening-analyzer.fixtures.ps1',
    'tools/testdata/collection-escape-shapes.fixtures.ps1'
)

$boundaryRules = @('PSEN004', 'PSEN005', 'PSEN006', 'PSEN007', 'PSEN008', 'PSEN009', 'PSEN010', 'PSEN011')

# ---------------------------------------------------------------- measurement

$cases = @(
    @{ Label = 'Positive-BareCollectionReturn'; Positive = $true; RuleId = 'PSEN004' }
    @{ Label = 'Positive-BareCollectionTrailingExpression'; Positive = $true; RuleId = 'PSEN004' }
    @{ Label = 'Negative-NoEnumerateCollectionReturn'; Positive = $false; RuleId = 'PSEN004' }
    @{ Label = 'Negative-CommaProtectedCollectionReturn'; Positive = $false; RuleId = 'PSEN004' }
    @{ Label = 'Negative-MaterializedCollectionReturn'; Positive = $false; RuleId = 'PSEN004' }
    @{ Label = 'Positive-CountOnUnconstrainedPipeline'; Positive = $true; RuleId = 'PSEN005' }
    @{ Label = 'Positive-IndexOnUnconstrainedPipeline'; Positive = $true; RuleId = 'PSEN005' }
    @{ Label = 'Negative-CountOnPreservedArray'; Positive = $false; RuleId = 'PSEN005' }
    @{ Label = 'Negative-CountOnLocalArray'; Positive = $false; RuleId = 'PSEN005' }
    @{ Label = 'Positive-UnqualifiedScriptScopeInScriptBlock'; Positive = $true; RuleId = 'PSEN006' }
    @{ Label = 'Negative-QualifiedScriptScopeInScriptBlock'; Positive = $false; RuleId = 'PSEN006' }
    @{ Label = 'Negative-ParameterBoundScriptBlock'; Positive = $false; RuleId = 'PSEN006' }
    @{ Label = 'Positive-ConvertToJsonWithoutDepth'; Positive = $true; RuleId = 'PSEN007' }
    @{ Label = 'Negative-ConvertToJsonWithDepth'; Positive = $false; RuleId = 'PSEN007' }
    @{ Label = 'Positive-ContractWriteWithoutCompress'; Positive = $true; RuleId = 'PSEN008' }
    @{ Label = 'Negative-ContractWriteWithCompress'; Positive = $false; RuleId = 'PSEN008' }
    @{ Label = 'Positive-FlattenedCommandResultCounted'; Positive = $true; RuleId = 'PSEN009' }
    @{ Label = 'Negative-PreservedCommandResultCounted'; Positive = $false; RuleId = 'PSEN009' }
    @{ Label = 'Positive-ClosureCallsRepositoryFunction'; Positive = $true; RuleId = 'PSEN010' }
    @{ Label = 'Negative-ClosureCapturesFunctionReference'; Positive = $false; RuleId = 'PSEN010' }
    @{ Label = 'Positive-WrapsProtectedCollectionReturn'; Positive = $true; RuleId = 'PSEN011' }
    @{ Label = 'Negative-AssignsProtectedCollectionBeforeWrapping'; Positive = $false; RuleId = 'PSEN011' }
)

$tokens = $null
$parseErrors = $null
$fixtureAst = [Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $fixture).Path, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) {
    throw "Fixture parse failed: $(($parseErrors.Message) -join '; ')"
}
$functions = @{}
foreach ($function in $fixtureAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true)) {
    $functions[$function.Name] = $function
}

$fixtureFindings = @(& $analyzer -Path $fixture -RuleId $boundaryRules -OutputFormat Json | ConvertFrom-Json)
$counts = [ordered]@{ TruePositives = 0; FalsePositives = 0; FalseNegatives = 0; TrueNegatives = 0 }
$results = [System.Collections.Generic.List[object]]::new()

foreach ($case in $cases) {
    if (-not $functions.ContainsKey($case.Label)) {
        throw "Fixture function '$($case.Label)' is missing."
    }
    $function = $functions[$case.Label]
    $hits = @($fixtureFindings | Where-Object {
            $_.RuleId -eq $case.RuleId -and
            $_.Line -ge $function.Extent.StartLineNumber -and
            $_.Line -le $function.Extent.EndLineNumber
        })
    $detected = $hits.Count -gt 0
    $classification = if ($case.Positive -and $detected) { $counts.TruePositives++; 'TP' }
    elseif (-not $case.Positive -and $detected) { $counts.FalsePositives++; 'FP' }
    elseif ($case.Positive) { $counts.FalseNegatives++; 'FN' }
    else { $counts.TrueNegatives++; 'TN' }
    [void]$results.Add([ordered]@{
            Label = $case.Label
            RuleId = $case.RuleId
            Classification = $classification
        })
}

# --------------------------------------------------------------- repository gate

function Get-RelativePath {
    param([string]$FullPath, [string]$Root)
    $relative = $FullPath
    if ($relative.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $relative.Substring($Root.Length)
    }
    return $relative.TrimStart('\', '/').Replace('\', '/')
}

function Get-FindingFingerprint {
    param([string]$RuleId, [string]$RelativePath, [string]$Snippet)
    $normalized = ($Snippet -replace '\s+', ' ').Trim()
    $material = "$RuleId|$RelativePath|$normalized"
    $hash = [Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($material))
    return [Convert]::ToHexString($hash).Substring(0, 16).ToLowerInvariant()
}

$scanRoots = @((Join-Path $RepoRoot 'src'), (Join-Path $RepoRoot 'tools'))
$raw = @(& $analyzer -Path $scanRoots -Recurse -OutputFormat Json | ConvertFrom-Json)

$current = @{}
$currentRules = @{}
foreach ($finding in $raw) {
    $relative = Get-RelativePath -FullPath ([string]$finding.File) -Root $RepoRoot
    if ($excludedRelativePaths -contains $relative) { continue }
    $fingerprint = Get-FindingFingerprint -RuleId ([string]$finding.RuleId) `
        -RelativePath $relative -Snippet ([string]$finding.Snippet)
    $key = "$($finding.RuleId)|$relative|$fingerprint"
    if (-not $current.ContainsKey($key)) {
        $current[$key] = [ordered]@{
            ruleId = [string]$finding.RuleId
            file = $relative
            fingerprint = $fingerprint
            count = 0
            firstLine = [int]$finding.Line
            message = [string]$finding.Message
        }
    }
    $current[$key].count++
    if (-not $currentRules.ContainsKey([string]$finding.RuleId)) { $currentRules[[string]$finding.RuleId] = 0 }
    $currentRules[[string]$finding.RuleId]++
}

$ruleRationale = [ordered]@{
    PSEN001 = 'Bare command output into a typed array. Pre-existing sites are dominated by preserved returns the analyzer cannot prove; each is debt until the producing function states its output contract.'
    PSEN002 = 'Array subexpressions that can retain an explicit null. Most surviving sites are adversarial fixtures and predicate references, kept as debt rather than rewritten mechanically.'
    PSEN003 = 'Measure-Object -Sum dereferences without a recognized guard. Two of these were real incidents; the rest await an indirect-guard model.'
    PSEN004 = 'Bare return of a locally constructed collection. This is the empty-fingerprint-set shape and the baseline is deliberately empty, so any new site is blocked.'
    PSEN005 = 'Cardinality read straight off an unconstrained pipeline. Existing sites are debt; they are the cheapest class to repair incrementally with @().'
    PSEN006 = 'Script block reading a script-scoped name unqualified. Existing sites are debt pending explicit capture.'
    PSEN007 = 'ConvertTo-Json without an explicit -Depth. Existing sites predate the file-contract layer; new contract writers must go through the shared stage-contract helpers instead.'
    PSEN008 = 'ConvertTo-Json reaching a file without an explicit -Compress decision. Same disposition as PSEN007.'
    PSEN009 = 'Non-preserved command result later counted or indexed. The largest debt class and the one with the weakest static evidence, so it is reported, never auto-rewritten.'
    PSEN010 = 'GetNewClosure block calling a repository function by name. Three separate live incidents came from this shape; existing sites are debt and new ones are blocked.'
    PSEN011 = 'An @() wrap around a deliberately protected collection return, which nests instead of flattens. This is the anchor-index nesting shape; the baseline is expected to stay small and every new site is blocked.'
}

if ($UpdateBaseline) {
    $entries = [object[]]@($current.Values | Sort-Object ruleId, file, fingerprint | ForEach-Object {
            [ordered]@{
                ruleId = $_.ruleId
                file = $_.file
                fingerprint = $_.fingerprint
                count = $_.count
            }
        })
    $ruleSummary = [object[]]@($ruleRationale.Keys | ForEach-Object {
            $ruleId = [string]$_
            $count = 0
            if ($currentRules.ContainsKey($ruleId)) { $count = [int]$currentRules[$ruleId] }
            [ordered]@{
                ruleId = $ruleId
                count = $count
                status = $(if ($count -eq 0) { 'clean' } else { 'debt' })
                rationale = [string]$ruleRationale[$ruleId]
            }
        })
    $baseline = [ordered]@{
        schemaVersion = 1
        kind = 'powershell-boundary-hardening-baseline'
        claim = 'recorded-debt-not-approved-debt'
        scannedRoots = @('src', 'tools')
        excludedPaths = $excludedRelativePaths
        totalFindings = @($entries | Measure-Object -Property count -Sum).Sum
        rules = $ruleSummary
        entries = $entries
    }
    $json = ConvertTo-Json -InputObject $baseline -Depth 6
    [IO.File]::WriteAllText($baselinePath, $json.Replace("`r`n", "`n").TrimEnd() + "`n", $utf8)
    Write-Host "Baseline written: $($baseline.totalFindings) finding(s) across $(@($entries).Count) fingerprint(s)."
    return
}

if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
    throw "Boundary baseline '$baselinePath' is missing; run with -UpdateBaseline and review the result."
}
$baseline = [IO.File]::ReadAllText($baselinePath, $utf8) | ConvertFrom-Json -Depth 8
if ([int]$baseline.schemaVersion -ne 1 -or
    [string]$baseline.kind -cne 'powershell-boundary-hardening-baseline') {
    throw 'Boundary baseline schema or kind drifted.'
}
$baselineEntries = @{}
foreach ($entry in @($baseline.entries)) {
    $baselineEntries["$($entry.ruleId)|$($entry.file)|$($entry.fingerprint)"] = [int]$entry.count
}

$newViolations = [System.Collections.Generic.List[object]]::new()
foreach ($key in ($current.Keys | Sort-Object)) {
    $observed = [int]$current[$key].count
    $allowed = 0
    if ($baselineEntries.ContainsKey($key)) { $allowed = $baselineEntries[$key] }
    if ($observed -le $allowed) { continue }
    [void]$newViolations.Add([ordered]@{
            ruleId = $current[$key].ruleId
            file = $current[$key].file
            line = $current[$key].firstLine
            baselineCount = $allowed
            observedCount = $observed
            message = $current[$key].message
        })
}

$resolved = 0
foreach ($key in $baselineEntries.Keys) {
    $observed = 0
    if ($current.ContainsKey($key)) { $observed = [int]$current[$key].count }
    if ($observed -lt [int]$baselineEntries[$key]) { $resolved += ([int]$baselineEntries[$key] - $observed) }
}

$debtByRule = [object[]]@($ruleRationale.Keys | ForEach-Object {
        $ruleId = [string]$_
        $count = 0
        if ($currentRules.ContainsKey($ruleId)) { $count = [int]$currentRules[$ruleId] }
        [ordered]@{ ruleId = $ruleId; count = $count }
    })

$report = [ordered]@{
    SchemaVersion = 1
    Kind = 'powershell-boundary-hardening-report'
    FixtureCount = $cases.Count
    Counts = $counts
    Fixtures = $results
    RepositoryDebt = $debtByRule
    ResolvedSinceBaseline = $resolved
    NewViolations = $newViolations
}
ConvertTo-Json -InputObject $report -Depth 6 -Compress

if ($counts.FalsePositives -ne 0 -or $counts.FalseNegatives -ne 0) {
    throw "Boundary fixture measurement has FP=$($counts.FalsePositives), FN=$($counts.FalseNegatives)."
}
if ($newViolations.Count -gt 0) {
    $detail = ($newViolations | ForEach-Object {
            "$($_.ruleId) $($_.file):$($_.line) (baseline $($_.baselineCount), now $($_.observedCount))"
        }) -join '; '
    throw "$($newViolations.Count) new PowerShell boundary violation(s): $detail"
}
Write-Host "PASS: boundary fixtures classify exactly, and no new violations above the recorded baseline." -ForegroundColor Green
