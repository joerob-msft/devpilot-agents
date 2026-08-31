#!/usr/bin/env pwsh
#requires -Version 7.0

<#
.SYNOPSIS
    Proves tools/Get-ReviewerDiscoveryCandidate.ps1 parses a sealed convention
    SPECIALIST discovery marker through the specialist-specific wrapper the
    production reviewer uses, not the generic result-marker reader.

.DESCRIPTION
    A convention specialist marker legitimately emits an empty
    changedCodeFix.evidenceFactIds as a JSON array ([]) rather than the schema's
    no-evidence empty string. Every production consumer parses that marker with
    ConvertFrom-ReviewerConventionSpecialistResultMarkerOutcome, whose
    -CandidateNormalizer rewrites that exact empty array to '' before the typed
    schema runs. The discovery-candidate extraction tool parsed the same
    specialist capture with the GENERIC ConvertFrom-AgentResultMarkerOutcome,
    which has no such normalizer, so it rejected a marker production accepts.

    This check pins the difference on one fully schema-valid marker whose only
    compatibility shape is the empty evidenceFactIds array, and pins the tool to
    the specialist parser for its specialist branch. No model, network, or
    provider call is made.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot "src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1") -Force
. (Join-Path $repoRoot "src\Agents\reviewer\SourceTransport.ps1")
. (Join-Path $repoRoot "src\Agents\reviewer\ConventionSpecialist.ps1")
. (Join-Path $repoRoot "src\Agents\reviewer\CrossVerification.ps1")

$failures = [System.Collections.Generic.List[string]]::new()
$checks = 0

function Assert-Parser {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:checks++
    if (-not $Condition) { [void]$script:failures.Add($Message) }
}

function Copy-MarkerObject {
    param([Parameter(Mandatory)]$Value)
    return ($Value | ConvertTo-Json -Depth 32 | ConvertFrom-Json -Depth 32)
}

# ---------------------------------------------------------------------------
# One fully schema-valid specialist marker. Every field is valid so the ONLY
# variable across the two parsers is the empty evidenceFactIds array.
# ---------------------------------------------------------------------------
$project = "Example"
$nonce = "nonce-1"
$repositoryId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
$sourceRepositoryId = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
$factId = "rf1:" + ("7" * 64)
$candidate = [pscustomobject][ordered]@{
    candidateId = "manifest-validation"
    category = "convention"
    severity = "important"
    anchorKind = "changedFile"
    filePath = "/src/a.cs"
    line = 12
    primaryTarget = "cf0:12"
    manifestations = ""
    packName = "csharp-core"
    ruleSourceId = "shared-rules"
    ruleSourceRepositoryId = $sourceRepositoryId
    ruleSourcePath = "/docs/rules.md"
    ruleSourceCommit = "c" * 40
    ruleSourceSha256 = "d" * 64
    ruleSection = "Build validation"
    ruleQuote = "validation manifests are required"
    diffEvidence = "The changed build registration omits the required manifest."
    impactCategory = "buildOrTestExecution"
    impact = "The validation job will not discover the changed tests."
    expectedFixOrValidation = "Add the manifest entry or show the generated equivalent."
    siblingStatus = "checked"
    siblingEvidence = "Unchanged sibling registrations include the manifest entry."
    siblingNotRequiredReason = ""
    factIds = $factId
    confidence = "high"
    residualRiskSummary = "Line coverage is file-granular because the transport exposes no verified right-side spans."
    semanticCandidateVersion = 2
    changedCodeFix = [pscustomobject][ordered]@{
        action = "add"; targets = "mi0"; conventionKey = "ValidationManifest"
        valueSource = "authoritativeRule"; evidenceFactIds = ""
    }
    existingDebtFollowUp = [pscustomobject][ordered]@{
        status = "none"; evidenceFactId = ""; selectorKey = ""; scopeKind = ""; scopePath = ""
        comparableCount = 0; compliantCount = 0; action = ""
    }
}
$coverageRow = [pscustomobject][ordered]@{
    ruleRef = "rs0"
    ruleSourceSha256 = "d" * 64
    ruleQuote = "validation manifests are required"
    status = "violation"
    scope = "invocation"
    violatingConstructs = "mi0"
    compliantConstructs = ""
    notInReachConstructs = ""
    unknownConstructs = ""
    violatingChangedFileTargets = ""
    codeEvidence = "The changed build registration omits the required manifest."
    siblingStatus = "checked"
    siblingEvidence = "Unchanged sibling registrations include the manifest entry."
    candidateId = "manifest-validation"
    notes = ""
}
$markerObject = [pscustomobject][ordered]@{
    schemaVersion = 2
    prId = 42
    repositoryId = $repositoryId
    project = $project
    reviewedSourceCommit = "1" * 40
    targetCommit = "2" * 40
    changeSetDigest = "3" * 64
    conventionPlanSha256 = "4" * 64
    factPlanSha256 = "5" * 64
    configSha256 = "6" * 64
    scriptSha256 = "7" * 64
    promptSha256 = "8" * 64
    candidates = @($candidate)
    ruleCoverage = @($coverageRow)
    withheld = @()
    residualRisks = @([pscustomobject][ordered]@{ text = "Changed-line spans are unavailable from this transport." })
    nonce = $nonce
}

$schema = Get-ReviewerConventionSpecialistMarkerSchema -ExpectedProject $project -ExpectedNonce $nonce
$scan = Get-ReviewerConventionSpecialistScanWindowChars
$prefix = $script:ReviewerConventionSpecialistMarkerPrefix

# Baseline: the fully valid marker (string evidenceFactIds) parses through BOTH
# readers. This proves the marker itself is not the reason the empty-array case
# below diverges.
$stringText = $prefix + " " + ($markerObject | ConvertTo-Json -Depth 32 -Compress)
$stringGeneric = ConvertFrom-AgentResultMarkerOutcome -StdOutText $stringText `
    -MarkerPrefix $prefix -Schema $schema -ScanWindowChars $scan
$stringSpecialist = ConvertFrom-ReviewerConventionSpecialistResultMarkerOutcome `
    -StdOutText $stringText -Schema $schema -ScanWindowChars $scan
Assert-Parser (([string]$stringGeneric.Status -ceq 'success') -and
    ([string]$stringSpecialist.Status -ceq 'success')) `
    "A fully valid specialist marker with a string evidenceFactIds did not parse through both readers; the fixture is not a clean baseline."

# The exact production compatibility shape: an empty JSON array at
# changedCodeFix.evidenceFactIds.
$emptyArrayMarker = Copy-MarkerObject $markerObject
$emptyArrayMarker.candidates[0].changedCodeFix.evidenceFactIds = @()
$emptyArrayText = $prefix + " " + ($emptyArrayMarker | ConvertTo-Json -Depth 32 -Compress)

# Falsifying reproduction of the tool's pre-fix path: the GENERIC reader the
# tool used has no candidate normalizer, so the empty array fails the typed
# string rule and the whole marker is rejected.
$genericOutcome = ConvertFrom-AgentResultMarkerOutcome -StdOutText $emptyArrayText `
    -MarkerPrefix $prefix -Schema $schema -ScanWindowChars $scan
Assert-Parser ([string]$genericOutcome.Status -cne 'success') `
    "The generic result-marker reader accepted the empty-array evidenceFactIds; the tool's pre-fix bypass would not have been observable."

# Production/post-fix path: the specialist wrapper normalizes the empty array to
# '' and accepts the marker.
$specialistOutcome = ConvertFrom-ReviewerConventionSpecialistResultMarkerOutcome `
    -StdOutText $emptyArrayText -Schema $schema -ScanWindowChars $scan
Assert-Parser ([string]$specialistOutcome.Status -ceq 'success' -and
    [string]$specialistOutcome.Value.candidates[0].changedCodeFix.evidenceFactIds -ceq '') `
    "The specialist wrapper did not accept and normalize the empty-array evidenceFactIds production accepts."

# ---------------------------------------------------------------------------
# The tool must route its specialist capture through the specialist wrapper.
# ---------------------------------------------------------------------------
$toolPath = Join-Path $repoRoot "tools\Get-ReviewerDiscoveryCandidate.ps1"
$toolText = [IO.File]::ReadAllText($toolPath)
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($toolText, [ref]$tokens, [ref]$parseErrors)
Assert-Parser ($parseErrors.Count -eq 0) "The discovery-candidate tool no longer parses."

# Isolate the specialist branch: the `if ($sourceRole -ceq 'specialist')` block.
$specialistBranch = $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses.Count -ge 1 -and
        $node.Clauses[0].Item1.Extent.Text -match "sourceRole\s+-ceq\s+'specialist'"
    }, $true) | Select-Object -First 1
Assert-Parser ($null -ne $specialistBranch) "The tool's specialist-capture branch was not found."
$branchText = if ($null -ne $specialistBranch) { $specialistBranch.Extent.Text } else { "" }
# Enumerate the actual command invocations in the branch. A substring scan would
# be fooled because the specialist wrapper's own name CONTAINS the generic
# reader's name, so judge the invoked command names precisely.
$branchCommandNames = @()
if ($null -ne $specialistBranch) {
    $branchCommandNames = @($specialistBranch.FindAll({
                param($node) $node -is [Management.Automation.Language.CommandAst]
            }, $true) | ForEach-Object { [string]$_.GetCommandName() } | Where-Object { $_ })
}
Assert-Parser ($branchCommandNames -contains 'ConvertFrom-ReviewerConventionSpecialistResultMarkerOutcome') `
    "The tool's specialist branch does not route the specialist capture through the specialist parser."
Assert-Parser ($branchCommandNames -notcontains 'ConvertFrom-AgentResultMarkerOutcome') `
    "The tool's specialist branch still parses the specialist capture with the generic result-marker reader, bypassing the supported normalization."

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if ($failures.Count -gt 0) {
    throw ("Discovery-candidate specialist-parser check failed $($failures.Count) of $checks check(s):`n - " +
        ($failures -join "`n - "))
}
Write-Host "PASS: discovery-candidate specialist-parser routing ($checks checks)."
