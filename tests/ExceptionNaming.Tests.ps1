#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.ContextualConventions\DevPilot.ContextualConventions.psd1') -Force

    function Invoke-ExceptionNamingCase {
        param(
            [Parameter(Mandatory)][string]$Content,
            [object[]]$Spans = @(@{ startLine = 1; endLine = 1000 }),
            [object[]]$AdditionalFiles = @()
        )
        $file = [ordered]@{
            path = 'src/Changed.cs'
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
        $ids | Should -HaveCount 23
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
}
