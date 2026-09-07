param(
    [string]$ConfigFile, [string]$RepoPath, [string]$StateDir, [string]$EventLogDirectory,
    [string]$DurableStateRoot, [string]$LeaseRoot, [string]$OperatorAlias, [string]$AgentName,
    [int]$PullRequestId, [int]$IntervalSeconds, [switch]$Once, [switch]$ForceAnalysis,
    [switch]$IncludeOwnPullRequests, [string]$OutputMode, [string]$Model,
    [string]$ManualDispatchManifest, [string]$LauncherWorkerManifest,
    [switch]$EnableFindingComments, [switch]$EnableThreadReplies, [switch]$EnableSummaryComment,
    [switch]$EnableBuddyRequeue, [switch]$EnableCodeChanges, [switch]$EnablePush,
    [switch]$LocalValidation, [switch]$ResumeCodingSession, [switch]$EnableTeamsNotifications
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
if (-not $env:DEVPILOT_SCHEDULING_FIXTURE) { throw 'Isolated fixture root required.' }
$root = $env:DEVPILOT_SCHEDULING_FIXTURE
$role = if ($PSCommandPath -match 'ReviewHandler') { 'review-handler' } else { 'reviewer' }
$config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -AsHashtable
$identity = @{ schemaVersion = 1; key = 'v1:github:114'; verified = $true }
$context = Get-AgentDurableStateContext -DurableStateRoot $DurableStateRoot -RepositoryIdentity $identity -Role $role -Create
$lease = $null; $state = $null; $descendant = $null
function Mark([string]$Name, $Value) {
    [IO.File]::WriteAllText((Join-Path $root $Name), (ConvertTo-Json $Value -Depth 10 -Compress), [Text.UTF8Encoding]::new($false))
}
try {
    if ($ManualDispatchManifest) {
        Assert-AgentManualDispatchEarlyContext $ManualDispatchManifest
        if ($config.testMode -eq 'startup-barrier' -and -not (Test-Path (Join-Path $root "contained-$PID"))) {
            throw 'Manual worker escaped its early containment barrier.'
        }
        $event = Join-Path $EventLogDirectory "manual-$PID.jsonl"
        $bound = if ($role -ceq 'reviewer') {
            @{ EnableFindingComments = [bool]$EnableFindingComments; EnableSummaryComment = [bool]$EnableSummaryComment
                EnableThreadReplies = [bool]$EnableThreadReplies; EnableApprovalVote = $false }
        }
        else {
            @{ EnableThreadReplies = [bool]$EnableThreadReplies; EnableBuddyRequeue = [bool]$EnableBuddyRequeue
                EnableCodeChanges = [bool]$EnableCodeChanges; EnablePush = [bool]$EnablePush
                LocalValidation = [bool]$LocalValidation; ResumeCodingSession = [bool]$ResumeCodingSession; EnableAutoComplete = $false }
        }
        $prompt = Enter-AgentManualDispatchStartup -ManifestPath $ManualDispatchManifest -RepositoryIdentity $identity `
            -RepositoryRoot $RepoPath -DurableContext $context -LeaseRoot $LeaseRoot -Role $role `
            -EventLogPath $event -BoundCapabilities $bound
        if ($prompt -cne 'isolated scheduling context') { throw 'Wrong fixture prompt.' }
        Mark 'manual-started' @{ pid = $PID; role = $role; pr = $PullRequestId; capabilities = $bound }
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        while (-not (Test-Path (Join-Path $root 'manual-release'))) {
            if (Test-AgentManualCancellationRequested $identity $PullRequestId $role) { break }
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Manual fixture timed out.' }
            Start-Sleep -Milliseconds 50
        }
        return
    }
    Initialize-AgentLauncherWorker -ManifestPath $LauncherWorkerManifest
    if ($config.testRole -ceq $role) {
        if ($config.testMode -ceq 'auto-startup-fail') { exit 17 }
        if (Test-Path (Join-Path $root 'manual-started')) {
            if ($config.testMode -ceq 'auto-resume-fail') { exit 17 }
            if ($config.testMode -ceq 'auto-resume-wait') {
                Mark 'resume-starting' $PID
                $deadline = [DateTime]::UtcNow.AddSeconds(30)
                while (-not (Test-Path (Join-Path $root 'resume-allow'))) {
                    if ([DateTime]::UtcNow -gt $deadline) { throw 'Resume fixture timed out.' }
                    Start-Sleep -Milliseconds 50
                }
            }
        }
    }
    Confirm-AgentLauncherWorkerStartup
    if ($role -ceq 'review-handler' -and $config.testRole -cne $role) {
        while ($true) { Wait-AgentLauncherInterval -Seconds 1 }
    }
    if ($role -ceq 'reviewer' -and $config.testRole -cne $role) {
        while ($true) { Wait-AgentLauncherInterval -Seconds 1 }
    }
    $generation = (Get-Content $LauncherWorkerManifest -Raw | ConvertFrom-Json).workerId
    Mark "launched-$generation" @{ pid = $PID; model = $Model; interval = $IntervalSeconds
        once = [bool]$Once; includeOwn = [bool]$IncludeOwnPullRequests; teams = [bool]$EnableTeamsNotifications
        finding = [bool]$EnableFindingComments; push = [bool]$EnablePush }
    foreach ($id in @(114, 115)) {
        $lease = Enter-AgentWorkLease -LeaseRoot $LeaseRoot -RepositoryIdentity $identity -PullRequestId $id -Role $role
        if (-not $lease.Acquired) {
            Mark 'foreign-contended' $lease.Reason
            while ($true) { Wait-AgentLauncherInterval -Seconds 1 }
        }
        $state = Enter-AgentDurableStateLock -Context $context
        if (-not $state.Acquired) {
            Mark 'foreign-contended' $state.Reason
            Exit-AgentLock $lease.Stream
            $lease = $null
            while ($true) { Wait-AgentLauncherInterval -Seconds 1 }
        }
        Mark "acquired-$generation-$id" @{ pid = $PID; role = $role; pr = $id }
        if ($config.testMode -in @('descendant', 'ack-descendant', 'termination-failed')) {
            $descendant = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 60') `
                -StandardOutputPath (Join-Path $root 'descendant.stdout') -StandardErrorPath (Join-Path $root 'descendant.stderr')
            Mark 'descendant-pid' $descendant.Process.Id
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        while (-not (Test-Path (Join-Path $root "release-$id"))) {
            if ($config.testMode -notin @('descendant', 'termination-failed') -and (Test-AgentLauncherCancellationRequested)) {
                Mark 'cancel-observed' $id
                throw '[cancelled] Isolated automatic worker acknowledged cancellation.'
            }
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Automatic fixture timed out.' }
            Start-Sleep -Milliseconds 50
        }
        Exit-AgentLock $state.Stream; $state = $null
        Exit-AgentLock $lease.Stream; $lease = $null
        Mark "released-$id" $generation
    }
    while ($true) { Wait-AgentLauncherInterval -Seconds 1 }
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
    Exit-AgentManualDispatchAuthority
    Close-AgentLauncherWorker
}
