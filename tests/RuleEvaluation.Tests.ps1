#requires -Version 7.0
BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
    Import-Module (Join-Path $repo 'src\DevPilot.RuleEvaluation\DevPilot.RuleEvaluation.psd1') -Force
    Import-Module (Join-Path $repo `
        'src\DevPilot.ActiveOwnerEvaluation\DevPilot.ActiveOwnerEvaluation.psd1')
    Import-Module (Join-Path $repo 'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1')
    Import-Module (Join-Path $repo 'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1')
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
            [int]$Iteration = 1,
            [switch]$EnableCoverage, [switch]$EnableOwner,
            [switch]$EnableRedundant, [switch]$EnableNamed, [string]$Content)
        $intakeConfig = Get-Content (Join-Path $repo 'samples\active-pr-intake.config.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $config = Get-Content (Join-Path $repo 'samples\rule-evaluation.config.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $config.enabled = $true
        if ($EnableCoverage) { $config.rules[1].enabled = $true }
        if ($EnableOwner) {
            $config.rules[0].enabled = $true
            $config.rules[0].binding = [ordered]@{
                ruleRepositoryId = 'enghub-example'
                rulePath = 'documentation/EngineeringProcesses/Conventions/AutomatedTests.md'
                ruleSection = '## Claim ownership'
                ruleCommit = 'f6db83436b48f48a8521095a888d79f67823bbb2'
                ruleHash = 'v1:sha256:bc31bfea6b378dffe4a1b28475dc1cac4cd3ee1ab793db57895446ded829ab2f'
                ruleLength = 100
                capabilityDigest = 'v1:sha256:' + ('e' * 64)
            }
            $config.rules[0].model = [ordered]@{
                id = 'gpt-5.6-sol'
                digest = 'v1:sha256:' + ([Convert]::ToHexString(
                        [Security.Cryptography.SHA256]::HashData(
                            [Text.Encoding]::UTF8.GetBytes('gpt-5.6-sol'))
                    )).ToLowerInvariant()
            }
        }
        if ($EnableRedundant) { $config.rules[2].enabled = $true }
        if ($EnableNamed) { $config.rules[3].enabled = $true }
        $policies = @('test-class-coverage', 'redundant-method-coverage',
            'named-areequal-arguments')
        for ($ruleIndex = 1; $ruleIndex -le 3; $ruleIndex++) {
            if (-not $config.rules[$ruleIndex].enabled) { continue }
            $policy = $policies[$ruleIndex - 1]
            $text = [IO.File]::ReadAllText((Join-Path $repo (
                        "src\DevPilot.OwnerCapability\Policy\$policy.v1.txt")))
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
            $capabilityHash = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes("$policy-capability-v1")
                )).ToLowerInvariant()
            $config.rules[$ruleIndex].binding = [ordered]@{
                ruleRepositoryId = 'rules-example'
                rulePath = "src/DevPilot.OwnerCapability/Policy/$policy.v1.txt"
                ruleCommit = 'c' * 40
                ruleHash = "v1:sha256:$hash"
                capabilityDigest = "v1:sha256:$capabilityHash"
            }
        }
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
                iterationId = $Iteration; status = 'active'; isDraft = $false
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
                    iterationId = if ($available) { $Iteration } else { $null }
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
            failHead = 0; drift = 0; driftAfterVisit = 0
            visits = @{}; discussions = @()
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
                    if (($state.drift -eq $id -and $state.visits[$id] -gt 1) -or
                        ($state.driftAfterVisit -eq $id -and
                            $state.visits[$id] -ge 4)) {
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
    function Invoke-RuleCase($Case, [scriptblock]$OwnerEvaluator) {
        Invoke-BoundedRuleEvaluation -Config $Case.config -IntakeConfig $Case.intakeConfig `
            -Provider $Case.provider -StateRoot $Case.root -RepositoryRoot $repo `
            -SignatureKey 'synthetic-key' -OwnerEvaluator $OwnerEvaluator -Run
    }
    function Get-RuleCaseObservation($Case, $Result, [int]$RuleIndex = 1) {
        $digest = $Result.heads[0].rules[$RuleIndex].observationDigest
        Get-Content -LiteralPath (Join-Path $Case.root (
                "rule-evaluation-v1\observations\$digest.json")) -Raw |
            ConvertFrom-Json -AsHashtable
    }
    function New-RuleCaseThread {
        param($Case, [int]$Line, [string]$Body, [int]$Id = 1,
            [int]$Iteration = 1, [string]$Status = 'active',
            [string]$Path = '/Example.cs', [switch]$Foreign)
        $author = if ($Foreign) {
            @{ id = '44444444-4444-4444-4444-444444444444'
                descriptor = 'aad.foreign'; uniqueName = 'foreign@example.invalid' }
        } else { $Case.intakeConfig.expectedAccount }
        return @{ id = $Id; status = $Status
            comments = @(@{ id = 1; author = $author; commentType = 'text'
                    content = $Body })
            threadContext = @{ filePath = $Path; rightFileStart = @{ line = $Line }
                rightFileEnd = @{ line = $Line } }
            pullRequestThreadContext = @{ changeTrackingId = 1
                iterationContext = @{ firstComparingIteration = $Iteration
                    secondComparingIteration = $Iteration } } }
    }
    function Get-RuleCaseClassBody($Case) {
        $binding = $Case.config.rules[1].binding
        $head = $Case.state.declarations[1]
        $contract = New-OwnerAcquisitionContract `
            -RepositoryId $head.repositoryId -ProjectId $head.projectId `
            -PullRequestId $head.pullRequestId -SourceCommit $head.sourceCommit `
            -TargetCommit $head.targetCommit -TargetRef $head.targetRef `
            -RuleRepositoryId $binding.ruleRepositoryId -RulePath $binding.rulePath `
            -RuleCommit $binding.ruleCommit -RuleSection $Case.config.rules[1].capabilityId `
            -RuleHash $binding.ruleHash -RuleLength 100 `
            -ConfigId 'bounded-rule-evaluation-v1' `
            -ConfigDigest ("v1:sha256:$(Get-TestDigest $Case.config)") `
            -CapabilityId $Case.config.rules[1].capabilityId `
            -CapabilityDigest $binding.capabilityDigest
        $constructRef = 'construct:' + (Get-TestDigest @(
                $Case.config.rules[1].capabilityId, '/Example.cs', 'Example', 3, 3))
        $finding = @{ disposition = 'violation'; constructRef = $constructRef
            anchor = @{ path = 'Example.cs'; line = 3; symbol = 'Example' }
            binding = @{ source = @{ representation = @{
                            constructIdentity = $constructRef; path = 'Example.cs'
                            symbol = 'Example'; startLine = 3; endLine = 3 } } } }
        $marker = Get-TestClassCoverageMarkerKey -Contract $contract -Finding $finding
        Format-TestClassCoverageComment -Contract $contract -Finding $finding `
            -MarkerKey $marker
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
    It 'rejects state inside the repository while accepting external absolute roots' {
        $c = New-RuleCase -EnableCoverage
        { Invoke-BoundedRuleEvaluation -Config $c.config `
                -IntakeConfig $c.intakeConfig -Provider $c.provider `
                -StateRoot (Join-Path $repo 'inside-repository') -RepositoryRoot $repo `
                -SignatureKey 'synthetic-key' -Run } |
            Should -Throw '*outside the repository*'
        $result = Invoke-RuleCase $c
        $result.rules[1].evaluated | Should -Be 1
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
        $declaration.ruleBinding.ruleHash | Should -Be $c.config.rules[1].binding.ruleHash
        $declaration.ruleBinding.capabilityDigest |
            Should -Be $c.config.rules[1].binding.capabilityDigest
        $observation.declarationDigest | Should -Be $rule.declarationDigest
        $observation.outcome.noOp + $observation.outcome.humanCovered +
            $observation.outcome.wouldCreate + $observation.outcome.unknown |
            Should -Be $observation.outcome.findings
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
    It 'keeps near-shifted same-account human comments unknown and never posts' {
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
        $result.rules[1].evaluated | Should -Be 1
        $observation = Get-RuleCaseObservation $c $result
        $observation.outcome.unknown | Should -Be 1
        $observation.outcome.wouldCreate | Should -Be 0
        ($result | ConvertTo-Json -Depth 32) |
            Should -Not -Match 'Please add|prior note|Example.cs'
        $result.providerWrites | Should -Be 0
    }
    It 'distinguishes an exact reviewer marker from same-account unmarked human coverage' {
        $c = New-RuleCase -EnableCoverage
        $body = Get-RuleCaseClassBody $c
        $c.state.discussions = @(New-RuleCaseThread $c 3 $body)
        $first = Invoke-RuleCase $c
        $firstObservation = Get-RuleCaseObservation $c $first
        $firstObservation.outcome.noOp | Should -Be 1
        $firstObservation.outcome.humanCovered | Should -Be 0
        $c.state.discussions = @(New-RuleCaseThread $c 3 'Exclude from code coverage.')
        $second = Invoke-RuleCase $c
        $secondObservation = Get-RuleCaseObservation $c $second
        $secondObservation.outcome.humanCovered | Should -Be 1
        $secondObservation.outcome.noOp | Should -Be 0
        $secondObservation.outcome.wouldCreate | Should -Be 0
        $second.generation | Should -Not -Be $first.generation
        $secondObservation.discussionDigest | Should -Match '^[a-f0-9]{64}$'
        @($c.state.calls | Where-Object { $_ -match '^(Post|Update|Create):' }).Count |
            Should -Be 0
    }
    It 'treats stale, closed, moved, and overlapping marker threads as unknown' {
        foreach ($mode in @('historical', 'closed', 'moved', 'overlap')) {
            $c = New-RuleCase -EnableCoverage -Iteration $(if ($mode -eq 'historical') { 2 } else { 1 })
            $body = Get-RuleCaseClassBody $c
            $c.state.discussions = @(switch ($mode) {
                historical { New-RuleCaseThread $c 3 $body -Iteration 1 }
                closed { New-RuleCaseThread $c 3 $body -Status 'closed' }
                moved { New-RuleCaseThread $c 4 $body }
                overlap {
                    New-RuleCaseThread $c 3 $body -Id 1
                    New-RuleCaseThread $c 3 'Exclude from code coverage.' -Id 2
                }
            })
            $result = Invoke-RuleCase $c
            $result.rules[1].evaluated | Should -Be 1
            $outcome = (Get-RuleCaseObservation $c $result).outcome
            $outcome.unknown | Should -Be 1 -Because $mode
            $outcome.noOp | Should -Be 0
            $outcome.wouldCreate | Should -Be 0
        }
    }
    It 'groups a plural class review over changed attributes and isolates method reviews' {
        $content = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Diagnostics.CodeAnalysis;
[TestClass]
[ExcludeFromCodeCoverage]
public class Example {
  [TestMethod]
  [ExcludeFromCodeCoverage]
  public void First() { Assert.AreEqual(1, 1); }
  [TestMethod]
  [ExcludeFromCodeCoverage]
  public void Second() { Assert.AreEqual(2, 2); }
}
'@
        $c = New-RuleCase -EnableRedundant -EnableNamed -Content ($content + "`n")
        $c.state.discussions = @(
            (New-RuleCaseThread $c 10 `
                'These method-level coverage exclusions are redundant because the entire class is already excluded.' -Id 1),
            (New-RuleCaseThread $c 8 'Please use named expected and actual arguments in Assert.AreEqual.' -Id 2))
        $result = Invoke-RuleCase $c
        $redundant = (Get-RuleCaseObservation $c $result 2).outcome
        $redundant.findings | Should -Be 1
        $redundant.humanCovered | Should -Be 1
        $named = (Get-RuleCaseObservation $c $result 3).outcome
        $named.findings | Should -Be 2
        $named.humanCovered | Should -Be 1
        $named.wouldCreate | Should -Be 1
    }
    It 'fails closed on incomplete discussion counts and unsigned rule provenance' {
        $c = New-RuleCase -EnableCoverage
        $c.config.rules[1].binding.ruleCommit = ''
        Sign-TestConfig $c.config
        { Invoke-RuleCase $c } | Should -Throw '*rule-binding-unavailable*'
        $c.state.calls.Count | Should -Be 0
        $valid = New-RuleCase -EnableCoverage
        $provider = $valid.provider
        $valid.provider = {
            param($operation, $request)
            if ($operation -ceq 'Discussions') {
                return @{ count = 2; threads = @() }
            }
            & $provider $operation $request
        }.GetNewClosure()
        $result = Invoke-RuleCase $valid
        $result.rules[1].evaluated | Should -Be 0
        $result.rules[1].unknown | Should -Be 1
        $result.heads[0].rules[1].reasonCode | Should -Be 'invalid-discussions'
        $result.providerWrites | Should -Be 0
    }
    It 'does not treat foreign marker text, incomplete anchors or body drift as no-op' {
        foreach ($mode in @('foreign', 'unanchored', 'unanchored-human', 'body-drift')) {
            $c = New-RuleCase -EnableCoverage
            $body = Get-RuleCaseClassBody $c
            $thread = New-RuleCaseThread $c 3 $body -Foreign:($mode -eq 'foreign')
            if ($mode -in @('unanchored', 'unanchored-human')) {
                $thread.threadContext.Remove('rightFileStart')
            }
            if ($mode -eq 'unanchored-human') {
                $thread.comments[0].content = 'Exclude from code coverage.'
            }
            if ($mode -eq 'body-drift') {
                $thread.comments[0].content = $body.Replace(
                    'Suggested fix:', 'Suggested correction:')
            }
            $c.state.discussions = @($thread)
            $result = Invoke-RuleCase $c
            $result.rules[1].evaluated | Should -Be 1
            $outcome = (Get-RuleCaseObservation $c $result).outcome
            $outcome.unknown | Should -Be 1 -Because $mode
            $outcome.noOp | Should -Be 0
            $outcome.wouldCreate | Should -Be 0
        }
    }
    It 'reconciles complete paged discussions without broad human gating' {
        $c = New-RuleCase -EnableCoverage
        $threads = [Collections.Generic.List[object]]::new()
        for ($id = 1; $id -le 201; $id++) {
            [void]$threads.Add((New-RuleCaseThread $c 3 'Unrelated discussion.' `
                    -Id $id -Path '/Other.cs' -Foreign))
        }
        $c.state.discussions = $threads.ToArray()
        $result = Invoke-RuleCase $c
        $result.rules[1].evaluated | Should -Be 1
        $observation = Get-RuleCaseObservation $c $result
        $observation.outcome.wouldCreate | Should -Be 1
        $observation.outcome.unknown | Should -Be 0
        $result.providerWrites | Should -Be 0
    }
    It 'treats 22 changed method attributes as one class finding' {
        $lines = [Collections.Generic.List[string]]::new()
        foreach ($line in @('using Microsoft.VisualStudio.TestTools.UnitTesting;',
                'using System.Diagnostics.CodeAnalysis;', '[TestClass]',
                '[ExcludeFromCodeCoverage]', 'public class Example {')) {
            [void]$lines.Add($line)
        }
        for ($i = 1; $i -le 22; $i++) {
            [void]$lines.Add('  [TestMethod]')
            [void]$lines.Add('  [ExcludeFromCodeCoverage]')
            [void]$lines.Add("  public void Test$i() {}")
        }
        [void]$lines.Add('}')
        $c = New-RuleCase -EnableRedundant -Content (($lines -join "`n") + "`n")
        $c.state.discussions = @(New-RuleCaseThread $c 7 `
                'These method-level exclusions are redundant: the class-level coverage exclusion already applies to the entire class.')
        $result = Invoke-RuleCase $c
        $observation = Get-RuleCaseObservation $c $result 2
        $observation.outcome.findings | Should -Be 1
        $observation.outcome.humanCovered | Should -Be 1
        $observation.outcome.wouldCreate | Should -Be 0
    }
    It 'binds a line-261 human comment only to its named-argument method among 26 calls' {
        $lines = [Collections.Generic.List[string]]::new()
        [void]$lines.Add('using Microsoft.VisualStudio.TestTools.UnitTesting;')
        while ($lines.Count -lt 254) { [void]$lines.Add('') }
        [void]$lines.Add('[TestClass]')
        [void]$lines.Add('public class Example {')
        $firstCallLine = 0
        for ($method = 1; $method -le 6; $method++) {
            [void]$lines.Add('  [TestMethod]')
            [void]$lines.Add("  public void Test$method() {")
            $calls = if ($method -le 2) { 5 } else { 4 }
            for ($call = 1; $call -le $calls; $call++) {
                if ($method -eq 1 -and $call -eq 1) { $firstCallLine = $lines.Count + 1 }
                [void]$lines.Add("    Assert.AreEqual($call, $call);")
            }
            [void]$lines.Add('  }')
        }
        [void]$lines.Add('}')
        while ($firstCallLine -lt 261) {
            $lines.Insert(254, '')
            $firstCallLine++
        }
        $firstCallLine | Should -Be 261
        $c = New-RuleCase -EnableNamed -Content (($lines -join "`n") + "`n")
        $c.state.discussions = @(New-RuleCaseThread $c 261 `
                'Please use named expected and actual arguments in Assert.AreEqual.')
        $result = Invoke-RuleCase $c
        $observation = Get-RuleCaseObservation $c $result 3
        $observation.outcome.findings | Should -Be 6
        $observation.outcome.humanCovered | Should -Be 1
        $observation.outcome.wouldCreate | Should -Be 5
        $observation.outcome.unknown | Should -Be 0
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
    It 'requires a signed exact EngHub Owner section binding before reading ADO' {
        $c = New-RuleCase -EnableOwner
        $c.config.rules[0].binding.ruleCommit = 'a' * 40
        Sign-TestConfig $c.config
        { Invoke-RuleCase $c } | Should -Throw '*owner-rule-binding-unavailable*'
        $c.state.calls.Count | Should -Be 0
    }
    It 'reports missing pinned Owner bytes explicitly without crediting a head' {
        $c = New-RuleCase -EnableOwner
        $owner = New-ActiveOwnerEvaluator -StateRoot $c.root `
            -IntakeConfig $c.intakeConfig `
            -ReviewerIdentity $c.intakeConfig.expectedAccount
        $result = Invoke-RuleCase $c $owner
        $result.rules[0].evaluated | Should -Be 0
        $result.heads[0].rules[0].reasonCode |
            Should -Be 'owner-rule-bytes-unavailable'
        $result.providerWrites | Should -Be 0
        Test-Path -LiteralPath (Join-Path $c.root 'active-owner-evaluation-v1') |
            Should -BeFalse
    }
    It 'preserves exact Owner per-finding outcomes despite unrelated human discussion' {
        $c = New-RuleCase -EnableOwner
        $c.state.discussions = @(New-RuleCaseThread $c 3 'Unrelated test discussion.')
        $intakeGeneration = $c.intake.generation
        $owner = {
            param($head, $files, $discussion, $evidence, $generation,
                $ruleConfig, $ruleDeclaration, $declarationDigest)
            return @{ state = 'evaluated'; reason = 'completed'; findings = 2
                unknown = 0; noOp = 1; humanCovered = 1; wouldCreate = 0
                discussionDigest = 'd' * 64
                findingOutcomes = @(
                    @{ findingDigest = 'e' * 64; classification = 'noOp'
                        reason = 'exact-marker' },
                    @{ findingDigest = 'f' * 64; classification = 'humanCovered'
                        reason = 'human-discussion' })
                completed = $true; providerWrites = 0; writeToolInvocations = 0
                modelToolInvocations = 0; manifestEntryCount = 1
                manifestDigest = 'v1:sha256:' + ('a' * 64)
                durableProof = @{
                    identity = 'b' * 64
                    stateDigest = 'v1:sha256:' + ('b' * 64)
                    observationDigest = 'v1:sha256:' + ('c' * 64)
                    recordFileDigest = 'v1:sha256:' + ('d' * 64)
                    manifestFileDigest = 'v1:sha256:' + ('e' * 64)
                    acquisitionPayloadDigest = 'v1:sha256:' + ('f' * 64)
                }
                intakeGeneration = $intakeGeneration
                declarationDigest = $declarationDigest
                sourceCommit = $head.sourceCommit; targetCommit = $head.targetCommit
                targetRef = $head.targetRef; iterationId = $head.iterationId
                ruleId = $ruleConfig.ruleId }
        }.GetNewClosure()
        $result = Invoke-RuleCase $c $owner
        $result.rules[0].evaluated | Should -Be 1
        $observation = Get-RuleCaseObservation $c $result 0
        $observation.outcome | Should -Not -BeNullOrEmpty
        $observation.outcome.findings | Should -Be 2
        $observation.outcome.noOp | Should -Be 1
        $observation.outcome.humanCovered | Should -Be 1
        $observation.outcome.wouldCreate | Should -Be 0
        $observation.findingOutcomes.Count | Should -Be 2
        $c.state.calls[-1] | Should -Be 'Head:1'
        @($c.state.calls | Where-Object { $_ -eq 'Discussions:1' }).Count |
            Should -Be 2
        $initialDiscussion = $c.state.discussions
        $state = $c.state
        $racing = {
            param($head, $files, $discussion, $evidence, $generation,
                $ruleConfig, $ruleDeclaration, $declarationDigest)
            $state.discussions = @()
            & $owner $head $files $discussion $evidence $generation `
                $ruleConfig $ruleDeclaration $declarationDigest
        }.GetNewClosure()
        $race = Invoke-RuleCase $c $racing
        $race.rules[0].evaluated | Should -Be 0
        $race.heads[0].rules[0].reasonCode | Should -Be 'discussion-head-mismatch'
        $race.providerWrites | Should -Be 0
        $c.state.discussions = $initialDiscussion
    }
    It 'rejects duplicate Owner finding identities and post-model drift' {
        $c = New-RuleCase -EnableOwner
        $intakeGeneration = $c.intake.generation
        $owner = {
            param($head, $files, $discussion, $evidence, $generation,
                $ruleConfig, $ruleDeclaration, $declarationDigest)
            return @{ state = 'evaluated'; reason = 'completed'; findings = 2
                noOp = 0; humanCovered = 0; wouldCreate = 2; unknown = 0
                discussionDigest = 'd' * 64
                findingOutcomes = @(
                    @{ findingDigest = 'e' * 64; classification = 'wouldCreate'
                        reason = 'reviewer-marker-not-found' },
                    @{ findingDigest = 'e' * 64; classification = 'wouldCreate'
                        reason = 'reviewer-marker-not-found' })
                completed = $true; providerWrites = 0; writeToolInvocations = 0
                modelToolInvocations = 0; manifestEntryCount = 1
                manifestDigest = 'v1:sha256:' + ('a' * 64)
                durableProof = @{
                    identity = 'b' * 64
                    stateDigest = 'v1:sha256:' + ('b' * 64)
                    observationDigest = 'v1:sha256:' + ('c' * 64)
                    recordFileDigest = 'v1:sha256:' + ('d' * 64)
                    manifestFileDigest = 'v1:sha256:' + ('e' * 64)
                    acquisitionPayloadDigest = 'v1:sha256:' + ('f' * 64)
                }
                intakeGeneration = $intakeGeneration
                declarationDigest = $declarationDigest
                sourceCommit = $head.sourceCommit; targetCommit = $head.targetCommit
                targetRef = $head.targetRef; iterationId = $head.iterationId
                ruleId = $ruleConfig.ruleId }
        }.GetNewClosure()
        $duplicate = Invoke-RuleCase $c $owner
        $duplicate.heads[0].rules[0].reasonCode | Should -Be 'rule-ambiguous'
        $duplicate.rules[0].evaluated | Should -Be 0
        $c.state.drift = 1
        $drift = Invoke-RuleCase $c $owner
        $drift.rules[0].evaluated | Should -Be 0
        $drift.heads[0].rules[0].reasonCode | Should -Be 'head-drift'
        $drift.providerWrites | Should -Be 0
        $c.state.drift = 0
        $c.state.visits.Clear()
        $c.state.driftAfterVisit = 1
        $lastReadDrift = Invoke-RuleCase $c $owner
        $lastReadDrift.rules[0].evaluated | Should -Be 0
        $lastReadDrift.heads[0].rules[0].reasonCode | Should -Be 'head-drift'
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
