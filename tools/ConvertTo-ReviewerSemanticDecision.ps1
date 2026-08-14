#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline)][string]$InputPath,
    [string]$ContractPath = (Join-Path $PSScriptRoot 'testdata\reviewer-semantic-normalization-contract.v1.json'),
    [switch]$HashOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$contract = Get-Content -LiteralPath $ContractPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
$document = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100

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

function Convert-Value {
    param($Value, [string]$Path = '$')
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or
        $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return $Value }
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
        if (@($contract.setArrayPaths) -ccontains $Path) {
            return ,@(Sort-Ordinal $items { param($item) ConvertTo-Json $item -Depth 100 -Compress })
        }
        return ,$items
    }
    throw "Unsupported value type '$($Value.GetType().FullName)' at $Path."
}

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
