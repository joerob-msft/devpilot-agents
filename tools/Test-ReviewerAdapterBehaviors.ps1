#!/usr/bin/env pwsh
[CmdletBinding()]
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $RepoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force

$adapter = Join-Path $RepoRoot 'src\Agents\reviewer\offline\Invoke-ReviewerModelAdapter.ps1'
$manifestA = Join-Path $RepoRoot 'tools\testdata\reviewer-adapter-behaviors-a.json'
$manifestB = Join-Path $RepoRoot 'tools\testdata\reviewer-adapter-behaviors-b.json'
$pwsh = (Get-Command pwsh).Source
$binding = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes('{"nonce":"bound-nonce"}'))
$schema = @{
    Keys = @('schemaVersion', 'nonce', 'decision')
    Fields = @{
        schemaVersion = @{ Type = 'int'; Min = 1; Max = 1 }
        nonce = @{ Type = 'exact'; Expected = 'bound-nonce' }
        decision = @{ Type = 'enum'; Values = @('accept') }
    }
}

function Invoke-Case {
    param([string]$Manifest, [string]$Role, [string]$Model, [int]$Timeout = 5)
    Invoke-TimedProcess -FilePath $pwsh -ArgumentList @(
        '-NoProfile', '-File', $adapter, '-ManifestPath', $Manifest, '-Role', $Role,
        '-Model', $Model, '-ExpectedBaseCommit', ('a' * 40), '-BindingBase64', $binding
    ) -StandardInputContent 'synthetic input' -CaptureStdOut -CaptureStdErr `
        -WorkingDirectory $RepoRoot -TimeoutSeconds $Timeout
}

$cases = @(
    @{ Name='success'; Manifest=$manifestA; Role='blind-gpt'; Model='gpt-5.6-sol'; Exit=0; Marker='success' },
    @{ Name='missing'; Manifest=$manifestA; Role='blind-opus'; Model='claude-opus-5'; Exit=0; Marker='missingMarker' },
    @{ Name='truncated'; Manifest=$manifestA; Role='specialist'; Model='claude-sonnet-5'; Exit=0; Marker='truncated' },
    @{ Name='multiple-identical'; Manifest=$manifestA; Role='reciprocal-gpt-verifier'; Model='gpt-5.6-sol'; Exit=0; Marker='success' },
    @{ Name='wrong-binding'; Manifest=$manifestA; Role='reciprocal-opus-verifier'; Model='claude-opus-5'; Exit=0; Marker='wrongBinding' },
    @{ Name='timeout'; Manifest=$manifestA; Role='compatibility-generalist'; Model='gpt-5.6-sol'; Timeout=1; TimedOut=$true },
    @{ Name='crash'; Manifest=$manifestA; Role='compatibility-verifier'; Model='gpt-5.6-sol'; Exit=23 },
    @{ Name='stdout-saturation'; Manifest=$manifestB; Role='blind-gpt'; Model='gpt-5.6-sol'; Exit=0; StdOutMin=1048576 },
    @{ Name='stderr-saturation'; Manifest=$manifestB; Role='blind-opus'; Model='claude-opus-5'; Exit=0; StdErrMin=1048576 }
)

$passed = 0
foreach ($case in $cases) {
    $timeout = if ($case.ContainsKey('Timeout')) { [int]$case.Timeout } else { 5 }
    $result = Invoke-Case $case.Manifest $case.Role $case.Model $timeout
    if ($case.ContainsKey('TimedOut') -and $case.TimedOut) {
        if (-not $result.TimedOut) { throw "$($case.Name): expected timeout." }
        if ($result.ProcessId -and (Get-Process -Id $result.ProcessId -ErrorAction SilentlyContinue)) {
            throw "$($case.Name): timed-out child process $($result.ProcessId) was not terminated."
        }
    } else {
        if ($result.TimedOut -or $result.ExitCode -ne [int]$case.Exit) {
            throw "$($case.Name): exit=$($result.ExitCode), timedOut=$($result.TimedOut), stderr=$($result.StdErr)"
        }
    }
    if ($case.ContainsKey('Marker')) {
        $cliOutcome = Get-AgentCliJsonOutcome -StdOutText $result.StdOut
        $markerSource = if ($cliOutcome -and $cliOutcome.Answer) { [string]$cliOutcome.Answer } else { [string]$result.StdOut }
        $outcome = ConvertFrom-AgentResultMarkerOutcome -StdOutText $markerSource `
            -MarkerPrefix 'TEST_RESULT_V1:' -Schema $schema
        if ($outcome.Status -cne [string]$case.Marker) {
            throw "$($case.Name): marker status '$($outcome.Status)', expected '$($case.Marker)'."
        }
    }
    if ($case.ContainsKey('StdOutMin') -and $result.StdOut.Length -lt [int]$case.StdOutMin) { throw "$($case.Name): stdout was not fully drained." }
    if ($case.ContainsKey('StdErrMin') -and $result.StdErr.Length -lt [int]$case.StdErrMin) { throw "$($case.Name): stderr was not fully drained." }
    $passed++
}
Write-Host "PASS: $passed deterministic adapter/process/parser behaviors; no model, network, or external write."
