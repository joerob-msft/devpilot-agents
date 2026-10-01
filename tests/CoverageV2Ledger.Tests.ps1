#requires -Version 7.0

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) `
        'src\DevPilot.CoverageV2CreateOnly\DevPilot.CoverageV2Ledger.psm1') -Force

InModuleScope DevPilot.CoverageV2Ledger {
    BeforeAll {
        $script:root = Join-Path (Split-Path -Parent $PSScriptRoot) (
            '.coverage-v2-ledger-test-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:root)
        if ($IsWindows) {
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $acl.SetOwner($sid)
            $acl.SetAccessRuleProtection($true, $false)
            $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit `
                -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
            $acl.AddAccessRule(
                [Security.AccessControl.FileSystemAccessRule]::new(
                    $sid, [Security.AccessControl.FileSystemRights]::FullControl,
                    $inherit, [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow))
            $system = [Security.Principal.SecurityIdentifier]::new(
                [Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
            $acl.AddAccessRule(
                [Security.AccessControl.FileSystemAccessRule]::new(
                    $system,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    $inherit, [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow))
            Set-Acl -LiteralPath $script:root -AclObject $acl
        }
        $script:key = [byte[]]::new(32)
        [Array]::Fill[byte]($script:key, [byte]0x46)
        function New-FictionalLedgerRequest {
            param([string]$RuleId = 'bpm-test-class-coverage@2',
                [string]$RunId = 'fictional-run-1',
                [int]$PullRequestId = 42,
                [char]$Digit = '1')
            return @{
                Root = $script:root
                Key = $script:key
                RepositoryId = '11111111-1111-1111-1111-111111111111'
                PullRequestId = $PullRequestId
                RuleId = $RuleId
                RunId = $RunId
                Marker = [string]$Digit * 64
                FindingDigest = [string]$Digit * 64
            }
        }
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:root) {
            Remove-Item -LiteralPath $script:root -Recurse -Force
        }
    }

    Describe 'fictional proof-neutral serialized ledger' {
        It 'has no exported commands and refuses real authority before state creation' {
            (Get-Module DevPilot.CoverageV2Ledger).ExportedCommands.Count |
                Should -Be 0
            $root = Join-Path $script:root 'not-created'
            { Invoke-CoverageV2TrustedLedger -Root $root -Authority @{} } |
                Should -Throw '*coverage-v2-signed-finding-authority-unavailable*'
            { Invoke-CoverageV2TrustedLedger -Root $root -Authority @{
                    signedFinding = $true
                    verifiedIdentity = $true
                    complete = $true
                } } |
                Should -Throw '*coverage-v2-signed-finding-authority-unavailable*'
            Test-Path -LiteralPath $root | Should -BeFalse
        }

        It 'records reservation, attempt and one explicit readback durably' {
            $p = New-FictionalLedgerRequest
            $reserve = Invoke-CoverageV2LedgerFixture @p -Operation Reserve
            $reserve.state | Should -Be 'proof-neutral-not-authority'
            $reserve.reservationCount | Should -Be 1
            (Invoke-CoverageV2LedgerFixture @p -Operation Attempt).recorded |
                Should -Be 'attempted'
            (Invoke-CoverageV2LedgerFixture @p -Operation Readback `
                    -ReadbackState confirmed).recorded |
                Should -Be 'readback-confirmed'
            $read = Invoke-CoverageV2LedgerFixture @p -Operation Inspect
            $read.events | Should -Be @('reserved', 'attempted',
                'readback-confirmed')
            { Invoke-CoverageV2LedgerFixture @p -Operation Reserve } |
                Should -Throw '*coverage-v2-ledger-retry-forbidden*'
        }

        It 'never retries an uncertain attempt or missing readback on reread' {
            $p = New-FictionalLedgerRequest -Digit '2' -PullRequestId 43 `
                -RunId 'fictional-run-2'
            [void](Invoke-CoverageV2LedgerFixture @p -Operation Reserve)
            [void](Invoke-CoverageV2LedgerFixture @p -Operation Attempt)
            [void](Invoke-CoverageV2LedgerFixture @p -Operation Readback `
                    -ReadbackState ambiguous)
            { Invoke-CoverageV2LedgerFixture @p -Operation Attempt } |
                Should -Throw '*coverage-v2-ledger-retry-forbidden*'
            { Invoke-CoverageV2LedgerFixture @p -Operation Readback `
                    -ReadbackState confirmed } |
                Should -Throw '*coverage-v2-ledger-readback-not-pending*'
            $p = New-FictionalLedgerRequest -Digit '3' -PullRequestId 43 `
                -RunId 'fictional-run-2'
            [void](Invoke-CoverageV2LedgerFixture @p -Operation Reserve)
            [void](Invoke-CoverageV2LedgerFixture @p -Operation Attempt)
            [void](Invoke-CoverageV2LedgerFixture @p -Operation Readback `
                    -ReadbackState missing)
            { Invoke-CoverageV2LedgerFixture @p -Operation Reserve } |
                Should -Throw '*coverage-v2-ledger-retry-forbidden*'
        }

        It 'enforces per-rule run and PR quotas across rereads and rule buckets' {
            $rule = 'bpm-redundant-method-coverage@2'
            foreach ($n in 4..5) {
                $p = New-FictionalLedgerRequest -RuleId $rule `
                    -RunId 'fictional-run-2' -PullRequestId 44 `
                    -Digit ([char]($n + 48))
                [void](Invoke-CoverageV2LedgerFixture @p -Operation Reserve)
            }
            $p = New-FictionalLedgerRequest -RuleId $rule `
                -RunId 'fictional-run-2' -PullRequestId 44 -Digit '6'
            { Invoke-CoverageV2LedgerFixture @p -Operation Reserve } |
                Should -Throw '*coverage-v2-ledger-budget-exhausted*'
            foreach ($n in 6..8) {
                $p = New-FictionalLedgerRequest -RuleId $rule `
                    -RunId "fictional-run-$n" -PullRequestId 44 `
                    -Digit ([char]($n + 48))
                [void](Invoke-CoverageV2LedgerFixture @p -Operation Reserve)
            }
            $p = New-FictionalLedgerRequest -RuleId $rule `
                -RunId 'fictional-run-9' -PullRequestId 44 -Digit '9'
            { Invoke-CoverageV2LedgerFixture @p -Operation Reserve } |
                Should -Throw '*coverage-v2-ledger-budget-exhausted*'
            $other = New-FictionalLedgerRequest -RunId 'fictional-run-3' `
                -PullRequestId 44 -Digit 'a'
            (Invoke-CoverageV2LedgerFixture @other -Operation Reserve).state |
                Should -Be 'proof-neutral-not-authority'
        }

        It 'limits one rule/run across PRs without sharing the other rule quota' {
            $ruleA = 'bpm-test-class-coverage@2'
            $ruleB = 'bpm-redundant-method-coverage@2'
            $first = New-FictionalLedgerRequest -RuleId $ruleA `
                -PullRequestId 48 -RunId 'fictional-cross-run' -Digit '1'
            $second = New-FictionalLedgerRequest -RuleId $ruleA `
                -PullRequestId 49 -RunId 'fictional-cross-run' -Digit '2'
            [void](Invoke-CoverageV2LedgerFixture @first -Operation Reserve)
            [void](Invoke-CoverageV2LedgerFixture @second -Operation Reserve)
            $third = New-FictionalLedgerRequest -RuleId $ruleA `
                -PullRequestId 50 -RunId 'fictional-cross-run' -Digit '3'
            { Invoke-CoverageV2LedgerFixture @third -Operation Reserve } |
                Should -Throw '*coverage-v2-ledger-budget-exhausted*'
            $independent = New-FictionalLedgerRequest -RuleId $ruleB `
                -PullRequestId 50 -RunId 'fictional-cross-run' -Digit '4'
            (Invoke-CoverageV2LedgerFixture @independent -Operation Reserve).recorded |
                Should -Be 'reserved'
            $third.RunId = 'fictional-new-run'
            (Invoke-CoverageV2LedgerFixture @third -Operation Reserve).recorded |
                Should -Be 'reserved'
        }

        It 'refuses an overlapping lock rather than stealing or retrying it' {
            $p = New-FictionalLedgerRequest -Digit 'b' -PullRequestId 45 `
                -RunId 'fictional-run-4'
            $bucket = Get-CoverageV2LedgerBucket $p.Root $p.RepositoryId `
                $p.PullRequestId $p.RuleId
            $lock = [IO.File]::Open($bucket.lockPath,
                [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
                [IO.FileShare]::None)
            try {
                { Invoke-CoverageV2LedgerFixture @p -Operation Reserve } |
                    Should -Throw '*coverage-v2-ledger-busy-or-stale-lock*'
                $anotherPr = New-FictionalLedgerRequest -Digit 'a' `
                    -PullRequestId 51 -RunId 'fictional-run-4'
                { Invoke-CoverageV2LedgerFixture @anotherPr -Operation Reserve } |
                    Should -Throw '*coverage-v2-ledger-busy-or-stale-lock*'
            }
            finally {
                $lock.Dispose()
            }
            { Invoke-CoverageV2LedgerFixture @p -Operation Reserve } |
                Should -Throw '*coverage-v2-ledger-busy-or-stale-lock*'
            Remove-Item -LiteralPath $bucket.lockPath -Force
            (Invoke-CoverageV2LedgerFixture @p -Operation Reserve).recorded |
                Should -Be 'reserved'
        }

        It 'refuses unknown or incomplete historical buckets globally' {
            $p = New-FictionalLedgerRequest -Digit 'f' -PullRequestId 53 `
                -RunId 'fictional-run-7'
            $unknown = Join-Path (Join-Path $script:root 'journal') `
                'unknown-fictional-bucket'
            [void](New-Item -ItemType Directory -Path $unknown)
            try {
                { Invoke-CoverageV2LedgerFixture @p -Operation Reserve } |
                    Should -Throw '*coverage-v2-ledger-history-unavailable*'
            }
            finally { Remove-Item -LiteralPath $unknown -Force }
            $empty = (Get-CoverageV2LedgerBucket $p.Root `
                    $p.RepositoryId $p.PullRequestId $p.RuleId).path
            [void](New-Item -ItemType Directory -Path $empty)
            try {
                { Invoke-CoverageV2LedgerFixture @p -Operation Reserve } |
                    Should -Throw '*coverage-v2-ledger-history-unavailable*'
            }
            finally { Remove-Item -LiteralPath $empty -Force }
        }

        It 'blocks every operation on a tampered immutable journal' {
            $p = New-FictionalLedgerRequest -Digit 'c' -PullRequestId 46 `
                -RunId 'fictional-run-5'
            [void](Invoke-CoverageV2LedgerFixture @p -Operation Reserve)
            $bucket = Get-CoverageV2LedgerBucket $p.Root $p.RepositoryId `
                $p.PullRequestId $p.RuleId
            $path = Join-Path $bucket.path '00000001.json'
            [void](Assert-AgentTrustedFile -Path $path `
                    -AllowedRoot $bucket.path -Private)
            $text = [IO.File]::ReadAllText($path)
            try {
                [IO.File]::WriteAllText($path, $text.Replace(
                        '"reserved"', '"attempted"'))
                { Invoke-CoverageV2LedgerFixture @p -Operation Inspect } |
                    Should -Throw '*coverage-v2-ledger-tampered*'
                $next = New-FictionalLedgerRequest -Digit 'd' `
                    -PullRequestId 52 -RunId 'fictional-run-5'
                { Invoke-CoverageV2LedgerFixture @next -Operation Reserve } |
                    Should -Throw '*coverage-v2-ledger-tampered*'
            }
            finally { [IO.File]::WriteAllText($path, $text) }
        }

        It 'refuses a missing middle journal event instead of resetting history' {
            $p = New-FictionalLedgerRequest -Digit 'e' -PullRequestId 47 `
                -RunId 'fictional-run-6'
            [void](Invoke-CoverageV2LedgerFixture @p -Operation Reserve)
            [void](Invoke-CoverageV2LedgerFixture @p -Operation Attempt)
            $bucket = Get-CoverageV2LedgerBucket $p.Root $p.RepositoryId `
                $p.PullRequestId $p.RuleId
            $firstFile = Join-Path $bucket.path '00000001.json'
            $original = [IO.File]::ReadAllBytes($firstFile)
            try {
                Remove-Item -LiteralPath $firstFile -Force
                { Invoke-CoverageV2LedgerFixture @p -Operation Inspect } |
                    Should -Throw '*coverage-v2-ledger-tampered*'
            }
            finally { [IO.File]::WriteAllBytes($firstFile, $original) }
        }

        It 'cannot write outside a dedicated fictional test-owned root' {
            $p = New-FictionalLedgerRequest -Digit 'f'
            $p.Root = Split-Path -Parent $script:root
            { Invoke-CoverageV2LedgerFixture @p -Operation Reserve } |
                Should -Throw '*coverage-v2-ledger-fixture-root-invalid*'
        }
    }
}
