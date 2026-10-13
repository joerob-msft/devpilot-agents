#requires -Version 7.0

BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1" -Force

    function Get-TestDigest([string]$Text) {
        return 'v1:sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
    }

    function New-TestContract {
        return New-OwnerAcquisitionContract `
            -RepositoryId 'repository-example' `
            -ProjectId 'project-example' `
            -PullRequestId 42 `
            -SourceCommit ('a' * 40) `
            -TargetCommit ('b' * 40) `
            -TargetRef 'refs/heads/main' `
            -RuleRepositoryId 'rules-example' `
            -RulePath '.config/rule.md' `
            -RuleCommit ('c' * 40) `
            -RuleSection 'rule' `
            -RuleHash (Get-TestDigest 'rule') `
            -RuleLength 4 `
            -ConfigId 'config' `
            -ConfigDigest (Get-TestDigest 'config') `
            -CapabilityId 'capability' `
            -CapabilityDigest (Get-TestDigest 'capability') `
            -Limits (New-OwnerAdapterLimits)
    }
}

Describe 'Owner discussion semantic snapshot digest' {
    It 'is stable across transport-only raw response metadata' {
        $reviewer = New-OwnerAzureDevOpsReviewerIdentity `
            -Id '11111111-2222-3333-4444-555555555555' `
            -Descriptor 'aad.test-reviewer-descriptor' `
            -UniqueName 'reviewer@example.com'
        $arguments = [ordered]@{
            repositoryId = 'repository-example'
            projectId = 'project-example'
            pullRequestId = 42
            sourceCommit = 'a' * 40
            targetCommit = 'b' * 40
            targetRef = 'refs/heads/main'
            pageOrdinal = 0
            pageSize = 100
            continuationToken = $null
        }
        $current = [ordered]@{
            id = 2
            sourceCommit = 'a' * 40
            targetCommit = 'b' * 40
        }
        $firstPage = ConvertTo-OwnerAzureDevOpsDiscussionPage `
            -Arguments $arguments `
            -RawResponse ([ordered]@{
                count = 0
                value = @()
                transportEnvelope = 'first'
            }) `
            -CurrentIteration $current `
            -ReviewerIdentity $reviewer
        $secondPage = ConvertTo-OwnerAzureDevOpsDiscussionPage `
            -Arguments $arguments `
            -RawResponse ([ordered]@{
                count = 0
                value = @()
                transportEnvelope = 'second'
            }) `
            -CurrentIteration $current `
            -ReviewerIdentity $reviewer
        $firstProvider = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
            -Name first -ReviewerIdentity $reviewer `
            -Handler { param($Operation, $Arguments) return $firstPage }.GetNewClosure()
        $secondProvider = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
            -Name second -ReviewerIdentity $reviewer `
            -Handler { param($Operation, $Arguments) return $secondPage }.GetNewClosure()
        $contract = New-TestContract

        $first = Get-OwnerDiscussionSnapshot `
            -Contract $contract -Provider $firstProvider `
            -RequireAzureDevOpsProvenance
        $second = Get-OwnerDiscussionSnapshot `
            -Contract $contract -Provider $secondProvider `
            -RequireAzureDevOpsProvenance

        $firstPage.sourceDigest | Should -BeExactly $secondPage.sourceDigest
        $firstPage.rawProvenanceDigest | Should -Not -BeExactly $secondPage.rawProvenanceDigest
        $first.Digest | Should -BeExactly $second.Digest
        $first.RawProvenanceDigests[0] | Should -Not -BeExactly $second.RawProvenanceDigests[0]
    }
}