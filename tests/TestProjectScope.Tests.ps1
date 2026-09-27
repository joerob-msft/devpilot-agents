#requires -Version 7.0
Import-Module "$PSScriptRoot\..\src\DevPilot.RuleEvaluation\DevPilot.RuleEvaluation.psd1" -Force

Describe 'Source-bound all-class project scope' {
    InModuleScope DevPilot.RuleEvaluation {
        BeforeAll {
            $script:repositoryId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            $script:sourceCommit = 'b' * 40
            function New-ScopeFile {
                param([string]$Content = "class Helper {}`n",
                    [object[]]$Spans = @(@{ startLine = 1; endLine = 1 }))
                return @{ path = '/Helper.cs'; content = $Content; objectId = 'c' * 40
                    spans = $Spans }
            }
            function New-ScopeEvidence {
                return @{
                    schemaVersion = 1
                    kind = 'source-bound-evaluated-project-graph-v1'
                    complete = $true
                    repositoryId = $script:repositoryId
                    sourceCommit = $script:sourceCommit
                    path = '/Helper.cs'
                    objectId = 'c' * 40
                    projects = @(@{ path = '/Tests/Tests.csproj'; objectId = 'd' * 40
                            compileIncluded = $true; isTestProject = $true })
                }
            }
            function Invoke-ScopeEvaluation {
                param([string]$Capability, [object]$File)
                Get-RuleEvaluation $Capability @($File) 32 $null $null `
                    $script:repositoryId $script:sourceCommit
            }
        }

        It 'fails closed on absent, incomplete, stale, mismatched and duplicated graph evidence' {
            $file = New-ScopeFile
            $evidence = New-ScopeEvidence
            $cases = @(
                $null
                @{ complete = $false }
                @{ complete = 'true' }
                @{ schemaVersion = '1' }
                @{ sourceCommit = 'e' * 40 }
                @{ objectId = 'e' * 40 }
                @{ path = '/Elsewhere.cs' }
                @{ repositoryId = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' }
                @{ projects = @() }
                @{ projects = @($evidence.projects[0], $evidence.projects[0]) }
                @{ projects = @(@{
                                path = '/Tests/Tests.csproj'; objectId = 'd' * 40
                                compileIncluded = $false; isTestProject = $true }) }
            )
            foreach ($case in $cases) {
                $file.projectEvidence = $null
                if ($null -ne $case) {
                    $file.projectEvidence = @{}
                    foreach ($key in $evidence.Keys) {
                        $file.projectEvidence[$key] = $evidence[$key]
                    }
                    foreach ($key in $case.Keys) {
                        $file.projectEvidence[$key] = $case[$key]
                    }
                }
                $result = Invoke-ScopeEvaluation 'bpm-test-class-coverage@2' $file
                $result.state | Should -BeExactly 'unknown'
                $result.reason | Should -BeExactly 'test-project-identity-unknown'
                $result.findings | Should -Be 0
            }
        }

        It 'never treats a product or mixed-ownership file as an all-class finding' {
            $file = New-ScopeFile
            $file.projectEvidence = New-ScopeEvidence
            $file.projectEvidence.projects[0].isTestProject = $false
            $file.content = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
[TestClass] class ProductTests {}
'@
            $file.spans = @(@{ startLine = 2; endLine = 2 })
            (Get-RuleTestProjectScope $file.projectEvidence $script:repositoryId `
                    $script:sourceCommit $file.path $file.objectId) | Should -BeExactly 'non-test'
            $result = Invoke-ScopeEvaluation 'bpm-test-class-coverage@2' $file
            $result.findings | Should -Be 0
            $result.reason | Should -BeExactly 'discussion-acquisition-unavailable'
            $result.unknown | Should -Be 1
            (Invoke-ScopeEvaluation 'bpm-test-class-coverage@1' $file).findings |
                Should -Be 1
            $file.projectEvidence.projects += @{
                path = '/Tests/Other.csproj'; objectId = 'f' * 40
                compileIncluded = $true; isTestProject = $true
            }
            $mixed = Invoke-ScopeEvaluation 'bpm-test-class-coverage@2' $file
            $mixed.reason | Should -BeExactly 'test-project-identity-unknown'
            $mixed.findings | Should -Be 0
        }

        It 'dispatches changed helper declarations and groups helper method attributes only with proof' {
            $content = @'
using System.Diagnostics.CodeAnalysis;
class Helper {}
[ExcludeFromCodeCoverage]
class Fixture {
    [ExcludeFromCodeCoverage]
    void Setup() {}
    [ExcludeFromCodeCoverage]
    void Teardown() {}
}
'@
            $file = New-ScopeFile -Content $content -Spans @(
                @{ startLine = 2; endLine = 2 },
                @{ startLine = 5; endLine = 5 },
                @{ startLine = 7; endLine = 7 }
            )
            $file.projectEvidence = New-ScopeEvidence
            (Get-RuleTestProjectScope $file.projectEvidence $script:repositoryId `
                    $script:sourceCommit $file.path $file.objectId) | Should -BeExactly 'test'
            $classes = @(Get-TestClassCoverageConstructs -Content $file.content `
                    -Spans $file.spans -Path $file.path -AllTestProjectClasses)
            @($classes | Where-Object { $_.recognized -and -not $_.hasExclude }).Count |
                Should -Be 1
            (Invoke-ScopeEvaluation 'bpm-test-class-coverage@1' $file).findings |
                Should -Be 0
            (Invoke-ScopeEvaluation 'bpm-redundant-method-coverage@1' $file).findings |
                Should -Be 0
            $classResult = Invoke-ScopeEvaluation 'bpm-test-class-coverage@2' $file
            $classResult.reason | Should -BeExactly 'discussion-acquisition-unavailable'
            $classResult.findings | Should -Be 1
            (Invoke-ScopeEvaluation 'bpm-redundant-method-coverage@2' $file).findings |
                Should -Be 1
            $file.projectEvidence = $null
            (Invoke-ScopeEvaluation 'bpm-redundant-method-coverage@2' $file).reason |
                Should -BeExactly 'test-project-identity-unknown'
        }
    }
}
