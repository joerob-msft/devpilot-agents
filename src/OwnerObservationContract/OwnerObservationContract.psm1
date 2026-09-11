#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:OwnerBindingVersion = 1
$script:OwnerUnknown = 'unknown'

function Get-OwnerContractMember {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $Default
    }
    if ($null -ne $Value) {
        $property = $Value.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    return $Default
}

function Get-OwnerContractSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return ([Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant()
}

function ConvertTo-OwnerContractCanonicalJson {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) {
        return ConvertTo-Json -InputObject $Value -Compress
    }
    if ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]) {
        return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [Collections.IDictionary]) {
        $parts = foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) {
            (ConvertTo-Json -InputObject ([string]$key) -Compress) + ':' +
                (ConvertTo-OwnerContractCanonicalJson -Value $Value[$key])
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $copy[$property.Name] = $property.Value
        }
        return ConvertTo-OwnerContractCanonicalJson -Value $copy
    }
    if ($Value -is [Collections.IEnumerable]) {
        return '[' + (@($Value | ForEach-Object {
                        ConvertTo-OwnerContractCanonicalJson -Value $_
                    }) -join ',') + ']'
    }
    throw "Owner observation canonical JSON does not support '$($Value.GetType().FullName)'."
}

function ConvertTo-OwnerRepositoryPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -cne $Path.Trim() -or
        $Path.Length -gt 4096 -or $Path -match '[\x00-\x1f\x7f]') {
        throw 'Repository path must be non-empty, trimmed, bounded text without control characters.'
    }
    if (-not $Path.IsNormalized([Text.NormalizationForm]::FormC)) {
        throw 'Repository path must already use Unicode normalization form C.'
    }
    if ($Path -match '^[A-Za-z]:' -or $Path -match '^[\\/]{2}' -or
        $Path -match '^[/\\]\?[/\\]' -or $Path -match '^[/\\]\.[/\\]') {
        throw 'Repository path must not be absolute or use a device path.'
    }

    $candidate = $Path.Replace('\', '/')
    if ($candidate.StartsWith('/', [StringComparison]::Ordinal)) {
        $candidate = $candidate.Substring(1)
    }
    if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.EndsWith('/') -or
        $candidate.Contains('//')) {
        throw 'Repository path normalization is ambiguous.'
    }
    $segments = @($candidate.Split('/'))
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.', '..') -or
            $segment.EndsWith(' ') -or $segment.EndsWith('.') -or
            $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "Repository path segment '$segment' is unsafe or ambiguous."
        }
    }
    return $segments -join '/'
}

function Assert-OwnerRepositoryPathSet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Paths)

    $ordinal = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $folded = [Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($rawPath in $Paths) {
        $normalized = ConvertTo-OwnerRepositoryPath -Path $rawPath
        if (-not $ordinal.Add($normalized)) {
            throw "Repository path '$normalized' is duplicated after normalization."
        }
        if ($folded.ContainsKey($normalized) -and
            [string]$folded[$normalized] -cne $normalized) {
            throw "Repository paths '$($folded[$normalized])' and '$normalized' collide by case."
        }
        $folded[$normalized] = $normalized
    }
}

function New-OwnerCanonicalAnchor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$StartLine,
        [ValidateRange(1, 2147483647)][int]$EndLine = $StartLine,
        [AllowNull()][object]$StartColumn = $script:OwnerUnknown,
        [AllowNull()][object]$EndColumn = $script:OwnerUnknown,
        [Parameter(Mandatory)][string]$Symbol,
        [Parameter(Mandatory)][string]$ConstructIdentity
    )

    if ($EndLine -lt $StartLine) {
        throw 'Owner finding span endLine must not precede startLine.'
    }
    foreach ($column in @($StartColumn, $EndColumn)) {
        if ($column -is [string]) {
            if ($column -cne $script:OwnerUnknown) {
                throw "Owner finding span columns must be positive integers or '$script:OwnerUnknown'."
            }
        }
        elseif ($column -is [bool] -or $column -isnot [int] -and $column -isnot [long] -or
            [long]$column -lt 1) {
            throw "Owner finding span columns must be positive integers or '$script:OwnerUnknown'."
        }
    }
    if (($StartColumn -is [string]) -xor ($EndColumn -is [string])) {
        throw 'Owner finding span columns must both be measured or both be unknown.'
    }
    if ($StartLine -eq $EndLine -and
        $StartColumn -isnot [string] -and [long]$EndColumn -lt [long]$StartColumn) {
        throw 'Owner finding span endColumn must not precede startColumn on the same line.'
    }
    if ([string]::IsNullOrWhiteSpace($Symbol) -or $Symbol -cne $Symbol.Trim() -or
        $Symbol.Length -gt 1024 -or $Symbol -match '[\r\n]') {
        throw 'Owner finding symbol must be non-empty, trimmed, bounded single-line text.'
    }
    if ([string]::IsNullOrWhiteSpace($ConstructIdentity) -or
        $ConstructIdentity -cne $ConstructIdentity.Trim() -or
        $ConstructIdentity.Length -gt 1024 -or $ConstructIdentity -match '[\r\n]') {
        throw 'Owner finding construct identity must be non-empty, trimmed, bounded single-line text.'
    }

    $normalizedPath = ConvertTo-OwnerRepositoryPath -Path $Path
    $raw = [ordered]@{
        path = $Path
        startLine = $StartLine
        endLine = $EndLine
        startColumn = $StartColumn
        endColumn = $EndColumn
        symbol = $Symbol
        constructIdentity = $ConstructIdentity
    }
    $canonicalConstruct = [ordered]@{
        schemaVersion = $script:OwnerBindingVersion
        repositoryPath = $normalizedPath
        span = [ordered]@{
            startLine = $StartLine
            endLine = $EndLine
            startColumn = $StartColumn
            endColumn = $EndColumn
        }
        symbol = $Symbol
    }
    return [ordered]@{
        schemaVersion = $script:OwnerBindingVersion
        repositoryPath = $normalizedPath
        span = $canonicalConstruct.span
        symbol = $Symbol
        constructIdentity = 'v1:sha256:' + (Get-OwnerContractSha256 -Bytes (
                [Text.UTF8Encoding]::new($false).GetBytes(
                    (ConvertTo-OwnerContractCanonicalJson -Value $canonicalConstruct))))
        source = [ordered]@{
            representation = $raw
            sha256 = Get-OwnerContractSha256 -Bytes (
                [Text.UTF8Encoding]::new($false).GetBytes(
                    (ConvertTo-OwnerContractCanonicalJson -Value $raw)))
        }
    }
}

function Get-OwnerSemanticFindingKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Subject,
        [Parameter(Mandatory)][object]$Rule,
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][object]$Binding
    )

    if ([int](Get-OwnerContractMember $Binding 'schemaVersion' 0) -ne
        $script:OwnerBindingVersion) {
        throw 'Owner finding binding has an unsupported schema version.'
    }
    $rulePath = [string](Get-OwnerContractMember $Rule 'path' '')
    if ($rulePath -and $rulePath -cne $script:OwnerUnknown) {
        $rulePath = ConvertTo-OwnerRepositoryPath -Path $rulePath
    }
    $material = [ordered]@{
        schemaVersion = 1
        subject = [ordered]@{
            repositoryId = [string](Get-OwnerContractMember $Subject 'repositoryId' '')
            pullRequestId = Get-OwnerContractMember $Subject 'pullRequestId'
            headCommit = [string](Get-OwnerContractMember $Subject 'headCommit' '')
        }
        rule = [ordered]@{
            path = $rulePath
            section = [string](Get-OwnerContractMember $Rule 'section' '')
            commit = [string](Get-OwnerContractMember $Rule 'commit' '')
            sha256 = [string](Get-OwnerContractMember $Rule 'sha256' '')
        }
        capability = $Capability
        anchor = [ordered]@{
            repositoryPath = [string](Get-OwnerContractMember $Binding 'repositoryPath' '')
            span = Get-OwnerContractMember $Binding 'span'
            symbol = [string](Get-OwnerContractMember $Binding 'symbol' '')
            constructIdentity = [string](Get-OwnerContractMember $Binding 'constructIdentity' '')
        }
    }
    $json = ConvertTo-OwnerContractCanonicalJson -Value $material
    return 'v1:sha256:' + (Get-OwnerContractSha256 -Bytes (
            [Text.UTF8Encoding]::new($false).GetBytes($json)))
}

function New-OwnerProviderMarker {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [ValidateSet('verified', 'invalid', 'unavailable')][string]$Integrity = 'unavailable'
    )
    if ([string]::IsNullOrEmpty($Value)) {
        return [ordered]@{
            availability = 'unavailable'
            integrity = 'unavailable'
            sha256 = $script:OwnerUnknown
        }
    }
    return [ordered]@{
        availability = 'available'
        integrity = $Integrity
        sha256 = Get-OwnerContractSha256 -Bytes (
            [Text.UTF8Encoding]::new($false).GetBytes($Value))
    }
}

function New-OwnerMeasurement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('measured', 'unavailable', 'notMeasured')]
        [string]$Status,
        [AllowNull()][object]$Value = $null,
        [AllowEmptyString()][string]$Reason = ''
    )
    if ($Status -ceq 'measured' -and $null -eq $Value) {
        throw 'Measured Owner telemetry requires an explicit value, including zero.'
    }
    if ($Status -cne 'measured' -and $null -ne $Value) {
        throw 'Unavailable or not-measured Owner telemetry must not carry a numeric value.'
    }
    return [ordered]@{
        status = $Status
        value = $Value
        reason = $(if ($Status -ceq 'measured') { $script:OwnerUnknown } else { $Reason })
    }
}

Export-ModuleMember -Function @(
    'Assert-OwnerRepositoryPathSet',
    'ConvertTo-OwnerContractCanonicalJson',
    'ConvertTo-OwnerRepositoryPath',
    'Get-OwnerSemanticFindingKey',
    'New-OwnerCanonicalAnchor',
    'New-OwnerMeasurement',
    'New-OwnerProviderMarker'
)
