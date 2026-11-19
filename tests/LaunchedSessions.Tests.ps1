BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
}

Describe 'Pre-assigned cycle session IDs' {
    It 'passes --session-id for a new session and never when resuming' {
        $id = [guid]::NewGuid().ToString()
        $fresh = Get-AgentCopilotArgs -SessionName '[DevPilot] Reviewer cycle PR 7' -NewSessionId $id
        $fresh | Should -Contain "--session-id=$id"
        $fresh | Should -Contain '--name=[DevPilot] Reviewer cycle PR 7'
        $fresh.IndexOf('--') | Should -BeLessThan $fresh.IndexOf("--session-id=$id")

        $resume = Get-AgentCopilotArgs -ResumeSessionId ([guid]::NewGuid().ToString()) -NewSessionId $id
        ($resume | Where-Object { $_ -like '--session-id*' }) | Should -BeNullOrEmpty
        { Get-AgentCopilotArgs -NewSessionId 'not-a-guid' } | Should -Throw
    }

    It 'records bounded IDs and reads them from sibling state folders' {
        $watch = Join-Path $TestDrive 'watch'
        $reviewer = Join-Path $watch 'reviewer'
        $handler = Join-Path $watch 'review-handler'
        New-Item -ItemType Directory -Force -Path $reviewer, $handler | Out-Null
        $ids = 1..5 | ForEach-Object { [guid]::NewGuid().ToString() }
        foreach ($id in $ids) { Add-AgentHarnessLaunchedSessionId -StateDir $reviewer -SessionId $id -MaxEntries 3 }

        $own = Get-AgentHarnessLaunchedSessionIds -StateDir $handler
        $own | Should -BeNullOrEmpty
        $all = Get-AgentHarnessLaunchedSessionIds -StateDir $handler -IncludeSiblings
        $all.Count | Should -Be 3
        $all | Should -Not -Contain $ids[0]
        $all | Should -Contain $ids[4]
    }

    It 'excludes recorded cycle sessions from coding-session resolution' {
        $root = Join-Path $TestDrive 'session-state'
        $cycleId = [guid]::NewGuid().ToString()
        $codingId = [guid]::NewGuid().ToString()
        foreach ($id in @($cycleId, $codingId)) {
            $dir = Join-Path $root $id
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'workspace.yaml') -Value @("id: $id", 'branch: feature/x', 'updated_at: 2026-11-17T00:00:00Z')
        }
        $state = Join-Path $TestDrive 'handler-state'
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        Add-AgentHarnessLaunchedSessionId -StateDir $state -SessionId $cycleId

        $found = @(Find-CopilotSessionForBranch -Branch 'feature/x' -SessionStateRoot $root `
                -ExcludeSessionIds (Get-AgentHarnessLaunchedSessionIds -StateDir $state))
        $found.SessionId | Should -Be @($codingId)
    }
}
