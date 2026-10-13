#requires -Version 7.0

BeforeAll {
    . "$PSScriptRoot\..\src\Agents\reviewer\AzureDevOpsOwnerV2CommentProvider.ps1"
}

Describe 'Owner writer live head binding' {
    It 'uses a latest iteration verified by the live source ref' {
        $result = Resolve-ApprovedOwnerV2LiveHead `
            -PullRequest ([ordered]@{
                sourceRefName = 'refs/heads/feature'
                targetRefName = 'refs/heads/master'
                lastMergeSourceCommit =
                    [ordered]@{ commitId = 'a' * 40 }
            }) `
            -Iteration ([ordered]@{
                id = 4
                sourceRefCommit =
                    [ordered]@{ commitId = 'c' * 40 }
                targetRefCommit =
                    [ordered]@{ commitId = 'd' * 40 }
            }) `
            -SourceRefs @([ordered]@{
                    name = 'refs/heads/feature'
                    objectId = 'c' * 40
                })
        $result.sourceCommit |
            Should -BeExactly ('c' * 40)
        $result.targetCommit |
            Should -BeExactly ('d' * 40)
    }

    It 'refuses a live source ref drift' {
        {
            Resolve-ApprovedOwnerV2LiveHead `
                -PullRequest ([ordered]@{
                    sourceRefName =
                        'refs/heads/feature'
                    targetRefName =
                        'refs/heads/master'
                }) `
                -Iteration ([ordered]@{
                    id = 4
                    sourceRefCommit =
                        [ordered]@{
                            commitId = 'c' * 40
                        }
                    targetRefCommit =
                        [ordered]@{
                            commitId = 'd' * 40
                        }
                }) `
                -SourceRefs @([ordered]@{
                        name = 'refs/heads/feature'
                        objectId = 'e' * 40
                    })
        } | Should -Throw '*source ref or iteration is inconsistent*'
    }
}
