BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
    Import-Module (Join-Path $repoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    $script:dashboardBuilt = Test-Path -LiteralPath (Join-Path $repoRoot 'src\DevPilot.Dashboard\dist\src\dispatch.js')

    function New-StartupFixture {
        param([string]$Mode)
        $root = Resolve-AgentTrustedRoot -Path (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))) `
            -Kind watch-state -RepositoryRoot $repoRoot -Create
        $toolkit = Join-Path $root 'toolkit'
        foreach ($relative in @('tools', 'src\Agents\reviewer', 'config')) {
            New-Item -ItemType Directory -Path (Join-Path $toolkit $relative) -Force | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $repoRoot 'src\DevPilot.AgentHarness') `
            -Destination (Join-Path $toolkit 'src') -Recurse
        Add-Content -LiteralPath (Join-Path $toolkit 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1') `
            -Value (Get-Content -LiteralPath "$PSScriptRoot\fixtures\ManualStartupProvider.ps1" -Raw)
        if ($Mode -eq 'termination-failed') {
            # Simulate one failed containment attempt, then let shutdown use the real terminator.
            Add-Content -LiteralPath (Join-Path $toolkit 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1') -Value @'
$script:StartupRealStop = ${function:Stop-AgentProcessContainment}
$script:StartupStopFailed = $false
function Stop-AgentProcessContainment {
    param([hashtable]$Containment, [Diagnostics.Process]$Process)
    if (-not $script:StartupStopFailed) { $script:StartupStopFailed = $true; return $false }
    & $script:StartupRealStop -Containment $Containment -Process $Process
}
'@
        }
        if ($Mode -in @('eof-termination-failed', 'shutdown-termination-failed')) {
            Add-Content -LiteralPath (Join-Path $toolkit 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1') -Value @'
function Stop-AgentProcessContainment {
    param([hashtable]$Containment, [Diagnostics.Process]$Process)
    return $false
}
'@
        }
        $broker = Join-Path $toolkit 'tools\Invoke-DevPilotAgentDispatch.ps1'
        Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\Invoke-DevPilotAgentDispatch.ps1') -Destination $broker
        $child = Join-Path $toolkit 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
        Copy-Item -LiteralPath "$PSScriptRoot\fixtures\ManualStartupChild.ps1" -Destination $child
        $watch = Resolve-AgentTrustedRoot -Path (Join-Path $root 'watch') -Kind watch-state -RepositoryRoot $toolkit -Create
        $durable = Resolve-AgentTrustedRoot -Path (Join-Path $root 'durable') -Kind durable-state -RepositoryRoot $toolkit -Create
        $leases = Resolve-AgentTrustedRoot -Path (Join-Path $root 'leases') -Kind lease -RepositoryRoot $toolkit -Create
        $config = Join-Path $toolkit 'config\reviewer.json'
        @{
            provider = 'GitHub'; repository = @{ organization = 'startup-fixture'; name = 'repository' }
            startupTestMode = $Mode
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $config -Encoding utf8NoBOM
        $descriptor = Join-Path $watch 'broker.descriptor.v1.json'
        @{
            schemaVersion = 1; ownerProcessId = $PID; stateRoot = $watch
            durableStateRoot = $durable; leaseRoot = $leases; operatorAlias = 'startup-test'
            roles = @{ reviewer = @{
                enabled = $true; scriptPath = $child; configRoot = (Split-Path $config); configFile = $config
                repositoryRoot = $toolkit; capabilities = @('EnableFindingComments', 'EnableSummaryComment', 'EnableThreadReplies')
                mandatoryDenies = @('EnableApprovalVote'); absoluteDenies = @()
            } }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $descriptor -Encoding utf8NoBOM
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($descriptor, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        return @{
            Root = $root; Toolkit = $toolkit; Broker = $broker; Descriptor = $descriptor
            Watch = $watch; Leases = $leases
        }
    }
}

Describe 'Windows manual startup process regressions' -Skip:(-not $IsWindows) {
    It 'transfers the actual anonymous-pipe secret to a redirected spawned child' {
        $root = Join-Path $TestDrive 'transport'
        $pipe = [IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::Out, [IO.HandleInheritability]::Inheritable)
        $secret = New-AgentBrokerAttestationSecret
        $nonce = New-AgentNonce
        $digest = 'a' * 64
        $module = Join-Path $repoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'
        $command = @'
param($Module, $Nonce, $Digest)
$ErrorActionPreference = 'Stop'
Import-Module $Module -Force
$secret = Receive-AgentBrokerAttestationSecret
try {
    if ($env:DEVPILOT_BROKER_ATTESTATION_HANDLE) { throw 'Inherited handle was not cleared.' }
    Get-AgentAttestationProof -SecretBytes $secret -Nonce $Nonce -Digest $Digest
}
finally { [Array]::Clear($secret, 0, $secret.Length) }
'@
        $child = $null
        try {
            $scriptPath = Join-Path $TestDrive 'transport-child.ps1'
            Set-Content -LiteralPath $scriptPath -Value $command -Encoding utf8NoBOM
            $child = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
                -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scriptPath, $module, $nonce, $digest) `
                -StandardOutputPath (Join-Path $root 'stdout') -StandardErrorPath (Join-Path $root 'stderr') `
                -AdditionalEnvironmentVariables @{ DEVPILOT_BROKER_ATTESTATION_HANDLE = $pipe.GetClientHandleAsString() }
            $pipe.DisposeLocalCopyOfClientHandle()
            $pipe.Write($secret, 0, $secret.Length)
            $pipe.Flush()
            $child.Process.WaitForExit(15000) | Should -BeTrue
            $result = Complete-AgentRedirectedProcess $child
            $result.ExitCode | Should -Be 0 -Because $result.SafeErrorTail
            $proofMatches = $result.SafeOutputTail.Trim() -ceq (Get-AgentAttestationProof -SecretBytes $secret -Nonce $nonce -Digest $digest)
            $proofMatches | Should -BeTrue -Because 'the spawned child must receive all 32 ephemeral bytes'
        }
        finally {
            $pipe.Dispose()
            [Array]::Clear($secret, 0, $secret.Length)
            if ($child) {
                if (-not $child.Process.HasExited) { $child.Process.Kill($true); [void]$child.Process.WaitForExit(5000) }
                $child.Process.Dispose()
            }
        }
    }

    It 'runs the real broker/client handshake with an isolated <Mode> child' -ForEach @(
        @{ Mode = 'success' }, @{ Mode = 'early-exit' }, @{ Mode = 'contention' }, @{ Mode = 'termination-failed' }
    ) {
        if (-not $dashboardBuilt) {
            Set-ItResult -Skipped -Because 'Run npm run build in src\DevPilot.Dashboard first; the dashboard CI job runs this integration.'
            return
        }
        $fixture = New-StartupFixture -Mode $Mode
        $savedAppData = $env:LOCALAPPDATA
        $lease = $null
        try {
            $env:LOCALAPPDATA = Join-Path $fixture.Root 'appdata'
            if ($Mode -eq 'contention') {
                $lease = Enter-AgentWorkLease -LeaseRoot $fixture.Leases -RepositoryIdentity @{
                    key = 'v1:github:114'; verified = $true
                } -PullRequestId 114 -Role reviewer -TimeoutMilliseconds 100
                $lease.Acquired | Should -BeTrue
            }
            $result = Invoke-TimedProcess -FilePath (Get-Command node -CommandType Application).Source `
                -ArgumentList @(
                    (Join-Path $PSScriptRoot 'fixtures\manual-startup-client.mjs'),
                    (Join-Path $repoRoot 'src\DevPilot.Dashboard\dist\src\dispatch.js'),
                    (Resolve-AgentPwshPath), $fixture.Broker, $fixture.Descriptor, $Mode
                ) -CaptureStdOut -CaptureStdErr -TimeoutSeconds 90
            $result.TimedOut | Should -BeFalse
            $testError = Join-Path $fixture.Watch 'logs\events\reviewer\startup-test-error.txt'
            $startupError = if (Test-Path -LiteralPath $testError) { Get-Content -LiteralPath $testError -Raw } else { '' }
            $result.ExitCode | Should -Be 0 -Because "$($result.StdErr)`n$startupError"
            $result.StdOut.Trim() | Should -BeExactly "startup-$Mode-verified"
            @(Get-ChildItem -LiteralPath (Join-Path $fixture.Watch 'manual-dispatch')).Count | Should -Be 0
        }
        finally {
            if ($lease -and $lease.Acquired) { Exit-AgentLock $lease.Stream }
            $env:LOCALAPPDATA = $savedAppData
        }
    }

    It 'keeps outer-finally containment output off JSONL with <Mode>' -ForEach @(
        @{ Mode = 'wait'; ExpectedExitCode = 0 }
        @{ Mode = 'eof-termination-failed'; ExpectedExitCode = 1 }
        @{ Mode = 'shutdown-termination-failed'; ExpectedExitCode = 1 }
    ) {
        $fixture = New-StartupFixture -Mode $Mode
        $savedAppData = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = Join-Path $fixture.Root 'appdata'
            $result = Invoke-TimedProcess -FilePath (Get-Command node -CommandType Application).Source `
                -ArgumentList @(
                    (Join-Path $PSScriptRoot 'fixtures\manual-startup-eof.mjs'),
                    (Resolve-AgentPwshPath), $fixture.Broker, $fixture.Descriptor, [string]$ExpectedExitCode, $Mode
                ) -CaptureStdOut -CaptureStdErr -TimeoutSeconds 60
            $result.TimedOut | Should -BeFalse
            $result.ExitCode | Should -Be 0 -Because $result.StdErr
            $result.StdOut.Trim() | Should -BeExactly 'startup-eof-verified'
            @(Get-ChildItem -LiteralPath (Join-Path $fixture.Watch 'manual-dispatch')).Count | Should -Be $ExpectedExitCode
        }
        finally { $env:LOCALAPPDATA = $savedAppData }
    }
}
