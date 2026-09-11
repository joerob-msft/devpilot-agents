BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:RepoRoot `
            'src/OwnerObservationContract/OwnerObservationContract.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot `
            'src/DevPilot.OwnerParity/DevPilot.OwnerParity.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot `
            'src/OwnerObservationContract/OwnerObservationContract.psd1') -Force
    $script:ParityModule = Get-Module DevPilot.OwnerParity

    function Get-TestSha256 {
        param([Parameter(Mandatory)][byte[]]$Bytes)
        return ([Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant()
    }

    function New-TestReference {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$RelativePath,
            [string]$Id = 'reference'
        )
        $path = Join-Path $Root $RelativePath
        $bytes = [IO.File]::ReadAllBytes($path)
        return [ordered]@{
            id = $Id
            relativePath = $RelativePath.Replace('\', '/')
            sha256 = Get-TestSha256 -Bytes $bytes
            length = $bytes.Length
            binding = 'critical:' + $RelativePath.Replace('\', '/')
        }
    }
}

Describe 'Owner canonical finding contract' {
    It 'normalizes separator and repository-root marker representations identically' {
        (ConvertTo-OwnerRepositoryPath -Path '/src\Tests\WidgetTests.cs') |
            Should -Be 'src/Tests/WidgetTests.cs'
    }

    It 'rejects traversal, ambiguous separators, device paths, and case collisions' {
        { ConvertTo-OwnerRepositoryPath -Path '..\secret.txt' } | Should -Throw
        { ConvertTo-OwnerRepositoryPath -Path 'src//Widget.cs' } | Should -Throw
        { ConvertTo-OwnerRepositoryPath -Path 'C:\repo\Widget.cs' } | Should -Throw
        { Assert-OwnerRepositoryPathSet -Paths @('src/Widget.cs', 'src/widget.cs') } |
            Should -Throw '*collide by case*'
    }

    It 'rejects reversed lines and columns' {
        {
            New-OwnerCanonicalAnchor -Path 'src/Widget.cs' `
                -StartLine 8 -EndLine 7 -Symbol Run -ConstructIdentity 'method:Run:8'
        } | Should -Throw '*endLine*'
        {
            New-OwnerCanonicalAnchor -Path 'src/Widget.cs' `
                -StartLine 8 -EndLine 8 -StartColumn 9 -EndColumn 2 `
                -Symbol Run -ConstructIdentity 'method:Run:8'
        } | Should -Throw '*endColumn*'
    }

    It 'keeps semantic keys stable across raw path representations' {
        $subject = [ordered]@{
            repositoryId = 'repo'; pullRequestId = 7; headCommit = 'a' * 40
        }
        $rule = [ordered]@{
            identity = 'rule'; path = 'docs/rule.md'; section = 'Owner'
            commit = 'b' * 40; sha256 = 'c' * 64
        }
        $left = New-OwnerCanonicalAnchor -Path '/src\Tests\Widget.cs' `
            -StartLine 12 -Symbol Run -ConstructIdentity 'method:Run:12'
        $right = New-OwnerCanonicalAnchor -Path 'src/Tests/Widget.cs' `
            -StartLine 12 -Symbol Run -ConstructIdentity 'method:Run:12'

        (Get-OwnerSemanticFindingKey -Subject $subject -Rule $rule `
                -Capability 'owner@1' -Binding $left) |
            Should -BeExactly (Get-OwnerSemanticFindingKey -Subject $subject -Rule $rule `
                -Capability 'owner@1' -Binding $right)
        $left.source.sha256 | Should -Not -Be $right.source.sha256
    }

    It 'changes semantic keys for head or span changes but not provider construct labels' {
        $subject = [ordered]@{
            repositoryId = 'repo'; pullRequestId = 7; headCommit = 'a' * 40
        }
        $rule = [ordered]@{
            identity = 'rule'; path = 'docs/rule.md'; section = 'Owner'
            commit = 'b' * 40; sha256 = 'c' * 64
        }
        $first = New-OwnerCanonicalAnchor -Path 'src/Widget.cs' `
            -StartLine 12 -Symbol Duplicate -ConstructIdentity 'method:Duplicate:12'
        $second = New-OwnerCanonicalAnchor -Path 'src/Widget.cs' `
            -StartLine 20 -Symbol Duplicate -ConstructIdentity 'method:Duplicate:20'
        $providerVariant = New-OwnerCanonicalAnchor -Path 'src/Widget.cs' `
            -StartLine 12 -Symbol Duplicate -ConstructIdentity 'provider-specific-id'
        $firstKey = Get-OwnerSemanticFindingKey -Subject $subject -Rule $rule `
            -Capability 'owner@1' -Binding $first
        $secondKey = Get-OwnerSemanticFindingKey -Subject $subject -Rule $rule `
            -Capability 'owner@1' -Binding $second
        $changedHead = [ordered]@{} + $subject
        $changedHead.headCommit = 'd' * 40

        $firstKey | Should -Not -Be $secondKey
        $firstKey | Should -Be (Get-OwnerSemanticFindingKey `
            -Subject $subject -Rule $rule -Capability 'owner@1' -Binding $providerVariant)
        $firstKey | Should -Not -Be (Get-OwnerSemanticFindingKey `
            -Subject $changedHead -Rule $rule -Capability 'owner@1' -Binding $first)
    }

    It 'reports provider marker integrity independently from semantic identity' {
        $verified = New-OwnerProviderMarker -Value 'provider-private-marker' -Integrity verified
        $missing = New-OwnerProviderMarker

        $verified.availability | Should -Be 'available'
        $verified.integrity | Should -Be 'verified'
        $verified.sha256 | Should -Match '^[0-9a-f]{64}$'
        $missing.availability | Should -Be 'unavailable'
        $missing.sha256 | Should -Be 'unknown'
    }
}

Describe 'Owner exact-byte and read-only attestation contract' {
    It 'validates exact bytes, detects tamper and binding mismatch, and rejects duplicates' {
        $root = Join-Path $TestDrive 'exact'
        New-Item -ItemType Directory -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'input.json'), '{}',
            [Text.UTF8Encoding]::new($false))
        $reference = New-TestReference -Root $root -RelativePath 'input.json'

        $read = & $script:ParityModule {
            param($Root, $Reference)
            Read-OwnerParityReferenceSet -Root $Root -References @($Reference)
        } $root $reference
        $read[0].length | Should -Be 2

        $wrongBinding = [ordered]@{} + $reference
        $wrongBinding.binding = 'critical:other.json'
        {
            & $script:ParityModule {
                param($Root, $Reference)
                Read-OwnerParityReferenceSet -Root $Root -References @($Reference)
            } $root $wrongBinding
        } | Should -Throw '*wrong immutable binding*'

        {
            & $script:ParityModule {
                param($Root, $Reference)
                Read-OwnerParityReferenceSet -Root $Root -References @($Reference, $Reference)
            } $root $reference
        } | Should -Throw '*duplicated*'

        [IO.File]::WriteAllText((Join-Path $root 'input.json'), '{"tampered":true}',
            [Text.UTF8Encoding]::new($false))
        {
            & $script:ParityModule {
                param($Root, $Reference)
                Read-OwnerParityReferenceSet -Root $Root -References @($Reference)
            } $root $reference
        } | Should -Throw '*wrong length*'
    }

    It 'accepts bounded append-only growth and rejects replacement, truncation, and unexpected files' {
        $root = Join-Path $TestDrive 'attested'
        New-Item -ItemType Directory -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'critical.json'), '{}',
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'scheduled.log'), 'prefix',
            [Text.UTF8Encoding]::new($false))
        $critical = New-TestReference -Root $root -RelativePath 'critical.json' -Id critical
        $volatileBytes = [IO.File]::ReadAllBytes((Join-Path $root 'scheduled.log'))
        $attestation = [ordered]@{
            critical = @($critical)
            volatile = @(
                [ordered]@{
                    id = 'scheduler-log'
                    relativePath = 'scheduled.log'
                    expectedPrefixSha256 = Get-TestSha256 -Bytes $volatileBytes
                    expectedPrefixLength = $volatileBytes.Length
                    maximumGrowthBytes = 16
                    affectsParityInputs = $false
                }
            )
        }
        $before = & $script:ParityModule {
            param($Root, $Value)
            Get-OwnerParityAttestationSnapshot `
                -Root $Root -Attestation $Value -ValidateVolatileBaseline
        } $root $attestation
        [IO.File]::AppendAllText((Join-Path $root 'scheduled.log'), '-append',
            [Text.UTF8Encoding]::new($false))
        $after = & $script:ParityModule {
            param($Root, $Value)
            Get-OwnerParityAttestationSnapshot -Root $Root -Attestation $Value
        } $root $attestation
        $comparison = & $script:ParityModule {
            param($Left, $Right, $Value)
            Compare-OwnerParityAttestationSnapshots `
                -Before $Left -After $Right -Attestation $Value
        } $before $after $attestation
        $comparison.unchanged | Should -BeTrue

        [IO.File]::WriteAllText((Join-Path $root 'scheduled.log'), 'replaced',
            [Text.UTF8Encoding]::new($false))
        $replaced = & $script:ParityModule {
            param($Root, $Value)
            Get-OwnerParityAttestationSnapshot -Root $Root -Attestation $Value
        } $root $attestation
        $replacement = & $script:ParityModule {
            param($Left, $Right, $Value)
            Compare-OwnerParityAttestationSnapshots `
                -Before $Left -After $Right -Attestation $Value
        } $before $replaced $attestation
        $replacement.unchanged | Should -BeFalse

        [IO.File]::WriteAllText((Join-Path $root 'unexpected.txt'), 'x',
            [Text.UTF8Encoding]::new($false))
        {
            & $script:ParityModule {
                param($Root, $Value)
                Get-OwnerParityAttestationSnapshot -Root $Root -Attestation $Value
            } $root $attestation
        } | Should -Throw '*Unexpected attestation file*'
    }

    It 'rejects linked exact-byte inputs when the platform permits creating a link' {
        $root = Join-Path $TestDrive 'links'
        New-Item -ItemType Directory -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'target.json'), '{}',
            [Text.UTF8Encoding]::new($false))
        $link = Join-Path $root 'linked.json'
        try {
            New-Item -ItemType SymbolicLink -Path $link `
                -Target (Join-Path $root 'target.json') -ErrorAction Stop | Out-Null
        }
        catch {
            Set-ItResult -Skipped -Because 'Symbolic links are unavailable in this environment.'
            return
        }
        $bytes = [IO.File]::ReadAllBytes($link)
        $reference = [ordered]@{
            id = 'linked'
            relativePath = 'linked.json'
            sha256 = Get-TestSha256 -Bytes $bytes
            length = $bytes.Length
            binding = 'critical:linked.json'
        }
        {
            & $script:ParityModule {
                param($Root, $Reference)
                Read-OwnerParityReferenceSet -Root $Root -References @($Reference)
            } $root $reference
        } | Should -Throw '*link or reparse point*'
    }
}
