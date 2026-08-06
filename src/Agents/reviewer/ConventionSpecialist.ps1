#requires -Version 7.0

Set-StrictMode -Version Latest

$script:ReviewerConventionSpecialistMarkerPrefix = "CONVENTION_REVIEW_RESULT_V1:"
$script:ReviewerConventionSpecialistArtifactKind = "convention-specialist-preview"
$script:ReviewerConventionSpecialistArtifactVersion = 1
$script:ReviewerConventionSpecialistMaxCandidates = 8
# The accounting shares the result marker's brace-scan window with the
# candidate array, so it is bounded on BOTH axes: at most this many rows, each
# with tightly bounded fields. A transported set larger than this is not
# silently sampled - the request states the cap and the reconciliation reports
# the remainder as unaccounted by construction.
$script:ReviewerConventionSpecialistMaxRuleCoverage = 10
$script:ReviewerConventionSpecialistMaxCoverageAnchors = 200
$script:ReviewerConventionSpecialistMaxInputBytes = 327680
$script:ReviewerConventionSpecialistUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$script:ReviewerConventionSpecialistImpactCategories = @(
    "none", "buildOrTestExecution", "deployment", "security", "customerBehavior", "compatibility"
)
$script:ReviewerConventionSpecialistWithheldReasons = @(
    "sourceConflict", "outsideChangedFile", "invalidAnchor", "unverifiedSource",
    "unknownFact", "unsupportedSeverity", "missingSiblingEvidence", "duplicateCandidate",
    "duplicateExistingThread", "accountedNotEmitted"
)
$script:ReviewerConventionSpecialistCoverageStatuses = @(
    "violation", "compliant", "notApplicable", "unknown"
)
# What a rule was judged against. The scope names the construct KINDS the rule
# governs, and the wrapper turns that into the exact set of ids the row must
# account for, so it cannot be left to prose.
$script:ReviewerConventionSpecialistCoverageScopePattern =
'^(none|(invocation|declaration|comment|assignment)(,(invocation|declaration|comment|assignment))*)$'

# The kinds of changed construct the wrapper enumerates. A row's scope is a set
# of these, so "which constructs does this row owe an answer for" is a wrapper
# fact and not a phrase the model can widen or narrow to suit its answer.
$script:ReviewerConventionSpecialistConstructKinds = @(
    "invocation", "declaration", "comment", "assignment"
)
$script:ReviewerConventionSpecialistConstructPrefixes = @{
    invocation = "mi"; declaration = "dc"; comment = "cm"; assignment = "as"
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
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $ids = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($part in @(($Text -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $match = [regex]::Match($part, '^([a-z]{2})([0-9]{1,3})(?:-([a-z]{2})([0-9]{1,3}))?$')
        if (-not $match.Success) { return @{ Ok = $false; Ids = @() } }
        $prefix = $match.Groups[1].Value
        if (@($script:ReviewerConventionSpecialistConstructPrefixes.Values) -cnotcontains $prefix) {
            return @{ Ok = $false; Ids = @() }
        }
        $first = [int]$match.Groups[2].Value
        $last = $first
        if ($match.Groups[3].Success) {
            if ($match.Groups[3].Value -cne $prefix) { return @{ Ok = $false; Ids = @() } }
            $last = [int]$match.Groups[4].Value
            if ($last -lt $first) { return @{ Ok = $false; Ids = @() } }
        }
        for ($index = $first; $index -le $last; $index++) {
            $id = "$prefix$index"
            if ($seen.Add($id)) { [void]$ids.Add($id) }
        }
    }
    return @{ Ok = $true; Ids = @($ids.ToArray()) }
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
        $Value -is [double] -or $Value -is [decimal]) {
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
    param(
        [Parameter(Mandatory)][string]$ExpectedProject,
        [Parameter(Mandatory)][string]$ExpectedNonce,
        [int]$MaxCandidateItems = $script:ReviewerConventionSpecialistMaxCandidates
    )
    $ascii = '^[\x20-\x7E]*$'
    $candidateKeys = @(
        "candidateId", "category", "severity", "anchorKind", "filePath", "line",
        "packName", "ruleSourceId", "ruleSourceRepositoryId", "ruleSourcePath",
        "ruleSourceCommit", "ruleSourceSha256", "ruleSection", "ruleQuote",
        "diffEvidence", "impactCategory", "impact", "expectedFixOrValidation",
        "siblingStatus", "siblingEvidence", "siblingNotRequiredReason",
        "factIds", "confidence", "residualRiskSummary"
    )
    return @{
        Keys = @(
            "schemaVersion", "prId", "repositoryId", "project", "reviewedSourceCommit",
            "targetCommit", "changeSetDigest", "conventionPlanSha256", "factPlanSha256",
            "configSha256", "scriptSha256", "promptSha256",
            "candidates", "ruleCoverage", "withheld", "residualRisks", "nonce"
        )
        Fields = @{
            schemaVersion = @{ Type = "int"; Min = 1; Max = 1 }
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
                Item = @{
                    Keys = $candidateKeys
                    Fields = @{
                        candidateId = @{ Type = "string"; MaxLength = 64; Pattern = '^[a-z][a-z0-9-]{0,63}$' }
                        category = @{ Type = "exact"; Expected = "convention" }
                        severity = @{ Type = "enum"; Values = @("suggestion", "important") }
                        anchorKind = @{ Type = "enum"; Values = @("changedFile", "prMetadata") }
                        filePath = @{ Type = "string"; MaxLength = 400; AllowEmpty = $true; Pattern = '^/?[\x20-\x21\x23-\x29\x2B-\x39\x3B\x3D\x40-\x5B\x5D-\x7B\x7D-\x7E]*$' }
                        line = @{ Type = "int"; Min = 0; Max = 1000000 }
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
                            Pattern = '^(|rf1:[0-9a-f]{64}(,rf1:[0-9a-f]{64}){0,7})$'
                        }
                        confidence = @{ Type = "enum"; Values = @("low", "medium", "high") }
                        residualRiskSummary = @{ Type = "string"; MaxLength = 800; AllowEmpty = $true; Pattern = $ascii; NormalizeTypography = $true }
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
            # A row anchors on CONSTRUCT IDS, not on file and line. The wrapper
            # enumerated every changed construct itself, so an id resolves to an
            # exact path and line that the wrapper can check - and, more to the
            # point, `checkedConstructs` has to name every construct in the
            # declared scope. That is what stops "named parameters: compliant"
            # from meaning "I looked at one call". Judging which constructs a
            # rule applies to is still the model's job against the rule text;
            # covering all of them is not optional.
            ruleCoverage = @{
                Type = "objectArray"; MaxItems = $script:ReviewerConventionSpecialistMaxRuleCoverage
                Item = @{
                    Keys = @(
                        "ruleRef", "ruleSourceSha256", "ruleQuote", "status",
                        "scope", "checkedConstructs", "notInReachConstructs",
                        "violatingConstructs",
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
                        # 200 rather than 400: ranges make a complete list four
                        # short spans, so the extra room bought nothing, and the
                        # whole section has to stay well inside the marker's
                        # scan window - which it shares with the candidates.
                        checkedConstructs = @{
                            Type = "string"; MaxLength = 200; AllowEmpty = $true
                            Pattern = '^(|(mi|dc|cm|as)[0-9]{1,3}(-(mi|dc|cm|as)[0-9]{1,3})?(,(mi|dc|cm|as)[0-9]{1,3}(-(mi|dc|cm|as)[0-9]{1,3})?)*)$'
                        }
                        # Constructs the row looked at and judged outside the
                        # rule's reach. Without this the model's only honest
                        # options are to list a production method as "checked"
                        # against a rule about tests, or to leave it out and be
                        # degraded - and it kept choosing the second. Narrowing
                        # is a real judgement and deserves somewhere to be
                        # written down; what is NOT allowed is silence.
                        notInReachConstructs = @{
                            Type = "string"; MaxLength = 200; AllowEmpty = $true
                            Pattern = '^(|(mi|dc|cm|as)[0-9]{1,3}(-(mi|dc|cm|as)[0-9]{1,3})?(,(mi|dc|cm|as)[0-9]{1,3}(-(mi|dc|cm|as)[0-9]{1,3})?)*)$'
                        }
                        violatingConstructs = @{
                            Type = "string"; MaxLength = 200; AllowEmpty = $true
                            Pattern = '^(|(mi|dc|cm|as)[0-9]{1,3}(-(mi|dc|cm|as)[0-9]{1,3})?(,(mi|dc|cm|as)[0-9]{1,3}(-(mi|dc|cm|as)[0-9]{1,3})?)*)$'
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
                        codeEvidence = @{ Type = "string"; MaxLength = 600; AllowEmpty = $true; Truncate = $true }
                        siblingStatus = @{ Type = "enum"; Values = @("checked", "notRequired", "unavailable") }
                        siblingEvidence = @{ Type = "string"; MaxLength = 600; AllowEmpty = $true; Truncate = $true }
                        candidateId = @{ Type = "string"; MaxLength = 64; AllowEmpty = $true; Pattern = '^(|[a-z][a-z0-9-]{0,63})$' }
                        notes = @{ Type = "string"; MaxLength = 600; AllowEmpty = $true; Truncate = $true }
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
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ChangeEntries)
    $paths = @(@($ChangeEntries) |
        Where-Object { [string](Get-ReviewerConventionSpecialistValue $_ "Role" "") -ceq "current" } |
        ForEach-Object { [string](Get-ReviewerConventionSpecialistValue $_ "Path" "") } |
        Where-Object { $_ } |
        Select-Object -Unique)
    $sorted = [string[]]@($paths)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $index = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        [void]$index.Add([pscustomobject][ordered]@{ anchorId = "cf$i"; path = $sorted[$i] })
    }
    return , $index.ToArray()
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
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ResolvedSources,
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
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $key = "{0}/{1}" -f `
            [string](Get-ReviewerConventionSpecialistValue $ordered[$i] "PackName" ""),
        [string](Get-ReviewerConventionSpecialistValue $ordered[$i] "SourceId" "")
        if ($i -ge $MaxRows) { [void]$unrequested.Add($key); continue }
        [void]$requested.Add([pscustomobject][ordered]@{
                ruleRef = "rs$i"
                packName = [string](Get-ReviewerConventionSpecialistValue $ordered[$i] "PackName" "")
                ruleSourceId = [string](Get-ReviewerConventionSpecialistValue $ordered[$i] "SourceId" "")
                ruleSourceSha256 = [string](Get-ReviewerConventionSpecialistValue $ordered[$i] "Sha256" "")
                source = $ordered[$i]
            })
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
        # The constructs the wrapper enumerated from the change set. A row has
        # to account for every one of them within the scope it declares.
        [AllowEmptyCollection()][object[]]$Constructs = @(),
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

    $candidateIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $candidateAnchors = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $candidateRuleKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($candidate in @($AcceptedCandidates)) {
        $candidateId = [string](Get-ReviewerConventionSpecialistValue $candidate "candidateId" "")
        [void]$candidateIds.Add($candidateId)
        $candidateAnchors[$candidateId] = "{0}|{1}" -f `
            (([string](Get-ReviewerConventionSpecialistValue $candidate "filePath" "")).TrimStart("/")),
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
        $ruleRef = [string](Get-ReviewerConventionSpecialistValue $row "ruleRef" "")
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
        $scopeKinds = @(@($scope -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -cne "none" })
        $checkedResult = Expand-ReviewerConventionSpecialistConstructIds `
            -Text ([string](Get-ReviewerConventionSpecialistValue $row "checkedConstructs" ""))
        $checked = @($checkedResult.Ids)
        $notInReachResult = Expand-ReviewerConventionSpecialistConstructIds `
            -Text ([string](Get-ReviewerConventionSpecialistValue $row "notInReachConstructs" ""))
        $notInReach = @($notInReachResult.Ids)
        $violatingResult = Expand-ReviewerConventionSpecialistConstructIds `
            -Text ([string](Get-ReviewerConventionSpecialistValue $row "violatingConstructs" ""))
        $violating = @($violatingResult.Ids)
        if ((-not $checkedResult.Ok) -or (-not $notInReachResult.Ok) -or (-not $violatingResult.Ok)) {
            $status = "unknown"
            if (-not $degradedReason) { $degradedReason = "the row wrote a construct range the wrapper could not read" }
        }
        # A construct is either one the rule reaches or one it does not. Claiming
        # both about the same construct is not an accounting, it is two.
        $bothWays = @(@($checked) | Where-Object { $notInReach -ccontains $_ })
        if ($bothWays.Count -gt 0) {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = "the row called the same construct both checked and out of reach: " +
                (@($bothWays | Select-Object -First 20) -join ",")
            }
        }
        # Out of reach is a judgement about the rule, not a place to file a
        # violation.
        $violatingOutOfReach = @(@($violating) | Where-Object { $notInReach -ccontains $_ })
        if ($violatingOutOfReach.Count -gt 0) {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = "the row called a construct out of the rule's reach and a violation of it at the same time"
            }
        }

        # The scope decides which constructs this row OWES an answer for. A row
        # that says a rule is compliant while leaving constructs in its own
        # declared scope unmentioned has not checked them, and saying so is the
        # whole point of this section.
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
        # `none` cannot be a free pass, and neither can declaring a scope and
        # then putting every construct in it out of reach. A row that examined
        # nothing has checked nothing, however it spells that - which is the
        # exact shape of the miss this section exists to make visible.
        $reachedNothing = ($constructById.Count -gt 0 -and @($checked).Count -eq 0)
        if ($reachedNothing -and @("notApplicable", "unknown") -cnotcontains $status) {
            $status = "unknown"
            if (-not $degradedReason) {
                $degradedReason = $(if (@($required).Count -eq 0) {
                        "the row claimed no construct was in reach while $($constructById.Count) were enumerated"
                    }
                    else {
                        "the row declared scope '$scope' and then put every construct in it out of the rule's reach, which is an answer about nothing"
                    })
            }
        }
        # Every construct in the declared scope must be accounted for one way or
        # the other: examined against the rule, or examined and judged outside
        # its reach. Silence about one is the miss this whole section exists to
        # make visible.
        $accountedConstructs = @(@($checked) + @($notInReach))
        $missingConstructs = @(@($required) | Where-Object { $accountedConstructs -cnotcontains $_ })
        $strayConstructs = @(@($accountedConstructs) | Where-Object { $required -cnotcontains $_ })
        if ($missingConstructs.Count -gt 0 -or $strayConstructs.Count -gt 0) {
            $status = "unknown"
            if (-not $degradedReason) {
                # Name them. "22 unaccounted" tells a reader that something went
                # wrong; the ids tell them what was not looked at.
                $degradedReason = $(if ($missingConstructs.Count -gt 0) {
                        "the row declared scope '$scope' but left these unaccounted: " +
                        (@($missingConstructs | Select-Object -First 20) -join ",") +
                        $(if ($missingConstructs.Count -gt 20) { " and $($missingConstructs.Count - 20) more" } else { "" })
                    }
                    else {
                        "the row named constructs outside the scope it declared: " +
                        (@($strayConstructs | Select-Object -First 20) -join ",")
                    })
            }
        }
        $unknownViolating = @(@($violating) | Where-Object { -not $constructById.ContainsKey($_) -or $checked -cnotcontains $_ })
        if ($unknownViolating.Count -gt 0) {
            $status = "unknown"
            if (-not $degradedReason) { $degradedReason = "the row named a violating construct it did not check, or one that does not exist" }
        }
        elseif ($status -ceq "violation" -and $violating.Count -eq 0) {
            $status = "unknown"
            if (-not $degradedReason) { $degradedReason = "the row reported a violation without naming the construct that violates" }
        }
        elseif ($status -cne "violation" -and $violating.Count -gt 0) {
            $status = "unknown"
            if (-not $degradedReason) { $degradedReason = "the row named violating constructs without reporting a violation" }
        }
        $quote = [string](Get-ReviewerConventionSpecialistValue $row "ruleQuote" "")
        if ($quote) {
            $sourceText = ([string](Get-ReviewerConventionSpecialistValue $source "Text" "")).Replace("`r`n", "`n").Replace("`r", "`n")
            if ($sourceText.IndexOf($quote.Replace("`r`n", "`n").Replace("`r", "`n"), [StringComparison]::Ordinal) -lt 0) {
                $status = "unknown"
                if (-not $degradedReason) { $degradedReason = "the row quoted text that is not in the transported source" }
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
        elseif ($linkedCandidate -and $violating.Count -gt 0) {
            # A wrong-anchor row cannot stand in for the right one. If the
            # linked candidate does not sit on one of the constructs this row
            # says are violating, the row is about one place and the finding is
            # about another, and neither has actually been accounted for.
            $candidateAnchor = [string]$candidateAnchors[$linkedCandidate]
            $anchorMatches = $false
            foreach ($id in $violating) {
                $construct = $constructById[$id]
                $constructPath = ([string](Get-ReviewerConventionSpecialistValue $construct "path" "")).TrimStart("/")
                $candidateParts = $candidateAnchor -split '\|'
                if ($candidateParts.Count -ne 2) { continue }
                if (-not [string]::Equals($constructPath, [string]$candidateParts[0], [StringComparison]::OrdinalIgnoreCase)) { continue }
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
                    $degradedReason = "the candidate it linked is anchored somewhere other than the constructs this row calls violating"
                }
            }
        }
        # A row whose rule DID produce an accepted candidate is emitted even if
        # the model forgot to write the link down. Recording it as unemitted
        # would report a finding as missing while it sits in the candidate list.
        $ruleProducedCandidate = $candidateRuleKeys.Contains($ruleKey)
        if ($status -ceq "violation" -and -not $linkedCandidate -and -not $alreadyWithheld -and -not $ruleProducedCandidate) {
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
                checkedConstructs = @($checked)
                notInReachConstructs = @($notInReach)
                violatingConstructs = @($violating)
                codeEvidence = [string](Get-ReviewerConventionSpecialistValue $row "codeEvidence" "")
                siblingStatus = [string](Get-ReviewerConventionSpecialistValue $row "siblingStatus" "unavailable")
                siblingEvidence = [string](Get-ReviewerConventionSpecialistValue $row "siblingEvidence" "")
                candidateId = $linkedCandidate
                notes = [string](Get-ReviewerConventionSpecialistValue $row "notes" "")
                degradedReason = $degradedReason
            })
    }

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
            -not $ConstructsIncomplete)
    }
}

function Resolve-ReviewerConventionSpecialistCandidates {
    param(
        [Parameter(Mandatory)][hashtable]$Marker,
        [Parameter(Mandatory)]$ConventionPlan,
        [Parameter(Mandatory)]$FactPlan,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ResolvedSources,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ChangeEntries,
        [AllowEmptyCollection()][object[]]$Constructs = @(),
        [bool]$ConstructsIncomplete = $false
    )
    if (@($ResolvedSources).Count -eq 0) {
        throw "Convention specialist candidate validation requires at least one resolved convention source."
    }
    if (@($ChangeEntries).Count -eq 0) {
        throw "Convention specialist candidate validation requires at least one pinned change entry."
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
    $currentPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($ChangeEntries)) {
        if ([string](Get-ReviewerConventionSpecialistValue $entry "Role" "") -ceq "current") {
            [void]$currentPaths.Add([string](Get-ReviewerConventionSpecialistValue $entry "Path" ""))
        }
    }
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $accepted = [System.Collections.Generic.List[object]]::new()
    $withheld = [System.Collections.Generic.List[object]]::new()
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
        foreach ($factId in $factIds) {
            if (-not $factMap.ContainsKey($factId)) {
                throw "Specialist candidate '$candidateId' cited unknown deterministic fact '$factId'."
            }
            [void]$facts.Add($factMap[$factId])
        }
        if ([string]$candidate.severity -ceq "important") {
            if ([string]$candidate.impactCategory -ceq "none") {
                throw "Specialist candidate '$candidateId' escalated severity without a protected impact category."
            }
            if ($facts.Count -eq 0 -and [string]$candidate.siblingStatus -cne "checked") {
                throw "Specialist candidate '$candidateId' used important severity without a deterministic fact or checked sibling evidence."
            }
            if ($facts.Count -eq 0 -and ([string]$candidate.siblingEvidence).Trim().Length -lt 16) {
                throw "Specialist candidate '$candidateId' used important severity without meaningful checked sibling evidence."
            }
            if (@($facts | Where-Object {
                        @("true", "false") -cnotcontains
                        [string](Get-ReviewerConventionSpecialistValue $_ "state" "")
                    }).Count -gt 0) {
                throw "Specialist candidate '$candidateId' used a non-deterministic fact to support important severity."
            }
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
            $relativePath = ([string]$candidate.filePath).TrimStart("/")
            if (-not [string]$candidate.filePath -or [int]$candidate.line -lt 1 -or
                -not $currentPaths.Contains($relativePath)) {
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId
                        reason = "outsideChangedFile"
                        detail = "The claimed file/line is not a current changed-file anchor; it was withheld and not relocated."
                    })
                continue
            }
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
    $changedFileIndex = Get-ReviewerConventionSpecialistChangedFileIndex -ChangeEntries $ChangeEntries
    $coverageRows = @()
    if ($Marker.ContainsKey("ruleCoverage")) { $coverageRows = @($Marker.ruleCoverage) }
    $coverage = Resolve-ReviewerConventionSpecialistRuleCoverage -Rows $coverageRows `
        -ResolvedSources $ResolvedSources `
        -AcceptedCandidates $accepted.ToArray() -Constructs $Constructs `
        -ConstructsIncomplete $ConstructsIncomplete `
        -WithheldCandidateIds @(@($withheld) | ForEach-Object {
                [string](Get-ReviewerConventionSpecialistValue $_ "candidateId" "")
            } | Where-Object { $_ })
    # A rule the model called violated but never emitted is recorded through the
    # EXISTING withheld channel, not a second one. Two lists that both mean
    # "nearly a finding" is exactly where a later edit promotes one.
    foreach ($unemitted in @($coverage.UnemittedViolations)) {
        $detail = "Rule accounting reported a violation of '$([string]$unemitted.ruleSourceId)' in pack '$([string]$unemitted.packName)' but the pass emitted no candidate for it."
        $note = [string]$unemitted.notes
        if ($note) { $detail = "$detail Stated reason: $note" }
        if ($detail.Length -gt 800) { $detail = $detail.Substring(0, 800) }
        [void]$withheld.Add([pscustomobject][ordered]@{
                candidateId = ""
                reason = "accountedNotEmitted"
                detail = $detail
            })
    }
    return @{
        Candidates = $accepted.ToArray()
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
        [Parameter(Mandatory)][AllowEmptyString()][string]$ThreadDigestText,
        [AllowEmptyString()][string]$PinnedSourceText = "",
        # Non-empty only in offline replay. The prompt tells this pass to
        # re-read the pull request and stop without a marker if it cannot; in
        # replay it cannot, because it has no repository tool at all. Without
        # saying so here the pass fails closed for a reason that is not a
        # finding about the change.
        [AllowEmptyString()][string]$ReplayNotice = "",
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
    $ruleRequest = Get-ReviewerConventionSpecialistRuleRequest -ResolvedSources $ResolvedSources
    # The anchor list is bounded too. It is only a naming convenience for the
    # rows - every path in it is already in `changedFiles` - and letting it grow
    # with a thousand-file change set would push the envelope past its bound and
    # turn today's graceful "pinned source dropped" degrade into a hard failure
    # of the whole pass.
    $fullAnchorIndex = @(Get-ReviewerConventionSpecialistChangedFileIndex -ChangeEntries $ChangeEntries)
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
                    [pscustomobject][ordered]@{
                        ruleRef = [string]$_.ruleRef
                        packName = [string]$_.packName
                        ruleSourceId = [string]$_.ruleSourceId
                        ruleSourceSha256 = [string]$_.ruleSourceSha256
                    }
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
        markerScaffold = [pscustomobject][ordered]@{
            schemaVersion = 1
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
            candidates = @()
            ruleCoverage = @()
            withheld = @()
            residualRisks = @()
            nonce = $Nonce
        }
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
