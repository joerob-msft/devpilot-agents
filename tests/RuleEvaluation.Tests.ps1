#requires -Version 7.0
BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
    Import-Module (Join-Path $repo 'src\DevPilot.RuleEvaluation\DevPilot.RuleEvaluation.psd1') -Force
    $script:roots = [Collections.Generic.List[string]]::new()
    function Get-TestDigest($Value) {
        $json = ConvertTo-Json -InputObject $Value -Depth 32 -Compress
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
    }
    function Sign-TestConfig($Config) {
        $unsigned = [ordered]@{}
        foreach ($key in $Config.Keys) {
            if ($key -ne 'signature') { $unsigned[$key] = $Config[$key] }
        }
        $hmac = [Security.Cryptography.HMACSHA256]::new(
            [Text.Encoding]::UTF8.GetBytes('synthetic-key'))
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes(
                (ConvertTo-AgentCanonicalJson -InputObject $unsigned))
            $Config.signature = 'v1:hmac-sha256:' +
                [Convert]::ToHexString($hmac.ComputeHash($bytes)).ToLowerInvariant()
        }
        finally { $hmac.Dispose() }
    }
    function New-RuleCase {
        param([int]$Master = 1, [int]$Other = 0, [int]$Unknown = 0,
            [switch]$EnableCoverage, [switch]$EnableOwner,
            [switch]$EnableRedundant, [switch]$EnableNamed, [string]$Content)
        $intakeConfig = Get-Content (Join-Path $repo 'samples\active-pr-intake.config.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $config = Get-Content (Join-Path $repo 'samples\rule-evaluation.config.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $config.enabled = $true
        if ($EnableCoverage) { $config.rules[1].enabled = $true }
        if ($EnableOwner) { $config.rules[0].enabled = $true }
        if ($EnableRedundant) { $config.rules[2].enabled = $true }
        if ($EnableNamed) { $config.rules[3].enabled = $true }
        Sign-TestConfig $config
        $root = Join-Path $env:USERPROFILE (
            '.copilot\rule-evaluation-pester-' + [guid]::NewGuid().ToString('N'))
        $script:roots.Add($root)
        $intakeRoot = Join-Path $root 'active-pr-intake-v1'
        New-Item -ItemType Directory -Path (Join-Path $intakeRoot 'generations') -Force |
            Out-Null
        $generation = [guid]::NewGuid().ToString('N')
        $content = if ($Content) { $Content } else {
            "using Microsoft.VisualStudio.TestTools.UnitTesting;`n" +
            "[TestClass]`npublic class Example {`n" +
            "  [TestMethod]`n  public void Test() { Assert.AreEqual(1, 1); }`n}`n"
        }
        $lineCount = @([regex]::Matches($content, '\n')).Count
        $path = '/Example.cs'
        $pathDigest = Get-TestDigest $path
        $heads = [Collections.Generic.List[object]]::new()
        $declarations = @{}
        $proofs = @{}
        $rules = @($config.rules | ForEach-Object {
                @{ id = $_.ruleId; capability = $_.capabilityId }
            })
        for ($i = 1; $i -le $Master + $Other; $i++) {
            $target = if ($i -le $Master) { 'refs/heads/master' }
            else { 'refs/heads/release' }
            $declaration = [ordered]@{
                repositoryId = $config.repositoryId; projectId = $config.projectId
                pullRequestId = $i; sourceRef = 'refs/heads/feature'
                targetRef = $target; sourceCommit = 'a' * 40
                targetCommit = 'b' * 40; commonCommit = 'c' * 40
                iterationId = 1; status = 'active'; isDraft = $false
            }
            $declarations[$i] = $declaration
            $file = [ordered]@{
                pathDigest = $pathDigest; originalPathDigest = $null
                changeType = 'add'; addedLines = $lineCount; deletedLines = 0
                newLineCount = $lineCount
                spans = @(@{ startLine = 1; endLine = $lineCount })
            }
            $evidence = [ordered]@{
                generation = $generation
                declarationDigest = Get-TestDigest $declaration
                configDigest = Get-TestDigest $intakeConfig
                baseCommit = 'c' * 40; changedFiles = 1; changedLines = $lineCount
                addedLines = $lineCount; deletedLines = 0; files = @($file)
            }
            $proofs[$i] = $evidence
            $available = $i -le ($Master - $Unknown)
            $state = if ($i -gt $Master) { 'skipped' }
            elseif ($available) { 'pending' }
            else { 'unknown' }
            $reason = if ($state -eq 'skipped') { 'target-out-of-policy' }
            elseif ($available) { 'rules-incomplete' }
            else { 'line-count-unavailable' }
            $heads.Add([ordered]@{
                    pullRequestId = $i
                    targetRef = $target
                    declaration = if ($available) { $declaration } else { $null }
                    declarationDigest = if ($available) { Get-TestDigest $declaration } else { $null }
                    sourceCommit = if ($available) { 'a' * 40 } else { $null }
                    targetCommit = if ($available) { 'b' * 40 } else { $null }
                    iterationId = if ($available) { 1 } else { $null }
                    status = $state; reason = $reason
                    lineEvidence = if ($available) { $evidence } else { $null }
                    lineEvidenceDigest = if ($available) { Get-TestDigest $evidence } else { $null }
                    rules = @($rules | ForEach-Object {
                            @{ id = $_.id; capability = $_.capability; ruleId = $_.id
                                capabilityId = $_.capability; status = $state
                                reasonCode = $reason }
                        })
                })
        }
        $intake = [ordered]@{
            schemaVersion = 1; kind = 'active-pr-intake-cohort'
            generation = $generation
            generationFile = Join-Path 'generations' "$generation.json"
            observedUtc = [DateTime]::UtcNow.ToString('o')
            binding = [ordered]@{
                organization = $config.organization
                projectId = $config.projectId; repositoryId = $config.repositoryId
                configDigest = Get-TestDigest $intakeConfig
            }
            inventory = [ordered]@{ state = 'complete'; discovered = $Master + $Other
                eligible = $Master; excludedOtherTargets = $Other; draft = 0 }
            heads = @($heads.ToArray())
            rules = @($rules | ForEach-Object {
                    @{ capabilityId = $_.capability; ruleId = $_.id
                        discovered = $Master + $Other; eligible = $Master; evaluated = 0 }
                })
        }
        $json = ConvertTo-Json -InputObject $intake -Depth 32
        [IO.File]::WriteAllText((Join-Path $intakeRoot 'cohort.json'), $json)
        [IO.File]::WriteAllText(
            (Join-Path $intakeRoot "generations\$generation.json"), $json)
        $state = @{ calls = [Collections.Generic.List[string]]::new()
            failHead = 0; drift = 0; visits = @{}; discussions = @()
            declarations = $declarations; proofs = $proofs
            blockLatest = 0; lock = $null; changeLines = $lineCount }
        $provider = {
            param($operation, $request)
            $id = [int]$request.pullRequestId
            $state.calls.Add("$operation`:$id") | Out-Null
            switch ($operation) {
                Identity {
                    return $intakeConfig.expectedAccount
                }
                Head {
                    if ($state.failHead -eq $id) { throw 'private ADO message' }
                    if ($state.blockLatest -eq $id -and $null -eq $state.lock) {
                        $latest = Join-Path $root 'rule-evaluation-v1\cohort.json'
                        $state.lock = [IO.File]::Open($latest, 'Open', 'Read', 'None')
                    }
                    if (-not $state.visits.ContainsKey($id)) { $state.visits[$id] = 0 }
                    $state.visits[$id]++
                    $copy = @{}
                    foreach ($key in $state.declarations[$id].Keys) {
                        $copy[$key] = $state.declarations[$id][$key]
                    }
                    if ($state.drift -eq $id -and $state.visits[$id] -gt 1) {
                        $copy.sourceCommit = 'd' * 40
                    }
                    return $copy
                }
                Changes {
                    $proof = $state.proofs[$id]
                    return @{ changedFiles = 1; changedLines = $state.changeLines
                        baseCommit = 'c' * 40
                        files = $proof.files
                        evaluationFiles = @(@{ path = $path; content = $content
                                objectId = 'e' * 40 }) }
                }
                Discussions {
                    return @{ count = $state.discussions.Count
                        threads = $state.discussions }
                }
                default { throw 'unexpected write or listing operation' }
            }
        }.GetNewClosure()
        return @{ config = $config; intakeConfig = $intakeConfig; provider = $provider
            state = $state; root = $root; intake = $intake }
    }
    function Invoke-RuleCase($Case) {
        Invoke-BoundedRuleEvaluation -Config $Case.config -IntakeConfig $Case.intakeConfig `
            -Provider $Case.provider -StateRoot $Case.root -RepositoryRoot $repo `
            -SignatureKey 'synthetic-key' -Run
    }
}
AfterAll {
    foreach ($root in $script:roots) {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}
Describe 'Bounded read-only scheduled rule evaluation' {
    It 'does not read the provider or write state without the run switch or enablement' {
        $c = New-RuleCase
        $result = Invoke-BoundedRuleEvaluation -Config $c.config `
            -IntakeConfig $c.intakeConfig -Provider $c.provider -StateRoot $c.root `
            -RepositoryRoot $repo
        $result.enabled | Should -BeFalse
        $c.state.calls.Count | Should -Be 0
        (Test-Path (Join-Path $c.root 'rule-evaluation-v1')) | Should -BeFalse
    }
    It 'rejects invalid signatures and tampered or incomplete immutable intake' {
        $c = New-RuleCase -EnableCoverage
        $c.config.limits.maxHeadsPerRun = 21
        { Invoke-RuleCase $c } | Should -Throw
        $c.config.limits.maxHeadsPerRun = 19
        { Invoke-RuleCase $c } | Should -Throw '*invalid-signature*'
        $c.config.limits.maxHeadsPerRun = 20
        Sign-TestConfig $c.config
        [IO.File]::AppendAllText((Join-Path $c.root 'active-pr-intake-v1\cohort.json'), ' ')
        { Invoke-RuleCase $c } | Should -Throw '*intake-generation-mismatch*'
        $c.state.calls.Count | Should -Be 0
    }
    It 'rejects stale intake and records draft exclusions separately from non-master heads' {
        $stale = New-RuleCase -EnableCoverage
        $stale.intake.observedUtc = [DateTime]::UtcNow.AddDays(-2).ToString('o')
        $intakeRoot = Join-Path $stale.root 'active-pr-intake-v1'
        $json = ConvertTo-Json -InputObject $stale.intake -Depth 32
        [IO.File]::WriteAllText((Join-Path $intakeRoot 'cohort.json'), $json)
        [IO.File]::WriteAllText(
            (Join-Path $intakeRoot "generations\$($stale.intake.generation).json"), $json)
        { Invoke-RuleCase $stale } | Should -Throw '*intake-stale-or-invalid*'
        $stale.state.calls.Count | Should -Be 0

        $current = New-RuleCase -Master 1 -Other 1 -EnableCoverage
        $current.intake.inventory.draft = 227
        $intakeRoot = Join-Path $current.root 'active-pr-intake-v1'
        $json = ConvertTo-Json -InputObject $current.intake -Depth 32
        [IO.File]::WriteAllText((Join-Path $intakeRoot 'cohort.json'), $json)
        [IO.File]::WriteAllText(
            (Join-Path $intakeRoot "generations\$($current.intake.generation).json"), $json)
        $result = Invoke-RuleCase $current
        $result.inventory.draftExcluded | Should -Be 227
        $result.inventory.excludedOtherTargets | Should -Be 1
        $result.rules[1].skipped | Should -Be 1
    }
    It 'keeps 347 discovered, 275 eligible and 72 excluded with every stable head selected within 14 batches' {
        $c = New-RuleCase -Master 275 -Other 72 -EnableCoverage
        $visited = [Collections.Generic.HashSet[int]]::new()
        for ($cycle = 0; $cycle -lt 14; $cycle++) {
            $result = Invoke-RuleCase $c
            $result.inventory.discovered | Should -Be 347
            $result.inventory.eligible | Should -Be 275
            $result.inventory.excludedOtherTargets | Should -Be 72
            $result.providerWrites | Should -Be 0
            @($result.heads | Where-Object {
                    $_.rules[1].status -eq 'evaluated'
                }).Count | Should -BeLessOrEqual 20
            foreach ($id in @($c.state.calls | Where-Object { $_ -like 'Head:*' } |
                    ForEach-Object { [int]($_ -split ':')[1] })) {
                [void]$visited.Add($id)
            }
        }
        $visited.Count | Should -Be 275
        @($visited | Where-Object { $_ -gt 275 }).Count | Should -Be 0
        @($result.heads | Where-Object { $_.rules[1].status -eq 'skipped' }).Count |
            Should -Be 72
    }
    It 'persists only new per-head/rule observations tied to the same immutable generation' {
        $c = New-RuleCase -Master 2 -EnableCoverage
        $result = Invoke-RuleCase $c
        $result.rules[1].evaluated | Should -Be 2
        $rule = $result.heads[0].rules[1]
        $rule.observationDigest | Should -Match '^[a-f0-9]{64}$'
        $path = Join-Path $c.root "rule-evaluation-v1\observations\$($rule.observationDigest).json"
        $bytes = [IO.File]::ReadAllBytes($path)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).
            ToLowerInvariant() | Should -Be $rule.observationDigest
        $observation = Get-Content $path -Raw | ConvertFrom-Json
        $observation.intakeGeneration | Should -Be $c.intake.generation
        $observation.generation | Should -Be $result.generation
        $observation.providerWrites | Should -Be 0
        $observation.outcome.findings | Should -Be 1
        $declarationPath = Join-Path $c.root (
            "rule-evaluation-v1\declarations\$($rule.declarationDigest).json")
        $declaration = Get-Content -LiteralPath $declarationPath -Raw |
            ConvertFrom-Json
        $declaration.intakeGeneration | Should -Be $c.intake.generation
        $declaration.lineEvidenceDigest |
            Should -Be $c.intake.heads[0].lineEvidenceDigest
        $declaration.writerEligible | Should -BeFalse
        $observation.declarationDigest | Should -Be $rule.declarationDigest
        (Get-Content $path -Raw) | Should -Not -Match 'Example.cs|Assert.AreEqual'
    }
    It 'keeps redundant exclusions per class and named positional calls per method independent' {
        $content = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Diagnostics.CodeAnalysis;
[TestClass]
[ExcludeFromCodeCoverage]
public class Example {
  [TestMethod]
  [ExcludeFromCodeCoverage]
  public void Test() {
    Assert.AreEqual(1, 1);
    Assert.AreEqual(2, 2);
  }
}
'@
        $c = New-RuleCase -EnableCoverage -EnableRedundant -EnableNamed `
            -Content ($content + "`n")
        $result = Invoke-RuleCase $c
        $result.rules[1].evaluated | Should -Be 1
        $result.rules[2].evaluated | Should -Be 1
        $result.rules[3].evaluated | Should -Be 1
        $getFindings = {
            param($Index)
            $digest = $result.heads[0].rules[$Index].observationDigest
            $file = Join-Path $c.root "rule-evaluation-v1\observations\$digest.json"
            (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).outcome.findings
        }
        (& $getFindings 1) | Should -Be 0
        (& $getFindings 2) | Should -Be 1
        (& $getFindings 3) | Should -Be 1
    }
    It 'refuses to credit a class evaluation exceeding its independent cap' {
        $content = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
[TestClass]
public class First { }
[TestClass]
public class Second { }
'@
        $c = New-RuleCase -EnableCoverage -Content ($content + "`n")
        $c.config.rules[1].maxFindingsPerHead = 1
        Sign-TestConfig $c.config
        $result = Invoke-RuleCase $c
        $result.rules[1].evaluated | Should -Be 0
        $result.rules[1].unknown | Should -Be 1
        $result.heads[0].rules[1].reasonCode | Should -Be 'finding-cap'
        $result.heads[0].rules[1].observationDigest | Should -BeNullOrEmpty
    }
    It 'treats duplicate historical same-account human comments as human and never posts' {
        $c = New-RuleCase -EnableCoverage
        $account = $c.intakeConfig.expectedAccount
        $c.state.discussions = @(
            @{ id = 1; comments = @(
                    @{ id = 1; author = $account; commentType = 'text'
                        content = 'Please add class coverage exclusion.' },
                    @{ id = 1; author = $account; commentType = 'text'
                        content = 'Please add class coverage exclusion.' },
                    @{ id = 2; author = $account; commentType = 'text'
                        content = '[DevPilot-Automation:v1] prior note' }
                ); threadContext = @{ filePath = '/Example.cs'
                    rightFileStart = @{ line = 2 }; rightFileEnd = @{ line = 2 } }
                pullRequestThreadContext = @{ changeTrackingId = 1
                    iterationContext = @{ firstComparingIteration = 1
                        secondComparingIteration = 1 } } }
        )
        $result = Invoke-RuleCase $c
        $result.rules[1].unknown | Should -Be 1
        $result.rules[1].evaluated | Should -Be 0
        ($result | ConvertTo-Json -Depth 32) |
            Should -Not -Match 'Please add|prior note|Example.cs'
        $result.providerWrites | Should -Be 0
    }
    It 'fails closed for mid-cycle drift and ADO failures without leaking diagnostics' {
        $c = New-RuleCase -Master 2 -EnableCoverage
        $c.state.drift = 1
        $c.state.failHead = 2
        $result = Invoke-RuleCase $c
        $result.rules[1].evaluated | Should -Be 0
        $result.rules[1].unknown | Should -Be 1
        $result.rules[1].error | Should -Be 1
        ($result | ConvertTo-Json -Depth 32) | Should -Not -Match 'private ADO message'
    }
    It 'does not credit changed-line mismatches or run concurrently under a lease' {
        $c = New-RuleCase -EnableCoverage
        $first = Invoke-RuleCase $c
        $lock = [IO.File]::Open((Join-Path $c.root 'rule-evaluation-v1\cohort.lock'),
            'Open', 'ReadWrite', 'None')
        try {
            { Invoke-RuleCase $c } | Should -Throw
        }
        finally { $lock.Dispose() }
        $current = Get-Content (Join-Path $c.root 'rule-evaluation-v1\cohort.json') -Raw |
            ConvertFrom-Json
        $current.generation | Should -Be $first.generation
        $c.state.changeLines++
        $later = Invoke-RuleCase $c
        $later.rules[1].evaluated | Should -Be 0
        $later.rules[1].unknown | Should -Be 1
        $later.heads[0].rules[1].reasonCode | Should -Be 'changed-lines-mismatch'
    }
    It 'does not credit selected heads with unknown changed lines' {
        $c = New-RuleCase -Master 2 -Unknown 1 -EnableCoverage
        $result = Invoke-RuleCase $c
        $result.rules[1].unknown | Should -Be 1
        $result.rules[1].evaluated | Should -Be 1
        @($c.state.calls | Where-Object { $_ -eq 'Head:2' }).Count | Should -Be 0
    }
    It 'accepts equivalent uppercase provider commit and GUID spellings' {
        $c = New-RuleCase -EnableCoverage
        $c.state.declarations[1].repositoryId = $c.config.repositoryId.ToUpperInvariant()
        $c.state.declarations[1].projectId = $c.config.projectId.ToUpperInvariant()
        $c.state.declarations[1].sourceCommit = ('a' * 40).ToUpperInvariant()
        $result = Invoke-RuleCase $c
        $result.rules[1].evaluated | Should -Be 1
    }
    It 'does not evaluate incomplete paging inventories or exceed read quotas' {
        $incomplete = New-RuleCase -EnableCoverage
        $intakeRoot = Join-Path $incomplete.root 'active-pr-intake-v1'
        $incomplete.intake.inventory.state = 'unknown'
        $json = ConvertTo-Json -InputObject $incomplete.intake -Depth 32
        [IO.File]::WriteAllText((Join-Path $intakeRoot 'cohort.json'), $json)
        [IO.File]::WriteAllText(
            (Join-Path $intakeRoot "generations\$($incomplete.intake.generation).json"), $json)
        { Invoke-RuleCase $incomplete } | Should -Throw '*intake-incomplete-or-unbound*'
        $incomplete.state.calls.Count | Should -Be 0

        $quota = New-RuleCase -Master 2 -EnableCoverage
        $quota.config.limits.maxReads = 1
        Sign-TestConfig $quota.config
        $result = Invoke-RuleCase $quota
        $result.rules[1].unknown | Should -Be 2
        $result.rules[1].evaluated | Should -Be 0
        $result.readCount | Should -Be 1
        @($quota.state.calls | Where-Object { $_ -like 'Changes:*' }).Count |
            Should -Be 0
    }
    It 'leaves Owner uncredited without a bound no-write evaluator' {
        $c = New-RuleCase -EnableOwner
        $result = Invoke-RuleCase $c
        $result.rules[0].unknown | Should -Be 1
        $result.heads[0].rules[0].reasonCode |
            Should -Be 'owner-evaluator-unavailable'
        $result.rules[0].evaluated | Should -Be 0
        $result.providerWrites | Should -Be 0
    }
    It 'retains the cursor and immutable generation on a crash before persistence' {
        $c = New-RuleCase -Master 23 -EnableCoverage
        $first = Invoke-RuleCase $c
        $c.state.blockLatest = 21
        try {
            { Invoke-RuleCase $c } | Should -Throw
        }
        finally {
            if ($c.state.lock) { $c.state.lock.Dispose(); $c.state.lock = $null }
            $c.state.blockLatest = 0
        }
        $unchanged = Get-Content (Join-Path $c.root 'rule-evaluation-v1\cohort.json') -Raw |
            ConvertFrom-Json
        $unchanged.generation | Should -Be $first.generation
        $unchanged.cursor.nextPullRequestId | Should -Be 21
        $retry = Invoke-RuleCase $c
        $retry.rules[1].evaluated | Should -Be 20
        $retry.heads[20].rules[1].status | Should -Be 'evaluated'
        $retry.cursor.nextPullRequestId | Should -Be 18
    }
}
