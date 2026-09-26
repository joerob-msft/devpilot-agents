BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.TestClassCoverage\DevPilot.TestClassCoverage.psd1" -Force

    function Parse-NamedAreEqual {
        param([string]$Source, [int]$First, [int]$Last = $First)
        return ,@(Get-NamedAreEqualConstructs -Content $Source -Path 'tests/Checks.cs' `
            -Spans @(@{ startLine = $First; endLine = $Last; state = 'complete' }))
    }
}

Describe 'Get-NamedAreEqualConstructs' {
    It 'exports one compliant construct for a fully named changed call' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
namespace My.Tests {
class Checks {
    void Verify() {
        Assert.AreEqual(expected: 1, actual: Value(), message: "text");
    }
}
}
'@
        $results = Parse-NamedAreEqual $source 5
        $results.Count | Should -Be 1
        $results[0].name | Should -BeExactly 'My.Tests.Checks.Verify'
        $results[0].declarationLine | Should -Be 4
        $results[0].startLine | Should -Be 5
        $results[0].recognized | Should -BeTrue
        $results[0].hasPositional | Should -BeFalse
        $results[0].affectedCallCount | Should -Be 1
        $results[0].affectedCallLines | Should -Be @(5)
        $results[0].path | Should -BeExactly 'tests/Checks.cs'
    }

    It 'groups changed calls by method and takes the first changed anchor' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
class Checks {
    void Verify() {
        Assert.AreEqual(1, A);
        Assert.AreEqual(expected: 2, actual: B);
        Assert.AreEqual(3, C);
    }
    void Other() {
        Assert.AreEqual(4, D);
    }
}
'@
        $results = Parse-NamedAreEqual $source 4 9
        $results.Count | Should -Be 2
        $verify = @($results | Where-Object name -eq 'Checks.Verify')[0]
        $other = @($results | Where-Object name -eq 'Checks.Other')[0]
        $verify.recognized | Should -BeTrue
        $verify.hasPositional | Should -BeTrue
        $verify.affectedCallCount | Should -Be 2
        $verify.affectedCallLines | Should -Be @(4, 6)
        $verify.startLine | Should -Be 4
        $other.affectedCallLines | Should -Be @(9)
    }

    It 'anchors a violating call after an earlier compliant changed call' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
class Checks {
    void Verify() {
        Assert.AreEqual(expected: 1, actual: 2);
        Assert.AreEqual(1, 2);
    }
}
'@
        $result = (Parse-NamedAreEqual $source 4 5)[0]
        $result.affectedCallLines | Should -Be @(5)
        $result.affectedCallCount | Should -Be 1
        $result.startLine | Should -Be 5
        $result.endLine | Should -Be 5
    }

    It 'marks same-line changed calls unknown rather than exposing duplicate anchors' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
class Checks { void Verify() {
    Assert.AreEqual(1, 2); Assert.AreEqual(3, 4);
} }
'@
        $result = (Parse-NamedAreEqual $source 3)[0]
        $result.recognized | Should -BeFalse
        $result.hasPositional | Should -BeFalse
        $result.reason | Should -BeExactly 'same-line-call-ambiguity'
        $result.startLine | Should -Be 3
        $result.affectedCallLines | Should -Be @(3)
        $result.affectedCallCount | Should -Be 1
    }

    It 'bounds the call list at 256 and flags precisely above twelve represented lines' {
        foreach ($count in @(12, 13, 257)) {
            $statements = @(1..$count | ForEach-Object { '    Assert.AreEqual(1, 2);' })
            $source = @('using Microsoft.VisualStudio.TestTools.UnitTesting;',
                'class Checks { void Verify() {') + $statements + @('} }') -join "`n"
            $result = (Parse-NamedAreEqual $source 3 (2 + $count))[0]
            $expected = [Math]::Min($count, 256)
            $result.affectedCallCount | Should -Be $expected
            $result.affectedCallLines.Count | Should -Be $expected
            $result.affectedCallLines[0] | Should -Be $result.startLine
            $result.affectedCallLines | Should -Be @(3..(2 + $expected))
            $result.callListTruncated | Should -Be ($expected -gt 12)
            $result.recognized | Should -Be ($count -le 256)
        }
    }

    It 'handles nested expressions, generics, and multiline argument lists' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
class Checks {
    void Verify() {
        Assert.AreEqual(
            expected: Get<Dictionary<string, int>>(1, 2),
            actual: Results[Next(1, 2)],
            message: string.Join(",", Parts));
        Assert.AreEqual<int>(Get(1, 2), actual: Other());
    }
}
'@
        $results = Parse-NamedAreEqual $source 4 8
        $results.Count | Should -Be 1
        $results[0].recognized | Should -BeTrue
        $results[0].hasPositional | Should -BeTrue
        $results[0].affectedCallCount | Should -Be 1
        $results[0].affectedCallLines | Should -Be @(8)
        $results[0].endLine | Should -Be 8
    }

    It 'resolves full names and aliases but not shadowed or unresolved Assert' {
        $source = @'
using M = Microsoft.VisualStudio.TestTools.UnitTesting;
using Check = global::Microsoft.VisualStudio.TestTools.UnitTesting.Assert;
class Checks {
    void Verify() {
        M.Assert.AreEqual(1, 2);
        Check.AreEqual(expected: 1, actual: 2);
        global::Microsoft.VisualStudio.TestTools.UnitTesting.Assert.AreEqual(1, 2);
    }
}
'@
        $results = Parse-NamedAreEqual $source 5 7
        $results.Count | Should -Be 1
        $results[0].recognized | Should -BeTrue
        $results[0].hasPositional | Should -BeTrue
        $results[0].affectedCallCount | Should -Be 2
        $results[0].affectedCallLines | Should -Be @(5, 7)

        $unresolved = $source.Replace('M.Assert.AreEqual', 'Assert.AreEqual')
        (Parse-NamedAreEqual $unresolved 5)[0].recognized | Should -BeFalse
        $shadow = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
class Assert { public static void AreEqual(int x, int y) {} }
class Checks { void Verify() { Assert.AreEqual(1, 2); } }
'@
        (Parse-NamedAreEqual $shadow 3)[0].recognized | Should -BeFalse
        $aliasedShadow = $source.Replace('M.Assert.AreEqual(1, 2);',
            'var M = new Other(); M.Assert.AreEqual(1, 2);')
        (Parse-NamedAreEqual $aliasedShadow 5)[0].recognized | Should -BeFalse
        $aliasConflict = @'
using Microsoft = Other;
class Checks { void Verify() {
    Microsoft.VisualStudio.TestTools.UnitTesting.Assert.AreEqual(1, 2);
} }
'@
        (Parse-NamedAreEqual $aliasConflict 3)[0].recognized | Should -BeFalse
        $member = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
class Checks { void Verify() {
    Factory().Assert.AreEqual(1, 2);
} }
'@
        (Parse-NamedAreEqual $member 3)[0].recognized | Should -BeFalse
    }

    It 'refuses overloaded methods and uncertain competing imports' {
        $overloads = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
class Checks {
    void Verify(int value) { Assert.AreEqual(1, value); }
    void Verify(string value) { Assert.AreEqual(1, value); }
}
'@
        @((Parse-NamedAreEqual $overloads 3 4) | Where-Object recognized).Count |
            Should -Be 0
        $otherImport = $overloads.Replace(
            'using Microsoft.VisualStudio.TestTools.UnitTesting;',
            "using Microsoft.VisualStudio.TestTools.UnitTesting;`nusing Other;")
        (Parse-NamedAreEqual $otherImport 4)[0].recognized | Should -BeFalse
    }

    It 'ignores comments and strings, and refuses changes without an exact opening anchor' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
class Checks {
    void Verify() {
        // Assert.AreEqual(1, 2);
        var text = "Assert.AreEqual(1, 2)";
        Assert
            .AreEqual(1, 2);
    }
}
'@
        (Parse-NamedAreEqual $source 4 5).Count | Should -Be 0
        $result = Parse-NamedAreEqual $source 7
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeFalse
        $result[0].hasPositional | Should -BeFalse
        $result[0].startLine | Should -Be 6
    }

    It 'treats literal arguments as supplied positional arguments without inspecting their text' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
class Checks { void Verify() {
    Assert.AreEqual("Assert.AreEqual(0, 0)", 'x');
    Assert.AreEqual(expected: "one", actual: "two");
} }
'@
        $results = Parse-NamedAreEqual $source 3 4
        $results.Count | Should -Be 1
        $results[0].recognized | Should -BeTrue
        $results[0].hasPositional | Should -BeTrue
        $results[0].affectedCallLines | Should -Be @(3)
    }

    It 'finds positional arguments before and after named arguments including an extra supplied argument' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
class Checks { void Verify() {
    Assert.AreEqual(0, actual: value, message: "x");
    Assert.AreEqual(expected: 0, actual: value, "x");
    Assert.AreEqual(expected: 0, actual: value, message: "x");
} }
'@
        $results = Parse-NamedAreEqual $source 3 5
        $results.Count | Should -Be 1
        $results[0].recognized | Should -BeTrue
        $results[0].hasPositional | Should -BeTrue
        $results[0].startLine | Should -Be 3
        $results[0].affectedCallCount | Should -Be 2
        $results[0].affectedCallLines | Should -Be @(3, 4)
    }

    It 'fails closed on preprocessor directives and malformed syntax' {
        $source = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
#if TEST
class Checks { void Verify() { Assert.AreEqual(1, 2); } }
#endif
'@
        $result = Parse-NamedAreEqual $source 3
        $result.Count | Should -Be 1
        $result[0].recognized | Should -BeFalse
        $broken = $source.Replace('#if TEST', '').Replace('#endif', '').Replace(');', ';')
        (Parse-NamedAreEqual $broken 3)[0].recognized | Should -BeFalse
    }
}
