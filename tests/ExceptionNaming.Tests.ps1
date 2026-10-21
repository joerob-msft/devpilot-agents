#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.ContextualConventions\DevPilot.ContextualConventions.psd1') -Force

    function Invoke-ExceptionNamingCase {
        param(
            [Parameter(Mandatory)][string]$Content,
            [string]$Path = 'src/Changed.cs',
            [object[]]$Spans = @(@{ startLine = 1; endLine = 1000 }),
            [object[]]$AdditionalFiles = @()
        )
        $file = [ordered]@{
            path = $Path
            state = 'complete'
            content = $Content
            spans = $Spans
        }
        return @(Get-ContextualConventionOutcomes `
            -Content $Content -Path $file.path -Spans $Spans `
            -SnapshotFiles (@($file) + $AdditionalFiles) |
            Where-Object ruleId -CEQ generic-exception-naming)
    }
}

Describe 'Generic exception catch naming' {
    It 'registers exactly one additive rule in analyzer, policy, and writer' {
        . (Join-Path $repoRoot `
            'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')
        $ids = @(Get-ContextualConventionRuleIds)
        $ids | Should -HaveCount 26
        @($ids | Where-Object { $_ -ceq 'generic-exception-naming' }) |
            Should -HaveCount 1
        $policy = Get-Content -LiteralPath (Join-Path $repoRoot `
            'src\DevPilot.OwnerCapability\Policy\contextual-conventions.v1.json') `
            -Raw | ConvertFrom-Json -AsHashtable
        ($policy.rules.id -join ',') | Should -BeExactly ($ids -join ',')
        ($script:ApprovedContextualRuleIds -join ',') |
            Should -BeExactly ($ids -join ',')
    }

    It 'finds the framework generic catch for <Type>' -TestCases @(
        @{ Prefix = 'using System;'; Type = 'Exception' }
        @{ Prefix = ''; Type = 'System.Exception' }
        @{ Prefix = ''; Type = 'global::System.Exception' }
        @{ Prefix = 'using E = System.Exception;'; Type = 'E' }
        @{ Prefix = 'using Exception = global::System.Exception;'; Type = 'Exception' }
        @{ Prefix = 'using Bcl = System;'; Type = 'Bcl.Exception' }
    ) {
        param($Prefix, $Type)
        $content = @"
$Prefix
class C {
    void M() {
        try { }
        catch ($Type cleanupScheduleException) when (cleanupScheduleException != null) {
            System.Console.WriteLine(cleanupScheduleException);
        }
    }
}
"@
        $outcomes = @(Invoke-ExceptionNamingCase -Content $content)
        $outcomes | Should -HaveCount 1
        $outcomes[0].state | Should -BeExactly violation
        $outcomes[0].line | Should -Be 5
        $outcomes[0].endLine | Should -Be 5
        $outcomes[0].symbol | Should -BeExactly cleanupScheduleException
        $outcomes[0].evidence | Should -Match 'System\.Exception'
        $outcomes[0].evidence | Should -Match 'ex'
        $outcomes[0].evidence | Should -Match 'uses'
    }

    It 'does not invent a violation for <Name>' -TestCases @(
        @{ Name = 'canonical ex'; Content = 'using System; class C { void M() { try {} catch (Exception ex) {} } }' }
        @{ Name = 'escaped ex'; Content = 'class C { void M() { try {} catch (System.Exception @ex) {} } }' }
        @{ Name = 'specialized exception'; Content = 'using System; class C { void M() { try {} catch (InvalidOperationException operationException) {} } }' }
        @{ Name = 'specialized alias'; Content = 'using Exception = System.InvalidOperationException; class C { void M() { try {} catch (Exception operationException) {} } }' }
        @{ Name = 'local Exception'; Content = 'using System; class Exception : System.Exception {} class C { void M() { try {} catch (Exception localException) {} } }' }
        @{ Name = 'nested Exception'; Content = 'using System; class C { class Exception : System.Exception {} void M() { try {} catch (Exception localException) {} } }' }
        @{ Name = 'qualified local Exception'; Content = 'namespace Local { class Exception : global::System.Exception {} } class C { void M() { try {} catch (Local.Exception localException) {} } }' }
        @{ Name = 'namespace alias to local'; Content = 'using Other = Local; namespace Local { class Exception : global::System.Exception {} } class C { void M() { try {} catch (Other.Exception localException) {} } }' }
        @{ Name = 'source System.Exception'; Content = 'namespace System { class Exception : global::System.ApplicationException {} } class C { void M() { try {} catch (System.Exception localException) {} } }' }
        @{ Name = 'catch without identifier'; Content = 'class C { void M() { try {} catch (System.Exception) {} } }' }
        @{ Name = 'bare catch'; Content = 'class C { void M() { try {} catch {} } }' }
        @{ Name = 'comments and strings'; Content = 'class C { string Text = "catch (System.Exception bad)"; /* catch (System.Exception bad) {} */ }' }
        @{ Name = 'permitted nested helper'; Content = 'class Tests { class TestHelper { void M() { try {} catch (System.Exception ex) {} } } }' }
    ) {
        param($Name, $Content)
        $outcomes = @(Invoke-ExceptionNamingCase -Content $Content)
        $outcomes | Should -HaveCount 1
        $outcomes[0].state | Should -BeExactly compliant
    }

    It 'keeps unsupported binding unknown for <Name>' -TestCases @(
        @{ Name = 'missing import'; Content = 'class C { void M() { try {} catch (Exception bad) {} } }' }
        @{ Name = 'unresolved alias'; Content = 'using Exception = Missing.Exception; class C { void M() { try {} catch (Exception bad) {} } }' }
        @{ Name = 'non-exception type alias'; Content = 'using Exception = System.Object; class C { void M() { try {} catch (Exception bad) {} } }' }
        @{ Name = 'type parameter'; Content = 'class C<T> where T : System.Exception { void M() { try {} catch (T bad) {} } }' }
        @{ Name = 'ambiguous import'; Content = 'using System; using Other; namespace Other { class Exception : System.Exception {} } class C { void M() { try {} catch (Exception bad) {} } }' }
        @{ Name = 'ambiguous namespace alias'; Content = 'using System = Local; namespace Local { class Exception {} } class C { void M() { try {} catch (System.Exception bad) {} } }' }
        @{ Name = 'conditional binding'; Content = "#if CUSTOM`nusing E = Local.Exception;`n#else`nusing E = System.Exception;`n#endif`nclass C { void M() { try {} catch (E bad) {} } }" }
        @{ Name = 'disabled conditional catch'; Content = "#if CUSTOM`nclass C { void M() { try {} catch (System.Exception bad) {} } }`n#endif" }
        @{ Name = 'malformed catch'; Content = 'class C { void M() { try {} catch (System.Exception bad { } } }' }
    ) {
        param($Name, $Content)
        $outcomes = @(Invoke-ExceptionNamingCase -Content $Content)
        $outcomes | Should -HaveCount 1
        $outcomes[0].state | Should -BeExactly unknown
        $outcomes[0].evidence | Should -BeNullOrEmpty
    }

    It 'resolves snapshot-local shadowing and aliases without guessing' {
        $content = 'using System; using Exception = Other.Exception; class C { void M() { try {} catch (Exception bad) {} } }'
        $other = @{
            path = 'src/Other.cs'
            state = 'complete'
            content = 'namespace Other { class Exception : global::System.Exception {} }'
            spans = @()
        }
        $result = @(Invoke-ExceptionNamingCase -Content $content -AdditionalFiles @($other))
        $result[0].state | Should -BeExactly compliant
        $other.state = 'unknown'
        $result = @(Invoke-ExceptionNamingCase -Content $content -AdditionalFiles @($other))
        $result[0].state | Should -BeExactly unknown
    }

    It 'ignores unchanged catch declarations when only their body or filter changes' {
        $content = @'
using System;
class C {
    void M() {
        try {}
        catch (Exception oldName)
            when (oldName != null) {
            System.Console.WriteLine(oldName);
        }
    }
}
'@
        foreach ($line in @(6, 7)) {
            $result = @(Invoke-ExceptionNamingCase -Content $content `
                -Spans @(@{ startLine = $line; endLine = $line }))
            $result[0].state | Should -BeExactly compliant
        }
    }

    It 'anchors a multiline declaration to an actual changed token line' {
        $content = @'
class C {
    void M() {
        try {}
        catch (
            System.Exception
            bad)
        {}
    }
}
'@
        $result = @(Invoke-ExceptionNamingCase -Content $content `
            -Spans @(@{ startLine = 6; endLine = 6 }))
        $result[0].state | Should -BeExactly violation
        $result[0].line | Should -Be 6
        $result[0].endLine | Should -Be 6
    }

    It 'does not let an unchanged outer catch mask a changed nested catch' {
        $content = @'
class C {
    void M() {
        try {}
        catch (System.Exception oldName) {
            try {}
            catch (System.Exception nestedName) {}
        }
    }
}
'@
        $result = @(Invoke-ExceptionNamingCase -Content $content `
            -Spans @(@{ startLine = 6; endLine = 6 }))
        $result[0].state | Should -BeExactly violation
        $result[0].line | Should -Be 6
        $result[0].symbol | Should -BeExactly nestedName
    }

    It 'reports every changed generic catch independently' {
        $content = @'
class C {
    void M() {
        try {} catch (System.Exception first) {}
        try {} catch (System.Exception second) {}
    }
}
'@
        $result = @(Invoke-ExceptionNamingCase -Content $content)
        $result | Should -HaveCount 2
        @($result | Where-Object state -CEQ violation) | Should -HaveCount 2
        ($result.line -join ',') | Should -BeExactly '3,4'
    }

    It 'excludes generated target paths for <Path>' -TestCases @(
        @{ Path = 'src/obj/Service.cs' }
        @{ Path = 'src/generated/Service.cs' }
        @{ Path = 'src/Ignore-AddedForReferenceOnly/Service.cs' }
        @{ Path = 'src/Service.g.cs' }
        @{ Path = 'src/Service.designer.cs' }
        @{ Path = 'src\generated\Service.cs' }
    ) {
        param($Path)
        $result = @(Invoke-ExceptionNamingCase -Path $Path -Content (
            'class C { void M() { try {} catch (System.Exception bad) {} } }'))
        $result[0].state | Should -BeExactly compliant
        $result[0].reason | Should -BeExactly generated-code-excluded
    }

    It 'excludes an auto-generated banner on an otherwise ordinary target' {
        $result = @(Invoke-ExceptionNamingCase -Content (
            "// <auto-generated>`nclass C { void M() { try {} catch (System.Exception bad) {} } }"))
        $result[0].state | Should -BeExactly compliant
        $result[0].reason | Should -BeExactly generated-code-excluded
    }

    It 'excludes catches inside generated <Scope> declarations' -TestCases @(
        @{ Scope = 'class'; Content = '[System.CodeDom.Compiler.GeneratedCode("tool", "1")] class C { void M() { try {} catch (System.Exception bad) {} } }' }
        @{ Scope = 'method'; Content = 'class C { [System.Runtime.CompilerServices.CompilerGenerated] void M() { try {} catch (System.Exception bad) {} } }' }
        @{ Scope = 'nested class'; Content = '[GeneratedCodeAttribute("tool", "1")] class C { class Nested { void M() { try {} catch (System.Exception bad) {} } } }' }
        @{ Scope = 'local function'; Content = 'class C { void M() { [CompilerGeneratedAttribute] void Local() { try {} catch (System.Exception bad) {} } } }' }
    ) {
        param($Scope, $Content)
        $result = @(Invoke-ExceptionNamingCase -Content $Content)
        $result[0].state | Should -BeExactly compliant
    }

    It 'retains handwritten siblings of generated declarations' {
        $content = @'
class C {
    [CompilerGenerated] void Generated() { try {} catch (System.Exception skipped) {} }
    void Handwritten() { try {} catch (System.Exception bad) {} }
}
'@
        $result = @(Invoke-ExceptionNamingCase -Content $content)
        $result | Should -HaveCount 1
        $result[0].state | Should -BeExactly violation
        $result[0].symbol | Should -BeExactly bad
    }

    It 'does not let generated snapshot <Name> poison handwritten binding' -TestCases @(
        @{ Name = 'path'; Path = 'src/obj/Generated.cs'; Content = '#if'; State = 'unknown'; Expected = 'violation' }
        @{ Name = 'banner'; Path = 'src/ServiceReference.cs'; Content = "// <auto-generated>`n#if FEATURE`nclass Exception {}`n#endif"; State = 'complete'; Expected = 'unknown' }
        @{ Name = 'shadowing'; Path = 'src/Service.g.cs'; Content = 'class Exception : System.Exception {}'; State = 'complete'; Expected = 'compliant' }
        @{ Name = 'attributed shadowing'; Path = 'src/Helper.cs'; Content = '[CompilerGenerated] class Exception : System.Exception {}'; State = 'complete'; Expected = 'compliant' }
        @{ Name = 'attributed body'; Path = 'src/Helper.cs'; Content = "[GeneratedCode(`"tool`", `"1`")] class Helper { void M() {`n#if DEBUG`nusing (var stream = Open()) {}`n#endif`n} }"; State = 'complete'; Expected = 'violation' }
    ) {
        param($Name, $Path, $Content, $State, $Expected)
        $result = @(Invoke-ExceptionNamingCase -Content (
            'using System; class C { void M() { try {} catch (Exception bad) {} } }') `
            -AdditionalFiles @(@{ path = $Path; content = $Content; state = $State; spans = @() }))
        $result[0].state | Should -BeExactly $Expected
        if ($Expected -ceq 'compliant') {
            $result[0].reason | Should -BeExactly not-system-exception
        }
    }

    It 'does not withhold a file without changed catches for <Name>' -TestCases @(
        @{ Name = 'empty preprocessor'; Content = "#if DEBUG`n#endif`nclass C {}"; Line = 3 }
        @{ Name = 'inactive noncatch'; Content = "#if DEBUG`nclass Hidden {} `n#endif`nclass C {}"; Line = 4 }
        @{ Name = 'unchanged inactive catch'; Content = "#if DEBUG`nclass Hidden { void M() { try {} catch (System.Exception bad) {} } }`n#endif`nclass C {}"; Line = 4 }
        @{ Name = 'inactive comment'; Content = "#if DEBUG`n// catch (System.Exception bad) {}`n#endif"; Line = 2 }
        @{ Name = 'inactive string'; Content = "#if DEBUG`nclass C { string Text = `"catch (System.Exception bad) {}`"; }`n#endif"; Line = 2 }
    ) {
        param($Name, $Content, $Line)
        $result = @(Invoke-ExceptionNamingCase -Content $Content `
            -Spans @(@{ startLine = $Line; endLine = $Line }))
        $result[0].state | Should -BeExactly compliant
    }

    It 'ignores unrelated preprocessor bodies for <Scope>' -TestCases @(
        @{ Scope = 'current method'; Other = $false; Content = "class C { void M() {`n#if DEBUG`nSystem.Console.WriteLine(0);`n#endif`ntry {} catch (System.Exception bad) {} } }" }
        @{ Scope = 'current accessor'; Other = $false; Content = "class C { int P { get {`n#if DEBUG`nSystem.Console.WriteLine(0);`n#endif`ntry {} catch (System.Exception bad) {} return 0; } } }" }
        @{ Scope = 'current using statement'; Other = $false; Content = "class C { void M() {`n#if DEBUG`nusing (var stream = Open()) {}`n#endif`ntry {} catch (System.Exception bad) {} } }" }
        @{ Scope = 'current using declaration'; Other = $false; Content = "class C { void M() {`n#if DEBUG`nusing var stream = Open();`n#endif`ntry {} catch (System.Exception bad) {} } }" }
        @{ Scope = 'snapshot empty condition'; Other = $true; Content = "#if DEBUG`n#endif`nclass Helper {}" }
        @{ Scope = 'snapshot method'; Other = $true; Content = "class Helper { void M() {`n#if DEBUG`nSystem.Console.WriteLine(0);`n#endif`n} }" }
        @{ Scope = 'snapshot using statement'; Other = $true; Content = "class Helper { void M() {`n#if DEBUG`nusing (var stream = Open()) {}`n#endif`n} }" }
        @{ Scope = 'current empty condition'; Other = $false; Content = "#if DEBUG`n#endif`nclass C { void M() { try {} catch (System.Exception bad) {} } }" }
        @{ Scope = 'current definition'; Other = $false; Content = "#define DEBUG`nclass C { void M() { try {} catch (System.Exception bad) {} } }" }
    ) {
        param($Scope, $Other, $Content)
        if ($Other) {
            $result = @(Invoke-ExceptionNamingCase -Content (
                'class C { void M() { try {} catch (System.Exception bad) {} } }') `
                -AdditionalFiles @(@{ path = 'src/Helper.cs'; content = $Content; state = 'complete'; spans = @() }))
        }
        else { $result = @(Invoke-ExceptionNamingCase -Content $Content) }
        $result[0].state | Should -BeExactly violation
    }

    It 'retains unknown when conditional <Name> can change type binding' -TestCases @(
        @{ Name = 'snapshot type'; Content = "#if CUSTOM`nclass Exception : System.Exception {}`n#endif"; Prefix = 'using System;' }
        @{ Name = 'snapshot global alias'; Content = "#if CUSTOM`nglobal using Exception = Other.Exception;`n#endif"; Prefix = 'using System;' }
    ) {
        param($Name, $Content, $Prefix)
        $result = @(Invoke-ExceptionNamingCase -Content (
            "$Prefix class C { void M() { try {} catch (Exception bad) {} } }") `
            -AdditionalFiles @(@{ path = 'src/Helper.cs'; content = $Content; state = 'complete'; spans = @() }))
        $result[0].state | Should -BeExactly unknown
    }

    It 'does not let a generated sibling body change handwritten catch binding' {
        $content = @'
class C {
    [CompilerGenerated] void Generated() {
#if DEBUG
        using var stream = Open();
#endif
    }
    void Handwritten() { try {} catch (System.Exception bad) {} }
}
'@
        $result = @(Invoke-ExceptionNamingCase -Content $content)
        $result[0].state | Should -BeExactly violation
        $result[0].line | Should -Be 7
    }

    It 'preserves unknown for an active conditional changed catch' {
        $content = @'
class C {
    void M() {
#if true
        try {} catch (System.Exception bad) {}
#endif
    }
}
'@
        $result = @(Invoke-ExceptionNamingCase -Content $content)
        $result[0].state | Should -BeExactly unknown
    }

    It 'anchors a fully changed multiline catch on its identifier' {
        $content = @'
class C {
    void M() {
        try {}
        catch (
            System.Exception
            bad
        ) {}
    }
}
'@
        $result = @(Invoke-ExceptionNamingCase -Content $content)
        $result[0].state | Should -BeExactly violation
        $result[0].line | Should -Be 6
        $result[0].endLine | Should -Be 6
        foreach ($line in @(4, 7)) {
            $unchanged = @(Invoke-ExceptionNamingCase -Content $content `
                -Spans @(@{ startLine = $line; endLine = $line }))
            $unchanged[0].state | Should -BeExactly compliant
        }
        $typeOnly = @(Invoke-ExceptionNamingCase -Content $content `
            -Spans @(@{ startLine = 5; endLine = 5 }))
        $typeOnly[0].state | Should -BeExactly violation
        $typeOnly[0].line | Should -Be 5
    }

    It 'preserves generated <Name> declarations for handwritten catches' -TestCases @(
        @{ Name = 'same-file shadow'; Declaration = '[GeneratedCode("tool", "1")] class Exception : System.Exception {}'; Type = 'Exception'; Snapshot = $false; Path = 'src/Helper.cs' }
        @{ Name = 'same-file specialized'; Declaration = '[GeneratedCode("tool", "1")] class ApiException : System.Exception {}'; Type = 'ApiException'; Snapshot = $false; Path = 'src/Helper.cs' }
        @{ Name = 'snapshot specialized'; Declaration = '[CompilerGenerated] class ApiException : System.Exception {}'; Type = 'ApiException'; Snapshot = $true; Path = 'src/Helper.cs' }
        @{ Name = 'designer shadow'; Declaration = 'class Exception : System.Exception {}'; Type = 'Exception'; Snapshot = $true; Path = 'src/Helper.designer.cs' }
        @{ Name = 'banner shadow'; Declaration = "// <auto-generated>`nclass Exception : System.Exception {}"; Type = 'Exception'; Snapshot = $true; Path = 'src/Helper.cs' }
        @{ Name = 'generated directory shadow'; Declaration = 'class Exception : System.Exception {}'; Type = 'Exception'; Snapshot = $true; Path = 'src/generated/Helper.cs' }
        @{ Name = 'generated specialized'; Declaration = 'class ApiException : System.Exception {}'; Type = 'ApiException'; Snapshot = $true; Path = 'src/Helper.g.cs' }
    ) {
        param($Name, $Declaration, $Type, $Snapshot, $Path)
        $content = "using System; class C { void M() { try {} catch ($Type customException) {} } }"
        $additional = @()
        if ($Snapshot) {
            $additional = @(@{ path = $Path; content = $Declaration; state = 'complete'; spans = @() })
        }
        else { $content = "using System;`n$Declaration`nclass C { void M() { try {} catch ($Type customException) {} } }" }
        $result = @(Invoke-ExceptionNamingCase -Content $content -AdditionalFiles $additional)
        $result | Should -HaveCount 1
        $result[0].state | Should -BeExactly compliant
        $result[0].reason | Should -BeExactly not-system-exception
    }

    It 'does not erase attributed <Name> syntax around handwritten catches' -TestCases @(
        @{ Name = 'enum member'; Declaration = 'enum Kind { [GeneratedCode("tool", "1")] First, Second }' }
        @{ Name = 'parameter'; Declaration = 'class Other { void M([CompilerGenerated] int a, int b) {} }' }
        @{ Name = 'lambda'; Declaration = 'class Other { System.Action Run = [CompilerGenerated] () => {}; }' }
        @{ Name = 'expression lambda'; Declaration = 'class Other { System.Func<int> Run = [CompilerGenerated] () => 1; }' }
    ) {
        param($Name, $Declaration)
        $result = @(Invoke-ExceptionNamingCase -Content (
            "$Declaration`nclass C { void M() { try {} catch (System.Exception bad) {} } }"))
        $result[0].state | Should -BeExactly violation
    }

    It 'excludes generated lambda catches without erasing their declaration' {
        $content = @'
class C {
    System.Action Run = [CompilerGenerated] () => {
        try {} catch (System.Exception skipped) {}
    };
    void M() { try {} catch (System.Exception bad) {} }
}
'@
        $result = @(Invoke-ExceptionNamingCase -Content $content)
        $result | Should -HaveCount 1
        $result[0].state | Should -BeExactly violation
        $result[0].symbol | Should -BeExactly bad
        $result[0].line | Should -Be 5
    }

    It 'ignores generated body syntax diagnostics without discarding its exception type' {
        $generated = @'
// <auto-generated>
class ApiException : System.Exception {
    void Generated() { var broken = ; }
}
'@
        $result = @(Invoke-ExceptionNamingCase -Content (
            'class C { void M() { try {} catch (ApiException apiException) {} } }') `
            -AdditionalFiles @(@{ path = 'src/ApiException.g.cs'; state = 'complete'; spans = @(); content = $generated }))
        $result[0].state | Should -BeExactly compliant
        $result[0].reason | Should -BeExactly not-system-exception
    }

    It 'preserves generated namespace imports and aliased exception declarations' {
        $generated = @'
// <auto-generated>
using BaseException = System.Exception;
namespace Contracts {
    [GeneratedCode("tool", "1")] class ApiException : BaseException {}
}
'@
        $result = @(Invoke-ExceptionNamingCase -Content (
            'using Contracts; class C { void M() { try {} catch (ApiException apiException) {} } }') `
            -AdditionalFiles @(@{ path = 'src/Contracts.designer.cs'; state = 'complete'; spans = @(); content = $generated }))
        $result[0].state | Should -BeExactly compliant
        $result[0].reason | Should -BeExactly not-system-exception
    }

    It 'preserves unknown for a generated conditional shadow' {
        $result = @(Invoke-ExceptionNamingCase -Content (
            'using System; class C { void M() { try {} catch (Exception bad) {} } }') `
            -AdditionalFiles @(@{ path = 'src/Helper.g.cs'; state = 'complete'; spans = @(); content = "#if FEATURE`nclass Exception : System.Exception {}`n#endif" }))
        $result[0].state | Should -BeExactly unknown
    }

    It 'ignores body-only <Name> tokens in inactive branches' -TestCases @(
        @{ Name = 'record local'; Statement = 'var record = 1;'; Snapshot = $false }
        @{ Name = 'anonymous delegate'; Statement = 'System.Action a = delegate {};'; Snapshot = $false }
        @{ Name = 'local generic constraint'; Statement = 'void Local<T>() where T : class {}'; Snapshot = $false }
        @{ Name = 'snapshot record local'; Statement = 'var record = 1;'; Snapshot = $true }
        @{ Name = 'snapshot delegate'; Statement = 'System.Action a = delegate {};'; Snapshot = $true }
    ) {
        param($Name, $Statement, $Snapshot)
        $conditional = "void Other() {`n#if DEBUG`n$Statement`n#endif`n}"
        $catch = 'void M() { try {} catch (System.Exception bad) {} }'
        $additional = @()
        if ($Snapshot) {
            $content = "class C { $catch }"
            $additional = @(@{ path = 'src/Helper.cs'; state = 'complete'; spans = @(); content = "class Helper { $conditional }" })
        }
        else { $content = "class C { $conditional`n$catch }" }
        $result = @(Invoke-ExceptionNamingCase -Content $content -AdditionalFiles $additional)
        $result[0].state | Should -BeExactly violation
    }

    It 'ignores body-only tokens in conditional <Scope> branches' -TestCases @(
        @{ Scope = 'accessor'; Content = "class C { int P { get {`n#if DEBUG`nvar record = 1; System.Action a = delegate {};`n#endif`nreturn 0; } } void M() { try {} catch (System.Exception bad) {} } }" }
        @{ Scope = 'local function'; Content = "class C { void Other() { void Local() {`n#if DEBUG`nvar record = 1;`n#endif`n} } void M() { try {} catch (System.Exception bad) {} } }" }
        @{ Scope = 'constructor'; Content = "class C { C() {`n#if DEBUG`nSystem.Action a = delegate {};`n#endif`n} void M() { try {} catch (System.Exception bad) {} } }" }
    ) {
        param($Scope, $Content)
        $result = @(Invoke-ExceptionNamingCase -Content $Content)
        $result[0].state | Should -BeExactly violation
    }

    It 'does not mistake inactive record <Name> identifiers for type declarations' -TestCases @(
        @{ Name = 'field'; Member = 'int record = 1;' }
        @{ Name = 'property'; Member = 'int record { get; set; }' }
        @{ Name = 'method'; Member = 'void record() {}' }
    ) {
        param($Name, $Member)
        $content = "class C {`n#if DEBUG`n$Member`n#endif`nvoid M() { try {} catch (System.Exception bad) {} } }"
        $result = @(Invoke-ExceptionNamingCase -Content $content)
        $result[0].state | Should -BeExactly violation
    }

    It 'scopes inactive catch uncertainty to the catch keyword line' {
        $content = @'
class Worker {
#if DEBUG
    void Old() { try {} catch (System.Exception oldBad) {} }
    void ChangedInDebug() {
        int x = 1;
    }
#endif
    void Active() {}
}
'@
        $unrelated = @(Invoke-ExceptionNamingCase -Content $content `
            -Spans @(@{ startLine = 5; endLine = 5 }))
        $unrelated[0].state | Should -BeExactly compliant
        $actualCatch = @(Invoke-ExceptionNamingCase -Content $content `
            -Spans @(@{ startLine = 3; endLine = 3 }))
        $actualCatch[0].state | Should -BeExactly unknown
    }

    It 'retains conditional record type uncertainty' -TestCases @(
        @{ Declaration = 'record Exception;' }
        @{ Declaration = 'record class Exception;' }
        @{ Declaration = 'record struct Exception;' }
    ) {
        param($Declaration)
        $content = "#if FEATURE`n$Declaration`n#endif`nusing System; class C { void M() { try {} catch (Exception bad) {} } }"
        $result = @(Invoke-ExceptionNamingCase -Content $content)
        $result[0].state | Should -BeExactly unknown
    }
}
