#Requires -Version 7.0

<#
.SYNOPSIS
    Generates or checks docs/escape-ledger-consolidation.v1.json from live git
    facts.

.DESCRIPTION
    Every identity in the map is READ FROM GIT here rather than typed in. Only
    the correspondence itself - which replacement commit carries which source
    commit's work, and on what basis - is a human statement, and it is exactly
    the statement the verifier then holds to its recorded identities.

    -Check regenerates in memory and compares, so a hand-edited map, a stale
    map, or a map whose evidence blobs have moved is a failing check rather than
    a silent acceptance.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$OutFile,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $PSScriptRoot 'EscapeLedgerConsolidation.ps1')
if (-not $OutFile) { $OutFile = Get-EscapeLedgerConsolidationDefaultPath -RepoRoot $RepoRoot }

function Resolve-Object {
    param([Parameter(Mandatory)][string]$Revision)
    $value = (& git -C $RepoRoot rev-parse --verify --quiet $Revision 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Revision '$Revision' does not resolve in '$RepoRoot'."
    }
    return ([string]$value).Trim().ToLowerInvariant()
}

function Get-Subject {
    param([Parameter(Mandatory)][string]$Commit)
    $value = (& git -C $RepoRoot show -s --format='%s' $Commit 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "Commit '$Commit' has no subject in '$RepoRoot'." }
    return ([string]$value).Trim()
}

# --- The declared correspondence -----------------------------------------------------------
#
# Source lineage: the pre-consolidation reviewer stack the escape ledger was
# evaluated against. Replacement lineage: the consolidated stack that replaced
# it. The anchors are the commits at which the two lineages are tree-equal, and
# they are what makes the rest of the map a statement about one history rather
# than two.

# The source head is the commit the escape ledger's coverage window was
# evaluated at, not the furthest tip any abandoned branch ever reached. The map
# exists to serve that frozen evaluation, so its source segment ends exactly
# where the evaluation did; a wider segment would make commits mappable that the
# ledger never claimed anything about.
$sourceHead = '5a8f10610bf142b7d4cd0a59bd770407994fb290'
$commonBase = '8d66afc8b31b0878152de846ebf0ad8644c996e1'

$anchorDeclarations = @(
    [ordered]@{
        name              = 'reviewer-format-guard'
        sourceCommit      = 'ccbf14632064118f008539becec2fef77030cf54'
        replacementCommit = 'dd9f661711936d7c124fccc89dbc1bc7a6388ec5'
    },
    [ordered]@{
        name              = 'reviewer-result-retries'
        sourceCommit      = '535fa9e3f398d8a885849265ecd3f92371f7d52a'
        replacementCommit = '79df38bcf588edcc6302a51b1648c58bcc2d3817'
    }
)

# One entry per pre-consolidation commit the frozen ledger cites and this branch
# no longer contains. Nothing else is mapped: a map that covered commits nobody
# needs would be an unaudited bridge waiting to be used.
$mappingDeclarations = @(
    [ordered]@{
        sourceCommit      = 'fc11fae765ac1145866720e141aaff738dca1e35'
        replacementCommit = '64c2e3ae1136ccca04bba49e7b695a3bb85d964b'
        anchor            = 'reviewer-result-retries'
        equivalenceBasis  = 'segmentConsolidation'
        note              = 'Cited by near miss NM-0001 as introducedCommit. The stage-boundary hardening this commit introduced was squashed into the consolidated hardening change; the regression guards NM-0001 names are carried at the recorded blobs.'
        carriedEvidence   = @('tools/Test-PowerShellBoundaryHardening.ps1', 'tools/Test-ReviewerCollectionCardinality.ps1', 'tools/testdata/boundary-hardening-analyzer.fixtures.ps1')
    },
    [ordered]@{
        sourceCommit      = 'cc5983c6ce02150562b5ae11ebbe3d2dc683cb78'
        replacementCommit = '64c2e3ae1136ccca04bba49e7b695a3bb85d964b'
        anchor            = 'reviewer-result-retries'
        equivalenceBasis  = 'segmentConsolidation'
        note              = 'Cited by near miss NM-0002 as introducedCommit and by NM-0001 as remediatedCommit. Squashed into the same consolidated hardening change; the falsifiable cross-file gate and the extracted coverage-clock derivation are carried at the recorded blobs.'
        carriedEvidence   = @('tools/Test-PowerShellBoundaryHardening.ps1', 'tools/Test-EscapeLedger.ps1')
    },
    [ordered]@{
        sourceCommit      = '5a8f10610bf142b7d4cd0a59bd770407994fb290'
        replacementCommit = '3149955f1268012b2af159c0dbe7ae6582f07aa3'
        anchor            = 'reviewer-result-retries'
        equivalenceBasis  = 'segmentConsolidation'
        note              = 'The commit the escape ledger coverage window was evaluated at. Its replacement is the tip of the consolidated segment, so the window end is measured against the branch that actually carries the work rather than against a history this branch does not have.'
        carriedEvidence   = @('docs/escape-ledger.v2.json', 'tools/Test-EscapeLedger.ps1')
    }
)

$anchors = foreach ($declared in $anchorDeclarations) {
    $sourceTree = Resolve-Object -Revision "$($declared.sourceCommit)^{tree}"
    $replacementTree = Resolve-Object -Revision "$($declared.replacementCommit)^{tree}"
    if ($sourceTree -cne $replacementTree) {
        throw ("Anchor '$($declared.name)' is not tree-equal: $($declared.sourceCommit) holds $sourceTree " +
            "and $($declared.replacementCommit) holds $replacementTree. An anchor that is not tree-equal proves nothing.")
    }
    [ordered]@{
        name              = [string]$declared.name
        replacementCommit = Resolve-Object -Revision $declared.replacementCommit
        sourceCommit      = Resolve-Object -Revision $declared.sourceCommit
        tree              = $sourceTree
    }
}

$replacementHead = Resolve-Object -Revision '3149955f1268012b2af159c0dbe7ae6582f07aa3'

$mappings = foreach ($declared in $mappingDeclarations) {
    $sourceCommit = Resolve-Object -Revision $declared.sourceCommit
    $replacementCommit = Resolve-Object -Revision $declared.replacementCommit
    $sourceTree = Resolve-Object -Revision "$sourceCommit^{tree}"
    $replacementTree = Resolve-Object -Revision "$replacementCommit^{tree}"
    $evidence = foreach ($path in @($declared.carriedEvidence)) {
        [ordered]@{
            blob = Resolve-Object -Revision "$replacementCommit`:$path"
            path = [string]$path
        }
    }
    [ordered]@{
        anchor            = [string]$declared.anchor
        carriedEvidence   = @($evidence)
        deltaIdentity     = Get-EscapeLedgerConsolidationDeltaIdentity -SourceCommit $sourceCommit -SourceTree $sourceTree `
            -ReplacementCommit $replacementCommit -ReplacementTree $replacementTree -EquivalenceBasis ([string]$declared.equivalenceBasis)
        equivalenceBasis  = [string]$declared.equivalenceBasis
        note              = [string]$declared.note
        replacementCommit = $replacementCommit
        replacementTree   = $replacementTree
        sourceCommit      = $sourceCommit
        sourceSubject     = Get-Subject -Commit $sourceCommit
        sourceTree        = $sourceTree
    }
}

$map = [ordered]@{
    commonBaseCommit   = Resolve-Object -Revision $commonBase
    description        = 'Maps pre-consolidation commits cited by the frozen escape ledger onto the consolidated replacement lineage. The ledger citations are never rewritten; this map is how the reachability contradiction check finds the work they name in a branch that no longer contains their commits. Every identity here is recomputed from git at verification time, and the map is consulted only for reachability - never for the merged-versus-not baseline that classifies a finding.'
    kind               = 'reviewer-escape-ledger-consolidation-map'
    lineageAnchors     = @($anchors)
    mappingVersion     = 1
    mappings           = @($mappings)
    replacementLineage = [ordered]@{
        headCommit = $replacementHead
        headTree   = Resolve-Object -Revision "$replacementHead^{tree}"
        name       = 'consolidated-cohort-protocol'
    }
    schemaVersion      = 1
    sourceLineage      = [ordered]@{
        headCommit = Resolve-Object -Revision $sourceHead
        headTree   = Resolve-Object -Revision "$sourceHead^{tree}"
        name       = 'pre-consolidation-reviewer-stack'
    }
}

$mapObject = ($map | ConvertTo-Json -Depth 32) | ConvertFrom-Json -Depth 32
$map['mappingDigest'] = Get-EscapeLedgerConsolidationDigest -Map $mapObject

$ordered = [ordered]@{}
foreach ($key in @([string[]]@($map.Keys) | Sort-Object -CaseSensitive)) { $ordered[$key] = $map[$key] }
$json = ($ordered | ConvertTo-Json -Depth 32) + [Environment]::NewLine

if ($Check) {
    if (-not (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
        throw "The escape-ledger consolidation map '$OutFile' does not exist; run this generator without -Check."
    }
    $existing = [IO.File]::ReadAllText($OutFile)
    if ($existing -cne $json) {
        throw "The escape-ledger consolidation map '$OutFile' does not match what this generator produces from live git facts; regenerate it."
    }
    Write-Host "PASS: escape-ledger consolidation map matches its generator ($(@($mappings).Count) mapping(s), $(@($anchors).Count) anchor(s))."
    return
}

$outDirectory = Split-Path -Parent $OutFile
if ($outDirectory -and -not (Test-Path -LiteralPath $outDirectory -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $outDirectory -Force)
}
[IO.File]::WriteAllText($OutFile, $json, [Text.UTF8Encoding]::new($false, $true))
Write-Host "Wrote $OutFile (digest $($map['mappingDigest']))."
