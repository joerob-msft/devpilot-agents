BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..").Path
    Import-Module "$repo\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        "$repo\tools\Invoke-DevPilotAgentDispatch.ps1", [ref]$null, [ref]$null)
    foreach ($name in @('Get-ManualTurnKey', 'Test-AutomaticManualPriority', 'Get-AutomaticPollingState',
        'Assert-AutomationRequest', 'Invoke-GetAutomationStatus', 'Invoke-ScanNow', 'Update-AutomaticWorkers',
        'Test-BrokerStartupInputPending')) {
        $fn = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    function Write-DispatchProtocolMessage($Message) { [void]$script:Messages.Add($Message) }
    function Register-BrokerRequestId($Id) { return $script:AcceptRequestId }
    function New-PollingRequest([string]$Operation) {
        @{ schemaVersion = 1; requestId = [Guid]::NewGuid().ToString('D'); operation = $Operation }
    }
    function New-PollingWorker([string]$Role = 'reviewer', [string]$Phase = 'idle', [bool]$Continuous = $true) {
        $process = [pscustomobject]@{ HasExited = $false }
        $process | Add-Member ScriptMethod Refresh {}
        return @{
            Spec = @{ role = $Role; continuous = $Continuous; IntervalSeconds = $(if ($Continuous) { 900 } else { $null })
                arguments = @('-OutputMode', 'Json', '-IntervalSeconds', '900') }
            Phase = $Phase; StartupAcknowledged = $true; ExitConfirmed = $false; FailureCode = ''; ExpectedExit = $false
            WakePending = $false; Sequence = 0; Child = @{ Process = $process }; RepositoryKey = 'v1:github:114'
            PullRequestId = 114; WorkId = [Guid]::NewGuid().ToString('D')
            Secret = New-AgentBrokerAttestationSecret
            Manifest = @{ workerId = [Guid]::NewGuid().ToString('D'); nonce = New-AgentNonce }
        }
    }
    function Set-PollingCheckpoint([hashtable]$Worker, [string]$Phase, [switch]$BadProof) {
        $record = @{
            workerId = $Worker.Manifest.workerId; sequence = $Worker.Sequence + 1; phase = $Phase
            repositoryKey = $Worker.RepositoryKey; pullRequestId = $Worker.PullRequestId; workId = $Worker.WorkId
        }
        $proof = Get-AgentAttestationProof $Worker.Secret $Worker.Manifest.nonce (Get-AgentCanonicalDigest $record)
        if ($BadProof) { $proof = '0' * 64 }
        $Worker['Connect'] = [Threading.Tasks.Task]::FromResult($true)
        $Worker['Read'] = [Threading.Tasks.Task]::FromResult((ConvertTo-AgentCanonicalJson @{ record = $record; proof = $proof }))
        $Worker['Reader'] = [pscustomobject]@{}
        $Worker.Reader | Add-Member ScriptMethod ReadLineAsync { [Threading.Tasks.TaskCompletionSource[string]]::new().Task }
        $Worker['Writer'] = [pscustomobject]@{}
        $Worker.Writer | Add-Member ScriptMethod WriteLine {
            param($Line)
            [void]$script:Replies.Add(($Line | ConvertFrom-Json -AsHashtable))
        }
    }
}

Describe 'Polling and scan-now authority state' {
    BeforeEach {
        $script:Messages = [Collections.Generic.List[object]]::new()
        $script:Replies = [Collections.Generic.List[object]]::new()
        $script:launcherControl = @{ schemaVersion = 1 }
        $script:manualTurns = @{}
        $script:automaticWorkers = @{ reviewer = New-PollingWorker }
        $script:utf8 = [Text.UTF8Encoding]::new($false, $true)
        $script:MaximumLineBytes = 65536
        $script:AcceptRequestId = $true
    }

    It 'reads polling state without changing policy, wake flags, admission, or lifecycle' {
        $worker = $automaticWorkers.reviewer
        $before = ConvertTo-AgentCanonicalJson @{ spec = $worker.Spec; phase = $worker.Phase; wake = $worker.WakePending; sequence = $worker.Sequence }
        1..3 | ForEach-Object { Invoke-GetAutomationStatus (New-PollingRequest 'get-automation-status') }
        $Messages.Count | Should -Be 3
        $Messages[0].agents[0].intervalSeconds | Should -Be 900
        $Messages[0].agents[0].canScanNow | Should -BeTrue
        (ConvertTo-AgentCanonicalJson @{ spec = $worker.Spec; phase = $worker.Phase; wake = $worker.WakePending; sequence = $worker.Sequence }) |
            Should -BeExactly $before
        $manualTurns.Count | Should -Be 0
    }

    It 'sets one current-interval wake, declines repeats, and authenticates the idle-only wake reply' {
        Invoke-ScanNow (New-PollingRequest 'scan-now')
        Invoke-ScanNow (New-PollingRequest 'scan-now')
        $Messages[0].results[0].outcome | Should -Be requested
        $Messages[1].results[0].outcome | Should -Be already-running
        Set-PollingCheckpoint $automaticWorkers.reviewer idle
        @(Update-AutomaticWorkers).Count | Should -Be 0
        $Replies[0].record.action | Should -Be wake
        $automaticWorkers.reviewer.Phase | Should -Be waking
        $automaticWorkers.reviewer.WakePending | Should -BeFalse
        Invoke-ScanNow (New-PollingRequest 'scan-now')
        $Messages[2].results[0].outcome | Should -Be already-running
    }

    It 'discards a late wake at natural expiry rather than forwarding it to the following wait' {
        $worker = $automaticWorkers.reviewer
        Invoke-ScanNow (New-PollingRequest 'scan-now')
        Set-PollingCheckpoint $worker scanning
        Update-AutomaticWorkers
        $Replies[0].record.action | Should -Be proceed
        $worker.WakePending | Should -BeFalse
        Invoke-ScanNow (New-PollingRequest 'scan-now')
        $Messages[1].results[0].outcome | Should -Be already-running
        Set-PollingCheckpoint $worker idle
        Update-AutomaticWorkers
        $Replies[1].record.action | Should -Be proceed
    }

    It 'lets <Phase> manual priority dominate a pending wake even before any repository checkpoint' -ForEach @(
        @{ Phase = 'pending' }, @{ Phase = 'running' }, @{ Phase = 'blocked' }, @{ Phase = 'resuming' }
    ) {
        $worker = $automaticWorkers.reviewer
        $worker.RepositoryKey = ''
        Invoke-ScanNow (New-PollingRequest 'scan-now')
        $manualTurns['v1:github:114|reviewer'] = @{ Phase = $Phase; Summary = @{ role = 'reviewer' } }
        Set-PollingCheckpoint $worker idle
        Update-AutomaticWorkers
        $Replies[0].record.action | Should -Be yield
        $worker.WakePending | Should -BeFalse
        Invoke-ScanNow (New-PollingRequest 'scan-now')
        $Messages[1].results[0].outcome | Should -Be manual-priority
    }

    It 'does not wake stopped, failed, starting, Once or actively scanning workers' {
        foreach ($case in @(
            @{ Phase = 'idle'; Once = $true; Exit = $false; Failure = ''; Startup = $true; Outcome = 'unavailable' },
            @{ Phase = 'started'; Once = $false; Exit = $true; Failure = ''; Startup = $true; Outcome = 'unavailable' },
            @{ Phase = 'failed'; Once = $false; Exit = $false; Failure = 'automatic-worker-failed'; Startup = $true; Outcome = 'unavailable' },
            @{ Phase = 'ready'; Once = $false; Exit = $false; Failure = ''; Startup = $false; Outcome = 'unavailable' },
            @{ Phase = 'scanning'; Once = $false; Exit = $false; Failure = ''; Startup = $true; Outcome = 'already-running' },
            @{ Phase = 'started'; Once = $false; Exit = $false; Failure = ''; Startup = $true; Outcome = 'already-running' }
        )) {
            $worker = New-PollingWorker -Phase $case.Phase -Continuous:(-not $case.Once)
            $worker.ExitConfirmed = $case.Exit; $worker.FailureCode = $case.Failure; $worker.StartupAcknowledged = $case.Startup
            $automaticWorkers.reviewer = $worker
            Invoke-ScanNow (New-PollingRequest 'scan-now')
            $Messages[$Messages.Count - 1].results[0].outcome | Should -Be $case.Outcome
            $worker.WakePending | Should -BeFalse
        }
    }

    It 'does not interpret legacy observation or foreign process records as control authority' {
        $script:launcherControl = $null
        Invoke-GetAutomationStatus (New-PollingRequest 'get-automation-status')
        $Messages[0].available | Should -BeFalse
        $Messages[0].scope | Should -BeNullOrEmpty
        $Messages[0].agents.Count | Should -Be 0
        { Invoke-ScanNow (New-PollingRequest 'scan-now') } | Should -Throw '*automation-unavailable*'
        $automaticWorkers.reviewer.WakePending | Should -BeFalse
    }

    It 'rejects extra authority fields and coerced envelopes without setting a wake' {
        foreach ($field in @('role', 'processId', 'repositoryKey', 'capabilities')) {
            $request = New-PollingRequest 'scan-now'
            $request[$field] = 'caller-selected'
            { Invoke-ScanNow $request } | Should -Throw '*invalid-request*'
        }
        $request = New-PollingRequest 'scan-now'; $request.schemaVersion = '1'
        { Invoke-ScanNow $request } | Should -Throw '*invalid-request*'
        $request = New-PollingRequest 'SCAN-NOW'
        { Invoke-ScanNow $request } | Should -Throw '*invalid-request*'
        $automaticWorkers.reviewer.WakePending | Should -BeFalse
    }

    It 'rejects a bad checkpoint proof and a signed idle transition while work is acquired' {
        $worker = $automaticWorkers.reviewer
        Set-PollingCheckpoint $worker idle -BadProof
        { Update-AutomaticWorkers } | Should -Throw '*checkpoint authentication failed*'
        $worker.Phase = 'acquired'
        Set-PollingCheckpoint $worker idle
        { Update-AutomaticWorkers } | Should -Throw '*idle interval transition is invalid*'
        $Replies.Count | Should -Be 0
    }

    It 'services <Operation> without interrupting pending manual startup' -ForEach @(
        @{ Operation = 'get-automation-status' }, @{ Operation = 'scan-now' }
    ) {
        $manualTurns['v1:github:114|reviewer'] = @{ Phase = 'pending'; Summary = @{ role = 'reviewer' } }
        $script:readTask = [Threading.Tasks.Task]::FromResult((ConvertTo-AgentCanonicalJson (New-PollingRequest $Operation)))
        $script:protocolReader = [pscustomobject]@{ Next = [Threading.Tasks.TaskCompletionSource[string]]::new().Task }
        $protocolReader | Add-Member ScriptMethod ReadLineAsync { $this.Next }
        (Test-BrokerStartupInputPending) | Should -BeFalse
        $Messages.Count | Should -Be 1
        if ($Operation -ceq 'scan-now') { $Messages[0].results[0].outcome | Should -Be manual-priority }
        $automaticWorkers.reviewer.WakePending | Should -BeFalse
    }

    It 'preserves EOF, cancellation, malformed requests and replayed IDs for the existing startup guard' {
        foreach ($line in @($null, '{bad json', (ConvertTo-AgentCanonicalJson (New-PollingRequest 'cancel-queued')))) {
            $inputTask = [Threading.Tasks.TaskCompletionSource[string]]::new()
            $inputTask.SetResult($line)
            $script:readTask = $inputTask.Task
            (Test-BrokerStartupInputPending) | Should -BeTrue
        }
        $script:AcceptRequestId = $false
        $script:readTask = [Threading.Tasks.Task]::FromResult((ConvertTo-AgentCanonicalJson (New-PollingRequest 'get-automation-status')))
        (Test-BrokerStartupInputPending) | Should -BeTrue
        $Messages.Count | Should -Be 0
    }

    It 'keeps harness checkpoints void and refuses wake outside idle or with a bad proof' {
        & (Get-Module DevPilot.AgentHarness) {
            foreach ($scenario in @('idle', 'scanning', 'bad-proof')) {
                $secret = New-AgentBrokerAttestationSecret
                $nonce = New-AgentNonce
                $id = [Guid]::NewGuid().ToString('D')
                $reply = @{ workerId = $id; sequence = 1; action = 'wake' }
                $proof = Get-AgentAttestationProof $secret $nonce (Get-AgentCanonicalDigest $reply)
                if ($scenario -ceq 'bad-proof') { $proof = '0' * 64 }
                $reader = [pscustomobject]@{ Line = (ConvertTo-AgentCanonicalJson @{ record = $reply; proof = $proof }) }
                $reader | Add-Member ScriptMethod ReadLineAsync { [Threading.Tasks.Task]::FromResult($this.Line) }
                $writer = [pscustomobject]@{}
                $writer | Add-Member ScriptMethod WriteLine { param($Line) }
                $script:AgentLauncherWorker = @{
                    Secret = $secret; Manifest = @{ workerId = $id; nonce = $nonce }
                    Reader = $reader; Writer = $writer; Sequence = 0; Lease = $null; State = $null
                    RepositoryKey = ''; PullRequestId = 0; WorkId = ''; WakeCurrentWait = $false
                }
                try {
                    if ($scenario -ceq 'idle') {
                        @(Invoke-AgentLauncherCheckpoint idle).Count | Should -Be 0
                        $script:AgentLauncherWorker.WakeCurrentWait | Should -BeTrue
                    }
                    else {
                        { Invoke-AgentLauncherCheckpoint $(if ($scenario -ceq 'scanning') { 'scanning' } else { 'idle' }) } |
                            Should -Throw '*launcher-control-invalid*'
                        $script:AgentLauncherWorker.WakeCurrentWait | Should -BeFalse
                    }
                }
                finally { [Array]::Clear($secret, 0, $secret.Length); $script:AgentLauncherWorker = $null }
            }
        }
    }
}

Describe 'Real isolated polling workers without Watch or model providers' -Skip:(-not $IsWindows) {
    It 'runs the owned polling protocol for <Mode>' -ForEach @(
        @{ Mode = 'wake' }, @{ Mode = 'natural' }, @{ Mode = 'once' }, @{ Mode = 'unavailable' }
        @{ Mode = 'manual-next' }, @{ Mode = 'manual-replace' }
        @{ Mode = 'manual-poll' }
    ) {
        $root = Resolve-AgentTrustedRoot -Path (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))) `
            -Kind watch-state -RepositoryRoot $repo -Create
        $toolkit = Join-Path $root 'toolkit'
        $dashboard = Join-Path $toolkit 'src\DevPilot.Dashboard'
        New-Item -ItemType Directory -Path "$toolkit\tools", "$toolkit\config", "$toolkit\src\Agents\reviewer",
            "$toolkit\src\Agents\review-handler", "$dashboard\node_modules\bun\bin", "$dashboard\dist\src" -Force | Out-Null
        Copy-Item "$repo\src\DevPilot.AgentHarness" "$toolkit\src" -Recurse
        Add-Content "$toolkit\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1" `
            (Get-Content "$PSScriptRoot\fixtures\SchedulingProvider.ps1" -Raw)
        Copy-Item "$repo\tools\Invoke-DevPilotAgentDispatch.ps1" "$toolkit\tools"
        foreach ($pair in @(@('reviewer', 'Start-ReviewerAgent.ps1'), @('review-handler', 'Start-ReviewHandlerAgent.ps1'))) {
            Copy-Item "$PSScriptRoot\fixtures\AutomationPollingWorker.ps1" "$toolkit\src\Agents\$($pair[0])\$($pair[1])"
            Copy-Item "$PSScriptRoot\fixtures\LauncherWorkerChild.ps1" "$toolkit\src\Agents\$($pair[0])\ManualFixture.ps1"
        }
        $config = @{ provider = 'GitHub'; repository = @{ organization = 'scheduling-fixture'; name = 'repository' }
            testMode = $Mode; testRole = 'reviewer' }
        $config | ConvertTo-Json -Depth 5 | Set-Content "$toolkit\config\agent.json"
        $config | ConvertTo-Json -Depth 5 | Set-Content "$root\scenario.json"
        Copy-Item "$repo\src\DevPilot.Dashboard\node_modules\bun\bin\bun.exe" "$dashboard\node_modules\bun\bin"
        Copy-Item "$repo\src\DevPilot.Dashboard\src\dispatch.ts", "$repo\src\DevPilot.Dashboard\src\domain.ts" "$dashboard\dist\src"
        Copy-Item "$PSScriptRoot\fixtures\automation-polling-client.mjs" "$dashboard\dist\src\index.js"
        $result = Invoke-TimedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', "$PSScriptRoot\fixtures\AutomationPollingLauncher.ps1",
            '-Root', $root, '-Toolkit', $toolkit, '-Mode', $Mode
        ) -CaptureStdOut -CaptureStdErr -TimeoutSeconds 90
        $diagnostics = @("$root\broker.log", "$root\watch\reviewer.stderr.log", "$root\watch\review-handler.stderr.log") |
            Where-Object { Test-Path $_ } | ForEach-Object { Get-Content $_ -Tail 8 }
        $result.TimedOut | Should -BeFalse
        $result.ExitCode | Should -Be 0 -Because "$($result.StdErr)`n$($diagnostics -join "`n")"
        (Test-Path "$root\verified") | Should -BeTrue
    }
}
