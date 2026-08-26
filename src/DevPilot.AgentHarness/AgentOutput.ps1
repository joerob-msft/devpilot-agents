Set-StrictMode -Version Latest

if (-not ('DevPilot.AgentInteractiveStatusTimer' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace DevPilot
{
    public sealed class AgentInteractiveStatusTimer : IDisposable
    {
        private readonly object gate = new object();
        private readonly TextWriter writer;
        private readonly Timer timer;
        private readonly int intervalMilliseconds;
        private readonly int configuredWidth;
        private readonly bool useLiveConsoleWidth;
        private readonly Stopwatch stopwatch = new Stopwatch();
        private string scope = "";
        private string phase = "";
        private long baseElapsedMilliseconds;
        private bool active;

        public AgentInteractiveStatusTimer(
            TextWriter writer,
            int intervalMilliseconds,
            int configuredWidth,
            bool useLiveConsoleWidth)
        {
            this.writer = writer;
            this.intervalMilliseconds = Math.Max(100, intervalMilliseconds);
            this.configuredWidth = configuredWidth;
            this.useLiveConsoleWidth = useLiveConsoleWidth;
            timer = new Timer(Render, null, Timeout.Infinite, Timeout.Infinite);
        }

        public void Start(string scope, string phase, long elapsedMilliseconds)
        {
            lock (gate)
            {
                this.scope = scope ?? "";
                this.phase = phase ?? "";
                baseElapsedMilliseconds = Math.Max(0, elapsedMilliseconds);
                stopwatch.Restart();
                active = true;
                RenderUnsafe();
                timer.Change(intervalMilliseconds, intervalMilliseconds);
            }
        }

        public void Stop()
        {
            lock (gate)
            {
                active = false;
                timer.Change(Timeout.Infinite, Timeout.Infinite);
                stopwatch.Stop();
            }
        }

        private void Render(object state)
        {
            try
            {
                lock (gate)
                {
                    if (active)
                    {
                        RenderUnsafe();
                    }
                }
            }
            catch
            {
                // Rendering is observational and must never affect the agent.
            }
        }

        private void RenderUnsafe()
        {
            try
            {
                var elapsed = TimeSpan.FromMilliseconds(baseElapsedMilliseconds + stopwatch.ElapsedMilliseconds);
                var duration = elapsed.TotalHours >= 1
                    ? string.Format("{0}h {1}m {2}s", (int)elapsed.TotalHours, elapsed.Minutes, elapsed.Seconds)
                    : elapsed.TotalMinutes >= 1
                        ? string.Format("{0}m {1}s", (int)elapsed.TotalMinutes, elapsed.Seconds)
                        : string.Format("{0}s", Math.Max(0, (int)elapsed.TotalSeconds));
                var text = string.Format("{0}  {1}  {2}", scope, phase, duration);
                var width = configuredWidth;
                if (useLiveConsoleWidth)
                {
                    width = 0;
                    try
                    {
                        if (Console.WindowWidth > 0)
                        {
                            width = Console.WindowWidth;
                        }
                    }
                    catch { }
                }
                if (width < 20)
                {
                    return;
                }
                var max = width - 1;
                if (text.Length > max)
                {
                    text = text.Substring(0, max - 3) + "...";
                }
                writer.Write("\r\u001b[2K" + text);
                writer.Flush();
            }
            catch
            {
                // Rendering is observational and must never affect the agent.
            }
        }

        public void Dispose()
        {
            Stop();
            timer.Dispose();
            stopwatch.Stop();
        }
    }
}
'@
    }
    catch { }
}
$script:AgentInteractiveTimerAvailable = $null -ne ('DevPilot.AgentInteractiveStatusTimer' -as [type])

if (-not ('DevPilot.AgentEventStream' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;

namespace DevPilot
{
    public sealed class AgentEventWriteResult
    {
        public long Sequence { get; set; }
        public string Timestamp { get; set; }
        public string Json { get; set; }
    }

    public sealed class AgentEventStream : IDisposable
    {
        private readonly object gate = new object();
        private readonly string path;
        private readonly string agent;
        private readonly string instanceId;
        private readonly int processId;
        private readonly TextWriter jsonOutput;
        private readonly Timer heartbeatTimer;
        private readonly int heartbeatIntervalMilliseconds;
        private long sequence;
        private int cycleNumber;
        private int pullRequestId;
        private string sourceCommit = "";
        private bool heartbeatStarted;
        private bool disposed;

        public long MaxBytes { get; set; } = 10 * 1024 * 1024;
        public int RetentionCount { get; set; } = 5;

        public AgentEventStream(
            string path,
            string agent,
            string instanceId,
            int processId,
            int heartbeatIntervalMilliseconds,
            TextWriter jsonOutput)
        {
            this.path = path;
            this.agent = agent;
            this.instanceId = instanceId;
            this.processId = processId;
            this.jsonOutput = jsonOutput;
            this.heartbeatIntervalMilliseconds = Math.Max(1000, heartbeatIntervalMilliseconds);
            heartbeatTimer = new Timer(WriteHeartbeat, null, Timeout.Infinite, Timeout.Infinite);
        }

        public AgentEventWriteResult WriteEvent(
            string eventType,
            string level,
            int cycleNumber,
            int pullRequestId,
            string sourceCommit,
            string dataJson,
            string message)
        {
            lock (gate)
            {
                if (disposed) return null;
                if (eventType == "agent.stopped")
                {
                    heartbeatStarted = false;
                    heartbeatTimer.Change(Timeout.Infinite, Timeout.Infinite);
                }
                this.cycleNumber = cycleNumber;
                this.pullRequestId = pullRequestId;
                this.sourceCommit = sourceCommit ?? "";
                var nextSequence = ++sequence;
                var timestamp = DateTime.UtcNow.ToString("o");
                object data = new Dictionary<string, object>();
                try
                {
                    using (var document = JsonDocument.Parse(
                        string.IsNullOrEmpty(dataJson) ? "{}" : dataJson))
                    {
                        data = document.RootElement.Clone();
                    }
                }
                catch { }
                var agentEvent = new Dictionary<string, object>
                {
                    ["schemaVersion"] = 2,
                    ["agent"] = agent,
                    ["instanceId"] = instanceId,
                    ["processId"] = processId,
                    ["timestamp"] = timestamp,
                    ["sequence"] = nextSequence,
                    ["eventType"] = eventType ?? "",
                    ["level"] = level ?? "info",
                    ["cycleNumber"] = cycleNumber,
                    ["pullRequestId"] = pullRequestId,
                    ["sourceCommit"] = this.sourceCommit,
                    ["data"] = data,
                    ["message"] = message ?? ""
                };
                var json = JsonSerializer.Serialize(agentEvent);
                AppendUnsafe(json);
                if (eventType == "agent.started" && !heartbeatStarted)
                {
                    heartbeatStarted = true;
                    heartbeatTimer.Change(heartbeatIntervalMilliseconds, heartbeatIntervalMilliseconds);
                }
                return new AgentEventWriteResult
                {
                    Sequence = nextSequence,
                    Timestamp = timestamp,
                    Json = json
                };
            }
        }

        private void WriteHeartbeat(object state)
        {
            try
            {
                lock (gate)
                {
                    if (disposed || !heartbeatStarted) return;
                    var heartbeat = new Dictionary<string, object>
                    {
                        ["schemaVersion"] = 2,
                        ["agent"] = agent,
                        ["instanceId"] = instanceId,
                        ["processId"] = processId,
                        ["timestamp"] = DateTime.UtcNow.ToString("o"),
                        ["sequence"] = ++sequence,
                        ["eventType"] = "agent.heartbeat",
                        ["level"] = "debug",
                        ["cycleNumber"] = cycleNumber,
                        ["pullRequestId"] = pullRequestId,
                        ["sourceCommit"] = sourceCommit,
                        ["data"] = new Dictionary<string, object>(),
                        ["message"] = ""
                    };
                    AppendUnsafe(JsonSerializer.Serialize(heartbeat));
                }
            }
            catch
            {
                // Telemetry is observational and must never affect the agent.
            }
        }

        private void AppendUnsafe(string json)
        {
            try
            {
                RotateUnsafe();
                var directory = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
                File.AppendAllText(path, json + Environment.NewLine, new UTF8Encoding(false));
            }
            catch
            {
                // A durable log failure must not change agent behavior.
            }
            try
            {
                if (jsonOutput != null)
                {
                    jsonOutput.WriteLine(json);
                    jsonOutput.Flush();
                }
            }
            catch
            {
                // A JSON sink failure must not change agent behavior.
            }
        }

        private void RotateUnsafe()
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) return;
            if (new FileInfo(path).Length < MaxBytes) return;
            var retention = Math.Max(1, RetentionCount);
            var oldest = path + "." + retention;
            if (File.Exists(oldest)) File.Delete(oldest);
            for (var index = retention - 1; index >= 1; index--)
            {
                var source = path + "." + index;
                if (File.Exists(source)) File.Move(source, path + "." + (index + 1), true);
            }
            File.Move(path, path + ".1", true);
        }

        public void Dispose()
        {
            lock (gate)
            {
                if (disposed) return;
                heartbeatStarted = false;
                heartbeatTimer.Change(Timeout.Infinite, Timeout.Infinite);
                disposed = true;
            }
            heartbeatTimer.Dispose();
        }
    }
}
'@
    }
    catch { }
}
$script:AgentEventStreamAvailable = $null -ne ('DevPilot.AgentEventStream' -as [type])

$script:AgentOutputEventTypes = @(
    'agent.started',
    'agent.heartbeat',
    'agent.stopped',
    'cycle.started',
    'candidates.enumerated',
    'candidate.skipped',
    'candidate.selected',
    'phase.changed',
    'delivery.retrying',
    'delivery.blocked',
    'work.completed',
    'cycle.completed',
    'cycle.failed',
    'agent.waiting'
)

function Test-AgentInteractiveOutput {
    param(
        [bool]$IsOutputRedirected = [Console]::IsOutputRedirected,
        [bool]$SupportsAnsi = ($null -ne $PSStyle -and $PSStyle.OutputRendering -ne 'PlainText'),
        [int]$WindowWidth = $(try { [Console]::WindowWidth } catch { 0 })
    )
    return (-not $IsOutputRedirected -and $SupportsAnsi -and $WindowWidth -ge 60)
}

function New-AgentOutputContext {
    param(
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Agent,
        [ValidateSet('Auto', 'Compact', 'Detailed', 'Json')]
        [string]$OutputMode = 'Auto',
        [string]$LogPath,
        [string]$PerInstanceLogDirectory,
        [int]$HeartbeatIntervalMilliseconds = 5000,
        [bool]$IsOutputRedirected = [Console]::IsOutputRedirected,
        [bool]$SupportsAnsi = ($null -ne $PSStyle -and $PSStyle.OutputRendering -ne 'PlainText'),
        [int]$WindowWidth = $(try { [Console]::WindowWidth } catch { 0 }),
        [scriptblock]$WriteLine = { param($Line) [Console]::Out.WriteLine($Line) },
        [scriptblock]$WriteRaw = { param($Text) [Console]::Out.Write($Text) },
        [System.IO.TextWriter]$InteractiveWriter = [Console]::Out,
        [int]$InteractiveRefreshIntervalMilliseconds = 1000,
        [bool]$UseLiveConsoleWidth = $true
    )
    $resolved = $OutputMode
    if ($OutputMode -eq 'Auto') {
        $resolved = if (Test-AgentInteractiveOutput -IsOutputRedirected $IsOutputRedirected `
                -SupportsAnsi $SupportsAnsi -WindowWidth $WindowWidth) { 'Interactive' } else { 'Compact' }
    }
    if ($resolved -eq 'Interactive' -and -not $script:AgentInteractiveTimerAvailable) {
        $resolved = 'Compact'
    }
    $interactiveTimer = if ($resolved -eq 'Interactive') {
        try {
            New-Object DevPilot.AgentInteractiveStatusTimer(
                $InteractiveWriter,
                [Math]::Max(100, $InteractiveRefreshIntervalMilliseconds),
                $WindowWidth,
                $UseLiveConsoleWidth)
        }
        catch {
            $resolved = 'Compact'
            $null
        }
    }
    $instanceId = [Guid]::NewGuid().ToString('D')
    $instanceLogPath = if ($PerInstanceLogDirectory) {
        Join-Path $PerInstanceLogDirectory "$instanceId.jsonl"
    } else {
        $LogPath
    }
    if ($PerInstanceLogDirectory) {
        try {
            [IO.Directory]::CreateDirectory($PerInstanceLogDirectory) | Out-Null
            $baseLogs = @(Get-ChildItem -LiteralPath $PerInstanceLogDirectory -File -Filter '*.jsonl' |
                Sort-Object LastWriteTimeUtc -Descending)
            # Keep nineteen previous streams so creating the current stream
            # leaves at most twenty base JSONL files per agent.
            foreach ($stale in @($baseLogs | Select-Object -Skip 19)) {
                Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction SilentlyContinue
                1..5 | ForEach-Object {
                    Remove-Item -LiteralPath "$($stale.FullName).$_" -Force -ErrorAction SilentlyContinue
                }
            }
        }
        catch { }
    }
    $eventStream = if ($PerInstanceLogDirectory -and $script:AgentEventStreamAvailable) {
        try {
            $jsonOutput = if ($resolved -eq 'Json') { [Console]::Out } else { $null }
            New-Object DevPilot.AgentEventStream(
                $instanceLogPath,
                $Agent,
                $instanceId,
                $PID,
                [Math]::Max(1000, $HeartbeatIntervalMilliseconds),
                $jsonOutput)
        }
        catch { $null }
    }
    return @{
        Agent = $Agent
        InstanceId = $instanceId
        ProcessId = $PID
        Sequence = [long]0
        RequestedMode = $OutputMode
        Mode = $resolved
        LogPath = $instanceLogPath
        EventStream = $eventStream
        WriteLine = $WriteLine
        WriteRaw = $WriteRaw
        StatusActive = $false
        InteractiveTimer = $interactiveTimer
        LastWorkCompletedCycle = -1
        LogMaxBytes = 10MB
        LogRetentionCount = 5
    }
}

function Set-AgentOutputLegacySuppression {
    <#
        Preference variables are scoped to the module that executes a command.
        A wrapper cannot suppress Write-Warning calls made inside this harness
        merely by changing its own $WarningPreference. Set both module-local
        preferences here so Compact/Interactive/Json output remains owned by
        the event renderer, including when harness helpers emit diagnostics.
    #>
    $script:InformationPreference = 'SilentlyContinue'
    $script:WarningPreference = 'SilentlyContinue'
    $script:PSDefaultParameterValues['Write-Host:InformationAction'] = 'Ignore'
    $script:PSDefaultParameterValues['Write-Warning:WarningAction'] = 'SilentlyContinue'
}

function Get-AgentNormalizedSkipReason {
    param([AllowEmptyString()][string]$Reason)
    $value = $Reason.Trim().ToLowerInvariant()
    if ($value -eq 'draft') { return 'draft' }
    if ($value -match 'authored by the operator') { return 'own' }
    if ($value -match 'title marks .*not ready') { return 'notReady' }
    if ($value -match 'already reviewed|already delivered') { return 'delivered' }
    if ($value -match 'starved|consecutive failures') { return 'starved' }
    if ($value -match 'source commit|40-hex') { return 'invalidCommit' }
    if ($value -match 'selection budget') { return 'budgetExhausted' }
    if ($value -match 'unfinished delivery|delivery plan') { return 'unfinishedDelivery' }
    return 'other'
}

function ConvertTo-ReviewerSafeEventValue {
    param($Value, [int]$Depth = 0, [string]$Key = '')
    if ($Key -match '(?i)(token|secret|password|authorization|credential|^pat$|[_-]pat(?:$|[_-]))') { return '[REDACTED]' }
    if ($Depth -ge 4) { return '[TRUNCATED]' }
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [byte] -or
        $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) { return $Value }
    if ($Value -is [string]) {
        $safeText = $Value
        $safeText = [regex]::Replace($safeText,
            '(?i)\b(authorization|token|secret|password|credential|pat)\s*[:=]\s*(?:bearer\s+)?[^\s;,]+',
            '$1=[REDACTED]')
        $safeText = [regex]::Replace($safeText,
            '(?i)\b(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b',
            '[REDACTED]')
        if ($safeText.Length -le 512) { return $safeText }
        return $safeText.Substring(0, 512) + '...'
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $safe = [ordered]@{}
        $count = 0
        foreach ($itemKey in $Value.Keys) {
            if ($count++ -ge 50) { $safe['_truncated'] = $true; break }
            $name = [string]$itemKey
            $safe[$name] = ConvertTo-ReviewerSafeEventValue -Value $Value[$itemKey] -Depth ($Depth + 1) -Key $name
        }
        return $safe
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $safe = New-Object System.Collections.Generic.List[object]
        $count = 0
        foreach ($item in $Value) {
            if ($count++ -ge 50) { [void]$safe.Add('[TRUNCATED]'); break }
            [void]$safe.Add((ConvertTo-ReviewerSafeEventValue -Value $item -Depth ($Depth + 1)))
        }
        return $safe.ToArray()
    }
    return ConvertTo-ReviewerSafeEventValue -Value ([string]$Value) -Depth ($Depth + 1) -Key $Key
}

function Rotate-ReviewerEventLog {
    param([hashtable]$Context)
    $path = [string]$Context.LogPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
    if ((Get-Item -LiteralPath $path).Length -lt [long]$Context.LogMaxBytes) { return }
    $last = [int]$Context.LogRetentionCount
    $oldest = "$path.$last"
    if (Test-Path -LiteralPath $oldest) { Remove-Item -LiteralPath $oldest -Force }
    for ($i = $last - 1; $i -ge 1; $i--) {
        $source = "$path.$i"
        if (Test-Path -LiteralPath $source) { Move-Item -LiteralPath $source -Destination "$path.$($i + 1)" -Force }
    }
    Move-Item -LiteralPath $path -Destination "$path.1" -Force
}

function Format-AgentCount {
    param([int]$Count, [Parameter(Mandatory)][string]$Singular, [string]$Plural)
    if (-not $Plural) { $Plural = "$Singular`s" }
    return "$Count $(if ($Count -eq 1) { $Singular } else { $Plural })"
}

function Format-ReviewerDuration {
    param([long]$ElapsedMilliseconds)
    $duration = [TimeSpan]::FromMilliseconds([Math]::Max(0, $ElapsedMilliseconds))
    if ($duration.TotalHours -ge 1) { return '{0}h {1}m {2}s' -f [int]$duration.TotalHours, $duration.Minutes, $duration.Seconds }
    if ($duration.TotalMinutes -ge 1) { return '{0}m {1}s' -f [int]$duration.TotalMinutes, $duration.Seconds }
    return '{0}s' -f [Math]::Max(0, [int]$duration.TotalSeconds)
}

function Format-AgentSkipSummary {
    param([System.Collections.IDictionary]$Counts)
    $labels = [ordered]@{
        draft = 'draft'; delivered = 'delivered'; own = 'own'; notReady = 'not ready'
        starved = 'starved'; invalidCommit = 'invalid commit'; budgetExhausted = 'budget exhausted'
        unfinishedDelivery = 'unfinished delivery'; other = 'other'
    }
    $parts = New-Object System.Collections.Generic.List[string]
    $total = 0
    foreach ($key in $labels.Keys) {
        $count = if ($Counts -and $Counts.Contains($key)) { [int]$Counts[$key] } else { 0 }
        $total += $count
        if ($count -gt 0) { [void]$parts.Add("$count $($labels[$key])") }
    }
    if ($parts.Count -eq 0) { [void]$parts.Add('0 routine skips') }
    return "Skipped ${total}: $($parts -join ', ')"
}

function Write-ReviewerInteractiveStatus {
    param(
        [hashtable]$Context,
        [string]$Scope,
        [string]$Phase,
        [long]$ElapsedMilliseconds
    )
    try {
        $Context.InteractiveTimer.Start($Scope, $Phase, $ElapsedMilliseconds)
        $Context.StatusActive = $true
    }
    catch { }
}

function Write-ReviewerOutputLine {
    param([hashtable]$Context, [string]$Text)
    if ($Context.Mode -eq 'Interactive' -and $Context.StatusActive) {
        try { $Context.InteractiveTimer.Stop() } catch { }
        & $Context.WriteRaw ("`r$([char]27)[2K")
        $Context.StatusActive = $false
    }
    & $Context.WriteLine $Text
}

function Write-ReviewerHumanEvent {
    param([hashtable]$Context, [System.Collections.IDictionary]$Event)
    $type = [string]$Event.eventType
    $data = $Event.data
    $cycle = [int]$Event.cycleNumber
    $prId = [int]$Event.pullRequestId
    $message = [string]$Event.message

    if ($Context.Mode -eq 'Detailed') {
        if ($message) { Write-ReviewerOutputLine -Context $Context -Text $message }
        return
    }
    if ($type -eq 'candidate.skipped') { return }
    switch ($type) {
        'agent.started' {
            $name = if ($Context.Agent -eq 'review-handler') { 'Review Handler' } else { 'Reviewer' }
            Write-ReviewerOutputLine $Context "DevPilot $name - RUNNING"
            Write-ReviewerOutputLine $Context ("{0} / {1} / {2} -> {3}" -f $data.organization, $data.project, $data.repository, $data.target)
            Write-ReviewerOutputLine $Context ("Operator: {0}  Writes: {1}  Vote: {2}" -f $data.operator, $data.writes, $data.vote)
        }
        'cycle.started' { Write-ReviewerOutputLine $Context "`nCycle $cycle" }
        'candidates.enumerated' {
            Write-ReviewerOutputLine $Context ("Scanned {0} across {1}" -f
                (Format-AgentCount ([int]$data.scanned) 'PR'), (Format-AgentCount ([int]$data.pages) 'page'))
            $skipTotal = [int](($data.skipped.Values | Measure-Object -Sum).Sum)
            if ($skipTotal -eq 0 -and [int]$data.selected -gt 0) {
                Write-ReviewerOutputLine $Context 'Selected the first eligible candidate; remaining PRs were not evaluated'
            }
            else {
                Write-ReviewerOutputLine $Context (Format-AgentSkipSummary -Counts $data.skipped)
            }
        }
        'candidate.selected' { Write-ReviewerOutputLine $Context ("Selected PR {0} - {1}" -f $prId, $data.title) }
        'phase.changed' {
            $scope = if ($prId -gt 0) { "PR $prId" } else { "Cycle $cycle" }
            if ($Context.Mode -eq 'Interactive') {
                Write-ReviewerInteractiveStatus $Context $scope ([string]$data.phase) ([long]$data.elapsedMilliseconds)
            }
            else {
                $text = "$scope  $($data.phase)  $([string](Format-ReviewerDuration ([long]$data.elapsedMilliseconds)))"
                Write-ReviewerOutputLine $Context $text
            }
        }
        'delivery.retrying' { Write-ReviewerOutputLine $Context ("Retrying unfinished delivery for PR {0} - {1}" -f $prId, $data.title) }
        'delivery.blocked' {
            Write-ReviewerOutputLine $Context "`nWARNING: DELIVERY BLOCKED - PR $prId$(if ($data.title) { " - $($data.title)" })"
            Write-ReviewerOutputLine $Context ([string]$data.reason)
            Write-ReviewerOutputLine $Context ("Outstanding: {0}. Retryable: {1}. Next retry: {2}." -f
                (@($data.outstanding) -join ', '), $(if ($data.retryable) { 'yes' } else { 'no' }), $data.nextRetry)
        }
        'work.completed' {
            Write-ReviewerOutputLine $Context ("`nPR {0} {1} in {2}" -f $prId, $data.result,
                (Format-ReviewerDuration ([long]$data.elapsedMilliseconds)))
            if ($Context.Agent -eq 'reviewer') {
                Write-ReviewerOutputLine $Context ("Findings: {0} critical, {1} important, {2} suggestions" -f
                    $data.critical, $data.important, $data.suggestion)
            }
            elseif ($data.summary) { Write-ReviewerOutputLine $Context ([string]$data.summary) }
            Write-ReviewerOutputLine $Context ("Delivered: {0}" -f $data.delivered)
            if ($data.previewPath) { Write-ReviewerOutputLine $Context ("Preview: {0}" -f $data.previewPath) }
            if ($data.reason) { Write-ReviewerOutputLine $Context ("Result detail: {0}" -f $data.reason) }
            $Context.LastWorkCompletedCycle = $cycle
        }
        'cycle.completed' {
            if ($message -and [int]$Context.LastWorkCompletedCycle -ne $cycle) {
                Write-ReviewerOutputLine $Context $message
            }
        }
        'cycle.failed' { Write-ReviewerOutputLine $Context ("ERROR: Cycle {0} failed: {1}" -f $cycle, $data.reason) }
        'agent.waiting' {
            Write-ReviewerOutputLine $Context ("Next {0} in {1}" -f $data.kind, (Format-ReviewerDuration ([long]$data.delayMilliseconds)))
        }
    }
}

function Publish-AgentEvent {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][ValidateScript({ $script:AgentOutputEventTypes -contains $_ })][string]$EventType,
        [ValidateSet('debug', 'info', 'warning', 'error')][string]$Level = 'info',
        [int]$Cycle = 0,
        [int]$PrId = 0,
        [string]$SourceCommit = '',
        [System.Collections.IDictionary]$Data = @{},
        [AllowEmptyString()][string]$Message = ''
    )
    try {
        $safeData = ConvertTo-ReviewerSafeEventValue -Value $Data
        $safeMessage = ConvertTo-ReviewerSafeEventValue -Value $Message
        $writeResult = $null
        if ($Context.EventStream) {
            $Context.EventStream.MaxBytes = [long]$Context.LogMaxBytes
            $Context.EventStream.RetentionCount = [int]$Context.LogRetentionCount
            $dataJson = ConvertTo-Json -InputObject $safeData -Depth 6 -Compress
            $writeResult = $Context.EventStream.WriteEvent(
                $EventType, $Level, $Cycle, $PrId, $SourceCommit, $dataJson, $safeMessage)
            if (-not $writeResult) { return $null }
            $sequence = [long]$writeResult.Sequence
            $timestamp = [string]$writeResult.Timestamp
        }
        else {
            $Context.Sequence = [long]$Context.Sequence + 1
            $sequence = [long]$Context.Sequence
            $timestamp = [DateTime]::UtcNow.ToString('o')
        }
        $event = [ordered]@{
            schemaVersion = 2
            agent = [string]$Context.Agent
            instanceId = [string]$Context.InstanceId
            processId = [int]$Context.ProcessId
            timestamp = $timestamp
            sequence = $sequence
            eventType = $EventType
            level = $Level
            cycleNumber = $Cycle
            pullRequestId = $PrId
            sourceCommit = $SourceCommit
            data = $safeData
            message = $safeMessage
        }
        $json = if ($writeResult) {
            [string]$writeResult.Json
        }
        else {
            ConvertTo-Json -InputObject $event -Depth 8 -Compress
        }
        try {
            if (-not $Context.EventStream -and $Context.LogPath) {
                Rotate-ReviewerEventLog -Context $Context
                $directory = Split-Path -Parent ([string]$Context.LogPath)
                if ($directory) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
                [IO.File]::AppendAllText([string]$Context.LogPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
            }
        }
        catch { }
        try {
            if ($Context.Mode -eq 'Json') {
                if (-not $Context.EventStream) { & $Context.WriteLine $json }
            }
            else {
                Write-ReviewerHumanEvent -Context $Context -Event $event
            }
        }
        catch { }
        return [pscustomobject]$event
    }
    catch {
        # Output is observational. It must never change reviewer behavior.
        return $null
    }
}

function Close-AgentOutputContext {
    param([Parameter(Mandatory)][hashtable]$Context)
    try {
        Publish-AgentEvent -Context $Context -EventType agent.stopped -Data @{
            reason = 'process exiting'
        } -Message 'Agent process is exiting.' | Out-Null
    }
    catch { }
    try {
        if ($Context.InteractiveTimer) { $Context.InteractiveTimer.Dispose() }
    }
    catch { }
    try {
        if ($Context.EventStream) { $Context.EventStream.Dispose() }
    }
    catch { }
}

Export-ModuleMember -Function @(
    'Test-AgentInteractiveOutput',
    'New-AgentOutputContext',
    'Set-AgentOutputLegacySuppression',
    'Get-AgentNormalizedSkipReason',
    'Format-AgentCount',
    'Format-AgentSkipSummary',
    'Publish-AgentEvent',
    'Close-AgentOutputContext'
)
