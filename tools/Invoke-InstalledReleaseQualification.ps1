#!/usr/bin/env pwsh
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolkitRoot,
    [Parameter(Mandatory)]
    [ValidatePattern('^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')]
    [string]$ExpectedVersion,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = [IO.Path]::TrimEndingDirectorySeparator(
    [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ToolkitRoot).Path))
$git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$commit = (& $git --no-pager --no-replace-objects -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -cne $ExpectedCommit) {
    throw "Installed candidate commit '$commit' does not match '$ExpectedCommit'."
}
if (& $git --no-pager --no-replace-objects -C $root status --porcelain=v1 --untracked-files=no) {
    throw 'Installed candidate has tracked source or index changes.'
}

$version = & (Join-Path $root 'tools\Test-DevPilotVersion.ps1') -ExpectedVersion $ExpectedVersion `
    -ExpectedTag "v$ExpectedVersion"
if ($version.Version -cne $ExpectedVersion) {
    throw "Installed candidate version '$($version.Version)' does not match '$ExpectedVersion'."
}

$manifest = Join-Path $root 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'
[void](Test-ModuleManifest -Path $manifest)
Import-Module $manifest -Force
[void](Get-DevPilotAgentPath)

& (Join-Path $root 'src\Agents\review-handler\Start-ReviewHandlerAgent.ps1') -DryRun `
    -ConfigFile (Join-Path $root 'samples\handler-ado.config.json')
& (Join-Path $root 'src\Agents\reviewer\Start-ReviewerAgent.ps1') -DryRun `
    -ConfigFile (Join-Path $root 'samples\reviewer-ado.config.json')
& (Join-Path $root 'tools\Test-Provider.ps1')

$pester = Invoke-Pester -Path @(
    (Join-Path $root 'tests\StartupMcpRecovery.Tests.ps1'),
    (Join-Path $root 'tests\AutomationPolling.Tests.ps1'),
    (Join-Path $root 'tests\DispatchStartup.Tests.ps1'),
    (Join-Path $root 'tests\GoldenPath.Tests.ps1')
) -Output Detailed -PassThru
if ($pester.FailedCount -gt 0 -or $pester.SkippedCount -gt 0) {
    throw "Installed Golden qualification failures/skips: $($pester.FailedCount)/$($pester.SkippedCount)."
}

$dashboard = Join-Path $root 'src\DevPilot.Dashboard'
$logicTests = @(Get-ChildItem -LiteralPath (Join-Path $dashboard 'dist\test') -Filter '*.test.js' -File |
    Where-Object Name -ne 'app.test.js' | ForEach-Object FullName)
if ($logicTests.Count -eq 0) { throw 'Installed dashboard logic artifacts are missing.' }
& node --test @logicTests
if ($LASTEXITCODE -ne 0) { throw 'Installed dashboard logic tests failed.' }

$bun = if ($IsWindows) {
    Join-Path $dashboard 'node_modules\bun\bin\bun.exe'
}
else {
    Join-Path $dashboard 'node_modules\bun\bin\bun'
}
& $bun --conditions=browser test (Join-Path $dashboard 'dist\test\app.test.js')
if ($LASTEXITCODE -ne 0) { throw 'Installed dashboard renderer test failed.' }
if ($IsWindows) {
    & node --test (Join-Path $dashboard 'dist\test\pty.integration.js')
    if ($LASTEXITCODE -ne 0) { throw 'Installed dashboard ConPTY test failed.' }
}
