#Requires -Version 7.0
<#
.SYNOPSIS
    Start, watch and stop a DevPilot agent running unattended in the background.

.DESCRIPTION
    An agent loop is a long-running process that spends most of its time waiting
    on a model. Running it in a terminal works, but the terminal then owns it:
    close the window and the agent dies, and there is no way to ask a detached
    process what it is doing.

    This script is the operator's side of that. It launches the agent detached,
    records the process identity so a later invocation can find it again, and
    exposes the three things an operator actually needs: is it alive, what is it
    doing, and stop it.

    It deliberately owns no agent behaviour. Everything after -AgentArguments is
    passed through untouched, so the agent's own contract - what it may write,
    what it reviews, which models it uses - stays entirely in the agent's
    parameters and its config file, where it can be reviewed. This script cannot
    grant an agent a capability the agent would not otherwise have.

    Runtime files live under <StateDir>\runner\, beside the state the agent
    already keeps, so an agent and its supervision are removed together.

.PARAMETER Action
    start     Launch the agent detached. Refuses if it is already running.
    status    Report whether it is alive, for how long, and what it last did.
    tail      Follow the console output live. Ctrl-C stops watching, not the agent.
    stop      Terminate the agent and any model process it spawned.
    install   Register a scheduled task so it starts at logon and survives reboot.
    uninstall Remove that scheduled task. Does not stop a running agent.

.PARAMETER AgentScript
    Path to the agent entry point, e.g. src/Agents/reviewer/Start-ReviewerAgent.ps1.
    Required for start and install.

.PARAMETER StateDir
    The agent's state directory - the same value passed to the agent as -StateDir.
    Required, and required to be explicit: supervision that guesses where an agent
    keeps its state can end up watching a different agent than the one it started.

.PARAMETER AgentArguments
    Everything to pass to the agent, verbatim.

.PARAMETER Name
    Names this run, so one state directory can host more than one. Default 'agent'.

.PARAMETER Lines
    How many lines of console output `tail` shows before following. Default 40.

.EXAMPLE
    # Start a two-pass reviewer that posts nothing, and watch it.
    # The pairing comes from the supported-model registry rather than being
    # typed out, so a retired model version cannot be started by copy-paste.
    $pair = Get-AgentGeneralistModelPair
    $state = "$env:LOCALAPPDATA\DevPilot\Reviewer\bpm"
    ./tools/Invoke-AgentControl.ps1 -Action start -Name bpm-reviewer -StateDir $state `
        -AgentScript ./src/Agents/reviewer/Start-ReviewerAgent.ps1 `
        -AgentArguments @(
            '-ConfigFile', 'C:\repos\my-repo\.github\copilot\agents\reviewer.config.json',
            '-OperatorAlias', 'myalias',
            '-StateDir', $state,
            '-Model', $pair.First, '-SecondPassModel', $pair.Second)

    ./tools/Invoke-AgentControl.ps1 -Action status -Name bpm-reviewer -StateDir $state
    ./tools/Invoke-AgentControl.ps1 -Action tail   -Name bpm-reviewer -StateDir $state
    ./tools/Invoke-AgentControl.ps1 -Action stop   -Name bpm-reviewer -StateDir $state
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('start', 'status', 'tail', 'stop', 'install', 'uninstall')]
    [string]$Action,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
    [string]$StateDir,

    [ValidateNotNullOrEmpty()][ValidatePattern('^[A-Za-z0-9._-]{1,64}$')]
    [string]$Name = 'agent',

    [string]$AgentScript,

    [string[]]$AgentArguments = @(),

    [ValidateRange(1, 1000)]
    [int]$Lines = 40
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Scheduled tasks, Win32_Process and the agents themselves are all Windows-only.
# Said here, once, rather than letting it surface as a missing cmdlet halfway
# through registering a task.
if (-not $IsWindows) {
    throw "Invoke-AgentControl.ps1 requires Windows: it uses the ScheduledTasks cmdlets and Win32_Process, and the agents it supervises are Windows-only."
}

$runnerDir = Join-Path $StateDir 'runner'
$pidPath = Join-Path $runnerDir "$Name.pid.json"
$logPath = Join-Path $runnerDir "$Name.console.log"
$prevLogPath = Join-Path $runnerDir "$Name.console.previous.log"
$taskName = "DevPilotAgent-$Name"

function Get-RecordedProcess {
    <#
        A bare PID is not an identity: Windows reuses process ids, and a stale
        .pid file left by a machine that lost power will eventually name a
        process that exists and is something else entirely - which `stop` would
        then kill. The recorded start time is what turns the pid back into an
        identity, because a reused id cannot also reproduce the original launch
        instant. A mismatch is treated as "not running", never as "close enough".
    #>
    if (-not (Test-Path -LiteralPath $pidPath)) { return $null }
    try { $rec = Get-Content -LiteralPath $pidPath -Raw | ConvertFrom-Json } catch { return $null }
    $props = @($rec.PSObject.Properties.Name)
    if ($props -notcontains 'ProcessId' -or $props -notcontains 'StartTimeTicks') { return $null }
    $proc = Get-Process -Id ([int]$rec.ProcessId) -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    $recordedTicks = [long]$rec.StartTimeTicks
    if ($proc.StartTime.Ticks -ne $recordedTicks) { return $null }
    return [pscustomobject]@{ Process = $proc; Record = $rec }
}

function Get-DescendantProcessIds {
    <#
        The agent launches the model as a child process. Terminating only the
        parent leaves that child running: it holds no lock, so nothing complains,
        and it keeps consuming a model budget nobody is watching. Descendants are
        collected by parent id - never by process name, which would match
        unrelated work the operator is doing in another window.

        Discovery is best effort. Where the process table cannot be queried at
        all, failing outright would take `stop` down with it and leave the
        operator unable to kill even the parent - a strictly worse outcome than
        killing the parent and saying plainly that any children may have
        survived.
    #>
    param([Parameter(Mandatory)][int]$RootProcessId)
    try { $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction Stop) }
    catch {
        Write-Warning ("Could not read the process table ($($_.Exception.Message)); child processes cannot be " +
            "identified. Any model process this agent spawned may keep running after it is stopped.")
        return @()
    }
    $result = New-Object System.Collections.Generic.List[int]
    $frontier = [System.Collections.Generic.Queue[int]]::new()
    $frontier.Enqueue($RootProcessId)
    while ($frontier.Count -gt 0) {
        $current = $frontier.Dequeue()
        foreach ($p in $all) {
            if ([int]$p.ParentProcessId -eq $current -and -not $result.Contains([int]$p.ProcessId)) {
                [void]$result.Add([int]$p.ProcessId)
                $frontier.Enqueue([int]$p.ProcessId)
            }
        }
    }
    return $result.ToArray()
}

function Get-AgentArgumentLine {
    <#
        For DISPLAY only. Quoted as PowerShell literals rather than with
        backslash escapes, so what `status` prints can be pasted back into a
        PowerShell prompt unchanged - backslash-escaping is a shell convention
        PowerShell does not share, and a command line that looks copyable but
        is not is worse than one that obviously needs editing.
    #>
    param([string[]]$Arguments)
    return (@($Arguments | ForEach-Object {
                if ([string]::IsNullOrEmpty($_) -or $_ -match '[\s''"`$]') { "'" + ($_ -replace "'", "''") + "'" } else { $_ }
            }) -join ' ')
}

function Show-RecentCycles {
    <#
        The console log says what the agent printed; the JSONL cycle log says
        what it decided. The second is the one worth reading, because it is the
        agent's own structured record rather than prose meant for a human.

        Each agent names its own log after itself, so the file is discovered
        rather than assumed: hard-coding one agent's filename here would silently
        report "no cycle log yet" for every other agent this script supervises.
    #>
    param([int]$Count = 5)
    $logDir = Join-Path $StateDir 'logs'
    $jsonl = @(Get-ChildItem -LiteralPath $logDir -Filter '*.log.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($jsonl.Count -eq 0) {
        Write-Host "  (no *.log.jsonl cycle log yet under $logDir)" -ForegroundColor DarkGray
        return
    }
    $recent = @(Get-Content -LiteralPath $jsonl[0].FullName -Tail $Count -ErrorAction SilentlyContinue)
    if ($recent.Count -eq 0) { Write-Host "  (cycle log $($jsonl[0].Name) is empty)" -ForegroundColor DarkGray; return }
    foreach ($line in $recent) {
        try { $r = $line | ConvertFrom-Json } catch { continue }
        $fields = @($r.PSObject.Properties |
            Where-Object { $_.Name -in @('ts', 'cycle', 'result', 'prId', 'reason', 'reviewModels', 'passesCompleted') } |
            ForEach-Object {
                # ConvertFrom-Json turns an ISO timestamp into a DateTime and it
                # then prints in the host's short local format, which is neither
                # what the log holds nor sortable. Put it back.
                $v = if ($_.Value -is [DateTime]) { $_.Value.ToUniversalTime().ToString('u') } else { $_.Value -join ',' }
                "$($_.Name)=$v"
            })
        Write-Host "  $($fields -join '  ')" -ForegroundColor DarkGray
    }
}

switch ($Action) {

    'start' {
        if (-not $AgentScript) { throw "-AgentScript is required to start an agent." }
        $resolvedScript = (Resolve-Path -LiteralPath $AgentScript).Path
        $existing = Get-RecordedProcess
        if ($existing) {
            throw ("'$Name' is already running as process $($existing.Process.Id) (started $($existing.Process.StartTime.ToString('u'))). " +
                "Stop it first, or pick a different -Name.")
        }

        [void](New-Item -ItemType Directory -Path $runnerDir -Force)

        # An unattended agent that posts is a different proposition from one that
        # only prepares reviews for a human to approve, and the difference is a
        # switch that is easy to leave on. Say so at the point of no return.
        $writeSwitches = @($AgentArguments | Where-Object { $_ -match '^-Enable(FindingComments|SummaryComment|ApprovalVote)$' })
        if ($writeSwitches.Count -gt 0) {
            Write-Warning ("This agent will WRITE to the pull request unattended ($($writeSwitches -join ', ')). " +
                "Nobody will read its output before it posts.")
        }
        else {
            Write-Host "This agent posts nothing: it will prepare reviews for you to read and promote." -ForegroundColor DarkGray
        }

        # One generation of console output is kept. Losing the log of the run that
        # just crashed to the run that replaced it is exactly when it was needed.
        if (Test-Path -LiteralPath $logPath) { Move-Item -LiteralPath $logPath -Destination $prevLogPath -Force }

        $psArgs = @('-NoProfile', '-NonInteractive', '-File', $resolvedScript) + $AgentArguments
        $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $psArgs `
            -RedirectStandardOutput $logPath -RedirectStandardError (Join-Path $runnerDir "$Name.stderr.log") `
            -WindowStyle Hidden -PassThru

        # Read the identity back off the OS rather than trusting what was asked
        # for: this is the same tuple `status` and `stop` will match against.
        Start-Sleep -Milliseconds 400
        $live = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if (-not $live) {
            Write-Warning "The agent exited immediately. Last output:"
            if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Tail 20 | ForEach-Object { Write-Host "  $_" } }
            throw "Failed to start '$Name'."
        }

        [pscustomobject]@{
            Name           = $Name
            ProcessId      = $live.Id
            StartTimeTicks = $live.StartTime.Ticks
            StartedUtc     = [DateTime]::UtcNow.ToString('o')
            AgentScript    = $resolvedScript
            AgentArguments = $AgentArguments
            StateDir       = $StateDir
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pidPath -Encoding UTF8

        Write-Host "Started '$Name' as process $($live.Id)." -ForegroundColor Green
        Write-Host "  console : $logPath"
        Write-Host "  follow  : ./tools/Invoke-AgentControl.ps1 -Action tail -Name $Name -StateDir `"$StateDir`""
        Write-Host "  stop    : ./tools/Invoke-AgentControl.ps1 -Action stop -Name $Name -StateDir `"$StateDir`""
    }

    'status' {
        $current = Get-RecordedProcess
        if (-not $current) {
            Write-Host "'$Name' is NOT running." -ForegroundColor Yellow
            if (Test-Path -LiteralPath $pidPath) {
                Write-Host "  A stale record remains at $pidPath (the recorded process is gone or was replaced)." -ForegroundColor DarkGray
            }
        }
        else {
            $uptime = [DateTime]::Now - $current.Process.StartTime
            Write-Host "'$Name' is RUNNING as process $($current.Process.Id)." -ForegroundColor Green
            Write-Host "  uptime  : $([int]$uptime.TotalHours)h $($uptime.Minutes)m"
            Write-Host "  command : $($current.Record.AgentScript) $(Get-AgentArgumentLine -Arguments @($current.Record.AgentArguments))"
            $children = @(Get-DescendantProcessIds -RootProcessId $current.Process.Id)
            Write-Host "  children: $(if ($children.Count) { $children -join ', ' } else { 'none detected (between cycles)' })"
        }

        Write-Host ""
        Write-Host "Recent cycles:"
        Show-RecentCycles -Count 5

        $previews = @(Get-ChildItem -LiteralPath (Join-Path $StateDir 'previews') -Filter '*.md' -ErrorAction SilentlyContinue)
        $failed = @(Get-ChildItem -LiteralPath (Join-Path $StateDir 'logs\failed-cycles') -ErrorAction SilentlyContinue)
        Write-Host ""
        Write-Host "Reviews waiting to be read : $($previews.Count)  ($(Join-Path $StateDir 'previews'))"
        Write-Host "Failed-cycle transcripts   : $($failed.Count)"
        if ($previews.Count -gt 0) {
            Write-Host "  newest: $(($previews | Sort-Object LastWriteTime -Descending | Select-Object -First 1).Name)" -ForegroundColor DarkGray
        }
        if (Test-Path -LiteralPath $logPath) {
            Write-Host ""
            Write-Host "Last console lines:"
            Get-Content -LiteralPath $logPath -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        }
    }

    'tail' {
        if (-not (Test-Path -LiteralPath $logPath)) { throw "No console log for '$Name' at $logPath. Has it been started?" }
        Write-Host "Following $logPath - Ctrl-C stops watching, it does NOT stop the agent." -ForegroundColor DarkGray
        Get-Content -LiteralPath $logPath -Tail $Lines -Wait
    }

    'stop' {
        $current = Get-RecordedProcess
        if (-not $current) {
            Write-Host "'$Name' is not running; nothing to stop." -ForegroundColor Yellow
            if (Test-Path -LiteralPath $pidPath) { Remove-Item -LiteralPath $pidPath -Force }
            break
        }
        # Children first: killing the parent first re-parents them and loses the
        # only link back to what they belonged to.
        $children = @(Get-DescendantProcessIds -RootProcessId $current.Process.Id)
        foreach ($childPid in $children) {
            Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue
        }
        Stop-Process -Id $current.Process.Id -Force -ErrorAction SilentlyContinue

        # The record is the ONLY link back to this process, so it is deleted only
        # once the process is confirmed gone. Deleting it optimistically is worse
        # than leaving it: a still-running agent with no record is one `start`
        # away from a second instance, and the operator has been told it stopped.
        if (-not $current.Process.WaitForExit(10000)) {
            Write-Warning ("Process $($current.Process.Id) did not exit within 10s. The record at $pidPath is kept " +
                "so it can still be found - re-run -Action stop, or investigate before starting '$Name' again.")
            exit 1
        }
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue

        Write-Host "Stopped '$Name' (process $($current.Process.Id)$(if ($children.Count) { " and $($children.Count) child process(es)" }))." -ForegroundColor Green
        $survivors = @($children | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($survivors.Count -gt 0) {
            Write-Warning "Child process(es) $($survivors -join ', ') outlived the agent and must be dealt with separately."
        }
        # Worth stating plainly, because "I killed it mid-review" is the moment an
        # operator wonders what they broke. The agent's own single-writer lock is
        # released by the OS when the handle closes, its state writes are atomic,
        # and an interrupted cycle is simply re-attempted - including one killed
        # after it had already posted, because posted comments are recognised
        # from the pull request itself rather than from local state.
        Write-Host "An interrupted cycle is discarded and re-attempted on the next run; no state is left half-written." -ForegroundColor DarkGray
    }

    'install' {
        if (-not $AgentScript) { throw "-AgentScript is required to install a scheduled task." }
        $resolvedScript = (Resolve-Path -LiteralPath $AgentScript).Path
        $selfPath = $PSCommandPath
        # -File cannot carry these arguments: an -AgentArguments value that
        # begins with '-' (which every agent switch does) is parsed as a
        # parameter name of THIS script rather than as an array element, and the
        # task silently fails at logon with "Missing an argument". A -Command
        # payload with an explicit array literal removes the ambiguity, at the
        # cost of having to quote every value exactly once.
        $quote = { param([string]$s) "'" + ($s -replace "'", "''") + "'" }
        $commandText = ("& {0} -Action start -Name {1} -StateDir {2} -AgentScript {3}" -f `
            (& $quote $selfPath), (& $quote $Name), (& $quote $StateDir), (& $quote $resolvedScript))
        if ($AgentArguments.Count -gt 0) {
            $commandText += " -AgentArguments @(" + ((@($AgentArguments) | ForEach-Object { & $quote $_ }) -join ',') + ")"
        }
        if ($commandText.Contains('"')) {
            throw "Refusing to register a task whose command line contains a double quote; quote handling would be ambiguous."
        }

        # Deliberately NOT $action/$trigger: PowerShell variable names are
        # case-insensitive, so $action would silently re-bind the validated
        # $Action parameter and fail its ValidateSet. This is the same footgun
        # the reviewer agent's own self-checks scan for.
        $taskAction = New-ScheduledTaskAction -Execute (Get-Process -Id $PID).Path `
            -Argument ("-NoProfile -NonInteractive -Command `"$commandText`"")
        $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
        # Interactive-token, no stored password, and no elevation: an unattended
        # agent should not run with more authority than the person supervising it.
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
            -LogonType Interactive -RunLevel Limited
        $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger `
            -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
        Write-Host "Registered scheduled task '$taskName' to start '$Name' at logon." -ForegroundColor Green
        Write-Host "  It starts the agent the same way -Action start does, so status/tail/stop still work." -ForegroundColor DarkGray
        Write-Host "  Remove with: -Action uninstall -Name $Name -StateDir `"$StateDir`"" -ForegroundColor DarkGray
    }

    'uninstall' {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task) { Write-Host "No scheduled task '$taskName'." -ForegroundColor Yellow; break }
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Removed scheduled task '$taskName'. A currently running agent is unaffected; stop it with -Action stop." -ForegroundColor Green
    }
}
