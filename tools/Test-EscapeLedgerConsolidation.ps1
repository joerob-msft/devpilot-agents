#Requires -Version 7.0

<#
.SYNOPSIS
    Falsification tests for the escape-ledger consolidation map and its verifier.

.DESCRIPTION
    The map is the one place where a commit that is NOT in this branch can still
    satisfy a reachability question, so every test here is an attempt to get
    something accepted that should not be. A map that only ever proves the happy
    path would be indistinguishable from no map at all.

    The attacks exercised are: editing an entry without resealing; resealing an
    edited entry so the digest agrees again; naming a real commit with a
    fabricated tree; naming a real, correctly-treed commit from outside the
    consolidated segment; breaking the tree-equality anchor that is the whole
    basis for treating the two lineages as one history; tampering with the
    carried-evidence blobs; mapping one source commit twice; deleting a mapping;
    and widening the map's shape with a field the verifier does not check.

    The suite also pins that the map changes nothing the budget counts: the
    ledger's trigger verdict and qualifying count are identical with and without
    commit verification, so nothing was reclassified into or out of the budget by
    introducing the mapping path.
#>

[CmdletBinding()]
param([string]$RepoRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $PSScriptRoot 'EscapeLedgerConsolidation.ps1')

$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Checks = 0

function Assert-Consolidation {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:Checks++
    if (-not $Condition) { $script:Failures.Add($Message) }
}

$mapPath = Get-EscapeLedgerConsolidationDefaultPath -RepoRoot $RepoRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("escape-consolidation-" + [Guid]::NewGuid().ToString('n'))
[void](New-Item -ItemType Directory -Path $scratch -Force)

function New-MutatedMap {
    <#
        .SYNOPSIS
        Writes a mutated copy of the committed map to scratch and returns its path.
        .DESCRIPTION
        -Reseal recomputes the mapping digest so the test attacks the identity
        checks rather than stopping at the digest. Without it the digest itself is
        what is being attacked.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Mutate,
        [switch]$Reseal
    )
    $copy = ([IO.File]::ReadAllText($mapPath) | ConvertFrom-Json -Depth 32)
    & $Mutate $copy
    if ($Reseal) {
        $roundTripped = ($copy | ConvertTo-Json -Depth 32) | ConvertFrom-Json -Depth 32
        $copy.mappingDigest = Get-EscapeLedgerConsolidationDigest -Map $roundTripped
    }
    $path = Join-Path $scratch "$Name.json"
    [IO.File]::WriteAllText($path, (($copy | ConvertTo-Json -Depth 32 -Compress:$false) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false, $true))
    return $path
}

function Test-MapRefused {
    <#
        .SYNOPSIS
        True when reading the map at this path is refused.
    #>
    param([Parameter(Mandatory)][string]$Path)
    try { [void](Read-EscapeLedgerConsolidationMap -Path $Path); return $false }
    catch { return $true }
}

function Get-ResolutionOutcome {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$SourceCommit)
    $map = Read-EscapeLedgerConsolidationMap -Path $Path
    return (Resolve-EscapeLedgerConsolidatedCommit -RepoRoot $RepoRoot -Map $map -SourceCommit $SourceCommit -HeadRef 'HEAD')
}

try {
    # --- 1. The committed map is real and does what it claims ------------------------------

    $map = $null
    $readError = $null
    try { $map = Read-EscapeLedgerConsolidationMap -Path $mapPath } catch { $readError = $_.Exception.Message }
    Assert-Consolidation ($null -eq $readError) "The committed consolidation map did not verify: $readError"
    if ($null -eq $map) { throw "The committed consolidation map at '$mapPath' could not be read; the rest of this suite has nothing to test." }

    Assert-Consolidation ([string]$map.mappingDigest -cmatch '^[0-9a-f]{64}$') 'The committed map carries no SHA-256 mapping digest.'
    Assert-Consolidation (@($map.lineageAnchors).Count -ge 1) 'The committed map declares no lineage anchor.'
    Assert-Consolidation (@($map.mappings).Count -ge 3) 'The committed map does not cover the three citations the frozen ledger needs.'

    foreach ($cited in @('fc11fae', 'cc5983c', '5a8f106')) {
        $outcome = Resolve-EscapeLedgerConsolidatedCommit -RepoRoot $RepoRoot -Map $map -SourceCommit $cited -HeadRef 'HEAD'
        Assert-Consolidation ([bool]$outcome.Accepted) "The committed map does not resolve the ledger citation $cited : $($outcome.Reason)"
        if ($outcome.Accepted) {
            Assert-Consolidation (Test-EscapeLedgerConsolidationAncestor -RepoRoot $RepoRoot -Ancestor $outcome.ReplacementCommit -Descendant 'HEAD') `
                "The replacement the map gives for $cited is not reachable from HEAD, so the map resolved to a commit this branch does not have."
            Assert-Consolidation (-not (Test-EscapeLedgerConsolidationAncestor -RepoRoot $RepoRoot -Ancestor $cited -Descendant 'HEAD')) `
                "The ledger citation $cited is directly reachable from HEAD, so this test is no longer exercising the mapping path at all."
        }
    }

    # The generator is the only sanctioned way to produce the map, and it reads every identity
    # from git. If a hand edit could survive -Check, the map would be editable prose.
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'New-EscapeLedgerConsolidationMap.ps1') -RepoRoot $RepoRoot -Check | Out-Null
    Assert-Consolidation ($LASTEXITCODE -eq 0) 'The committed consolidation map does not match what its generator produces from live git facts.'

    # --- 2. A commit nobody mapped is refused ----------------------------------------------

    foreach ($unmapped in @('8d66afc8b31b0878152de846ebf0ad8644c996e1', 'ccbf14632064118f008539becec2fef77030cf54', '0000000')) {
        $outcome = Resolve-EscapeLedgerConsolidatedCommit -RepoRoot $RepoRoot -Map $map -SourceCommit $unmapped -HeadRef 'HEAD'
        Assert-Consolidation (-not $outcome.Accepted) "The map resolved '$unmapped', which it does not name; acceptance is not restricted to exact entries."
    }

    # Case folding is a resolution convenience, never a way past the shape rules: an uppercase
    # object name inside the FILE is refused, while an uppercase QUERY still finds its entry.
    $upperOutcome = Resolve-EscapeLedgerConsolidatedCommit -RepoRoot $RepoRoot -Map $map -SourceCommit 'FC11FAE' -HeadRef 'HEAD'
    Assert-Consolidation ([bool]$upperOutcome.Accepted) 'An uppercase citation of a mapped commit was refused, so the ledger''s own casing decides whether evidence resolves.'
    $upperFile = New-MutatedMap -Name 'uppercase-object-name' -Reseal -Mutate {
        param($m) $m.mappings[0].sourceCommit = ([string]$m.mappings[0].sourceCommit).ToUpperInvariant()
    }
    Assert-Consolidation (Test-MapRefused -Path $upperFile) 'A map recording an uppercase object name was accepted, so the same commit could be named twice in two casings.'

    # --- 3. Editing an entry without resealing ---------------------------------------------

    # A mapping that carries no evidence proves nothing, and a RESEALED one is
    # the dangerous shape: the digest is honest, the delta identity is honest,
    # and neither of them covers the evidence list. For 'segmentConsolidation' -
    # the basis every committed mapping uses - anchor tree equality does not
    # apply either, so with the evidence gone the acceptance collapses to "both
    # commits fall in their segments", which any unrelated pair satisfies. This
    # is the fail-open a reviewer found by reading the loop rather than the data.
    $evidenceless = New-MutatedMap -Name 'evidence-stripped' -Reseal -Mutate {
        param($m) $m.mappings[0].carriedEvidence = @()
    }
    Assert-Consolidation (Test-MapRefused -Path $evidenceless) `
        'A resealed mapping carrying no evidence was accepted, so segment membership alone can carry an incident.'

    $unsealed = New-MutatedMap -Name 'edited-not-resealed' -Mutate {
        param($m) $m.mappings[0].replacementCommit = '0e8507f67b91e2d2c16bcbf3ee74c5ca39af0178'
    }
    Assert-Consolidation (Test-MapRefused -Path $unsealed) 'A map whose entry was edited without resealing was accepted; the digest is not load-bearing.'

    # --- 4. Resealing an edited entry: the delta identity must still object ------------------

    $resealedOnly = New-MutatedMap -Name 'resealed-stale-delta' -Reseal -Mutate {
        param($m) $m.mappings[0].replacementCommit = '0e8507f67b91e2d2c16bcbf3ee74c5ca39af0178'
    }
    Assert-Consolidation (Test-MapRefused -Path $resealedOnly) `
        'An entry was repointed at a different replacement commit and resealed, and the stale delta identity did not object; the four identities are separable.'

    # --- 5. A fabricated tree on a real commit ----------------------------------------------

    $wrongTree = New-MutatedMap -Name 'wrong-replacement-tree' -Reseal -Mutate {
        param($m)
        $m.mappings[0].replacementTree = '951ea73dca9d605983d78bcce6fb7d819bf482ed'
        $m.mappings[0].deltaIdentity = Get-EscapeLedgerConsolidationDeltaIdentity `
            -SourceCommit ([string]$m.mappings[0].sourceCommit) -SourceTree ([string]$m.mappings[0].sourceTree) `
            -ReplacementCommit ([string]$m.mappings[0].replacementCommit) -ReplacementTree ([string]$m.mappings[0].replacementTree) `
            -EquivalenceBasis ([string]$m.mappings[0].equivalenceBasis)
    }
    $wrongTreeOutcome = Get-ResolutionOutcome -Path $wrongTree -SourceCommit 'fc11fae'
    Assert-Consolidation (-not $wrongTreeOutcome.Accepted) `
        'A mapping recording a tree the replacement commit does not hold was accepted, so recorded trees are decoration.'
    Assert-Consolidation ([string]$wrongTreeOutcome.Reason -match 'not the tree the consolidation map recorded') `
        "A fabricated replacement tree was refused for the wrong reason: $($wrongTreeOutcome.Reason)"

    $wrongSourceTree = New-MutatedMap -Name 'wrong-source-tree' -Reseal -Mutate {
        param($m)
        $m.mappings[2].sourceTree = '6a0a443397f7117ce42f01dba3e872675890da6b'
        $m.mappings[2].deltaIdentity = Get-EscapeLedgerConsolidationDeltaIdentity `
            -SourceCommit ([string]$m.mappings[2].sourceCommit) -SourceTree ([string]$m.mappings[2].sourceTree) `
            -ReplacementCommit ([string]$m.mappings[2].replacementCommit) -ReplacementTree ([string]$m.mappings[2].replacementTree) `
            -EquivalenceBasis ([string]$m.mappings[2].equivalenceBasis)
    }
    $wrongSourceOutcome = Get-ResolutionOutcome -Path $wrongSourceTree -SourceCommit '5a8f106'
    Assert-Consolidation (-not $wrongSourceOutcome.Accepted) `
        'A mapping recording a tree the SOURCE commit does not hold was accepted, so a commit id could be reused against different content.'

    # --- 6. A real, correctly-treed commit from outside the consolidated segment --------------

    # dd9f661 is a genuine replacement-lineage commit with a genuine tree, reachable from HEAD.
    # It is also BEFORE the anchor this entry cites, so it is outside the range the
    # consolidation covered. The carried evidence is left exactly as the sealed map
    # records it, so this case turns purely on segment containment: the evidence would
    # also refuse dd9f661 (it does not carry those blobs), but containment is checked
    # first, which is what the reason assertion below pins down.
    $outsideSegment = New-MutatedMap -Name 'outside-replacement-segment' -Reseal -Mutate {
        param($m)
        $m.mappings[0].replacementCommit = 'dd9f661711936d7c124fccc89dbc1bc7a6388ec5'
        $m.mappings[0].replacementTree = '6a0a443397f7117ce42f01dba3e872675890da6b'
        $m.mappings[0].deltaIdentity = Get-EscapeLedgerConsolidationDeltaIdentity `
            -SourceCommit ([string]$m.mappings[0].sourceCommit) -SourceTree ([string]$m.mappings[0].sourceTree) `
            -ReplacementCommit ([string]$m.mappings[0].replacementCommit) -ReplacementTree ([string]$m.mappings[0].replacementTree) `
            -EquivalenceBasis ([string]$m.mappings[0].equivalenceBasis)
    }
    $outsideOutcome = Get-ResolutionOutcome -Path $outsideSegment -SourceCommit 'fc11fae'
    Assert-Consolidation (-not $outsideOutcome.Accepted) `
        'A replacement commit from outside the consolidated segment was accepted, so any reachable commit can stand in for the work.'
    Assert-Consolidation ([string]$outsideOutcome.Reason -match 'consolidated replacement segment') `
        "An out-of-segment replacement was refused for the wrong reason: $($outsideOutcome.Reason)"

    # And the same on the source side: a commit that predates the anchor is not in the range
    # the consolidation replaced, so it cannot be laundered through the map either.
    $outsideSource = New-MutatedMap -Name 'outside-source-segment' -Reseal -Mutate {
        param($m)
        $m.mappings[0].sourceCommit = 'ccbf14632064118f008539becec2fef77030cf54'
        $m.mappings[0].sourceTree = '6a0a443397f7117ce42f01dba3e872675890da6b'
        $m.mappings[0].deltaIdentity = Get-EscapeLedgerConsolidationDeltaIdentity `
            -SourceCommit ([string]$m.mappings[0].sourceCommit) -SourceTree ([string]$m.mappings[0].sourceTree) `
            -ReplacementCommit ([string]$m.mappings[0].replacementCommit) -ReplacementTree ([string]$m.mappings[0].replacementTree) `
            -EquivalenceBasis ([string]$m.mappings[0].equivalenceBasis)
    }
    $outsideSourceOutcome = Get-ResolutionOutcome -Path $outsideSource -SourceCommit 'ccbf146'
    Assert-Consolidation (-not $outsideSourceOutcome.Accepted) `
        'A source commit from outside the consolidated segment was accepted, so the map is a general-purpose ancestry bypass.'

    # --- 7. Breaking the anchor breaks everything that rests on it ---------------------------

    $brokenAnchor = New-MutatedMap -Name 'anchor-not-tree-equal' -Reseal -Mutate {
        param($m)
        foreach ($anchor in $m.lineageAnchors) {
            if ([string]$anchor.name -ceq 'reviewer-result-retries') {
                $anchor.replacementCommit = '64c2e3ae1136ccca04bba49e7b695a3bb85d964b'
            }
        }
    }
    $brokenAnchorOutcome = Get-ResolutionOutcome -Path $brokenAnchor -SourceCommit 'fc11fae'
    Assert-Consolidation (-not $brokenAnchorOutcome.Accepted) `
        'A mapping resting on an anchor that is not tree-equal was accepted, so the two lineages were never shown to be one history.'
    Assert-Consolidation ([string]$brokenAnchorOutcome.Reason -match 'tree-equal') `
        "A broken anchor was refused for the wrong reason: $($brokenAnchorOutcome.Reason)"

    $anchorTreeLie = New-MutatedMap -Name 'anchor-tree-lie' -Reseal -Mutate {
        param($m)
        foreach ($anchor in $m.lineageAnchors) {
            if ([string]$anchor.name -ceq 'reviewer-result-retries') { $anchor.tree = '6a0a443397f7117ce42f01dba3e872675890da6b' }
        }
    }
    $anchorLieOutcome = Get-ResolutionOutcome -Path $anchorTreeLie -SourceCommit 'fc11fae'
    Assert-Consolidation (-not $anchorLieOutcome.Accepted) `
        'An anchor recording a tree neither of its commits holds was accepted, so the anchor tree is not checked against git.'

    $unknownAnchor = New-MutatedMap -Name 'unknown-anchor' -Reseal -Mutate {
        param($m) $m.mappings[0].anchor = 'no-such-anchor'
    }
    Assert-Consolidation (Test-MapRefused -Path $unknownAnchor) `
        'A mapping citing an anchor the map does not declare was accepted, so an entry can rest on nothing.'

    # --- 8. Carried evidence is content, and content is checked ------------------------------

    $evidenceLie = New-MutatedMap -Name 'evidence-blob-lie' -Reseal -Mutate {
        param($m) $m.mappings[0].carriedEvidence[0].blob = '43368f4025283bf9d43784cc256f0734e22fd4a3'
    }
    $evidenceOutcome = Get-ResolutionOutcome -Path $evidenceLie -SourceCommit 'fc11fae'
    Assert-Consolidation (-not $evidenceOutcome.Accepted) `
        'A mapping whose carried-evidence blob does not match the replacement commit was accepted, so the carry claim is unchecked.'

    $evidencePathLie = New-MutatedMap -Name 'evidence-path-lie' -Reseal -Mutate {
        param($m) $m.mappings[0].carriedEvidence[0].path = 'tools/Test-EscapeLedger.ps1'
    }
    $evidencePathOutcome = Get-ResolutionOutcome -Path $evidencePathLie -SourceCommit 'fc11fae'
    Assert-Consolidation (-not $evidencePathOutcome.Accepted) `
        'A carried-evidence path was swapped for another real file and still accepted, so path and blob are not checked together.'

    # --- 9. Duplicates, deletions and shape widening -----------------------------------------

    $duplicate = New-MutatedMap -Name 'duplicate-source' -Reseal -Mutate {
        param($m)
        $clone = ($m.mappings[0] | ConvertTo-Json -Depth 32) | ConvertFrom-Json -Depth 32
        $clone.replacementCommit = '3149955f1268012b2af159c0dbe7ae6582f07aa3'
        $clone.replacementTree = '951ea73dca9d605983d78bcce6fb7d819bf482ed'
        $clone.carriedEvidence = @()
        $clone.deltaIdentity = Get-EscapeLedgerConsolidationDeltaIdentity `
            -SourceCommit ([string]$clone.sourceCommit) -SourceTree ([string]$clone.sourceTree) `
            -ReplacementCommit ([string]$clone.replacementCommit) -ReplacementTree ([string]$clone.replacementTree) `
            -EquivalenceBasis ([string]$clone.equivalenceBasis)
        $m.mappings = @(@($m.mappings) + @($clone))
    }
    Assert-Consolidation (Test-MapRefused -Path $duplicate) `
        'A map naming one source commit twice was accepted, so which replacement a citation resolves to depends on search order.'

    $deleted = New-MutatedMap -Name 'missing-mapping' -Reseal -Mutate {
        param($m) $m.mappings = @(@($m.mappings) | Where-Object { -not ([string]$_.sourceCommit).StartsWith('5a8f106') })
    }
    $deletedOutcome = Get-ResolutionOutcome -Path $deleted -SourceCommit '5a8f106'
    Assert-Consolidation (-not $deletedOutcome.Accepted) 'A deleted mapping still resolved, so entries are not what acceptance depends on.'
    Assert-Consolidation ([string]$deletedOutcome.Reason -match 'no entry') `
        "A missing mapping was refused for the wrong reason: $($deletedOutcome.Reason)"

    $widened = New-MutatedMap -Name 'extra-field' -Reseal -Mutate {
        param($m) $m | Add-Member -NotePropertyName 'trustMe' -NotePropertyValue 'yes'
    }
    Assert-Consolidation (Test-MapRefused -Path $widened) `
        'A map carrying a field this build does not verify was accepted, which is how an unchecked escape hatch is added later.'

    $wrongKind = New-MutatedMap -Name 'wrong-kind' -Reseal -Mutate { param($m) $m.kind = 'something-else' }
    Assert-Consolidation (Test-MapRefused -Path $wrongKind) 'A map declaring a different kind was accepted.'

    $wrongVersion = New-MutatedMap -Name 'wrong-mapping-version' -Reseal -Mutate { param($m) $m.mappingVersion = 2 }
    Assert-Consolidation (Test-MapRefused -Path $wrongVersion) `
        'A map declaring a mapping version this build does not verify was accepted, so a future format would be read with today''s rules.'

    $badBasis = New-MutatedMap -Name 'unknown-basis' -Reseal -Mutate {
        param($m)
        $m.mappings[0].equivalenceBasis = 'trustTheAuthor'
        $m.mappings[0].deltaIdentity = Get-EscapeLedgerConsolidationDeltaIdentity `
            -SourceCommit ([string]$m.mappings[0].sourceCommit) -SourceTree ([string]$m.mappings[0].sourceTree) `
            -ReplacementCommit ([string]$m.mappings[0].replacementCommit) -ReplacementTree ([string]$m.mappings[0].replacementTree) `
            -EquivalenceBasis ([string]$m.mappings[0].equivalenceBasis)
    }
    Assert-Consolidation (Test-MapRefused -Path $badBasis) 'A map declaring an equivalence basis this build does not implement was accepted.'

    # A treeEquality claim is held to tree equality. Declaring the strongest basis over a pair
    # that does not hold it must fail, or the basis field is a label rather than a claim.
    $falseTreeEquality = New-MutatedMap -Name 'false-tree-equality' -Reseal -Mutate {
        param($m)
        $m.mappings[0].equivalenceBasis = 'treeEquality'
        $m.mappings[0].deltaIdentity = Get-EscapeLedgerConsolidationDeltaIdentity `
            -SourceCommit ([string]$m.mappings[0].sourceCommit) -SourceTree ([string]$m.mappings[0].sourceTree) `
            -ReplacementCommit ([string]$m.mappings[0].replacementCommit) -ReplacementTree ([string]$m.mappings[0].replacementTree) `
            -EquivalenceBasis ([string]$m.mappings[0].equivalenceBasis)
    }
    $falseEqualityOutcome = Get-ResolutionOutcome -Path $falseTreeEquality -SourceCommit 'fc11fae'
    Assert-Consolidation (-not $falseEqualityOutcome.Accepted) `
        'An entry declaring tree equality over two different trees was accepted, so the basis field claims nothing.'

    # --- 10. A missing map is a refusal, not a pass ------------------------------------------

    $absent = Join-Path $scratch 'not-written.json'
    Assert-Consolidation (Test-MapRefused -Path $absent) 'A missing consolidation map was treated as readable.'
    Assert-Consolidation (-not (Test-EscapeLedgerCommitReachableThroughConsolidation -RepoRoot $RepoRoot -Commit 'fc11fae' -HeadRef 'HEAD' -Map $null)) `
        'With no map at all, an unreachable citation was still reported as present in this branch.'
    Assert-Consolidation (Test-EscapeLedgerCommitReachableThroughConsolidation -RepoRoot $RepoRoot -Commit 'HEAD' -HeadRef 'HEAD' -Map $null) `
        'A commit that is directly reachable was reported as absent, so the unchanged fast path is broken.'

    # --- 11. The map moves no budget --------------------------------------------------------

    # Reachability is the only question the map answers. If introducing it had changed what the
    # budget counts - a near miss becoming an escape, a category total moving - the trigger
    # verdict or the qualifying count would differ between the two modes. They must not.
    $ledgerScript = Join-Path $PSScriptRoot 'Test-EscapeLedger.ps1'
    $withoutCommits = (& pwsh -NoProfile -File $ledgerScript) | Where-Object { $_ -match '^\{' } | Select-Object -First 1
    $withCommits = (& pwsh -NoProfile -File $ledgerScript -VerifyCommits) | Where-Object { $_ -match '^\{' } | Select-Object -First 1
    Assert-Consolidation ($LASTEXITCODE -eq 0) 'The escape ledger did not pass with commit verification enabled.'
    $plain = $withoutCommits | ConvertFrom-Json
    $verified = $withCommits | ConvertFrom-Json
    foreach ($field in @('triggered', 'qualifyingCount', 'inWindow', 'typeBinding', 'reachedShadowOrLive', 'remediated', 'openDebt', 'nearMisses')) {
        Assert-Consolidation (([string]$plain.$field) -eq ([string]$verified.$field)) `
            "The ledger's $field differs with commit verification on ($($plain.$field) versus $($verified.$field)); the consolidation path is moving what the budget counts."
    }
    Assert-Consolidation ([string]$verified.coverageWindowBoundaryVia -eq 'consolidation') `
        'The coverage window boundary did not resolve through the consolidation map, so this branch is not exercising the migration it ships.'
    Assert-Consolidation ([int]$verified.commitsBehindHead -ge 0) 'The staleness clock was not measured against a boundary this branch carries.'
    Assert-Consolidation ([int]$verified.commitsBehindHead -le [int](([IO.File]::ReadAllText((Join-Path $RepoRoot 'docs/escape-ledger.v2.json')) | ConvertFrom-Json).coverageWindow.staleAfterCommitsBehindHead)) `
        'The coverage window is past its declared staleness bound when measured from the replacement boundary.'
}
finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

$report = [ordered]@{
    check    = 'reviewer-escape-ledger-consolidation'
    mapPath  = 'docs/escape-ledger-consolidation.v1.json'
    digest   = [string]$map.mappingDigest
    mappings = @($map.mappings).Count
    anchors  = @($map.lineageAnchors).Count
    checks   = $script:Checks
    failed   = $script:Failures.Count
}
Write-Output ($report | ConvertTo-Json -Depth 6 -Compress)

if ($script:Failures.Count -gt 0) {
    $detail = ($script:Failures | ForEach-Object { " - $_" }) -join [Environment]::NewLine
    throw "Escape-ledger consolidation validation failed $($script:Failures.Count) check(s):$([Environment]::NewLine)$detail"
}

Write-Host "PASS: escape-ledger consolidation map ($($script:Checks) checks, $(@($map.mappings).Count) mapping(s))."
