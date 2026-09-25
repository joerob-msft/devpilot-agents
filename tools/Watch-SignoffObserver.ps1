#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ObserverConfigFile,
    [string]$ObserverPythonPath = 'python',
    [string]$StateDir,
    [switch]$Continuous,
    [switch]$Once,
    [switch]$PreviewOnly,
    [switch]$ObserverEnableModel
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$toolkit = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $toolkit 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
$worker = Join-Path $toolkit 'src\Agents\signoff-observer\Start-SignoffObserver.ps1'
$parameters = @{ ConfigFile = $ObserverConfigFile; PythonPath = $ObserverPythonPath; PreviewOnly = $PreviewOnly
    EnableModel = $ObserverEnableModel }
if ($StateDir) { $parameters.StateDir = $StateDir }
& $worker @parameters -ValidateOnly
if ($LASTEXITCODE -ne 0) { throw 'Observer validation failed; no worker was started.' }
if (-not $StateDir) { $StateDir = (Get-Content -LiteralPath $ObserverConfigFile -Raw | ConvertFrom-Json).stateRoot }
$dashboard = Join-Path $PSScriptRoot 'Start-DevPilotDashboard.ps1'
& $dashboard -StateDir $StateDir -LaunchMode observe -ValidateOnly
if ($LASTEXITCODE -ne 0) { throw 'Dashboard preflight failed; no observer was started.' }
if (-not $PSCmdlet.ShouldProcess($StateDir, 'Start read-only sign-off observer and observe-only dashboard')) { return }
$arguments = @('-NoProfile', '-NonInteractive', '-File', $worker, '-ConfigFile', $ObserverConfigFile,
    '-PythonPath', $ObserverPythonPath, '-StateDir', $StateDir)
if (-not $Continuous -or $Once) { $arguments += '-Once' }
if ($PreviewOnly) { $arguments += '-PreviewOnly' }
if ($ObserverEnableModel) { $arguments += '-EnableModel' }
$owned = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList $arguments `
    -StandardOutputPath (Join-Path $StateDir 'signoff-observer.stdout.log') `
    -StandardErrorPath (Join-Path $StateDir 'signoff-observer.stderr.log') -WorkingDirectory $toolkit
$containment = New-AgentProcessContainment -Process $owned.Process
try {
    if ($owned.Process.WaitForExit(2000) -and $owned.Process.ExitCode -ne 0) {
        throw "Observer startup failed; inspect signoff-observer.stderr.log (exit $($owned.Process.ExitCode))."
    }
    & $dashboard -StateDir $StateDir -LaunchMode observe
}
finally {
    if (-not (Test-AgentProcessContainmentExited -Containment $containment -Process $owned.Process)) {
        if (-not (Stop-AgentProcessContainment -Containment $containment -Process $owned.Process)) {
            throw 'Observer owned process tree could not be stopped.'
        }
    }
    [void](Complete-AgentRedirectedProcess $owned)
    Close-AgentProcessContainment $containment
}
