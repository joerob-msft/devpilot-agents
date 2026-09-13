Set-StrictMode -Version Latest

$script:OwnerObserverSchemaPath = Join-Path $PSScriptRoot 'schemas/owner-observation.v1.json'
$script:OwnerObserverUnknown = 'unknown'
$script:OwnerObserverMaximumDiagnosticLength = 512
$script:OwnerObserverMaximumArtifacts = 64
$script:OwnerObserverMaximumFindings = 512
$script:OwnerObserverMaximumAuditFiles = 512

function Get-OwnerObserverValue {
    param($Container, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Container) { return $Default }
    if ($Container -is [Collections.IDictionary]) {
        if ($Container.Contains($Name)) { return $Container[$Name] }
        return $Default
    }
    $property = $Container.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function ConvertTo-OwnerObserverJsonString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $builder = [Text.StringBuilder]::new($Value.Length + 2)
    [void]$builder.Append('"')
    foreach ($character in $Value.ToCharArray()) {
        $code = [int]$character
        switch ($character) {
            '"' { [void]$builder.Append('\"'); continue }
            '\' { [void]$builder.Append('\\'); continue }
            "`b" { [void]$builder.Append('\b'); continue }
            "`f" { [void]$builder.Append('\f'); continue }
            "`n" { [void]$builder.Append('\n'); continue }
            "`r" { [void]$builder.Append('\r'); continue }
            "`t" { [void]$builder.Append('\t'); continue }
            default {
                if ($code -lt 32 -or $code -eq 127) {
                    [void]$builder.AppendFormat('\u{0:x4}', $code)
                }
                else {
                    [void]$builder.Append($character)
                }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-OwnerObserverOrdinalJsonString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $builder = [Text.StringBuilder]::new($Value.Length + 2)
    [void]$builder.Append('"')
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        $code = [int]$character
        if ([char]::IsHighSurrogate($character)) {
            if ($index + 1 -ge $Value.Length -or -not [char]::IsLowSurrogate($Value[$index + 1])) {
                throw 'Owner observer canonical JSON does not accept unpaired surrogate characters.'
            }
            [void]$builder.Append($character)
            $index++
            [void]$builder.Append($Value[$index])
            continue
        }
        if ([char]::IsLowSurrogate($character)) {
            throw 'Owner observer canonical JSON does not accept unpaired surrogate characters.'
        }
        switch ($code) {
            34 { [void]$builder.Append('\"'); continue }
            92 { [void]$builder.Append('\\'); continue }
            8 { [void]$builder.Append('\b'); continue }
            12 { [void]$builder.Append('\f'); continue }
            10 { [void]$builder.Append('\n'); continue }
            13 { [void]$builder.Append('\r'); continue }
            9 { [void]$builder.Append('\t'); continue }
            default {
                if ($code -lt 32 -or $code -eq 127) {
                    [void]$builder.AppendFormat('\u{0:x4}', $code)
                }
                else {
                    [void]$builder.Append($character)
                }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Assert-OwnerObserverCanonicalTextSafe {
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 24) { throw 'Owner observer payload exceeded the maximum canonical depth.' }
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        $legacy = ConvertTo-OwnerObserverJsonString -Value $Value
        $ordinal = ConvertTo-OwnerObserverOrdinalJsonString -Value $Value
        if ($legacy -cne $ordinal) {
            throw 'Owner v1 signed record contains text whose canonical HMAC representation is ambiguous.'
        }
        return
    }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($name in @($Value.Keys)) {
            Assert-OwnerObserverCanonicalTextSafe -Value ([string]$name) -Depth ($Depth + 1)
            Assert-OwnerObserverCanonicalTextSafe -Value $Value[$name] -Depth ($Depth + 1)
        }
        return
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        foreach ($property in @($Value.PSObject.Properties)) {
            Assert-OwnerObserverCanonicalTextSafe -Value $property.Name -Depth ($Depth + 1)
            Assert-OwnerObserverCanonicalTextSafe -Value $property.Value -Depth ($Depth + 1)
        }
        return
    }
    if ($Value -is [Collections.IEnumerable]) {
        foreach ($item in $Value) {
            Assert-OwnerObserverCanonicalTextSafe -Value $item -Depth ($Depth + 1)
        }
    }
}

function Get-OwnerObserverSortedNames {
    param([string[]]$Names)
    $sorted = [string[]]@($Names)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return $sorted
}

function Get-OwnerObserverSortedFiles {
    param([IO.FileInfo[]]$Files)
    $sorted = [IO.FileInfo[]]@($Files)
    [Array]::Sort(
        $sorted,
        [Collections.Generic.Comparer[IO.FileInfo]]::Create(
            [Comparison[IO.FileInfo]]{
                param($left, $right)
                return [StringComparer]::Ordinal.Compare($left.Name, $right.Name)
            }))
    return $sorted
}

function Get-OwnerObserverSortedFindings {
    param([object[]]$Findings)
    $sorted = [object[]]@($Findings)
    [Array]::Sort(
        $sorted,
        [Collections.Generic.Comparer[object]]::Create(
            [Comparison[object]]{
                param($left, $right)
                $identity = [StringComparer]::Ordinal.Compare(
                    [string]$left.identity, [string]$right.identity)
                if ($identity -ne 0) { return $identity }
                return [StringComparer]::Ordinal.Compare(
                    [string]$left.disposition, [string]$right.disposition)
            }))
    return $sorted
}

function ConvertTo-OwnerObserverCanonicalJson {
    <#
        Matches the v1 queue's canonical JSON contract without importing or
        executing the frozen runtime.
    #>
    [CmdletBinding()]
    param($Value, [int]$Depth = 0)

    if ($Depth -gt 24) { throw 'Owner observer payload exceeded the maximum canonical depth.' }
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) { return ConvertTo-OwnerObserverJsonString -Value $Value }
    if ($Value -is [int] -or $Value -is [long]) {
        return [Convert]::ToString([long]$Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [double] -or $Value -is [decimal]) {
        throw 'Owner observer canonical JSON does not accept non-integral numbers.'
    }
    if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) {
        throw 'Owner observer canonical JSON does not accept date values.'
    }
    if ($Value -is [Collections.IDictionary]) {
        $names = Get-OwnerObserverSortedNames -Names @($Value.Keys | ForEach-Object { [string]$_ })
        $parts = foreach ($name in $names) {
            (ConvertTo-OwnerObserverJsonString -Value $name) + ':' +
            (ConvertTo-OwnerObserverCanonicalJson -Value $Value[$name] -Depth ($Depth + 1))
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $names = Get-OwnerObserverSortedNames -Names @($Value.PSObject.Properties.Name)
        $parts = foreach ($name in $names) {
            (ConvertTo-OwnerObserverJsonString -Value $name) + ':' +
            (ConvertTo-OwnerObserverCanonicalJson -Value $Value.PSObject.Properties[$name].Value -Depth ($Depth + 1))
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable]) {
        $parts = foreach ($item in $Value) {
            ConvertTo-OwnerObserverCanonicalJson -Value $item -Depth ($Depth + 1)
        }
        return '[' + (@($parts) -join ',') + ']'
    }
    throw "Owner observer canonical JSON encountered unsupported type '$($Value.GetType().FullName)'."
}

function Get-OwnerObserverHmac {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $hmac = [Security.Cryptography.HMACSHA256]::new($Key)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ([Convert]::ToHexString($hmac.ComputeHash($bytes))).ToLowerInvariant()
    }
    finally {
        $hmac.Dispose()
    }
}

function Get-OwnerObserverBytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant()
}

function Test-OwnerObserverHexEqual {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )
    if ($Left -cnotmatch '^[0-9a-f]{64}$' -or $Right -cnotmatch '^[0-9a-f]{64}$') { return $false }
    $leftBytes = [Convert]::FromHexString($Left)
    $rightBytes = [Convert]::FromHexString($Right)
    return [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($leftBytes, $rightBytes)
}

function ConvertTo-OwnerObserverDiagnostic {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $bounded = $Text.Replace("`r", ' ').Replace("`n", ' ')
    $bounded = [regex]::Replace($bounded, '[\x00-\x1f\x7f]', '?')
    $bounded = [regex]::Replace(
        $bounded,
        '(?i)\b(token|secret|password|api[-_]?key|ledger[-_]?key)\s*[:=]\s*[^;\s,]+',
        '$1=[redacted]')
    $bounded = [regex]::Replace($bounded, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[email]')
    $bounded = [regex]::Replace($bounded, '(?<![A-Za-z0-9])(?:[A-Za-z]:\\|/)[^\s''"]+', '[path]')
    $bounded = [regex]::Replace($bounded, '(?<![A-Za-z0-9+/=])[A-Za-z0-9+/]{43,}={0,2}(?![A-Za-z0-9+/=])', '[secret]')
    $bounded = $bounded.Trim()
    if ($bounded.Length -gt $script:OwnerObserverMaximumDiagnosticLength) {
        return $bounded.Substring(0, $script:OwnerObserverMaximumDiagnosticLength - 3) + '...'
    }
    return $bounded
}

function Test-OwnerObserverPathWithin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return $fullPath.Equals($fullRoot, $comparison) -or
        $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Assert-OwnerObserverNoLinks {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Boundary
    )
    $current = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($Boundary).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType) {
            throw "Owner observer path traverses a link or reparse point."
        }
        $trimmed = $current.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if ([string]::Equals(
                $trimmed,
                $root,
                $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) {
            return
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    throw 'Owner observer path does not reach its declared boundary.'
}

function Resolve-OwnerObserverRoot {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$Label must be a non-empty absolute path."
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "$Label does not exist."
    }
    Assert-OwnerObserverNoLinks -Path $full -Boundary ([IO.Path]::GetPathRoot($full))
    return $full
}

function Resolve-OwnerObserverContainedFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    $candidate = if ([IO.Path]::IsPathFullyQualified($Path)) { $Path } else { Join-Path $Root $Path }
    $full = [IO.Path]::GetFullPath($candidate)
    if (-not (Test-OwnerObserverPathWithin -Path $full -Root $Root)) {
        throw "$Label is outside its allowed root."
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "$Label does not exist." }
    Assert-OwnerObserverNoLinks -Path $full -Boundary $Root
    return $full
}

function Resolve-OwnerObserverFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$Label must be a non-empty absolute path."
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "$Label does not exist." }
    Assert-OwnerObserverNoLinks -Path $full -Boundary ([IO.Path]::GetPathRoot($full))
    return $full
}

function Read-OwnerObserverKey {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [AllowEmptyString()][string]$KeyPath
    )
    $path = if ($KeyPath) {
        Resolve-OwnerObserverContainedFile -Root $StateRoot -Path $KeyPath -Label 'Owner v1 HMAC key'
    }
    else {
        Resolve-OwnerObserverContainedFile -Root $StateRoot -Path 'keys/ledger.key' -Label 'Owner v1 HMAC key'
    }
    $raw = ([Text.UTF8Encoding]::new($false, $true)).GetString([IO.File]::ReadAllBytes($path)).Trim()
    try { $key = [Convert]::FromBase64String($raw) }
    catch { throw 'Owner v1 HMAC key is not canonical base64.' }
    if ($key.Length -lt 32 -or [Convert]::ToBase64String($key) -cne $raw) {
        throw 'Owner v1 HMAC key is invalid or non-canonical.'
    }
    return , $key
}

function Read-OwnerObserverSignedRecord {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 4MB) { throw 'Owner v1 signed record exceeds the 4 MiB observation limit.' }
    try {
        $text = ([Text.UTF8Encoding]::new($false, $true)).GetString($bytes)
        $envelope = $text | ConvertFrom-Json -Depth 64 -AsHashtable
    }
    catch {
        throw 'Owner v1 signed record is not valid UTF-8 JSON.'
    }
    if ([int](Get-OwnerObserverValue $envelope 'schemaVersion' 0) -ne 1 -or
        [string](Get-OwnerObserverValue $envelope 'kind' '') -cne 'reviewer-owner-preview-signed-record') {
        throw 'Owner v1 signed record has the wrong envelope kind or version.'
    }
    $envelopeNames = Get-OwnerObserverSortedNames -Names @(
        $envelope.Keys | ForEach-Object { [string]$_ })
    $expectedEnvelopeNames = @('hmac', 'kind', 'payload', 'schemaVersion')
    if ($envelopeNames.Count -ne $expectedEnvelopeNames.Count) {
        throw 'Owner v1 signed record envelope has unexpected fields.'
    }
    for ($index = 0; $index -lt $expectedEnvelopeNames.Count; $index++) {
        if ($envelopeNames[$index] -cne $expectedEnvelopeNames[$index]) {
            throw 'Owner v1 signed record envelope has unexpected fields.'
        }
    }
    $payload = Get-OwnerObserverValue $envelope 'payload'
    $actual = [string](Get-OwnerObserverValue $envelope 'hmac' '')
    Assert-OwnerObserverCanonicalTextSafe -Value $payload
    $canonical = ConvertTo-OwnerObserverCanonicalJson -Value $payload
    $expected = Get-OwnerObserverHmac -Text $canonical -Key $Key
    if (-not (Test-OwnerObserverHexEqual -Left $actual -Right $expected)) {
        throw 'Owner v1 signed record failed HMAC verification.'
    }
    return [pscustomobject]@{
        Payload = $payload
        Sha256 = Get-OwnerObserverBytesSha256 -Bytes $bytes
    }
}

function Add-OwnerObserverValidationError {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Errors,
        [AllowNull()][AllowEmptyString()][string]$Text
    )
    if ($Errors.Count -ge 32) { return }
    $diagnostic = ConvertTo-OwnerObserverDiagnostic -Text $Text
    if ($diagnostic) { [void]$Errors.Add($diagnostic) }
}

function Add-OwnerObserverArtifact {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Artifacts,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Errors,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][ValidateSet('verified', 'not-applicable', 'unknown')][string]$Signature
    )
    if ($Artifacts.Count -ge $script:OwnerObserverMaximumArtifacts) {
        $message = 'Source artifact digests exceeded the 64-entry observation limit; provenance is incomplete.'
        if (-not $Errors.Contains($message)) {
            if ($Errors.Count -ge 32) {
                $Errors.RemoveAt($Errors.Count - 1)
            }
            Add-OwnerObserverValidationError -Errors $Errors -Text $message
        }
        return
    }
    [void]$Artifacts.Add([ordered]@{
            kind = $Kind
            sha256 = $Sha256
            signature = $Signature
        })
}

function Get-OwnerObserverKnownNumber {
    param($Container, [Parameter(Mandatory)][string]$Name)
    $value = Get-OwnerObserverValue $Container $Name $null
    if ($null -eq $value) { return $script:OwnerObserverUnknown }
    if ($value -isnot [byte] -and $value -isnot [int16] -and $value -isnot [int] -and $value -isnot [long]) {
        return $script:OwnerObserverUnknown
    }
    if ([long]$value -lt 0) { return $script:OwnerObserverUnknown }
    return [long]$value
}

function Get-OwnerObserverKnownText {
    param($Container, [Parameter(Mandatory)][string]$Name)
    $value = Get-OwnerObserverValue $Container $Name $null
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value) -or
        ([string]$value).Length -gt 1024) {
        return $script:OwnerObserverUnknown
    }
    return [string]$value
}

function Get-OwnerObserverLifecycle {
    param($Record)
    $state = [string](Get-OwnerObserverValue $Record 'state' '')
    $status = switch -CaseSensitive ($state) {
        'pending' { 'pending' }
        'running' { 'pending' }
        'completed' { 'completed' }
        'incomplete' { 'incomplete' }
        'blocked' { 'blocked' }
        default { 'unknown' }
    }
    return [ordered]@{
        status = $status
        prepared = $(if ($Record) { $true } else { $script:OwnerObserverUnknown })
        completed = $(if ($status -eq 'unknown') { $script:OwnerObserverUnknown } else { $status -eq 'completed' })
        incomplete = $(if ($status -eq 'unknown') { $script:OwnerObserverUnknown } else { $status -in @('incomplete', 'blocked') })
        pending = $(if ($status -eq 'unknown') { $script:OwnerObserverUnknown } else { $status -eq 'pending' })
    }
}

function Find-OwnerObserverStatus {
    param(
        [Parameter(Mandatory)][string]$SubjectRoot,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )
    if ($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Owner v1 artifact status digest is invalid.'
    }
    $root = Resolve-OwnerObserverRoot -Path $SubjectRoot -Label 'Owner v1 subject root'
    $runs = Join-Path $root 'runs'
    if (-not (Test-Path -LiteralPath $runs -PathType Container)) {
        throw 'Owner v1 subject root has no runs directory.'
    }
    Assert-OwnerObserverNoLinks -Path $runs -Boundary $root
    $statusMatches = [Collections.Generic.List[object]]::new()
    $children = @(Get-ChildItem -LiteralPath $runs -Directory -Force -ErrorAction Stop)
    if ($children.Count -gt 256) { throw 'Owner v1 runs directory exceeds the 256-entry observation limit.' }
    foreach ($child in $children) {
        if ($child.Name -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Owner v1 runs directory contains an invalid direct child.'
        }
        Assert-OwnerObserverNoLinks -Path $child.FullName -Boundary $runs
        $statusPath = Join-Path $child.FullName 'owner-preview-status.json'
        if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) { continue }
        Assert-OwnerObserverNoLinks -Path $statusPath -Boundary $runs
        $bytes = [IO.File]::ReadAllBytes($statusPath)
        if ($bytes.Length -gt 4MB) { throw 'Owner v1 status exceeds the 4 MiB observation limit.' }
        $digest = Get-OwnerObserverBytesSha256 -Bytes $bytes
        if ($digest -ceq $ExpectedSha256) {
            [void]$statusMatches.Add([pscustomobject]@{
                    Path = $statusPath
                    Bytes = $bytes
                    Sha256 = $digest
                })
        }
    }
    if ($statusMatches.Count -ne 1) {
        throw "Owner v1 status digest resolved to $($statusMatches.Count) direct run files; exactly one is required."
    }
    return $statusMatches[0]
}

function Read-OwnerObserverAudit {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$HeadKey,
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Artifacts,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Errors
    )
    $anchors = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $intentCount = 0
    $outcomeCount = 0
    $pendingIntent = $false
    $providerWrites = 0L
    $dedupe = [ordered]@{
        created = 0L
        updated = 0L
        noOp = 0L
        wouldCreate = 0L
        wouldUpdate = 0L
        unknown = 0L
    }
    $auditRoot = Join-Path $StateRoot 'approved-comments'
    if (-not (Test-Path -LiteralPath $auditRoot -PathType Container)) {
        return [pscustomobject]@{
            Anchors = $anchors
            OperatorIntervention = $false
            ProviderWrites = 0L
            Dedupe = $dedupe
        }
    }
    Assert-OwnerObserverNoLinks -Path $auditRoot -Boundary $StateRoot
    $outcomeNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($phase in @('outcomes', 'intents')) {
        $directory = Join-Path (Join-Path $auditRoot $phase) $HeadKey
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        Assert-OwnerObserverNoLinks -Path $directory -Boundary $StateRoot
        $files = @(Get-OwnerObserverSortedFiles -Files @(
                Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -Force -ErrorAction Stop))
        if ($files.Count -gt $script:OwnerObserverMaximumAuditFiles) {
            throw "Owner v1 $phase audit directory exceeds the observation limit."
        }
        foreach ($file in $files) {
            $signed = Read-OwnerObserverSignedRecord -Path $file.FullName -Key $Key
            Add-OwnerObserverArtifact -Artifacts $Artifacts -Errors $Errors -Kind "v1-approved-comment-$phase" `
                -Sha256 $signed.Sha256 -Signature verified
            $payload = $signed.Payload
            if ($phase -eq 'outcomes') {
                if ([string](Get-OwnerObserverValue $payload 'kind' '') -cne 'reviewer-approved-owner-comment-outcome' -or
                    [string](Get-OwnerObserverValue $payload 'headKey' '') -cne $HeadKey) {
                    throw 'Owner v1 approved-comment outcome has a foreign identity.'
                }
                $outcomeCount++
                [void]$outcomeNames.Add($file.Name)
                $writes = Get-OwnerObserverKnownNumber -Container $payload -Name 'providerWrites'
                if ($writes -eq $script:OwnerObserverUnknown) { $pendingIntent = $true }
                else { $providerWrites += [long]$writes }
                foreach ($result in @(Get-OwnerObserverValue $payload 'results' @())) {
                    $name = [string](Get-OwnerObserverValue $result 'outcome' '')
                    if ($dedupe.Contains($name)) { $dedupe[$name] = [long]$dedupe[$name] + 1 }
                    else { $dedupe.unknown = [long]$dedupe.unknown + 1 }
                }
            }
            else {
                if ([string](Get-OwnerObserverValue $payload 'kind' '') -cne 'reviewer-approved-owner-comment-intent' -or
                    [string](Get-OwnerObserverValue $payload 'headKey' '') -cne $HeadKey) {
                    throw 'Owner v1 approved-comment intent has a foreign identity.'
                }
                $intentCount++
                if (-not $outcomeNames.Contains($file.Name)) { $pendingIntent = $true }
                foreach ($selection in @(Get-OwnerObserverValue $payload 'selections' @())) {
                    $findingId = [string](Get-OwnerObserverValue $selection 'findingId' '')
                    if (-not $findingId) { continue }
                    $path = Get-OwnerObserverKnownText -Container $selection -Name 'path'
                    $line = Get-OwnerObserverKnownNumber -Container $selection -Name 'line'
                    $symbol = Get-OwnerObserverKnownText -Container $selection -Name 'symbol'
                    if ($path -eq $script:OwnerObserverUnknown -or
                        $line -is [string] -or [long]$line -lt 1) { continue }
                    $anchors[$findingId] = [ordered]@{
                        path = $path
                        line = $line
                        symbol = $symbol
                    }
                }
            }
        }
    }
    if ($pendingIntent) {
        $providerWrites = $script:OwnerObserverUnknown
        $dedupe.unknown = $script:OwnerObserverUnknown
    }
    return [pscustomobject]@{
        Anchors = $anchors
        OperatorIntervention = ($intentCount -gt 0 -or $outcomeCount -gt 0)
        ProviderWrites = $providerWrites
        Dedupe = $dedupe
    }
}

function New-OwnerObserverFinding {
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][ValidateSet('violation', 'unknown')][string]$Disposition,
        [Parameter(Mandatory)][Collections.IDictionary]$Anchors
    )
    $ruleRef = Get-OwnerObserverKnownText -Container $Entry -Name 'ruleRef'
    $constructRef = Get-OwnerObserverKnownText -Container $Entry -Name 'constructRef'
    $identity = if ($ruleRef -ne $script:OwnerObserverUnknown -and $constructRef -ne $script:OwnerObserverUnknown) {
        "$Capability`:$ruleRef`:$constructRef"
    }
    else {
        $script:OwnerObserverUnknown
    }
    if ($identity.Length -gt 1024) { $identity = $script:OwnerObserverUnknown }
    return [ordered]@{
        identity = $identity
        disposition = $Disposition
        ruleRef = $ruleRef
        constructRef = $constructRef
        anchor = $(if ($anchors.ContainsKey($identity)) { $anchors[$identity] } else { $script:OwnerObserverUnknown })
    }
}

function Read-OwnerV1Observation {
    <#
    .SYNOPSIS
        Reads deployed Owner v1 evidence without modifying it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [ValidatePattern('^$|^[0-9a-f]{64}$')][string]$HeadKey = '',
        [AllowEmptyString()][string]$KeyPath = '',
        [AllowEmptyString()][string]$SubjectRootOverride = ''
    )

    $root = Resolve-OwnerObserverRoot -Path $StateRoot -Label 'Owner v1 state root'
    $key = Read-OwnerObserverKey -StateRoot $root -KeyPath $KeyPath
    $artifacts = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()

    $indexPath = Resolve-OwnerObserverContainedFile -Root $root -Path 'index/current.json' `
        -Label 'Owner v1 current index'
    $signedIndex = Read-OwnerObserverSignedRecord -Path $indexPath -Key $key
    Add-OwnerObserverArtifact -Artifacts $artifacts -Errors $errors -Kind 'v1-queue-index' `
        -Sha256 $signedIndex.Sha256 -Signature verified
    $index = $signedIndex.Payload
    if ([int](Get-OwnerObserverValue $index 'schemaVersion' 0) -ne 1 -or
        [string](Get-OwnerObserverValue $index 'kind' '') -cne 'reviewer-owner-preview-queue-index') {
        throw 'Owner v1 queue index has the wrong payload kind or version.'
    }
    $records = @(Get-OwnerObserverValue $index 'records' @())
    if ($records.Count -gt 1024) { throw 'Owner v1 queue index exceeds the 1024-record observation limit.' }
    if ($HeadKey) {
        $selected = @($records | Where-Object {
                [string](Get-OwnerObserverValue $_ 'headKey' '') -ceq $HeadKey
            })
    }
    else {
        $selected = @($records)
    }
    if ($selected.Count -ne 1) {
        throw "Owner v1 observation selected $($selected.Count) records; exactly one is required."
    }
    $record = $selected[0]
    $queueHeadKey = Get-OwnerObserverKnownText -Container $record -Name 'headKey'
    $capability = Get-OwnerObserverKnownText -Container $record -Name 'capability'
    $status = $null
    $statusHeadKey = $script:OwnerObserverUnknown

    $artifactPathValue = [string](Get-OwnerObserverValue $record 'artifact' '')
    if ($artifactPathValue) {
        try {
            $artifactPath = Resolve-OwnerObserverContainedFile -Root $root -Path $artifactPathValue `
                -Label 'Owner v1 queue artifact'
            $signedArtifact = Read-OwnerObserverSignedRecord -Path $artifactPath -Key $key
            Add-OwnerObserverArtifact -Artifacts $artifacts -Errors $errors -Kind 'v1-queue-artifact' `
                -Sha256 $signedArtifact.Sha256 -Signature verified
            $artifact = $signedArtifact.Payload
            if ([int](Get-OwnerObserverValue $artifact 'schemaVersion' 0) -ne 1 -or
                [string](Get-OwnerObserverValue $artifact 'kind' '') -cne 'reviewer-owner-preview-queue-artifact' -or
                [string](Get-OwnerObserverValue $artifact 'headKey' '') -cne $queueHeadKey) {
                throw 'Owner v1 queue artifact has a foreign identity.'
            }
            $subjectRoot = if ($SubjectRootOverride) {
                $SubjectRootOverride
            }
            else {
                [string](Get-OwnerObserverValue $artifact 'subjectRoot' '')
            }
            $resolvedStatus = Find-OwnerObserverStatus -SubjectRoot $subjectRoot `
                -ExpectedSha256 ([string](Get-OwnerObserverValue $artifact 'statusSha256' ''))
            Add-OwnerObserverArtifact -Artifacts $artifacts -Errors $errors -Kind 'v1-preview-status' `
                -Sha256 $resolvedStatus.Sha256 -Signature not-applicable
            try {
                $statusText = ([Text.UTF8Encoding]::new($false, $true)).GetString($resolvedStatus.Bytes)
                $candidateStatus = $statusText | ConvertFrom-Json -Depth 64 -AsHashtable
            }
            catch {
                throw 'Owner v1 preview status is not valid UTF-8 JSON.'
            }
            if ([int](Get-OwnerObserverValue $candidateStatus 'schemaVersion' 0) -ne 1 -or
                [string](Get-OwnerObserverValue $candidateStatus 'kind' '') -cne 'reviewer-owner-preview-status') {
                throw 'Owner v1 preview status has the wrong payload kind or version.'
            }
            $status = $candidateStatus
            $statusHeadKey = Get-OwnerObserverKnownText -Container $status -Name 'headKey'
        }
        catch {
            Add-OwnerObserverValidationError -Errors $errors -Text $_.Exception.Message
        }
    }
    else {
        Add-OwnerObserverValidationError -Errors $errors -Text 'Owner v1 queue record has no signed artifact reference.'
    }

    $audit = if ($statusHeadKey -ne $script:OwnerObserverUnknown) {
        Read-OwnerObserverAudit -StateRoot $root -HeadKey $statusHeadKey -Key $key `
            -Artifacts $artifacts -Errors $errors
    }
    else {
        [pscustomobject]@{
            Anchors = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
            OperatorIntervention = $script:OwnerObserverUnknown
            ProviderWrites = $script:OwnerObserverUnknown
            Dedupe = [ordered]@{
                created = $script:OwnerObserverUnknown
                updated = $script:OwnerObserverUnknown
                noOp = $script:OwnerObserverUnknown
                wouldCreate = $script:OwnerObserverUnknown
                wouldUpdate = $script:OwnerObserverUnknown
                unknown = $script:OwnerObserverUnknown
            }
        }
    }

    $subject = Get-OwnerObserverValue $record 'subject'
    $rule = Get-OwnerObserverValue $record 'rule'
    $terminal = Get-OwnerObserverValue $record 'terminal'
    $counts = Get-OwnerObserverValue $record 'counts'
    if ($status) {
        $subject = Get-OwnerObserverValue $status 'subject' $subject
        $rule = Get-OwnerObserverValue $status 'rule' $rule
        $terminal = Get-OwnerObserverValue $status 'terminal' $terminal
        $counts = Get-OwnerObserverValue $status 'counts' $counts
    }
    $notInReach = Get-OwnerObserverKnownNumber -Container $counts -Name 'notInReach'
    $notRouted = Get-OwnerObserverKnownNumber -Container $counts -Name 'notRouted'
    $uncovered = if ($notInReach -eq $script:OwnerObserverUnknown -or $notRouted -eq $script:OwnerObserverUnknown) {
        $script:OwnerObserverUnknown
    }
    else {
        [long]$notInReach + [long]$notRouted
    }

    $findings = [Collections.Generic.List[object]]::new()
    $observerFindingsTruncated = $false
    if ($status) {
        $violationEntries = @(Get-OwnerObserverValue $status 'violations' @())
        $unknownEntries = @(Get-OwnerObserverValue $status 'unknowns' @())
        foreach ($entry in $violationEntries) {
            if ($findings.Count -ge $script:OwnerObserverMaximumFindings) {
                $observerFindingsTruncated = $true
                break
            }
            [void]$findings.Add((New-OwnerObserverFinding -Capability $capability -Entry $entry `
                    -Disposition violation -Anchors $audit.Anchors))
        }
        foreach ($entry in $unknownEntries) {
            if ($findings.Count -ge $script:OwnerObserverMaximumFindings) {
                $observerFindingsTruncated = $true
                break
            }
            [void]$findings.Add((New-OwnerObserverFinding -Capability $capability -Entry $entry `
                    -Disposition unknown -Anchors $audit.Anchors))
        }
        if ($observerFindingsTruncated) {
            Add-OwnerObserverValidationError -Errors $errors `
                -Text 'Findings exceeded the 512-entry normalized observation limit; finding parity is incomplete.'
        }
    }

    $previewWrites = Get-OwnerObserverKnownNumber -Container $record -Name 'providerWriteCount'
    $providerWrites = if ($previewWrites -eq $script:OwnerObserverUnknown -or
        $audit.ProviderWrites -eq $script:OwnerObserverUnknown) {
        $script:OwnerObserverUnknown
    }
    else {
        [long]$previewWrites + [long]$audit.ProviderWrites
    }
    $terminalStatus = Get-OwnerObserverKnownText -Container $terminal -Name 'status'
    $diagnostic = ConvertTo-OwnerObserverDiagnostic -Text (
        [string](Get-OwnerObserverValue $terminal 'diagnostic' ''))

    $outcome = [ordered]@{
        schemaVersion = 1
        kind = 'owner-observation'
        implementation = [ordered]@{
            id = 'owner-v1-external'
            version = '1'
        }
        capability = $capability
        subject = [ordered]@{
            pullRequestId = Get-OwnerObserverKnownNumber -Container $subject -Name 'pullRequestId'
            repositoryId = Get-OwnerObserverKnownText -Container $subject -Name 'repositoryId'
            headCommit = Get-OwnerObserverKnownText -Container $subject -Name 'sourceCommit'
            targetCommit = Get-OwnerObserverKnownText -Container $subject -Name 'targetCommit'
            targetRef = Get-OwnerObserverKnownText -Container $subject -Name 'targetRefName'
        }
        rule = [ordered]@{
            identity = $(if ($rule) {
                    $ruleIdentity = [ordered]@{
                        path = Get-OwnerObserverKnownText -Container $rule -Name 'path'
                        section = Get-OwnerObserverKnownText -Container $rule -Name 'section'
                        commit = Get-OwnerObserverKnownText -Container $rule -Name 'commit'
                        sha256 = Get-OwnerObserverKnownText -Container $rule -Name 'sha256'
                    }
                    if (@($ruleIdentity.Values | Where-Object { $_ -eq $script:OwnerObserverUnknown }).Count -gt 0) {
                        $script:OwnerObserverUnknown
                    }
                    else {
                        Get-OwnerObserverBytesSha256 -Bytes (
                            [Text.UTF8Encoding]::new($false).GetBytes(
                                (ConvertTo-OwnerObserverCanonicalJson -Value $ruleIdentity)))
                    }
                }
                else { $script:OwnerObserverUnknown })
            path = Get-OwnerObserverKnownText -Container $rule -Name 'path'
            section = Get-OwnerObserverKnownText -Container $rule -Name 'section'
            commit = Get-OwnerObserverKnownText -Container $rule -Name 'commit'
            sha256 = Get-OwnerObserverKnownText -Container $rule -Name 'sha256'
        }
        lifecycle = Get-OwnerObserverLifecycle -Record $record
        counts = [ordered]@{
            checked = Get-OwnerObserverKnownNumber -Container $counts -Name 'checked'
            violations = Get-OwnerObserverKnownNumber -Container $counts -Name 'violations'
            unknown = Get-OwnerObserverKnownNumber -Container $counts -Name 'unknown'
            uncovered = $uncovered
        }
        findingsComplete = $(if ($status) {
                -not ($observerFindingsTruncated -or
                    (Get-OwnerObserverValue $status 'violationsTruncated' $null) -or
                    (Get-OwnerObserverValue $status 'unknownsTruncated' $null))
            }
            else { $script:OwnerObserverUnknown })
        findings = @(Get-OwnerObserverSortedFindings -Findings $findings.ToArray())
        execution = [ordered]@{
            attempts = Get-OwnerObserverKnownNumber -Container $record -Name 'attempts'
            modelStarts = Get-OwnerObserverKnownNumber -Container $record -Name 'startCount'
            latencyMs = Get-OwnerObserverKnownNumber -Container $record -Name 'latencyMs'
            refusalReason = $(if ($terminalStatus -eq 'blocked' -and $diagnostic) { $diagnostic } else { $script:OwnerObserverUnknown })
            incompleteReason = $(if ($terminalStatus -in @('incomplete', 'running', 'pending') -and $diagnostic) {
                    $diagnostic
                }
                else { $script:OwnerObserverUnknown })
        }
        effects = [ordered]@{
            providerWrites = $providerWrites
            writeToolInvocations = Get-OwnerObserverKnownNumber -Container $record -Name 'writeToolInvocations'
            dedupe = $audit.Dedupe
            operatorIntervention = $audit.OperatorIntervention
        }
        sourceArtifacts = @($artifacts.ToArray())
        validationErrors = @($errors.ToArray())
    }
    if (-not (Test-OwnerObservation -Observation $outcome)) {
        throw 'Owner v1 normalization produced an invalid owner-observation document.'
    }
    return $outcome
}

function Test-OwnerObservation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Observation)
    if (-not (Test-Path -LiteralPath $script:OwnerObserverSchemaPath -PathType Leaf)) {
        throw 'Owner observation schema is missing.'
    }
    try {
        $json = $Observation | ConvertTo-Json -Depth 64 -Compress
        return Test-Json -Json $json -SchemaFile $script:OwnerObserverSchemaPath -ErrorAction Stop
    }
    catch {
        return $false
    }
}

function Read-OwnerNormalizedObservation {
    <#
    .SYNOPSIS
        Reads a future Owner implementation that already emits the shared shape.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-OwnerObserverFile -Path $Path -Label 'Normalized Owner observation'
    $bytes = [IO.File]::ReadAllBytes($resolved)
    if ($bytes.Length -gt 4MB) { throw 'Normalized Owner observation exceeds the 4 MiB limit.' }
    try {
        $text = ([Text.UTF8Encoding]::new($false, $true)).GetString($bytes)
        $outcome = $text | ConvertFrom-Json -Depth 64 -AsHashtable
    }
    catch {
        throw 'Normalized Owner observation is not valid UTF-8 JSON.'
    }
    if (-not (Test-OwnerObservation -Observation $outcome)) {
        throw 'Normalized Owner observation failed owner-observation schema validation.'
    }
    $outcome.execution.refusalReason = if ([string]$outcome.execution.refusalReason -eq $script:OwnerObserverUnknown) {
        $script:OwnerObserverUnknown
    }
    else {
        ConvertTo-OwnerObserverDiagnostic -Text ([string]$outcome.execution.refusalReason)
    }
    $outcome.execution.incompleteReason = if ([string]$outcome.execution.incompleteReason -eq $script:OwnerObserverUnknown) {
        $script:OwnerObserverUnknown
    }
    else {
        ConvertTo-OwnerObserverDiagnostic -Text ([string]$outcome.execution.incompleteReason)
    }
    $outcome.validationErrors = @($outcome.validationErrors | ForEach-Object {
            ConvertTo-OwnerObserverDiagnostic -Text ([string]$_)
        })
    $artifacts = [Collections.Generic.List[object]]::new()
    foreach ($artifact in @($outcome.sourceArtifacts)) { [void]$artifacts.Add($artifact) }
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($error in @($outcome.validationErrors)) { [void]$errors.Add([string]$error) }
    Add-OwnerObserverArtifact -Artifacts $artifacts -Errors $errors -Kind 'normalized-owner-output' `
        -Sha256 (Get-OwnerObserverBytesSha256 -Bytes $bytes) -Signature 'not-applicable'
    $outcome.sourceArtifacts = @($artifacts.ToArray())
    $outcome.validationErrors = @($errors.ToArray())
    if (-not (Test-OwnerObservation -Observation $outcome)) {
        throw 'Normalized Owner observation became invalid after provenance normalization.'
    }
    return $outcome
}

function Get-OwnerObserverFindingMap {
    param([Parameter(Mandatory)]$Observation)
    $map = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $hasUncomparable = $false
    foreach ($finding in @($Observation.findings)) {
        $identity = [string](Get-OwnerObserverValue $finding 'identity' '')
        if (-not $identity -or $identity -ceq $script:OwnerObserverUnknown) {
            $hasUncomparable = $true
            continue
        }
        if ($map.ContainsKey($identity)) {
            $hasUncomparable = $true
            continue
        }
        $map[$identity] = $finding
    }
    return [pscustomobject]@{
        Map = $map
        HasUncomparable = $hasUncomparable
    }
}

function Compare-OwnerObserverScalar {
    param($Left, $Right)
    if (($Left -is [string] -and $Left -ceq $script:OwnerObserverUnknown) -or
        ($Right -is [string] -and $Right -ceq $script:OwnerObserverUnknown)) {
        return $script:OwnerObserverUnknown
    }
    return [bool]($Left -ceq $Right)
}

function Compare-OwnerObservations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Baseline,
        [Parameter(Mandatory)]$Candidate
    )
    if (-not (Test-OwnerObservation -Observation $Baseline) -or
        -not (Test-OwnerObservation -Observation $Candidate)) {
        throw 'Both parity inputs must satisfy the owner-observation schema.'
    }

    $baselineFindingResult = Get-OwnerObserverFindingMap -Observation $Baseline
    $candidateFindingResult = Get-OwnerObserverFindingMap -Observation $Candidate
    $baselineFindings = $baselineFindingResult.Map
    $candidateFindings = $candidateFindingResult.Map
    $retained = @(Get-OwnerObserverSortedNames -Names @(
            $baselineFindings.Keys | Where-Object { $candidateFindings.ContainsKey($_) }))
    $lost = @(Get-OwnerObserverSortedNames -Names @(
            $baselineFindings.Keys | Where-Object { -not $candidateFindings.ContainsKey($_) }))
    $new = @(Get-OwnerObserverSortedNames -Names @(
            $candidateFindings.Keys | Where-Object { -not $baselineFindings.ContainsKey($_) }))

    $bindingFields = @(
        @{ Name = 'capability'; Left = $Baseline.capability; Right = $Candidate.capability },
        @{ Name = 'subject.pullRequestId'; Left = $Baseline.subject.pullRequestId; Right = $Candidate.subject.pullRequestId },
        @{ Name = 'subject.repositoryId'; Left = $Baseline.subject.repositoryId; Right = $Candidate.subject.repositoryId },
        @{ Name = 'subject.headCommit'; Left = $Baseline.subject.headCommit; Right = $Candidate.subject.headCommit },
        @{ Name = 'subject.targetCommit'; Left = $Baseline.subject.targetCommit; Right = $Candidate.subject.targetCommit },
        @{ Name = 'subject.targetRef'; Left = $Baseline.subject.targetRef; Right = $Candidate.subject.targetRef },
        @{ Name = 'rule.identity'; Left = $Baseline.rule.identity; Right = $Candidate.rule.identity }
    )
    $mismatches = [Collections.Generic.List[string]]::new()
    $bindingUnknown = $false
    foreach ($field in $bindingFields) {
        $comparison = Compare-OwnerObserverScalar -Left $field.Left -Right $field.Right
        if ($comparison -is [string] -and $comparison -ceq $script:OwnerObserverUnknown) {
            $bindingUnknown = $true
        }
        elseif (-not $comparison) { [void]$mismatches.Add([string]$field.Name) }
    }

    $countRegressions = [Collections.Generic.List[string]]::new()
    foreach ($definition in @(
            @{ Name = 'checked-decreased'; Field = 'checked'; Direction = 'down' },
            @{ Name = 'violations-decreased'; Field = 'violations'; Direction = 'down' },
            @{ Name = 'unknown-increased'; Field = 'unknown'; Direction = 'up' },
            @{ Name = 'uncovered-increased'; Field = 'uncovered'; Direction = 'up' })) {
        $left = $Baseline.counts[$definition.Field]
        $right = $Candidate.counts[$definition.Field]
        if ($left -eq $script:OwnerObserverUnknown -or $right -eq $script:OwnerObserverUnknown) { continue }
        if (($definition.Direction -eq 'down' -and [long]$right -lt [long]$left) -or
            ($definition.Direction -eq 'up' -and [long]$right -gt [long]$left)) {
            [void]$countRegressions.Add([string]$definition.Name)
        }
    }

    $completionUnknown =
        ($Baseline.lifecycle.completed -is [string] -and
            $Baseline.lifecycle.completed -ceq $script:OwnerObserverUnknown) -or
        ($Candidate.lifecycle.completed -is [string] -and
            $Candidate.lifecycle.completed -ceq $script:OwnerObserverUnknown)
    $completionRegression = if ($completionUnknown) {
        $script:OwnerObserverUnknown
    }
    else {
        [bool]($Baseline.lifecycle.completed -eq $true -and
            $Candidate.lifecycle.completed -ne $true)
    }
    $writeFields = @('providerWrites', 'writeToolInvocations')
    $writeMismatches = [Collections.Generic.List[string]]::new()
    $writeUnknown = $false
    foreach ($field in $writeFields) {
        $comparison = Compare-OwnerObserverScalar -Left $Baseline.effects[$field] -Right $Candidate.effects[$field]
        if ($comparison -is [string] -and $comparison -ceq $script:OwnerObserverUnknown) {
            $writeUnknown = $true
        }
        elseif (-not $comparison) { [void]$writeMismatches.Add($field) }
    }
    $baselineLatency = $Baseline.execution.latencyMs
    $candidateLatency = $Candidate.execution.latencyMs
    $latency = if ($baselineLatency -eq $script:OwnerObserverUnknown -or
        $candidateLatency -eq $script:OwnerObserverUnknown) {
        [ordered]@{
            baselineMs = $baselineLatency
            candidateMs = $candidateLatency
            deltaMs = $script:OwnerObserverUnknown
            comparison = $script:OwnerObserverUnknown
        }
    }
    else {
        $delta = [long]$candidateLatency - [long]$baselineLatency
        [ordered]@{
            baselineMs = [long]$baselineLatency
            candidateMs = [long]$candidateLatency
            deltaMs = $delta
            comparison = $(if ($delta -lt 0) { 'faster' } elseif ($delta -gt 0) { 'slower' } else { 'equal' })
        }
    }
    $statusUnknown = $Baseline.lifecycle.status -ceq $script:OwnerObserverUnknown -or
        $Candidate.lifecycle.status -ceq $script:OwnerObserverUnknown
    $statusRegression = if ($completionUnknown -or $statusUnknown) {
        $script:OwnerObserverUnknown
    }
    else {
        [bool]($completionRegression -or
            ($Baseline.lifecycle.status -eq 'pending' -and
                $Candidate.lifecycle.status -in @('incomplete', 'blocked')) -or
            ($Baseline.lifecycle.status -eq 'incomplete' -and
                $Candidate.lifecycle.status -eq 'blocked'))
    }
    $baselineFindingsUnknown = $Baseline.findingsComplete -ne $true
    $candidateFindingsUnknown = $Candidate.findingsComplete -ne $true
    $parity = if ($bindingUnknown -or $writeUnknown -or
        $baselineFindingsUnknown -or $candidateFindingsUnknown -or
        $baselineFindingResult.HasUncomparable -or $candidateFindingResult.HasUncomparable -or
        $completionUnknown -or $statusUnknown) {
        $script:OwnerObserverUnknown
    }
    else {
        -not ($mismatches.Count -gt 0 -or $lost.Count -gt 0 -or $countRegressions.Count -gt 0 -or
            $writeMismatches.Count -gt 0 -or $statusRegression)
    }

    return [ordered]@{
        schemaVersion = 1
        kind = 'owner-observation-parity'
        baseline = $Baseline.implementation
        candidate = $Candidate.implementation
        parity = $parity
        findings = [ordered]@{
            retained = $retained
            lost = $lost
            new = $new
        }
        binding = [ordered]@{
            matches = $(if ($bindingUnknown) {
                    $script:OwnerObserverUnknown
                }
                else { $mismatches.Count -eq 0 })
            mismatches = @($mismatches.ToArray())
        }
        regressions = [ordered]@{
            status = $statusRegression
            counts = @($countRegressions.ToArray())
        }
        writes = [ordered]@{
            matches = $(if ($writeUnknown) {
                    $script:OwnerObserverUnknown
                }
                else { $writeMismatches.Count -eq 0 })
            mismatches = @($writeMismatches.ToArray())
            baseline = [ordered]@{
                providerWrites = $Baseline.effects.providerWrites
                writeToolInvocations = $Baseline.effects.writeToolInvocations
            }
            candidate = [ordered]@{
                providerWrites = $Candidate.effects.providerWrites
                writeToolInvocations = $Candidate.effects.writeToolInvocations
            }
        }
        completion = [ordered]@{
            baseline = $Baseline.lifecycle.status
            candidate = $Candidate.lifecycle.status
            regression = $completionRegression
        }
        latency = $latency
    }
}
