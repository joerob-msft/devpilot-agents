#requires -Version 7.0

Set-StrictMode -Version Latest

$script:ReviewerAcquisitionPackageUtf8 = [Text.UTF8Encoding]::new($false, $true)

function ConvertTo-ReviewerAcquisitionPackageCanonicalElement {
    param([Parameter(Mandatory)][System.Text.Json.JsonElement]$Element, [int]$Depth = 0)
    if ($Depth -gt 64) { throw 'Acquisition package canonical JSON exceeded depth 64.' }
    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Object) {
            $properties = @($Element.EnumerateObject())
            $names = [Collections.Generic.List[string]]::new()
            $values = @{}
            foreach ($property in $properties) {
                [void]$names.Add($property.Name)
                $values[$property.Name] = $property.Value
            }
            $names.Sort([StringComparer]::Ordinal)
            $parts = foreach ($name in $names) {
                (ConvertTo-Json -InputObject $name -Compress) + ':' +
                (ConvertTo-ReviewerAcquisitionPackageCanonicalElement -Element $values[$name] -Depth ($Depth + 1))
            }
            return '{' + ($parts -join ',') + '}'
        }
        ([System.Text.Json.JsonValueKind]::Array) {
            $parts = foreach ($item in $Element.EnumerateArray()) {
                ConvertTo-ReviewerAcquisitionPackageCanonicalElement -Element $item -Depth ($Depth + 1)
            }
            return '[' + ($parts -join ',') + ']'
        }
        ([System.Text.Json.JsonValueKind]::String) { return ConvertTo-Json -InputObject $Element.GetString() -Compress }
        ([System.Text.Json.JsonValueKind]::Number) { return $Element.GetRawText() }
        ([System.Text.Json.JsonValueKind]::True) { return 'true' }
        ([System.Text.Json.JsonValueKind]::False) { return 'false' }
        ([System.Text.Json.JsonValueKind]::Null) { return 'null' }
        default { return $Element.GetRawText() }
    }
}

function ConvertTo-ReviewerAcquisitionPackageCanonicalText {
    param([Parameter(Mandatory)][string]$JsonText)
    $document = [System.Text.Json.JsonDocument]::Parse($JsonText)
    try {
        return ConvertTo-ReviewerAcquisitionPackageCanonicalElement -Element $document.RootElement
    }
    finally { $document.Dispose() }
}

function Get-ReviewerAcquisitionPackageTextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString(
                $sha.ComputeHash($script:ReviewerAcquisitionPackageUtf8.GetBytes($Text)))).ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-ReviewerAcquisitionPackageFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ReviewerAcquisitionPackageBytesSha256 {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return ([Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant()
}

function Get-ReviewerAcquisitionPackageHmac {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $hmac = [Security.Cryptography.HMACSHA256]::new($Key)
    try {
        return ([Convert]::ToHexString(
                $hmac.ComputeHash($script:ReviewerAcquisitionPackageUtf8.GetBytes($Text)))).ToLowerInvariant()
    }
    finally { $hmac.Dispose() }
}

function Assert-ReviewerAcquisitionTranscriptPackage {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$SealKeyPath,
        [string]$SchemaPath,
        [switch]$RequireCaptured
    )
    $root = (Resolve-Path -LiteralPath $PackageRoot -ErrorAction Stop).Path
    $rootItem = Get-Item -LiteralPath $root -Force
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The acquisition package root '$root' must be a real directory, not a reparse point."
    }
    $manifestPath = Join-Path $root 'transcript-package.json'
    $sealPath = Join-Path $root 'transcript-package.seal'
    $corePath = Join-Path $root 'capture-core.json'
    $markerPath = Join-Path $root 'result-marker.txt'
    foreach ($required in @($manifestPath, $sealPath, $corePath, $markerPath, $SealKeyPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "The authenticated acquisition package is missing required file '$required'."
        }
    }

    $manifestText = [IO.File]::ReadAllText($manifestPath, $script:ReviewerAcquisitionPackageUtf8)
    $canonical = ConvertTo-ReviewerAcquisitionPackageCanonicalText -JsonText $manifestText
    if ($canonical -cne $manifestText) {
        throw 'The acquisition package manifest is not canonical; it may have been tampered with.'
    }
    if ($SchemaPath -and
        -not (Test-Json -Json $manifestText -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) {
        throw 'The acquisition package manifest failed its versioned schema.'
    }
    $manifest = $manifestText | ConvertFrom-Json -Depth 64
    $seal = [IO.File]::ReadAllText($sealPath, $script:ReviewerAcquisitionPackageUtf8) |
        ConvertFrom-Json -Depth 16
    $sealKeys = @($seal.PSObject.Properties.Name | Sort-Object)
    $expectedSealKeys = @('kind', 'manifestHmac', 'manifestSha256', 'schemaVersion', 'sealedUtc') | Sort-Object
    if (($sealKeys -join "`n") -cne ($expectedSealKeys -join "`n") -or
        [int]$seal.schemaVersion -ne 1 -or
        [string]$seal.kind -cne 'reviewer-blinded-transcript-package-seal') {
        throw 'The acquisition package seal has an unexpected shape.'
    }
    $key = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $SealKeyPath).Path)
    if ($key.Length -lt 32) { throw 'The acquisition package HMAC key must contain at least 32 bytes.' }
    $manifestSha = Get-ReviewerAcquisitionPackageTextSha256 -Text $manifestText
    if ([string]$seal.manifestSha256 -cne $manifestSha) {
        throw 'The acquisition package manifest SHA-256 seal does not match.'
    }
    $expectedHmac = Get-ReviewerAcquisitionPackageHmac -Text $manifestText -Key $key
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            [Convert]::FromHexString([string]$seal.manifestHmac),
            [Convert]::FromHexString($expectedHmac))) {
        throw 'The acquisition package manifest HMAC seal does not match.'
    }

    $boundFiles = @{}
    $boundFileBytes = @{}
    foreach ($entry in @($manifest.files)) {
        $relative = [string]$entry.name
        if ($boundFiles.ContainsKey($relative) -or
            $relative -match '(^|/)\.\.(/|$)' -or $relative -match '^([A-Za-z]:|/|\\)') {
            throw "The acquisition package declares an illegal or duplicate bound file '$relative'."
        }
        $boundFiles[$relative] = $true
        $path = Join-Path $root ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The acquisition package is missing bound file '$relative'."
        }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "reparse-point file present: $relative"
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) {
            throw "writable file present (not read-only): $relative"
        }
        # Read each authenticated payload exactly once. Every downstream parse,
        # digest, and supervisor-owned child copy consumes these same bytes rather
        # than reopening caller-controlled paths after verification.
        [byte[]]$bytes = [IO.File]::ReadAllBytes($path)
        if ([long]$bytes.Length -ne [long]$entry.bytes -or
            (Get-ReviewerAcquisitionPackageBytesSha256 -Bytes $bytes) -cne [string]$entry.sha256) {
            throw "The acquisition package bound file '$relative' failed its byte/hash binding."
        }
        $boundFileBytes[$relative] = $bytes
    }

    $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force)) {
        $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "reparse-point file present: $relative"
        }
        if (($file.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) {
            throw "writable file present (not read-only): $relative"
        }
        if ($relative -notin @('transcript-package.json', 'transcript-package.seal') -and
            -not $boundFiles.ContainsKey($relative)) {
            throw "The acquisition package contains unbound file '$relative'."
        }
    }

    $boundDirectories = @{}
    foreach ($entry in @($manifest.directories)) {
        $relative = [string]$entry.name
        if ($boundDirectories.ContainsKey($relative) -or
            $relative -match '(^|/)\.\.(/|$)' -or $relative -match '^([A-Za-z]:|/|\\)') {
            throw "The acquisition package declares an illegal or duplicate directory '$relative'."
        }
        $boundDirectories[$relative] = $true
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force)) {
        $relative = $directory.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not $boundDirectories.ContainsKey($relative) -or
            @(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0) {
            throw "The acquisition package directory '$relative' failed its recursive inventory binding."
        }
    }
    foreach ($relative in $boundDirectories.Keys) {
        $path = Join-Path $root ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            throw "The acquisition package is missing bound directory '$relative'."
        }
    }

    [byte[]]$coreBytes = $boundFileBytes['capture-core.json']
    [byte[]]$markerBytes = $boundFileBytes['result-marker.txt']
    if ($null -eq $coreBytes -or $null -eq $markerBytes) {
        throw 'The acquisition package manifest does not bind its capture core and result marker.'
    }
    $coreText = $script:ReviewerAcquisitionPackageUtf8.GetString($coreBytes)
    $markerText = $script:ReviewerAcquisitionPackageUtf8.GetString($markerBytes)
    $core = $coreText | ConvertFrom-Json -Depth 64
    $manifestHasSpecialistEnabled = $null -ne
        $manifest.PSObject.Properties['conventionSpecialistEnabled']
    $manifestHasSpecialistModel = $null -ne
        $manifest.PSObject.Properties['conventionSpecialistModel']
    $coreHasSpecialistEnabled = $null -ne
        $core.PSObject.Properties['conventionSpecialistEnabled']
    $coreHasSpecialistModel = $null -ne
        $core.PSObject.Properties['conventionSpecialistModel']
    if ($manifestHasSpecialistEnabled -ne $manifestHasSpecialistModel -or
        $coreHasSpecialistEnabled -ne $coreHasSpecialistModel) {
        throw 'The acquisition package has a partial convention specialist binding.'
    }
    $manifestHasSpecialistBinding = $manifestHasSpecialistEnabled
    $coreHasSpecialistBinding = $coreHasSpecialistEnabled
    if ($manifestHasSpecialistBinding -ne $coreHasSpecialistBinding) {
        throw 'The acquisition package manifest and capture core disagree on convention specialist binding presence.'
    }
    if ($coreHasSpecialistBinding -and $core.conventionSpecialistEnabled -isnot [bool]) {
        throw 'The acquisition package capture core has an invalid convention specialist binding.'
    }
    if ($coreHasSpecialistBinding -and [bool]$core.conventionSpecialistEnabled) {
        if ($core.conventionSpecialistModel -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$core.conventionSpecialistModel)) {
            throw 'The acquisition package capture core has an invalid convention specialist binding.'
        }
    }
    elseif ($coreHasSpecialistBinding -and $null -ne $core.conventionSpecialistModel) {
        throw 'The acquisition package capture core has an invalid convention specialist binding.'
    }
    if ([string]$manifest.role -cne [string]$core.role -or
        [string]$manifest.requestedModel -cne [string]$core.requestedModel -or
        [string]$manifest.reportedModel -cne [string]$core.reportedModel -or
        [string]$manifest.secondGeneralistModel -cne [string]$core.secondGeneralistModel -or
        ($coreHasSpecialistBinding -and
            ($manifest.conventionSpecialistEnabled -cne $core.conventionSpecialistEnabled -or
                $manifest.conventionSpecialistModel -cne $core.conventionSpecialistModel)) -or
        [string]$manifest.nonce -cne [string]$core.nonce -or
        [string]$manifest.resultMarkerPrefix -cne [string]$core.resultMarkerPrefix -or
        [string]$manifest.terminalStatus -cne [string]$core.terminalStatus) {
        throw 'The acquisition package manifest and capture core disagree on source identity.'
    }
    if ($RequireCaptured -and
        ([string]$core.terminalStatus -cne 'captured' -or
            [string]$core.requestedModel -cne [string]$core.reportedModel -or
            [string]@($core.attempts)[-1].markerStatus -cne 'success')) {
        throw 'The acquisition package is not a successful, model-matched result-marker capture.'
    }

    return [pscustomobject]@{
        Root           = $root
        Manifest       = $manifest
        ManifestPath   = $manifestPath
        ManifestSha256 = $manifestSha
        Core           = $core
        CoreBytes      = $coreBytes
        CoreText       = $coreText
        CoreSha256     = Get-ReviewerAcquisitionPackageBytesSha256 -Bytes $coreBytes
        CorePath       = $corePath
        MarkerBytes    = $markerBytes
        MarkerText     = $markerText
        MarkerSha256   = Get-ReviewerAcquisitionPackageBytesSha256 -Bytes $markerBytes
        MarkerPath     = $markerPath
    }
}
