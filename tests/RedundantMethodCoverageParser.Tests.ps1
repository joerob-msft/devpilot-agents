BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.TestClassCoverage\DevPilot.TestClassCoverage.psd1" -Force
}

Describe 'Get-RedundantMethodCoverageConstructs' {
    It 'accepts changed stand-alone method exclusion only under an excluded MSTest class' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Diagnostics.CodeAnalysis;
[TestClass]
[ExcludeFromCodeCoverage]
class Tests {
    [TestMethod]
    [ExcludeFromCodeCoverage]
    public void Check() {}
}
'@
        $result = @(Get-RedundantMethodCoverageConstructs -Content $source `
            -Path 'tests/Tests.cs' -Spans @(@{ startLine = 7; endLine = 7; state = 'complete' }))
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeTrue
        $result[0].hasExclude | Should -BeTrue
        $result[0].startLine | Should -Be 7
        $result[0].name | Should -BeExactly 'Tests'
        $result[0].affectedMethodCount | Should -Be 1
        $result[0].affectedMethods | Should -Be @('Check')
        @(Get-RedundantMethodCoverageConstructs -Content $source `
            -Path 'tests/Tests.cs' -Spans @(@{ startLine = 4; endLine = 4; state = 'complete' })).Count |
            Should -Be 0
    }

    It 'keeps unresolved aliases, partial types, malformed input, and mixed lists unknown' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Diagnostics.CodeAnalysis;
[TestClass]
[ExcludeFromCodeCoverage]
partial class Tests {
    [TestMethod]
    [ExcludeFromCodeCoverage]
    void Check() {}
}
'@
        $result = @(Get-RedundantMethodCoverageConstructs -Content $source `
            -Path 'tests/Tests.cs' -Spans @(@{ startLine = 7; endLine = 7; state = 'complete' }))
        $result[0].recognized | Should -BeFalse
        $source = $source.Replace('partial class', 'class').Replace(
            '    [ExcludeFromCodeCoverage]', '    [ExcludeFromCodeCoverage, Obsolete]')
        $result = @(Get-RedundantMethodCoverageConstructs -Content $source `
            -Path 'tests/Tests.cs' -Spans @(@{ startLine = 7; endLine = 7; state = 'complete' }))
        $result[0].recognized | Should -BeFalse
        $malformed = $source.Substring(0, $source.LastIndexOf('}'))
        $result = @(Get-RedundantMethodCoverageConstructs -Content $malformed `
            -Path 'tests/Tests.cs' -Spans @(@{ startLine = 7; endLine = 7; state = 'complete' }))
        $result[0].reason | Should -BeExactly 'lexical-input-unknown'
        $alias = $source.Replace('[ExcludeFromCodeCoverage, Obsolete]',
            '[Unknown.ExcludeFromCodeCoverage]')
        $result = @(Get-RedundantMethodCoverageConstructs -Content $alias `
            -Path 'tests/Tests.cs' -Spans @(@{ startLine = 7; endLine = 7; state = 'complete' }))
        @($result | Where-Object recognized).Count | Should -Be 0
    }

    It 'isolates a conditional unrelated using alias before the declaration' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Diagnostics.CodeAnalysis;
#if NET_TEST
using Unrelated = Example.Helper;
#endif
[TestClass]
[ExcludeFromCodeCoverage]
class Tests {
    [TestMethod]
    [ExcludeFromCodeCoverage]
    void Check() {}
}
'@
        $result = @(Get-RedundantMethodCoverageConstructs -Content $source `
            -Path 'tests/Tests.cs' -Spans @(@{ startLine = 10; endLine = 10; state = 'complete' }))
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeTrue
        $relevant = $source.Replace('Example.Helper', 'System.Diagnostics.CodeAnalysis')
        $result = @(Get-RedundantMethodCoverageConstructs -Content $relevant `
            -Path 'tests/Tests.cs' -Spans @(@{ startLine = 10; endLine = 10; state = 'complete' }))
        @($result | Where-Object recognized).Count | Should -Be 0
    }

    It 'refuses duplicate exclusions and a multiline attribute without a changed opening anchor' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Diagnostics.CodeAnalysis;
[TestClass, ExcludeFromCodeCoverage]
class Tests {
    [TestMethod]
    [ExcludeFromCodeCoverage]
    [ExcludeFromCodeCoverage]
    void Check() {}
}
'@
        $result = @(Get-RedundantMethodCoverageConstructs -Content $source `
            -Path 'tests/Tests.cs' -Spans @(@{ startLine = 7; endLine = 7; state = 'complete' }))
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeFalse
        $source = $source -replace `
            '\[ExcludeFromCodeCoverage\]\r?\n    \[ExcludeFromCodeCoverage\]', `
            "[`n        ExcludeFromCodeCoverage`n    ]"
        $result = @(Get-RedundantMethodCoverageConstructs -Content $source `
            -Path 'tests/Tests.cs' -Spans @(@{ startLine = 7; endLine = 7; state = 'complete' }))
        @($result | Where-Object recognized).Count | Should -Be 0
    }

    It 'groups many changed method attributes into one class with a bounded method list' {
        $methods = @(1..22 | ForEach-Object {
            "    [TestMethod]`n    [ExcludeFromCodeCoverage]`n    void Check$_() {}"
        })
        $source = @(
            'using Microsoft.VisualStudio.TestTools.UnitTesting;'
            'using System.Diagnostics.CodeAnalysis;'
            '[TestClass]'
            '[ExcludeFromCodeCoverage]'
            'class Tests {'
            $methods
            '}'
        ) -join "`n"
        $result = @(Get-RedundantMethodCoverageConstructs -Content $source `
            -Path 'tests/Tests.cs' -Spans @(@{ startLine = 1; endLine = 72; state = 'complete' }))
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeTrue
        $result[0].startLine | Should -Be 7
        $result[0].affectedMethodCount | Should -Be 22
        @($result[0].affectedMethods).Count | Should -Be 12
        $result[0].methodListTruncated | Should -BeTrue

        $ambiguous = $source -replace `
            '(?m)^    \[ExcludeFromCodeCoverage\](?=\r?\n    void Check22)', `
            '    [ExcludeFromCodeCoverage, Obsolete]'
        $unknown = @(Get-RedundantMethodCoverageConstructs -Content $ambiguous `
            -Path 'tests/Tests.cs' -Spans @(@{ startLine = 1; endLine = 72; state = 'complete' }))
        $unknown.Count | Should -Be 1
        $unknown[0].recognized | Should -BeFalse
    }
}
