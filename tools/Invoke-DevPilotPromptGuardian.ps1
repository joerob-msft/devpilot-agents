#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [Parameter(Mandatory)][int]$BrokerProcessId,
    [Parameter(Mandatory)][string]$BrokerStartIdentity,
    [Parameter(Mandatory)][string]$Token,
    [ValidateRange(1, 300)][int]$DeadlineSeconds = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($IsWindows) { throw 'The prompt guardian is used only on Unix.' }
$root = [IO.Path]::GetFullPath($RuntimeRoot)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Runtime root does not exist.' }
$mode = [IO.File]::GetUnixFileMode($root)
$unsafe = [IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::GroupWrite -bor
    [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherRead -bor
    [IO.UnixFileMode]::OtherWrite -bor [IO.UnixFileMode]::OtherExecute
if (($mode -band $unsafe) -ne 0) { throw 'Runtime root is not access restricted.' }
if ($Token -notmatch '^[0-9a-f]{32}$') { throw 'Guardian token is malformed.' }

$registration = Join-Path $root "guardian-$Token.json"
$readyPath = Join-Path $root "guardian-$Token.ready"
$registeredPath = Join-Path $root "guardian-$Token.registered"
$terminalPath = Join-Path $root "guardian-$Token.terminal.json"
$tracePath = if ($VerbosePreference -ne 'SilentlyContinue') {
    Join-Path $root "guardian-$Token.trace"
} else { $null }
function Write-GuardianTrace {
    param([string]$Message)
    Write-Verbose $Message
    if ($script:tracePath) {
        [IO.File]::AppendAllText($script:tracePath, "$Message`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::SetUnixFileMode($script:tracePath,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
    }
}
[IO.File]::WriteAllText($readyPath, "ready`n", [Text.UTF8Encoding]::new($false))
[IO.File]::SetUnixFileMode($readyPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
Write-GuardianTrace "Guardian ready for broker $BrokerProcessId."
$deadline = [DateTime]::UtcNow.AddSeconds($DeadlineSeconds)
$tracked = @()
$record = $null
$registered = $false
if (-not ('DevPilot.PromptGuardian.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace DevPilot.PromptGuardian {
  public static class Native {
    [DllImport("libc", SetLastError=true)] public static extern int kill(int pid, int signal);
    public static int LastError() { return Marshal.GetLastWin32Error(); }
  }
}
'@
}
function Invoke-GuardianGroupSignal {
    param(
        [int]$ProcessGroupId,
        [string]$LeaderStartIdentity,
        [ValidateSet(0, 9, 15)][int]$Signal
    )
    if ($ProcessGroupId -le 1) {
        throw 'Guardian process group must be a verified child leader PID greater than 1.'
    }
    if ($Signal -ne 0) {
        $leader = Get-Process -Id $ProcessGroupId -ErrorAction SilentlyContinue
        if (-not $leader) { return 'leader-exited' }
        if ($leader.Id -ne $ProcessGroupId) {
            throw 'Guardian process group is not the verified child leader; refusing to signal.'
        }
        if ((Get-GuardianProcessStartIdentity -Process $leader) -cne $LeaderStartIdentity) {
            throw 'Guardian child leader identity changed; refusing to signal a stale process group.'
        }
    }
    $result = [DevPilot.PromptGuardian.Native]::kill(-$ProcessGroupId, $Signal)
    if ($result -eq 0) { return 'alive' }
    $errorNumber = [DevPilot.PromptGuardian.Native]::LastError()
    if ($errorNumber -eq 3) { return 'absent' }
    if ($errorNumber -eq 1 -and $Signal -eq 0) { return 'unknown' }
    if ($errorNumber -eq 1) { throw 'Guardian cannot signal the registered process group (EPERM).' }
    throw "Guardian process-group signal $Signal failed with errno $errorNumber."
}
function Test-GuardianGroupAlive {
    param([int]$ProcessGroupId, [string]$LeaderStartIdentity)
    return ((Invoke-GuardianGroupSignal -ProcessGroupId $ProcessGroupId `
                -LeaderStartIdentity $LeaderStartIdentity -Signal 0) -eq 'alive')
}
function Test-GuardianProcessZombie {
    param([int]$ProcessId)
    if (-not $IsLinux -or $ProcessId -le 0) { return $false }
    try {
        $stat = [IO.File]::ReadAllText("/proc/$ProcessId/stat")
        $nameEnd = $stat.LastIndexOf(')')
        return $nameEnd -ge 0 -and $stat.Length -gt ($nameEnd + 2) -and
            $stat[$nameEnd + 2] -eq 'Z'
    }
    catch {
        return $false
    }
}
function Get-GuardianProcessStartIdentity {
    param([Diagnostics.Process]$Process)
    if ($IsLinux) {
        $stat = [IO.File]::ReadAllText("/proc/$($Process.Id)/stat")
        $nameEnd = $stat.LastIndexOf(')')
        if ($nameEnd -lt 0) { throw 'Malformed procfs process identity.' }
        $fields = @($stat.Substring($nameEnd + 1).Trim() -split '\s+')
        if ($fields.Count -le 19 -or $fields[19] -notmatch '^\d+$') {
            throw 'Malformed procfs process start identity.'
        }
        return "linux:$($fields[19])"
    }
    return "utc:$($Process.StartTime.ToUniversalTime().Ticks)"
}
function Test-GuardianLeaderLive {
    param([int]$ProcessGroupId, [string]$LeaderStartIdentity)
    if ([string]::IsNullOrWhiteSpace($LeaderStartIdentity)) { return $false }
    try {
        $leader = Get-Process -Id $ProcessGroupId -ErrorAction Stop
        return -not (Test-GuardianProcessZombie -ProcessId $ProcessGroupId) -and
            (Get-GuardianProcessStartIdentity -Process $leader) -ceq $LeaderStartIdentity
    }
    catch {
        return $false
    }
}
function Test-GuardianBrokerLive {
    param([int]$ProcessId, [string]$StartIdentity)
    if ([string]::IsNullOrWhiteSpace($StartIdentity)) { return $false }
    try {
        $broker = Get-Process -Id $ProcessId -ErrorAction Stop
        return -not (Test-GuardianProcessZombie -ProcessId $ProcessId) -and
            (Get-GuardianProcessStartIdentity -Process $broker) -ceq $StartIdentity
    }
    catch {
        return $false
    }
}
$terminationRequested = $false
while ($true) {
    $brokerAlive = Test-GuardianBrokerLive -ProcessId $BrokerProcessId `
        -StartIdentity $BrokerStartIdentity
    if (Test-Path -LiteralPath $registration -PathType Leaf) {
        try {
            $record = Get-Content -LiteralPath $registration -Raw -Encoding UTF8 |
                ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch [IO.IOException] {
            Start-Sleep -Milliseconds 25
            continue
        }
        if ([string]$record.token -cne $Token) { throw 'Guardian registration token mismatch.' }
        $tracked = @($record.paths | ForEach-Object {
                $candidate = [IO.Path]::GetFullPath((Join-Path $root ([string]$_)))
                if (-not $candidate.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
                    throw 'Guardian registration escaped the runtime root.'
                }
                $candidate
            })
        if ($tracked.Count -gt 0 -and -not (Test-Path -LiteralPath $registeredPath)) {
            [IO.File]::WriteAllText($registeredPath, "registered`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::SetUnixFileMode($registeredPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
            Write-GuardianTrace "Guardian registered child process group $($record['childProcessId'])."
        }
        $registered = $tracked.Count -gt 0
    }
    if (-not $registered -and [DateTime]::UtcNow -ge $deadline) {
        throw 'Guardian registration timed out.'
    }
    $childProcessId = if ($record -and $record.ContainsKey('childProcessId')) {
        [int]$record['childProcessId']
    } else { 0 }
    $childLeaderStartIdentity = if ($record -and $record.ContainsKey('childLeaderStartIdentity')) {
        [string]$record['childLeaderStartIdentity']
    } else { '' }
    if (Test-Path -LiteralPath $terminalPath -PathType Leaf) {
        $terminal = Get-Content -LiteralPath $terminalPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ([int]$terminal.schemaVersion -ne 1 -or [string]$terminal.operation -cne 'terminal-handoff' -or
            [string]$terminal.token -cne $Token) {
            throw 'Guardian terminal handoff authentication failed.'
        }
        if ($childProcessId -le 0 -or -not (Test-GuardianGroupAlive -ProcessGroupId $childProcessId `
                    -LeaderStartIdentity $childLeaderStartIdentity)) {
            foreach ($path in $tracked) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $registration, $readyPath, $registeredPath, $terminalPath -Force -ErrorAction SilentlyContinue
            if ($tracePath) { Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue }
            exit 0
        }
    }
    if (-not $brokerAlive) {
        if (-not $terminationRequested) {
            Write-GuardianTrace "Guardian observed broker $BrokerProcessId exit."
        }
        if (-not $terminationRequested -and $childProcessId -gt 0 -and
            (Test-GuardianLeaderLive -ProcessGroupId $childProcessId `
                    -LeaderStartIdentity $childLeaderStartIdentity)) {
            $terminationRequested = $true
            $termResult = Invoke-GuardianGroupSignal -ProcessGroupId $childProcessId `
                -LeaderStartIdentity $childLeaderStartIdentity -Signal 15
            Write-GuardianTrace "Guardian sent TERM to process group $childProcessId ($termResult)."
            Start-Sleep -Milliseconds 500
            if (Test-GuardianLeaderLive -ProcessGroupId $childProcessId `
                    -LeaderStartIdentity $childLeaderStartIdentity) {
                $killResult = Invoke-GuardianGroupSignal -ProcessGroupId $childProcessId `
                    -LeaderStartIdentity $childLeaderStartIdentity -Signal 9
                Write-GuardianTrace "Guardian sent KILL to process group $childProcessId ($killResult)."
            }
        }
        elseif (-not $terminationRequested -and $childProcessId -gt 0) {
            $currentLeader = Get-Process -Id $childProcessId -ErrorAction SilentlyContinue
            $currentTicks = if ($currentLeader) {
                try { Get-GuardianProcessStartIdentity -Process $currentLeader } catch { '<unavailable>' }
            } else { '<absent>' }
            Write-GuardianTrace (
                "Guardian refused unverified leader $childProcessId " +
                "(recorded=$childLeaderStartIdentity,current=$currentTicks).")
            $terminationRequested = $true
        }
        if ($childProcessId -le 0 -or -not (Test-GuardianGroupAlive -ProcessGroupId $childProcessId `
                    -LeaderStartIdentity $childLeaderStartIdentity)) {
            foreach ($path in $tracked) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $registration, $readyPath, $registeredPath, $terminalPath `
                -Force -ErrorAction SilentlyContinue
            if ($tracePath) { Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue }
            exit 0
        }
    }
    Start-Sleep -Milliseconds 100
}
