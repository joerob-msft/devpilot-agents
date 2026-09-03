#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [Parameter(Mandatory)][int]$BrokerProcessId,
    [Parameter(Mandatory)][long]$BrokerStartTimeUtcTicks,
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
[IO.File]::WriteAllText($readyPath, "ready`n", [Text.UTF8Encoding]::new($false))
[IO.File]::SetUnixFileMode($readyPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
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
        [long]$LeaderStartTimeUtcTicks,
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
        if ($LeaderStartTimeUtcTicks -le 0 -or
            $leader.StartTime.ToUniversalTime().Ticks -ne $LeaderStartTimeUtcTicks) {
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
    param([int]$ProcessGroupId, [long]$LeaderStartTimeUtcTicks)
    return ((Invoke-GuardianGroupSignal -ProcessGroupId $ProcessGroupId `
                -LeaderStartTimeUtcTicks $LeaderStartTimeUtcTicks -Signal 0) -eq 'alive')
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
function Test-GuardianLeaderLive {
    param([int]$ProcessGroupId, [long]$LeaderStartTimeUtcTicks)
    if ($LeaderStartTimeUtcTicks -le 0) { return $false }
    try {
        $leader = Get-Process -Id $ProcessGroupId -ErrorAction Stop
        return -not (Test-GuardianProcessZombie -ProcessId $ProcessGroupId) -and
            $leader.StartTime.ToUniversalTime().Ticks -eq $LeaderStartTimeUtcTicks
    }
    catch {
        return $false
    }
}
function Test-GuardianBrokerLive {
    param([int]$ProcessId, [long]$StartTimeUtcTicks)
    if ($StartTimeUtcTicks -le 0) { return $false }
    try {
        $broker = Get-Process -Id $ProcessId -ErrorAction Stop
        return -not (Test-GuardianProcessZombie -ProcessId $ProcessId) -and
            $broker.StartTime.ToUniversalTime().Ticks -eq $StartTimeUtcTicks
    }
    catch {
        return $false
    }
}
$terminationRequested = $false
while ($true) {
    $brokerAlive = Test-GuardianBrokerLive -ProcessId $BrokerProcessId `
        -StartTimeUtcTicks $BrokerStartTimeUtcTicks
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
        }
        $registered = $tracked.Count -gt 0
    }
    if (-not $registered -and [DateTime]::UtcNow -ge $deadline) {
        throw 'Guardian registration timed out.'
    }
    $childProcessId = if ($record -and $record.ContainsKey('childProcessId')) {
        [int]$record['childProcessId']
    } else { 0 }
    $childLeaderStartTimeUtcTicks = if ($record -and $record.ContainsKey('childLeaderStartTimeUtcTicks')) {
        [long]$record['childLeaderStartTimeUtcTicks']
    } else { 0 }
    if (Test-Path -LiteralPath $terminalPath -PathType Leaf) {
        $terminal = Get-Content -LiteralPath $terminalPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ([int]$terminal.schemaVersion -ne 1 -or [string]$terminal.operation -cne 'terminal-handoff' -or
            [string]$terminal.token -cne $Token) {
            throw 'Guardian terminal handoff authentication failed.'
        }
        if ($childProcessId -le 0 -or -not (Test-GuardianGroupAlive -ProcessGroupId $childProcessId `
                    -LeaderStartTimeUtcTicks $childLeaderStartTimeUtcTicks)) {
            foreach ($path in $tracked) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $registration, $readyPath, $registeredPath, $terminalPath -Force -ErrorAction SilentlyContinue
            exit 0
        }
    }
    if (-not $brokerAlive) {
        if (-not $terminationRequested -and $childProcessId -gt 0 -and
            (Test-GuardianLeaderLive -ProcessGroupId $childProcessId `
                    -LeaderStartTimeUtcTicks $childLeaderStartTimeUtcTicks)) {
            $terminationRequested = $true
            [void](Invoke-GuardianGroupSignal -ProcessGroupId $childProcessId `
                    -LeaderStartTimeUtcTicks $childLeaderStartTimeUtcTicks -Signal 15)
            Start-Sleep -Milliseconds 500
            if (Test-GuardianLeaderLive -ProcessGroupId $childProcessId `
                    -LeaderStartTimeUtcTicks $childLeaderStartTimeUtcTicks) {
                [void](Invoke-GuardianGroupSignal -ProcessGroupId $childProcessId `
                        -LeaderStartTimeUtcTicks $childLeaderStartTimeUtcTicks -Signal 9)
            }
        }
        if ($childProcessId -le 0 -or -not (Test-GuardianGroupAlive -ProcessGroupId $childProcessId `
                    -LeaderStartTimeUtcTicks $childLeaderStartTimeUtcTicks)) {
            foreach ($path in $tracked) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $registration, $readyPath, $registeredPath, $terminalPath -Force -ErrorAction SilentlyContinue
            exit 0
        }
    }
    Start-Sleep -Milliseconds 100
}
