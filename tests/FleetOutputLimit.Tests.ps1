BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
}

Describe 'Opt-in timed-process output limits' {
    It 'caps captured output and reports excess without changing the unlimited default' {
        $pwsh = Resolve-AgentPwshPath
        $bounded = Invoke-TimedProcess -FilePath $pwsh -ArgumentList @(
            '-NoProfile', '-Command', '[Console]::Out.Write(("x" * 100000)); Start-Sleep -Seconds 20'
        ) -CaptureStdOut -CaptureStdErr -ContainDescendants -MaxOutputCharacters 4096 -TimeoutSeconds 10
        $bounded.OutputLimitExceeded | Should -BeTrue
        $bounded.StdOut.Length | Should -BeLessOrEqual 4096
        $bounded.Cancelled | Should -BeTrue
        $normal = Invoke-TimedProcess -FilePath $pwsh -ArgumentList @(
            '-NoProfile', '-Command', '[Console]::Out.Write("ok")'
        ) -CaptureStdOut -MaxOutputCharacters 4096 -TimeoutSeconds 10
        $normal.StdOut | Should -BeExactly 'ok'
        $normal.OutputLimitExceeded | Should -BeFalse
        $normal.ExitCode | Should -Be 0
    }

    It 'honors cancellation while retaining bounded stdout and stderr' {
        $result = Invoke-TimedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
            '-NoProfile', '-Command', 'Start-Sleep -Seconds 30'
        ) -CaptureStdOut -CaptureStdErr -ContainDescendants -CancellationProbe { $true } `
            -MaxOutputCharacters 4096 -TimeoutSeconds 10
        $result.Cancelled | Should -BeTrue
        $result.OutputLimitExceeded | Should -BeFalse
    }
}
