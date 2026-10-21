#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot `
            'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') -Force
    Import-Module (Join-Path $repoRoot `
            'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1') -Force
    Import-Module (Join-Path $repoRoot `
            'src\OwnerObservationContract\OwnerObservationContract.psd1') -Force
    . (Join-Path $repoRoot `
        'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')
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
    It 'executes the dot-sourced PR description and template digest path' {
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
                        changeEntries = @()
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
                selections = @([ordered]@{
                        findingId =
                            'contextual-v1:' + ('3' * 64)
                        scope = 'pull-request'
                        subject = 'description'
                        constructRef =
                            'construct:' + ('4' * 64)
                        marker = '5' * 64
                    })
            }
        }
        finally {
            Set-Item -LiteralPath (
                'Function:\Invoke-ApprovedOwnerV2AzureCliJson') `
                -Value $original
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

        $config = Get-Content -LiteralPath $configPath -Raw |
            ConvertFrom-Json -AsHashtable
        $contract | Add-Member -NotePropertyName CommentPresentation -NotePropertyValue @{
            subjectProvider = $config.subjectProvider
        }
        $source = $live.PullRequest.metadata.template
        $constructRef = 'construct:' + ('4' * 64)
        $finding = [ordered]@{
            identity = 'contextual-v1:' + ('3' * 64)
            semanticKey = 'v1:sha256:' + ('5' * 64)
            disposition = 'violation'
            ruleId = 'pr-template-compliance'
            constructRef = $constructRef
            issueIdentity = 'v1:sha256:' + ('6' * 64)
            missingSections = @('Problem', 'Solution', 'Validation')
            evidence = 'Add meaningful content under the required PR description sections.'
            anchor = @{ scope = 'pull-request'; subject = 'description' }
            binding = New-OwnerCanonicalPullRequestBinding `
                -DescriptionSha256 $expectedDescription `
                -TemplatePath $source.path -TemplateRef $source.ref `
                -TemplateCommit $source.commit -TemplateBlob $source.blob `
                -TemplateContentSha256 $source.contentSha256 `
                -ConstructIdentity $constructRef
        }
        $observation = Resolve-OwnerV2DiscussionReconciliation `
            -Contract $contract -Snapshot $live.Snapshot -Observation ([ordered]@{
                capability = 'bpm-contextual-conventions@1'
                lifecycle = @{ status = 'completed' }
                findings = @($finding)
                effects = @{ dedupe = @{} }
                sourceArtifacts = @()
            })
        $evidence = [pscustomobject]@{
            Contract = $contract
            Declaration = @{ capability = @{ id = 'bpm-contextual-conventions@1' } }
            Observation = $observation
        }
        $proposal = Get-ApprovedOwnerV2Proposal -Evidence $evidence `
            -Finding $finding -Delivery contextual-conventions
        $result = Assert-ApprovedOwnerV2LiveRead `
            -Evidence $evidence -Live $live -Selections @($proposal) `
            -ExpectedSnapshotSha256 $live.Snapshot.Digest.Substring(10) `
            -Delivery contextual-conventions -Approval @{
                subject = @{
                    projectId = $contract.Request.ProjectId
                    repositoryId = $contract.Request.RepositoryId
                    pullRequestId = 42
                    sourceCommit = $contract.Request.SourceCommit
                    targetCommit = $contract.Request.TargetCommit
                    targetRef = $contract.Request.TargetRef
                }
                provider = $live.ProviderBinding
                operator = $live.Reviewer
            }
        $result.Classifications[$finding.identity] | Should -BeExactly wouldCreate
        $proposal.body | Should -Match '\*\*Effective template:\*\* \['
        $proposal.body | Should -Match 'version=GC1111111111111111111111111111111111111111'
        $proposal.body | Should -Not -Match 'Changed-line occurrences:|Rule bundle:'
        $proposal.Contains('path') | Should -BeFalse
        $proposal.Contains('line') | Should -BeFalse
    }
}
