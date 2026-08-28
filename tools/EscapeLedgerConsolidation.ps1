#Requires -Version 7.0

<#
.SYNOPSIS
    The versioned escape-ledger consolidation map: how a commit named by a frozen
    ledger record is located in the replacement lineage that replaced the history
    the record was written against.

.DESCRIPTION
    WHY THIS FILE EXISTS. The escape ledger is an append-only record of defects.
    Every incident and near miss cites the commit that introduced it and the
    commit that remediated it, and those citations are IMMUTABLE: they are the
    evidence, and evidence that is rewritten whenever the branch is rearranged is
    not evidence at all.

    The ledger's validator also asks git a question about those citations - is
    this commit reachable from HEAD? - to catch a record that describes a history
    this branch does not have. That question was correct while there was one
    history. When the reviewer stack was consolidated, one hundred and
    forty-eight commits were replaced by five, and three citations that had
    always been true became unreachable:

        NM-0001 introducedCommit fc11fae
        NM-0002 introducedCommit cc5983c
        coverageWindow.endCommit 5a8f106

    There were two dishonest ways out and this file takes neither. Rewriting the
    citations to name replacement commits would falsify the record. Dropping the
    reachability check would remove the contradiction detector that makes the
    record falsifiable at all.

    WHAT REPLACES IT. A committed, versioned, digest-sealed map that states
    explicitly which replacement commit carries the work of which source commit,
    and a verifier that will accept a source commit ONLY through an exact entry
    in that map whose identities it recomputes from git. The map is a claim; the
    identities are proof obligations discharged here, not assertions the map is
    trusted for.

    WHAT IS ACTUALLY PROVEN. For every accepted source commit, all of:

      1. the map self-verifies: closed shape, declared kind and mapping version,
         and a recomputed domain-separated digest over its own canonical form. An
         edited map fails here, so an entry cannot be added by hand.

      2. the two lineages share a declared common base commit, and that commit is
         an ancestor of both declared heads. Two unrelated histories cannot be
         bridged.

      3. every declared anchor is TREE-EQUAL: the source anchor commit and the
         replacement anchor commit resolve, from git, to the same tree object.
         This is the load-bearing fact. It proves the replacement lineage is not
         merely a plausible retelling: at the anchor the two histories hold byte
         for byte the same working tree, so everything before the anchor is
         carried exactly.

      4. the source commit lies inside the declared source segment - at or after
         an anchor's source side, at or before the declared source head - and the
         replacement commit lies inside the declared replacement segment. A
         commit from outside the consolidated range cannot be laundered through
         the map.

      5. the recorded source tree and replacement tree equal the trees git
         reports for those commits. A commit id reused against different content
         fails here, and so does an entry that names a real commit with a
         fabricated tree.

      6. the replacement commit is reachable from the checkout being validated.
         The map cannot make a claim about a branch that does not contain it.

      7. the entry's deltaIdentity recomputes: a domain-separated digest over the
         (source commit, source tree, replacement commit, replacement tree,
         basis) tuple. This binds the four identities together so that no field
         of an entry can be edited independently of the others.

      8. every carriedEvidence path resolves, in the REPLACEMENT commit, to
         exactly the blob the map recorded. These are the files the ledger
         record's own regressionGuard prose names. It is the closest thing to a
         content-level carry proof that survives a squash.

    WHAT THIS DELIBERATELY DOES NOT CLAIM. It does not claim the source commit's
    diff is byte-identical to any part of the replacement commit's diff. It is
    not. A squash of one hundred and forty-eight commits into five does not
    preserve per-commit deltas, and this was measured rather than assumed:
    changed-path blob identity between the source commits and their replacements
    is between zero and four paths out of fifteen to nineteen. Calling the
    resulting digest a "delta proof" would be a lie, so it is named
    deltaIdentity and documented as what it is - a binding over four verified
    identities plus a declared basis.

    NOTHING HERE RECLASSIFIES. The map is consulted at exactly two places in the
    ledger validator: the near-miss "is this branch containing the change you
    describe" question, and the coverage window's end-commit question. Every
    other use of git in that validator - in particular the merged-versus-not
    baseline that decides whether a finding is an escape or a near miss - keeps
    using strict ancestry with no map in the path. A mapping can therefore never
    turn a near miss into an escape, or an escape into a near miss, or move a
    record between budget categories.
#>

Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Agents/reviewer/ReviewerBaseContract.ps1')

$script:EscapeLedgerConsolidationKind = 'reviewer-escape-ledger-consolidation-map'
$script:EscapeLedgerConsolidationMappingVersion = 1
# Domain separation. The map digest and the per-entry delta identity live in
# distinct label spaces so that neither can be produced by hashing the other, or
# by hashing any other sealed document in this repository.
$script:EscapeLedgerConsolidationDigestLabel = 'devpilot.reviewer.escape-ledger.consolidation.map.v1'
$script:EscapeLedgerConsolidationDeltaLabel = 'devpilot.reviewer.escape-ledger.consolidation.delta.v1'
$script:EscapeLedgerConsolidationRelativePath = 'docs/escape-ledger-consolidation.v1.json'
$script:EscapeLedgerConsolidationUtf8 = [Text.UTF8Encoding]::new($false, $true)

# Closed key sets. A map that grew a field this build does not verify would
# otherwise be accepted with that field unchecked, which is the shape an
# unverified escape hatch takes when it is added later.
$script:EscapeLedgerConsolidationTopLevelKeys = @(
    'commonBaseCommit', 'description', 'kind', 'lineageAnchors', 'mappingDigest',
    'mappingVersion', 'mappings', 'replacementLineage', 'schemaVersion', 'sourceLineage'
)
$script:EscapeLedgerConsolidationLineageKeys = @('headCommit', 'headTree', 'name')
$script:EscapeLedgerConsolidationAnchorKeys = @('name', 'replacementCommit', 'sourceCommit', 'tree')
$script:EscapeLedgerConsolidationMappingKeys = @(
    'anchor', 'carriedEvidence', 'deltaIdentity', 'equivalenceBasis', 'note',
    'replacementCommit', 'replacementTree', 'sourceCommit', 'sourceSubject', 'sourceTree'
)
$script:EscapeLedgerConsolidationEvidenceKeys = @('blob', 'path')
$script:EscapeLedgerConsolidationBases = @('treeEquality', 'segmentConsolidation')

function Get-EscapeLedgerConsolidationDefaultPath {
    <#
    .SYNOPSIS
        The committed map's path under a repository root.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)
    return (Join-Path $RepoRoot ($script:EscapeLedgerConsolidationRelativePath -replace '/', [IO.Path]::DirectorySeparatorChar))
}

function Get-EscapeLedgerConsolidationDigest {
    <#
    .SYNOPSIS
        The domain-separated digest over a map, excluding its own digest field.
    .DESCRIPTION
        The canonical writer is borrowed from the reviewer base contract rather
        than duplicated. That writer is itself one of the base contract's bound
        artifacts, so it is hash-pinned; a second hand-maintained copy would be
        one more thing that can drift. Domain separation comes from the label in
        the preimage, not from having a separate serialiser.
    #>
    param([Parameter(Mandatory)]$Map)
    $copy = [ordered]@{}
    foreach ($name in @(@($Map.PSObject.Properties | ForEach-Object { [string]$_.Name }) | Sort-Object -CaseSensitive)) {
        if ($name -ceq 'mappingDigest') { continue }
        $copy[$name] = $Map.PSObject.Properties[$name].Value
    }
    $preimage = $script:EscapeLedgerConsolidationDigestLabel + "`n" +
    (ConvertTo-ReviewerBaseContractCanonicalText -Value $copy)
    $bytes = $script:EscapeLedgerConsolidationUtf8.GetBytes($preimage)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function Get-EscapeLedgerConsolidationDeltaIdentity {
    <#
    .SYNOPSIS
        The binding over one mapping entry's four object identities and its basis.
    .DESCRIPTION
        Deliberately NOT a proof that the source diff survives in the replacement
        diff - a squash does not preserve per-commit deltas and this repository
        measured that it did not. What it does is make the four identities
        inseparable: changing any one of them, or the declared basis, changes the
        digest, so an entry cannot be half-edited into naming a different
        replacement commit while keeping a trusted-looking source side.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$SourceTree,
        [Parameter(Mandatory)][string]$ReplacementCommit,
        [Parameter(Mandatory)][string]$ReplacementTree,
        [Parameter(Mandatory)][string]$EquivalenceBasis
    )
    $preimage = $script:EscapeLedgerConsolidationDeltaLabel + "`n" + (@(
            $SourceCommit.ToLowerInvariant(), $SourceTree.ToLowerInvariant(),
            $ReplacementCommit.ToLowerInvariant(), $ReplacementTree.ToLowerInvariant(),
            $EquivalenceBasis) -join "`n")
    $bytes = $script:EscapeLedgerConsolidationUtf8.GetBytes($preimage)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function Read-EscapeLedgerConsolidationMap {
    <#
    .SYNOPSIS
        Reads and self-verifies the committed map, or refuses.
    .DESCRIPTION
        Shape is checked as a closed set before the digest, so a map carrying an
        extra field is refused by name rather than by a digest mismatch that says
        nothing about what changed. Duplicate source commits are refused here:
        one source commit resolves to one replacement commit or to none, never to
        whichever entry a search happens to reach first.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The escape-ledger consolidation map '$Path' does not exist, so no pre-consolidation commit can be resolved."
    }
    $map = $null
    try {
        $map = [IO.File]::ReadAllText($Path, $script:EscapeLedgerConsolidationUtf8) | ConvertFrom-Json -Depth 32
    }
    catch {
        throw "The escape-ledger consolidation map '$Path' could not be read: $($_.Exception.Message)"
    }
    if ($null -eq $map) { throw "The escape-ledger consolidation map '$Path' is empty." }

    $names = @(@($map.PSObject.Properties | ForEach-Object { [string]$_.Name }) | Sort-Object -CaseSensitive)
    $expected = @(@($script:EscapeLedgerConsolidationTopLevelKeys) | Sort-Object -CaseSensitive)
    if (($names -join "`n") -cne ($expected -join "`n")) {
        throw ("The escape-ledger consolidation map '$Path' has an unexpected top-level shape: " +
            "[$($names -join ', ')] rather than [$($expected -join ', ')].")
    }
    if ([string]$map.kind -cne $script:EscapeLedgerConsolidationKind) {
        throw "The escape-ledger consolidation map '$Path' declares kind '$([string]$map.kind)'."
    }
    if ([int]$map.schemaVersion -ne 1) {
        throw "The escape-ledger consolidation map '$Path' declares schema version $([int]$map.schemaVersion), which this build does not verify."
    }
    if ([int]$map.mappingVersion -ne $script:EscapeLedgerConsolidationMappingVersion) {
        throw "The escape-ledger consolidation map '$Path' declares mapping version $([int]$map.mappingVersion), which this build does not verify."
    }
    if ([string]$map.commonBaseCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw "The escape-ledger consolidation map '$Path' names common base '$([string]$map.commonBaseCommit)', which is not a full lowercase object name."
    }

    foreach ($side in @('sourceLineage', 'replacementLineage')) {
        $lineage = $map.PSObject.Properties[$side].Value
        $lineageNames = @(@($lineage.PSObject.Properties | ForEach-Object { [string]$_.Name }) | Sort-Object -CaseSensitive)
        $expectedLineage = @(@($script:EscapeLedgerConsolidationLineageKeys) | Sort-Object -CaseSensitive)
        if (($lineageNames -join "`n") -cne ($expectedLineage -join "`n")) {
            throw "The '$side' of the escape-ledger consolidation map '$Path' has an unexpected shape: [$($lineageNames -join ', ')]."
        }
        foreach ($field in @('headCommit', 'headTree')) {
            if ([string]$lineage.PSObject.Properties[$field].Value -cnotmatch '^[0-9a-f]{40}$') {
                throw "The '$side' of '$Path' names $field '$([string]$lineage.PSObject.Properties[$field].Value)', which is not a full lowercase object name."
            }
        }
        if ([string]$lineage.name -notmatch '\S') {
            throw "The '$side' of '$Path' is unnamed."
        }
    }

    if (@($map.lineageAnchors).Count -lt 1) {
        throw "The escape-ledger consolidation map '$Path' declares no lineage anchor, so the two histories are never shown to be the same history."
    }
    $anchorNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($anchor in @($map.lineageAnchors)) {
        $keys = @(@($anchor.PSObject.Properties | ForEach-Object { [string]$_.Name }) | Sort-Object -CaseSensitive)
        $expectedKeys = @(@($script:EscapeLedgerConsolidationAnchorKeys) | Sort-Object -CaseSensitive)
        if (($keys -join "`n") -cne ($expectedKeys -join "`n")) {
            throw "An anchor in '$Path' has an unexpected shape: [$($keys -join ', ')]."
        }
        foreach ($field in @('sourceCommit', 'replacementCommit', 'tree')) {
            if ([string]$anchor.PSObject.Properties[$field].Value -cnotmatch '^[0-9a-f]{40}$') {
                throw "An anchor in '$Path' names $field '$([string]$anchor.PSObject.Properties[$field].Value)', which is not a full lowercase object name."
            }
        }
        if (-not $anchorNames.Add([string]$anchor.name)) {
            throw "The escape-ledger consolidation map '$Path' declares two anchors named '$([string]$anchor.name)'."
        }
    }

    if (@($map.mappings).Count -lt 1) {
        throw "The escape-ledger consolidation map '$Path' declares no mapping."
    }
    $seenSources = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($mapping in @($map.mappings)) {
        $keys = @(@($mapping.PSObject.Properties | ForEach-Object { [string]$_.Name }) | Sort-Object -CaseSensitive)
        $expectedKeys = @(@($script:EscapeLedgerConsolidationMappingKeys) | Sort-Object -CaseSensitive)
        if (($keys -join "`n") -cne ($expectedKeys -join "`n")) {
            throw "A mapping in '$Path' has an unexpected shape: [$($keys -join ', ')]."
        }
        foreach ($field in @('sourceCommit', 'sourceTree', 'replacementCommit', 'replacementTree')) {
            if ([string]$mapping.PSObject.Properties[$field].Value -cnotmatch '^[0-9a-f]{40}$') {
                throw "A mapping in '$Path' names $field '$([string]$mapping.PSObject.Properties[$field].Value)', which is not a full lowercase object name."
            }
        }
        if ([string]$mapping.deltaIdentity -cnotmatch '^[0-9a-f]{64}$') {
            throw "A mapping in '$Path' names delta identity '$([string]$mapping.deltaIdentity)', which is not a SHA-256 hex digest."
        }
        if ([string]$mapping.equivalenceBasis -cnotin $script:EscapeLedgerConsolidationBases) {
            throw ("A mapping in '$Path' declares equivalence basis '$([string]$mapping.equivalenceBasis)', " +
                "which is not one of [$($script:EscapeLedgerConsolidationBases -join ', ')].")
        }
        if (-not $anchorNames.Contains([string]$mapping.anchor)) {
            throw "A mapping in '$Path' cites anchor '$([string]$mapping.anchor)', which the map does not declare."
        }
        if (-not $seenSources.Add(([string]$mapping.sourceCommit).ToLowerInvariant())) {
            throw ("The escape-ledger consolidation map '$Path' maps source commit " +
                "'$([string]$mapping.sourceCommit)' more than once; a source commit resolves to one replacement or to none.")
        }
        # AT LEAST ONE, ALWAYS. For 'segmentConsolidation' - the basis every
        # mapping in the committed map uses - the anchor tree-equality check does
        # not apply, so carried evidence is the ONLY content-level link between a
        # source commit and the replacement claimed to carry it. An empty list
        # makes the acceptance loop below run zero times and fall through to
        # accepted, reducing the whole proof to "both commits are somewhere in
        # their respective segments", which any unrelated pair satisfies. The
        # delta identity does not close it either: it binds the two commits and
        # their trees, not the evidence. This mirrors the reviewer base
        # contract's refusal of an empty bound-artifact list, and for the same
        # reason - a binding that binds nothing is not a binding.
        if (@($mapping.carriedEvidence).Count -lt 1) {
            throw ("The mapping for source commit '$([string]$mapping.sourceCommit)' in '$Path' carries no evidence, " +
                'so nothing links it to its replacement except the segment ranges both happen to fall in. ' +
                'A mapping must name at least one blob the replacement demonstrably carries.')
        }
        foreach ($evidence in @($mapping.carriedEvidence)) {
            $evidenceKeys = @(@($evidence.PSObject.Properties | ForEach-Object { [string]$_.Name }) | Sort-Object -CaseSensitive)
            $expectedEvidence = @(@($script:EscapeLedgerConsolidationEvidenceKeys) | Sort-Object -CaseSensitive)
            if (($evidenceKeys -join "`n") -cne ($expectedEvidence -join "`n")) {
                throw "A carried-evidence entry in '$Path' has an unexpected shape: [$($evidenceKeys -join ', ')]."
            }
            if ([string]$evidence.blob -cnotmatch '^[0-9a-f]{40}$') {
                throw "A carried-evidence entry in '$Path' names blob '$([string]$evidence.blob)', which is not a full lowercase object name."
            }
            if ([string]$evidence.path -notmatch '^[A-Za-z0-9._/-]+$') {
                throw "A carried-evidence entry in '$Path' names path '$([string]$evidence.path)', which is not a plain repository path."
            }
        }
        $expectedDelta = Get-EscapeLedgerConsolidationDeltaIdentity `
            -SourceCommit ([string]$mapping.sourceCommit) -SourceTree ([string]$mapping.sourceTree) `
            -ReplacementCommit ([string]$mapping.replacementCommit) -ReplacementTree ([string]$mapping.replacementTree) `
            -EquivalenceBasis ([string]$mapping.equivalenceBasis)
        if ([string]$mapping.deltaIdentity -cne $expectedDelta) {
            throw ("The mapping for source commit '$([string]$mapping.sourceCommit)' in '$Path' carries a delta identity " +
                'that does not bind the identities it records; the entry was edited after it was sealed.')
        }
    }

    $recomputed = Get-EscapeLedgerConsolidationDigest -Map $map
    if ([string]$map.mappingDigest -cne $recomputed) {
        throw ("The escape-ledger consolidation map '$Path' does not match its own digest " +
            "(recorded $([string]$map.mappingDigest), recomputed $recomputed); regenerate it with tools/New-EscapeLedgerConsolidationMap.ps1.")
    }
    return $map
}

function Invoke-EscapeLedgerConsolidationGit {
    <#
    .SYNOPSIS
        One git invocation whose exit status is inspected rather than assumed.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $output = & git -C $RepoRoot @Arguments 2>$null
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = (@($output) -join "`n").Trim()
    }
}

function Get-EscapeLedgerConsolidationTree {
    <#
    .SYNOPSIS
        The tree a commit resolves to, or $null when the object is absent.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Commit)
    $result = Invoke-EscapeLedgerConsolidationGit -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', "$Commit^{tree}")
    if ($result.ExitCode -ne 0 -or $result.Output -cnotmatch '^[0-9a-f]{40}$') { return $null }
    return $result.Output
}

function Test-EscapeLedgerConsolidationAncestor {
    <#
    .SYNOPSIS
        Strict ancestry, with a present-object precondition so a missing object is
        reported as missing rather than as "not an ancestor".
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Ancestor,
        [Parameter(Mandatory)][string]$Descendant
    )
    foreach ($commit in @($Ancestor, $Descendant)) {
        $probe = Invoke-EscapeLedgerConsolidationGit -RepoRoot $RepoRoot -Arguments @('cat-file', '-e', "$commit^{commit}")
        if ($probe.ExitCode -ne 0) { return $false }
    }
    $result = Invoke-EscapeLedgerConsolidationGit -RepoRoot $RepoRoot -Arguments @('merge-base', '--is-ancestor', $Ancestor, $Descendant)
    return ($result.ExitCode -eq 0)
}

function Resolve-EscapeLedgerConsolidatedCommit {
    <#
    .SYNOPSIS
        Resolves a pre-consolidation commit to its replacement, discharging every
        proof obligation, or returns a typed refusal.

    .DESCRIPTION
        Returns an object with Accepted, ReplacementCommit and Reason. Callers get
        a reason on refusal so a ledger failure names the specific obligation that
        was not met - missing entry, wrong tree, unreachable replacement, broken
        anchor - rather than saying only that a commit is not reachable.

        Short source citations are supported because the ledger records them that
        way (fc11fae, cc5983c). A short name is resolved against the map's full
        object names by unambiguous prefix; two entries sharing a prefix are a
        refusal, never a guess.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Map,
        [Parameter(Mandatory)][string]$SourceCommit,
        [string]$HeadRef = 'HEAD'
    )
    $refuse = { param([string]$Reason) [pscustomobject]@{ Accepted = $false; ReplacementCommit = $null; Reason = $Reason; Basis = $null } }
    $needle = $SourceCommit.Trim().ToLowerInvariant()
    if ($needle -cnotmatch '^[0-9a-f]{7,40}$') {
        return (& $refuse "'$SourceCommit' is not an object name the consolidation map can resolve.")
    }
    $candidates = @(@($Map.mappings) | Where-Object { ([string]$_.sourceCommit).ToLowerInvariant().StartsWith($needle, [StringComparison]::Ordinal) })
    if ($candidates.Count -eq 0) {
        return (& $refuse "the consolidation map has no entry for source commit '$SourceCommit'")
    }
    if ($candidates.Count -gt 1) {
        return (& $refuse "source commit '$SourceCommit' matches $($candidates.Count) consolidation entries, so it names no single replacement")
    }
    $entry = $candidates[0]
    $sourceCommitFull = ([string]$entry.sourceCommit).ToLowerInvariant()
    $replacementCommitFull = ([string]$entry.replacementCommit).ToLowerInvariant()

    $anchor = @(@($Map.lineageAnchors) | Where-Object { [string]$_.name -ceq [string]$entry.anchor })[0]
    $anchorSourceTree = Get-EscapeLedgerConsolidationTree -RepoRoot $RepoRoot -Commit ([string]$anchor.sourceCommit)
    $anchorReplacementTree = Get-EscapeLedgerConsolidationTree -RepoRoot $RepoRoot -Commit ([string]$anchor.replacementCommit)
    if ($null -eq $anchorSourceTree -or $null -eq $anchorReplacementTree) {
        return (& $refuse "anchor '$([string]$anchor.name)' names a commit this checkout does not contain, so the two lineages are not shown to be the same history")
    }
    if ($anchorSourceTree -cne $anchorReplacementTree -or $anchorSourceTree -cne ([string]$anchor.tree).ToLowerInvariant()) {
        return (& $refuse "anchor '$([string]$anchor.name)' is not tree-equal in this checkout, so the replacement lineage is not shown to carry the source lineage")
    }

    # The common base must be an ancestor of both heads. Without it two unrelated
    # histories could be declared to be one, and every downstream check would
    # still pass because each side is internally consistent.
    foreach ($head in @([string]$Map.sourceLineage.headCommit, [string]$Map.replacementLineage.headCommit)) {
        if (-not (Test-EscapeLedgerConsolidationAncestor -RepoRoot $RepoRoot -Ancestor ([string]$Map.commonBaseCommit) -Descendant $head)) {
            return (& $refuse "the declared common base is not an ancestor of '$head', so the map bridges two histories that never met")
        }
    }

    $sourceTree = Get-EscapeLedgerConsolidationTree -RepoRoot $RepoRoot -Commit $sourceCommitFull
    if ($null -eq $sourceTree) {
        return (& $refuse "source commit '$sourceCommitFull' is not an object in this checkout")
    }
    if ($sourceTree -cne ([string]$entry.sourceTree).ToLowerInvariant()) {
        return (& $refuse "source commit '$sourceCommitFull' holds tree $sourceTree, not the tree the consolidation map recorded")
    }
    $replacementTree = Get-EscapeLedgerConsolidationTree -RepoRoot $RepoRoot -Commit $replacementCommitFull
    if ($null -eq $replacementTree) {
        return (& $refuse "replacement commit '$replacementCommitFull' is not an object in this checkout")
    }
    if ($replacementTree -cne ([string]$entry.replacementTree).ToLowerInvariant()) {
        return (& $refuse "replacement commit '$replacementCommitFull' holds tree $replacementTree, not the tree the consolidation map recorded")
    }

    # Segment containment. The source side must sit between its anchor and the
    # declared source head, and the replacement side between the same anchor's
    # replacement and the declared replacement head. This is what stops an
    # arbitrary commit - including one carrying an identical subject line - from
    # being mapped in: it has to be inside the range the consolidation covered.
    if (-not (Test-EscapeLedgerConsolidationAncestor -RepoRoot $RepoRoot -Ancestor ([string]$anchor.sourceCommit) -Descendant $sourceCommitFull)) {
        return (& $refuse "source commit '$sourceCommitFull' is not inside the consolidated source segment")
    }
    if (-not (Test-EscapeLedgerConsolidationAncestor -RepoRoot $RepoRoot -Ancestor $sourceCommitFull -Descendant ([string]$Map.sourceLineage.headCommit))) {
        return (& $refuse "source commit '$sourceCommitFull' is not at or before the declared source head")
    }
    if (-not (Test-EscapeLedgerConsolidationAncestor -RepoRoot $RepoRoot -Ancestor ([string]$anchor.replacementCommit) -Descendant $replacementCommitFull)) {
        return (& $refuse "replacement commit '$replacementCommitFull' is not inside the consolidated replacement segment")
    }
    if (-not (Test-EscapeLedgerConsolidationAncestor -RepoRoot $RepoRoot -Ancestor $replacementCommitFull -Descendant ([string]$Map.replacementLineage.headCommit))) {
        return (& $refuse "replacement commit '$replacementCommitFull' is not at or before the declared replacement head")
    }

    if ([string]$entry.equivalenceBasis -ceq 'treeEquality' -and $sourceTree -cne $replacementTree) {
        return (& $refuse "the mapping for '$sourceCommitFull' declares tree equality, but the two commits hold different trees")
    }

    # The replacement side has to be in the branch actually being validated.
    # Everything above is a statement about two recorded lineages; this is the
    # statement about THIS checkout, and it is the one the ledger's original
    # reachability question was asking.
    if (-not (Test-EscapeLedgerConsolidationAncestor -RepoRoot $RepoRoot -Ancestor $replacementCommitFull -Descendant $HeadRef)) {
        return (& $refuse "replacement commit '$replacementCommitFull' is not reachable from $HeadRef")
    }

    foreach ($evidence in @($entry.carriedEvidence)) {
        $probe = Invoke-EscapeLedgerConsolidationGit -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', "$replacementCommitFull`:$([string]$evidence.path)")
        if ($probe.ExitCode -ne 0 -or $probe.Output -cne ([string]$evidence.blob).ToLowerInvariant()) {
            return (& $refuse ("the carried-evidence path '$([string]$evidence.path)' does not hold the recorded blob in replacement commit " +
                    "'$replacementCommitFull', so the work the source commit describes is not shown to be carried"))
        }
    }

    return [pscustomobject]@{
        Accepted          = $true
        ReplacementCommit = $replacementCommitFull
        Reason            = $null
        Basis             = [string]$entry.equivalenceBasis
    }
}

function Test-EscapeLedgerCommitReachableThroughConsolidation {
    <#
    .SYNOPSIS
        Is this commit in the checkout, either directly or through an exact,
        fully verified consolidation mapping?
    .DESCRIPTION
        Direct ancestry is tried first and is unchanged, so nothing about a
        commit that never moved goes through the map. Only a commit that fails
        the original question reaches the map, and it is accepted only when every
        obligation in Resolve-EscapeLedgerConsolidatedCommit is discharged.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Commit,
        [string]$HeadRef = 'HEAD',
        $Map
    )
    if (Test-EscapeLedgerConsolidationAncestor -RepoRoot $RepoRoot -Ancestor $Commit -Descendant $HeadRef) { return $true }
    if ($null -eq $Map) { return $false }
    $resolved = Resolve-EscapeLedgerConsolidatedCommit -RepoRoot $RepoRoot -Map $Map -SourceCommit $Commit -HeadRef $HeadRef
    return [bool]$resolved.Accepted
}
