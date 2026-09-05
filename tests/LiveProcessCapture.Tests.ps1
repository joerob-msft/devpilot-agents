BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    function New-CaptureTestRoot {
        $path = Join-Path $TestDrive ("capture with spaces " + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $path | Out-Null
        if ($IsWindows) {
            $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $acl.SetOwner($user)
            $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($user,
                [Security.AccessControl.FileSystemRights]::FullControl,
                ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
                [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
            Set-Acl $path $acl
        }
        else { [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute) }
        Copy-Item "$PSScriptRoot\fixtures\live-stdout-child.ps1" (Join-Path $path 'child with spaces.ps1')
        return $path
    }
    function Start-CaptureFixture {
        param([string]$Root, [bool]$Live = $true, [string]$Mode = 'small')
        return New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $Root 'child with spaces.ps1'),
            '-Message', 'space "quoted" C:\a path\tail\ ; $(Get-Date)', '-ReleasePath', (Join-Path $Root 'release'), '-Mode', $Mode
        ) -StandardOutputPath (Join-Path $Root 'stdout.jsonl') -StandardErrorPath (Join-Path $Root 'stderr.log') `
            -WorkingDirectory $Root -LiveStandardOutput:$Live
    }
    function Finish-CaptureFixture {
        param([hashtable]$Child, [string]$Root)
        [IO.File]::WriteAllText((Join-Path $Root 'release'), 'finish naturally')
        if (-not $Child.Process.WaitForExit(50000)) { throw 'Fixture did not exit within its own bounded lifetime.' }
    }
    function Read-LiveCapture {
        param([string]$Path)
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
}

Describe 'opt-in bounded live process stdout' {
    It 'supports two live captures after the old BoundedDrain was loaded before module import' -Tag 'ReloadCompatibility' {
        $root = New-CaptureTestRoot
        $result = Invoke-TimedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', "$PSScriptRoot\fixtures\live-capture-reload.ps1",
            '-ModulePath', "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1",
            '-StateRoot', $root
        ) -CaptureStdOut -CaptureStdErr -TimeoutSeconds 120
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        $proof = $result.StdOut | ConvertFrom-Json
        $proof.legacyTypePreserved | Should -BeTrue
        $proof.liveCaptures | Should -Be 2
    }

    It 'preserves typed spaced/quoted arguments and default capture semantics (live=<Live>)' -ForEach @(
        @{ Live = $false }, @{ Live = $true }
    ) {
        $root = New-CaptureTestRoot
        $child = Start-CaptureFixture -Root $root -Live $Live
        try {
            if ($Live) {
                $until = [DateTime]::UtcNow.AddSeconds(5)
                while ((Get-Item $child.StdOutPath).Length -eq 0 -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 20 }
                $first = Read-LiveCapture $child.StdOutPath | ConvertFrom-Json
                $first.message | Should -BeExactly 'space "quoted" C:\a path\tail\ ; $(Get-Date)'
                $child.Process.HasExited | Should -BeFalse
                [void](Assert-AgentTrustedFile -Path $child.StdOutPath -Private)
            }
            else {
                Start-Sleep -Milliseconds 500
                Test-Path $child.StdOutPath | Should -BeFalse
                $child.Process.HasExited | Should -BeFalse
            }
        }
        finally { Finish-CaptureFixture -Child $child -Root $root }
        if ($Live) {
            $child.StdOutTask.Wait(5000) | Should -BeTrue
            $before = [IO.File]::ReadAllBytes($child.StdOutPath)
        }
        $completed = Complete-AgentRedirectedProcess -Child $child
        $completed.OutputDrained | Should -BeTrue
        $text = [IO.File]::ReadAllText($child.StdOutPath)
        ($text -split '\r?\n')[0] | ConvertFrom-Json | Select-Object -ExpandProperty message |
            Should -BeExactly 'space "quoted" C:\a path\tail\ ; $(Get-Date)'
        $text | Should -Match '"final":"Ω"'
        $text.EndsWith('unterminated Ω') | Should -BeTrue
        if ($Live) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($child.StdOutPath)) | Should -BeExactly ([Convert]::ToBase64String($before)) }
    }

    It 'bounds disk and diagnostic memory, rotates only whole frames, and retains private ACLs and prompt redaction' {
        $root = New-CaptureTestRoot
        $child = Start-CaptureFixture -Root $root -Mode flood
        Finish-CaptureFixture -Child $child -Root $root
        $completed = Complete-AgentRedirectedProcess -Child $child
        $child.StdOutTask.Result.Length | Should -BeLessOrEqual 10MB
        $completed.SafeOutputTail | Should -Not -Match 'private-context-test-sentinel'
        $completed.SafeOutputTail | Should -Match 'operator context block redacted'
        foreach ($path in @($child.StdOutPath, ($child.StdOutPath + '.1'))) {
            (Get-Item $path).Length | Should -BeLessOrEqual 10MB
            [void](Assert-AgentTrustedFile -Path $path -Private)
            $text = [IO.File]::ReadAllText($path)
            $text.EndsWith("`n") | Should -BeTrue
            foreach ($line in ($text -split '\r?\n' | Where-Object { $_.StartsWith('{') })) {
                $record = $line | ConvertFrom-Json
                $record.data.Length | Should -Be 32768
            }
        }
    }

    It 'reports capture I/O and oversized frame failures without blocking or stopping the child (mode=<Mode>)' -ForEach @(
        @{ Mode = 'flood' }, @{ Mode = 'oversized' }
    ) {
        $root = New-CaptureTestRoot
        $child = Start-CaptureFixture -Root $root -Mode $Mode
        if ($Mode -eq 'flood') { New-Item -ItemType Directory -Path ($child.StdOutPath + '.1') | Out-Null }
        Finish-CaptureFixture -Child $child -Root $root
        $captureErrors = @()
        $completed = Complete-AgentRedirectedProcess -Child $child -ErrorVariable captureErrors 2>$null
        $completed.OutputDrained | Should -BeFalse
        ($captureErrors | Out-String) | Should -Match 'live-stdout-capture-failed'
        $child.Process.ExitCode | Should -Be 0
        (Get-Item $child.StdOutPath).Length | Should -BeLessOrEqual 10MB
    }

    It 'refuses existing captures before spawning rather than truncating retained logs' {
        $root = New-CaptureTestRoot
        $path = Join-Path $root 'stdout.jsonl'
        [IO.File]::WriteAllText($path, 'retained')
        { Start-CaptureFixture -Root $root } | Should -Throw
        [IO.File]::ReadAllText($path) | Should -BeExactly 'retained'
    }
}
