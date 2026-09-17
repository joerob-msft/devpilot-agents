#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bindingTypeName = 'DevPilot.OwnerPipeline.OwnerPipelineBinding'
if (-not ($bindingTypeName -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Security.Cryptography;
using System.Text;

namespace DevPilot.OwnerPipeline
{
    public sealed class OwnerPipelineBinding
    {
        public int SchemaVersion { get { return 1; } }
        public string SubjectKey { get; }
        public string HeadKey { get; }
        public string RuleKey { get; }
        public string CapabilityKey { get; }
        public string AuthorizationKey { get; }
        public string BindingId { get; }

        public OwnerPipelineBinding(
            string subjectKey,
            string headKey,
            string ruleKey,
            string capabilityKey,
            string authorizationKey)
        {
            SubjectKey = subjectKey;
            HeadKey = headKey;
            RuleKey = ruleKey;
            CapabilityKey = capabilityKey;
            AuthorizationKey = authorizationKey;

            var material = new StringBuilder("owner-pipeline-binding-v1");
            Append(material, subjectKey);
            Append(material, headKey);
            Append(material, ruleKey);
            Append(material, capabilityKey);
            Append(material, authorizationKey);
            using (var sha = SHA256.Create())
            {
                var digest = sha.ComputeHash(Encoding.UTF8.GetBytes(material.ToString()));
                var hex = new StringBuilder(digest.Length * 2);
                foreach (var value in digest)
                {
                    hex.Append(value.ToString("x2"));
                }
                BindingId = "v1:sha256:" + hex;
            }
        }

        private static void Append(StringBuilder target, string value)
        {
            target.Append('|');
            target.Append(value.Length);
            target.Append(':');
            target.Append(value);
        }

        public override string ToString()
        {
            return BindingId;
        }
    }
}
'@
}

$script:OwnerStageNames = @(
    'Acquire snapshot',
    'Build evidence',
    'Run capability',
    'Validate findings',
    'Preview',
    'Authorize delivery'
)
$script:OwnerStates = @('complete', 'incomplete', 'unknown')
$script:OwnerMaximumDiagnostics = 16
$script:OwnerMaximumDiagnosticLength = 240
$script:OwnerMaximumUnits = 256
$script:OwnerMaximumAssessments = 256
$script:OwnerMaximumFindings = 512
$script:OwnerMaximumJsonDepth = 16
$script:OwnerMaximumJsonNodes = 10000
$script:OwnerMaximumJsonMembers = 1024

function Assert-OwnerText {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [int]$MaximumLength = 512
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -cne $Value.Trim() -or
        $Value.Length -gt $MaximumLength -or
        $Value -match '[\r\n]') {
        throw "$Name must be non-empty, trimmed, single-line text no longer than $MaximumLength characters."
    }
}

function Copy-OwnerJsonNode {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,
        [Parameter(Mandatory)][int]$Depth,
        [Parameter(Mandatory)][ref]$NodeCount
    )

    if ($null -eq $Value) { return $null }
    $NodeCount.Value++
    if ($Depth -gt $script:OwnerMaximumJsonDepth -or
        $NodeCount.Value -gt $script:OwnerMaximumJsonNodes) {
        throw 'JSON-shaped adapter data exceeded the facade depth or node bound.'
    }
    if ($Value -is [string] -or $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [short] -or $Value -is [ushort] -or
        $Value -is [int] -or $Value -is [uint] -or
        $Value -is [long] -or $Value -is [ulong] -or
        $Value -is [decimal] -or $Value -is [double] -or
        $Value -is [single]) {
        return $Value
    }
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Count -gt $script:OwnerMaximumJsonMembers) {
            throw 'JSON-shaped adapter data exceeded the facade member bound.'
        }
        $copy = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        $keys = [string[]]@($Value.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($keyObject in $keys) {
            if ($keyObject -isnot [string] -or [string]::IsNullOrEmpty($keyObject)) {
                throw 'JSON-shaped adapter objects require non-empty string keys.'
            }
            $copy[$keyObject] = Copy-OwnerJsonNode -Value $Value[$keyObject] `
                -Depth ($Depth + 1) -NodeCount $NodeCount
        }
        return $copy
    }
    if ($Value -is [Collections.IList]) {
        if ($Value.Count -gt $script:OwnerMaximumJsonMembers) {
            throw 'JSON-shaped adapter data exceeded the facade member bound.'
        }
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            [void]$items.Add((Copy-OwnerJsonNode -Value $item -Depth ($Depth + 1) -NodeCount $NodeCount))
        }
        Write-Output -NoEnumerate ([object[]]$items.ToArray())
        return
    }
    if ($Value -is [pscustomobject]) {
        $properties = @($Value.PSObject.Properties)
        if ($properties.Count -gt $script:OwnerMaximumJsonMembers) {
            throw 'JSON-shaped adapter data exceeded the facade member bound.'
        }
        $copy = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        $propertyNames = [string[]]@($properties.Name)
        [Array]::Sort($propertyNames, [StringComparer]::Ordinal)
        foreach ($propertyName in $propertyNames) {
            $copy[$propertyName] = Copy-OwnerJsonNode -Value $Value.$propertyName `
                -Depth ($Depth + 1) -NodeCount $NodeCount
        }
        return $copy
    }
    throw 'Adapter data contained a value outside the JSON-shaped facade contract.'
}

function Copy-OwnerJsonValue {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    $nodeCount = 0
    $copy = Copy-OwnerJsonNode -Value $Value -Depth 0 -NodeCount ([ref]$nodeCount)
    if ($Value -is [Collections.IList]) {
        Write-Output -NoEnumerate ([object[]]@($copy))
        return
    }
    return $copy
}

function Copy-OwnerNormalizedValue {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or
        $Value -is [string] -or $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [short] -or $Value -is [ushort] -or
        $Value -is [int] -or $Value -is [uint] -or
        $Value -is [long] -or $Value -is [ulong] -or
        $Value -is [decimal] -or $Value -is [double] -or
        $Value -is [single]) {
        return $Value
    }
    if ($Value -is [Collections.IDictionary]) {
        $copy = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        $keys = [string[]]@($Value.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) {
            $copy[$key] = Copy-OwnerNormalizedValue -Value $Value[$key]
        }
        return $copy
    }
    if ($Value -is [Collections.IList]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            [void]$items.Add((Copy-OwnerNormalizedValue -Value $item))
        }
        Write-Output -NoEnumerate ([object[]]$items.ToArray())
        return
    }
    throw 'Facade-owned data was not normalized.'
}

function ConvertTo-OwnerCanonicalNode {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [short] -or $Value -is [ushort] -or
        $Value -is [int] -or $Value -is [uint] -or
        $Value -is [long] -or $Value -is [ulong] -or
        $Value -is [decimal] -or $Value -is [double] -or
        $Value -is [single]) {
        return $Value
    }
    if ($Value -is [Collections.IDictionary] -or
        $Value -is [Collections.IList]) {
        return Copy-OwnerNormalizedValue -Value $Value
    }
    throw "Owner pipeline contracts accept only JSON-shaped values, not '$($Value.GetType().FullName)'."
}

function ConvertTo-OwnerCanonicalJson {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    $canonical = ConvertTo-OwnerCanonicalNode -Value $Value
    return ConvertTo-Json -InputObject $canonical -Depth 32 -Compress -EscapeHandling EscapeNonAscii
}

function Get-OwnerDigest {
    param([Parameter(Mandatory)][object]$Value)

    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-OwnerCanonicalJson -Value $Value))
    $digest = [Security.Cryptography.SHA256]::HashData($bytes)
    return 'v1:sha256:' + [Convert]::ToHexString($digest).ToLowerInvariant()
}

function Add-OwnerDiagnostic {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Diagnostics,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        [string]$Stage = ''
    )

    if ($Diagnostics.Count -ge $script:OwnerMaximumDiagnostics) { return }
    $safeCode = if ($Code -match '^[a-z0-9-]{1,64}$') { $Code } else { 'invalid-diagnostic-code' }
    $safeMessage = ($Message -replace '[\r\n\t]+', ' ').Trim()
    if ($safeMessage.Length -gt $script:OwnerMaximumDiagnosticLength) {
        $safeMessage = $safeMessage.Substring(0, $script:OwnerMaximumDiagnosticLength)
    }
    [void]$Diagnostics.Add([pscustomobject][ordered]@{
            code = $safeCode
            message = $safeMessage
            stage = $Stage
        })
}

function Import-OwnerDiagnostics {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Target,
        [Parameter()][AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Stage
    )

    $imported = 0
    foreach ($entry in @($Value)) {
        if ($imported -ge 4) { break }
        if ($null -eq $entry) { continue }
        if ($entry -is [Collections.IDictionary]) {
            $code = if ($entry.Contains('code')) { [string]($entry['code']) } else { 'adapter-diagnostic' }
            $message = if ($entry.Contains('message')) { [string]($entry['message']) } else { 'Adapter reported a diagnostic.' }
            Add-OwnerDiagnostic -Diagnostics $Target -Code $code -Message $message -Stage $Stage
        }
        else {
            Add-OwnerDiagnostic -Diagnostics $Target -Code 'adapter-diagnostic' -Message ([string]$entry) -Stage $Stage
        }
        $imported++
    }
}

function Test-OwnerAdapter {
    param(
        [Parameter(Mandatory)][object]$Adapter,
        [Parameter(Mandatory)][string]$ExpectedStage
    )

    if ($Adapter -isnot [pscustomobject] -or
        $Adapter.PSTypeNames -cnotcontains 'DevPilot.OwnerPipeline.Adapter' -or
        $Adapter.Stage -cne $ExpectedStage -or
        $Adapter.Handler -isnot [scriptblock]) {
        throw "Expected a '$ExpectedStage' adapter created by New-OwnerPipelineAdapter."
    }
}

function Invoke-OwnerAdapter {
    param(
        [Parameter(Mandatory)][object]$Adapter,
        [Parameter(Mandatory)][object]$AdapterInput,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Diagnostics,
        [Parameter(Mandatory)][string]$Stage
    )

    try {
        $handler = $Adapter.Handler
        $values = @(& $handler $AdapterInput)
        if ($values.Count -ne 1 -or $values[0] -isnot [Collections.IDictionary]) {
            throw [InvalidOperationException]::new('Adapter must return exactly one dictionary.')
        }
        return [pscustomobject]@{ succeeded = $true; value = $values[0] }
    }
    catch {
        $exceptionType = $_.Exception.GetType().Name
        Add-OwnerDiagnostic -Diagnostics $Diagnostics -Code 'adapter-failed' `
            -Message "Adapter '$($Adapter.Name)' failed with $exceptionType." -Stage $Stage
        return [pscustomobject]@{ succeeded = $false; value = $null }
    }
}

function Test-OwnerBoundResponse {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Response,
        [Parameter(Mandatory)][DevPilot.OwnerPipeline.OwnerPipelineBinding]$Binding,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Diagnostics
    )

    if (-not $Response.Contains('schemaVersion') -or $Response['schemaVersion'] -ne 1) {
        Add-OwnerDiagnostic -Diagnostics $Diagnostics -Code 'schema-mismatch' `
            -Message 'Adapter response did not use schema version 1.' -Stage $Stage
        return $false
    }
    if (-not $Response.Contains('bindingId') -or [string]($Response['bindingId']) -cne $Binding.BindingId) {
        Add-OwnerDiagnostic -Diagnostics $Diagnostics -Code 'binding-mismatch' `
            -Message 'Adapter response did not match the wrapper-owned pipeline binding.' -Stage $Stage
        return $false
    }
    return $true
}

function New-OwnerStageRecords {
    $records = [ordered]@{}
    foreach ($name in $script:OwnerStageNames) {
        $records[$name] = [ordered]@{
            name = $name
            state = 'pending'
        }
    }
    return $records
}

function Complete-OwnerStageRecords {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Stages,
        [Parameter(Mandatory)][string]$AfterStage
    )

    $after = $false
    foreach ($name in $script:OwnerStageNames) {
        if ($after -and $Stages[$name]['state'] -eq 'pending') {
            $Stages[$name]['state'] = 'skipped'
        }
        if ($name -eq $AfterStage) { $after = $true }
    }
}

function Get-OwnerResultState {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Stages,
        [Parameter()][AllowNull()][object]$Validation
    )

    if (@($Stages.Values | Where-Object { $_['state'] -eq 'failed' }).Count -gt 0) { return 'failed' }
    if ($Stages['Authorize delivery']['state'] -eq 'unknown') { return 'unknown' }
    if ($null -eq $Validation) { return 'unknown' }
    return [string]$Validation.state
}

function New-OwnerPipelineBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubjectKey,
        [Parameter(Mandatory)][string]$HeadKey,
        [Parameter(Mandatory)][string]$RuleKey,
        [Parameter(Mandatory)][string]$CapabilityKey,
        [Parameter(Mandatory)][string]$AuthorizationKey
    )

    Assert-OwnerText -Value $SubjectKey -Name SubjectKey
    Assert-OwnerText -Value $HeadKey -Name HeadKey -MaximumLength 256
    Assert-OwnerText -Value $RuleKey -Name RuleKey
    Assert-OwnerText -Value $CapabilityKey -Name CapabilityKey
    Assert-OwnerText -Value $AuthorizationKey -Name AuthorizationKey
    return [DevPilot.OwnerPipeline.OwnerPipelineBinding]::new(
        $SubjectKey,
        $HeadKey,
        $RuleKey,
        $CapabilityKey,
        $AuthorizationKey)
}

function New-OwnerPipelineAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('acquisition', 'capability', 'delivery')][string]$Stage,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Handler
    )

    Assert-OwnerText -Value $Name -Name Name -MaximumLength 128
    $adapter = [pscustomobject][ordered]@{
        Name = $Name
        Stage = $Stage
        Handler = $Handler
    }
    $adapter.PSTypeNames.Insert(0, 'DevPilot.OwnerPipeline.Adapter')
    return $adapter
}

function Invoke-OwnerReviewPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][DevPilot.OwnerPipeline.OwnerPipelineBinding]$Binding,
        [Parameter(Mandatory)][object]$AcquisitionAdapter,
        [Parameter(Mandatory)][object]$CapabilityAdapter,
        [Parameter()][AllowNull()][object]$DeliveryAdapter,
        [switch]$AuthorizeDelivery
    )

    Test-OwnerAdapter -Adapter $AcquisitionAdapter -ExpectedStage acquisition
    Test-OwnerAdapter -Adapter $CapabilityAdapter -ExpectedStage capability
    if ($null -ne $DeliveryAdapter) {
        Test-OwnerAdapter -Adapter $DeliveryAdapter -ExpectedStage delivery
    }
    elseif ($AuthorizeDelivery) {
        throw 'AuthorizeDelivery requires an injected delivery adapter.'
    }

    $diagnostics = [Collections.Generic.List[object]]::new()
    $stages = New-OwnerStageRecords
    $snapshot = $null
    $evidence = $null
    $capability = $null
    $pendingAssessments = @()
    $validation = $null
    $preview = $null
    $delivery = $null
    $halted = $false

    $stages['Acquire snapshot']['state'] = 'running'
    $acquisitionInput = [pscustomobject][ordered]@{
        schemaVersion = 1
        binding = $Binding
    }
    $acquired = Invoke-OwnerAdapter -Adapter $AcquisitionAdapter -AdapterInput $acquisitionInput `
        -Diagnostics $diagnostics -Stage 'Acquire snapshot'
    if (-not $acquired.succeeded) {
        $stages['Acquire snapshot']['state'] = 'failed'
        Complete-OwnerStageRecords -Stages $stages -AfterStage 'Acquire snapshot'
        $halted = $true
    }
    elseif (-not (Test-OwnerBoundResponse -Response $acquired.value -Binding $Binding `
                -Stage 'Acquire snapshot' -Diagnostics $diagnostics)) {
        $stages['Acquire snapshot']['state'] = 'failed'
        Complete-OwnerStageRecords -Stages $stages -AfterStage 'Acquire snapshot'
        $halted = $true
    }
    else {
        $rawSnapshot = $acquired.value
        $snapshotState = if ($rawSnapshot.Contains('state')) { [string]($rawSnapshot['state']) } else { '' }
        $rawUnits = @(if ($rawSnapshot.Contains('evidenceUnits')) { $rawSnapshot['evidenceUnits'] })
        if ($snapshotState -cnotin $script:OwnerStates -or $rawUnits.Count -gt $script:OwnerMaximumUnits) {
            Add-OwnerDiagnostic -Diagnostics $diagnostics -Code 'snapshot-invalid' `
                -Message 'Snapshot state or evidence-unit count was outside the facade contract.' -Stage 'Acquire snapshot'
            $stages['Acquire snapshot']['state'] = 'failed'
            Complete-OwnerStageRecords -Stages $stages -AfterStage 'Acquire snapshot'
            $halted = $true
        }
        else {
            $unitIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $normalizedUnits = [Collections.Generic.SortedDictionary[string,object]]::new(
                [StringComparer]::Ordinal)
            foreach ($unit in $rawUnits) {
                if ($unit -isnot [Collections.IDictionary] -or
                    -not $unit.Contains('unitId') -or
                    -not $unit.Contains('state')) {
                    Add-OwnerDiagnostic -Diagnostics $diagnostics -Code 'snapshot-unit-invalid' `
                        -Message 'An evidence unit was missing its generic identity or state.' -Stage 'Acquire snapshot'
                    $halted = $true
                    break
                }
                $unitId = [string]($unit['unitId'])
                $unitState = [string]($unit['state'])
                if ([string]::IsNullOrWhiteSpace($unitId) -or $unitId.Length -gt 128 -or
                    $unitId -match '[\r\n]' -or -not $unitIds.Add($unitId) -or
                    $unitState -cnotin $script:OwnerStates) {
                    Add-OwnerDiagnostic -Diagnostics $diagnostics -Code 'snapshot-unit-invalid' `
                        -Message 'An evidence unit had an invalid, duplicate, or unbounded identity/state.' -Stage 'Acquire snapshot'
                    $halted = $true
                    break
                }
                try {
                    $unitData = Copy-OwnerJsonValue -Value $(if ($unit.Contains('data')) { $unit['data'] } else { $null })
                }
                catch {
                    Add-OwnerDiagnostic -Diagnostics $diagnostics -Code 'snapshot-unit-invalid' `
                        -Message 'An evidence unit contained data outside the bounded JSON-shaped contract.' `
                        -Stage 'Acquire snapshot'
                    $halted = $true
                    break
                }
                $normalizedUnits.Add($unitId, [ordered]@{
                        unitId = $unitId
                        state = $unitState
                        data = $unitData
                    })
            }
            if ($halted) {
                $stages['Acquire snapshot']['state'] = 'failed'
                Complete-OwnerStageRecords -Stages $stages -AfterStage 'Acquire snapshot'
            }
            else {
                Import-OwnerDiagnostics -Target $diagnostics `
                    -Value $(if ($rawSnapshot.Contains('diagnostics')) { $rawSnapshot['diagnostics'] } else { @() }) `
                    -Stage 'Acquire snapshot'
                $snapshot = [ordered]@{
                    schemaVersion = 1
                    bindingId = $Binding.BindingId
                    state = $snapshotState
                    evidenceUnits = @($normalizedUnits.Values)
                }
                $stages['Acquire snapshot']['state'] = $snapshotState
            }
        }
    }

    if (-not $halted) {
        $stages['Build evidence']['state'] = 'running'
        $evidenceBody = [ordered]@{
            schemaVersion = 1
            bindingId = $Binding.BindingId
            state = $snapshot.state
            evidenceUnits = Copy-OwnerNormalizedValue -Value $snapshot.evidenceUnits
        }
        $evidence = [ordered]@{
            schemaVersion = 1
            bindingId = $Binding.BindingId
            state = $snapshot.state
            evidenceDigest = Get-OwnerDigest -Value $evidenceBody
            evidenceUnits = $evidenceBody.evidenceUnits
        }
        $stages['Build evidence']['state'] = $evidence.state
    }

    if (-not $halted) {
        $stages['Run capability']['state'] = 'running'
        $capabilityInput = [pscustomobject][ordered]@{
            schemaVersion = 1
            binding = $Binding
            evidence = Copy-OwnerNormalizedValue -Value $evidence
        }
        $capabilityResult = Invoke-OwnerAdapter -Adapter $CapabilityAdapter -AdapterInput $capabilityInput `
            -Diagnostics $diagnostics -Stage 'Run capability'
        if (-not $capabilityResult.succeeded -or
            -not (Test-OwnerBoundResponse -Response $capabilityResult.value -Binding $Binding `
                -Stage 'Run capability' -Diagnostics $diagnostics)) {
            $stages['Run capability']['state'] = 'failed'
            Complete-OwnerStageRecords -Stages $stages -AfterStage 'Run capability'
            $halted = $true
        }
        else {
            $rawCapability = $capabilityResult.value
            $capabilityState = if ($rawCapability.Contains('state')) { [string]($rawCapability['state']) } else { '' }
            $rawAssessments = @(if ($rawCapability.Contains('assessments')) { $rawCapability['assessments'] })
            if ($capabilityState -cnotin $script:OwnerStates -or
                $rawAssessments.Count -gt $script:OwnerMaximumAssessments) {
                Add-OwnerDiagnostic -Diagnostics $diagnostics -Code 'capability-invalid' `
                    -Message 'Capability state or assessment count was outside the facade contract.' -Stage 'Run capability'
                $stages['Run capability']['state'] = 'failed'
                Complete-OwnerStageRecords -Stages $stages -AfterStage 'Run capability'
                $halted = $true
            }
            else {
                Import-OwnerDiagnostics -Target $diagnostics `
                    -Value $(if ($rawCapability.Contains('diagnostics')) { $rawCapability['diagnostics'] } else { @() }) `
                    -Stage 'Run capability'
                $capability = [ordered]@{
                    schemaVersion = 1
                    bindingId = $Binding.BindingId
                    state = $capabilityState
                    assessments = @()
                }
                $pendingAssessments = @($rawAssessments)
                $stages['Run capability']['state'] = $capabilityState
            }
        }
    }

    if (-not $halted) {
        $stages['Validate findings']['state'] = 'running'
        $knownUnits = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $unitEvidenceStates = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach ($unit in $evidence.evidenceUnits) {
            [void]$knownUnits.Add([string]($unit['unitId']))
            $unitEvidenceStates[[string]($unit['unitId'])] = [string]($unit['state'])
        }
        $assessmentIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $findingIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $unitAssessmentStates = [Collections.Generic.Dictionary[
            string, Collections.Generic.List[string]]]::new([StringComparer]::Ordinal)
        $normalizedAssessments = [Collections.Generic.List[object]]::new()
        $findingCount = 0
        $validationFailed = $false

        foreach ($assessment in $pendingAssessments) {
            if ($assessment -isnot [Collections.IDictionary] -or
                -not $assessment.Contains('assessmentId') -or
                -not $assessment.Contains('evidenceUnitIds') -or
                -not $assessment.Contains('state')) {
                $validationFailed = $true
                break
            }
            $assessmentId = [string]($assessment['assessmentId'])
            $assessmentState = [string]($assessment['state'])
            $assessmentUnitIds = @($assessment['evidenceUnitIds'] | ForEach-Object { [string]$_ })
            if ([string]::IsNullOrWhiteSpace($assessmentId) -or $assessmentId.Length -gt 128 -or
                $assessmentId -match '[\r\n]' -or -not $assessmentIds.Add($assessmentId) -or
                $assessmentState -cnotin $script:OwnerStates -or $assessmentUnitIds.Count -eq 0) {
                $validationFailed = $true
                break
            }
            $assessmentUnitSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($unitId in $assessmentUnitIds) {
                if (-not $knownUnits.Contains($unitId) -or -not $assessmentUnitSet.Add($unitId)) {
                    $validationFailed = $true
                    break
                }
                if (-not $unitAssessmentStates.ContainsKey($unitId)) {
                    $unitAssessmentStates[$unitId] = [Collections.Generic.List[string]]::new()
                }
                $unitAssessmentStates[$unitId].Add($assessmentState)
            }
            if ($validationFailed) { break }

            $normalizedFindings = [Collections.Generic.List[object]]::new()
            foreach ($finding in @(if ($assessment.Contains('findings')) { $assessment['findings'] })) {
                $findingCount++
                if ($findingCount -gt $script:OwnerMaximumFindings -or
                    $finding -isnot [Collections.IDictionary] -or
                    -not $finding.Contains('findingId') -or
                    -not $finding.Contains('summary')) {
                    $validationFailed = $true
                    break
                }
                $findingId = [string]($finding['findingId'])
                $summary = [string]($finding['summary'])
                if ([string]::IsNullOrWhiteSpace($findingId) -or $findingId.Length -gt 128 -or
                    $findingId -match '[\r\n]' -or -not $findingIds.Add($findingId) -or
                    [string]::IsNullOrWhiteSpace($summary) -or $summary.Length -gt 500 -or
                    $summary -match '[\r\n]') {
                    $validationFailed = $true
                    break
                }
                try {
                    $findingData = Copy-OwnerJsonValue -Value $(if ($finding.Contains('data')) { $finding['data'] } else { $null })
                }
                catch {
                    $validationFailed = $true
                    break
                }
                [void]$normalizedFindings.Add([ordered]@{
                        findingId = $findingId
                        summary = $summary
                        data = $findingData
                    })
            }
            if ($validationFailed) { break }
            $normalizedAssessment = [ordered]@{
                    assessmentId = $assessmentId
                    evidenceUnitIds = @($assessmentUnitIds)
                    state = $assessmentState
                    findings = @($normalizedFindings)
                }
            if ($assessment.Contains('data')) {
                try {
                    $normalizedAssessment['data'] = Copy-OwnerJsonValue -Value $assessment['data']
                }
                catch {
                    $validationFailed = $true
                    break
                }
            }
            [void]$normalizedAssessments.Add($normalizedAssessment)
        }

        if ($validationFailed) {
            Add-OwnerDiagnostic -Diagnostics $diagnostics -Code 'findings-invalid' `
                -Message 'Capability assessments or findings violated the generic facade contract.' `
                -Stage 'Validate findings'
            $stages['Validate findings']['state'] = 'failed'
            Complete-OwnerStageRecords -Stages $stages -AfterStage 'Validate findings'
            $halted = $true
        }
        else {
            $coverage = [Collections.Generic.List[object]]::new()
            foreach ($unit in $evidence.evidenceUnits) {
                $unitId = [string]($unit['unitId'])
                $evidenceState = $unitEvidenceStates[$unitId]
                $assessmentStates = @(
                    if ($unitAssessmentStates.ContainsKey($unitId)) { $unitAssessmentStates[$unitId] }
                )
                $coverageState = if ($evidenceState -eq 'unknown') {
                    'unknown'
                }
                elseif ($evidenceState -eq 'incomplete') {
                    'incomplete'
                }
                elseif ($assessmentStates.Count -eq 0 -or $assessmentStates -contains 'unknown') {
                    'unknown'
                }
                elseif ($assessmentStates -contains 'incomplete') {
                    'incomplete'
                }
                else {
                    'complete'
                }
                [void]$coverage.Add([ordered]@{
                        unitId = $unitId
                        state = $coverageState
                    })
            }

            $coverageStates = @($coverage | ForEach-Object { $_['state'] })
            $validationState = if ($coverageStates.Count -eq 0) {
                'unknown'
            }
            elseif ($evidence.state -eq 'unknown' -or $capability.state -eq 'unknown' -or
                $coverageStates -contains 'unknown') {
                'unknown'
            }
            elseif ($evidence.state -eq 'complete' -and $capability.state -eq 'complete' -and
                @($coverageStates | Where-Object { $_ -ne 'complete' }).Count -eq 0) {
                'complete'
            }
            else {
                'incomplete'
            }

            $validation = [ordered]@{
                schemaVersion = 1
                bindingId = $Binding.BindingId
                state = $validationState
                assessments = @($normalizedAssessments)
                unitCoverage = @($coverage)
            }
            $capability['assessments'] = @($normalizedAssessments)
            $stages['Validate findings']['state'] = $validationState
        }
    }

    if (-not $halted) {
        $stages['Preview']['state'] = 'running'
        $eligibleFindings = [Collections.Generic.List[object]]::new()
        foreach ($assessment in @($validation.assessments | Where-Object { $_['state'] -eq 'complete' })) {
            foreach ($finding in @($assessment['findings'])) {
                [void]$eligibleFindings.Add([ordered]@{
                        assessmentId = $assessment['assessmentId']
                        evidenceUnitIds = Copy-OwnerNormalizedValue -Value $assessment['evidenceUnitIds']
                        findingId = $finding['findingId']
                        summary = $finding['summary']
                        data = Copy-OwnerNormalizedValue -Value $finding['data']
                    })
            }
        }
        $preview = [ordered]@{
            schemaVersion = 1
            bindingId = $Binding.BindingId
            state = $validation.state
            evidenceDigest = $evidence.evidenceDigest
            findings = Copy-OwnerNormalizedValue -Value @($eligibleFindings)
            unitCoverage = Copy-OwnerNormalizedValue -Value $validation.unitCoverage
            writeAllowed = $false
        }
        $stages['Preview']['state'] = $preview.state
    }

    if (-not $halted) {
        $stages['Authorize delivery']['state'] = 'running'
        if (-not $AuthorizeDelivery) {
            $delivery = [ordered]@{
                schemaVersion = 1
                bindingId = $Binding.BindingId
                state = 'not-authorized'
                attempted = $false
                writeCount = 0
            }
            $stages['Authorize delivery']['state'] = 'complete'
        }
        elseif ($validation.state -ne 'complete') {
            Add-OwnerDiagnostic -Diagnostics $diagnostics -Code 'delivery-blocked' `
                -Message 'Delivery authorization was withheld because validation was not complete.' `
                -Stage 'Authorize delivery'
            $delivery = [ordered]@{
                schemaVersion = 1
                bindingId = $Binding.BindingId
                state = 'blocked'
                attempted = $false
                writeCount = 0
            }
            $stages['Authorize delivery']['state'] = 'incomplete'
        }
        else {
            $deliveryInput = [pscustomobject][ordered]@{
                schemaVersion = 1
                binding = $Binding
                preview = Copy-OwnerNormalizedValue -Value $preview
                authorization = [ordered]@{
                    bindingId = $Binding.BindingId
                    authorized = $true
                }
            }
            $deliveryInput.preview['writeAllowed'] = $true
            $deliveryResult = Invoke-OwnerAdapter -Adapter $DeliveryAdapter -AdapterInput $deliveryInput `
                -Diagnostics $diagnostics -Stage 'Authorize delivery'
            if (-not $deliveryResult.succeeded -or
                -not (Test-OwnerBoundResponse -Response $deliveryResult.value -Binding $Binding `
                    -Stage 'Authorize delivery' -Diagnostics $diagnostics)) {
                $delivery = [ordered]@{
                    schemaVersion = 1
                    bindingId = $Binding.BindingId
                    state = 'failed'
                    attempted = $true
                    writeCount = 0
                }
                $stages['Authorize delivery']['state'] = 'failed'
            }
            else {
                $rawDelivery = $deliveryResult.value
                $deliveryState = if ($rawDelivery.Contains('state')) { [string]($rawDelivery['state']) } else { '' }
                $writeCount = if ($rawDelivery.Contains('writeCount')) { $rawDelivery['writeCount'] } else { 0 }
                $parsedWriteCount = 0L
                $writeCountValid = $writeCount -isnot [bool] -and
                    [long]::TryParse(
                        [string]$writeCount,
                        [Globalization.NumberStyles]::Integer,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [ref]$parsedWriteCount)
                if ($deliveryState -cnotin @('delivered', 'no-op', 'unknown', 'failed') -or
                    -not $writeCountValid -or $parsedWriteCount -lt 0 -or $parsedWriteCount -gt 512) {
                    Add-OwnerDiagnostic -Diagnostics $diagnostics -Code 'delivery-invalid' `
                        -Message 'Delivery response violated the bounded facade contract.' `
                        -Stage 'Authorize delivery'
                    $delivery = [ordered]@{
                        schemaVersion = 1
                        bindingId = $Binding.BindingId
                        state = 'failed'
                        attempted = $true
                        writeCount = 0
                    }
                    $stages['Authorize delivery']['state'] = 'failed'
                }
                else {
                    Import-OwnerDiagnostics -Target $diagnostics `
                        -Value $(if ($rawDelivery.Contains('diagnostics')) { $rawDelivery['diagnostics'] } else { @() }) `
                        -Stage 'Authorize delivery'
                    $delivery = [ordered]@{
                        schemaVersion = 1
                        bindingId = $Binding.BindingId
                        state = $deliveryState
                        attempted = $true
                        writeCount = [int]$parsedWriteCount
                    }
                    $stages['Authorize delivery']['state'] = if ($deliveryState -eq 'failed') { 'failed' } `
                        elseif ($deliveryState -eq 'unknown') { 'unknown' } else { 'complete' }
                }
            }
        }
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        binding = $Binding
        state = Get-OwnerResultState -Stages $stages -Validation $validation
        stages = @($script:OwnerStageNames | ForEach-Object { [pscustomobject]$stages[$_] })
        snapshot = $snapshot
        evidence = $evidence
        capability = $capability
        validation = $validation
        preview = $preview
        delivery = $delivery
        diagnostics = @($diagnostics)
    }
}

Export-ModuleMember -Function @(
    'New-OwnerPipelineBinding',
    'New-OwnerPipelineAdapter',
    'Invoke-OwnerReviewPipeline'
)
