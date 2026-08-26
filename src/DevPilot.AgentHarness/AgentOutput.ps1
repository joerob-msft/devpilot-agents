Set-StrictMode -Version Latest

$script:AgentOutputEventTypes = @(
    'agent.started',
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
        [bool]$IsOutputRedirected = [Console]::IsOutputRedirected,
        [bool]$SupportsAnsi = ($null -ne $PSStyle -and $PSStyle.OutputRendering -ne 'PlainText'),
        [int]$WindowWidth = $(try { [Console]::WindowWidth } catch { 0 }),
        [scriptblock]$WriteLine = { param($Line) [Console]::Out.WriteLine($Line) },
        [scriptblock]$WriteRaw = { param($Text) [Console]::Out.Write($Text) }
    )
    $resolved = $OutputMode
    if ($OutputMode -eq 'Auto') {
        $resolved = if (Test-AgentInteractiveOutput -IsOutputRedirected $IsOutputRedirected `
                -SupportsAnsi $SupportsAnsi -WindowWidth $WindowWidth) { 'Interactive' } else { 'Compact' }
    }
    return @{
        Agent = $Agent
        InstanceId = [Guid]::NewGuid().ToString('D')
        ProcessId = $PID
        Sequence = [long]0
        RequestedMode = $OutputMode
        Mode = $resolved
        LogPath = $LogPath
        WriteLine = $WriteLine
        WriteRaw = $WriteRaw
        StatusActive = $false
        LogMaxBytes = 10MB
        LogRetentionCount = 5
    }
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
    if ($Key -match '(?i)(token|secret|password|authorization|credential|pat)') { return '[REDACTED]' }
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
    param([hashtable]$Context, [string]$Text)
    $width = try { [Console]::WindowWidth } catch { 80 }
    $max = [Math]::Max(20, $width - 1)
    if ($Text.Length -gt $max) { $Text = $Text.Substring(0, $max - 3) + '...' }
    & $Context.WriteRaw ("`r$([char]27)[2K$Text")
    $Context.StatusActive = $true
}

function Write-ReviewerOutputLine {
    param([hashtable]$Context, [string]$Text)
    if ($Context.Mode -eq 'Interactive' -and $Context.StatusActive) {
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
            Write-ReviewerOutputLine $Context (Format-AgentSkipSummary -Counts $data.skipped)
        }
        'candidate.selected' { Write-ReviewerOutputLine $Context ("Selected PR {0} - {1}" -f $prId, $data.title) }
        'phase.changed' {
            $text = "PR $prId  $($data.phase)  $([string](Format-ReviewerDuration ([long]$data.elapsedMilliseconds)))"
            if ($Context.Mode -eq 'Interactive') { Write-ReviewerInteractiveStatus $Context $text }
            else { Write-ReviewerOutputLine $Context $text }
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
        }
        'cycle.completed' { if ($message) { Write-ReviewerOutputLine $Context $message } }
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
        $Context.Sequence = [long]$Context.Sequence + 1
        $event = [ordered]@{
            agent = [string]$Context.Agent
            instanceId = [string]$Context.InstanceId
            processId = [int]$Context.ProcessId
            timestamp = [DateTime]::UtcNow.ToString('o')
            sequence = [long]$Context.Sequence
            eventType = $EventType
            level = $Level
            cycleNumber = $Cycle
            pullRequestId = $PrId
            sourceCommit = $SourceCommit
            data = ConvertTo-ReviewerSafeEventValue -Value $Data
            message = ConvertTo-ReviewerSafeEventValue -Value $Message
        }
        $json = ConvertTo-Json -InputObject $event -Depth 8 -Compress
        try {
            if ($Context.LogPath) {
                Rotate-ReviewerEventLog -Context $Context
                $directory = Split-Path -Parent ([string]$Context.LogPath)
                if ($directory) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
                [IO.File]::AppendAllText([string]$Context.LogPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
            }
        }
        catch { }
        try {
            if ($Context.Mode -eq 'Json') { & $Context.WriteLine $json }
            else { Write-ReviewerHumanEvent -Context $Context -Event $event }
        }
        catch { }
        return [pscustomobject]$event
    }
    catch {
        # Output is observational. It must never change reviewer behavior.
        return $null
    }
}

Export-ModuleMember -Function @(
    'Test-AgentInteractiveOutput',
    'New-AgentOutputContext',
    'Get-AgentNormalizedSkipReason',
    'Format-AgentCount',
    'Format-AgentSkipSummary',
    'Publish-AgentEvent'
)
