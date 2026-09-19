#!/usr/bin/env pwsh
#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('WindowsComplete', 'PlatformSafety')]
    [string]$Mode = 'WindowsComplete'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
$dashboard = Join-Path $root 'src\DevPilot.Dashboard'
$pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$pesterPath = $env:PATH
if ($IsWindows) {
    $primaryPwshDirectory = Split-Path $pwsh -Parent
    $pathSeparator = [IO.Path]::PathSeparator
    $pesterPath = (($env:PATH -split [regex]::Escape([string]$pathSeparator)) |
        Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $_ 'pwsh.exe')) -or
            [IO.Path]::GetFullPath($_) -eq [IO.Path]::GetFullPath($primaryPwshDirectory)
        }) -join $pathSeparator
}

function Invoke-DevPilotPesterIsolated {
    param([Parameter(Mandatory)][string[]]$Path)

    $env:DEVPILOT_CI_PESTER_PATHS = ConvertTo-Json -InputObject @($Path) -Compress
    $originalPath = $env:PATH
    try {
        $env:PATH = $pesterPath
        & $pwsh -NoLogo -NoProfile -NonInteractive -Command @'
$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion 5.7.1 -ErrorAction Stop
$paths = @(ConvertFrom-Json -InputObject $env:DEVPILOT_CI_PESTER_PATHS)
$result = Invoke-Pester -Path $paths -Output Detailed -PassThru
if ($result.FailedCount -gt 0) { exit 1 }
'@
        if ($LASTEXITCODE -ne 0) { throw 'Pester qualification failed.' }
    }
    finally {
        $env:PATH = $originalPath
        Remove-Item Env:DEVPILOT_CI_PESTER_PATHS -ErrorAction SilentlyContinue
    }
}

& (Join-Path $root 'tools\Test-DevPilotVersion.ps1') | Out-Null

if ($Mode -eq 'PlatformSafety') {
    Invoke-DevPilotPesterIsolated -Path @(
        (Join-Path $root 'tests\DispatchProtocol.Tests.ps1'),
        (Join-Path $root 'tests\DurableState.Tests.ps1'),
        (Join-Path $root 'tests\DurableStateMigration.Tests.ps1'),
        (Join-Path $root 'tests\Invoke-TimedProcess.Tests.ps1'),
        (Join-Path $root 'tests\ManualRedispatch.Tests.ps1'),
        (Join-Path $root 'tests\ReviewHandler.Resume.Tests.ps1'),
        (Join-Path $root 'tests\ReviewerOutput.Tests.ps1')
    )
    Push-Location $dashboard
    try {
        & npm ci
        if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
        & npm test
        if ($LASTEXITCODE -ne 0) { throw 'Dashboard logic tests failed.' }
        $bun = if ($IsWindows) {
            '.\node_modules\bun\bin\bun.exe'
        }
        else {
            './node_modules/bun/bin/bun.exe'
        }
        & $bun --conditions=browser test .\dist\test\dispatch.test.js
        if ($LASTEXITCODE -ne 0) { throw 'Dashboard dispatch test failed.' }
    }
    finally { Pop-Location }
    return
}

& (Join-Path $root 'tools\Test-NoEmployerSpecifics.ps1')
$analysis = Invoke-ScriptAnalyzer -Path (Join-Path $root 'src') -Recurse -Severity Error
if ($analysis) {
    $analysis | Format-Table -AutoSize
    throw "PSScriptAnalyzer reported $($analysis.Count) error-severity finding(s)."
}

$manifest = Join-Path $root 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'
$env:DEVPILOT_CI_MANIFEST = $manifest
try {
    & $pwsh -NoLogo -NoProfile -NonInteractive -Command @'
$ErrorActionPreference = 'Stop'
$manifest = $env:DEVPILOT_CI_MANIFEST
[void](Test-ModuleManifest -Path $manifest)
Import-Module $manifest -Force
[void](Get-DevPilotAgentPath)
'@
    if ($LASTEXITCODE -ne 0) { throw 'Harness manifest qualification failed.' }
}
finally { Remove-Item Env:DEVPILOT_CI_MANIFEST -ErrorAction SilentlyContinue }

Push-Location $dashboard
try {
    & npm ci
    if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
    & npm run build
    if ($LASTEXITCODE -ne 0) { throw 'Dashboard build failed.' }
}
finally { Pop-Location }

Invoke-DevPilotPesterIsolated -Path (Join-Path $root 'tests')

Push-Location $dashboard
try {
    & npm test
    if ($LASTEXITCODE -ne 0) { throw 'Dashboard logic tests failed.' }
    & npm run test:renderer
    if ($LASTEXITCODE -ne 0) { throw 'Dashboard renderer test failed.' }
    if ($IsWindows) {
        & npm run test:pty
        if ($LASTEXITCODE -ne 0) { throw 'Dashboard ConPTY test failed.' }
    }
}
finally { Pop-Location }

& (Join-Path $root 'src\Agents\review-handler\Start-ReviewHandlerAgent.ps1') -DryRun `
    -ConfigFile (Join-Path $root 'samples\handler-ado.config.json')
& (Join-Path $root 'src\Agents\reviewer\Start-ReviewerAgent.ps1') -DryRun `
    -ConfigFile (Join-Path $root 'samples\reviewer-ado.config.json')
& (Join-Path $root 'tools\Test-Provider.ps1')
