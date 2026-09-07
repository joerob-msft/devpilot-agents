#requires -Version 7.0

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

$script:ReviewerConventionSpecialistMarkerPrefix = "CONVENTION_REVIEW_RESULT_V2:"
# Version 3 gets its OWN prefix rather than a version field inside a shared one.
# A reader that has to parse a payload before it can tell which contract the
# payload is written against has already trusted it; the prefix decides first,
# so a v2 transcript sealed months ago is still read by the v2 rules and can
# never be silently re-interpreted under v3.
$script:ReviewerConventionSpecialistMarkerPrefixV3 = "CONVENTION_REVIEW_RESULT_V3:"
# Version 4 reduces the model to a per-construct verdict matrix. It gets its own
# prefix for the same reason version 3 did: the reader must know which contract
# it is reading before it parses anything.
$script:ReviewerConventionSpecialistMarkerPrefixV4 = "CONVENTION_REVIEW_RESULT_V4:"
$script:ReviewerConventionSpecialistContractVersion = 4

# One table, so a version can never be known to one lookup and unknown to
# another. Ordered highest-first: the ambiguity check below walks it directly.
#
# The keys are STRINGS. An ordered dictionary indexed with an integer treats it
# as a POSITION, not a key, so `$map[3]` would silently return the third entry
# rather than version 3 - and version 2 would appear to work by pure coincidence
# of its position in the table.
$script:ReviewerConventionSpecialistMarkerPrefixesByVersion = [ordered]@{
    '4' = $script:ReviewerConventionSpecialistMarkerPrefixV4
    '3' = $script:ReviewerConventionSpecialistMarkerPrefixV3
    '2' = $script:ReviewerConventionSpecialistMarkerPrefix
}

function Get-ReviewerConventionSpecialistContractVersionFromText {
    <#
        Which contract a SEALED marker was written against, decided by the
        prefix it actually carries.

        An artifact sealed months ago must be read by the rules it was written
        against, not by whatever this build happens to produce today. Guessing
        the current version would make an old, valid transcript look malformed;
        guessing the old one would make a new transcript unreadable. The prefix
        is the only thing that knows, so it decides.

        AMBIGUITY IS A REFUSAL, NOT A PREFERENCE. The scan is a substring search
        over the whole response, so a marker whose prose quotes another
        contract's prefix carries two of them. Picking the higher one would let
        a payload written against one contract be read under another's rules -
        the precise failure the per-version prefix exists to prevent. Two
        distinct known prefixes therefore yield 0, which every caller must treat
        as unreadable rather than as a version.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $found = [System.Collections.Generic.List[int]]::new()
    foreach ($entry in $script:ReviewerConventionSpecialistMarkerPrefixesByVersion.GetEnumerator()) {
        if ($Text.IndexOf([string]$entry.Value, [System.StringComparison]::Ordinal) -ge 0) {
            [void]$found.Add([int]$entry.Key)
        }
    }
    # A v2 prefix is a proper substring of nothing else here - the version digit
    # differs - so each hit is independent and two hits really are two claims.
    if ($found.Count -gt 1) { return 0 }
    if ($found.Count -eq 1) { return $found[0] }
    # No prefix at all still reads as the frozen v2 contract, which is what every
    # pre-versioning sealed artifact on disk was written against.
    return 2
}

function Get-ReviewerConventionSpecialistMarkerPrefixForVersion {
    <#
        Exact per-version lookup, never `-ge`. An open-ended comparison quietly
        hands a newer contract the previous contract's prefix, which is a
        mismatch that no later validation can see: the payload would be scanned
        for, and sealed under, a marker it was not written against.
    #>
    param([ValidateSet(2, 3, 4)][int]$ContractVersion = 2)
    $key = [string]$ContractVersion
    if (-not $script:ReviewerConventionSpecialistMarkerPrefixesByVersion.Contains($key)) {
        throw "Convention specialist contract version '$ContractVersion' has no marker prefix."
    }
    return [string]$script:ReviewerConventionSpecialistMarkerPrefixesByVersion[$key]
}

function Get-ReviewerConventionSpecialistPromptFileName {
    <#
        Which prompt file a contract version is reviewed with.

        Version 4 gets its OWN file rather than an edit of the version 3 prompt.
        `promptSha256` is a binding, so editing the live prompt moves a digest
        that sealed transcripts, corpus seals and the exact-path oracle all
        retain - every one of them would need rebaselining to say the same thing
        it already said. A new file leaves the version 3 digest exactly where it
        is, which is what lets an artifact sealed under version 3 still verify.
    #>
    param([ValidateSet(2, 3, 4)][int]$ContractVersion = 2)
    if ($ContractVersion -eq 4) { return "convention-review.v4.prompt.md" }
    return "convention-review.prompt.md"
}

function Get-ReviewerConventionSpecialistPromptPath {
    param(
        [Parameter(Mandatory)][string]$AgentDirectory,
        [ValidateSet(2, 3, 4)][int]$ContractVersion = 2
    )
    $path = Join-Path $AgentDirectory (Get-ReviewerConventionSpecialistPromptFileName -ContractVersion $ContractVersion)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Convention-specialist prompt '$path' does not exist."
    }
    return $path
}

function Resolve-ReviewerConventionSpecialistSealedContractVersion {
    <#
        The contract version of a sealed marker, for callers that must have one.

        `Get-...ContractVersionFromText` answers 0 when the text claims two
        contracts at once. That is deliberately not a version, and it must not be
        handed to a `ValidateSet` parameter, where it would surface as a generic
        argument-validation error that says nothing about what was actually
        wrong with the artifact. This turns it into the diagnostic a reader needs.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $version = Get-ReviewerConventionSpecialistContractVersionFromText -Text $Text
    if ($version -le 0) {
        throw ("The sealed specialist marker carries more than one convention result-marker " +
            "prefix, so the contract it was written against is ambiguous and it cannot be read.")
    }
    return [int]$version
}
$script:ReviewerConventionSpecialistArtifactKind = "convention-specialist-preview"
$script:ReviewerConventionSpecialistArtifactVersion = 2
$script:ReviewerConventionSpecialistMaxCandidates = 8
# The accounting shares the result marker's brace-scan window with the
# candidate array, so it is bounded on BOTH axes: at most this many rows, each
# with tightly bounded fields. A transported set larger than this is not
# silently sampled - the request states the cap and the reconciliation reports
# the remainder as unaccounted by construction.
$script:ReviewerConventionSpecialistMaxRuleCoverage = 10
$script:ReviewerConventionSpecialistMaxCoverageAnchors = 200
$script:ReviewerConventionSpecialistMaxInputBytes = 327680

# --- Version 4 bounds -------------------------------------------------------
#
# A v4 row answers for EVERY in-scope construct, so the row length is set by the
# construct enumerator's own cap rather than by anything the model chooses.
# `ReviewerConstructMaxTotal` is 120, so a row can always cover the largest set
# the wrapper is capable of enumerating; a row can never be asked for more.
$script:ReviewerConventionSpecialistMaxConstructAssessments = 120
# Rationale and suggestion are explanatory, never eligibility-critical, so the
# tail of a very large violation set loses its prose rather than its verdicts.
# Eight is the old candidate cap: the number of distinct findings this pass was
# ever able to render prose for anyway.
$script:ReviewerConventionSpecialistMaxProseAssessments = 8
$script:ReviewerConventionSpecialistMaxRationaleLength = 200
$script:ReviewerConventionSpecialistMaxSuggestionLength = 240
$script:ReviewerConventionSpecialistConstructRefPattern = '^(mi|dc|cm|as)[0-9]{1,3}$'
$script:ReviewerConventionSpecialistVerdicts = @("violation", "compliant", "unknown")

$script:ReviewerConventionSpecialistUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

function ConvertTo-ReviewerConventionSpecialistCanonicalPath {
    param([AllowEmptyString()][string]$Path = "")
    if (-not (Get-Command ConvertTo-ReviewerSourceIdentityPath -ErrorAction SilentlyContinue)) {
        throw "Convention specialist path validation requires SourceTransport.ps1."
    }
    return ConvertTo-ReviewerSourceIdentityPath -Path $Path
}

function ConvertTo-ReviewerConventionSpecialistRangesByPath {
    param([hashtable]$RightHandRangesByPath = @{})
    $result = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($rawPath in $RightHandRangesByPath.Keys) {
        $path = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path ([string]$rawPath)
        if (-not $path) {
            throw "Changed-file right-hand ranges contain an invalid repository path."
        }
        if ($result.ContainsKey($path)) {
            throw "Changed-file right-hand ranges contain ambiguous path identity '$path'."
        }
        $result.Add($path, @($RightHandRangesByPath[$rawPath]))
    }
    return $result
}

function Test-ReviewerConventionSpecialistInteger {
    param([AllowNull()]$Value)
    return ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or ($Value -is [uint64] -and
            $Value -le [uint64][int64]::MaxValue))
}

function Test-ReviewerConventionSpecialistDeterministicFact {
    param([AllowNull()]$Fact)
    if ($null -eq $Fact -or
        @("true", "false") -cnotcontains
            [string](Get-ReviewerConventionSpecialistValue $Fact "state" "")) {
        return $false
    }
    $value = Get-ReviewerConventionSpecialistValue $Fact "value" $null
    if ($value -is [bool]) { return $true }
    return ($value -is [string] -and
        -not ([string]$value -match '[\x00-\x1f\x7f]'))
}

function Resolve-ReviewerConventionSpecialistTargets {
    <#
        Resolves the one target grammar used by candidates, remediation,
        reconciliation, and previews. A cf target names one exact delivered
        right-hand line. A lexical target names one wrapper-enumerated construct.
        Nothing is inferred from nearby syntax or from a path supplied by a model.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [AllowEmptyCollection()][object[]]$Constructs = @(),
        [AllowEmptyCollection()][object[]]$ChangedFileAnchors = @(),
        [switch]$ChangedLinesOnly,
        [switch]$AllowPrMetadata,
        [int]$MaxTargets = 32
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    $constructMap = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $invalidConstructIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($construct in $(if ($ChangedLinesOnly) { @() } else { @($Constructs) })) {
        $id = [string](Get-ReviewerConventionSpecialistValue $construct "constructId" "")
        $path = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
            [string](Get-ReviewerConventionSpecialistValue $construct "path" ""))
        $line = Get-ReviewerConventionSpecialistValue $construct "line" $null
        $endLine = Get-ReviewerConventionSpecialistValue $construct "endLine" $null
        if ($id -cnotmatch '^(mi|dc|cm|as)[0-9]{1,3}$' -or
            $constructMap.ContainsKey($id) -or $invalidConstructIds.Contains($id) -or -not $path -or
            -not (Test-ReviewerConventionSpecialistInteger $line) -or
            -not (Test-ReviewerConventionSpecialistInteger $endLine) -or
            [int64]$line -lt 1 -or [int64]$endLine -lt [int64]$line -or
            [string](Get-ReviewerConventionSpecialistValue $construct "status" "known") -cne "known") {
            if ($id) {
                [void]$invalidConstructIds.Add($id)
                [void]$constructMap.Remove($id)
            }
            continue
        }
        $constructMap.Add($id, [pscustomobject][ordered]@{
                target = $id
                kind = "construct"
                constructKind = [string](Get-ReviewerConventionSpecialistValue $construct "kind" "")
                path = $path
                line = [int64]$line
                endLine = [int64]$endLine
            })
    }
    $fileMap = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $invalidFileIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($anchor in @($ChangedFileAnchors)) {
        $id = [string](Get-ReviewerConventionSpecialistValue $anchor "anchorId" "")
        $path = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
            [string](Get-ReviewerConventionSpecialistValue $anchor "path" ""))
        if ($id -cnotmatch '^cf[0-9]{1,3}$') { continue }
        if (-not $path -or $fileMap.ContainsKey($id) -or $invalidFileIds.Contains($id)) {
            [void]$invalidFileIds.Add($id)
            [void]$fileMap.Remove($id)
            continue
        }
        $ranges = [System.Collections.Generic.List[object]]::new()
        $malformedRange = $false
        foreach ($range in @(Get-ReviewerConventionSpecialistValue $anchor "rightHandRanges" @())) {
            $start = Get-ReviewerConventionSpecialistValue $range "startLine" $null
            $end = Get-ReviewerConventionSpecialistValue $range "endLine" $null
            if (-not (Test-ReviewerConventionSpecialistInteger $start) -or
                -not (Test-ReviewerConventionSpecialistInteger $end) -or
                [int64]$start -lt 1 -or [int64]$end -lt [int64]$start) {
                $malformedRange = $true
                break
            }
            [void]$ranges.Add([pscustomobject]@{ startLine = [int64]$start; endLine = [int64]$end })
        }
        if ($malformedRange) {
            [void]$invalidFileIds.Add($id)
            continue
        }
        $fileMap.Add($id, [pscustomobject]@{ path = $path; ranges = $ranges.ToArray() })
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $resolved = [System.Collections.Generic.List[object]]::new()
    $tokens = @($Text -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($tokens.Count -gt $MaxTargets) {
        [void]$errors.Add("target list exceeds the bounded $MaxTargets-target limit")
    }
    foreach ($token in @($tokens | Select-Object -First $MaxTargets)) {
        if (-not $seen.Add($token)) {
            [void]$errors.Add("target '$token' is duplicated")
            continue
        }
        if ($token -ceq "prmetadata") {
            if (-not $AllowPrMetadata -or $tokens.Count -ne 1) {
                [void]$errors.Add("prMetadata cannot be combined with changed-code targets")
            }
            else {
                [void]$resolved.Add([pscustomobject][ordered]@{
                        target = "prMetadata"; kind = "prMetadata"; path = ""; line = 0; endLine = 0
                    })
            }
            continue
        }
        $lineMatch = [regex]::Match($token, '^(cf[0-9]{1,3}):([1-9][0-9]{0,6})$')
        if ($lineMatch.Success) {
            $fileId = $lineMatch.Groups[1].Value
            $line = [int64]$lineMatch.Groups[2].Value
            if ($invalidFileIds.Contains($fileId) -or -not $fileMap.ContainsKey($fileId)) {
                [void]$errors.Add("changed-file target '$token' is missing or belongs to another sealed change set")
                continue
            }
            $anchor = $fileMap[$fileId]
            if (@($anchor.ranges | Where-Object {
                        $line -ge [int64]$_.startLine -and $line -le [int64]$_.endLine
                    }).Count -ne 1) {
                [void]$errors.Add("changed-file target '$token' is deleted, context, ambiguous, or outside its exact RawSpan")
                continue
            }
            [void]$resolved.Add([pscustomobject][ordered]@{
                    target = $token; kind = "changedLine"; path = [string]$anchor.path
                    line = $line; endLine = $line
                })
            continue
        }
        if (-not $ChangedLinesOnly -and $token -cmatch '^(mi|dc|cm|as)[0-9]{1,3}$') {
            if ($invalidConstructIds.Contains($token) -or -not $constructMap.ContainsKey($token)) {
                [void]$errors.Add("lexical target '$token' is missing or belongs to another sealed construct table")
            }
            else { [void]$resolved.Add($constructMap[$token]) }
            continue
        }
        [void]$errors.Add("target '$token' does not match the canonical target grammar")
    }
    $ordered = @($resolved.ToArray())
    [Array]::Sort($ordered, [System.Comparison[object]]{
            param($left, $right)
            $comparison = [StringComparer]::Ordinal.Compare([string]$left.path, [string]$right.path)
            if ($comparison -ne 0) { return $comparison }
            $comparison = [int64]$left.line - [int64]$right.line
            if ($comparison -ne 0) { return [Math]::Sign($comparison) }
            return [StringComparer]::Ordinal.Compare([string]$left.target, [string]$right.target)
        })
    return @{
        Ok = ($errors.Count -eq 0)
        Errors = [string[]]$errors.ToArray()
        Targets = @($ordered)
        Canonical = (@($ordered | ForEach-Object { [string]$_.target }) -join ",")
    }
}

function Get-ReviewerConventionSpecialistLocalDeclarationEvidence {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Constructs
    )
    $known = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $incomplete = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $unanchored = [System.Collections.Generic.List[string]]::new()
    $declarations = @($Constructs | Where-Object {
            [string](Get-ReviewerConventionSpecialistValue $_ "kind" "") -ceq "declaration"
        })
    foreach ($target in @($Targets)) {
        $targetName = [string](Get-ReviewerConventionSpecialistValue $target "target" "")
        $targetPath = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
            [string](Get-ReviewerConventionSpecialistValue $target "path" ""))
        $targetLine = [int64](Get-ReviewerConventionSpecialistValue $target "line" 0)
        $matches = @($declarations | Where-Object {
                $path = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
                    [string](Get-ReviewerConventionSpecialistValue $_ "path" ""))
                $start = [int64](Get-ReviewerConventionSpecialistValue $_ "line" 0)
                $end = [int64](Get-ReviewerConventionSpecialistValue $_ "endLine" $start)
                if ($end -lt $start) { $end = $start }
                $path -and [string]::Equals($path, $targetPath, [StringComparison]::Ordinal) -and
                    $targetLine -ge $start -and $targetLine -le $end
            })
        if ($matches.Count -eq 0) {
            if ($targetName) { [void]$unanchored.Add($targetName) }
            continue
        }
        foreach ($declaration in $matches) {
            $id = [string](Get-ReviewerConventionSpecialistValue $declaration "constructId" "")
            if (-not $id) { continue }
            if ([string](Get-ReviewerConventionSpecialistValue $declaration "status" "known") -ceq "known") {
                if (-not $known.Contains($id)) { $known.Add($id, $declaration) }
            }
            else { [void]$incomplete.Add($id) }
        }
    }
    $knownIds = [string[]]@($known.Keys)
    $incompleteIds = [string[]]@($incomplete)
    [Array]::Sort($incompleteIds, [StringComparer]::Ordinal)
    $ok = ($knownIds.Count -gt 0 -and $incompleteIds.Count -eq 0 -and $unanchored.Count -eq 0)
    $knownRange = ConvertTo-ReviewerConventionSpecialistConstructIdRanges -Ids $knownIds
    $evidence = "Wrapper local declaration evidence: $($knownIds.Count) anchored declaration(s)"
    if ($knownRange) { $evidence += " ($knownRange)" }
    $evidence += " have status known and established own attribute lists."
    return @{
        Ok = $ok
        Evidence = (Get-ReviewerConventionSpecialistShortened -Text $evidence -MaxLength 800)
        KnownIds = $knownIds
        IncompleteIds = $incompleteIds
        UnanchoredTargets = [string[]]$unanchored.ToArray()
    }
}

function Get-ReviewerConventionSpecialistDebtEvidenceFactId {
    param([Parameter(Mandatory)]$Evidence)
    $rows = @((Get-ReviewerConventionSpecialistValue $Evidence "attributeFrequency" @()) |
        ForEach-Object {
            [pscustomobject]@{
                attribute = [string](Get-ReviewerConventionSpecialistValue $_ "attribute" "")
                declarations = [int](Get-ReviewerConventionSpecialistValue $_ "declarations" 0)
            }
        })
    $text = @(
        [string](Get-ReviewerConventionSpecialistValue $Evidence "path" ""),
        [string][int](Get-ReviewerConventionSpecialistValue $Evidence "declarationCount" 0),
        [string][bool](Get-ReviewerConventionSpecialistValue $Evidence "attributeCountsComplete" $false),
        [string][bool](Get-ReviewerConventionSpecialistValue $Evidence "generatedCode" $true),
        [string][bool](Get-ReviewerConventionSpecialistValue $Evidence "wholeFileComplete" $false),
        [string][int](Get-ReviewerConventionSpecialistValue $Evidence "wholeFileLineCount" 0),
        [string](Get-ReviewerConventionSpecialistValue $Evidence "wholeFileSha256" ""),
        @($rows | ForEach-Object { "$($_.attribute)=$($_.declarations)" }) -join ","
    ) -join "`n"
    return "rdf1:$(Get-ReviewerConventionSpecialistSha256 -Text $text)"
}

function Get-ReviewerConventionSpecialistRemediationErrors {
    param(
        [Parameter(Mandatory)]$Candidate,
        [AllowEmptyCollection()][object[]]$Constructs = @(),
        [AllowEmptyCollection()][object[]]$ConstructFiles = @(),
        [AllowEmptyCollection()][object[]]$ChangedFileAnchors = @(),
        $FactPlan = $null
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    $changedFix = Get-ReviewerConventionSpecialistValue $Candidate "changedCodeFix" $null
    $action = [string](Get-ReviewerConventionSpecialistValue $changedFix "action" "")
    $conventionKey = [string](Get-ReviewerConventionSpecialistValue $changedFix "conventionKey" "")
    $valueSource = [string](Get-ReviewerConventionSpecialistValue $changedFix "valueSource" "")
    $changedFactText = [string](Get-ReviewerConventionSpecialistValue $changedFix "evidenceFactIds" "")
    if (@("add", "modify", "remove", "rename", "replace", "validate") -cnotcontains $action -or
        $conventionKey -cnotmatch '^[A-Za-z_][A-Za-z0-9_.:\-]{0,127}$' -or
        @("authoritativeRule", "deterministicFact") -cnotcontains $valueSource -or
        ($valueSource -ceq "authoritativeRule" -and $changedFactText) -or
        ($valueSource -ceq "deterministicFact" -and -not $changedFactText)) {
        [void]$errors.Add("changed-code remediation is incomplete or contradictory")
    }
    $anchorKind = [string](Get-ReviewerConventionSpecialistValue $Candidate "anchorKind" "")
    $resolvedTargets = Resolve-ReviewerConventionSpecialistTargets `
        -Text ([string](Get-ReviewerConventionSpecialistValue $changedFix "targets" "")) `
        -Constructs $Constructs -ChangedFileAnchors $ChangedFileAnchors `
        -AllowPrMetadata:($anchorKind -ceq "prMetadata")
    foreach ($targetError in @($resolvedTargets.Errors)) { [void]$errors.Add($targetError) }
    if ($anchorKind -ceq "prMetadata") {
        if ([string]$resolvedTargets.Canonical -cne "prMetadata") {
            [void]$errors.Add("metadata remediation must target prMetadata")
        }
    }
    else {
        if (@($resolvedTargets.Targets).Count -eq 0) {
            [void]$errors.Add("changed-file remediation must target a sealed changed line or truthful lexical construct")
        }
    }
    $factMap = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($fact in @(Get-ReviewerConventionSpecialistValue $FactPlan "facts" @())) {
        $id = [string](Get-ReviewerConventionSpecialistValue $fact "id" "")
        if ($id -and -not $factMap.ContainsKey($id)) { $factMap.Add($id, $fact) }
    }
    $changedFactIds = @($changedFactText -split ',' | Where-Object { $_ })
    if (@($changedFactIds | Select-Object -Unique).Count -ne $changedFactIds.Count) {
        [void]$errors.Add("changed-code remediation duplicates a deterministic fact")
    }
    foreach ($factId in $changedFactIds) {
        if ($factId -cnotmatch '^rf1:[0-9a-f]{64}$' -or -not $factMap.ContainsKey($factId) -or
            -not (Test-ReviewerConventionSpecialistDeterministicFact $factMap[$factId])) {
            [void]$errors.Add("changed-code remediation cites a fact that is unknown or not a canonical boolean/string value")
        }
    }

    $debt = Get-ReviewerConventionSpecialistValue $Candidate "existingDebtFollowUp" $null
    $debtStatus = [string](Get-ReviewerConventionSpecialistValue $debt "status" "")
    $debtFactId = [string](Get-ReviewerConventionSpecialistValue $debt "evidenceFactId" "")
    $selectorKey = [string](Get-ReviewerConventionSpecialistValue $debt "selectorKey" "")
    $scopeKind = [string](Get-ReviewerConventionSpecialistValue $debt "scopeKind" "")
    $scopePath = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
        [string](Get-ReviewerConventionSpecialistValue $debt "scopePath" ""))
    $comparableValue = Get-ReviewerConventionSpecialistValue $debt "comparableCount" $null
    $compliantValue = Get-ReviewerConventionSpecialistValue $debt "compliantCount" $null
    $debtAction = [string](Get-ReviewerConventionSpecialistValue $debt "action" "")
    if ($debtStatus -ceq "none") {
        if ($debtFactId -or $selectorKey -or $scopeKind -or $scopePath -or $debtAction -or
            -not (Test-ReviewerConventionSpecialistInteger $comparableValue) -or
            -not (Test-ReviewerConventionSpecialistInteger $compliantValue) -or
            [int]$comparableValue -ne 0 -or [int]$compliantValue -ne 0) {
            [void]$errors.Add("empty existing-debt follow-up must be explicit and contain no claim")
        }
    }
    elseif ($debtStatus -ceq "required") {
        $candidatePath = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
            [string](Get-ReviewerConventionSpecialistValue $Candidate "filePath" ""))
        if ($debtFactId -cnotmatch '^rdf1:[0-9a-f]{64}$' -or
            $selectorKey -cnotmatch '^[A-Za-z_][A-Za-z0-9_.:-]{0,127}$' -or
            $selectorKey -ceq $conventionKey -or
            $scopeKind -cne "file" -or -not $scopePath -or $scopePath -cne $candidatePath -or
            -not (Test-ReviewerConventionSpecialistInteger $comparableValue) -or
            -not (Test-ReviewerConventionSpecialistInteger $compliantValue) -or
            [int]$comparableValue -lt 4 -or [int]$compliantValue -ne 0 -or
            @("recordTrackedFollowUp", "linkTrackedFollowUp") -cnotcontains $debtAction) {
            [void]$errors.Add("existing-debt follow-up is unsupported, unbounded, or non-systematic")
        }
        $matchingFiles = @($ConstructFiles | Where-Object {
                [string](Get-ReviewerConventionSpecialistValue $_ "evidenceFactId" "") -ceq $debtFactId -and
                (ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
                    [string](Get-ReviewerConventionSpecialistValue $_ "path" ""))) -ceq $scopePath
            })
        if ($matchingFiles.Count -ne 1 -or
            -not [bool](Get-ReviewerConventionSpecialistValue $matchingFiles[0] "attributeCountsComplete" $false) -or
            [bool](Get-ReviewerConventionSpecialistValue $matchingFiles[0] "generatedCode" $true) -or
            -not [bool](Get-ReviewerConventionSpecialistValue $matchingFiles[0] "wholeFileComplete" $false) -or
            [int](Get-ReviewerConventionSpecialistValue $matchingFiles[0] "wholeFileLineCount" 0) -lt
                [int](Get-ReviewerConventionSpecialistValue $matchingFiles[0] "declarationCount" 0) -or
            [string](Get-ReviewerConventionSpecialistValue $matchingFiles[0] "wholeFileSha256" "") -cnotmatch
                '^[0-9a-f]{64}$' -or
            (Get-ReviewerConventionSpecialistDebtEvidenceFactId -Evidence $matchingFiles[0]) -cne $debtFactId) {
            [void]$errors.Add("existing-debt evidence does not bind the claimed bounded scope and count")
        }
        else {
            $selectorFrequency = @((Get-ReviewerConventionSpecialistValue `
                        $matchingFiles[0] "attributeFrequency" @()) | Where-Object {
                    [string](Get-ReviewerConventionSpecialistValue $_ "attribute" "") -ceq $selectorKey
                })
            $matchingFrequency = @((Get-ReviewerConventionSpecialistValue `
                        $matchingFiles[0] "attributeFrequency" @()) | Where-Object {
                    [string](Get-ReviewerConventionSpecialistValue $_ "attribute" "") -ceq $conventionKey
                })
            $actualCompliant = $(if ($matchingFrequency.Count -eq 1) {
                    [int](Get-ReviewerConventionSpecialistValue $matchingFrequency[0] "declarations" 0)
                } else { 0 })
            $actualComparable = $(if ($selectorFrequency.Count -eq 1) {
                    [int](Get-ReviewerConventionSpecialistValue $selectorFrequency[0] "declarations" 0)
                } else { -1 })
            if ($selectorFrequency.Count -ne 1 -or $actualComparable -ne [int]$comparableValue -or
                $matchingFrequency.Count -gt 1 -or $actualCompliant -ne [int]$compliantValue) {
                [void]$errors.Add("existing-debt compliant count disagrees with sealed evidence")
            }
        }
    }
    else {
        [void]$errors.Add("existing-debt follow-up status is missing")
    }
    return , [string[]]$errors.ToArray()
}
$script:ReviewerConventionSpecialistImpactCategories = @(
    "none", "buildOrTestExecution", "deployment", "security", "customerBehavior", "compatibility"
)
$script:ReviewerConventionSpecialistWithheldReasons = @(
    "sourceConflict", "outsideChangedFile", "invalidAnchor", "unverifiedSource",
    "unknownFact", "unsupportedSeverity", "missingSiblingEvidence", "duplicateCandidate",
    "duplicateExistingThread", "accountedNotEmitted", "invalidTarget", "invalidEvidence"
)
$script:ReviewerConventionSpecialistCoverageStatuses = @(
    "violation", "compliant", "notApplicable", "unknown"
)
# What a rule was judged against. The scope names the construct KINDS the rule
# governs, and the wrapper turns that into the exact set of ids the row must
# account for, so it cannot be left to prose.
$script:ReviewerConventionSpecialistCoverageScopePattern =
'^(none|(invocation|declaration|comment|assignment)(,(invocation|declaration|comment|assignment))*)$'

# The kinds of changed construct the wrapper enumerates. Every row owes an
# answer for the full sealed table; scope is only the subset of kinds the rule
# can judge as violating, compliant, or unknown.
$script:ReviewerConventionSpecialistConstructKinds = @(
    "invocation", "declaration", "comment", "assignment"
)
# One place for the id-list shape: ids and inclusive same-kind ranges. Four row
# fields share it, and four copies of a regex is four chances to edit three.
$script:ReviewerConventionSpecialistConstructListPattern =
'^(|(mi|dc|cm|as)[0-9]{1,3}(-(mi|dc|cm|as)[0-9]{1,3})?(,(mi|dc|cm|as)[0-9]{1,3}(-(mi|dc|cm|as)[0-9]{1,3})?)*)$'
$script:ReviewerConventionSpecialistChangedLineListPattern =
'^(|cf[0-9]{1,3}:[1-9][0-9]{0,6}(,cf[0-9]{1,3}:[1-9][0-9]{0,6})*)$'
$script:ReviewerConventionSpecialistTargetListPattern =
'^(prMetadata|(?:cf[0-9]{1,3}:[1-9][0-9]{0,6}|(?:mi|dc|cm|as)[0-9]{1,3})(?:,(?:cf[0-9]{1,3}:[1-9][0-9]{0,6}|(?:mi|dc|cm|as)[0-9]{1,3})){0,31})$'
$script:ReviewerConventionSpecialistConstructPrefixes = @{
    invocation = "mi"; declaration = "dc"; comment = "cm"; assignment = "as"
}

function New-ReviewerConventionSpecialistConstructIdResult {
    <#
        The blind-results stage boundary for one accounted construct-id field.

        Every exit from the id reader goes through here, including the
        unreadable ones: an empty id list is exactly the shape that turned a
        sealed anchor set into "every anchor is missing a verdict", so it has to
        be judged rather than waved through because it carries no elements. The
        judged payload is what the caller's answer is built from, so removing
        the boundary removes the answer with it.
    #>
    param(
        [Parameter(Mandatory)][bool]$Ok,
        [Parameter(Mandatory)][AllowNull()]$Ids,
        [Parameter(Mandatory)][AllowNull()]$Duplicated
    )

    $asserted = New-ReviewerBlindResultsStageContract -ConstructIds $Ids -DuplicatedConstructIds $Duplicated
    return @{
        Ok = $Ok
        Ids = [object[]]$asserted.constructIds
        Duplicated = [object[]]$asserted.duplicatedConstructIds
    }
}

function Expand-ReviewerConventionSpecialistConstructIds {
    <#
        Reads a construct-id list that may use inclusive ranges - `mi0-mi37` for
        every invocation from 0 to 37.

        Without ranges a complete accounting over a large change set does not
        fit in a field short enough to survive the marker's length bound, and an
        answer that cannot be written is the same as no checklist at all. A
        range must stay within one kind and must not run backwards; anything
        else is reported unreadable rather than guessed at.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [int]$MaxIds = 4096)
    # Lowercased first, for the same reason `scope` is. The marker validator
    # checks its `Pattern` case-insensitively, so `MI0,DC3` gets past validation
    # and then fails the case-sensitive parse below - degrading a row that was
    # right over a capital letter. Ids are lowercase by construction, so folding
    # cannot admit an id that does not exist.
    $Text = $Text.ToLowerInvariant()
    $ids = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $duplicated = [System.Collections.Generic.List[string]]::new()
    $duplicatedSeen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $scanned = 0
    $scanCeiling = $MaxIds * 4
    foreach ($part in @(($Text -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $match = [regex]::Match($part, '^([a-z]{2})([0-9]{1,3})(?:-([a-z]{2})([0-9]{1,3}))?$')
        if (-not $match.Success) { return New-ReviewerConventionSpecialistConstructIdResult -Ok $false -Ids ([object[]]@()) -Duplicated ([object[]]@()) }
        $prefix = $match.Groups[1].Value
        if (@($script:ReviewerConventionSpecialistConstructPrefixes.Values) -cnotcontains $prefix) {
            return New-ReviewerConventionSpecialistConstructIdResult -Ok $false -Ids ([object[]]@()) -Duplicated ([object[]]@())
        }
        $first = [int]$match.Groups[2].Value
        $last = $first
        if ($match.Groups[3].Success) {
            if ($match.Groups[3].Value -cne $prefix) { return New-ReviewerConventionSpecialistConstructIdResult -Ok $false -Ids ([object[]]@()) -Duplicated ([object[]]@()) }
            $last = [int]$match.Groups[4].Value
            if ($last -lt $first) { return New-ReviewerConventionSpecialistConstructIdResult -Ok $false -Ids ([object[]]@()) -Duplicated ([object[]]@()) }
        }
        for ($index = $first; $index -le $last; $index++) {
            # Two ceilings, because they catch different shapes. `MaxIds`
            # bounds the UNIQUE ids, which is what the partition costs
            # downstream. `$scanned` bounds the WORK: a field of overlapping
            # ranges (`mi0-mi134` forty times over) never adds a new id, so it
            # never reaches the first ceiling, and it ran the inner loop in
            # full - 1.6 seconds per call, three times over if the specialist
            # retries.
            if ($ids.Count -ge $MaxIds -or $scanned -ge $scanCeiling) {
                return New-ReviewerConventionSpecialistConstructIdResult -Ok $false -Ids ([object[]]@()) -Duplicated ([object[]]@())
            }
            $scanned++
            $id = "$prefix$index"
            # A repeated id is not a harmless spelling. Silently collapsing it
            # would let a row name the same anchor twice and still look like an
            # exact cover, which is the one property this whole partition rests
            # on.
            if ($seen.Add($id)) { [void]$ids.Add($id) }
            elseif ($duplicatedSeen.Add($id)) { [void]$duplicated.Add($id) }
        }
    }
    return New-ReviewerConventionSpecialistConstructIdResult -Ok $true -Ids $ids -Duplicated $duplicated
}

function ConvertTo-ReviewerConventionSpecialistConstructIdRanges {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Ids)
    if (Get-Command -Name Get-ReviewerConstructIdRanges -ErrorAction SilentlyContinue) {
        return Get-ReviewerConstructIdRanges -Ids $Ids
    }
    $items = @($Ids)
    if ($items.Count -eq 0) { return "" }
    $parts = [System.Collections.Generic.List[string]]::new()
    $runStart = $items[0]
    $previous = $items[0]
    for ($i = 1; $i -le $items.Count; $i++) {
        $current = if ($i -lt $items.Count) { [string]$items[$i] } else { "" }
        $contiguous = $false
        if ($current) {
            $previousMatch = [regex]::Match($previous, '^([a-z]{2})([0-9]+)$')
            $currentMatch = [regex]::Match($current, '^([a-z]{2})([0-9]+)$')
            if ($previousMatch.Success -and $currentMatch.Success -and
                $previousMatch.Groups[1].Value -ceq $currentMatch.Groups[1].Value -and
                ([int]$currentMatch.Groups[2].Value - [int]$previousMatch.Groups[2].Value) -eq 1) {
                $contiguous = $true
            }
        }
        if (-not $contiguous) {
            if ($runStart -ceq $previous) { [void]$parts.Add($runStart) }
            else { [void]$parts.Add("$runStart-$previous") }
            $runStart = $current
        }
        $previous = $current
    }
    return ($parts -join ",")
}

function Get-ReviewerConventionSpecialistShortened {
    <#
        Cuts a string to a length without splitting a surrogate pair.

        The text being cut here is model prose from a coverage row's `notes`,
        which carries no ASCII pattern, so a non-BMP character in it is legal.
        Half a surrogate pair is not a control character and has no pattern to
        fail, so it survives every check and then throws when the preview is
        written as strict UTF-8 - taking the whole pass, candidates included,
        with an error that reads like corruption. The harness guards its own
        truncation the same way; this is the one place the wrapper cuts text
        itself.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$MaxLength
    )
    if ($MaxLength -le 0) { return "" }
    if ($Text.Length -le $MaxLength) { return $Text }
    $cut = $MaxLength
    if ($cut -gt 0 -and [char]::IsHighSurrogate($Text[$cut - 1])) { $cut-- }
    return $Text.Substring(0, $cut)
}

function Get-ReviewerConventionSpecialistValue {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        $containsKey = $Object.PSObject.Methods["ContainsKey"]
        if (($containsKey -and $Object.ContainsKey($Name)) -or
            (-not $containsKey -and $Object.Contains($Name))) {
            return $Object[$Name]
        }
        return $Default
    }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $property = $Object.PSObject.Properties[$Name]
        if ($property) { return $property.Value }
    }
    return $Default
}

function Get-ReviewerConventionSpecialistSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
                $sha.ComputeHash($script:ReviewerConventionSpecialistUtf8.GetBytes($Text)))).Replace("-", "").ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function ConvertTo-ReviewerConventionSpecialistCanonicalJson {
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 32) { throw "Convention specialist canonical JSON exceeded the maximum object depth of 32." }
    if ($null -eq $Value) { return "null" }
    if ($Value -is [bool]) { return $(if ($Value) { "true" } else { "false" }) }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal] -or
        $Value -is [System.Numerics.BigInteger]) {
        return [Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string]) {
        [void]$script:ReviewerConventionSpecialistUtf8.GetByteCount($Value)
        return ConvertTo-Json -InputObject $Value -Compress
    }
    if ($Value -is [System.Collections.IDictionary] -or
        $Value -is [System.Management.Automation.PSCustomObject]) {
        $names = [System.Collections.Generic.List[string]]::new()
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.Keys) {
                if ($key -isnot [string]) { throw "Convention specialist canonical JSON keys must be strings." }
                [void]$names.Add([string]$key)
            }
        }
        else {
            foreach ($property in $Value.PSObject.Properties) { [void]$names.Add($property.Name) }
        }
        $names.Sort([StringComparer]::Ordinal)
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $names) {
            $rawValue = $null
            if ($Value -is [System.Collections.IDictionary]) { $rawValue = $Value[$name] }
            else { $rawValue = $Value.PSObject.Properties[$name].Value }
            [void]$parts.Add(
                (ConvertTo-Json -InputObject $name -Compress) + ":" +
                (ConvertTo-ReviewerConventionSpecialistCanonicalJson -Value $rawValue -Depth ($Depth + 1)))
        }
        return "{" + ($parts.ToArray() -join ",") + "}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $Value) {
            [void]$parts.Add((ConvertTo-ReviewerConventionSpecialistCanonicalJson -Value $item -Depth ($Depth + 1)))
        }
        return "[" + ($parts.ToArray() -join ",") + "]"
    }
    throw "Convention specialist canonical JSON encountered unsupported type '$($Value.GetType().FullName)'."
}

function Get-ReviewerConventionSpecialistObjectSha256 {
    param([Parameter(Mandatory)]$Value)
    return Get-ReviewerConventionSpecialistSha256 -Text (
        ConvertTo-ReviewerConventionSpecialistCanonicalJson -Value $Value)
}

function Get-ReviewerConventionSpecialistDomainKey {
    param(
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [Parameter(Mandatory)][ValidateSet("plan", "preview")][string]$Domain
    )
    $label = "devpilot.reviewer.convention-specialist.$Domain.v1"
    $hmac = [Security.Cryptography.HMACSHA256]::new($MasterKey)
    try { return , $hmac.ComputeHash($script:ReviewerConventionSpecialistUtf8.GetBytes($label)) }
    finally { $hmac.Dispose() }
}

function Get-ReviewerConventionSpecialistSignature {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $hmac = [Security.Cryptography.HMACSHA256]::new($Key)
    try {
        return ([BitConverter]::ToString(
                $hmac.ComputeHash($script:ReviewerConventionSpecialistUtf8.GetBytes($Json)))).Replace("-", "").ToLowerInvariant()
    }
    finally { $hmac.Dispose() }
}

function Test-ReviewerConventionSpecialistSignature {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][byte[]]$Key,
        [AllowEmptyString()][string]$Signature = ""
    )
    if ($Signature -notmatch '^[0-9a-f]{64}$') { return $false }
    $expected = Get-ReviewerConventionSpecialistSignature -Json $Json -Key $Key
    return [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
        [Convert]::FromHexString($expected),
        [Convert]::FromHexString($Signature))
}

function Save-ReviewerConventionPlanFile {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][byte[]]$MasterKey
    )
    if ($BaseName -notmatch '^[A-Za-z0-9._-]+$') { throw "Convention plan base name is unsafe." }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Convention plan directory '$Directory' does not exist."
    }
    $json = $Plan | ConvertTo-Json -Depth 32 -Compress
    [void]$script:ReviewerConventionSpecialistUtf8.GetByteCount($json)
    $key = Get-ReviewerConventionSpecialistDomainKey -MasterKey $MasterKey -Domain plan
    $signature = Get-ReviewerConventionSpecialistSignature -Json $json -Key $key
    $path = Join-Path $Directory ($BaseName + ".json")
    $signaturePath = $path + ".sig"
    $nonce = [Guid]::NewGuid().ToString("N")
    $tempPath = "$path.$nonce.tmp"
    $tempSignaturePath = "$signaturePath.$nonce.tmp"
    try {
        [IO.File]::WriteAllText($tempPath, $json, $script:ReviewerConventionSpecialistUtf8)
        [IO.File]::WriteAllText($tempSignaturePath, $signature, [Text.Encoding]::ASCII)
        Move-Item -LiteralPath $tempPath -Destination $path -Force
        Move-Item -LiteralPath $tempSignaturePath -Destination $signaturePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
        if (Test-Path -LiteralPath $tempSignaturePath) { Remove-Item -LiteralPath $tempSignaturePath -Force }
    }
    return $path
}

function Read-ReviewerConventionPlanFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$MasterKey
    )
    $signaturePath = $Path + ".sig"
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        -not (Test-Path -LiteralPath $signaturePath -PathType Leaf)) {
        throw "Convention plan or its detached signature is missing."
    }
    $json = [IO.File]::ReadAllText($Path, $script:ReviewerConventionSpecialistUtf8)
    $signature = [IO.File]::ReadAllText($signaturePath, [Text.Encoding]::ASCII).Trim()
    $key = Get-ReviewerConventionSpecialistDomainKey -MasterKey $MasterKey -Domain plan
    if (-not (Test-ReviewerConventionSpecialistSignature -Json $json -Key $key -Signature $signature)) {
        throw "Convention plan signature verification failed."
    }
    $plan = $json | ConvertFrom-Json -Depth 32
    if ($plan -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Convention plan top level must be an object."
    }
    return $plan
}

function Get-ReviewerConventionSpecialistMarkerSchema {
    <#
        The result contract, by version.

        Version 2 is FROZEN. Sealed transcripts and previews on disk were
        produced against it, and a replay that cannot read them is a replay that
        cannot check anything. Nothing in it may change shape.

        Version 3 removes the eight fields the wrapper already holds and the
        model merely retyped - the pack name, the five rule-source provenance
        fields, and the anchor's file path and line - and asks for `ruleRef`
        instead, which is the same `rs<n>` addressing the coverage rows already
        use. Every one of those fields was an independent way for a correct
        finding to be refused over a transcription slip: `ruleSourceSha256`
        alone is sixty-four hex characters copied by hand. The wrapper derives
        them all from what it transported, so they cannot disagree with it.

        Version 3 also lets `factIds` cite a declaration-census fact (`rdf1:`)
        as well as a review fact (`rf1:`). An adoption rule - "this attribute
        belongs on these declarations" - turns on the census, and version 2 gave
        the model no legal way to name the evidence its own conclusion rested
        on.

        Version 4 stops trimming the model's transport surface and removes it.
        Ten qualification runs found all nine violating declarations every time,
        with zero false positives, and lost them anyway: to a `primaryTarget`
        written as a construct id, to six different spellings of a
        `conventionKey`, to a `notInReachConstructs` list that omitted the 25
        out-of-kind ids it was a set-complement of, and to a row `status` the
        wrapper already derived and overrode. Every one of those is arithmetic or
        provenance the wrapper holds. So version 4 asks for the one thing it does
        not hold - a verdict on each construct - and derives the rest.

        A row is `ruleRef` plus one entry per in-scope construct, each carrying
        an opaque `constructRef` and a `verdict`. Rationale and suggestion are
        optional, violation-only, and NON-ELIGIBILITY-CRITICAL: they are dropped
        on failure and the verdict survives, so prose can no longer cost a
        finding. `candidates` and `ruleCoverage` are gone as separate arrays -
        the wrapper groups violations into candidates itself, which is why a
        model that splits its answer per file and one that does not now produce
        identical output.
    #>
    param(
        [Parameter(Mandatory)][string]$ExpectedProject,
        [Parameter(Mandatory)][string]$ExpectedNonce,
        [int]$MaxCandidateItems = $script:ReviewerConventionSpecialistMaxCandidates,
        [ValidateSet(2, 3, 4)][int]$ContractVersion = 2
    )
    $ascii = '^[\x20-\x7E]*$'
    # Version 4 is a DIFFERENT shape, not a narrower version 3, so it returns its
    # own schema rather than threading `-ge 3` branches through the one below.
    # Sharing the builder would mean every existing branch silently applied to a
    # contract that no longer has the fields those branches are about.
    if ($ContractVersion -eq 4) {
        return @{
            Keys = @(
                "schemaVersion", "prId", "repositoryId", "project", "reviewedSourceCommit",
                "targetCommit", "changeSetDigest", "conventionPlanSha256", "factPlanSha256",
                "configSha256", "scriptSha256", "promptSha256",
                "assessments", "withheld", "residualRisks", "nonce"
            )
            Fields = @{
                schemaVersion = @{ Type = "int"; Min = 4; Max = 4 }
                prId = @{ Type = "int"; Min = 1; Max = [int]::MaxValue }
                repositoryId = @{ Type = "guid" }
                project = @{ Type = "exact"; Expected = $ExpectedProject }
                reviewedSourceCommit = @{ Type = "hex"; Length = 40 }
                targetCommit = @{ Type = "hex"; Length = 40 }
                changeSetDigest = @{ Type = "hex"; Length = 64 }
                conventionPlanSha256 = @{ Type = "hex"; Length = 64 }
                factPlanSha256 = @{ Type = "hex"; Length = 64 }
                configSha256 = @{ Type = "hex"; Length = 64 }
                scriptSha256 = @{ Type = "hex"; Length = 64 }
                promptSha256 = @{ Type = "hex"; Length = 64 }
                # One row per REQUESTED rule. A row that cannot be read drops
                # ITSELF; the rules beside it are untouched, because one
                # unreadable row says nothing about the others.
                assessments = @{
                    Type = "objectArray"
                    MaxItems = $script:ReviewerConventionSpecialistMaxRuleCoverage
                    ElementFailurePolicy = "drop"
                    Item = @{
                        Keys = @("ruleRef", "constructs", "notes")
                        Fields = @{
                            ruleRef = @{ Type = "string"; MaxLength = 5; Pattern = '^rs[0-9]{1,3}$' }
                            # Exactly one entry per in-scope construct. The
                            # wrapper checks that against the set it enumerated
                            # and delivered, so an omission cannot pass as
                            # "nothing to say about it" - it makes the ROW
                            # incomplete. This is the whole anti-silence
                            # mechanism, moved off the model's arithmetic and
                            # onto the wrapper's.
                            constructs = @{
                                Type = "objectArray"
                                MaxItems = $script:ReviewerConventionSpecialistMaxConstructAssessments
                                # NOT "drop". A dropped construct entry is
                                # indistinguishable from one the model never
                                # sent, and both must make the row incomplete
                                # rather than quietly shrink the set that gets a
                                # verdict. The row-level policy above already
                                # keeps that local to one rule.
                                ElementFailurePolicy = "fail"
                                Item = @{
                                    Keys = @("constructRef", "verdict")
                                    Fields = @{
                                        constructRef = @{
                                            Type = "string"; MaxLength = 5
                                            Pattern = $script:ReviewerConventionSpecialistConstructRefPattern
                                        }
                                        verdict = @{
                                            Type = "enum"
                                            Values = $script:ReviewerConventionSpecialistVerdicts
                                        }
                                    }
                                }
                            }
                            # Prose lives HERE, not on the verdict, for two
                            # reasons. It is bounded independently, so the
                            # largest legal row is a hundred and twenty short
                            # verdicts plus a few sentences rather than a
                            # hundred and twenty paragraphs - which is what
                            # keeps the worst legal marker inside the launch
                            # contract's scan window. And it is `drop`, so an
                            # unreadable sentence discards ITSELF: prose can
                            # never cost a verdict, a finding, or a row.
                            notes = @{
                                Type = "objectArray"
                                MaxItems = $script:ReviewerConventionSpecialistMaxProseAssessments
                                ElementFailurePolicy = "drop"
                                Item = @{
                                    Keys = @("constructRef", "rationale", "suggestion")
                                    Fields = @{
                                        constructRef = @{
                                            Type = "string"; MaxLength = 5
                                            Pattern = $script:ReviewerConventionSpecialistConstructRefPattern
                                        }
                                        rationale = @{
                                            Type = "string"; AllowEmpty = $true
                                            MaxLength = $script:ReviewerConventionSpecialistMaxRationaleLength
                                            Pattern = $ascii; NormalizeTypography = $true
                                        }
                                        suggestion = @{
                                            Type = "string"; AllowEmpty = $true
                                            MaxLength = $script:ReviewerConventionSpecialistMaxSuggestionLength
                                            Pattern = $ascii; NormalizeTypography = $true
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                withheld = @{
                    Type = "objectArray"; MaxItems = 24
                    # `drop`, for the same reason the notes array is. A withheld
                    # entry is the model reporting its OWN limitation; it is not
                    # a finding, and it must not be able to discard nine correct
                    # verdicts by being malformed. The drop is itself reported,
                    # so a lost self-report is visible rather than silent.
                    ElementFailurePolicy = "drop"
                    Item = @{
                        Keys = @("candidateId", "reason", "detail")
                        Fields = @{
                            candidateId = @{ Type = "string"; MaxLength = 64; AllowEmpty = $true; Pattern = '^(|[a-z][a-z0-9-]{0,63})$' }
                            reason = @{ Type = "enum"; Values = $script:ReviewerConventionSpecialistWithheldReasons }
                            detail = @{ Type = "string"; MaxLength = 800; Pattern = $ascii }
                        }
                    }
                }
                # A residual risk is a caveat, not a verdict. Under versions 2
                # and 3 a malformed one failed the WHOLE marker - and in the
                # final v4 qualification series that is exactly what happened
                # twice, costing two of five model starts, because the model
                # wrote the risks as bare strings instead of `{text}` objects.
                # Nine correct verdicts were discarded over the shape of a
                # footnote. The normalizer now coerces a bare string, and
                # anything still unreadable drops itself.
                residualRisks = @{
                    Type = "objectArray"; MaxItems = 12
                    ElementFailurePolicy = "drop"
                    Item = @{
                        Keys = @("text")
                        Fields = @{ text = @{ Type = "string"; MaxLength = 800; Pattern = $ascii; NormalizeTypography = $true } }
                    }
                }
                nonce = @{ Type = "exact"; Expected = $ExpectedNonce }
            }
        }
    }
    $wrapperOwnedKeys = @(
        "filePath", "line", "packName", "ruleSourceId", "ruleSourceRepositoryId",
        "ruleSourcePath", "ruleSourceCommit", "ruleSourceSha256"
    )
    $candidateKeys = @(
        "candidateId", "category", "severity", "anchorKind", "filePath", "line",
        "primaryTarget", "manifestations",
        "packName", "ruleSourceId", "ruleSourceRepositoryId", "ruleSourcePath",
        "ruleSourceCommit", "ruleSourceSha256", "ruleSection", "ruleQuote",
        "diffEvidence", "impactCategory", "impact", "expectedFixOrValidation",
        "siblingStatus", "siblingEvidence", "siblingNotRequiredReason",
        "factIds", "confidence", "residualRiskSummary", "semanticCandidateVersion",
        "changedCodeFix", "existingDebtFollowUp"
    )
    if ($ContractVersion -ge 3) {
        $candidateKeys = @(@($candidateKeys | Where-Object { $wrapperOwnedKeys -notcontains $_ }) + "ruleRef")
    }
    $factIdPattern = if ($ContractVersion -ge 3) {
        # Either namespace, in any order, still bounded at eight.
        '^(|r(d)?f1:[0-9a-f]{64}(,r(d)?f1:[0-9a-f]{64}){0,7})$'
    }
    else { '^(|rf1:[0-9a-f]{64}(,rf1:[0-9a-f]{64}){0,7})$' }
    return @{
        Keys = @(
            "schemaVersion", "prId", "repositoryId", "project", "reviewedSourceCommit",
            "targetCommit", "changeSetDigest", "conventionPlanSha256", "factPlanSha256",
            "configSha256", "scriptSha256", "promptSha256",
            "candidates", "ruleCoverage", "withheld", "residualRisks", "nonce"
        )
        Fields = @{
            schemaVersion = @{ Type = "int"; Min = $ContractVersion; Max = $ContractVersion }
            prId = @{ Type = "int"; Min = 1; Max = [int]::MaxValue }
            repositoryId = @{ Type = "guid" }
            project = @{ Type = "exact"; Expected = $ExpectedProject }
            reviewedSourceCommit = @{ Type = "hex"; Length = 40 }
            targetCommit = @{ Type = "hex"; Length = 40 }
            changeSetDigest = @{ Type = "hex"; Length = 64 }
            conventionPlanSha256 = @{ Type = "hex"; Length = 64 }
            factPlanSha256 = @{ Type = "hex"; Length = 64 }
            configSha256 = @{ Type = "hex"; Length = 64 }
            scriptSha256 = @{ Type = "hex"; Length = 64 }
            promptSha256 = @{ Type = "hex"; Length = 64 }
            candidates = @{
                Type = "objectArray"; MaxItems = $MaxCandidateItems
                # Version 3 only: one unreadable semantic field withholds ITS OWN
                # candidate instead of the whole marker. Under version 2 a single
                # bad sub-field discarded every candidate and every rule row
                # beside it, and "nothing came back" is indistinguishable from
                # "there was nothing to find" - which is the one thing this layer
                # must never say by accident.
                ElementFailurePolicy = $(if ($ContractVersion -ge 3) { "drop" } else { "fail" })
                Item = @{
                    Keys = $candidateKeys
                    Fields = @{
                        candidateId = @{ Type = "string"; MaxLength = 64; Pattern = '^[a-z][a-z0-9-]{0,63}$' }
                        category = @{ Type = "exact"; Expected = "convention" }
                        severity = @{ Type = "enum"; Values = @("suggestion", "important") }
                        anchorKind = @{ Type = "enum"; Values = @("changedFile", "prMetadata") }
                        filePath = @{ Type = "string"; MaxLength = 400; AllowEmpty = $true; Pattern = '^/?[\x20-\x21\x23-\x29\x2B-\x39\x3B\x3D\x40-\x5B\x5D-\x7B\x7D-\x7E]*$' }
                        line = @{ Type = "int"; Min = 0; Max = 1000000 }
                        ruleRef = @{ Type = "string"; MaxLength = 5; Pattern = '^rs[0-9]{1,3}$' }
                        primaryTarget = $(if ($ContractVersion -ge 3) {
                                @{
                                    Type = "string"; MaxLength = 24; AllowEmpty = $true
                                    Pattern = '^$|^(prMetadata|cf[0-9]{1,3}:[1-9][0-9]{0,6})$'
                                }
                            }
                            else {
                                @{
                                    Type = "string"; MaxLength = 24
                                    Pattern = '^(prMetadata|cf[0-9]{1,3}:[1-9][0-9]{0,6})$'
                                }
                            })
                        manifestations = @{
                            Type = "string"; MaxLength = 400; AllowEmpty = $true
                            Pattern = $script:ReviewerConventionSpecialistChangedLineListPattern
                        }
                        packName = @{ Type = "string"; MaxLength = 64; Pattern = '^[a-z][a-z0-9-]{0,63}$' }
                        ruleSourceId = @{ Type = "string"; MaxLength = 1100; Pattern = $ascii }
                        ruleSourceRepositoryId = @{ Type = "guid" }
                        ruleSourcePath = @{ Type = "string"; MaxLength = 1024; Pattern = '^/[A-Za-z0-9._ /-]+$' }
                        ruleSourceCommit = @{ Type = "hex"; Length = 40 }
                        ruleSourceSha256 = @{ Type = "hex"; Length = 64 }
                        ruleSection = @{ Type = "string"; MaxLength = 240; Pattern = $ascii; NormalizeTypography = $true }
                        ruleQuote = @{ Type = "string"; MaxLength = 600; Pattern = '^(?=.{8,}$)(?=.*\S)[\x20-\x7E]+$' }
                        diffEvidence = @{ Type = "string"; MaxLength = 1200; Pattern = $ascii; NormalizeTypography = $true }
                        impactCategory = @{ Type = "enum"; Values = $script:ReviewerConventionSpecialistImpactCategories }
                        impact = @{ Type = "string"; MaxLength = 800; Pattern = $ascii; NormalizeTypography = $true }
                        expectedFixOrValidation = @{ Type = "string"; MaxLength = 1000; Pattern = $ascii; NormalizeTypography = $true }
                        siblingStatus = @{ Type = "enum"; Values = @("checked", "notRequired") }
                        siblingEvidence = @{ Type = "string"; MaxLength = 800; AllowEmpty = $true; Pattern = $ascii; NormalizeTypography = $true }
                        siblingNotRequiredReason = @{ Type = "string"; MaxLength = 400; AllowEmpty = $true; Pattern = $ascii; NormalizeTypography = $true }
                        factIds = @{
                            Type = "string"; MaxLength = 600; AllowEmpty = $true
                            Pattern = $factIdPattern
                        }
                        confidence = @{ Type = "enum"; Values = @("low", "medium", "high") }
                        residualRiskSummary = @{ Type = "string"; MaxLength = 800; AllowEmpty = $true; Pattern = $ascii; NormalizeTypography = $true }
                        semanticCandidateVersion = @{ Type = "int"; Min = 2; Max = 2 }
                        changedCodeFix = @{
                            Type = "object"
                            Schema = @{
                                Keys = @("action", "targets", "conventionKey", "valueSource", "evidenceFactIds")
                                Fields = @{
                                    action = @{ Type = "enum"; Values = @("add", "modify", "remove", "rename", "replace", "validate") }
                                    targets = @{
                                        Type = "string"; MaxLength = 600
                                        Pattern = $script:ReviewerConventionSpecialistTargetListPattern
                                    }
                                    conventionKey = @{ Type = "string"; MaxLength = 128; Pattern = '^[A-Za-z_][A-Za-z0-9_.:\-]{0,127}$' }
                                    valueSource = @{ Type = "enum"; Values = @("authoritativeRule", "deterministicFact") }
                                    evidenceFactIds = @{
                                        Type = "string"; MaxLength = 600; AllowEmpty = $true
                                        Pattern = '^(|rf1:[0-9a-f]{64}(,rf1:[0-9a-f]{64}){0,7})$'
                                    }
                                }
                            }
                        }
                        existingDebtFollowUp = @{
                            Type = "object"
                            Schema = @{
                                Keys = @(
                                    "status", "evidenceFactId", "selectorKey", "scopeKind", "scopePath",
                                    "comparableCount", "compliantCount", "action"
                                )
                                Fields = @{
                                    status = @{ Type = "enum"; Values = @("none", "required") }
                                    evidenceFactId = @{ Type = "string"; MaxLength = 69; AllowEmpty = $true; Pattern = '^(|rdf1:[0-9a-f]{64})$' }
                                    selectorKey = @{ Type = "string"; MaxLength = 128; AllowEmpty = $true; Pattern = '^(|[A-Za-z_][A-Za-z0-9_.:-]{0,127})$' }
                                    scopeKind = @{ Type = "enum"; Values = @("", "file") }
                                    scopePath = @{ Type = "string"; MaxLength = 400; AllowEmpty = $true; Pattern = '^/?[\x20-\x21\x23-\x29\x2B-\x39\x3B\x3D\x40-\x5B\x5D-\x7B\x7D-\x7E]*$' }
                                    comparableCount = @{ Type = "int"; Min = 0; Max = 1000000 }
                                    compliantCount = @{ Type = "int"; Min = 0; Max = 1000000 }
                                    action = @{ Type = "enum"; Values = @("", "recordTrackedFollowUp", "linkTrackedFollowUp") }
                                }
                            }
                        }
                    }
                }
            }
            withheld = @{
                Type = "objectArray"; MaxItems = 24
                Item = @{
                    Keys = @("candidateId", "reason", "detail")
                    Fields = @{
                        candidateId = @{ Type = "string"; MaxLength = 64; AllowEmpty = $true; Pattern = '^(|[a-z][a-z0-9-]{0,63})$' }
                        reason = @{ Type = "enum"; Values = $script:ReviewerConventionSpecialistWithheldReasons }
                        detail = @{ Type = "string"; MaxLength = 800; Pattern = $ascii }
                    }
                }
            }
            # One row per REQUESTED convention source. The wrapper knows that
            # set exactly, so this is checkable rather than decorative: a source
            # the model never mentions, mentions twice, or invents is a gap in
            # the accounting, reported as one.
            #
            # A row names its rule by INDEX into the request the wrapper sent
            # (`rs<n>`), not by repeating pack and source id. Source ids run to
            # a full repository path, and repeating one per row would blow the
            # marker's brace-scan window - at which point there is no report at
            # all, because the whole marker falls outside the scan.
            #
            # Lexical accounting remains on construct ids. A separate exact
            # cf<n>:<line> channel covers rule violations on delivered right-hand
            # lines that do not belong to any lexical construct.
            # point, the row must give a VERDICT for every anchor in the kinds
            # it declares: violating, compliant, out of the rule's reach, or
            # unknown, disjoint and covering the set exactly. That is what stops
            # "named parameters: compliant" from meaning "I looked at one call".
            # The wrapper then derives the row's status from those verdicts.
            # Judging which constructs a rule reaches is still the model's job
            # against the rule text; giving each one an answer is not optional.
            ruleCoverage = @{
                Type = "objectArray"; MaxItems = $script:ReviewerConventionSpecialistMaxRuleCoverage
                Item = @{
                    Keys = @(
                        "ruleRef", "ruleSourceSha256", "ruleQuote", "status",
                        "scope", "violatingConstructs", "compliantConstructs",
                        "notInReachConstructs", "unknownConstructs",
                        "violatingChangedFileTargets",
                        "codeEvidence", "siblingStatus", "siblingEvidence",
                        "candidateId", "notes"
                    )
                    Fields = @{
                        ruleRef = @{ Type = "string"; MaxLength = 6; Pattern = '^rs[0-9]{1,3}$' }
                        ruleSourceSha256 = @{ Type = "hex"; Length = 64 }
                        ruleQuote = @{
                            Type = "string"; MaxLength = 200; AllowEmpty = $true
                            # At least eight characters when present, the same
                            # floor a candidate's quote has. A one-character
                            # "quote" satisfies a substring check against almost
                            # any source and so proves nothing about whether the
                            # row read the rule.
                            Pattern = '^(|[\x20-\x7E]{8,})$'
                        }
                        status = @{ Type = "enum"; Values = $script:ReviewerConventionSpecialistCoverageStatuses }
                        scope = @{
                            Type = "string"; MaxLength = 64
                            Pattern = $script:ReviewerConventionSpecialistCoverageScopePattern
                        }
                        # Four disjoint id lists that together must equal every
                        # construct in the sealed table. Scope identifies the
                        # applicable subset; constructs of all other kinds must
                        # be named only as not in reach. This is the whole
                        # mechanism: a row does not assert an outcome for a rule
                        # and then list some ids, it gives a verdict for EVERY
                        # anchor, and the wrapper derives the row's status from
                        # the partition. That is what stops one chosen method
                        # standing in for a rule, and what stops silence reading
                        # as compliance.
                        #
                        # 200 characters each: ranges make a complete list a few
                        # short spans, and the section has to stay well inside
                        # the marker scan window it shares with the candidates.
                        violatingConstructs = @{
                            Type = "string"; MaxLength = 370; AllowEmpty = $true
                            Pattern = $script:ReviewerConventionSpecialistConstructListPattern
                        }
                        compliantConstructs = @{
                            Type = "string"; MaxLength = 370; AllowEmpty = $true
                            Pattern = $script:ReviewerConventionSpecialistConstructListPattern
                        }
                        # Anchors the row examined and judged outside the rule's
                        # reach. Without this the model's only honest options
                        # were to call a production method "checked" against a
                        # rule about tests, or to leave it out and be degraded -
                        # and it kept choosing the second. Narrowing is a real
                        # judgement and deserves somewhere to be written down;
                        # what is NOT allowed is silence.
                        notInReachConstructs = @{
                            Type = "string"; MaxLength = 370; AllowEmpty = $true
                            Pattern = $script:ReviewerConventionSpecialistConstructListPattern
                        }
                        # Anchors the row could not decide about. A first-class
                        # answer, and the only honest one when the source was
                        # not delivered or the rule text does not settle it.
                        unknownConstructs = @{
                            Type = "string"; MaxLength = 370; AllowEmpty = $true
                            Pattern = $script:ReviewerConventionSpecialistConstructListPattern
                        }
                        violatingChangedFileTargets = @{
                            # There can be at most eight candidates in the marker;
                            # eight cf<n>:<line> targets fit within this bound.
                            Type = "string"; MaxLength = 128; AllowEmpty = $true
                            Pattern = $script:ReviewerConventionSpecialistChangedLineListPattern
                        }
                        # No ASCII pattern on the three prose fields, lengths
                        # with real headroom rather than a cap that tracks the
                        # last observed answer by thirty characters, and - since
                        # headroom alone was not enough - permission for the
                        # wrapper to SHORTEN them rather than reject the marker.
                        #
                        # Three times now a correct, complete accounting was
                        # discarded whole - once for evidence twenty-five
                        # characters over, once for a single curly quote inside
                        # a sentence about code, once for a paragraph naming
                        # every construct it had checked - and each time it took
                        # the candidates down with it. A reporting section must
                        # not be able to destroy the findings it reports on, and
                        # a shortened sentence in a preview is a far smaller
                        # loss than an entire pass.
                        #
                        # This is not a loosening of the marker contract. The
                        # marker validator refuses control characters in every
                        # string regardless of pattern, and truncation is opt-in
                        # per field: candidate text, which is rendered into a
                        # pull-request comment, may never be silently altered.
                        # These three appear only in the local preview and the
                        # sealed, non-promotable artifact - which is why the
                        # pattern-free spelling is acceptable here even though a
                        # few non-control separators (U+2028, U+2029) would
                        # survive it. ruleQuote keeps the strict pattern and no
                        # truncation, because it must be an exact substring of
                        # the transported source and the wrapper checks that.
                        codeEvidence = @{ Type = "string"; MaxLength = 280; AllowEmpty = $true; Truncate = $true }
                        siblingStatus = @{ Type = "enum"; Values = @("checked", "notRequired", "unavailable") }
                        siblingEvidence = @{ Type = "string"; MaxLength = 280; AllowEmpty = $true; Truncate = $true }
                        candidateId = @{ Type = "string"; MaxLength = 64; AllowEmpty = $true; Pattern = '^(|[a-z][a-z0-9-]{0,63})$' }
                        notes = @{ Type = "string"; MaxLength = 280; AllowEmpty = $true; Truncate = $true }
                    }
                }
            }
            residualRisks = @{
                Type = "objectArray"; MaxItems = 12
                Item = @{
                    Keys = @("text")
                    Fields = @{ text = @{ Type = "string"; MaxLength = 800; Pattern = $ascii; NormalizeTypography = $true } }
                }
            }
            nonce = @{ Type = "exact"; Expected = $ExpectedNonce }
        }
    }
}

function ConvertFrom-ReviewerConventionSpecialistResultMarkerOutcome {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$StdOutText,
        [Parameter(Mandatory)][hashtable]$Schema,
        [int]$ScanWindowChars = 327680,
        [ValidateSet(2, 3, 4)][int]$ContractVersion = 2
    )
    $markerPrefix = Get-ReviewerConventionSpecialistMarkerPrefixForVersion -ContractVersion $ContractVersion
    $normalizer = {
        param($MarkerCandidate)
        $normalizedFields = [System.Collections.Generic.List[object]]::new()
        if ($ContractVersion -eq 4) {
            # Prose is explanatory. It is the one thing in this contract that a
            # reader would merely find less useful if it were missing, and the
            # only thing whose absence costs nothing - so it must never be able
            # to cost a VERDICT. The schema already isolates it in its own
            # `drop` array; this adds the two repairs a schema cannot express:
            # supplying the array when it is absent entirely, and supplying the
            # two sentence fields when a note carries only one of them.
            #
            # Ten trials lost correct findings to fields the model had to author
            # exactly. Prose is the last one left, and this is why it cannot join
            # them.
            $assessmentsProperty = $MarkerCandidate.PSObject.Properties['assessments']
            # A residual risk is a caveat the model writes in prose. Two of the
            # five starts in the final qualification series were spent on markers
            # refused whole because these arrived as bare strings rather than
            # `{text}` objects - nine correct verdicts discarded over the shape
            # of a footnote. The obvious intent is recoverable, so recover it.
            $risksProperty = $MarkerCandidate.PSObject.Properties['residualRisks']
            if (-not $risksProperty -or $risksProperty.Value -isnot [System.Object[]]) {
                $from = $(if (-not $risksProperty) { 'absent' } else { 'notAnArray' })
                Add-Member -InputObject $MarkerCandidate -NotePropertyName 'residualRisks' `
                    -NotePropertyValue @() -Force
                [void]$normalizedFields.Add([ordered]@{
                        Field = 'residualRisks'
                        From = $from
                        To = 'emptyArray'
                        OriginalTypedReason = ("The non-eligibility-critical key 'residualRisks' was " +
                            "unreadable ($from); no verdict is affected.")
                    })
            }
            else {
                $risks = [System.Object[]]$risksProperty.Value
                for ($riskIndex = 0; $riskIndex -lt $risks.Count; $riskIndex++) {
                    if ($risks[$riskIndex] -isnot [string]) { continue }
                    $field = "residualRisks[$riskIndex]"
                    $risks[$riskIndex] = [pscustomobject]@{ text = [string]$risks[$riskIndex] }
                    [void]$normalizedFields.Add([ordered]@{
                            Field = $field
                            From = 'bareString'
                            To = 'textObject'
                            OriginalTypedReason = ("The marker wrote '$field' as a bare string rather than " +
                                "an object with a 'text' key; it was read as that text.")
                        })
                }
            }
            if ($assessmentsProperty -and $assessmentsProperty.Value -is [System.Object[]]) {
                $rows = [System.Object[]]$assessmentsProperty.Value
                for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex++) {
                    $row = $rows[$rowIndex]
                    if ($row -isnot [System.Management.Automation.PSCustomObject]) { continue }
                    # Absent, `null`, or any other non-array shape are the SAME
                    # repair. A `notes` value that is not an array fails the
                    # field rule, and because a bad field fails its whole
                    # element, that would drop the entire row - every construct
                    # verdict in it - over a sentence list. `"notes": null` is
                    # what a model most often writes for "no notes", so the one
                    # surface this contract promised could never cost a finding
                    # would have been the easiest way to lose one.
                    $notesProperty = $row.PSObject.Properties['notes']
                    if (-not $notesProperty -or $notesProperty.Value -isnot [System.Object[]]) {
                        $field = "assessments[$rowIndex].notes"
                        $from = $(if (-not $notesProperty) { 'absent' } else { 'notAnArray' })
                        Add-Member -InputObject $row -NotePropertyName 'notes' `
                            -NotePropertyValue @() -Force
                        [void]$normalizedFields.Add([ordered]@{
                                Field = $field
                                From = $from
                                To = 'emptyArray'
                                OriginalTypedReason = ("The non-eligibility-critical key '$field' was " +
                                    "unreadable ($from); the row's verdicts are unaffected.")
                            })
                        continue
                    }
                    $notes = [System.Object[]]$notesProperty.Value
                    for ($noteIndex = 0; $noteIndex -lt $notes.Count; $noteIndex++) {
                        $note = $notes[$noteIndex]
                        if ($note -isnot [System.Management.Automation.PSCustomObject]) { continue }
                        foreach ($name in @('rationale', 'suggestion')) {
                            if ($note.PSObject.Properties[$name]) { continue }
                            $field = "assessments[$rowIndex].notes[$noteIndex].$name"
                            Add-Member -InputObject $note -NotePropertyName $name `
                                -NotePropertyValue '' -Force
                            [void]$normalizedFields.Add([ordered]@{
                                    Field = $field
                                    From = 'absent'
                                    To = 'emptyString'
                                    OriginalTypedReason = ("The marker omitted the non-eligibility-critical " +
                                        "key '$field'; the construct's verdict is unaffected.")
                                })
                        }
                    }
                }
            }
            return @{ Value = $MarkerCandidate; NormalizedFields = @($normalizedFields) }
        }
        $candidatesProperty = $MarkerCandidate.PSObject.Properties['candidates']
        if ($candidatesProperty -and $candidatesProperty.Value -is [System.Object[]]) {
            $candidates = [System.Object[]]$candidatesProperty.Value
            for ($index = 0; $index -lt $candidates.Count; $index++) {
                $candidateItem = $candidates[$index]
                if ($candidateItem -isnot [System.Management.Automation.PSCustomObject]) { continue }
                if ($ContractVersion -eq 3) {
                    # `siblingNotRequiredReason` is the reason sibling evidence
                    # was NOT required. When `siblingStatus` is `checked` there
                    # is no such reason - the wrapper's own validation below
                    # insists the field be empty in that case - so requiring the
                    # model to emit an empty string for it is asking it to state
                    # something it has already stated. Three real-model trials
                    # lost an otherwise correct nine-declaration finding to
                    # exactly that omission.
                    #
                    # Defaulted only for `checked`. For `notRequired` the reason
                    # is real content the wrapper cannot know, so an omission
                    # there stays a refusal rather than becoming a silent blank.
                    $statusProperty = $candidateItem.PSObject.Properties['siblingStatus']
                    if ($statusProperty -and [string]$statusProperty.Value -ceq 'checked' -and
                        -not $candidateItem.PSObject.Properties['siblingNotRequiredReason']) {
                        $reasonField = "candidates[$index].siblingNotRequiredReason"
                        Add-Member -InputObject $candidateItem -NotePropertyName 'siblingNotRequiredReason' `
                            -NotePropertyValue '' -Force
                        [void]$normalizedFields.Add([ordered]@{
                                Field = $reasonField
                                From = 'absentUnderCheckedSiblingStatus'
                                To = 'emptyString'
                                OriginalTypedReason = "The marker omitted the required key '$reasonField'."
                            })
                    }
                }
                $fixProperty = $candidateItem.PSObject.Properties['changedCodeFix']
                if (-not $fixProperty -or
                    $fixProperty.Value -isnot [System.Management.Automation.PSCustomObject]) { continue }
                $evidenceProperty = $fixProperty.Value.PSObject.Properties['evidenceFactIds']
                if (-not $evidenceProperty -or $evidenceProperty.Value -isnot [System.Object[]] -or
                    ([System.Object[]]$evidenceProperty.Value).Count -ne 0) { continue }
                $field = "candidates[$index].changedCodeFix.evidenceFactIds"
                $evidenceProperty.Value = ''
                [void]$normalizedFields.Add([ordered]@{
                        Field = $field
                        From = 'emptyJsonArray'
                        To = 'emptyString'
                        OriginalTypedReason = "The marker field '$field' failed its typed schema rule."
                    })
            }
        }
        return @{ Value = $MarkerCandidate; NormalizedFields = @($normalizedFields) }
    }
    return ConvertFrom-AgentResultMarkerOutcome -StdOutText $StdOutText `
        -MarkerPrefix $markerPrefix -Schema $Schema `
        -ScanWindowChars $ScanWindowChars -CandidateNormalizer $normalizer
}

function Test-ReviewerConventionSpecialistBinding {
    param(
        [Parameter(Mandatory)][hashtable]$Marker,
        [Parameter(Mandatory)][int]$PrId,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$TargetCommit,
        [Parameter(Mandatory)][string]$ChangeSetDigest,
        [Parameter(Mandatory)][string]$ConventionPlanSha256,
        [Parameter(Mandatory)][string]$FactPlanSha256,
        [Parameter(Mandatory)][string]$ConfigSha256,
        [Parameter(Mandatory)][string]$ScriptSha256,
        [Parameter(Mandatory)][string]$PromptSha256
    )
    return (
        [int]$Marker.prId -eq $PrId -and
        [string]::Equals([string]$Marker.repositoryId, $RepositoryId, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$Marker.reviewedSourceCommit, $SourceCommit, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$Marker.targetCommit, $TargetCommit, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$Marker.changeSetDigest, $ChangeSetDigest, [StringComparison]::Ordinal) -and
        [string]::Equals([string]$Marker.conventionPlanSha256, $ConventionPlanSha256, [StringComparison]::Ordinal) -and
        [string]::Equals([string]$Marker.factPlanSha256, $FactPlanSha256, [StringComparison]::Ordinal) -and
        [string]::Equals([string]$Marker.configSha256, $ConfigSha256, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$Marker.scriptSha256, $ScriptSha256, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$Marker.promptSha256, $PromptSha256, [StringComparison]::OrdinalIgnoreCase)
    )
}

function Test-ReviewerConventionSpecialistVoteText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return $Text -match '(?i)(recommendedVote|approveWithSuggestions|waitForAuthor|approvedVote|"vote"\s*:)'
}

function Get-ReviewerConventionSpecialistFailureReason {
    param(
        [bool]$TimedOut,
        [int]$ExitCode,
        [bool]$MarkerValid,
        [int]$TimeoutSeconds = 0
    )
    if ($TimedOut) { return "Convention specialist timed out after ${TimeoutSeconds}s." }
    if ($ExitCode -ne 0) { return "Convention specialist exited $ExitCode." }
    if (-not $MarkerValid) {
        # Name the length case explicitly. The marker is recovered from the
        # transcript by a brace scan with a hard character ceiling, so a marker
        # that is merely too long is indistinguishable from an absent one - and
        # the accounting rows are the part most likely to push it over. An
        # operator reading only "missing or invalid" would look for the wrong
        # thing.
        return ("Convention specialist produced a missing or invalid result marker. " +
            "A marker that is well formed but too long reaches this the same way, " +
            "so check the transcript for an over-length ruleCoverage or candidates array.")
    }
    return ""
}

function ConvertTo-ReviewerConventionSpecialistToolIdentity {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    switch -Regex ($Name) {
        '^(?i:ado\(repo_pull_request\)|ado-repo_pull_request|ado_repo_pull_request|repo_pull_request|mcp__ado__repo_pull_request)$' {
            return "ado(repo_pull_request)"
        }

        '^(?i:ado\(repo_file\)|ado-repo_file|ado_repo_file|repo_file|mcp__ado__repo_file)$' {
            return "ado(repo_file)"
        }
        default { return "" }
    }
}

function Format-ReviewerConventionSpecialistAuditName {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $Name.ToCharArray()) {
        if ([int]$character -ge 0x20 -and [int]$character -le 0x7e) {
            [void]$builder.Append($character)
        }
        else {
            [void]$builder.Append("?")
        }
        if ($builder.Length -ge 120) { break }
    }
    $text = ([regex]::Replace($builder.ToString(), ' +', ' ')).Trim()
    if ($Name.Length -gt 120) {
        if ($text.Length -gt 116) { $text = $text.Substring(0, 116) }
        $text += "..."
    }
    if (-not $text) { return "<unparsed>" }
    return $text
}

function Test-ReviewerConventionSpecialistPlanBinding {
    param(
        [Parameter(Mandatory)]$ConventionPlan,
        [Parameter(Mandatory)]$FactPlan,
        [Parameter(Mandatory)][int]$PrId,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$TargetCommit,
        [Parameter(Mandatory)][string]$ChangeSetDigest,
        [Parameter(Mandatory)][string]$ConfigSha256,
        [Parameter(Mandatory)][string]$ScriptSha256
    )
    if ([string](Get-ReviewerConventionSpecialistValue $ConventionPlan "status" "") -cne "ready") {
        throw "Convention specialist requires a ready convention plan."
    }
    foreach ($pair in @(
            @("pullRequestId", [int]$PrId), @("repositoryId", $RepositoryId), @("project", $Project),
            @("sourceCommit", $SourceCommit), @("targetCommit", $TargetCommit),
            @("changeSetDigest", $ChangeSetDigest), @("configSha256", $ConfigSha256),
            @("scriptSha256", $ScriptSha256)
        )) {
        $actual = Get-ReviewerConventionSpecialistValue $ConventionPlan ([string]$pair[0])
        if ($actual -is [string]) {
            if (-not [string]::Equals([string]$actual, [string]$pair[1], [StringComparison]::OrdinalIgnoreCase)) {
                throw "Convention plan binding '$($pair[0])' is stale."
            }
        }
        elseif ([long]$actual -ne [long]$pair[1]) { throw "Convention plan binding '$($pair[0])' is stale." }
    }
    $factStatus = [string](Get-ReviewerConventionSpecialistValue $FactPlan "status" "")
    if (@("complete", "partial") -cnotcontains $factStatus) {
        throw "Convention specialist requires a complete or partial verified fact plan."
    }
    if (-not (Test-ReviewerFactPlanIntegrity -Plan $FactPlan)) {
        throw "Convention specialist fact plan failed integrity validation."
    }
    $binding = Get-ReviewerConventionSpecialistValue $FactPlan "binding"
    foreach ($pair in @(
            @("pullRequestId", [int]$PrId), @("repositoryId", $RepositoryId), @("project", $Project),
            @("sourceCommit", $SourceCommit), @("targetCommit", $TargetCommit),
            @("changeSetDigest", $ChangeSetDigest)
        )) {
        $actual = Get-ReviewerConventionSpecialistValue $binding ([string]$pair[0])
        if ($actual -is [string]) {
            if (-not [string]::Equals([string]$actual, [string]$pair[1], [StringComparison]::OrdinalIgnoreCase)) {
                throw "Fact plan binding '$($pair[0])' is stale."
            }
        }
        elseif ([long]$actual -ne [long]$pair[1]) { throw "Fact plan binding '$($pair[0])' is stale." }
    }
    $hashes = Get-ReviewerConventionSpecialistValue $FactPlan "hashes"
    if (-not [string]::Equals(
            [string](Get-ReviewerConventionSpecialistValue $hashes "configSha256" ""),
            $ConfigSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Fact plan config binding is stale."
    }
    $closure = @(Get-ReviewerConventionSpecialistValue $hashes "scriptClosure" @())
    $wrapper = @($closure | Where-Object {
            [string](Get-ReviewerConventionSpecialistValue $_ "path" "") -ceq "Start-ReviewerAgent.ps1"
        })
    if ($wrapper.Count -ne 1 -or -not [string]::Equals(
            [string](Get-ReviewerConventionSpecialistValue $wrapper[0] "sha256" ""),
            $ScriptSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Fact plan script binding is stale."
    }
    return $true
}

function Get-ReviewerConventionSpecialistChangedFileIndex {
    <#
        The changed-file list the model is given, in one fixed order, so that a
        coverage row can name an anchor as cf<n>:<line> instead of repeating a
        path. Sorted ordinally by path: the order has to be a function of the
        change set alone, or two runs over the same pull request would number
        the same file differently and no anchor would be comparable.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ChangeEntries,
        [hashtable]$RightHandRangesByPath = @{}
    )
    $pathSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($ChangeEntries)) {
        if ([string](Get-ReviewerConventionSpecialistValue $entry "Role" "") -cne "current") { continue }
        $path = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
            [string](Get-ReviewerConventionSpecialistValue $entry "Path" ""))
        if (-not $path) { throw "Changed-file index contains an invalid current repository path." }
        if (-not $pathSet.Add($path)) {
            throw "Changed-file index contains ambiguous duplicate path identity '$path'."
        }
    }
    $sorted = [string[]]@($pathSet)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $canonicalRanges = ConvertTo-ReviewerConventionSpecialistRangesByPath `
        -RightHandRangesByPath $RightHandRangesByPath
    $index = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $ranges = @()
        if ($canonicalRanges.ContainsKey($sorted[$i])) {
            $ranges = @($canonicalRanges[$sorted[$i]] | ForEach-Object {
                    [pscustomobject][ordered]@{
                        startLine = [int](Get-ReviewerConventionSpecialistValue $_ "startLine" 0)
                        endLine = [int](Get-ReviewerConventionSpecialistValue $_ "endLine" 0)
                    }
                })
        }
        [void]$index.Add([pscustomobject][ordered]@{
                anchorId = "cf$i"
                path = $sorted[$i]
                rightHandRanges = $ranges
            })
    }
    return , $index.ToArray()
}

function Get-ReviewerConventionSpecialistRoutedPathsByPack {
    <#
        Which changed files each selected pack was actually routed to, from the
        signed convention plan's own routing evidence.

        This is the whole basis of the version 4 in-scope set, and it costs no
        new pack metadata: `matchedPaths` is already the record of which globs
        matched which changed path, written when the pack was selected.

        A selected pack with NO routing evidence is reported as UNRESOLVED, not
        as an empty set. Empty would mean "this rule reaches nothing here", which
        is a substantive claim; absent means the wrapper cannot say. Treating the
        second as the first would silently excuse every rule in a plan that lost
        its routing, which is precisely the silent narrowing this contract exists
        to prevent.
    #>
    param([Parameter(Mandatory)]$ConventionPlan)
    $byPack = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($pack in @(Get-ReviewerConventionSpecialistValue $ConventionPlan "selectedPacks" @())) {
        $name = [string](Get-ReviewerConventionSpecialistValue $pack "name" "")
        if (-not $name -or $byPack.ContainsKey($name)) { continue }
        $matched = @(Get-ReviewerConventionSpecialistValue $pack "matchedPaths" @())
        $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $resolved = $true
        if (@($matched).Count -eq 0) { $resolved = $false }
        foreach ($match in @($matched)) {
            $path = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
                [string](Get-ReviewerConventionSpecialistValue $match "path" ""))
            # An unreadable routing entry is not a smaller route; it is a route
            # the wrapper cannot vouch for.
            if (-not $path) { $resolved = $false; continue }
            [void]$paths.Add($path)
        }
        $byPack[$name] = @{ Paths = $paths; Resolved = $resolved }
    }
    return $byPack
}

function Get-ReviewerConventionSpecialistRuleRequest {
    <#
        The exact accounting the wrapper will reconcile against: one requested
        row per transported source, in a fixed ordinal order, each addressed by
        a short `rs<n>` reference.

        Capped. The marker's brace-scan window is shared with the candidate
        array, so asking for more rows than the schema admits would not produce
        a longer report - it would produce none, because the whole marker would
        fail validation. When the transported set is larger than the cap the
        remainder is reported as unaccounted BY CONSTRUCTION rather than
        quietly sampled.

        Under version 4 each row also carries the EXACT construct id set the
        model owes a verdict for. The model never computes that set: five of ten
        qualification runs lost their accounting to a set-complement the wrapper
        could have done itself, so it now does.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ResolvedSources,
        [AllowEmptyCollection()][object[]]$Constructs = @(),
        [ValidateSet(2, 3, 4)][int]$ContractVersion = 2,
        # Version 4 only. The signed plan's routing evidence decides which
        # changed files each rule reaches, and therefore which constructs its row
        # owes a verdict for.
        $ConventionPlan = $null,
        [int]$MaxRows = $script:ReviewerConventionSpecialistMaxRuleCoverage
    )
    # Ordinal, not Sort-Object. This order does not merely number the rows: it
    # decides WHICH rules are requested at all when the transported set is
    # larger than the cap. A culture-sensitive comparison would mean the same
    # set of rules is accounted for differently on two machines, which is the
    # one thing an accounting section may not do.
    $keyed = [System.Collections.Generic.List[object]]::new()
    foreach ($source in @($ResolvedSources)) {
        $sourceKey = "{0}/{1}" -f `
            [string](Get-ReviewerConventionSpecialistValue $source "PackName" ""),
        [string](Get-ReviewerConventionSpecialistValue $source "SourceId" "")
        [void]$keyed.Add(@{ Key = $sourceKey; Source = $source })
    }
    $keys = [string[]]@(@($keyed) | ForEach-Object { [string]$_.Key })
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $ordered = [System.Collections.Generic.List[object]]::new()
    $taken = [System.Collections.Generic.List[object]]::new()
    foreach ($key in $keys) {
        foreach ($entry in $keyed) {
            if ([string]$entry.Key -cne $key) { continue }
            if ($taken.Contains($entry)) { continue }
            [void]$taken.Add($entry)
            [void]$ordered.Add($entry.Source)
            break
        }
    }
    $requested = [System.Collections.Generic.List[object]]::new()
    $unrequested = [System.Collections.Generic.List[string]]::new()
    $knownDeclarationIds = [string[]]@($Constructs | Where-Object {
            [string](Get-ReviewerConventionSpecialistValue $_ "kind" "") -ceq "declaration" -and
            [string](Get-ReviewerConventionSpecialistValue $_ "status" "known") -ceq "known"
        } | ForEach-Object { [string](Get-ReviewerConventionSpecialistValue $_ "constructId" "") } |
        Where-Object { $_ })
    $knownDeclarationRanges = ConvertTo-ReviewerConventionSpecialistConstructIdRanges -Ids $knownDeclarationIds
    # Version 4: the id set each rule owes a verdict for, keyed by pack. Built
    # once, because every row of the same pack shares it. Materialized into a
    # local dictionary rather than bound straight to the helper's return, so the
    # lookups below index something this scope owns.
    $routedByPack = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    if ($ContractVersion -eq 4 -and $null -ne $ConventionPlan) {
        foreach ($routed in (Get-ReviewerConventionSpecialistRoutedPathsByPack `
                    -ConventionPlan $ConventionPlan).GetEnumerator()) {
            $routedByPack[[string]$routed.Key] = $routed.Value
        }
    }
    # Enumeration order is the construct id order the wrapper assigned, so the
    # in-scope list a model receives is stable between runs on the same input.
    $orderedConstructs = @($Constructs | Where-Object {
            [string](Get-ReviewerConventionSpecialistValue $_ "constructId" "")
        })
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $key = "{0}/{1}" -f `
            [string](Get-ReviewerConventionSpecialistValue $ordered[$i] "PackName" ""),
        [string](Get-ReviewerConventionSpecialistValue $ordered[$i] "SourceId" "")
        if ($i -ge $MaxRows) { [void]$unrequested.Add($key); continue }
        $packDeclarationEvidence = [string](Get-ReviewerConventionSpecialistValue $ordered[$i] "PackDeclarationEvidence" "")
        if (-not $packDeclarationEvidence) {
            $packDeclarationEvidence = [string](Get-ReviewerConventionSpecialistValue $ordered[$i] "declarationEvidence" "")
        }
        if (-not $packDeclarationEvidence) {
            $packDeclarationEvidence = [string](Get-ReviewerConventionSpecialistValue $ordered[$i] "DeclarationEvidence" "")
        }
        $siblingEvidenceRequired = -not ($ContractVersion -ge 3 -and $packDeclarationEvidence -ceq "local")
        $row = [ordered]@{
                ruleRef = "rs$i"
                packName = [string](Get-ReviewerConventionSpecialistValue $ordered[$i] "PackName" "")
                ruleSourceId = [string](Get-ReviewerConventionSpecialistValue $ordered[$i] "SourceId" "")
                ruleSourceSha256 = [string](Get-ReviewerConventionSpecialistValue $ordered[$i] "Sha256" "")
                source = $ordered[$i]
            }
        if ($ContractVersion -ge 3) {
            $row.Add("siblingEvidenceRequired", [bool]$siblingEvidenceRequired)
            $row.Add("locallyAdjudicableConstructs", $(if ($siblingEvidenceRequired) { "" } else { $knownDeclarationRanges }))
        }
        if ($ContractVersion -eq 4) {
            $packName = [string](Get-ReviewerConventionSpecialistValue $ordered[$i] "PackName" "")
            $routed = $null
            if ($routedByPack.ContainsKey($packName)) { $routed = $routedByPack[$packName] }
            $inScopeIds = [System.Collections.Generic.List[string]]::new()
            # No routing evidence is UNRESOLVED, never an empty scope. An empty
            # scope says the rule reaches nothing in this change set; unresolved
            # says the wrapper cannot tell. Only the first is an answer.
            $inScopeResolved = ($null -ne $routed -and [bool]$routed.Resolved)
            if ($inScopeResolved) {
                foreach ($construct in $orderedConstructs) {
                    $constructPath = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
                        [string](Get-ReviewerConventionSpecialistValue $construct "path" ""))
                    if (-not $constructPath -or -not $routed.Paths.Contains($constructPath)) { continue }
                    [void]$inScopeIds.Add([string](Get-ReviewerConventionSpecialistValue $construct "constructId" ""))
                }
            }
            # A rule whose routed set is larger than one row can carry cannot be
            # answered completely, and a partial answer is exactly the silent
            # narrowing this contract refuses. Say so instead of sampling.
            if ($inScopeIds.Count -gt $script:ReviewerConventionSpecialistMaxConstructAssessments) {
                $inScopeResolved = $false
                $inScopeIds.Clear()
            }
            $row.Add("inScopeResolved", [bool]$inScopeResolved)
            $row.Add("inScopeConstructIds", [string[]]@($inScopeIds.ToArray()))
            $row.Add("inScopeConstructs", (ConvertTo-ReviewerConventionSpecialistConstructIdRanges `
                        -Ids ([string[]]@($inScopeIds.ToArray()))))
        }
        [void]$requested.Add([pscustomobject]$row)
    }
    return @{ Requested = $requested.ToArray(); Unrequested = @($unrequested.ToArray()) }
}

function Resolve-ReviewerConventionSpecialistRuleCoverage {
    <#
        Reconciles the model's rule accounting against the request the WRAPPER
        sent. Pure, and deliberately powerless: it can mark the accounting
        incomplete, and it can record that a claimed violation was never emitted
        as a candidate, but it can neither create a candidate nor widen one.
        Everything a reader would act on still has to come from candidates[],
        through cross-verification, through the gate.

        Degrades rather than throws. A specialist run that found something real
        and then miscounted its own checklist is still worth reading; losing it
        entirely would trade a recall improvement for a recall regression.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ResolvedSources,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AcceptedCandidates,
        # The constructs the wrapper enumerated from the change set. Every row
        # has to account for every one; scope only identifies the applicable
        # subset that may carry a verdict other than not-in-reach.
        [AllowEmptyCollection()][object[]]$Constructs = @(),
        [AllowEmptyCollection()][object[]]$ChangedFileAnchors = @(),
        # True when the enumeration itself was incomplete - a cap was hit, or a
        # file could not be lexed to the end. An accounting that fully covers a
        # construct set that is missing entries is not complete, and saying so
        # is the difference between this section meaning something and not.
        [bool]$ConstructsIncomplete = $false,
        # Candidate ids the wrapper already rejected. A row that links to one of
        # these is not an unreported violation - it is a reported one that did
        # not survive validation, and the withheld list already says so. Adding
        # a second entry for it would double-count the same event.
        [AllowEmptyCollection()][string[]]$WithheldCandidateIds = @()
    )
    $request = Get-ReviewerConventionSpecialistRuleRequest -ResolvedSources $ResolvedSources
    $expected = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($request.Requested)) { $expected.Add([string]$entry.ruleRef, $entry) }

    $constructById = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $idsByKind = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($kind in $script:ReviewerConventionSpecialistConstructKinds) {
        $idsByKind[$kind] = [System.Collections.Generic.List[string]]::new()
    }
    foreach ($construct in @($Constructs)) {
        $id = [string](Get-ReviewerConventionSpecialistValue $construct "constructId" "")
        if (-not $id -or $constructById.ContainsKey($id)) { continue }
        $kind = [string](Get-ReviewerConventionSpecialistValue $construct "kind" "")
        if (-not $idsByKind.ContainsKey($kind)) { continue }
        $constructById.Add($id, $construct)
        [void]$idsByKind[$kind].Add($id)
    }
    $changedLineAnchors = [System.Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::Ordinal)
    foreach ($anchor in @($ChangedFileAnchors)) {
        $anchorId = [string](Get-ReviewerConventionSpecialistValue $anchor "anchorId" "")
        $anchorPath = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
            [string](Get-ReviewerConventionSpecialistValue $anchor "path" ""))
        if ($anchorId -cnotmatch '^cf[0-9]+$' -or -not $anchorPath) {
            throw "Changed-file line-target table contains a malformed anchor."
        }
        if ($changedLineAnchors.ContainsKey($anchorId)) {
            throw "Changed-file line-target table contains duplicate anchor '$anchorId'."
        }
        $ranges = [System.Collections.Generic.List[object]]::new()
        foreach ($range in @(Get-ReviewerConventionSpecialistValue $anchor "rightHandRanges" @())) {
            $startLine = [int](Get-ReviewerConventionSpecialistValue $range "startLine" 0)
            $endLine = [int](Get-ReviewerConventionSpecialistValue $range "endLine" 0)
            if ($startLine -lt 1 -or $endLine -lt $startLine) {
                throw "Changed-file line-target table contains a malformed right-hand range."
            }
            [void]$ranges.Add([pscustomobject]@{ startLine = $startLine; endLine = $endLine })
        }
        $changedLineAnchors.Add($anchorId, [pscustomobject]@{
                path = $anchorPath; ranges = $ranges.ToArray()
            })
    }

    $candidateIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $candidateAnchors = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $candidateAnchorKinds = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $candidateRuleKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($candidate in @($AcceptedCandidates)) {
        $candidateId = [string](Get-ReviewerConventionSpecialistValue $candidate "candidateId" "")
        [void]$candidateIds.Add($candidateId)
        $candidateAnchorKinds[$candidateId] = [string](Get-ReviewerConventionSpecialistValue `
                $candidate "anchorKind" "")
        $candidateAnchors[$candidateId] = "{0}|{1}" -f `
            (ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
                [string](Get-ReviewerConventionSpecialistValue $candidate "filePath" ""))),
        ([int](Get-ReviewerConventionSpecialistValue $candidate "line" 0))
        [void]$candidateRuleKeys.Add(("{0}/{1}" -f `
                [string](Get-ReviewerConventionSpecialistValue $candidate "packName" ""),
                [string](Get-ReviewerConventionSpecialistValue $candidate "ruleSourceId" "")))
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $duplicates = [System.Collections.Generic.List[string]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    $normalized = [System.Collections.Generic.List[object]]::new()
    $unemitted = [System.Collections.Generic.List[object]]::new()

    foreach ($row in @($Rows)) {
        # Lowercased for the same reason the scope and the id lists are: the
        # marker's pattern check is case-insensitive, so `RS0` validates and
        # then misses the ordinal lookup, costing a whole rule its accounting.
        $ruleRef = ([string](Get-ReviewerConventionSpecialistValue $row "ruleRef" "")).ToLowerInvariant()
        if (-not $expected.ContainsKey($ruleRef)) { [void]$unknown.Add($ruleRef); continue }
        if (-not $seen.Add($ruleRef)) { [void]$duplicates.Add($ruleRef); continue }

        $entry = $expected[$ruleRef]
        $source = $entry.source
        $ruleKey = "{0}/{1}" -f [string]$entry.packName, [string]$entry.ruleSourceId
        $status = [string](Get-ReviewerConventionSpecialistValue $row "status" "unknown")
        $degradedReason = ""
        # Provenance first, and first-writer-wins: a row that is wrong in more
        # than one way is explained by the WORST thing wrong with it, not by
        # whichever check happened to run last.
        if (-not [string]::Equals(
                [string](Get-ReviewerConventionSpecialistValue $row "ruleSourceSha256" ""),
                [string](Get-ReviewerConventionSpecialistValue $source "Sha256" ""),
                [StringComparison]::OrdinalIgnoreCase)) {
            $status = "unknown"
            $degradedReason = "the row cited a rule-source hash that is not the transported one"
        }
        $scope = [string](Get-ReviewerConventionSpecialistValue $row "scope" "none")
        # Lowercased before the lookup. The marker schema matches its patterns
        # case-insensitively, so `Invocation` gets past validation and then
        # misses the ordinal kind lookup - degrading a row that was actually
        # right over one capital letter. The kinds are lowercase by definition,
        # so folding here costs nothing and cannot admit a kind that does not
        # exist.
        $scopeKinds = @(@($scope -split ',') |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Where-Object { $_ -and $_ -cne "none" })

        # THE PARTITION. A row does not assert an outcome for a rule and then
        # name a few ids; it gives a verdict for EVERY sealed anchor. The four
        # lists must be disjoint and cover that full universe exactly. Scope is
        # a separate applicable subset: anchors outside it belong only in
        # notInReachConstructs. The wrapper then DERIVES the row's status from
        # the partition rather than taking the model's word for it.
        #
        # That is the whole mechanism. One chosen method can no longer stand in
        # for a rule, silence can no longer read as compliance, and the status a
        # reader sees is a function of the anchors rather than of a sentence.
        $partition = [ordered]@{}
        $partitionOk = $true
        $partitionDuplicated = @()
        foreach ($field in @("violatingConstructs", "compliantConstructs", "notInReachConstructs", "unknownConstructs")) {
            $expanded = Expand-ReviewerConventionSpecialistConstructIds `
                -Text ([string](Get-ReviewerConventionSpecialistValue $row $field "")) `
                -MaxIds ($constructById.Count + 16)
            if (-not $expanded.Ok) { $partitionOk = $false }
            foreach ($dup in @($expanded.Duplicated)) {
                if ($partitionDuplicated -cnotcontains $dup) { $partitionDuplicated += $dup }
            }
            $partition[$field] = @($expanded.Ids)
        }
        $violating = @($partition["violatingConstructs"])
        $compliantIds = @($partition["compliantConstructs"])
        $notInReach = @($partition["notInReachConstructs"])
        $unknownIds = @($partition["unknownConstructs"])
        $violatingChangedLines = @(([string](Get-ReviewerConventionSpecialistValue `
                    $row "violatingChangedFileTargets" "")) -split ',' | Where-Object { $_ })
        $lineTargetSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $resolvedLineTargets = [System.Collections.Generic.Dictionary[string, string]]::new(
            [StringComparer]::Ordinal)
        $invalidLineTargets = [System.Collections.Generic.List[string]]::new()
        foreach ($target in $violatingChangedLines) {
            $parts = @(([string]$target) -split ':')
            $valid = ($lineTargetSet.Add([string]$target) -and $parts.Count -eq 2 -and
                $parts[0] -cmatch '^cf[0-9]+$' -and $parts[1] -cmatch '^[1-9][0-9]*$' -and
                $changedLineAnchors.ContainsKey([string]$parts[0]))
            $line = $(if ($valid) { [int]$parts[1] } else { 0 })
            if ($valid) {
                $anchor = $changedLineAnchors[[string]$parts[0]]
                $valid = @($anchor.ranges | Where-Object {
                        $line -ge [int]$_.startLine -and $line -le [int]$_.endLine
                    }).Count -gt 0
                if ($valid) {
                    $resolvedLineTargets.Add([string]$target, "$([string]$anchor.path)|$line")
                }
            }
            if (-not $valid) { [void]$invalidLineTargets.Add([string]$target) }
        }
        if ($invalidLineTargets.Count -gt 0) {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = "the row named duplicate or unavailable changed-file line targets: " +
                    (@($invalidLineTargets | Select-Object -First 20) -join ",")
            }
        }
        if (-not $partitionOk) {
            $status = "unknown"
            if (-not $degradedReason) { $degradedReason = "the row wrote a construct range the wrapper could not read" }
        }
        # A repeat inside one list is as much a broken cover as a repeat across
        # two. The expander refuses to collapse it quietly, so say so here.
        if ($partitionDuplicated.Count -gt 0) {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = "the row named $(($partitionDuplicated | Select-Object -First 4) -join ', ') twice in one verdict list"
            }
        }

        # Reject a partition that is larger than the anchor set before doing
        # anything quadratic with it. Ten rows writing four thousand ids each
        # took twelve seconds in the scans below and wrote two megabytes of ids
        # into the sealed artifact; the row is wrong either way, so it should be
        # wrong cheaply.
        $partitionCeiling = $constructById.Count + 16
        $partitionSize = 0
        foreach ($field in @($partition.Keys)) { $partitionSize += @($partition[$field]).Count }
        if ($partitionSize -gt $partitionCeiling) {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = "the row gave $partitionSize verdicts over $($constructById.Count) anchors"
            }
            # The lists stay. Emptying them here erased the one record of what
            # the row claimed - the sealed row read `violating: []` for a model
            # that had named violations, and the `accountedNotEmitted` entry
            # that should follow a claimed violation vanished with it. The
            # scans below are safe to run on the raw claim because the
            # per-field `-MaxIds` ceiling already bounds each list at the
            # anchor count; the ceiling that was expensive was the unbounded
            # expansion, and that is now caught inside the expander.
        }

        # The applicable subset: these are the only anchors the rule may judge.
        $requiredList = [System.Collections.Generic.List[string]]::new()
        foreach ($kind in $scopeKinds) {
            if (-not $idsByKind.ContainsKey($kind)) {
                $status = "unknown"
                if (-not $degradedReason) { $degradedReason = "the row declared a construct kind the wrapper does not enumerate" }
                continue
            }
            foreach ($id in $idsByKind[$kind]) { [void]$requiredList.Add($id) }
        }
        $required = @($requiredList.ToArray())
        $sealedUniverse = @($constructById.Keys)
        # A scope has to name a kind. With `none` the required set is empty, the
        # missing-anchor check is vacuous, and out-of-reach ids are exempt from
        # the stray check - so one arbitrary id in `notInReachConstructs` bought
        # a clean row that had weighed nothing. A rule that reaches nothing must
        # say WHICH anchors it does not reach, and it cannot do that without
        # naming the kinds those anchors belong to.
        if ($constructById.Count -gt 0 -and @($scopeKinds).Count -eq 0 -and
            @($violatingChangedLines).Count -eq 0) {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = "the row declared no construct kind while $($constructById.Count) anchors were enumerated; a rule that reaches nothing must name the kinds it would govern and put their anchors out of reach"
            }
        }
        elseif (@($scopeKinds).Count -gt 0 -and $constructById.Count -gt 0 -and
            $required.Count -eq 0) {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = "the row declared scope '$scope', but that scope contains no anchors in the sealed construct universe"
            }
        }
        # Scope limits applicable verdicts, not the universe. Anchors of other
        # kinds are still part of the exact partition, but may only be ruled out.
        $outOfScopeJudgements = @(@($violating) + @($compliantIds) + @($unknownIds) |
            Where-Object { $required -cnotcontains $_ })
        if ($outOfScopeJudgements.Count -gt 0) {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = "the row judged anchors outside its applicable scope instead of ruling them out of reach: " +
                (@($outOfScopeJudgements | Select-Object -First 20) -join ",")
            }
        }

        # Disjoint. An anchor with two verdicts is not an accounting, it is two.
        $seenInPartition = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $doubleCounted = [System.Collections.Generic.List[string]]::new()
        $allAccounted = [System.Collections.Generic.List[string]]::new()
        foreach ($field in @($partition.Keys)) {
            foreach ($id in @($partition[$field])) {
                if (-not $seenInPartition.Add($id)) { [void]$doubleCounted.Add($id) }
                else { [void]$allAccounted.Add($id) }
            }
        }
        if ($doubleCounted.Count -gt 0) {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = "the row gave the same anchor more than one verdict: " +
                (@($doubleCounted | Select-Object -First 20) -join ",")
            }
        }
        # Real anchors only.
        $ghostAnchors = @(@($allAccounted) | Where-Object { -not $constructById.ContainsKey($_) })
        if ($ghostAnchors.Count -gt 0) {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = "the row named anchors that do not exist: " +
                (@($ghostAnchors | Select-Object -First 20) -join ",")
            }
        }
        # Exact 1:1 coverage of the full sealed universe. Scope is checked
        # separately above so an outside-kind anchor can appear only out of
        # reach, never as a substantive or undecided judgement.
        $verdictBearing = @(@($violating) + @($compliantIds) + @($unknownIds) +
            @($violatingChangedLines))
        $weighedAnything = @($verdictBearing).Count -gt 0
        $missingConstructs = @(@($sealedUniverse) | Where-Object { -not $seenInPartition.Contains($_) })
        if ($missingConstructs.Count -gt 0) {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = "the row gave no verdict for these sealed anchors: " +
                (@($missingConstructs | Select-Object -First 20) -join ",") +
                $(if ($missingConstructs.Count -gt 20) { " and $($missingConstructs.Count - 20) more" } else { "" })
            }
        }
        # In-scope narrowing is a model judgement, not a consequence of kind.
        # Require the row to carry evidence for it; outside-scope anchors need no
        # extra prose because the declared scope itself is the allowed evidence.
        $applicableNotInReach = @(@($notInReach) | Where-Object { $required -ccontains $_ })
        $reachEvidence = [string](Get-ReviewerConventionSpecialistValue $row "codeEvidence" "")
        if ($applicableNotInReach.Count -gt 0 -and [string]::IsNullOrWhiteSpace($reachEvidence)) {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = "the row ruled applicable anchors out of reach without code evidence: " +
                (@($applicableNotInReach | Select-Object -First 20) -join ",")
            }
        }
        # `none` with nothing named is not an answer. A rule that genuinely
        # reaches nothing has to SAY so against the anchors - declare the kinds
        # it would govern and put them out of reach - because that is a claim a
        # reader can check. A row that names no anchor at all has said nothing
        # falsifiable, and `notApplicable` is exactly the word a model reaches
        # for when it wants out; it cannot also be the word that exempts it.
        $namedAnything = @($allAccounted).Count -gt 0
        if ($constructById.Count -gt 0 -and -not $namedAnything -and $status -cne "unknown") {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = "the row named no anchor at all while $($constructById.Count) were enumerated; a rule that reaches nothing must say so against the anchors"
            }
        }
        elseif ($constructById.Count -gt 0 -and -not $weighedAnything -and
            @("notApplicable", "unknown") -cnotcontains $status) {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = "the row declared scope '$scope' and then put every anchor in it out of the rule's reach, which is an answer about nothing"
            }
        }

        # Provenance before arithmetic: a row that fabricated its rule quote
        # never read the rule at all, which is a worse thing to know than a
        # headline disagreeing with its own anchors - and first-writer-wins
        # means whichever check runs first is the one a reader is told about.
        $quote = [string](Get-ReviewerConventionSpecialistValue $row "ruleQuote" "")
        if ($quote) {
            $sourceText = ([string](Get-ReviewerConventionSpecialistValue $source "Text" "")).Replace("`r`n", "`n").Replace("`r", "`n")
            if ($sourceText.IndexOf($quote.Replace("`r`n", "`n").Replace("`r", "`n"), [StringComparison]::Ordinal) -lt 0) {
                $status = "unknown"
                if (-not $degradedReason) { $degradedReason = "the row quoted text that is not in the transported source" }
            }
        }

        # The DERIVED status. Skipped only when the WRAPPER already degraded the
        # row - a partition the wrapper could not trust has nothing worth
        # deriving from. A row that merely called ITSELF unknown still gets its
        # anchors read, which is the whole point.
        if (-not $degradedReason) {
            $derived = $(if (@($unknownIds).Count -gt 0) { "unknown" }
                elseif (@($violating).Count -gt 0 -or @($violatingChangedLines).Count -gt 0) { "violation" }
                elseif (-not $weighedAnything) { "notApplicable" }
                else { "compliant" })
            if ($derived -cne $status) {
                # Not merely a note: the wrapper counts a disagreement toward
                # the degraded-row count and it zeroes `Complete`, because a row
                # whose headline contradicted its own anchors is a row a reader
                # should look at even though the anchors settled it.
                if (-not $degradedReason) {
                    $degradedReason = "the row said '$status' while its own anchor verdicts say '$derived'; the anchors decide"
                }
                $status = $derived
            }
        }
        $linkedCandidate = [string](Get-ReviewerConventionSpecialistValue $row "candidateId" "")
        $alreadyWithheld = $false
        if ($linkedCandidate -and -not $candidateIds.Contains($linkedCandidate)) {
            $alreadyWithheld = (@($WithheldCandidateIds) -ccontains $linkedCandidate)
            # Not an error about the finding - the candidate list is what it is -
            # but the link is not real, so it is not recorded as one.
            $linkedCandidate = ""
            if (-not $degradedReason) {
                $degradedReason = $(if ($alreadyWithheld) {
                        "the candidate it linked was withheld by the wrapper"
                    }
                    else { "the row linked a candidate that this pass did not emit" })
            }
        }
        elseif ($linkedCandidate -and
            [string]$candidateAnchorKinds[$linkedCandidate] -cne "prMetadata") {
            # A wrong-anchor row cannot stand in for the right one. If the
            # linked candidate does not sit on one of the constructs this row
            # says are violating, the row is about one place and the finding is
            # about another, and neither has actually been accounted for.
            $candidateAnchor = [string]$candidateAnchors[$linkedCandidate]
            $anchorMatches = $false
            foreach ($target in $violatingChangedLines) {
                if ($resolvedLineTargets.ContainsKey([string]$target) -and
                    [string]$resolvedLineTargets[[string]$target] -ceq $candidateAnchor) {
                    $anchorMatches = $true
                    break
                }
            }
            foreach ($id in $violating) {
                if ($anchorMatches) { break }
                $construct = $constructById[$id]
                # A construct the enumerator could not finish reading has an
                # endLine that is where the walk gave up, not where the call
                # ends - up to eighty lines away. Accepting a candidate
                # anywhere in that span would let one unreadable construct
                # license a comment almost anywhere. An anchor has to be an
                # anchor.
                if ([string](Get-ReviewerConventionSpecialistValue $construct "status" "known") -cne "known") { continue }
                $constructPath = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
                    [string](Get-ReviewerConventionSpecialistValue $construct "path" ""))
                $candidateParts = $candidateAnchor -split '\|'
                if ($candidateParts.Count -ne 2) { continue }
                if (-not [string]::Equals($constructPath, [string]$candidateParts[0], [StringComparison]::Ordinal)) { continue }
                # ANYWHERE inside the construct, not just its opening line. The
                # rule that started this is about the last argument of a
                # multi-line call, and a reviewer anchors that comment on the
                # offending argument - so an opening-line-only test would
                # discard precisely the rows that got it right.
                $candidateLine = [int]$candidateParts[1]
                $constructStart = [int](Get-ReviewerConventionSpecialistValue $construct "line" 0)
                $constructEnd = [int](Get-ReviewerConventionSpecialistValue $construct "endLine" $constructStart)
                if ($constructEnd -lt $constructStart) { $constructEnd = $constructStart }
                if ($candidateLine -ge $constructStart -and $candidateLine -le $constructEnd) { $anchorMatches = $true; break }
            }
            if (-not $anchorMatches) {
                $status = "unknown"
                $linkedCandidate = ""
                if (-not $degradedReason) {
                    $degradedReason = "the candidate it linked is anchored somewhere other than the constructs or changed-file targets this row calls violating"
                }
            }
        }
        # A row whose rule DID produce an accepted candidate is emitted even if
        # the model forgot to write the link down. Recording it as unemitted
        # would report a finding as missing while it sits in the candidate list.
        $ruleProducedCandidate = $candidateRuleKeys.Contains($ruleKey)
        # The PARTITION, not the derived status. One undecided anchor makes the
        # row unknown, and a pre- or post-derive degrade rewrites the status
        # too - either way a violation the row explicitly named would vanish
        # from the record entirely, which is the opposite of the point.
        if ((@($violating).Count -gt 0 -or @($violatingChangedLines).Count -gt 0) -and
            -not $linkedCandidate -and -not $alreadyWithheld -and -not $ruleProducedCandidate) {
            [void]$unemitted.Add([pscustomobject][ordered]@{
                    packName = [string]$entry.packName
                    ruleSourceId = [string]$entry.ruleSourceId
                    notes = [string](Get-ReviewerConventionSpecialistValue $row "notes" "")
                })
        }
        [void]$normalized.Add([pscustomobject][ordered]@{
                ruleRef = $ruleRef
                packName = [string]$entry.packName
                ruleSourceId = [string]$entry.ruleSourceId
                ruleSourceSha256 = [string](Get-ReviewerConventionSpecialistValue $source "Sha256" "")
                ruleQuote = $quote
                status = $status
                scope = $scope
                violatingConstructs = @($violating)
                violatingChangedFileTargets = @($violatingChangedLines)
                compliantConstructs = @($compliantIds)
                notInReachConstructs = @($notInReach)
                unknownConstructs = @($unknownIds)
                codeEvidence = [string](Get-ReviewerConventionSpecialistValue $row "codeEvidence" "")
                siblingStatus = [string](Get-ReviewerConventionSpecialistValue $row "siblingStatus" "unavailable")
                siblingEvidence = [string](Get-ReviewerConventionSpecialistValue $row "siblingEvidence" "")
                candidateId = $linkedCandidate
                notes = [string](Get-ReviewerConventionSpecialistValue $row "notes" "")
                degradedReason = $degradedReason
            })
    }

    # An accounting that weighed no anchor at all is not complete over anything,
    # however correctly each row is spelled. Every row may legitimately rule its
    # anchors out of reach - but then the whole checklist has looked at nothing,
    # and `Complete` is the one word a reader trusts.
    # Distinct anchors, not the sum of the rows' claims. Ten rows may each weigh
    # the same twenty anchors, and "checked 200 of 20" is arithmetic nobody can
    # read - the more so now that an over-claiming row keeps its verdicts on the
    # record instead of having them erased.
    $checkedSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $notInReachSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in @($normalized)) {
        foreach ($id in @(@($row.violatingConstructs) + @($row.compliantConstructs) + @($row.unknownConstructs))) {
            if ($constructById.ContainsKey([string]$id)) { [void]$checkedSet.Add([string]$id) }
        }
        foreach ($id in @($row.notInReachConstructs)) {
            if ($constructById.ContainsKey([string]$id)) { [void]$notInReachSet.Add([string]$id) }
        }
    }
    $checkedConstructCount = $checkedSet.Count
    $checkedChangedFileTargetSet = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($row in @($normalized)) {
        foreach ($target in @($row.violatingChangedFileTargets)) {
            [void]$checkedChangedFileTargetSet.Add([string]$target)
        }
    }
    $checkedChangedFileTargetCount = $checkedChangedFileTargetSet.Count
    $notInReachConstructCount = $notInReachSet.Count
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($request.Requested)) {
        if (-not $seen.Contains([string]$entry.ruleRef)) {
            [void]$missing.Add(("{0}/{1}" -f [string]$entry.packName, [string]$entry.ruleSourceId))
        }
    }
    foreach ($key in @($request.Unrequested)) { [void]$missing.Add($key) }
    $accountedKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in @($normalized)) {
        [void]$accountedKeys.Add(("{0}/{1}" -f [string]$row.packName, [string]$row.ruleSourceId))
    }
    $unaccountedCandidates = @(@($AcceptedCandidates) | Where-Object {
            -not $accountedKeys.Contains(("{0}/{1}" -f `
                    [string](Get-ReviewerConventionSpecialistValue $_ "packName" ""),
                    [string](Get-ReviewerConventionSpecialistValue $_ "ruleSourceId" "")))
        } | ForEach-Object { [string](Get-ReviewerConventionSpecialistValue $_ "candidateId" "") })
    $degradedCount = @(@($normalized) | Where-Object { [string]$_.degradedReason }).Count

    return @{
        Rows = $normalized.ToArray()
        ExpectedSourceCount = @($ResolvedSources).Count
        RequestedSourceCount = @($request.Requested).Count
        AccountedSourceCount = $seen.Count
        DegradedRowCount = $degradedCount
        Missing = @($missing.ToArray())
        Duplicates = @($duplicates.ToArray())
        Unknown = @($unknown.ToArray())
        UnaccountedCandidates = @($unaccountedCandidates)
        # Every construct the row was given to account for, and how it split
        # them. "Complete: True" beside "checked 1, out of reach 119" is a very
        # different claim from "checked 120", and a reader must be able to see
        # which one they are looking at.
        EnumeratedConstructCount = $constructById.Count
        CheckedConstructCount = $checkedConstructCount
        CheckedChangedFileTargetCount = $checkedChangedFileTargetCount
        NotInReachConstructCount = $notInReachConstructCount
        UnemittedViolations = @($unemitted.ToArray())
        ConstructsIncomplete = $ConstructsIncomplete
        # The construct table the rows were reconciled against, compactly. A
        # reader who wants to check a row - "which call is mi25?" - otherwise
        # has to re-run the enumeration and hope it matches. An accounting
        # nobody can audit is a claim, not evidence.
        Constructs = @(@($Constructs) | ForEach-Object {
                [pscustomobject][ordered]@{
                    constructId = [string](Get-ReviewerConventionSpecialistValue $_ "constructId" "")
                    kind = [string](Get-ReviewerConventionSpecialistValue $_ "kind" "")
                    path = [string](Get-ReviewerConventionSpecialistValue $_ "path" "")
                    line = [int](Get-ReviewerConventionSpecialistValue $_ "line" 0)
                    endLine = [int](Get-ReviewerConventionSpecialistValue $_ "endLine" 0)
                    name = [string](Get-ReviewerConventionSpecialistValue $_ "name" "")
                    argumentNaming = [string](Get-ReviewerConventionSpecialistValue $_ "argumentNaming" "")
                }
            })
        # A row that the wrapper had to degrade is not a check that happened.
        # Leaving it out of this would let a marker whose every row cited a
        # fabricated hash still print "Complete: True", which is the one line a
        # reader will trust. Nor is an accounting complete over a construct set
        # the wrapper knows it could not finish enumerating.
        Complete = ($seen.Count -eq @($request.Requested).Count -and @($request.Unrequested).Count -eq 0 -and
            $duplicates.Count -eq 0 -and $unknown.Count -eq 0 -and
            $degradedCount -eq 0 -and @($unaccountedCandidates).Count -eq 0 -and
            -not $ConstructsIncomplete -and
            # An accounting that weighed no anchor at all is not complete over
            # anything, however correctly each row is spelled. Every row may
            # legitimately rule its anchors out of reach - but then the whole
            # checklist has looked at nothing, and "Complete" would be the one
            # word a reader trusts.
            (@($Constructs).Count -eq 0 -or $checkedConstructCount -gt 0 -or
                $checkedChangedFileTargetCount -gt 0))
    }
}

function Get-ReviewerConventionSpecialistAuthoritativeRuleQuote {
    <#
        The first quotable line of a rule's own section.

        Deliberately the same walk the verifier does for its wrapper-derived
        convention binding. Version 4 stopped asking the model to copy a quote
        out of a document the wrapper transported, so the wrapper has to cut one
        itself, and the two must agree: a candidate quoted one way here and
        another way there would look like two different rules to a reader
        comparing the specialist's artifact with the verifier's.

        Returns empty when no line qualifies. Empty is a refusal to emit a
        candidate, never a candidate without provenance.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Section,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceText
    )
    $normalized = $SourceText.Replace("`r`n", "`n").Replace("`r", "`n")
    if (-not $Section -or $normalized.IndexOf($Section, [StringComparison]::Ordinal) -lt 0) {
        # A whole-file source has no heading to cut at, so take the first line
        # that can stand as a quote. It is still the transported text.
        if ($Section) { return "" }
        foreach ($sourceLine in @($normalized -split "`n")) {
            $line = $sourceLine.Trim()
            if ($line -match '^(#{1,6})\s+') { continue }
            if (-not $line) { continue }
            if ($line.Length -gt 600) { $line = $line.Substring(0, 600).TrimEnd() }
            if ($line.Length -ge 8 -and $line -notmatch '[^\x20-\x7E]') { return $line }
        }
        return ""
    }
    $sectionSeen = $false
    $sectionLevel = 0
    foreach ($sourceLine in @($normalized -split "`n")) {
        $line = $sourceLine.Trim()
        if (-not $sectionSeen) {
            if ($line -ceq $Section.Trim()) {
                $sectionSeen = $true
                if ($line -match '^(#{1,6})\s+') { $sectionLevel = $Matches[1].Length }
            }
            continue
        }
        if ($line -match '^(#{1,6})\s+') {
            if ($sectionLevel -eq 0 -or $Matches[1].Length -le $sectionLevel) { break }
            continue
        }
        if (-not $line) { continue }
        if ($line.Length -gt 600) { $line = $line.Substring(0, 600).TrimEnd() }
        if ($line.Length -ge 8 -and $line -notmatch '[^\x20-\x7E]') { return $line }
    }
    return ""
}

function Get-ReviewerConventionSpecialistSafeProse {
    <#
        Model prose on its way into a rendered artifact.

        Prose is the only model-authored text left in version 4, and it is
        explicitly non-eligibility-critical, so it may never be the reason a
        finding is lost. The marker normalizer already bounded and de-typographed
        it; what is left is the one thing a length rule cannot catch - text that
        recommends a VOTE, which this layer is forbidden to carry. That is
        answered by dropping the sentence, not the finding.
    #>
    param([AllowEmptyString()][string]$Text = "", [Parameter(Mandatory)][string]$Fallback)
    $value = [string]$Text
    if ([string]::IsNullOrWhiteSpace($value)) { return $Fallback }
    if (Test-ReviewerConventionSpecialistVoteText -Text $value) { return $Fallback }
    return $value
}

function Format-ReviewerConventionSpecialistNormalizations {
    <#
        The human sentence that records what the wrapper altered in a
        model-owned field, and the field name that leads it.

        Extracted from the reviewer's inline pipeline because an inline block is
        not testable, and an untestable describer is exactly how this layer came
        to hold a defect that could destroy a correct pass. The original read
        `$_.To` inside a `switch`, where PowerShell has rebound `$_` to the
        switch's own input - so the read reached a plain string and threw under
        StrictMode. The two named arms never touched `$_`, so the fault sat
        unreachable until a contract emitted a normalization kind that fell to
        `default`. The first one that did cost a live qualification trial its
        entire pass, and the answer it destroyed was correct.

        So this function has two properties, and both are asserted by tests:
        it names every kind by what it ACTUALLY was, and it CANNOT throw. Every
        field is read through the tolerant accessor, so a record missing any key
        - or carrying a kind nobody has written yet - still describes. A
        description is commentary; it may never be the reason a finding is lost.
    #>
    param([AllowEmptyCollection()][object[]]$Normalizations = @())
    $records = @($Normalizations)
    if ($records.Count -eq 0) {     return @{ Detail = ""; Reason = ""; NormalizedCount = 0 } }
    $described = [System.Collections.Generic.List[string]]::new()
    foreach ($normalization in $records) {
        $from = [string](Get-ReviewerConventionSpecialistValue $normalization "From" "")
        $to = [string](Get-ReviewerConventionSpecialistValue $normalization "To" "")
        $field = [string](Get-ReviewerConventionSpecialistValue $normalization "Field" "")
        $typed = [string](Get-ReviewerConventionSpecialistValue $normalization "OriginalTypedReason" "")
        # Named by what it was. A hard-coded description of one kind mislabels
        # every other kind, which is worse than saying nothing.
        $what = switch ($from) {
            'emptyJsonArray' { "an exact empty JSON array to the schema's empty string" }
            'absentUnderCheckedSiblingStatus' { "an absent reason to the empty string the checked sibling status requires" }
            'bareString' { "a bare string to the object with a text key the schema requires" }
            'absent' { "an absent key to '$to'" }
            'notAnArray' { "a value that was not an array to '$to'" }
            default { "'$from' to '$to'" }
        }
        [void]$described.Add("$what at '$field' (original typed reason: $typed)")
    }
    return @{
        Detail = [string](Get-ReviewerConventionSpecialistValue $records[0] "Field" "")
        Reason = "Compatibility-normalized $($records.Count) field(s): " + ($described -join '; ')
        # Deliberately NOT named `Count`. On a hashtable that name collides with
        # the dictionary's own entry count, so a caller reading `.Count` gets one
        # or the other depending on how the adapter resolves it - and a test that
        # passes for the wrong reason is worse than no test.
        NormalizedCount = $records.Count
    }
}

function Convert-ReviewerConventionSpecialistV4Marker {
    <#
        A validated version 4 marker, rewritten into the version 3 shape the rest
        of this pipeline already understands.

        The point is not translation for its own sake. Every field the model no
        longer sends still has to exist downstream: the verification and
        run-reconciliation schemas REQUIRE `changedCodeFix` and
        `existingDebtFollowUp` on a candidate, and the preview, the gate and the
        reconciler all read the version 3 candidate shape. Deriving that shape
        here means version 4 changes what the MODEL is asked for without changing
        anything the wrapper hands on - so cross-verification, reconciliation and
        delivery are untouched by this contract.

        It also means the wrapper's own derivations are checked by exactly the
        code that used to check the model's. Nothing here is trusted because the
        wrapper wrote it; it goes through the same candidate validation, the same
        target resolution and the same accounting reconciliation. A derivation
        bug is caught rather than believed.

        Completeness is decided HERE, against the id set the wrapper itself sent.
        A row must carry exactly one verdict per in-scope construct. A missing,
        duplicated or unbound id makes the ROW incomplete and unknown - it never
        shrinks the set that gets a verdict, because "the model said nothing
        about this construct" and "the model said this construct is fine" must
        never arrive at a reader looking the same.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Marker,
        [Parameter(Mandatory)]$ConventionPlan,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ResolvedSources,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ChangeEntries,
        [AllowEmptyCollection()][object[]]$Constructs = @(),
        [AllowEmptyCollection()][object[]]$ConstructFiles = @(),
        [hashtable]$RightHandRangesByPath = @{}
    )
    $withheld = [System.Collections.Generic.List[object]]::new()
    $candidates = [System.Collections.Generic.List[object]]::new()
    $coverageRows = [System.Collections.Generic.List[object]]::new()

    $request = Get-ReviewerConventionSpecialistRuleRequest -ResolvedSources $ResolvedSources `
        -Constructs $Constructs -ContractVersion 4 -ConventionPlan $ConventionPlan
    $requestedByRef = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($row in @($request.Requested)) { $requestedByRef[[string]$row.ruleRef] = $row }

    $changedFileIndex = Get-ReviewerConventionSpecialistChangedFileIndex -ChangeEntries $ChangeEntries `
        -RightHandRangesByPath $RightHandRangesByPath
    $anchorIdByPath = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($anchor in @($changedFileIndex)) {
        $anchorPath = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
            [string](Get-ReviewerConventionSpecialistValue $anchor "path" ""))
        $anchorId = [string](Get-ReviewerConventionSpecialistValue $anchor "anchorId" "")
        if ($anchorPath -and $anchorId -and -not $anchorIdByPath.ContainsKey($anchorPath)) {
            $anchorIdByPath.Add($anchorPath, $anchorId)
        }
    }
    $constructById = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($construct in @($Constructs)) {
        $id = [string](Get-ReviewerConventionSpecialistValue $construct "constructId" "")
        if ($id -and -not $constructById.ContainsKey($id)) { $constructById.Add($id, $construct) }
    }
    $censusByPath = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($file in @($ConstructFiles)) {
        $filePath = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
            [string](Get-ReviewerConventionSpecialistValue $file "path" ""))
        if ($filePath -and -not $censusByPath.ContainsKey($filePath)) { $censusByPath.Add($filePath, $file) }
    }

    $assessmentsByRef = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($assessment in @($Marker.assessments)) {
        # Lowercased for the same reason the coverage reconciler does it: the
        # marker pattern is case-insensitive, so `RS0` validates and then misses
        # the ordinal lookup, costing a whole rule its accounting.
        $ruleRef = ([string](Get-ReviewerConventionSpecialistValue $assessment "ruleRef" "")).ToLowerInvariant()
        if (-not $requestedByRef.ContainsKey($ruleRef)) {
            [void]$withheld.Add([pscustomobject][ordered]@{
                    candidateId = ""
                    reason = "invalidEvidence"
                    detail = "An assessment cited rule reference '$ruleRef', which the wrapper did not transport."
                })
            continue
        }
        if ($assessmentsByRef.ContainsKey($ruleRef)) {
            [void]$withheld.Add([pscustomobject][ordered]@{
                    candidateId = ""
                    reason = "invalidEvidence"
                    detail = "Rule reference '$ruleRef' was assessed more than once; the duplicate was not read."
                })
            continue
        }
        $assessmentsByRef[$ruleRef] = $assessment
    }

    foreach ($requestedRow in @($request.Requested)) {
        $ruleRef = [string]$requestedRow.ruleRef
        $source = $requestedRow.source
        $sourceSha = [string](Get-ReviewerConventionSpecialistValue $source "Sha256" "")
        $section = [string](Get-ReviewerConventionSpecialistValue $source "Section" "")
        $sourceText = [string](Get-ReviewerConventionSpecialistValue $source "Text" "")
        $quote = Get-ReviewerConventionSpecialistAuthoritativeRuleQuote -Section $section -SourceText $sourceText
        $inScopeIds = [string[]]@(Get-ReviewerConventionSpecialistValue $requestedRow "inScopeConstructIds" @())
        $inScopeResolved = [bool](Get-ReviewerConventionSpecialistValue $requestedRow "inScopeResolved" $false)
        $scopeKinds = [System.Collections.Generic.List[string]]::new()
        foreach ($kind in $script:ReviewerConventionSpecialistConstructKinds) {
            foreach ($id in $inScopeIds) {
                if (-not $constructById.ContainsKey($id)) { continue }
                if ([string](Get-ReviewerConventionSpecialistValue $constructById[$id] "kind" "") -cne $kind) { continue }
                [void]$scopeKinds.Add($kind)
                break
            }
        }

        $assessment = $null
        if ($assessmentsByRef.ContainsKey($ruleRef)) { $assessment = $assessmentsByRef[$ruleRef] }
        # A rule the model never answered is left OUT of the accounting entirely,
        # so the reconciler reports it as the gap it is. Writing an empty row
        # here would be the wrapper answering on the model's behalf.
        if ($null -eq $assessment) { continue }

        $verdicts = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
        $proseById = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $defects = [System.Collections.Generic.List[string]]::new()
        if (-not $inScopeResolved) {
            [void]$defects.Add("the wrapper could not establish which constructs this rule reaches")
        }
        # Prose is read first and separately, and its defects are NOT row
        # defects. A note for a construct that got no verdict, or a second note
        # for the same one, is simply not used; nothing about the accounting
        # changes, because a sentence is not an assertion about coverage.
        foreach ($note in @(Get-ReviewerConventionSpecialistValue $assessment "notes" @())) {
            $noteRef = [string](Get-ReviewerConventionSpecialistValue $note "constructRef" "")
            if (-not $noteRef -or $proseById.ContainsKey($noteRef)) { continue }
            $proseById[$noteRef] = $note
        }
        foreach ($entry in @(Get-ReviewerConventionSpecialistValue $assessment "constructs" @())) {
            $constructRef = [string](Get-ReviewerConventionSpecialistValue $entry "constructRef" "")
            $verdict = [string](Get-ReviewerConventionSpecialistValue $entry "verdict" "")
            if ($inScopeIds -cnotcontains $constructRef) {
                [void]$defects.Add("verdict for '$constructRef', which is not in this rule's in-scope set")
                continue
            }
            if ($verdicts.ContainsKey($constructRef)) {
                [void]$defects.Add("more than one verdict for '$constructRef'")
                continue
            }
            $verdicts[$constructRef] = $verdict
        }
        $missing = @($inScopeIds | Where-Object { -not $verdicts.ContainsKey($_) })
        if ($missing.Count -gt 0) {
            [void]$defects.Add("no verdict for " + (@($missing | Select-Object -First 12) -join ",") +
                $(if ($missing.Count -gt 12) { " and $($missing.Count - 12) more" } else { "" }))
        }

        $violatingIds = [string[]]@($inScopeIds | Where-Object {
                $verdicts.ContainsKey($_) -and $verdicts[$_] -ceq "violation"
            })
        $compliantIds = [string[]]@($inScopeIds | Where-Object {
                $verdicts.ContainsKey($_) -and $verdicts[$_] -ceq "compliant"
            })
        $unknownIds = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $inScopeIds) {
            if ($verdicts.ContainsKey($id) -and $verdicts[$id] -ceq "unknown") { [void]$unknownIds.Add($id) }
        }
        # An incomplete row asserts nothing. Every in-scope construct becomes
        # UNKNOWN and no candidate is emitted from it: a row that could not
        # account for itself must not also be a source of findings.
        if ($defects.Count -gt 0) {
            $violatingIds = [string[]]@()
            $compliantIds = [string[]]@()
            $unknownIds.Clear()
            foreach ($id in $inScopeIds) { [void]$unknownIds.Add($id) }
            [void]$withheld.Add([pscustomobject][ordered]@{
                    candidateId = ""
                    reason = "invalidEvidence"
                    detail = Get-ReviewerConventionSpecialistShortened -Text (
                        "Rule '$ruleRef' did not account for its in-scope constructs (" +
                        (@($defects | Select-Object -First 4) -join "; ") +
                        "); every construct it reaches was recorded as unknown and it produced no finding.") -MaxLength 800
                })
        }

        # Not in reach is the wrapper's arithmetic, not the model's. Five of ten
        # qualification runs lost their accounting to exactly this complement.
        $judged = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($id in @($violatingIds) + @($compliantIds) + @($unknownIds.ToArray())) { [void]$judged.Add($id) }
        $notInReachIds = [string[]]@(@($constructById.Keys) | Where-Object { -not $judged.Contains($_) })

        $rowCandidateIds = [System.Collections.Generic.List[string]]::new()
        # Grouping is a WRAPPER decision: violations are grouped by file, in the
        # anchor order the wrapper assigned. A model that answers per file and
        # one that answers in a single block now produce byte-identical output,
        # so a correct split can no longer be scored as a miss.
        $violatingByPath = [ordered]@{}
        foreach ($id in $violatingIds) {
            if (-not $constructById.ContainsKey($id)) { continue }
            $path = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
                [string](Get-ReviewerConventionSpecialistValue $constructById[$id] "path" ""))
            if (-not $path) { continue }
            if (-not $violatingByPath.Contains($path)) {
                $violatingByPath[$path] = [System.Collections.Generic.List[string]]::new()
            }
            [void]$violatingByPath[$path].Add($id)
        }
        $groupPaths = [string[]]@($violatingByPath.Keys)
        [Array]::Sort($groupPaths, [StringComparer]::Ordinal)
        $groupIndex = 0
        foreach ($groupPath in $groupPaths) {
            $groupIds = [string[]]@($violatingByPath[$groupPath].ToArray())
            $anchorId = $(if ($anchorIdByPath.ContainsKey($groupPath)) { $anchorIdByPath[$groupPath] } else { "" })
            $targets = [System.Collections.Generic.List[string]]::new()
            foreach ($id in $groupIds) {
                $line = [int](Get-ReviewerConventionSpecialistValue $constructById[$id] "line" 0)
                if (-not $anchorId -or $line -lt 1) { continue }
                [void]$targets.Add("$($anchorId):$line")
            }
            $candidateId = "c$($ruleRef)f$groupIndex"
            $groupIndex++
            if ($targets.Count -ne $groupIds.Count -or -not $quote) {
                $reason = $(if (-not $quote) {
                        "the wrapper could not cut a quotable line from the transported rule source"
                    }
                    else { "one or more violating constructs do not sit on a delivered changed line" })
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId
                        reason = "invalidTarget"
                        detail = Get-ReviewerConventionSpecialistShortened -Text (
                            "A violation group in '$groupPath' was not published because $reason.") -MaxLength 800
                    })
                continue
            }
            # The prose of the group's first violating construct speaks for the
            # group. Deterministic, so the same matrix always renders the same
            # candidate.
            $leadEntry = $(if ($proseById.ContainsKey($groupIds[0])) { $proseById[$groupIds[0]] } else { $null })
            $rationale = Get-ReviewerConventionSpecialistSafeProse -Text (
                [string](Get-ReviewerConventionSpecialistValue $leadEntry "rationale" "")) -Fallback (
                "The transported rule governs this construct and it does not satisfy it.")
            $suggestion = Get-ReviewerConventionSpecialistSafeProse -Text (
                [string](Get-ReviewerConventionSpecialistValue $leadEntry "suggestion" "")) -Fallback (
                "Bring the named constructs into line with the quoted rule, or record why the rule does not apply.")
            $factIds = ""
            if ($censusByPath.ContainsKey($groupPath)) {
                $census = $censusByPath[$groupPath]
                # A partial census is not evidence: it cannot say an attribute is
                # absent, only that it was not seen in what was read.
                if ([bool](Get-ReviewerConventionSpecialistValue $census "attributeCountsComplete" $false) -and
                    [bool](Get-ReviewerConventionSpecialistValue $census "wholeFileComplete" $false)) {
                    $factIds = [string](Get-ReviewerConventionSpecialistValue $census "evidenceFactId" "")
                }
            }
            $conventionKey = [string](Get-ReviewerConventionSpecialistValue $source "SourceId" "")
            if ($conventionKey -cnotmatch '^[A-Za-z_][A-Za-z0-9_.:\-]{0,127}$') {
                $conventionKey = [string](Get-ReviewerConventionSpecialistValue $source "PackName" "")
            }
            if ($conventionKey -cnotmatch '^[A-Za-z_][A-Za-z0-9_.:\-]{0,127}$') {
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId
                        reason = "unverifiedSource"
                        detail = "A violation group was not published because its rule has no usable convention key."
                    })
                continue
            }
            $targetText = (@($targets.ToArray()) -join ",")
            [void]$rowCandidateIds.Add($candidateId)
            [void]$candidates.Add(@{
                    candidateId = $candidateId
                    category = "convention"
                    # Version 4 never escalates. Escalation needs a policy the
                    # pack does not yet express, and inventing one here would be
                    # the wrapper asserting an impact nobody stated.
                    severity = "suggestion"
                    anchorKind = "changedFile"
                    filePath = ""
                    line = 0
                    # Left empty on purpose: the version 3 resolver derives the
                    # primary anchor, the file and the line from the target union
                    # below. Deriving it a second time here would be a second
                    # statement of the same thing, and two statements can differ.
                    primaryTarget = ""
                    manifestations = $targetText
                    ruleRef = $ruleRef
                    ruleSection = $section
                    ruleQuote = $quote
                    diffEvidence = "Wrapper-resolved changed-line anchors for this rule: $targetText."
                    impactCategory = "none"
                    impact = $rationale
                    expectedFixOrValidation = $suggestion
                    siblingStatus = "notRequired"
                    siblingEvidence = ""
                    siblingNotRequiredReason = "The wrapper adjudicated this rule from the constructs it enumerated and delivered."
                    factIds = $factIds
                    confidence = "medium"
                    residualRiskSummary = ""
                    semanticCandidateVersion = 2
                    changedCodeFix = @{
                        action = "replace"
                        targets = $targetText
                        conventionKey = $conventionKey
                        valueSource = "authoritativeRule"
                        evidenceFactIds = ""
                    }
                    # Version 4 makes no debt claim. The counts behind one are a
                    # pack policy this contract does not carry, and a follow-up
                    # nobody can substantiate is worse than none.
                    existingDebtFollowUp = @{
                        status = "none"
                        evidenceFactId = ""
                        selectorKey = ""
                        scopeKind = ""
                        scopePath = ""
                        comparableCount = 0
                        compliantCount = 0
                        action = ""
                    }
                })
        }

        $reachEvidence = ("The wrapper routed this rule to " + @($groupPaths).Count.ToString() +
            " changed file(s) by its pack's path globs; every construct outside that routing is out of reach.")
        [void]$coverageRows.Add([pscustomobject][ordered]@{
                ruleRef = $ruleRef
                ruleSourceSha256 = $sourceSha
                ruleQuote = (Get-ReviewerConventionSpecialistShortened -Text $quote -MaxLength 200)
                # Derived by EXACTLY the rule the coverage reconciler applies:
                # any unknown anchor makes the row unknown, then any violation
                # makes it a violation, then an unweighed row is notApplicable,
                # else compliant. Authoring anything else here would be the
                # wrapper disagreeing with itself - and the reconciler counts a
                # headline that contradicts its own anchors as a degraded row and
                # zeroes `Complete`. A model that answers `unknown` for a
                # construct it genuinely could not decide - which this contract
                # explicitly asks it to do - must not cost the pass its
                # accounting for having been honest.
                status = $(if ($defects.Count -gt 0) { "unknown" }
                    elseif ($unknownIds.Count -gt 0) { "unknown" }
                    elseif (@($violatingIds).Count -gt 0) { "violation" }
                    elseif (@($compliantIds).Count -gt 0) { "compliant" }
                    else { "notApplicable" })
                scope = $(if ($scopeKinds.Count -gt 0) { (@($scopeKinds.ToArray()) -join ",") } else { "none" })
                violatingConstructs = (ConvertTo-ReviewerConventionSpecialistConstructIdRanges -Ids $violatingIds)
                compliantConstructs = (ConvertTo-ReviewerConventionSpecialistConstructIdRanges -Ids $compliantIds)
                notInReachConstructs = (ConvertTo-ReviewerConventionSpecialistConstructIdRanges -Ids $notInReachIds)
                unknownConstructs = (ConvertTo-ReviewerConventionSpecialistConstructIdRanges -Ids ([string[]]@($unknownIds.ToArray())))
                violatingChangedFileTargets = ""
                codeEvidence = $reachEvidence
                siblingStatus = "notRequired"
                siblingEvidence = ""
                candidateId = $(if ($rowCandidateIds.Count -gt 0) { $rowCandidateIds[0] } else { "" })
                notes = ""
            })
    }

    $converted = @{}
    foreach ($key in @($Marker.Keys)) {
        if (@("assessments") -ccontains [string]$key) { continue }
        $converted[$key] = $Marker[$key]
    }
    $converted["schemaVersion"] = 3
    $converted["candidates"] = @($candidates.ToArray())
    $converted["ruleCoverage"] = @($coverageRows.ToArray())
    $converted["withheld"] = @(@($Marker.withheld) + @($withheld.ToArray()))
    return @{ Marker = $converted; ChangedFileIndex = $changedFileIndex }
}

function Resolve-ReviewerConventionSpecialistCandidates {
    param(
        [Parameter(Mandatory)][hashtable]$Marker,
        [Parameter(Mandatory)]$ConventionPlan,
        [Parameter(Mandatory)]$FactPlan,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ResolvedSources,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ChangeEntries,
        [AllowEmptyCollection()][object[]]$Constructs = @(),
        [AllowEmptyCollection()][object[]]$ConstructFiles = @(),
        [bool]$ConstructsIncomplete = $false,
        [hashtable]$RightHandRangesByPath = @{},
        [ValidateSet(2, 3, 4)][int]$ContractVersion = 2,
        # Candidates the marker extractor withheld because a semantic field of
        # theirs could not be read. They arrive here so they leave a mark: a
        # shortened candidate list that says nothing about what is missing from
        # it reads exactly like a clean review.
        [AllowEmptyCollection()][object[]]$DroppedElements = @()
    )
    if (@($ResolvedSources).Count -eq 0) {
        throw "Convention specialist candidate validation requires at least one resolved convention source."
    }
    if (@($ChangeEntries).Count -eq 0) {
        throw "Convention specialist candidate validation requires at least one pinned change entry."
    }
    # Version 4 arrives as a per-construct verdict matrix. Convert it to the
    # version 3 candidate/coverage shape FIRST, then resolve it with exactly the
    # code that resolves a version 3 marker. The wrapper's own derivations are
    # then validated by the same checks that used to validate the model's, so a
    # derivation bug is caught here rather than published.
    if ($ContractVersion -eq 4) {
        $convertedV4 = Convert-ReviewerConventionSpecialistV4Marker -Marker $Marker `
            -ConventionPlan $ConventionPlan -ResolvedSources $ResolvedSources `
            -ChangeEntries $ChangeEntries -Constructs $Constructs `
            -ConstructFiles $ConstructFiles -RightHandRangesByPath $RightHandRangesByPath
        return Resolve-ReviewerConventionSpecialistCandidates -Marker $convertedV4.Marker `
            -ConventionPlan $ConventionPlan -FactPlan $FactPlan -ResolvedSources $ResolvedSources `
            -ChangeEntries $ChangeEntries -Constructs $Constructs -ConstructFiles $ConstructFiles `
            -ConstructsIncomplete $ConstructsIncomplete -RightHandRangesByPath $RightHandRangesByPath `
            -ContractVersion 3 -DroppedElements $DroppedElements
    }
    $sourceMap = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($source in @($ResolvedSources)) {
        $packName = [string](Get-ReviewerConventionSpecialistValue $source "PackName" "")
        $sourceId = [string](Get-ReviewerConventionSpecialistValue $source "SourceId" "")
        $key = "$packName`n$sourceId"
        if (-not $packName -or -not $sourceId -or $sourceMap.ContainsKey($key)) {
            throw "Resolved convention specialist sources must have unique pack/source identities."
        }
        $sourceMap.Add($key, $source)
    }
    $selectedPacks = @((Get-ReviewerConventionSpecialistValue $ConventionPlan "selectedPacks" @()) | ForEach-Object {
            [string](Get-ReviewerConventionSpecialistValue $_ "name" "")
        })
    $factMap = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($fact in @(Get-ReviewerConventionSpecialistValue $FactPlan "facts" @())) {
        $id = [string](Get-ReviewerConventionSpecialistValue $fact "id" "")
        if ($id -and -not $factMap.ContainsKey($id)) { $factMap.Add($id, $fact) }
    }
    $currentPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($ChangeEntries)) {
        if ([string](Get-ReviewerConventionSpecialistValue $entry "Role" "") -ceq "current") {
            $currentPath = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
                [string](Get-ReviewerConventionSpecialistValue $entry "Path" ""))
            if (-not $currentPath) {
                throw "Convention specialist change entries contain an invalid current repository path."
            }
            if (-not $currentPaths.Add($currentPath)) {
                throw "Convention specialist change entries contain ambiguous duplicate path identity '$currentPath'."
            }
        }
    }
    $canonicalRanges = ConvertTo-ReviewerConventionSpecialistRangesByPath `
        -RightHandRangesByPath $RightHandRangesByPath
    # Contract v3: the model addresses a rule by the same short `rs<n>` the
    # coverage rows use, and the wrapper fills in the provenance itself from the
    # source it actually transported. Under v2 the model retyped a pack name, a
    # repository GUID, a path, a 40-hex commit and a 64-hex digest, and every one
    # of them was a way for a correct finding to be refused over a transcription
    # slip - or, worse, to be accepted while disagreeing with what was really
    # delivered.
    $ruleRefMap = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    if ($ContractVersion -ge 3) {
        foreach ($row in @((Get-ReviewerConventionSpecialistRuleRequest -ResolvedSources $ResolvedSources `
                    -Constructs $Constructs -ContractVersion $ContractVersion).Requested)) {
            $ruleRefMap[[string]$row.ruleRef] = $row
        }
    }
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $accepted = [System.Collections.Generic.List[object]]::new()
    $withheld = [System.Collections.Generic.List[object]]::new()
    foreach ($drop in @($DroppedElements)) {
        $field = [string](Get-ReviewerConventionSpecialistValue $drop "Field" "")
        $reason = [string](Get-ReviewerConventionSpecialistValue $drop "Reason" "")
        # The identifier comes from the extractor, which reports a rejected
        # key by a safe name rather than the model's own. Re-assert that here
        # anyway: this detail is rendered into an artifact a person reads, and
        # it is the one withheld entry the wrapper composes rather than
        # validates, so it does not get to be the exception to the rule that
        # nothing reaches a rendered artifact unchecked.
        # `\z`, not `$`: in .NET `$` also matches before a final newline, so an
        # otherwise-safe identifier ending in one line break would pass.
        if ($field -cnotmatch '^[A-Za-z0-9_.\[\]~-]{0,120}\z') { $field = "unreportableField" }
        if ($reason -cnotmatch '^[A-Za-z0-9]{0,40}\z') { $reason = "unreportableReason" }
        $detail = [string](Get-ReviewerConventionSpecialistShortened `
                -Text ("A result element was withheld because '$field' failed its schema rule ($reason). " +
                    "It was not assessed and must not be read as an absence of findings.") -MaxLength 800)
        if (Test-ReviewerConventionSpecialistVoteText -Text $detail) {
            throw "A withheld result element's diagnostic carried a vote recommendation."
        }
        [void]$withheld.Add([pscustomobject][ordered]@{
                # There is no candidate id to name: the element that carried it
                # is exactly what could not be read.
                candidateId = ""
                reason = "schemaInvalidCandidate"
                detail = $detail
            })
    }
    $changedFileIndex = Get-ReviewerConventionSpecialistChangedFileIndex -ChangeEntries $ChangeEntries `
        -RightHandRangesByPath $RightHandRangesByPath
    foreach ($item in @($Marker.withheld)) {
        if (Test-ReviewerConventionSpecialistVoteText -Text ([string]$item.detail)) {
            throw "Specialist withheld diagnostics carried a vote recommendation."
        }
    }
    foreach ($risk in @($Marker.residualRisks)) {
        if (Test-ReviewerConventionSpecialistVoteText -Text ([string]$risk.text)) {
            throw "Specialist residual risks carried a vote recommendation."
        }
    }
    foreach ($candidate in @($Marker.candidates)) {
        $candidateId = [string]$candidate.candidateId
        if (-not $seenIds.Add($candidateId)) { throw "Specialist output duplicated candidate id '$candidateId'." }
        $candidateRuleRow = $null
        if ($ContractVersion -ge 3) {
            $ruleRef = [string](Get-ReviewerConventionSpecialistValue $candidate "ruleRef" "")
            if (-not $ruleRefMap.ContainsKey($ruleRef)) {
                # A reference to a rule nobody transported is withheld, not
                # guessed at. Withheld rather than thrown because one candidate
                # naming a rule that is not there says nothing about the others.
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; reason = "invalidEvidence"
                        detail = "Candidate cited rule reference '$ruleRef', which the wrapper did not transport."
                    })
                continue
            }
            $candidateRuleRow = $ruleRefMap[$ruleRef]
            $refSource = $candidateRuleRow.source
            foreach ($pair in @(
                    @("packName", "PackName"), @("ruleSourceId", "SourceId"),
                    @("ruleSourceRepositoryId", "RepositoryId"), @("ruleSourcePath", "Path"),
                    @("ruleSourceCommit", "CommitSha"), @("ruleSourceSha256", "Sha256")
                )) {
                $candidate[[string]$pair[0]] = [string](
                    Get-ReviewerConventionSpecialistValue $refSource ([string]$pair[1]) "")
            }
        }
        $anchorKind = [string](Get-ReviewerConventionSpecialistValue $candidate "anchorKind" "")
        $primaryTarget = [string](Get-ReviewerConventionSpecialistValue $candidate "primaryTarget" "")
        $manifestationText = [string](Get-ReviewerConventionSpecialistValue $candidate "manifestations" "")
        $resolvedCandidateTargets = @()
        if ($anchorKind -ceq "prMetadata") {
            if ($primaryTarget -cne "prMetadata" -or $manifestationText) {
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; reason = "invalidTarget"
                        detail = "Metadata candidates require primaryTarget prMetadata and no changed-line manifestations."
                    })
                continue
            }
            if ($ContractVersion -ge 3) {
                $candidate["filePath"] = ""
                $candidate["line"] = 0
            }
        }
        else {
            $primary = Resolve-ReviewerConventionSpecialistTargets -Text $primaryTarget `
                -Constructs $Constructs -ChangedFileAnchors $changedFileIndex -ChangedLinesOnly
            $additional = Resolve-ReviewerConventionSpecialistTargets -Text $manifestationText `
                -Constructs $Constructs -ChangedFileAnchors $changedFileIndex -ChangedLinesOnly
            $full = Resolve-ReviewerConventionSpecialistTargets `
                -Text (@($primaryTarget, $manifestationText | Where-Object { $_ }) -join ",") `
                -Constructs $Constructs -ChangedFileAnchors $changedFileIndex -ChangedLinesOnly
            $targetErrors = @($primary.Errors) + @($additional.Errors) + @($full.Errors)
            $derivedPrimaryTarget = ""
            $derivedManifestations = ""
            if ($ContractVersion -ge 3) {
                # The anchor IS the target. There is only one statement of it, so
                # there is nothing to cross-check and no way for two statements to
                # disagree; the wrapper reads the path and line back off the
                # target it just resolved.
                if ([string]::IsNullOrWhiteSpace($primaryTarget)) {
                    if (@($full.Targets).Count -eq 0) {
                        $targetErrors += "target union did not resolve any changed-line anchors"
                    }
                    elseif ($targetErrors.Count -eq 0) {
                        $deterministicPrimary = @($full.Targets)[0]
                        $derivedPrimaryTarget = [string]$deterministicPrimary.target
                        $derivedManifestations = (@(@($full.Targets) | Select-Object -Skip 1 |
                                ForEach-Object { [string]$_.target }) -join ",")
                        $candidate["filePath"] = [string]$deterministicPrimary.path
                        $candidate["line"] = [int]$deterministicPrimary.line
                    }
                }
                elseif (@($primary.Targets).Count -ne 1) {
                    $targetErrors += "primaryTarget did not resolve to exactly one changed-line anchor"
                }
                else {
                    $candidate["filePath"] = [string]((@($primary.Targets)[0]).path)
                    $candidate["line"] = [int]((@($primary.Targets)[0]).line)
                }
            }
            else {
                $candidatePath = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
                    [string](Get-ReviewerConventionSpecialistValue $candidate "filePath" ""))
                $candidateLine = Get-ReviewerConventionSpecialistValue $candidate "line" $null
                if (@($primary.Targets).Count -ne 1 -or
                    [string]((@($primary.Targets)[0]).path) -cne $candidatePath -or
                    -not (Test-ReviewerConventionSpecialistInteger $candidateLine) -or
                    [int64]((@($primary.Targets)[0]).line) -ne [int64]$candidateLine) {
                    $targetErrors += "primaryTarget does not exactly match the posted filePath and line"
                }
            }
            if ($primaryTarget -and @($full.Targets).Count -gt 0) {
                $deterministicPrimary = @($full.Targets)[0]
                if ([string]$deterministicPrimary.target -cne $primaryTarget.ToLowerInvariant()) {
                    $targetErrors += "primaryTarget is not the deterministic ordinal path/line selection"
                }
            }
            if ($targetErrors.Count -gt 0) {
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; reason = "invalidTarget"
                        detail = Get-ReviewerConventionSpecialistShortened `
                            -Text ("Candidate target validation failed: " + ($targetErrors -join "; ") + ".") `
                            -MaxLength 800
                    })
                continue
            }
            if ($ContractVersion -ge 3 -and [string]::IsNullOrWhiteSpace($primaryTarget)) {
                $candidate.primaryTarget = $derivedPrimaryTarget
                $candidate.manifestations = $derivedManifestations
            }
            else {
                $candidate.primaryTarget = [string]$primary.Canonical
                $candidate.manifestations = [string]$additional.Canonical
            }
            $resolvedCandidateTargets = @($full.Targets)
        }
        $remediationErrors = [string[]](Get-ReviewerConventionSpecialistRemediationErrors `
                -Candidate $candidate -Constructs $Constructs -ConstructFiles $ConstructFiles `
                    -ChangedFileAnchors $changedFileIndex -FactPlan $FactPlan)
        if ($remediationErrors.Count -gt 0) {
            [void]$withheld.Add([pscustomobject][ordered]@{
                    candidateId = $candidateId; reason = "invalidTarget"
                    detail = Get-ReviewerConventionSpecialistShortened `
                        -Text ("Structured remediation validation failed: " +
                            ($remediationErrors -join "; ") + ".") -MaxLength 800
                })
            continue
        }
        $candidate.changedCodeFix.targets = [string](Resolve-ReviewerConventionSpecialistTargets `
            -Text ([string]$candidate.changedCodeFix.targets) -Constructs $Constructs `
            -ChangedFileAnchors $changedFileIndex -AllowPrMetadata:($anchorKind -ceq "prMetadata")).Canonical
        $debt = Get-ReviewerConventionSpecialistValue $candidate "existingDebtFollowUp" $null
        if ([string](Get-ReviewerConventionSpecialistValue $debt "status" "") -ceq "required") {
            $debtFactId = [string](Get-ReviewerConventionSpecialistValue $debt "evidenceFactId" "")
            $debtEvidence = @($ConstructFiles | Where-Object {
                    [string](Get-ReviewerConventionSpecialistValue $_ "evidenceFactId" "") -ceq $debtFactId
                })
            if ($debtEvidence.Count -ne 1) {
                throw "Specialist candidate '$candidateId' lost its validated existing-debt evidence."
            }
            $candidate["existingDebtEvidence"] = $debtEvidence[0]
        }
        if ($selectedPacks -cnotcontains [string]$candidate.packName) {
            throw "Specialist candidate '$candidateId' cited an unrelated convention pack."
        }
        $sourceKey = "$([string]$candidate.packName)`n$([string]$candidate.ruleSourceId)"
        if (-not $sourceMap.ContainsKey($sourceKey)) {
            throw "Specialist candidate '$candidateId' cited an unrelated convention source."
        }
        $source = $sourceMap[$sourceKey]
        foreach ($field in @(
                @("ruleSourceRepositoryId", "RepositoryId"), @("ruleSourcePath", "Path"),
                @("ruleSourceCommit", "CommitSha"), @("ruleSourceSha256", "Sha256")
            )) {
            if (-not [string]::Equals(
                    [string](Get-ReviewerConventionSpecialistValue $candidate ([string]$field[0]) ""),
                    [string](Get-ReviewerConventionSpecialistValue $source ([string]$field[1]) ""),
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw "Specialist candidate '$candidateId' cited stale source provenance."
            }
        }
        $sourceText = ([string](Get-ReviewerConventionSpecialistValue $source "Text" "")).Replace("`r`n", "`n").Replace("`r", "`n")
        $quote = ([string]$candidate.ruleQuote).Replace("`r`n", "`n").Replace("`r", "`n")
        if ($sourceText.IndexOf($quote, [StringComparison]::Ordinal) -lt 0) {
            throw "Specialist candidate '$candidateId' quoted text not present in its provenance-bound source."
        }
        $factIds = @()
        if ([string]$candidate.factIds) { $factIds = @(([string]$candidate.factIds) -split ',') }
        if (@($factIds | Select-Object -Unique).Count -ne $factIds.Count) {
            throw "Specialist candidate '$candidateId' duplicated a deterministic fact id."
        }
        $facts = [System.Collections.Generic.List[object]]::new()
        # Census facts are kept apart from review facts because they are a
        # different KIND of evidence. A review fact carries a canonical
        # true/false state; a complete declaration census carries counts, and
        # its determinism was already established above by requiring the counts
        # and the whole file to be complete. Mixing them meant the state check
        # below - written for review facts - read a census record that has no
        # `state` at all, and threw. That threw out of candidate resolution
        # entirely, degrading the pass to zero candidates and discarding every
        # other finding and rule row in it: exactly the all-or-nothing failure
        # this contract exists to remove, reintroduced through its own new
        # feature and with a wider blast radius than the case it fixed.
        $censusFacts = [System.Collections.Generic.List[object]]::new()
        $invalidEvidence = [System.Collections.Generic.List[string]]::new()
        foreach ($factId in $factIds) {
            # Contract v3 lets an adoption rule cite the declaration census its
            # conclusion actually rests on. Under v2 the only legal citation was
            # a review fact (`rf1:`), so "this attribute is on none of the
            # fifteen declarations in this file" - the whole basis of the
            # finding - had nowhere to be named, and a model that named it
            # anyway had its entire marker refused.
            if ($ContractVersion -ge 3 -and $factId -cmatch '^rdf1:[0-9a-f]{64}$') {
                $census = @($ConstructFiles | Where-Object {
                        [string](Get-ReviewerConventionSpecialistValue $_ "evidenceFactId" "") -ceq $factId
                    })
                if ($census.Count -ne 1) {
                    [void]$invalidEvidence.Add("unknown declaration census '$factId'")
                    continue
                }
                # A partial count is not evidence. It cannot say an attribute is
                # absent; it can only say it was not seen in what was read.
                if (-not [bool](Get-ReviewerConventionSpecialistValue $census[0] "attributeCountsComplete" $false) -or
                    -not [bool](Get-ReviewerConventionSpecialistValue $census[0] "wholeFileComplete" $false)) {
                    [void]$invalidEvidence.Add("declaration census '$factId' is incomplete")
                    continue
                }
                [void]$censusFacts.Add($census[0])
                continue
            }
            if (-not $factMap.ContainsKey($factId)) {
                [void]$invalidEvidence.Add("unknown deterministic fact '$factId'")
                continue
            }
            if (@("true", "false") -cnotcontains [string](
                    Get-ReviewerConventionSpecialistValue $factMap[$factId] "state" "")) {
                [void]$invalidEvidence.Add("fact '$factId' does not have a deterministic state")
                continue
            }
            [void]$facts.Add($factMap[$factId])
        }
        if ($invalidEvidence.Count -gt 0) {
            [void]$withheld.Add([pscustomobject][ordered]@{
                    candidateId = $candidateId; reason = "invalidEvidence"
                    detail = Get-ReviewerConventionSpecialistShortened `
                        -Text ("Candidate evidence validation failed: " +
                            (@($invalidEvidence) -join "; ") + ".") -MaxLength 800
                })
            continue
        }
        if ($ContractVersion -ge 3 -and $null -ne $candidateRuleRow -and
            -not [bool](Get-ReviewerConventionSpecialistValue $candidateRuleRow "siblingEvidenceRequired" $true)) {
            if ($anchorKind -cne "changedFile") {
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; reason = "invalidEvidence"
                        detail = "Local declaration evidence is available only for changed declaration anchors."
                    })
                continue
            }
            $localEvidence = Get-ReviewerConventionSpecialistLocalDeclarationEvidence `
                -Targets $resolvedCandidateTargets -Constructs $Constructs
            if (-not [bool]$localEvidence.Ok) {
                $detail = "Candidate local declaration evidence is incomplete."
                if (@($localEvidence.IncompleteIds).Count -gt 0) {
                    $detail += " Unknown declaration(s): " + ((@($localEvidence.IncompleteIds) |
                            Select-Object -First 8) -join ",") + "."
                }
                if (@($localEvidence.UnanchoredTargets).Count -gt 0) {
                    $detail += " Unanchored target(s): " + ((@($localEvidence.UnanchoredTargets) |
                            Select-Object -First 8) -join ",") + "."
                }
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; reason = "invalidEvidence"
                        detail = Get-ReviewerConventionSpecialistShortened -Text $detail -MaxLength 800
                    })
                continue
            }
            $candidate["siblingStatus"] = "checked"
            $candidate["siblingEvidence"] = [string]$localEvidence.Evidence
            $candidate["siblingNotRequiredReason"] = ""
        }
        if ([string]$candidate.severity -ceq "important") {
            $candidateSiblingStatus = [string](Get-ReviewerConventionSpecialistValue `
                $candidate "siblingStatus" "")
            # A complete census is deterministic evidence in its own right: it
            # is the count that says an attribute is on none of the declarations
            # in a file, which is precisely the argument that justifies
            # escalating past `suggestion` for an adoption rule.
            $evidenceCount = $facts.Count + $censusFacts.Count
            if ([string]$candidate.impactCategory -ceq "none") {
                throw "Specialist candidate '$candidateId' escalated severity without a protected impact category."
            }
            if ($evidenceCount -eq 0 -and $candidateSiblingStatus -cne "checked") {
                throw "Specialist candidate '$candidateId' used important severity without a deterministic fact or checked sibling evidence (status '$candidateSiblingStatus')."
            }
            if ($evidenceCount -eq 0 -and ([string]$candidate.siblingEvidence).Trim().Length -lt 16) {
                throw "Specialist candidate '$candidateId' used important severity without meaningful checked sibling evidence."
            }
            # Every id left in $facts already passed the per-fact deterministic
            # state check above, which withholds rather than throws. There is
            # deliberately no second state guard here: an unreachable one reads
            # like a live defence and would rot untested.
        }
        elseif ([string]$candidate.impactCategory -cne "none") {
            throw "Specialist candidate '$candidateId' classified protected impact but did not use important severity."
        }
        if ([string]$candidate.siblingStatus -ceq "checked") {
            if ([string]::IsNullOrWhiteSpace([string]$candidate.siblingEvidence) -or
                -not [string]::IsNullOrWhiteSpace([string]$candidate.siblingNotRequiredReason)) {
                throw "Specialist candidate '$candidateId' has invalid sibling evidence."
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$candidate.siblingEvidence) -or
            [string]::IsNullOrWhiteSpace([string]$candidate.siblingNotRequiredReason)) {
            throw "Specialist candidate '$candidateId' omitted the reason sibling evidence was not required."
        }
        foreach ($textField in @(
                "ruleSection", "ruleQuote", "diffEvidence", "impact", "expectedFixOrValidation",
                "siblingEvidence", "siblingNotRequiredReason", "residualRiskSummary"
            )) {
            if (Test-ReviewerConventionSpecialistVoteText -Text ([string](Get-ReviewerConventionSpecialistValue $candidate $textField ""))) {
                throw "Specialist candidate '$candidateId' carried a vote recommendation."
            }
        }
        if ([string]$candidate.anchorKind -ceq "changedFile") {
            $relativePath = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
                [string]$candidate.filePath)
            $lineInChangedRange = $false
            if ($canonicalRanges.ContainsKey($relativePath)) {
                foreach ($range in @($canonicalRanges[$relativePath])) {
                    $startLine = [int](Get-ReviewerConventionSpecialistValue $range "startLine" 0)
                    $endLine = [int](Get-ReviewerConventionSpecialistValue $range "endLine" 0)
                    if ([int]$candidate.line -ge $startLine -and [int]$candidate.line -le $endLine) {
                        $lineInChangedRange = $true
                        break
                    }
                }
            }
            if (-not [string]$candidate.filePath -or [int]$candidate.line -lt 1 -or
                -not $currentPaths.Contains($relativePath) -or
                ($canonicalRanges.Count -gt 0 -and -not $lineInChangedRange)) {
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId
                        reason = "outsideChangedFile"
                        detail = "The claimed file/line is not a current changed-file anchor; it was withheld and not relocated."
                    })
                continue
            }
            $candidate.filePath = $relativePath
        }
        else {
            if ([string]$candidate.filePath -or [int]$candidate.line -ne 0 -or $facts.Count -eq 0 -or
                @($facts | Where-Object {
                        [string](Get-ReviewerConventionSpecialistValue $_ "domain" "") -cne "metadata" -or
                        @("true", "false") -cnotcontains [string](Get-ReviewerConventionSpecialistValue $_ "state" "")
                    }).Count -gt 0) {
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId
                        reason = "invalidAnchor"
                        detail = "PR metadata anchors require only deterministic true/false metadata facts; it was withheld and not relocated."
                    })
                continue
            }
        }
        [void]$accepted.Add($candidate)
    }
    foreach ($item in @($Marker.withheld)) { [void]$withheld.Add($item) }
    # The accounting runs LAST and over the ACCEPTED candidates, so it describes
    # the pass that actually happened rather than the one the model proposed.
    $coverageRows = @()
    if ($Marker.ContainsKey("ruleCoverage")) { $coverageRows = @($Marker.ruleCoverage) }
    $coverage = Resolve-ReviewerConventionSpecialistRuleCoverage -Rows $coverageRows `
        -ResolvedSources $ResolvedSources `
        -AcceptedCandidates $accepted.ToArray() -Constructs $Constructs `
        -ChangedFileAnchors $changedFileIndex `
        -ConstructsIncomplete $ConstructsIncomplete `
        -WithheldCandidateIds @(@($withheld) | ForEach-Object {
                [string](Get-ReviewerConventionSpecialistValue $_ "candidateId" "")
            } | Where-Object { $_ })
    # A manifestation is not merely any changed line. It must be one of the
    # exact changed-line violations in the linked rule row, or lie inside one of
    # that row's truthful lexical violation constructs. This keeps unrelated
    # changed lines from changing semantic identity or widening fix scope.
    $retained = [System.Collections.Generic.List[object]]::new()
    $constructById = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($construct in @($Constructs)) {
        $id = [string](Get-ReviewerConventionSpecialistValue $construct "constructId" "")
        if ($id -and
            [string](Get-ReviewerConventionSpecialistValue $construct "status" "known") -ceq "known" -and
            -not $constructById.ContainsKey($id)) {
            $constructById.Add($id, $construct)
        }
    }
    foreach ($candidate in @($accepted)) {
        if ([string](Get-ReviewerConventionSpecialistValue $candidate "anchorKind" "") -cne "changedFile") {
            [void]$retained.Add($candidate)
            continue
        }
        $rows = @($coverage.Rows | Where-Object {
               [string]$_.packName -ceq [string]$candidate.packName -and
               [string]$_.ruleSourceId -ceq [string]$candidate.ruleSourceId
            })
        $manifestations = Resolve-ReviewerConventionSpecialistTargets -Text (
            @([string]$candidate.primaryTarget, [string]$candidate.manifestations |
               Where-Object { $_ }) -join ",") -ChangedFileAnchors $changedFileIndex -ChangedLinesOnly
        $unsupported = [System.Collections.Generic.List[string]]::new()
        if ($rows.Count -ne 1 -or -not $manifestations.Ok) {
            [void]$unsupported.Add([string]$candidate.primaryTarget)
        }
        else {
            $row = $rows[0]
            $allowedLines = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($target in @($row.violatingChangedFileTargets)) { [void]$allowedLines.Add([string]$target) }
            $violationConstructs = @($row.violatingConstructs | Where-Object {
                   $constructById.ContainsKey([string]$_)
               } | ForEach-Object { $constructById[[string]$_] })
            foreach ($manifestation in @($manifestations.Targets)) {
               if ($allowedLines.Contains([string]$manifestation.target)) { continue }
               $insideViolation = @($violationConstructs | Where-Object {
                       (ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path (
                           [string](Get-ReviewerConventionSpecialistValue $_ "path" ""))) -ceq
                           [string]$manifestation.path -and
                       [int64]$manifestation.line -ge
                           [int64](Get-ReviewerConventionSpecialistValue $_ "line" 0) -and
                       [int64]$manifestation.line -le
                           [int64](Get-ReviewerConventionSpecialistValue $_ "endLine" 0)
                   }).Count -gt 0
               if (-not $insideViolation) { [void]$unsupported.Add([string]$manifestation.target) }
            }
        }
        if ($unsupported.Count -gt 0) {
            [void]$withheld.Add([pscustomobject][ordered]@{
                   candidateId = [string]$candidate.candidateId
                   reason = "invalidTarget"
                   detail = "Manifestations are not exact violations in the candidate's authoritative rule row: " +
                       (@($unsupported) -join ",") + "."
               })
        }
        else { [void]$retained.Add($candidate) }
    }
    if ($retained.Count -ne $accepted.Count) {
        $coverage = Resolve-ReviewerConventionSpecialistRuleCoverage -Rows $coverageRows `
            -ResolvedSources $ResolvedSources -AcceptedCandidates $retained.ToArray() `
            -Constructs $Constructs -ChangedFileAnchors $changedFileIndex `
            -ConstructsIncomplete $ConstructsIncomplete `
            -WithheldCandidateIds @(@($withheld) | ForEach-Object {
                   [string](Get-ReviewerConventionSpecialistValue $_ "candidateId" "")
               } | Where-Object { $_ })
    }
    # A rule the model called violated but never emitted is recorded through the
    # EXISTING withheld channel, not a second one. Two lists that both mean
    # "nearly a finding" is exactly where a later edit promotes one.
    foreach ($unemitted in @($coverage.UnemittedViolations)) {
        $detail = "Rule accounting reported a violation of '$([string]$unemitted.ruleSourceId)' in pack '$([string]$unemitted.packName)' but the pass emitted no candidate for it."
        $note = [string]$unemitted.notes
        if ($note) { $detail = "$detail Stated reason: $note" }
        if ($detail.Length -gt 800) { $detail = Get-ReviewerConventionSpecialistShortened -Text $detail -MaxLength 800 }
        [void]$withheld.Add([pscustomobject][ordered]@{
                candidateId = ""
                reason = "accountedNotEmitted"
                detail = $detail
            })
    }
    return @{
        Candidates = $retained.ToArray()
        Withheld = $withheld.ToArray()
        ResidualRisks = @($Marker.residualRisks)
        RuleCoverage = $coverage
        ChangedFileIndex = $changedFileIndex
    }
}

function New-ReviewerConventionSpecialistInput {
    param(
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][string]$Nonce,
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][int]$PrId,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$TargetCommit,
        [Parameter(Mandatory)][string]$ChangeSetDigest,
        [Parameter(Mandatory)][string]$ConventionPlanSha256,
        [Parameter(Mandatory)][string]$FactPlanSha256,
        [Parameter(Mandatory)][string]$ConfigSha256,
        [Parameter(Mandatory)][string]$ScriptSha256,
        [Parameter(Mandatory)][string]$PromptSha256,
        [Parameter(Mandatory)]$ConventionPlan,
        [Parameter(Mandatory)]$FactPlan,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ResolvedSources,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ChangeEntries,
        # The constructs the wrapper enumerated from the change set. Named here
        # rather than left to the model to find, because the accounting is
        # reconciled against exactly this set.
        [AllowEmptyCollection()][object[]]$Constructs = @(),
        [AllowEmptyCollection()][object[]]$ConstructFiles = @(),
        $ConstructIdRanges = $null,
        [hashtable]$RightHandRangesByPath = @{},
        [Parameter(Mandatory)][AllowEmptyString()][string]$ThreadDigestText,
        [AllowEmptyString()][string]$PinnedSourceText = "",
        # Non-empty only in offline replay. The prompt tells this pass to
        # re-read the pull request and stop without a marker if it cannot; in
        # replay it cannot, because it has no repository tool at all. Without
        # saying so here the pass fails closed for a reason that is not a
        # finding about the change.
        [AllowEmptyString()][string]$ReplayNotice = "",
        [ValidateSet(2, 3, 4)][int]$ContractVersion = 2,
        [int]$MaxInputBytes = $script:ReviewerConventionSpecialistMaxInputBytes
    )
    if (@($ResolvedSources).Count -eq 0) {
        throw "Convention specialist input requires at least one resolved convention source."
    }
    if (@($ChangeEntries).Count -eq 0) {
        throw "Convention specialist input requires at least one pinned change entry."
    }
    $sourceRecords = @($ResolvedSources | ForEach-Object {
            [pscustomobject][ordered]@{
                packName = [string](Get-ReviewerConventionSpecialistValue $_ "PackName" "")
                sourceId = [string](Get-ReviewerConventionSpecialistValue $_ "SourceId" "")
                trustTier = [string](Get-ReviewerConventionSpecialistValue $_ "TrustTier" "")
                organization = [string](Get-ReviewerConventionSpecialistValue $_ "Organization" "")
                project = [string](Get-ReviewerConventionSpecialistValue $_ "Project" "")
                repositoryId = [string](Get-ReviewerConventionSpecialistValue $_ "RepositoryId" "")
                path = [string](Get-ReviewerConventionSpecialistValue $_ "Path" "")
                section = [string](Get-ReviewerConventionSpecialistValue $_ "Section" "")
                commitSha = [string](Get-ReviewerConventionSpecialistValue $_ "CommitSha" "")
                sha256 = [string](Get-ReviewerConventionSpecialistValue $_ "Sha256" "")
                mimeType = [string](Get-ReviewerConventionSpecialistValue $_ "MimeType" "")
                byteLength = [int](Get-ReviewerConventionSpecialistValue $_ "ByteLength" 0)
                text = [string](Get-ReviewerConventionSpecialistValue $_ "Text" "")
            }
        })
    $ruleRequest = Get-ReviewerConventionSpecialistRuleRequest -ResolvedSources $ResolvedSources `
        -Constructs $Constructs -ContractVersion $ContractVersion -ConventionPlan $ConventionPlan
    # The anchor list is bounded too. It is only a naming convenience for the
    # rows - every path in it is already in `changedFiles` - and letting it grow
    # with a thousand-file change set would push the envelope past its bound and
    # turn today's graceful "pinned source dropped" degrade into a hard failure
    # of the whole pass.
    # Assign the `,`-protected index directly: wrapping the call in @() nests
    # the whole index as a single Object[] element instead of flattening it, so
    # the anchor list handed to the model (and its .Count truncation check)
    # would collapse to one bogus entry. Direct assignment keeps the real
    # per-file anchors, and still round-trips a zero- or one-file change set as
    # an array because the function returns a protected array.
    $fullAnchorIndex = Get-ReviewerConventionSpecialistChangedFileIndex -ChangeEntries $ChangeEntries `
        -RightHandRangesByPath $RightHandRangesByPath
    $anchorsTruncated = ($fullAnchorIndex.Count -gt $script:ReviewerConventionSpecialistMaxCoverageAnchors)
    $anchorIndex = @($fullAnchorIndex | Select-Object -First $script:ReviewerConventionSpecialistMaxCoverageAnchors)
    $runtime = [pscustomobject][ordered]@{
        contract = "convention-specialist-v1"
        nonce = $Nonce
        binding = [pscustomobject][ordered]@{
            organization = $Organization
            project = $Project
            repositoryId = $RepositoryId
            pullRequestId = $PrId
            sourceCommit = $SourceCommit
            targetCommit = $TargetCommit
            changeSetDigest = $ChangeSetDigest
        }
        hashes = [pscustomobject][ordered]@{
            conventionPlanSha256 = $ConventionPlanSha256
            factPlanSha256 = $FactPlanSha256
            configSha256 = $ConfigSha256
            scriptSha256 = $ScriptSha256
            promptSha256 = $PromptSha256
        }
        conventionPlan = $ConventionPlan
        factPlan = $FactPlan
        resolvedConventionSources = $sourceRecords
        changedFiles = @($ChangeEntries)
        # The exact accounting the wrapper will reconcile against. Naming it
        # here rather than leaving the model to infer it is what turns the
        # checklist from a request into a contract: the rows below are the rows
        # that must come back, one each, and the anchor ids are the only anchors
        # a row may cite.
        ruleCoverageRequest = [pscustomobject][ordered]@{
            requiredRows = @($ruleRequest.Requested | ForEach-Object {
                    $row = [ordered]@{
                        ruleRef = [string]$_.ruleRef
                        packName = [string]$_.packName
                        ruleSourceId = [string]$_.ruleSourceId
                        ruleSourceSha256 = [string]$_.ruleSourceSha256
                    }
                    if ($ContractVersion -ge 3) {
                        $row["siblingEvidenceRequired"] = [bool]$_.siblingEvidenceRequired
                        $row["locallyAdjudicableConstructs"] = [string]$_.locallyAdjudicableConstructs
                    }
                    if ($ContractVersion -eq 4) {
                        # The EXACT id set this row owes a verdict for, already
                        # range-compressed. The model never derives it, because
                        # deriving it is what five of ten qualification runs got
                        # wrong; and `inScopeResolved` false means the wrapper
                        # could not establish the set at all, which is not the
                        # same as a rule that reaches nothing.
                        $row["inScopeResolved"] = [bool]$_.inScopeResolved
                        $row["inScopeConstructs"] = [string]$_.inScopeConstructs
                    }
                    [pscustomobject]$row
                })
            unrequestedSources = @($ruleRequest.Unrequested)
            changedFileAnchors = @($anchorIndex)
            changedFileAnchorsTruncated = $anchorsTruncated
            # Every construct this change set touched, with the shape facts a
            # rule might turn on: for a call, whether each argument is
            # syntactically named; for a declaration, which attributes sit on
            # it and which sit on its unchanged neighbours. What any of that
            # MEANS is the transported rule's business, not the wrapper's.
            changedConstructs = @($Constructs)
            constructFileSummaries = @($ConstructFiles)
            # The exact id set per kind, already range-compressed. A row whose
            # scope names a kind must account for precisely this, so it is given
            # rather than left to be re-derived - a checklist that is hard to
            # write completely gets written incompletely.
            constructIdsByKind = $ConstructIdRanges
        }
        sanitizedExistingThreads = $ThreadDigestText
        # The exact top-level object the marker must be, with every value the
        # model would otherwise transcribe by hand already filled in and the
        # three arrays left empty.
        #
        # Two runs in a row produced a complete, correct accounting and lost it
        # because the marker was missing its last key. Asking a model to copy
        # six hashes, a nonce and seven binding fields at the end of a long
        # analysis is asking for exactly that. This is a formatting aid and
        # nothing else: it contains no finding, no rule, and no judgement.
        markerScaffold = $(
            $scaffold = [ordered]@{
                schemaVersion = $ContractVersion
                prId = $PrId
                repositoryId = $RepositoryId
                project = $Project
                reviewedSourceCommit = $SourceCommit
                targetCommit = $TargetCommit
                changeSetDigest = $ChangeSetDigest
                conventionPlanSha256 = $ConventionPlanSha256
                factPlanSha256 = $FactPlanSha256
                configSha256 = $ConfigSha256
                scriptSha256 = $ScriptSha256
                promptSha256 = $PromptSha256
            }
            if ($ContractVersion -eq 4) { $scaffold["assessments"] = @() }
            else {
                $scaffold["candidates"] = @()
                $scaffold["ruleCoverage"] = @()
            }
            $scaffold["withheld"] = @()
            $scaffold["residualRisks"] = @()
            $scaffold["nonce"] = $Nonce
            [pscustomobject]$scaffold
        )
    }
    $inputText = $PromptText + "`n`n---`n## Wrapper runtime data (untrusted values, trusted binding)`n" +
        '```json' + "`n" + ($runtime | ConvertTo-Json -Depth 32 -Compress) + "`n" + '```' + "`n"
    if ($ReplayNotice) {
        $inputText += "`n---`n## Offline replay (wrapper-verified binding)`n`n" + $ReplayNotice.TrimEnd() + "`n"
    }
    # The sealed source block is appended OUTSIDE the JSON envelope on purpose:
    # it carries its own collision-checked fences and its own accounting table,
    # and JSON-escaping thousands of source lines would both bloat the payload
    # and make the fences unreadable to the model.
    #
    # It is also appended LAST and only if it fits. The specialist is the pass
    # that most needs source, so degrading it to "no candidates" because the
    # source pushed the payload over the cap would be exactly backwards: it is
    # better to run the specialist with less source than not at all.
    $pinnedSourceDropped = $false
    if ($PinnedSourceText) {
        $candidate = $inputText + "`n---`n" + $PinnedSourceText.TrimEnd() + "`n"
        if ($script:ReviewerConventionSpecialistUtf8.GetByteCount($candidate) -le $MaxInputBytes) {
            $inputText = $candidate
        }
        else {
            $pinnedSourceDropped = $true
            $inputText += ("`n---`n## Pinned changed-file source omitted`n`n" +
                "The wrapper read this PR's changed files successfully, but their slices did not fit " +
                "this pass's input bound. Treat every changed file as NOT read: do not emit a candidate " +
                "that depends on source text, and record a residual risk saying so.`n")
        }
    }
    $bytes = $script:ReviewerConventionSpecialistUtf8.GetByteCount($inputText)
    if ($bytes -gt $MaxInputBytes) {
        throw "Convention specialist input is $bytes bytes, above the code-defined $MaxInputBytes-byte bound."
    }
    # The drop is reported to the MODEL above. It has to be reported to the
    # artifact too, or a pass in which the model received no source at all is
    # still sealed beside a coverage record claiming every file was delivered.
    return @{ Text = $inputText; Bytes = $bytes; PinnedSourceDropped = $pinnedSourceDropped }
}

function Save-ReviewerConventionSpecialistPreview {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][byte[]]$MasterKey
    )
    if ($BaseName -notmatch '^[A-Za-z0-9._-]+$') { throw "Convention specialist preview base name is unsafe." }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Convention specialist preview directory '$Directory' does not exist."
    }
    $manifestJson = ConvertTo-ReviewerConventionSpecialistCanonicalJson -Value $Manifest
    $key = Get-ReviewerConventionSpecialistDomainKey -MasterKey $MasterKey -Domain preview
    $envelope = [ordered]@{
        manifestJson = $manifestJson
        signatureAlg = "HMACSHA256"
        signature = Get-ReviewerConventionSpecialistSignature -Json $manifestJson -Key $key
    }
    $path = Join-Path $Directory ($BaseName + ".json")
    [IO.File]::WriteAllText(
        $path,
        ($envelope | ConvertTo-Json -Depth 4),
        $script:ReviewerConventionSpecialistUtf8)
    return $path
}

function Read-ReviewerConventionSpecialistPreview {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$MasterKey
    )
    $envelope = [IO.File]::ReadAllText($Path, $script:ReviewerConventionSpecialistUtf8) | ConvertFrom-Json
    $manifestJson = [string](Get-ReviewerConventionSpecialistValue $envelope "manifestJson" "")
    $signature = [string](Get-ReviewerConventionSpecialistValue $envelope "signature" "")
    $key = Get-ReviewerConventionSpecialistDomainKey -MasterKey $MasterKey -Domain preview
    if (-not $manifestJson -or
        -not (Test-ReviewerConventionSpecialistSignature -Json $manifestJson -Key $key -Signature $signature)) {
        throw "Convention specialist preview signature verification failed."
    }
    $manifest = $manifestJson | ConvertFrom-Json -Depth 32
    if ([string](Get-ReviewerConventionSpecialistValue $manifest "kind" "") -cne $script:ReviewerConventionSpecialistArtifactKind -or
        [int](Get-ReviewerConventionSpecialistValue $manifest "artifactVersion" 0) -ne $script:ReviewerConventionSpecialistArtifactVersion) {
        throw "Convention specialist preview kind or version is invalid."
    }
    return $manifest
}
