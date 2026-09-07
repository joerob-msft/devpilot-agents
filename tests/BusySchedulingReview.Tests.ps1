BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..").Path
    Import-Module "$repo\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        "$repo\tools\Invoke-DevPilotAgentDispatch.ps1", [ref]$null, [ref]$null)
    foreach ($name in @('Get-OptionalMember', 'Write-Rejection', 'Get-ManualTurnKey', 'Get-TurnProgressRecords',
        'Add-DeferredTurnProgress', 'Complete-ManualTurn', 'Update-ManualTurns', 'Update-AutomaticWorkers',
        'Stop-BrokerForAutomaticFailure', 'Write-RunProgress')) {
        $function = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    function Write-DispatchProtocolMessage($Message) { [void]$script:Messages.Add($Message) }
    function Remove-ScheduleDraft($Summary) {}
    function Test-RunAuthorityAvailable($Summary) { return $script:AuthorityAvailable }
    function Complete-AgentRedirectedProcess($Child) { throw 'Fixture completion must be configured.' }
    function Test-AgentProcessContainmentExited($Containment, $Process) { throw 'Fixture containment must be configured.' }
    function Close-AgentProcessContainment($Containment) {}
    function Start-AutomaticWorker($Spec) {
        $script:AutomaticRestarts++
        $script:automaticWorkers[$Spec.role] = @{
            Spec = $Spec; ExitConfirmed = $false; Phase = 'starting'; StartupAcknowledged = $false
            Manifest = @{ workerId = [guid]::NewGuid().ToString() }; FailureCode = ''
        }
    }
    function New-TestTurn([string]$Id, [string]$DispatchId = '') {
        return @{
            QueueId = $Id; RequestId = $Id; DispatchId = $DispatchId; Phase = 'running'; Progress = ''; Code = ''
            Summary = @{ role = 'reviewer'; repositoryIdentity = @{ key = 'v1:github:114' }; prSnapshot = @{ pullRequestId = 116 } }
            DeferredProgress = @(); Predecessor = $null
        }
    }
}

Describe 'Reviewed scheduler ownership and startup regressions' {
    BeforeEach {
        $script:Messages = [Collections.Generic.List[object]]::new()
        $script:manualTurns = @{}
        $script:automaticWorkers = @{}
        $script:children = @{}
        $script:runPreparations = @{}
        $script:AutomaticRestarts = 0
        $script:AuthorityAvailable = $false
        $script:key = 'v1:github:114|reviewer'
    }

    It 'restores predecessor after <Outcome> (predecessor already exited=<Exited>) and holds through lock release and startup acknowledgement' -ForEach @(
        @{ Outcome = 'cancel'; Exited = $false }, @{ Outcome = 'expiry'; Exited = $false }
        @{ Outcome = 'cancel'; Exited = $true }, @{ Outcome = 'expiry'; Exited = $true }
    ) {
        $predecessor = New-TestTurn ([guid]::NewGuid().ToString()) ([guid]::NewGuid().ToString())
        $successor = New-TestTurn ([guid]::NewGuid().ToString())
        $successor.Phase = 'pending'
        $successor.Predecessor = $predecessor
        $successor['Conflict'] = @{ kind = 'manual'; workId = $predecessor.DispatchId }
        $successor['Mode'] = 'next'
        $successor['Cancelled'] = $Outcome -ceq 'cancel'
        $successor['Expires'] = if ($Outcome -ceq 'expiry') { [DateTime]::UtcNow.AddSeconds(-1) } else { [DateTime]::UtcNow.AddMinutes(5) }
        $script:manualTurns[$key] = $successor
        if (-not $Exited) { $script:children[$predecessor.DispatchId] = @{ Owned = $true } }
        $script:automaticWorkers.reviewer = @{
            Spec = @{ role = 'reviewer' }; ExitConfirmed = $true; Phase = 'yielding'
            StartupAcknowledged = $true; FailureCode = ''
        }

        Update-ManualTurns
        [object]::ReferenceEquals($manualTurns[$key], $predecessor) | Should -BeTrue
        $AutomaticRestarts | Should -Be 0
        @($Messages | Where-Object state -EQ resumed).Count | Should -Be 0
        $manualTurns[$key].DeferredProgress[0].QueueId | Should -Be $successor.QueueId

        $script:children.Clear()
        Update-ManualTurns
        $AutomaticRestarts | Should -Be 0 -Because 'tree exit alone is not an independent authority-release observation'
        $script:AuthorityAvailable = $true
        Update-ManualTurns
        $AutomaticRestarts | Should -Be 1
        $manualTurns[$key].Phase | Should -Be resuming
        @($Messages | Where-Object state -EQ resumed).Count | Should -Be 0

        $automaticWorkers.reviewer.StartupAcknowledged = $true
        Complete-ManualTurn $key $manualTurns[$key]
        $manualTurns.ContainsKey($key) | Should -BeFalse
        @($Messages | Where-Object { $_.state -ceq 'resumed' -and $_.queueId -ceq $successor.QueueId }).Count | Should -Be 1
    }

    It 'preserves and classifies automatic exit <ExitCode> (started=<Started>, continuous=<Continuous>, yielding=<Yielding>)' -ForEach @(
        @{ ExitCode = 17; Started = $false; Continuous = $true; Yielding = $false; Code = 'automatic-startup-failed' }
        @{ ExitCode = 0; Started = $false; Continuous = $false; Yielding = $false; Code = 'automatic-startup-failed' }
        @{ ExitCode = 17; Started = $true; Continuous = $true; Yielding = $false; Code = 'automatic-worker-failed' }
        @{ ExitCode = 0; Started = $true; Continuous = $true; Yielding = $false; Code = 'automatic-worker-failed' }
        @{ ExitCode = 0; Started = $true; Continuous = $false; Yielding = $false; Code = '' }
        @{ ExitCode = 1; Started = $true; Continuous = $true; Yielding = $true; Code = '' }
    ) {
        $script:ExitCode = $ExitCode
        Mock Complete-AgentRedirectedProcess { @{ ExitCode = $script:ExitCode; SafeErrorTail = 'private fixture diagnostics' } }
        Mock Test-AgentProcessContainmentExited { $true }
        Mock Close-AgentProcessContainment {}
        $process = [pscustomobject]@{ HasExited = $true; ExitCode = $ExitCode }
        $process | Add-Member ScriptMethod Refresh {}
        $pipe = [pscustomobject]@{}
        $pipe | Add-Member ScriptMethod Dispose {}
        $entry = @{
            Spec = @{ role = 'reviewer'; continuous = $Continuous }; Child = @{ Process = $process }
            Containment = @{}; Pipe = $pipe; Secret = [byte[]]::new(32); ExitConfirmed = $false
            StartupAcknowledged = $Started; ExpectedExit = $false; Phase = $(if ($Yielding) { 'yielding' } else { 'starting' })
            FailureCode = ''; ExitResult = $null
        }
        $automaticWorkers.reviewer = $entry
        $turn = New-TestTurn ([guid]::NewGuid().ToString())
        $turn.Phase = 'resuming'
        $manualTurns[$key] = $turn
        if ($Code) { { Update-AutomaticWorkers } | Should -Throw "*$Code*" }
        else { Update-AutomaticWorkers }
        $entry.ExitResult.ExitCode | Should -Be $ExitCode
        $entry.ExitConfirmed | Should -BeTrue
        $AutomaticRestarts | Should -Be 0
        @($Messages | Where-Object state -EQ resumed).Count | Should -Be 0
        if ($Code) {
            $entry.FailureCode | Should -Be $Code
            $turn.Phase | Should -Be blocked
            @($Messages | Where-Object { $_.operation -ceq 'rejected' -and $_.code -ceq $Code }).Count | Should -Be 1
            ($Messages | ConvertTo-Json -Depth 8) | Should -Not -Match 'private fixture diagnostics'
        }
        else { $Messages.Count | Should -Be 0 }
    }

    It 'does not release ownership when only the leader has exited' {
        Mock Test-AgentProcessContainmentExited { $false }
        Mock Complete-AgentRedirectedProcess { throw 'Uncertain tree must not be completed.' }
        $process = [pscustomobject]@{ HasExited = $true; ExitCode = 17 }
        $process | Add-Member ScriptMethod Refresh {}
        $entry = @{
            Spec = @{ role = 'reviewer'; continuous = $true }
            Child = @{ Process = $process }; Containment = @{}; ExitConfirmed = $false; StartupAcknowledged = $false
            StartupDeadline = [DateTime]::UtcNow.AddMinutes(1); Deadline = [DateTime]::UtcNow.AddMinutes(1)
            Connect = [Threading.Tasks.TaskCompletionSource[bool]]::new().Task
        }
        $automaticWorkers.reviewer = $entry
        { Update-AutomaticWorkers } | Should -Throw '*automatic-startup-failed*'
        $entry.ExitConfirmed | Should -BeFalse
        $entry.LeaderExitCode | Should -Be 17
        @($Messages | Where-Object operation -EQ rejected).Count | Should -Be 1
        $Messages[0].detail | Should -Match 'contained-tree exit remains unconfirmed'
    }
}
