BeforeAll {
    $script:repo = Split-Path $PSScriptRoot -Parent
    $script:entry = Join-Path $script:repo 'tools\Invoke-SignoffReplay.ps1'
    $script:python = if ($env:DEVPILOT_SIGNOFF_TEST_PYTHON) { $env:DEVPILOT_SIGNOFF_TEST_PYTHON } else { 'python' }
}

Describe 'Standalone sign-off replay wrapper' {
    It 'validates the shipped strict bundle without SDK or provider access' {
        $result = & pwsh -NoProfile -File $script:entry -Action ValidateBundle `
            -InputPath (Join-Path $script:repo 'samples\signoff\complete.bundle.json') -PythonPath $script:python
        $LASTEXITCODE | Should -Be 0
        ($result | ConvertFrom-Json).valid | Should -BeTrue
    }

    It 'persists fixture output and resumes only the exact run' {
        $outputRoot = Join-Path $TestDrive 'replay-output'
        $arguments = @('-NoProfile', '-File', $script:entry, '-Action', 'Run', '-Mode', 'Offline',
            '-InputPath', (Join-Path $script:repo 'samples\signoff\complete.bundle.json'),
            '-FixturePath', (Join-Path $script:repo 'samples\signoff\responses.json'),
            '-OutputRoot', $outputRoot, '-Model', 'fixture-v1', '-PythonPath', $script:python)
        & pwsh @arguments | Out-Null
        $LASTEXITCODE | Should -Be 0
        $result = Get-Content (Join-Path $outputRoot 'results.jsonl') -Raw | ConvertFrom-Json
        $result.recommendation | Should -BeExactly 'APPROVE'
        $result.authorization | Should -BeExactly 'NONE'
        $result.runs.Count | Should -Be 2
        & pwsh @arguments -Resume | Out-Null
        $LASTEXITCODE | Should -Be 0
        & pwsh @arguments -Resume -DeadlineSeconds 61 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 2
    }

    It 'keeps the entry point out of agent role state and contains descendants' {
        $text = Get-Content $script:entry -Raw
        $text | Should -Match '-ContainDescendants'
        $text | Should -Not -Match 'Enter-AgentWorkLease|AgentName reviewer|AgentName review-handler|Set-AgentProvider'
        $text | Should -Not -Match 'pip install|download-runtime'
    }

    It 'rejects cancellation without writing a case result' {
        $cancel = Join-Path $TestDrive 'cancel'
        New-Item $cancel -ItemType File | Out-Null
        $outputRoot = Join-Path $TestDrive 'cancelled-output'
        & pwsh -NoProfile -File $script:entry -Action Run -Mode Offline `
            -InputPath (Join-Path $script:repo 'samples\signoff\complete.bundle.json') `
            -FixturePath (Join-Path $script:repo 'samples\signoff\responses.json') `
            -OutputRoot $outputRoot -Model fixture-v1 -PythonPath $script:python -CancelFile $cancel 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 130
        Test-Path (Join-Path $outputRoot 'results.jsonl') | Should -BeFalse
    }

    It 'terminates a real child and its descendant on cancellation' -Skip:(-not $IsWindows) {
        Import-Module (Join-Path $script:repo 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
        $pidFile = Join-Path $TestDrive 'owned-descendant.pid'
        $escapedPidFile = $pidFile.Replace("'", "''")
        $command = @"
`$child = Start-Process -FilePath (Get-Command pwsh).Source -PassThru -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')
[IO.File]::WriteAllText('$escapedPidFile', [string]`$child.Id)
Start-Sleep -Seconds 30
"@
        $result = Invoke-TimedProcess -FilePath (Get-Command pwsh).Source `
            -ArgumentList @('-NoProfile', '-Command', $command) -ContainDescendants `
            -CancellationProbe { Test-Path -LiteralPath $pidFile } -TimeoutSeconds 15 `
            -CaptureStdOut -CaptureStdErr
        $result.Cancelled | Should -BeTrue
        $ownedPid = [int](Get-Content -LiteralPath $pidFile -Raw)
        Get-Process -Id $ownedPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
