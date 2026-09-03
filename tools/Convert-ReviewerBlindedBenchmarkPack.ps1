#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Materializes one legacy blinded benchmark projection into an acquisition bundle.

.DESCRIPTION
    Converts only a schema-valid legacy blinded projection and an exact role
    provenance document already sealed by that projection. Replay, config and
    prompt bytes must be independently supplied and digest-pinned. The tool never
    reconstructs missing content, reads a live host, launches a model, or accepts
    oracle/expected-decision material.

    Publication is staged, production-loader validated, recursively inventoried,
    marked read-only, and atomically renamed into place. -VerifyOnly is read-only.
#>
[CmdletBinding(DefaultParameterSetName = 'Materialize')]
param(
    [Parameter(ParameterSetName = 'Materialize', Mandatory)][string]$PackRoot,
    [Parameter(ParameterSetName = 'Materialize', Mandatory)][string]$LegacyProjectionFile,
    [Parameter(ParameterSetName = 'Materialize', Mandatory)]
    [ValidateSet('generalist', 'specialist', 'verifier')][string]$Role,
    [Parameter(ParameterSetName = 'Materialize', Mandatory)][string]$RoleProvenanceFile,
    [Parameter(ParameterSetName = 'Materialize', Mandatory)][string]$ReplaySnapshotPath,
    [Parameter(ParameterSetName = 'Materialize', Mandatory)][string]$ConfigFile,
    [Parameter(ParameterSetName = 'Materialize', Mandatory)][string]$PromptFile,
    [Parameter(ParameterSetName = 'Materialize', Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedReplayManifestFileSha256,
    [Parameter(ParameterSetName = 'Materialize', Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedConfigSha256,
    [Parameter(ParameterSetName = 'Materialize', Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedPromptSha256,
    [Parameter(ParameterSetName = 'Materialize', Mandatory)]
    [string]$SecondGeneralistModel,
    [Parameter(ParameterSetName = 'Materialize')]
    [string]$ConventionSpecialistModel,
    [Parameter(ParameterSetName = 'Materialize')]
    [string]$ReviewerScriptFile,
    [Parameter(ParameterSetName = 'Materialize')]
    [switch]$PreserveSourceClassification,
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(ParameterSetName = 'Verify', Mandatory)][switch]$VerifyOnly,
    [Parameter(ParameterSetName = 'Verify', Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedTransformationManifestSha256,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Utf8 = [Text.UTF8Encoding]::new($false, $true)
$SchemaDir = Join-Path $RepoRoot 'src\Agents\reviewer\acquisition\v1'
$HarnessModule = Join-Path $RepoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'
$MaxDeclaredResourceBytes = 1GB
Import-Module $HarnessModule -Force -ErrorAction Stop

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Utf8.GetBytes($Text))).ToLowerInvariant()
}

function Get-BytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-CanonicalJson {
    param([Parameter(Mandatory)]$Value)
    return (ConvertTo-AgentReplayCanonicalJson -Value $Value)
}

function Assert-Schema {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Surface)
    $errors = $null
    if (-not (Test-Json -Json $Text -SchemaFile (Join-Path $SchemaDir $Name) -ErrorVariable errors -ErrorAction SilentlyContinue)) {
        $detail = if ($errors) { ': ' + (($errors | ForEach-Object { $_.ToString() }) -join '; ') } else { '' }
        throw "$Surface failed schema '$Name'$detail"
    }
}

function Get-ForbiddenHits {
    param([AllowNull()]$Node, [string]$Path = '$', [int]$Depth = 0)
    if ($Depth -gt 64) { throw 'Oracle scan exceeded depth 64.' }
    $hits = [Collections.Generic.List[string]]::new()
    $denied = @('oracle', 'expected', 'groundtruth', 'ground_truth', 'answerkey', 'adjudication',
        'golden', 'verdicttruth', 'correctness', 'deliveryeligibility', 'truth', 'decision', 'label', 'labels')
    $properties = @()
    if ($Node -is [Collections.IDictionary]) {
        $properties = @($Node.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $Node[$_] } })
    }
    elseif ($Node -is [Management.Automation.PSCustomObject]) {
        $properties = @($Node.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } })
    }
    foreach ($property in $properties) {
        $normalized = $property.Name.ToLowerInvariant() -replace '[^a-z0-9_]', ''
        foreach ($term in $denied) {
            if ($normalized.Contains($term)) { [void]$hits.Add("$Path.$($property.Name)"); break }
        }
        foreach ($hit in @(Get-ForbiddenHits -Node $property.Value -Path "$Path.$($property.Name)" -Depth ($Depth + 1))) {
            [void]$hits.Add($hit)
        }
    }
    if ($Node -isnot [string] -and $Node -is [Collections.IEnumerable] -and
        $Node -isnot [Collections.IDictionary] -and $Node -isnot [Management.Automation.PSCustomObject]) {
        $index = 0
        foreach ($item in $Node) {
            foreach ($hit in @(Get-ForbiddenHits -Node $item -Path "$Path[$index]" -Depth ($Depth + 1))) {
                [void]$hits.Add($hit)
            }
            $index++
        }
    }
    return $hits.ToArray()
}

function Assert-OracleFree {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Surface)
    $hits = @(Get-ForbiddenHits -Node $Value)
    if ($hits.Count -gt 0) {
        throw "$Surface contains forbidden oracle/expected material: $($hits -join ', ')."
    }
}

function Assert-SafeRelativePath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Surface)
    if ([IO.Path]::IsPathRooted($Path) -or $Path -match '(^|[\\/])\.\.([\\/]|$)' -or $Path -match '(^|[\\/])\.([\\/]|$)') {
        throw "$Surface path '$Path' is rooted, aliased, or traverses outside its root."
    }
    $segments = @($Path -split '[\\/]')
    if ($segments.Count -eq 0 -or @($segments | Where-Object { -not $_ }).Count -gt 0) {
        throw "$Surface path '$Path' contains an empty segment."
    }
    foreach ($segment in $segments) {
        if ($segment -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw "$Surface path '$Path' contains a non-portable or alias-capable segment '$segment'."
        }
        $name = $segment.ToLowerInvariant() -replace '[^a-z0-9]', ''
        if ($name -match 'oracle|expected|groundtruth|answerkey|adjudication|golden') {
            throw "$Surface path '$Path' contains a forbidden oracle/expected segment."
        }
    }
    return ($segments -join '/')
}

function Assert-NoAlternateDataStreams {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Surface)
    if (-not [OperatingSystem]::IsWindows()) { return }
    $streamPath = if ($Path.StartsWith('\\')) { '\\?\UNC\' + $Path.TrimStart('\') } else { '\\?\' + $Path }
    try {
        $alternateStreams = @(Get-Item -LiteralPath $streamPath -Stream * -ErrorAction Stop |
            Where-Object { [string]$_.Stream -cne ':$DATA' })
    }
    catch { throw "$Surface '$Path' could not be inspected for alternate data streams: $($_.Exception.Message)" }
    if ($alternateStreams.Count -gt 0) {
        throw "$Surface '$Path' contains alternate data stream(s): $($alternateStreams.Stream -join ', ')."
    }
}

function Resolve-SafeFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Within, [Parameter(Mandatory)][string]$Surface)
    $root = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Within).Path).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Surface '$full' is outside '$root'."
    }
    $cursor = $full
    while ($cursor.Length -gt $root.Length) {
        $item = Get-Item -LiteralPath $cursor -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Surface '$full' crosses reparse point '$cursor'."
        }
        $cursor = Split-Path $cursor -Parent
    }
    Assert-NoAlternateDataStreams -Path $full -Surface $Surface
    return $full
}

function Set-ReadOnlyTree {
    param([Parameter(Mandatory)][string]$Root)
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force)) {
        $file.Attributes = $file.Attributes -bor [IO.FileAttributes]::ReadOnly
        if (((Get-Item -LiteralPath $file.FullName -Force).Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) {
            throw "Could not mark '$($file.FullName)' read-only."
        }
    }
}

function New-Inventory {
    param([Parameter(Mandatory)][string]$Root, [string[]]$Exclude = @())
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $items = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Inventory rejects reparse-point file '$($file.FullName)'."
        }
        Assert-NoAlternateDataStreams -Path $file.FullName -Surface 'Inventory file'
        $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
        if ($Exclude -contains $relative) { continue }
        [void]$items.Add([ordered]@{ path = $relative; sha256 = Get-FileSha256 $file.FullName; byteLength = [long]$file.Length })
    }
    return , $items.ToArray()
}

function New-DirectoryInventory {
    param([Parameter(Mandatory)][string]$Root)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $items = [Collections.Generic.List[object]]::new()
    foreach ($directory in @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force | Sort-Object FullName)) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Inventory rejects reparse-point directory '$($directory.FullName)'."
        }
        if (@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0) {
            throw "Inventory rejects empty directory '$($directory.FullName)'."
        }
        $relative = $directory.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
        [void]$items.Add([ordered]@{ path = $relative })
    }
    return , $items.ToArray()
}

function Test-SpecialistBindingShape {
    param([Parameter(Mandatory)]$Enabled, [AllowNull()]$Model)
    if ($Enabled -isnot [bool]) { return $false }
    if ([bool]$Enabled) {
        return ($Model -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$Model))
    }
    return $null -eq $Model
}

function Test-Bundle {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$ExpectedManifestSha256)
    $problems = [Collections.Generic.List[string]]::new()
    $manifestPath = Join-Path $Root 'transformation-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return @('missing transformation-manifest.json') }
    if ((Get-FileSha256 $manifestPath) -cne $ExpectedManifestSha256.ToLowerInvariant()) {
        [void]$problems.Add('transformation manifest SHA-256 differs from the pinned digest')
    }
    try {
        $text = [IO.File]::ReadAllText($manifestPath, $Utf8)
        $manifest = $text | ConvertFrom-Json -AsHashtable -Depth 64
        if (-not (Test-SpecialistBindingShape `
                -Enabled $manifest.source.conventionSpecialistEnabled `
                -Model $manifest.source.conventionSpecialistModel) -or
            -not (Test-SpecialistBindingShape `
                -Enabled $manifest.output.conventionSpecialistEnabled `
                -Model $manifest.output.conventionSpecialistModel) -or
            $manifest.source.conventionSpecialistEnabled -cne
                $manifest.output.conventionSpecialistEnabled -or
            $manifest.source.conventionSpecialistModel -cne
                $manifest.output.conventionSpecialistModel) {
            [void]$problems.Add('transformation manifest convention specialist binding mismatch')
        }
        $withoutDigest = [ordered]@{}
        foreach ($key in $manifest.Keys) { if ($key -cne 'manifestDigest') { $withoutDigest[$key] = $manifest[$key] } }
        if ([string]$manifest.manifestDigest -cne (Get-TextSha256 (Get-CanonicalJson $withoutDigest))) {
            [void]$problems.Add('transformation manifest digest mismatch')
        }
        $bound = @{}
        foreach ($entry in @($manifest.files)) {
            $relative = [string]$entry.path
            try { [void](Assert-SafeRelativePath -Path $relative -Surface 'Bound bundle') }
            catch { [void]$problems.Add($_.Exception.Message); continue }
            if ($bound.ContainsKey($relative)) { [void]$problems.Add("duplicate bound file: $relative"); continue }
            $bound[$relative] = $entry
            $filePath = Join-Path $Root ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { [void]$problems.Add("missing bound file: $relative"); continue }
            try { Assert-NoAlternateDataStreams -Path $filePath -Surface 'Bound bundle file' }
            catch { [void]$problems.Add($_.Exception.Message) }
            if ((Get-FileSha256 $filePath) -cne [string]$entry.sha256) { [void]$problems.Add("SHA-256 mismatch: $relative") }
            if ([long](Get-Item -LiteralPath $filePath -Force).Length -ne [long]$entry.byteLength) { [void]$problems.Add("length mismatch: $relative") }
        }
        $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
        foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force)) {
            $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { [void]$problems.Add("reparse-point file: $relative") }
            try { Assert-NoAlternateDataStreams -Path $file.FullName -Surface 'Bundle file' }
            catch { [void]$problems.Add($_.Exception.Message) }
            if (($file.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) { [void]$problems.Add("writable file: $relative") }
            if ($relative -cne 'transformation-manifest.json' -and -not $bound.ContainsKey($relative)) {
                [void]$problems.Add("extra unbound file: $relative")
            }
        }
        $boundDirectories = @{}
        foreach ($entry in @($manifest.directories)) {
            $relative = [string]$entry.path
            try { [void](Assert-SafeRelativePath -Path $relative -Surface 'Bound bundle directory') }
            catch { [void]$problems.Add($_.Exception.Message); continue }
            if ($boundDirectories.ContainsKey($relative)) { [void]$problems.Add("duplicate bound directory: $relative"); continue }
            $boundDirectories[$relative] = $true
            $directoryPath = Join-Path $Root ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
                [void]$problems.Add("missing bound directory: $relative")
            }
        }
        foreach ($directory in @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force)) {
            $relative = $directory.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
            if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                [void]$problems.Add("reparse-point directory: $relative")
            }
            elseif (-not $boundDirectories.ContainsKey($relative)) {
                [void]$problems.Add("extra unbound directory: $relative")
            }
            if (@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0) {
                [void]$problems.Add("empty directory: $relative")
            }
        }
        $projectionPath = Join-Path $Root 'projection.json'
        $projectionText = [IO.File]::ReadAllText($projectionPath, $Utf8)
        Assert-Schema -Text $projectionText -Name 'fixture-projection.schema.json' -Surface 'Materialized projection'
        Assert-OracleFree -Value ($projectionText | ConvertFrom-Json -Depth 64) -Surface 'Materialized projection'
        $replayRoot = Join-Path $Root 'replay'
        $snapshot = New-AgentReplaySnapshot -ReplayRoot $replayRoot -SnapshotName ([string]$manifest.output.snapshotName) `
            -ExpectedManifestDigest ([string]$manifest.output.replayManifestDigest)
        if (-not [bool]$snapshot.Classification.NonPromotable) {
            [void]$problems.Add('materialized replay is not classified non-promotable')
        }
        if ([string]$snapshot.Classification.SealKind -ceq 'benchmarkPackMaterialization') {
            $sidecar = $snapshot.Classification.Sidecar
            if (-not $sidecar.PSObject.Properties['conventionSpecialistEnabled'] -or
                -not $sidecar.PSObject.Properties['conventionSpecialistModel'] -or
                -not (Test-SpecialistBindingShape `
                    -Enabled $sidecar.conventionSpecialistEnabled `
                    -Model $sidecar.conventionSpecialistModel) -or
                $sidecar.conventionSpecialistEnabled -cne
                    $manifest.output.conventionSpecialistEnabled -or
                $sidecar.conventionSpecialistModel -cne
                    $manifest.output.conventionSpecialistModel) {
                [void]$problems.Add('materialization sidecar convention specialist binding mismatch')
            }
        }
        else {
            $requiredModels = @([string]$manifest.output.secondGeneralistModel)
            if ([bool]$manifest.output.conventionSpecialistEnabled) {
                $requiredModels += [string]$manifest.output.conventionSpecialistModel
            }
            foreach ($requiredModel in $requiredModels) {
                if (@($snapshot.Bindings.Models) -cnotcontains $requiredModel) {
                    [void]$problems.Add("preserved replay does not bind required model '$requiredModel'")
                }
            }
        }
    }
    catch { [void]$problems.Add($_.Exception.Message) }
    return $problems.ToArray()
}

$outputFull = [IO.Path]::GetFullPath($OutputRoot)
if ($VerifyOnly) {
    $verifyProblems = @(Test-Bundle -Root $outputFull -ExpectedManifestSha256 $ExpectedTransformationManifestSha256)
    if ($verifyProblems.Count -gt 0) { throw "Bundle verification failed: $($verifyProblems -join '; ')" }
    Write-Output (Get-Content -LiteralPath (Join-Path $outputFull 'transformation-manifest.json') -Raw -Encoding UTF8)
    exit 0
}

foreach ($path in @($PackRoot, $LegacyProjectionFile, $RoleProvenanceFile, $ReplaySnapshotPath, $ConfigFile, $PromptFile, $HarnessModule)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input '$path' does not exist." }
}
if (-not $ReviewerScriptFile) { $ReviewerScriptFile = Join-Path $RepoRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1' }
if (-not (Test-Path -LiteralPath $ReviewerScriptFile -PathType Leaf)) { throw "Reviewer script '$ReviewerScriptFile' does not exist." }

$packFull = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $PackRoot).Path)
$legacyFull = Resolve-SafeFile -Path $LegacyProjectionFile -Within $packFull -Surface 'Legacy projection'
$legacyBytes = [IO.File]::ReadAllBytes($legacyFull)
$legacyText = $Utf8.GetString($legacyBytes)
$legacySha = Get-BytesSha256 $legacyBytes
Assert-Schema -Text $legacyText -Name 'legacy-benchmark-projection.schema.json' -Surface 'Legacy projection'
$legacy = $legacyText | ConvertFrom-Json -AsHashtable -Depth 64
Assert-OracleFree -Value $legacy -Surface 'Legacy projection'
if ((Get-TextSha256 (Get-CanonicalJson $legacy.binding)) -cne [string]$legacy.bindingSha256) {
    throw 'Legacy projection bindingSha256 does not match its canonical binding.'
}

$resourceByPath = @{}
$replayResources = [Collections.Generic.List[object]]::new()
$roleProvenanceResources = [Collections.Generic.List[object]]::new()
$declaredResourceBytes = [long]0
foreach ($resource in @($legacy.resources)) { $declaredResourceBytes += [long]$resource.byteLength }
if ($declaredResourceBytes -gt $MaxDeclaredResourceBytes) {
    throw "Legacy projection declares $declaredResourceBytes resource bytes, exceeding the $MaxDeclaredResourceBytes-byte materialization limit."
}
foreach ($resource in @($legacy.resources)) {
    $relative = Assert-SafeRelativePath -Path ([string]$resource.sealedPath) -Surface 'Sealed resource'
    if (-not $relative.StartsWith('sealed-resources/', [StringComparison]::Ordinal)) {
        throw "Sealed resource '$relative' is not under sealed-resources/."
    }
    if ($resourceByPath.ContainsKey($relative)) { throw "Legacy projection repeats sealed resource '$relative'." }
    $resourcePath = Resolve-SafeFile -Path (Join-Path $packFull ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)) `
        -Within $packFull -Surface 'Sealed resource'
    $leaf = Split-Path $resourcePath -Leaf
    if (-not $leaf.StartsWith(([string]$resource.sha256 + '-'), [StringComparison]::Ordinal)) {
        throw "Sealed resource '$relative' is not hash-named with its declared SHA-256."
    }
    $resourceItem = Get-Item -LiteralPath $resourcePath -Force
    if ((Get-FileSha256 $resourcePath) -cne [string]$resource.sha256 -or
        [long]$resourceItem.Length -ne [long]$resource.byteLength) {
        throw "Sealed resource '$relative' fails its SHA-256/length binding."
    }
    $resourceByPath[$relative] = [pscustomobject]@{
        Declaration = $resource
        FullPath = $resourcePath
    }
    if ([string]$resource.mediaRole -ceq 'replay-manifest') { [void]$replayResources.Add($resource) }
    if ([string]$resource.mediaRole -ceq "role-provenance-$Role") {
        [void]$roleProvenanceResources.Add($resource)
    }
}
if ($replayResources.Count -ne 1) { throw "Legacy projection must seal exactly one replay-manifest resource; found $($replayResources.Count)." }
if ($roleProvenanceResources.Count -ne 1) {
    throw "Legacy projection must seal exactly one role-provenance-$Role resource; found $($roleProvenanceResources.Count)."
}

$provenanceFull = Resolve-SafeFile -Path $RoleProvenanceFile -Within $packFull -Surface 'Role provenance'
$provenanceRelative = [IO.Path]::GetRelativePath($packFull, $provenanceFull).Replace('\', '/')
if (-not $resourceByPath.ContainsKey($provenanceRelative)) {
    throw "Role provenance '$provenanceRelative' is not a resource sealed by the legacy projection."
}
$provenanceDeclaration = $resourceByPath[$provenanceRelative].Declaration
if ([string]$roleProvenanceResources[0].sealedPath -cne $provenanceRelative) {
    throw "Supplied role provenance '$provenanceRelative' is not the projection's unique role-provenance-$Role resource."
}
if ([string]$provenanceDeclaration.mediaRole -cne "role-provenance-$Role") {
    throw "Role provenance resource mediaRole '$([string]$provenanceDeclaration.mediaRole)' is not 'role-provenance-$Role'."
}
$provenanceBytes = [IO.File]::ReadAllBytes([string]$resourceByPath[$provenanceRelative].FullPath)
if ((Get-BytesSha256 $provenanceBytes) -cne [string]$provenanceDeclaration.sha256 -or
    [long]$provenanceBytes.Length -ne [long]$provenanceDeclaration.byteLength) {
    throw 'Role provenance changed after sealed-resource validation.'
}
$provenanceText = $Utf8.GetString($provenanceBytes)
$provenanceSha = Get-BytesSha256 $provenanceBytes
Assert-Schema -Text $provenanceText -Name 'role-provenance.schema.json' -Surface 'Role provenance'
$provenance = $provenanceText | ConvertFrom-Json -AsHashtable -Depth 64
Assert-OracleFree -Value $provenance -Surface 'Role provenance'
if ($Role -ceq 'specialist') {
    foreach ($name in @('conventionPlanJson', 'factPlanJson')) {
        if (-not $provenance.context.ContainsKey($name) -or
            [string]::IsNullOrWhiteSpace([string]$provenance.context[$name])) { continue }
        try { $decodedRoleJson = ([string]$provenance.context[$name]) | ConvertFrom-Json -AsHashtable -Depth 64 -ErrorAction Stop }
        catch { throw "Role provenance context.$name is not valid JSON." }
        Assert-OracleFree -Value $decodedRoleJson -Surface "Role provenance context.$name decoded JSON"
    }
}
if ([string]$provenance.fixtureId -cne [string]$legacy.fixtureId -or
    [string]$provenance.role -cne $Role -or
    [string]$provenance.bindingSha256 -cne [string]$legacy.bindingSha256) {
    throw 'Role provenance does not exactly bind the legacy fixture, role, and binding.'
}

$snapshotFull = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ReplaySnapshotPath).Path)
$snapshotName = Split-Path $snapshotFull -Leaf
$sourceReplayRoot = Split-Path $snapshotFull -Parent
$sourceManifestPath = Join-Path $snapshotFull 'manifest.json'
Assert-NoAlternateDataStreams -Path $sourceManifestPath -Surface 'Independent replay manifest'
$sourceManifestBytes = [IO.File]::ReadAllBytes($sourceManifestPath)
$sourceManifestText = $Utf8.GetString($sourceManifestBytes)
$sourceManifestFileSha = Get-BytesSha256 $sourceManifestBytes
$replayDeclaration = $replayResources[0]
if ($sourceManifestFileSha -cne $ExpectedReplayManifestFileSha256.ToLowerInvariant() -or
    $sourceManifestFileSha -cne [string]$replayDeclaration.sha256 -or
    [long]$sourceManifestBytes.Length -ne [long]$replayDeclaration.byteLength) {
    throw 'Independent replay manifest does not equal the projection-sealed and operator-pinned manifest bytes.'
}
$pinnedSourceManifest = $sourceManifestText | ConvertFrom-Json -AsHashtable -Depth 64
$sourceSnapshot = New-AgentReplaySnapshot -ReplayRoot $sourceReplayRoot -SnapshotName $snapshotName `
    -ExpectedManifestDigest ([string]$pinnedSourceManifest.manifestDigest)
$sourceManifestAfterLoad = [IO.File]::ReadAllBytes($sourceManifestPath)
if ([long]$sourceManifestAfterLoad.Length -ne [long]$sourceManifestBytes.Length -or
    (Get-BytesSha256 $sourceManifestAfterLoad) -cne $sourceManifestFileSha) {
    throw 'Independent replay manifest changed during production-loader validation.'
}
if ([bool]$sourceSnapshot.Classification.NonPromotable -and -not $PreserveSourceClassification) {
    throw "The source replay is already classified '$([string]$sourceSnapshot.Classification.SealKind)'; materialization will not replace existing non-promotable lineage."
}
if ($PreserveSourceClassification -and -not [bool]$sourceSnapshot.Classification.NonPromotable) {
    throw '-PreserveSourceClassification requires an already non-promotable source replay.'
}
$generalistPair = Get-AgentGeneralistModelPair
[void](Assert-AgentSupportedModel -ModelId $SecondGeneralistModel `
        -Where 'benchmark materialization second generalist model')
if (@($generalistPair.Models) -cnotcontains $SecondGeneralistModel) {
    throw ("Benchmark materialization requires one member of the current configured " +
        "generalist pair: $($generalistPair.First) and $($generalistPair.Second).")
}
$pairedGeneralistModel = @($generalistPair.Models | Where-Object {
        [string]$_ -cne [string]$SecondGeneralistModel
    })[0]
if (@($sourceSnapshot.Bindings.Models) -cnotcontains $pairedGeneralistModel) {
    throw "The source replay does not bind the paired generalist '$pairedGeneralistModel'."
}

$replayBinding = $sourceSnapshot.Binding
$legacyBinding = $legacy.binding
if ([int]$legacyBinding.pr -ne [int]$replayBinding.PullRequestId -or
    [string]$legacyBinding.repositoryId -cne [string]$replayBinding.RepositoryId -or
    ([string]$legacyBinding.source).ToLowerInvariant() -cne [string]$replayBinding.SourceCommit -or
    ([string]$legacyBinding.target).ToLowerInvariant() -cne [string]$replayBinding.TargetCommit) {
    throw 'Independent replay binding does not exactly match the legacy projection identity.'
}
if ($sourceSnapshot.SchemaVersion -eq 2 -and
    (([int]$legacyBinding.iteration -ne [int]$replayBinding.IterationId -or
        ([string]$legacyBinding.common).ToLowerInvariant() -cne [string]$replayBinding.CommonCommit))) {
    throw 'Independent replay iteration/common binding does not exactly match the legacy projection.'
}

$configFull = (Resolve-Path -LiteralPath $ConfigFile).Path
$promptFull = (Resolve-Path -LiteralPath $PromptFile).Path
$scriptFull = (Resolve-Path -LiteralPath $ReviewerScriptFile).Path
Assert-NoAlternateDataStreams -Path $configFull -Surface 'Config'
Assert-NoAlternateDataStreams -Path $promptFull -Surface 'Prompt'
Assert-NoAlternateDataStreams -Path $scriptFull -Surface 'Reviewer script'
$configStream = [IO.File]::Open(
    $configFull, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $configBytes = [byte[]]::new($configStream.Length)
    $configOffset = 0
    while ($configOffset -lt $configBytes.Length) {
        $configRead = $configStream.Read(
            $configBytes, $configOffset, $configBytes.Length - $configOffset)
        if ($configRead -le 0) {
            throw 'Config changed or became unreadable while acquiring its immutable byte snapshot.'
        }
        $configOffset += $configRead
    }
    $configLoad = Get-AgentConfig -Path $configFull -AgentDir (Split-Path $scriptFull -Parent) `
        -SupportedSchemaVersions @(1) -PromptFileField 'promptFile'
}
finally {
    $configStream.Dispose()
}
$promptBytes = [IO.File]::ReadAllBytes($promptFull)
$scriptBytes = [IO.File]::ReadAllBytes($scriptFull)
$configSha = Get-BytesSha256 $configBytes
$promptSha = Get-BytesSha256 $promptBytes
$scriptSha = Get-BytesSha256 $scriptBytes
if ($configSha -cne $ExpectedConfigSha256.ToLowerInvariant()) { throw 'Config does not match -ExpectedConfigSha256.' }
if ($promptSha -cne $ExpectedPromptSha256.ToLowerInvariant()) { throw 'Prompt does not match -ExpectedPromptSha256.' }
if ([string]$provenance.configSha256 -cne $configSha -or
    [string]$provenance.promptSha256 -cne $promptSha -or
    [string]$provenance.scriptSha256 -cne $scriptSha) {
    throw 'Projection-sealed role provenance does not exactly bind the supplied config, prompt, and reviewer script.'
}
foreach ($bindingCheck in @(
        @{ Name = 'config'; Recorded = [string]$sourceSnapshot.Bindings.ConfigSha256; Actual = $configSha },
        @{ Name = 'prompt'; Recorded = [string]$sourceSnapshot.Bindings.PromptSha256; Actual = $promptSha },
        @{ Name = 'script'; Recorded = [string]$sourceSnapshot.Bindings.ScriptSha256; Actual = $scriptSha })) {
    if ($bindingCheck.Recorded -cne ('0' * 64) -and $bindingCheck.Recorded -cne $bindingCheck.Actual) {
        throw "Independent $($bindingCheck.Name) bytes do not match the replay manifest binding."
    }
}
$config = $configLoad.Raw
$configuredConventionSpecialistModel = ''
$configVerificationEnabled = $false
if ($config.PSObject.Properties.Name -ccontains 'review') {
    $configReview = $config.review
    if ($configReview.PSObject.Properties.Name -ccontains 'conventionSpecialistModel') {
        if ($configReview.conventionSpecialistModel -isnot [string]) {
            throw "review.conventionSpecialistModel must be a string when configured."
        }
        $configuredConventionSpecialistModel = [string]$configReview.conventionSpecialistModel
    }
    if ($configReview.PSObject.Properties.Name -ccontains 'verification' -and
        $configReview.verification.PSObject.Properties.Name -ccontains 'enabled') {
        if ($configReview.verification.enabled -isnot [bool]) {
            throw "review.verification.enabled must be a JSON boolean."
        }
        $configVerificationEnabled = [bool]$configReview.verification.enabled
    }
}
$conventionSpecialistEnabled = (
    $Role -cne 'generalist' -or
    $configVerificationEnabled -or
    [bool]$ConventionSpecialistModel)
$effectiveConventionSpecialistModel = $null
if ($conventionSpecialistEnabled) {
    $effectiveConventionSpecialistModel = if ($ConventionSpecialistModel) {
        $ConventionSpecialistModel
    }
    else {
        $configuredConventionSpecialistModel
    }
    if (-not $effectiveConventionSpecialistModel) {
        throw ("A $Role benchmark materialization with verification/convention specialist enabled " +
            'requires an explicit -ConventionSpecialistModel or config.review.conventionSpecialistModel.')
    }
    [void](Assert-AgentSupportedModel -ModelId $effectiveConventionSpecialistModel `
            -Where 'benchmark materialization convention specialist model')
}
if ($PreserveSourceClassification) {
    foreach ($requiredModel in @($SecondGeneralistModel, $effectiveConventionSpecialistModel)) {
        if ($requiredModel -and @($sourceSnapshot.Bindings.Models) -cnotcontains $requiredModel) {
            throw "Preserved source replay does not bind required model '$requiredModel'; its classification cannot be rewritten to add it."
        }
    }
}
$resolvedPromptFull = [IO.Path]::GetFullPath([string]$configLoad.PromptFilePath)
if ($resolvedPromptFull -cne [IO.Path]::GetFullPath($promptFull)) {
    throw "Config promptFile resolves to '$resolvedPromptFull', not the independently supplied prompt '$promptFull'."
}
$promptRelative = Assert-SafeRelativePath -Path ([string]$config.promptFile) -Surface 'Config promptFile'
if ($promptRelative -ceq 'reviewer.config.json') {
    throw "Config promptFile '$promptRelative' collides with the materialized config path."
}

$context = $provenance.context
$projection = [ordered]@{
    schemaVersion = 1
    kind = 'reviewer-blinded-fixture-projection'
    fixtureId = [string]$legacy.fixtureId
    role = $Role
    binding = [ordered]@{
        prId = [int]$replayBinding.PullRequestId
        repositoryId = [string]$replayBinding.RepositoryId
        project = [string]$replayBinding.Project
        sourceCommit = [string]$replayBinding.SourceCommit
        targetCommit = [string]$replayBinding.TargetCommit
        changeSetDigest = [string]$replayBinding.ChangeSetSha256
    }
}
if ($Role -ceq 'verifier') {
    if (([string]$context.targetCommit).ToLowerInvariant() -cne [string]$replayBinding.TargetCommit -or
        [string]$context.changeSetDigest -cne [string]$replayBinding.ChangeSetSha256 -or
        [string]$context.configSha256 -cne $configSha -or [string]$context.scriptSha256 -cne $scriptSha -or
        [string]$context.promptSha256 -cne $promptSha) {
        throw 'Verifier role provenance does not exactly bind replay/config/script/prompt identities.'
    }
}
$projection[$Role] = $context
$projectionText = ConvertTo-Json -InputObject $projection -Depth 64
Assert-Schema -Text $projectionText -Name 'fixture-projection.schema.json' -Surface 'Materialized projection'
Assert-OracleFree -Value $projection -Surface 'Materialized projection'

$outputParent = Split-Path $outputFull -Parent
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) { throw "Output parent '$outputParent' does not exist." }
if (Test-Path -LiteralPath $outputFull) { throw "Output '$outputFull' already exists; materialization never overwrites." }
$outputLeaf = Split-Path $outputFull -Leaf
$lockHash = (Get-TextSha256 $outputFull).Substring(0, 16)
$lockPath = Join-Path $outputParent ".$outputLeaf.$lockHash.materialize.lock"
$lockStream = $null
try { $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
catch { throw "Materialization lock '$lockPath' already exists; concurrent or repeated publication is refused." }

$staging = Join-Path $outputParent ".$outputLeaf.$([Guid]::NewGuid().ToString('N')).staging"
$published = $false
try {
    New-Item -ItemType Directory -Path $staging | Out-Null
    $projectionPath = Join-Path $staging 'projection.json'
    [IO.File]::WriteAllText($projectionPath, (Get-CanonicalJson $projection), $Utf8)

    $stagedReplayRoot = Join-Path $staging 'replay'
    $stagedSnapshot = Join-Path $stagedReplayRoot $snapshotName
    New-Item -ItemType Directory -Force -Path $stagedSnapshot | Out-Null
    $sourceManifest = $pinnedSourceManifest
    $copyPaths = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $replayExpectations = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($resource in @($sourceManifest.resources)) {
        $relative = Assert-SafeRelativePath ([string]$resource.payloadFile) 'Replay payload'
        if ($copyPaths.ContainsKey($relative) -and $copyPaths[$relative] -cne $relative) {
            throw "Replay payload paths '$($copyPaths[$relative])' and '$relative' are case-aliases."
        }
        $copyPaths[$relative] = $relative
        $expected = [pscustomobject]@{ Sha256 = [string]$resource.payloadSha256; ByteLength = [long]$resource.payloadByteLength }
        if ($replayExpectations.ContainsKey($relative) -and
            ($replayExpectations[$relative].Sha256 -cne $expected.Sha256 -or
                $replayExpectations[$relative].ByteLength -ne $expected.ByteLength)) {
            throw "Replay manifest gives conflicting bindings for shared payload '$relative'."
        }
        $replayExpectations[$relative] = $expected
    }
    if ($sourceManifest.ContainsKey('sourceTransport')) {
        $relative = Assert-SafeRelativePath ([string]$sourceManifest.sourceTransport.artifactFile) 'Source transport'
        if ($copyPaths.ContainsKey($relative) -and $copyPaths[$relative] -cne $relative) {
            throw "Replay paths '$($copyPaths[$relative])' and '$relative' are case-aliases."
        }
        $copyPaths[$relative] = $relative
        $replayExpectations[$relative] = [pscustomobject]@{
            Sha256 = [string]$sourceManifest.sourceTransport.artifactSha256
            ByteLength = [long]$sourceManifest.sourceTransport.artifactByteLength
        }
    }
    if ($PreserveSourceClassification) {
        $sidecarRelative = Assert-SafeRelativePath ([string]$sourceManifest.classification.sidecarFile) `
            'Source replay classification sidecar'
        $copyPaths[$sidecarRelative] = $sidecarRelative
        $sidecarItem = Get-Item -LiteralPath (Join-Path $snapshotFull $sidecarRelative) -ErrorAction Stop
        $replayExpectations[$sidecarRelative] = [pscustomobject]@{
            Sha256 = [string]$sourceManifest.classification.sidecarSha256
            ByteLength = [long]$sidecarItem.Length
        }
    }
    foreach ($relative in $copyPaths.Values) {
        $source = Resolve-SafeFile -Path (Join-Path $snapshotFull ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)) `
            -Within $snapshotFull -Surface 'Replay file'
        $bytes = [IO.File]::ReadAllBytes($source)
        $expected = $replayExpectations[$relative]
        if ((Get-BytesSha256 $bytes) -cne [string]$expected.Sha256 -or
            [long]$bytes.Length -ne [long]$expected.ByteLength) {
            throw "Replay file '$relative' changed after validation or disagrees with the sealed manifest."
        }
        $destination = Join-Path $stagedSnapshot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
        [IO.File]::WriteAllBytes($destination, $bytes)
    }

    if ($PreserveSourceClassification) {
        $materializedDigest = [string]$sourceSnapshot.ManifestDigest
        [IO.File]::WriteAllBytes((Join-Path $stagedSnapshot 'manifest.json'), $sourceManifestBytes)
    }
    else {
        $sidecar = [ordered]@{
            schemaVersion = 1
            kind = 'reviewer-benchmark-pack-materialization'
            sealKind = 'benchmarkPackMaterialization'
            snapshotId = $snapshotName
            nonPromotable = $true
            sourceManifestFileSha256 = $sourceManifestFileSha
            sourceManifestDigest = [string]$sourceSnapshot.ManifestDigest
            legacyProjectionSha256 = $legacySha
            roleProvenanceSha256 = $provenanceSha
            fixtureId = [string]$legacy.fixtureId
            role = $Role
            projectionSha256 = Get-FileSha256 $projectionPath
            configSha256 = $configSha
            promptSha256 = $promptSha
            reviewerScriptSha256 = $scriptSha
            secondGeneralistModel = $SecondGeneralistModel
            conventionSpecialistEnabled = [bool]$conventionSpecialistEnabled
            conventionSpecialistModel = $effectiveConventionSpecialistModel
        }
        $sidecarName = 'benchmark-pack-materialization.json'
        $sidecarPath = Join-Path $stagedSnapshot $sidecarName
        [IO.File]::WriteAllText($sidecarPath, (Get-CanonicalJson $sidecar), $Utf8)
        $sourceManifest.Remove('manifestDigest')
        $sourceManifest.bindings.models = @(
            @($sourceManifest.bindings.models) + $SecondGeneralistModel +
                @($effectiveConventionSpecialistModel) |
                Select-Object -Unique)
        if ([int]$sourceManifest.schemaVersion -eq 1) {
            # Version 3 is the classified counterpart of the v1 shape: it adds only
            # the digest-bound non-promotable classification. Version 2 remains the
            # source-transport shape and is never fabricated when source transport
            # was not independently supplied.
            $sourceManifest.schemaVersion = 3
        }
        $sourceManifest['classification'] = [ordered]@{
            sealKind = 'benchmarkPackMaterialization'
            nonPromotable = $true
            sidecarFile = $sidecarName
            sidecarSha256 = Get-FileSha256 $sidecarPath
        }
        $materializedDigest = Get-TextSha256 (Get-CanonicalJson $sourceManifest)
        $sourceManifest['manifestDigest'] = $materializedDigest
        [IO.File]::WriteAllText((Join-Path $stagedSnapshot 'manifest.json'), (Get-CanonicalJson $sourceManifest), $Utf8)
    }

    $configDestination = Join-Path $staging 'config\reviewer.config.json'
    New-Item -ItemType Directory -Force -Path (Split-Path $configDestination -Parent) | Out-Null
    [IO.File]::WriteAllBytes($configDestination, $configBytes)
    $promptDestination = Join-Path (Join-Path $staging 'prompt') ($promptRelative -replace '/', [IO.Path]::DirectorySeparatorChar)
    New-Item -ItemType Directory -Force -Path (Split-Path $promptDestination -Parent) | Out-Null
    [IO.File]::WriteAllBytes($promptDestination, $promptBytes)

    $loaded = New-AgentReplaySnapshot -ReplayRoot $stagedReplayRoot -SnapshotName $snapshotName `
        -ExpectedManifestDigest $materializedDigest
    $expectedSealKind = if ($PreserveSourceClassification) {
        [string]$sourceSnapshot.Classification.SealKind
    }
    else { 'benchmarkPackMaterialization' }
    if (-not [bool]$loaded.Classification.NonPromotable -or
        [string]$loaded.Classification.SealKind -cne $expectedSealKind) {
        throw 'Production replay loader did not accept the materialized non-promotable classification.'
    }

    $manifestBase = [ordered]@{
        schemaVersion = 1
        kind = 'reviewer-blinded-benchmark-pack-transformation'
        source = [ordered]@{
            fixtureId = [string]$legacy.fixtureId
            legacyProjectionSha256 = $legacySha
            bindingSha256 = [string]$legacy.bindingSha256
            roleProvenanceSha256 = $provenanceSha
            replayManifestFileSha256 = $sourceManifestFileSha
            replayManifestDigest = [string]$sourceSnapshot.ManifestDigest
            configSha256 = $configSha
            promptSha256 = $promptSha
            reviewerScriptSha256 = $scriptSha
            secondGeneralistModel = $SecondGeneralistModel
            conventionSpecialistEnabled = [bool]$conventionSpecialistEnabled
            conventionSpecialistModel = $effectiveConventionSpecialistModel
        }
        output = [ordered]@{
            role = $Role
            secondGeneralistModel = $SecondGeneralistModel
            conventionSpecialistEnabled = [bool]$conventionSpecialistEnabled
            conventionSpecialistModel = $effectiveConventionSpecialistModel
            projectionSha256 = Get-FileSha256 $projectionPath
            snapshotName = $snapshotName
            replayManifestDigest = $materializedDigest
            configPath = 'config/reviewer.config.json'
            promptEvidencePath = "prompt/$promptRelative"
        }
        classification = [ordered]@{
            blinded = $true
            oracleFree = $true
            nonPromotable = $true
            writesPermitted = $false
            reconstructedContent = $false
        }
        files = New-Inventory -Root $staging -Exclude @('transformation-manifest.json')
        directories = New-DirectoryInventory -Root $staging
    }
    $transformation = [ordered]@{}
    foreach ($key in $manifestBase.Keys) { $transformation[$key] = $manifestBase[$key] }
    $transformation['manifestDigest'] = Get-TextSha256 (Get-CanonicalJson $manifestBase)
    $transformationPath = Join-Path $staging 'transformation-manifest.json'
    [IO.File]::WriteAllText($transformationPath, (Get-CanonicalJson $transformation), $Utf8)
    Set-ReadOnlyTree -Root $staging

    $transformationSha = Get-FileSha256 $transformationPath
    $stagedProblems = @(Test-Bundle -Root $staging -ExpectedManifestSha256 $transformationSha)
    if ($stagedProblems.Count -gt 0) { throw "Staged bundle verification failed: $($stagedProblems -join '; ')" }
    if (Test-Path -LiteralPath $outputFull) { throw "Output '$outputFull' appeared before atomic publication." }
    [IO.Directory]::Move($staging, $outputFull)
    $published = $true
    $publishedProblems = @(Test-Bundle -Root $outputFull -ExpectedManifestSha256 $transformationSha)
    if ($publishedProblems.Count -gt 0) { throw "Published bundle verification failed: $($publishedProblems -join '; ')" }
    Write-Output ([ordered]@{
            ready = $true
            bundleRoot = $outputFull
            transformationManifestSha256 = $transformationSha
            projectionFile = (Join-Path $outputFull 'projection.json')
            replayRoot = (Join-Path $outputFull 'replay')
            replaySnapshotName = $snapshotName
            replayManifestDigest = $materializedDigest
            configFile = (Join-Path $outputFull 'config\reviewer.config.json')
            secondGeneralistModel = $SecondGeneralistModel
            conventionSpecialistEnabled = [bool]$conventionSpecialistEnabled
            conventionSpecialistModel = $effectiveConventionSpecialistModel
        } | ConvertTo-Json -Depth 8 -Compress)
}
finally {
    if ($lockStream) { $lockStream.Dispose() }
    if (-not $published -and (Test-Path -LiteralPath $staging)) {
        Get-ChildItem -LiteralPath $staging -File -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Attributes = [IO.FileAttributes]::Normal }
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}
