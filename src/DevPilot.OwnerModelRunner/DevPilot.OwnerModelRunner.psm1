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
$script:DigestPattern = '^v1:sha256:[0-9a-f]{64}$'
$script:NoncePattern = '^[0-9a-f]{36}$'
$script:ExecutionUnitPattern = '^unit:[0-9a-f]{64}$'
$script:Judgments = @('compliant', 'violation', 'unknown')
$script:SensitiveEnvironmentPattern = '(?i)(?:token|secret|password|credential|api[_-]?key|github|azure|ado|copilot)'

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
        [Parameter(Mandatory)][string]$ExpectedExecutionUnitId
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
            if ($line.StartsWith($script:MarkerPrefix, [StringComparison]::Ordinal)) { $line }
        }
    )
    if ($markers.Count -ne 1 -or
        $markers[0] -cnotmatch ('^' + [regex]::Escape($script:MarkerPrefix) + '[A-Za-z0-9_-]+$')) {
        return [pscustomobject]@{ Valid = $false; AtomicFailure = $false; Judgment = 'unknown'; Failure = 'marker-invalid' }
    }

    try {
        $payloadText = $markers[0].Substring($script:MarkerPrefix.Length)
        $payloadBytes = ConvertFrom-OwnerModelBase64Url -Text $payloadText
        $json = $utf8.GetString($payloadBytes)
        $response = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 8 -NoEnumerate
    }
    catch {
        return [pscustomobject]@{ Valid = $false; AtomicFailure = $false; Judgment = 'unknown'; Failure = 'json-invalid' }
    }

    if ($response -isnot [Collections.IDictionary] -or
        -not (Test-OwnerModelExactKeys -Value $response -Expected @(
                'schemaVersion', 'nonce', 'inputDigest', 'subjectBinding', 'responses'
            )) -or
        $response.schemaVersion -ne 1 -or
        $response.nonce -isnot [string] -or
        $response.inputDigest -isnot [string] -or
        $response.subjectBinding -isnot [string] -or
        $response.responses -isnot [Collections.IList] -or
        @($response.responses).Count -gt 16) {
        return [pscustomobject]@{ Valid = $false; AtomicFailure = $false; Judgment = 'unknown'; Failure = 'schema-invalid' }
    }

    if ([string]$response.nonce -cne $ExpectedNonce -or
        [string]$response.inputDigest -cne $ExpectedInputDigest -or
        [string]$response.subjectBinding -cne $ExpectedSubjectBinding) {
        return [pscustomobject]@{ Valid = $false; AtomicFailure = $true; Judgment = 'unknown'; Failure = 'binding-mismatch' }
    }

    $matched = [Collections.Generic.List[string]]::new()
    foreach ($item in @($response.responses)) {
        if ($item -isnot [Collections.IDictionary] -or
            -not (Test-OwnerModelExactKeys -Value $item -Expected @('executionUnitId', 'judgment')) -or
            $item.executionUnitId -isnot [string] -or
            [string]$item.executionUnitId -cnotmatch $script:ExecutionUnitPattern -or
            $item.judgment -isnot [string] -or
            [string]$item.judgment -cnotin $script:Judgments) {
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
    return [pscustomobject]@{
        Records = [Collections.Generic.List[object]]::new()
    }
}

function Add-OwnerModelTelemetryRecord {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$ExecutionUnitId,
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)][bool]$ModelStarted,
        [Parameter(Mandatory)][long]$LatencyMilliseconds,
        [Parameter(Mandatory)][string]$Outcome
    )

    [void]$State.Records.Add([pscustomobject][ordered]@{
            executionUnitId = $ExecutionUnitId
            attempt = $Attempt
            modelStarted = $ModelStarted
            latencyMs = [Math]::Max(0L, $LatencyMilliseconds)
            outcome = $Outcome
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
    return [ordered]@{
        attempts = $records.Count
        modelStarts = @($records | Where-Object modelStarted).Count
        latencyMs = $latency
        refusalReason = if ($failures.Count -eq 0) { 'none' } else { [string]$failures[-1] }
        records = @(
            foreach ($record in $records) {
                [ordered]@{
                    executionUnitId = $record.executionUnitId
                    attempt = $record.attempt
                    modelStarted = $record.modelStarted
                    latencyMs = $record.latencyMs
                    outcome = $record.outcome
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
        $ResponseBytes = ConvertTo-OwnerModelMarkerBytes -Response ([ordered]@{
                schemaVersion = 1
                nonce = $Nonce
                inputDigest = $inputDigest
                subjectBinding = $subjectBinding
                responses = @(
                    [ordered]@{
                        executionUnitId = $executionUnitId
                        judgment = $Judgment
                    }
                )
            })
    }
    return [pscustomobject][ordered]@{
        executionUnitId = $executionUnitId
        nonce = $Nonce
        inputDigest = $inputDigest
        subjectBinding = $subjectBinding
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
        $responseBytes = Get-OwnerModelMember -Value $record -Name responseBytes
        if ($executionUnitId -cnotmatch $script:ExecutionUnitPattern -or
            -not $ids.Add($executionUnitId) -or
            $nonce -cnotmatch $script:NoncePattern -or
            $inputDigest -cnotmatch $script:DigestPattern -or
            $subjectBinding -cnotmatch $script:DigestPattern -or
            $responseBytes -isnot [byte[]] -or
            $responseBytes.Length -gt 1048576) {
            throw 'Replay record violated the bounded sanitized fixture contract.'
        }
        [void]$copies.Add([pscustomobject][ordered]@{
                executionUnitId = $executionUnitId
                nonce = $nonce
                inputDigest = $inputDigest
                subjectBinding = $subjectBinding
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
    $telemetry = New-OwnerModelTelemetryState
    $getMemberCommand = Get-Command Get-OwnerModelMember -CommandType Function
    $getInputDigestCommand = Get-Command Get-OwnerModelInputDigest -CommandType Function
    $getSubjectBindingCommand = Get-Command Get-OwnerModelSubjectBinding -CommandType Function
    $parseResponseCommand = Get-Command ConvertFrom-OwnerModelResponseBytes -CommandType Function
    $addTelemetryCommand = Get-Command Add-OwnerModelTelemetryRecord -CommandType Function
    $getTelemetryCommand = Get-Command Get-OwnerModelTelemetrySnapshot -CommandType Function
    $handler = {
        param($request)
        $unitId = [string](& $getMemberCommand -Value $request -Name executionUnitId)
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $outcome = 'response-omitted'
        $judgment = 'unknown'
        if ($records.ContainsKey($unitId)) {
            $record = $records[$unitId]
            $inputDigest = & $getInputDigestCommand -Request $request
            $subjectBinding = & $getSubjectBindingCommand -ExecutionUnitId $unitId
            if ($inputDigest -cne $record.inputDigest -or $subjectBinding -cne $record.subjectBinding) {
                $outcome = 'binding-mismatch'
            }
            else {
                $parsed = & $parseResponseCommand `
                    -Bytes $record.responseBytes `
                    -ExpectedNonce $record.nonce `
                    -ExpectedInputDigest $inputDigest `
                    -ExpectedSubjectBinding $subjectBinding `
                    -ExpectedExecutionUnitId $unitId
                $judgment = $parsed.Judgment
                $outcome = $parsed.Failure
            }
        }
        $stopwatch.Stop()
        & $addTelemetryCommand -State $telemetry -ExecutionUnitId $unitId `
            -Attempt 1 -ModelStarted $false -LatencyMilliseconds $stopwatch.ElapsedMilliseconds `
            -Outcome $outcome
        return @{
            schemaVersion = 2
            executionUnitId = $unitId
            judgment = $judgment
        }
    }.GetNewClosure()
    $telemetryProvider = { & $getTelemetryCommand -State $telemetry }.GetNewClosure()
    return New-OwnerSemanticRunner -Name $Name -Handler $handler -TelemetryProvider $telemetryProvider
}

function New-OwnerModelProcessStartInfo {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$Envelope
    )

    $psi = [Diagnostics.ProcessStartInfo]::new()
    if ($IsWindows) {
        $psi.FileName = $FilePath
        Set-TimedProcessArguments -Psi $psi -ArgumentList (@($ArgumentList) + @($Envelope))
    }
    else {
        $setsid = Get-Command setsid -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($setsid) {
            $psi.FileName = [IO.Path]::GetFullPath($setsid.Source)
            Set-TimedProcessArguments -Psi $psi -ArgumentList (@($FilePath) + @($ArgumentList) + @($Envelope))
        }
        else {
            $perl = Get-Command perl -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $perl) {
                throw 'Unix process containment requires a trusted setsid executable or Perl POSIX shim.'
            }
            $psi.FileName = [IO.Path]::GetFullPath($perl.Source)
            Set-TimedProcessArguments -Psi $psi -ArgumentList (@(
                    '-MPOSIX', '-e',
                    'POSIX::setsid() >= 0 or die "setsid failed: $!"; exec @ARGV or die "exec failed: $!";',
                    '--', $FilePath
                ) + @($ArgumentList) + @($Envelope))
        }
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $psi.StandardInputEncoding = $utf8
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    foreach ($name in @($psi.Environment.Keys)) {
        if ($name -match $script:SensitiveEnvironmentPattern) {
            [void]$psi.Environment.Remove($name)
        }
    }
    foreach ($name in (Get-AgentSessionIsolationEnvVars)) {
        [void]$psi.Environment.Remove($name)
    }
    $psi.Environment['DEV_PILOT_OWNER_MODEL_TEST_ONLY'] = '1'
    return $psi
}

function Invoke-OwnerModelProcessAttempt {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][string]$Nonce,
        [Parameter(Mandatory)][string]$InputDigest,
        [Parameter(Mandatory)][string]$SubjectBinding,
        [Parameter(Mandatory)][DevPilot.OwnerModelRunner.OwnerModelRunnerLimits]$Limits,
        [Parameter(Mandatory)][DateTime]$TotalDeadlineUtc
    )

    $unitId = [string](Get-OwnerModelMember -Value $Request -Name executionUnitId)
    $envelopeObject = [ordered]@{
        schemaVersion = 1
        semantics = 'owner-model-stimulus-v1'
        nonce = $Nonce
        inputDigest = $InputDigest
        subjectBinding = $SubjectBinding
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
    $psi = New-OwnerModelProcessStartInfo -FilePath $FilePath -ArgumentList $ArgumentList -Envelope $envelope
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $containment = $null
    $stdoutDrain = [DevPilot.OwnerModelRunner.BoundedByteDrain]::new(
        $Limits.MaximumStdoutBytes, $Limits.MaximumOutputLines)
    $stderrDrain = [DevPilot.OwnerModelRunner.BoundedByteDrain]::new(
        $Limits.MaximumStderrBytes, $Limits.MaximumOutputLines)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $outcome = 'start-failed'
    $started = $false
    try {
        if (-not $process.Start()) { return [pscustomobject]@{ Started = $false; LatencyMs = 0L; Failure = $outcome } }
        $started = $true
        try {
            $containment = New-AgentProcessContainment -Process $process
        }
        catch {
            Stop-ProcessTree -Process $process
            throw
        }
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
            if ($now -ge $TotalDeadlineUtc) { $outcome = 'total-timeout'; break }
            if ($now -ge $callDeadlineUtc) { $outcome = 'call-timeout'; break }
            $lastActivity = [Math]::Max(
                $stdoutDrain.LastActivityTimestamp,
                $stderrDrain.LastActivityTimestamp)
            $activityMs = 1000.0 * ([Diagnostics.Stopwatch]::GetTimestamp() - $lastActivity) / $frequency
            if ($activityMs -ge $Limits.ActivityDeadlineMilliseconds) {
                $outcome = 'activity-timeout'
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
            $parsed = ConvertFrom-OwnerModelResponseBytes `
                -Bytes $stdoutDrain.GetBytes() `
                -ExpectedNonce $Nonce `
                -ExpectedInputDigest $InputDigest `
                -ExpectedSubjectBinding $SubjectBinding `
                -ExpectedExecutionUnitId $unitId
            $stopwatch.Stop()
            return [pscustomobject]@{
                Started = $true
                LatencyMs = $stopwatch.ElapsedMilliseconds
                Failure = $parsed.Failure
                AtomicFailure = $parsed.AtomicFailure
                Valid = $parsed.Valid
                Judgment = $parsed.Judgment
            }
        }
        $stopwatch.Stop()
        return [pscustomobject]@{
            Started = $started
            LatencyMs = $stopwatch.ElapsedMilliseconds
            Failure = $outcome
            AtomicFailure = $false
            Valid = $false
            Judgment = 'unknown'
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

function New-OwnerModelTestProcessRunner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [DevPilot.OwnerModelRunner.OwnerModelRunnerLimits]$Limits = (New-OwnerModelRunnerLimits),
        [string]$Name = 'owner-model-contained-test-child'
    )

    Assert-OwnerModelText -Value $Name -Name Name -MaximumLength 128
    $absolute = [IO.Path]::GetFullPath($FilePath)
    if (-not [IO.Path]::IsPathFullyQualified($absolute) -or
        -not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
        throw 'Test child executable must be an existing absolute file.'
    }
    $capturedArguments = @($ArgumentList)
    $capturedLimits = $Limits
    $telemetry = New-OwnerModelTelemetryState
    $getMemberCommand = Get-Command Get-OwnerModelMember -CommandType Function
    $getInputDigestCommand = Get-Command Get-OwnerModelInputDigest -CommandType Function
    $getSubjectBindingCommand = Get-Command Get-OwnerModelSubjectBinding -CommandType Function
    $invokeAttemptCommand = Get-Command Invoke-OwnerModelProcessAttempt -CommandType Function
    $addTelemetryCommand = Get-Command Add-OwnerModelTelemetryRecord -CommandType Function
    $getTelemetryCommand = Get-Command Get-OwnerModelTelemetrySnapshot -CommandType Function
    $newNonceCommand = Get-Command New-AgentNonce -CommandType Function
    $handler = {
        param($request)
        $unitId = [string](& $getMemberCommand -Value $request -Name executionUnitId)
        if ($unitId -cnotmatch $script:ExecutionUnitPattern) {
            throw 'Owner model runner received an invalid execution-unit reference.'
        }
        $totalDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds(
            $capturedLimits.TotalDeadlineMilliseconds)
        $judgment = 'unknown'
        for ($attempt = 1; $attempt -le $capturedLimits.MaximumAttemptsPerUnit; $attempt++) {
            if ([DateTime]::UtcNow -ge $totalDeadlineUtc) {
                & $addTelemetryCommand -State $telemetry -ExecutionUnitId $unitId `
                    -Attempt $attempt -ModelStarted $false -LatencyMilliseconds 0 -Outcome 'total-timeout'
                break
            }
            $nonce = & $newNonceCommand
            $inputDigest = & $getInputDigestCommand -Request $request
            $subjectBinding = & $getSubjectBindingCommand -ExecutionUnitId $unitId
            $result = & $invokeAttemptCommand `
                -FilePath $absolute `
                -ArgumentList $capturedArguments `
                -Request $request `
                -Nonce $nonce `
                -InputDigest $inputDigest `
                -SubjectBinding $subjectBinding `
                -Limits $capturedLimits `
                -TotalDeadlineUtc $totalDeadlineUtc
            & $addTelemetryCommand -State $telemetry -ExecutionUnitId $unitId `
                -Attempt $attempt -ModelStarted ([bool]$result.Started) `
                -LatencyMilliseconds ([long]$result.LatencyMs) -Outcome ([string]$result.Failure)
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
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [DevPilot.OwnerModelRunner.OwnerModelRunnerLimits]$Limits = (New-OwnerModelRunnerLimits),
        [string]$Name = 'owner-model-process-unavailable'
    )

    throw '[owner-model-launch-unavailable] Current model CLI no-tools enforcement is not proven; live launch is fail-closed.'
}

Export-ModuleMember -Function @(
    'Get-OwnerModelRunnerTelemetry',
    'New-OwnerModelProcessRunner',
    'New-OwnerModelReplayFixture',
    'New-OwnerModelReplayRecord',
    'New-OwnerModelReplayRunner',
    'New-OwnerModelRunnerLimits'
)
