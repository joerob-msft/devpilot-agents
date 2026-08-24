#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Seals a complete schema-v2 replay snapshot offline from an already-captured,
    integrity-indexed research corpus. Never contacts a repository host.

.DESCRIPTION
    This tool has NO live seam. It opens no MCP session, launches no process,
    resolves no `az`, and has no fallback that could reach a repository host: the
    only bytes it can read are the ones the canonical corpus index names, and the
    only way it can fail to find something is by refusing.

    It takes two inputs:

      -CorpusRoot        an immutable corpus directory whose corpus-index.json
                         binds every payload to a path, SHA-256 and byte length;
      -Recipe            a PRIVATE recipe that independently binds the identity,
                         change set, changed-file right-hand content and spans,
                         prompt evidence, hashes, source transport and census
                         this seal is supposed to produce.

    -CorpusIndexSha256 is mandatory. An index that is only self-consistent proves
    nothing, because whoever edited it could recompute whatever it contains.

    The result is permanently NON-PROMOTABLE. The snapshot id must say
    `offlinecorpusseal`, an `offline-corpus-seal.json` sidecar records the same
    thing under its own digest, and the seal explicitly records that no live
    post-read race check was performed - because none was, and claiming one would
    be the artifact asserting a guarantee it never obtained.

    Both the corpus and its index are opened read-only. Nothing here writes into
    the corpus under any code path.

.EXAMPLE
    ./tools/Save-CorpusReplaySeal.ps1 `
        -CorpusRoot <corpus> -CorpusIndexSha256 <64 hex> `
        -Recipe <private recipe>.json -ReplayRoot <private replay root>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CorpusRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$CorpusIndexSha256,
    [Parameter(Mandatory)][string]$Recipe,
    [Parameter(Mandatory)][string]$ReplayRoot,
    [switch]$Force,
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot "src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1") -Force
. (Join-Path $repoRoot "src\Agents\reviewer\SourceTransport.ps1")
. (Join-Path $repoRoot "src\Agents\reviewer\CorpusSeal.ps1")

# The real-path walk, the separator-anchored containment test and the replay-root
# guard all live in CorpusSeal.ps1 rather than here, so a caller that reaches the
# library directly gets the same protection this tool does.
# A corpus seal is private research evidence about a real pull request. Writing
# one inside the toolkit's own working tree is how it ends up in a commit, so the
# tool refuses the location rather than trusting an operator to notice. Both the
# candidate and the repository are compared as REAL paths, and the candidates are
# additionally refused if they pass through a link at all.
$corpusFull = Resolve-ReviewerCorpusSealRealPath -Path $CorpusRoot -RejectReparsePoints
$replayFull = Resolve-ReviewerCorpusSealRealPath -Path $ReplayRoot -RejectReparsePoints
$repoFull = Resolve-ReviewerCorpusSealRealPath -Path $repoRoot
foreach ($boundary in @($repoFull, [System.IO.Path]::GetFullPath($repoRoot))) {
    if (Test-ReviewerCorpusSealPathWithin -Path $replayFull -Boundary $boundary) {
        throw "The replay root '$replayFull' is inside this repository; a private corpus seal must be written outside it."
    }
    if (Test-ReviewerCorpusSealPathWithin -Path $corpusFull -Boundary $boundary) {
        throw "The corpus root '$corpusFull' is inside this repository; a private corpus is never committed."
    }
}

$index = Import-ReviewerCorpusIndex -CorpusRoot $corpusFull -ExpectedIndexSha256 $CorpusIndexSha256
Write-Host ("Corpus index verified: {0} payload(s), SHA-256 {1}" -f $index.PayloadCount, $index.IndexSha256) -ForegroundColor DarkCyan

$recipeObject = Import-ReviewerCorpusSealRecipe -Path $Recipe
$plan = New-ReviewerCorpusSealPlan -Index $index -Recipe $recipeObject -ToolkitRoot $repoRoot
Write-Host ("Recipe validated: {0} recorded read(s), {1} changed path(s), source transport '{2}' ({3})" -f `
        @($plan.Resources).Count, [int]$plan.Census.rightHandCoveredPathCount,
    $plan.SourceTransport.Mode, $plan.SourceTransport.Kind) -ForegroundColor DarkCyan

if ($ValidateOnly) {
    Write-Host "Validation only: nothing was written." -ForegroundColor Yellow
    return
}

if (-not (Test-Path -LiteralPath $replayFull -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $replayFull | Out-Null
}
$result = Save-ReviewerCorpusSeal -Plan $plan -ReplayRoot $replayFull -Force:$Force
Write-Host ("Sealed offline corpus snapshot '{0}': schema v{1}, {2} resource(s), {3} payload byte(s)" -f `
        $result.SnapshotId, $result.SchemaVersion, $result.ResourceCount, $result.PayloadBytes) -ForegroundColor Green
Write-Host ("  manifest digest {0}" -f $result.ManifestDigest) -ForegroundColor Green
Write-Host ("  seal digest     {0}" -f $result.SealDigest) -ForegroundColor Green
Write-Host "  This snapshot is permanently non-promotable offlineCorpusSeal evidence." -ForegroundColor Yellow
$result
