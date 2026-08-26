#requires -Version 7.0

<#
.SYNOPSIS
    Launches a preview-only reviewer and opens the dashboard on that run.

.DESCRIPTION
    Creates an isolated state directory, starts a reviewer without any write
    capabilities, and opens the read-only operations dashboard in the current
    terminal. By default the reviewer runs one cycle. Continuous keeps cycling
    until the dashboard exits, at which point the watcher stops the reviewer
    process tree. AttachOnly observes an existing state directory without
    launching a reviewer.

.EXAMPLE
    .\tools\Watch-DevPilotReviewer.ps1 `
        -ConfigFile C:\repo\.github\copilot\agents\reviewer.config.json `
        -PullRequestId 12345

.EXAMPLE
    .\tools\Watch-DevPilotReviewer.ps1 -AttachOnly -StateDir C:\DevPilot\state

.EXAMPLE
    .\tools\Watch-DevPilotReviewer.ps1 -Continuous -IntervalSeconds 900
#>
[CmdletBinding(DefaultParameterSetName = 'Launch')]
param(
    [Parameter(ParameterSetName = 'Launch')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigFile,

    [Parameter(Mandatory, ParameterSetName = 'Attach')]
    [switch]$AttachOnly,

    [Parameter(ParameterSetName = 'Launch')]
    [Parameter(Mandatory, ParameterSetName = 'Attach')]
    [ValidateNotNullOrEmpty()]
    [string]$StateDir,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateRange(0, 2147483647)]
    [int]$PullRequestId = 0,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$Continuous,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateRange(30, 86400)]
    [int]$IntervalSeconds = 900,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$OperatorAlias,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$AgentName,

    [Parameter(ParameterSetName = 'Launch')]
    [string]$Model,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$IncludeOwnPullRequests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$toolkitRoot = Split-Path $PSScriptRoot -Parent
$dashboardLauncher = Join-Path $PSScriptRoot 'Start-DevPilotDashboard.ps1'
$reviewerScript = Join-Path $toolkitRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'

if (-not $StateDir) {
    $watchId = '{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    $StateDir = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'devpilot-reviewer-watch') $watchId
}
$StateDir = [IO.Path]::GetFullPath($StateDir)
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

# Complete dashboard preflight before a reviewer process can be started.
$global:LASTEXITCODE = 0
& $dashboardLauncher -StateDir $StateDir -ValidateOnly
if ($LASTEXITCODE -ne 0) {
    throw "Dashboard preflight failed with code $LASTEXITCODE; no reviewer was started."
}

if ($AttachOnly) {
    $global:LASTEXITCODE = 0
    & $dashboardLauncher -StateDir $StateDir
    if ($LASTEXITCODE -ne 0) { throw "Dashboard exited with code $LASTEXITCODE." }
    return
}

if ($Continuous -and $PullRequestId -gt 0) {
    throw '-PullRequestId cannot be combined with -Continuous because that would repeatedly review one pull request.'
}

$ConfigFile = if ($ConfigFile) {
    $ConfigFile
}
else {
    Join-Path (Get-Location) '.github\copilot\agents\reviewer.config.json'
}
$ConfigFile = [IO.Path]::GetFullPath($ConfigFile)
if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    throw "Reviewer config was not found: $ConfigFile"
}
if (-not (Test-Path -LiteralPath $reviewerScript -PathType Leaf)) {
    throw "Reviewer script was not found: $reviewerScript"
}

if (-not $OperatorAlias) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    $repositoryRoot = if ($git) {
        & $git.Source -C (Split-Path $ConfigFile -Parent) rev-parse --show-toplevel 2>$null
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
if (-not $AgentName) {
    $AgentName = "reviewer-watch-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
}

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

$parameterLines = New-Object System.Collections.Generic.List[string]
[void]$parameterLines.Add("ConfigFile = $(ConvertTo-PowerShellLiteral $ConfigFile)")
[void]$parameterLines.Add("StateDir = $(ConvertTo-PowerShellLiteral $StateDir)")
[void]$parameterLines.Add("AgentName = $(ConvertTo-PowerShellLiteral $AgentName)")
[void]$parameterLines.Add("OperatorAlias = $(ConvertTo-PowerShellLiteral $OperatorAlias)")
[void]$parameterLines.Add("OutputMode = 'Json'")
if ($Continuous) {
    [void]$parameterLines.Add("IntervalSeconds = $IntervalSeconds")
}
else {
    [void]$parameterLines.Add('Once = $true')
}
if ($PullRequestId -gt 0) { [void]$parameterLines.Add("PullRequestId = $PullRequestId") }
if ($Model) { [void]$parameterLines.Add("Model = $(ConvertTo-PowerShellLiteral $Model)") }
if ($IncludeOwnPullRequests) { [void]$parameterLines.Add('IncludeOwnPullRequests = $true') }

$childCommand = @"
`$ErrorActionPreference = 'Stop'
`$parameters = @{
    $($parameterLines -join "`n    ")
}
& $(ConvertTo-PowerShellLiteral $reviewerScript) @parameters
exit `$LASTEXITCODE
"@
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
$pwsh = Get-Command pwsh -ErrorAction Stop
$stdoutPath = Join-Path $StateDir 'reviewer.stdout.jsonl'
$stderrPath = Join-Path $StateDir 'reviewer.stderr.log'

$reviewerProcess = Start-Process -FilePath $pwsh.Source -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCommand
) -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru

Write-Host "Watching reviewer PID $($reviewerProcess.Id) in $StateDir" -ForegroundColor Cyan
Write-Host 'This run is preview-only: no comments, replies, summary, vote, or notifications are enabled.' -ForegroundColor Green
if ($Continuous) {
    Write-Host "The reviewer will scan every $IntervalSeconds second(s) until the dashboard exits." -ForegroundColor Green
}

$null = $reviewerProcess.WaitForExit(3000)
$reviewerProcess.Refresh()
if ($reviewerProcess.HasExited -and $reviewerProcess.ExitCode -ne 0) {
    Write-Error "Reviewer exited during startup with code $($reviewerProcess.ExitCode). Diagnostics: $stderrPath"
    exit $reviewerProcess.ExitCode
}

$dashboardCompletedNormally = $false
$reviewerStoppedByDashboard = $false
try {
    $global:LASTEXITCODE = 0
    & $dashboardLauncher -StateDir $StateDir
    if ($LASTEXITCODE -ne 0) { throw "Dashboard exited with code $LASTEXITCODE." }
    $dashboardCompletedNormally = $true
}
finally {
    $reviewerProcess.Refresh()
    $stopReviewer = (-not $dashboardCompletedNormally -or $Continuous) -and -not $reviewerProcess.HasExited
    if ($stopReviewer) {
        if ($dashboardCompletedNormally) {
            Write-Host "Dashboard closed; stopping continuous reviewer PID $($reviewerProcess.Id)." -ForegroundColor Yellow
        }
        else {
            Write-Warning "Dashboard failed; stopping preview reviewer PID $($reviewerProcess.Id)."
        }
        $reviewerProcess.Kill($true)
        if (-not $reviewerProcess.WaitForExit(5000)) {
            throw "Dashboard failed and preview reviewer PID $($reviewerProcess.Id) could not be stopped."
        }
        $reviewerStoppedByDashboard = $true
    }
    elseif (-not $reviewerProcess.HasExited) {
        Write-Host "Reviewer PID $($reviewerProcess.Id) is still running." -ForegroundColor Yellow
        Write-Host "Reattach with: .\tools\Watch-DevPilotReviewer.ps1 -AttachOnly -StateDir '$StateDir'" -ForegroundColor Yellow
    }
}

if ($reviewerStoppedByDashboard -and $dashboardCompletedNormally) { exit 0 }
$reviewerProcess.Refresh()
if ($reviewerProcess.HasExited) { exit $reviewerProcess.ExitCode }
