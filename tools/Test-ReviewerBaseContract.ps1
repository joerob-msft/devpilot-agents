#Requires -Version 7.0

<#
.SYNOPSIS
    Proves the reviewer base lineage contract accepts exactly the identities it
    should and refuses everything else.

.DESCRIPTION
    The contract replaced a single `git merge-base --is-ancestor` call. That
    call had one virtue worth keeping: it failed closed. These checks exist to
    show the replacement fails closed in strictly more ways, not fewer.

    The positive cases prove old sealed artifacts still read. The negative cases
    prove the three things a tree-equality bridge could plausibly have broken:
    an arbitrary commit is still refused, a rewritten boundary is still refused,
    and a superseded identity whose replacement carries a DIFFERENT tree is
    refused rather than waved through on the strength of the contract saying so.

    Negative cases mutate a COPY of the contract in a temporary directory and
    verify against the real repository. Nothing under the repository is written.
#>

[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'src/Agents/reviewer/ReviewerBaseContract.ps1')

$script:Failures = @()
$script:Passes = 0
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)

function Assert-Pass {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passes++
        Write-Host "  PASS  $Name"
    }
    catch {
        $script:Failures += "$Name :: $($_.Exception.Message)"
        Write-Host "  FAIL  $Name :: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Refused {
    <#
    .SYNOPSIS
        The body must throw, and the message must name the reason expected.
    .DESCRIPTION
        Matching the message matters. A refusal for the wrong reason is a test
        that would keep passing after the check it targets was deleted.
    #>
    param([string]$Name, [string]$Because, [scriptblock]$Body)
    try {
        & $Body | Out-Null
        $script:Failures += "$Name :: accepted an input that must be refused"
        Write-Host "  FAIL  $Name :: accepted an input that must be refused" -ForegroundColor Red
        return
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message -notmatch $Because) {
            $script:Failures += "$Name :: refused for the wrong reason: $message"
            Write-Host "  FAIL  $Name :: refused for the wrong reason: $message" -ForegroundColor Red
            return
        }
    }
    $script:Passes++
    Write-Host "  PASS  $Name"
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("reviewer-base-contract-" + [Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

function New-MutatedContract {
    <#
    .SYNOPSIS
        A copy of the committed contract with one mutation, re-sealed unless the
        caller is testing the seal itself.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Mutate,
        [switch]$LeaveDigestStale
    )
    $source = Get-ReviewerBaseContractDefaultPath -RepoRoot $RepoRoot
    $contract = [IO.File]::ReadAllText($source, $script:Utf8) | ConvertFrom-Json -Depth 32
    & $Mutate $contract
    if (-not $LeaveDigestStale) {
        $contract.contractDigest = Get-ReviewerBaseContractDigest -Contract $contract
    }
    $path = Join-Path $sandbox ($Name + '.json')
    [IO.File]::WriteAllText($path, (($contract | ConvertTo-Json -Depth 32).Replace("`r`n", "`n") + "`n"), $script:Utf8)
    return $path
}

try {
    Write-Host 'Reviewer base lineage contract'

    $committedPath = Get-ReviewerBaseContractDefaultPath -RepoRoot $RepoRoot
    $committed = Read-ReviewerBaseContract -Path $committedPath

    Assert-Pass 'the committed contract is exactly what the generator produces' {
        $temporary = Join-Path $sandbox 'regenerated.json'
        & (Join-Path $RepoRoot 'tools/New-ReviewerBaseContract.ps1') -RepoRoot $RepoRoot -OutFile $temporary | Out-Null
        $expected = [IO.File]::ReadAllText($temporary, $script:Utf8).Replace("`r`n", "`n")
        $actual = [IO.File]::ReadAllText($committedPath, $script:Utf8).Replace("`r`n", "`n")
        if ($expected -cne $actual) {
            throw 'the committed contract is stale; run tools/New-ReviewerBaseContract.ps1'
        }
    }

    Assert-Pass 'the contract declares exactly one active lineage' {
        $active = @($committed.lineages | Where-Object { [string]$_.status -ceq 'active' })
        if (@($active).Count -ne 1) { throw "found $(@($active).Count)" }
    }

    $legacy = @($committed.lineages | Where-Object { [string]$_.status -ceq 'superseded' })[0]
    $active = @($committed.lineages | Where-Object { [string]$_.status -ceq 'active' })[0]

    Assert-Pass 'the superseded base identity sealed fixtures name is still accepted' {
        $acceptance = Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit)
        if ([string]$acceptance.mode -cne 'consolidated-equivalent-tree') { throw "mode was $($acceptance.mode)" }
        if ([string]$acceptance.boundaryCommit -cne ([string]$active.baseCommit)) { throw 'wrong boundary' }
        if ([string]$acceptance.contractDigest -cne ([string]$committed.contractDigest)) { throw 'wrong digest' }
    }

    Assert-Pass 'the active base identity is accepted directly' {
        $acceptance = Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$active.baseCommit)
        if ([string]$acceptance.mode -cne 'active-lineage') { throw "mode was $($acceptance.mode)" }
    }

    Assert-Pass 'the equivalence the supersession rests on is a real tree equality in git' {
        $legacyTree = Get-ReviewerBaseContractTree -RepoRoot $RepoRoot -Commit ([string]$legacy.baseCommit)
        $activeTree = Get-ReviewerBaseContractTree -RepoRoot $RepoRoot -Commit ([string]$active.baseCommit)
        if ($legacyTree.Length -eq 0 -or $activeTree.Length -eq 0) { throw 'a boundary object is missing' }
        if ($legacyTree -cne $activeTree) { throw "$legacyTree vs $activeTree" }
    }

    Assert-Pass 'the superseded identity is genuinely NOT an ancestor, so ancestry alone would have refused it' {
        $priorPreference = $PSNativeCommandUseErrorActionPreference
        try {
            $PSNativeCommandUseErrorActionPreference = $false
            & git -C $RepoRoot merge-base --is-ancestor ([string]$legacy.baseCommit) HEAD 2>$null
            if ([int]$LASTEXITCODE -eq 0) {
                throw 'the superseded commit is an ancestor, so this suite is not testing what it claims to test'
            }
        }
        finally { $PSNativeCommandUseErrorActionPreference = $priorPreference }
    }

    Assert-Refused 'an arbitrary commit is refused even though it is a real ancestor' 'not an accepted base identity' {
        $priorPreference = $PSNativeCommandUseErrorActionPreference
        $ancestor = ''
        try {
            $PSNativeCommandUseErrorActionPreference = $false
            $ancestor = ([string](& git -C $RepoRoot rev-parse 'HEAD~1')).Trim()
        }
        finally { $PSNativeCommandUseErrorActionPreference = $priorPreference }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit $ancestor
    }

    Assert-Refused 'a commit-shaped string that is not 40 hex is refused' 'not a full 40-character object name' {
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit 'ccbf146'
    }

    Assert-Refused 'an edited contract whose digest was not recomputed is refused' 'does not match its own digest' {
        $path = New-MutatedContract -Name 'stale-digest' -LeaveDigestStale -Mutate {
            param($c) $c.description = 'tampered'
        }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) -ContractPath $path
    }

    Assert-Refused 'a bound artifact that no longer hashes to its recorded digest is refused' 'hashes to' {
        $path = New-MutatedContract -Name 'artifact-drift' -Mutate {
            param($c) $c.boundArtifacts[0].sha256 = ('0' * 64)
        }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) -ContractPath $path
    }

    Assert-Refused 'a bound artifact that does not exist is refused' 'does not exist under' {
        $path = New-MutatedContract -Name 'artifact-missing' -Mutate {
            param($c) $c.boundArtifacts[0].path = 'src/Agents/reviewer/does-not-exist.ps1'
        }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) -ContractPath $path
    }

    Assert-Refused 'a contract that binds nothing is refused' 'binds no artifact' {
        $path = New-MutatedContract -Name 'artifact-empty' -Mutate {
            param($c) $c.boundArtifacts = @()
        }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) -ContractPath $path
    }

    Assert-Refused 'a recorded tree that disagrees with the named commit is refused' 'identity and the content disagree' {
        $path = New-MutatedContract -Name 'wrong-legacy-tree' -Mutate {
            param($c)
            foreach ($lineage in $c.lineages) { $lineage.baseTree = ('a' * 40) }
        }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) -ContractPath $path
    }

    Assert-Refused 'a supersession whose replacement tree differs is refused' 'carrying the identical tree' {
        # The replacement points at a real, ancestral commit with a real,
        # correctly recorded tree - it is simply a DIFFERENT tree. This is the
        # case a bridge built on "the contract says they are equivalent" would
        # have let through.
        $path = New-MutatedContract -Name 'unequal-supersession' -Mutate {
            param($c)
            $other = ([string](& git -C $RepoRoot rev-parse 'HEAD^{tree}')).Trim().ToLowerInvariant()
            $head = ([string](& git -C $RepoRoot rev-parse 'HEAD')).Trim().ToLowerInvariant()
            foreach ($lineage in $c.lineages) {
                if ([string]$lineage.status -ceq 'active') {
                    $lineage.baseCommit = $head
                    $lineage.baseTree = $other
                }
            }
        }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) -ContractPath $path
    }

    Assert-Refused 'an active boundary whose tree was rewritten is refused' 'boundary has been rewritten' {
        # Both lineages keep the same (equal) recorded tree so the supersession
        # check passes, but the recorded tree no longer matches what git says the
        # boundary contains.
        $path = New-MutatedContract -Name 'rewritten-boundary' -Mutate {
            param($c)
            $head = ([string](& git -C $RepoRoot rev-parse 'HEAD')).Trim().ToLowerInvariant()
            foreach ($lineage in $c.lineages) {
                if ([string]$lineage.status -ceq 'active') { $lineage.baseCommit = $head }
            }
        }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) -ContractPath $path
    }

    Assert-Refused 'an active boundary absent from the checkout is refused' 'not present in' {
        $path = New-MutatedContract -Name 'absent-boundary' -Mutate {
            param($c)
            foreach ($lineage in $c.lineages) {
                if ([string]$lineage.status -ceq 'active') { $lineage.baseCommit = ('b' * 40) }
            }
        }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) -ContractPath $path
    }

    Assert-Refused 'a boundary that is not carried by the revision under test is refused' 'is not an ancestor of' {
        # The contract is untouched and entirely valid. The checkout is the
        # problem: this revision predates the boundary, so it does not carry the
        # reviewer state the fixture names. Expected-base safety is unchanged by
        # the migration.
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) `
            -HeadRef '8d66afc8b31b0878152de846ebf0ad8644c996e1'
    }

    Assert-Refused 'a contract with two active lineages is refused' 'active lineage' {
        $path = New-MutatedContract -Name 'two-active' -Mutate {
            param($c)
            foreach ($lineage in $c.lineages) {
                $lineage.status = 'active'
                $lineage.supersededByLineageVersion = 0
            }
        }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) -ContractPath $path
    }

    Assert-Refused 'a contract naming one base identity twice is refused' 'in more than one lineage' {
        $path = New-MutatedContract -Name 'duplicate-identity' -Mutate {
            param($c)
            $c.lineages[0].baseCommit = $c.lineages[1].baseCommit
        }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) -ContractPath $path
    }

    Assert-Refused 'a superseded lineage pointing at a lineage that does not exist is refused' 'does not define exactly once' {
        $path = New-MutatedContract -Name 'dangling-supersession' -Mutate {
            param($c)
            foreach ($lineage in $c.lineages) {
                if ([string]$lineage.status -ceq 'superseded') { $lineage.supersededByLineageVersion = 99 }
            }
        }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) -ContractPath $path
    }

    Assert-Refused 'a contract carrying an unexpected top-level field is refused' 'unexpected top-level shape' {
        $path = New-MutatedContract -Name 'extra-field' -Mutate {
            param($c) $c | Add-Member -NotePropertyName 'allowAnyCommit' -NotePropertyValue $true
        }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) -ContractPath $path
    }

    Assert-Refused 'a contract declaring a schema version this build cannot verify is refused' 'does not verify' {
        $path = New-MutatedContract -Name 'future-schema' -Mutate {
            param($c) $c.schemaVersion = 2
        }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) -ContractPath $path
    }

    Assert-Refused 'a missing contract is refused rather than treated as no constraint' 'does not exist' {
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$legacy.baseCommit) `
            -ContractPath (Join-Path $sandbox 'absent.json')
    }

    Assert-Pass 'the sealed exact-path fixture still names the pre-consolidation identity' {
        # The proof that old artifacts read unchanged: nothing rewrote them.
        $manifest = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/Agents/reviewer/testdata/exact-path/adapter-manifest.json') -Raw |
            ConvertFrom-Json -Depth 16
        if ([string]$manifest.expectedBaseCommit -cne ([string]$legacy.baseCommit)) {
            throw "the fixture names $([string]$manifest.expectedBaseCommit)"
        }
        Assert-ReviewerBaseCommitAccepted -RepoRoot $RepoRoot -ExpectedBaseCommit ([string]$manifest.expectedBaseCommit) | Out-Null
    }
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if (@($script:Failures).Count -gt 0) {
    Write-Host "FAILED: $(@($script:Failures).Count) check(s), $($script:Passes) passed." -ForegroundColor Red
    exit 1
}
Write-Host "All $($script:Passes) reviewer base lineage contract checks passed."
exit 0
