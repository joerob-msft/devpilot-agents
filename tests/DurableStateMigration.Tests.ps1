BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    $script:migrationTool = (Resolve-Path "$PSScriptRoot\..\tools\Initialize-DevPilotDurableState.ps1").Path
}

Describe 'legacy durable-state migration validation' {
    It 'reads an Azure DevOps fixture through the provider-neutral snapshot API' {
        $commit = 'a' * 40
        $calls = [Collections.Generic.List[object]]::new()
        $context = New-AgentProviderContext -Provider AzureDevOps -Organization contoso `
            -Project widgets -RepositoryName service `
            -RepositoryId '11111111-2222-3333-4444-555555555555' -McpInvoker {
                param($name, $arguments, $raw)
                $calls.Add(@{ name = $name; arguments = $arguments; raw = $raw })
                return @{
                    pullRequestId = 104; status = 'active'; isDraft = $false
                    sourceCommitId = $commit; sourceRefName = 'refs/heads/feature'
                    targetRefName = 'refs/heads/main'; title = 'Fixture'
                }

            }
        $snapshot = Get-AgentProviderPullRequestSnapshot -Context $context -PullRequestId 104
        $snapshot.sourceCommit | Should -Be $commit
        $calls.Count | Should -Be 1
        $calls[0].name | Should -Be 'repo_pull_request'
        $calls[0].arguments.action | Should -Be 'get'
    }

    It 'runs the migration tool for an ADO fixture and reconciled empty state' {
        $repositoryId = '11111111-2222-3333-4444-555555555555'
        $commit = 'a' * 40
        $provider = New-AgentProviderContext -Provider AzureDevOps -Organization contoso `
            -Project widgets -RepositoryName service -RepositoryId $repositoryId -McpInvoker {
                param($name, $arguments, $raw)
                if ($name -eq 'repo_repository') {
                    return @{ id = $repositoryId; name = 'service'; project = @{ name = 'widgets' } }
                }
                if ($name -eq 'repo_pull_request') {
                    return @{ pullRequestId = 104; sourceCommitId = $commit; status = 'active' }
                }
                throw "Unexpected fixture call '$name'."
            }
        $legacy = Join-Path $TestDrive 'legacy'
        $durable = Join-Path $TestDrive 'durable'
        $leases = Join-Path $TestDrive 'leases'
        New-Item -ItemType Directory -Path $legacy | Out-Null
        @{ '104' = @{ sourceCommit = $commit; deliveryPending = $false } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $legacy 'reviewed.json') -Encoding utf8NoBOM

        $imported = & $migrationTool -Role reviewer -LegacyStateDir $legacy `
            -RepositoryRoot (Resolve-Path "$PSScriptRoot\..").Path -Organization contoso `
            -Project widgets -RepositoryName service -RepositoryId $repositoryId `
            -DurableStateRoot $durable -LeaseRoot $leases -ProviderContext $provider
        $imported.recordsImported | Should -Be 1
        Test-Path -LiteralPath $imported.statePath -PathType Leaf | Should -BeTrue

        $empty = & $migrationTool -Role review-handler -ReconciledEmpty `
            -RepositoryRoot (Resolve-Path "$PSScriptRoot\..").Path -Organization contoso `
            -Project widgets -RepositoryName service -RepositoryId $repositoryId `
            -DurableStateRoot $durable -LeaseRoot $leases -ProviderContext $provider
        $empty.recordsImported | Should -Be 0
        $state = Get-Content -LiteralPath $empty.statePath -Raw | ConvertFrom-Json -AsHashtable
        $state.records.Count | Should -Be 0
    }

    It 'requires live provider commit agreement' {
        $records = @{ '104' = @{ sourceCommit = ('a' * 40); deliveryPending = $false } }
        $confirmed = Confirm-AgentLegacyRecordsForMigration -Role reviewer -Records $records `
            -PullRequestReader { param($id) @{ sourceCommit = ('a' * 40) } }
        $confirmed['104'].sourceCommit | Should -Be ('a' * 40)

        { Confirm-AgentLegacyRecordsForMigration -Role reviewer -Records $records `
                -PullRequestReader { param($id) @{ sourceCommit = ('b' * 40) } } } | Should -Throw
    }

    It 'refuses a pending delivery whose sealed manifest is missing' {
        $records = @{
            '104' = @{
                sourceCommit = ('a' * 40)
                deliveryPending = $true
                artifactPath = (Join-Path $TestDrive 'missing.json')
            }
        }
        { Confirm-AgentLegacyRecordsForMigration -Role reviewer -Records $records `
                -PullRequestReader { param($id) @{ sourceCommit = ('a' * 40) } } } |
            Should -Throw '*sealed manifest is missing*'
    }

    It 'preserves a pending manifest reference after validation' {
        $manifest = Join-Path $TestDrive 'sealed.json'
        '{}' | Set-Content -LiteralPath $manifest -Encoding utf8NoBOM
        $records = @{
            '104' = @{
                sourceCommit = ('a' * 40)
                deliveryPending = $true
                artifactPath = $manifest
                fingerprint = 'unchanged'
            }
        }
        $confirmed = Confirm-AgentLegacyRecordsForMigration -Role reviewer -Records $records `
            -PullRequestReader { param($id) @{ sourceCommit = ('a' * 40) } }
        $confirmed['104'].artifactPath | Should -Be $manifest
        $confirmed['104'].fingerprint | Should -Be 'unchanged'
    }

    It 'migrates a pending reviewer signing key into stable durable role storage across restarts' {
        $repositoryId = '11111111-2222-3333-4444-555555555555'
        $commit = 'a' * 40
        $provider = New-AgentProviderContext -Provider AzureDevOps -Organization contoso `
            -Project widgets -RepositoryName service -RepositoryId $repositoryId -McpInvoker {
                param($name, $arguments, $raw)
                if ($name -eq 'repo_repository') {
                    return @{ id = $repositoryId; name = 'service'; project = @{ name = 'widgets' } }
                }
                if ($name -eq 'repo_pull_request') {
                    return @{ pullRequestId = 104; sourceCommitId = $commit; status = 'active' }
                }
                throw "Unexpected fixture call '$name'."
            }
        $legacy = Join-Path $TestDrive 'legacy-pending'
        $durable = Join-Path $TestDrive 'durable-pending'
        $leases = Join-Path $TestDrive 'leases-pending'
        New-Item -ItemType Directory -Path $legacy | Out-Null
        $manifest = Join-Path $legacy 'sealed.json'
        '{}' | Set-Content -LiteralPath $manifest -Encoding utf8NoBOM
        @{ '104' = @{
                sourceCommit = $commit; deliveryPending = $true
                artifactPath = $manifest; fingerprint = 'pending'
            } } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $legacy 'reviewed.json') -Encoding utf8NoBOM
        $key = [byte[]](1..32)
        ('raw:' + [Convert]::ToBase64String($key)) |
            Set-Content -LiteralPath (Join-Path $legacy 'artifact-signing.key') -Encoding ascii
        if (-not $IsWindows) {
            # A real legacy signing key would already carry owner-only
            # permissions (every writer of security-sensitive artifacts in
            # this codebase sets them); Read-LegacyReviewerSigningKey
            # correctly fails closed via Assert-AgentTrustedFile -Private
            # when that is not the case, so the fixture must model a
            # realistic, securely-permissioned legacy key rather than rely on
            # the ambient umask.
            [IO.File]::SetUnixFileMode((Join-Path $legacy 'artifact-signing.key'),
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }

        $first = & $migrationTool -Role reviewer -LegacyStateDir $legacy `
            -RepositoryRoot (Resolve-Path "$PSScriptRoot\..").Path -Organization contoso `
            -Project widgets -RepositoryName service -RepositoryId $repositoryId `
            -DurableStateRoot $durable -LeaseRoot $leases -ProviderContext $provider
        $durableKey = Join-Path (Split-Path $first.statePath -Parent) 'artifact-signing.key'
        (Get-Content -LiteralPath $durableKey -Raw).Trim() |
            Should -Be ('raw:' + [Convert]::ToBase64String($key))

        $second = & $migrationTool -Role reviewer -LegacyStateDir $legacy `
            -RepositoryRoot (Resolve-Path "$PSScriptRoot\..").Path -Organization contoso `
            -Project widgets -RepositoryName service -RepositoryId $repositoryId `
            -DurableStateRoot $durable -LeaseRoot $leases -ProviderContext $provider
        $second.generation | Should -Be $first.generation
        (Get-Content -LiteralPath $durableKey -Raw).Trim() |
            Should -Be ('raw:' + [Convert]::ToBase64String($key))
    }

    It 'rejects malformed PR and source-commit bindings' {
        { Confirm-AgentLegacyRecordsForMigration -Role review-handler `
                -Records @{ '../escape' = @{ sourceCommit = ('a' * 40) } } `
                -PullRequestReader { throw 'must not read' } } | Should -Throw
        { Confirm-AgentLegacyRecordsForMigration -Role review-handler `
                -Records @{ '104' = @{ sourceCommit = 'main' } } `
                -PullRequestReader { throw 'must not read' } } | Should -Throw
    }
}
