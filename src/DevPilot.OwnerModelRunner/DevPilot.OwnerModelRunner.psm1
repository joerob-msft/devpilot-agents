#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1"
Import-Module "$PSScriptRoot\..\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1"

$limitsTypeName = 'DevPilot.OwnerModelRunner.OwnerModelRunnerLimits'
if (-not ($limitsTypeName -as [type])) {
    Add-Type -TypeDefinition @'
namespace DevPilot.OwnerModelRunner
{
    public sealed class OwnerModelRunnerLimits
    {
        public int TotalDeadlineMilliseconds { get; }
        public int ActivityDeadlineMilliseconds { get; }
        public int PerCallDeadlineMilliseconds { get; }
        public int MaximumAttemptsPerUnit { get; }
        public int MaximumStdoutBytes { get; }
        public int MaximumStderrBytes { get; }
        public int MaximumOutputLines { get; }

        public OwnerModelRunnerLimits(
            int totalDeadlineMilliseconds,
            int activityDeadlineMilliseconds,
            int perCallDeadlineMilliseconds,
            int maximumAttemptsPerUnit,
            int maximumStdoutBytes,
            int maximumStderrBytes,
            int maximumOutputLines)
        {
            TotalDeadlineMilliseconds = totalDeadlineMilliseconds;
            ActivityDeadlineMilliseconds = activityDeadlineMilliseconds;
            PerCallDeadlineMilliseconds = perCallDeadlineMilliseconds;
            MaximumAttemptsPerUnit = maximumAttemptsPerUnit;
            MaximumStdoutBytes = maximumStdoutBytes;
            MaximumStderrBytes = maximumStderrBytes;
            MaximumOutputLines = maximumOutputLines;
        }
    }
}
'@
}

if (-not ('DevPilot.OwnerModelRunner.BoundedByteDrain' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace DevPilot.OwnerModelRunner
{
    public sealed class BoundedByteDrain
    {
        private readonly object gate = new object();
        private readonly MemoryStream captured = new MemoryStream();
        private readonly int maximumBytes;
        private readonly int maximumLines;
        private long lastActivityTimestamp;
        private int observedBytes;
        private int observedLines;
        private bool sawByte;
        private bool lastByteWasNewline;

        public BoundedByteDrain(int maximumBytes, int maximumLines)
        {
            this.maximumBytes = maximumBytes;
            this.maximumLines = maximumLines;
            lastActivityTimestamp = Stopwatch.GetTimestamp();
        }

        public long LastActivityTimestamp
        {
            get { return Interlocked.Read(ref lastActivityTimestamp); }
        }

        public bool Overflowed { get; private set; }

        public async Task ReadAsync(Stream stream)
        {
            var buffer = new byte[4096];
            int count;
            while ((count = await stream.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0)
            {
                Interlocked.Exchange(ref lastActivityTimestamp, Stopwatch.GetTimestamp());
                lock (gate)
                {
                    for (int index = 0; index < count; index++)
                    {
                        observedBytes++;
                        sawByte = true;
                        lastByteWasNewline = buffer[index] == 10;
                        if (lastByteWasNewline) observedLines++;
                        if (observedBytes <= maximumBytes && EffectiveLineCount() <= maximumLines)
                        {
                            captured.WriteByte(buffer[index]);
                        }
                        else
                        {
                            Overflowed = true;
                        }
                    }
                }
            }
        }

        public byte[] GetBytes()
        {
            lock (gate) { return captured.ToArray(); }
        }

        private int EffectiveLineCount()
        {
            return observedLines + (sawByte && !lastByteWasNewline ? 1 : 0);
        }
    }
}
'@
}

$script:MarkerPrefix = 'DEV_PILOT_OWNER_RESULT '
$script:JsonMarkerPrefix = 'DEV_PILOT_OWNER_RESULT_JSON '
$script:DigestPattern = '^v1:sha256:[0-9a-f]{64}$'
$script:NoncePattern = '^[0-9a-f]{36}$'
$script:ExecutionUnitPattern = '^unit:[0-9a-f]{64}$'
$script:Judgments = @('compliant', 'violation', 'unknown')
$script:CopilotCliMinimumVersion = [version]'1.0.79'
$script:CopilotCliInvocationContract = 'github-copilot-cli-acp-no-tools-v1'
$script:CopilotCliInvocationVersion = '2'
$script:CopilotCliCredentialNames = @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')
$script:CopilotCliNoToolsSentinel = '__devpilot_no_such_tool_7f2c17a64a3e4d6b__'
$script:CopilotCliArguments = @(
    '--acp',
    '--stdio',
    '--no-ask-user',
    '--disallow-temp-dir',
    "--available-tools=$script:CopilotCliNoToolsSentinel",
    '--disable-builtin-mcps',
    '--no-custom-instructions',
    '--no-remote',
    '--no-remote-export',
    '--no-auto-update',
    '--no-bash-env',
    '--no-experimental',
    '--no-color',
    '--log-level', 'none',
    '--max-autopilot-continues', '1',
    '--secret-env-vars=COPILOT_GITHUB_TOKEN'
)

function Assert-OwnerModelText {
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

function Get-OwnerModelMember {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Value -is [Collections.IDictionary] -and $Value.Contains($Name)) {
        $member = $Value[$Name]
        if ($member -is [byte[]]) {
            Write-Output -NoEnumerate $member
            return
        }
        return $member
    }
    if ($null -ne $Value) {
        $property = $Value.PSObject.Properties[$Name]
        if ($null -ne $property) {
            if ($property.Value -is [byte[]]) {
                Write-Output -NoEnumerate $property.Value
                return
            }
            return $property.Value
        }
    }
    return $null
}

function Get-OwnerModelInputDigest {
    param([Parameter(Mandatory)][object]$Request)
    return 'v1:sha256:' + (Get-AgentCanonicalDigest -InputObject $Request)
}

function Get-OwnerModelBytesDigest {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return 'v1:sha256:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)
    ).ToLowerInvariant()
}

function Get-OwnerModelFileDigest {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::Open(
        [IO.Path]::GetFullPath($Path),
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        return 'v1:sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($stream)
        ).ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
    }
}

function Get-OwnerModelSubjectBinding {
    param([Parameter(Mandatory)][string]$ExecutionUnitId)
    return 'v1:sha256:' + (Get-AgentSha256 -Text "owner-model-subject-v1|$ExecutionUnitId")
}

function ConvertTo-OwnerModelBase64Url {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-OwnerModelBase64Url {
    param([Parameter(Mandatory)][string]$Text)

    if ($Text -cnotmatch '^[A-Za-z0-9_-]+$') {
        throw 'Response marker payload was not base64url.'
    }
    $padded = $Text.Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) {
        0 {}
        2 { $padded += '==' }
        3 { $padded += '=' }
        default { throw 'Response marker payload had invalid base64url length.' }
    }
    $bytes = [Convert]::FromBase64String($padded)
    if ((ConvertTo-OwnerModelBase64Url -Bytes $bytes) -cne $Text) {
        throw 'Response marker payload was not canonical base64url.'
    }
    return $bytes
}

function ConvertTo-OwnerModelMarkerBytes {
    param([Parameter(Mandatory)][Collections.IDictionary]$Response)

    $json = ConvertTo-AgentCanonicalJson -InputObject $Response
    $payload = ConvertTo-OwnerModelBase64Url -Bytes ([Text.Encoding]::UTF8.GetBytes($json))
    return [Text.Encoding]::UTF8.GetBytes($script:MarkerPrefix + $payload + "`n")
}

function Test-OwnerModelExactKeys {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string[]]$Expected
    )

    $actual = @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
    $wanted = @($Expected | Sort-Object -CaseSensitive)
    return $actual.Count -eq $wanted.Count -and ($actual -join '|') -ceq ($wanted -join '|')
}

function ConvertFrom-OwnerModelResponseBytes {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$ExpectedNonce,
        [Parameter(Mandatory)][string]$ExpectedInputDigest,
        [Parameter(Mandatory)][string]$ExpectedSubjectBinding,
        [Parameter(Mandatory)][string]$ExpectedExecutionUnitId,
        [string]$ExpectedModelIdentity
    )

    try {
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $text = $utf8.GetString($Bytes).Replace("`r`n", "`n").Replace("`r", "`n")
    }
    catch {
        return [pscustomobject]@{ Valid = $false; AtomicFailure = $false; Judgment = 'unknown'; Failure = 'invalid-utf8' }
    }

    $markers = @(
        foreach ($line in $text.Split("`n")) {
            if ($line.StartsWith($script:MarkerPrefix, [StringComparison]::Ordinal) -or
                $line.StartsWith($script:JsonMarkerPrefix, [StringComparison]::Ordinal)) {
                $line
            }
        }
    )
    if ($markers.Count -ne 1) {
        return [pscustomobject]@{ Valid = $false; AtomicFailure = $false; Judgment = 'unknown'; Failure = 'marker-invalid' }
    }
    if ($markers[0].StartsWith($script:MarkerPrefix, [StringComparison]::Ordinal) -and
        $markers[0] -cnotmatch (
            '^' + [regex]::Escape($script:MarkerPrefix) + '[A-Za-z0-9_-]+$')) {
        return [pscustomobject]@{ Valid = $false; AtomicFailure = $false; Judgment = 'unknown'; Failure = 'marker-invalid' }
    }

    try {
        if ($markers[0].StartsWith($script:JsonMarkerPrefix, [StringComparison]::Ordinal)) {
            $json = $markers[0].Substring($script:JsonMarkerPrefix.Length)
            if ([string]::IsNullOrWhiteSpace($json)) { throw 'empty JSON marker' }
        }
        else {
            $payloadText = $markers[0].Substring($script:MarkerPrefix.Length)
            $payloadBytes = ConvertFrom-OwnerModelBase64Url -Text $payloadText
            $json = $utf8.GetString($payloadBytes)
        }
        $response = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 8 -NoEnumerate
    }
    catch {
        return [pscustomobject]@{ Valid = $false; AtomicFailure = $false; Judgment = 'unknown'; Failure = 'json-invalid' }
    }

    $responseSchemaVersion = Get-OwnerModelMember -Value $response -Name schemaVersion
    $topLevelValid = $response -is [Collections.IDictionary] -and (
        ($responseSchemaVersion -eq 1 -and [string]::IsNullOrEmpty($ExpectedModelIdentity) -and
            (Test-OwnerModelExactKeys -Value $response -Expected @(
                    'schemaVersion', 'nonce', 'inputDigest', 'subjectBinding', 'responses'
                ))) -or
        ($responseSchemaVersion -eq 2 -and
            (Test-OwnerModelExactKeys -Value $response -Expected @(
                    'schemaVersion', 'nonce', 'inputDigest', 'subjectBinding',
                    'modelIdentity', 'responses'
                )))
    )
    if (-not $topLevelValid -or
        $response.nonce -isnot [string] -or
        $response.inputDigest -isnot [string] -or
        $response.subjectBinding -isnot [string] -or
        ($responseSchemaVersion -eq 2 -and $response.modelIdentity -isnot [string]) -or
        $response.responses -isnot [Collections.IList] -or
        @($response.responses).Count -gt 16) {
        return [pscustomobject]@{ Valid = $false; AtomicFailure = $false; Judgment = 'unknown'; Failure = 'schema-invalid' }
    }

    if ([string]$response.nonce -cne $ExpectedNonce -or
        [string]$response.inputDigest -cne $ExpectedInputDigest -or
        [string]$response.subjectBinding -cne $ExpectedSubjectBinding -or
        ($responseSchemaVersion -eq 2 -and
            [string]$response.modelIdentity -cne $ExpectedModelIdentity)) {
        return [pscustomobject]@{ Valid = $false; AtomicFailure = $true; Judgment = 'unknown'; Failure = 'binding-mismatch' }
    }

    $matched = [Collections.Generic.List[string]]::new()
    foreach ($item in @($response.responses)) {
        $itemKeysValid = $item -is [Collections.IDictionary] -and (
            (Test-OwnerModelExactKeys -Value $item -Expected @('executionUnitId', 'judgment')) -or
            (Test-OwnerModelExactKeys -Value $item -Expected @('executionUnitId', 'judgment', 'rationale'))
        )
        if (-not $itemKeysValid -or
            $item.executionUnitId -isnot [string] -or
            [string]$item.executionUnitId -cnotmatch $script:ExecutionUnitPattern -or
            $item.judgment -isnot [string] -or
            [string]$item.judgment -cnotin $script:Judgments -or
            ($item.Contains('rationale') -and (
                $item.rationale -isnot [string] -or
                [string]::IsNullOrWhiteSpace([string]$item.rationale) -or
                [string]$item.rationale -cne ([string]$item.rationale).Trim() -or
                ([string]$item.rationale).Length -gt 512 -or
                [string]$item.rationale -match '[\r\n]'
            ))) {
            return [pscustomobject]@{ Valid = $false; AtomicFailure = $false; Judgment = 'unknown'; Failure = 'schema-invalid' }
        }
        if ([string]$item.executionUnitId -ceq $ExpectedExecutionUnitId) {
            [void]$matched.Add([string]$item.judgment)
        }
    }
    if ($matched.Count -eq 0) {
        return [pscustomobject]@{ Valid = $false; AtomicFailure = $false; Judgment = 'unknown'; Failure = 'response-omitted' }
    }
    if ($matched.Count -ne 1) {
        return [pscustomobject]@{ Valid = $false; AtomicFailure = $false; Judgment = 'unknown'; Failure = 'response-duplicate' }
    }
    return [pscustomobject]@{
        Valid = $true
        AtomicFailure = $false
        Judgment = $matched[0]
        Failure = $(if ($matched[0] -ceq 'unknown') { 'model-unknown' } else { 'none' })
        MarkerBytes = [Text.Encoding]::UTF8.GetBytes($markers[0] + "`n")
    }
}

function New-OwnerModelRunnerLimits {
    [CmdletBinding()]
    param(
        [ValidateRange(100, 600000)][int]$TotalDeadlineMilliseconds = 120000,
        [ValidateRange(50, 600000)][int]$ActivityDeadlineMilliseconds = 15000,
        [ValidateRange(100, 600000)][int]$PerCallDeadlineMilliseconds = 30000,
        [ValidateRange(1, 3)][int]$MaximumAttemptsPerUnit = 2,
        [ValidateRange(256, 1048576)][int]$MaximumStdoutBytes = 65536,
        [ValidateRange(256, 1048576)][int]$MaximumStderrBytes = 65536,
        [ValidateRange(1, 4096)][int]$MaximumOutputLines = 256
    )

    return [DevPilot.OwnerModelRunner.OwnerModelRunnerLimits]::new(
        $TotalDeadlineMilliseconds,
        $ActivityDeadlineMilliseconds,
        $PerCallDeadlineMilliseconds,
        $MaximumAttemptsPerUnit,
        $MaximumStdoutBytes,
        $MaximumStderrBytes,
        $MaximumOutputLines)
}

function New-OwnerModelTelemetryState {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Provider,
        [Parameter(Mandatory)][Collections.IDictionary]$Policy
    )

    return [pscustomobject]@{
        Provider = $Provider
        Policy = $Policy
        Records = [Collections.Generic.List[object]]::new()
    }
}

function Add-OwnerModelTelemetryRecord {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$ExecutionUnitId,
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)][bool]$ProcessStarted,
        [Parameter(Mandatory)][AllowNull()][object]$ModelStarted,
        [Parameter(Mandatory)][long]$LatencyMilliseconds,
        [Parameter(Mandatory)][string]$Outcome,
        [Parameter(Mandatory)][string]$InputDigest,
        [Parameter(Mandatory)][string]$Nonce,
        [Parameter(Mandatory)][string]$SubjectBinding,
        [Parameter(Mandatory)][string]$InvocationDigest,
        [Parameter(Mandatory)][string]$StdoutDigest,
        [Parameter(Mandatory)][string]$StderrDigest,
        [Parameter(Mandatory)][AllowNull()][object]$ExitCode,
        [Parameter(Mandatory)][string]$Timeout,
        [AllowNull()][string]$ResponseBytesBase64
    )

    [void]$State.Records.Add([pscustomobject][ordered]@{
            executionUnitId = $ExecutionUnitId
            attempt = $Attempt
            processStarted = $ProcessStarted
            modelStarted = $ModelStarted
            latencyMs = [Math]::Max(0L, $LatencyMilliseconds)
            outcome = $Outcome
            inputDigest = $InputDigest
            nonce = $Nonce
            subjectBinding = $SubjectBinding
            invocationDigest = $InvocationDigest
            stdoutDigest = $StdoutDigest
            stderrDigest = $StderrDigest
            exitCode = $ExitCode
            timeout = $Timeout
            responseBytesBase64 = $ResponseBytesBase64
        })
}

function Get-OwnerModelTelemetrySnapshot {
    param([Parameter(Mandatory)][object]$State)

    $records = @($State.Records)
    $terminalIndexes = [Collections.Generic.Dictionary[string,int]]::new(
        [StringComparer]::Ordinal)
    for ($index = 0; $index -lt $records.Count; $index++) {
        $terminalIndexes[$records[$index].executionUnitId] = $index
    }
    $failures = @(
        for ($index = 0; $index -lt $records.Count; $index++) {
            $record = $records[$index]
            if ($terminalIndexes[$record.executionUnitId] -eq $index -and
                $record.outcome -cne 'none') {
                [string]$record.outcome
            }
        }
    )
    $latency = if ($records.Count -eq 0) {
        0L
    }
    else {
        [long](($records | Measure-Object -Property latencyMs -Sum).Sum)
    }
    $modelStarts = if (@($records | Where-Object { $_.modelStarted -is [string] }).Count -gt 0) {
        'unknown'
    }
    else {
        @($records | Where-Object { $_.modelStarted -eq $true }).Count
    }
    return [ordered]@{
        attempts = $records.Count
        modelStarts = $modelStarts
        modelStartsMinimum = @($records | Where-Object { $_.modelStarted -eq $true }).Count
        latencyMs = $latency
        refusalReason = if ($failures.Count -eq 0) { 'none' } else { [string]$failures[-1] }
        provider = $State.Provider
        policy = $State.Policy
        records = @(
            foreach ($record in $records) {
                [ordered]@{
                    executionUnitId = $record.executionUnitId
                    attempt = $record.attempt
                    processStarted = $record.processStarted
                    modelStarted = $record.modelStarted
                    latencyMs = $record.latencyMs
                    outcome = $record.outcome
                    inputDigest = $record.inputDigest
                    nonce = $record.nonce
                    subjectBinding = $record.subjectBinding
                    invocationDigest = $record.invocationDigest
                    stdoutDigest = $record.stdoutDigest
                    stderrDigest = $record.stderrDigest
                    exitCode = $record.exitCode
                    timeout = $record.timeout
                    responseBytesBase64 = $record.responseBytesBase64
                }
            }
        )
    }
}

function Get-OwnerModelRunnerTelemetry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Runner)

    if ($Runner.PSTypeNames -cnotcontains 'DevPilot.OwnerCapability.SemanticRunner' -or
        $Runner.PSObject.Properties['TelemetryProvider'] -eq $null -or
        $Runner.TelemetryProvider -isnot [scriptblock]) {
        throw 'Runner does not expose Owner model telemetry.'
    }
    return & $Runner.TelemetryProvider
}

function New-OwnerModelReplayRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Request,
        [ValidateSet('compliant', 'violation', 'unknown')][string]$Judgment,
        [string]$Nonce = (New-AgentNonce),
        [string]$ModelIdentity,
        [byte[]]$ResponseBytes
    )

    $executionUnitId = [string](Get-OwnerModelMember -Value $Request -Name executionUnitId)
    if ($executionUnitId -cnotmatch $script:ExecutionUnitPattern) {
        throw 'Replay request must contain an opaque Owner execution-unit reference.'
    }
    if ($Nonce -cnotmatch $script:NoncePattern) {
        throw 'Replay nonce must be a lowercase 18-byte hexadecimal value.'
    }
    $inputDigest = Get-OwnerModelInputDigest -Request $Request
    $subjectBinding = Get-OwnerModelSubjectBinding -ExecutionUnitId $executionUnitId
    if ($null -eq $ResponseBytes) {
        if ([string]::IsNullOrWhiteSpace($Judgment)) {
            throw 'Judgment is required when ResponseBytes is not supplied.'
        }
        $response = [ordered]@{
                schemaVersion = $(if ([string]::IsNullOrEmpty($ModelIdentity)) { 1 } else { 2 })
                nonce = $Nonce
                inputDigest = $inputDigest
                subjectBinding = $subjectBinding
                responses = @(
                    [ordered]@{
                        executionUnitId = $executionUnitId
                        judgment = $Judgment
                    }
                )
            }
        if (-not [string]::IsNullOrEmpty($ModelIdentity)) {
            $response.Insert(4, 'modelIdentity', $ModelIdentity)
        }
        $ResponseBytes = ConvertTo-OwnerModelMarkerBytes -Response $response
    }
    return [pscustomobject][ordered]@{
        executionUnitId = $executionUnitId
        nonce = $Nonce
        inputDigest = $inputDigest
        subjectBinding = $subjectBinding
        modelIdentity = $ModelIdentity
        responseBytes = [byte[]]$ResponseBytes.Clone()
    }
}

function New-OwnerModelReplayFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)

    $copies = [Collections.Generic.List[object]]::new()
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in $Records) {
        $executionUnitId = [string](Get-OwnerModelMember -Value $record -Name executionUnitId)
        $nonce = [string](Get-OwnerModelMember -Value $record -Name nonce)
        $inputDigest = [string](Get-OwnerModelMember -Value $record -Name inputDigest)
        $subjectBinding = [string](Get-OwnerModelMember -Value $record -Name subjectBinding)
        $modelIdentity = [string](Get-OwnerModelMember -Value $record -Name modelIdentity)
        $responseBytes = Get-OwnerModelMember -Value $record -Name responseBytes
        if ($executionUnitId -cnotmatch $script:ExecutionUnitPattern -or
            -not $ids.Add($executionUnitId) -or
            $nonce -cnotmatch $script:NoncePattern -or
            $inputDigest -cnotmatch $script:DigestPattern -or
            $subjectBinding -cnotmatch $script:DigestPattern -or
            (-not [string]::IsNullOrEmpty($modelIdentity) -and (
                [string]::IsNullOrWhiteSpace($modelIdentity) -or
                $modelIdentity -cne $modelIdentity.Trim() -or
                $modelIdentity.Length -gt 128 -or
                $modelIdentity -match '[\r\n]')) -or
            $responseBytes -isnot [byte[]] -or
            $responseBytes.Length -gt 1048576) {
            throw 'Replay record violated the bounded sanitized fixture contract.'
        }
        [void]$copies.Add([pscustomobject][ordered]@{
                executionUnitId = $executionUnitId
                nonce = $nonce
                inputDigest = $inputDigest
                subjectBinding = $subjectBinding
                modelIdentity = $modelIdentity
                responseBytes = [byte[]]$responseBytes.Clone()
            })
    }
    $fixture = [pscustomobject][ordered]@{ Records = @($copies) }
    $fixture.PSTypeNames.Insert(0, 'DevPilot.OwnerModelRunner.ReplayFixture')
    return $fixture
}

function New-OwnerModelReplayRunner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Fixture,
        [string]$Name = 'owner-model-offline-replay'
    )

    Assert-OwnerModelText -Value $Name -Name Name -MaximumLength 128
    if ($Fixture.PSTypeNames -cnotcontains 'DevPilot.OwnerModelRunner.ReplayFixture') {
        throw 'Expected a fixture created by New-OwnerModelReplayFixture.'
    }
    $records = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($record in @($Fixture.Records)) { $records.Add($record.executionUnitId, $record) }
    $providerTelemetry = [ordered]@{
        kind = 'offline-replay'
        name = $Name
        modelIdentity = 'recorded-response-bytes'
        invocationContract = 'owner-model-replay-v1'
        invocationVersion = '1'
    }
    $policyTelemetry = [ordered]@{
        availableTools = @()
        mcpServers = @()
        customInstructions = $false
        memory = $false
        resume = $false
        repositoryAccess = $false
        networkAccess = $false
        providerWrite = $false
        environmentNames = @()
    }
    $telemetry = New-OwnerModelTelemetryState -Provider $providerTelemetry -Policy $policyTelemetry
    $getMemberCommand = Get-Command Get-OwnerModelMember -CommandType Function
    $getInputDigestCommand = Get-Command Get-OwnerModelInputDigest -CommandType Function
    $getSubjectBindingCommand = Get-Command Get-OwnerModelSubjectBinding -CommandType Function
    $parseResponseCommand = Get-Command ConvertFrom-OwnerModelResponseBytes -CommandType Function
    $getBytesDigestCommand = Get-Command Get-OwnerModelBytesDigest -CommandType Function
    $addTelemetryCommand = Get-Command Add-OwnerModelTelemetryRecord -CommandType Function
    $getTelemetryCommand = Get-Command Get-OwnerModelTelemetrySnapshot -CommandType Function
    $handler = {
        param($request)
        $unitId = [string](& $getMemberCommand -Value $request -Name executionUnitId)
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $outcome = 'response-omitted'
        $judgment = 'unknown'
        $record = $null
        $inputDigest = & $getInputDigestCommand -Request $request
        $subjectBinding = & $getSubjectBindingCommand -ExecutionUnitId $unitId
        $responseBytes = [byte[]]::new(0)
        $responseValid = $false
        if ($records.ContainsKey($unitId)) {
            $record = $records[$unitId]
            $responseBytes = [byte[]]$record.responseBytes.Clone()
            if ($inputDigest -cne $record.inputDigest -or $subjectBinding -cne $record.subjectBinding) {
                $outcome = 'binding-mismatch'
            }
            else {
                $parsed = & $parseResponseCommand `
                    -Bytes $record.responseBytes `
                    -ExpectedNonce $record.nonce `
                    -ExpectedInputDigest $inputDigest `
                    -ExpectedSubjectBinding $subjectBinding `
                    -ExpectedExecutionUnitId $unitId `
                    -ExpectedModelIdentity ([string]$record.modelIdentity)
                $judgment = $parsed.Judgment
                $outcome = $parsed.Failure
                $responseValid = $parsed.Valid
            }
        }
        $stopwatch.Stop()
        $responseBase64 = if ($responseValid) {
            [Convert]::ToBase64String($responseBytes)
        }
        else { $null }
        & $addTelemetryCommand -State $telemetry -ExecutionUnitId $unitId `
            -Attempt 1 -ProcessStarted $false -ModelStarted $false `
            -LatencyMilliseconds $stopwatch.ElapsedMilliseconds -Outcome $outcome `
            -InputDigest $inputDigest -Nonce $(if ($record) { $record.nonce } else { '0' * 36 }) `
            -SubjectBinding $subjectBinding `
            -InvocationDigest ('v1:sha256:' + ('0' * 64)) `
            -StdoutDigest (& $getBytesDigestCommand -Bytes $responseBytes) `
            -StderrDigest (& $getBytesDigestCommand -Bytes ([byte[]]::new(0))) `
            -ExitCode 0 -Timeout none -ResponseBytesBase64 $responseBase64
        return @{
            schemaVersion = 2
            executionUnitId = $unitId
            judgment = $judgment
        }
    }.GetNewClosure()
    $telemetryProvider = { & $getTelemetryCommand -State $telemetry }.GetNewClosure()
    return New-OwnerSemanticRunner -Name $Name -Handler $handler -TelemetryProvider $telemetryProvider
}

function Get-OwnerModelRepositoryRoot {
    return [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') '..'))
}

function Test-OwnerModelPathWithin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    $comparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    return $fullPath.Equals($fullRoot, $comparison) -or
        $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Assert-OwnerModelPathIsNotLink {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $null -ne $item.LinkType -or $null -ne $item.LinkTarget) {
        throw "Owner model isolation path '$Path' must not be a link or reparse point."
    }
}

function New-OwnerModelPrivateLaunchRoot {
    param([Parameter(Mandatory)][string]$BasePath)
    $absoluteBase = [IO.Path]::GetFullPath($BasePath)
    if (-not [IO.Path]::IsPathFullyQualified($absoluteBase) -or
        (Test-OwnerModelPathWithin -Path $absoluteBase -Root (Get-OwnerModelRepositoryRoot))) {
        throw 'Model launch root must be an absolute path outside the repository.'
    }
    if (-not (Test-Path -LiteralPath $absoluteBase -PathType Container)) {
        New-Item -ItemType Directory -Path $absoluteBase -Force | Out-Null
    }
    Assert-OwnerModelPathIsNotLink -Path $absoluteBase
    $privateRoot = Join-Path $absoluteBase ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($privateRoot)
    Assert-OwnerModelPathIsNotLink -Path $privateRoot
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode(
            $privateRoot,
            [IO.UnixFileMode]::UserRead -bor
            [IO.UnixFileMode]::UserWrite -bor
            [IO.UnixFileMode]::UserExecute)
    }
    return [IO.Path]::GetFullPath($privateRoot)
}

function Assert-OwnerModelExecutableShape {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Kind
    )
    if ($Kind -ne 'copilot-cli') { return }
    if ($IsWindows -and [IO.Path]::GetExtension($Path) -cne '.exe') {
        throw '[owner-model-launch-unavailable] Copilot CLI must resolve to a native .exe on Windows.'
    }
    if (-not $IsWindows) {
        $stream = [IO.File]::OpenRead($Path)
        try {
            if ($stream.Length -ge 2 -and $stream.ReadByte() -eq 35 -and $stream.ReadByte() -eq 33) {
                throw '[owner-model-launch-unavailable] Copilot CLI must be a native executable, not an interpreter shim.'
            }
        }
        finally {
            $stream.Dispose()
        }
    }
}

function Resolve-OwnerModelExecutablePath {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath ([IO.Path]::GetFullPath($Path)) -Force
    if ($item.LinkType -and $item.LinkType -cne 'HardLink') {
        $target = $item.ResolveLinkTarget($true)
        if ($null -eq $target) {
            throw '[owner-model-launch-unavailable] Model provider executable link target could not be resolved.'
        }
        return [IO.Path]::GetFullPath($target.FullName)
    }
    return [IO.Path]::GetFullPath($item.FullName)
}

function New-OwnerModelProviderObject {
    param(
        [Parameter(Mandatory)][ValidateSet('copilot-cli', 'fake-process')][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$ModelIdentity,
        [Parameter(Mandatory)][string]$InvocationContract,
        [Parameter(Mandatory)][string]$InvocationVersion,
        [Parameter(Mandatory)][string]$LaunchRoot,
        [string[]]$ArgumentPrefix = @(),
        [AllowNull()][string]$CredentialEnvironmentName,
        [ValidateSet('real-when-valid', 'always-zero')][string]$ModelStartPolicy
    )

    Assert-OwnerModelText -Value $Name -Name Name -MaximumLength 128
    Assert-OwnerModelText -Value $ModelIdentity -Name ModelIdentity -MaximumLength 128
    Assert-OwnerModelText -Value $InvocationContract -Name InvocationContract -MaximumLength 128
    Assert-OwnerModelText -Value $InvocationVersion -Name InvocationVersion -MaximumLength 32
    $absolute = Resolve-OwnerModelExecutablePath -Path $FilePath
    if (-not [IO.Path]::IsPathFullyQualified($absolute) -or
        -not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
        throw 'Model provider executable must be an existing absolute file.'
    }
    Assert-OwnerModelExecutableShape -Path $absolute -Kind $Kind
    $absoluteRoot = New-OwnerModelPrivateLaunchRoot -BasePath $LaunchRoot
    $provider = [pscustomobject][ordered]@{
        Kind = $Kind
        Name = $Name
        FilePath = $absolute
        ModelIdentity = $ModelIdentity
        InvocationContract = $InvocationContract
        InvocationVersion = $InvocationVersion
        LaunchRoot = $absoluteRoot
        ArgumentPrefix = @($ArgumentPrefix)
        ExecutableSha256 = (Get-OwnerModelFileDigest -Path $absolute).Substring(10)
        PublisherIdentity = $(if ($Kind -ceq 'copilot-cli' -and
                (Test-OwnerCopilotPublisherIdentity -Path $absolute)) {
                'verified-github'
            }
            elseif ($Kind -ceq 'copilot-cli') {
                'not-proven'
            }
            else {
                'not-applicable'
            })
        CredentialEnvironmentName = $CredentialEnvironmentName
        ModelStartPolicy = $ModelStartPolicy
    }
    $provider.PSTypeNames.Insert(0, 'DevPilot.OwnerModelRunner.ModelProvider')
    Remove-OwnerModelPrivateLaunchRoot -Provider $provider
    return $provider
}

function New-OwnerCopilotCliModelProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Model,
        [string]$FilePath,
        [ValidateSet('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')]
        [string]$CredentialEnvironmentName,
        [string]$LaunchRoot = (Join-Path ([IO.Path]::GetTempPath()) 'devpilot-owner-model-launch'),
        [string]$Name = 'owner-model-copilot-cli-no-tools'
    )

    [void](Assert-AgentSupportedModel -ModelId $Model -Where 'Owner model')
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        $commands = @(Get-Command copilot -CommandType Application -ErrorAction SilentlyContinue)
        if ($commands.Count -ne 1) {
            throw '[owner-model-launch-unavailable] Exactly one Copilot CLI executable is required.'
        }
        $FilePath = $commands[0].Source
    }
    if ([string]::IsNullOrWhiteSpace($CredentialEnvironmentName)) {
        $selectedCredentialNames = @(
            $script:CopilotCliCredentialNames | Where-Object {
                -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_))
            } | Select-Object -First 1
        )
        if ($selectedCredentialNames.Count -eq 0) {
            $CredentialEnvironmentName = 'COPILOT_GITHUB_TOKEN'
        }
        else {
            $CredentialEnvironmentName = [string]$selectedCredentialNames[0]
        }
    }
    return New-OwnerModelProviderObject -Kind copilot-cli -Name $Name `
        -FilePath $FilePath -ModelIdentity $Model `
        -InvocationContract $script:CopilotCliInvocationContract `
        -InvocationVersion $script:CopilotCliInvocationVersion `
        -LaunchRoot $LaunchRoot -ArgumentPrefix $script:CopilotCliArguments `
        -CredentialEnvironmentName $CredentialEnvironmentName `
        -ModelStartPolicy real-when-valid
}

function New-OwnerModelFakeProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$LaunchRoot = (Join-Path ([IO.Path]::GetTempPath()) 'devpilot-owner-model-fake'),
        [string]$Name = 'owner-model-deterministic-fake'
    )

    return New-OwnerModelProviderObject -Kind fake-process -Name $Name `
        -FilePath $FilePath -ModelIdentity 'deterministic-fake-process' `
        -InvocationContract 'owner-model-fake-process-v1' -InvocationVersion '1' `
        -LaunchRoot $LaunchRoot -ArgumentPrefix $ArgumentList -ModelStartPolicy always-zero
}

function Assert-OwnerModelProvider {
    param([Parameter(Mandatory)][object]$Provider)

    if ($Provider.PSTypeNames -cnotcontains 'DevPilot.OwnerModelRunner.ModelProvider') {
        throw 'Expected an Owner model provider.'
    }
    try {
        $currentExecutableSha256 = (Get-OwnerModelFileDigest `
                -Path ([string]$Provider.FilePath)).Substring(10)
    }
    catch {
        throw '[owner-model-launch-unavailable] Model provider executable could not be verified.'
    }
    if ([string]$Provider.ExecutableSha256 -cne $currentExecutableSha256) {
        throw '[owner-model-launch-unavailable] Model provider executable hash changed after construction.'
    }
    if ($Provider.Kind -ceq 'copilot-cli') {
        $currentPublisherIdentity = if (
            Test-OwnerCopilotPublisherIdentity -Path ([string]$Provider.FilePath)) {
            'verified-github'
        }
        else {
            'not-proven'
        }
        if ($Provider.InvocationContract -cne $script:CopilotCliInvocationContract -or
            $Provider.InvocationVersion -cne $script:CopilotCliInvocationVersion -or
            (@($Provider.ArgumentPrefix) -join "`0") -cne ($script:CopilotCliArguments -join "`0") -or
            $Provider.CredentialEnvironmentName -cnotin $script:CopilotCliCredentialNames -or
            $Provider.PublisherIdentity -cne $currentPublisherIdentity -or
            $Provider.ModelStartPolicy -cne 'real-when-valid') {
            throw '[owner-model-launch-unavailable] Copilot provider policy was mutated.'
        }
    }
    elseif ($Provider.Kind -ceq 'fake-process') {
        if ($Provider.InvocationContract -cne 'owner-model-fake-process-v1' -or
            $Provider.ModelStartPolicy -cne 'always-zero' -or
            -not [string]::IsNullOrEmpty([string]$Provider.CredentialEnvironmentName)) {
            throw 'Fake model provider policy was mutated.'
        }
    }
    else {
        throw 'Owner model provider kind is unsupported.'
    }
}

function Copy-OwnerModelPinnedExecutable {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][string]$AttemptDirectory
    )
    Assert-OwnerModelProvider -Provider $Provider
    if ($Provider.Kind -cne 'copilot-cli') {
        return [string]$Provider.FilePath
    }
    $extension = [IO.Path]::GetExtension([string]$Provider.FilePath)
    $destination = Join-Path $AttemptDirectory "provider$extension"
    $sourceStream = [IO.File]::Open(
        [string]$Provider.FilePath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        $destinationStream = [IO.File]::Open(
            $destination,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        try {
            $sourceStream.CopyTo($destinationStream)
            $destinationStream.Flush($true)
        }
        finally {
            $destinationStream.Dispose()
        }
    }
    finally {
        $sourceStream.Dispose()
    }
    if ((Get-OwnerModelFileDigest -Path $destination).Substring(10) -cne
        [string]$Provider.ExecutableSha256) {
        throw '[owner-model-launch-unavailable] Staged model provider executable hash did not match its pin.'
    }
    if ($Provider.PublisherIdentity -ceq 'verified-github' -and
        -not (Test-OwnerCopilotPublisherIdentity -Path $destination)) {
        throw '[owner-model-launch-unavailable] Staged Copilot executable publisher identity was not valid.'
    }
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode(
            $destination,
            [IO.UnixFileMode]::UserRead -bor
            [IO.UnixFileMode]::UserWrite -bor
            [IO.UnixFileMode]::UserExecute)
    }
    return [IO.Path]::GetFullPath($destination)
}

function Test-OwnerCopilotPublisherIdentity {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $IsWindows) { return $false }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    return $signature.Status -eq [Management.Automation.SignatureStatus]::Valid -and
        $null -ne $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -cmatch (
            '(^|,\s*)O="GitHub, Inc\."(,|$)')
}

function Test-OwnerModelAcpAtomicContainmentAvailable {
    if ($IsWindows) {
        # System.Diagnostics.Process starts executing before a job can be assigned.
        return $false
    }
    return Test-OwnerModelContainmentAvailable
}

function New-OwnerModelAttemptDirectory {
    param([Parameter(Mandatory)][object]$Provider)
    Assert-OwnerModelProvider -Provider $Provider
    if (-not (Test-Path -LiteralPath $Provider.LaunchRoot -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($Provider.LaunchRoot)
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode(
                $Provider.LaunchRoot,
                [IO.UnixFileMode]::UserRead -bor
                [IO.UnixFileMode]::UserWrite -bor
                [IO.UnixFileMode]::UserExecute)
        }
    }
    Assert-OwnerModelPathIsNotLink -Path $Provider.LaunchRoot
    $directory = Join-Path $Provider.LaunchRoot ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    Assert-OwnerModelPathIsNotLink -Path $directory
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode(
            $directory,
            [IO.UnixFileMode]::UserRead -bor
            [IO.UnixFileMode]::UserWrite -bor
            [IO.UnixFileMode]::UserExecute)
    }
    foreach ($leaf in @('home', 'appdata', 'localappdata', 'temp')) {
        New-Item -ItemType Directory -Path (Join-Path $directory $leaf) | Out-Null
    }
    return [IO.Path]::GetFullPath($directory)
}

function Remove-OwnerModelPrivateLaunchRoot {
    param([Parameter(Mandatory)][object]$Provider)
    if (-not (Test-Path -LiteralPath $Provider.LaunchRoot -PathType Container)) { return }
    Assert-OwnerModelPathIsNotLink -Path $Provider.LaunchRoot
    if (@(Get-ChildItem -LiteralPath $Provider.LaunchRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $Provider.LaunchRoot -Force
    }
}

function Get-OwnerModelProcessEnvironment {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][string]$AttemptDirectory,
        [switch]$IncludeCredential
    )
    Assert-OwnerModelProvider -Provider $Provider
    $environment = [ordered]@{
        HOME = Join-Path $AttemptDirectory 'home'
        USERPROFILE = Join-Path $AttemptDirectory 'home'
        APPDATA = Join-Path $AttemptDirectory 'appdata'
        LOCALAPPDATA = Join-Path $AttemptDirectory 'localappdata'
        TEMP = Join-Path $AttemptDirectory 'temp'
        TMP = Join-Path $AttemptDirectory 'temp'
    }
    if ($IsWindows) {
        foreach ($name in @('SystemRoot', 'WINDIR')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if (-not [string]::IsNullOrEmpty($value)) { $environment[$name] = $value }
        }
    }
    if ($Provider.Kind -ceq 'copilot-cli') {
        $environment['COPILOT_HOME'] = Join-Path $AttemptDirectory 'home'
        $environment['COPILOT_AUTO_UPDATE'] = 'false'
        $environment['COPILOT_OTEL_ENABLED'] = 'false'
        $environment['COPILOT_MULTIPLEXER'] = 'none'
        $environment['NO_COLOR'] = '1'
        if ($IncludeCredential) {
            $credential = [Environment]::GetEnvironmentVariable(
                [string]$Provider.CredentialEnvironmentName)
            if ([string]::IsNullOrEmpty($credential)) {
                throw '[owner-model-launch-unavailable] Selected Copilot credential is absent.'
            }
            $environment['COPILOT_GITHUB_TOKEN'] = $credential
        }
    }
    else {
        foreach ($name in @('PATH', 'PATHEXT', 'PSModulePath')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if (-not [string]::IsNullOrEmpty($value)) { $environment[$name] = $value }
        }
        $environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
        $environment['DEV_PILOT_OWNER_MODEL_TEST_ONLY'] = '1'
    }
    return $environment
}

function Get-OwnerModelPolicyEnvironmentNames {
    param([Parameter(Mandatory)][object]$Provider)
    $names = @(
        (Get-OwnerModelProcessEnvironment -Provider $Provider `
            -AttemptDirectory (Join-Path $Provider.LaunchRoot 'policy')).Keys |
            ForEach-Object { [string]$_ }
    )
    if ($Provider.Kind -ceq 'copilot-cli') { $names += 'COPILOT_GITHUB_TOKEN' }
    return @($names | Sort-Object -Unique)
}

function New-OwnerModelInvocation {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][string]$EnvelopeBase64,
        [Parameter(Mandatory)][string]$AttemptDirectory,
        [switch]$IncludeCredential
    )
    Assert-OwnerModelProvider -Provider $Provider
    if ($Provider.Kind -ceq 'copilot-cli') {
        throw '[owner-model-launch-unavailable] copilot-cli-acp-confidentiality-unproven'
    }
    $stimulusPath = Join-Path $AttemptDirectory 'bounded-stimulus.b64'
    [IO.File]::WriteAllText(
        $stimulusPath,
        $EnvelopeBase64,
        [Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode(
            $stimulusPath,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
    }
    $arguments = @($Provider.ArgumentPrefix) + @($stimulusPath)
    $environment = Get-OwnerModelProcessEnvironment -Provider $Provider `
        -AttemptDirectory $AttemptDirectory -IncludeCredential:$IncludeCredential
    $safeEnvironmentNames = @($environment.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    $expectedEnvironmentNames = @(Get-OwnerModelPolicyEnvironmentNames -Provider $Provider)
    if (($safeEnvironmentNames -join "`0") -cne ($expectedEnvironmentNames -join "`0")) {
        throw 'Owner model invocation environment did not match the code-defined allowlist.'
    }
    return [pscustomobject][ordered]@{
        FilePath = [string]$Provider.FilePath
        ArgumentList = @($arguments)
        Environment = $environment
        EnvironmentNames = $safeEnvironmentNames
        WorkingDirectory = $AttemptDirectory
        InvocationDigest = 'v1:sha256:' + (Get-AgentCanonicalDigest -InputObject ([ordered]@{
                    fileSha256 = 'v1:sha256:' + [string]$Provider.ExecutableSha256
                    arguments = @($Provider.ArgumentPrefix) + @('bounded-stimulus.b64')
                    stimulusDigest = Get-OwnerModelBytesDigest -Bytes (
                        [Text.Encoding]::UTF8.GetBytes($EnvelopeBase64))
                    environmentNames = $safeEnvironmentNames
                    workingDirectoryPolicy = 'fresh-isolated-directory-with-bounded-stimulus'
                }))
    }
}

function Invoke-OwnerModelPreflightCommand {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$AttemptDirectory,
        [string]$ExecutablePath = [string]$Provider.FilePath
    )
    $environment = Get-OwnerModelProcessEnvironment -Provider $Provider `
        -AttemptDirectory $AttemptDirectory
    $psi = [Diagnostics.ProcessStartInfo]::new()
    Set-OwnerModelContainedCommand -Psi $psi -FilePath $ExecutablePath `
        -ArgumentList $ArgumentList
    $psi.WorkingDirectory = $AttemptDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Environment.Clear()
    foreach ($entry in $environment.GetEnumerator()) {
        $psi.Environment[[string]$entry.Key] = [string]$entry.Value
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $containment = $null
    $started = $false
    $stdoutDrain = [DevPilot.OwnerModelRunner.BoundedByteDrain]::new(131072, 4096)
    $stderrDrain = [DevPilot.OwnerModelRunner.BoundedByteDrain]::new(131072, 4096)
    try {
        if (-not $process.Start()) { throw 'Copilot preflight process did not start.' }
        $started = $true
        $containment = New-AgentProcessContainment -Process $process
        $process.StandardInput.Close()
        $stdoutTask = $stdoutDrain.ReadAsync($process.StandardOutput.BaseStream)
        $stderrTask = $stderrDrain.ReadAsync($process.StandardError.BaseStream)
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not $process.HasExited) {
            if ([DateTime]::UtcNow -ge $deadline) {
                [void](Stop-AgentProcessContainment -Containment $containment -Process $process)
                throw 'Copilot preflight process timed out.'
            }
            if ($stdoutDrain.Overflowed -or $stderrDrain.Overflowed) {
                [void](Stop-AgentProcessContainment -Containment $containment -Process $process)
                throw 'Copilot preflight output exceeded its fixed limit.'
            }
            Start-Sleep -Milliseconds 20
        }
        $settleDeadline = [DateTime]::UtcNow.AddMilliseconds(750)
        while ([DateTime]::UtcNow -lt $settleDeadline -and
            -not (Test-AgentProcessContainmentExited -Containment $containment -Process $process)) {
            Start-Sleep -Milliseconds 20
        }
        if (-not (Test-AgentProcessContainmentExited -Containment $containment -Process $process)) {
            [void](Stop-AgentProcessContainment -Containment $containment -Process $process)
            throw 'Copilot preflight descendant process survived.'
        }
        if (-not [Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000)) {
            throw 'Copilot preflight output drain timed out.'
        }
        if ($stdoutDrain.Overflowed -or $stderrDrain.Overflowed) {
            throw 'Copilot preflight output exceeded its fixed limit.'
        }
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $utf8.GetString($stdoutDrain.GetBytes())
            Stderr = $utf8.GetString($stderrDrain.GetBytes())
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            if ($containment) {
                [void](Stop-AgentProcessContainment -Containment $containment -Process $process)
            }
            else {
                Stop-ProcessTree -Process $process
            }
        }
        Close-AgentProcessContainment -Containment $containment
        $process.Dispose()
    }
}

function Assert-OwnerAcpJsonHasNoDuplicateProperties {
    param([Parameter(Mandatory)][Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) {
                throw 'ACP initialize response contained a duplicate JSON property.'
            }
            Assert-OwnerAcpJsonHasNoDuplicateProperties -Element $property.Value
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) {
            Assert-OwnerAcpJsonHasNoDuplicateProperties -Element $item
        }
    }
}

function Invoke-OwnerModelAcpInitializePreflight {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][string]$AttemptDirectory,
        [string]$ExecutablePath = [string]$Provider.FilePath,
        [string[]]$ArgumentList = (
            @($Provider.ArgumentPrefix) + @('--model', [string]$Provider.ModelIdentity)),
        [int]$DeadlineMilliseconds = 10000
    )

    Assert-OwnerModelProvider -Provider $Provider
    if ($Provider.Kind -ceq 'copilot-cli' -and
        -not (Test-OwnerModelAcpAtomicContainmentAvailable)) {
        throw 'ACP atomic process containment is unavailable on this platform.'
    }
    $environment = Get-OwnerModelProcessEnvironment -Provider $Provider `
        -AttemptDirectory $AttemptDirectory
    if ($environment.Contains('COPILOT_GITHUB_TOKEN')) {
        throw 'ACP initialize preflight must not receive a provider credential.'
    }
    if ($Provider.Kind -ceq 'copilot-cli') {
        $argumentOptions = @(
            $ArgumentList |
                Where-Object { $_ -clike '-*' } |
                ForEach-Object { ([string]$_ -split '=', 2)[0] }
        )
        if ($argumentOptions -cnotcontains '--acp' -or
            $argumentOptions -cnotcontains '--stdio' -or
            @($argumentOptions | Where-Object {
                    $_ -cin @('-p', '--prompt', '-i', '--interactive')
                }).Count -ne 0) {
            throw 'ACP initialize preflight argument policy was widened.'
        }
    }
    $safeEnvironmentNames = @(
        $environment.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    $expectedEnvironmentNames = @(
        Get-OwnerModelPolicyEnvironmentNames -Provider $Provider |
            Where-Object { $_ -cne 'COPILOT_GITHUB_TOKEN' })
    if (($safeEnvironmentNames -join "`0") -cne ($expectedEnvironmentNames -join "`0")) {
        throw 'ACP initialize preflight environment did not match the code-defined allowlist.'
    }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    Set-OwnerModelContainedCommand -Psi $psi -FilePath $ExecutablePath `
        -ArgumentList $ArgumentList
    $psi.WorkingDirectory = $AttemptDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $psi.StandardInputEncoding = $utf8
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.Environment.Clear()
    foreach ($entry in $environment.GetEnumerator()) {
        $psi.Environment[[string]$entry.Key] = [string]$entry.Value
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $containment = $null
    $started = $false
    $stdinClosed = $false
    $stdoutDrain = [DevPilot.OwnerModelRunner.BoundedByteDrain]::new(65536, 8)
    $stderrDrain = [DevPilot.OwnerModelRunner.BoundedByteDrain]::new(65536, 64)
    try {
        if (-not $process.Start()) { throw 'ACP initialize process did not start.' }
        $started = $true
        $containment = New-AgentProcessContainment -Process $process
        $stdoutTask = $stdoutDrain.ReadAsync($process.StandardOutput.BaseStream)
        $stderrTask = $stderrDrain.ReadAsync($process.StandardError.BaseStream)
        $initializeRequest = ConvertTo-Json -InputObject ([ordered]@{
                jsonrpc = '2.0'
                id = 1
                method = 'initialize'
                params = [ordered]@{
                    protocolVersion = 1
                    clientCapabilities = [ordered]@{
                        fs = [ordered]@{
                            readTextFile = $false
                            writeTextFile = $false
                        }
                        terminal = $false
                        auth = [ordered]@{ terminal = $false }
                    }
                    clientInfo = [ordered]@{
                        name = 'devpilot-owner-preflight'
                        title = 'DevPilot Owner Preflight'
                        version = '1'
                    }
                }
            }) -Depth 8 -Compress
        $process.StandardInput.WriteLine($initializeRequest)
        $process.StandardInput.Flush()

        $deadline = [DateTime]::UtcNow.AddMilliseconds($DeadlineMilliseconds)
        $sawResponseLine = $false
        while (-not $process.HasExited) {
            if ($stdoutDrain.Overflowed -or $stderrDrain.Overflowed) {
                throw 'ACP initialize output exceeded its fixed limit.'
            }
            $stdoutBytes = $stdoutDrain.GetBytes()
            if ([Array]::IndexOf($stdoutBytes, [byte]10) -ge 0) {
                $sawResponseLine = $true
                break
            }
            if ([DateTime]::UtcNow -ge $deadline) {
                throw 'ACP initialize response timed out.'
            }
            Start-Sleep -Milliseconds 20
        }
        if (-not $sawResponseLine) {
            if ($process.HasExited -and
                -not [Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 1000)) {
                throw 'ACP initialize output drain timed out after process exit.'
            }
            if ($stdoutDrain.Overflowed -or $stderrDrain.Overflowed) {
                throw 'ACP initialize output exceeded its fixed limit.'
            }
            $stdoutBytes = $stdoutDrain.GetBytes()
            $sawResponseLine = [Array]::IndexOf($stdoutBytes, [byte]10) -ge 0
        }
        if (-not $sawResponseLine -and $process.HasExited) {
            throw 'ACP initialize process exited before responding.'
        }

        $process.StandardInput.Close()
        $stdinClosed = $true
        $exitDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not $process.HasExited -and [DateTime]::UtcNow -lt $exitDeadline) {
            if ($stdoutDrain.Overflowed -or $stderrDrain.Overflowed) {
                throw 'ACP initialize output exceeded its fixed limit.'
            }
            Start-Sleep -Milliseconds 20
        }
        if (-not $process.HasExited) {
            throw 'ACP server did not terminate after its protocol input closed.'
        }
        $settleDeadline = [DateTime]::UtcNow.AddMilliseconds(750)
        while ([DateTime]::UtcNow -lt $settleDeadline -and
            -not (Test-AgentProcessContainmentExited -Containment $containment -Process $process)) {
            Start-Sleep -Milliseconds 20
        }
        if (-not (Test-AgentProcessContainmentExited -Containment $containment -Process $process)) {
            throw 'ACP initialize descendant process survived.'
        }
        if (-not [Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000)) {
            throw 'ACP initialize output drain timed out.'
        }
        if ($stdoutDrain.Overflowed -or $stderrDrain.Overflowed) {
            throw 'ACP initialize output exceeded its fixed limit.'
        }
        if ($process.ExitCode -ne 0) {
            throw "ACP initialize process exited with code $($process.ExitCode)."
        }

        $stdoutBytes = $stdoutDrain.GetBytes()
        $stdoutText = $utf8.GetString($stdoutBytes)
        if ($stdoutText -notmatch '\A[^\r\n]+\r?\n\z') {
            throw 'ACP initialize emitted an unexpected protocol message count.'
        }
        $lines = @($stdoutText.TrimEnd("`r", "`n"))
        $document = [Text.Json.JsonDocument]::Parse($lines[0])
        try {
            Assert-OwnerAcpJsonHasNoDuplicateProperties -Element $document.RootElement
            $root = $document.RootElement
            if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
                throw 'ACP initialize response was not a JSON object.'
            }
            $rootNames = @($root.EnumerateObject() | ForEach-Object Name | Sort-Object)
            if (($rootNames -join "`0") -cne (@('id', 'jsonrpc', 'result') -join "`0")) {
                throw 'ACP initialize response envelope was not the required JSON-RPC result.'
            }
            if ($root.GetProperty('jsonrpc').GetString() -cne '2.0' -or
                $root.GetProperty('id').GetInt32() -ne 1) {
                throw 'ACP initialize response binding did not match the request.'
            }
            $result = $root.GetProperty('result')
            if ($result.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
                $result.GetProperty('protocolVersion').GetInt32() -ne 1) {
                throw 'ACP protocol version negotiation did not select version 1.'
            }
            $capabilities = $result.GetProperty('agentCapabilities')
            if ($capabilities.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
                throw 'ACP initialize response omitted agent capabilities.'
            }
            $loadSession = $false
            $loadProperty = [Text.Json.JsonElement]::new()
            if ($capabilities.TryGetProperty('loadSession', [ref]$loadProperty)) {
                if ($loadProperty.ValueKind -notin @(
                        [Text.Json.JsonValueKind]::True,
                        [Text.Json.JsonValueKind]::False)) {
                    throw 'ACP loadSession capability was not boolean.'
                }
                $loadSession = $loadProperty.GetBoolean()
            }
            $sessionCapabilityNames = @()
            $sessionCapabilities = [Text.Json.JsonElement]::new()
            if ($capabilities.TryGetProperty('sessionCapabilities', [ref]$sessionCapabilities)) {
                if ($sessionCapabilities.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
                    throw 'ACP sessionCapabilities was not an object.'
                }
                $sessionCapabilityNames = @(
                    $sessionCapabilities.EnumerateObject() |
                        ForEach-Object Name |
                        Sort-Object
                )
            }
            $agentVersion = 'unknown'
            $agentInfo = [Text.Json.JsonElement]::new()
            if ($result.TryGetProperty('agentInfo', [ref]$agentInfo) -and
                $agentInfo.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $versionProperty = [Text.Json.JsonElement]::new()
                if ($agentInfo.TryGetProperty('version', [ref]$versionProperty) -and
                    $versionProperty.ValueKind -eq [Text.Json.JsonValueKind]::String) {
                    $agentVersion = $versionProperty.GetString()
                }
            }
            return [pscustomobject][ordered]@{
                protocolVersion = 1
                agentVersion = $agentVersion
                loadSession = $loadSession
                sessionCapabilities = $sessionCapabilityNames
                stdoutDigest = Get-OwnerModelBytesDigest -Bytes $stdoutBytes
                stderrDigest = Get-OwnerModelBytesDigest -Bytes $stderrDrain.GetBytes()
                modelCalls = 0
            }
        }
        finally {
            $document.Dispose()
        }
    }
    finally {
        if ($started -and -not $stdinClosed) {
            $process.StandardInput.Close()
        }
        if ($started -and -not $process.HasExited) {
            if ($containment) {
                [void](Stop-AgentProcessContainment -Containment $containment -Process $process)
            }
            else {
                Stop-ProcessTree -Process $process
            }
        }
        Close-AgentProcessContainment -Containment $containment
        $process.Dispose()
    }
}

function Test-OwnerModelContainmentAvailable {
    if ($IsWindows) { return $true }
    if (Get-Command setsid -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1) {
        return $true
    }
    return $null -ne (
        Get-Command perl -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1)
}

function New-OwnerModelPreflightResult {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][bool]$Available,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$CredentialState,
        [string]$CliVersion = 'not-checked',
        [bool]$ProcessContainment = $false,
        [bool]$AtomicProcessContainment = $false
    )
    return [pscustomobject][ordered]@{
        available = $Available
        reason = $Reason
        credential = [ordered]@{
            sourceName = [string]$Provider.CredentialEnvironmentName
            childName = 'COPILOT_GITHUB_TOKEN'
            state = $CredentialState
        }
        cliVersion = $CliVersion
        executableSha256 = [string]$Provider.ExecutableSha256
        publisherIdentity = [string]$Provider.PublisherIdentity
        modelIdentity = $Provider.ModelIdentity
        invocationContract = $Provider.InvocationContract
        invocationVersion = $Provider.InvocationVersion
        promptTransport = $(if ($Provider.Kind -ceq 'copilot-cli') {
                'acp-v1-ndjson-stdio-not-proven'
            }
            else {
                'private-file'
            })
        acpProtocolVersion = 'not-proven'
        acpAgentVersion = 'not-proven'
        acpSessionCapabilities = @()
        blockedCapabilities = $(if ($Provider.Kind -ceq 'copilot-cli') {
                @(
                    'session-persistence-disable-not-documented',
                    'memory-disable-not-documented',
                    'acp-session-scope-of-hardening-flags-not-documented',
                    'acp-public-preview'
                )
            }
            else {
                @()
            })
        sessionPersistence = 'not-proven'
        initializeStdoutDigest = $null
        initializeStderrDigest = $null
        initializeFailureDigest = $null
        effectiveTools = $(if ($Provider.Kind -ceq 'copilot-cli') {
                'not-proven-acp-session-scope'
            }
            else {
                'not-proven'
            })
        availabilityFilter = $script:CopilotCliNoToolsSentinel
        environmentNames = @(Get-OwnerModelPolicyEnvironmentNames -Provider $Provider)
        mcpServers = @()
        customInstructions = $false
        memory = $false
        resume = $false
        repositoryAccess = $false
        processContainment = $ProcessContainment
        atomicProcessContainment = $AtomicProcessContainment
        providerWrites = 0
        modelCalls = 0
    }
}

function Test-OwnerModelProviderPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Provider)

    Assert-OwnerModelProvider -Provider $Provider
    if ($Provider.Kind -ne 'copilot-cli') {
        $result = [pscustomobject][ordered]@{
            available = $true
            reason = 'fake-offline'
            credential = [ordered]@{
                sourceName = 'none'
                childName = 'none'
                state = 'not-required'
            }
            cliVersion = 'not-applicable'
            executableSha256 = [string]$Provider.ExecutableSha256
            publisherIdentity = [string]$Provider.PublisherIdentity
            modelIdentity = $Provider.ModelIdentity
            invocationContract = $Provider.InvocationContract
            invocationVersion = $Provider.InvocationVersion
            promptTransport = 'private-file'
            acpProtocolVersion = 'not-applicable'
            acpAgentVersion = 'not-applicable'
            acpSessionCapabilities = @()
            blockedCapabilities = @()
            sessionPersistence = 'not-applicable'
            initializeStdoutDigest = $null
            initializeStderrDigest = $null
            initializeFailureDigest = $null
            effectiveTools = @()
            availabilityFilter = 'not-applicable'
            environmentNames = @(Get-OwnerModelPolicyEnvironmentNames -Provider $Provider)
            mcpServers = @()
            customInstructions = $false
            memory = $false
            resume = $false
            repositoryAccess = $false
            processContainment = Test-OwnerModelContainmentAvailable
            atomicProcessContainment = Test-OwnerModelAcpAtomicContainmentAvailable
            modelCalls = 0
            providerWrites = 0
        }
        Remove-OwnerModelPrivateLaunchRoot -Provider $Provider
        return $result
    }
    $processContainmentAvailable = Test-OwnerModelContainmentAvailable
    $atomicContainmentAvailable = Test-OwnerModelAcpAtomicContainmentAvailable
    if (-not $processContainmentAvailable) {
        $result = New-OwnerModelPreflightResult -Provider $Provider -Available $false `
            -Reason process-containment-unavailable -CredentialState not-checked
        Remove-OwnerModelPrivateLaunchRoot -Provider $Provider
        return $result
    }
    if (-not $atomicContainmentAvailable) {
        $result = New-OwnerModelPreflightResult -Provider $Provider -Available $false `
            -Reason acp-atomic-process-containment-unavailable -CredentialState not-checked `
            -ProcessContainment $true
        Remove-OwnerModelPrivateLaunchRoot -Provider $Provider
        return $result
    }
    if ($Provider.PublisherIdentity -cne 'verified-github') {
        $result = New-OwnerModelPreflightResult -Provider $Provider -Available $false `
            -Reason copilot-cli-publisher-identity-unproven -CredentialState not-checked `
            -ProcessContainment $true -AtomicProcessContainment $true
        Remove-OwnerModelPrivateLaunchRoot -Provider $Provider
        return $result
    }
    $attemptDirectory = New-OwnerModelAttemptDirectory -Provider $Provider
    try {
        $executablePath = Copy-OwnerModelPinnedExecutable -Provider $Provider `
            -AttemptDirectory $attemptDirectory
        $credential = [Environment]::GetEnvironmentVariable(
            [string]$Provider.CredentialEnvironmentName)
        $credentialState = if ([string]::IsNullOrEmpty($credential)) {
            'absent'
        }
        elseif ($credential.StartsWith('ghp_', [StringComparison]::Ordinal)) {
            'classic-pat-unsupported'
        }
        elseif ($credential -cmatch '^(github_pat_|gh[osu]_)[A-Za-z0-9_]+$') {
            'present-supported-shape'
        }
        else {
            'unrecognized-shape'
        }
        try {
            $versionResult = Invoke-OwnerModelPreflightCommand -Provider $Provider `
                -ArgumentList @('--version') -AttemptDirectory $attemptDirectory `
                -ExecutablePath $executablePath
            $helpResult = Invoke-OwnerModelPreflightCommand -Provider $Provider `
                -ArgumentList @('--help') -AttemptDirectory $attemptDirectory `
                -ExecutablePath $executablePath
            $permissionsResult = Invoke-OwnerModelPreflightCommand -Provider $Provider `
                -ArgumentList @('help', 'permissions') -AttemptDirectory $attemptDirectory `
                -ExecutablePath $executablePath
            $syntaxResult = Invoke-OwnerModelPreflightCommand -Provider $Provider `
                -ArgumentList (@($Provider.ArgumentPrefix) + @(
                        '--model', [string]$Provider.ModelIdentity, 'version'
                    )) -AttemptDirectory $attemptDirectory `
                -ExecutablePath $executablePath
        }
        catch {
            return New-OwnerModelPreflightResult -Provider $Provider -Available $false `
                -Reason copilot-cli-probe-failed -CredentialState $credentialState `
                -ProcessContainment $true -AtomicProcessContainment $true
        }
        $versionMatch = [regex]::Match($versionResult.Stdout, 'GitHub Copilot CLI (?<v>\d+\.\d+\.\d+)')
        $version = if ($versionMatch.Success) { [version]$versionMatch.Groups['v'].Value } else { $null }
        $requiredOptions = @(
            @($Provider.ArgumentPrefix | Where-Object {
                    $_ -clike '--*' -and $_ -cne '--stdio'
                }) +
            @('--model')
        ) | ForEach-Object { ([string]$_ -split '=', 2)[0] } | Select-Object -Unique
        $allOptionsDocumented = @($requiredOptions | Where-Object {
                $helpResult.Stdout -cnotmatch (
                    [regex]::Escape($_) + '(?![A-Za-z0-9-])')
            }).Count -eq 0
        $interfaceValid = $versionResult.ExitCode -eq 0 -and
            $helpResult.ExitCode -eq 0 -and
            $permissionsResult.ExitCode -eq 0 -and
            $syntaxResult.ExitCode -eq 0 -and
            $null -ne $version -and $version -ge $script:CopilotCliMinimumVersion -and
            $allOptionsDocumented -and
            $permissionsResult.Stdout -cmatch (
                'The --available-tools option\s+disables all other tools') -and
            $atomicContainmentAvailable
        $acpProbe = $null
        $acpProbeFailureDigest = $null
        if ($interfaceValid) {
            try {
                $acpProbe = Invoke-OwnerModelAcpInitializePreflight `
                    -Provider $Provider -AttemptDirectory $attemptDirectory `
                    -ExecutablePath $executablePath
            }
            catch {
                $acpProbeFailureDigest = Get-OwnerModelBytesDigest -Bytes (
                    [Text.Encoding]::UTF8.GetBytes($_.Exception.Message))
            }
        }
        $agentVersionMatches = $null -ne $acpProbe -and
            $acpProbe.agentVersion -ceq $version.ToString()
        $blockedCapabilities = [Collections.Generic.List[string]]::new()
        if ($null -ne $acpProbe) {
            if ($acpProbe.loadSession) {
                [void]$blockedCapabilities.Add('session-load-advertised')
            }
            if (@($acpProbe.sessionCapabilities) -ccontains 'list') {
                [void]$blockedCapabilities.Add('session-list-advertised')
            }
            if (@($acpProbe.sessionCapabilities) -cnotcontains 'delete') {
                [void]$blockedCapabilities.Add('session-delete-not-advertised')
            }
        }
        [void]$blockedCapabilities.Add('session-persistence-disable-not-documented')
        [void]$blockedCapabilities.Add('memory-disable-not-documented')
        [void]$blockedCapabilities.Add(
            'acp-session-scope-of-hardening-flags-not-documented')
        [void]$blockedCapabilities.Add('acp-public-preview')
        $available = $false
        $reason = if (-not $processContainmentAvailable) {
            'process-containment-unavailable'
        }
        elseif (-not $atomicContainmentAvailable) {
            'acp-atomic-process-containment-unavailable'
        }
        elseif (-not $interfaceValid) {
            'copilot-cli-interface-unproven'
        }
        elseif ($null -eq $acpProbe) {
            'copilot-cli-acp-initialize-unproven'
        }
        elseif (-not $agentVersionMatches) {
            'copilot-cli-acp-runtime-identity-unproven'
        }
        else {
            'copilot-cli-acp-confidentiality-unproven'
        }
        return [pscustomobject][ordered]@{
            available = $available
            reason = $reason
            credential = [ordered]@{
                sourceName = [string]$Provider.CredentialEnvironmentName
                childName = 'COPILOT_GITHUB_TOKEN'
                state = $credentialState
            }
            cliVersion = if ($version) { $version.ToString() } else { 'unknown' }
            executableSha256 = [string]$Provider.ExecutableSha256
            publisherIdentity = [string]$Provider.PublisherIdentity
            modelIdentity = $Provider.ModelIdentity
            invocationContract = $Provider.InvocationContract
            invocationVersion = $Provider.InvocationVersion
            promptTransport = $(if ($null -ne $acpProbe) {
                    'acp-v1-ndjson-stdio-blocked'
                }
                else {
                    'acp-v1-ndjson-stdio-not-proven'
                })
            acpProtocolVersion = $(if ($acpProbe) {
                    [int]$acpProbe.protocolVersion
                }
                else {
                    'not-proven'
                })
            acpAgentVersion = $(if ($acpProbe) {
                    [string]$acpProbe.agentVersion
                }
                else {
                    'not-proven'
                })
            acpSessionCapabilities = $(if ($acpProbe) {
                    Write-Output -NoEnumerate (
                        [object[]]@($acpProbe.sessionCapabilities))
                }
                else {
                    Write-Output -NoEnumerate ([object[]]@())
                })
            blockedCapabilities = @($blockedCapabilities)
            sessionPersistence = $(if ($null -ne $acpProbe -and (
                        $acpProbe.loadSession -or
                        @($acpProbe.sessionCapabilities) -ccontains 'list')) {
                    'advertised'
                }
                elseif ($null -eq $acpProbe) {
                    'not-proven'
                }
                else {
                    'disable-control-not-documented'
                })
            initializeStdoutDigest = $(if ($acpProbe) {
                    [string]$acpProbe.stdoutDigest
                }
                else {
                    $null
                })
            initializeStderrDigest = $(if ($acpProbe) {
                    [string]$acpProbe.stderrDigest
                }
                else {
                    $null
                })
            initializeFailureDigest = $acpProbeFailureDigest
            effectiveTools = 'not-proven-acp-session-scope'
            availabilityFilter = $script:CopilotCliNoToolsSentinel
            environmentNames = @(Get-OwnerModelPolicyEnvironmentNames -Provider $Provider)
            mcpServers = @()
            customInstructions = $false
            memory = $false
            resume = $false
            repositoryAccess = $false
            processContainment = $processContainmentAvailable
            atomicProcessContainment = $atomicContainmentAvailable
            providerWrites = 0
            modelCalls = 0
        }
    }
    finally {
        if (Test-Path -LiteralPath $attemptDirectory -PathType Container) {
            Remove-Item -LiteralPath $attemptDirectory -Recurse -Force
        }
        Remove-OwnerModelPrivateLaunchRoot -Provider $Provider
    }
}

function New-OwnerModelProcessStartInfo {
    param(
        [Parameter(Mandatory)][object]$Invocation
    )

    $psi = [Diagnostics.ProcessStartInfo]::new()
    Set-OwnerModelContainedCommand -Psi $psi -FilePath $Invocation.FilePath `
        -ArgumentList $Invocation.ArgumentList
    $psi.WorkingDirectory = $Invocation.WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $psi.StandardInputEncoding = $utf8
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.Environment.Clear()
    foreach ($entry in $Invocation.Environment.GetEnumerator()) {
        $psi.Environment[[string]$entry.Key] = [string]$entry.Value
    }
    return $psi
}

function Set-OwnerModelContainedCommand {
    param(
        [Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$Psi,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    if ($IsWindows) {
        $Psi.FileName = $FilePath
        Set-TimedProcessArguments -Psi $Psi -ArgumentList $ArgumentList
    }
    else {
        $setsid = Get-Command setsid -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($setsid) {
            $Psi.FileName = [IO.Path]::GetFullPath($setsid.Source)
            Set-TimedProcessArguments -Psi $Psi -ArgumentList (
                @($FilePath) + @($ArgumentList))
        }
        else {
            $perl = Get-Command perl -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $perl) {
                throw 'Unix process containment requires a trusted setsid executable or Perl POSIX shim.'
            }
            $Psi.FileName = [IO.Path]::GetFullPath($perl.Source)
            Set-TimedProcessArguments -Psi $Psi -ArgumentList (@(
                    '-MPOSIX', '-e',
                    'POSIX::setsid() >= 0 or die "setsid failed: $!"; exec @ARGV or die "exec failed: $!";',
                    '--', $FilePath
                ) + @($ArgumentList))
        }
    }
}

function Invoke-OwnerModelProcessAttempt {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][string]$Nonce,
        [Parameter(Mandatory)][string]$InputDigest,
        [Parameter(Mandatory)][string]$SubjectBinding,
        [Parameter(Mandatory)][DevPilot.OwnerModelRunner.OwnerModelRunnerLimits]$Limits,
        [Parameter(Mandatory)][DateTime]$TotalDeadlineUtc
    )

    $unitId = [string](Get-OwnerModelMember -Value $Request -Name executionUnitId)
    $envelopeObject = [ordered]@{
        schemaVersion = 2
        semantics = 'owner-model-stimulus-v1'
        nonce = $Nonce
        inputDigest = $InputDigest
        subjectBinding = $SubjectBinding
        modelIdentity = [string]$Provider.ModelIdentity
        toolCeiling = [ordered]@{
            context = @('capability-stimulus')
            tools = @()
            providerWrite = $false
            adoWrite = $false
            shell = $false
            web = $false
            delegation = $false
        }
        stimulus = $Request
    }
    $envelopeJson = ConvertTo-AgentCanonicalJson -InputObject $envelopeObject
    $envelope = ConvertTo-OwnerModelBase64Url -Bytes ([Text.Encoding]::UTF8.GetBytes($envelopeJson))
    $attemptDirectory = $null
    $invocation = $null
    $process = $null
    $containment = $null
    $stdoutDrain = $null
    $stderrDrain = $null
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $outcome = 'start-failed'
    $started = $false
    $exitCode = $null
    $timeout = 'none'
    $stdoutBytes = [byte[]]::new(0)
    $stderrBytes = [byte[]]::new(0)
    try {
        $attemptDirectory = New-OwnerModelAttemptDirectory -Provider $Provider
        $invocation = New-OwnerModelInvocation -Provider $Provider `
            -EnvelopeBase64 $envelope `
            -AttemptDirectory $attemptDirectory -IncludeCredential:($Provider.Kind -ceq 'copilot-cli')
        $psi = New-OwnerModelProcessStartInfo -Invocation $invocation
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $psi
        $stdoutDrain = [DevPilot.OwnerModelRunner.BoundedByteDrain]::new(
            $Limits.MaximumStdoutBytes, $Limits.MaximumOutputLines)
        $stderrDrain = [DevPilot.OwnerModelRunner.BoundedByteDrain]::new(
            $Limits.MaximumStderrBytes, $Limits.MaximumOutputLines)
        if (-not $process.Start()) {
            return [pscustomobject]@{
                Started = $false
                ModelStarted = $(if ($Provider.ModelStartPolicy -ceq 'always-zero') { $false } else { 'unknown' })
                LatencyMs = 0L
                Failure = $outcome
                AtomicFailure = $false
                Valid = $false
                Judgment = 'unknown'
                InvocationDigest = $invocation.InvocationDigest
                StdoutDigest = Get-OwnerModelBytesDigest -Bytes $stdoutBytes
                StderrDigest = Get-OwnerModelBytesDigest -Bytes $stderrBytes
                ExitCode = $null
                Timeout = 'none'
                ResponseBytesBase64 = $null
                EnvironmentNames = $invocation.EnvironmentNames
            }
        }
        $started = $true
        try {
            $containment = New-AgentProcessContainment -Process $process
        }
        catch {
            $outcome = 'containment-failed'
            Stop-ProcessTree -Process $process
            throw
        }
        $outcome = 'none'
        $process.StandardInput.Close()
        $stdoutTask = $stdoutDrain.ReadAsync($process.StandardOutput.BaseStream)
        $stderrTask = $stderrDrain.ReadAsync($process.StandardError.BaseStream)
        $callDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds($Limits.PerCallDeadlineMilliseconds)
        if ($callDeadlineUtc -gt $TotalDeadlineUtc) { $callDeadlineUtc = $TotalDeadlineUtc }
        $frequency = [double][Diagnostics.Stopwatch]::Frequency
        while ($true) {
            $process.Refresh()
            if ($process.HasExited) { break }
            $now = [DateTime]::UtcNow
            if ($now -ge $TotalDeadlineUtc) { $outcome = 'total-timeout'; $timeout = 'total'; break }
            if ($now -ge $callDeadlineUtc) { $outcome = 'call-timeout'; $timeout = 'call'; break }
            $lastActivity = [Math]::Max(
                $stdoutDrain.LastActivityTimestamp,
                $stderrDrain.LastActivityTimestamp)
            $activityMs = 1000.0 * ([Diagnostics.Stopwatch]::GetTimestamp() - $lastActivity) / $frequency
            if ($activityMs -ge $Limits.ActivityDeadlineMilliseconds) {
                $outcome = 'activity-timeout'
                $timeout = 'activity'
                break
            }
            if ($stdoutDrain.Overflowed -or $stderrDrain.Overflowed) {
                $outcome = 'output-limit'
                break
            }
            Start-Sleep -Milliseconds 20
        }
        if (-not $process.HasExited) {
            if (-not (Stop-AgentProcessContainment -Containment $containment -Process $process)) {
                $outcome = 'containment-failed'
            }
        }
        else {
            $settleDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds(750)
            while ([DateTime]::UtcNow -lt $settleDeadlineUtc -and
                -not (Test-AgentProcessContainmentExited -Containment $containment -Process $process)) {
                Start-Sleep -Milliseconds 20
            }
            if (-not (Test-AgentProcessContainmentExited -Containment $containment -Process $process)) {
                $outcome = 'descendant-survived'
                if (-not (Stop-AgentProcessContainment -Containment $containment -Process $process)) {
                    $outcome = 'containment-failed'
                }
            }
        }
        [void][Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000)
        if (-not $stdoutTask.IsCompleted -or -not $stderrTask.IsCompleted) {
            $outcome = 'output-drain-timeout'
        }
        elseif ($stdoutDrain.Overflowed -or $stderrDrain.Overflowed) {
            $outcome = 'output-limit'
        }
        elseif ($outcome -notin @('start-failed', 'none')) {
            # Preserve the deadline or containment result selected above.
        }
        elseif ($process.ExitCode -ne 0) {
            $outcome = 'early-exit'
        }
        else {
            $exitCode = $process.ExitCode
            $stdoutBytes = $stdoutDrain.GetBytes()
            $stderrBytes = $stderrDrain.GetBytes()
            $parsed = ConvertFrom-OwnerModelResponseBytes `
                -Bytes $stdoutBytes `
                -ExpectedNonce $Nonce `
                -ExpectedInputDigest $InputDigest `
                -ExpectedSubjectBinding $SubjectBinding `
                -ExpectedExecutionUnitId $unitId `
                -ExpectedModelIdentity ([string]$Provider.ModelIdentity)
            $stopwatch.Stop()
            return [pscustomobject]@{
                Started = $true
                ModelStarted = $(if ($Provider.ModelStartPolicy -ceq 'always-zero') {
                        $false
                    }
                    elseif ($parsed.Valid) {
                        $true
                    }
                    else {
                        'unknown'
                    })
                LatencyMs = $stopwatch.ElapsedMilliseconds
                Failure = $parsed.Failure
                AtomicFailure = $parsed.AtomicFailure
                Valid = $parsed.Valid
                Judgment = $parsed.Judgment
                InvocationDigest = $invocation.InvocationDigest
                StdoutDigest = Get-OwnerModelBytesDigest -Bytes $stdoutBytes
                StderrDigest = Get-OwnerModelBytesDigest -Bytes $stderrBytes
                ExitCode = $exitCode
                Timeout = $timeout
                ResponseBytesBase64 = $(if ($parsed.Valid) {
                        [Convert]::ToBase64String([byte[]]$parsed.MarkerBytes)
                    }
                    else {
                        $null
                    })
                EnvironmentNames = $invocation.EnvironmentNames
            }
        }
        if ($process.HasExited) { $exitCode = $process.ExitCode }
        $stdoutBytes = $stdoutDrain.GetBytes()
        $stderrBytes = $stderrDrain.GetBytes()
        $stopwatch.Stop()
        return [pscustomobject]@{
            Started = $started
            ModelStarted = $(if ($Provider.ModelStartPolicy -ceq 'always-zero') {
                    $false
                }
                else {
                    'unknown'
                })
            LatencyMs = $stopwatch.ElapsedMilliseconds
            Failure = $outcome
            AtomicFailure = $false
            Valid = $false
            Judgment = 'unknown'
            InvocationDigest = $invocation.InvocationDigest
            StdoutDigest = Get-OwnerModelBytesDigest -Bytes $stdoutBytes
            StderrDigest = Get-OwnerModelBytesDigest -Bytes $stderrBytes
            ExitCode = $exitCode
            Timeout = $timeout
            ResponseBytesBase64 = $null
            EnvironmentNames = $invocation.EnvironmentNames
        }
    }
    catch {
        $stopwatch.Stop()
        $failure = if ($outcome -cne 'none') { $outcome } else { 'process-failed' }
        return [pscustomobject]@{
            Started = $started
            ModelStarted = $(if ($Provider.ModelStartPolicy -ceq 'always-zero') {
                    $false
                }
                else {
                    'unknown'
                })
            LatencyMs = $stopwatch.ElapsedMilliseconds
            Failure = $failure
            AtomicFailure = $false
            Valid = $false
            Judgment = 'unknown'
            InvocationDigest = $(if ($invocation) {
                    $invocation.InvocationDigest
                }
                else {
                    'v1:sha256:' + ('0' * 64)
                })
            StdoutDigest = Get-OwnerModelBytesDigest -Bytes $stdoutBytes
            StderrDigest = Get-OwnerModelBytesDigest -Bytes $stderrBytes
            ExitCode = $exitCode
            Timeout = $timeout
            ResponseBytesBase64 = $null
            EnvironmentNames = $(if ($invocation) { @($invocation.EnvironmentNames) } else { @() })
        }
    }
    finally {
        if ($process -and $started -and -not $process.HasExited) {
            if ($containment) {
                [void](Stop-AgentProcessContainment -Containment $containment -Process $process)
            }
            else {
                Stop-ProcessTree -Process $process
            }
        }
        Close-AgentProcessContainment -Containment $containment
        if ($process) { $process.Dispose() }
        if ($attemptDirectory -and (Test-Path -LiteralPath $attemptDirectory -PathType Container)) {
            Remove-Item -LiteralPath $attemptDirectory -Recurse -Force
        }
        Remove-OwnerModelPrivateLaunchRoot -Provider $Provider
    }
}

function New-OwnerModelProviderRunner {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [DevPilot.OwnerModelRunner.OwnerModelRunnerLimits]$Limits = (New-OwnerModelRunnerLimits),
        [Parameter(Mandatory)][string]$Name
    )

    Assert-OwnerModelProvider -Provider $Provider
    Assert-OwnerModelText -Value $Name -Name Name -MaximumLength 128
    $policyEnvironmentNames = @(Get-OwnerModelPolicyEnvironmentNames -Provider $Provider)
    $providerTelemetry = [ordered]@{
        kind = [string]$Provider.Kind
        name = [string]$Provider.Name
        modelIdentity = [string]$Provider.ModelIdentity
        invocationContract = [string]$Provider.InvocationContract
        invocationVersion = [string]$Provider.InvocationVersion
        executableSha256 = [string]$Provider.ExecutableSha256
    }
    $policyTelemetry = [ordered]@{
        availableTools = @()
        mcpServers = @()
        customInstructions = $false
        memory = $false
        resume = $false
        repositoryAccess = $false
        networkAccess = $Provider.Kind -ceq 'copilot-cli'
        providerWrite = $false
        environmentNames = @($policyEnvironmentNames | Sort-Object -Unique)
        workingDirectory = 'fresh-isolated-directory-with-bounded-stimulus'
    }
    $capturedProvider = $Provider
    $capturedLimits = $Limits
    $telemetry = New-OwnerModelTelemetryState -Provider $providerTelemetry -Policy $policyTelemetry
    $getMemberCommand = Get-Command Get-OwnerModelMember -CommandType Function
    $getInputDigestCommand = Get-Command Get-OwnerModelInputDigest -CommandType Function
    $getSubjectBindingCommand = Get-Command Get-OwnerModelSubjectBinding -CommandType Function
    $invokeAttemptCommand = Get-Command Invoke-OwnerModelProcessAttempt -CommandType Function
    $addTelemetryCommand = Get-Command Add-OwnerModelTelemetryRecord -CommandType Function
    $getTelemetryCommand = Get-Command Get-OwnerModelTelemetrySnapshot -CommandType Function
    $newNonceCommand = Get-Command New-AgentNonce -CommandType Function
    $executionUnitPattern = $script:ExecutionUnitPattern
    $handler = {
        param($request)
        $unitId = [string](& $getMemberCommand -Value $request -Name executionUnitId)
        if ($unitId -cnotmatch $executionUnitPattern) {
            throw 'Owner model runner received an invalid execution-unit reference.'
        }
        $totalDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds(
            $capturedLimits.TotalDeadlineMilliseconds)
        $judgment = 'unknown'
        for ($attempt = 1; $attempt -le $capturedLimits.MaximumAttemptsPerUnit; $attempt++) {
            $nonce = & $newNonceCommand
            $inputDigest = & $getInputDigestCommand -Request $request
            $subjectBinding = & $getSubjectBindingCommand -ExecutionUnitId $unitId
            if ([DateTime]::UtcNow -ge $totalDeadlineUtc) {
                & $addTelemetryCommand -State $telemetry -ExecutionUnitId $unitId `
                    -Attempt $attempt -ProcessStarted $false -ModelStarted $false `
                    -LatencyMilliseconds 0 -Outcome 'total-timeout' `
                    -InputDigest $inputDigest -Nonce $nonce -SubjectBinding $subjectBinding `
                    -InvocationDigest ('v1:sha256:' + ('0' * 64)) `
                    -StdoutDigest ('v1:sha256:' + ('0' * 64)) `
                    -StderrDigest ('v1:sha256:' + ('0' * 64)) `
                    -ExitCode $null -Timeout total -ResponseBytesBase64 $null
                break
            }
            $result = & $invokeAttemptCommand `
                -Provider $capturedProvider `
                -Request $request `
                -Nonce $nonce `
                -InputDigest $inputDigest `
                -SubjectBinding $subjectBinding `
                -Limits $capturedLimits `
                -TotalDeadlineUtc $totalDeadlineUtc
            & $addTelemetryCommand -State $telemetry -ExecutionUnitId $unitId `
                -Attempt $attempt -ProcessStarted ([bool]$result.Started) `
                -ModelStarted $result.ModelStarted `
                -LatencyMilliseconds ([long]$result.LatencyMs) -Outcome ([string]$result.Failure) `
                -InputDigest $inputDigest -Nonce $nonce -SubjectBinding $subjectBinding `
                -InvocationDigest ([string]$result.InvocationDigest) `
                -StdoutDigest ([string]$result.StdoutDigest) `
                -StderrDigest ([string]$result.StderrDigest) `
                -ExitCode $result.ExitCode -Timeout ([string]$result.Timeout) `
                -ResponseBytesBase64 $result.ResponseBytesBase64
            if ($result.Valid) {
                $judgment = [string]$result.Judgment
                break
            }
            if ($result.AtomicFailure -or
                $result.Failure -cin @('containment-failed', 'total-timeout')) {
                break
            }
        }
        return @{
            schemaVersion = 2
            executionUnitId = $unitId
            judgment = $judgment
        }
    }.GetNewClosure()
    $telemetryProvider = { & $getTelemetryCommand -State $telemetry }.GetNewClosure()
    return New-OwnerSemanticRunner -Name $Name -Handler $handler -TelemetryProvider $telemetryProvider
}

function New-OwnerModelProcessRunner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Provider,
        [DevPilot.OwnerModelRunner.OwnerModelRunnerLimits]$Limits = (New-OwnerModelRunnerLimits),
        [switch]$EnableRealLaunch,
        [string]$Name = 'owner-model-contained-provider'
    )

    Assert-OwnerModelProvider -Provider $Provider
    if ($Provider.Kind -ceq 'copilot-cli') {
        if (-not $EnableRealLaunch) {
            throw '[owner-model-launch-unavailable] Real model launch requires explicit -EnableRealLaunch opt-in.'
        }
        $preflight = Test-OwnerModelProviderPreflight -Provider $Provider
        if (-not $preflight.available) {
            throw "[owner-model-launch-unavailable] $($preflight.reason)"
        }
    }
    return New-OwnerModelProviderRunner -Provider $Provider -Limits $Limits -Name $Name
}

Export-ModuleMember -Function @(
    'Get-OwnerModelRunnerTelemetry',
    'New-OwnerCopilotCliModelProvider',
    'New-OwnerModelFakeProvider',
    'New-OwnerModelProcessRunner',
    'New-OwnerModelReplayFixture',
    'New-OwnerModelReplayRecord',
    'New-OwnerModelReplayRunner',
    'New-OwnerModelRunnerLimits',
    'Test-OwnerModelProviderPreflight'
)
