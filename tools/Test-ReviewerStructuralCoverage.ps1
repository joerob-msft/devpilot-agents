#!/usr/bin/env pwsh
[CmdletBinding()]
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$path = Join-Path $RepoRoot 'tools\testdata\reviewer-structural-coverage-matrix.v1.json'
$raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
$matrix = $raw | ConvertFrom-Json -Depth 32

if ([int]$matrix.schemaVersion -ne 2 -or
    [string]$matrix.kind -cne 'reviewer-gate-0-1-structural-coverage-matrix' -or
    [string]$matrix.claim -cne 'orchestration-correctness-not-model-quality') {
    throw 'Structural coverage schema, kind, or claim drifted.'
}
$cells = @($matrix.cells)
if ($cells.Count -ne 46 -or @($cells.id | Select-Object -Unique).Count -ne $cells.Count) {
    throw "Structural coverage must contain exactly 46 uniquely identified cells."
}
$allowed = @('covered', 'structurallyUntestable')
if (@($cells | Where-Object { $allowed -cnotcontains [string]$_.status }).Count -ne 0) {
    throw 'Structural coverage contains a silent or unsupported status.'
}
$covered = @($cells | Where-Object status -ceq 'covered')
$residual = @($cells | Where-Object status -ceq 'structurallyUntestable')
if ($covered.Count -ne 41 -or $residual.Count -ne 5) {
    throw "Structural coverage golden changed: covered=$($covered.Count), residual=$($residual.Count)."
}
foreach ($cell in $covered) {
    $evidence = Join-Path $RepoRoot ([string]$cell.evidence)
    if (-not (Test-Path -LiteralPath $evidence -PathType Leaf)) {
        throw "Covered cell '$($cell.id)' names missing evidence '$($cell.evidence)'."
    }
}
$sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.UTF8Encoding]::new($false).GetBytes($raw))).ToLowerInvariant()
$expectedSha = 'aa4fde1f41699c1aaeb27cb382ee50dbf7b6abf89c29820b172411693a3ffdb4'
if ($sha -cne $expectedSha) {
    throw "Structural coverage matrix drifted ($sha); review cells and update the explicit golden."
}
$contractPath = Join-Path $RepoRoot 'tools\testdata\reviewer-semantic-normalization-contract.v1.json'
$contractSha = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedContractSha = 'd99976318861e2c3804c9f60e9b8aa9a7b6f92ccda3fa30d6191733b9f54d455'
if ($contractSha -cne $expectedContractSha) {
    throw "Semantic normalization contract drifted ($contractSha); review exclusions and update the explicit golden."
}
$normalizerPath = Join-Path $RepoRoot 'tools\ConvertTo-ReviewerSemanticDecision.ps1'
$normalizerSha = (Get-FileHash -LiteralPath $normalizerPath -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedNormalizerSha = '221df9036cfcf1750a45b1e57892a7910bb62fd4e179ef607f854ebb6103526d'
if ($normalizerSha -cne $expectedNormalizerSha) {
    throw "Semantic normalizer implementation drifted ($normalizerSha); review behavior and update the explicit golden."
}
Write-Host "PASS: structural coverage is pinned at $sha (41 covered, 5 live-only residuals)."
