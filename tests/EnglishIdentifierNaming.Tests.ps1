#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.ContextualConventions\DevPilot.ContextualConventions.psd1') -Force

    function Invoke-EnglishNamingCase {
        param(
            [string]$Content,
            [string]$Path = 'src/XmlComposer.cs',
            [object[]]$Spans = @(@{ startLine = 1; endLine = 1000 }),
            [object[]]$AdditionalFiles = @()
        )
        $file = @{ path = $Path; content = $Content; state = 'complete'; spans = $Spans }
        return @(Get-ContextualConventionOutcomes -Content $Content -Path $Path `
            -Spans $Spans -SnapshotFiles (@($file) + $AdditionalFiles) |
            Where-Object ruleId -CEQ english-identifier-naming)
    }

    $script:OriginalPropertyCase = @'
using System;
using System.Linq;
using Newtonsoft.Json.Linq;
class XmlComposer {
    static class XmlToJsonConstants { public const string JsonKeyGroupPrefix = ":group"; }
    void HandleGroup(JObject holder) {
        var syntheticProp = holder.Properties().FirstOrDefault(p => p.Name.StartsWith(XmlToJsonConstants.JsonKeyGroupPrefix, StringComparison.Ordinal));
    }
}
'@
}

Describe 'Source-backed English identifier naming' {
    It 'registers the additive rule without promoting it into historical bundles' {
        . (Join-Path $repoRoot 'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')
        $ids = @(Get-ContextualConventionRuleIds)
        $ids | Should -HaveCount 27
        $ids[-1] | Should -BeExactly english-identifier-naming
        ($script:ApprovedContextualRuleIds -join ',') | Should -BeExactly ($ids -join ',')
        $policy = Get-Content -LiteralPath (Join-Path $repoRoot `
            'src\DevPilot.OwnerCapability\Policy\contextual-conventions.v1.json') -Raw |
            ConvertFrom-Json -AsHashtable
        ($policy.rules.id -join ',') | Should -BeExactly ($ids -join ',')
        $policy.sourceAuthority.englishIdentifierNaming.commit |
            Should -BeExactly ff0692776598b8eb07993e8c45e0be03b7e32fa3
        $currentPredecessor = @{
            hash = 'v1:sha256:9221ce2c9cb4777bb0cbfc0ed11dea9e0e68328ce98137a026c4b68b4c80c756'
            length = 11517
        }
        (Test-ContextualConventionPriorRuleIds -Rule $currentPredecessor `
            -RuleIds @($ids | Where-Object { $_ -cne 'english-identifier-naming' })) | Should -BeTrue
        (Test-ContextualConventionPriorRuleIds -Rule $currentPredecessor `
            -RuleIds @('english-identifier-naming')) | Should -BeFalse
        $currentPredecessor.length++
        (Test-ContextualConventionPriorRuleIds -Rule $currentPredecessor `
            -RuleIds @('explicit-string-comparison')) | Should -BeFalse
    }

    It 'finds the original reviewed p lambda and accepts its property successor' {
        $before = @(Invoke-EnglishNamingCase $script:OriginalPropertyCase)
        $before | Should -HaveCount 1
        $before[0].state | Should -BeExactly violation
        $before[0].line | Should -Be 7
        $before[0].symbol | Should -BeExactly p
        $before[0].evidence | Should -Match "'p' 'property'"
        $before[0].evidence | Should -Match 'update its uses'
        $after = @(Invoke-EnglishNamingCase (
            $script:OriginalPropertyCase.Replace('p => p.Name', 'property => property.Name')))
        $after | Should -HaveCount 1
        $after[0].state | Should -BeExactly compliant
    }

    It 'supports a bound <Form> parameter without spelling-based type guesses' -TestCases @(
        @{ Form = 'parenthesized'; Parameter = '(p)' }
        @{ Form = 'typed'; Parameter = '(JProperty p)' }
        @{ Form = 'qualified'; Parameter = '(global::Newtonsoft.Json.Linq.JProperty p)' }
        @{ Form = 'escaped'; Parameter = '@p' }
    ) {
        param($Form, $Parameter)
        $content = $script:OriginalPropertyCase.Replace('p => p.Name', "$Parameter => p.Name")
        $result = @(Invoke-EnglishNamingCase $content)
        $result[0].state | Should -BeExactly violation
        $result[0].symbol | Should -BeExactly p
    }

    It 'recognizes the semantic naming pattern for arbitrary letter <Name>' -TestCases @(
        @{Name='x'}, @{Name='q'}, @{Name='z'}, @{Name='P'}, @{Name='a'}
    ) {
        param($Name)
        $content = $script:OriginalPropertyCase.Replace('p => p.Name', "$Name => $Name.Name")
        $result = @(Invoke-EnglishNamingCase $content)
        $result[0].state | Should -BeExactly violation
        $result[0].symbol | Should -BeExactly $Name
        $result[0].evidence | Should -Match ([regex]::Escape("'$Name' 'property'"))
    }

    It 'leaves <Name> outside its supported naming judgment' -TestCases @(
        @{ Name = 'loop counters'; Content = 'class C { void M() { for (int i=0; i<1; i++) {} } }' }
        @{ Name = 'common acronyms and domain names'; Content = 'class C { string xml; string id; string sku; string etag; }' }
        @{ Name = 'unrelated local p'; Content = 'class C { void M() { int p=2; } }' }
        @{ Name = 'method parameter p'; Content = 'class C { int M(int p) => p; }' }
        @{ Name = 'discards'; Content = 'class C { void M() { System.Func<int,int> f = _ => 1; } }' }
        @{ Name = 'generic exception ex'; Content = 'class C { void M() { try {} catch (System.Exception ex) {} } }' }
        @{ Name = 'English property'; Content = 'using Newtonsoft.Json.Linq; class C { void M() { System.Func<JProperty,bool> f = property => property != null; } }' }
        @{ Name = 'descriptive currentProperty'; Content = 'using Newtonsoft.Json.Linq; class C { void M() { System.Func<JProperty,bool> f = currentProperty => currentProperty != null; } }' }
        @{ Name = 'another English name'; Content = 'using Newtonsoft.Json.Linq; class C { void M() { System.Func<JProperty,bool> f = candidate => candidate != null; } }' }
        @{ Name = 'strings and comments'; Content = 'class C { string Text = "FirstOrDefault(p => p.Name)"; /* p => p.Name */ }' }
    ) {
        param($Name, $Content)
        $result = @(Invoke-EnglishNamingCase $Content)
        $result | Should -HaveCount 1
        $result[0].state | Should -BeExactly compliant
        $result[0].reason | Should -BeExactly no-supported-naming-candidate
    }

    It 'keeps intent or role unproven for <Name>' -TestCases @(
        @{ Name = 'unknown receiver'; Content = 'class C { void M(Missing holder) { var result = holder.Properties().FirstOrDefault(p => p.Name != null); } }' }
        @{ Name = 'dynamic receiver'; Content = 'class C { void M(dynamic holder) { var result = holder.Properties().FirstOrDefault(p => p.Name != null); } }' }
        @{ Name = 'ambiguous alias'; Content = 'using Property = Missing.JProperty; class C { void M() { System.Func<Property,bool> f = p => p != null; } }' }
        @{ Name = 'malformed syntax'; Content = 'class C { void M( { System.Func<int,bool> f = p => p > 0; } }' }
        @{ Name = 'conditional import'; Content = "#if FEATURE`nusing Property = Missing.Property;`n#else`nusing Property = Newtonsoft.Json.Linq.JProperty;`n#endif`nclass C { void M() { System.Func<Property,bool> f = p => p != null; } }" }
        @{ Name = 'conditional active lambda'; Content = "class C { void M() {`n#if !FEATURE`nSystem.Func<Newtonsoft.Json.Linq.JProperty,bool> f = p => p != null;`n#endif`n} }" }
        @{ Name = 'conditional inactive lambda'; Content = "class C { void M() {`n#if FEATURE`nSystem.Func<Newtonsoft.Json.Linq.JProperty,bool> f = p => p != null;`n#endif`n} }" }
    ) {
        param($Name, $Content)
        $result = @(Invoke-EnglishNamingCase $Content)
        $result | Should -HaveCount 1
        $result[0].state | Should -BeExactly unknown
        $result[0].evidence | Should -BeNullOrEmpty
    }

    It 'does not invent a property noun for <Name>' -TestCases @(
        @{ Name = 'different domain role'; Content = 'class C { void M() { System.Func<int,bool> f = p => p > 0; } }' }
        @{ Name = 'shadowed JProperty'; Content = 'using Newtonsoft.Json.Linq; class JProperty {} class C { void M() { System.Func<JProperty,bool> f = p => p != null; } }' }
        @{ Name = 'shadowed namespace'; Content = 'namespace Newtonsoft.Json.Linq { class JProperty {} } class C { void M() { System.Func<Newtonsoft.Json.Linq.JProperty,bool> f = p => p != null; } }' }
        @{ Name = 'unrelated foreign property'; Content = 'namespace Foreign { class JProperty {} } class C { void M() { System.Func<Foreign.JProperty,bool> f = x => x != null; } }' }
    ) {
        param($Name, $Content)
        $result = @(Invoke-EnglishNamingCase $Content)
        $result[0].state | Should -BeExactly compliant
        $result[0].reason | Should -BeExactly unsupported-identifier-role
    }

    It 'resolves aliases and snapshot-local shadowing against trusted JSON metadata' {
        $content = 'using Property = Newtonsoft.Json.Linq.JProperty; class C { void M() { System.Func<Property,bool> f = p => p != null; } }'
        @(Invoke-EnglishNamingCase $content)[0].state | Should -BeExactly violation
        $shadow = @{ path='src/Shadow.cs'; state='complete'; spans=@(); content='namespace Newtonsoft.Json.Linq { class JProperty {} }' }
        @(Invoke-EnglishNamingCase $content -AdditionalFiles @($shadow))[0].state | Should -BeExactly compliant
        $shadow.state = 'unknown'
        @(Invoke-EnglishNamingCase $content -AdditionalFiles @($shadow))[0].state | Should -BeExactly unknown
    }

    It 'withholds inferred roles when unproven conditional overloads change lambda target typing' {
        $content = @'
using Newtonsoft.Json.Linq;
class C {
#if FEATURE
    void Select(System.Func<int,bool> predicate) {}
#else
    void Select(System.Func<JProperty,bool> predicate) {}
#endif
    void M() { Select(q => q != null); }
}
'@
        $result = @(Invoke-EnglishNamingCase $content -Spans @(@{startLine=8;endLine=8}))
        $result[0].state | Should -BeExactly unknown
        $peer = @{path='src/Selection.cs';state='complete';spans=@();content=$content.Replace(
            '    void M() { Select(q => q != null); }', '')}
        $source = 'using Newtonsoft.Json.Linq; partial class C { void M() { Select(x => x != null); } }'
        $peer.content = $peer.content.Replace('class C', 'partial class C')
        @(Invoke-EnglishNamingCase $source -AdditionalFiles @($peer))[0].state | Should -BeExactly unknown
    }

    It 'keeps explicit property roles independent of unrelated conditional method bodies' {
        $content = @'
using Newtonsoft.Json.Linq;
class C {
    void Trace() {
#if FEATURE
        System.Console.WriteLine(1);
#endif
    }
    void M() { System.Func<JProperty,bool> predicate = (JProperty q) => q != null; }
}
'@
        $result = @(Invoke-EnglishNamingCase $content -Spans @(@{startLine=8;endLine=8}))
        $result[0].state | Should -BeExactly violation
        $result[0].symbol | Should -BeExactly q
    }

    It 'requires the actual parameter identifier line to change, not its body or enclosing declaration' {
        $content = @'
using System;
using Newtonsoft.Json.Linq;
class C {
    void M() {
        Func<JProperty,bool> predicate =
            p =>
                p.Name != null;
    }
}
'@
        foreach ($line in @(5, 7)) {
            @(Invoke-EnglishNamingCase $content -Spans @(@{startLine=$line;endLine=$line}))[0].state |
                Should -BeExactly compliant
        }
        $result = @(Invoke-EnglishNamingCase $content -Spans @(@{startLine=6;endLine=6}))
        $result[0].state | Should -BeExactly violation
        $result[0].line | Should -Be 6
        $result[0].endLine | Should -Be 6
    }

    It 'binds a changed nested lambda independently of its same-named outer parameter' {
        $content = @'
using Newtonsoft.Json.Linq;
class C {
    void M() {
        System.Func<int,System.Func<JProperty,bool>> predicate = p =>
            (JProperty p) => p != null;
    }
}
'@
        $result = @(Invoke-EnglishNamingCase $content -Spans @(@{startLine=5;endLine=5}))
        $result[0].state | Should -BeExactly violation
        $result[0].line | Should -Be 5
    }

    It 'reports independently scoped parameters, not same-named fields or body references' {
        $content = @'
using Newtonsoft.Json.Linq;
class C {
    int p;
    void M() {
        System.Func<JProperty,bool> first = p => p.Name != null;
        System.Func<JProperty,bool> second = p => p.Value != null;
    }
}
'@
        $result = @(Invoke-EnglishNamingCase $content)
        $result | Should -HaveCount 2
        @($result | Where-Object state -CEQ violation) | Should -HaveCount 2
        ($result.line -join ',') | Should -BeExactly '5,6'
    }

    It 'excludes generated file <Path>' -TestCases @(
        @{ Path='src/obj/C.cs' }
        @{ Path='src/generated/C.cs' }
        @{ Path='src/C.g.cs' }
        @{ Path='src/C.designer.cs' }
        @{ Path='src/Ignore-AddedForReferenceOnly/C.cs' }
        @{ Path='src\generated\C.cs' }
    ) {
        param($Path)
        $result = @(Invoke-EnglishNamingCase $script:OriginalPropertyCase -Path $Path)
        $result[0].state | Should -BeExactly compliant
        $result[0].reason | Should -BeExactly generated-code-excluded
    }

    It 'excludes generated banners and attributed ancestors but retains handwritten siblings' {
        @(Invoke-EnglishNamingCase ("// <auto-generated>`n" + $script:OriginalPropertyCase))[0].state |
            Should -BeExactly compliant
        $content = @'
using Newtonsoft.Json.Linq;
class C {
    [System.Runtime.CompilerServices.CompilerGenerated]
    void Generated() { System.Func<JProperty,bool> generated = p => p != null; }
    void Handwritten() { System.Func<JProperty,bool> handwritten = p => p != null; }
}
'@
        $result = @(Invoke-EnglishNamingCase $content)
        $result | Should -HaveCount 1
        $result[0].state | Should -BeExactly violation
        $result[0].line | Should -Be 5
    }

    It 'does not make an unrelated changed line eligible because disabled text contains p' {
        $content = "#if FEATURE`nclass C { System.Func<int,int> predicate = p => p; }`n#endif`nclass D {}"
        $result = @(Invoke-EnglishNamingCase $content -Spans @(@{startLine=4;endLine=4}))
        $result[0].state | Should -BeExactly compliant
    }
}
