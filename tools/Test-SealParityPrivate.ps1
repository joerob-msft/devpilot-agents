#!/usr/bin/env pwsh
#requires -Version 7.0
[CmdletBinding()]
param(
    [string[]]$ReplayManifest = @(),
    [string[]]$MaterializationManifest = @(),
    [string[]]$AcquisitionPackage = @(),
    [string]$AcquisitionKeyPath,
    [string[]]$TerminalPackage = @(),
    [string]$TerminalKeyPath,
    [string[]]$CaptureBundle = @(),
    [string]$CaptureKeyPath,
    [string[]]$RunSet = @(),
    [string]$RunSetMasterKeyPath,
    [switch]$ReplayDerivedRunSetKey,
    # Roots to walk for every sealed artifact already sitting on this host. The
    # committed vectors stay employer-neutral, so breadth cannot come from the
    # repository; it can only come from whatever real history the operator
    # already has, which is exactly what this widens the parity check to cover.
    [string[]]$DiscoverRoot = @(),
    [ValidateRange(1, 100000)][int]$DiscoverLimit = 2000
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path $PSScriptRoot -Parent
$project = Join-Path $PSScriptRoot 'SealParity\SealParity.csproj'
$utf8 = [Text.UTF8Encoding]::new($false, $true)

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('seal-parity-private-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tempRoot)
$results = [Collections.Generic.List[object]]::new()
$previousTelemetryPreference = $env:DOTNET_CLI_TELEMETRY_OPTOUT

function Invoke-SealParity {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Request)
    $requestPath = Join-Path $tempRoot ([Guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($requestPath, ($Request | ConvertTo-Json -Depth 10 -Compress), $utf8)
    $output = & dotnet $dll --request $requestPath
    if ($LASTEXITCODE -ne 0) { throw "SealParity rejected a private sample request." }
    return ($output | ConvertFrom-Json)
}

function Add-Result {
    param([string]$Surface, [string[]]$Problems, [string]$Sample = '')
    [void]$results.Add([pscustomobject][ordered]@{
            surface = $Surface
            # Recorded so a divergence can be traced to the artifact that caused
            # it. A failure that only says "one sample diverged" out of dozens is
            # a report nobody can act on.
            sample = $Sample
            status = $(if ($Problems.Count -eq 0) { 'pass' } else { 'fail' })
            divergences = @($Problems)
        })
}

function Test-SelfExcludingManifest {
    param([string]$Path, [string]$Surface)
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $manifest = [IO.File]::ReadAllText($full, $utf8) | ConvertFrom-Json -Depth 64
    $actual = Invoke-SealParity ([ordered]@{
            contractVersion = 'devpilot.seal-parity.v1'
            operation = 'sha256'
            profile = 'replay-v1'
            inputFile = $full
            excludeRootProperties = @('manifestDigest')
        })
    $problems = [Collections.Generic.List[string]]::new()
    if (-not $manifest.PSObject.Properties['manifestDigest']) {
        [void]$problems.Add('manifestDigest: field absent')
    }
    elseif ([string]$actual.sha256 -cne [string]$manifest.manifestDigest) {
        [void]$problems.Add('manifestDigest: replay-v1 self-excluding SHA-256 differs')
    }
    Add-Result -Surface $Surface -Problems $problems.ToArray() -Sample $full
}

function Test-CorpusSealBinding {
    <#
    .SYNOPSIS
        A corpus seal sidecar's own sealDigest, and the manifest binding when it
        carries one.
    .DESCRIPTION
        A seal is not a manifest, so the manifest test cannot be pointed at one.
        Save-CorpusReplaySeal computes sealDigest over the canonical form of the
        seal without sealDigest and then writes the two together, which is the
        same self-excluding shape the manifests use but under a different field.
        Some seals additionally carry manifestDigest, and there it is the digest
        of the sibling manifest rather than of the seal, so that field is checked
        as a binding: given the manifest, does the C# canonicalizer arrive at the
        digest the PowerShell sealer wrote down beside it?
    #>
    param([string]$Path, [string]$Surface)
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $seal = [IO.File]::ReadAllText($full, $utf8) | ConvertFrom-Json -Depth 64
    $problems = [Collections.Generic.List[string]]::new()
    $sealDigest = Invoke-SealParity ([ordered]@{
            contractVersion = 'devpilot.seal-parity.v1'
            operation = 'sha256'
            profile = 'replay-v1'
            inputFile = $full
            excludeRootProperties = @('sealDigest')
        })
    if ([string]$sealDigest.sha256 -cne [string]$seal.sealDigest) {
        [void]$problems.Add('sealDigest: replay-v1 self-excluding SHA-256 differs')
    }
    if ($seal.PSObject.Properties['manifestDigest']) {
        $manifestPath = Join-Path ([IO.Path]::GetDirectoryName($full)) 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            [void]$problems.Add('manifest.json: the seal binds a manifest that is not beside it')
        }
        else {
            $bound = Invoke-SealParity ([ordered]@{
                    contractVersion = 'devpilot.seal-parity.v1'
                    operation = 'sha256'
                    profile = 'replay-v1'
                    inputFile = $manifestPath
                    excludeRootProperties = @('manifestDigest')
                })
            if ([string]$bound.sha256 -cne [string]$seal.manifestDigest) {
                [void]$problems.Add('manifestDigest: the seal does not bind the replay-v1 digest of the manifest beside it')
            }
        }
    }
    Add-Result -Surface $Surface -Problems $problems.ToArray() -Sample $full
}

function Get-SealParityDiscoveredSample {
    <#
    .SYNOPSIS
        Every sealed artifact under the given roots, classified by the shape it
        actually has on disk.
    .DESCRIPTION
        Classification is by content, not by filename: a name is a convention a
        producer may change, whereas the fields a seal must carry to be checkable
        are the seal. Anything that does not carry them is skipped in silence
        rather than reported as a divergence, because a JSON file that is not a
        seal has nothing to diverge from.

        Keyed surfaces are only collected when the operator supplied the matching
        key. Discovering a sealed package whose key is absent and then failing it
        would report a missing key as a canonicalization defect.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Root,
        [Parameter(Mandatory)][int]$Limit
    )

    $found = [ordered]@{
        ReplayManifest = [Collections.Generic.List[string]]::new()
        CorpusSeal = [Collections.Generic.List[string]]::new()
        AcquisitionPackage = [Collections.Generic.List[string]]::new()
        TerminalPackage = [Collections.Generic.List[string]]::new()
        CaptureBundle = [Collections.Generic.List[string]]::new()
        RunSet = [Collections.Generic.List[string]]::new()
        Scanned = 0
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $usable = 0
    foreach ($candidateRoot in $Root) {
        if (-not (Test-Path -LiteralPath $candidateRoot)) { continue }
        $usable++
        $resolved = (Resolve-Path -LiteralPath $candidateRoot).ProviderPath
        foreach ($file in (Get-ChildItem -LiteralPath $resolved -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
            if ($found.Scanned -ge $Limit) { break }
            if (-not $seen.Add($file.FullName)) { continue }
            $found.Scanned++
            # A seal is small. Reading a multi-megabyte payload to discover it is
            # not one wastes the walk on files that cannot qualify.
            if ($file.Length -gt 8mb) { continue }
            $document = $null
            try {
                $document = [IO.File]::ReadAllText($file.FullName, $utf8) | ConvertFrom-Json -Depth 64
            }
            catch {
                # Unreadable or non-UTF8 files are not seals this tool wrote.
                continue
            }
            # A JSON array or scalar deserializes to something that has no named
            # properties at all, and asking one for them under StrictMode throws.
            # A seal is always a JSON object, so anything else is simply not one.
            if ($document -isnot [System.Management.Automation.PSCustomObject]) { continue }
            # Enumerated explicitly rather than through member enumeration on the
            # property collection: an empty JSON object has no properties, and
            # asking an empty collection for .Name throws under StrictMode.
            $names = [Collections.Generic.List[string]]::new()
            foreach ($property in $document.PSObject.Properties) { [void]$names.Add([string]$property.Name) }
            # A seal record carries the digest of something else, so it has to be
            # separated from the manifests before the manifest test claims it. It
            # declares itself: nothing here has to guess from a filename. The kind
            # is read through the collected names because asking a JSON object for
            # a property it does not have throws under StrictMode. A sealDigest is
            # required so that seal *recipes* -- inputs, not sealed artifacts --
            # are not counted as evidence they are not.
            $declaredKind = if ($names -ccontains 'kind') { [string]$document.kind } else { '' }
            if ($names -ccontains 'sealDigest' -and ($names -ccontains 'sealKind' -or $declaredKind -clike '*-seal')) {
                [void]$found.CorpusSeal.Add($file.FullName)
                continue
            }
            if ($names -ccontains 'manifestDigest' -and $names -ccontains 'schemaVersion' -and $names -ccontains 'snapshotId') {
                [void]$found.ReplayManifest.Add($file.FullName)
                continue
            }
            if ($names -ccontains 'manifestJson' -and $names -ccontains 'signature' -and $names -ccontains 'signatureAlg') {
                if ($RunSetMasterKeyPath) { [void]$found.RunSet.Add($file.FullName) }
                continue
            }
            if ($file.Name -ceq 'capture-seal.json' -and $names -ccontains 'signedFile' -and $names -ccontains 'manifestHmac') {
                if ($CaptureKeyPath) { [void]$found.CaptureBundle.Add($file.DirectoryName) }
                continue
            }
            if ($file.Name -ceq 'transcript-package.json' -and
                (Test-Path -LiteralPath (Join-Path $file.DirectoryName 'transcript-package.seal'))) {
                if ($AcquisitionKeyPath) { [void]$found.AcquisitionPackage.Add($file.DirectoryName) }
                continue
            }
            if ($file.Name -ceq 'terminal-evidence.json' -and
                (Test-Path -LiteralPath (Join-Path $file.DirectoryName 'terminal-evidence.seal'))) {
                if ($TerminalKeyPath -or $AcquisitionKeyPath) { [void]$found.TerminalPackage.Add($file.DirectoryName) }
                continue
            }
        }
    }
    if ($usable -eq 0) {
        # A discovery request that matched no root is a typo, not an empty host.
        # Reporting zero samples as success would let a mistyped path be read as
        # evidence that all of history agrees.
        throw ("None of the -DiscoverRoot path(s) exist: " + ($Root -join '; ') +
            ". Pass each root as its own array element.")
    }
    return $found
}

try {
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $offlineSource = Join-Path $tempRoot 'empty-nuget-source'
    $packages = Join-Path $tempRoot 'packages'
    [void](New-Item -ItemType Directory -Path $offlineSource)
    & dotnet restore $project --source $offlineSource --packages $packages `
        -p:NuGetAudit=false --nologo --verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw 'SealParity offline restore failed.' }
    & dotnet build $project --configuration Release --no-restore --nologo --verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw 'SealParity build failed.' }
    $script:dll = Join-Path $PSScriptRoot 'SealParity\bin\Release\net10.0\SealParity.dll'
    $discoveredScanned = 0
    if ($DiscoverRoot.Count -gt 0) {
        $discovered = Get-SealParityDiscoveredSample -Root $DiscoverRoot -Limit $DiscoverLimit
        $discoveredScanned = [int]$discovered.Scanned
        $ReplayManifest = @($ReplayManifest) + @($discovered.ReplayManifest)
        $corpusSeal = @($discovered.CorpusSeal)
        $AcquisitionPackage = @($AcquisitionPackage) + @($discovered.AcquisitionPackage)
        $TerminalPackage = @($TerminalPackage) + @($discovered.TerminalPackage)
        $CaptureBundle = @($CaptureBundle) + @($discovered.CaptureBundle)
        $RunSet = @($RunSet) + @($discovered.RunSet)
        Write-Host ("seal-parity discovery: scanned $discoveredScanned JSON file(s); " +
            "replay=$($discovered.ReplayManifest.Count) corpusSeal=$($discovered.CorpusSeal.Count) " +
            "acquisition=$($discovered.AcquisitionPackage.Count) " +
            "terminal=$($discovered.TerminalPackage.Count) capture=$($discovered.CaptureBundle.Count) " +
            "runSet=$($discovered.RunSet.Count).") -ForegroundColor DarkGray
        foreach ($path in $corpusSeal) {
            Test-CorpusSealBinding -Path $path -Surface 'corpus seal binding'
        }
    }
    foreach ($path in $ReplayManifest) {
        Test-SelfExcludingManifest -Path $path -Surface 'replay manifest'
    }
    foreach ($path in $MaterializationManifest) {
        Test-SelfExcludingManifest -Path $path -Surface 'materialization manifest'
    }
    foreach ($directory in $AcquisitionPackage) {
        if (-not $AcquisitionKeyPath) { throw 'Acquisition samples require -AcquisitionKeyPath.' }
        $manifestPath = Join-Path (Resolve-Path -LiteralPath $directory).ProviderPath 'transcript-package.json'
        $sealPath = Join-Path (Resolve-Path -LiteralPath $directory).ProviderPath 'transcript-package.seal'
        $manifestText = [IO.File]::ReadAllText($manifestPath, $utf8)
        $seal = [IO.File]::ReadAllText($sealPath, $utf8) | ConvertFrom-Json
        $actual = Invoke-SealParity ([ordered]@{
                contractVersion = 'devpilot.seal-parity.v1'
                operation = 'hmac-sha256'
                profile = 'json-text-v1'
                inputFile = $manifestPath
                key = [ordered]@{ format = 'raw-file'; path = (Resolve-Path -LiteralPath $AcquisitionKeyPath).ProviderPath }
            })
        $problems = [Collections.Generic.List[string]]::new()
        if ([string]$actual.canonicalText -cne $manifestText) {
            [void]$problems.Add('format: transcript-package.json is not json-text-v1 canonical bytes')
        }
        if ([string]$actual.sha256 -cne [string]$seal.manifestSha256) {
            [void]$problems.Add('manifestSha256: canonical UTF-8 SHA-256 differs')
        }
        if ([string]$actual.hmacSha256 -cne [string]$seal.manifestHmac) {
            [void]$problems.Add('manifestHmac: raw-file HMAC-SHA256 differs')
        }
        Add-Result -Surface 'acquisition package' -Problems $problems.ToArray() -Sample $manifestPath
    }
    foreach ($directory in $TerminalPackage) {
        $effectiveTerminalKeyPath = if ($TerminalKeyPath) { $TerminalKeyPath } else { $AcquisitionKeyPath }
        if (-not $effectiveTerminalKeyPath) { throw 'Terminal samples require -TerminalKeyPath or -AcquisitionKeyPath.' }
        $manifestPath = Join-Path (Resolve-Path -LiteralPath $directory).ProviderPath 'terminal-evidence.json'
        $sealPath = Join-Path (Resolve-Path -LiteralPath $directory).ProviderPath 'terminal-evidence.seal'
        $manifestText = [IO.File]::ReadAllText($manifestPath, $utf8)
        $seal = [IO.File]::ReadAllText($sealPath, $utf8) | ConvertFrom-Json
        $actual = Invoke-SealParity ([ordered]@{
                contractVersion = 'devpilot.seal-parity.v1'
                operation = 'hmac-sha256'
                profile = 'json-text-v1'
                inputFile = $manifestPath
                key = [ordered]@{ format = 'raw-file'; path = (Resolve-Path -LiteralPath $effectiveTerminalKeyPath).ProviderPath }
            })
        $problems = [Collections.Generic.List[string]]::new()
        if ([string]$actual.canonicalText -cne $manifestText) {
            [void]$problems.Add('format: terminal-evidence.json is not json-text-v1 canonical bytes')
        }
        if ([string]$actual.sha256 -cne [string]$seal.manifestSha256) {
            [void]$problems.Add('manifestSha256: canonical UTF-8 SHA-256 differs')
        }
        if ([string]$actual.hmacSha256 -cne [string]$seal.manifestHmac) {
            [void]$problems.Add('manifestHmac: raw-file HMAC-SHA256 differs')
        }
        Add-Result -Surface 'terminal evidence' -Problems $problems.ToArray() -Sample $manifestPath
    }
    foreach ($directory in $CaptureBundle) {
        if (-not $CaptureKeyPath) { throw 'Capture samples require -CaptureKeyPath.' }
        $root = (Resolve-Path -LiteralPath $directory).ProviderPath
        $seal = [IO.File]::ReadAllText((Join-Path $root 'capture-seal.json'), $utf8) | ConvertFrom-Json
        $signedPath = Join-Path $root ([string]$seal.signedFile)
        $actual = Invoke-SealParity ([ordered]@{
                contractVersion = 'devpilot.seal-parity.v1'
                operation = 'hmac-sha256'
                profile = 'exact-text-v1'
                inputFile = $signedPath
                key = [ordered]@{ format = 'raw-file'; path = (Resolve-Path -LiteralPath $CaptureKeyPath).ProviderPath }
            })
        $problems = [Collections.Generic.List[string]]::new()
        if ([string]$actual.sha256 -cne [string]$seal.signedSha256) {
            [void]$problems.Add('signedSha256: exact-text UTF-8 SHA-256 differs')
        }
        if ([string]$actual.hmacSha256 -cne [string]$seal.manifestHmac) {
            [void]$problems.Add('manifestHmac: exact-text raw-file HMAC-SHA256 differs')
        }
        Add-Result -Surface 'capture manifest' -Problems $problems.ToArray() -Sample $root
    }
    foreach ($path in $RunSet) {
        if (-not $RunSetMasterKeyPath) { throw 'Run-set samples require -RunSetMasterKeyPath.' }
        $envelope = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $path).ProviderPath, $utf8) |
            ConvertFrom-Json -Depth 8
        $domains = [Collections.Generic.List[string]]::new()
        if ($ReplayDerivedRunSetKey) { [void]$domains.Add('devpilot.reviewer.replay.artifact.v1') }
        [void]$domains.Add('devpilot.reviewer.convention-specialist.preview.v1')
        $actual = Invoke-SealParity ([ordered]@{
                contractVersion = 'devpilot.seal-parity.v1'
                operation = 'hmac-sha256'
                profile = 'exact-text-v1'
                text = [string]$envelope.manifestJson
                key = [ordered]@{ format = 'stored-file'; path = (Resolve-Path -LiteralPath $RunSetMasterKeyPath).ProviderPath }
                domains = $domains.ToArray()
            })
        $problems = [Collections.Generic.List[string]]::new()
        if ([string]$envelope.signatureAlg -cne 'HMACSHA256') {
            [void]$problems.Add('signatureAlg: expected HMACSHA256')
        }
        if ([string]$actual.hmacSha256 -cne [string]$envelope.signature) {
            [void]$problems.Add('signature: domain-separated exact-text HMAC-SHA256 differs')
        }
        Add-Result -Surface 'qualification run set' -Problems $problems.ToArray() -Sample $path
    }
}
finally {
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = $previousTelemetryPreference
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

$failed = @($results | Where-Object status -eq 'fail')
$sampleCount = $results.Count
if ($sampleCount -eq 0) { throw 'No private seal-parity samples were supplied.' }
$results | ConvertTo-Json -Depth 5
$bySurface = @($results | Group-Object surface | Sort-Object Name |
        ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
Write-Host "seal-parity samples: $sampleCount ($bySurface); failures: $($failed.Count)."
if ($failed.Count -gt 0) { throw "$($failed.Count) private seal-parity sample(s) diverged." }
