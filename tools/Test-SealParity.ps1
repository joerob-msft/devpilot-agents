#!/usr/bin/env pwsh
#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path $PSScriptRoot -Parent

# The hosted CI shell DOT-SOURCES this script and then exits with whatever
# $LASTEXITCODE holds. The refusal vectors below run the parity binary and
# REQUIRE it to fail, so the last native exit code left behind here is
# deliberately non-zero - which reported a failed step for a run in which all
# seventeen vectors passed in both directions. The script states its own result
# at the end instead. Asserted here on itself, so removing that trailing exit
# fails this suite rather than quietly restoring a green run reported as red.
$sealParitySelf = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$null, [ref]$null)
$sealParityLast = @($sealParitySelf.EndBlock.Statements | Select-Object -Last 1)
if (@($sealParityLast).Count -ne 1 -or
    $sealParityLast[0] -isnot [System.Management.Automation.Language.ExitStatementAst]) {
    throw ('Test-SealParity must end in an explicit exit: the hosted CI shell dot-sources it and reports ' +
        '$LASTEXITCODE, which the refusal vectors deliberately leave non-zero.')
}

$project = Join-Path $PSScriptRoot 'SealParity\SealParity.csproj'
$vectorsPath = Join-Path $PSScriptRoot 'SealParity\vectors.v1.json'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
Import-Module (Join-Path $repoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
. (Join-Path $repoRoot 'src\Agents\reviewer\AcquisitionPackage.ps1')
. (Join-Path $repoRoot 'src\Agents\reviewer\ConventionSpecialist.ps1')

function Get-ReferenceCanonical {
    param([Parameter(Mandatory)]$Vector)
    if ([string]$Vector.profile -ceq 'exact-text-v1') { return [string]$Vector.text }
    if ([string]$Vector.profile -ceq 'json-text-v1') {
        return ConvertTo-ReviewerAcquisitionPackageCanonicalText -JsonText ([string]$Vector.inputJson)
    }
    $value = [string]$Vector.inputJson | ConvertFrom-Json -AsHashtable -Depth 64
    if ($Vector.PSObject.Properties['excludeRootProperties']) {
        foreach ($name in @($Vector.excludeRootProperties)) { [void]$value.Remove([string]$name) }
    }
    if ([string]$Vector.profile -ceq 'replay-v1') {
        return ConvertTo-AgentReplayCanonicalJson -Value $value
    }
    return ConvertTo-ReviewerConventionSpecialistCanonicalJson -Value $value
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('seal-parity-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tempRoot)
$previousTelemetryPreference = $env:DOTNET_CLI_TELEMETRY_OPTOUT
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
    $dll = Join-Path $PSScriptRoot 'SealParity\bin\Release\net10.0\SealParity.dll'
    $vectors = [IO.File]::ReadAllText($vectorsPath, $utf8) | ConvertFrom-Json -Depth 16
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($vector in @($vectors.vectors)) {
        $referenceCanonical = Get-ReferenceCanonical -Vector $vector
        $referenceBytes = $utf8.GetBytes($referenceCanonical)
        $referenceBase64 = [Convert]::ToBase64String($referenceBytes)
        $referenceSha = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($referenceBytes)).ToLowerInvariant()
        if ($referenceBase64 -cne [string]$vector.canonicalUtf8Base64) {
            [void]$failures.Add("$($vector.name): frozen bytes differ from the current PowerShell reference")
        }
        if ($referenceSha -cne [string]$vector.sha256) {
            [void]$failures.Add("$($vector.name): frozen SHA-256 differs from the current PowerShell reference")
        }
        $request = [ordered]@{
            contractVersion = 'devpilot.seal-parity.v1'
            operation = $(if ($vector.PSObject.Properties['key']) { 'hmac-sha256' } else { 'sha256' })
            profile = [string]$vector.profile
        }
        if ($vector.PSObject.Properties['inputJson']) {
            $inputPath = Join-Path $tempRoot "$($vector.name)-input.json"
            $inputBytes = $utf8.GetBytes([string]$vector.inputJson)
            if ($vector.PSObject.Properties['inputBom'] -and [bool]$vector.inputBom) {
                $inputBytes = [byte[]](@(0xef, 0xbb, 0xbf) + @($inputBytes))
            }
            [IO.File]::WriteAllBytes($inputPath, $inputBytes)
            $request.inputFile = $inputPath
        }
        else { $request.text = [string]$vector.text }
        if ([string]$vector.profile -ceq 'exact-text-v1' -and
            $vector.PSObject.Properties['inputBom'] -and [bool]$vector.inputBom) {
            $inputPath = Join-Path $tempRoot "$($vector.name)-exact-text.txt"
            $inputBytes = [byte[]](@(0xef, 0xbb, 0xbf) + @($utf8.GetBytes([string]$vector.text)))
            [IO.File]::WriteAllBytes($inputPath, $inputBytes)
            [void]$request.Remove('text')
            $request.inputFile = $inputPath
        }
        if ($vector.PSObject.Properties['excludeRootProperties']) {
            $request.excludeRootProperties = @($vector.excludeRootProperties)
        }
        if ($vector.PSObject.Properties['key']) { $request.key = $vector.key }
        if ($vector.PSObject.Properties['domains']) { $request.domains = @($vector.domains) }
        $requestPath = Join-Path $tempRoot "$($vector.name)-request.json"
        [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 8 -Compress), $utf8)
        $actualText = & dotnet $dll --request $requestPath
        if ($LASTEXITCODE -ne 0) {
            [void]$failures.Add("$($vector.name): C# process failed")
            continue
        }
        $actual = $actualText | ConvertFrom-Json
        if ([string]$actual.canonicalUtf8Base64 -cne [string]$vector.canonicalUtf8Base64) {
            [void]$failures.Add("$($vector.name): canonical bytes differ")
        }
        if ([string]$actual.sha256 -cne [string]$vector.sha256) {
            [void]$failures.Add("$($vector.name): SHA-256 differs")
        }
        if ($vector.PSObject.Properties['hmacSha256'] -and
            [string]$actual.hmacSha256 -cne [string]$vector.hmacSha256) {
            [void]$failures.Add("$($vector.name): HMAC-SHA256 differs")
        }
        if ($vector.PSObject.Properties['hmacSha256']) {
            $key = if ([string]$vector.key.format -ceq 'hex') {
                [Convert]::FromHexString([string]$vector.key.value)
            }
            else {
                [Convert]::FromBase64String(([string]$vector.key.value).Substring(4))
            }
            $referenceDomains = if ($vector.PSObject.Properties['domains']) { @($vector.domains) } else { @() }
            foreach ($domain in $referenceDomains) {
                if ([string]$domain -ceq 'devpilot.reviewer.convention-specialist.preview.v1') {
                    $key = Get-ReviewerConventionSpecialistDomainKey -MasterKey $key -Domain preview
                }
                else {
                    $key = [Security.Cryptography.HMACSHA256]::HashData(
                        $key, $utf8.GetBytes([string]$domain))
                }
            }
            $referenceHmac = if ($referenceDomains -contains 'devpilot.reviewer.convention-specialist.preview.v1') {
                Get-ReviewerConventionSpecialistSignature -Json $referenceCanonical -Key $key
            }
            elseif ([string]$vector.profile -ceq 'json-text-v1') {
                Get-ReviewerAcquisitionPackageHmac -Text $referenceCanonical -Key $key
            }
            else {
                [Convert]::ToHexString(
                    [Security.Cryptography.HMACSHA256]::HashData($key, $referenceBytes)).ToLowerInvariant()
            }
            if ($referenceHmac -cne [string]$vector.hmacSha256) {
                [void]$failures.Add("$($vector.name): frozen HMAC differs from the current PowerShell reference")
            }
        }
        $roundTripBytes = $utf8.GetBytes([string]$actual.canonicalText)
        if ([Convert]::ToBase64String($roundTripBytes) -cne [string]$vector.canonicalUtf8Base64) {
            [void]$failures.Add("$($vector.name): C# output text did not round-trip to the PowerShell bytes")
        }
        if ([string]$vector.profile -ne 'exact-text-v1') {
            $roundTripPath = Join-Path $tempRoot "$($vector.name)-csharp-output.json"
            [IO.File]::WriteAllText($roundTripPath, [string]$actual.canonicalText, $utf8)
            $roundTripVector = [pscustomobject]@{
                profile = $vector.profile
                inputJson = [IO.File]::ReadAllText($roundTripPath, $utf8)
            }
            $powerShellRoundTrip = Get-ReferenceCanonical -Vector $roundTripVector
            if ($powerShellRoundTrip -cne [string]$actual.canonicalText) {
                [void]$failures.Add("$($vector.name): PowerShell did not accept the C# canonical text as canonical")
            }
        }
    }

    foreach ($rejectedDate in @(
            '2024-01-01T12:00:00',
            '2024-01-01T12:00:00.5Z',
            '2024-01-01T12:00:00+01',
            '2024-01-01T12:00:00+0100',
            '2024-01-01T12:00:00+01:00',
            '/Date(1700000000000)/',
            '/Date(1700000000000+0100)/'
        )) {
        $rejectedDateRequest = [ordered]@{
            contractVersion = 'devpilot.seal-parity.v1'
            operation = 'sha256'
            profile = 'replay-v1'
            value = [ordered]@{ timestamp = $rejectedDate }
        }
        $rejectedDatePath = Join-Path $tempRoot ([Guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($rejectedDatePath, ($rejectedDateRequest | ConvertTo-Json -Compress), $utf8)
        $previousNativePreference = $PSNativeCommandUseErrorActionPreference
        try {
            $PSNativeCommandUseErrorActionPreference = $false
            $null = & dotnet $dll --request $rejectedDatePath 2>&1
            if ($LASTEXITCODE -eq 0) {
                [void]$failures.Add("replay date '$rejectedDate': C# accepted a value PowerShell coerces and rejects")
            }
        }
        finally { $PSNativeCommandUseErrorActionPreference = $previousNativePreference }
    }

        foreach ($acceptedDate in @(
                '2021-02-29T00:00:00Z',
                '2020-99-99T99:99:99Z',
                '2024-01-01T12:00:00.12345678Z'
            )) {
            $acceptedRequest = [ordered]@{
                contractVersion = 'devpilot.seal-parity.v1'
                operation = 'sha256'
                profile = 'replay-v1'
                value = [ordered]@{ timestamp = $acceptedDate }
            }
            $acceptedPath = Join-Path $tempRoot ([Guid]::NewGuid().ToString('N') + '.json')
            [IO.File]::WriteAllText($acceptedPath, ($acceptedRequest | ConvertTo-Json -Compress), $utf8)
            $null = & dotnet $dll --request $acceptedPath
            if ($LASTEXITCODE -ne 0) {
                [void]$failures.Add("replay invalid ISO-shaped string '$acceptedDate': C# rejected a value PowerShell preserves")
            }
        }

        $stdinRequest = [ordered]@{
            contractVersion = 'devpilot.seal-parity.v1'
            operation = 'sha256'
            profile = 'json-text-v1'
            value = [ordered]@{ text = 'é Ω 😀' }
        } | ConvertTo-Json -Compress
        $start = [Diagnostics.ProcessStartInfo]::new('dotnet', "`"$dll`"")
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardInputEncoding = $utf8
        $process = [Diagnostics.Process]::Start($start)
        $process.StandardInput.Write($stdinRequest)
        $process.StandardInput.Close()
        $stdinOutput = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $stdinResult = $stdinOutput | ConvertFrom-Json
        if ($process.ExitCode -ne 0 -or [string]$stdinResult.canonicalText -cne '{"text":"é Ω 😀"}') {
            [void]$failures.Add('UTF-8 stdin: non-ASCII request text changed')
        }

        $deepValue = '0'
        foreach ($depth in 1..64) { $deepValue = "[$deepValue]" }
        $deepRequestPath = Join-Path $tempRoot 'depth-64.json'
        [IO.File]::WriteAllText(
            $deepRequestPath,
            '{"contractVersion":"devpilot.seal-parity.v1","operation":"sha256","profile":"json-text-v1","value":' +
                $deepValue + '}',
            $utf8)
        $null = & dotnet $dll --request $deepRequestPath
        if ($LASTEXITCODE -ne 0) {
            [void]$failures.Add('json-text-v1 depth 64: request envelope reduced the documented limit')
        }

        $surrogateRequestPath = Join-Path $tempRoot 'invalid-surrogate.json'
        [IO.File]::WriteAllText(
            $surrogateRequestPath,
            '{"contractVersion":"devpilot.seal-parity.v1","operation":"sha256","profile":"json-text-v1","value":"\ud800"}',
            $utf8)
        try {
            $PSNativeCommandUseErrorActionPreference = $false
            $null = & dotnet $dll --request $surrogateRequestPath 2>&1
            if ($LASTEXITCODE -ne 2) {
                [void]$failures.Add('invalid UTF-16: expected controlled request-error exit code 2')
            }
        }
        finally { $PSNativeCommandUseErrorActionPreference = $previousNativePreference }
}
finally {
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = $previousTelemetryPreference
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
Write-Host "Seal parity: $(@($vectors.vectors).Count) PowerShell/C# vectors passed in both directions."
exit 0
