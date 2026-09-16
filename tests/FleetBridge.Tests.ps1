BeforeAll {
    $script:repository = Split-Path -Parent $PSScriptRoot
    $script:bridge = Join-Path $script:repository 'src\DevPilot.Fleet\bridge\Invoke-FleetAttempt.ps1'
    $script:pwsh = (Get-Process -Id $PID).Path
    Import-Module (Join-Path $script:repository 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force -DisableNameChecking

    function Invoke-FleetAdmissionFixture {
        param([switch]$Cancel, [switch]$ChangedOwner)
        $root = Join-Path ([IO.Path]::GetTempPath()) "devpilot-fleet-bridge-$([guid]::NewGuid().ToString('N'))"
        $savedToken = $env:COPILOT_GITHUB_TOKEN
        try {
            [void](Resolve-AgentTrustedRoot -Path $root -Kind durable-state -RepositoryRoot $script:repository -Create)
            $request = Join-Path $root 'request.json'
            $lock = Join-Path $root 'owner.json'
            @{
                prompt = 'Do not execute: admission fixture.'
                nonce = 'a' * 32
                inputHash = 'b' * 64
                timeoutSeconds = 10
            } | ConvertTo-Json | Set-Content -LiteralPath $request -Encoding utf8
            @{ pid = $PID; token = $(if ($ChangedOwner) { 'different-owner' } else { 'fixture-owner' }) } |
                ConvertTo-Json | Set-Content -LiteralPath $lock -Encoding utf8
            if ($Cancel) { Set-Content -LiteralPath (Join-Path $root 'cancel') -Value 'cancel' }
            $env:COPILOT_GITHUB_TOKEN = 'fixture-token-never-used'
            # A shell executable, not Copilot: even an admission regression cannot invoke a model.
            $arguments = @(
                '-NoProfile', '-NonInteractive', '-File', $script:bridge,
                '-RequestPath', $request, '-ExecutorPath', $script:pwsh,
                '-OwnerPid', [string]$PID,
                '-OwnerCreatedAt', [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(),
                '-LockPath', $lock, '-OwnerToken', 'fixture-owner'
            )
            $process = Invoke-TimedProcess -FilePath $script:pwsh -ArgumentList $arguments `
                -CaptureStdOut -CaptureStdErr -ContainDescendants -MaxOutputCharacters 32768 -TimeoutSeconds 30
            $process.TimedOut | Should -BeFalse
            Get-Content -LiteralPath (Join-Path $root 'outcome.json') -Raw | ConvertFrom-Json
        }
        finally {
            $env:COPILOT_GITHUB_TOKEN = $savedToken
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }
}

Describe 'Fleet bridge pre-execution admission' -Skip:(-not $IsWindows) {
    It 'reports confirmed cancellation without starting the model when cancellation already exists' {
        $outcome = Invoke-FleetAdmissionFixture -Cancel
        $outcome.status | Should -Be 'cancelled'
        $outcome.cleanupConfirmed | Should -BeTrue
    }

    It 'rejects changed ownership before starting any subprocess' {
        $outcome = Invoke-FleetAdmissionFixture -ChangedOwner
        $outcome.status | Should -Be 'failed'
        $outcome.cleanupConfirmed | Should -BeTrue
        $outcome.error | Should -Match 'ownership changed'
    }
}
