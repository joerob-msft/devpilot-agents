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
    [switch]$ReplayDerivedRunSetKey
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
    param([string]$Surface, [string[]]$Problems)
    [void]$results.Add([pscustomobject][ordered]@{
            surface = $Surface
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
    Add-Result -Surface $Surface -Problems $problems.ToArray()
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
        Add-Result -Surface 'acquisition package' -Problems $problems.ToArray()
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
        Add-Result -Surface 'terminal evidence' -Problems $problems.ToArray()
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
        Add-Result -Surface 'capture manifest' -Problems $problems.ToArray()
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
        Add-Result -Surface 'qualification run set' -Problems $problems.ToArray()
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
if ($failed.Count -gt 0) { throw "$($failed.Count) private seal-parity sample(s) diverged." }
