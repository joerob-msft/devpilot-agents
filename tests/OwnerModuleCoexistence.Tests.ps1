Describe 'Owner dependency module coexistence' {
    It 'preserves a global AgentHarness import through <Target> (caller Force=<Force>)' -ForEach @(
        @{ Target = 'DevPilot.OwnerOrchestrator'; Force = $false }
        @{ Target = 'DevPilot.OwnerOrchestrator'; Force = $true }
        @{ Target = 'DevPilot.OwnerParity'; Force = $false }
        @{ Target = 'DevPilot.OwnerParity'; Force = $true }
    ) {
        param($Target, $Force)

        $repoRoot = Split-Path $PSScriptRoot -Parent
        $targetManifest = switch ($Target) {
            'DevPilot.OwnerOrchestrator' {
                Join-Path $repoRoot 'src\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1'
            }
            'DevPilot.OwnerParity' {
                Join-Path $repoRoot 'src\DevPilot.OwnerParity\DevPilot.OwnerParity.psd1'
            }
        }
        if (-not (Test-Path -LiteralPath $targetManifest -PathType Leaf)) {
            Set-ItResult -Skipped -Because "$Target is introduced by an upper stack layer."
            return
        }

        $harnessManifest = Join-Path $repoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'
        $caseRoot = Join-Path $TestDrive (
            $Target.Replace('.', '-') + '-' + $Force.ToString().ToLowerInvariant())
        $probePath = Join-Path $caseRoot 'probe.ps1'
        [void](New-Item -ItemType Directory -Path $caseRoot -Force)
        Copy-Item -LiteralPath (
            Join-Path $repoRoot 'tests\fixtures\owner-orchestrator\generic-cohort.json'
        ) -Destination (Join-Path $caseRoot 'cohort.json')
        [IO.File]::WriteAllText($probePath, @'
param(
    [Parameter(Mandatory)][string]$HarnessManifest,
    [Parameter(Mandatory)][string]$TargetManifest,
    [Parameter(Mandatory)][string]$TargetName,
    [Parameter(Mandatory)][string]$UseForce,
    [Parameter(Mandatory)][string]$CaseRoot,
    [Parameter(Mandatory)][string]$RepositoryRoot
)
$ErrorActionPreference = 'Stop'
Import-Module $HarnessManifest -Global
$beforeModule = Get-Module DevPilot.AgentHarness
$beforeCommand = Get-Command Get-DevPilotAgentPath -ErrorAction Stop

if ($UseForce -ceq 'true') {
    Import-Module $TargetManifest -Force
}
else {
    Import-Module $TargetManifest
}

$afterModules = @(Get-Module DevPilot.AgentHarness)
$afterCommand = Get-Command Get-DevPilotAgentPath -ErrorAction SilentlyContinue
$targetModule = Get-Module $TargetName
$commandWorked = switch ($TargetName) {
    'DevPilot.OwnerOrchestrator' {
        $stateRoot = Join-Path $CaseRoot 'state'
        $manifestPath = Join-Path $CaseRoot 'cohort.json'
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath)
        (Get-OwnerV2PreviewStatus -StateRoot $stateRoot -ManifestPath $manifestPath).kind -ceq `
            'owner-v2-preview-status'
    }
    'DevPilot.OwnerParity' {
        $v1Root = Join-Path $CaseRoot 'v1'
        $v2Root = Join-Path $CaseRoot 'v2'
        [void](New-Item -ItemType Directory -Path $v1Root -Force)
        (Test-OwnerParityPathIsolation `
                -V1StateRoot $v1Root `
                -V2StateRoot $v2Root `
                -RepositoryRoot $RepositoryRoot).isolated
    }
}

[pscustomobject]@{
    HarnessCount = $afterModules.Count
    SameHarnessModule = $afterModules.Count -eq 1 -and
        [object]::ReferenceEquals($beforeModule, $afterModules[0])
    HarnessCommandAvailable = $null -ne $afterCommand
    SameCommandModule = $null -ne $afterCommand -and
        [object]::ReferenceEquals($beforeCommand.Module, $afterCommand.Module)
    TargetLoaded = $null -ne $targetModule
    TargetCommandWorked = [bool]$commandWorked
} | ConvertTo-Json -Compress
'@, [Text.UTF8Encoding]::new($false))

        $output = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive `
            -File $probePath `
            -HarnessManifest $harnessManifest `
            -TargetManifest $targetManifest `
            -TargetName $Target `
            -UseForce $Force.ToString().ToLowerInvariant() `
            -CaseRoot $caseRoot `
            -RepositoryRoot $repoRoot
        if ($LASTEXITCODE -ne 0) {
            throw ($output | Out-String)
        }
        $result = @($output | Select-Object -Last 1 | ConvertFrom-Json)

        $result | Should -HaveCount 1
        $result[0].HarnessCount | Should -Be 1
        $result[0].SameHarnessModule | Should -BeTrue
        $result[0].HarnessCommandAvailable | Should -BeTrue
        $result[0].SameCommandModule | Should -BeTrue
        $result[0].TargetLoaded | Should -BeTrue
        $result[0].TargetCommandWorked | Should -BeTrue
    }
}
