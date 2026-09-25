#requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('ValidateBundle', 'Run')][string]$Action = 'Run',
    [Parameter(Mandatory)][string]$InputPath,
    [ValidateSet('Offline', 'Live')][string]$Mode,
    [string]$FixturePath,
    [string]$OutputRoot,
    [string]$Model,
    [string]$RuntimePath,
    [string]$PythonPath = 'python',
    [ValidateRange(1, 25)][int]$MaxCases = 25,
    [ValidateRange(1, 600)][int]$DeadlineSeconds = 60,
    [ValidateRange(1, 2)][int]$MaxAttempts = 1,
    [ValidateRange(30, 100)][double]$MaxAiCredits = 30,
    [string]$CancelFile,
    [switch]$Exploratory,
    [switch]$Resume
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
$python = (Get-Command $PythonPath -CommandType Application -ErrorAction Stop).Source
$entry = (Resolve-Path "$PSScriptRoot\..\src\DevPilot.SignoffConfidence\signoff_replay.py").Path
$arguments = @('-B', $entry)
if ($Action -eq 'ValidateBundle') {
    $arguments += @('validate-bundle', '--input', [IO.Path]::GetFullPath($InputPath), '--max-cases', "$MaxCases")
    $timeout = 60
}
else {
    if (-not $Mode -or -not $OutputRoot -or -not $Model) {
        throw 'Run requires explicit Mode, OutputRoot and Model.'
    }
    if ($Mode -eq 'Live' -and -not $IsWindows) {
        throw 'Live preview requires Windows Job Object descendant containment; use offline mode on this platform.'
    }
    $arguments += @('run', '--mode', $Mode.ToLowerInvariant(), '--input', [IO.Path]::GetFullPath($InputPath),
        '--output-root', [IO.Path]::GetFullPath($OutputRoot), '--model', $Model, '--max-cases', "$MaxCases",
        '--deadline-seconds', "$DeadlineSeconds", '--max-attempts', "$MaxAttempts",
        '--max-ai-credits', $MaxAiCredits.ToString([Globalization.CultureInfo]::InvariantCulture))
    if ($FixturePath) { $arguments += @('--fixtures', [IO.Path]::GetFullPath($FixturePath)) }
    if ($RuntimePath) { $arguments += @('--runtime-path', [IO.Path]::GetFullPath($RuntimePath)) }
    if ($CancelFile) { $arguments += @('--cancel-file', [IO.Path]::GetFullPath($CancelFile)) }
    if ($Exploratory) { $arguments += '--exploratory' }
    if ($Resume) { $arguments += '--resume' }
    $timeout = 60 + $MaxCases * 2 * $MaxAttempts * ($DeadlineSeconds + 15)
}

# The harness owns the process tree, not reviewer/handler role state.
$result = Invoke-TimedProcess -FilePath $python -ArgumentList $arguments `
    -WorkingDirectory ([IO.Path]::GetTempPath()) -CaptureStdOut -CaptureStdErr `
    -EnvironmentVariablesToRemove @('PYTHONPATH', 'PYTHONSTARTUP', 'COPILOT_CLI_URL') `
    -ContainDescendants -TimeoutSeconds $timeout
if ($result.StdOut) { [Console]::Out.Write($result.StdOut) }
if ($result.StdErr) { [Console]::Error.Write($result.StdErr) }
if ($result.TimedOut) { [Console]::Error.WriteLine('REPLAY_DEADLINE: child process tree terminated.'); exit 124 }
exit $result.ExitCode
