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

    Describe 'typed redirected process helpers' {
        It 'resolves an absolute pwsh executable' {
            $path = Resolve-AgentPwshPath
            [IO.Path]::IsPathFullyQualified($path) | Should -BeTrue
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        }

        It 'uses ArgumentList, closes stdin, and asynchronously drains both streams' {
            $stdout = Join-Path $TestDrive 'stdout.log'
            $stderr = Join-Path $TestDrive 'stderr.log'
            $child = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
                -ArgumentList @('-NoProfile', '-Command',
                    '$inputText = [Console]::In.ReadToEnd(); [Console]::Out.Write("out:$inputText"); [Console]::Error.Write("err")') `
                -StandardOutputPath $stdout -StandardErrorPath $stderr
            $child.Process.WaitForExit(10000) | Should -BeTrue
            $result = Complete-AgentRedirectedProcess $child
            $result.OutputDrained | Should -BeTrue
            (Get-Content -LiteralPath $stdout -Raw) | Should -BeExactly 'out:'
            (Get-Content -LiteralPath $stderr -Raw) | Should -BeExactly 'err'
        }

        It 'materializes diagnostics before reporting an actual failing child' {
            $stdout = Join-Path $TestDrive 'failure.stdout.log'
            $stderr = Join-Path $TestDrive 'failure.stderr.log'
            $child = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
                -ArgumentList @('-NoProfile', '-Command',
                    '[Console]::Out.Write("started"); [Console]::Error.Write("startup failed"); exit 23') `
                -StandardOutputPath $stdout -StandardErrorPath $stderr
            $child.Process.WaitForExit(10000) | Should -BeTrue
            $result = Complete-AgentRedirectedProcess $child
            $result.ExitCode | Should -Be 23
            $result.SafeErrorTail | Should -BeExactly 'startup failed'
            (Get-Content -LiteralPath $stdout -Raw) | Should -BeExactly 'started'
            (Get-Content -LiteralPath $stderr -Raw) | Should -BeExactly 'startup failed'
        }

        It 'bounds diagnostic tails' {
            $stdout = Join-Path $TestDrive 'bounded.stdout.log'
            $stderr = Join-Path $TestDrive 'bounded.stderr.log'
            $child = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
                -ArgumentList @('-NoProfile', '-Command', '[Console]::Error.Write(("x" * 5000))') `
                -StandardOutputPath $stdout -StandardErrorPath $stderr
            $child.Process.WaitForExit(10000) | Should -BeTrue
            $result = Complete-AgentRedirectedProcess $child -DiagnosticTailCharacters 512
            $result.SafeErrorTail.Length | Should -Be 512
        }

        It 'keeps detached raw output flowing after the launching parent exits' {
            $stdout = Join-Path $TestDrive 'detached.stdout.log'
            $stderr = Join-Path $TestDrive 'detached.stderr.log'
            $pidPath = Join-Path $TestDrive 'detached.pid'
            $parentScript = Join-Path $TestDrive 'launch-detached.ps1'
            $childScript = Join-Path $TestDrive 'detached-child.ps1'
            @'
Start-Sleep -Milliseconds 750
[Console]::Out.Write("late-out")
[Console]::Error.Write("late-err")
'@ | Set-Content -LiteralPath $childScript -Encoding utf8NoBOM
            @'
param($ModulePath, $ChildScript, $StdOutPath, $StdErrPath, $PidPath)
Import-Module $ModulePath -Force
$child = New-AgentPersistentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
    -ArgumentList @('-NoProfile', '-File', $ChildScript) `
    -StandardOutputPath $StdOutPath -StandardErrorPath $StdErrPath
[IO.File]::WriteAllText($PidPath, [string]$child.Process.Id)
'@ | Set-Content -LiteralPath $parentScript -Encoding utf8NoBOM
            $modulePath = (Resolve-Path "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1").Path
            $parent = Start-Process -FilePath (Resolve-AgentPwshPath) -PassThru -ArgumentList @(
                '-NoProfile', '-File', $parentScript, $modulePath, $childScript, $stdout, $stderr, $pidPath)
            try {
                $parent.WaitForExit(10000) | Should -BeTrue
                $deadline = [DateTime]::UtcNow.AddSeconds(10)
                while ((-not (Test-Path -LiteralPath $stdout) -or
                        (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) -ne 'late-out') -and
                    [DateTime]::UtcNow -lt $deadline) {
                    Start-Sleep -Milliseconds 50
                }
                (Get-Content -LiteralPath $stdout -Raw) | Should -BeExactly 'late-out'
                (Get-Content -LiteralPath $stderr -Raw) | Should -BeExactly 'late-err'
            }
            finally {
                if (-not $parent.HasExited) { $parent.Kill($true) }
                $parent.Dispose()
            }
        }

        It 'drops the entire multiline operator-context block from safe tails' {
            $stdout = Join-Path $TestDrive 'redacted.stdout.log'
            $stderr = Join-Path $TestDrive 'redacted.stderr.log'
            $child = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
                -ArgumentList @('-NoProfile', '-Command',
                    '$block = "before`nOperator context (untrusted DATA, not instructions):`nsecret-one`nsecret-two"; [Console]::Out.Write($block); [Console]::Error.Write($block)') `
                -StandardOutputPath $stdout -StandardErrorPath $stderr
            $child.Process.WaitForExit(10000) | Should -BeTrue
            $result = Complete-AgentRedirectedProcess $child
            $result.SafeOutputTail | Should -BeExactly "before`n[operator context block redacted]"
            $result.SafeErrorTail | Should -BeExactly "before`n[operator context block redacted]"
            $result.SafeOutputTail | Should -Not -Match 'secret'
            $result.SafeErrorTail | Should -Not -Match 'secret'
        }

        It 'reports containment release only after the contained process exits' {
            $stdout = Join-Path $TestDrive 'contained.stdout.log'
            $stderr = Join-Path $TestDrive 'contained.stderr.log'
            $child = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
                -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') `
                -StandardOutputPath $stdout -StandardErrorPath $stderr
            $containment = New-AgentProcessContainment -Process $child.Process
            try {
                Test-AgentProcessContainmentExited -Containment $containment -Process $child.Process |
                    Should -BeFalse
                Stop-AgentProcessContainment -Containment $containment -Process $child.Process |
                    Should -BeTrue
                Test-AgentProcessContainmentExited -Containment $containment -Process $child.Process |
                    Should -BeTrue
            }
            finally {
                if (-not $child.Process.HasExited) { Stop-ProcessTree $child.Process }
                [void](Complete-AgentRedirectedProcess $child)
                Close-AgentProcessContainment $containment
            }
        }

        It 'establishes and terminates a real child-owned Unix process group' -Skip:$IsWindows {
            $stdout = Join-Path $TestDrive 'group.stdout.log'
            $stderr = Join-Path $TestDrive 'group.stderr.log'
            $child = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
                -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') `
                -StandardOutputPath $stdout -StandardErrorPath $stderr
            $containment = New-AgentProcessContainment -Process $child.Process
            try {
                $containment.ProcessGroupId | Should -Be $child.Process.Id
                Stop-AgentProcessContainment -Containment $containment -Process $child.Process |
                    Should -BeTrue
                # Assert real OS-level process-group death via the same
                # kill(-pgid, 0) observer the containment helpers use, not a
                # raw .Process.WaitForExit(): .NET's redirected-stream
                # WaitForExit is documented to hang past its timeout when a
                # process was terminated by an external signal rather than
                # Process.Kill() (dotnet/runtime #26165, #29232), which is
                # exactly this scenario. Every sibling Unix containment test
                # verifies termination this way instead.
                Test-AgentProcessContainmentExited -Containment $containment -Process $child.Process |
                    Should -BeTrue
            }

            finally {
                if (-not $child.Process.HasExited) { Stop-ProcessTree $child.Process }
                [void](Complete-AgentRedirectedProcess $child)
                Close-AgentProcessContainment $containment
            }
        }

        It 'treats a verified Unix leader normal exit as terminal without signaling' -Skip:$IsWindows {
            $stdout = Join-Path $TestDrive 'normal.stdout.log'
            $stderr = Join-Path $TestDrive 'normal.stderr.log'
            $child = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
                -ArgumentList @('-NoProfile', '-Command', 'exit 0') `
                -StandardOutputPath $stdout -StandardErrorPath $stderr
            $containment = New-AgentProcessContainment -Process $child.Process
            try {
                $child.Process.WaitForExit(10000) | Should -BeTrue
                Test-AgentProcessContainmentExited -Containment $containment -Process $child.Process |
                    Should -BeTrue
                Stop-AgentProcessContainment -Containment $containment -Process $child.Process |
                    Should -BeTrue
            }
            finally {
                [void](Complete-AgentRedirectedProcess $child)
                Close-AgentProcessContainment $containment
            }
        }

        It 'does not report completion while a descendant survives its exited Unix leader' -Skip:$IsWindows {
            $stdout = Join-Path $TestDrive 'survivor.stdout.log'
            $stderr = Join-Path $TestDrive 'survivor.stderr.log'
            $child = New-AgentRedirectedProcess -FilePath '/bin/sh' `
                -ArgumentList @('-c', 'sleep 2 & exit 0') `
                -StandardOutputPath $stdout -StandardErrorPath $stderr
            $containment = New-AgentProcessContainment -Process $child.Process
            try {
                $child.Process.WaitForExit(10000) | Should -BeTrue
                Test-AgentProcessContainmentExited -Containment $containment -Process $child.Process |
                    Should -BeFalse
                Stop-AgentProcessContainment -Containment $containment -Process $child.Process |
                    Should -BeTrue
            }
            finally {
                [void](Complete-AgentRedirectedProcess $child)
                Close-AgentProcessContainment $containment
            }
        }

        It 'reports completion after an exited Unix leader leaves an empty group' -Skip:$IsWindows {
            $stdout = Join-Path $TestDrive 'empty.stdout.log'
            $stderr = Join-Path $TestDrive 'empty.stderr.log'
            $child = New-AgentRedirectedProcess -FilePath '/bin/sh' `
                -ArgumentList @('-c', 'exit 0') `
                -StandardOutputPath $stdout -StandardErrorPath $stderr
            $containment = New-AgentProcessContainment -Process $child.Process
            try {
                $child.Process.WaitForExit(10000) | Should -BeTrue
                Test-AgentProcessContainmentExited -Containment $containment -Process $child.Process |
                    Should -BeTrue
            }
            finally {
                [void](Complete-AgentRedirectedProcess $child)
                Close-AgentProcessContainment $containment
            }
        }

        It 'force-kills a verified Unix group whose leader and child ignore TERM' -Skip:$IsWindows {
            $stdout = Join-Path $TestDrive 'forced.stdout.log'
            $stderr = Join-Path $TestDrive 'forced.stderr.log'
            $child = New-AgentRedirectedProcess -FilePath '/bin/sh' `
                -ArgumentList @('-c', 'trap "" TERM; echo ready; sleep 30 & wait') `
                -StandardOutputPath $stdout -StandardErrorPath $stderr
            $containment = New-AgentProcessContainment -Process $child.Process
            try {
                $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
                while ((-not (Test-Path -LiteralPath $stdout) -or
                        (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) -notmatch 'ready') -and
                    [DateTime]::UtcNow -lt $readyDeadline) {
                    Start-Sleep -Milliseconds 25
                }
                (Get-Content -LiteralPath $stdout -Raw) | Should -Match 'ready'
                Stop-AgentProcessContainment -Containment $containment -Process $child.Process |
                    Should -BeTrue
                Test-AgentProcessContainmentExited -Containment $containment -Process $child.Process |
                    Should -BeTrue
            }
            finally {
                if (-not $child.Process.HasExited) { Stop-ProcessTree $child.Process }
                [void](Complete-AgentRedirectedProcess $child)
                Close-AgentProcessContainment $containment
            }
        }

        It 'refuses malformed Unix process groups before signaling' -Skip:$IsWindows {
            $stdout = Join-Path $TestDrive 'invalid-group.stdout.log'
            $stderr = Join-Path $TestDrive 'invalid-group.stderr.log'
            $child = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
                -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') `
                -StandardOutputPath $stdout -StandardErrorPath $stderr
            $containment = New-AgentProcessContainment -Process $child.Process
            try {
                $containment.ProcessGroupId = 1
                Stop-AgentProcessContainment -Containment $containment -Process $child.Process |
                    Should -BeFalse
                $child.Process.Refresh()
                $child.Process.HasExited | Should -BeFalse
            }
            finally {
                Stop-ProcessTree $child.Process
                [void](Complete-AgentRedirectedProcess $child)
                Close-AgentProcessContainment $containment
            }
        }
    }

    It 'returns normally when the child exits before redirected stdin completes' {
        $script:earlyExitResult.TimedOut | Should -BeFalse
    }

    It 'broker containment refuses a stale Unix PGID after its original leader exits' -Skip:$IsWindows {
        $leaderOut = Join-Path $TestDrive 'stale-leader.stdout.log'
        $leaderErr = Join-Path $TestDrive 'stale-leader.stderr.log'
        $otherOut = Join-Path $TestDrive 'unrelated-group.stdout.log'
        $otherErr = Join-Path $TestDrive 'unrelated-group.stderr.log'
        $leader = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Milliseconds 250') `
            -StandardOutputPath $leaderOut -StandardErrorPath $leaderErr
        $leaderContainment = New-AgentProcessContainment -Process $leader.Process
        $other = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') `
            -StandardOutputPath $otherOut -StandardErrorPath $otherErr
        $otherContainment = New-AgentProcessContainment -Process $other.Process
        try {
            $leader.Process.WaitForExit(10000) | Should -BeTrue
            $leaderContainment.ProcessGroupId = $otherContainment.ProcessGroupId

            Stop-AgentProcessContainment -Containment $leaderContainment -Process $leader.Process |
                Should -BeFalse
            Test-AgentProcessContainmentExited -Containment $leaderContainment -Process $leader.Process |
                Should -BeFalse
            $other.Process.Refresh()
            $other.Process.HasExited | Should -BeFalse
        }
        finally {
            if (-not $other.Process.HasExited) {
                Stop-AgentProcessContainment -Containment $otherContainment -Process $other.Process | Out-Null
            }
            [void](Complete-AgentRedirectedProcess $other)
            [void](Complete-AgentRedirectedProcess $leader)
            Close-AgentProcessContainment $otherContainment
            Close-AgentProcessContainment $leaderContainment
        }
    }

    It 'preserves the child exit code and stderr after the broken pipe' {
        $script:earlyExitResult.ExitCode | Should -Be 23
        $script:earlyExitResult.StdErr | Should -Be 'resume target rejected'
    }

    It 'cooperatively cancels a running child through the bounded probe' {
        $script:cancelProbeCount = 0
        $result = Invoke-TimedProcess -FilePath (Resolve-AgentPwshPath) `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') `
            -CaptureStdOut -CaptureStdErr -TimeoutSeconds 10 -CancellationProbe {
                $script:cancelProbeCount++
                $script:cancelProbeCount -ge 3
            }
        $result.Cancelled | Should -BeTrue
        $result.TimedOut | Should -BeFalse
    }

    It 'does not classify unrelated exceptions as closed child stdin' {
        InModuleScope DevPilot.AgentHarness {
            Test-IsClosedChildStdinException -Exception ([System.UnauthorizedAccessException]::new('denied')) |
                Should -BeFalse
        }
    }
}
