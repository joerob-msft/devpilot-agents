#requires -Version 7.0

<#
.SYNOPSIS
    Launches DevPilot agents and observes them in one dashboard.

.DESCRIPTION
    Starts the reviewer, review-handler, or both in isolated child processes
    and observes their event streams. Runs are preview-only unless Operational
    is passed. Operational binds the agents' fixed production capability set;
    notification delivery remains independently opt-in per role. By default
    each selected agent runs one cycle. Continuous keeps the agents cycling
    until the dashboard exits, then stops every process tree owned by this
    launcher. AttachOnly observes an existing state root without launching an
    agent.

.EXAMPLE
    .\tools\Watch-DevPilotAgents.ps1 -Agent Both -Continuous

.EXAMPLE
    .\tools\Watch-DevPilotAgents.ps1 -Agent ReviewHandler -Continuous -IntervalSeconds 60

.EXAMPLE
    .\tools\Watch-DevPilotAgents.ps1 -AttachOnly -StateDir C:\DevPilot\watch
#>
[CmdletBinding(DefaultParameterSetName = 'Launch')]
param(
    [Parameter(ParameterSetName = 'Launch')]
    [ValidateSet('Reviewer', 'ReviewHandler', 'Both')]
    [string]$Agent = 'Both',

    [Parameter(Mandatory, ParameterSetName = 'Attach')]
    [switch]$AttachOnly,

    [Parameter(ParameterSetName = 'Launch')]
    [Parameter(Mandatory, ParameterSetName = 'Attach')]
    [ValidateNotNullOrEmpty()]
    [string]$StateDir,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateNotNullOrEmpty()]
    [string]$ReviewerConfigFile,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateNotNullOrEmpty()]
    [string]$ReviewHandlerConfigFile,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateRange(0, 2147483647)]
    [int]$ReviewerPullRequestId = 0,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateRange(0, 2147483647)]
    [int]$ReviewHandlerPullRequestId = 0,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$Continuous,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$Operational,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$EnableReviewerTeamsNotifications,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$EnableReviewHandlerTeamsNotifications,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$EnableReviewHandlerCodeUpdates,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateRange(30, 86400)]
    [int]$IntervalSeconds = 900,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$OperatorAlias,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$ReviewerAgentName,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$ReviewHandlerAgentName,

    [Parameter(ParameterSetName = 'Launch')]
    [string]$ReviewerModel,

    [Parameter(ParameterSetName = 'Launch')]
    [string]$ReviewHandlerModel,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$IncludeOwnPullRequests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$toolkitRoot = Split-Path $PSScriptRoot -Parent
$dashboardLauncher = Join-Path $PSScriptRoot 'Start-DevPilotDashboard.ps1'
$reviewerScript = Join-Path $toolkitRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
$reviewHandlerScript = Join-Path $toolkitRoot 'src\Agents\review-handler\Start-ReviewHandlerAgent.ps1'
$reviewerOperationalCapabilities = @(
    'EnableFindingComments',
    'EnableThreadReplies',
    'EnableSummaryComment'
)
$reviewHandlerOperationalCapabilities = @(
    'EnableThreadReplies',
    'EnableBuddyRequeue'
)
$reviewHandlerCodeUpdateCapabilities = @(
    'EnableCodeChanges',
    'EnablePush',
    'LocalValidation',
    'ResumeCodingSession'
)

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Close-OwnedAgentProcess {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$Role
    )
    $Process.Refresh()
    if ($Process.HasExited) { return }
    Write-Host "Stopping $Role PID $($Process.Id)." -ForegroundColor Yellow
    try {
        $Process.Kill($true)
    }
    catch [System.InvalidOperationException] {
        $Process.Refresh()
        if (-not $Process.HasExited) { throw }
    }
    if (-not $Process.WaitForExit(5000)) {
        throw "$Role PID $($Process.Id) could not be stopped."
    }
}

if (-not $StateDir) {
    $watchId = '{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    $StateDir = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'devpilot-agent-watch') $watchId
}
$StateDir = [IO.Path]::GetFullPath($StateDir)
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

$global:LASTEXITCODE = 0
& $dashboardLauncher -StateDir $StateDir -ValidateOnly
if ($LASTEXITCODE -ne 0) {
    throw "Dashboard preflight failed with code $LASTEXITCODE; no agent was started."
}

if ($AttachOnly) {
    $global:LASTEXITCODE = 0
    & $dashboardLauncher -StateDir $StateDir
    if ($LASTEXITCODE -ne 0) { throw "Dashboard exited with code $LASTEXITCODE." }
    return
}

if ($Continuous -and ($ReviewerPullRequestId -gt 0 -or $ReviewHandlerPullRequestId -gt 0)) {
    throw 'A pull request ID cannot be combined with -Continuous because that would repeatedly process one pull request.'
}
if (-not $Operational -and (
        $EnableReviewerTeamsNotifications -or
        $EnableReviewHandlerTeamsNotifications -or
        $EnableReviewHandlerCodeUpdates
    )) {
    throw 'Notifications and review-handler code updates require -Operational. Preview runs never enable side effects.'
}

$launchReviewer = $Agent -in @('Reviewer', 'Both')
$launchReviewHandler = $Agent -in @('ReviewHandler', 'Both')
if ($EnableReviewerTeamsNotifications -and -not $launchReviewer) {
    throw '-EnableReviewerTeamsNotifications requires -Agent Reviewer or -Agent Both.'
}
if ($EnableReviewHandlerTeamsNotifications -and -not $launchReviewHandler) {
    throw '-EnableReviewHandlerTeamsNotifications requires -Agent ReviewHandler or -Agent Both.'
}
if ($EnableReviewHandlerCodeUpdates -and -not $launchReviewHandler) {
    throw '-EnableReviewHandlerCodeUpdates requires -Agent ReviewHandler or -Agent Both.'
}
$defaultConfigRoot = Join-Path (Get-Location) '.github\copilot\agents'
if ($launchReviewer) {
    $ReviewerConfigFile = [IO.Path]::GetFullPath($(if ($ReviewerConfigFile) {
        $ReviewerConfigFile
    } else {
        Join-Path $defaultConfigRoot 'reviewer.config.json'
    }))
    if (-not (Test-Path -LiteralPath $ReviewerConfigFile -PathType Leaf)) {
        throw "Reviewer config was not found: $ReviewerConfigFile"
    }
    if (-not (Test-Path -LiteralPath $reviewerScript -PathType Leaf)) {
        throw "Reviewer script was not found: $reviewerScript"
    }
}
if ($launchReviewHandler) {
    $ReviewHandlerConfigFile = [IO.Path]::GetFullPath($(if ($ReviewHandlerConfigFile) {
        $ReviewHandlerConfigFile
    } else {
        Join-Path $defaultConfigRoot 'review-handler.config.json'
    }))
    if (-not (Test-Path -LiteralPath $ReviewHandlerConfigFile -PathType Leaf)) {
        throw "Review-handler config was not found: $ReviewHandlerConfigFile"
    }
    if (-not (Test-Path -LiteralPath $reviewHandlerScript -PathType Leaf)) {
        throw "Review-handler script was not found: $reviewHandlerScript"
    }
}

if (-not $OperatorAlias) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    $configForRepository = if ($launchReviewer) { $ReviewerConfigFile } else { $ReviewHandlerConfigFile }
    $repositoryRoot = if ($git) {
        & $git.Source -C (Split-Path $configForRepository -Parent) rev-parse --show-toplevel 2>$null
    }
    $email = if ($git -and $LASTEXITCODE -eq 0 -and $repositoryRoot) {
        & $git.Source -C ([string]$repositoryRoot).Trim() config user.email 2>$null
    }
    $candidate = if ($email) { ([string]$email).Trim().Split('@')[0] } else { ([string]$env:USERNAME).Trim() }
    if ($candidate -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'Could not detect a safe operator alias. Configure git user.email or pass -OperatorAlias.'
    }
    $OperatorAlias = $candidate
}

$sessionSuffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
if (-not $ReviewerAgentName) { $ReviewerAgentName = "reviewer-watch-$sessionSuffix" }
if (-not $ReviewHandlerAgentName) { $ReviewHandlerAgentName = "review-handler-watch-$sessionSuffix" }

$specs = New-Object System.Collections.Generic.List[object]
if ($launchReviewer) {
    [void]$specs.Add([pscustomobject]@{
        Role = 'reviewer'
        Script = $reviewerScript
        ConfigFile = $ReviewerConfigFile
        StateDir = (Join-Path $StateDir 'reviewer')
        AgentName = $ReviewerAgentName
        PullRequestId = $ReviewerPullRequestId
        Model = $ReviewerModel
        IncludeOwn = [bool]$IncludeOwnPullRequests
    })
}
if ($launchReviewHandler) {
    [void]$specs.Add([pscustomobject]@{
        Role = 'review-handler'
        Script = $reviewHandlerScript
        ConfigFile = $ReviewHandlerConfigFile
        StateDir = (Join-Path $StateDir 'review-handler')
        AgentName = $ReviewHandlerAgentName
        PullRequestId = $ReviewHandlerPullRequestId
        Model = $ReviewHandlerModel
        IncludeOwn = $false
    })
}

$pwsh = Get-Command pwsh -ErrorAction Stop
$children = New-Object System.Collections.Generic.List[object]
try {
    foreach ($spec in $specs) {
        New-Item -ItemType Directory -Force -Path $spec.StateDir | Out-Null
        $parameterLines = New-Object System.Collections.Generic.List[string]
        [void]$parameterLines.Add("ConfigFile = $(ConvertTo-PowerShellLiteral $spec.ConfigFile)")
        [void]$parameterLines.Add("StateDir = $(ConvertTo-PowerShellLiteral $spec.StateDir)")
        [void]$parameterLines.Add("AgentName = $(ConvertTo-PowerShellLiteral $spec.AgentName)")
        [void]$parameterLines.Add("OperatorAlias = $(ConvertTo-PowerShellLiteral $OperatorAlias)")
        [void]$parameterLines.Add("OutputMode = 'Json'")
        if ($Continuous) {
            [void]$parameterLines.Add("IntervalSeconds = $IntervalSeconds")
        }
        else {
            [void]$parameterLines.Add('Once = $true')
        }
        if ($spec.PullRequestId -gt 0) { [void]$parameterLines.Add("PullRequestId = $($spec.PullRequestId)") }
        if ($spec.Model) { [void]$parameterLines.Add("Model = $(ConvertTo-PowerShellLiteral $spec.Model)") }
        if ($spec.IncludeOwn) { [void]$parameterLines.Add('IncludeOwnPullRequests = $true') }
        if ($Operational) {
            if ($spec.Role -eq 'reviewer') {
                foreach ($capability in $reviewerOperationalCapabilities) {
                    [void]$parameterLines.Add("$capability = `$true")
                }
                if ($EnableReviewerTeamsNotifications) {
                    [void]$parameterLines.Add('EnableTeamsNotifications = $true')
                }
            }
            else {
                foreach ($capability in $reviewHandlerOperationalCapabilities) {
                    [void]$parameterLines.Add("$capability = `$true")
                }
                if ($EnableReviewHandlerCodeUpdates) {
                    foreach ($capability in $reviewHandlerCodeUpdateCapabilities) {
                        [void]$parameterLines.Add("$capability = `$true")
                    }
                }
                if ($EnableReviewHandlerTeamsNotifications) {
                    [void]$parameterLines.Add('EnableTeamsNotifications = $true')
                }
            }
        }

        $childCommand = @"
`$ErrorActionPreference = 'Stop'
`$parameters = @{
    $($parameterLines -join "`n    ")
}
& $(ConvertTo-PowerShellLiteral $spec.Script) @parameters
exit `$LASTEXITCODE
"@
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
        $stdoutPath = Join-Path $StateDir "$($spec.Role).stdout.jsonl"
        $stderrPath = Join-Path $StateDir "$($spec.Role).stderr.log"
        $process = Start-Process -FilePath $pwsh.Source -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCommand
        ) -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
        [void]$children.Add([pscustomobject]@{
            Role = $spec.Role
            Process = $process
            StdErrPath = $stderrPath
        })
        Write-Host "Watching $($spec.Role) PID $($process.Id)." -ForegroundColor Cyan
    }
}
catch {
    foreach ($child in $children) {
        Close-OwnedAgentProcess -Process $child.Process -Role $child.Role
    }
    throw
}

Write-Host "Shared state root: $StateDir" -ForegroundColor Cyan
if ($Operational) {
    Write-Information 'OPERATIONAL: reviewer comments, replies, and summaries plus review-handler replies and requeues are enabled. Reviewer votes and review-handler auto-complete remain disabled.' -InformationAction Continue
    Write-Information "Review-handler code updates: $([bool]$EnableReviewHandlerCodeUpdates) (code changes, local validation, session resume, and push)." -InformationAction Continue
    Write-Information "Teams notifications: reviewer=$([bool]$EnableReviewerTeamsNotifications) review-handler=$([bool]$EnableReviewHandlerTeamsNotifications)." -InformationAction Continue
    Write-Warning 'Closing the dashboard immediately stops owned agent process trees. Quit while agents are waiting when possible to avoid interrupting an in-flight operation.'
}
else {
    Write-Information 'PREVIEW ONLY: no code changes, pushes, replies, comments, summaries, votes, requeues, auto-complete, or notifications are enabled.' -InformationAction Continue
}
if ($Continuous) {
    Write-Host "Agents will scan every $IntervalSeconds second(s) until the dashboard exits." -ForegroundColor Green
}

$startupFailure = $null
foreach ($child in $children) {
    $null = $child.Process.WaitForExit(3000)
    $child.Process.Refresh()
    if ($child.Process.HasExited -and $child.Process.ExitCode -ne 0) {
        $startupFailure = $child
        break
    }
}
if ($startupFailure) {
    foreach ($child in $children) {
        Close-OwnedAgentProcess -Process $child.Process -Role $child.Role
    }
    Write-Error "$($startupFailure.Role) exited during startup with code $($startupFailure.Process.ExitCode). Diagnostics: $($startupFailure.StdErrPath)"
    exit $startupFailure.Process.ExitCode
}

$dashboardCompletedNormally = $false
$agentsStoppedByDashboard = $false
try {
    $global:LASTEXITCODE = 0
    & $dashboardLauncher -StateDir $StateDir
    if ($LASTEXITCODE -ne 0) { throw "Dashboard exited with code $LASTEXITCODE." }
    $dashboardCompletedNormally = $true
}
finally {
    if (-not $dashboardCompletedNormally -or $Continuous -or $Operational) {
        foreach ($child in $children) {
            Close-OwnedAgentProcess -Process $child.Process -Role $child.Role
        }
        $agentsStoppedByDashboard = $true
    }
    else {
        $running = @($children | Where-Object {
            $_.Process.Refresh()
            -not $_.Process.HasExited
        })
        if ($running.Count -gt 0) {
            Write-Host "$($running.Count) preview agent(s) are still running." -ForegroundColor Yellow
            Write-Host "Reattach with: .\tools\Watch-DevPilotAgents.ps1 -AttachOnly -StateDir '$StateDir'" -ForegroundColor Yellow
        }
    }
}

if ($agentsStoppedByDashboard -and $dashboardCompletedNormally) { exit 0 }
$failedChild = @($children | Where-Object {
    $_.Process.Refresh()
    $_.Process.HasExited -and $_.Process.ExitCode -ne 0
} | Select-Object -First 1)
if ($failedChild.Count -gt 0) { exit $failedChild[0].Process.ExitCode }
