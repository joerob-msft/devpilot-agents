BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..").Path
    Import-Module (Join-Path $repo 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    function New-SchedulingFixture {
        param([string]$Mode, [string]$Role, [bool]$Preview)
        $root = Resolve-AgentTrustedRoot -Path (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))) `
            -Kind watch-state -RepositoryRoot $repo -Create
        $toolkit = Join-Path $root 'toolkit'
        $watch = Join-Path $root 'watch'
        $durable = Join-Path $root 'durable'
        $leases = Join-Path $root 'leases'
        $dashboard = Join-Path $toolkit 'src\DevPilot.Dashboard'
        New-Item -ItemType Directory -Path "$toolkit\tools", "$toolkit\src\Agents\reviewer",
            "$toolkit\src\Agents\review-handler", "$toolkit\config", "$dashboard\dist\src",
            "$dashboard\node_modules\bun\bin" -Force | Out-Null
        Copy-Item (Join-Path $repo 'src\DevPilot.AgentHarness') (Join-Path $toolkit 'src') -Recurse
        Add-Content "$toolkit\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1" `
            (Get-Content "$PSScriptRoot\fixtures\SchedulingProvider.ps1" -Raw)
        if ($Mode -eq 'termination-failed') {
            Add-Content "$toolkit\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1" @'
$script:FixtureRealStop = ${function:Stop-AgentProcessContainment}
$script:FixtureFailedOnce = $false
function Stop-AgentProcessContainment {
    param([hashtable]$Containment, [Diagnostics.Process]$Process)
    if (-not $script:FixtureFailedOnce) { $script:FixtureFailedOnce = $true; return $false }
    & $script:FixtureRealStop $Containment $Process
}
'@
        }
        if ($Mode -eq 'startup-barrier') {
            Add-Content "$toolkit\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1" @'
$script:FixtureRealContain = ${function:New-AgentProcessContainment}
function New-AgentProcessContainment {
    param([Diagnostics.Process]$Process)
    Start-Sleep -Seconds 2
    $containment = & $script:FixtureRealContain $Process
    [IO.File]::WriteAllText((Join-Path $env:DEVPILOT_SCHEDULING_FIXTURE "contained-$($Process.Id)"), 'fixture')
    return $containment
}
'@
        }
        Copy-Item "$repo\tools\Watch-DevPilotAgents.ps1", "$repo\tools\Invoke-DevPilotAgentDispatch.ps1" "$toolkit\tools"
        if ($Mode -in @('expiry', 'manual-next-expiry')) {
            $path = "$toolkit\tools\Invoke-DevPilotAgentDispatch.ps1"
            $seconds = if ($Mode -ceq 'manual-next-expiry') { 8 } else { 4 }
            [IO.File]::WriteAllText($path, ([IO.File]::ReadAllText($path).Replace('$DraftLifetimeSeconds = 600', "`$DraftLifetimeSeconds = $seconds")))
        }
        foreach ($relative in @('reviewer\Start-ReviewerAgent.ps1', 'review-handler\Start-ReviewHandlerAgent.ps1')) {
            Copy-Item "$PSScriptRoot\fixtures\LauncherWorkerChild.ps1" "$toolkit\src\Agents\$relative"
        }
        $config = @{ provider = 'GitHub'; repository = @{ organization = 'scheduling-fixture'; name = 'repository' }
            testMode = $Mode; testRole = $Role; previewOnly = $Preview }
        $config | ConvertTo-Json -Depth 6 | Set-Content "$root\scenario.json" -Encoding utf8NoBOM
        $config | ConvertTo-Json -Depth 6 | Set-Content "$toolkit\config\agent.json" -Encoding utf8NoBOM
        $reviewerConfig = "$toolkit\config\agent.json"
        $handlerConfig = "$toolkit\config\agent.json"
        if ($Mode -ceq 'real-startup-fail') {
            $relative = if ($Role -ceq 'reviewer') { 'reviewer\Start-ReviewerAgent.ps1' } else { 'review-handler\Start-ReviewHandlerAgent.ps1' }
            Copy-Item "$repo\src\Agents\$relative" "$toolkit\src\Agents\$relative" -Force
            $invalid = "$toolkit\config\invalid.json"
            [IO.File]::WriteAllText($invalid, '{invalid fixture JSON')
            if ($Role -ceq 'reviewer') { $reviewerConfig = $invalid } else { $handlerConfig = $invalid }
        }
        Copy-Item "$repo\src\DevPilot.Dashboard\node_modules\bun\bin\bun.exe" "$dashboard\node_modules\bun\bin\bun.exe"
        Copy-Item "$repo\src\DevPilot.Dashboard\src\dispatch.ts", "$repo\src\DevPilot.Dashboard\src\domain.ts" "$dashboard\dist\src"
        Copy-Item "$PSScriptRoot\fixtures\scheduling-dashboard.mjs" "$dashboard\dist\src\index.js"
        @'
param([string[]]$StateDir, [string[]]$EventLogPath, [string]$BrokerDescriptorPath, [string]$LaunchMode, [switch]$ValidateOnly)
if ($ValidateOnly) { return }
$dashboard = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\DevPilot.Dashboard'
& (Join-Path $dashboard 'node_modules\bun\bin\bun.exe') --conditions=browser `
    (Join-Path $dashboard 'dist\src\index.js') --launch-mode $LaunchMode --state-dir $StateDir[0] `
    --broker-executable (Resolve-AgentPwshPath) --broker-script (Join-Path $PSScriptRoot 'Invoke-DevPilotAgentDispatch.ps1') `
    --broker-descriptor $BrokerDescriptorPath
if ($LASTEXITCODE -ne 0) { throw "Scheduling fixture failed: $LASTEXITCODE" }
'@ | Set-Content "$toolkit\tools\Start-DevPilotDashboard.ps1" -Encoding utf8NoBOM
        return @{ Root = $root; Toolkit = $toolkit; Watch = $watch; Durable = $durable; Leases = $leases
            ReviewerConfig = $reviewerConfig; HandlerConfig = $handlerConfig }
    }
    function Invoke-SchedulingScenario {
        param([string]$Mode, [string]$Role, [bool]$Preview)
        $fixture = New-SchedulingFixture $Mode $Role $Preview
        $saved = @{ Local = $env:LOCALAPPDATA; Fixture = $env:DEVPILOT_SCHEDULING_FIXTURE }
        $lock = $null
        try {
            $env:LOCALAPPDATA = Join-Path $fixture.Root 'appdata'
            $env:DEVPILOT_SCHEDULING_FIXTURE = $fixture.Root
            if ($Mode -eq 'foreign') {
                [void](Resolve-AgentTrustedRoot -Path $fixture.Durable -Kind durable-state -RepositoryRoot $fixture.Toolkit -Create)
                $context = Get-AgentDurableStateContext -DurableStateRoot $fixture.Durable `
                    -RepositoryIdentity @{ key = 'v1:github:114'; verified = $true } -Role $Role -Create
                $lock = Enter-AgentDurableStateLock $context
                $lock.Acquired | Should -BeTrue
            }
            $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', "$($fixture.Toolkit)\tools\Watch-DevPilotAgents.ps1",
                '-Golden', '-ReviewerConfigFile', $fixture.ReviewerConfig,
                '-ReviewHandlerConfigFile', $fixture.HandlerConfig, '-OperatorAlias', 'fixture',
                '-StateDir', $fixture.Watch, '-DurableStateRoot', $fixture.Durable, '-LeaseRoot', $fixture.Leases,
                '-IntervalSeconds', '73', '-ReviewerModel', 'gpt-5.4', '-ReviewHandlerModel', 'gpt-5.4', '-IncludeOwnPullRequests')
            if ($Preview) { $arguments += '-PreviewOnly' }
            $result = Invoke-TimedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList $arguments `
                -WorkingDirectory $fixture.Toolkit -CaptureStdOut -CaptureStdErr -TimeoutSeconds 110
            $result.TimedOut | Should -BeFalse
            $errors = @(Get-ChildItem $fixture.Watch -Filter '*.log' -Recurse | ForEach-Object {
                if ($_.Length -gt 0) { Get-Content $_.FullName -Tail 5 }
            }) -join "`n"
            $result.ExitCode | Should -Be 0 -Because "$($result.StdErr)`n$errors"
            (Test-Path "$($fixture.Root)\verified.json") | Should -BeTrue
        }
        finally {
            if ($lock) { Exit-AgentLock $lock.Stream }
            $env:LOCALAPPDATA = $saved.Local
            $env:DEVPILOT_SCHEDULING_FIXTURE = $saved.Fixture
        }
    }

}

Describe 'Current launcher busy scheduling with real Windows containment and fake providers' -Skip:(-not $IsWindows) {
        It 'hands off <Mode> for <Role> (preview=<Preview>) without widening or admitting another PR' -ForEach @(
            @{ Mode = 'replace'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'next'; Role = 'reviewer'; Preview = $false }
            @{ Mode = 'next'; Role = 'review-handler'; Preview = $true }
            @{ Mode = 'descendant'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'ack-descendant'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'source'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'stale'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'cancel'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'shutdown'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'expiry'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'foreign'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'policy'; Role = 'reviewer'; Preview = $false }
            @{ Mode = 'termination-failed'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'eof'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'eof-revalidation'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'manual-next'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'manual-replace'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'startup-barrier'; Role = 'reviewer'; Preview = $true }
        ) {
            Invoke-SchedulingScenario $Mode $Role $Preview
        }

        It 'review regression <Mode> for <Role> preserves predecessor ownership and truthful startup status' -ForEach @(
            @{ Mode = 'manual-next-cancel'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'manual-next-expiry'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'manual-next-cancel-race'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'auto-startup-fail'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'real-startup-fail'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'real-startup-fail'; Role = 'review-handler'; Preview = $true }
            @{ Mode = 'auto-resume-fail'; Role = 'reviewer'; Preview = $true }
            @{ Mode = 'auto-resume-wait'; Role = 'reviewer'; Preview = $true }
        ) {
            Invoke-SchedulingScenario $Mode $Role $Preview
    }
}
