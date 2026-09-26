BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.TestClassCoverage\DevPilot.TestClassCoverage.psd1" -Force

    function Get-CoverageTestResults {
        param([string]$Source, [int]$First = 1, [int]$Last = 100)
        return ,@(Get-TestClassCoverageConstructs -Content $Source -Path 'tests/Sample.cs' `
                -Spans @(@{ startLine = $First; endLine = $Last; state = 'complete' }))
    }
}

Describe 'Get-TestClassCoverageConstructs' {
    It 'exports the standalone contract and retains class declaration anchors' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
[TestClass]
[global::System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverageAttribute]
public partial class Sample<T>
    where T : class
{
    [TestMethod] public void Method() {}
}
'@
        $result = Get-CoverageTestResults $source 2 2
        $result.Count | Should -Be 1
        $result[0] | Should -BeOfType [hashtable]
        $result[0].name | Should -Be 'Sample'
        $result[0].declarationLine | Should -Be 4
        $result[0].startLine | Should -Be 2
        $result[0].endLine | Should -Be 6
        $result[0].recognized | Should -BeTrue
        $result[0].hasTestClass | Should -BeTrue
        $result[0].hasExclude | Should -BeTrue
        $result[0].path | Should -Be 'tests/Sample.cs'
        $result[0].reason | Should -Be 'class-level-coverage-exclusion-present'
    }

    It 'detects missing class-level exclusion, but not method-only changes' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
[TestClass]
public class Missing
{
    [TestMethod]
    [global::System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverage]
    public void Method() {}
}
'@
        $result = Get-CoverageTestResults $source 2 3
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeTrue
        $result[0].hasExclude | Should -BeFalse
        (Get-CoverageTestResults $source 5 7).Count | Should -Be 0
        $methodAttribute = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
class Ordinary {
    [TestClass] void IncorrectlyAttributedMethod() {}
}
'@
        (Get-CoverageTestResults $methodAttribute 3 3).Count | Should -Be 0
    }

    It 'resolves separated lists, namespace imports and aliases on the class only' {
        $source = @'
using Unit = Microsoft.VisualStudio.TestTools.UnitTesting;
using Coverage = global::System.Diagnostics.CodeAnalysis;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Diagnostics.CodeAnalysis;
namespace Tests {
    [Unit.TestClassAttribute]
    [Obsolete]
    [Coverage.ExcludeFromCodeCoverage]
    internal class First {}
}
[TestClass, Obsolete]
[ExcludeFromCodeCoverageAttribute]
class Second {}
'@
        $results = Get-CoverageTestResults $source
        $results.Count | Should -Be 2
        @($results | Where-Object { $_.recognized -and $_.hasExclude }).Count | Should -Be 2
        $results[0].name | Should -Be 'Tests.First'
    }

    It 'supports type aliases and nested partial declarations without confusing methods' {
        $source = @'
using TC = Microsoft.VisualStudio.TestTools.UnitTesting.TestClassAttribute;
using Ex = System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverageAttribute;
class Outer {
    [TC]
    [Ex]
    partial class Inner<T> { }
    [TC] void Method() {}
}
'@
        $results = Get-CoverageTestResults $source
        $results.Count | Should -Be 1
        $results[0].name | Should -Be 'Outer.Inner'
        $results[0].hasExclude | Should -BeTrue
        (Get-CoverageTestResults $source 7 7).Count | Should -Be 0
    }

    It 'recognizes both attributes in one class-level list' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Diagnostics.CodeAnalysis;
[TestClass, ExcludeFromCodeCoverage]
class Together {}
'@
        $result = Get-CoverageTestResults $source 3 3
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeTrue
        $result[0].hasExclude | Should -BeTrue
    }

    It 'joins attribute lists separated by multiline comments and preserves exact class line' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Diagnostics.CodeAnalysis;
[TestClass]
/* misleading:
 [TestMethod] class Decoy {}
*/
[ExcludeFromCodeCoverage]
public partial
class Actual
{}
'@
        $result = Get-CoverageTestResults $source 7 7
        $result.Count | Should -Be 1
        $result[0].name | Should -Be 'Actual'
        $result[0].declarationLine | Should -Be 9
        $result[0].recognized | Should -BeTrue
        $result[0].hasExclude | Should -BeTrue
    }

    It 'does not treat comments, regular, interpolated, verbatim or raw strings as attributes' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
// [TestClass]
/* [TestClass]
   [ExcludeFromCodeCoverage] */
var a = "[TestClass] class False {}";
var b = @"[TestClass] ""class False {}""";
var c = $"""[TestClass]
class False {}
""";
var d = $"[TestClass] {1}";
class Real {}
'@
        (Get-CoverageTestResults $source).Count | Should -Be 0
    }

    It 'marks unresolved target attributes and unrecognized class-like declarations unknown' {
        $unresolved = @'
[TestClass]
class Maybe {}
'@
        $result = Get-CoverageTestResults $unresolved
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeFalse
        $result[0].hasTestClass | Should -BeFalse
        $missingExcludeUsing = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
[TestClass, ExcludeFromCodeCoverage]
class Maybe {}
'@
        (Get-CoverageTestResults $missingExcludeUsing)[0].recognized | Should -BeFalse
        $record = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
[TestClass]
record class NotAClass {}
'@
        $result = Get-CoverageTestResults $record
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeFalse
    }

    It 'does not use TestClass imports outside their namespace scope' {
        $source = @'
namespace A {
    using Microsoft.VisualStudio.TestTools.UnitTesting;
    [TestClass] class Actual {}
}
namespace B {
    [TestClass] class Unresolved {}
}
'@
        $results = Get-CoverageTestResults $source
        $results.Count | Should -Be 2
        $results[0].recognized | Should -BeTrue
        $results[1].recognized | Should -BeFalse
    }

    It 'does not claim a violation when aliases or short exclusion names are unresolved' {
        $source = @'
using Unit = Unknown.Namespace;
[Unit.TestClass]
class Aliased {}
'@
        $result = Get-CoverageTestResults $source
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeFalse

        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Coverage = Unknown.Namespace;
[TestClass]
[Coverage.ExcludeFromCodeCoverage]
class UnresolvedExclusion {}
'@
        $result = Get-CoverageTestResults $source
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeFalse
        $result[0].hasExclude | Should -BeFalse
    }

    It 'keeps competing imports and locally shadowed attribute names unknown' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Custom.Attributes;
namespace Custom.Attributes {
    class TestClassAttribute : System.Attribute {}
}
[TestClass] class MaybeOtherAttribute {}
'@
        (Get-CoverageTestResults $source)[0].recognized | Should -BeFalse
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
namespace Scoped {
    class TestClassAttribute : System.Attribute {}
    [TestClass] class MaybeLocalAttribute {}
}
'@
        $result = Get-CoverageTestResults $source
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeFalse
    }

    It 'does not treat an unrelated import alone as a conflicting attribute declaration' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Diagnostics.CodeAnalysis;
using Custom.Diagnostics;
[TestClass]
[ExcludeFromCodeCoverage]
class Recognized {}
'@
        $result = Get-CoverageTestResults $source
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeTrue
        $result[0].hasExclude | Should -BeTrue
    }

    It 'does not claim a missing attribute on one part of an incomplete partial class' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
[TestClass]
public partial class SplitTests {}
'@
        $result = Get-CoverageTestResults $source
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeFalse
        $result[0].reason | Should -BeExactly 'partial-class-coverage-unknown'
    }

    It 'does not report a clean file after an ambiguous interpolated string swallows a class' {
        foreach ($expression in @(
                'public class Helper { string Value() => $"pre {1 /* " */} post"; }',
                'public class Helper { string Value() => $"pre {1} /* " */ post"; }'
            )) {
            $source = @(
                'using Microsoft.VisualStudio.TestTools.UnitTesting;'
                $expression
                '[TestClass]'
                'public class MissingTests {}'
            ) -join "`n"
            $result = Get-CoverageTestResults $source
            $result.Count | Should -BeGreaterThan 0
            @($result | Where-Object recognized).Count | Should -Be 0
            $result[0].reason | Should -BeExactly 'lexical-input-unknown'
        }
    }

    It 'recognizes fully qualified attributes and file-scoped namespace class symbols' {
        $source = @'
namespace A.B;
[global::Microsoft.VisualStudio.TestTools.UnitTesting.TestClassAttribute]
[global::System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverage]
partial class Tests {}
'@
        $result = Get-CoverageTestResults $source
        $result.Count | Should -Be 1
        $result[0].name | Should -Be 'A.B.Tests'
        $result[0].recognized | Should -BeTrue
        $result[0].hasExclude | Should -BeTrue
    }

    It 'accepts non-global fully qualified coverage exclusion with and without Attribute suffix' {
        foreach ($suffix in @('', 'Attribute')) {
            $source = @"
[Microsoft.VisualStudio.TestTools.UnitTesting.TestClass]
[System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverage$suffix]
class Qualified {}
"@
            $result = Get-CoverageTestResults $source
            $result.Count | Should -Be 1
            $result[0].recognized | Should -BeTrue
            $result[0].hasTestClass | Should -BeTrue
            $result[0].hasExclude | Should -BeTrue
        }
    }

    It 'accepts escaped C# identifiers in attribute and class names' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
[@TestClass] class @Escaped {}
'@
        $result = Get-CoverageTestResults $source
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeTrue
        $result[0].name | Should -Be 'Escaped'
    }

    It 'resolves namespace alias qualifiers and treats extern aliases as unknown' {
        $source = @'
using Unit = Microsoft.VisualStudio.TestTools.UnitTesting;
using Coverage = System.Diagnostics.CodeAnalysis;
[Unit::TestClass]
[Coverage::ExcludeFromCodeCoverageAttribute]
class Qualified {}
'@
        $result = Get-CoverageTestResults $source
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeTrue
        $result[0].hasExclude | Should -BeTrue
        $source = @'
extern alias Unknown;
[Unknown::TestClass]
class Unresolved {}
'@
        (Get-CoverageTestResults $source)[0].recognized | Should -BeFalse
    }

    It 'does not report changes to unrelated attributes or the class body' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
[TestClass]
[Obsolete]
class Actual {
    void Changed() {}
}
'@
        (Get-CoverageTestResults $source 5 5).Count | Should -Be 0
        (Get-CoverageTestResults $source 3 3).Count | Should -Be 1
    }

    It 'does not report a changed class without a TestClass attribute' {
        $source = @'
using System.Diagnostics.CodeAnalysis;
class Ordinary
{
    [ExcludeFromCodeCoverage]
    void Method() {}
}
'@
        (Get-CoverageTestResults $source 2 2).Count | Should -Be 0
        (Get-CoverageTestResults $source 4 5).Count | Should -Be 0
    }

    It 'anchors both classes in two large source generations without leaking sibling attributes' {
        foreach ($generation in @(
                @{ total = 1013; missingLine = 25 },
                @{ total = 1063; missingLine = 26 }
            )) {
            $lines = [string[]]::new($generation.total)
            for ($i = 0; $i -lt $lines.Length; $i++) { $lines[$i] = '// padding' }
            $lines[0] = 'using Microsoft.VisualStudio.TestTools.UnitTesting;'
            $lines[1] = 'using System.Diagnostics.CodeAnalysis;'
            $lines[21] = '[TestClass]'
            $lines[$generation.missingLine - 1] = 'public class MissingTests {'
            $lines[$generation.missingLine] = '}'
            $lines[29] = '[TestClass]'
            $lines[32] = '[ExcludeFromCodeCoverage]'
            $lines[33] = 'public class CoveredTests {}'
            $source = $lines -join "`n"

            $results = Get-CoverageTestResults $source 1 $generation.total
            $results.Count | Should -Be 2
            $missing = @($results | Where-Object name -CEQ 'MissingTests')[0]
            $covered = @($results | Where-Object name -CEQ 'CoveredTests')[0]
            $missing.declarationLine | Should -Be $generation.missingLine
            $missing.startLine | Should -Be 22
            $missing.hasTestClass | Should -BeTrue
            $missing.hasExclude | Should -BeFalse
            $covered.declarationLine | Should -Be 34
            $covered.startLine | Should -Be 30
            $covered.hasTestClass | Should -BeTrue
            $covered.hasExclude | Should -BeTrue

            $changedOnly = Get-CoverageTestResults $source $generation.missingLine $generation.missingLine
            $changedOnly.Count | Should -Be 1
            $changedOnly[0].name | Should -Be 'MissingTests'
        }
    }

    It 'treats conditional C# declarations as unknown and refuses unbounded inputs' {
        $source = @'
#if TESTS
using Microsoft.VisualStudio.TestTools.UnitTesting;
[TestClass]
class Conditional {}
#endif
'@
        (Get-CoverageTestResults $source)[0].recognized | Should -BeFalse
        { Get-TestClassCoverageConstructs -Content ('a' * (16MB + 1)) `
                -Spans @(@{ startLine = 1; endLine = 1 }) -Path 'Huge.cs' } |
            Should -Throw
    }
}
