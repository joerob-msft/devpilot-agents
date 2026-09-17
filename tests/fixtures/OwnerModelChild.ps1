param(
    [Parameter(Mandatory)][string]$Mode,
    [string]$StatePath,
    [Parameter(Mandatory)][string]$EnvelopePath
)

$ErrorActionPreference = 'Stop'
if ($StatePath -ceq '-') { $StatePath = $null }

function ConvertFrom-Base64Url([string]$Text) {
    $padded = $Text.Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) {
        0 {}
        2 { $padded += '==' }
        3 { $padded += '=' }
        default { throw 'invalid base64url' }
    }
    return [Convert]::FromBase64String($padded)
}

function ConvertTo-Base64Url([byte[]]$Bytes) {
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$envelope = [IO.File]::ReadAllText($EnvelopePath, [Text.Encoding]::UTF8)
$inputObject = [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $envelope)) |
    ConvertFrom-Json -AsHashtable -Depth 16
$unitId = [string]$inputObject.stimulus.executionUnitId
$judgment = if ([string]$inputObject.stimulus.construct.name -match 'Compliant') {
    'compliant'
}
else {
    'violation'
}
$response = [ordered]@{
    schemaVersion = 2
    nonce = $inputObject.nonce
    inputDigest = $inputObject.inputDigest
    subjectBinding = $inputObject.subjectBinding
    modelIdentity = $inputObject.modelIdentity
    responses = @([ordered]@{ executionUnitId = $unitId; judgment = $judgment })
}

switch ($Mode) {
    'no-findings' { $response.responses[0].judgment = 'compliant' }
    'unknown' { $response.responses[0].judgment = 'unknown' }
    'omitted' { $response.responses = @() }
    'duplicate' { $response.responses += $response.responses[0] }
    'unknown-ref' {
        $response.responses = @(
            [ordered]@{ executionUnitId = ('unit:' + ('f' * 64)); judgment = 'violation' }
        )
    }
    'wrong-nonce' { $response.nonce = '0' * 36 }
    'wrong-digest' { $response.inputDigest = 'v1:sha256:' + ('0' * 64) }
    'wrong-subject' { $response.subjectBinding = 'v1:sha256:' + ('0' * 64) }
    'wrong-model' { $response.modelIdentity = 'wrong-model' }
    'rationale' { $response.responses[0].rationale = 'Bounded deterministic rationale.' }
    'malformed-marker' {
        [Console]::Out.WriteLine('DEV_PILOT_OWNER_RESULT !!!')
        exit 0
    }
    'malformed-json' {
        $bytes = [Text.Encoding]::UTF8.GetBytes('{')
        [Console]::Out.WriteLine('DEV_PILOT_OWNER_RESULT ' + (ConvertTo-Base64Url $bytes))
        exit 0
    }
    'missing-schema' {
        [Console]::Out.WriteLine('DEV_PILOT_OWNER_RESULT_JSON {"unexpected":true}')
        exit 0
    }
    'malformed-schema' { $response.Remove('responses') }
    'stdout-flood' {
        [Console]::Out.Write(('x' * 8192))
        exit 0
    }
    'stderr-flood' {
        [Console]::Error.Write(('secret-value-' + ('x' * 8192)))
        exit 0
    }
    'line-flood' {
        1..64 | ForEach-Object { [Console]::Out.WriteLine('x') }
        exit 0
    }
    'early-exit' {
        [Console]::Error.Write('secret-value')
        exit 23
    }
    'timeout' {
        Start-Sleep -Seconds 30
        exit 0
    }
    'descendant' {
        $pwsh = (Get-Command pwsh).Source
        $descendant = Start-Process -FilePath $pwsh -PassThru -ArgumentList @(
            '-NoProfile', '-Command', 'Start-Sleep -Seconds 30')
        if ($StatePath) {
            [IO.File]::WriteAllText($StatePath, [string]$descendant.Id)
        }
        Start-Sleep -Seconds 30
        exit 0
    }
    'retry-once' {
        $count = if ($StatePath -and (Test-Path -LiteralPath $StatePath)) {
            [int][IO.File]::ReadAllText($StatePath)
        }
        else { 0 }
        $count++
        [IO.File]::WriteAllText($StatePath, [string]$count)
        if ($count -eq 1) { exit 23 }
    }
    'inspect-envelope' {
        $sensitiveNames = @(
            Get-ChildItem env: |
                Where-Object Name -Match '(?i)(?:token|secret|password|credential|api[_-]?key|github|azure|ado|copilot)' |
                Select-Object -ExpandProperty Name
        )
        $summary = [ordered]@{
            envelopeKeys = @($inputObject.Keys | Sort-Object)
            stimulusKeys = @($inputObject.stimulus.Keys | Sort-Object)
            constructKeys = @($inputObject.stimulus.construct.Keys | Sort-Object)
            toolCeiling = $inputObject.toolCeiling
            sensitiveEnvironmentNames = $sensitiveNames
            testOnly = $env:DEV_PILOT_OWNER_MODEL_TEST_ONLY
            currentDirectory = [Environment]::CurrentDirectory
            envelopeFile = [IO.Path]::GetFileName($EnvelopePath)
            commandLineContainsSnippet = [Environment]::CommandLine.Contains(
                [string]$inputObject.stimulus.construct.snippet,
                [StringComparison]::Ordinal)
            directoryEntries = @(
                Get-ChildItem -LiteralPath ([Environment]::CurrentDirectory) -Force |
                    Select-Object -ExpandProperty Name |
                    Sort-Object
            )
            environmentNames = @(
                Get-ChildItem env: | Select-Object -ExpandProperty Name | Sort-Object
            )
        }
        [IO.File]::WriteAllText(
            $StatePath,
            (ConvertTo-Json -InputObject $summary -Depth 8 -Compress),
            [Text.UTF8Encoding]::new($false))
    }
}

$json = ConvertTo-Json -InputObject $response -Depth 8 -Compress
$payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($json))
[Console]::Out.WriteLine('DEV_PILOT_OWNER_RESULT ' + $payload)
