#requires -Version 7.0

Set-StrictMode -Version Latest

$script:ReviewerConventionSpecialistMarkerPrefix = "CONVENTION_REVIEW_RESULT_V1:"
$script:ReviewerConventionSpecialistArtifactKind = "convention-specialist-preview"
$script:ReviewerConventionSpecialistArtifactVersion = 1
$script:ReviewerConventionSpecialistMaxCandidates = 8
$script:ReviewerConventionSpecialistMaxInputBytes = 327680
$script:ReviewerConventionSpecialistUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$script:ReviewerConventionSpecialistImpactCategories = @(
    "none", "buildOrTestExecution", "deployment", "security", "customerBehavior", "compatibility"
)
$script:ReviewerConventionSpecialistWithheldReasons = @(
    "sourceConflict", "outsideChangedFile", "invalidAnchor", "unverifiedSource",
    "unknownFact", "unsupportedSeverity", "missingSiblingEvidence", "duplicateCandidate",
    "duplicateExistingThread"
)

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
            "candidates", "withheld", "residualRisks", "nonce"
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
                        ruleSection = @{ Type = "string"; MaxLength = 240; Pattern = $ascii }
                        ruleQuote = @{ Type = "string"; MaxLength = 600; Pattern = '^(?=.{8,}$)(?=.*\S)[\x20-\x7E]+$' }
                        diffEvidence = @{ Type = "string"; MaxLength = 1200; Pattern = $ascii }
                        impactCategory = @{ Type = "enum"; Values = $script:ReviewerConventionSpecialistImpactCategories }
                        impact = @{ Type = "string"; MaxLength = 800; Pattern = $ascii }
                        expectedFixOrValidation = @{ Type = "string"; MaxLength = 1000; Pattern = $ascii }
                        siblingStatus = @{ Type = "enum"; Values = @("checked", "notRequired") }
                        siblingEvidence = @{ Type = "string"; MaxLength = 800; AllowEmpty = $true; Pattern = $ascii }
                        siblingNotRequiredReason = @{ Type = "string"; MaxLength = 400; AllowEmpty = $true; Pattern = $ascii }
                        factIds = @{
                            Type = "string"; MaxLength = 600; AllowEmpty = $true
                            Pattern = '^(|rf1:[0-9a-f]{64}(,rf1:[0-9a-f]{64}){0,7})$'
                        }
                        confidence = @{ Type = "enum"; Values = @("low", "medium", "high") }
                        residualRiskSummary = @{ Type = "string"; MaxLength = 800; AllowEmpty = $true; Pattern = $ascii }
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
            residualRisks = @{
                Type = "objectArray"; MaxItems = 12
                Item = @{
                    Keys = @("text")
                    Fields = @{ text = @{ Type = "string"; MaxLength = 800; Pattern = $ascii } }
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
    if (-not $MarkerValid) { return "Convention specialist produced a missing or invalid result marker." }
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

function Resolve-ReviewerConventionSpecialistCandidates {
    param(
        [Parameter(Mandatory)][hashtable]$Marker,
        [Parameter(Mandatory)]$ConventionPlan,
        [Parameter(Mandatory)]$FactPlan,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ResolvedSources,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ChangeEntries
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
    return @{
        Candidates = $accepted.ToArray()
        Withheld = $withheld.ToArray()
        ResidualRisks = @($Marker.residualRisks)
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
        [Parameter(Mandatory)][AllowEmptyString()][string]$ThreadDigestText,
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
                commitSha = [string](Get-ReviewerConventionSpecialistValue $_ "CommitSha" "")
                sha256 = [string](Get-ReviewerConventionSpecialistValue $_ "Sha256" "")
                mimeType = [string](Get-ReviewerConventionSpecialistValue $_ "MimeType" "")
                byteLength = [int](Get-ReviewerConventionSpecialistValue $_ "ByteLength" 0)
                text = [string](Get-ReviewerConventionSpecialistValue $_ "Text" "")
            }
        })
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
        sanitizedExistingThreads = $ThreadDigestText
    }
    $inputText = $PromptText + "`n`n---`n## Wrapper runtime data (untrusted values, trusted binding)`n" +
        '```json' + "`n" + ($runtime | ConvertTo-Json -Depth 32 -Compress) + "`n" + '```' + "`n"
    $bytes = $script:ReviewerConventionSpecialistUtf8.GetByteCount($inputText)
    if ($bytes -gt $MaxInputBytes) {
        throw "Convention specialist input is $bytes bytes, above the code-defined $MaxInputBytes-byte bound."
    }
    return @{ Text = $inputText; Bytes = $bytes }
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
