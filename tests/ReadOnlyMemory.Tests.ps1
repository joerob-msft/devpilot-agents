Describe '<Role> read-only repository memory permissions' -ForEach @(
    @{ Role = 'Reviewer'; Source = 'src\Agents\reviewer\Start-ReviewerAgent.ps1'; CeilingName = 'ReviewerAllowToolCeiling' }
    @{ Role = 'Handler'; Source = 'src\Agents\review-handler\Start-ReviewHandlerAgent.ps1'; CeilingName = 'HandlerBaseAllowToolCeiling' }
) {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path "$PSScriptRoot\.." $Source), [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $variables = @("script:$CeilingName", "script:${Role}MandatoryDenyTools",
            'script:ReviewerForbiddenToolFamilies')
        foreach ($assignment in $ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                    $variables -contains $node.Left.VariablePath.UserPath
                }, $true)) {
            . ([scriptblock]::Create($assignment.Extent.Text))
        }
        $functionName = "Get-${Role}EffectiveAllowTools"
        $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
            }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $ceiling = Get-Variable -Name $CeilingName -ValueOnly
        $mandatoryDeny = Get-Variable -Name "${Role}MandatoryDenyTools" -ValueOnly
        $reads = @('squad_state_health', 'squad_state_read', 'squad_state_list', 'memory.search') |
            ForEach-Object { "squad_state($_)" }
        $writes = @('squad_decide', 'squad_state_write', 'squad_state_append', 'squad_state_delete',
            'memory.write', 'memory.promote', 'memory.delete') |
            ForEach-Object { "squad_state($_)" }
    }

    It 'allows exact read operations through validation and the effective cycle list' {
        { Test-AgentAllowToolCeiling -Candidates $reads -Ceiling $ceiling `
                -MandatoryDeny $mandatoryDeny -Where 'memory fixture' } | Should -Not -Throw
        [string[]]$effective = & $functionName -BaseAllow $reads
        $effective | Should -Be $reads
    }

    It 'rejects whole-server and wildcard grants instead of widening read access' {
        foreach ($candidate in @('squad_state', 'squad_state(*)', 'squad_state(memory.*)')) {
            { Test-AgentAllowToolCeiling -Candidates @($candidate) -Ceiling $ceiling `
                    -MandatoryDeny $mandatoryDeny -Where 'memory fixture' } | Should -Throw
        }
    }

    It 'denies mutations even with a polluted ceiling and strips them from cycle grants' {
        foreach ($write in $writes) {
            { Test-AgentAllowToolCeiling -Candidates @($write) -Ceiling ($ceiling + @($write)) `
                    -MandatoryDeny $mandatoryDeny -Where 'memory fixture' } | Should -Throw
        }
        [string[]]$effective = & $functionName -BaseAllow ($reads + $writes)
        $effective | Should -Be $reads
    }
}
