#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Contract checks for the offline snapshot replay mode and for the convention
    specialist's rule-coverage accounting.

.DESCRIPTION
    Offline and deterministic: no network, no repository host, no model. Every
    check is a pure function of the committed synthetic fixture or of fixtures
    this script builds in a temporary directory it owns.

.EXAMPLE
    ./tools/Test-ReplaySnapshot.ps1
#>
[CmdletBinding()]
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Import-Module (Join-Path $RepoRoot "src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1") -Force
. (Join-Path $RepoRoot "src\Agents\reviewer\ConventionSpecialist.ps1")

$script:Checks = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Assert-Replay {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:Checks++
    if (-not $Condition) { [void]$script:Failures.Add($Message); Write-Host "  FAIL - $Message" -ForegroundColor Red }
}

function Assert-ReplayThrows {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message, [string]$Match)
    $script:Checks++
    try {
        & $Action | Out-Null
        [void]$script:Failures.Add($Message)
        Write-Host "  FAIL - $Message" -ForegroundColor Red
    }
    catch {
        if ($Match -and [string]$_.Exception.Message -notmatch $Match) {
            [void]$script:Failures.Add("$Message (threw, but not for the stated reason: $($_.Exception.Message))")
            Write-Host "  FAIL - $Message (wrong reason: $($_.Exception.Message))" -ForegroundColor Red
        }
    }
}

$fixtureRoot = Join-Path $RepoRoot "src\Agents\reviewer\testdata\replay-v1"
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("devpilot-replay-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

function Copy-Fixture {
    <# Each case gets its own replay ROOT with the snapshot still named
       synthetic-pr inside it, because a snapshot declares its own id and
       refuses to load under a different one. #>
    param([Parameter(Mandatory)][string]$Name)
    $root = Join-Path $sandbox $Name
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Copy-Item -Recurse -Force (Join-Path $fixtureRoot "synthetic-pr") (Join-Path $root "synthetic-pr")
    return $root
}

try {
    # -- 1. The shipped fixture loads, and every payload is hash-bound ---------
    Write-Host "1/10 shipped synthetic snapshot" -ForegroundColor Cyan
    $snapshot = New-AgentReplaySnapshot -ReplayRoot $fixtureRoot -SnapshotName "synthetic-pr"
    Assert-Replay ($snapshot.SnapshotId -ceq "synthetic-pr") "The shipped fixture did not load under its own name."
    Assert-Replay ($snapshot.ResourceCount -eq 7) "The shipped fixture should carry exactly 7 recorded reads."
    Assert-Replay ($snapshot.ManifestDigest -match '^[0-9a-f]{64}$') "The shipped fixture produced no manifest digest."
    Assert-Replay ($snapshot.ReplayNonce -match '^[0-9a-f]{36}$') "A loaded snapshot must mint a replay nonce."
    Assert-Replay ($snapshot.Binding.PullRequestId -eq 4242) "The shipped fixture is bound to the wrong pull request."

    $second = New-AgentReplaySnapshot -ReplayRoot $fixtureRoot -SnapshotName "synthetic-pr"
    Assert-Replay ($second.ManifestDigest -ceq $snapshot.ManifestDigest) "Two loads of one snapshot disagreed on its digest."
    Assert-Replay ($second.ReplayNonce -cne $snapshot.ReplayNonce) "Two loads of one snapshot reused a replay nonce."

    Assert-ReplayThrows { New-AgentReplaySnapshot -ReplayRoot $fixtureRoot -SnapshotName "synthetic-pr" -ExpectedManifestDigest ("0" * 64) } `
        "An operator-supplied digest that does not match must refuse the snapshot." -Match "does not match the operator-supplied"

    # -- 2. Serving preserves the live tool response shapes -------------------
    Write-Host "2/10 served responses keep the live shapes" -ForegroundColor Cyan
    $session = Open-AgentMcpSession -AgencyPath "never-executed" -Server "ado" -Organization "contoso" -ReplaySnapshot $snapshot
    Assert-Replay ($null -eq $session.Process) "A replay session must not start a process."
    $pr = Invoke-AgentMcpTool -Session $session -Name "repo_pull_request" -Arguments @{
        action = "get"; project = "Widgets"; repositoryId = "11111111-2222-3333-4444-555555555555"; pullRequestId = 4242
    }
    Assert-Replay ([int]$pr.pullRequestId -eq 4242) "A replayed PR read did not return the recorded pull request."
    Assert-Replay ([string]$pr.lastMergeSourceCommit.commitId -ceq "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0") "A replayed PR read lost its commit binding."

    $resource = Send-AgentMcpRequest -Session $session -Method "tools/call" -Params @{
        name = "repo_file"
        arguments = @{
            action = "get_content"; project = "Widgets"; repositoryId = "11111111-2222-3333-4444-555555555555"
            path = "/src/Widget.cs"; versionType = "Commit"; version = "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0"
        }
    }
    # The live resource decoder must accept a replayed resource unchanged: same
    # envelope, same base64 canonicity, same MIME allow-list, same UTF-8 rules.
    $decoded = ConvertFrom-AgentMcpResourceContent -ToolResult $resource -ExpectedUri "/src/Widget.cs" -MaxBytes 65536
    Assert-Replay ($decoded.Text.Contains("WidgetBuilder")) "The live resource decoder did not accept a replayed resource."
    Assert-Replay ($decoded.Sha256 -match '^[0-9a-f]{64}$') "A replayed resource produced no content hash."

    $again = Invoke-AgentMcpTool -Session $session -Name "repo_pull_request" -Arguments @{
        action = "get"; project = "Widgets"; repositoryId = "11111111-2222-3333-4444-555555555555"; pullRequestId = 4242
    }
    Assert-Replay ([int]$again.pullRequestId -eq 4242 -and -not [object]::ReferenceEquals($again, $pr)) `
        "Two serves of one recorded read must be equal in value and separate objects."

    # -- 3. Absent, write, and closed all fail closed -------------------------
    Write-Host "3/10 absent reads, writes, and closed sessions fail closed" -ForegroundColor Cyan
    Assert-ReplayThrows { Invoke-AgentMcpTool -Session $session -Name "repo_pull_request" -Arguments @{
            action = "get"; project = "Widgets"; repositoryId = "11111111-2222-3333-4444-555555555555"; pullRequestId = 9999
        } } "A read the snapshot does not carry must fail, never fall through to a live read." -Match "no recorded response"
    Assert-ReplayThrows { Invoke-AgentMcpTool -Session $session -Name "repo_pull_request_thread" -RawText -Arguments @{
            action = "create"; project = "Widgets"; repositoryId = "11111111-2222-3333-4444-555555555555"; pullRequestId = 4242; content = "x"
        } } "A thread create must be refused by the replay read ceiling." -Match "outside the replay read ceiling"
    Assert-ReplayThrows { Invoke-AgentMcpTool -Session $session -Name "repo_pull_request_write" -RawText -Arguments @{
            action = "get"; project = "Widgets"; pullRequestId = 4242
        } } "A write tool must be refused by the replay read ceiling." -Match "not in the replay read ceiling"
    Assert-ReplayThrows { Invoke-AgentMcpTool -Session $session -Name "repo_file" -Arguments @{
            project = "Widgets"; path = "/src/Widget.cs"
        } } "A call with no action must be refused rather than defaulted to a read." -Match "without an action"
    Assert-ReplayThrows { Send-AgentMcpRequest -Session $session -Method "initialize" -Params @{} } `
        "A replay session must refuse any method other than tools/call." -Match "refuses JSON-RPC method"
    Assert-ReplayThrows { Send-AgentMcpNotification -Session $session -Method "notifications/initialized" } `
        "A replay session must refuse notifications." -Match "refuses JSON-RPC notification"

    Close-AgentMcpSession -Session $session
    Assert-ReplayThrows { Invoke-AgentMcpTool -Session $session -Name "repo_pull_request" -Arguments @{
            action = "get"; project = "Widgets"; repositoryId = "11111111-2222-3333-4444-555555555555"; pullRequestId = 4242
        } } "A closed replay session must refuse to serve." -Match "session is closed"

    Assert-ReplayThrows { Open-AgentMcpSession -AgencyPath "x" -Server "ado" -Organization "contoso" `
            -ReplaySnapshot @{ Seal = "agent-replay-v1"; Binding = @{ Organization = "contoso" }; Served = @{} } } `
        "A hand-built snapshot object must not be accepted as a loaded one." -Match "produced by New-AgentReplaySnapshot"
    Assert-ReplayThrows { Open-AgentMcpSession -AgencyPath "x" -Server "ado" -Organization "other-org" -ReplaySnapshot $snapshot } `
        "A snapshot captured for one organization must not serve another." -Match "was captured against organization"

    # -- 4. Tampering, stale bindings, and missing payloads -------------------
    Write-Host "4/10 tamper, stale binding, and missing resource" -ForegroundColor Cyan
    $tampered = Copy-Fixture -Name "tampered"
    $payload = Join-Path $tampered "synthetic-pr\payloads\pr-get.json"
    [IO.File]::WriteAllBytes($payload, $utf8.GetBytes(([IO.File]::ReadAllText($payload, $utf8)).Replace("4242", "4243")))
    Assert-ReplayThrows { New-AgentReplaySnapshot -ReplayRoot $tampered -SnapshotName "synthetic-pr" } `
        "An edited payload must fail its recorded hash." -Match "does not match its recorded SHA-256|is \d+ bytes"

    $rebound = Copy-Fixture -Name "rebound"
    $manifestPath = Join-Path $rebound "synthetic-pr\manifest.json"
    $manifest = [IO.File]::ReadAllText($manifestPath, $utf8) | ConvertFrom-Json
    $manifest.binding.pullRequestId = 9999
    [IO.File]::WriteAllBytes($manifestPath, $utf8.GetBytes(($manifest | ConvertTo-Json -Depth 20)))
    Assert-ReplayThrows { New-AgentReplaySnapshot -ReplayRoot $rebound -SnapshotName "synthetic-pr" } `
        "A binding edited after capture must break the manifest digest." -Match "manifest and its payloads disagree"

    $missing = Copy-Fixture -Name "missing"
    Remove-Item (Join-Path $missing "synthetic-pr\payloads\branch-main.json") -Force
    Assert-ReplayThrows { New-AgentReplaySnapshot -ReplayRoot $missing -SnapshotName "synthetic-pr" } `
        "A payload named by the manifest but absent on disk must refuse the snapshot." -Match "Cannot find|does not exist|could not be found"

    $renamed = Copy-Fixture -Name "renamed"
    Rename-Item (Join-Path $renamed "synthetic-pr") "other-pr"
    Assert-ReplayThrows { New-AgentReplaySnapshot -ReplayRoot $renamed -SnapshotName "other-pr" } `
        "A snapshot loaded under a different name than it declares must be refused." -Match "declares snapshotId"

    # -- 5. Path attacks ------------------------------------------------------
    Write-Host "5/10 path attacks" -ForegroundColor Cyan
    foreach ($name in @("..", "..\other", "a/b", "C:\windows", "with:stream", "")) {
        Assert-ReplayThrows { New-AgentReplaySnapshot -ReplayRoot $fixtureRoot -SnapshotName $name } `
            "Snapshot name '$name' must be refused as a path-free single name."
    }
    $escaped = Copy-Fixture -Name "escaped"
    $escapedManifestPath = Join-Path $escaped "synthetic-pr\manifest.json"
    $escapedManifest = [IO.File]::ReadAllText($escapedManifestPath, $utf8) | ConvertFrom-Json
    $escapedManifest.resources[0].payloadFile = "../synthetic-pr/payloads/pr-get.json"
    [IO.File]::WriteAllBytes($escapedManifestPath, $utf8.GetBytes(($escapedManifest | ConvertTo-Json -Depth 20)))
    Assert-ReplayThrows { New-AgentReplaySnapshot -ReplayRoot $escaped -SnapshotName "synthetic-pr" } `
        "A payload path that leaves the snapshot directory must be refused." -Match "not a plain relative path"

    # A junction is the interesting Windows case: the manifest string stays
    # inside the snapshot while the bytes come from anywhere on the volume.
    $junctionRoot = Copy-Fixture -Name "junction"
    $outside = Join-Path $sandbox "outside"
    New-Item -ItemType Directory -Force -Path $outside | Out-Null
    Copy-Item (Join-Path $fixtureRoot "synthetic-pr\payloads\pr-get.json") (Join-Path $outside "pr-get.json") -Force
    $junctionMade = $false
    try {
        Remove-Item -Recurse -Force (Join-Path $junctionRoot "synthetic-pr\payloads") -ErrorAction SilentlyContinue
        New-Item -ItemType Junction -Path (Join-Path $junctionRoot "synthetic-pr\payloads") -Target $outside -ErrorAction Stop | Out-Null
        $junctionMade = $true
    }
    catch { Write-Host "  (skipped: this host would not create a junction)" -ForegroundColor DarkGray }
    if ($junctionMade) {
        Assert-ReplayThrows { New-AgentReplaySnapshot -ReplayRoot $junctionRoot -SnapshotName "synthetic-pr" } `
            "A reparse point inside a snapshot must be refused." -Match "reparse point|is a Junction"
    }

    # -- 6. Recorded writes cannot be sealed into a snapshot at all -----------
    Write-Host "6/10 a snapshot may only carry reads" -ForegroundColor Cyan
    $writeAttempt = Join-Path $sandbox "write-attempt"
    New-Item -ItemType Directory -Force -Path (Join-Path $writeAttempt "payloads") | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $writeAttempt "payloads\w.json"),
        $utf8.GetBytes('{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{}"}]}}'))
    $writeRecipe = @(@{
            tool = "repo_pull_request_thread"
            arguments = [ordered]@{ action = "create"; project = "Widgets"; pullRequestId = 4242; content = "x" }
            payloadFile = "payloads/w.json"
        })
    [IO.File]::WriteAllBytes((Join-Path $writeAttempt "recipe.json"), $utf8.GetBytes(($writeRecipe | ConvertTo-Json -Depth 10)))
    Assert-ReplayThrows {
        & (Join-Path $RepoRoot "tools\Save-AgentReplaySnapshot.ps1") -SnapshotPath $writeAttempt `
            -Recipe (Join-Path $writeAttempt "recipe.json") -Organization "contoso" -Project "Widgets" `
            -RepositoryId "11111111-2222-3333-4444-555555555555" -PullRequestId 4242 `
            -SourceCommit ("a" * 40) -TargetCommit ("b" * 40)
    } "The snapshot writer must refuse to seal a recorded write." -Match "may only carry reads"

    # Green path: the writer and the loader must agree on the digest for a
    # snapshot the writer produces from scratch. Only exercising the refusal
    # path would leave a writer/loader disagreement invisible until an operator
    # hit it with a real snapshot.
    $sealRoot = Join-Path $sandbox "sealed"
    $sealDir = Join-Path $sealRoot "round-trip"
    New-Item -ItemType Directory -Force -Path (Join-Path $sealDir "payloads") | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $sealDir "payloads\pr.json"),
        $utf8.GetBytes('{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"pullRequestId\":9}"}]}}'))
    $sealRecipe = @(@{
            tool = "repo_pull_request"
            arguments = [ordered]@{ action = "get"; project = "Widgets"; repositoryId = "11111111-2222-3333-4444-555555555555"; pullRequestId = 9 }
            payloadFile = "payloads/pr.json"
        })
    [IO.File]::WriteAllBytes((Join-Path $sealDir "recipe.json"), $utf8.GetBytes(($sealRecipe | ConvertTo-Json -Depth 10)))
    $sealOutput = & (Join-Path $RepoRoot "tools\Save-AgentReplaySnapshot.ps1") -SnapshotPath $sealDir `
        -Recipe (Join-Path $sealDir "recipe.json") -Organization "contoso" -Project "Widgets" `
        -RepositoryId "11111111-2222-3333-4444-555555555555" -PullRequestId 9 `
        -SourceCommit ("a" * 40) -TargetCommit ("b" * 40) -Models @("claude-opus-5") *>&1 | Out-String
    Assert-Replay ($sealOutput -match "Sealed replay snapshot") "The writer must report the snapshot it sealed."
    $sealedDigest = ([IO.File]::ReadAllText((Join-Path $sealDir "manifest.json"), $utf8) | ConvertFrom-Json).manifestDigest
    $reloaded = New-AgentReplaySnapshot -ReplayRoot $sealRoot -SnapshotName "round-trip" -ExpectedManifestDigest $sealedDigest
    Assert-Replay ($reloaded.ManifestDigest -ceq $sealedDigest -and $reloaded.ResourceCount -eq 1) `
        "The loader must recompute exactly the digest the writer recorded."

    # -- 7. Canonical form and lookup keys are host-independent ---------------
    Write-Host "7/10 canonical form is ordinal and host-independent" -ForegroundColor Cyan
    $mixed = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($pair in @(@("ab", 1), @("Aa", 2), @("aa", 3), @("ch", 4), @("cz", 5), @("_x", 6))) {
        $mixed[[string]$pair[0]] = [int]$pair[1]
    }
    $canonical = ConvertTo-AgentReplayCanonicalJson -Value $mixed
    Assert-Replay ($canonical -ceq '{"Aa":2,"_x":6,"aa":3,"ab":1,"ch":4,"cz":5}') `
        "Canonical key ordering must be ordinal, not culture-dependent (got $canonical)."
    $keyA = Get-AgentReplayRequestKey -Name "repo_file" -Arguments @{ action = "get_content"; path = "/a.cs"; project = "P" }
    $keyB = Get-AgentReplayRequestKey -Name "repo_file" -Arguments ([ordered]@{ project = "P"; path = "/a.cs"; action = "get_content" })
    Assert-Replay ($keyA.Key -ceq $keyB.Key) "Argument order must not change a lookup key."
    $keyC = Get-AgentReplayRequestKey -Name "repo_file" -Arguments @{ action = "get_content"; path = "/b.cs"; project = "P" }
    Assert-Replay ($keyA.Key -cne $keyC.Key) "A different argument must be a different resource."
    Assert-ReplayThrows { ConvertTo-AgentReplayCanonicalJson -Value @{ when = [DateTime]::UtcNow } } `
        "A date value must be refused rather than rendered ambiguously." -Match "does not accept date values"
    Assert-ReplayThrows { ConvertTo-AgentReplayCanonicalJson -Value @{ ratio = 1.5 } } `
        "A non-integral number must be refused." -Match "non-integral"
    $escapes = ConvertTo-AgentReplayCanonicalJson -Value @{ t = "a`"b\c`nd" }
    Assert-Replay ($escapes -ceq '{"t":"a\"b\\c\nd"}') "String escaping must be explicit and stable (got $escapes)."

    # -- 8. Rule-coverage accounting ------------------------------------------
    Write-Host "8/10 rule-coverage accounting" -ForegroundColor Cyan
    $sources = @(
        [pscustomobject][ordered]@{ PackName = "core"; SourceId = "rule-a"; Sha256 = ("a" * 64); Text = "Prefer assigning a field once." }
        [pscustomobject][ordered]@{ PackName = "core"; SourceId = "rule-b"; Sha256 = ("b" * 64); Text = "Name every argument of a multi-line call." }
    )
    $anchors = @(
        [pscustomobject][ordered]@{ anchorId = "cf0"; path = "src/a.cs" }
        [pscustomobject][ordered]@{ anchorId = "cf1"; path = "src/b.cs" }
    )
    $accepted = @([pscustomobject][ordered]@{ candidateId = "reassigns-field"; packName = "core"; ruleSourceId = "rule-a" })
    # rule-a sorts to rs0 and rule-b to rs1 under the request's ordinal order.
    function New-CoverageRow {
        param([string]$Ref, [string]$Sha, [string]$Status, [string]$Anchors = "cf0:12", [string]$Candidate = "", [string]$Quote = "")
        return [pscustomobject][ordered]@{
            ruleRef = $Ref; ruleSourceSha256 = $Sha; ruleQuote = $Quote
            status = $Status; changedAnchors = $Anchors; codeEvidence = "evidence"
            siblingStatus = "checked"; siblingEvidence = "sibling"; candidateId = $Candidate; notes = "note"
        }
    }

    $complete = Resolve-ReviewerConventionSpecialistRuleCoverage -ResolvedSources $sources -ChangedFileIndex $anchors `
        -AcceptedCandidates $accepted -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Candidate "reassigns-field"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([bool]$complete.Complete) "Accounting that covers every transported source exactly once must be complete."
    Assert-Replay (@($complete.UnemittedViolations).Count -eq 0) "A violation linked to an accepted candidate is not an unemitted one."

    $short = Resolve-ReviewerConventionSpecialistRuleCoverage -ResolvedSources $sources -ChangedFileIndex $anchors `
        -AcceptedCandidates @() -Rows @((New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant"))
    Assert-Replay (-not [bool]$short.Complete -and @($short.Missing) -ccontains "core/rule-b") `
        "A transported source with no row must be reported missing, not silently dropped."

    $dupe = Resolve-ReviewerConventionSpecialistRuleCoverage -ResolvedSources $sources -ChangedFileIndex $anchors `
        -AcceptedCandidates @() -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant"),
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "notApplicable"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay (-not [bool]$dupe.Complete -and @($dupe.Duplicates) -ccontains "rs0") `
        "A source accounted for twice must be reported as a duplicate."

    $bogus = Resolve-ReviewerConventionSpecialistRuleCoverage -ResolvedSources $sources -ChangedFileIndex $anchors `
        -AcceptedCandidates @() -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant"),
        (New-CoverageRow -Ref "rs9" -Sha ("c" * 64) -Status "violation")
    )
    Assert-Replay (-not [bool]$bogus.Complete -and @($bogus.Unknown) -ccontains "rs9") `
        "A row naming a source that was never transported must be reported, not counted."
    Assert-Replay (@($bogus.UnemittedViolations).Count -eq 0) `
        "A violation on a source that was never transported must not become a withheld finding."

    $badAnchor = Resolve-ReviewerConventionSpecialistRuleCoverage -ResolvedSources $sources -ChangedFileIndex $anchors `
        -AcceptedCandidates @() -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Anchors "cf9:4"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($badAnchor.Rows)[0].status -ceq "unknown") `
        "A row anchored outside the delivered change set must degrade to unknown."

    $badHash = Resolve-ReviewerConventionSpecialistRuleCoverage -ResolvedSources $sources -ChangedFileIndex $anchors `
        -AcceptedCandidates @() -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("f" * 64) -Status "compliant"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($badHash.Rows)[0].status -ceq "unknown") `
        "A row citing a rule-source hash that was not transported must degrade to unknown."

    $badQuote = Resolve-ReviewerConventionSpecialistRuleCoverage -ResolvedSources $sources -ChangedFileIndex $anchors `
        -AcceptedCandidates @() -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Quote "text that is not in the source"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($badQuote.Rows)[0].status -ceq "unknown") `
        "A row quoting text absent from the transported source must degrade to unknown."

    $ghost = Resolve-ReviewerConventionSpecialistRuleCoverage -ResolvedSources $sources -ChangedFileIndex $anchors `
        -AcceptedCandidates @() -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Candidate "never-emitted"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay (@($ghost.UnemittedViolations).Count -eq 1) `
        "A claimed violation with no emitted candidate must be recorded as unemitted."
    Assert-Replay ([string]@($ghost.Rows)[0].candidateId -ceq "") `
        "A link to a candidate that does not exist must not be recorded as a link."

    $alreadyWithheld = Resolve-ReviewerConventionSpecialistRuleCoverage -ResolvedSources $sources -ChangedFileIndex $anchors `
        -AcceptedCandidates @() -WithheldCandidateIds @("reassigns-field") -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Candidate "reassigns-field"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay (@($alreadyWithheld.UnemittedViolations).Count -eq 0) `
        "A violation whose candidate the wrapper already withheld must not be counted a second time."

    $unaccounted = Resolve-ReviewerConventionSpecialistRuleCoverage -ResolvedSources $sources -ChangedFileIndex $anchors `
        -AcceptedCandidates @([pscustomobject][ordered]@{ candidateId = "x"; packName = "core"; ruleSourceId = "rule-b" }) `
        -Rows @((New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant"))
    Assert-Replay (-not [bool]$unaccounted.Complete -and @($unaccounted.UnaccountedCandidates) -ccontains "x") `
        "A candidate whose rule has no accounting row must be reported."

    $index = Get-ReviewerConventionSpecialistChangedFileIndex -ChangeEntries @(
        [pscustomobject][ordered]@{ Path = "src/z.cs"; Role = "current" },
        [pscustomobject][ordered]@{ Path = "src/a.cs"; Role = "current" },
        [pscustomobject][ordered]@{ Path = "src/gone.cs"; Role = "original" }
    )
    Assert-Replay (@($index).Count -eq 2 -and [string]@($index)[0].path -ceq "src/a.cs" -and [string]@($index)[0].anchorId -ceq "cf0") `
        "The changed-file anchor index must be ordinal, deduplicated, and current-role only."

    # -- 9. Schema bounds ------------------------------------------------------
    Write-Host "9/10 schema bounds" -ForegroundColor Cyan
    $schema = Get-ReviewerConventionSpecialistMarkerSchema -ExpectedProject "Widgets" -ExpectedNonce "n"
    Assert-Replay ($schema.Keys -ccontains "ruleCoverage") "The marker schema must declare ruleCoverage."
    $coverageSpec = $schema.Fields["ruleCoverage"]
    Assert-Replay ([int]$coverageSpec.MaxItems -eq 17) "The rule-coverage array must be bounded at 17 rows."
    $rowFields = $coverageSpec.Item.Fields
    # Every field of a row must be individually bounded, and the whole section
    # must stay well inside the marker scan window - an unbounded accounting
    # section would not produce a longer report, it would produce none at all.
    $perRow = 0
    foreach ($fieldName in $coverageSpec.Item.Keys) {
        $spec = $rowFields[$fieldName]
        Assert-Replay ($null -ne $spec) "Rule-coverage field '$fieldName' has no declared type."
        $bound = switch ([string]$spec.Type) {
            "hex" { [int]$spec.Length }
            "enum" { 32 }
            default { [int]$spec.MaxLength }
        }
        Assert-Replay ($bound -gt 0) "Rule-coverage field '$fieldName' is not length-bounded."
        $perRow += $bound + $fieldName.Length + 8
    }
    Assert-Replay (($perRow * [int]$coverageSpec.MaxItems) -lt 32768) `
        "The rule-coverage section's worst case ($($perRow * [int]$coverageSpec.MaxItems) chars) must stay under half the marker scan window, which it shares with the candidate array."
    # A transported set larger than the row cap must be REPORTED, not sampled.
    $wide = @(0..($coverageSpec.MaxItems + 3) | ForEach-Object {
            [pscustomobject][ordered]@{ PackName = "core"; SourceId = ("rule-{0:d3}" -f $_); Sha256 = ("c" * 64); Text = "text" }
        })
    $wideRequest = Get-ReviewerConventionSpecialistRuleRequest -ResolvedSources $wide
    Assert-Replay (@($wideRequest.Requested).Count -eq [int]$coverageSpec.MaxItems -and @($wideRequest.Unrequested).Count -eq 4) `
        "A transported set larger than the row cap must be capped in the request and the remainder named."
    $wideCoverage = Resolve-ReviewerConventionSpecialistRuleCoverage -ResolvedSources $wide -ChangedFileIndex $anchors `
        -AcceptedCandidates @() -Rows @(@($wideRequest.Requested) | ForEach-Object {
            [pscustomobject][ordered]@{
                ruleRef = [string]$_.ruleRef; ruleSourceSha256 = ("c" * 64); ruleQuote = ""
                status = "compliant"; changedAnchors = ""; codeEvidence = ""
                siblingStatus = "notRequired"; siblingEvidence = ""; candidateId = ""; notes = ""
            }
        })
    Assert-Replay (-not [bool]$wideCoverage.Complete -and @($wideCoverage.Missing).Count -eq 4) `
        "Sources beyond the row cap must be reported unaccounted, never silently dropped."
    Assert-Replay ($script:ReviewerConventionSpecialistWithheldReasons -ccontains "accountedNotEmitted") `
        "The withheld reason set must include the wrapper's unemitted-violation reason."
    Assert-Replay ($coverageSpec.Item.Fields["status"].Values.Count -eq 4) `
        "A coverage row's status must be one of exactly four values."

    # -- 10. The replay tool grant --------------------------------------------
    # Extracted from the reviewer's own source and evaluated here, because the
    # claim "the model has no usable tool in replay" is otherwise a comment.
    Write-Host "10/10 replay tool grant" -ForegroundColor Cyan
    $reviewerSource = [IO.File]::ReadAllText((Join-Path $RepoRoot "src\Agents\reviewer\Start-ReviewerAgent.ps1"), $utf8)
    $reviewerTokens = $null
    $reviewerErrors = $null
    $reviewerAst = [Management.Automation.Language.Parser]::ParseInput($reviewerSource, [ref]$reviewerTokens, [ref]$reviewerErrors)
    foreach ($fn in @("Get-ReviewerLaunchAllowTools", "Get-ReviewerEffectiveDenyTools")) {
        $node = $reviewerAst.FindAll({
                param($candidate)
                $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -ceq $fn
            }, $true) | Select-Object -First 1
        Assert-Replay ($null -ne $node) "The reviewer must define $fn."
        if ($node) { . ([scriptblock]::Create($node.Extent.Text)) }
    }
    $script:ReviewerAllowToolCeiling = @("read", "ado(repo_pull_request)", "ado(repo_file)", "bluebird")
    $script:ReviewerMandatoryDenyTools = @("edit", "create")
    $passCeilings = @(
        @{ Name = "generalist"; Tools = @("read", "ado(repo_pull_request)", "ado(repo_file)") },
        @{ Name = "specialist"; Tools = @("ado(repo_pull_request)", "ado(repo_file)") },
        @{ Name = "verifier"; Tools = @("ado(repo_pull_request)", "ado(repo_file)") }
    )
    foreach ($mode in @($false, $true)) {
        $script:ReviewerReplayActive = $mode
        # Assign first, then wrap: these functions return `, @(...)` so that a
        # single-element list stays a list, and @(f x) in expression position
        # would keep that outer wrapper instead of unrolling it.
        $denyResult = Get-ReviewerEffectiveDenyTools -ConfigDeny @()
        $deny = @($denyResult)
        foreach ($pass in $passCeilings) {
            $allowResult = Get-ReviewerLaunchAllowTools -Intended ([string[]]$pass.Tools)
            $allow = @($allowResult)
            Assert-Replay (@($allow).Count -gt 0) `
                "The $($pass.Name) grant must never be empty (an empty grant restores CLI default discovery)."
            $widened = @($allow | Where-Object { $pass.Tools -cnotcontains $_ })
            Assert-Replay ($widened.Count -eq 0) `
                "The $($pass.Name) grant must never exceed its own ceiling, in replay or not (got: $($widened -join ', '))."
            if ($mode) {
                $survivors = @($allow | Where-Object { $deny -cnotcontains $_ })
                Assert-Replay ($survivors.Count -eq 0) `
                    "In replay every tool the $($pass.Name) is granted must also be denied (survived: $($survivors -join ', '))."
            }
        }
    }
    $script:ReviewerReplayActive = $false
}
finally {
    Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:Failures.Count -eq 0) {
    Write-Host "PASS - $($script:Checks) replay-snapshot and rule-coverage check(s) passed." -ForegroundColor Green
    exit 0
}
Write-Host "FAIL - $($script:Failures.Count) failure(s) across $($script:Checks) check(s)." -ForegroundColor Red
$script:Failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
exit 1
