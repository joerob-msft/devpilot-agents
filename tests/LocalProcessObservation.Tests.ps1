BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    $path = Join-Path $PSScriptRoot '..\tools\Invoke-DevPilotAgentDispatch.ps1'
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-LocalWatchObservation'
    }, $false)
    . ([ScriptBlock]::Create($function.Extent.Text))
}

Describe 'local watch observation provenance' {
    BeforeEach {
        $script:root = Join-Path $TestDrive 'watch'
        $script:descriptor = @{
            ownerProcessId = $PID
            localObservation = @{
                schemaVersion = 1
                ownerStartIdentity = 'utc:1234'
                streams = @(@{
                    role = 'reviewer'; processId = 42
                    eventLogPath = (Join-Path $script:root 'reviewer.stdout.jsonl')
                })
            }
        }
        Mock Get-AgentImmediateParentProcessId {
            param($ProcessId)
            if ($ProcessId -eq $PID) { return $PID + 1 }
            return $PID
        }
        Mock Get-AgentProcessStartIdentity { 'utc:1234' }
        Mock Assert-AgentTrustedFile {
            param($Path, $AllowedRoot, $ExpectedPath)
            if ($Path -cne $ExpectedPath) { throw 'unexpected capture path' }
            return $Path
        }
    }

    It 'reports only the actual current launch owned capture without checking whether its child is still alive' {
        $result = Get-LocalWatchObservation -Descriptor $descriptor -StateRoot $root -DashboardProvenance
        $result.operation | Should -BeExactly 'local-observation'
        @($result.streams).Count | Should -Be 1
        $result.streams[0].processId | Should -Be 42
        $result.streams[0].eventLogPath | Should -BeExactly (Join-Path $root 'reviewer.stdout.jsonl')
        Should -Invoke Get-AgentImmediateParentProcessId -Times 2 -Exactly
        Should -Invoke Assert-AgentTrustedFile -Times 1 -Exactly
    }

    It 'never infers local origin for ordinary headless, old, copied or attach descriptors' {
        Get-LocalWatchObservation -Descriptor $descriptor -StateRoot $root | Should -BeNullOrEmpty
        $descriptor.Remove('localObservation')
        Get-LocalWatchObservation -Descriptor $descriptor -StateRoot $root -DashboardProvenance | Should -BeNullOrEmpty
        Should -Invoke Get-AgentImmediateParentProcessId -Times 0 -Exactly
    }

    It 'rejects a claimed owner that is not the actual launcher' {
        $descriptor.ownerProcessId = $PID + 10
        Get-LocalWatchObservation -Descriptor $descriptor -StateRoot $root -DashboardProvenance | Should -BeNullOrEmpty
        Should -Invoke Assert-AgentTrustedFile -Times 0 -Exactly
    }

    It 'rejects a reused owner PID with a different process start identity' {
        Mock Get-AgentProcessStartIdentity { 'utc:5678' }
        Get-LocalWatchObservation -Descriptor $descriptor -StateRoot $root -DashboardProvenance | Should -BeNullOrEmpty
        Should -Invoke Assert-AgentTrustedFile -Times 0 -Exactly
    }

    It 'rejects empty process start identity even if both sources are unavailable' {
        $descriptor.localObservation.ownerStartIdentity = ''
        Mock Get-AgentProcessStartIdentity { '' }
        Get-LocalWatchObservation -Descriptor $descriptor -StateRoot $root -DashboardProvenance | Should -BeNullOrEmpty
    }

    It 'rejects duplicate role captures' {
        $descriptor.localObservation.streams = @($descriptor.localObservation.streams[0], $descriptor.localObservation.streams[0])
        Get-LocalWatchObservation -Descriptor $descriptor -StateRoot $root -DashboardProvenance | Should -BeNullOrEmpty
    }

    It 'keeps observations unavailable when OS or file provenance cannot be read' -ForEach @(
        @{ Command = 'Get-AgentImmediateParentProcessId' },
        @{ Command = 'Get-AgentProcessStartIdentity' },
        @{ Command = 'Assert-AgentTrustedFile' }
    ) {
        Mock $Command { throw 'access denied' }
        Get-LocalWatchObservation -Descriptor $descriptor -StateRoot $root -DashboardProvenance | Should -BeNullOrEmpty
    }

    It 'rejects arbitrary paths, unknown roles and unsafe process IDs in startup metadata' {
        foreach ($change in @(
            @{ field = 'eventLogPath'; value = (Join-Path $root 'copied.jsonl') },
            @{ field = 'role'; value = 'other' },
            @{ field = 'processId'; value = -1 },
            @{ field = 'processId'; value = '42' }
        )) {
            $copy = $descriptor | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
            $copy.localObservation.streams[0][$change.field] = $change.value
            Get-LocalWatchObservation -Descriptor $copy -StateRoot $root -DashboardProvenance | Should -BeNullOrEmpty
        }
    }
}
