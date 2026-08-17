#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)]
    [ValidateSet(
        'blind-gpt', 'blind-opus', 'specialist',
        'reciprocal-gpt-verifier', 'reciprocal-opus-verifier',
        'compatibility-generalist', 'compatibility-verifier')]
    [string]$Role,
    [Parameter(Mandatory)][string]$Model,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedBaseCommit,
    [Parameter(Mandatory)][string]$BindingBase64
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false, $true)

function Get-AdapterProperty {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)

    $current = $Value
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) { throw "Adapter placeholder '$Path' resolved through null." }
        if ($part -match '^[0-9]+$') {
            $items = @($current)
            $index = [int]$part
            if ($index -ge $items.Count) { throw "Adapter placeholder '$Path' indexes past its collection." }
            $current = $items[$index]
            continue
        }
        $property = $current.PSObject.Properties[$part]
        if (-not $property) { throw "Adapter placeholder '$Path' names no property '$part'." }
        $current = $property.Value
    }
    return $current
}

function Expand-AdapterTemplate {
    param([AllowNull()]$Value, [Parameter(Mandatory)]$Context)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $match = [regex]::Match($Value, '^\{\{([A-Za-z0-9_.-]+)\}\}$')
        if ($match.Success) {
            return Get-AdapterProperty -Value $Context -Path $match.Groups[1].Value
        }
        return $Value
    }
    if ($Value -is [Collections.IDictionary]) {
        $expanded = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $expanded[[string]$key] = Expand-AdapterTemplate -Value $Value[$key] -Context $Context
        }
        return [pscustomobject]$expanded
    }
    if ($Value -is [pscustomobject]) {
        $expanded = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $expanded[$property.Name] = Expand-AdapterTemplate -Value $property.Value -Context $Context
        }
        return [pscustomobject]$expanded
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return ,@($Value | ForEach-Object { Expand-AdapterTemplate -Value $_ -Context $Context })
    }
    return $Value
}

function Get-AdapterRuntime {
    param([Parameter(Mandatory)][string]$InputText)

    $matches = [regex]::Matches($InputText, '(?s)```json\s*(\{.*?\})\s*```')
    if ($matches.Count -eq 0) { return $null }
    return $matches[$matches.Count - 1].Groups[1].Value | ConvertFrom-Json -Depth 64
}

function Get-AllConstructIds {
    param([AllowNull()]$Runtime)

    if ($null -eq $Runtime) { return '' }
    $request = $Runtime.PSObject.Properties['ruleCoverageRequest']
    if (-not $request) { return '' }
    $changed = $request.Value.PSObject.Properties['changedConstructs']
    if (-not $changed) { return '' }
    return (@($changed.Value | ForEach-Object {
                if ($null -eq $_) { return }
                $idProperty = $_.PSObject.Properties['id']
                if ($idProperty) { [string]$idProperty.Value }
            } | Where-Object { $_ }) -join ',')
}

try {
    # This adapter stands in for the MCP/tool-side child during deterministic
    # acquisition. It must inherit neither write-provider nor Copilot
    # authentication credentials. Name a violating variable, never its value.
    foreach ($credentialName in @(
            'AZURE_DEVOPS_EXT_PAT', 'SYSTEM_ACCESSTOKEN',
            'COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
        if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($credentialName))) {
            throw "Offline adapter credential boundary violated: $credentialName is present."
        }
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 64
    if ([string]$manifest.kind -cne 'reviewer-offline-model-adapter' -or
        [int]$manifest.schemaVersion -ne 1) {
        throw 'Adapter manifest kind/version is unsupported.'
    }
    if ([string]$manifest.expectedBaseCommit -cne $ExpectedBaseCommit) {
        throw 'Adapter expected-base binding mismatch.'
    }
    if (-not [bool]$manifest.classification.offlineOnly -or
        -not [bool]$manifest.classification.nonPromotable -or
        [bool]$manifest.classification.writesPermitted -or
        -not [bool]$manifest.classification.outputsPreAuthored -or
        [bool]$manifest.classification.oracleDerivedAtRuntime) {
        throw 'Adapter manifest classification is unsafe.'
    }

    $roleRecord = $manifest.roles.PSObject.Properties[$Role]
    if (-not $roleRecord) { throw "Adapter manifest has no pre-authored '$Role' output." }
    $roleSpec = $roleRecord.Value
    if ([string]$roleSpec.model -cne $Model) {
        throw "Adapter role '$Role' is bound to a different model."
    }

    $inputText = [Console]::In.ReadToEnd()
    $inputSha256 = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($utf8.GetBytes($inputText))).ToLowerInvariant()
    $bindingJson = $utf8.GetString([Convert]::FromBase64String($BindingBase64))
    $binding = $bindingJson | ConvertFrom-Json -Depth 32
    $runtime = Get-AdapterRuntime -InputText $inputText
    $context = [pscustomobject][ordered]@{
        binding = $binding
        runtime = $runtime
        derived = [pscustomobject][ordered]@{
            inputSha256 = $inputSha256
            allConstructIds = Get-AllConstructIds -Runtime $runtime
        }
    }

    $behavior = [string]$roleSpec.behavior
    if ($behavior -eq 'timeout') {
        Start-Sleep -Seconds ([int]$roleSpec.delaySeconds)
        exit 0
    }
    if ($behavior -eq 'crash') { exit ([int]$roleSpec.exitCode) }
    if ($behavior -eq 'stdoutSaturation') {
        [Console]::Out.Write('x' * [int]$roleSpec.byteCount)
    }
    if ($behavior -eq 'stderrSaturation') {
        [Console]::Error.Write('x' * [int]$roleSpec.byteCount)
    }

    $answer = ''
    if ($behavior -notin 'missingMarker', 'stdoutSaturation', 'stderrSaturation') {
        $marker = Expand-AdapterTemplate -Value $roleSpec.markerTemplate -Context $context
        $markerJson = ConvertTo-Json -InputObject $marker -Depth 64 -Compress
        if ($behavior -eq 'truncatedMarker') {
            $markerJson = $markerJson.Substring(0, [Math]::Max(1, $markerJson.Length - 3))
        }
        if ($behavior -eq 'wrongBinding') {
            $marker.nonce = 'wrong-binding'
            $markerJson = ConvertTo-Json -InputObject $marker -Depth 64 -Compress
        }
        if ($behavior -eq 'schemaInvalidMarker') {
            # Inject an unexpected key so the exact production result-marker parser
            # classifies the payload as 'schemaInvalid' (an unexpected key), distinct
            # from 'wrongBinding' (an exact field carrying a wrong value). Role-generic:
            # every role's marker schema forbids additional keys.
            $marker | Add-Member -NotePropertyName 'unexpectedSchemaKey' -NotePropertyValue 'x' -Force
            $markerJson = ConvertTo-Json -InputObject $marker -Depth 64 -Compress
        }
        $answer = "$([string]$roleSpec.markerPrefix) $markerJson"
        if ($behavior -eq 'multipleMarkers') { $answer = "$answer`n$answer" }
    }

    if ($behavior -in 'stdoutSaturation', 'stderrSaturation') { exit 0 }
    # The reported CLI-envelope model is the run model unless the role pre-authors a
    # reportedModelOverride, which drives the verifier's exact-production modelMismatch
    # classification (the envelope model != the authorized verifier model). This never
    # changes which model the subprocess is; only the reported identity in the envelope.
    $reportedModel = $Model
    if ($roleSpec.PSObject.Properties['reportedModelOverride']) {
        $override = [string]$roleSpec.reportedModelOverride
        if ($override) { $reportedModel = $override }
    }
    [pscustomobject]@{
        type = 'assistant.message'
        data = [pscustomobject]@{ content = $answer; model = $reportedModel }
    } | ConvertTo-Json -Compress -Depth 8
    [pscustomobject]@{
        type = 'result'
        exitCode = 0
        usage = [pscustomobject]@{
            premiumRequests = 0
            totalApiDurationMs = 0
            sessionDurationMs = 0
            codeChanges = [pscustomobject]@{ filesModified = @() }
        }
    } | ConvertTo-Json -Compress -Depth 8
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 70
}
