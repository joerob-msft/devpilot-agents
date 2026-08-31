#Requires -Version 7.0

<#
.SYNOPSIS
    Regenerates the committed reviewer base lineage contract.

.DESCRIPTION
    The contract is data, but it is data ABOUT this repository, so it is
    generated from the repository rather than hand-edited: bound artifact
    digests are read from disk, lineage trees are read from git, and the
    contract digest is recomputed over the result.

    Test-ReviewerBaseContract.ps1 runs this generator into a temporary file and
    fails when the committed contract differs. That is what keeps a hand-edited
    contract - the one thing this file exists to make unnecessary - from
    surviving review.

.PARAMETER RepoRoot
    Defaults to the repository containing this script.

.PARAMETER OutFile
    Defaults to the committed contract path. Point it elsewhere to compare.

.PARAMETER Check
    Writes nothing; exits non-zero when the committed contract is stale.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$OutFile = '',
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'src/Agents/reviewer/ReviewerBaseContract.ps1')

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Get-ReviewerBaseContractDefaultPath -RepoRoot $RepoRoot
}

# The lineages, declared here and nowhere else.
#
# Lineage 1 is the pre-consolidation reviewer base every sealed fixture in this
# repository was captured against. Its commit is no longer an ancestor of the
# consolidated history; its TREE is, unchanged, under lineage 2. That tree
# equality is what makes the supersession verifiable rather than asserted, and
# it is recomputed from git below rather than copied from here.
#
# Lineage 2 is the consolidated replacement boundary. It is the identity a
# future capture should bind to; lineage 1 stays because the fixtures that name
# it stay, and rewriting them would destroy the binding they exist to record.
$lineageDeclarations = @(
    [ordered]@{
        lineageVersion             = 1
        name                       = 'pre-consolidation'
        status                     = 'superseded'
        supersededByLineageVersion = 2
        baseCommit                 = 'ccbf14632064118f008539becec2fef77030cf54'
    },
    [ordered]@{
        lineageVersion             = 2
        name                       = 'consolidated-replacement'
        status                     = 'active'
        supersededByLineageVersion = 0
        baseCommit                 = 'dd9f661711936d7c124fccc89dbc1bc7a6388ec5'
    }
)

# The reviewer-side content a sealed fixture's pre-authored answers actually
# depend on.
#
# Start-ReviewerAgent.ps1 is deliberately ABSENT. It is the seventeen-thousand
# line host that changes in nearly every pull request, and binding it would mean
# regenerating this contract on every unrelated edit until someone regenerated
# it reflexively - at which point the binding stops being evidence of anything.
# What is bound instead is the narrow surface a fixture is replayed through: the
# offline adapter that stands where the model stands, the manifest and plan
# schemas that decide whether a sealed artifact is well formed, the exact-path
# configuration a replay is driven by, and this contract's own verifier.
$boundArtifactPaths = @(
    'src/Agents/reviewer/ReviewerBaseContract.ps1',
    'src/Agents/reviewer/acquisition/v1/acquisition-plan.schema.json',
    'src/Agents/reviewer/offline/Invoke-ReviewerModelAdapter.ps1',
    'src/Agents/reviewer/offline/v1/adapter-manifest.schema.json',
    'src/Agents/reviewer/testdata/exact-path/reviewer.config.json'
)

$lineages = @()
foreach ($declaration in $lineageDeclarations) {
    [string]$tree = Get-ReviewerBaseContractTree -RepoRoot $RepoRoot -Commit ([string]$declaration.baseCommit)
    if ($tree.Length -eq 0) {
        throw ("Lineage $([int]$declaration.lineageVersion) names commit $([string]$declaration.baseCommit), which is " +
            "not present in '$RepoRoot'. The contract cannot be sealed from a clone that cannot see the identities it pins.")
    }
    $lineages += , ([ordered]@{
            baseCommit                 = ([string]$declaration.baseCommit).ToLowerInvariant()
            baseTree                   = $tree
            lineageVersion             = [int]$declaration.lineageVersion
            name                       = [string]$declaration.name
            status                     = [string]$declaration.status
            supersededByLineageVersion = [int]$declaration.supersededByLineageVersion
        })
}

$boundArtifacts = @()
foreach ($relative in @($boundArtifactPaths | Sort-Object -CaseSensitive)) {
    $full = Join-Path $RepoRoot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "The bound artifact '$relative' does not exist under '$RepoRoot'."
    }
    $boundArtifacts += , ([ordered]@{
            path   = $relative
            sha256 = (Get-ReviewerBaseContractArtifactDigest -Path $full `
                    -Basis $script:ReviewerBaseContractDefaultArtifactHashBasis)
        })
}

$contract = [ordered]@{
    artifactHashBasis = $script:ReviewerBaseContractDefaultArtifactHashBasis
    boundArtifacts = $boundArtifacts
    contractDigest = ''
    contractId     = 'reviewer-base-lineage/v1'
    description    = ('The base identities a sealed reviewer fixture may be bound to. A superseded identity is ' +
        'accepted only through an active lineage whose boundary commit is an ancestor of the checkout and whose ' +
        'tree is exactly equal to the superseded identity tree. Regenerate with tools/New-ReviewerBaseContract.ps1.')
    kind           = 'reviewer-base-lineage-contract'
    lineageVersion = 2
    lineages       = $lineages
    schemaVersion  = 1
}
$asObject = ($contract | ConvertTo-Json -Depth 32) | ConvertFrom-Json -Depth 32
$contract['contractDigest'] = Get-ReviewerBaseContractDigest -Contract $asObject

$json = ($contract | ConvertTo-Json -Depth 32)
$text = $json.Replace("`r`n", "`n").TrimEnd() + "`n"

if ($Check) {
    if (-not (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
        Write-Error "The reviewer base lineage contract '$OutFile' does not exist."
        exit 1
    }
    $existing = [IO.File]::ReadAllText($OutFile, [Text.UTF8Encoding]::new($false, $true)).Replace("`r`n", "`n")
    if ($existing -cne $text) {
        Write-Error "The committed reviewer base lineage contract is stale. Run tools/New-ReviewerBaseContract.ps1."
        exit 1
    }
    Write-Host "The reviewer base lineage contract is current (digest $($contract['contractDigest']))."
    exit 0
}

$directory = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
[IO.File]::WriteAllText($OutFile, $text, [Text.UTF8Encoding]::new($false, $true))
Write-Host "Wrote $OutFile (digest $($contract['contractDigest']), $(@($boundArtifacts).Count) bound artifacts)."
