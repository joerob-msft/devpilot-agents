#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\DevPilot.NamedAreEqualBridge\DevPilot.NamedAreEqualBridge.psd1') -Force
    Import-Module (Join-Path $repoRoot 'src\DevPilot.ContextualConventionsBridge\DevPilot.ContextualConventionsBridge.psd1') -Force
    Import-Module (Join-Path $repoRoot 'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1') -Force
    . (Join-Path $repoRoot 'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')

    function New-ReferenceValidationConfig {
        param([string]$Delivery)
        $sample = if ($Delivery -ceq 'named-areequal') {
            'named-areequal-current-pr.config.json'
        } else { 'contextual-conventions-current-pr.config.json' }
        Get-Content -LiteralPath (Join-Path $repoRoot "samples\$sample") -Raw |
            ConvertFrom-Json -AsHashtable
    }
}

Describe 'Reviewer comment reference validation boundaries' {
    It 'rejects malformed <Mode> entries before any rule fires at every configured boundary' -TestCases @(
        @{ Mode = 'unknown-rule' }, @{ Mode = 'entry-key' }, @{ Mode = 'link-key' },
        @{ Mode = 'empty-links' }, @{ Mode = 'scalar-links' }, @{ Mode = 'missing-name' },
        @{ Mode = 'external-host' }, @{ Mode = 'fragment' }, @{ Mode = 'duplicate-version' },
        @{ Mode = 'duplicate-path' }, @{ Mode = 'duplicate-line' }, @{ Mode = 'unexpected-query' },
        @{ Mode = 'traversal' }, @{ Mode = 'encoded-traversal' }, @{ Mode = 'double-encoding' },
        @{ Mode = 'wrong-repository' }, @{ Mode = 'wrong-project' }, @{ Mode = 'missing-binding' },
        @{ Mode = 'external-binding' }, @{ Mode = 'repository-binding-key' }, @{ Mode = 'zero-line' },
        @{ Mode = 'unrooted-path' }, @{ Mode = 'dot-segment' }, @{ Mode = 'backslash' },
        @{ Mode = 'empty-path-segment' }, @{ Mode = 'userinfo' }, @{ Mode = 'untrusted-alias' }
    ) {
        param($Mode)
        foreach ($delivery in @('named-areequal', 'contextual-conventions', 'owner')) {
            $config = New-ReferenceValidationConfig -Delivery $delivery
            $ruleId = if ($delivery -ceq 'named-areequal') { 'named-areequal' } else { 'exception-logging' }
            $reference = $config.commentRuleReferences[$ruleId]
            if ($delivery -ceq 'owner') {
                $config.commentRuleReferences = @{ owner = $reference }
                $ruleId = 'owner'
            }
            $link = $reference.links[0]
            switch ($Mode) {
                unknown-rule { $config.commentRuleReferences['invented-rule'] = $reference }
                entry-key { $reference['authority'] = 'invented' }
                link-key { $link['trusted'] = $true }
                empty-links { $reference.links = @() }
                scalar-links { $reference.links = $link }
                missing-name { $link.Remove('name') }
                external-host { $link.url = $link.url.Replace('https://dev.azure.com/msazure/One/_git/AzureUX-BPM-EngHub', 'https://evil.example.com/phish') }
                fragment { $link.url = $link.url.Replace('?version=', '#?version=') }
                duplicate-version { $link.url = $link.url.Replace('?version=', '?version=GBmaster&version=') }
                duplicate-path { $link.url += '&path=/other.md' }
                duplicate-line { $link.url += '&line=1' }
                unexpected-query { $link.url += '&extra=value' }
                traversal { $link.url = $link.url -replace 'path=[^&]+', 'path=/../../secret.md' }
                encoded-traversal { $link.url = $link.url -replace 'path=[^&]+', 'path=/%2e%2e/secret.md' }
                double-encoding { $link.url = $link.url -replace 'path=[^&]+', 'path=/%252e%252e/secret.md' }
                wrong-repository { $link.url = $link.url.Replace('_git/AzureUX-BPM-EngHub', '_git/Other') }
                wrong-project { $link.url = $link.url.Replace('/One/_git/', '/Other/_git/') }
                missing-binding { $config.Remove('commentRuleRepository') }
                external-binding { $config.commentRuleRepository.organization = 'https://evil.example.com' }
                repository-binding-key { $config.commentRuleRepository['trusted'] = $true }
                zero-line { $link.url = $link.url -replace 'line=\d+', 'line=0' }
                unrooted-path { $link.url = $link.url -replace 'path=[^&]+', 'path=rule.md' }
                dot-segment { $link.url = $link.url -replace 'path=[^&]+', 'path=/docs/./rule.md' }
                backslash { $link.url = $link.url -replace 'path=[^&]+', 'path=/%5crule.md' }
                empty-path-segment { $link.url = $link.url -replace 'path=[^&]+', 'path=/docs//rule.md' }
                userinfo { $link.url = $link.url.Replace('https://', 'https://person@') }
                untrusted-alias { $link.url = $link.url.Replace('https://dev.azure.com/msazure', 'https://msazure.visualstudio.com') }
            }
            {
                Assert-OwnerCommentRuleReferences -Delivery $delivery `
                    -References $config.commentRuleReferences -Repository $config['commentRuleRepository']
            } | Should -Throw -ExceptionType ([ArgumentException])
            if ($delivery -ceq 'named-areequal') {
                {
                    & (Get-Module DevPilot.NamedAreEqualBridge) {
                        param($Config, $Root)
                        Assert-NamedBridgeConfig -Config $Config -RepositoryRoot $Root
                    } $config $repoRoot
                } | Should -Throw -ExceptionType ([ArgumentException])
            } elseif ($delivery -ceq 'contextual-conventions') {
                {
                    & (Get-Module DevPilot.ContextualConventionsBridge) {
                        param($Config, $Root)
                        Assert-ContextualBridgeConfig -Config $Config -RepositoryRoot $Root
                    } $config $repoRoot
                } | Should -Throw -ExceptionType ([ArgumentException])
            }
            $capability = switch ($delivery) {
                named-areequal { 'bpm-named-areequal-arguments@1' }
                contextual-conventions { 'bpm-contextual-conventions@1' }
                owner { 'bpm-test-ownership@1' }
            }
            {
                Set-ApprovedOwnerV2CommentPresentation `
                    -Contract ([pscustomobject]@{ Request = @{ CapabilityId = $capability } }) `
                    -Observation @{ sourceArtifacts = @(); findings = @() } -ToolkitConfig $config
            } | Should -Throw -ExceptionType ([ArgumentException])
        }
    }

    It 'accepts exact independently configured Azure DevOps aliases without deriving trust from a link' {
        foreach ($organization in @('https://dev.azure.com/msazure', 'https://msazure.visualstudio.com', 'https://msazure.visualstudio.com/DefaultCollection')) {
            $config = New-ReferenceValidationConfig -Delivery named-areequal
            $config.commentRuleRepository.organization = $organization
            $link = $config.commentRuleReferences['named-areequal'].links[0]
            $link.url = $link.url.Replace('https://dev.azure.com/msazure', $organization)
            {
                Assert-OwnerCommentRuleReferences -Delivery named-areequal `
                    -References $config.commentRuleReferences -Repository $config.commentRuleRepository
            } | Should -Not -Throw
        }
    }

    It 'imports the validator explicitly from each bridge in a fresh no-profile process' {
        $child = @'
$ErrorActionPreference = 'Stop'
Import-Module '__MANIFEST__'
& (Get-Module '__MODULE__') {
    Get-Command Assert-OwnerCommentRuleReferences -ErrorAction Stop | Out-Null
}
'@
        foreach ($name in @('DevPilot.NamedAreEqualBridge', 'DevPilot.ContextualConventionsBridge')) {
            $manifest = Join-Path $repoRoot "src\$name\$name.psd1"
            $script = $child.Replace('__MANIFEST__', $manifest.Replace("'", "''")).Replace('__MODULE__', $name)
            $output = @(& (Get-Command pwsh -CommandType Application).Source -NoLogo -NoProfile -NonInteractive -Command $script 2>&1)
            $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        }
    }
}
