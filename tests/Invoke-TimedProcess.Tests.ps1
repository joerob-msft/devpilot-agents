BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
}

Describe 'Invoke-TimedProcess early stdin closure' {
    BeforeAll {
        $payload = 'x' * (16MB)
        $script:earlyExitResult = Invoke-TimedProcess `
            -FilePath (Get-Command pwsh).Source `
            -ArgumentList @(
                '-NoProfile',
                '-Command',
                '[Console]::Error.Write("resume target rejected"); exit 23'
            ) `
            -StandardInputContent $payload `
            -CaptureStdOut `
            -CaptureStdErr `
            -TimeoutSeconds 10
    }

    It 'returns normally when the child exits before redirected stdin completes' {
        $script:earlyExitResult.TimedOut | Should -BeFalse
    }

    It 'preserves the child exit code and stderr after the broken pipe' {
        $script:earlyExitResult.ExitCode | Should -Be 23
        $script:earlyExitResult.StdErr | Should -Be 'resume target rejected'
    }

    It 'does not classify unrelated exceptions as closed child stdin' {
        InModuleScope DevPilot.AgentHarness {
            Test-IsClosedChildStdinException -Exception ([System.UnauthorizedAccessException]::new('denied')) |
                Should -BeFalse
        }
    }
}
