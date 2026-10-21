#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot `
            'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') -Force
    . (Join-Path $repoRoot `
        'src\Agents\reviewer\AzureDevOpsOwnerV2CommentProvider.ps1')
}

Describe 'Azure DevOps Owner v2 changed spans' {
    It 'returns scalar span records for added content' {
        $spans = @(
            Get-ApprovedOwnerV2ChangedSpans `
                -Path 'src/Added.cs' `
                -ChangeType add `
                -SourceContent "line1`nline2" `
                -TargetContent '')

        $spans | Should -HaveCount 1
        $spans[0] |
            Should -BeOfType `
                ([Collections.IDictionary])
        $spans[0].startLine | Should -Be 1
        $spans[0].endLine | Should -Be 2
    }

    It 'returns scalar span records for modified content' {
        $spans = @(
            Get-ApprovedOwnerV2ChangedSpans `
                -Path 'src/Changed.cs' `
                -ChangeType edit `
                -SourceContent "before`nafter" `
                -TargetContent "before`nold" `
                -GitPath 'git')

        $spans.Count | Should -BeGreaterThan 0
        @($spans | Where-Object {
                $_ -isnot [Collections.IDictionary]
            }) | Should -HaveCount 0
        @($spans.startLine |
            Where-Object {
                $_ -isnot [int]
            }) | Should -HaveCount 0
    }
}

Describe 'Azure DevOps Owner v2 CLI transport' {
    It 'preserves non-BMP JSON text as exact UTF-8' {
        $folder = [char]::ConvertFromUtf32(0x1F4C2)
        $script = @'
$folder = [char]::ConvertFromUtf32(0x1F4C2)
[Console]::OutputEncoding =
    [Text.UTF8Encoding]::new($false)
[Console]::Out.Write(
    (@{ content = "$folder$folder$folder" } |
        ConvertTo-Json -Compress))
'@
        $result = Invoke-ApprovedOwnerV2AzureCliJson `
            -AzureCliPath (
                (Get-Command pwsh -CommandType Application).
                    Source) `
            -Arguments @(
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-Command',
                $script)

        [string]$result.content |
            Should -BeExactly "$folder$folder$folder"
    }
}

Describe 'Azure DevOps Owner v2 PR-wide freshness read' {
    It 'executes the dot-sourced <Scope> freshness read with rename=<Rename>' -TestCases @(
        @{ Scope = 'pull-request'; Rename = $false },
        @{ Scope = 'file-header'; Rename = $false },
        @{ Scope = 'file-header'; Rename = $true }
    ) {
        param($Scope, $Rename)
        (Get-Command `
                Get-ApprovedOwnerV2ProviderTextSha256 `
                -CommandType Function) |
            Should -Not -BeNullOrEmpty

        $reviewer =
            New-OwnerAzureDevOpsReviewerIdentity `
                -Id '33333333-3333-3333-3333-333333333333' `
                -Descriptor 'aad.synthetic-service-account' `
                -UniqueName 'service@example.invalid'
        $adapter =
            New-OwnerAzureDevOpsReadOnlyProviderAdapter `
                -Name pr-template-provider-test `
                -ReviewerIdentity $reviewer `
                -Handler { throw 'not invoked' }
        $configPath =
            Join-Path $TestDrive 'provider.json'
        [IO.File]::WriteAllText(
            $configPath,
            ([ordered]@{
                subjectProvider = [ordered]@{
                    kind =
                        'azure-devops-read-only-v1'
                    organization =
                        'https://dev.azure.com/example-org'
                    projectName = 'ExampleProject'
                    projectId =
                        '22222222-2222-2222-2222-222222222222'
                    repositoryId =
                        '11111111-1111-1111-1111-111111111111'
                }
                discussionProvider = [ordered]@{
                    kind =
                        'azure-devops-rest-owner-discussions-v1'
                    mappingDigest =
                        $adapter.
                            AzureDevOpsDiscussionMappingDigest
                    reviewerIdentity = [ordered]@{
                        id = [string]$reviewer.Id
                        descriptor =
                            [string]$reviewer.Descriptor
                        uniqueName =
                            [string]$reviewer.UniqueName
                        digest =
                            $adapter.
                                AzureDevOpsReviewerIdentityDigest
                    }
                }
            } | ConvertTo-Json -Depth 16),
            [Text.UTF8Encoding]::new($false))
        $contract =
            New-OwnerAcquisitionContract `
                -RepositoryId (
                    '11111111-1111-1111-1111-111111111111') `
                -ProjectId (
                    '22222222-2222-2222-2222-222222222222') `
                -PullRequestId 42 `
                -SourceCommit ('a' * 40) `
                -TargetCommit ('b' * 40) `
                -TargetRef refs/heads/master `
                -RuleRepositoryId rules `
                -RulePath rules/contextual.json `
                -RuleCommit ('c' * 40) `
                -RuleSection bpm-contextual-conventions@1 `
                -RuleHash (
                    'v1:sha256:' + ('d' * 64)) `
                -RuleLength 1 `
                -ConfigId contextual-test `
                -ConfigDigest (
                    'v1:sha256:' + ('e' * 64)) `
                -CapabilityId bpm-contextual-conventions@1 `
                -CapabilityDigest (
                    'v1:sha256:' + ('f' * 64))
        $template = @'
**Problem:**

**Solution:**

**Validation:**
'@
        $description =
            'Synthetic description without required sections.'
        $content = "namespace Tests`n{`n    class C { int M() => 2; }`n}"
        $targetContent = $content.Replace('=> 2', '=> 1')
        $readPaths = [Collections.Generic.List[string]]::new()
        $original =
            ${function:Invoke-ApprovedOwnerV2AzureCliJson}
        $fake = {
            param(
                [string]$AzureCliPath,
                [string[]]$Arguments,
                [string]$InputPath = '',
                [int]$TimeoutMilliseconds = 120000
            )
            if ($Arguments -contains 'account') {
                return [ordered]@{
                    user = [ordered]@{
                        name =
                            'service@example.invalid'
                    }
                }
            }
            if ($Arguments -contains 'pr' -and
                $Arguments -contains 'show') {
                return [ordered]@{
                    pullRequestId = 42
                    status = 'active'
                    isDraft = $false
                    title = 'Synthetic PR'
                    description = $description
                    sourceRefName =
                        'refs/heads/feature'
                    targetRefName =
                        'refs/heads/master'
                    repository = [ordered]@{
                        id =
                            '11111111-1111-1111-1111-111111111111'
                        project = [ordered]@{
                            id =
                                '22222222-2222-2222-2222-222222222222'
                        }
                    }
                }
            }
            $resourceIndex =
                [Array]::IndexOf(
                    $Arguments, '--resource')
            $resource = if ($resourceIndex -ge 0) {
                [string]$Arguments[
                    $resourceIndex + 1]
            }
            else { '' }
            switch ($resource) {
                pullRequestIterations {
                    return [ordered]@{
                        value = @([ordered]@{
                                id = 3
                                sourceRefCommit =
                                    [ordered]@{
                                        commitId =
                                            'a' * 40
                                    }
                                targetRefCommit =
                                    [ordered]@{
                                        commitId =
                                            'b' * 40
                                    }
                            })
                    }
                }
                refs {
                    return [ordered]@{
                        value = @(
                            [ordered]@{
                                name =
                                    'refs/heads/feature'
                                objectId = 'a' * 40
                            },
                            [ordered]@{
                                name =
                                    'refs/heads/master'
                                objectId = '1' * 40
                            })
                    }
                }
                pullRequestIterationChanges {
                    return [ordered]@{
                        changeEntries = $(if ($Scope -ceq 'file-header') {
                            @([ordered]@{
                                changeTrackingId = 7
                                changeType = $(if ($Rename) { 'rename, edit' } else { 'edit' })
                                originalPath = $(if ($Rename) { '/src/Old.cs' } else { $null })
                                item = @{ path = '/src/Header.cs' }
                            })
                        } else { @() })
                    }
                }
                pullRequestThreads {
                    return [ordered]@{
                        value = @()
                        count = 0
                    }
                }
                repositories {
                    return [ordered]@{
                        defaultBranch =
                            'refs/heads/master'
                    }
                }
                items {
                    $pathArgument = @($Arguments | Where-Object { $_ -like 'path=*' })
                    if ($pathArgument.Count -eq 1 -and
                        $pathArgument[0] -in @('path=/src/Header.cs', 'path=/src/Old.cs')) {
                        [void]$readPaths.Add($pathArgument[0])
                        return [ordered]@{
                            content = $(if ($Arguments -contains ('versionDescriptor.version=' + ('a' * 40))) {
                                $content
                            } else { $targetContent })
                            contentMetadata = @{ contentType = 'text/plain' }
                        }
                    }
                    if ($Arguments -contains
                        'scopePath=/.azuredevops') {
                        return [ordered]@{
                            value = @([ordered]@{
                                    path =
                                        '/.azuredevops/pull_request_template.txt'
                                    objectId = '2' * 40
                                    isFolder = $false
                                })
                        }
                    }
                    return [ordered]@{
                        content = $template
                        contentMetadata =
                            [ordered]@{
                                contentType =
                                    'text/plain'
                            }
                    }
                }
                default {
                    throw "Unexpected resource '$resource'."
                }
            }
        }.GetNewClosure()
        try {
            Set-Item -LiteralPath (
                'Function:\Invoke-ApprovedOwnerV2AzureCliJson') `
                -Value $fake
            $provider =
                New-ApprovedOwnerV2AzureDevOpsProvider `
                    -ProviderConfigPath $configPath `
                    -AzureCliPath 'ignored'
            $live = & $provider 'ReadCurrent' @{
                evidence =
                    [pscustomobject]@{
                        Contract = $contract
                    }
                operator = [ordered]@{
                    id = [string]$reviewer.Id
                    descriptor =
                        [string]$reviewer.Descriptor
                    uniqueName =
                        [string]$reviewer.UniqueName
                }
                selections = @($(if ($Scope -ceq 'file-header') {
                    [ordered]@{
                        findingId = 'contextual-v1:' + ('3' * 64)
                        scope = 'file-header'
                        ruleId = 'file-copyright-header'
                        path = 'src/Header.cs'
                        line = 1
                        symbol = 'copyright-header'
                    }
                } else { [ordered]@{
                        findingId =
                            'contextual-v1:' + ('3' * 64)
                        scope = 'pull-request'
                        subject = 'description'
                        constructRef =
                            'construct:' + ('4' * 64)
                        marker = '5' * 64
                    } }))
            }
        }
        finally {
            Set-Item -LiteralPath (
                'Function:\Invoke-ApprovedOwnerV2AzureCliJson') `
                -Value $original
        }
        if ($Scope -ceq 'file-header') {
            @($live.Anchors) | Should -HaveCount 1
            $live.Anchors[0].scope | Should -BeExactly file-header
            $live.Anchors[0].startLine | Should -Be 1
            $live.Anchors[0].fileHeader.origin | Should -BeExactly pre-existing
            $live.Anchors[0].fileHeader.targetDigest |
                Should -BeExactly ('v1:sha256:' + (Get-ApprovedOwnerV2ProviderTextSha256 $targetContent))
            if ($Rename) {
                $live.Anchors[0].fileHeader.oldPath | Should -BeExactly 'src/Old.cs'
                $readPaths[1] | Should -BeExactly 'path=/src/Old.cs'
            }
            else { $readPaths[1] | Should -BeExactly 'path=/src/Header.cs' }
            return
        }
        $expectedDescription =
            Get-ApprovedOwnerV2ProviderTextSha256 `
                -Text $description
        $expectedTemplate =
            Get-ApprovedOwnerV2ProviderTextSha256 `
                -Text $template

        $live.PullRequest.metadata.
            descriptionSha256 |
            Should -BeExactly $expectedDescription
        $live.PullRequest.metadata.template.path |
            Should -BeExactly (
                '.azuredevops/pull_request_template.txt')
        $live.PullRequest.metadata.template.
            contentSha256 |
            Should -BeExactly $expectedTemplate
        @($live.Anchors) |
            Should -HaveCount 0
    }
}
