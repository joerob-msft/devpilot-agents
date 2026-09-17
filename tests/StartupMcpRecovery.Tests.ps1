function Open-AgentMcpSession {
    param([string]$AgencyPath, [string]$Server, [string]$Organization, [string[]]$Toolsets,
        [int]$TimeoutSeconds, [string[]]$EnvironmentVariablesToRemove)
}
function Close-AgentMcpSession { param([hashtable]$Session) }
function New-AgentProviderContext {
    param([string]$Provider, [string]$Organization, [string]$Project, [string]$RepositoryName,
        [string]$RepositoryId, [scriptblock]$McpInvoker, [int]$TimeoutSeconds)
}
function Resolve-AgentProviderRepositoryIdentity { param([hashtable]$Context) }
function Invoke-AgentMcpTool {
    param([hashtable]$Session, [string]$Name, [hashtable]$Arguments, [switch]$RawText)
}
function Send-ReviewerEvent {
    param([string]$EventType, [string]$Level, [int]$Cycle, [int]$PrId,
        [string]$SourceCommit, [hashtable]$Data, [string]$Message)
}
function Send-HandlerEvent {
    param([string]$EventType, [string]$Level, [int]$Cycle, [int]$PrId,
        [string]$SourceCommit, [hashtable]$Data, [string]$Message)
}

Describe '<Role> startup repository MCP recovery' -ForEach @(
    @{
        Role = 'reviewer'
        ScriptName = 'Start-ReviewerAgent.ps1'
        ResolveFunction = 'Resolve-ReviewerStartupRepositoryIdentity'
        RecoverFunction = 'Test-ReviewerRecoverableMcpFailure'
        EventFunction = 'Send-ReviewerEvent'
    }
    @{
        Role = 'review-handler'
        ScriptName = 'Start-ReviewHandlerAgent.ps1'
        ResolveFunction = 'Resolve-HandlerStartupRepositoryIdentity'
        RecoverFunction = 'Test-HandlerRecoverableMcpFailure'
        EventFunction = 'Send-HandlerEvent'
    }
) {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
        function Send-ReviewerEvent {
            param([string]$EventType, [string]$Level, [int]$Cycle, [int]$PrId,
                [string]$SourceCommit, [hashtable]$Data, [string]$Message)
        }
        function Send-HandlerEvent {
            param([string]$EventType, [string]$Level, [int]$Cycle, [int]$PrId,
                [string]$SourceCommit, [hashtable]$Data, [string]$Message)
        }
        $path = (Resolve-Path "$PSScriptRoot\..\src\Agents\$Role\$ScriptName").Path
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        foreach ($name in @($RecoverFunction, $ResolveFunction)) {
            $definition = $ast.Find({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $name
                }, $true)
            if (-not $definition) { throw "Function '$name' was not found." }
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $script:resolveFunction = $ResolveFunction
        $script:eventFunction = $EventFunction
        $script:source = Get-Content -LiteralPath $path -Raw
    }

    BeforeEach {
        $script:Organization = 'example-org'
        $script:ExpectedProject = 'ExampleProject'
        $script:RepositoryName = 'example-repository'
        $script:cfgRepoId = '11111111-1111-1111-1111-111111111111'
        $script:provider = 'AzureDevOps'
        $script:McpSensitiveEnvironmentVariables = @()
        $script:ReviewerOutputContext = @{ Agent = 'reviewer' }
        $script:HandlerOutputContext = @{ Agent = 'review-handler' }
        $script:LauncherWorkerManifest = ''
        $script:openCount = 0
        $script:resolveCount = 0
        $script:closeCount = 0
        $script:failure = 'Agent MCP response timed out.'

        Mock Open-AgentMcpSession {
            $script:openCount++
            @{ Process = [pscustomobject]@{ Alive = $true }; Id = $script:openCount }
        }
        Mock Close-AgentMcpSession { $script:closeCount++ }
        Mock New-AgentProviderContext {
            param($McpInvoker)
            @{ McpInvoker = $McpInvoker }
        }
        Mock Resolve-AgentProviderRepositoryIdentity {
            $script:resolveCount++
            if ($script:resolveCount -le $script:failCount) { throw $script:failure }
            @{ verified = $true; key = 'v1:azuredevops:11111111-1111-1111-1111-111111111111' }
        }
        Mock Write-Warning {}
        Mock Send-AgentLauncherWorkerStartupRetry {}
        Mock Wait-AgentLauncherStartupRetry {}
        Mock $script:eventFunction {}
    }

    It 'retries one transport timeout with a fresh session and succeeds' {
        $script:failCount = 1

        $identity = & $script:resolveFunction -AgencyPath 'agency.exe'

        $identity.verified | Should -BeTrue
        $script:openCount | Should -Be 2
        $script:closeCount | Should -Be 2
        Should -Invoke $script:eventFunction -Times 1 -ParameterFilter {
            $EventType -eq 'delivery.retrying' -and
            $Data.reason -eq 'Agent MCP response timed out.' -and
            $Data.nextRetry -eq 'immediate fresh ADO session' -and
            $Data.attempt -eq 2 -and $Data.retryDelaySeconds -eq 0
        }
        Should -Invoke Send-AgentLauncherWorkerStartupRetry -Times 0
        Should -Invoke Wait-AgentLauncherStartupRetry -Times 0
    }

    It 'fails after one retry when both sessions time out' {
        $script:failCount = 2

        { & $script:resolveFunction -AgencyPath 'agency.exe' } |
            Should -Throw 'Agent MCP response timed out.'

        $script:openCount | Should -Be 2
        $script:closeCount | Should -Be 2
        Should -Invoke $script:eventFunction -Times 1 -ParameterFilter {
            $EventType -eq 'delivery.retrying'
        }
    }

    It 'keeps retrying recoverable automatic startup failures with capped staggered backoff' {
        $script:LauncherWorkerManifest = 'worker.json'
        $script:failCount = 3

        $identity = & $script:resolveFunction -AgencyPath 'agency.exe'

        $identity.verified | Should -BeTrue
        $script:openCount | Should -Be 4
        $script:closeCount | Should -Be 4
        $expectedDelays = if ($Role -eq 'reviewer') { @(5, 15, 30) } else { @(8, 18, 36) }
        Should -Invoke Send-AgentLauncherWorkerStartupRetry -Times 3 -Exactly
        Should -Invoke Wait-AgentLauncherStartupRetry -Times 3 -Exactly
        for ($index = 0; $index -lt $expectedDelays.Count; $index++) {
            $attempt = $index + 1
            $delay = $expectedDelays[$index]
            Should -Invoke Send-AgentLauncherWorkerStartupRetry -Times 1 -Exactly -ParameterFilter {
                $Attempt -eq $attempt -and $DelaySeconds -eq $delay
            }
            Should -Invoke Wait-AgentLauncherStartupRetry -Times 1 -Exactly -ParameterFilter {
                $Seconds -eq $delay
            }
        }
        Should -Invoke $script:eventFunction -Times 3 -Exactly -ParameterFilter {
            $EventType -eq 'delivery.retrying' -and $Data.retryable -and
            $Data.retryDelaySeconds -gt 0
        }
    }

    It 'caps automatic startup retry delay at five minutes' {
        Get-AgentStartupMcpRetryDelaySeconds -Attempt 100 -Role $Role | Should -Be 300
    }

    It 'does not retry a provider or data failure' {
        $script:failCount = 1
        $script:failure = 'Repository identity did not match the configured repository.'

        { & $script:resolveFunction -AgencyPath 'agency.exe' } |
            Should -Throw 'Repository identity did not match*'

        $script:openCount | Should -Be 1
        $script:closeCount | Should -Be 1
        Should -Invoke $script:eventFunction -Times 0
        Should -Invoke Send-AgentLauncherWorkerStartupRetry -Times 0
    }

    It 'wires live startup through the retrying identity resolver' {
        $script:source | Should -Match "\`$repositoryIdentity\s*=\s*$ResolveFunction\s+-AgencyPath"
    }
}
