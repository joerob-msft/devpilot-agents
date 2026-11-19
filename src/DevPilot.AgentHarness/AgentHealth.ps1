# Agent health, failure-detail extraction, operator skips, and model preflight.
#
# Every function here is observational bookkeeping. Callers wrap them so a
# failure to read or write health/skip state can never break a review cycle.

$script:AgentHealthStuckThreshold = 3
$script:AgentHealthFailingThreshold = 3
$script:AgentHealthBackoffCapSeconds = 14400
$script:AgentHealthMaxTrackedPrs = 200
$script:AgentSkippedPrsMaxEntries = 200
$script:AgentFailureResults = @('failed', 'deferred', 'error')
$script:AgentNonSuccessResults = @('failed', 'deferred', 'error', 'blocked')
# Cycle-level results that neither prove nor disprove the agent can do work.
$script:AgentNeutralResults = @('blocked', 'idle', 'retried', 'skipped', 'none', '')
# Results that complete work without moving the PR forward; repeating one on
# the same commit is what makes a PR "stuck".
$script:AgentNoProgressResults = @('no-safe-progress', 'no-progress', 'validation-failed')
$script:AgentTransientFailurePattern = '(?i)timeout|timed out|\b429\b|rate limit|\b503\b|\b502\b|ECONNRESET|network|temporar'
$script:AgentSecretLinePattern = '(?i)Bearer |token=|Authorization'
$script:AgentAnsiPattern = '\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B\[[0-?]*[ -/]*[@-~]|\x1B[@-Z\\-_]'
# Agency prints a banner of emoji-prefixed status lines (robot, folder, package,
# brain, check mark, plug, rocket, ...) before the child's own output.
$script:AgentBannerLinePattern = '^\s*(?:[\uD800-\uDBFF][\uDC00-\uDFFF]|[\u2190-\u2BFF])'

function ConvertTo-AgentFailureLines {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $lines = foreach ($raw in ($Text -split "`r?`n")) {
        $line = ($raw -replace $script:AgentAnsiPattern, '') -replace '[\x00-\x08\x0B-\x1F\x7F]', ''
        $line = ($line -replace '\s+', ' ').Trim()
        if (-not $line) { continue }
        if ($line -match $script:AgentSecretLinePattern) { continue }
        $line
    }
    return @($lines)
}

function Get-AgentFailureDetail {
    <#
        One single-line, ANSI-free, secret-free sentence (<= 240 chars) that
        explains why a child run failed: the last `Error:` line from stderr then
        stdout, else the last non-banner stderr line, else the fallback reason.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$StdErr = '',
        [AllowNull()][AllowEmptyString()][string]$StdOut = '',
        [AllowNull()][AllowEmptyString()][string]$FallbackReason = ''
    )
    try {
        $err = @(ConvertTo-AgentFailureLines -Text $StdErr)
        $out = @(ConvertTo-AgentFailureLines -Text $StdOut)
        $pick = @($err | Where-Object { $_ -cmatch '^Error:' }) | Select-Object -Last 1
        if (-not $pick) { $pick = @($out | Where-Object { $_ -cmatch '^Error:' }) | Select-Object -Last 1 }
        if (-not $pick) { $pick = @($err | Where-Object { $_ -notmatch $script:AgentBannerLinePattern }) | Select-Object -Last 1 }
        if (-not $pick) { $pick = @(ConvertTo-AgentFailureLines -Text $FallbackReason) -join ' ' }
        $detail = ([string]$pick).Trim()
        if ($detail.Length -gt 240) { $detail = $detail.Substring(0, 237) + '...' }
        return $detail
    }
    catch { return '' }
}

function Get-AgentNormalizedFailureText {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $value = $Text.ToLowerInvariant() -replace '\b[0-9a-f]{40}\b', '<sha>' -replace '\d+', '#'
    return ($value -replace '\s+', ' ').Trim()
}

function Get-AgentFailureKind {
    param(
        [AllowNull()][AllowEmptyString()][string]$FailureDetail = '',
        [AllowNull()][AllowEmptyString()][string]$PreviousFailureDetail = ''
    )
    if ($FailureDetail -match $script:AgentTransientFailurePattern) { return 'transient' }
    $current = Get-AgentNormalizedFailureText -Text $FailureDetail
    if ($current -and $current -eq (Get-AgentNormalizedFailureText -Text $PreviousFailureDetail)) { return 'persistent' }
    return 'unknown'
}

function New-AgentHealthState {
    return @{
        schemaVersion = 1; consecutiveFailures = 0; failingSinceUtc = $null; lastSuccessUtc = $null
        cause = ''; lastFailureDetail = ''; lastAlertedState = 'healthy'; alertedStuck = @(); prs = @{}
    }
}

function ConvertTo-AgentHealthHashtable {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($key in $Value.Keys) { $copy[[string]$key] = ConvertTo-AgentHealthHashtable $Value[$key] }
        return $copy
    }
    if ($Value -is [pscustomobject]) {
        $copy = @{}
        foreach ($p in $Value.PSObject.Properties) { $copy[$p.Name] = ConvertTo-AgentHealthHashtable $p.Value }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return , @($Value | ForEach-Object { ConvertTo-AgentHealthHashtable $_ })
    }
    return $Value
}

function Read-AgentHealthState {
    param([Parameter(Mandatory)][string]$Path)
    $state = New-AgentHealthState
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $state }
        $loaded = ConvertTo-AgentHealthHashtable (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop)
        if ($loaded -isnot [hashtable] -or [int]$loaded['schemaVersion'] -ne 1) { return $state }
        foreach ($key in @($state.Keys)) { if ($loaded.ContainsKey($key) -and $null -ne $loaded[$key]) { $state[$key] = $loaded[$key] } }
        if ($state.prs -isnot [hashtable]) { $state.prs = @{} }
        $state.alertedStuck = @($state.alertedStuck | Where-Object { $_ })
        $state.consecutiveFailures = [Math]::Max(0, [int]$state.consecutiveFailures)
    }
    catch { return (New-AgentHealthState) }
    return $state
}

function Write-AgentHealthState {
    <# Atomic, owner-private write (best effort). Never throws. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$State)
    $temp = "$Path.tmp-$PID-$([Guid]::NewGuid().ToString('N'))"
    try {
        $directory = Split-Path -Parent $Path
        if ($directory) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
        [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $State -Depth 8), [Text.UTF8Encoding]::new($false))
        if (-not $IsWindows) { try { & chmod 600 $temp 2>$null } catch { } }
        [IO.File]::Move($temp, $Path, $true)
        return $true
    }
    catch { return $false }
    finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}

function Get-AgentStuckBackoffSeconds {
    <# Doubles from the normal interval per repeat past the threshold, capped at 4 h. #>
    param(
        [Parameter(Mandatory)][int]$RepeatCount,
        [int]$BaseSeconds = 300,
        [int]$CapSeconds = $script:AgentHealthBackoffCapSeconds
    )
    $base = [Math]::Max(1, $BaseSeconds)
    if ($RepeatCount -lt $script:AgentHealthStuckThreshold) { return $base }
    $exponent = [Math]::Min(30, $RepeatCount - $script:AgentHealthStuckThreshold + 1)
    return [int][Math]::Min([double]$CapSeconds, $base * [Math]::Pow(2, $exponent))
}

function Get-AgentHealthStuckList {
    param([Parameter(Mandatory)][hashtable]$State)
    $stuck = foreach ($key in @($State.prs.Keys)) {
        $pr = $State.prs[$key]
        if ([int]$pr.repeatCount -ge $script:AgentHealthStuckThreshold) {
            [ordered]@{
                pullRequestId = [int]$key; sourceCommit = [string]$pr.sourceCommit; outcome = [string]$pr.outcome
                repeatCount = [int]$pr.repeatCount; nextAttemptUtc = [string]$pr.nextAttemptUtc
            }
        }
    }
    return @($stuck | Sort-Object { $_.pullRequestId })
}

function Get-AgentHealthStateName {
    param([Parameter(Mandatory)][hashtable]$State)
    if ([int]$State.consecutiveFailures -ge $script:AgentHealthFailingThreshold) { return 'failing' }
    if (@(Get-AgentHealthStuckList -State $State).Count -gt 0) { return 'stuck' }
    return 'healthy'
}

function Update-AgentHealthState {
    <#
        Folds one work.completed outcome into the health state and returns the
        resulting agent.health payload plus the alert-worthy transition, if any.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Result,
        [int]$PullRequestId = 0,
        [AllowEmptyString()][string]$SourceCommit = '',
        [AllowEmptyString()][string]$Outcome = '',
        [AllowEmptyString()][string]$FailureDetail = '',
        [DateTime]$NowUtc = [DateTime]::UtcNow,
        [int]$BaseIntervalSeconds = 300
    )
    $now = $NowUtc.ToUniversalTime()
    $previous = Get-AgentHealthStateName -State $State
    $normalizedResult = $Result.ToLowerInvariant()
    $isFailure = $script:AgentFailureResults -contains $normalizedResult
    $isSuccess = ($script:AgentNonSuccessResults -notcontains $normalizedResult) -and ($script:AgentNeutralResults -notcontains $normalizedResult)
    if ($isFailure) {
        $State.consecutiveFailures = [int]$State.consecutiveFailures + 1
        if (-not $State.failingSinceUtc) { $State.failingSinceUtc = $now.ToString('o') }
        $State.cause = $FailureDetail
        $State.lastFailureDetail = $FailureDetail
    }
    elseif ($isSuccess) {
        $State.consecutiveFailures = 0
        $State.failingSinceUtc = $null
        $State.lastSuccessUtc = $now.ToString('o')
        $State.cause = ''
    }

    if ($PullRequestId -gt 0) {
        $key = [string]$PullRequestId
        $noProgress = (-not $isSuccess) -or ($script:AgentNoProgressResults -contains $normalizedResult) -or
            ($script:AgentNoProgressResults -contains $Outcome.ToLowerInvariant())
        if ($noProgress) {
            $normalizedOutcome = Get-AgentNormalizedFailureText -Text $(if ($Outcome) { $Outcome } else { $Result })
            $commit = $SourceCommit.ToLowerInvariant()
            $prior = $State.prs[$key]
            $repeat = if ($prior -and [string]$prior.sourceCommit -eq $commit -and [string]$prior.outcome -eq $normalizedOutcome) {
                [int]$prior.repeatCount + 1
            } else { 1 }
            $next = if ($repeat -ge $script:AgentHealthStuckThreshold) {
                $now.AddSeconds((Get-AgentStuckBackoffSeconds -RepeatCount $repeat -BaseSeconds $BaseIntervalSeconds)).ToString('o')
            } else { '' }
            $State.prs[$key] = @{ sourceCommit = $commit; outcome = $normalizedOutcome; repeatCount = $repeat; nextAttemptUtc = $next; lastAtUtc = $now.ToString('o') }
        }
        elseif ($State.prs.ContainsKey($key)) { $State.prs.Remove($key) }
        if ($State.prs.Count -gt $script:AgentHealthMaxTrackedPrs) {
            foreach ($old in @($State.prs.Keys | Sort-Object { [string]$State.prs[$_].lastAtUtc } |
                    Select-Object -First ($State.prs.Count - $script:AgentHealthMaxTrackedPrs))) { $State.prs.Remove($old) }
        }
    }

    $current = Get-AgentHealthStateName -State $State
    $stuck = @(Get-AgentHealthStuckList -State $State)
    $stuckKeys = @($stuck | ForEach-Object { "$($_.pullRequestId):$($_.sourceCommit)" })
    $newlyStuck = @($stuck | Where-Object { @($State.alertedStuck) -notcontains "$($_.pullRequestId):$($_.sourceCommit)" })
    $alert = $null
    $lastAlerted = [string]$State.lastAlertedState
    if ($current -eq 'failing' -and $lastAlerted -ne 'failing') { $alert = 'failing' }
    elseif ($current -ne 'failing' -and $newlyStuck.Count -gt 0) { $alert = 'stuck' }
    elseif ($current -eq 'healthy' -and $lastAlerted -ne 'healthy') { $alert = 'recovered' }
    if ($alert) { $State.lastAlertedState = $current }
    $State.alertedStuck = @($stuckKeys)

    $stuckPr = if ($stuck.Count -gt 0) { [int]$stuck[0].pullRequestId } else { 0 }
    return @{
        Previous = $previous
        State = $current
        Changed = ($previous -ne $current)
        Alert = $alert
        NewlyStuck = $newlyStuck
        PullRequestId = $stuckPr
        Data = [ordered]@{
            state = $current
            consecutiveFailures = [int]$State.consecutiveFailures
            failingSinceUtc = $State.failingSinceUtc
            lastSuccessUtc = $State.lastSuccessUtc
            cause = [string]$State.cause
            stuck = @($stuck)
        }
    }
}

function Get-AgentHealthStuckRetryUtc {
    <# Returns the backoff deadline when this PR+commit is stuck and still waiting, else $null. #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][int]$PullRequestId,
        [AllowEmptyString()][string]$SourceCommit = '',
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )
    try {
        $pr = $State.prs[[string]$PullRequestId]
        if (-not $pr -or [int]$pr.repeatCount -lt $script:AgentHealthStuckThreshold) { return $null }
        if (-not $SourceCommit -or [string]$pr.sourceCommit -ne $SourceCommit.ToLowerInvariant()) { return $null }
        $next = [DateTime]::Parse([string]$pr.nextAttemptUtc, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
        if ($next -gt $NowUtc.ToUniversalTime()) { return $next }
    }
    catch { }
    return $null
}

function Get-AgentHealthAlertText {
    param(
        [Parameter(Mandatory)][string]$RoleLabel,
        [Parameter(Mandatory)][hashtable]$Update,
        [AllowEmptyString()][string]$RepositoryName = '',
        [int]$RecoveredPullRequestId = 0
    )
    $repo = if ($RepositoryName) { " on $RepositoryName" } else { '' }
    $data = $Update.Data
    switch ([string]$Update.Alert) {
        'failing' {
            $since = ''
            try { $since = ' since ' + ([DateTime]::Parse([string]$data.failingSinceUtc).ToLocalTime().ToString('h:mm tt', [Globalization.CultureInfo]::InvariantCulture)) } catch { }
            $cause = if ($data.cause) { ": $($data.cause)" } else { '' }
            return "DevPilot: $RoleLabel failing$repo - $($data.consecutiveFailures) failures in a row$since$cause"
        }
        'stuck' {
            $pr = @($Update.NewlyStuck)[0]
            return "DevPilot: $RoleLabel stuck$repo - PR #$($pr.pullRequestId) returned '$($pr.outcome)' $($pr.repeatCount) times on the same commit; backing off until $($pr.nextAttemptUtc)"
        }
        'recovered' {
            $what = if ($RecoveredPullRequestId -gt 0) { " (completed PR #$RecoveredPullRequestId)" } else { '' }
            return "DevPilot: $RoleLabel recovered$repo$what"
        }
    }
    return ''
}

function Read-AgentSkippedPrs {
    <# Operator skip list written by the canvas. Missing/invalid -> empty; never throws. #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
        $file = Get-Item -LiteralPath $Path
        if ($file.Length -gt 1MB) { return @() }
        $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
        if ([int]$doc.schemaVersion -ne 1) { return @() }
        $entries = foreach ($e in @($doc.entries | Select-Object -Last $script:AgentSkippedPrsMaxEntries)) {
            $id = 0
            if ($null -eq $e -or -not [int]::TryParse([string]$e.pullRequestId, [ref]$id) -or $id -le 0) { continue }
            $commit = [string]$e.sourceCommit
            if ($commit -notmatch '^[0-9a-fA-F]{40}$') { continue }
            [pscustomobject]@{ repositoryKey = [string]$e.repositoryKey; pullRequestId = $id; sourceCommit = $commit.ToLowerInvariant() }
        }
        return @($entries)
    }
    catch { return @() }
}

function Test-AgentPrOperatorSkipped {
    param(
        [AllowNull()][object[]]$Entries,
        [AllowEmptyString()][string]$RepositoryKey = '',
        [Parameter(Mandatory)][int]$PullRequestId,
        [AllowEmptyString()][string]$SourceCommit = ''
    )
    if (-not $SourceCommit) { return $false }
    foreach ($e in @($Entries)) {
        if ($null -eq $e -or [int]$e.pullRequestId -ne $PullRequestId) { continue }
        if ([string]$e.sourceCommit -ne $SourceCommit.ToLowerInvariant()) { continue }
        if ($RepositoryKey -and $e.repositoryKey -and [string]$e.repositoryKey -ne $RepositoryKey) { continue }
        return $true
    }
    return $false
}

function Invoke-AgentModelPreflight {
    <#
        Proves a model is usable through the same `agency copilot --` path the
        agents use, from an empty temp working directory so no repo MCP config
        is loaded. Returns @{ Succeeded; FailureDetail; ExitCode }. Output is
        never logged; only the sanitized failure detail leaves this function.
    #>
    param(
        [Parameter(Mandatory)][string]$Model,
        [string]$AgencyPath = 'agency',
        [int]$TimeoutSeconds = 120,
        [scriptblock]$Launcher
    )
    $arguments = @('copilot', '--', '-p', 'Reply with the single word OK', '--model', $Model,
        '--name', '[DevPilot] model preflight')
    $workDir = Join-Path ([IO.Path]::GetTempPath()) ("devpilot-preflight-" + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($workDir) | Out-Null
        $run = if ($Launcher) {
            & $Launcher $AgencyPath $arguments $workDir $TimeoutSeconds
        }
        else {
            $psi = [Diagnostics.ProcessStartInfo]::new($AgencyPath)
            foreach ($a in $arguments) { $psi.ArgumentList.Add($a) }
            $psi.WorkingDirectory = $workDir
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardInput = $true
            $process = [Diagnostics.Process]::Start($psi)
            $process.StandardInput.Close()
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $exited = $process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)
            if (-not $exited) { try { $process.Kill($true) } catch { } }
            [void]$process.WaitForExit(5000)
            @{
                ExitCode = $(if ($exited) { $process.ExitCode } else { -1 })
                TimedOut = -not $exited
                StdOut = $(if ($stdoutTask.Wait(5000)) { $stdoutTask.Result } else { '' })
                StdErr = $(if ($stderrTask.Wait(5000)) { $stderrTask.Result } else { '' })
            }
        }
        if ($run -isnot [System.Collections.IDictionary]) { throw 'preflight launcher returned no result' }
        if ([bool]$run['TimedOut']) {
            return @{ Succeeded = $false; ExitCode = -1; FailureDetail = "timed out after $TimeoutSeconds s" }
        }
        if ([int]$run['ExitCode'] -eq 0) { return @{ Succeeded = $true; ExitCode = 0; FailureDetail = '' } }
        $detail = Get-AgentFailureDetail -StdErr ([string]$run['StdErr']) -StdOut ([string]$run['StdOut']) `
            -FallbackReason "exit code $($run['ExitCode'])"
        return @{ Succeeded = $false; ExitCode = [int]$run['ExitCode']; FailureDetail = $detail }
    }
    catch {
        return @{ Succeeded = $false; ExitCode = -1; FailureDetail = (Get-AgentFailureDetail -FallbackReason $_.Exception.Message) }
    }
    finally { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Add-AgentWorkFailureFields {
    <#
        Adds failureDetail/failureLogPath/failureKind to a failed or deferred
        work.completed payload (in place). Existing values win, so call sites
        with the child's stderr can pre-populate a better detail.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Data,
        [AllowNull()][hashtable]$HealthState
    )
    try {
        $result = ([string]$Data['result']).ToLowerInvariant()
        if ($script:AgentFailureResults -notcontains $result) { return }
        if (-not $Data.Contains('failureDetail') -or -not [string]$Data['failureDetail']) {
            $Data['failureDetail'] = Get-AgentFailureDetail -FallbackReason ([string]$Data['reason'])
        }
        else { $Data['failureDetail'] = Get-AgentFailureDetail -FallbackReason ([string]$Data['failureDetail']) }
        if (-not $Data.Contains('failureLogPath')) { $Data['failureLogPath'] = '' }
        $previous = if ($HealthState) { [string]$HealthState.lastFailureDetail } else { '' }
        $Data['failureKind'] = Get-AgentFailureKind -FailureDetail ([string]$Data['failureDetail']) -PreviousFailureDetail $previous
    }
    catch { }
}

function Get-AgentHealthEventMessage {
    param([Parameter(Mandatory)][string]$RoleLabel, [Parameter(Mandatory)][hashtable]$Update)
    $data = $Update.Data
    switch ([string]$data.state) {
        'failing' {
            $cause = if ($data.cause) { ": $($data.cause)" } else { '' }
            return "$RoleLabel failing - $($data.consecutiveFailures) failures in a row$cause"
        }
        'stuck' {
            $ids = @($data.stuck | ForEach-Object { "#$($_.pullRequestId)" }) -join ', '
            return "$RoleLabel healthy but PR(s) $ids keep returning the same outcome; backing off"
        }
    }
    return "$RoleLabel healthy"
}

function Get-AgentCandidateHold {
    <#
        Returns why a candidate must be left alone this cycle - an operator
        skip at its current commit, or a stuck-PR backoff - or $null. Never
        throws: unreadable state simply means "no hold".
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$StateDir = '',
        [AllowNull()][hashtable]$HealthState,
        [AllowEmptyString()][string]$RepositoryKey = '',
        [Parameter(Mandatory)][int]$PullRequestId,
        [AllowEmptyString()][string]$SourceCommit = '',
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )
    if (-not $StateDir) { return $null }
    try {
        $entries = Read-AgentSkippedPrs -Path (Join-Path $StateDir 'skipped-prs.json')
        if (Test-AgentPrOperatorSkipped -Entries $entries -RepositoryKey $RepositoryKey -PullRequestId $PullRequestId -SourceCommit $SourceCommit) {
            return @{ Kind = 'operatorSkipped'; Reason = 'skipped by operator until a new commit'; NextAttemptUtc = ''
                Message = "PR $PullRequestId skipped by operator until a new commit" }
        }
        if ($HealthState) {
            $next = Get-AgentHealthStuckRetryUtc -State $HealthState -PullRequestId $PullRequestId -SourceCommit $SourceCommit -NowUtc $NowUtc
            if ($next) {
                $stamp = $next.ToString('o')
                return @{ Kind = 'stuckBackoff'; Reason = "repeated identical outcome; backing off until $stamp"; NextAttemptUtc = $stamp
                    Message = "PR $PullRequestId skipped (same outcome repeated on this commit; backing off until $stamp)" }
            }
        }
    }
    catch { }
    return $null
}

function Get-AgentModelPreflightPlanLine {
    param([string[]]$Models = @(), [switch]$Skip)
    $distinct = @($Models | Where-Object { $_ } | Select-Object -Unique)
    if ($Skip) { return '  Model preflight     : skipped (-SkipModelPreflight)' }
    if ($distinct.Count -eq 0) { return '  Model preflight     : none (no automatic roles)' }
    return "  Model preflight     : will verify $($distinct -join ', ') before starting agents"
}

function Assert-AgentModelPreflight {
    <# Throws the operator-facing error for the first configured model that cannot answer. #>
    param(
        [string[]]$Models = @(),
        [string]$AgencyPath = 'agency',
        [int]$TimeoutSeconds = 120,
        [scriptblock]$Launcher
    )
    foreach ($model in @($Models | Where-Object { $_ } | Select-Object -Unique)) {
        $probe = Invoke-AgentModelPreflight -Model $model -AgencyPath $AgencyPath -TimeoutSeconds $TimeoutSeconds -Launcher $Launcher
        if (-not $probe.Succeeded) {
            throw "DevPilot model preflight failed for model '$model': $($probe.FailureDetail). Choose a supported model (copilot --help) or pass -SkipModelPreflight."
        }
    }
}

Export-ModuleMember -Function @(
    'Get-AgentFailureDetail', 'Get-AgentFailureKind', 'New-AgentHealthState', 'Read-AgentHealthState',
    'Write-AgentHealthState', 'Get-AgentStuckBackoffSeconds', 'Update-AgentHealthState',
    'Get-AgentHealthStuckRetryUtc', 'Get-AgentHealthAlertText', 'Read-AgentSkippedPrs',
    'Test-AgentPrOperatorSkipped', 'Invoke-AgentModelPreflight', 'Get-AgentModelPreflightPlanLine',
    'Assert-AgentModelPreflight', 'Add-AgentWorkFailureFields', 'Get-AgentHealthEventMessage',
    'Get-AgentCandidateHold'
)
