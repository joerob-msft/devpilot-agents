#requires -Version 7.0

<#
    Offline corpus seal.

    Turns an already-captured, integrity-indexed research corpus plus a private
    recipe into a schema-v2 replay snapshot, with NO live seam of any kind: no
    MCP session, no Azure CLI, no `az`, no child process, no network, and no
    fallback that could reach a repository host. Every byte the seal emits is
    resolved through the corpus index and re-verified against it.

    The split matters. Capture is credentialed and host-specific and already
    happened; the corpus is immutable evidence of it. Sealing is pure, so it can
    be tested, reviewed and re-run anywhere, and it can be made to fail closed on
    every way a corpus or a recipe can be wrong.

    What the recipe must bind INDEPENDENTLY of the corpus (so a disagreement is a
    refusal rather than a silent adoption of whatever the corpus happens to say):

      - organization / project / repository / pull request / iteration;
      - source, common and target commits;
      - the authoritative change-set digest AND its path order;
      - every changed file's right-hand payload, its SHA-256, byte length and
        exact right-hand spans;
      - the siblings, rules, threads and facts the prompts consume;
      - the policy, config, script, schema and prompt hashes;
      - the source-transport mode, coverage record, gate and rendered block;
      - the capture provenance and status-at-capture;
      - non-promotability.

    Everything the seal writes is permanently NON-PROMOTABLE and is stamped
    `offlineCorpusSeal`. The seal never claims a live post-read race check was
    performed, because none was: it records the capture's own end-of-capture
    identity as recorded evidence, not as a fresh observation.
#>

Set-StrictMode -Version Latest

# The twelve stage producer boundaries are declared in one shared file, so a
# stage and the corpus that drives it can never exercise two different copies of
# the same contract.
#
# The guard asks whether THIS script scope already holds the producer table, not
# whether the commands are merely visible. A dot-sourced library resolves
# $script: variables against the scope of whoever is running it, so a script that
# can see an outer scope's functions but never loaded the libraries itself would
# reach a registry that does not exist there - and it would only find out at the
# first boundary call, which is exactly the call that must not fail for the wrong
# reason.
if (-not (Get-Variable -Name 'ReviewerStageProducerContracts' -Scope Script -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'StageProducers.ps1')
}

$script:ReviewerCorpusSealKind = "reviewer-offline-corpus-seal"
$script:ReviewerCorpusSealRecipeKind = "reviewer-offline-corpus-seal-recipe"
$script:ReviewerCorpusIndexKinds = @(
    "private-immutable-non-promotable-research-corpus",
    "private-non-promotable-research-corpus"
)
$script:ReviewerCorpusSealSchemaVersion = 1
$script:ReviewerCorpusSealSnapshotSchemaVersion = 2
$script:ReviewerCorpusSealMaxPayloads = 4096
$script:ReviewerCorpusSealMaxPayloadBytes = 25165824
$script:ReviewerCorpusSealMaxTotalBytes = 67108864
$script:ReviewerCorpusSealSegmentPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}\z'
$script:ReviewerCorpusSealHexPattern = '^[0-9a-f]{64}\z'
$script:ReviewerCorpusSealCommitPattern = '^[0-9a-f]{40}\z'
$script:ReviewerCorpusSealSnapshotNamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z'
$script:ReviewerCorpusSealEnvelopes = @("jsonRpcResult", "mcpTextContent", "mcpResourceContent")
$script:ReviewerCorpusSealTransportModes = @("mcpFlat", "azureDevOpsCliFallback", "legacyMcp")
$script:ReviewerCorpusSealSourceKinds = @("capturedArtifact", "derivedFromCorpus")
$script:ReviewerCorpusSealUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
# The names the seal writes for itself. They are reserved: a recipe may not
# route a payload or the transport artifact onto any of them, because a resource
# that overwrote the manifest or the sidecar would be a snapshot rewriting the
# very assertions that describe it.
$script:ReviewerCorpusSealManifestFile = "manifest.json"
$script:ReviewerCorpusSealSidecarFile = "offline-corpus-seal.json"
$script:ReviewerCorpusSealReservedFiles = @(
    $script:ReviewerCorpusSealManifestFile, $script:ReviewerCorpusSealSidecarFile
)
# The manifest classification this sealer stamps. It must be one of the seal
# kinds the replay loader recognizes as non-promotable, because the loader is
# what makes the label binding rather than advisory.
$script:ReviewerCorpusSealClassification = "offlineCorpusSeal"
# A toolkit policy, when one is used at all, may only ever come from here.
$script:ReviewerCorpusSealToolkitPolicyRoot = "src/Agents/reviewer/source"
$script:ReviewerCorpusSealPolicyProvenances = @("corpus", "toolkitSealTime")
# This toolkit's own working tree, derived from where THIS file lives rather than
# from anything a caller passes in. A corpus seal is private evidence about a real
# pull request, so it is never written inside the tree that gets committed - and
# that has to hold for a direct library call, not only for the CLI that used to
# own the check. Deriving it from $PSScriptRoot means a caller cannot move the
# boundary by supplying a different one.
$script:ReviewerCorpusSealToolkitRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot (Join-Path ".." (Join-Path ".." ".."))))

function Get-ReviewerCorpusSealSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Test-ReviewerCorpusSealRelativePath {
    <#
        One shape of relative path, and only one. A corpus path is operator input
        that selects bytes, so every way of writing the same name differently -
        a backslash separator, a '.' or '..' segment, a leading or doubled
        slash, a trailing slash, a drive letter, an alternate data stream - is a
        path ALIAS, and an alias is how an unindexed payload gets read under an
        indexed name. All are refused here rather than normalized, because
        normalizing would accept two spellings for one entry and make "is this
        path in the index?" ambiguous.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or $Path.Length -gt 512) { return $false }
    if ($Path.Contains("\") -or $Path.Contains(":")) { return $false }
    if ($Path.StartsWith("/") -or $Path.EndsWith("/") -or $Path.Contains("//")) { return $false }
    foreach ($segment in ($Path -split '/')) {
        if ($segment -cnotmatch $script:ReviewerCorpusSealSegmentPattern) { return $false }
    }
    return $true
}

function Resolve-ReviewerCorpusSealRealPath {
    <#
        Returns the real filesystem path of $Path, walking it component by
        component so that links are SEEN rather than assumed away.

        [System.IO.Path]::GetFullPath only does textual normalization: it will
        happily report a path "outside the repository" that a junction points
        straight back into it. Any containment or confinement decision has to be
        made about the path the filesystem will actually use.

        -RejectReparsePoints is for locations this toolkit writes to or reads
        policy from: there a link anywhere in the chain is refused outright
        rather than followed, because a link is a place that can be re-aimed
        after it was checked, and an operator who did not intend one will not
        notice it.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$RejectReparsePoints
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root)) { throw "Path '$Path' has no filesystem root." }
    $relative = $full.Substring($root.Length).Trim([System.IO.Path]::DirectorySeparatorChar)
    $segments = if ($relative) { @($relative -split [regex]::Escape([System.IO.Path]::DirectorySeparatorChar)) } else { @() }
    $current = $root
    foreach ($segment in $segments) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            # Nothing below an absent component can be a link, so the remaining
            # segments are taken literally.
            continue
        }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
        if (-not $isReparse) { continue }
        if ($RejectReparsePoints) {
            throw ("Path '$Path' passes through the reparse point '$current'; a corpus-seal location must be a real " +
                "directory so that where it is cannot be changed out from under the containment check.")
        }
        $target = $item.ResolveLinkTarget($true)
        if ($null -ne $target) { $current = [System.IO.Path]::GetFullPath($target.FullName) }
    }
    return $current
}

function Test-ReviewerCorpusSealPathWithin {
    <#
        Separator-anchored on both sides, so "...\devpilot-agents-private" is not
        read as living inside "...\devpilot-agents".
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Boundary
    )
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $candidate = $Path.TrimEnd($separator) + $separator
    $within = $Boundary.TrimEnd($separator) + $separator
    return $candidate.StartsWith($within, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-ReviewerCorpusSealReplayRoot {
    <#
        The replay root a seal is written to, revalidated at the moment of use.

        This lives in the LIBRARY rather than only in the CLI on purpose. The CLI
        is one caller; a direct call to Save-ReviewerCorpusSeal is another, and a
        safety property that only one entry point enforces is a safety property
        the other entry point does not have.

        PowerShell cannot open a directory handle and hold it across a rename, so
        a perfect TOCTOU defence is not available here. What is available is to
        shrink the window and to check at every moment that matters: immediately
        before staging is created, and again immediately before publication. A
        link swapped in between those two points still has to survive the second
        check, and the second check happens after all the bytes are already
        written and verified, so the remaining window is a rename rather than a
        whole build.

        Containment in the toolkit's own tree is refused here too, both
        lexically and after resolution. Refusing only reparse points left the
        plainest mistake of all - naming a directory inside the repository -
        available to any caller that did not go through the CLI.
    #>
    param(
        [Parameter(Mandatory)][string]$ReplayRoot,
        [Parameter(Mandatory)][string]$Stage
    )
    $real = Resolve-ReviewerCorpusSealRealPath -Path $ReplayRoot -RejectReparsePoints
    $textual = [System.IO.Path]::GetFullPath($ReplayRoot)
    if ($real -cne $textual) {
        throw ("The replay root '$ReplayRoot' resolves to '$real' at $Stage; a corpus seal is written only to the " +
            "real directory it names.")
    }
    $toolkitReal = Resolve-ReviewerCorpusSealRealPath -Path $script:ReviewerCorpusSealToolkitRoot
    foreach ($boundary in @($script:ReviewerCorpusSealToolkitRoot, $toolkitReal)) {
        foreach ($candidate in @($textual, $real)) {
            if (Test-ReviewerCorpusSealPathWithin -Path $candidate -Boundary $boundary) {
                throw ("The replay root '$candidate' is inside the toolkit working tree '$boundary' at $Stage; a " +
                    "private corpus seal is evidence about a real pull request and is never written where it could " +
                    "be committed.")
            }
        }
    }
    if (Test-Path -LiteralPath $real) {
        $item = Get-Item -LiteralPath $real -Force -ErrorAction Stop
        if ($item -isnot [System.IO.DirectoryInfo]) {
            throw "The replay root '$real' is not a directory."
        }
    }
    return $real
}

function Assert-ReviewerCorpusSealWriteTarget {
    <#
        A directory this seal is about to write into, or move within, checked at
        the moment of use rather than once at the start.

        The replay root being sound when the build began says nothing about the
        directories underneath it thirty seconds later. Every parent a payload is
        written into, the staging root, the snapshot directory and the publication
        parent are all re-checked: no reparse point anywhere along them, and still
        inside the boundary they are supposed to be inside. The window cannot be
        closed in this runtime, but it can be made a single filesystem call wide
        instead of an entire build wide.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Boundary,
        [Parameter(Mandatory)][string]$Stage
    )
    $textual = [System.IO.Path]::GetFullPath($Path)
    $boundaryFull = [System.IO.Path]::GetFullPath($Boundary)
    if (-not (Test-ReviewerCorpusSealPathWithin -Path $textual -Boundary $boundaryFull)) {
        throw "Corpus seal $Stage target '$textual' is not inside '$boundaryFull'."
    }
    $real = Resolve-ReviewerCorpusSealRealPath -Path $textual -RejectReparsePoints
    if ($real -cne $textual -or -not (Test-ReviewerCorpusSealPathWithin -Path $real -Boundary $boundaryFull)) {
        throw ("Corpus seal $Stage target '$textual' resolves to '$real', outside the location it was checked " +
            "against; refusing to write through it.")
    }
    return $real
}

function Remove-ReviewerCorpusSealScratch {
    <#
        Deletes a staging or retired directory WITHOUT ever recursing through a
        reparse point. `Remove-Item -Recurse` follows junctions on Windows, so a
        link dropped into staging during the build would turn the cleanup path -
        the one path that runs even when everything else failed - into a delete
        of whatever it pointed at. A link is unlinked; only real directories are
        descended into.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
    if ($isReparse) {
        if ($item -is [System.IO.DirectoryInfo]) { [System.IO.Directory]::Delete($item.FullName, $false) }
        else { [System.IO.File]::Delete($item.FullName) }
        return
    }
    if ($item -is [System.IO.DirectoryInfo]) {
        foreach ($child in @([System.IO.Directory]::GetFileSystemEntries($item.FullName))) {
            Remove-ReviewerCorpusSealScratch -Path $child
        }
        [System.IO.Directory]::Delete($item.FullName, $false)
        return
    }
    [System.IO.File]::Delete($item.FullName)
}

function Get-ReviewerCorpusSealSpanEvidence {
    <#
        Derives the authoritative right-hand spans, per path, from an INDEXED
        span/diff evidence payload - never from the recipe.

        A recipe that could state its own spans could seal a file's bytes while
        pointing the reviewer at the wrong lines of them, and every other check
        would still pass: the payload hashes, the path normalizes, the change set
        carries it. The spans decide which lines the reviewer is shown, so they
        have to come from captured evidence, and the recipe's copy has to be a
        restatement that is COMPARED rather than a source that is adopted.

        The evidence is a captured hunk census: per path, the diff hunks with
        their old and new starts and counts. The right-hand span of a hunk is
        exactly (newStart, newCount); a hunk with newCount = 0 removed lines and
        contributes no right-hand span, which is how a pure deletion legitimately
        ends up with none.

        Returns an ordered path -> @(@{ Start; Count }) map. Malformed evidence is
        a refusal, not a filter: the one thing this must never do is quietly
        return a smaller census than the evidence describes.
    #>
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$Where
    )
    if ($Evidence -isnot [System.Collections.IList]) {
        throw "$Where must be a JSON array of per-path hunk records."
    }
    $byPath = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $entryIndex = 0
    foreach ($entry in @($Evidence)) {
        $entryIndex++
        if ($entry -isnot [System.Management.Automation.PSCustomObject]) {
            throw "$Where entry $entryIndex is not an object."
        }
        foreach ($required in @("path", "hunks")) {
            if (-not $entry.PSObject.Properties[$required]) {
                throw "$Where entry $entryIndex omits '$required'."
            }
        }
        $rawPath = [string]$entry.path
        $path = ConvertTo-ReviewerSourcePath -Path $rawPath
        if (-not $path -or $path -cne $rawPath) {
            throw "$Where entry $entryIndex names '$rawPath', which is not already in normalized form."
        }
        if ($byPath.Contains($path)) {
            throw "$Where names '$path' more than once; one path has one authoritative hunk census."
        }
        $spans = [System.Collections.Generic.List[object]]::new()
        $previousEnd = 0
        $hunkIndex = 0
        foreach ($hunk in @($entry.hunks)) {
            $hunkIndex++
            if ($hunk -isnot [System.Management.Automation.PSCustomObject]) {
                throw "$Where hunk $hunkIndex for '$path' is not an object."
            }
            foreach ($required in @("newStart", "newCount")) {
                if (-not $hunk.PSObject.Properties[$required]) {
                    throw "$Where hunk $hunkIndex for '$path' omits '$required'."
                }
            }
            $rawStart = $hunk.newStart
            $rawCount = $hunk.newCount
            if ($rawStart -isnot [int] -and $rawStart -isnot [long]) {
                throw "$Where hunk $hunkIndex for '$path' has a non-integer newStart."
            }
            if ($rawCount -isnot [int] -and $rawCount -isnot [long]) {
                throw "$Where hunk $hunkIndex for '$path' has a non-integer newCount."
            }
            $start = [int]$rawStart
            $count = [int]$rawCount
            if ($count -lt 0 -or $start -lt 0) {
                throw "$Where hunk $hunkIndex for '$path' declares an out-of-range span ($start, $count)."
            }
            if ($count -eq 0) { continue }
            if ($start -lt 1) {
                throw "$Where hunk $hunkIndex for '$path' declares an out-of-range span ($start, $count)."
            }
            if ($start -le $previousEnd) {
                throw "$Where hunks for '$path' are not in strictly ascending, non-overlapping right-hand order."
            }
            $previousEnd = $start + $count - 1
            [void]$spans.Add(@{ Start = $start; Count = $count })
        }
        $byPath[$path] = @($spans.ToArray())
    }
    # The snapshot stage boundary, in force. Both halves of the census are judged
    # together: the path list (which files the reviewer will be shown) and the
    # per-path span map (which lines of them). A path that survives with its span
    # list collapsed to a scalar is the exact shape that shows one hunk of a file
    # and calls the rest reviewed.
    $asserted = New-ReviewerSnapshotStageContract -SpanPaths ([string[]]@($byPath.Keys)) -SpansByPath $byPath
    return $asserted.spansByPath
}

function Assert-ReviewerCorpusSealOutputPaths {
    <#
        Proves the whole set of names this seal will write can actually coexist
        as files in one directory tree, BEFORE anything is written.

        Three ways a set of individually valid names is collectively impossible:

          - two names are the same file (a duplicate, exact or case-folded, since
            the filesystem this runs on folds case);
          - one name is a strict ancestor directory of another ("a/b" needs "a"
            to be a directory, so "a" cannot also be a payload);
          - a name collides with one the sealer writes for itself, so a payload
            would overwrite the manifest or the sidecar - the two files that
            describe what everything else is.

        Each of those, discovered mid-write, leaves a half-built snapshot on
        disk. Discovered here, it is a refusal that creates nothing.
    #>
    param([Parameter(Mandatory)][string[]]$RelativePaths)
    $byPath = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $directories = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $RelativePaths) {
        if (-not (Test-ReviewerCorpusSealRelativePath -Path $relative)) {
            throw "Corpus seal output '$relative' is not a plain relative path."
        }
        foreach ($reserved in $script:ReviewerCorpusSealReservedFiles) {
            if ([string]::Equals($relative, $reserved, [StringComparison]::OrdinalIgnoreCase)) {
                throw ("Corpus seal output '$relative' collides with the reserved snapshot file '$reserved'; a payload " +
                    "may not overwrite the manifest or the classification sidecar.")
            }
        }
        if ($byPath.ContainsKey($relative)) {
            throw "Corpus seal writes '$relative' and '$($byPath[$relative])' to the same file."
        }
        $byPath[$relative] = $relative
    }
    # Reserved names live at the root, so a directory named for one is the same
    # collision seen from the other side.
    foreach ($reserved in $script:ReviewerCorpusSealReservedFiles) { $byPath[$reserved] = $reserved }
    foreach ($relative in $byPath.Keys) {
        $segments = @($relative -split '/')
        $prefix = ""
        for ($i = 0; $i -lt ($segments.Count - 1); $i++) {
            $prefix = if ($prefix) { "$prefix/$($segments[$i])" } else { [string]$segments[$i] }
            $directories[$prefix] = $relative
        }
    }
    foreach ($relative in $byPath.Keys) {
        if ($directories.ContainsKey($relative)) {
            throw ("Corpus seal writes '$relative' as a file, but '$($directories[$relative])' needs it to be a " +
                "directory; one name cannot be both.")
        }
    }
    return $true
}

function Get-ReviewerCorpusSealProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet("string", "sha256", "commit", "int", "bool", "object", "array")][string]$Type,
        [Parameter(Mandatory)][string]$Where,
        [long]$Min = 0,
        [long]$Max = 2147483647,
        [string]$Pattern
    )
    if ($Object -isnot [System.Management.Automation.PSCustomObject]) { throw "$Where must be an object." }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Where is missing required field '$Name'." }
    $value = $property.Value
    switch ($Type) {
        "string" {
            if ($value -isnot [string]) { throw "$Where field '$Name' must be a string." }
            if ($Pattern -and [string]$value -cnotmatch $Pattern) { throw "$Where field '$Name' does not match its required shape." }
            return [string]$value
        }
        "sha256" {
            if ($value -isnot [string] -or [string]$value -cnotmatch $script:ReviewerCorpusSealHexPattern) {
                throw "$Where field '$Name' must be a lowercase SHA-256 hex digest."
            }
            return [string]$value
        }
        "commit" {
            if ($value -isnot [string] -or [string]$value -cnotmatch $script:ReviewerCorpusSealCommitPattern) {
                throw "$Where field '$Name' must be a lowercase 40-hex commit id."
            }
            return [string]$value
        }
        "int" {
            if ($value -isnot [int] -and $value -isnot [long]) { throw "$Where field '$Name' must be a JSON integer." }
            $number = [long]$value
            if ($number -lt $Min -or $number -gt $Max) { throw "$Where field '$Name' must be in [$Min,$Max]." }
            return $number
        }
        "bool" {
            if ($value -isnot [bool]) { throw "$Where field '$Name' must be a boolean." }
            return [bool]$value
        }
        "object" {
            if ($value -isnot [System.Management.Automation.PSCustomObject]) { throw "$Where field '$Name' must be an object." }
            return $value
        }
        "array" {
            if ($value -isnot [System.Object[]]) { throw "$Where field '$Name' must be an array." }
            return @($value)
        }
    }
}

function Assert-ReviewerCorpusSealExactKeys {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Where
    )
    if ($Object -isnot [System.Management.Automation.PSCustomObject]) { throw "$Where must be an object." }
    $actual = @($Object.PSObject.Properties.Name)
    $unexpected = @($actual | Where-Object { $Expected -cnotcontains $_ })
    if ($unexpected.Count -gt 0) { throw "$Where carries unexpected field(s): $($unexpected -join ', ')." }
    $missing = @($Expected | Where-Object { -not $Object.PSObject.Properties[$_] })
    if ($missing.Count -gt 0) { throw "$Where is missing field(s): $($missing -join ', ')." }
}

function Import-ReviewerCorpusIndex {
    <#
        Opens the corpus for READING and proves it is the exact corpus the caller
        named. The index digest is mandatory: an index that is merely
        self-consistent proves nothing, because whoever edited it could recompute
        anything it contains. Nothing in this file ever writes to the corpus.
    #>
    param(
        [Parameter(Mandatory)][string]$CorpusRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedIndexSha256
    )
    if (-not (Test-Path -LiteralPath $CorpusRoot -PathType Container)) {
        throw "Corpus root '$CorpusRoot' does not exist."
    }
    $rootItem = Get-Item -LiteralPath $CorpusRoot -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) {
        throw "Corpus root '$CorpusRoot' is a reparse point; a corpus may not redirect its own contents."
    }
    $rootFull = [System.IO.Path]::GetFullPath($rootItem.FullName)
    $indexPath = Join-Path $rootFull "corpus-index.json"
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        throw "Corpus root '$rootFull' has no corpus-index.json."
    }
    $indexBytes = [System.IO.File]::ReadAllBytes($indexPath)
    $indexSha = Get-ReviewerCorpusSealSha256 -Bytes $indexBytes
    if ($indexSha -cne $ExpectedIndexSha256.ToLowerInvariant()) {
        throw "Corpus index SHA-256 $indexSha does not match the expected $($ExpectedIndexSha256.ToLowerInvariant())."
    }
    $indexText = $script:ReviewerCorpusSealUtf8.GetString($indexBytes)
    try { $index = $indexText | ConvertFrom-Json -Depth 32 -ErrorAction Stop }
    catch { throw "Corpus index is not valid strict UTF-8 JSON." }
    if ($index -isnot [System.Management.Automation.PSCustomObject]) { throw "Corpus index must be a JSON object." }
    $kind = Get-ReviewerCorpusSealProperty -Object $index -Name "kind" -Type string -Where "Corpus index"
    if ($script:ReviewerCorpusIndexKinds -cnotcontains $kind) {
        throw "Corpus index kind '$kind' is not a private non-promotable research corpus."
    }
    $declaredCount = Get-ReviewerCorpusSealProperty -Object $index -Name "payloadCount" -Type int `
        -Where "Corpus index" -Min 1 -Max $script:ReviewerCorpusSealMaxPayloads
    $payloads = @(Get-ReviewerCorpusSealProperty -Object $index -Name "payloads" -Type array -Where "Corpus index")
    if ($payloads.Count -ne $declaredCount) {
        throw "Corpus index declares $declaredCount payload(s) but lists $($payloads.Count)."
    }
    $byPath = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $foldedSeen = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $payloads) {
        $path = Get-ReviewerCorpusSealProperty -Object $entry -Name "path" -Type string -Where "Corpus index payload"
        if (-not (Test-ReviewerCorpusSealRelativePath -Path $path)) {
            throw "Corpus index payload path '$path' is not a plain relative corpus path."
        }
        if ($byPath.ContainsKey($path)) { throw "Corpus index lists '$path' more than once." }
        if ($foldedSeen.ContainsKey($path)) {
            # Two names that differ only by case would resolve to one file on a
            # case-insensitive filesystem, so one entry could serve the other's
            # hash. Refused rather than picked between.
            throw "Corpus index lists '$path' and '$($foldedSeen[$path])', which alias one another."
        }
        $foldedSeen[$path] = $path
        $byPath[$path] = [pscustomobject][ordered]@{
            path = $path
            sha256 = Get-ReviewerCorpusSealProperty -Object $entry -Name "sha256" -Type sha256 -Where "Corpus index payload '$path'"
            length = Get-ReviewerCorpusSealProperty -Object $entry -Name "length" -Type int -Where "Corpus index payload '$path'" `
                -Min 0 -Max $script:ReviewerCorpusSealMaxPayloadBytes
        }
    }
    $identities = @{}
    if ($index.PSObject.Properties["identities"]) {
        $identityObject = $index.identities
        if ($identityObject -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Corpus index 'identities' must be an object."
        }
        foreach ($property in $identityObject.PSObject.Properties) { $identities[[string]$property.Name] = $property.Value }
    }
    # The corpus names the repository it was captured from, as
    # `organization/project/repositoryName`. It is required, not optional: the
    # seal has to bind organization, project and repository INDEPENDENTLY, and a
    # corpus that will not say which repository it came from cannot support that
    # - it would leave the recipe as the only witness to its own provenance.
    $repositoryText = Get-ReviewerCorpusSealProperty -Object $index -Name "repository" -Type string `
        -Where "Corpus index" -Pattern '^[^/\s]{1,128}/[^/\s]{1,128}/[^/\s]{1,128}\z'
    $repositoryParts = $repositoryText -split '/'
    return @{
        Root = $rootFull
        IndexSha256 = $indexSha
        PayloadCount = $declaredCount
        Payloads = $byPath
        Identities = $identities
        Repository = [pscustomobject][ordered]@{
            raw = $repositoryText
            organization = [string]$repositoryParts[0]
            project = [string]$repositoryParts[1]
            repositoryName = [string]$repositoryParts[2]
        }
    }
}

function Get-ReviewerCorpusSealPayload {
    <#
        Resolves ONE indexed corpus payload to bytes. Membership, on-disk length
        and on-disk SHA-256 are all required to agree with the index, and the
        resolved location must still be strictly inside the corpus after the
        filesystem has applied its own casing and short-name normalization. A
        path the index does not carry is refused outright, which is what stops an
        extra, unindexed file from entering a seal.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Index,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )
    if (-not (Test-ReviewerCorpusSealRelativePath -Path $Path)) {
        throw "Corpus path '$Path' is not a plain relative corpus path."
    }
    if (-not $Index.Payloads.ContainsKey($Path)) {
        throw "Corpus path '$Path' is not a member of the canonical corpus index."
    }
    $entry = $Index.Payloads[$Path]
    $full = $Index.Root
    $segments = @($Path -split '/')
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $full = Join-Path $full $segments[$i]
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        $isLast = ($i -eq ($segments.Count - 1))
        if ($isLast -and $item.PSIsContainer) { throw "Corpus path '$Path' is a directory, not a payload." }
        if (-not $isLast -and -not $item.PSIsContainer) { throw "Corpus path '$Path' traverses a non-directory." }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) {
            throw "Corpus path '$Path' passes through a reparse point."
        }
        if ($item.PSObject.Properties["LinkType"] -and $item.LinkType) {
            throw "Corpus path '$Path' passes through a $($item.LinkType); a corpus payload may not alias other content."
        }
    }
    $resolved = [System.IO.Path]::GetFullPath($full)
    $boundary = $Index.Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Corpus path '$Path' resolved outside the corpus boundary."
    }
    $bytes = [System.IO.File]::ReadAllBytes($resolved)
    if ($bytes.Length -ne [long]$entry.length) {
        throw "Corpus payload '$Path' is $($bytes.Length) bytes; the index records $($entry.length)."
    }
    $sha = Get-ReviewerCorpusSealSha256 -Bytes $bytes
    if ($sha -cne [string]$entry.sha256) {
        throw "Corpus payload '$Path' does not match its indexed SHA-256."
    }
    return @{ Path = $Path; Bytes = $bytes; Sha256 = $sha; ByteLength = [long]$bytes.Length }
}

function Get-ReviewerCorpusSealBoundPayload {
    <#
        Resolves an indexed payload AND requires the recipe's own independently
        declared hash and length to agree with the index. The recipe is written
        by an operator who has to state what they believe they are sealing; if
        the corpus disagrees, one of the two is wrong and neither is authoritative
        enough to overrule the other.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Index,
        [Parameter(Mandatory)]$Declaration,
        [Parameter(Mandatory)][string]$Where
    )
    Assert-ReviewerCorpusSealExactKeys -Object $Declaration -Where $Where -Expected @("corpusPath", "sha256", "byteLength")
    $path = Get-ReviewerCorpusSealProperty -Object $Declaration -Name "corpusPath" -Type string -Where $Where
    $sha = Get-ReviewerCorpusSealProperty -Object $Declaration -Name "sha256" -Type sha256 -Where $Where
    $length = Get-ReviewerCorpusSealProperty -Object $Declaration -Name "byteLength" -Type int -Where $Where `
        -Min 0 -Max $script:ReviewerCorpusSealMaxPayloadBytes
    $payload = Get-ReviewerCorpusSealPayload -Index $Index -Path $path
    if ($payload.Sha256 -cne $sha) { throw "$Where declares a SHA-256 the corpus payload '$path' does not have." }
    if ($payload.ByteLength -ne $length) { throw "$Where declares $length byte(s); corpus payload '$path' is $($payload.ByteLength)." }
    return $payload
}

function Import-ReviewerCorpusSealRecipe {
    <#
        Reads and shape-validates the PRIVATE recipe. Closed key sets everywhere:
        a field this build does not know is a field it cannot honour, and a
        recipe that silently carries one is a recipe whose author believes
        something is being enforced that is not.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Corpus seal recipe '$Path' does not exist." }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 2 -or $bytes.Length -gt 8388608) {
        throw "Corpus seal recipe is $($bytes.Length) bytes; expected 2..8388608."
    }
    $text = $script:ReviewerCorpusSealUtf8.GetString($bytes)
    try { $recipe = $text | ConvertFrom-Json -Depth 64 -ErrorAction Stop }
    catch { throw "Corpus seal recipe is not valid strict UTF-8 JSON." }
    if ($recipe -isnot [System.Management.Automation.PSCustomObject]) { throw "Corpus seal recipe must be a JSON object." }
    Assert-ReviewerCorpusSealExactKeys -Object $recipe -Where "Corpus seal recipe" -Expected @(
        "schemaVersion", "kind", "snapshotId", "provider", "capturedUtc", "corpus", "binding",
        "capture", "bindings", "hashes", "changeSet", "changedFiles", "evidence",
        "sourceTransport", "resources", "sourceCensus", "nonPromotable", "sealKind"
    )
    $schemaVersion = Get-ReviewerCorpusSealProperty -Object $recipe -Name "schemaVersion" -Type int `
        -Where "Corpus seal recipe" -Min 1 -Max 1
    if ($schemaVersion -ne $script:ReviewerCorpusSealSchemaVersion) {
        throw "Corpus seal recipe declares schema version $schemaVersion; this build seals version $script:ReviewerCorpusSealSchemaVersion."
    }
    $kind = Get-ReviewerCorpusSealProperty -Object $recipe -Name "kind" -Type string -Where "Corpus seal recipe"
    if ($kind -cne $script:ReviewerCorpusSealRecipeKind) {
        throw "Corpus seal recipe kind '$kind' is not '$script:ReviewerCorpusSealRecipeKind'."
    }
    if ((Get-ReviewerCorpusSealProperty -Object $recipe -Name "nonPromotable" -Type bool -Where "Corpus seal recipe") -ne $true) {
        throw "A corpus seal recipe must declare nonPromotable = true; an offline corpus seal is never promotable."
    }
    $sealKind = Get-ReviewerCorpusSealProperty -Object $recipe -Name "sealKind" -Type string -Where "Corpus seal recipe"
    if ($sealKind -cne "offlineCorpusSeal") {
        throw "A corpus seal recipe must declare sealKind = 'offlineCorpusSeal'."
    }
    return $recipe
}

function ConvertTo-ReviewerCorpusSealJsonString {
    <#
        The canonical renderer's own string escaping, reached through the one
        exported entry point. Reimplementing the escape table here would give the
        seal a second definition of "the same string", which is exactly the class
        of drift the canonical form exists to remove.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return (ConvertTo-AgentReplayCanonicalJson -Value $Value)
}

function Get-ReviewerCorpusSealTextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return (Get-ReviewerCorpusSealSha256 -Bytes ($script:ReviewerCorpusSealUtf8.GetBytes($Text)))
}

function New-ReviewerCorpusSealEnvelope {
    <#
        Materializes ONE recorded read as the exact JSON-RPC response line the
        replay loader serves. The transform is fixed by the declared envelope
        kind and is byte-deterministic, so two seals of one recipe over one
        corpus produce identical payloads:

          jsonRpcResult      - the corpus payload IS the tool result, MCP content
                               shape and all; it is embedded verbatim, so the
                               sealed bytes contain the captured bytes
                               unchanged. A captured REST body is NOT a tool
                               result and is refused here.
          mcpTextContent     - the corpus payload is the text a text-content tool
                               returned.
          mcpResourceContent - the corpus payload is file content an embedded
                               resource carried; base64 is canonical by
                               construction and the URI/MIME are pinned by the
                               recipe.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet("jsonRpcResult", "mcpTextContent", "mcpResourceContent")][string]$Envelope,
        [Parameter(Mandatory)][hashtable]$Payload,
        [AllowEmptyString()][string]$ResourceUri = "",
        [AllowEmptyString()][string]$MimeType = ""
    )
    $text = $script:ReviewerCorpusSealUtf8.GetString($Payload.Bytes)
    switch ($Envelope) {
        "jsonRpcResult" {
            $parsed = $null
            try { $parsed = $text | ConvertFrom-Json -Depth 64 -ErrorAction Stop }
            catch { throw "Corpus payload '$($Payload.Path)' is not valid JSON and cannot be a JSON-RPC result." }
            # Embedding verbatim is only honest when what was captured IS a tool
            # result. A captured REST body seals, loads and binds cleanly and
            # then cannot be read by anything, because every reader goes through
            # Invoke-AgentMcpTool. Such a payload belongs in an mcpTextContent
            # envelope - that is the exact shape the MCP server returns for it.
            if (-not (Test-AgentMcpToolResultShape -Result $parsed)) {
                throw ("Corpus payload '$($Payload.Path)' is not an MCP tool result, so a jsonRpcResult " +
                    "envelope would seal a response no reader can consume. Declare it as mcpTextContent, " +
                    "which wraps the captured text the way the MCP server does.")
            }
            return $script:ReviewerCorpusSealUtf8.GetBytes('{"jsonrpc":"2.0","result":' + $text + '}')
        }
        "mcpTextContent" {
            $encoded = ConvertTo-ReviewerCorpusSealJsonString -Value $text
            return $script:ReviewerCorpusSealUtf8.GetBytes(
                '{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":' + $encoded + '}]}}')
        }
        "mcpResourceContent" {
            if (-not $ResourceUri) { throw "An mcpResourceContent resource must declare its exact resourceUri." }
            if (-not $MimeType) { throw "An mcpResourceContent resource must declare its exact mimeType." }
            if ($Payload.ByteLength -lt 1) { throw "Corpus payload '$($Payload.Path)' is empty and cannot be an embedded resource." }
            $blob = [Convert]::ToBase64String($Payload.Bytes)
            return $script:ReviewerCorpusSealUtf8.GetBytes(
                '{"jsonrpc":"2.0","result":{"content":[{"type":"resource","resource":{"uri":' +
                (ConvertTo-ReviewerCorpusSealJsonString -Value $ResourceUri) + ',"mimeType":' +
                (ConvertTo-ReviewerCorpusSealJsonString -Value $MimeType) + ',"blob":"' + $blob + '"}}]}}')
        }
    }
    throw "Unsupported corpus seal envelope '$Envelope'."
}

function Get-ReviewerCorpusSealIdentity {
    <#
        The corpus's own record of what was captured, for the ONE pull request
        this seal is about. A recipe whose binding disagrees with it - a stale
        source commit, a different iteration, another pull request's identity -
        is refused here, before a single byte is written.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Index,
        [Parameter(Mandatory)][int]$PullRequestId
    )
    $key = [string]$PullRequestId
    if (-not $Index.Identities.ContainsKey($key)) {
        throw "The corpus index carries no captured identity for pull request $PullRequestId."
    }
    $identity = $Index.Identities[$key]
    return [pscustomobject][ordered]@{
        pullRequestId = [int](Get-ReviewerCorpusSealProperty -Object $identity -Name "pullRequestId" -Type int `
                -Where "Corpus identity $key" -Min 1)
        iteration = [int](Get-ReviewerCorpusSealProperty -Object $identity -Name "iteration" -Type int `
                -Where "Corpus identity $key" -Min 1)
        source = (Get-ReviewerCorpusSealProperty -Object $identity -Name "source" -Type commit -Where "Corpus identity $key")
        common = (Get-ReviewerCorpusSealProperty -Object $identity -Name "common" -Type commit -Where "Corpus identity $key")
        target = (Get-ReviewerCorpusSealProperty -Object $identity -Name "target" -Type commit -Where "Corpus identity $key")
        status = (Get-ReviewerCorpusSealProperty -Object $identity -Name "status" -Type string -Where "Corpus identity $key")
        isDraft = [bool](Get-ReviewerCorpusSealProperty -Object $identity -Name "isDraft" -Type bool -Where "Corpus identity $key")
    }
}

function New-ReviewerCorpusSealPlan {
    <#
        The whole validation. Nothing is written until every check below has
        passed, so a refusal is always a refusal to CREATE rather than a
        half-written snapshot someone has to clean up.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Index,
        [Parameter(Mandatory)]$Recipe,
        [string]$ToolkitRoot
    )
    # -- corpus binding -----------------------------------------------------
    $corpus = Get-ReviewerCorpusSealProperty -Object $Recipe -Name "corpus" -Type object -Where "Corpus seal recipe"
    Assert-ReviewerCorpusSealExactKeys -Object $corpus -Where "Corpus seal recipe corpus" -Expected @("indexSha256", "payloadCount")
    $declaredIndexSha = Get-ReviewerCorpusSealProperty -Object $corpus -Name "indexSha256" -Type sha256 -Where "Corpus seal recipe corpus"
    if ($declaredIndexSha -cne $Index.IndexSha256) {
        throw "Corpus seal recipe binds index $declaredIndexSha but the opened corpus index is $($Index.IndexSha256)."
    }
    $declaredPayloadCount = Get-ReviewerCorpusSealProperty -Object $corpus -Name "payloadCount" -Type int `
        -Where "Corpus seal recipe corpus" -Min 1 -Max $script:ReviewerCorpusSealMaxPayloads
    if ($declaredPayloadCount -ne $Index.PayloadCount) {
        throw "Corpus seal recipe binds $declaredPayloadCount corpus payload(s); the index carries $($Index.PayloadCount)."
    }

    # -- snapshot identity --------------------------------------------------
    $snapshotId = Get-ReviewerCorpusSealProperty -Object $Recipe -Name "snapshotId" -Type string `
        -Where "Corpus seal recipe" -Pattern $script:ReviewerCorpusSealSnapshotNamePattern
    if ($snapshotId -cnotmatch 'offlinecorpusseal') {
        # The name is the one label that travels with a snapshot everywhere it
        # is copied, quoted or logged, so it - not only a sidecar - has to say
        # what this artifact is.
        throw "An offline corpus seal must carry 'offlinecorpusseal' in its snapshot id; '$snapshotId' does not."
    }
    $provider = Get-ReviewerCorpusSealProperty -Object $Recipe -Name "provider" -Type string `
        -Where "Corpus seal recipe" -Pattern '^[a-z][a-z0-9-]{0,31}\z'
    $capturedUtc = Get-ReviewerCorpusSealProperty -Object $Recipe -Name "capturedUtc" -Type string `
        -Where "Corpus seal recipe" -Pattern '^\d{8}T\d{6}Z\z'

    # -- binding, checked against the corpus's own captured identity --------
    $binding = Get-ReviewerCorpusSealProperty -Object $Recipe -Name "binding" -Type object -Where "Corpus seal recipe"
    Assert-ReviewerCorpusSealExactKeys -Object $binding -Where "Corpus seal recipe binding" -Expected @(
        "organization", "project", "repositoryId", "repositoryName", "pullRequestId", "iterationId",
        "sourceCommit", "commonCommit", "targetCommit", "changeSetSha256"
    )
    $bound = [ordered]@{
        organization = Get-ReviewerCorpusSealProperty -Object $binding -Name "organization" -Type string `
            -Where "Corpus seal recipe binding" -Pattern '^[^/\s]{1,128}\z'
        project = Get-ReviewerCorpusSealProperty -Object $binding -Name "project" -Type string `
            -Where "Corpus seal recipe binding" -Pattern '^[^/\s]{1,128}\z'
        repositoryId = Get-ReviewerCorpusSealProperty -Object $binding -Name "repositoryId" -Type string `
            -Where "Corpus seal recipe binding" -Pattern '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
        repositoryName = Get-ReviewerCorpusSealProperty -Object $binding -Name "repositoryName" -Type string `
            -Where "Corpus seal recipe binding" -Pattern '^[^/\s]{1,128}\z'
        pullRequestId = [int](Get-ReviewerCorpusSealProperty -Object $binding -Name "pullRequestId" -Type int `
                -Where "Corpus seal recipe binding" -Min 1)
        iterationId = [int](Get-ReviewerCorpusSealProperty -Object $binding -Name "iterationId" -Type int `
                -Where "Corpus seal recipe binding" -Min 1)
        sourceCommit = Get-ReviewerCorpusSealProperty -Object $binding -Name "sourceCommit" -Type commit -Where "Corpus seal recipe binding"
        commonCommit = Get-ReviewerCorpusSealProperty -Object $binding -Name "commonCommit" -Type commit -Where "Corpus seal recipe binding"
        targetCommit = Get-ReviewerCorpusSealProperty -Object $binding -Name "targetCommit" -Type commit -Where "Corpus seal recipe binding"
        changeSetSha256 = Get-ReviewerCorpusSealProperty -Object $binding -Name "changeSetSha256" -Type sha256 -Where "Corpus seal recipe binding"
    }
    # Organization, project and repository are bound INDEPENDENTLY, each against a
    # witness the recipe does not control. Two of them come from the corpus
    # index's own `organization/project/repositoryName`; the repository GUID comes
    # from the captured identity payload below. Checking only the pull request id
    # would let a recipe re-label one repository's capture as another's - the
    # payloads would still hash correctly, and every downstream digest would agree
    # with itself about a pull request that never existed there.
    if ($bound.organization -cne [string]$Index.Repository.organization -or
        $bound.project -cne [string]$Index.Repository.project -or
        $bound.repositoryName -cne [string]$Index.Repository.repositoryName) {
        throw ("Corpus seal recipe binds $($bound.organization)/$($bound.project)/$($bound.repositoryName); the corpus " +
            "index was captured from $($Index.Repository.raw).")
    }
    $identity = Get-ReviewerCorpusSealIdentity -Index $Index -PullRequestId $bound.pullRequestId
    if ($identity.pullRequestId -ne $bound.pullRequestId -or $identity.iteration -ne $bound.iterationId -or
        $identity.source -cne $bound.sourceCommit -or $identity.common -cne $bound.commonCommit -or
        $identity.target -cne $bound.targetCommit) {
        throw ("Corpus seal recipe binding does not match the corpus's captured identity for pull request " +
            "$($bound.pullRequestId); a stale commit, a different iteration or another pull request's identity was substituted.")
    }

    # -- capture provenance and status at capture ---------------------------
    $capture = Get-ReviewerCorpusSealProperty -Object $Recipe -Name "capture" -Type object -Where "Corpus seal recipe"
    Assert-ReviewerCorpusSealExactKeys -Object $capture -Where "Corpus seal recipe capture" -Expected @(
        "identity", "endIdentity", "statusAtCapture", "isDraft", "mode", "livePostReadRaceCheck"
    )
    $captureIdentity = Get-ReviewerCorpusSealBoundPayload -Index $Index `
        -Declaration (Get-ReviewerCorpusSealProperty -Object $capture -Name "identity" -Type object -Where "Corpus seal recipe capture") `
        -Where "Corpus seal capture identity"
    $captureEndIdentity = Get-ReviewerCorpusSealBoundPayload -Index $Index `
        -Declaration (Get-ReviewerCorpusSealProperty -Object $capture -Name "endIdentity" -Type object -Where "Corpus seal recipe capture") `
        -Where "Corpus seal capture end identity"
    $statusAtCapture = Get-ReviewerCorpusSealProperty -Object $capture -Name "statusAtCapture" -Type string `
        -Where "Corpus seal recipe capture" -Pattern '^[a-zA-Z][a-zA-Z0-9 ._-]{0,63}\z'
    $captureIsDraft = [bool](Get-ReviewerCorpusSealProperty -Object $capture -Name "isDraft" -Type bool -Where "Corpus seal recipe capture")
    $captureMode = Get-ReviewerCorpusSealProperty -Object $capture -Name "mode" -Type string `
        -Where "Corpus seal recipe capture" -Pattern '^[a-zA-Z][a-zA-Z0-9._-]{0,63}\z'
    $raceCheck = Get-ReviewerCorpusSealProperty -Object $capture -Name "livePostReadRaceCheck" -Type string -Where "Corpus seal recipe capture"
    if ($raceCheck -cne "notPerformed") {
        # A seal built from a corpus performed no live read at all, so it cannot
        # have re-checked the pull request after one. Recording anything else
        # would be the seal claiming a guarantee it did not obtain.
        throw "An offline corpus seal must record livePostReadRaceCheck = 'notPerformed'; it never contacts a live host."
    }
    if ($statusAtCapture -cne [string]$identity.status -or $captureIsDraft -ne [bool]$identity.isDraft) {
        throw "Corpus seal recipe records a status-at-capture the corpus index does not."
    }
    $captureIdentityJson = $script:ReviewerCorpusSealUtf8.GetString($captureIdentity.Bytes) | ConvertFrom-Json -Depth 32
    foreach ($pair in @(
            @("pullRequestId", [int]$bound.pullRequestId),
            @("repositoryId", [string]$bound.repositoryId),
            @("sourceCommit", [string]$bound.sourceCommit),
            @("targetCommit", [string]$bound.targetCommit),
            @("commonCommit", [string]$bound.commonCommit),
            @("iterationId", [int]$bound.iterationId),
            @("status", [string]$statusAtCapture))) {
        $name = [string]$pair[0]
        if (-not $captureIdentityJson.PSObject.Properties[$name]) {
            throw "The captured identity payload omits '$name'."
        }
        if ([string]$captureIdentityJson.PSObject.Properties[$name].Value -cne [string]$pair[1]) {
            throw "The captured identity payload's '$name' does not match the sealed binding."
        }
    }
    if (-not $captureIdentityJson.PSObject.Properties["isDraft"]) {
        throw "The captured identity payload omits 'isDraft'."
    }
    if ([bool]$captureIdentityJson.isDraft -ne $captureIsDraft) {
        throw "The captured identity payload's 'isDraft' does not match the sealed binding."
    }
    # The END of capture is the only evidence that the pull request did not move
    # WHILE it was being read. Checking only its pull request id made it almost
    # decorative: a capture whose source commit advanced mid-read would have
    # sealed a mixture of two iterations and still passed. Every field it carries
    # that the binding can be compared to is compared, and a capture that says it
    # does not match its own beginning is refused outright.
    $endIdentityJson = $script:ReviewerCorpusSealUtf8.GetString($captureEndIdentity.Bytes) | ConvertFrom-Json -Depth 32
    if ([int]$endIdentityJson.pullRequestId -ne [int]$bound.pullRequestId) {
        throw "The end-of-capture identity payload is about a different pull request."
    }
    $endIdentityChecked = 0
    foreach ($pair in @(
            @(@("sourceCommit", "lastMergeSourceCommit"), [string]$bound.sourceCommit, "source commit"),
            @(@("targetCommit", "lastMergeTargetCommit"), [string]$bound.targetCommit, "target commit"),
            @(@("status"), [string]$statusAtCapture, "status"),
            @(@("repositoryId"), [string]$bound.repositoryId, "repository"))) {
        foreach ($name in @($pair[0])) {
            if (-not $endIdentityJson.PSObject.Properties[$name]) { continue }
            $endIdentityChecked++
            if ([string]$endIdentityJson.PSObject.Properties[$name].Value -cne [string]$pair[1]) {
                throw ("The end-of-capture identity payload's '$name' does not match the sealed $($pair[2]); the pull " +
                    "request moved while it was being captured, so this corpus is not one coherent snapshot.")
            }
        }
    }
    if ($endIdentityJson.PSObject.Properties["isDraft"]) {
        $endIdentityChecked++
        if ([bool]$endIdentityJson.isDraft -ne $captureIsDraft) {
            throw "The end-of-capture identity payload's 'isDraft' does not match the sealed capture."
        }
    }
    if ($endIdentityJson.PSObject.Properties["matchesInitialCapture"]) {
        $endIdentityChecked++
        if (-not [bool]$endIdentityJson.matchesInitialCapture) {
            throw ("The end-of-capture identity payload records matchesInitialCapture = false; the capture drifted " +
                "from its own starting identity and cannot be sealed as one snapshot.")
        }
    }
    if ($endIdentityChecked -lt 1) {
        throw ("The end-of-capture identity payload carries nothing the sealed binding can be checked against; a " +
            "capture with no verifiable end state proves nothing about drift during the read.")
    }

    # -- prompt/config/script/schema/policy hashes --------------------------
    $bindings = Get-ReviewerCorpusSealProperty -Object $Recipe -Name "bindings" -Type object -Where "Corpus seal recipe"
    Assert-ReviewerCorpusSealExactKeys -Object $bindings -Where "Corpus seal recipe bindings" -Expected @(
        "configSha256", "scriptSha256", "promptSha256", "models"
    )
    $models = @(Get-ReviewerCorpusSealProperty -Object $bindings -Name "models" -Type array -Where "Corpus seal recipe bindings")
    if ($models.Count -gt 8) { throw "Corpus seal recipe binds more than 8 models." }
    foreach ($model in $models) {
        if ($model -isnot [string] -or [string]$model -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
            throw "Corpus seal recipe model binding is not a plain model name."
        }
    }
    $bindingsRecord = [ordered]@{
        configSha256 = Get-ReviewerCorpusSealProperty -Object $bindings -Name "configSha256" -Type sha256 -Where "Corpus seal recipe bindings"
        scriptSha256 = Get-ReviewerCorpusSealProperty -Object $bindings -Name "scriptSha256" -Type sha256 -Where "Corpus seal recipe bindings"
        promptSha256 = Get-ReviewerCorpusSealProperty -Object $bindings -Name "promptSha256" -Type sha256 -Where "Corpus seal recipe bindings"
        models = @($models | ForEach-Object { [string]$_ })
    }
    $hashes = Get-ReviewerCorpusSealProperty -Object $Recipe -Name "hashes" -Type object -Where "Corpus seal recipe"
    Assert-ReviewerCorpusSealExactKeys -Object $hashes -Where "Corpus seal recipe hashes" -Expected @(
        "policySha256", "configSha256", "scriptSha256", "schemaSha256", "promptSha256"
    )
    $hashRecord = [ordered]@{}
    foreach ($name in @("policySha256", "configSha256", "scriptSha256", "schemaSha256", "promptSha256")) {
        $hashRecord[$name] = Get-ReviewerCorpusSealProperty -Object $hashes -Name $name -Type sha256 -Where "Corpus seal recipe hashes"
    }
    if ($hashRecord.configSha256 -cne $bindingsRecord.configSha256 -or
        $hashRecord.scriptSha256 -cne $bindingsRecord.scriptSha256 -or
        $hashRecord.promptSha256 -cne $bindingsRecord.promptSha256) {
        throw "Corpus seal recipe states config/script/prompt hashes twice and they disagree."
    }

    # -- authoritative change set: digest AND order -------------------------
    $changeSet = Get-ReviewerCorpusSealProperty -Object $Recipe -Name "changeSet" -Type object -Where "Corpus seal recipe"
    Assert-ReviewerCorpusSealExactKeys -Object $changeSet -Where "Corpus seal recipe changeSet" -Expected @(
        "authoritative", "digestOrder", "spanEvidence"
    )
    $changeSetPayload = Get-ReviewerCorpusSealBoundPayload -Index $Index `
        -Declaration (Get-ReviewerCorpusSealProperty -Object $changeSet -Name "authoritative" -Type object -Where "Corpus seal recipe changeSet") `
        -Where "Corpus seal authoritative change set"
    $changeSetJson = $script:ReviewerCorpusSealUtf8.GetString($changeSetPayload.Bytes) | ConvertFrom-Json -Depth 32
    $computedChangeDigest = Get-ReviewerSourceChangeIdentityDigest -Response $changeSetJson
    if ($computedChangeDigest -cne $bound.changeSetSha256) {
        throw ("The authoritative change set digests to $computedChangeDigest, not the bound $($bound.changeSetSha256); " +
            "the recipe and the corpus disagree about which files changed.")
    }
    $digestOrder = @(Get-ReviewerCorpusSealProperty -Object $changeSet -Name "digestOrder" -Type array -Where "Corpus seal recipe changeSet")
    # Normalize every raw path and REFUSE the ones that will not normalize. The
    # previous revision filtered them out, which silently shrank the denominator:
    # a change set carrying an unusable path would have produced a seal that
    # claimed complete coverage of a change set it had quietly redacted. A path
    # the reviewer cannot address is a reason this corpus cannot be sealed, not a
    # row to drop.
    $rawAuthoritativePaths = @(Get-ReviewerSourceRawChangedPaths -Response $changeSetJson)
    $authoritativeList = [System.Collections.Generic.List[string]]::new()
    $authoritativeSeen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($raw in $rawAuthoritativePaths) {
        $normalized = ConvertTo-ReviewerSourcePath -Path ([string]$raw)
        if (-not $normalized) {
            throw ("The authoritative change set carries the path '$([string]$raw)', which does not normalize to an " +
                "addressable repository path; a corpus whose change set the reviewer cannot address cannot be sealed.")
        }
        if (-not $authoritativeSeen.Add($normalized)) {
            throw ("The authoritative change set names '$normalized' more than once; a seal cannot bind one path to " +
                "two positions in the change-set order.")
        }
        [void]$authoritativeList.Add($normalized)
    }
    $authoritativePaths = @($authoritativeList.ToArray())
    if ($digestOrder.Count -ne $authoritativePaths.Count) {
        throw "Corpus seal recipe declares $($digestOrder.Count) change-set path(s); the authoritative change set carries $($authoritativePaths.Count)."
    }
    for ($i = 0; $i -lt $digestOrder.Count; $i++) {
        if ([string]$digestOrder[$i] -cne [string]$authoritativePaths[$i]) {
            throw "Corpus seal recipe change-set order differs from the authoritative change set at position $($i + 1)."
        }
    }
    # The change set's OWN statement about what happened to each path. This, not
    # the recipe, decides which paths are content-bearing - a recipe that could
    # nominate its own change kinds could excuse any path it did not want to
    # deliver, which is exactly the hole the census is supposed to close.
    $authoritativeKindsByPath = Get-ReviewerSourceChangeKindsByPath -Response $changeSetJson
    $authoritativeRightHand = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $authoritativePaths) {
        if (-not $authoritativeKindsByPath.Contains($path)) {
            throw "The authoritative change set carries '$path' but declares no change type for it."
        }
        if (Test-ReviewerSourceChangeCarriesRightHand -ChangeTypeValue $authoritativeKindsByPath[$path]) {
            [void]$authoritativeRightHand.Add($path)
        }
    }

    # -- authoritative right-hand spans, from indexed evidence --------------
    # The spans come from the capture, not the recipe. Anything the evidence does
    # not describe cannot be sealed with spans, and anything the evidence does
    # describe has to be a path the change set carries - otherwise a span census
    # from one pull request could be spliced onto another's file list.
    $spanEvidencePayload = Get-ReviewerCorpusSealBoundPayload -Index $Index `
        -Declaration (Get-ReviewerCorpusSealProperty -Object $changeSet -Name "spanEvidence" -Type object `
            -Where "Corpus seal recipe changeSet") `
        -Where "Corpus seal span evidence"
    $spanEvidenceJson = $script:ReviewerCorpusSealUtf8.GetString($spanEvidencePayload.Bytes) | ConvertFrom-Json -Depth 32
    $authoritativeSpansByPath = Get-ReviewerCorpusSealSpanEvidence -Evidence $spanEvidenceJson `
        -Where "Corpus seal span evidence '$($spanEvidencePayload.Path)'"
    foreach ($evidencePath in @($authoritativeSpansByPath.Keys)) {
        if ($authoritativePaths -cnotcontains $evidencePath) {
            throw ("Corpus seal span evidence describes '$evidencePath', which the authoritative change set does not " +
                "carry; span evidence and change set must describe the same pull request.")
        }
    }
    foreach ($path in $authoritativeRightHand) {
        if (-not $authoritativeSpansByPath.Contains($path)) {
            throw ("Corpus seal span evidence describes no hunks for '$path', which the authoritative change set says " +
                "carries right-hand content; a seal cannot invent the lines it shows.")
        }
    }

    # -- changed files: right-hand payload and exact spans, in full ---------
    $changedFiles = @(Get-ReviewerCorpusSealProperty -Object $Recipe -Name "changedFiles" -Type array -Where "Corpus seal recipe")
    $spansByPath = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $rightHandByPath = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $changeKindsByPath = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($file in $changedFiles) {
        Assert-ReviewerCorpusSealExactKeys -Object $file -Where "Corpus seal changed file" -Expected @(
            "path", "changeKinds", "rightHand", "spans"
        )
        $rawPath = Get-ReviewerCorpusSealProperty -Object $file -Name "path" -Type string -Where "Corpus seal changed file"
        $path = ConvertTo-ReviewerSourcePath -Path $rawPath
        if (-not $path -or $path -cne $rawPath) {
            throw "Corpus seal changed-file path '$rawPath' is not already in normalized form."
        }
        if ($rightHandByPath.ContainsKey($path)) { throw "Corpus seal recipe declares changed file '$path' twice." }
        if ($authoritativePaths -cnotcontains $path) {
            throw "Corpus seal recipe declares changed file '$path', which the authoritative change set does not carry."
        }
        $kinds = @(Get-ReviewerCorpusSealProperty -Object $file -Name "changeKinds" -Type array -Where "Corpus seal changed file '$path'")
        foreach ($kind in $kinds) {
            if ($kind -isnot [string] -or [string]$kind -cnotmatch '^[a-z]{1,32}$') {
                throw "Corpus seal changed file '$path' declares a malformed change kind."
            }
        }
        # The recipe restates the change kinds so an operator has to say what they
        # believe happened to this path, but the change set is what DECIDES it.
        # Anywhere the two disagree the seal refuses: a recipe that could pick its
        # own kinds could relabel an edit as a delete and walk the path straight
        # out of the coverage denominator.
        $declaredKinds = [string[]]@(@($kinds | ForEach-Object { [string]$_ }) | Sort-Object -CaseSensitive -Unique)
        $authoritativeKinds = [string[]]@(@($authoritativeKindsByPath[$path]) |
                ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive -Unique)
        if (($declaredKinds -join "`n") -cne ($authoritativeKinds -join "`n")) {
            throw ("Corpus seal changed file '$path' declares change kinds [$($declaredKinds -join ', ')]; the " +
                "authoritative change set declares [$($authoritativeKinds -join ', ')].")
        }
        if (-not $authoritativeRightHand.Contains($path)) {
            throw ("Corpus seal recipe seals right-hand content for '$path', but the authoritative change set's own " +
                "change kinds [$($authoritativeKinds -join ', ')] say it has none.")
        }
        $changeKindsByPath[$path] = $authoritativeKinds
        $rightHand = Get-ReviewerCorpusSealBoundPayload -Index $Index `
            -Declaration (Get-ReviewerCorpusSealProperty -Object $file -Name "rightHand" -Type object -Where "Corpus seal changed file '$path'") `
            -Where "Corpus seal right-hand payload for '$path'"
        $rightHandByPath[$path] = $rightHand
        $spans = @(Get-ReviewerCorpusSealProperty -Object $file -Name "spans" -Type array -Where "Corpus seal changed file '$path'")
        if ($spans.Count -lt 1) {
            throw "Corpus seal changed file '$path' declares no right-hand span; a changed file with right-hand content has at least one."
        }
        # The recipe restates the spans; the EVIDENCE decides them. Any divergence
        # is a refusal, so a recipe cannot seal one file's bytes while addressing
        # another file's lines, and cannot widen or shift a span to pull unchanged
        # code into the reviewer's window.
        $derivedSpans = @($authoritativeSpansByPath[$path])
        if ($derivedSpans.Count -lt 1) {
            throw ("Corpus seal changed file '$path' declares right-hand spans, but the span evidence derives none " +
                "for it.")
        }
        if ($spans.Count -ne $derivedSpans.Count) {
            throw ("Corpus seal changed file '$path' declares $($spans.Count) span(s); the authoritative span " +
                "evidence derives $($derivedSpans.Count).")
        }
        $spanList = [System.Collections.Generic.List[object]]::new()
        $previousEnd = 0
        for ($spanIndex = 0; $spanIndex -lt $spans.Count; $spanIndex++) {
            $span = $spans[$spanIndex]
            Assert-ReviewerCorpusSealExactKeys -Object $span -Where "Corpus seal span for '$path'" -Expected @("start", "count")
            $start = [int](Get-ReviewerCorpusSealProperty -Object $span -Name "start" -Type int -Where "Corpus seal span for '$path'" -Min 1)
            $count = [int](Get-ReviewerCorpusSealProperty -Object $span -Name "count" -Type int -Where "Corpus seal span for '$path'" -Min 1)
            $derived = $derivedSpans[$spanIndex]
            if ($start -ne [int]$derived.Start -or $count -ne [int]$derived.Count) {
                throw ("Corpus seal changed file '$path' declares span $($spanIndex + 1) as ($start, $count); the " +
                    "authoritative span evidence derives ($($derived.Start), $($derived.Count)).")
            }
            if ($start -le $previousEnd) {
                throw "Corpus seal spans for '$path' are not in strictly ascending, non-overlapping order."
            }
            $previousEnd = $start + $count - 1
            [void]$spanList.Add(@{ Start = $start; End = $previousEnd })
        }
        $spansByPath[$path] = @($spanList.ToArray())
    }

    # -- the source census: complete, or refused ----------------------------
    $census = Get-ReviewerCorpusSealProperty -Object $Recipe -Name "sourceCensus" -Type object -Where "Corpus seal recipe"
    Assert-ReviewerCorpusSealExactKeys -Object $census -Where "Corpus seal recipe sourceCensus" -Expected @(
        "authoritativeChangedPathCount", "rightHandCoveredPathCount", "noRightHandPaths"
    )
    $declaredChangedCount = [int](Get-ReviewerCorpusSealProperty -Object $census -Name "authoritativeChangedPathCount" `
            -Type int -Where "Corpus seal recipe sourceCensus" -Min 0)
    $declaredCoveredCount = [int](Get-ReviewerCorpusSealProperty -Object $census -Name "rightHandCoveredPathCount" `
            -Type int -Where "Corpus seal recipe sourceCensus" -Min 0)
    $noRightHandPaths = @(Get-ReviewerCorpusSealProperty -Object $census -Name "noRightHandPaths" -Type array `
            -Where "Corpus seal recipe sourceCensus" | ForEach-Object { [string]$_ })
    if ($declaredChangedCount -ne $authoritativePaths.Count) {
        throw "Corpus seal census declares $declaredChangedCount authoritative changed path(s); the change set carries $($authoritativePaths.Count)."
    }
    if ($declaredCoveredCount -ne $rightHandByPath.Count) {
        throw "Corpus seal census declares $declaredCoveredCount covered path(s); the recipe carries $($rightHandByPath.Count)."
    }
    foreach ($path in $noRightHandPaths) {
        if ($authoritativePaths -cnotcontains $path) {
            throw "Corpus seal census excuses '$path', which the authoritative change set does not carry."
        }
        if ($rightHandByPath.ContainsKey($path)) {
            throw "Corpus seal census excuses '$path' while the recipe also seals its right-hand content."
        }
        # A path is excusable only when the change set itself proves it: a delete,
        # a rename half, or a pure metadata change. Letting the recipe decide
        # would make the census self-certifying, and "we didn't deliver it because
        # we said we didn't have to" is precisely the shape of hole a completeness
        # claim is supposed to rule out.
        if ($authoritativeRightHand.Contains($path)) {
            $kindText = @($authoritativeKindsByPath[$path]) -join ', '
            throw ("Corpus seal census excuses '$path' as carrying no right-hand source, but the authoritative " +
                "change set declares change kinds [$kindText], which do carry right-hand content.")
        }
    }
    $uncovered = @($authoritativePaths | Where-Object {
            -not $rightHandByPath.ContainsKey($_) -and $noRightHandPaths -cnotcontains $_
        })
    if ($uncovered.Count -gt 0) {
        # The census is the whole point of a seal claiming completeness: a path
        # that is neither delivered nor explicitly accounted for as having no
        # right-hand content is an unexplained hole, and a snapshot with one is
        # not a complete replay of the change set.
        throw ("Corpus seal source census is incomplete: $($uncovered.Count) authoritative changed path(s) are neither " +
            "sealed nor accounted for as carrying no right-hand source ($($uncovered -join ', ')).")
    }
    # Every content-bearing path the change set names must actually be sealed.
    # The two checks are not redundant: the one above catches a path nobody
    # mentioned, this one catches a path the census mentioned in the wrong list.
    $missingRightHand = @($authoritativeRightHand | Where-Object { -not $rightHandByPath.ContainsKey($_) })
    if ($missingRightHand.Count -gt 0) {
        throw ("Corpus seal source census is incomplete: the authoritative change set says " +
            "$($missingRightHand.Count) path(s) carry right-hand content that this recipe does not seal " +
            "($($missingRightHand -join ', ')).")
    }

    # -- evidence the prompts consume ---------------------------------------
    $evidence = Get-ReviewerCorpusSealProperty -Object $Recipe -Name "evidence" -Type object -Where "Corpus seal recipe"
    Assert-ReviewerCorpusSealExactKeys -Object $evidence -Where "Corpus seal recipe evidence" -Expected @(
        "siblings", "rules", "threads", "facts"
    )
    $evidenceRecord = [ordered]@{}
    $evidenceSeen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($class in @("siblings", "rules", "threads", "facts")) {
        $items = @(Get-ReviewerCorpusSealProperty -Object $evidence -Name $class -Type array -Where "Corpus seal recipe evidence")
        $resolved = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $items) {
            $payload = Get-ReviewerCorpusSealBoundPayload -Index $Index -Declaration $item -Where "Corpus seal $class evidence"
            if (-not $evidenceSeen.Add($payload.Path)) {
                throw "Corpus seal recipe cites evidence payload '$($payload.Path)' more than once."
            }
            [void]$resolved.Add($payload)
        }
        $evidenceRecord[$class] = @($resolved.ToArray())
    }

    # -- recorded reads ------------------------------------------------------
    $resources = @(Get-ReviewerCorpusSealProperty -Object $Recipe -Name "resources" -Type array -Where "Corpus seal recipe")
    if ($resources.Count -lt 1 -or $resources.Count -gt $script:ReviewerCorpusSealMaxPayloads) {
        throw "Corpus seal recipe declares $($resources.Count) resource(s); expected 1..$script:ReviewerCorpusSealMaxPayloads."
    }
    $plannedResources = [System.Collections.Generic.List[object]]::new()
    $requestKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $payloadFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $totalBytes = [long]0
    $resourceIndex = 0
    foreach ($resource in $resources) {
        $resourceIndex++
        Assert-ReviewerCorpusSealExactKeys -Object $resource -Where "Corpus seal resource $resourceIndex" -Expected @(
            "tool", "arguments", "envelope", "payloadFile", "corpusPayload", "resourceUri", "mimeType", "expected"
        )
        $tool = Get-ReviewerCorpusSealProperty -Object $resource -Name "tool" -Type string `
            -Where "Corpus seal resource $resourceIndex" -Pattern '^[a-z][a-z0-9_]{0,63}\z'
        $arguments = Get-ReviewerCorpusSealProperty -Object $resource -Name "arguments" -Type object -Where "Corpus seal resource $resourceIndex"
        $permitted = Test-AgentReplayToolPermitted -Name $tool -Arguments $arguments
        if (-not $permitted.Permitted) {
            throw "Corpus seal resource $resourceIndex records $($permitted.Reason); a replay snapshot may only carry reads."
        }
        $envelope = Get-ReviewerCorpusSealProperty -Object $resource -Name "envelope" -Type string -Where "Corpus seal resource $resourceIndex"
        if ($script:ReviewerCorpusSealEnvelopes -cnotcontains $envelope) {
            throw "Corpus seal resource $resourceIndex declares unsupported envelope '$envelope'."
        }
        $payloadFile = Get-ReviewerCorpusSealProperty -Object $resource -Name "payloadFile" -Type string -Where "Corpus seal resource $resourceIndex"
        if (-not (Test-ReviewerCorpusSealRelativePath -Path $payloadFile)) {
            throw "Corpus seal resource $resourceIndex declares payloadFile '$payloadFile', which is not a plain relative path."
        }
        if (-not $payloadFiles.Add($payloadFile)) {
            throw "Corpus seal recipe writes two resources to '$payloadFile'."
        }
        $corpusPayload = Get-ReviewerCorpusSealBoundPayload -Index $Index `
            -Declaration (Get-ReviewerCorpusSealProperty -Object $resource -Name "corpusPayload" -Type object `
                -Where "Corpus seal resource $resourceIndex") `
            -Where "Corpus seal resource $resourceIndex payload"
        $resourceUri = Get-ReviewerCorpusSealProperty -Object $resource -Name "resourceUri" -Type string -Where "Corpus seal resource $resourceIndex"
        $mimeType = Get-ReviewerCorpusSealProperty -Object $resource -Name "mimeType" -Type string -Where "Corpus seal resource $resourceIndex"
        if ($envelope -cne "mcpResourceContent" -and ($resourceUri -or $mimeType)) {
            throw "Corpus seal resource $resourceIndex declares a resourceUri/mimeType for a non-resource envelope."
        }
        $bytes = New-ReviewerCorpusSealEnvelope -Envelope $envelope -Payload $corpusPayload `
            -ResourceUri $resourceUri -MimeType $mimeType
        if ($bytes.Length -lt 2 -or $bytes.Length -gt $script:ReviewerCorpusSealMaxPayloadBytes) {
            throw "Corpus seal resource $resourceIndex sealed to $($bytes.Length) bytes; expected 2..$script:ReviewerCorpusSealMaxPayloadBytes."
        }
        $sha = Get-ReviewerCorpusSealSha256 -Bytes $bytes
        $expected = Get-ReviewerCorpusSealProperty -Object $resource -Name "expected" -Type object -Where "Corpus seal resource $resourceIndex"
        Assert-ReviewerCorpusSealExactKeys -Object $expected -Where "Corpus seal resource $resourceIndex expected" `
            -Expected @("payloadSha256", "payloadByteLength")
        $expectedSha = Get-ReviewerCorpusSealProperty -Object $expected -Name "payloadSha256" -Type sha256 `
            -Where "Corpus seal resource $resourceIndex expected"
        $expectedLength = [long](Get-ReviewerCorpusSealProperty -Object $expected -Name "payloadByteLength" -Type int `
                -Where "Corpus seal resource $resourceIndex expected" -Min 2 -Max $script:ReviewerCorpusSealMaxPayloadBytes)
        if ($sha -cne $expectedSha -or $bytes.Length -ne $expectedLength) {
            throw ("Corpus seal resource $resourceIndex seals to $sha/$($bytes.Length) byte(s) but the recipe declares " +
                "$expectedSha/$expectedLength; the recipe does not describe what this corpus produces.")
        }
        $key = Get-AgentReplayRequestKey -Name $tool -Arguments $arguments
        if (-not $requestKeys.Add($key.Key)) {
            throw "Corpus seal recipe records the same '$tool' request twice; a snapshot must answer each request one way."
        }
        $totalBytes += $bytes.Length
        if ($totalBytes -gt $script:ReviewerCorpusSealMaxTotalBytes) {
            throw "Corpus seal would carry more than $script:ReviewerCorpusSealMaxTotalBytes payload bytes."
        }
        [void]$plannedResources.Add([pscustomobject][ordered]@{
                tool = $tool
                arguments = $arguments
                requestSha256 = $key.Key
                payloadFile = $payloadFile
                payloadSha256 = $sha
                payloadByteLength = [long]$bytes.Length
                corpusPath = [string]$corpusPayload.Path
                corpusSha256 = [string]$corpusPayload.Sha256
                corpusByteLength = [long]$corpusPayload.ByteLength
                bytes = $bytes
            })
    }

    # -- every sealed right-hand payload is a RECORDED READ of that file ----
    # Binding the recipe's rightHand to the corpus index proves the bytes are
    # indexed; it does not prove they are this file's bytes at this commit. Any
    # indexed blob would satisfy that check, so a recipe could seal one path's
    # content under another path's name, or last week's content under this
    # iteration's commit, and every downstream digest would agree with itself.
    #
    # So the binding is DERIVED here rather than declared: for each sealed path
    # there must be exactly one recorded read whose own arguments name this
    # repository, this path and the source commit, and that read's corpus payload
    # must be byte-identical to the sealed right-hand payload. Nothing about that
    # correspondence comes from the recipe except the material it has to match.
    #
    # A read that CLAIMS to be a source-commit content read is then held to the
    # whole contract rather than the part of it that happened to be present. The
    # earlier revision skipped a read missing `versionType` and accepted any path
    # that merely normalized to the sealed one - so `//src/a.cs`, `/src/./a.cs`
    # and `\src\a.cs` all bound to `/src/a.cs`, and an unqualified read bound to a
    # commit it never named. Aliases are refused, not normalized: the recorded
    # argument has to be the canonical path itself.
    $sourceReadsByPath = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $resourceOrdinal = 0
    foreach ($resource in $plannedResources) {
        $resourceOrdinal++
        if ([string]$resource.tool -cne "repo_file") { continue }
        $arguments = $resource.arguments
        $argumentNames = @($arguments.PSObject.Properties.Name)
        # Only reads that claim this repository AND this source commit are
        # candidates. Everything else - common-commit reads, target-commit reads,
        # sibling evidence from other commits - is simply not a source read and is
        # left alone rather than judged against a contract it never asserted.
        if ($argumentNames -cnotcontains "version" -or $argumentNames -cnotcontains "repositoryId") { continue }
        if ([string]$arguments.version -cne $bound.sourceCommit) { continue }
        if ([string]$arguments.repositoryId -cne $bound.repositoryId) { continue }
        $where = "Corpus seal resource $resourceOrdinal records a source-commit repo_file read that"
        foreach ($required in @("action", "project", "versionType", "path")) {
            if ($argumentNames -cnotcontains $required) {
                throw "$where omits '$required'; a read that names the source commit must name it completely."
            }
        }
        if ([string]$arguments.action -cne "get_content") {
            throw "$where declares action '$([string]$arguments.action)', not 'get_content'."
        }
        if ([string]$arguments.versionType -cne "Commit") {
            throw ("$where declares versionType '$([string]$arguments.versionType)', not 'Commit'; a branch or tag " +
                "name is not a commit and does not pin the bytes it returned.")
        }
        if ([string]$arguments.project -cne $bound.project) {
            throw "$where names project '$([string]$arguments.project)', not the bound '$($bound.project)'."
        }
        if ($argumentNames -ccontains "organization" -and
            [string]$arguments.organization -cne $bound.organization) {
            throw ("$where names organization '$([string]$arguments.organization)', not the bound " +
                "'$($bound.organization)'.")
        }
        $rawReadPath = [string]$arguments.path
        $readPath = ConvertTo-ReviewerSourcePath -Path $rawReadPath
        if (-not $readPath -or $readPath -cne $rawReadPath) {
            throw ("$where names the path '$rawReadPath', which is not already the canonical repository path; a seal " +
                "binds recorded reads by their exact path, never by an alias of one.")
        }
        if ($sourceReadsByPath.ContainsKey($readPath)) {
            throw ("Corpus seal recipe records two source-commit reads of '$readPath'; a snapshot must answer that " +
                "read one way.")
        }
        $sourceReadsByPath[$readPath] = $resource
    }
    foreach ($path in @($rightHandByPath.Keys)) {
        if (-not $sourceReadsByPath.ContainsKey($path)) {
            throw ("Corpus seal seals right-hand content for '$path' but records no read of that path at source " +
                "commit $($bound.sourceCommit); sealed bytes must be bytes this capture actually read.")
        }
        $read = $sourceReadsByPath[$path]
        $sealedPayload = $rightHandByPath[$path]
        if ([string]$read.corpusPath -cne [string]$sealedPayload.Path -or
            [string]$read.corpusSha256 -cne [string]$sealedPayload.Sha256 -or
            [long]$read.corpusByteLength -ne [long]$sealedPayload.ByteLength) {
            throw ("Corpus seal binds '$path' to right-hand payload '$($sealedPayload.Path)', but the recorded read " +
                "of that path at the source commit returned '$($read.corpusPath)'; a seal cannot show one file's " +
                "bytes as another's.")
        }
    }

    # -- source transport ----------------------------------------------------
    # EVERY authoritative path goes through the report, not only the sealed ones.
    # A path the census excused still belongs in the transport's own denominator:
    # the report is what produces the coverage record and the gate, and handing it
    # a pre-filtered path list would let it certify complete coverage of a change
    # set it was never shown in full.
    $reportSpansByPath = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $reportKindsByPath = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($path in $authoritativePaths) {
        $reportSpansByPath[$path] = if ($spansByPath.Contains($path)) { @($spansByPath[$path]) } else { @() }
        $reportKindsByPath[$path] = [string[]]@(@($authoritativeKindsByPath[$path]) |
                ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive -Unique)
    }
    $sourcePlan = New-ReviewerCorpusSealSourceTransport -Index $Index -Recipe $Recipe -Binding $bound `
        -SpansByPath $reportSpansByPath -ChangeKindsByPath $reportKindsByPath -RightHandByPath $rightHandByPath `
        -AuthoritativePaths ([string[]]@($authoritativePaths)) -PolicySha256 $hashRecord.policySha256 `
        -ToolkitRoot $ToolkitRoot
    $totalBytes += $sourcePlan.Bytes.Length
    if ($totalBytes -gt $script:ReviewerCorpusSealMaxTotalBytes) {
        throw "Corpus seal would carry more than $script:ReviewerCorpusSealMaxTotalBytes payload bytes."
    }
    # Every name this seal will write, checked together. Individually valid names
    # can still be collectively impossible, and finding that out mid-write is how
    # a half-built snapshot ends up on disk.
    [void](Assert-ReviewerCorpusSealOutputPaths -RelativePaths ([string[]]@(
                @($plannedResources | ForEach-Object { [string]$_.payloadFile }) +
                @([string]$sourcePlan.ArtifactFile))))

    return @{
        SnapshotId = $snapshotId
        Provider = $provider
        CapturedUtc = $capturedUtc
        Binding = $bound
        Bindings = $bindingsRecord
        Hashes = $hashRecord
        Resources = @($plannedResources.ToArray())
        SourceTransport = $sourcePlan
        Evidence = $evidenceRecord
        Capture = [ordered]@{
            identityPath = $captureIdentity.Path
            identitySha256 = $captureIdentity.Sha256
            endIdentityPath = $captureEndIdentity.Path
            endIdentitySha256 = $captureEndIdentity.Sha256
            statusAtCapture = $statusAtCapture
            isDraft = $captureIsDraft
            mode = $captureMode
            livePostReadRaceCheck = "notPerformed"
        }
        Census = [ordered]@{
            authoritativeChangedPathCount = $authoritativePaths.Count
            rightHandCoveredPathCount = $rightHandByPath.Count
            noRightHandPaths = [string[]]@($noRightHandPaths)
            changeSetSha256 = $computedChangeDigest
            digestOrder = [string[]]@($authoritativePaths)
        }
        CorpusIndexSha256 = $Index.IndexSha256
        CorpusPayloadCount = $Index.PayloadCount
        TotalPayloadBytes = $totalBytes
    }
}

function Get-ReviewerCorpusSealPolicyPayload {
    <#
        Resolves the source-transport POLICY the seal derives under. Exactly two
        origins are admissible, and the recipe must name exactly one of them.

        `corpusPath` - the policy the capture itself recorded, as an indexed
        corpus payload. Always preferred: it is inside the index's integrity
        claim, it is immutable, and it is the policy the captured behaviour
        actually ran under.

        `toolkitPath` - a versioned policy from this toolkit's own
        `src/Agents/reviewer/source/` tree, for the case the requirement
        contemplates and every real corpus so far exhibits: the capture recorded
        the transport's OUTPUTS but never the policy document itself, so there is
        no indexed copy to name. Refusing that case outright does not make the
        seal more honest, it just makes it impossible; what makes it honest is
        binding the bytes and saying where they came from.

        So the toolkit route is fenced rather than trusted:

          - the path must be relative, forward-slashed, and lie strictly under
            `src/Agents/reviewer/source/` - not merely start with it, and with no
            '..', backslash, drive letter or absolute form anywhere;
          - the resolved real path must still be under that directory, and no
            component of it may be a reparse point, so a link cannot aim the
            policy somewhere else after the name was checked;
          - the recipe must independently declare the SHA-256 and byte length,
            both of which are verified against the bytes actually read;
          - `hashes.policySha256` must agree as well (checked by the caller), so
            the same digest is stated twice from two different places in the
            recipe;
          - the provenance recorded in the sidecar is `toolkitSealTime`, never
            flattened together with `corpus`, because a policy chosen at seal
            time is a materially weaker claim than one the capture recorded, and
            the artifact has to say which it is.

        This is still not a live seam: it is a hash-pinned read of a versioned
        file in this repository, with no host, process or network involved.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Index,
        [Parameter(Mandatory)]$Declaration,
        [Parameter(Mandatory)][string]$Where,
        [string]$ToolkitRoot
    )
    if ($Declaration -isnot [System.Management.Automation.PSCustomObject]) { throw "$Where must be an object." }
    $hasCorpus = [bool]$Declaration.PSObject.Properties["corpusPath"]
    $hasToolkit = [bool]$Declaration.PSObject.Properties["toolkitPath"]
    if ($hasCorpus -and $hasToolkit) {
        throw "$Where names both a corpus payload and a toolkit policy; a seal derives under exactly one policy."
    }
    if (-not $hasCorpus -and -not $hasToolkit) {
        throw "$Where must name the policy via 'corpusPath' (preferred) or 'toolkitPath'."
    }
    if ($hasCorpus) {
        $payload = Get-ReviewerCorpusSealBoundPayload -Index $Index -Declaration $Declaration -Where $Where
        return @{ Payload = $payload; Provenance = "corpus"; Reference = $payload.Path }
    }

    Assert-ReviewerCorpusSealExactKeys -Object $Declaration -Where $Where -Expected @("toolkitPath", "sha256", "byteLength")
    $relative = Get-ReviewerCorpusSealProperty -Object $Declaration -Name "toolkitPath" -Type string -Where $Where
    if (-not (Test-ReviewerCorpusSealRelativePath -Path $relative)) {
        throw ("$Where declares toolkitPath '$relative', which is not a plain relative forward-slashed path. " +
            "Every alias spelling is refused rather than normalized.")
    }
    if (-not $relative.StartsWith($script:ReviewerCorpusSealToolkitPolicyRoot + "/", [StringComparison]::Ordinal)) {
        throw ("$Where declares toolkitPath '$relative'; a toolkit policy must live strictly under " +
            "'$script:ReviewerCorpusSealToolkitPolicyRoot/'.")
    }
    if (-not $ToolkitRoot) {
        throw ("$Where names a toolkit policy, but no toolkit root was supplied to resolve it against. " +
            "A toolkit policy is only readable when the sealer knows which checkout it is reading.")
    }
    $policyRootReal = Resolve-ReviewerCorpusSealRealPath -RejectReparsePoints -Path (
        Join-Path $ToolkitRoot ($script:ReviewerCorpusSealToolkitPolicyRoot -replace '/', [System.IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $policyRootReal -PathType Container)) {
        throw "$Where names a toolkit policy, but '$policyRootReal' is not a directory in this checkout."
    }
    $candidate = $policyRootReal
    foreach ($segment in @($relative.Substring($script:ReviewerCorpusSealToolkitPolicyRoot.Length + 1) -split '/')) {
        $candidate = Join-Path $candidate $segment
    }
    $real = Resolve-ReviewerCorpusSealRealPath -Path $candidate -RejectReparsePoints
    if (-not (Test-ReviewerCorpusSealPathWithin -Path $real -Boundary $policyRootReal)) {
        throw ("$Where resolves toolkitPath '$relative' to '$real', which escapes " +
            "'$policyRootReal'; a toolkit policy is confined to the versioned policy tree.")
    }
    if (-not (Test-Path -LiteralPath $real -PathType Leaf)) {
        throw "$Where declares toolkitPath '$relative', which is not a file in this checkout."
    }
    $bytes = [System.IO.File]::ReadAllBytes($real)
    $declaredSha = Get-ReviewerCorpusSealProperty -Object $Declaration -Name "sha256" -Type sha256 -Where $Where
    $declaredLength = [long](Get-ReviewerCorpusSealProperty -Object $Declaration -Name "byteLength" -Type int `
            -Where $Where -Min 2 -Max $script:ReviewerCorpusSealMaxPayloadBytes)
    $actualSha = Get-ReviewerCorpusSealSha256 -Bytes $bytes
    if ($actualSha -cne $declaredSha -or $bytes.Length -ne $declaredLength) {
        throw ("$Where binds toolkit policy '$relative' to $declaredSha/$declaredLength byte(s), but this checkout " +
            "carries $actualSha/$($bytes.Length). A seal derives only under the exact policy bytes it declares.")
    }
    return @{
        Payload = @{ Path = $relative; Sha256 = $actualSha; ByteLength = [long]$bytes.Length; Bytes = $bytes }
        Provenance = "toolkitSealTime"
        Reference = $relative
    }
}

function New-ReviewerCorpusSealSourceTransport {
    <#
        Produces the canonical source-transport replay artifact this snapshot
        seals, either by adopting one the corpus already captured or by deriving
        one offline from captured right-hand content.

        Derivation is not invention. It runs the reviewer's OWN transport report,
        coverage record, gate and sealed-block renderer over the exact captured
        bytes, with a reader that can only return indexed corpus payloads. The
        recipe then has to state the artifact's digest, byte length, block digest,
        gate outcome and coverage digest independently, and a disagreement is a
        refusal.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Index,
        [Parameter(Mandatory)]$Recipe,
        [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)]$SpansByPath,
        [Parameter(Mandatory)]$ChangeKindsByPath,
        [Parameter(Mandatory)]$RightHandByPath,
        [Parameter(Mandatory)][string[]]$AuthoritativePaths,
        [Parameter(Mandatory)][string]$PolicySha256,
        [string]$ToolkitRoot
    )
    $source = Get-ReviewerCorpusSealProperty -Object $Recipe -Name "sourceTransport" -Type object -Where "Corpus seal recipe"
    Assert-ReviewerCorpusSealExactKeys -Object $source -Where "Corpus seal recipe sourceTransport" -Expected @(
        "kind", "mode", "artifactFile", "policy", "blockNonce", "capturedArtifact", "expected"
    )
    $kind = Get-ReviewerCorpusSealProperty -Object $source -Name "kind" -Type string -Where "Corpus seal recipe sourceTransport"
    if ($script:ReviewerCorpusSealSourceKinds -cnotcontains $kind) {
        throw "Corpus seal source transport kind '$kind' is unsupported."
    }
    $mode = Get-ReviewerCorpusSealProperty -Object $source -Name "mode" -Type string -Where "Corpus seal recipe sourceTransport"
    if ($script:ReviewerCorpusSealTransportModes -cnotcontains $mode) {
        throw "Corpus seal source transport mode '$mode' is unsupported."
    }
    $artifactFile = Get-ReviewerCorpusSealProperty -Object $source -Name "artifactFile" -Type string -Where "Corpus seal recipe sourceTransport"
    if (-not (Test-ReviewerCorpusSealRelativePath -Path $artifactFile)) {
        throw "Corpus seal source transport artifactFile '$artifactFile' is not a plain relative path."
    }
    $expected = Get-ReviewerCorpusSealProperty -Object $source -Name "expected" -Type object -Where "Corpus seal recipe sourceTransport"
    Assert-ReviewerCorpusSealExactKeys -Object $expected -Where "Corpus seal recipe sourceTransport expected" -Expected @(
        "artifactSha256", "artifactByteLength", "blockSha256", "coverageRecordSha256", "gateOk", "gateReasonCodes"
    )
    $replayBinding = [ordered]@{
        organization = [string]$Binding.organization
        project = [string]$Binding.project
        repositoryId = [string]$Binding.repositoryId
        pullRequestId = [int]$Binding.pullRequestId
        iterationId = [int]$Binding.iterationId
        commonCommit = [string]$Binding.commonCommit
        sourceCommit = [string]$Binding.sourceCommit
        targetCommit = [string]$Binding.targetCommit
        changeSetSha256 = [string]$Binding.changeSetSha256
    }

    # The policy is a corpus payload in BOTH shapes. A captured artifact that is
    # only checked against itself proves nothing about the rules it was produced
    # under, so the seal re-derives the coverage record, the gate and the rendered
    # block from the report using the same policy bytes either way.
    $policyDeclaration = Get-ReviewerCorpusSealProperty -Object $source -Name "policy" -Type object -Where "Corpus seal recipe sourceTransport"
    $policyResolved = Get-ReviewerCorpusSealPolicyPayload -Index $Index -Declaration $policyDeclaration `
        -Where "Corpus seal source-transport policy" -ToolkitRoot $ToolkitRoot
    $policyPayload = $policyResolved.Payload
    if ($policyPayload.Sha256 -cne $PolicySha256) {
        throw "The sealed source-transport policy does not hash to the recipe's declared policySha256."
    }
    $policyJson = $script:ReviewerCorpusSealUtf8.GetString($policyPayload.Bytes) | ConvertFrom-Json -Depth 32
    # The reviewer's own loader drops the documentation key before validating, so
    # the seal has to as well; otherwise a byte-identical policy file would be
    # accepted in production and refused here.
    $policyProperties = [ordered]@{}
    foreach ($property in $policyJson.PSObject.Properties) {
        if ($property.Name -ceq "_note") { continue }
        $policyProperties[$property.Name] = $property.Value
    }
    $policy = New-ReviewerSourceTransportPolicy -Policy ([pscustomobject]$policyProperties)

    if ($kind -ceq "capturedArtifact") {
        $captured = Get-ReviewerCorpusSealProperty -Object $source -Name "capturedArtifact" -Type object -Where "Corpus seal recipe sourceTransport"
        $payload = Get-ReviewerCorpusSealBoundPayload -Index $Index -Declaration $captured -Where "Corpus seal captured source-transport artifact"
        $artifactBytes = $payload.Bytes
        # The production importer is the authority here. It re-derives the
        # coverage record, the gate and the block from the report and refuses any
        # divergence, so adopting a captured artifact is held to exactly the
        # standard a replayed one is.
        $imported = Import-ReviewerSourceTransportReplayArtifact -Bytes $artifactBytes -Policy $policy `
            -PolicySha256 $PolicySha256 -ExpectedBinding $replayBinding
        if ([string]$imported.Mode -cne $mode) {
            throw "The captured source-transport artifact records mode '$($imported.Mode)'; the recipe declares '$mode'."
        }
        $blockText = [string]$imported.BlockText
        $coverageRecord = $imported.Record
        $gate = [ordered]@{ ok = [bool]$imported.Gate.Ok; reasonCodes = [string[]]@($imported.Gate.ReasonCodes) }
    }
    else {
        $blockNonce = Get-ReviewerCorpusSealProperty -Object $source -Name "blockNonce" -Type string `
            -Where "Corpus seal recipe sourceTransport" -Pattern '^[A-Z0-9]{8,128}\z'
        # The reader can ONLY return indexed corpus bytes for a path this recipe
        # sealed. There is no fallback branch: a path the corpus does not carry
        # reads as unreadable, which lands in the coverage accounting as an
        # uncovered file rather than as a silent live fetch.
        $rightHand = $RightHandByPath
        $reader = {
            param([string]$path)
            if (-not $rightHand.ContainsKey($path)) { return $null }
            $entry = $rightHand[$path]
            $text = ([System.Text.UTF8Encoding]::new($false, $true)).GetString($entry.Bytes)
            return [pscustomobject]@{
                Text = $text
                ByteLength = [int]$entry.ByteLength
                Sha256 = [string]$entry.Sha256
                MimeType = "text/plain"
            }
        }.GetNewClosure()
        $changedPaths = [string[]]@($AuthoritativePaths)
        $report = New-ReviewerSourceTransportReport -CommitSha ([string]$Binding.sourceCommit) `
            -ChangedPaths $changedPaths -SpansByPath $SpansByPath -Policy $policy -Reader $reader `
            -ChangeKindsByPath $ChangeKindsByPath `
            -RecoveryBaseCommit ([string]$Binding.commonCommit) `
            -RecoveryIterationId ([int]$Binding.iterationId)
        $blockText = Format-ReviewerSealedSourceBlock -Report $report -NonceFactory { $blockNonce }.GetNewClosure()
        $artifactBytes = New-ReviewerSourceTransportReplayArtifact -Report $report -BlockText $blockText `
            -Policy $policy -PolicySha256 $PolicySha256 -Mode $mode -Binding $replayBinding
        $artifact = ($script:ReviewerCorpusSealUtf8.GetString($artifactBytes) | ConvertFrom-Json -AsHashtable -Depth 64)
        $coverageRecord = $artifact.coverageRecord
        $gate = $artifact.gate
    }

    # -- the recipe's independent claims about the artifact -----------------
    $artifactSha = Get-ReviewerCorpusSealSha256 -Bytes $artifactBytes
    $expectedArtifactSha = Get-ReviewerCorpusSealProperty -Object $expected -Name "artifactSha256" -Type sha256 `
        -Where "Corpus seal recipe sourceTransport expected"
    $expectedArtifactLength = [long](Get-ReviewerCorpusSealProperty -Object $expected -Name "artifactByteLength" -Type int `
            -Where "Corpus seal recipe sourceTransport expected" -Min 2 -Max 16777216)
    if ($artifactSha -cne $expectedArtifactSha -or $artifactBytes.Length -ne $expectedArtifactLength) {
        throw ("The sealed source-transport artifact is $artifactSha/$($artifactBytes.Length) byte(s); the recipe declares " +
            "$expectedArtifactSha/$expectedArtifactLength.")
    }
    $blockSha = Get-ReviewerSourceSha256 -Text $blockText
    if ($blockSha -cne (Get-ReviewerCorpusSealProperty -Object $expected -Name "blockSha256" -Type sha256 `
                -Where "Corpus seal recipe sourceTransport expected")) {
        throw "The rendered sealed source block does not hash to the recipe's declared blockSha256."
    }
    $coverageSha = Get-ReviewerSourceSha256 -Text (Get-ReviewerSourceReplayCanonicalJson -Value $coverageRecord)
    if ($coverageSha -cne (Get-ReviewerCorpusSealProperty -Object $expected -Name "coverageRecordSha256" -Type sha256 `
                -Where "Corpus seal recipe sourceTransport expected")) {
        throw "The source-transport coverage record does not hash to the recipe's declared coverageRecordSha256."
    }
    $gateOk = [bool](Get-ReviewerCorpusSealProperty -Object $expected -Name "gateOk" -Type bool `
            -Where "Corpus seal recipe sourceTransport expected")
    if ([bool]$gate.ok -ne $gateOk) {
        throw "The reconstructed source-coverage gate says ok=$([bool]$gate.ok); the recipe declares ok=$gateOk."
    }
    $expectedReasons = [string[]]@(Get-ReviewerCorpusSealProperty -Object $expected -Name "gateReasonCodes" -Type array `
            -Where "Corpus seal recipe sourceTransport expected" | ForEach-Object { [string]$_ })
    $actualReasons = [string[]]@(@($gate.reasonCodes) | ForEach-Object { [string]$_ })
    if (($expectedReasons -join "`n") -cne ($actualReasons -join "`n")) {
        throw "The reconstructed source-coverage gate reason codes differ from the recipe's declared codes."
    }
    return @{
        Mode = $mode
        Kind = $kind
        ArtifactFile = $artifactFile
        Bytes = $artifactBytes
        Sha256 = $artifactSha
        ByteLength = [long]$artifactBytes.Length
        BlockSha256 = $blockSha
        CoverageRecordSha256 = $coverageSha
        GateOk = [bool]$gate.ok
        GateReasonCodes = $actualReasons
        PolicyProvenance = [string]$policyResolved.Provenance
        PolicyReference = [string]$policyResolved.Reference
    }
}

function Save-ReviewerCorpusSeal {
    <#
        Writes the validated plan as a schema-v2 replay snapshot plus its
        non-promotability sidecar, then LOADS what it just wrote with the
        production loader and the digest it computed. A sealer that emits a
        snapshot the loader would refuse is worse than one that refuses to emit.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][string]$ReplayRoot,
        [switch]$Force
    )
    # First of two checks. A caller that reached this function directly - without
    # the CLI's containment guard - still cannot be talked into writing through a
    # link, because the guard is here rather than only there.
    $rootFull = Assert-ReviewerCorpusSealReplayRoot -ReplayRoot $ReplayRoot -Stage "staging"
    $publishFull = Join-Path $rootFull $Plan.SnapshotId
    $exists = Test-Path -LiteralPath $publishFull
    if ($exists -and -not $Force) {
        throw "Snapshot '$($Plan.SnapshotId)' already exists under '$rootFull'; pass -Force to replace it."
    }
    # Everything is built in a staging root and only becomes the published
    # snapshot after the production loader has accepted it. Writing in place
    # would mean any failure - a bad byte, a refused manifest, a full disk -
    # leaves a partial snapshot where a valid one used to be, and under -Force
    # it would already have destroyed the previous one to get there.
    $stamp = [System.Guid]::NewGuid().ToString("n").Substring(0, 12)
    $stagingRoot = Join-Path $rootFull ".corpus-seal-staging-$stamp"
    $retiredPath = Join-Path $rootFull ".corpus-seal-retired-$stamp"
    $snapshotFull = Join-Path $stagingRoot $Plan.SnapshotId
    $published = $false
    $retired = $false
    try {
        New-Item -ItemType Directory -Force -Path $snapshotFull | Out-Null
        # The staging tree exists now, so it is re-checked as a real location
        # rather than assumed from the root check a moment ago.
        $stagingReal = Assert-ReviewerCorpusSealWriteTarget -Path $stagingRoot -Boundary $rootFull -Stage "staging root"
        [void](Assert-ReviewerCorpusSealWriteTarget -Path $snapshotFull -Boundary $stagingReal -Stage "staging snapshot")
        $verifiedParents = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

        $resources = [System.Collections.Generic.List[object]]::new()
        $digestResources = [System.Collections.Generic.List[object]]::new()
        foreach ($resource in $Plan.Resources) {
            $relative = [string]$resource.payloadFile
            $target = $snapshotFull
            $segments = @($relative -split '/')
            for ($i = 0; $i -lt $segments.Count; $i++) {
                $target = Join-Path $target $segments[$i]
                if ($i -lt ($segments.Count - 1)) {
                    New-Item -ItemType Directory -Force -Path $target | Out-Null
                    if ($verifiedParents.Add($target)) {
                        [void](Assert-ReviewerCorpusSealWriteTarget -Path $target -Boundary $snapshotFull `
                                -Stage "payload directory")
                    }
                }
            }
            [void](Assert-ReviewerCorpusSealWriteTarget -Path (Split-Path -Parent $target) -Boundary $snapshotFull `
                    -Stage "payload parent")
            [System.IO.File]::WriteAllBytes($target, $resource.bytes)
            $entry = [ordered]@{
                tool = [string]$resource.tool
                arguments = $resource.arguments
                requestSha256 = [string]$resource.requestSha256
                payloadFile = $relative
                payloadSha256 = [string]$resource.payloadSha256
                payloadByteLength = [long]$resource.payloadByteLength
            }
            [void]$resources.Add($entry)
            [void]$digestResources.Add([ordered]@{
                    tool = $entry.tool
                    requestSha256 = $entry.requestSha256
                    payloadFile = $entry.payloadFile
                    payloadSha256 = $entry.payloadSha256
                    payloadByteLength = $entry.payloadByteLength
                    arguments = $entry.arguments
                })
        }
        $artifactPath = $snapshotFull
        $artifactSegments = @([string]$Plan.SourceTransport.ArtifactFile -split '/')
        for ($i = 0; $i -lt $artifactSegments.Count; $i++) {
            $artifactPath = Join-Path $artifactPath $artifactSegments[$i]
            if ($i -lt ($artifactSegments.Count - 1)) {
                New-Item -ItemType Directory -Force -Path $artifactPath | Out-Null
                if ($verifiedParents.Add($artifactPath)) {
                    [void](Assert-ReviewerCorpusSealWriteTarget -Path $artifactPath -Boundary $snapshotFull `
                            -Stage "artifact directory")
                }
            }
        }
        [void](Assert-ReviewerCorpusSealWriteTarget -Path (Split-Path -Parent $artifactPath) -Boundary $snapshotFull `
                -Stage "artifact parent")
        [System.IO.File]::WriteAllBytes($artifactPath, $Plan.SourceTransport.Bytes)

        $binding = [ordered]@{
            organization = [string]$Plan.Binding.organization
            project = [string]$Plan.Binding.project
            repositoryId = [string]$Plan.Binding.repositoryId
            pullRequestId = [int]$Plan.Binding.pullRequestId
            sourceCommit = [string]$Plan.Binding.sourceCommit
            targetCommit = [string]$Plan.Binding.targetCommit
            changeSetSha256 = [string]$Plan.Binding.changeSetSha256
            iterationId = [int]$Plan.Binding.iterationId
            commonCommit = [string]$Plan.Binding.commonCommit
        }
        $bindings = [ordered]@{
            configSha256 = [string]$Plan.Bindings.configSha256
            scriptSha256 = [string]$Plan.Bindings.scriptSha256
            promptSha256 = [string]$Plan.Bindings.promptSha256
            models = @($Plan.Bindings.models)
        }
        $sourceTransport = [ordered]@{
            mode = [string]$Plan.SourceTransport.Mode
            artifactFile = [string]$Plan.SourceTransport.ArtifactFile
            artifactSha256 = [string]$Plan.SourceTransport.Sha256
            artifactByteLength = [long]$Plan.SourceTransport.ByteLength
        }

        # The non-promotability sidecar is written BEFORE the manifest, because
        # the manifest pins the sidecar's SHA-256 and the digest pins the
        # manifest. That direction is the whole point: the label cannot be shed
        # by deleting or editing the sidecar, since either breaks the load, and
        # the manifest cannot be quietly corrected, since that breaks the
        # digest. The sidecar therefore does NOT carry the manifest digest -
        # binding both ways would be a cycle neither side could compute.
        $policyProvenance = [string]$Plan.SourceTransport.PolicyProvenance
        if ($script:ReviewerCorpusSealPolicyProvenances -cnotcontains $policyProvenance) {
            throw "The seal plan carries policy provenance '$policyProvenance', which this build does not recognize."
        }
        $seal = [ordered]@{
            schemaVersion = $script:ReviewerCorpusSealSchemaVersion
            kind = $script:ReviewerCorpusSealKind
            sealKind = $script:ReviewerCorpusSealClassification
            snapshotId = [string]$Plan.SnapshotId
            nonPromotable = $true
            promotionKeyDomain = $null
            liveSeamCount = 0
            liveHostContacted = $false
            modelRequired = $false
            livePostReadRaceCheck = "notPerformed"
            corpus = [ordered]@{
                indexSha256 = [string]$Plan.CorpusIndexSha256
                payloadCount = [int]$Plan.CorpusPayloadCount
            }
            capture = $Plan.Capture
            census = $Plan.Census
            sourceTransport = [ordered]@{
                kind = [string]$Plan.SourceTransport.Kind
                mode = [string]$Plan.SourceTransport.Mode
                artifactSha256 = [string]$Plan.SourceTransport.Sha256
                artifactByteLength = [long]$Plan.SourceTransport.ByteLength
                blockSha256 = [string]$Plan.SourceTransport.BlockSha256
                coverageRecordSha256 = [string]$Plan.SourceTransport.CoverageRecordSha256
                gateOk = [bool]$Plan.SourceTransport.GateOk
                gateReasonCodes = [string[]]@($Plan.SourceTransport.GateReasonCodes)
                policyProvenance = $policyProvenance
                policyReference = [string]$Plan.SourceTransport.PolicyReference
            }
            evidence = [ordered]@{
                siblings = [string[]]@($Plan.Evidence.siblings | ForEach-Object { [string]$_.Path })
                rules = [string[]]@($Plan.Evidence.rules | ForEach-Object { [string]$_.Path })
                threads = [string[]]@($Plan.Evidence.threads | ForEach-Object { [string]$_.Path })
                facts = [string[]]@($Plan.Evidence.facts | ForEach-Object { [string]$_.Path })
            }
            hashes = $Plan.Hashes
            statement = ("This snapshot was sealed offline from an immutable captured corpus. It contacted no live host, " +
                "performed no post-read race check, and is permanently non-promotable research evidence.")
        }
        $sealDigest = Get-ReviewerCorpusSealTextSha256 -Text (ConvertTo-AgentReplayCanonicalJson -Value $seal)
        $sealed = [ordered]@{}
        foreach ($key in $seal.Keys) { $sealed[$key] = $seal[$key] }
        $sealed["sealDigest"] = $sealDigest
        $sidecarBytes = $script:ReviewerCorpusSealUtf8.GetBytes((ConvertTo-AgentReplayCanonicalJson -Value $sealed))
        [void](Assert-ReviewerCorpusSealWriteTarget -Path $snapshotFull -Boundary $stagingReal -Stage "sidecar parent")
        [System.IO.File]::WriteAllBytes((Join-Path $snapshotFull $script:ReviewerCorpusSealSidecarFile), $sidecarBytes)
        $classification = [ordered]@{
            sealKind = $script:ReviewerCorpusSealClassification
            nonPromotable = $true
            sidecarFile = $script:ReviewerCorpusSealSidecarFile
            sidecarSha256 = Get-ReviewerCorpusSealSha256 -Bytes $sidecarBytes
        }

        $digestInput = [ordered]@{
            schemaVersion = $script:ReviewerCorpusSealSnapshotSchemaVersion
            kind = "agent-replay-snapshot"
            snapshotId = [string]$Plan.SnapshotId
            capturedUtc = [string]$Plan.CapturedUtc
            provider = [string]$Plan.Provider
            binding = $binding
            bindings = $bindings
            resources = @($digestResources.ToArray())
            sourceTransport = $sourceTransport
            classification = $classification
        }
        $digest = Get-ReviewerCorpusSealTextSha256 -Text (ConvertTo-AgentReplayCanonicalJson -Value $digestInput)
        $manifest = [ordered]@{
            schemaVersion = $script:ReviewerCorpusSealSnapshotSchemaVersion
            kind = "agent-replay-snapshot"
            snapshotId = [string]$Plan.SnapshotId
            capturedUtc = [string]$Plan.CapturedUtc
            provider = [string]$Plan.Provider
            binding = $binding
            bindings = $bindings
            resources = @($resources.ToArray())
            sourceTransport = $sourceTransport
            classification = $classification
            manifestDigest = $digest
        }
        [void](Assert-ReviewerCorpusSealWriteTarget -Path $snapshotFull -Boundary $stagingReal -Stage "manifest parent")
        [System.IO.File]::WriteAllBytes((Join-Path $snapshotFull $script:ReviewerCorpusSealManifestFile),
            $script:ReviewerCorpusSealUtf8.GetBytes(($manifest | ConvertTo-Json -Depth 20)))

        # Load what was just written, from staging, with the production loader.
        # A sealer that emits a snapshot the loader would refuse is worse than
        # one that refuses to emit, and doing it before publication means the
        # refusal costs nothing that was already on disk.
        $verified = New-AgentReplaySnapshot -ReplayRoot $stagingRoot -SnapshotName $Plan.SnapshotId `
            -ExpectedManifestDigest $digest
        if (-not $verified.Classification.NonPromotable -or
            [string]$verified.Classification.SealKind -cne $script:ReviewerCorpusSealClassification) {
            throw ("The sealed snapshot loaded without the '$script:ReviewerCorpusSealClassification' " +
                "non-promotable classification; refusing to publish it.")
        }

        # Publication is two renames on one volume and nothing else. Any earlier
        # snapshot is moved aside rather than deleted, so a failure at the last
        # step still ends with the original in place.
        #
        # Second of two checks, deliberately as late as it can be: everything is
        # already built and loader-verified, so what remains between here and the
        # rename is as small as this runtime allows.
        $rootAtPublish = Assert-ReviewerCorpusSealReplayRoot -ReplayRoot $ReplayRoot -Stage "publication"
        if ($rootAtPublish -cne $rootFull) {
            throw "The replay root changed from '$rootFull' to '$rootAtPublish' while the seal was being built."
        }
        # Both ends of both renames, immediately before they happen: the staging
        # snapshot is still where it was built, the publication parent is still
        # the real replay root, and neither has acquired a link along the way.
        [void](Assert-ReviewerCorpusSealWriteTarget -Path $stagingRoot -Boundary $rootFull -Stage "publication staging root")
        [void](Assert-ReviewerCorpusSealWriteTarget -Path $snapshotFull -Boundary $stagingReal -Stage "publication source")
        if ($exists) {
            [void](Assert-ReviewerCorpusSealWriteTarget -Path $publishFull -Boundary $rootFull -Stage "publication target")
            [System.IO.Directory]::Move($publishFull, $retiredPath)
            $retired = $true
        }
        [System.IO.Directory]::Move($snapshotFull, $publishFull)
        $published = $true

        return [pscustomobject][ordered]@{
            SnapshotId = [string]$Plan.SnapshotId
            SnapshotPath = $publishFull
            ManifestDigest = $digest
            SealDigest = $sealDigest
            SchemaVersion = [int]$verified.SchemaVersion
            ResourceCount = [int]$verified.ResourceCount
            PayloadBytes = [long]$verified.PayloadBytes
            SourceTransportMode = [string]$Plan.SourceTransport.Mode
            NonPromotable = $true
            SealKind = $script:ReviewerCorpusSealClassification
        }
    }
    finally {
        if ($retired -and -not $published -and (Test-Path -LiteralPath $retiredPath)) {
            # -Force replaces a snapshot only on success. On any failure the one
            # that was already there goes back exactly as it was.
            [System.IO.Directory]::Move($retiredPath, $publishFull)
            $retired = $false
        }
        $scratchPaths = @($stagingRoot)
        if ($retired) { $scratchPaths += $retiredPath }
        foreach ($scratch in $scratchPaths) {
            # Never `Remove-Item -Recurse` here: it follows junctions, and this is
            # the one path that runs even when the build failed, which is exactly
            # when a hostile link is most likely to still be sitting in staging.
            try { Remove-ReviewerCorpusSealScratch -Path $scratch } catch { }
        }
    }
}
