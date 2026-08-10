#requires -Version 7.0

Set-StrictMode -Version Latest

$script:ReviewerVerificationMarkerPrefix = "VERIFICATION_RESULT_V1:"
$script:ReviewerVerificationInputKind = "verification-input-preview"
$script:ReviewerVerificationPreviewKind = "verification-decision-preview"
$script:ReviewerVerificationArtifactVersion = 1
$script:ReviewerVerificationMaxCandidates = 64
$script:ReviewerVerificationMaxClusterSize = 8
$script:ReviewerVerificationMaxInputBytes = 524288
$script:ReviewerVerificationMaxArtifactBytes = 2097152
$script:ReviewerVerificationMaxVerifierRuns = 12
$script:ReviewerVerificationMaxPhaseSeconds = 3600
$script:ReviewerVerificationNearExactJaccard = 0.70
$script:ReviewerVerificationSemanticJaccard = 0.55
$script:ReviewerVerificationExistingThreadJaccard = 0.68
$script:ReviewerVerificationUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$script:ReviewerVerificationOutcomes = @(
    "verified", "duplicate", "unsupported", "wrongSeverity", "needsHuman"
)
$script:ReviewerVerificationWithheldReasons = @(
    "anchorInvalid", "candidateLimit", "clusterLimit", "degradedDiscovery",
    "duplicateExistingThread", "duplicatePriorAgent", "duplicateCandidate",
    "incompleteVerifier", "invalidMarker", "modelMismatch", "selfVerification",
    "staleBinding", "timeout", "toolViolation", "unsupported", "needsHuman",
    "missingEvidence", "wrongSeverity", "severityEscalation", "verifierDisagreement",
    "sourceInvalid", "factInvalid", "siblingInvalid", "specialistDegraded"
)

function ConvertTo-ReviewerVerificationEffectivePolicy {
    param([Parameter(Mandatory)]$Policy)
    foreach ($entry in @(
            @("maxCandidates", 1), @("maxClusterSize", 1), @("maxInputBytes", 1024),
            @("maxArtifactBytes", 1024), @("maxVerifierRuns", 1),
            @("maxVerificationSeconds", 30)
        )) {
        $value = Get-ReviewerVerificationValue $Policy ([string]$entry[0]) $null
        if ($null -eq $value -or [int64]$value -lt [int]$entry[1] -or
            [int64]$value -gt [int]::MaxValue) {
            throw "Verification policy '$($entry[0])' is outside its supported positive range."
        }
    }
    foreach ($name in @("nearExactJaccard", "semanticJaccard", "existingThreadJaccard")) {
        $value = Get-ReviewerVerificationValue $Policy $name $null
        if ($null -eq $value -or [double]$value -lt 0.0 -or [double]$value -gt 1.0) {
            throw "Verification policy '$name' must be a number from 0 through 1."
        }
    }
    return [pscustomobject][ordered]@{
        maxCandidates = [Math]::Min(
            [int](Get-ReviewerVerificationValue $Policy "maxCandidates" 0),
            $script:ReviewerVerificationMaxCandidates)
        maxClusterSize = [Math]::Min(
            [int](Get-ReviewerVerificationValue $Policy "maxClusterSize" 0),
            $script:ReviewerVerificationMaxClusterSize)
        maxInputBytes = [Math]::Min(
            [int](Get-ReviewerVerificationValue $Policy "maxInputBytes" 0),
            $script:ReviewerVerificationMaxInputBytes)
        maxArtifactBytes = [Math]::Min(
            [int](Get-ReviewerVerificationValue $Policy "maxArtifactBytes" 0),
            $script:ReviewerVerificationMaxArtifactBytes)
        maxVerifierRuns = [Math]::Min(
            [int](Get-ReviewerVerificationValue $Policy "maxVerifierRuns" 0),
            $script:ReviewerVerificationMaxVerifierRuns)
        maxVerificationSeconds = [Math]::Min(
            [int](Get-ReviewerVerificationValue $Policy "maxVerificationSeconds" 0),
            $script:ReviewerVerificationMaxPhaseSeconds)
        nearExactJaccard = [double](Get-ReviewerVerificationValue $Policy "nearExactJaccard" 0.0)
        semanticJaccard = [double](Get-ReviewerVerificationValue $Policy "semanticJaccard" 0.0)
        existingThreadJaccard = [double](Get-ReviewerVerificationValue $Policy "existingThreadJaccard" 0.0)
    }
}

function Get-ReviewerVerificationValue {
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

function Get-ReviewerVerificationSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
                $sha.ComputeHash($script:ReviewerVerificationUtf8.GetBytes($Text)))).Replace("-", "").ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function ConvertTo-ReviewerVerificationCanonicalArray {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [int]$Depth = 0
    )
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Items) {
        if ($item -is [System.Array]) {
            [void]$parts.Add((ConvertTo-ReviewerVerificationCanonicalArray `
                    -Items $item -Depth ($Depth + 1)))
        }
        else {
            [void]$parts.Add((ConvertTo-ReviewerVerificationCanonicalJson `
                    -Value $item -Depth ($Depth + 1)))
        }
    }
    return "[" + ($parts.ToArray() -join ",") + "]"
}

function ConvertTo-ReviewerVerificationCanonicalJson {
    param(
        [AllowNull()][AllowEmptyCollection()][object]$Value,
        [int]$Depth = 0
    )
    if ($Depth -gt 32) { throw "Verification canonical JSON exceeded the maximum object depth of 32." }
    if ($null -eq $Value) { return "null" }
    if ($Value -is [bool]) { return $(if ($Value) { "true" } else { "false" }) }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]) {
        if (($Value -is [single] -or $Value -is [double]) -and
            ([double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value))) {
            throw "Verification canonical JSON does not support non-finite numbers."
        }
        return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string]) {
        [void]$script:ReviewerVerificationUtf8.GetByteCount($Value)
        return ConvertTo-Json -InputObject $Value -Compress
    }
    if ($Value -is [System.Collections.IDictionary] -or
        $Value -is [System.Management.Automation.PSCustomObject]) {
        $names = [System.Collections.Generic.List[string]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.Keys) {
                if ($key -isnot [string]) { throw "Verification canonical JSON keys must be strings." }
                if (-not $seen.Add([string]$key)) { throw "Verification canonical JSON contains a duplicate object key." }
                [void]$names.Add([string]$key)
            }
        }
        else {
            foreach ($property in $Value.PSObject.Properties) {
                if (-not $seen.Add($property.Name)) { throw "Verification canonical JSON contains a duplicate object key." }
                [void]$names.Add($property.Name)
            }
        }
        $names.Sort([StringComparer]::Ordinal)
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $names) {
            $rawValue = $null
            if ($Value -is [System.Collections.IDictionary]) { $rawValue = $Value[$name] }
            else { $rawValue = $Value.PSObject.Properties[$name].Value }
            $canonicalValue = if ($rawValue -is [System.Array]) {
                ConvertTo-ReviewerVerificationCanonicalArray `
                    -Items $rawValue -Depth ($Depth + 1)
            }
            else {
                ConvertTo-ReviewerVerificationCanonicalJson `
                    -Value $rawValue -Depth ($Depth + 1)
            }
            [void]$parts.Add(
                (ConvertTo-Json -InputObject $name -Compress) + ":" + $canonicalValue)
        }
        return "{" + ($parts.ToArray() -join ",") + "}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return ConvertTo-ReviewerVerificationCanonicalArray `
            -Items @($Value) -Depth ($Depth + 1)
    }
    throw "Verification canonical JSON encountered unsupported type '$($Value.GetType().FullName)'."
}

function Get-ReviewerVerificationObjectSha256 {
    param([Parameter(Mandatory)]$Value)
    return Get-ReviewerVerificationSha256 -Text (
        ConvertTo-ReviewerVerificationCanonicalJson -Value $Value)
}

function Copy-ReviewerVerificationJsonValue {
    param(
        [AllowNull()][AllowEmptyCollection()][object]$Value,
        [int]$Depth = 0
    )
    if ($Depth -gt 32) { throw "Verification JSON copy exceeded the maximum object depth of 32." }
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]) {
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary] -or
        $Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        $names = [System.Collections.Generic.List[string]]::new()
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.Keys) {
                if ($key -isnot [string]) {
                    throw "Verification JSON copy requires unique string object keys."
                }
                [void]$names.Add([string]$key)
            }
        }
        else {
            foreach ($property in $Value.PSObject.Properties) {
                [void]$names.Add([string]$property.Name)
            }
        }
        foreach ($nameValue in $names) {
            if ($copy.Contains([string]$nameValue)) {
                throw "Verification JSON copy requires unique string object keys."
            }
            $name = [string]$nameValue
            if ($Value -is [System.Collections.IDictionary]) {
                $raw = $Value[$name]
            }
            else {
                $raw = $Value.PSObject.Properties[$name].Value
            }
            $copy[$name] = Copy-ReviewerVerificationJsonValue -Value $raw -Depth ($Depth + 1)
        }
        return [pscustomobject]$copy
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            [void]$items.Add((Copy-ReviewerVerificationJsonValue -Value $item -Depth ($Depth + 1)))
        }
        return , $items.ToArray()
    }
    throw "Verification JSON copy encountered unsupported type '$($Value.GetType().FullName)'."
}

function Get-ReviewerVerificationDomainKey {
    param(
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [Parameter(Mandatory)][ValidateSet("input", "preview")][string]$Domain
    )
    $label = "devpilot.reviewer.verification.$Domain.v1"
    $hmac = [Security.Cryptography.HMACSHA256]::new($MasterKey)
    try { return , $hmac.ComputeHash($script:ReviewerVerificationUtf8.GetBytes($label)) }
    finally { $hmac.Dispose() }
}

function Get-ReviewerVerificationSignature {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $hmac = [Security.Cryptography.HMACSHA256]::new($Key)
    try {
        return ([BitConverter]::ToString(
                $hmac.ComputeHash($script:ReviewerVerificationUtf8.GetBytes($Json)))).Replace("-", "").ToLowerInvariant()
    }
    finally { $hmac.Dispose() }
}

function Test-ReviewerVerificationSignature {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][byte[]]$Key,
        [AllowEmptyString()][string]$Signature = ""
    )
    if ($Signature -notmatch '^[0-9a-f]{64}$') { return $false }
    $expected = Get-ReviewerVerificationSignature -Json $Json -Key $Key
    return [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
        [Convert]::FromHexString($expected),
        [Convert]::FromHexString($Signature))
}

function Save-ReviewerVerificationArtifact {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [Parameter(Mandatory)][ValidateSet("input", "preview")][string]$Domain,
        [ValidateRange(1024, [int]::MaxValue)][int]$MaxArtifactBytes = $script:ReviewerVerificationMaxArtifactBytes
    )
    if ($BaseName -notmatch '^[A-Za-z0-9._-]+$') { throw "Verification artifact base name is unsafe." }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Verification artifact directory '$Directory' does not exist."
    }
    $manifestJson = ConvertTo-ReviewerVerificationCanonicalJson -Value $Manifest
    $effectiveMaxArtifactBytes = [Math]::Min(
        $MaxArtifactBytes, $script:ReviewerVerificationMaxArtifactBytes)
    if ($script:ReviewerVerificationUtf8.GetByteCount($manifestJson) -gt $effectiveMaxArtifactBytes) {
        throw "Verification artifact exceeded the effective $effectiveMaxArtifactBytes-byte cap."
    }
    $key = Get-ReviewerVerificationDomainKey -MasterKey $MasterKey -Domain $Domain
    $envelope = [ordered]@{
        manifestJson = $manifestJson
        signatureAlg = "HMACSHA256"
        signature = Get-ReviewerVerificationSignature -Json $manifestJson -Key $key
    }
    $path = Join-Path $Directory ($BaseName + ".json")
    $nonce = [Guid]::NewGuid().ToString("N")
    $tempPath = "$path.$nonce.tmp"
    try {
        [IO.File]::WriteAllText(
            $tempPath,
            ($envelope | ConvertTo-Json -Depth 4),
            $script:ReviewerVerificationUtf8)
        Move-Item -LiteralPath $tempPath -Destination $path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    }
    return $path
}

function Read-ReviewerVerificationArtifact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [Parameter(Mandatory)][ValidateSet("input", "preview")][string]$Domain
    )
    $envelope = [IO.File]::ReadAllText($Path, $script:ReviewerVerificationUtf8) | ConvertFrom-Json -Depth 8
    $manifestJson = [string](Get-ReviewerVerificationValue $envelope "manifestJson" "")
    $signature = [string](Get-ReviewerVerificationValue $envelope "signature" "")
    if ([string](Get-ReviewerVerificationValue $envelope "signatureAlg" "") -cne "HMACSHA256") {
        throw "Verification artifact signature algorithm is invalid."
    }
    $key = Get-ReviewerVerificationDomainKey -MasterKey $MasterKey -Domain $Domain
    if (-not $manifestJson -or
        -not (Test-ReviewerVerificationSignature -Json $manifestJson -Key $key -Signature $signature)) {
        throw "Verification artifact signature verification failed."
    }
    $manifest = $manifestJson | ConvertFrom-Json -Depth 32
    $expectedKind = if ($Domain -ceq "input") {
        $script:ReviewerVerificationInputKind
    }
    else {
        $script:ReviewerVerificationPreviewKind
    }
    if ([string](Get-ReviewerVerificationValue $manifest "kind" "") -cne $expectedKind -or
        [int](Get-ReviewerVerificationValue $manifest "artifactVersion" 0) -ne
        $script:ReviewerVerificationArtifactVersion) {
        throw "Verification artifact kind or version is invalid."
    }
    return $manifest
}

function Save-ReviewerVerificationInput {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [ValidateRange(1024, [int]::MaxValue)][int]$MaxArtifactBytes = $script:ReviewerVerificationMaxArtifactBytes
    )
    return Save-ReviewerVerificationArtifact -Manifest $Manifest -Directory $Directory `
        -BaseName $BaseName -MasterKey $MasterKey -Domain input -MaxArtifactBytes $MaxArtifactBytes
}

function Read-ReviewerVerificationInput {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$MasterKey)
    return Read-ReviewerVerificationArtifact -Path $Path -MasterKey $MasterKey -Domain input
}

function Save-ReviewerVerificationPreview {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [ValidateRange(1024, [int]::MaxValue)][int]$MaxArtifactBytes = $script:ReviewerVerificationMaxArtifactBytes
    )
    return Save-ReviewerVerificationArtifact -Manifest $Manifest -Directory $Directory `
        -BaseName $BaseName -MasterKey $MasterKey -Domain preview -MaxArtifactBytes $MaxArtifactBytes
}

function Read-ReviewerVerificationPreview {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$MasterKey)
    return Read-ReviewerVerificationArtifact -Path $Path -MasterKey $MasterKey -Domain preview
}

function ConvertTo-ReviewerVerificationNormalizedText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $value = $Text.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant()
    $value = [regex]::Replace($value, '[^a-z0-9._/-]+', ' ', "CultureInvariant", [TimeSpan]::FromMilliseconds(250))
    return ([regex]::Replace($value, '\s+', ' ', "CultureInvariant", [TimeSpan]::FromMilliseconds(250))).Trim()
}

function ConvertTo-ReviewerVerificationPath {
    param([AllowEmptyString()][string]$Path = "")
    if (-not (Get-Command ConvertTo-ReviewerSourceIdentityPath -ErrorAction SilentlyContinue)) {
        throw "Cross-verification path validation requires SourceTransport.ps1."
    }
    return ConvertTo-ReviewerSourceIdentityPath -Path $Path
}

function ConvertTo-ReviewerVerificationReadPath {
    param([AllowEmptyString()][string]$Path = "")
    if (-not (Get-Command ConvertTo-ReviewerSourcePath -ErrorAction SilentlyContinue)) {
        throw "Cross-verification source reads require SourceTransport.ps1."
    }
    return ConvertTo-ReviewerSourcePath -Path $Path
}

function Get-ReviewerVerificationTokens {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $stop = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($word in @(
            "a", "an", "and", "are", "as", "at", "be", "because", "by", "can", "does",
            "for", "from", "if", "in", "into", "is", "it", "of", "on", "or", "should",
            "that", "the", "this", "to", "was", "when", "which", "will", "with"
        )) {
        [void]$stop.Add($word)
    }
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($token in @((ConvertTo-ReviewerVerificationNormalizedText -Text $Text) -split ' ')) {
        if ($token.Length -lt 3 -or $stop.Contains($token)) { continue }
        $token = $token.Trim('.', '/', '-')
        switch ($token) {
            "lost" { $token = "lose" }
            "loss" { $token = "lose" }
            "previous" { $token = "prior" }
        }
        if ($token.Length -gt 6 -and $token.EndsWith("ing", [StringComparison]::Ordinal)) {
            $token = $token.Substring(0, $token.Length - 3)
        }
        elseif ($token.Length -gt 5 -and $token.EndsWith("ed", [StringComparison]::Ordinal)) {
            $token = $token.Substring(0, $token.Length - 2)
        }
        elseif ($token.Length -gt 4 -and $token.EndsWith("s", [StringComparison]::Ordinal)) {
            $token = $token.Substring(0, $token.Length - 1)
        }
        if ($token.Length -gt 4 -and $token.EndsWith("e", [StringComparison]::Ordinal)) {
            $token = $token.Substring(0, $token.Length - 1)
        }
        if ($token.Length -lt 3 -or $stop.Contains($token)) { continue }
        [void]$set.Add($token)
    }
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($token in $set) { [void]$list.Add($token) }
    $list.Sort([StringComparer]::Ordinal)
    return $list.ToArray()
}

function Get-ReviewerVerificationIssueClass {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $value = ConvertTo-ReviewerVerificationNormalizedText -Text $Text
    foreach ($rule in @(
            @("security", '\b(auth|authorization|credential|secret|security|token|permission|injection)\b'),
            @("buildTest", '\b(build|compile|test|manifest|pipeline|validation)\b'),
            @("dataIntegrity", '\b(data|database|serialize|state|corrupt|loss|persist)\b'),
            @("errorHandling", '\b(error|exception|failure|timeout|retry|fallback)\b'),
            @("concurrency", '\b(race|concurrent|lock|deadlock|atomic)\b'),
            @("compatibility", '\b(api|compatib|breaking|contract|schema|version)\b'),
            @("behavior", '\b(return|result|behavior|incorrect|wrong|missing|duplicate)\b')
        )) {
        if ($value -match [string]$rule[1]) { return [string]$rule[0] }
    }
    return "other"
}

function Get-ReviewerVerificationSimilarity {
    param([string[]]$Left = @(), [string[]]$Right = @())
    $leftSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $rightSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in @($Left)) { [void]$leftSet.Add([string]$item) }
    foreach ($item in @($Right)) { [void]$rightSet.Add([string]$item) }
    if ($leftSet.Count -eq 0 -and $rightSet.Count -eq 0) { return 1.0 }
    $intersection = 0
    foreach ($item in $leftSet) { if ($rightSet.Contains($item)) { $intersection++ } }
    $union = $leftSet.Count + $rightSet.Count - $intersection
    if ($union -eq 0) { return 0.0 }
    return ([double]$intersection / [double]$union)
}

function New-ReviewerVerificationCandidate {
    param(
        [Parameter(Mandatory)][ValidateSet("generalist", "convention")][string]$OriginKind,
        [Parameter(Mandatory)][string]$OriginModel,
        [Parameter(Mandatory)][string]$OriginArtifactSha256,
        [Parameter(Mandatory)]$RawCandidate,
        [string]$OriginCandidateId = ""
    )
    $severity = [string](Get-ReviewerVerificationValue $RawCandidate "severity" "suggestion")
    $filePath = ConvertTo-ReviewerVerificationPath -Path (
        [string](Get-ReviewerVerificationValue $RawCandidate "filePath" ""))
    $line = [int](Get-ReviewerVerificationValue $RawCandidate "line" 0)
    $anchorKind = [string](Get-ReviewerVerificationValue $RawCandidate "anchorKind" "")
    if (-not $anchorKind) { $anchorKind = $(if ($filePath) { "changedFile" } else { "prMetadata" }) }
    $comment = if ($OriginKind -ceq "generalist") {
        [string](Get-ReviewerVerificationValue $RawCandidate "comment" "")
    }
    else {
        [string](Get-ReviewerVerificationValue $RawCandidate "impact" "")
    }
    $evidence = if ($OriginKind -ceq "generalist") {
        $comment
    }
    else {
        [string](Get-ReviewerVerificationValue $RawCandidate "diffEvidence" "")
    }
    $behaviorText = "$comment $evidence $([string](Get-ReviewerVerificationValue $RawCandidate 'expectedFixOrValidation' ''))"
    $tokens = @(Get-ReviewerVerificationTokens -Text $behaviorText)
    $rawJson = ConvertTo-ReviewerVerificationCanonicalJson -Value $RawCandidate
    $record = [pscustomobject][ordered]@{
        schemaVersion = 1
        originKind = $OriginKind
        originModel = $OriginModel
        originArtifactSha256 = $OriginArtifactSha256.ToLowerInvariant()
        originCandidateId = $OriginCandidateId
        issueClass = Get-ReviewerVerificationIssueClass -Text $behaviorText
        affectedBehavior = ($tokens -join " ")
        anchorKind = $anchorKind
        filePath = $filePath
        line = $line
        severity = $severity
        comment = $comment
        evidence = $evidence
        ruleSourceId = [string](Get-ReviewerVerificationValue $RawCandidate "ruleSourceId" "")
        ruleSourceSha256 = [string](Get-ReviewerVerificationValue $RawCandidate "ruleSourceSha256" "")
        ruleQuote = [string](Get-ReviewerVerificationValue $RawCandidate "ruleQuote" "")
        siblingStatus = [string](Get-ReviewerVerificationValue $RawCandidate "siblingStatus" "")
        siblingEvidence = [string](Get-ReviewerVerificationValue $RawCandidate "siblingEvidence" "")
        siblingNotRequiredReason = [string](Get-ReviewerVerificationValue $RawCandidate "siblingNotRequiredReason" "")
        factIds = [string](Get-ReviewerVerificationValue $RawCandidate "factIds" "")
        changedCodeFix = Get-ReviewerVerificationValue $RawCandidate "changedCodeFix" $null
        existingDebtFollowUp = Get-ReviewerVerificationValue $RawCandidate "existingDebtFollowUp" $null
        existingDebtEvidence = Get-ReviewerVerificationValue $RawCandidate "existingDebtEvidence" $null
        rawCandidateSha256 = Get-ReviewerVerificationSha256 -Text $rawJson
    }
    $hash = Get-ReviewerVerificationObjectSha256 -Value $record
    return [pscustomobject][ordered]@{
        candidateId = "cand1:$hash"
        candidateHash = $hash
        schemaVersion = $record.schemaVersion
        originKind = $record.originKind
        originModel = $record.originModel
        originArtifactSha256 = $record.originArtifactSha256
        originCandidateId = $record.originCandidateId
        issueClass = $record.issueClass
        affectedBehavior = $record.affectedBehavior
        anchorKind = $record.anchorKind
        filePath = $record.filePath
        line = $record.line
        severity = $record.severity
        comment = $record.comment
        evidence = $record.evidence
        ruleSourceId = $record.ruleSourceId
        ruleSourceSha256 = $record.ruleSourceSha256
        ruleQuote = $record.ruleQuote
        siblingStatus = $record.siblingStatus
        siblingEvidence = $record.siblingEvidence
        siblingNotRequiredReason = $record.siblingNotRequiredReason
        factIds = $record.factIds
        changedCodeFix = $record.changedCodeFix
        existingDebtFollowUp = $record.existingDebtFollowUp
        existingDebtEvidence = $record.existingDebtEvidence
        rawCandidateSha256 = $record.rawCandidateSha256
    }
}

function ConvertTo-ReviewerVerificationCandidates {
    param(
        [object[]]$GeneralistPasses = @(),
        [object[]]$ConventionCandidates = @(),
        [string]$ConventionModel = "",
        [string]$ConventionArtifactSha256 = ("0" * 64),
        [int]$MaxCandidates = $script:ReviewerVerificationMaxCandidates
    )
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($pass in @($GeneralistPasses)) {
        $model = [string](Get-ReviewerVerificationValue $pass "model" (
                Get-ReviewerVerificationValue $pass "Model" ""))
        $marker = Get-ReviewerVerificationValue $pass "marker" (
            Get-ReviewerVerificationValue $pass "Marker")
        if (-not $marker) { continue }
        $markerJson = ConvertTo-ReviewerVerificationCanonicalJson -Value $marker
        $artifactSha = Get-ReviewerVerificationSha256 -Text $markerJson
        $index = 0
        foreach ($finding in @(Get-ReviewerVerificationValue $marker "findings" @())) {
            $index++
            [void]$result.Add((New-ReviewerVerificationCandidate -OriginKind generalist `
                    -OriginModel $model -OriginArtifactSha256 $artifactSha `
                    -RawCandidate $finding -OriginCandidateId "finding-$index"))
        }
    }
    foreach ($candidate in @($ConventionCandidates)) {
        [void]$result.Add((New-ReviewerVerificationCandidate -OriginKind convention `
                -OriginModel $ConventionModel -OriginArtifactSha256 $ConventionArtifactSha256 `
                -RawCandidate $candidate `
                -OriginCandidateId ([string](Get-ReviewerVerificationValue $candidate "candidateId" ""))))
    }
    if ($result.Count -gt $MaxCandidates) {
        throw "Verification candidate count $($result.Count) exceeds the code-defined $MaxCandidates-item cap."
    }
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $result) { [void]$ordered.Add($candidate) }
    $ordered.Sort([System.Comparison[object]] {
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string](Get-ReviewerVerificationValue $left "candidateHash" ""),
                [string](Get-ReviewerVerificationValue $right "candidateHash" ""))
        })
    return $ordered.ToArray()
}

function Get-ReviewerVerificationCandidatePlan {
    param(
        [object[]]$GeneralistPasses = @(),
        [object[]]$ConventionCandidates = @(),
        [string]$ConventionModel = "",
        [string]$ConventionArtifactSha256 = ("0" * 64),
        [int]$MaxCandidates = $script:ReviewerVerificationMaxCandidates
    )
    $MaxCandidates = [Math]::Min($MaxCandidates, $script:ReviewerVerificationMaxCandidates)
    $allCandidates = @(ConvertTo-ReviewerVerificationCandidates `
        -GeneralistPasses $GeneralistPasses -ConventionCandidates $ConventionCandidates `
        -ConventionModel $ConventionModel -ConventionArtifactSha256 $ConventionArtifactSha256 `
        -MaxCandidates ([int]::MaxValue))
    $bounded = [System.Collections.Generic.List[object]]::new()
    $withheld = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $allCandidates.Count; $index++) {
        $candidate = $allCandidates[$index]
        if ($index -lt $MaxCandidates) {
            [void]$bounded.Add($candidate)
            continue
        }
        [void]$withheld.Add([pscustomobject][ordered]@{
                candidateId = [string]$candidate.candidateId
                candidateHash = [string]$candidate.candidateHash
                originKind = [string]$candidate.originKind
                originModel = [string]$candidate.originModel
                clusterId = ""
                reason = "candidateLimit"
                detail = "Candidate exceeded the versioned $MaxCandidates-item normalization cap."
            })
    }
    return [pscustomobject][ordered]@{
        candidates = $bounded.ToArray()
        withheld = $withheld.ToArray()
        totalCandidateCount = $allCandidates.Count
    }
}

function Get-ReviewerVerificationClusteringKey {
    param([Parameter(Mandatory)]$Candidate)
    return (
        [string](Get-ReviewerVerificationValue $Candidate "issueClass" "") + "|" +
        (ConvertTo-ReviewerVerificationPath -Path (
                [string](Get-ReviewerVerificationValue $Candidate "filePath" ""))) + "|" +
        [Convert]::ToString(
            [int](Get-ReviewerVerificationValue $Candidate "line" 0),
            [Globalization.CultureInfo]::InvariantCulture) + "|" +
        [string](Get-ReviewerVerificationValue $Candidate "affectedBehavior" "") + "|" +
        (ConvertTo-ReviewerVerificationNormalizedText -Text (
                [string](Get-ReviewerVerificationValue $Candidate "comment" (
                    Get-ReviewerVerificationValue $Candidate "evidence" ""))))
    )
}

function Get-ReviewerVerificationCandidatePairScore {
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right,
        [ValidateRange(0.0, 1.0)][double]$NearExactJaccard = $script:ReviewerVerificationNearExactJaccard,
        [ValidateRange(0.0, 1.0)][double]$SemanticJaccard = $script:ReviewerVerificationSemanticJaccard
    )
    $leftText = ConvertTo-ReviewerVerificationNormalizedText -Text (
        [string](Get-ReviewerVerificationValue $Left "comment" (
            Get-ReviewerVerificationValue $Left "evidence" "")))
    $rightText = ConvertTo-ReviewerVerificationNormalizedText -Text (
        [string](Get-ReviewerVerificationValue $Right "comment" (
            Get-ReviewerVerificationValue $Right "evidence" "")))
    $leftPath = ConvertTo-ReviewerVerificationPath -Path (
        [string](Get-ReviewerVerificationValue $Left "filePath" ""))
    $rightPath = ConvertTo-ReviewerVerificationPath -Path (
        [string](Get-ReviewerVerificationValue $Right "filePath" ""))
    $leftLine = [int](Get-ReviewerVerificationValue $Left "line" 0)
    $rightLine = [int](Get-ReviewerVerificationValue $Right "line" 0)
    $sameAnchor = $leftPath -ceq $rightPath -and $leftLine -eq $rightLine
    $leftTokens = @(([string](Get-ReviewerVerificationValue $Left "affectedBehavior" "")) -split ' ' |
        Where-Object { $_ })
    $rightTokens = @(([string](Get-ReviewerVerificationValue $Right "affectedBehavior" "")) -split ' ' |
        Where-Object { $_ })
    $similarity = Get-ReviewerVerificationSimilarity -Left $leftTokens -Right $rightTokens
    $rightSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($token in $rightTokens) { [void]$rightSet.Add($token) }
    $shared = 0
    foreach ($token in $leftTokens) { if ($rightSet.Contains($token)) { $shared++ } }
    if ($sameAnchor -and $leftText -ceq $rightText) { return 1.0 }
    if ($sameAnchor -and $shared -ge 4 -and $similarity -ge $NearExactJaccard) {
        return $similarity
    }
    $sameClass = [string](Get-ReviewerVerificationValue $Left "issueClass" "") -ceq
        [string](Get-ReviewerVerificationValue $Right "issueClass" "")
    if (-not $sameClass -or
        [string](Get-ReviewerVerificationValue $Left "issueClass" "") -ceq "other") {
        return -1.0
    }
    $requiredShared = if ($leftPath -cne $rightPath) { 4 } else { 3 }
    if ($shared -ge $requiredShared -and $similarity -ge $SemanticJaccard) {
        return $similarity
    }
    return -1.0
}

function Test-ReviewerVerificationCandidatePair {
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right,
        [ValidateRange(0.0, 1.0)][double]$NearExactJaccard = $script:ReviewerVerificationNearExactJaccard,
        [ValidateRange(0.0, 1.0)][double]$SemanticJaccard = $script:ReviewerVerificationSemanticJaccard
    )
    return ((Get-ReviewerVerificationCandidatePairScore -Left $Left -Right $Right `
            -NearExactJaccard $NearExactJaccard -SemanticJaccard $SemanticJaccard) -ge 0.0)
}

function Get-ReviewerVerificationClusters {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        [int]$MaxCandidates = $script:ReviewerVerificationMaxCandidates,
        [int]$MaxClusterSize = $script:ReviewerVerificationMaxClusterSize,
        [ValidateRange(0.0, 1.0)][double]$NearExactJaccard = $script:ReviewerVerificationNearExactJaccard,
        [ValidateRange(0.0, 1.0)][double]$SemanticJaccard = $script:ReviewerVerificationSemanticJaccard
    )
    $MaxCandidates = [Math]::Min($MaxCandidates, $script:ReviewerVerificationMaxCandidates)
    $MaxClusterSize = [Math]::Min($MaxClusterSize, $script:ReviewerVerificationMaxClusterSize)
    $orderedItems = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in @($Candidates)) { [void]$orderedItems.Add($candidate) }
    $orderedItems.Sort([System.Comparison[object]] {
            param($left, $right)
            $semantic = [StringComparer]::Ordinal.Compare(
                (Get-ReviewerVerificationClusteringKey -Candidate $left),
                (Get-ReviewerVerificationClusteringKey -Candidate $right))
            if ($semantic -ne 0) { return $semantic }
            return [StringComparer]::Ordinal.Compare(
                [string](Get-ReviewerVerificationValue $left "candidateHash" ""),
                [string](Get-ReviewerVerificationValue $right "candidateHash" ""))
        })
    $activeItems = @($orderedItems | Select-Object -First $MaxCandidates)
    $overflowItems = @($orderedItems | Select-Object -Skip $MaxCandidates)
    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $activeItems) {
        $matchedGroup = $null
        $bestGroupScore = -1.0
        $bestGroupKey = ""
        foreach ($group in $groups) {
            $cohesive = $true
            $groupScore = 1.0
            foreach ($member in $group) {
                $pairScore = Get-ReviewerVerificationCandidatePairScore -Left $candidate -Right $member `
                    -NearExactJaccard $NearExactJaccard -SemanticJaccard $SemanticJaccard
                if ($pairScore -lt 0.0) {
                    $cohesive = $false
                    break
                }
                $groupScore = [Math]::Min($groupScore, $pairScore)
            }
            if (-not $cohesive) { continue }
            $groupKey = Get-ReviewerVerificationClusteringKey -Candidate $group[0]
            if ($null -eq $matchedGroup -or $groupScore -gt $bestGroupScore -or
                ($groupScore -eq $bestGroupScore -and
                    [StringComparer]::Ordinal.Compare($groupKey, $bestGroupKey) -lt 0)) {
                $matchedGroup = $group
                $bestGroupScore = $groupScore
                $bestGroupKey = $groupKey
            }
        }
        if (-not $matchedGroup) {
            $matchedGroup = [System.Collections.Generic.List[object]]::new()
            [void]$groups.Add($matchedGroup)
        }
        [void]$matchedGroup.Add($candidate)
    }
    if ($overflowItems.Count -gt 0) {
        $overflowGroup = [System.Collections.Generic.List[object]]::new()
        foreach ($candidate in $overflowItems) { [void]$overflowGroup.Add($candidate) }
        [void]$groups.Add($overflowGroup)
    }
    $clusters = [System.Collections.Generic.List[object]]::new()
    foreach ($group in $groups) {
        $members = [System.Collections.Generic.List[object]]::new()
        foreach ($member in $group) { [void]$members.Add($member) }
        $members.Sort([System.Comparison[object]] {
                param($left, $right)
                return [StringComparer]::Ordinal.Compare(
                    [string](Get-ReviewerVerificationValue $left "candidateHash" ""),
                    [string](Get-ReviewerVerificationValue $right "candidateHash" ""))
            })
        $hashes = @($members | ForEach-Object {
                [string](Get-ReviewerVerificationValue $_ "candidateHash" "")
            })
        $clusterHash = Get-ReviewerVerificationObjectSha256 -Value $hashes
        $origins = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($member in $members) {
            [void]$origins.Add([string](Get-ReviewerVerificationValue $member "originModel" ""))
        }
        $originList = [System.Collections.Generic.List[string]]::new()
        foreach ($origin in $origins) { [void]$originList.Add($origin) }
        $originList.Sort([StringComparer]::Ordinal)
        $status = if (@($members | Where-Object {
                    $overflowItems -contains $_
                }).Count -gt 0) {
            "candidateLimit"
        }
        elseif ($members.Count -gt $MaxClusterSize) {
            "clusterLimit"
        }
        else {
            "ready"
        }
        [void]$clusters.Add([pscustomobject][ordered]@{
                clusterId = "vc1:$clusterHash"
                status = $status
                memberHashes = $hashes
                origins = $originList.ToArray()
                members = $members.ToArray()
            })
    }
    $clusters.Sort([System.Comparison[object]] {
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string](Get-ReviewerVerificationValue $left "clusterId" ""),
                [string](Get-ReviewerVerificationValue $right "clusterId" ""))
        })
    return $clusters.ToArray()
}

function Get-ReviewerVerificationAcceptedConventionCandidateDecisions {
    param(
        [AllowEmptyCollection()][object[]]$Decisions = @(),
        [AllowEmptyCollection()][object[]]$Clusters = @()
    )
    $acceptedCandidates = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($decision in @($Decisions)) {
        $candidateId = [string](Get-ReviewerVerificationValue $decision "candidateId" "")
        if (-not $candidateId) { continue }
        if ($acceptedCandidates.ContainsKey($candidateId)) {
            throw "Verification decisions contain duplicate candidate id '$candidateId'."
        }
        $acceptedCandidates.Add($candidateId, $decision)
    }
    $result = [System.Collections.Generic.List[object]]::new()
    $seenOriginIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($cluster in @($Clusters)) {
        foreach ($member in @(Get-ReviewerVerificationValue $cluster "members" @())) {
            $candidateId = [string](Get-ReviewerVerificationValue $member "candidateId" "")
            if (-not $acceptedCandidates.ContainsKey($candidateId)) { continue }
            if ([string](Get-ReviewerVerificationValue $member "originKind" "") -cne "convention") {
                continue
            }
            $originCandidateId = [string](Get-ReviewerVerificationValue $member "originCandidateId" "")
            if (-not $originCandidateId -or -not $seenOriginIds.Add($originCandidateId)) { continue }
            $decision = $acceptedCandidates[$candidateId]
            [void]$result.Add([pscustomobject][ordered]@{
                    originCandidateId = $originCandidateId
                    candidateId = $candidateId
                    correctedSeverity = [string](Get-ReviewerVerificationValue $decision "correctedSeverity" "")
                    existingDebtFollowUpRetained = [bool](Get-ReviewerVerificationValue `
                        $decision "existingDebtFollowUpRetained" $false)
                })
        }
    }
    $result.Sort([System.Comparison[object]] {
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string]$left.originCandidateId, [string]$right.originCandidateId)
        })
    return $result.ToArray()
}

function Get-ReviewerVerificationAcceptedConventionCandidates {
    param(
        [AllowEmptyCollection()][object[]]$ConventionCandidates = @(),
        [AllowEmptyCollection()][object[]]$Decisions = @(),
        [AllowEmptyCollection()][object[]]$Clusters = @()
    )
    $candidateMap = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($candidate in @($ConventionCandidates)) {
        $candidateId = [string](Get-ReviewerVerificationValue $candidate "candidateId" "")
        if (-not $candidateId -or $candidateMap.ContainsKey($candidateId)) {
            throw "Convention candidate set contains a missing or duplicate candidate id."
        }
        $candidateMap.Add($candidateId, $candidate)
    }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($accepted in @(Get-ReviewerVerificationAcceptedConventionCandidateDecisions `
            -Decisions $Decisions -Clusters $Clusters)) {
        $originCandidateId = [string]$accepted.originCandidateId
        if (-not $candidateMap.ContainsKey($originCandidateId)) {
            throw "Accepted convention decision references unknown origin candidate '$originCandidateId'."
        }
        $candidate = Copy-ReviewerVerificationJsonValue -Value $candidateMap[$originCandidateId]
        if ([string]$accepted.correctedSeverity -cne "none") {
            $candidate.severity = [string]$accepted.correctedSeverity
        }
        $debt = Get-ReviewerVerificationValue $candidate "existingDebtFollowUp" $null
        if ([string](Get-ReviewerVerificationValue $debt "status" "") -ceq "required" -and
            -not [bool]$accepted.existingDebtFollowUpRetained) {
            $candidate.existingDebtFollowUp = [pscustomobject][ordered]@{
                status = "none"; evidenceFactId = ""; selectorKey = ""; scopeKind = ""; scopePath = ""
                comparableCount = 0; compliantCount = 0; action = ""
            }
        }
        [void]$result.Add($candidate)
    }
    return $result.ToArray()
}

function Get-ReviewerVerificationAcceptedConventionCandidateIds {
    param(
        [AllowEmptyCollection()][object[]]$Decisions = @(),
        [AllowEmptyCollection()][object[]]$Clusters = @()
    )
    $candidateIds = [System.Collections.Generic.List[string]]::new()
    foreach ($accepted in @(Get-ReviewerVerificationAcceptedConventionCandidateDecisions `
            -Decisions $Decisions -Clusters $Clusters)) {
        [void]$candidateIds.Add([string]$accepted.originCandidateId)
    }
    return $candidateIds.ToArray()
}

function Get-ReviewerVerificationThreadFacts {
    param($FactPlan)
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($fact in @(Get-ReviewerVerificationValue $FactPlan "facts" @())) {
        if ([string](Get-ReviewerVerificationValue $fact "domain" "") -cne "threads" -or
            [string](Get-ReviewerVerificationValue $fact "kind" "") -cne "reviewThread" -or
            [string](Get-ReviewerVerificationValue $fact "state" "") -cne "true") {
            continue
        }
        $value = Get-ReviewerVerificationValue $fact "value"
        [void]$records.Add([pscustomobject][ordered]@{
                threadId = [string](Get-ReviewerVerificationValue $fact "subject" "")
                fingerprint = [string](Get-ReviewerVerificationValue $value "fingerprint" "")
                contentSha256 = [string](Get-ReviewerVerificationValue $value "contentSha256" "")
                filePath = [string](Get-ReviewerVerificationValue $value "filePath" "")
                line = [int](Get-ReviewerVerificationValue $value "line" 0)
                status = [string](Get-ReviewerVerificationValue $value "status" "")
                authorClasses = @((Get-ReviewerVerificationValue $value "authorClasses" @()))
                sanitizedSubstance = [string](Get-ReviewerVerificationValue $value "sanitizedSubstance" "")
                substanceTruncated = [bool](Get-ReviewerVerificationValue $value "substanceTruncated" $false)
            })
    }
    $records.Sort([System.Comparison[object]] {
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string](Get-ReviewerVerificationValue $left "threadId" ""),
                [string](Get-ReviewerVerificationValue $right "threadId" ""))
        })
    return $records.ToArray()
}

function Find-ReviewerVerificationExistingDuplicate {
    param(
        [Parameter(Mandatory)]$Candidate,
        [object[]]$ThreadFacts = @(),
        [ValidateRange(0.0, 1.0)][double]$ExistingThreadJaccard = $script:ReviewerVerificationExistingThreadJaccard
    )
    $candidatePath = ConvertTo-ReviewerVerificationPath -Path (
        [string](Get-ReviewerVerificationValue $Candidate "filePath" ""))
    $candidateLine = [int](Get-ReviewerVerificationValue $Candidate "line" 0)
    $candidateText = [string](Get-ReviewerVerificationValue $Candidate "comment" (
            Get-ReviewerVerificationValue $Candidate "evidence" ""))
    $candidateTokens = @(Get-ReviewerVerificationTokens -Text $candidateText)
    foreach ($thread in @($ThreadFacts)) {
        $threadPath = ConvertTo-ReviewerVerificationPath -Path (
            [string](Get-ReviewerVerificationValue $thread "filePath" ""))
        $threadLine = [int](Get-ReviewerVerificationValue $thread "line" 0)
        if ($candidatePath -cne $threadPath -or $candidateLine -ne $threadLine) { continue }
        $threadText = [string](Get-ReviewerVerificationValue $thread "sanitizedSubstance" "")
        $threadTokens = @(Get-ReviewerVerificationTokens -Text $threadText)
        if ($candidateTokens.Count -ge 3 -and
            (Get-ReviewerVerificationSimilarity -Left $candidateTokens -Right $threadTokens) -ge
            $ExistingThreadJaccard) {
            $authorClasses = @((Get-ReviewerVerificationValue $thread "authorClasses" @()))
            return [pscustomobject][ordered]@{
                duplicate = $true
                targetId = "thread:" + [string](Get-ReviewerVerificationValue $thread "threadId" "")
                evidenceSha256 = [string](Get-ReviewerVerificationValue $thread "contentSha256" "")
                reason = $(if ($authorClasses -ccontains "agent") { "duplicatePriorAgent" } else { "duplicateExistingThread" })
            }
        }
    }
    return [pscustomobject][ordered]@{
        duplicate = $false; targetId = ""; evidenceSha256 = ""; reason = ""
    }
}

function Test-ReviewerVerificationThreadRelevant {
    param(
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)]$Thread,
        [ValidateRange(0.0, 1.0)][double]$ExistingThreadJaccard = $script:ReviewerVerificationExistingThreadJaccard
    )
    $candidatePath = ConvertTo-ReviewerVerificationPath -Path (
        [string](Get-ReviewerVerificationValue $Candidate "filePath" ""))
    $candidateLine = [int](Get-ReviewerVerificationValue $Candidate "line" 0)
    $threadPath = ConvertTo-ReviewerVerificationPath -Path (
        [string](Get-ReviewerVerificationValue $Thread "filePath" ""))
    $threadLine = [int](Get-ReviewerVerificationValue $Thread "line" 0)
    if ($candidatePath -cne $threadPath -or $candidateLine -ne $threadLine) { return $false }
    $candidateText = [string](Get-ReviewerVerificationValue $Candidate "comment" (
            Get-ReviewerVerificationValue $Candidate "evidence" ""))
    $threadText = [string](Get-ReviewerVerificationValue $Thread "sanitizedSubstance" "")
    $candidateTokens = @(Get-ReviewerVerificationTokens -Text $candidateText)
    $threadTokens = @(Get-ReviewerVerificationTokens -Text $threadText)
    return ($candidateTokens.Count -ge 3 -and
        (Get-ReviewerVerificationSimilarity -Left $candidateTokens -Right $threadTokens) -ge
        $ExistingThreadJaccard)
}

function Get-ReviewerVerificationAssignments {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Clusters,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$GeneralistModels,
        [AllowEmptyString()][string]$ConventionVerifierModel = "",
        [string[]]$ChangedPaths = @()
    )
    $modelSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $models = [System.Collections.Generic.List[string]]::new()
    foreach ($model in @($GeneralistModels)) {
        if ([string]::IsNullOrWhiteSpace([string]$model)) { continue }
        if ($modelSet.Add([string]$model)) { [void]$models.Add([string]$model) }
    }
    if ($models.Count -ne 2) {
        throw "Cross-verification requires exactly two distinct configured generalist models."
    }
    $models.Sort([StringComparer]::Ordinal)
    if ($ConventionVerifierModel -and -not $modelSet.Contains($ConventionVerifierModel)) {
        throw "The compatibility convention verifier model must name one of the two generalist cross-check models."
    }
    $changed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in @($ChangedPaths)) {
        $normalized = ConvertTo-ReviewerVerificationPath -Path ([string]$path)
        if ($normalized) { [void]$changed.Add($normalized) }
    }
    $assignments = [System.Collections.Generic.List[object]]::new()
    foreach ($cluster in @($Clusters)) {
        if ([string](Get-ReviewerVerificationValue $cluster "status" "ready") -cne "ready") {
            continue
        }
        foreach ($candidate in @(Get-ReviewerVerificationValue $cluster "members" @())) {
            $originKind = [string](Get-ReviewerVerificationValue $candidate "originKind" "")
            $originModel = [string](Get-ReviewerVerificationValue $candidate "originModel" "")
            if ($originKind -ceq "convention" -and $modelSet.Contains($originModel)) {
                throw "The convention-specialist discovery model cannot be a generalist cross-check model."
            }
            if ($changed.Count -gt 0 -and [string]$candidate.anchorKind -ceq "changedFile") {
                $candidatePath = ConvertTo-ReviewerVerificationPath -Path ([string]$candidate.filePath)
                if (-not $candidatePath -or [int]$candidate.line -lt 1 -or
                    -not $changed.Contains($candidatePath)) {
                    continue
                }
            }
            foreach ($target in $models) {
                [void]$assignments.Add([pscustomobject][ordered]@{
                        assignmentId = "va1:" + (Get-ReviewerVerificationObjectSha256 -Value @(
                                [string](Get-ReviewerVerificationValue $cluster "clusterId" ""),
                                [string](Get-ReviewerVerificationValue $candidate "candidateHash" ""),
                                $target
                            ))
                        clusterId = [string](Get-ReviewerVerificationValue $cluster "clusterId" "")
                        candidateId = [string](Get-ReviewerVerificationValue $candidate "candidateId" "")
                        candidateHash = [string](Get-ReviewerVerificationValue $candidate "candidateHash" "")
                        originKind = $originKind
                        originModel = $originModel
                        ruleQuote = [string](Get-ReviewerVerificationValue $candidate "ruleQuote" "")
                        verifierModel = $target
                    })
            }
        }
    }
    $assignments.Sort([System.Comparison[object]] {
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string](Get-ReviewerVerificationValue $left "assignmentId" ""),
                [string](Get-ReviewerVerificationValue $right "assignmentId" ""))
        })
    return $assignments.ToArray()
}

function Test-ReviewerVerificationReportedModel {
    param(
        [Parameter(Mandatory)][string]$ExpectedModel,
        [AllowEmptyString()][string]$ReportedModel = ""
    )
    return (-not [string]::IsNullOrWhiteSpace($ReportedModel) -and
        [string]::Equals($ExpectedModel, $ReportedModel, [StringComparison]::Ordinal))
}

function Get-ReviewerVerificationRunBudget {
    param(
        [ValidateRange(0, [int]::MaxValue)][int]$RunsLaunched,
        [ValidateRange(1, [int]::MaxValue)][int]$MaxRuns,
        [ValidateRange(0.0, [double]::MaxValue)][double]$ElapsedSeconds,
        [ValidateRange(30, [int]::MaxValue)][int]$MaxPhaseSeconds,
        [ValidateRange(30, 3600)][int]$ConfiguredRunTimeoutSeconds
    )
    $effectiveMaxRuns = [Math]::Min($MaxRuns, $script:ReviewerVerificationMaxVerifierRuns)
    $effectiveMaxSeconds = [Math]::Min(
        $MaxPhaseSeconds, $script:ReviewerVerificationMaxPhaseSeconds)
    if ($RunsLaunched -ge $effectiveMaxRuns) {
        return [pscustomobject][ordered]@{
            canRun = $false; reason = "candidateLimit"; timeoutSeconds = 0; remainingSeconds = 0
        }
    }
    $remaining = [int][Math]::Floor($effectiveMaxSeconds - $ElapsedSeconds)
    if ($remaining -lt 30) {
        return [pscustomobject][ordered]@{
            canRun = $false; reason = "timeout"; timeoutSeconds = 0
            remainingSeconds = [Math]::Max(0, $remaining)
        }
    }
    return [pscustomobject][ordered]@{
        canRun = $true
        reason = ""
        timeoutSeconds = [Math]::Min($ConfiguredRunTimeoutSeconds, $remaining)
        remainingSeconds = $remaining
    }
}

function Get-ReviewerVerificationMarkerSchema {
    param(
        [Parameter(Mandatory)][string]$ExpectedProject,
        [Parameter(Mandatory)][string]$ExpectedNonce,
        [Parameter(Mandatory)][string]$ExpectedVerifierModel,
        [int]$MaxVerdicts = $script:ReviewerVerificationMaxClusterSize
    )
    $ascii = '^[\x20-\x7E]*$'
    return @{
        Keys = @(
            "schemaVersion", "prId", "repositoryId", "project", "reviewedSourceCommit",
            "targetCommit", "changeSetDigest", "verificationInputSha256", "clusterId",
            "configSha256", "scriptSha256", "promptSha256", "verifierModel",
            "verdicts", "diagnostics", "nonce"
        )
        Fields = @{
            schemaVersion = @{ Type = "int"; Min = 1; Max = 1 }
            prId = @{ Type = "int"; Min = 1; Max = [int]::MaxValue }
            repositoryId = @{ Type = "guid" }
            project = @{ Type = "exact"; Expected = $ExpectedProject }
            reviewedSourceCommit = @{ Type = "hex"; Length = 40 }
            targetCommit = @{ Type = "hex"; Length = 40 }
            changeSetDigest = @{ Type = "hex"; Length = 64 }
            verificationInputSha256 = @{ Type = "hex"; Length = 64 }
            clusterId = @{ Type = "string"; MaxLength = 68; Pattern = '^vc1:[0-9a-f]{64}$' }
            configSha256 = @{ Type = "hex"; Length = 64 }
            scriptSha256 = @{ Type = "hex"; Length = 64 }
            promptSha256 = @{ Type = "hex"; Length = 64 }
            verifierModel = @{ Type = "exact"; Expected = $ExpectedVerifierModel }
            verdicts = @{
                Type = "objectArray"; MaxItems = $MaxVerdicts
                Item = @{
                    Keys = @(
                        "candidateId", "candidateHash", "outcome", "evidenceKind",
                        "evidenceSha256", "factIds", "duplicateTargetId",
                        "correctedSeverity", "rationale", "confidence",
                        "changedCodeFixOutcome", "changedCodeFixEvidenceSha256",
                        "changedCodeFixFactIds", "existingDebtFollowUpOutcome",
                        "existingDebtEvidenceSha256", "existingDebtEvidenceFactId"
                    )
                    Fields = @{
                        candidateId = @{ Type = "string"; MaxLength = 70; Pattern = '^cand1:[0-9a-f]{64}$' }
                        candidateHash = @{ Type = "hex"; Length = 64 }
                        outcome = @{ Type = "enum"; Values = $script:ReviewerVerificationOutcomes }
                        evidenceKind = @{
                            Type = "enum"
                            Values = @("diffHunk", "sourceQuote", "deterministicFact", "sibling", "existingThread", "siblingCandidate")
                        }
                        evidenceSha256 = @{ Type = "hex"; Length = 64 }
                        factIds = @{
                            Type = "string"; MaxLength = 600; AllowEmpty = $true
                            Pattern = '^(|rf1:[0-9a-f]{64}(,rf1:[0-9a-f]{64}){0,7})$'
                        }
                        duplicateTargetId = @{ Type = "string"; MaxLength = 160; AllowEmpty = $true; Pattern = $ascii }
                        correctedSeverity = @{
                            Type = "enum"; Values = @("none", "suggestion", "important", "critical")
                        }
                        rationale = @{ Type = "string"; MaxLength = 900; Pattern = '^(?=.*\S)[\x20-\x7E]+$' }
                        confidence = @{ Type = "enum"; Values = @("low", "medium", "high") }
                        changedCodeFixOutcome = @{
                            Type = "enum"; Values = @("notApplicable", "supported", "unsupported", "needsHuman")
                        }
                        changedCodeFixEvidenceSha256 = @{
                            Type = "string"; MaxLength = 64; AllowEmpty = $true; Pattern = '^(|[0-9a-f]{64})$'
                        }
                        changedCodeFixFactIds = @{
                            Type = "string"; MaxLength = 600; AllowEmpty = $true
                            Pattern = '^(|rf1:[0-9a-f]{64}(,rf1:[0-9a-f]{64}){0,7})$'
                        }
                        existingDebtFollowUpOutcome = @{
                            Type = "enum"; Values = @("notRequested", "supported", "unsupported", "needsHuman")
                        }
                        existingDebtEvidenceSha256 = @{
                            Type = "string"; MaxLength = 64; AllowEmpty = $true; Pattern = '^(|[0-9a-f]{64})$'
                        }
                        existingDebtEvidenceFactId = @{
                            Type = "string"; MaxLength = 69; AllowEmpty = $true; Pattern = '^(|rdf1:[0-9a-f]{64})$'
                        }
                    }
                }
            }
            diagnostics = @{
                Type = "objectArray"; MaxItems = 8
                Item = @{
                    Keys = @("candidateId", "reason", "detail")
                    Fields = @{
                        candidateId = @{ Type = "string"; MaxLength = 70; AllowEmpty = $true; Pattern = '^(|cand1:[0-9a-f]{64})$' }
                        reason = @{ Type = "enum"; Values = @("none", "partialEvidence", "ambiguous", "toolUnavailable") }
                        detail = @{ Type = "string"; MaxLength = 600; Pattern = $ascii }
                    }
                }
            }
            nonce = @{ Type = "exact"; Expected = $ExpectedNonce }
        }
    }
}

function Test-ReviewerVerificationBinding {
    param(
        [Parameter(Mandatory)][hashtable]$Marker,
        [Parameter(Mandatory)][int]$PrId,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$TargetCommit,
        [Parameter(Mandatory)][string]$ChangeSetDigest,
        [Parameter(Mandatory)][string]$VerificationInputSha256,
        [Parameter(Mandatory)][string]$ClusterId,
        [Parameter(Mandatory)][string]$ConfigSha256,
        [Parameter(Mandatory)][string]$ScriptSha256,
        [Parameter(Mandatory)][string]$PromptSha256,
        [Parameter(Mandatory)][string]$VerifierModel
    )
    foreach ($pair in @(
            @("repositoryId", $RepositoryId), @("reviewedSourceCommit", $SourceCommit),
            @("targetCommit", $TargetCommit), @("changeSetDigest", $ChangeSetDigest),
            @("verificationInputSha256", $VerificationInputSha256), @("clusterId", $ClusterId),
            @("configSha256", $ConfigSha256), @("scriptSha256", $ScriptSha256),
            @("promptSha256", $PromptSha256), @("verifierModel", $VerifierModel)
        )) {
        if (-not [string]::Equals([string]$Marker[[string]$pair[0]], [string]$pair[1],
                [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return [int]$Marker.prId -eq $PrId
}

function Test-ReviewerVerificationForbiddenText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return $Text -match '(?i)(recommendedVote|approveWithSuggestions|waitForAuthor|approvedVote|"vote"\s*:|"comment"\s*:|"write"\s*:)'
}

function Get-ReviewerVerificationDeterministicFacts {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        $FactPlan = $null,
        [ValidateRange(1, 32)][int]$MaxFactIds = 16,
        [ValidateRange(1024, 65536)][int]$MaxCanonicalBytes = 32768
    )
    $requested = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $includeMetadata = $false
    foreach ($candidate in $Candidates) {
        if ([string](Get-ReviewerVerificationValue $candidate "anchorKind" "") -ceq "prMetadata") {
            $includeMetadata = $true
        }
        foreach ($text in @(
                [string](Get-ReviewerVerificationValue $candidate "factIds" ""),
                [string](Get-ReviewerVerificationValue (
                        Get-ReviewerVerificationValue $candidate "changedCodeFix" $null) "evidenceFactIds" ""))) {
            $ids = @($text -split ',' | Where-Object { $_ })
            $seenSubset = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            if ($ids.Count -gt 8) { throw "A verifier fact subset exceeded the 8-ID bound." }
            foreach ($id in $ids) {
                if ($id -cnotmatch '^rf1:[0-9a-f]{64}$' -or -not $seenSubset.Add($id)) {
                    throw "A verifier fact subset contains a malformed or duplicate ID."
                }
                [void]$requested.Add($id)
            }
        }
    }
    $factMap = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($fact in @(Get-ReviewerVerificationValue $FactPlan "facts" @())) {
        $id = [string](Get-ReviewerVerificationValue $fact "id" "")
        if (-not $id -or $factMap.ContainsKey($id)) {
            throw "The verifier fact plan contains a missing or duplicate ID."
        }
        $factMap.Add($id, $fact)
        if ($includeMetadata -and [string](Get-ReviewerVerificationValue $fact "domain" "") -ceq "metadata") {
            [void]$requested.Add($id)
        }
    }
    if ($requested.Count -gt $MaxFactIds) {
        throw "Verification deterministic-fact union exceeded the $MaxFactIds-ID bound."
    }
    foreach ($id in $requested) {
        if (-not $factMap.ContainsKey($id)) { throw "A verifier fact subset cites an invented or missing ID." }
    }
    $facts = @((Get-ReviewerVerificationValue $FactPlan "facts" @()) | Where-Object {
            $requested.Contains([string](Get-ReviewerVerificationValue $_ "id" ""))
        })
    $canonical = ConvertTo-ReviewerVerificationCanonicalArray -Items $facts
    if ($script:ReviewerVerificationUtf8.GetByteCount($canonical) -gt $MaxCanonicalBytes) {
        throw "Verification deterministic facts exceeded the $MaxCanonicalBytes-byte bound."
    }
    return $facts
}

function Get-ReviewerVerificationCandidateFactPartition {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        $FactPlan = $null,
        [ValidateRange(1, 32)][int]$MaxFactIds = 16,
        [ValidateRange(1024, 65536)][int]$MaxCanonicalBytes = 32768
    )
    [void](Get-ReviewerVerificationDeterministicFacts -Candidates @() -FactPlan $FactPlan `
            -MaxFactIds $MaxFactIds -MaxCanonicalBytes $MaxCanonicalBytes)
    $accepted = [System.Collections.Generic.List[object]]::new()
    $withheld = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $Candidates) {
        try {
            [void](Get-ReviewerVerificationDeterministicFacts -Candidates @($candidate) `
                    -FactPlan $FactPlan -MaxFactIds $MaxFactIds `
                    -MaxCanonicalBytes $MaxCanonicalBytes)
            [void]$accepted.Add($candidate)
        }
        catch {
            [void]$withheld.Add([pscustomobject][ordered]@{
                    candidateId = [string](Get-ReviewerVerificationValue $candidate "candidateId" "")
                    clusterId = ""
                    reason = "missingEvidence"
                    detail = "Candidate deterministic-fact evidence was rejected: $($_.Exception.Message)"
                })
        }
    }
    return [pscustomobject][ordered]@{
        candidates = $accepted.ToArray()
        withheld = $withheld.ToArray()
    }
}

function Get-ReviewerVerificationClusterFactPartition {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Clusters,
        $FactPlan = $null,
        [ValidateRange(1, 32)][int]$MaxFactIds = 16,
        [ValidateRange(1024, 65536)][int]$MaxCanonicalBytes = 32768
    )
    $rejectedIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $withheld = [System.Collections.Generic.List[object]]::new()
    foreach ($cluster in $Clusters) {
        if ([string](Get-ReviewerVerificationValue $cluster "status" "") -cne "ready") {
            continue
        }
        $acceptedMembers = [System.Collections.Generic.List[object]]::new()
        foreach ($candidate in @(Get-ReviewerVerificationValue $cluster "members" @())) {
            $trial = @($acceptedMembers.ToArray()) + @($candidate)
            try {
                [void](Get-ReviewerVerificationDeterministicFacts -Candidates $trial `
                        -FactPlan $FactPlan -MaxFactIds $MaxFactIds `
                        -MaxCanonicalBytes $MaxCanonicalBytes)
                [void]$acceptedMembers.Add($candidate)
            }
            catch {
                $candidateId = [string](Get-ReviewerVerificationValue $candidate "candidateId" "")
                [void]$rejectedIds.Add($candidateId)
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId
                        clusterId = [string](Get-ReviewerVerificationValue $cluster "clusterId" "")
                        reason = "missingEvidence"
                        detail = "Candidate deterministic facts exceed the bounded verifier input for this cluster."
                    })
            }
        }
    }
    return [pscustomobject][ordered]@{
        candidates = @($Candidates | Where-Object {
                -not $rejectedIds.Contains(
                    [string](Get-ReviewerVerificationValue $_ "candidateId" ""))
            })
        withheld = $withheld.ToArray()
    }
}

function Get-ReviewerVerificationEvidenceOptions {
    param(
        [Parameter(Mandatory)]$Candidate,
        $FactPlan = $null,
        [object[]]$ThreadFacts = @(),
        [object[]]$EvidenceHunks = @(),
        [object[]]$SiblingCandidates = @(),
        [ValidateRange(0.0, 1.0)][double]$ExistingThreadJaccard = $script:ReviewerVerificationExistingThreadJaccard
    )
    $candidateId = [string](Get-ReviewerVerificationValue $Candidate "candidateId" "")
    $options = [System.Collections.Generic.List[object]]::new()
    $hunk = @($EvidenceHunks | Where-Object {
            [string](Get-ReviewerVerificationValue $_ "candidateId" "") -ceq $candidateId
        } | Select-Object -First 1)
    if ($hunk.Count -eq 1 -and
        [string](Get-ReviewerVerificationValue $hunk[0] "sha256" "") -match '^[0-9a-f]{64}$') {
        [void]$options.Add([pscustomobject][ordered]@{
                purpose = "candidate"
                kind = "diffHunk"
                sha256 = [string](Get-ReviewerVerificationValue $hunk[0] "sha256" "")
                factIds = ""
                evidenceFactId = ""
                duplicateTargetId = ""
            })
    }
    $quote = [string](Get-ReviewerVerificationValue $Candidate "ruleQuote" "")
    if ($quote) {
        [void]$options.Add([pscustomobject][ordered]@{
                purpose = "candidate"
                kind = "sourceQuote"
                sha256 = Get-ReviewerVerificationSha256 -Text $quote
                factIds = ""
                evidenceFactId = ""
                duplicateTargetId = ""
            })
    }
    $siblingText = if ([string](Get-ReviewerVerificationValue $Candidate "siblingStatus" "") -ceq "checked") {
        [string](Get-ReviewerVerificationValue $Candidate "siblingEvidence" "")
    }
    else {
        [string](Get-ReviewerVerificationValue $Candidate "siblingNotRequiredReason" "")
    }
    if ($siblingText) {
        [void]$options.Add([pscustomobject][ordered]@{
                purpose = "candidate"
                kind = "sibling"
                sha256 = Get-ReviewerVerificationSha256 -Text $siblingText
                factIds = ""
                evidenceFactId = ""
                duplicateTargetId = ""
            })
    }
    $factMap = @{}
    foreach ($fact in @(Get-ReviewerVerificationValue $FactPlan "facts" @())) {
        $id = [string](Get-ReviewerVerificationValue $fact "id" "")
        if ($id) { $factMap[$id] = $fact }
    }
    $candidateFactIds = @(([string](Get-ReviewerVerificationValue $Candidate "factIds" "")) -split ',' |
        Where-Object { $_ })
    if ($candidateFactIds.Count -gt 0) {
        $facts = [System.Collections.Generic.List[object]]::new()
        foreach ($factId in $candidateFactIds) {
            if ($factMap.ContainsKey($factId)) { [void]$facts.Add($factMap[$factId]) }
        }
        if ($facts.Count -eq $candidateFactIds.Count) {
            [void]$options.Add([pscustomobject][ordered]@{
                    purpose = "candidate"
                    kind = "deterministicFact"
                    sha256 = Get-ReviewerVerificationSha256 -Text (
                        ConvertTo-ReviewerVerificationCanonicalArray -Items $facts.ToArray())
                    factIds = ($candidateFactIds -join ",")
                    evidenceFactId = ""
                    duplicateTargetId = ""
                })
        }
    }
    elseif ([string](Get-ReviewerVerificationValue $Candidate "anchorKind" "") -ceq "prMetadata") {
        foreach ($fact in @(Get-ReviewerVerificationValue $FactPlan "facts" @())) {
            if ([string](Get-ReviewerVerificationValue $fact "domain" "") -cne "metadata" -or
                [string](Get-ReviewerVerificationValue $fact "state" "") -notin @("true", "false")) {
                continue
            }
            $factId = [string](Get-ReviewerVerificationValue $fact "id" "")
            [void]$options.Add([pscustomobject][ordered]@{
                    purpose = "candidate"
                    kind = "deterministicFact"
                    sha256 = Get-ReviewerVerificationSha256 -Text (
                        ConvertTo-ReviewerVerificationCanonicalArray -Items @($fact))
                    factIds = $factId
                    evidenceFactId = ""
                    duplicateTargetId = ""
                })
        }
    }
    if ([string](Get-ReviewerVerificationValue $Candidate "originKind" "") -ceq "convention") {
        $changedFix = Get-ReviewerVerificationValue $Candidate "changedCodeFix" $null
        $changedValueSource = [string](Get-ReviewerVerificationValue $changedFix "valueSource" "")
        $changedFactText = [string](Get-ReviewerVerificationValue $changedFix "evidenceFactIds" "")
        if ($changedValueSource -ceq "authoritativeRule" -and $quote) {
            [void]$options.Add([pscustomobject][ordered]@{
                    purpose = "changedCodeFix"; kind = "sourceQuote"
                    sha256 = Get-ReviewerVerificationSha256 -Text $quote
                    factIds = ""; evidenceFactId = ""; duplicateTargetId = ""
                })
        }
        elseif ($changedValueSource -ceq "deterministicFact") {
            $changedFactIds = @($changedFactText -split ',' | Where-Object { $_ })
            $uniqueChangedFactIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $changedFacts = [System.Collections.Generic.List[object]]::new()
            $validChangedSubset = ($changedFactIds.Count -gt 0 -and $changedFactIds.Count -le 8)
            foreach ($factId in $changedFactIds) {
                if (-not $uniqueChangedFactIds.Add($factId) -or -not $factMap.ContainsKey($factId) -or
                    [string](Get-ReviewerVerificationValue $factMap[$factId] "state" "") -notin @("true", "false")) {
                    $validChangedSubset = $false
                    continue
                }
                [void]$changedFacts.Add($factMap[$factId])
            }
            if ($validChangedSubset -and $changedFacts.Count -eq $changedFactIds.Count) {
                [void]$options.Add([pscustomobject][ordered]@{
                        purpose = "changedCodeFix"; kind = "deterministicFact"
                        sha256 = Get-ReviewerVerificationSha256 -Text (
                            ConvertTo-ReviewerVerificationCanonicalArray -Items $changedFacts.ToArray())
                        factIds = ($changedFactIds -join ",")
                        evidenceFactId = ""; duplicateTargetId = ""
                    })
            }
        }
        $debtFollowUp = Get-ReviewerVerificationValue $Candidate "existingDebtFollowUp" $null
        $debtEvidence = Get-ReviewerVerificationValue $Candidate "existingDebtEvidence" $null
        if ([string](Get-ReviewerVerificationValue $debtFollowUp "status" "") -ceq "required" -and
            $null -ne $debtEvidence) {
            $debtFactId = [string](Get-ReviewerVerificationValue $debtFollowUp "evidenceFactId" "")
            if ($debtFactId -cmatch '^rdf1:[0-9a-f]{64}$' -and
                [string](Get-ReviewerVerificationValue $debtEvidence "evidenceFactId" "") -ceq $debtFactId) {
                [void]$options.Add([pscustomobject][ordered]@{
                        purpose = "existingDebtFollowUp"; kind = "debtCensus"
                        sha256 = Get-ReviewerVerificationObjectSha256 -Value $debtEvidence
                        factIds = ""; evidenceFactId = $debtFactId; duplicateTargetId = ""
                    })
            }
        }
    }
    foreach ($thread in @($ThreadFacts)) {
        if (-not (Test-ReviewerVerificationThreadRelevant -Candidate $Candidate -Thread $thread `
                -ExistingThreadJaccard $ExistingThreadJaccard)) {
            continue
        }
        $threadId = [string](Get-ReviewerVerificationValue $thread "threadId" "")
        $contentSha = [string](Get-ReviewerVerificationValue $thread "contentSha256" "")
        if ($threadId -and $contentSha -match '^[0-9a-f]{64}$') {
            [void]$options.Add([pscustomobject][ordered]@{
                    purpose = "candidate"
                    kind = "existingThread"
                    sha256 = $contentSha
                    factIds = ""
                    evidenceFactId = ""
                    duplicateTargetId = "thread:$threadId"
                })
        }
    }
    foreach ($sibling in @($SiblingCandidates)) {
        $siblingId = [string](Get-ReviewerVerificationValue $sibling "candidateId" "")
        $siblingHash = [string](Get-ReviewerVerificationValue $sibling "candidateHash" "")
        if ($siblingId -and $siblingId -cne
                [string](Get-ReviewerVerificationValue $Candidate "candidateId" "") -and
                $siblingHash -match '^[0-9a-f]{64}$') {
                [void]$options.Add([pscustomobject][ordered]@{
                        purpose = "candidate"
                        kind = "siblingCandidate"
                        sha256 = $siblingHash
                        factIds = ""
                        evidenceFactId = ""
                        duplicateTargetId = $siblingId
                    })
        }
    }
    return $options.ToArray()
}

function Resolve-ReviewerVerificationDecisions {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Clusters,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assignments,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$VerifierRuns,
        [object[]]$ThreadFacts = @(),
        [string[]]$ChangedPaths = @(),
        $FactPlan = $null,
        [object[]]$ResolvedSources = @(),
        [object[]]$EvidenceHunks = @(),
        [object[]]$PreVerificationWithheld = @(),
        [ValidateRange(0.0, 1.0)][double]$ExistingThreadJaccard = $script:ReviewerVerificationExistingThreadJaccard,
        [bool]$SpecialistDegraded = $false,
        [string[]]$RequiredVerifierModels = @()
    )
    $eligible = [System.Collections.Generic.List[object]]::new()
    $withheld = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($PreVerificationWithheld)) { [void]$withheld.Add($item) }
    $decisions = [System.Collections.Generic.List[object]]::new()
    $assignmentMap = @{}
    foreach ($assignment in @($Assignments)) {
        $candidateId = [string](Get-ReviewerVerificationValue $assignment "candidateId" "")
        if (-not $assignmentMap.ContainsKey($candidateId)) {
            $assignmentMap[$candidateId] = [System.Collections.Generic.List[object]]::new()
        }
        [void]$assignmentMap[$candidateId].Add($assignment)
    }
    $runMap = @{}
    foreach ($run in @($VerifierRuns)) {
        $assignmentId = [string](Get-ReviewerVerificationValue $run "assignmentId" "")
        if ($assignmentId -and -not $runMap.ContainsKey($assignmentId)) { $runMap[$assignmentId] = $run }
    }
    $changed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in @($ChangedPaths)) {
        $normalized = ConvertTo-ReviewerVerificationPath -Path ([string]$path)
        if ($normalized) { [void]$changed.Add($normalized) }
    }
    $factMap = @{}
    foreach ($fact in @(Get-ReviewerVerificationValue $FactPlan "facts" @())) {
        $factId = [string](Get-ReviewerVerificationValue $fact "id" "")
        if ($factId) { $factMap[$factId] = $fact }
    }
    $sourceMap = @{}
    foreach ($source in @($ResolvedSources)) {
        $sourceId = [string](Get-ReviewerVerificationValue $source "SourceId" (
                Get-ReviewerVerificationValue $source "sourceId" ""))
        if ($sourceId -and -not $sourceMap.ContainsKey($sourceId)) { $sourceMap[$sourceId] = $source }
    }
    foreach ($cluster in @($Clusters)) {
        $clusterId = [string](Get-ReviewerVerificationValue $cluster "clusterId" "")
        $clusterStatus = [string](Get-ReviewerVerificationValue $cluster "status" "ready")
        if ($clusterStatus -cne "ready") {
            foreach ($candidate in @(Get-ReviewerVerificationValue $cluster "members" @())) {
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = [string]$candidate.candidateId
                        candidateHash = [string]$candidate.candidateHash
                        originKind = [string]$candidate.originKind
                        originModel = [string]$candidate.originModel
                        clusterId = $clusterId
                        reason = $clusterStatus
                        detail = $(if ($clusterStatus -ceq "clusterLimit") {
                            "Candidate belongs to a semantic cluster above the versioned member cap."
                        }
                        else {
                            "Candidate exceeds the versioned normalization cap."
                        })
                    })
            }
            continue
        }
        $clusterCandidates = [System.Collections.Generic.List[object]]::new()
        foreach ($candidate in @(Get-ReviewerVerificationValue $cluster "members" @())) {
            $candidateFailed = $false
            $candidateId = [string](Get-ReviewerVerificationValue $candidate "candidateId" "")
            $candidateHash = [string](Get-ReviewerVerificationValue $candidate "candidateHash" "")
            $originKind = [string](Get-ReviewerVerificationValue $candidate "originKind" "")
            if ($originKind -ceq "convention" -and $SpecialistDegraded) {
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; clusterId = $clusterId
                        reason = "specialistDegraded"; detail = "The specialist discovery artifact was degraded."
                    })
                continue
            }
            $duplicate = Find-ReviewerVerificationExistingDuplicate -Candidate $candidate `
                -ThreadFacts $ThreadFacts -ExistingThreadJaccard $ExistingThreadJaccard
            if ([bool]$duplicate.duplicate) {
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; clusterId = $clusterId
                        reason = [string]$duplicate.reason; detail = [string]$duplicate.targetId
                    })
                continue
            }
            $path = ConvertTo-ReviewerVerificationPath -Path ([string]$candidate.filePath)
            $anchorValid = if ([string]$candidate.anchorKind -ceq "prMetadata") {
                [int]$candidate.line -eq 0 -and -not $candidate.filePath
            }
            else {
                $path -and [int]$candidate.line -gt 0 -and $changed.Contains($path)
            }
            if (-not $anchorValid) {
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; clusterId = $clusterId
                        reason = "anchorInvalid"; detail = "The candidate anchor is not in the pinned change set."
                    })
                continue
            }
            $candidateAssignments = @(if ($assignmentMap.ContainsKey($candidateId)) {
                @($assignmentMap[$candidateId])
            }
            else {
                @()
            })
            if (@($RequiredVerifierModels).Count -gt 0) {
                $expectedModels = @(@($RequiredVerifierModels) | Sort-Object -Unique)
                $actualModels = @($candidateAssignments | ForEach-Object {
                        [string](Get-ReviewerVerificationValue $_ "verifierModel" "")
                    } | Sort-Object -Unique)
                if ($expectedModels.Count -ne 2 -or $actualModels.Count -ne 2 -or
                    ($expectedModels -join "`n") -cne ($actualModels -join "`n") -or
                    $candidateAssignments.Count -ne 2) {
                    [void]$withheld.Add([pscustomobject][ordered]@{
                            candidateId = $candidateId; clusterId = $clusterId
                            reason = "incompleteVerifier"
                            detail = "The candidate did not receive exactly one fresh cross-check from each required generalist model."
                        })
                    continue
                }
            }
            if ($candidateAssignments.Count -eq 0) {
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; clusterId = $clusterId
                        reason = "selfVerification"; detail = "No independent verifier assignment was available."
                    })
                continue
            }
            $candidateVerdicts = [System.Collections.Generic.List[object]]::new()
            foreach ($assignment in $candidateAssignments) {
                $assignmentId = [string](Get-ReviewerVerificationValue $assignment "assignmentId" "")
                if (-not $runMap.ContainsKey($assignmentId)) {
                    $candidateFailed = $true
                    [void]$withheld.Add([pscustomobject][ordered]@{
                            candidateId = $candidateId; clusterId = $clusterId
                            reason = "incompleteVerifier"; detail = "The assigned verifier did not produce a run record."
                        })
                    continue
                }
                $run = $runMap[$assignmentId]
                $status = [string](Get-ReviewerVerificationValue $run "status" "")
                if ($status -cne "complete") {
                    $candidateFailed = $true
                    $reason = [string](Get-ReviewerVerificationValue $run "reason" "incompleteVerifier")
                    if ($script:ReviewerVerificationWithheldReasons -cnotcontains $reason) { $reason = "incompleteVerifier" }
                    [void]$withheld.Add([pscustomobject][ordered]@{
                            candidateId = $candidateId; clusterId = $clusterId
                            reason = $reason; detail = [string](Get-ReviewerVerificationValue $run "detail" "")
                        })
                    continue
                }
                $marker = Get-ReviewerVerificationValue $run "marker"
                $matching = @((Get-ReviewerVerificationValue $marker "verdicts" @()) | Where-Object {
                        [string](Get-ReviewerVerificationValue $_ "candidateId" "") -ceq $candidateId
                    })
                if ($matching.Count -ne 1 -or
                    [string](Get-ReviewerVerificationValue $matching[0] "candidateHash" "") -cne $candidateHash) {
                    $candidateFailed = $true
                    [void]$withheld.Add([pscustomobject][ordered]@{
                            candidateId = $candidateId; clusterId = $clusterId
                            reason = "invalidMarker"; detail = "The verdict was missing, duplicated, or bound to another candidate."
                        })
                    continue
                }
                $verdict = $matching[0]
                if (Test-ReviewerVerificationForbiddenText -Text (
                        [string](Get-ReviewerVerificationValue $verdict "rationale" ""))) {
                    $candidateFailed = $true
                    [void]$withheld.Add([pscustomobject][ordered]@{
                            candidateId = $candidateId; clusterId = $clusterId
                            reason = "toolViolation"; detail = "Verifier rationale contained a forbidden write or vote field."
                        })
                    continue
                }
                if ([string](Get-ReviewerVerificationValue $verdict "evidenceSha256" "") -notmatch '^[0-9a-f]{64}$') {
                    $candidateFailed = $true
                    [void]$withheld.Add([pscustomobject][ordered]@{
                            candidateId = $candidateId; clusterId = $clusterId
                            reason = "missingEvidence"; detail = "The verifier did not bind its rationale to evidence."
                        })
                    continue
                }
                $evidenceKind = [string](Get-ReviewerVerificationValue $verdict "evidenceKind" "")
                $evidenceSha = [string](Get-ReviewerVerificationValue $verdict "evidenceSha256" "")
                $verdictFactIds = [string](Get-ReviewerVerificationValue $verdict "factIds" "")
                $verdictDuplicateTarget = [string](Get-ReviewerVerificationValue $verdict "duplicateTargetId" "")
                $evidenceOptions = @(Get-ReviewerVerificationEvidenceOptions -Candidate $candidate `
                    -FactPlan $FactPlan -ThreadFacts $ThreadFacts -EvidenceHunks $EvidenceHunks `
                    -SiblingCandidates @(Get-ReviewerVerificationValue $cluster "members" @()) `
                    -ExistingThreadJaccard $ExistingThreadJaccard)
                $matchingEvidence = @($evidenceOptions | Where-Object {
                        [string](Get-ReviewerVerificationValue $_ "purpose" "") -ceq "candidate" -and
                        [string](Get-ReviewerVerificationValue $_ "kind" "") -ceq $evidenceKind -and
                        [string]::Equals(
                            [string](Get-ReviewerVerificationValue $_ "sha256" ""),
                            $evidenceSha,
                            [StringComparison]::OrdinalIgnoreCase) -and
                        [string](Get-ReviewerVerificationValue $_ "factIds" "") -ceq $verdictFactIds -and
                        [string](Get-ReviewerVerificationValue $_ "duplicateTargetId" "") -ceq $verdictDuplicateTarget
                    })
                if ($matchingEvidence.Count -ne 1) {
                    $candidateFailed = $true
                    [void]$withheld.Add([pscustomobject][ordered]@{
                            candidateId = $candidateId; clusterId = $clusterId
                            reason = "missingEvidence"; detail = "Verifier evidence hash does not bind to wrapper-supplied evidence."
                        })
                    continue
                }
                [void]$candidateVerdicts.Add($verdict)
            }
            if ($candidateVerdicts.Count -ne $candidateAssignments.Count) { continue }
            $shapes = @($candidateVerdicts | ForEach-Object {
                    [string](Get-ReviewerVerificationValue $_ "outcome" "") + "|" +
                    [string](Get-ReviewerVerificationValue $_ "correctedSeverity" "none") + "|" +
                    [string](Get-ReviewerVerificationValue $_ "duplicateTargetId" "") + "|" +
                    [string](Get-ReviewerVerificationValue $_ "changedCodeFixOutcome" "") + "|" +
                    [string](Get-ReviewerVerificationValue $_ "changedCodeFixEvidenceSha256" "") + "|" +
                    [string](Get-ReviewerVerificationValue $_ "changedCodeFixFactIds" "") + "|" +
                    [string](Get-ReviewerVerificationValue $_ "existingDebtFollowUpOutcome" "") + "|" +
                    [string](Get-ReviewerVerificationValue $_ "existingDebtEvidenceSha256" "") + "|" +
                    [string](Get-ReviewerVerificationValue $_ "existingDebtEvidenceFactId" "")
                } | Select-Object -Unique)
            if ($shapes.Count -ne 1) {
                $candidateFailed = $true
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; clusterId = $clusterId
                        reason = "verifierDisagreement"; detail = "Independent verifier outcomes disagree; no majority was computed."
                    })
                continue
            }
            $verdict = $candidateVerdicts[0]
            $outcome = [string](Get-ReviewerVerificationValue $verdict "outcome" "")
            $correctedSeverity = [string](Get-ReviewerVerificationValue $verdict "correctedSeverity" "none")
            $duplicateTargetId = [string](Get-ReviewerVerificationValue $verdict "duplicateTargetId" "")
            if ($outcome -cne "duplicate" -and $duplicateTargetId) {
                $candidateFailed = $true
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; clusterId = $clusterId
                        reason = "invalidMarker"; detail = "Only a duplicate outcome may carry a duplicate target."
                    })
                continue
            }
            if ([string](Get-ReviewerVerificationValue $verdict "evidenceKind" "") -ceq "existingThread" -and
                $outcome -cne "duplicate") {
                $candidateFailed = $true
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; clusterId = $clusterId
                        reason = "invalidMarker"; detail = "Existing-thread evidence is valid only for duplicate outcomes."
                    })
                continue
            }
            if ($outcome -ceq "wrongSeverity") {
                $severityOrder = @("critical", "important", "suggestion")
                $oldRank = [array]::IndexOf([object[]]$severityOrder, [string]$candidate.severity)
                $newRank = [array]::IndexOf([object[]]$severityOrder, $correctedSeverity)
                if ($newRank -lt 0 -or $oldRank -lt 0 -or $newRank -le $oldRank) {
                    $candidateFailed = $true
                    [void]$withheld.Add([pscustomobject][ordered]@{
                            candidateId = $candidateId; clusterId = $clusterId
                            reason = "severityEscalation"; detail = "Severity correction was absent or did not lower severity."
                        })
                    continue
                }
            }
            elseif ($correctedSeverity -cne "none") {
                $candidateFailed = $true
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; clusterId = $clusterId
                        reason = "invalidMarker"; detail = "A non-severity verdict carried corrected severity."
                    })
                continue
            }
            if ($outcome -in @("unsupported", "needsHuman")) {
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; clusterId = $clusterId
                        reason = $outcome; detail = [string](Get-ReviewerVerificationValue $verdict "rationale" "")
                    })
                continue
            }
            if ($outcome -ceq "duplicate") {
                $target = [string](Get-ReviewerVerificationValue $verdict "duplicateTargetId" "")
                if (-not $target) {
                    $candidateFailed = $true
                    [void]$withheld.Add([pscustomobject][ordered]@{
                            candidateId = $candidateId; clusterId = $clusterId
                            reason = "invalidMarker"; detail = "Duplicate outcome omitted its target."
                        })
                    continue
                }
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; clusterId = $clusterId
                        reason = "duplicateCandidate"; detail = $target
                    })
                continue
            }
            $changedFix = Get-ReviewerVerificationValue $candidate "changedCodeFix" $null
            $debtFollowUp = Get-ReviewerVerificationValue $candidate "existingDebtFollowUp" $null
            $changedFixOutcome = [string](Get-ReviewerVerificationValue $verdict "changedCodeFixOutcome" "")
            $debtOutcome = [string](Get-ReviewerVerificationValue $verdict "existingDebtFollowUpOutcome" "")
            $retainDebtFollowUp = $false
            if ($originKind -ceq "convention") {
                $partEvidenceOptions = @(Get-ReviewerVerificationEvidenceOptions -Candidate $candidate `
                    -FactPlan $FactPlan -ThreadFacts $ThreadFacts -EvidenceHunks $EvidenceHunks `
                    -SiblingCandidates @(Get-ReviewerVerificationValue $cluster "members" @()) `
                    -ExistingThreadJaccard $ExistingThreadJaccard)
                $changedValueSource = [string](Get-ReviewerVerificationValue $changedFix "valueSource" "")
                $expectedChangedFactIds = [string](Get-ReviewerVerificationValue $changedFix "evidenceFactIds" "")
                $changedOptions = @($partEvidenceOptions | Where-Object {
                        [string](Get-ReviewerVerificationValue $_ "purpose" "") -ceq "changedCodeFix" -and
                        [string](Get-ReviewerVerificationValue $_ "factIds" "") -ceq $expectedChangedFactIds
                    })
                $expectedChangedSha = if ($changedOptions.Count -eq 1) {
                    [string](Get-ReviewerVerificationValue $changedOptions[0] "sha256" "")
                } else { "" }
                if ($changedFixOutcome -cne "supported" -or
                    $changedOptions.Count -ne 1 -or
                    [string](Get-ReviewerVerificationValue $verdict "changedCodeFixEvidenceSha256" "") -cne
                        $expectedChangedSha -or
                    [string](Get-ReviewerVerificationValue $verdict "changedCodeFixFactIds" "") -cne
                        $expectedChangedFactIds) {
                    [void]$withheld.Add([pscustomobject][ordered]@{
                            candidateId = $candidateId; clusterId = $clusterId
                            reason = "unsupported"
                            detail = "Required changed-code remediation was not independently supported."
                        })
                    continue
                }
                $debtStatus = [string](Get-ReviewerVerificationValue $debtFollowUp "status" "")
                if ($debtStatus -ceq "none") {
                    if ($debtOutcome -cne "notRequested" -or
                        [string](Get-ReviewerVerificationValue $verdict "existingDebtEvidenceSha256" "") -or
                        [string](Get-ReviewerVerificationValue $verdict "existingDebtEvidenceFactId" "")) {
                        [void]$withheld.Add([pscustomobject][ordered]@{
                                candidateId = $candidateId; clusterId = $clusterId
                                reason = "invalidMarker"
                                detail = "Verifier claimed existing-debt evidence when no follow-up was requested."
                            })
                        continue
                    }
                }
                elseif ($debtStatus -ceq "required") {
                    $debtEvidence = Get-ReviewerVerificationValue $candidate "existingDebtEvidence" $null
                    $expectedDebtFactId = [string](Get-ReviewerVerificationValue $debtFollowUp "evidenceFactId" "")
                    $debtOptions = @($partEvidenceOptions | Where-Object {
                            [string](Get-ReviewerVerificationValue $_ "purpose" "") -ceq "existingDebtFollowUp" -and
                            [string](Get-ReviewerVerificationValue $_ "evidenceFactId" "") -ceq $expectedDebtFactId
                        })
                    $expectedDebtSha = if ($debtOptions.Count -eq 1) {
                        [string](Get-ReviewerVerificationValue $debtOptions[0] "sha256" "")
                    } else { "" }
                    $retainDebtFollowUp = ($debtOutcome -ceq "supported" -and
                        $debtOptions.Count -eq 1 -and
                        [string](Get-ReviewerVerificationValue $verdict "existingDebtEvidenceSha256" "") -ceq
                            $expectedDebtSha -and
                        [string](Get-ReviewerVerificationValue $verdict "existingDebtEvidenceFactId" "") -ceq
                            $expectedDebtFactId)
                    if (-not $retainDebtFollowUp -and $debtOutcome -cnotin @("unsupported", "needsHuman")) {
                        $debtOutcome = "unsupported"
                    }
                }
                else {
                    [void]$withheld.Add([pscustomobject][ordered]@{
                            candidateId = $candidateId; clusterId = $clusterId
                            reason = "invalidMarker"; detail = "Existing-debt follow-up status is malformed."
                        })
                    continue
                }
            }
            elseif ($changedFixOutcome -cne "notApplicable" -or $debtOutcome -cne "notRequested") {
                [void]$withheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId; clusterId = $clusterId
                        reason = "invalidMarker"; detail = "Generalist verdict carried convention remediation claims."
                    })
                continue
            }
            if ($originKind -ceq "convention") {
                $sourceId = [string]$candidate.ruleSourceId
                $sourceValid = $sourceMap.ContainsKey($sourceId)
                if ($sourceValid) {
                    $source = $sourceMap[$sourceId]
                    $expectedHash = [string](Get-ReviewerVerificationValue $source "Sha256" (
                            Get-ReviewerVerificationValue $source "sha256" ""))
                    $sourceText = [string](Get-ReviewerVerificationValue $source "Text" (
                            Get-ReviewerVerificationValue $source "text" ""))
                    $sourceValid = [string]::Equals(
                        $expectedHash, [string]$candidate.ruleSourceSha256,
                        [StringComparison]::OrdinalIgnoreCase) -and
                        $sourceText.IndexOf([string]$candidate.ruleQuote, [StringComparison]::Ordinal) -ge 0
                }
                if (-not $sourceValid -or
                    [string]$candidate.ruleSourceSha256 -notmatch '^[0-9a-f]{64}$' -or
                    [string]::IsNullOrWhiteSpace([string]$candidate.ruleQuote)) {
                    $candidateFailed = $true
                    [void]$withheld.Add([pscustomobject][ordered]@{
                            candidateId = $candidateId; clusterId = $clusterId
                            reason = "sourceInvalid"; detail = "Convention source hash or quote is invalid."
                        })
                    continue
                }
                if ([string]$candidate.siblingStatus -ceq "checked") {
                    if ([string]::IsNullOrWhiteSpace([string]$candidate.siblingEvidence)) {
                        $candidateFailed = $true
                        [void]$withheld.Add([pscustomobject][ordered]@{
                                candidateId = $candidateId; clusterId = $clusterId
                                reason = "siblingInvalid"; detail = "Checked sibling evidence is empty."
                            })
                        continue
                    }
                }
                elseif ([string]$candidate.siblingStatus -cne "notRequired" -or
                    [string]::IsNullOrWhiteSpace([string]$candidate.siblingNotRequiredReason)) {
                    $candidateFailed = $true
                    [void]$withheld.Add([pscustomobject][ordered]@{
                            candidateId = $candidateId; clusterId = $clusterId
                            reason = "siblingInvalid"; detail = "Sibling evidence requirement is unsatisfied."
                        })
                    continue
                }
                foreach ($factId in @(([string]$candidate.factIds) -split ',' | Where-Object { $_ })) {
                    if (-not $factMap.ContainsKey($factId) -or
                        [string](Get-ReviewerVerificationValue $factMap[$factId] "state" "") -notin @("true", "false")) {
                        $candidateFailed = $true
                        [void]$withheld.Add([pscustomobject][ordered]@{
                                candidateId = $candidateId; clusterId = $clusterId
                                reason = "factInvalid"; detail = "A cited deterministic fact is missing or non-deterministic."
                            })
                        break
                    }
                }
                if ($candidateFailed) { continue }
            }
            [void]$clusterCandidates.Add([pscustomobject][ordered]@{
                    candidate = $candidate
                    verifierOutcome = $outcome
                    correctedSeverity = $correctedSeverity
                    rationale = [string](Get-ReviewerVerificationValue $verdict "rationale" "")
                    confidence = [string](Get-ReviewerVerificationValue $verdict "confidence" "")
                    retainDebtFollowUp = $retainDebtFollowUp
                })
            [void]$decisions.Add([pscustomobject][ordered]@{
                    candidateId = $candidateId; clusterId = $clusterId; outcome = $outcome
                    correctedSeverity = $correctedSeverity
                    changedCodeFixOutcome = $changedFixOutcome
                    existingDebtFollowUpOutcome = $debtOutcome
                    existingDebtFollowUpRetained = $retainDebtFollowUp
                    verifierModels = @($candidateAssignments | ForEach-Object {
                            [string](Get-ReviewerVerificationValue $_ "verifierModel" "")
                        })
                })
        }
        if ($clusterCandidates.Count -eq 0) { continue }
        $representatives = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $clusterCandidates) { [void]$representatives.Add($entry) }
        $representatives.Sort([System.Comparison[object]] {
                param($left, $right)
                $leftKind = [string]$left.candidate.originKind
                $rightKind = [string]$right.candidate.originKind
                if ($leftKind -cne $rightKind) {
                    if ($leftKind -ceq "generalist") { return -1 }
                    if ($rightKind -ceq "generalist") { return 1 }
                }
                return [StringComparer]::Ordinal.Compare(
                    [string]$left.candidate.candidateHash,
                    [string]$right.candidate.candidateHash)
            })
        $winner = $representatives[0]
        $severityOrder = @("critical", "important", "suggestion")
        $finalSeverityRank = -1
        foreach ($entry in $representatives) {
            $entrySeverity = if ([string]$entry.correctedSeverity -cne "none") {
                [string]$entry.correctedSeverity
            }
            else {
                [string]$entry.candidate.severity
            }
            $entryRank = [array]::IndexOf([object[]]$severityOrder, $entrySeverity)
            if ($entryRank -gt $finalSeverityRank) { $finalSeverityRank = $entryRank }
        }
        $finalSeverity = [string]$severityOrder[$finalSeverityRank]
        $effectiveDebt = if ([bool]$winner.retainDebtFollowUp) {
            $winner.candidate.existingDebtFollowUp
        }
        else {
            [pscustomobject][ordered]@{
                status = "none"; evidenceFactId = ""; selectorKey = ""; scopeKind = ""; scopePath = ""
                comparableCount = 0; compliantCount = 0; action = ""
            }
        }
        $structuredComment = [string]$winner.candidate.comment
        if ([string]$winner.candidate.originKind -ceq "convention") {
            $fix = $winner.candidate.changedCodeFix
            $targetText = [string](Get-ReviewerVerificationValue $fix "targets" "")
            $keyText = [string](Get-ReviewerVerificationValue $fix "conventionKey" "")
            $sourceText = $(if ([string](Get-ReviewerVerificationValue $fix "valueSource" "") -ceq
                    "deterministicFact") { "the sealed deterministic evidence" } else { "the authoritative rule" })
            $structuredComment = "$([string](Get-ReviewerVerificationValue $fix 'action' 'modify')) '$keyText' on changed construct(s) $targetText using the correct value from $sourceText."
            if ([string](Get-ReviewerVerificationValue $effectiveDebt "status" "") -ceq "required") {
                $structuredComment += " Record and link a tracked follow-up for the bounded existing debt in $([string](Get-ReviewerVerificationValue $effectiveDebt 'scopePath' '')) ($([int](Get-ReviewerVerificationValue $effectiveDebt 'compliantCount' 0)) of $([int](Get-ReviewerVerificationValue $effectiveDebt 'comparableCount' 0)) comparable declarations comply); do not clean unrelated debt in this pull request."
            }
        }
        [void]$eligible.Add([pscustomobject][ordered]@{
                clusterId = $clusterId
                candidateId = [string]$winner.candidate.candidateId
                candidateHash = [string]$winner.candidate.candidateHash
                originKind = [string]$winner.candidate.originKind
                originCandidateId = [string]$winner.candidate.originCandidateId
                origins = @((Get-ReviewerVerificationValue $cluster "origins" @()))
                severity = $finalSeverity
                filePath = [string]$winner.candidate.filePath
                line = [int]$winner.candidate.line
                comment = $structuredComment
                evidence = [string]$winner.candidate.evidence
                confidence = [string]$winner.confidence
                changedCodeFix = $winner.candidate.changedCodeFix
                existingDebtFollowUp = $effectiveDebt
            })
        for ($i = 1; $i -lt $representatives.Count; $i++) {
            [void]$withheld.Add([pscustomobject][ordered]@{
                    candidateId = [string]$representatives[$i].candidate.candidateId; clusterId = $clusterId
                    reason = "duplicateCandidate"; detail = [string]$winner.candidate.candidateId
                })
        }
    }
    $eligibleIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $eligible) { [void]$eligibleIds.Add([string]$item.candidateId) }
    $withheldIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $finalWithheld = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $withheld) {
        $candidateId = [string](Get-ReviewerVerificationValue $item "candidateId" "")
        if (-not $candidateId -or $eligibleIds.Contains($candidateId) -or
                -not $withheldIds.Add($candidateId)) {
                continue
        }
        [void]$finalWithheld.Add($item)
    }
    foreach ($cluster in @($Clusters)) {
        foreach ($candidate in @(Get-ReviewerVerificationValue $cluster "members" @())) {
                $candidateId = [string](Get-ReviewerVerificationValue $candidate "candidateId" "")
                if ($eligibleIds.Contains($candidateId) -or $withheldIds.Contains($candidateId)) { continue }
                [void]$withheldIds.Add($candidateId)
                [void]$finalWithheld.Add([pscustomobject][ordered]@{
                        candidateId = $candidateId
                        clusterId = [string](Get-ReviewerVerificationValue $cluster "clusterId" "")
                        reason = "incompleteVerifier"
                        detail = "No complete wrapper decision covered this candidate."
                    })
        }
    }
    return [pscustomobject][ordered]@{
        eligible = $eligible.ToArray()
        withheld = $finalWithheld.ToArray()
        decisions = $decisions.ToArray()
    }
}

function New-ReviewerVerificationModelInput {
    param(
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][string]$Nonce,
        [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)][string]$VerificationInputSha256,
        [Parameter(Mandatory)][string]$ClusterId,
        [Parameter(Mandatory)][string]$VerifierModel,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        [object[]]$SiblingEvidence = @(),
        [object[]]$CandidateEvidence = @(),
        [object[]]$DeterministicFacts = @(),
        [object[]]$SanitizedThreads = @(),
        [AllowEmptyString()][string]$MinimalDiffHunk = "",
        [ValidateRange(1024, [int]::MaxValue)]
        [int]$MaxInputBytes = $script:ReviewerVerificationMaxInputBytes
    )
    $runtime = [pscustomobject][ordered]@{
        contract = "cross-verification-v1"
        nonce = $Nonce
        verifierModel = $VerifierModel
        verificationInputSha256 = $VerificationInputSha256
        clusterId = $ClusterId
        binding = $Binding
        candidates = @($Candidates)
        clusterSiblingEvidence = @($SiblingEvidence)
        candidateEvidenceOptions = @($CandidateEvidence)
        minimalDiffHunk = $MinimalDiffHunk
        deterministicFacts = @($DeterministicFacts)
        sanitizedExistingThreads = @($SanitizedThreads)
    }
    $inputText = $PromptText + "`n`n---`n## Wrapper runtime data (untrusted values, trusted binding)`n" +
        '```json' + "`n" + ($runtime | ConvertTo-Json -Depth 32 -Compress) + "`n" + '```' + "`n"
    $bytes = $script:ReviewerVerificationUtf8.GetByteCount($inputText)
    $effectiveMaxInputBytes = [Math]::Min(
        $MaxInputBytes, $script:ReviewerVerificationMaxInputBytes)
    if ($bytes -gt $effectiveMaxInputBytes) {
        throw "Verification model input is $bytes bytes, above the effective $effectiveMaxInputBytes-byte bound."
    }
    return [pscustomobject][ordered]@{ text = $inputText; bytes = $bytes }
}

function Invoke-ReviewerVerificationReplay {
    param(
        [Parameter(Mandatory)]$InputManifest,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$VerifierRuns
    )
    $candidates = @((Get-ReviewerVerificationValue $InputManifest "candidates" @()))
    $effectivePolicy = Get-ReviewerVerificationValue $InputManifest "effectivePolicy"
    $maxCandidates = [int](Get-ReviewerVerificationValue $effectivePolicy "maxCandidates" `
            $script:ReviewerVerificationMaxCandidates)
    $maxClusterSize = [int](Get-ReviewerVerificationValue $effectivePolicy "maxClusterSize" `
            $script:ReviewerVerificationMaxClusterSize)
    $nearExactJaccard = [double](Get-ReviewerVerificationValue $effectivePolicy `
            "nearExactJaccard" $script:ReviewerVerificationNearExactJaccard)
    $semanticJaccard = [double](Get-ReviewerVerificationValue $effectivePolicy `
            "semanticJaccard" $script:ReviewerVerificationSemanticJaccard)
    $existingThreadJaccard = [double](Get-ReviewerVerificationValue `
            $effectivePolicy "existingThreadJaccard" $script:ReviewerVerificationExistingThreadJaccard)
    $clusters = @(Get-ReviewerVerificationClusters -Candidates $candidates `
        -MaxCandidates $maxCandidates -MaxClusterSize $maxClusterSize `
        -NearExactJaccard $nearExactJaccard -SemanticJaccard $semanticJaccard)
    $assignments = @((Get-ReviewerVerificationValue $InputManifest "assignments" @()))
    $crossCheckModels = @((Get-ReviewerVerificationValue $InputManifest "crossCheckModels" @()))
    $threads = @((Get-ReviewerVerificationValue $InputManifest "threadFacts" @()))
    $changedPaths = @((Get-ReviewerVerificationValue $InputManifest "changedPaths" @()))
    $factPlan = Get-ReviewerVerificationValue $InputManifest "factPlan"
    $resolvedSources = @((Get-ReviewerVerificationValue $InputManifest "resolvedSources" @()))
    $evidenceHunks = @((Get-ReviewerVerificationValue $InputManifest "evidenceHunks" @()))
    $preVerificationWithheld = @((Get-ReviewerVerificationValue `
            $InputManifest "preVerificationWithheld" @()))
    $sealedTotalCandidateCount = Get-ReviewerVerificationValue `
        $InputManifest "totalCandidateCount" $null
    if ($null -ne $sealedTotalCandidateCount -and
        [int]$sealedTotalCandidateCount -ne ($candidates.Count + $preVerificationWithheld.Count)) {
        throw "Verification replay candidate coverage does not match sealed totalCandidateCount."
    }
    $specialistStatus = [string](Get-ReviewerVerificationValue $InputManifest "specialistStatus" "degraded")
    $resolved = Resolve-ReviewerVerificationDecisions -Clusters $clusters -Assignments $assignments `
        -VerifierRuns $VerifierRuns -ThreadFacts $threads -ChangedPaths $changedPaths `
        -FactPlan $factPlan -ResolvedSources $resolvedSources `
        -EvidenceHunks $evidenceHunks -PreVerificationWithheld $preVerificationWithheld `
        -ExistingThreadJaccard $existingThreadJaccard `
        -SpecialistDegraded ($specialistStatus -cne "complete") `
        -RequiredVerifierModels $crossCheckModels
    return [pscustomobject][ordered]@{
        clusters = $clusters
        assignments = $assignments
        eligible = @($resolved.eligible)
        withheld = @($resolved.withheld)
        decisions = @($resolved.decisions)
        replaySha256 = Get-ReviewerVerificationObjectSha256 -Value ([ordered]@{
                clusters = @($clusters | ForEach-Object {
                        [ordered]@{
                            clusterId = [string]$_.clusterId
                            memberHashes = @($_.memberHashes)
                            origins = @($_.origins)
                        }
                    })
                assignments = $assignments
                eligible = @($resolved.eligible)
                withheld = @($resolved.withheld)
                decisions = @($resolved.decisions)
            })
    }
}
