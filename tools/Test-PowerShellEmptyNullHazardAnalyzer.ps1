#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Measures the focused empty-output-to-null analyzer fixture corpus.

.DESCRIPTION
    Emits one compact JSON object with confusion-matrix counts and fails unless
    every labeled fixture is classified as expected.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$analyzer = Join-Path $PSScriptRoot 'Find-PowerShellEmptyNullHazard.ps1'
$fixture = Join-Path $PSScriptRoot 'testdata\empty-null-analyzer.fixtures.ps1'

$cases = @(
    @{ Label = 'Positive-TypedArrayAssignment'; Positive = $true; RuleId = 'PSEN001' }
    @{ Label = 'Negative-PreservedTypedArrayAssignment'; Positive = $false; RuleId = 'PSEN001' }
    @{ Label = 'Positive-MandatoryArrayArgument'; Positive = $true; RuleId = 'PSEN001' }
    @{ Label = 'Negative-PreservedMandatoryArrayArgument'; Positive = $false; RuleId = 'PSEN001' }
    @{ Label = 'Positive-PhantomNullArray'; Positive = $true; RuleId = 'PSEN002' }
    @{ Label = 'Positive-PhantomNullAmongValues'; Positive = $true; RuleId = 'PSEN002' }
    @{ Label = 'Negative-FilteredNullArray'; Positive = $false; RuleId = 'PSEN002' }
    @{ Label = 'Negative-EmptyArray'; Positive = $false; RuleId = 'PSEN002' }
    @{ Label = 'Positive-UnguardedEmptySum'; Positive = $true; RuleId = 'PSEN003' }
    @{ Label = 'Positive-WeakEmptySumGuard'; Positive = $true; RuleId = 'PSEN003' }
    @{ Label = 'Positive-DisjunctiveEmptySumGuard'; Positive = $true; RuleId = 'PSEN003' }
    @{ Label = 'Negative-DefaultedEmptySum'; Positive = $false; RuleId = 'PSEN003' }
    @{ Label = 'Negative-NonEmptyGuardedSum'; Positive = $false; RuleId = 'PSEN003' }
    @{ Label = 'Negative-ConjunctiveNonEmptyGuardedSum'; Positive = $false; RuleId = 'PSEN003' }
    @{ Label = 'Negative-EarlyReturnGuardedSum'; Positive = $false; RuleId = 'PSEN003' }
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

$json = & $analyzer -Path $fixture -OutputFormat Json
$findings = @($json | ConvertFrom-Json)
$counts = [ordered]@{
    TruePositives = 0
    FalsePositives = 0
    FalseNegatives = 0
    TrueNegatives = 0
}
$results = New-Object System.Collections.Generic.List[object]

foreach ($case in $cases) {
    if (-not $functions.ContainsKey($case.Label)) {
        throw "Fixture function '$($case.Label)' is missing."
    }
    $function = $functions[$case.Label]
    $hits = @($findings | Where-Object {
            $_.RuleId -eq $case.RuleId -and
            $_.Line -ge $function.Extent.StartLineNumber -and
            $_.Line -le $function.Extent.EndLineNumber
        })
    $detected = $hits.Count -gt 0
    $classification = if ($case.Positive -and $detected) {
        $counts.TruePositives++
        'TP'
    }
    elseif (-not $case.Positive -and $detected) {
        $counts.FalsePositives++
        'FP'
    }
    elseif ($case.Positive) {
        $counts.FalseNegatives++
        'FN'
    }
    else {
        $counts.TrueNegatives++
        'TN'
    }
    [void]$results.Add([ordered]@{
            Label = $case.Label
            RuleId = $case.RuleId
            Classification = $classification
        })
}

$report = [ordered]@{
    SchemaVersion = 1
    FixtureCount = $cases.Count
    Counts = $counts
    Fixtures = $results
}
$report | ConvertTo-Json -Depth 5 -Compress

if ($counts.FalsePositives -ne 0 -or $counts.FalseNegatives -ne 0) {
    throw "Analyzer fixture measurement has FP=$($counts.FalsePositives), FN=$($counts.FalseNegatives)."
}
