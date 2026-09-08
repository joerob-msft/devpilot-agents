BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
}

Describe 'WorkIQ empty-error structured envelope compatibility' {
    BeforeEach {
        $script:session = @{ Response = $null }
        Mock Send-AgentMcpRequest -ModuleName DevPilot.AgentHarness { param($Session) return $Session.Response }
    }

    It 'retains HTTP <Status> metadata from an isError envelope with empty content' -ForEach @(
        @{ Status = 400 }, @{ Status = 429 }
    ) {
        $session.Response = [pscustomobject]@{
            isError = $true; content = @()
            structuredContent = [pscustomobject]@{ results = @([pscustomobject]@{
                statusCode = $Status; data = $null; headers = [pscustomobject]@{ 'Retry-After' = '3' }
                error = [pscustomobject]@{ message = 'synthetic private provider details'; code = 'BadRequest' }
            }) }
        }
        try {
            $null = Invoke-AgentWorkIqTool -Session $session -Name fetch -Arguments @{ entityUrls = @('/teams/fixture/channels/channel/messages/root') }
            throw 'Expected provider rejection.'
        }
        catch {
            $_.Exception | Should -BeOfType ([InvalidOperationException])
            $_.Exception.Data['WorkIqStatusCode'] | Should -Be $Status
            $_.Exception.Data['WorkIqRetryAfter'] | Should -BeExactly '3'
            $_.Exception.Message | Should -Not -Match 'private|provider details|Index|outside'
        }
    }

    It 'does not treat isError plus HTTP 201 and a valid id as success' {
        $session.Response = [pscustomobject]@{
            isError = $true; content = @(); structuredContent = [pscustomobject]@{
                statusCode = 201; data = [pscustomobject]@{ id = 'root-id' }; error = 'synthetic details'
            }
        }
        { Invoke-AgentWorkIqTool -Session $session -Name create_entity -Arguments @{ parentUrl = '/teams/fixture/channels/channel/messages' } } |
            Should -Throw
    }

    It 'fails safely when error content and structured metadata are both absent' {
        $session.Response = [pscustomobject]@{ isError = $true; content = @() }
        $failure = $null
        try {
            Invoke-AgentWorkIqTool -Session $session -Name fetch -Arguments @{ entityUrls = @('/me') }
        }
        catch { $failure = $_.Exception }
        $failure | Should -Not -BeNullOrEmpty
        $failure.Message | Should -Match 'structuredContent'
        $failure.Message | Should -Not -Match 'Index'
        $failure.Data.Contains('WorkIqStatusCode') | Should -BeFalse
    }

    It 'never coerces malformed status or error flags into validated transport metadata' -ForEach @(
        @{ Status = '429'; Flag = $true }, @{ Status = 429; Flag = 'true' }, @{ Status = $true; Flag = $true }
    ) {
        $session.Response = [pscustomobject]@{
            isError = $Flag; content = @(); structuredContent = [pscustomobject]@{ statusCode = $Status; data = $null }
        }
        $failure = $null
        try { Invoke-AgentWorkIqTool -Session $session -Name fetch -Arguments @{ entityUrls = @('/me') } }
        catch { $failure = $_.Exception }
        $failure | Should -Not -BeNullOrEmpty
        $failure.Data.Contains('WorkIqStatusCode') | Should -BeFalse
    }

    It 'does not manufacture retry metadata from error prose or unsafe header text' -ForEach @(
        @{ Header = $null }, @{ Header = "1`r`nInjected: true" }, @{ Header = ('1' * 129) }
    ) {
        $entry = [pscustomobject]@{ statusCode = 429; data = $null; error = 'Retry after 1 second, synthetic provider prose.' }
        if ($null -ne $Header) { $entry | Add-Member headers ([pscustomobject]@{ 'Retry-After' = $Header }) }
        $session.Response = [pscustomobject]@{ isError = $true; content = @(); structuredContent = $entry }
        $failure = $null
        try { Invoke-AgentWorkIqTool -Session $session -Name fetch -Arguments @{ entityUrls = @('/me') } }
        catch { $failure = $_.Exception }
        $failure | Should -Not -BeNullOrEmpty
        $failure.Data['WorkIqStatusCode'] | Should -Be 429
        $failure.Data.Contains('WorkIqRetryAfter') | Should -BeFalse
        $failure.Message | Should -Not -Match 'Retry after|provider prose|Injected'
    }
}
