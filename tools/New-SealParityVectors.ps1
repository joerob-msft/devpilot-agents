#!/usr/bin/env pwsh
#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'SealParity\vectors.v1.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path $PSScriptRoot -Parent
$utf8 = [Text.UTF8Encoding]::new($false, $true)
Import-Module (Join-Path $repoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
. (Join-Path $repoRoot 'src\Agents\reviewer\AcquisitionPackage.ps1')
. (Join-Path $repoRoot 'src\Agents\reviewer\ConventionSpecialist.ps1')

function Get-PublicKeyHex {
    param([Parameter(Mandatory)][byte]$First)
    return ((0..31 | ForEach-Object { ([byte]($First + $_)).ToString('x2') }) -join '')
}

$definitions = @(
    @{ name = 'json-nested-order'; profile = 'json-text-v1'; inputJson = '{"z":null,"a":[true,false,{"b":2,"a":1}]}' },
    @{ name = 'json-empty-singleton'; profile = 'json-text-v1'; inputJson = '{"singleton":[{"only":"value"}],"emptyObject":{},"emptyArray":[]}' },
    @{ name = 'json-unicode-escapes-newlines'; profile = 'json-text-v1'; inputJson = '{"unicode":"é Ω 😀","escaped":"quote \" slash \\","lines":"a\nb\r\nc\t\u0000","separator":"\u2028"}' },
    @{ name = 'json-c1-next-line'; profile = 'json-text-v1'; inputJson = '{"nel":"before\u0085after"}' },
    @{ name = 'json-bom-whitespace-and-newline'; profile = 'json-text-v1'; inputJson = "{`r`n  `"b`": 2,`r`n  `"a`": 1`r`n}`r`n"; inputBom = $true },
    @{ name = 'json-case-distinct-key-lookup'; profile = 'json-text-v1'; inputJson = '{"a":1,"A":2}' },
    @{ name = 'json-number-lexemes'; profile = 'json-text-v1'; inputJson = '{"integer":1,"negativeZero":-0,"decimal":1.2300,"exponent":1e2,"large":9223372036854775808}' },
    @{ name = 'replay-integers-and-order'; profile = 'replay-v1'; inputJson = '{"z":0,"A":-7,"a":[1,2,3],"null":null,"flag":true}' },
    @{ name = 'replay-duplicate-key-collapse'; profile = 'replay-v1'; inputJson = '{"a":1,"a":2,"A":3}' },
    @{ name = 'convention-number-rendering'; profile = 'convention-v1'; inputJson = '{"decimal":1.2300,"exponent":1e2,"negativeZero":-0,"large":9223372036854775808}' },
    @{ name = 'convention-overflow-number-rendering'; profile = 'convention-v1'; inputJson = '{"negative":-1e309,"positive":1e309}' },
    @{ name = 'self-excluding-manifest-digest'; profile = 'replay-v1'; inputJson = '{"schemaVersion":1,"kind":"example-materialization","files":[],"manifestDigest":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}'; excludeRootProperties = @('manifestDigest') },
    @{ name = 'acquisition-raw-key-hmac'; profile = 'json-text-v1'; inputJson = '{"schemaVersion":1,"kind":"example-package","files":[]}'; keyHex = Get-PublicKeyHex 0 },
    @{ name = 'runset-preview-domain-hmac'; profile = 'exact-text-v1'; text = '{"artifactVersion":2,"kind":"reviewer.run-reconciliation-set","plannedRunCount":2}'; keyHex = Get-PublicKeyHex 32; domains = @('devpilot.reviewer.convention-specialist.preview.v1') },
    @{ name = 'replay-runset-domain-chain'; profile = 'exact-text-v1'; text = '{"kind":"reviewer.run-reconciliation-set","promotable":false}'; keyHex = Get-PublicKeyHex 64; domains = @('devpilot.reviewer.replay.artifact.v1', 'devpilot.reviewer.convention-specialist.preview.v1') },
    @{ name = 'stored-raw-key-format'; profile = 'exact-text-v1'; text = 'sealed text without newline'; storedRaw = ('raw:' + [Convert]::ToBase64String([byte[]](96..127))) }
    @{ name = 'exact-text-input-bom'; profile = 'exact-text-v1'; text = 'decoded text'; inputBom = $true }
)

function Get-Canonical {
    param([hashtable]$Definition)
    if ($Definition.profile -ceq 'exact-text-v1') { return [string]$Definition.text }
    if ($Definition.profile -ceq 'json-text-v1') {
        $canonical = ConvertTo-ReviewerAcquisitionPackageCanonicalText -JsonText $Definition.inputJson
    }
    elseif ($Definition.profile -ceq 'replay-v1') {
        $value = $Definition.inputJson | ConvertFrom-Json -AsHashtable -Depth 64
        $canonical = ConvertTo-AgentReplayCanonicalJson -Value $value
    }
    else {
        $value = $Definition.inputJson | ConvertFrom-Json -AsHashtable -Depth 64
        $canonical = ConvertTo-ReviewerConventionSpecialistCanonicalJson -Value $value
    }
    if ($Definition.ContainsKey('excludeRootProperties')) {
        $value = $canonical | ConvertFrom-Json -AsHashtable -Depth 64
        foreach ($name in $Definition.excludeRootProperties) { [void]$value.Remove($name) }
        if ($Definition.profile -ceq 'replay-v1') { $canonical = ConvertTo-AgentReplayCanonicalJson -Value $value }
        else { $canonical = ConvertTo-ReviewerAcquisitionPackageCanonicalText -JsonText ($value | ConvertTo-Json -Depth 64 -Compress) }
    }
    return $canonical
}

$vectors = foreach ($definition in $definitions) {
    $canonical = Get-Canonical $definition
    $bytes = $utf8.GetBytes($canonical)
    $record = [ordered]@{
        name = $definition.name
        profile = $definition.profile
    }
    if ($definition.ContainsKey('inputJson')) { $record.inputJson = $definition.inputJson }
    if ($definition.ContainsKey('text')) { $record.text = $definition.text }
    if ($definition.ContainsKey('inputBom')) { $record.inputBom = [bool]$definition.inputBom }
    if ($definition.ContainsKey('excludeRootProperties')) { $record.excludeRootProperties = @($definition.excludeRootProperties) }
    if ($definition.ContainsKey('keyHex')) { $record.key = [ordered]@{ format = 'hex'; value = $definition.keyHex } }
    if ($definition.ContainsKey('storedRaw')) { $record.key = [ordered]@{ format = 'stored-raw'; value = $definition.storedRaw } }
    if ($definition.ContainsKey('domains')) { $record.domains = @($definition.domains) }
    $record.canonicalUtf8Base64 = [Convert]::ToBase64String($bytes)
    $record.sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($record.Contains('key')) {
        $key = if ($record.key.format -ceq 'hex') { [Convert]::FromHexString($record.key.value) }
            else { [Convert]::FromBase64String($record.key.value.Substring(4)) }
        $domains = if ($record.Contains('domains')) { @($record.domains) } else { @() }
        foreach ($domain in $domains) {
            if ([string]$domain -ceq 'devpilot.reviewer.convention-specialist.preview.v1') {
                $key = Get-ReviewerConventionSpecialistDomainKey -MasterKey $key -Domain preview
            }
            else {
                $key = [Security.Cryptography.HMACSHA256]::HashData($key, $utf8.GetBytes($domain))
            }
        }
        $record.hmacSha256 = if ($domains -contains 'devpilot.reviewer.convention-specialist.preview.v1') {
            Get-ReviewerConventionSpecialistSignature -Json $canonical -Key $key
        }
        elseif ($definition.profile -ceq 'json-text-v1') {
            Get-ReviewerAcquisitionPackageHmac -Text $canonical -Key $key
        }
        else {
            [Convert]::ToHexString(
                [Security.Cryptography.HMACSHA256]::HashData($key, $bytes)).ToLowerInvariant()
        }
    }
    [pscustomobject]$record
}

$document = [ordered]@{
    contractVersion = 'devpilot.seal-parity.v1'
    reference = 'PowerShell production functions at PR62 head 535fa9e3f398d8a885849265ecd3f92371f7d52a'
    vectors = @($vectors)
}
[IO.File]::WriteAllText($OutputPath, ($document | ConvertTo-Json -Depth 12), $utf8)
Write-Host "Wrote $($vectors.Count) PowerShell reference vectors to $OutputPath"
