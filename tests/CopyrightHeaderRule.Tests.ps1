#requires -Version 7.0

BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.ContextualConventions\DevPilot.ContextualConventions.psd1" -Force
    $header = @'
//------------------------------------------------------------
// Copyright (c) Microsoft Corporation.  All rights reserved.
//------------------------------------------------------------
'@
    function Invoke-CopyrightCase {
        param(
            [AllowEmptyString()][string]$Content = 'namespace Tests { class C {} }',
            [AllowNull()][object]$Target = 'namespace Tests { class C { void Old() {} } }',
            [string]$ChangeType = 'edit',
            [string]$Path = 'tests/Changed.cs',
            [string]$State = 'complete',
            [switch]$ContextOnly,
            [switch]$NoProof
        )
        $proof = Get-ContextualCopyrightHeaderEvidence -Path $Path `
            -OldPath $(if ($ChangeType -match 'rename') { 'tests/Old.cs' } else { $null }) `
            -ChangeType $ChangeType -Content $Content -TargetContent $Target `
            -SourceCommit ('a' * 40) -TargetCommit ('b' * 40)
        $file = [ordered]@{
            path = $Path
            state = $State
            changeType = $proof.changeType
            content = $Content
            spans = @([ordered]@{ startLine = 15; endLine = 16 })
            contextOnly = [bool]$ContextOnly
        }
        if (-not $NoProof) { $file['fileHeader'] = $proof }
        return Get-ContextualCopyrightHeaderOutcome -Content $Content -Path $Path -SnapshotFiles @($file)
    }
}

Describe 'Changed C# file copyright headers' {
    It 'detects a pre-existing omission even when the file header is not a changed line' {
        $result = Invoke-CopyrightCase
        $result.state | Should -BeExactly violation
        $result.reason | Should -BeExactly missing-copyright-header-pre-existing
        $result.fileHeader.origin | Should -BeExactly pre-existing
        $result.line | Should -Be 1
        $result.symbol | Should -BeExactly copyright-header
    }

    It 'classifies a new file as introduced' {
        $result = Invoke-CopyrightCase -ChangeType add -Target ''
        $result.state | Should -BeExactly violation
        $result.fileHeader.origin | Should -BeExactly introduced
        $result.fileHeader.targetHeaderState | Should -BeExactly absent-added
    }

    It 'classifies removal of a header as introduced' {
        $result = Invoke-CopyrightCase -Target "$header`nnamespace Tests { class C {} }"
        $result.state | Should -BeExactly violation
        $result.fileHeader.origin | Should -BeExactly introduced
    }

    It 'accepts the same Microsoft notice with <YearForm> without requiring annual rollover' -TestCases @(
        @{ YearForm = 'no year'; YearText = '' },
        @{ YearForm = 'the current year'; YearText = "$([DateTime]::UtcNow.Year) " },
        @{ YearForm = 'a historical year'; YearText = '2010 ' },
        @{ YearForm = 'a historical year range'; YearText = '2010-2016 ' },
        @{ YearForm = 'a horizontally spaced year range'; YearText = "2010 `t- 2016 " }
    ) {
        param($YearForm, $YearText)
        $text = "// ---`n// Copyright (c) ${YearText}Microsoft Corporation. All rights reserved.`n// ---`nnamespace Tests { class C {} }"
        (Invoke-CopyrightCase -Content $text).state |
            Should -BeExactly compliant
    }

    It 'classifies removal of a historical dated header as introduced, not pre-existing' {
        $text = "// ---`n// Copyright (c) 2010-2016 Microsoft Corporation. All rights reserved.`n// ---`nnamespace Tests { class C {} }"
        $result = Invoke-CopyrightCase -Target $text
        $result.state | Should -BeExactly violation
        $result.fileHeader.origin | Should -BeExactly introduced
        $result.fileHeader.targetHeaderState | Should -BeExactly present
    }

    It 'accepts <Newline> with a leading BOM, blank lines and semantic horizontal whitespace' -TestCases @(
        @{ Newline = 'LF'; Separator = "`n" },
        @{ Newline = 'CRLF'; Separator = "`r`n" }
    ) {
        param($Newline, $Separator)
        $text = [char]0xFEFF + " `t$Separator" +
            (@('// ---', "//`tCopyright (c) Microsoft Corporation.`tAll rights reserved.", '// ---',
                'namespace Tests { class C {} }') -join $Separator)
        (Invoke-CopyrightCase -Content $text).state | Should -BeExactly compliant
    }

    It 'does not accept <Case> as an initial standard header' -TestCases @(
        @{ Case = 'a string literal'; Text = 'class C { string S = "// Copyright (c) Microsoft Corporation.  All rights reserved."; }' },
        @{ Case = 'a late header'; Text = "namespace Tests {}`n//------------------------------------------------------------`n// Copyright (c) Microsoft Corporation.  All rights reserved.`n//------------------------------------------------------------" },
        @{ Case = 'a block with nonstandard framing'; Text = '/* Copyright (c) Microsoft Corporation. All rights reserved. */ class C {}' },
        @{ Case = 'a malformed year'; Text = "// ---`n// Copyright (c) 20x6 Microsoft Corporation. All rights reserved.`n// ---`nclass C {}" },
        @{ Case = 'a malformed year range'; Text = "// ---`n// Copyright (c) 2010-20x6 Microsoft Corporation. All rights reserved.`n// ---`nclass C {}" },
        @{ Case = 'a wrong owner'; Text = "// ---`n// Copyright (c) 2010-2016 Contoso Corporation. All rights reserved.`n// ---`nclass C {}" },
        @{ Case = 'an incomplete notice'; Text = "// ---`n// Copyright (c) 2010 Microsoft Corporation.`n// ---`nclass C {}" },
        @{ Case = 'a missing notice'; Text = "// ---`n// All rights reserved.`n// ---`nclass C {}" }
    ) {
        param($Case, $Text)
        (Invoke-CopyrightCase -Content $Text).state | Should -BeExactly violation
    }

    It 'excludes generated or vendored path <Path>' -TestCases @(
        @{ Path = 'generated/C.cs' }, @{ Path = 'obj/C.cs' },
        @{ Path = 'src/C.g.cs' }, @{ Path = 'src/C.designer.cs' },
        @{ Path = 'vendor/C.cs' }, @{ Path = 'third_party/C.cs' }
    ) {
        param($Path)
        (Invoke-CopyrightCase -Path $Path).reason | Should -BeExactly copyright-file-excluded
    }

    It 'excludes an initial generated-code comment but not a buried string' {
        (Invoke-CopyrightCase -Content "// <auto-generated>`nclass C {}").reason |
            Should -BeExactly copyright-file-excluded
        (Invoke-CopyrightCase -Content 'class C { string S = "<auto-generated>"; }').state |
            Should -BeExactly violation
    }

    It 'excludes deleted files and context-only project support' {
        (Invoke-CopyrightCase -ChangeType delete).state | Should -BeExactly compliant
        (Invoke-CopyrightCase -ContextOnly).state | Should -BeExactly compliant
        (Invoke-CopyrightCase -Path 'src/Changed.ts').state | Should -BeExactly compliant
    }

    It 'does not infer an outcome from missing target, source, or inventory authority' {
        (Invoke-CopyrightCase -Target $null).state | Should -BeExactly unknown
        (Invoke-CopyrightCase -State unknown).state | Should -BeExactly unknown
        (Invoke-CopyrightCase -NoProof).state | Should -BeExactly unknown
        (Get-ContextualCopyrightHeaderOutcome -Content 'class C {}' -Path 'unchanged.cs' `
            -SnapshotFiles @()).state | Should -BeExactly unknown
    }

    It 'preserves renamed file identity and compares the original file' {
        $result = Invoke-CopyrightCase -ChangeType rename
        $result.state | Should -BeExactly violation
        $result.fileHeader.oldPath | Should -BeExactly 'tests/Old.cs'
        $result.fileHeader.path | Should -BeExactly 'tests/Changed.cs'
    }

    It 'rejects tampered source content or classification in a header proof' {
        $proof = (Invoke-CopyrightCase).fileHeader
        (Test-ContextualCopyrightHeaderEvidence -Evidence $proof -Path 'tests/Changed.cs' `
            -Content 'class Different {}') | Should -BeFalse
        $proof.origin = 'introduced'
        (Test-ContextualCopyrightHeaderEvidence -Evidence $proof -Path 'tests/Changed.cs' `
            -Content 'namespace Tests { class C {} }') | Should -BeFalse
    }

    It 'adds exactly one rule and never promotes it from any old bundle' {
        $rules = @(Get-ContextualConventionRuleIds)
        $rules | Should -HaveCount 23
        $rules[-1] | Should -BeExactly file-copyright-header
        $old = @(
            @{ hash = 'v1:sha256:0f6bd9dd21df64854bba7e2ba487c2639be15fa90f068da00df20f031ef9c749'; length = 3706; count = 18 },
            @{ hash = 'v1:sha256:6a7db82e68b407af4ed19aab4517973337592e757a32d5fa7a142b63ef75d22a'; length = 5205; count = 20 },
            @{ hash = 'v1:sha256:9834f5ee38aefe532a9c2b5e05b90dd0f55faa8d87d743e2a650bb191c89506e'; length = 5399; count = 21 },
            @{ hash = 'v1:sha256:e84ed0793dbabb4494a603fb445bea120af872b6df4477f2952148fc9bc3efac'; length = 6249; count = 22 }
        )
        foreach ($prior in $old) {
            $binding = @{ hash = $prior.hash; length = $prior.length }
            $excluded = switch ($prior.count) {
                18 { @('xml-summary-layout', 'duplicate-constant-declarations', 'test-class-code-coverage', 'pr-template-compliance', 'file-copyright-header') }
                20 { @('test-class-code-coverage', 'pr-template-compliance', 'file-copyright-header') }
                21 { @('pr-template-compliance', 'file-copyright-header') }
                22 { @('file-copyright-header') }
            }
            $unchanged = @($rules | Where-Object { $_ -cnotin $excluded })
            $unchanged | Should -HaveCount $prior.count
            (Test-ContextualConventionPriorRuleIds -Rule $binding -RuleIds $unchanged) |
                Should -BeTrue
            (Test-ContextualConventionPriorRuleIds -Rule $binding -RuleIds @('explicit-string-comparison')) |
                Should -BeTrue
            (Test-ContextualConventionPriorRuleIds -Rule $binding -RuleIds @('file-copyright-header')) |
                Should -BeFalse
        }
    }
}
