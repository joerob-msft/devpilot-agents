#requires -Version 7.0

BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.ContextualConventions\DevPilot.ContextualConventions.psd1" -Force

    function Invoke-CoverageRule {
        param(
            [Parameter(Mandatory)][string]$Source,
            [Parameter(Mandatory)][string]$Project,
            [object[]]$Spans = @([ordered]@{
                    startLine = 1
                    endLine = 100
                })
        )
        $files = @(
            [ordered]@{
                path = 'src/Tests/Cases.cs'
                content = $Source
                state = 'complete'
                spans = $Spans
            },
            [ordered]@{
                path = 'src/Tests/Tests.csproj'
                content = $Project
                state = 'complete'
                spans = @()
                contextOnly = $true
            })
        return @(Get-ContextualConventionOutcomes `
                -Content $Source -Path 'src/Tests/Cases.cs' `
                -Spans $Spans -SnapshotFiles $files |
                Where-Object {
                    $_.ruleId -ceq
                        'test-class-code-coverage'
                })[0]
    }

    $script:TestProject = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <CoverageDisabled>true</CoverageDisabled>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.7.1" />
  </ItemGroup>
</Project>
'@
}

Describe 'Test-project class coverage exclusion rule' {
    It 'finds a helper class without requiring TestClass' {
        $result = Invoke-CoverageRule `
            -Source 'public class Helper { }' `
            -Project $script:TestProject
        $result.state | Should -BeExactly 'violation'
        $result.line | Should -Be 1
        $result.symbol | Should -BeExactly 'Helper'
    }

    It 'recognizes only the framework class attribute' {
        $covered = @(
            'using System.Diagnostics.CodeAnalysis; [ExcludeFromCodeCoverage] class Covered { }'
            'namespace Tests { using System.Diagnostics.CodeAnalysis; [ExcludeFromCodeCoverage] class Covered { } }'
            '[global::System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverageAttribute] class Covered { }'
            'using Coverage = System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverageAttribute; [Coverage] class Covered { }'
        )
        foreach ($source in $covered) {
            (Invoke-CoverageRule -Source $source `
                -Project $script:TestProject).state |
                Should -BeExactly 'compliant'
        }

        $unrelated = @(
            'using Other; [ExcludeFromCodeCoverage] class Helper { }'
            'using System.Diagnostics.CodeAnalysis; class ExcludeFromCodeCoverageAttribute : System.Attribute { } [ExcludeFromCodeCoverage] class Helper { }'
            '[assembly: System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverage] class Helper { }'
        )
        foreach ($source in $unrelated) {
            (Invoke-CoverageRule -Source $source `
                -Project $script:TestProject).state |
                Should -BeExactly 'violation'
        }
    }

    It 'uses parsed unconditional project metadata' {
        $commented = '<Project Sdk="Microsoft.NET.Sdk"><!-- <IsTestProject>true</IsTestProject> --></Project>'
        (Invoke-CoverageRule -Source 'class Product { }' `
            -Project $commented).state |
            Should -BeExactly 'compliant'

        $conditional = '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><IsTestProject Condition="''$(Configuration)'' == ''Test''">true</IsTestProject></PropertyGroup></Project>'
        (Invoke-CoverageRule -Source 'class MaybeTest { }' `
            -Project $conditional).state |
            Should -BeExactly 'unknown'
    }

    It 'keeps each definite class attributable and preserves partial ambiguity' {
        $source = @(
            'class FirstHelper { }'
            'partial class UncertainHelper { }'
            'class SecondHelper { }'
        ) -join "`n"
        $files = @(
            [ordered]@{
                path = 'src/Tests/Cases.cs'
                content = $source
                state = 'complete'
                spans = @([ordered]@{
                        startLine = 1
                        endLine = 3
                    })
            },
            [ordered]@{
                path = 'src/Tests/Tests.csproj'
                content = $script:TestProject
                state = 'complete'
                spans = @()
            })
        $results = @(Get-ContextualConventionOutcomes `
                -Content $source -Path 'src/Tests/Cases.cs' `
                -Spans $files[0].spans -SnapshotFiles $files |
                Where-Object {
                    $_.ruleId -ceq
                        'test-class-code-coverage'
                })
        @($results | Where-Object state -CEQ violation |
            ForEach-Object symbol) |
            Should -Be @('FirstHelper', 'SecondHelper')
        @($results | Where-Object state -CEQ unknown) |
            Should -HaveCount 0
    }

    It 'includes record classes and anchors the changed declaration header line' {
        $record = Invoke-CoverageRule `
            -Source 'public record class HelperRecord(int Value);' `
            -Project $script:TestProject
        $record.state | Should -BeExactly 'violation'
        $record.symbol | Should -BeExactly 'HelperRecord'

        $source = @(
            'public class'
            '    MultilineHelper'
            '{'
            '}'
        ) -join "`n"
        $multiline = Invoke-CoverageRule -Source $source `
            -Project $script:TestProject `
            -Spans @([ordered]@{
                    startLine = 2
                    endLine = 2
                })
        $multiline.state | Should -BeExactly 'violation'
        $multiline.line | Should -Be 2
        $multiline.symbol | Should -BeExactly 'MultilineHelper'

        $bodyOnly = Invoke-CoverageRule -Source $source `
            -Project $script:TestProject `
            -Spans @([ordered]@{
                    startLine = 3
                    endLine = 3
                })
        $bodyOnly.state | Should -BeExactly 'compliant'
    }

    It 'withholds a partial-only class and missing project evidence' {
        $partial = Invoke-CoverageRule `
            -Source 'partial class Helper { }' `
            -Project $script:TestProject
        $partial.state | Should -BeExactly 'unknown'
        $partial.reason | Should -BeExactly `
            'partial-class-coverage-attribute-unproven'

        $source = 'class Helper { }'
        $missing = @(Get-ContextualConventionOutcomes `
                -Content $source -Path 'src/Tests/Cases.cs' `
                -Spans @([ordered]@{
                        startLine = 1
                        endLine = 1
                    }) `
                -SnapshotFiles @([ordered]@{
                        path = 'src/Tests/Cases.cs'
                        content = $source
                        state = 'complete'
                        spans = @([ordered]@{
                                startLine = 1
                                endLine = 1
                            })
                    }) |
                Where-Object {
                    $_.ruleId -ceq
                        'test-class-code-coverage'
                })[0]
        $missing.state | Should -BeExactly 'unknown'
        $missing.reason | Should -BeExactly `
            'test-project-evidence-missing'
    }
}
