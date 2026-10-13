#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
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
