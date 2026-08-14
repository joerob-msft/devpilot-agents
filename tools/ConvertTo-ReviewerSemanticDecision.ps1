#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline)][string]$InputPath,
    [string]$ContractPath = (Join-Path $PSScriptRoot 'testdata\reviewer-semantic-normalization-contract.v1.json'),
    [string[]]$OperationalRoot = @(),
    [switch]$HashOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$contract = Get-Content -LiteralPath $ContractPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
$document = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
$derivedAliases = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
$derivedValues = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$derivedAliasIndex = 0

function Sort-Ordinal {
    param([object[]]$Items, [scriptblock]$Key)
    $pairs = @($Items | ForEach-Object {
            [pscustomobject]@{ Value = $_; SortKey = [string](& $Key $_) }
        })
    [Array]::Sort($pairs, [Collections.Generic.Comparer[object]]::Create({
                param($left, $right)
                [StringComparer]::Ordinal.Compare([string]$left.SortKey, [string]$right.SortKey)
            }))
    return @($pairs | ForEach-Object { $_.Value })
}

function Test-ExcludedProperty {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($pattern in @($contract.excludedKeyPatterns)) {
        if ($Name -cmatch [string]$pattern) { return $true }
    }
    return $false
}

function Test-DerivedOperationalPath {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($pattern in @($contract.derivedOperationalValuePathPatterns)) {
        if ($Path -cmatch [string]$pattern) { return $true }
    }
    return $false
}

function Add-DerivedValues {
    param($Value, [string]$Path = '$')
    if ($Value -is [string]) {
        $trimmed = ([string]$Value).Trim()
        if (($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) -or
            ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
            try { Add-DerivedValues ($trimmed | ConvertFrom-Json -Depth 100) "$Path<json>" } catch {}
        }
        return
    }
    if ($null -eq $Value -or $Value -is [ValueType]) { return }
    if ($Value -is [pscustomobject]) {
        foreach ($property in @(Sort-Ordinal @($Value.PSObject.Properties) { param($item) $item.Name })) {
            $propertyPath = "$Path.$($property.Name)"
            if ((Test-DerivedOperationalPath $propertyPath) -and $property.Value -is [string]) {
                [void]$derivedValues.Add([string]$property.Value)
            }
            Add-DerivedValues $property.Value $propertyPath
        }
        return
    }
    if ($Value -is [Collections.IEnumerable]) {
        foreach ($item in $Value) { Add-DerivedValues $item "$Path[]" }
    }
}

function Get-DerivedAliasSortValue {
    param($Value, [string]$Path = '$')
    if ($null -eq $Value -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [string]) {
        if ($derivedValues.Contains([string]$Value)) { return '$DERIVED_OPERATIONAL' }
        $trimmed = ([string]$Value).Trim()
        if (($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) -or
            ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
            try { return Get-DerivedAliasSortValue ($trimmed | ConvertFrom-Json -Depth 100) "$Path<json>" } catch {}
        }
        return [string]$Value
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in @(Sort-Ordinal @($Value.PSObject.Properties) { param($item) $item.Name })) {
            if (Test-ExcludedProperty $property.Name) { continue }
            $propertyPath = "$Path.$($property.Name)"
            $result[$property.Name] = if (Test-DerivedOperationalPath $propertyPath) {
                '$DERIVED_OPERATIONAL'
            }
            else { Get-DerivedAliasSortValue $property.Value $propertyPath }
        }
        return [pscustomobject]$result
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { Get-DerivedAliasSortValue $_ "$Path[]" })
        return ,@(Sort-Ordinal $items { param($item) ConvertTo-Json $item -Depth 100 -Compress })
    }
    return [string]$Value
}

function Register-DerivedAliases {
    param($Value, [string]$Path = '$')
    if ($Value -is [string]) {
        $trimmed = ([string]$Value).Trim()
        if (($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) -or
            ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
            try { Register-DerivedAliases ($trimmed | ConvertFrom-Json -Depth 100) "$Path<json>" } catch {}
        }
        return
    }
    if ($null -eq $Value -or $Value -is [ValueType]) { return }
    if ($Value -is [pscustomobject]) {
        foreach ($property in @(Sort-Ordinal @($Value.PSObject.Properties) { param($item) $item.Name })) {
            $propertyPath = "$Path.$($property.Name)"
            if ((Test-DerivedOperationalPath $propertyPath) -and $property.Value -is [string]) {
                $raw = [string]$property.Value
                if (-not $derivedAliases.ContainsKey($raw)) {
                    $script:derivedAliasIndex++
                    $derivedAliases[$raw] = '$DERIVED_OPERATIONAL_' + $script:derivedAliasIndex
                }
            }
            Register-DerivedAliases $property.Value $propertyPath
        }
        return
    }
    if ($Value -is [Collections.IEnumerable]) {
        $orderedItems = @(Sort-Ordinal @($Value) {
                param($item)
                ConvertTo-Json (Get-DerivedAliasSortValue $item "$Path[]") -Depth 100 -Compress
            })
        foreach ($item in $orderedItems) { Register-DerivedAliases $item "$Path[]" }
    }
}

function Convert-Value {
    param($Value, [string]$Path = '$')
    if ($Value -is [string]) {
        $text = [string]$Value
        if ($derivedAliases.ContainsKey($text)) { return $derivedAliases[$text] }
        for ($index = 0; $index -lt @($OperationalRoot).Count; $index++) {
            $root = [IO.Path]::GetFullPath([string]$OperationalRoot[$index]).TrimEnd('\', '/')
            $text = $text.Replace($root, ('$OPERATIONAL_ROOT_' + $index), [StringComparison]::OrdinalIgnoreCase)
            $text = $text.Replace($root.Replace('\', '/'), ('$OPERATIONAL_ROOT_' + $index), [StringComparison]::OrdinalIgnoreCase)
        }
        foreach ($rawAlias in @($derivedAliases.Keys | Sort-Object Length -Descending)) {
            $text = $text.Replace(
                [string]$rawAlias,
                [string]$derivedAliases[[string]$rawAlias],
                [StringComparison]::Ordinal)
        }
        if ($Path -cmatch '(?i)\.(?:artifactPath|previewPath|markdownPath|inputArtifactPath|specialistArtifactPath)$') {
            $text = [regex]::Replace(
                $text,
                '-\d{8}T\d{6}Z(?:-[0-9a-f]{8,})?(?=\.(?:json|md)(?:\z|["''\s]))',
                '-$OPERATIONAL_ARTIFACT',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $text = [regex]::Replace(
                $text,
                '-[0-9a-f]{16,}(?=\.json(?:\z|["''\s]))',
                '-$OPERATIONAL_ARTIFACT',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        $trimmed = $text.Trim()
        if (($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) -or
            ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
            try {
                return Convert-Value ($trimmed | ConvertFrom-Json -Depth 100) "$Path<json>"
            }
            catch {}
        }
        return $text
    }
    if ($null -eq $Value -or $Value -is [bool] -or
        $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return $Value }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime().ToString('o') }
    if ($Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in @(Sort-Ordinal @($Value.PSObject.Properties) { param($item) $item.Name })) {
            $excluded = $false
            foreach ($pattern in @($contract.excludedKeyPatterns)) {
                if ($property.Name -cmatch [string]$pattern) { $excluded = $true; break }
            }
            if (-not $excluded) { $result[$property.Name] = Convert-Value $property.Value "$Path.$($property.Name)" }
        }
        return [pscustomobject]$result
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { Convert-Value $_ "$Path[]" })
        $isSet = @($contract.setArrayPaths) -ccontains $Path
        foreach ($pattern in @($contract.setArrayPathPatterns)) {
            if ($Path -cmatch [string]$pattern) { $isSet = $true; break }
        }
        if ($isSet) {
            return ,@(Sort-Ordinal $items { param($item) ConvertTo-Json $item -Depth 100 -Compress })
        }
        return ,$items
    }
    throw "Unsupported value type '$($Value.GetType().FullName)' at $Path."
}

Add-DerivedValues $document
Register-DerivedAliases $document
$normalized = Convert-Value $document
$json = ConvertTo-Json $normalized -Depth 100 -Compress
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
$digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
if ($HashOnly) { $digest }
else {
    [pscustomobject][ordered]@{
        schemaVersion = 1
        contract = [string]$contract.kind
        semanticSha256 = $digest
        decision = $normalized
    } | ConvertTo-Json -Depth 100 -Compress
}
