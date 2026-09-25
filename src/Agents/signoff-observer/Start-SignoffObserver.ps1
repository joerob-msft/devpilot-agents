#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [string]$PythonPath = 'python',
    [string]$StateDir,
    [string]$CancelFile,
    [string]$AdjudicationFile,
    [switch]$Once,
    [switch]$PreviewOnly,
    [switch]$EnableModel,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$toolkit = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
Import-Module (Join-Path $toolkit 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
$configPath = (Resolve-Path -LiteralPath $ConfigFile).Path
# Configuration is operator-selected; never execute a command extracted from PR/model content.
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
foreach ($path in @($configPath, $config.collector.scriptPath, $config.collector.configPath)) {
    [void](Assert-AgentTrustedFile -Path $path -AllowedRoot (Split-Path $path -Parent))
}
$stateRoot = Resolve-AgentTrustedRoot -Path $config.stateRoot -Kind durable-state -RepositoryRoot $toolkit -Create
if (-not $StateDir) { $StateDir = $stateRoot }
$StateDir = Resolve-AgentTrustedRoot -Path $StateDir -Kind watch-state -RepositoryRoot $toolkit -Create
if (-not $IsWindows -and -not $ValidateOnly) {
    throw 'Observer requires Windows process-tree containment; no uncontained collector or SDK fallback.'
}
$python = (Get-Command $PythonPath -CommandType Application -ErrorAction Stop).Source
$arguments = @('-B', (Join-Path $toolkit 'src\DevPilot.SignoffConfidence\observer.py'),
    '--config', $configPath, '--state-dir', $StateDir, '--pwsh', (Resolve-AgentPwshPath))
if ($Once) { $arguments += '--once' }
if ($ValidateOnly) { $arguments += '--validate-only' }
if ($EnableModel) { $arguments += '--enable-model' }
if ($CancelFile) { $arguments += @('--cancel-file', [IO.Path]::GetFullPath($CancelFile)) }
if ($AdjudicationFile) {
    if ($ValidateOnly) { throw 'Adjudication import and ValidateOnly cannot be combined.' }
    [void](Assert-AgentTrustedFile -Path ([IO.Path]::GetFullPath($AdjudicationFile)) -Private)
    $arguments += @('--adjudication', [IO.Path]::GetFullPath($AdjudicationFile))
}
$result = Invoke-TimedProcess -FilePath $python -ArgumentList $arguments `
    -WorkingDirectory ([IO.Path]::GetTempPath()) -CaptureStdOut -CaptureStdErr `
    -EnvironmentVariablesToRemove @('PYTHONPATH', 'PYTHONSTARTUP', 'COPILOT_CLI_URL') `
    -ContainDescendants -TimeoutSeconds $(if ($ValidateOnly) { 60 } else { 604920 })
if ($result.StdOut) { [Console]::Out.Write($result.StdOut) }
if ($result.StdErr) { [Console]::Error.Write($result.StdErr) }
if ($result.TimedOut) { [Console]::Error.WriteLine('OBSERVER_CONTAINMENT_DEADLINE'); exit 124 }
exit $result.ExitCode
