param(
    [string]$ConfigFile, [string]$RepoPath, [string]$StateDir, [string]$EventLogDirectory,
    [string]$DurableStateRoot, [string]$LeaseRoot, [string]$OperatorAlias, [string]$AgentName,
    [int]$PullRequestId, [int]$IntervalSeconds, [switch]$Once, [switch]$ForceAnalysis,
    [switch]$IncludeOwnPullRequests, [string]$OutputMode, [string]$Model,
    [string]$ManualDispatchManifest, [string]$LauncherWorkerManifest,
    [switch]$EnableFindingComments, [switch]$EnableThreadReplies, [switch]$EnableSummaryComment
)
if ($ManualDispatchManifest) {
    if ((Get-Content $ConfigFile -Raw | ConvertFrom-Json).testMode -ceq 'manual-poll') {
        [IO.File]::WriteAllText((Join-Path $env:DEVPILOT_SCHEDULING_FIXTURE 'manual-startup-wait'), 'fixture')
        Start-Sleep -Seconds 2
    }
    & (Join-Path $PSScriptRoot 'ManualFixture.ps1') @PSBoundParameters
    return
}
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
$root = $env:DEVPILOT_SCHEDULING_FIXTURE
if (-not $root) { throw 'An isolated polling fixture root is required.' }
$role = if ($PSCommandPath -match 'ReviewHandler') { 'review-handler' } else { 'reviewer' }
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json -AsHashtable
$lease = $null; $state = $null
function Mark-PollingFixture([string]$Name, $Value) {
    [IO.File]::WriteAllText((Join-Path $root $Name), (ConvertTo-Json $Value -Compress -Depth 10))
}
try {
    Initialize-AgentLauncherWorker $LauncherWorkerManifest
    Confirm-AgentLauncherWorkerStartup
    Mark-PollingFixture "$role.launch" @{
        processId = $PID; interval = $IntervalSeconds; once = [bool]$Once
        finding = [bool]$EnableFindingComments; replies = [bool]$EnableThreadReplies; summary = [bool]$EnableSummaryComment
    }
    for ($cycle = 1; $true; $cycle++) {
        if ($role -ceq 'reviewer' -and $config.testMode -cin @('manual-next', 'manual-replace', 'manual-poll') -and $cycle -eq 1) {
            $identity = @{ key = 'v1:github:114'; verified = $true }
            $context = Get-AgentDurableStateContext $DurableStateRoot $identity reviewer -Create
            $lease = Enter-AgentWorkLease $LeaseRoot $identity 114 reviewer
            if (-not $lease.Acquired) { throw 'Fixture work lease was not acquired.' }
            $state = Enter-AgentDurableStateLock $context
            if (-not $state.Acquired) { throw 'Fixture state lock was not acquired.' }
        }
        Mark-PollingFixture "$role.scan-$cycle" $PID
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (-not (Test-Path (Join-Path $root "$role.finish-$cycle"))) {
            if (Test-AgentLauncherCancellationRequested) { throw '[cancelled] Isolated work cancelled.' }
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Polling fixture scan barrier timed out.' }
            Start-Sleep -Milliseconds 25
        }
        if ($state) { Exit-AgentLock $state.Stream; $state = $null }
        if ($lease) { Exit-AgentLock $lease.Stream; $lease = $null }
        if ($Once) { break }
        Wait-AgentLauncherInterval -Seconds $(if ($config.testMode -ceq 'natural') { 1 } else { $IntervalSeconds })
    }
}
catch {
    if ($_.Exception.Message -notmatch '^\[(launcher-yielded|cancelled)\]') { throw }
}
finally {
    if ($state) { Exit-AgentLock $state.Stream }
    if ($lease) {
        try { Exit-AgentLock $lease.Stream }
        catch { if ($_.Exception.Message -notmatch '^\[launcher-yielded\]') { throw } }
    }
    Close-AgentLauncherWorker
}
