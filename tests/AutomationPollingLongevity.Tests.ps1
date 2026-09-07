BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..").Path
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        "$repo\tools\Invoke-DevPilotAgentDispatch.ps1", [ref]$null, [ref]$null)
    foreach ($name in @('Register-BrokerRequestId', 'Test-AutomaticManualPriority', 'Get-AutomaticPollingState',
        'Assert-AutomationRequest', 'Invoke-GetAutomationStatus')) {
        $fn = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    function Write-DispatchProtocolMessage($Message) {
        $script:ResponseCount++
        $script:LastResponse = $Message
    }
}

Describe 'Periodic automation polling has no lifetime request budget' {
    It 'rotates bounded read history without evicting mutation IDs or allocating dispatch state' {
        $script:requestIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $script:requestIdOrder = [Collections.Generic.Queue[string]]::new()
        $script:pollRequestIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $script:pollRequestIdOrder = [Collections.Generic.Queue[string]]::new()
        # Accelerate sixteen full retention windows without a clock or a slow polling interval.
        $script:MaxTrackedRequestIds = 64
        $script:ResponseCount = 0
        $script:LastResponse = $null
        $script:launcherControl = @{ schemaVersion = 1 }
        $script:drafts = @{}
        $script:runPreparations = @{}
        $script:manualTurns = @{}
        $script:children = @{}
        $script:narrowingPreviews = @{}
        $script:automaticWorkers = @{ reviewer = @{
            Spec = @{ role = 'reviewer'; continuous = $true; IntervalSeconds = 900 }
            Phase = 'idle'; StartupAcknowledged = $true; ExitConfirmed = $false; FailureCode = ''
            ExpectedExit = $false; WakePending = $false; Child = @{ Process = @{ HasExited = $false } }
        } }
        $protected = 1..3 | ForEach-Object { [Guid]::NewGuid().ToString('D') }
        foreach ($id in $protected) { (Register-BrokerRequestId $id) | Should -BeTrue }
        for ($index = 0; $index -lt 1024; $index++) {
            $pollId = [Guid]::NewGuid().ToString('D')
            if (-not (Register-BrokerRequestId $pollId -AutomationPoll)) { throw 'A fresh poll hit a lifetime budget.' }
            Invoke-GetAutomationStatus @{ schemaVersion = 1; requestId = $pollId; operation = 'get-automation-status' }
        }
        $ResponseCount | Should -Be 1024
        $LastResponse.available | Should -BeTrue
        $LastResponse.agents[0].canScanNow | Should -BeTrue
        $requestIds.Count | Should -Be 3
        $requestIdOrder.Count | Should -Be 3
        $pollRequestIds.Count | Should -Be $MaxTrackedRequestIds
        $pollRequestIdOrder.Count | Should -Be $MaxTrackedRequestIds
        foreach ($id in $protected) {
            (Register-BrokerRequestId $id) | Should -BeFalse
            (Register-BrokerRequestId $id -AutomationPoll) | Should -BeFalse
        }
        (Register-BrokerRequestId $pollId) | Should -BeFalse
        (Register-BrokerRequestId $pollId -AutomationPoll) | Should -BeFalse
        foreach ($table in @($drafts, $runPreparations, $manualTurns, $children, $narrowingPreviews)) {
            $table.Count | Should -Be 0
        }
        $automaticWorkers.reviewer.WakePending | Should -BeFalse
        # Explicit operations keep their original bounded eviction policy.
        1..128 | ForEach-Object { [void](Register-BrokerRequestId ([Guid]::NewGuid().ToString('D'))) }
        $requestIds.Count | Should -Be $MaxTrackedRequestIds
        $requestIdOrder.Count | Should -Be $MaxTrackedRequestIds
    }
}
