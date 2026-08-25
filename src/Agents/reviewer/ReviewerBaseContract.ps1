#Requires -Version 7.0

<#
.SYNOPSIS
    The versioned reviewer-base lineage contract: which base identity a sealed
    offline fixture may be bound to, and what makes that identity true in THIS
    checkout.

.DESCRIPTION
    WHY THIS FILE EXISTS. Every sealed offline fixture in this repository is
    bound to an "expected reviewer base commit" - the state of the reviewer the
    fixture's pre-authored answers were captured against. The binding used to be
    enforced with one git question:

        git merge-base --is-ancestor <expectedBase> HEAD

    That question is both too weak and too brittle.

    Too weak, because ancestry says nothing about CONTENT. Any descendant of the
    named commit passes, however far the reviewer has since drifted, and a commit
    is accepted purely because of where it sits in a graph - never because of
    what it contains.

    Too brittle, because ancestry is a fact about ONE history. When the reviewer
    stack was consolidated, the replacement lineage reproduced the same trees
    under new commit identities, and every fixture bound to a pre-consolidation
    commit began to fail - not because anything about the reviewer had changed,
    but because a hash had. Re-pointing each fixture at a new commit would have
    thrown away the historical binding and taught the codebase that these
    identities are editable, which is the opposite of what they are for.

    WHAT REPLACES IT. A committed, versioned contract that states the accepted
    base identities EXPLICITLY, each one pinned by the git TREE it names, and
    that records - explicitly, by lineage version - which identity supersedes
    which. Acceptance then requires all of:

      1. the contract itself verifies: closed shape, declared kind and schema
         version, and a recomputed domain-separated digest over its own
         canonical form. An edited contract fails here.

      2. every bound artifact still hashes to what the contract recorded. These
         are the reviewer-side files a sealed fixture's answers actually depend
         on - the offline adapter, its manifest schema, the acquisition plan
         schema, the exact-path configuration, and this verifier. A tampered
         reviewer fails here even when the git graph is untouched.

      3. the requested base commit is one the contract NAMES. An arbitrary
         commit is refused, including one carrying the same commit message: the
         contract keys on identity, never on subject text.

      4. that commit's own tree, when the object is present, equals the tree the
         contract recorded for it. A commit id re-used against different content
         fails here.

      5. the ACTIVE lineage's boundary commit is an ancestor of the checkout and
         its tree equals the tree the contract recorded. A superseded identity is
         accepted only through an active lineage whose boundary tree is EXACTLY
         EQUAL to the superseded identity's tree - the equivalence is a tree
         equality this file recomputes from git, not an assertion the contract
         is trusted for.

    WHAT THIS DELIBERATELY DOES NOT DO. It does not claim the running checkout
    equals the base. It cannot: HEAD is normally ahead of the boundary, exactly
    as it was under the ancestry rule. What it adds over that rule is that the
    boundary itself is pinned by content, that the reviewer-side files the
    fixture depends on are pinned by content, and that the supersession from one
    lineage to the next is an explicit, versioned, tree-verified statement rather
    than an accident of graph shape.

    OLD ARTIFACTS STILL READ. A fixture that names the pre-consolidation commit
    keeps naming it. Nothing in this file rewrites a manifest, and the legacy
    identity is a first-class lineage entry rather than a compatibility shim.
#>

Set-StrictMode -Version Latest

$script:ReviewerBaseContractKind = 'reviewer-base-lineage-contract'
$script:ReviewerBaseContractSchemaVersion = 1
# Domain separation. The digest of this contract must not be reachable by
# hashing any other document this repository seals, so the label is part of the
# preimage rather than a comment about it.
$script:ReviewerBaseContractDigestLabel = 'devpilot.reviewer.base-lineage.contract.v1'
$script:ReviewerBaseContractRelativePath = 'src/Agents/reviewer/contracts/v1/reviewer-base-contract.json'
$script:ReviewerBaseContractUtf8 = [Text.UTF8Encoding]::new($false, $true)

# The exact top-level key set. Read as a closed set on purpose: a contract that
# grew a field this build does not verify would otherwise be accepted with that
# field unchecked, which is how an unverified escape hatch gets added later.
$script:ReviewerBaseContractTopLevelKeys = @(
    'boundArtifacts', 'contractDigest', 'contractId', 'description', 'kind',
    'lineageVersion', 'lineages', 'schemaVersion'
)
$script:ReviewerBaseContractLineageKeys = @(
    'baseCommit', 'baseTree', 'lineageVersion', 'name', 'status', 'supersededByLineageVersion'
)
$script:ReviewerBaseContractArtifactKeys = @('path', 'sha256')

function Get-ReviewerBaseContractDefaultPath {
    <#
    .SYNOPSIS
        The committed contract's path under a repository root.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)
    return (Join-Path $RepoRoot ($script:ReviewerBaseContractRelativePath -replace '/', [IO.Path]::DirectorySeparatorChar))
}

function ConvertTo-ReviewerBaseContractCanonicalText {
    <#
    .SYNOPSIS
        One deterministic text for one contract value.
    .DESCRIPTION
        Object keys are emitted in ordinal order, arrays keep their order,
        numbers are emitted as integers only, and no insignificant whitespace is
        produced. Anything this build cannot render deterministically - a float,
        a date, an arbitrary .NET type - is refused rather than rendered
        approximately, because a digest over an approximation proves nothing.
    #>
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 32) { throw 'The reviewer base contract nests deeper than this build will canonicalise.' }
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) {
        $builder = [Text.StringBuilder]::new()
        [void]$builder.Append('"')
        foreach ($character in $Value.ToCharArray()) {
            switch ($character) {
                '"' { [void]$builder.Append('\"'); continue }
                '\' { [void]$builder.Append('\\'); continue }
                "`b" { [void]$builder.Append('\b'); continue }
                "`f" { [void]$builder.Append('\f'); continue }
                "`n" { [void]$builder.Append('\n'); continue }
                "`r" { [void]$builder.Append('\r'); continue }
                "`t" { [void]$builder.Append('\t'); continue }
                default {
                    if ([int]$character -lt 0x20 -or [int]$character -gt 0x7E) {
                        [void]$builder.Append('\u' + ([int]$character).ToString('x4'))
                    }
                    else { [void]$builder.Append($character) }
                }
            }
        }
        [void]$builder.Append('"')
        return $builder.ToString()
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) {
        return ([long]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = foreach ($key in @([string[]]@($Value.Keys) | Sort-Object -CaseSensitive)) {
            (ConvertTo-ReviewerBaseContractCanonicalText -Value ([string]$key) -Depth ($Depth + 1)) + ':' +
            (ConvertTo-ReviewerBaseContractCanonicalText -Value $Value[$key] -Depth ($Depth + 1))
        }
        return '{' + ((@($parts)) -join ',') + '}'
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $names = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
        $parts = foreach ($key in @($names | Sort-Object -CaseSensitive)) {
            (ConvertTo-ReviewerBaseContractCanonicalText -Value $key -Depth ($Depth + 1)) + ':' +
            (ConvertTo-ReviewerBaseContractCanonicalText -Value $Value.PSObject.Properties[$key].Value -Depth ($Depth + 1))
        }
        return '{' + ((@($parts)) -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = foreach ($item in $Value) {
            ConvertTo-ReviewerBaseContractCanonicalText -Value $item -Depth ($Depth + 1)
        }
        return '[' + ((@($parts)) -join ',') + ']'
    }
    throw "The reviewer base contract carries a value of type '$($Value.GetType().FullName)', which this build will not canonicalise."
}

function Get-ReviewerBaseContractDigest {
    <#
    .SYNOPSIS
        The domain-separated digest over a contract, excluding its own digest.
    #>
    param([Parameter(Mandatory)]$Contract)
    $copy = [ordered]@{}
    foreach ($name in @(@($Contract.PSObject.Properties | ForEach-Object { [string]$_.Name }) | Sort-Object -CaseSensitive)) {
        if ($name -ceq 'contractDigest') { continue }
        $copy[$name] = $Contract.PSObject.Properties[$name].Value
    }
    $preimage = $script:ReviewerBaseContractDigestLabel + "`n" +
    (ConvertTo-ReviewerBaseContractCanonicalText -Value $copy)
    $bytes = $script:ReviewerBaseContractUtf8.GetBytes($preimage)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function Read-ReviewerBaseContract {
    <#
    .SYNOPSIS
        Reads and self-verifies the committed contract, or refuses.
    .DESCRIPTION
        The shape is checked as a CLOSED set before the digest, so a contract
        carrying an extra field is refused by name rather than by a digest
        mismatch that says nothing about what changed.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The reviewer base lineage contract '$Path' does not exist, so no expected base identity can be accepted."
    }
    $contract = $null
    try {
        $contract = [IO.File]::ReadAllText($Path, $script:ReviewerBaseContractUtf8) | ConvertFrom-Json -Depth 32
    }
    catch {
        throw "The reviewer base lineage contract '$Path' could not be read: $($_.Exception.Message)"
    }
    if ($null -eq $contract) { throw "The reviewer base lineage contract '$Path' is empty." }
    $names = @(@($contract.PSObject.Properties | ForEach-Object { [string]$_.Name }) | Sort-Object -CaseSensitive)
    $expected = @(@($script:ReviewerBaseContractTopLevelKeys) | Sort-Object -CaseSensitive)
    if (($names -join "`n") -cne ($expected -join "`n")) {
        throw ("The reviewer base lineage contract '$Path' has an unexpected top-level shape: " +
            "[$($names -join ', ')] rather than [$($expected -join ', ')].")
    }
    if ([string]$contract.kind -cne $script:ReviewerBaseContractKind) {
        throw "The reviewer base lineage contract '$Path' declares kind '$([string]$contract.kind)'."
    }
    if ([int]$contract.schemaVersion -ne $script:ReviewerBaseContractSchemaVersion) {
        throw "The reviewer base lineage contract '$Path' declares schema version $([int]$contract.schemaVersion), which this build does not verify."
    }
    if (@($contract.lineages).Count -lt 1) {
        throw "The reviewer base lineage contract '$Path' names no lineage."
    }
    $seenVersions = [Collections.Generic.HashSet[int]]::new()
    $seenCommits = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $activeCount = 0
    foreach ($lineage in @($contract.lineages)) {
        $lineageNames = @(@($lineage.PSObject.Properties | ForEach-Object { [string]$_.Name }) | Sort-Object -CaseSensitive)
        $expectedLineage = @(@($script:ReviewerBaseContractLineageKeys) | Sort-Object -CaseSensitive)
        if (($lineageNames -join "`n") -cne ($expectedLineage -join "`n")) {
            throw ("A lineage in the reviewer base lineage contract '$Path' has an unexpected shape: " +
                "[$($lineageNames -join ', ')].")
        }
        if ([string]$lineage.baseCommit -cnotmatch '^[0-9a-f]{40}$') {
            throw "A lineage in '$Path' names base commit '$([string]$lineage.baseCommit)', which is not a full lowercase object name."
        }
        if ([string]$lineage.baseTree -cnotmatch '^[0-9a-f]{40}$') {
            throw "A lineage in '$Path' names base tree '$([string]$lineage.baseTree)', which is not a full lowercase object name."
        }
        if ([string]$lineage.status -cne 'active' -and [string]$lineage.status -cne 'superseded') {
            throw "Lineage $([int]$lineage.lineageVersion) in '$Path' declares status '$([string]$lineage.status)'."
        }
        if (-not $seenVersions.Add([int]$lineage.lineageVersion)) {
            throw "The reviewer base lineage contract '$Path' declares lineage version $([int]$lineage.lineageVersion) twice."
        }
        # A base identity that appears twice could be resolved two ways, and the
        # resolution would then depend on iteration order rather than on the
        # contract. Refused rather than resolved by first match.
        if (-not $seenCommits.Add([string]$lineage.baseCommit)) {
            throw "The reviewer base lineage contract '$Path' names base commit $([string]$lineage.baseCommit) in more than one lineage."
        }
        if ([string]$lineage.status -ceq 'active') {
            $activeCount++
            if ([int]$lineage.supersededByLineageVersion -ne 0) {
                throw "Lineage $([int]$lineage.lineageVersion) in '$Path' is active and also claims to be superseded."
            }
        }
        elseif ([int]$lineage.supersededByLineageVersion -eq 0) {
            throw "Lineage $([int]$lineage.lineageVersion) in '$Path' is superseded and names no superseding lineage."
        }
    }
    if ($activeCount -ne 1) {
        throw "The reviewer base lineage contract '$Path' declares $activeCount active lineage(s); exactly one is required."
    }
    if (-not $seenVersions.Contains([int]$contract.lineageVersion)) {
        throw "The reviewer base lineage contract '$Path' declares current lineage version $([int]$contract.lineageVersion), which it does not define."
    }
    foreach ($artifact in @($contract.boundArtifacts)) {
        $artifactNames = @(@($artifact.PSObject.Properties | ForEach-Object { [string]$_.Name }) | Sort-Object -CaseSensitive)
        $expectedArtifact = @(@($script:ReviewerBaseContractArtifactKeys) | Sort-Object -CaseSensitive)
        if (($artifactNames -join "`n") -cne ($expectedArtifact -join "`n")) {
            throw "A bound artifact in '$Path' has an unexpected shape: [$($artifactNames -join ', ')]."
        }
        if ([string]$artifact.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "The bound artifact '$([string]$artifact.path)' in '$Path' records a digest that is not a lowercase SHA-256."
        }
        if ([string]$artifact.path -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted([string]$artifact.path)) {
            throw "The bound artifact path '$([string]$artifact.path)' in '$Path' must be repository-relative and may not traverse."
        }
    }
    if (@($contract.boundArtifacts).Count -lt 1) {
        throw "The reviewer base lineage contract '$Path' binds no artifact, so a tampered reviewer would still be accepted."
    }
    $recomputed = Get-ReviewerBaseContractDigest -Contract $contract
    if ([string]$contract.contractDigest -cne $recomputed) {
        throw ("The reviewer base lineage contract '$Path' does not match its own digest " +
            "(recorded $([string]$contract.contractDigest), recomputed $recomputed). The contract has been edited.")
    }
    return $contract
}

function Test-ReviewerBaseContractBoundArtifact {
    <#
    .SYNOPSIS
        Every bound artifact's on-disk digest, or the first objection.
    #>
    param(
        [Parameter(Mandatory)]$Contract,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    foreach ($artifact in @($Contract.boundArtifacts)) {
        $relative = ([string]$artifact.path) -replace '/', [IO.Path]::DirectorySeparatorChar
        $full = Join-Path $RepoRoot $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            return "The bound artifact '$([string]$artifact.path)' does not exist under '$RepoRoot'."
        }
        $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne [string]$artifact.sha256) {
            return ("The bound artifact '$([string]$artifact.path)' hashes to $actual, not the " +
                "$([string]$artifact.sha256) the reviewer base lineage contract records.")
        }
    }
    return ''
}

function Invoke-ReviewerBaseContractGit {
    <#
    .SYNOPSIS
        One git query against a repository root, with its exit code.
    .DESCRIPTION
        Native exit codes are read explicitly rather than through the ambient
        error preference, so a caller that has turned native errors into
        terminating ones does not change what a refusal here means.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList
    )
    $priorPreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & git -C $RepoRoot @ArgumentList 2>$null
        return [pscustomobject]@{
            ExitCode = [int]$LASTEXITCODE
            Text     = [string](@($output) -join "`n").Trim()
        }
    }
    finally { $PSNativeCommandUseErrorActionPreference = $priorPreference }
}

function Get-ReviewerBaseContractTree {
    <#
    .SYNOPSIS
        The tree a commit names, or an empty string when the object is absent.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Commit)
    $result = Invoke-ReviewerBaseContractGit -RepoRoot $RepoRoot -ArgumentList @('rev-parse', '--verify', '--quiet', ($Commit + '^{tree}'))
    if ([int]$result.ExitCode -ne 0) { return '' }
    return ([string]$result.Text).ToLowerInvariant()
}

function Assert-ReviewerBaseCommitAccepted {
    <#
    .SYNOPSIS
        Accepts one expected reviewer base commit against this checkout, or
        throws with the exact reason it was refused.

    .PARAMETER RepoRoot
        The repository the fixture will be replayed in.

    .PARAMETER ExpectedBaseCommit
        The 40-hex identity the sealed fixture is bound to. Passed through
        verbatim from the fixture; this function never rewrites it.

    .PARAMETER ContractPath
        Defaults to the committed contract under RepoRoot.

    .PARAMETER HeadRef
        The revision the boundary must be an ancestor of. Defaults to HEAD; the
        checks take it as a parameter so a test can drive an unrelated history
        without rewriting the worktree.

    .OUTPUTS
        An acceptance record naming the lineage that accepted the identity, the
        boundary commit that carried it, and the contract digest under which the
        decision was made. Callers record it; nothing about the decision is left
        implicit.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ExpectedBaseCommit,
        [string]$ContractPath = '',
        [string]$HeadRef = 'HEAD'
    )
    if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
        throw "The repository root '$RepoRoot' does not exist, so no reviewer base identity can be verified against it."
    }
    $repoFull = (Resolve-Path -LiteralPath $RepoRoot).Path
    $path = $ContractPath
    if ([string]::IsNullOrWhiteSpace($path)) { $path = Get-ReviewerBaseContractDefaultPath -RepoRoot $repoFull }
    $contract = Read-ReviewerBaseContract -Path $path

    [string]$artifactObjection = Test-ReviewerBaseContractBoundArtifact -Contract $contract -RepoRoot $repoFull
    if ($artifactObjection.Length -gt 0) {
        throw ("The reviewer base identity cannot be accepted: $artifactObjection " +
            'A sealed fixture is bound to reviewer-side content, not only to a place in the commit graph.')
    }

    $requested = ([string]$ExpectedBaseCommit).ToLowerInvariant()
    if ($requested -cnotmatch '^[0-9a-f]{40}$') {
        throw "The expected reviewer base commit '$ExpectedBaseCommit' is not a full 40-character object name."
    }
    $entry = @($contract.lineages | Where-Object { [string]$_.baseCommit -ceq $requested })
    if (@($entry).Count -ne 1) {
        throw ("The expected reviewer base commit '$requested' is not an accepted base identity in '$path'. " +
            'A commit is accepted because the contract names it, never because it carries a familiar subject line ' +
            'or sits under HEAD.')
    }
    $lineage = @($entry)[0]

    # The named identity's own content, when the object is present in this
    # clone. A clone that no longer carries the pre-consolidation objects is not
    # a failure - the acceptance below does not depend on them - but a clone that
    # DOES carry them and finds a different tree is a re-used commit id and is
    # refused.
    [string]$requestedTree = Get-ReviewerBaseContractTree -RepoRoot $repoFull -Commit $requested
    $requestedTreePresent = ($requestedTree.Length -gt 0)
    if ($requestedTreePresent -and $requestedTree -cne ([string]$lineage.baseTree).ToLowerInvariant()) {
        throw ("The expected reviewer base commit '$requested' names tree $requestedTree in this repository, but the " +
            "contract records $([string]$lineage.baseTree) for that identity. The identity and the content disagree.")
    }

    $active = $lineage
    $mode = 'active-lineage'
    if ([string]$lineage.status -cne 'active') {
        $successor = @($contract.lineages | Where-Object {
                [int]$_.lineageVersion -eq [int]$lineage.supersededByLineageVersion
            })
        if (@($successor).Count -ne 1) {
            throw ("Lineage $([int]$lineage.lineageVersion) claims supersession by lineage " +
                "$([int]$lineage.supersededByLineageVersion), which '$path' does not define exactly once.")
        }
        $active = @($successor)[0]
        if ([string]$active.status -cne 'active') {
            throw ("Lineage $([int]$lineage.lineageVersion) is superseded by lineage $([int]$active.lineageVersion), " +
                'which is not the active lineage. Supersession must terminate at the active lineage in one step.')
        }
        # THE EQUIVALENCE, and the whole reason a superseded identity may be
        # accepted at all: the replacement boundary must reproduce the superseded
        # identity's tree EXACTLY. Consolidation that preserved content preserved
        # this equality; a rewrite that changed content did not, and is refused.
        if (([string]$active.baseTree).ToLowerInvariant() -cne ([string]$lineage.baseTree).ToLowerInvariant()) {
            throw ("Lineage $([int]$lineage.lineageVersion) records tree $([string]$lineage.baseTree) and the active " +
                "lineage $([int]$active.lineageVersion) records tree $([string]$active.baseTree). A superseded base " +
                'identity is accepted only through a replacement boundary carrying the identical tree.')
        }
        $mode = 'consolidated-equivalent-tree'
    }

    $boundary = ([string]$active.baseCommit).ToLowerInvariant()
    [string]$boundaryTree = Get-ReviewerBaseContractTree -RepoRoot $repoFull -Commit $boundary
    if ($boundaryTree.Length -eq 0) {
        throw ("The active reviewer base boundary '$boundary' is not present in '$repoFull', so the expected base " +
            "'$requested' cannot be shown to be carried by this checkout.")
    }
    if ($boundaryTree -cne ([string]$active.baseTree).ToLowerInvariant()) {
        throw ("The active reviewer base boundary '$boundary' names tree $boundaryTree in this repository, but the " +
            "contract records $([string]$active.baseTree). The boundary has been rewritten.")
    }
    $ancestry = Invoke-ReviewerBaseContractGit -RepoRoot $repoFull `
        -ArgumentList @('merge-base', '--is-ancestor', $boundary, $HeadRef)
    if ([int]$ancestry.ExitCode -ne 0) {
        throw ("The active reviewer base boundary '$boundary' is not an ancestor of '$HeadRef', so this checkout does " +
            "not carry the reviewer state the expected base '$requested' names.")
    }

    return [pscustomobject][ordered]@{
        acceptanceVersion    = 1
        expectedBaseCommit   = $requested
        expectedBaseTree     = ([string]$lineage.baseTree).ToLowerInvariant()
        expectedBasePresent  = [bool]$requestedTreePresent
        lineageVersion       = [int]$lineage.lineageVersion
        activeLineageVersion = [int]$active.lineageVersion
        boundaryCommit       = $boundary
        boundaryTree         = $boundaryTree
        mode                 = [string]$mode
        contractDigest       = ([string]$contract.contractDigest).ToLowerInvariant()
        contractPath         = [string]([IO.Path]::GetFullPath($path))
        boundArtifactCount   = [int]@($contract.boundArtifacts).Count
    }
}
