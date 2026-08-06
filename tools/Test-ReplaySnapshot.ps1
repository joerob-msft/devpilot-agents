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

# The marker field validator is module-internal; exercise it in module scope
# rather than exporting it just for a test.
function Test-MarkerField {
    param([Parameter(Mandatory)][hashtable]$Spec, [Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $module = Get-Module DevPilot.AgentHarness
    return (& $module { param($s, $v) ConvertTo-AgentMarkerFieldValue -Spec $s -Value $v } $Spec $Value)
}

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
    Write-Host "1/11 shipped synthetic snapshot" -ForegroundColor Cyan
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
    Write-Host "2/11 served responses keep the live shapes" -ForegroundColor Cyan
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
    Write-Host "3/11 absent reads, writes, and closed sessions fail closed" -ForegroundColor Cyan
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
    Write-Host "4/11 tamper, stale binding, and missing resource" -ForegroundColor Cyan
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
    Write-Host "5/11 path attacks" -ForegroundColor Cyan
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
    Write-Host "6/11 a snapshot may only carry reads" -ForegroundColor Cyan
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
    Write-Host "7/11 canonical form is ordinal and host-independent" -ForegroundColor Cyan
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
    Write-Host "8/11 rule-coverage accounting" -ForegroundColor Cyan
    $sources = @(
        [pscustomobject][ordered]@{ PackName = "core"; SourceId = "rule-a"; Sha256 = ("a" * 64); Text = "Prefer assigning a field once." }
        [pscustomobject][ordered]@{ PackName = "core"; SourceId = "rule-b"; Sha256 = ("b" * 64); Text = "Name every argument of a multi-line call." }
    )
    $anchors = @(
        [pscustomobject][ordered]@{ anchorId = "cf0"; path = "src/a.cs" }
        [pscustomobject][ordered]@{ anchorId = "cf1"; path = "src/b.cs" }
    )
    $constructs = @(
        [pscustomobject][ordered]@{ constructId = "mi0"; kind = "invocation"; path = "src/a.cs"; line = 12 }
        [pscustomobject][ordered]@{ constructId = "mi1"; kind = "invocation"; path = "src/a.cs"; line = 40 }
        [pscustomobject][ordered]@{ constructId = "dc0"; kind = "declaration"; path = "src/b.cs"; line = 7 }
    )
    $accepted = @([pscustomobject][ordered]@{
            candidateId = "reassigns-field"; packName = "core"; ruleSourceId = "rule-a"
            filePath = "/src/a.cs"; line = 12
        })
    # rule-a sorts to rs0 and rule-b to rs1 under the request's ordinal order.
    function New-CoverageRow {
        param(
            [string]$Ref, [string]$Sha, [string]$Status, [string]$Scope = "invocation",
            [string]$Checked = "mi0,mi1", [string]$Violating = "", [string]$Candidate = "", [string]$Quote = "",
            [string]$NotInReach = ""
        )
        return [pscustomobject][ordered]@{
            ruleRef = $Ref; ruleSourceSha256 = $Sha; ruleQuote = $Quote; status = $Status
            scope = $Scope; checkedConstructs = $Checked; notInReachConstructs = $NotInReach
            violatingConstructs = $Violating
            codeEvidence = "evidence"; siblingStatus = "checked"; siblingEvidence = "sibling"
            candidateId = $Candidate; notes = "note"
        }
    }
    function Invoke-Coverage {
        param(
            [object[]]$Rows, [object[]]$Accepted = @(), [string[]]$Withheld = @(),
            [object[]]$WithConstructs = $null, [bool]$Incomplete = $false
        )
        $set = if ($null -eq $WithConstructs) { $constructs } else { $WithConstructs }
        return Resolve-ReviewerConventionSpecialistRuleCoverage -Rows $Rows -ResolvedSources $sources `
            -AcceptedCandidates $Accepted -Constructs $set `
            -ConstructsIncomplete $Incomplete -WithheldCandidateIds $Withheld
    }

    $complete = Invoke-Coverage -Accepted $accepted -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Violating "mi0" -Candidate "reassigns-field"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([bool]$complete.Complete) `
        "Accounting that covers every requested source and every construct in scope must be complete."
    Assert-Replay (@($complete.UnemittedViolations).Count -eq 0) "A violation linked to an accepted candidate is not an unemitted one."

    $short = Invoke-Coverage -Rows @((New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant"))
    Assert-Replay (-not [bool]$short.Complete -and @($short.Missing) -ccontains "core/rule-b") `
        "A requested source with no row must be reported missing, not silently dropped."

    $dupe = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant"),
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "notApplicable" -Scope "none" -Checked ""),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay (-not [bool]$dupe.Complete -and @($dupe.Duplicates) -ccontains "rs0") `
        "A source accounted for twice must be reported as a duplicate."

    $bogus = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant"),
        (New-CoverageRow -Ref "rs9" -Sha ("c" * 64) -Status "violation" -Violating "mi0")
    )
    Assert-Replay (-not [bool]$bogus.Complete -and @($bogus.Unknown) -ccontains "rs9") `
        "A row naming a source that was never requested must be reported, not counted."
    Assert-Replay (@($bogus.UnemittedViolations).Count -eq 0) `
        "A violation on a source that was never requested must not become a withheld finding."

    # The heart of it: a rule cannot be called compliant while a construct in
    # its own declared scope goes unmentioned.
    $partialScope = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Checked "mi0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($partialScope.Rows)[0].status -ceq "unknown" -and
        [string]@($partialScope.Rows)[0].degradedReason -match "unaccounted") `
        "A row that checks only some of the constructs in its scope must degrade to unknown."
    Assert-Replay (-not [bool]$partialScope.Complete) "A partly-checked scope must not read as complete."

    $strayScope = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Checked "mi0,mi1,dc0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($strayScope.Rows)[0].status -ceq "unknown") `
        "A row that checks constructs outside its declared scope must degrade to unknown."

    $declarationScope = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope "declaration" -Checked "dc0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($declarationScope.Rows)[0].status -ceq "compliant") `
        "A declarations-scoped row that covers every declaration must stand."

    $ghostConstruct = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Violating "mi7"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($ghostConstruct.Rows)[0].status -ceq "unknown") `
        "A violating construct that does not exist must degrade the row."

    $unnamedViolation = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($unnamedViolation.Rows)[0].status -ceq "unknown") `
        "A violation that names no violating construct must degrade the row."

    $violatingWithoutViolation = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Violating "mi0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($violatingWithoutViolation.Rows)[0].status -ceq "unknown") `
        "Naming violating constructs while reporting no violation must degrade the row."

    # A wrong-anchor row cannot stand in for the right one.
    $wrongAnchor = Invoke-Coverage -Accepted $accepted -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Violating "mi1" -Candidate "reassigns-field"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($wrongAnchor.Rows)[0].status -ceq "unknown" -and
        [string]@($wrongAnchor.Rows)[0].candidateId -ceq "") `
        "A candidate anchored somewhere other than the constructs the row calls violating must not satisfy that row."

    $badHash = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("f" * 64) -Status "compliant"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($badHash.Rows)[0].status -ceq "unknown") `
        "A row citing a rule-source hash that was not transported must degrade to unknown."

    $badQuote = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Quote "text that is not in the source"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($badQuote.Rows)[0].status -ceq "unknown") `
        "A row quoting text absent from the transported source must degrade to unknown."

    $ghost = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Violating "mi0" -Candidate "never-emitted"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay (@($ghost.UnemittedViolations).Count -eq 1) `
        "A claimed violation with no emitted candidate must be recorded as unemitted."
    Assert-Replay ([string]@($ghost.Rows)[0].candidateId -ceq "") `
        "A link to a candidate that does not exist must not be recorded as a link."

    $alreadyWithheld = Invoke-Coverage -Withheld @("reassigns-field") -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Violating "mi0" -Candidate "reassigns-field"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay (@($alreadyWithheld.UnemittedViolations).Count -eq 0) `
        "A violation whose candidate the wrapper already withheld must not be counted a second time."

    $unaccounted = Invoke-Coverage -Accepted @([pscustomobject][ordered]@{
            candidateId = "x"; packName = "core"; ruleSourceId = "rule-b"; filePath = "/src/a.cs"; line = 12
        }) -Rows @((New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant"))
    Assert-Replay (-not [bool]$unaccounted.Complete -and @($unaccounted.UnaccountedCandidates) -ccontains "x") `
        "A candidate whose rule has no accounting row must be reported."

    # `none` is the shape a row takes when the model wants out of the checklist
    # without saying so. It has to cost something.
    # Narrowing is a real judgement - a production method is not a test method -
    # and it needs somewhere to be written down. What is not allowed is silence.
    $narrowed = Invoke-Coverage -WithConstructs @(
        [pscustomobject][ordered]@{ constructId = "dc0"; kind = "declaration"; path = "src/a.cs"; line = 5; endLine = 5 }
        [pscustomobject][ordered]@{ constructId = "dc1"; kind = "declaration"; path = "src/a.cs"; line = 20; endLine = 20 }
        [pscustomobject][ordered]@{ constructId = "dc2"; kind = "declaration"; path = "src/a.cs"; line = 40; endLine = 40 }
    ) -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope "declaration" -Checked "dc1,dc2" -NotInReach "dc0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope "declaration" -Checked "dc0-dc2")
    )
    Assert-Replay ([string]@($narrowed.Rows)[0].status -ceq "compliant" -and [bool]$narrowed.Complete) `
        "A row may put a construct out of the rule's reach and still be complete, as long as it says which."
    Assert-Replay ((@(@($narrowed.Rows)[0].notInReachConstructs) -join ",") -ceq "dc0") `
        "The out-of-reach set must be recorded, so a reader can see what the row decided not to weigh."

    $silent = Invoke-Coverage -WithConstructs @(
        [pscustomobject][ordered]@{ constructId = "dc0"; kind = "declaration"; path = "src/a.cs"; line = 5; endLine = 5 }
        [pscustomobject][ordered]@{ constructId = "dc1"; kind = "declaration"; path = "src/a.cs"; line = 20; endLine = 20 }
    ) -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope "declaration" -Checked "dc1"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope "declaration" -Checked "dc0,dc1")
    )
    Assert-Replay ([string]@($silent.Rows)[0].status -ceq "unknown" -and
        ([string]@($silent.Rows)[0].degradedReason).Contains("dc0")) `
        "Leaving a construct out of BOTH lists must still degrade, and the reason must name it."

    $bothWays = Invoke-Coverage -WithConstructs @(
        [pscustomobject][ordered]@{ constructId = "dc0"; kind = "declaration"; path = "src/a.cs"; line = 5; endLine = 5 }
    ) -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope "declaration" -Checked "dc0" -NotInReach "dc0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope "declaration" -Checked "dc0")
    )
    Assert-Replay ([string]@($bothWays.Rows)[0].status -ceq "unknown") `
        "A construct cannot be both weighed against the rule and outside its reach."

    $allOutOfReach = Invoke-Coverage -WithConstructs @(
        [pscustomobject][ordered]@{ constructId = "dc0"; kind = "declaration"; path = "src/a.cs"; line = 5; endLine = 5 }
    ) -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope "declaration" -Checked "" -NotInReach "dc0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope "declaration" -Checked "dc0")
    )
    Assert-Replay ([string]@($allOutOfReach.Rows)[0].status -ceq "unknown") `
        "Putting every construct out of reach and calling the rule compliant is an answer about nothing."
    $allOutOfReachOk = Invoke-Coverage -WithConstructs @(
        [pscustomobject][ordered]@{ constructId = "dc0"; kind = "declaration"; path = "src/a.cs"; line = 5; endLine = 5 }
    ) -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "notApplicable" -Scope "declaration" -Checked "" -NotInReach "dc0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope "declaration" -Checked "dc0")
    )
    Assert-Replay ([string]@($allOutOfReachOk.Rows)[0].status -ceq "notApplicable" -and [bool]$allOutOfReachOk.Complete) `
        "A rule that reaches nothing in a scope it declared may say exactly that."

    $vacuous = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope "none" -Checked ""),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($vacuous.Rows)[0].status -ceq "unknown" -and -not [bool]$vacuous.Complete) `
        "A row claiming nothing was in reach while constructs exist must degrade, not pass as compliant."

    $vacuousOk = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "notApplicable" -Scope "none" -Checked ""),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($vacuousOk.Rows)[0].status -ceq "notApplicable" -and [bool]$vacuousOk.Complete) `
        "A rule that genuinely does not apply may say so with an empty scope."

    $wrongKind = Invoke-Coverage -WithConstructs @(
        [pscustomobject][ordered]@{ constructId = "mi0"; kind = "invocation"; path = "src/a.cs"; line = 12; endLine = 12 }
    ) -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope "declaration" -Checked ""),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Checked "mi0")
    )
    Assert-Replay ([string]@($wrongKind.Rows)[0].status -ceq "unknown") `
        "Narrowing scope to a kind the change set does not contain is the same empty answer and must degrade too."

    # A comment on a multi-line call belongs on the offending argument, which is
    # never the line the call opens on. Requiring exact equality here would
    # reject precisely the rows that anchored correctly.
    $spanned = Invoke-Coverage -WithConstructs @(
        [pscustomobject][ordered]@{ constructId = "mi0"; kind = "invocation"; path = "SRC/a.cs"; line = 10; endLine = 14 }
    ) -Accepted @([pscustomobject][ordered]@{
            candidateId = "positional-message"; packName = "core"; ruleSourceId = "rule-a"; filePath = "/src/A.cs"; line = 13
        }) -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Scope "invocation" -Checked "mi0" -Violating "mi0" -Candidate "positional-message"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope "invocation" -Checked "mi0")
    )
    Assert-Replay ([string]@($spanned.Rows)[0].candidateId -ceq "positional-message" -and [bool]$spanned.Complete) `
        "A candidate anchored inside a construct's span, on a path differing only in case, must count as linked."

    $offSpan = Invoke-Coverage -WithConstructs @(
        [pscustomobject][ordered]@{ constructId = "mi0"; kind = "invocation"; path = "src/a.cs"; line = 10; endLine = 14 }
    ) -Accepted @([pscustomobject][ordered]@{
            candidateId = "elsewhere"; packName = "core"; ruleSourceId = "rule-a"; filePath = "/src/a.cs"; line = 99
        }) -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Scope "invocation" -Checked "mi0" -Violating "mi0" -Candidate "elsewhere"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope "invocation" -Checked "mi0")
    )
    Assert-Replay ([string]@($offSpan.Rows)[0].status -ceq "unknown") `
        "A candidate outside every construct the row called violating must still degrade the row."

    $partial = Invoke-Coverage -Incomplete $true -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Violating "mi0" -Candidate "reassigns-field"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    ) -Accepted $accepted
    Assert-Replay ([bool]$partial.Complete -eq $false -and [bool]$partial.ConstructsIncomplete) `
        "An accounting over a construct set the wrapper could not finish enumerating is not complete."
    Assert-Replay (@($partial.Constructs).Count -eq @($constructs).Count -and
        [string]@($partial.Constructs)[0].constructId -ceq "mi0") `
        "The accounting must carry the construct table it was reconciled against, so a reader can check a row without re-running the enumeration."

    $index = Get-ReviewerConventionSpecialistChangedFileIndex -ChangeEntries @(        [pscustomobject][ordered]@{ Path = "src/z.cs"; Role = "current" },
        [pscustomobject][ordered]@{ Path = "src/a.cs"; Role = "current" },
        [pscustomobject][ordered]@{ Path = "src/gone.cs"; Role = "original" }
    )
    Assert-Replay (@($index).Count -eq 2 -and [string]@($index)[0].path -ceq "src/a.cs" -and [string]@($index)[0].anchorId -ceq "cf0") `
        "The changed-file anchor index must be ordinal, deduplicated, and current-role only."

    # -- 9. Schema bounds ------------------------------------------------------
    Write-Host "9/11 schema bounds" -ForegroundColor Cyan
    $schema = Get-ReviewerConventionSpecialistMarkerSchema -ExpectedProject "Widgets" -ExpectedNonce "n"
    Assert-Replay ($schema.Keys -ccontains "ruleCoverage") "The marker schema must declare ruleCoverage."
    $coverageSpec = $schema.Fields["ruleCoverage"]
    Assert-Replay ([int]$coverageSpec.MaxItems -eq 10) "The rule-coverage array must be bounded at 10 rows."
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
    $wideCoverage = Resolve-ReviewerConventionSpecialistRuleCoverage -ResolvedSources $wide `
        -AcceptedCandidates @() -Rows @(@($wideRequest.Requested) | ForEach-Object {
            [pscustomobject][ordered]@{
                ruleRef = [string]$_.ruleRef; ruleSourceSha256 = ("c" * 64); ruleQuote = ""
                status = "notApplicable"; scope = "none"; checkedConstructs = ""; notInReachConstructs = ""; violatingConstructs = ""
                codeEvidence = ""; siblingStatus = "notRequired"; siblingEvidence = ""
                candidateId = ""; notes = ""
            }
        })
    Assert-Replay (-not [bool]$wideCoverage.Complete -and @($wideCoverage.Missing).Count -eq 4) `
        "Sources beyond the row cap must be reported unaccounted, never silently dropped."
    Assert-Replay ($script:ReviewerConventionSpecialistWithheldReasons -ccontains "accountedNotEmitted") `
        "The withheld reason set must include the wrapper's unemitted-violation reason."
    Assert-Replay ($coverageSpec.Item.Fields["status"].Values.Count -eq 4) `
        "A coverage row's status must be one of exactly four values."
    # The construct id list has to be able to hold EVERY construct the wrapper
    # can enumerate. If it cannot, a complete accounting would be unwritable and
    # the section would fail exactly the change sets it was built for. Ranges
    # are what make that possible: the whole set is four ranges, one per kind.
    . (Join-Path $RepoRoot "src\Agents\reviewer\ChangedConstructs.ps1")
    $widestIdList = 0
    foreach ($prefix in @("mi", "dc", "cm", "as")) {
        $kindIds = [string[]]@(0..($script:ReviewerConstructMaxTotal - 1) | ForEach-Object { "$prefix$_" })
        $widestIdList += (Get-ReviewerConstructIdRanges -Ids $kindIds).Length + 1
    }
    Assert-Replay ($widestIdList -le [int]$coverageSpec.Item.Fields["checkedConstructs"].MaxLength) `
        "The checked-construct field ($([int]$coverageSpec.Item.Fields['checkedConstructs'].MaxLength) chars) must hold every id the enumerator can produce ($widestIdList chars)."
    Assert-Replay ($widestIdList -le [int]$coverageSpec.Item.Fields["violatingConstructs"].MaxLength) `
        "The violating-construct field must hold every id the enumerator can produce."
    $roundTrip = Expand-ReviewerConventionSpecialistConstructIds -Text (Get-ReviewerConstructIdRanges -Ids ([string[]]@("mi0", "mi1", "mi2", "mi7")))
    Assert-Replay ([bool]$roundTrip.Ok -and (@($roundTrip.Ids) -join ",") -ceq "mi0,mi1,mi2,mi7") `
        "A range-compressed id list must expand back to exactly the ids it came from."
    # The marker pattern and the expander both stop at three digits. Raising the
    # construct budget past that would produce ids no row could legally name,
    # with nothing anywhere to say so.
    Assert-Replay ($script:ReviewerConstructMaxTotal -le 999) `
        "The construct budget must stay inside the three-digit id space the marker pattern and the expander both enforce."
    $tooWide = Expand-ReviewerConventionSpecialistConstructIds -Text "mi1000"
    Assert-Replay (-not [bool]$tooWide.Ok) "A four-digit construct id must be refused rather than silently truncated."
    foreach ($bad in @("mi3-mi1", "mi0-dc4", "mi", "mi0,,mi1-", "xx0")) {
        $rejected = Expand-ReviewerConventionSpecialistConstructIds -Text $bad
        Assert-Replay (-not [bool]$rejected.Ok) "A construct list of '$bad' must be reported unreadable, not guessed at."
    }

    # A reporting section must not be able to destroy the findings it reports
    # on. Twice a complete accounting was discarded whole - once for evidence a
    # few characters over a cap, once for a single curly quote - taking the
    # candidates with it. Prose fields therefore carry no ASCII pattern; the
    # marker validator still refuses control characters in every string, and
    # these fields never reach a pull-request comment.
    $candidateSpec = $schema.Fields["candidates"]
    foreach ($prose in @("codeEvidence", "siblingEvidence", "notes")) {
        $spec = $coverageSpec.Item.Fields[$prose]
        Assert-Replay (-not ($spec.ContainsKey("Pattern") -and $spec.Pattern)) `
            "Rule-coverage field '$prose' must not carry a character pattern that a sentence about code can fail."
        $accepted = Test-MarkerField -Spec $spec -Value ([string][char]0x2019 + "a curly quote and an en dash " + [char]0x2013)
        Assert-Replay ([bool]$accepted.Ok) "Rule-coverage field '$prose' must accept ordinary typographic characters."
        $control = Test-MarkerField -Spec $spec -Value "line one`nline two"
        Assert-Replay (-not [bool]$control.Ok) "Rule-coverage field '$prose' must still refuse control characters."
        # Over-length must SHORTEN, not reject. A row that names every construct
        # it checked is exactly the row most likely to run long, and losing the
        # marker over it loses every candidate the pass found.
        $long = Test-MarkerField -Spec $spec -Value ("x" * ([int]$spec.MaxLength + 500))
        Assert-Replay ([bool]$long.Ok) "Rule-coverage field '$prose' must be shortened when it runs long, not reject the whole marker."
        Assert-Replay (([string]$long.Value).Length -le [int]$spec.MaxLength) `
            "A shortened rule-coverage field must end up within its own bound."
        Assert-Replay (([string]$long.Value).EndsWith("...")) `
            "A shortened rule-coverage field must show that it was shortened."
        # A lone surrogate half is not a control character and has no pattern to
        # fail, so it survives validation and then throws when the preview is
        # written as strict UTF-8 - losing the pass to the mechanism that exists
        # to stop passes being lost.
        $astral = [string][char]0xD83D + [string][char]0xDE00
        $pairCut = Test-MarkerField -Spec $spec -Value (("y" * ([int]$spec.MaxLength - 4)) + $astral + ("z" * 40))
        Assert-Replay ([bool]$pairCut.Ok) "A shortened field containing an astral character must still validate."
        $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $encoded = $null
        try { $encoded = $strictUtf8.GetBytes([string]$pairCut.Value) } catch { $encoded = $null }
        Assert-Replay ($null -ne $encoded) `
            "Shortening must never cut a surrogate pair in half: the result has to survive being written as strict UTF-8."
    }
    # Truncation is opt-in, and comment text never opts in.
    foreach ($strict in @("ruleQuote", "checkedConstructs", "violatingConstructs")) {
        $spec = $coverageSpec.Item.Fields[$strict]
        Assert-Replay (-not ($spec.ContainsKey("Truncate") -and [bool]$spec.Truncate)) `
            "Rule-coverage field '$strict' must never be silently shortened: the wrapper checks it against something exact."
    }
    foreach ($commentField in @($candidateSpec.Item.Keys)) {
        $spec = $candidateSpec.Item.Fields[$commentField]
        Assert-Replay (-not ($spec.ContainsKey("Truncate") -and [bool]$spec.Truncate)) `
            "Candidate field '$commentField' must never be silently shortened: it becomes pull-request comment text."
    }
    # The candidate fields, which DO become comment text, stay strict: a
    # character outside the enumerated transliteration is still refused.
    $commentSpec = $candidateSpec.Item.Fields["diffEvidence"]
    $rejected = Test-MarkerField -Spec $commentSpec -Value ("curly " + [string][char]0x2192)
    Assert-Replay (-not [bool]$rejected.Ok) "Candidate comment text must remain printable ASCII only."
    $quoteSpec = $coverageSpec.Item.Fields["ruleQuote"]
    $quoteRejected = Test-MarkerField -Spec $quoteSpec -Value ([string][char]0x2019 + "curly")
    Assert-Replay (-not [bool]$quoteRejected.Ok) `
        "A coverage row's rule quote must stay ASCII, because it has to match the transported source exactly."

    # A model reaches for an em dash or a curly quote without thinking, and the
    # ASCII rule that protects comment text from carrying structure then costs
    # the whole pass. The enumerated transliteration is meaning-preserving; what
    # is not in the table still fails closed.
    $dashField = $candidateSpec.Item.Fields["diffEvidence"]
    $dashed = Test-MarkerField -Spec $dashField -Value ("mi20 lines 744-750: called positionally " + [string][char]0x2014 + " both args positional.")
    Assert-Replay ([bool]$dashed.Ok) "An em dash in candidate evidence must not cost the pass."
    Assert-Replay (([string]$dashed.Value).IndexOf([char]0x2014) -lt 0 -and ([string]$dashed.Value) -match ' - both args') `
        "The em dash must be replaced by the character a reader would have read anyway."
    $quoted = Test-MarkerField -Spec $dashField -Value ([string][char]0x201C + "value" + [string][char]0x201D + " and " + [string][char]0x2026)
    Assert-Replay ([bool]$quoted.Ok -and ([string]$quoted.Value) -ceq '"value" and ...') `
        "Curly quotes and an ellipsis must transliterate to their ASCII equivalents."
    $stillRejected = Test-MarkerField -Spec $dashField -Value ("evidence with an arrow " + [string][char]0x2192)
    Assert-Replay (-not [bool]$stillRejected.Ok) `
        "A character outside the transliteration table must still be refused: this is not a licence for arbitrary Unicode."
    $stillControl = Test-MarkerField -Spec $dashField -Value "line one`nline two"
    Assert-Replay (-not [bool]$stillControl.Ok) "Control characters must still be refused in candidate text."
    foreach ($exact in @("candidateId", "packName", "filePath", "ruleSourcePath", "factIds")) {
        $spec = $candidateSpec.Item.Fields[$exact]
        Assert-Replay (-not ($spec.ContainsKey("NormalizeTypography") -and [bool]$spec.NormalizeTypography)) `
            "Candidate field '$exact' is an identifier or a path and must never be rewritten."
    }
    $quoteSpecStrict = $candidateSpec.Item.Fields["ruleQuote"]
    Assert-Replay (-not ($quoteSpecStrict.ContainsKey("NormalizeTypography") -and [bool]$quoteSpecStrict.NormalizeTypography)) `
        "A candidate's rule quote must never be rewritten: it is checked against the transported source verbatim."

    # The scaffold: the top-level object handed to the model already built, so a
    # long analysis cannot end with a marker missing its last key.
    $inputResult = New-ReviewerConventionSpecialistInput -PromptText "prompt" -Nonce "n-scaffold" `
        -Organization "org" -Project "Widgets" -RepositoryId "repo" -PrId 7 `
        -SourceCommit ("1" * 40) -TargetCommit ("2" * 40) -ChangeSetDigest ("3" * 64) `
        -ConventionPlanSha256 ("4" * 64) -FactPlanSha256 ("9" * 64) -ConfigSha256 ("8" * 64) `
        -ScriptSha256 ("5" * 64) -PromptSha256 ("6" * 64) `
        -ConventionPlan ([pscustomobject]@{}) -FactPlan ([pscustomobject]@{}) `
        -ResolvedSources $sources -ChangeEntries @(
        [pscustomobject][ordered]@{ Path = "src/a.cs"; Role = "current" }
    ) -Constructs $constructs `
        -ThreadDigestText "" -PinnedSourceText ""
    $runtimeJson = [regex]::Match([string]$inputResult.Text, '(?s)```json\r?\n(\{.*?\})\r?\n```')
    Assert-Replay ($runtimeJson.Success) "The specialist input must embed its runtime data as JSON."
    $runtime = $runtimeJson.Groups[1].Value | ConvertFrom-Json

    $scaffold = $runtime.markerScaffold
    Assert-Replay ($null -ne $scaffold) "The specialist input must carry a prebuilt marker scaffold."
    $scaffoldKeys = @($scaffold.PSObject.Properties | ForEach-Object { $_.Name })
    $topKeys = @($schema.Keys)
    Assert-Replay (($scaffoldKeys -join "|") -ceq ($topKeys -join "|")) `
        "The marker scaffold must have exactly the schema's top-level keys, in order, or it teaches the wrong shape."
    Assert-Replay ([string]$scaffold.nonce -ceq "n-scaffold" -and [string]$scaffold.scriptSha256 -ceq ("5" * 64)) `
        "The scaffold must carry the real binding values, since transcribing them by hand is what was losing markers."
    foreach ($arrayKey in @("candidates", "ruleCoverage", "withheld", "residualRisks")) {
        Assert-Replay (@($scaffold.$arrayKey).Count -eq 0) `
            "The scaffold's '$arrayKey' must be empty: it is a format aid and must never suggest a finding."
    }

    # -- 10. Changed-construct enumeration -------------------------------------
    # The generic half of the calibration: what the wrapper can establish about
    # a change set WITHOUT knowing the language's testing framework, its
    # attributes, or anything about the repository it came from.
    Write-Host "10/11 changed-construct enumeration" -ForegroundColor Cyan
    . (Join-Path $RepoRoot "src\Agents\reviewer\ChangedConstructs.ps1")

    function Get-Constructs {
        param([string[]]$Code, [int[]]$Changed, [string]$Path = "src/Sample.cs")
        $changedLines = if ($Changed) { $Changed } else { @(1..$Code.Count) }
        return Get-ReviewerChangedConstructs -Files @(@{ Path = $Path; Lines = $Code; ChangedLines = $changedLines })
    }
    function Get-Invocation {
        param($Result, [int]$Index = 0)
        $items = @(@($Result.Constructs) | Where-Object { [string]$_.kind -ceq "invocation" })
        if ($items.Count -le $Index) { return $null }
        return $items[$Index]
    }

    # A multi-line call whose FINAL argument is positional while earlier ones
    # are named. This is the exact shape a real review missed.
    $positional = Get-Constructs -Code @(
        'public void T()', '{', '    Assert.AreEqual(', '        expected: 1,',
        '        actual: 2,', '        "a positional message");', '}')
    $positionalCall = Get-Invocation -Result $positional
    Assert-Replay ($null -ne $positionalCall -and [string]$positionalCall.argumentNaming -ceq "nnp") `
        "A trailing positional argument after named ones must be visible as 'nnp' (got '$(if ($positionalCall) { $positionalCall.argumentNaming } else { 'no call' })')."
    Assert-Replay ($null -ne $positionalCall -and [int]$positionalCall.line -eq 3 -and [int]$positionalCall.endLine -eq 6) `
        "A multi-line call must report the line it opens on and the line it closes on."

    $allNamed = Get-Constructs -Code @(
        'public void T()', '{', '    Assert.AreEqual(', '        expected: 1,', '        actual: 2);', '}')
    Assert-Replay ([string](Get-Invocation -Result $allNamed).argumentNaming -ceq "nn") `
        "A fully named multi-line call must read as all-named."

    # One lambda argument. A rule about naming parameters between linefeeds has
    # nothing to say here, and the enumeration must make that visible rather
    # than reporting a violation shape.
    $singleLambda = Get-Constructs -Code @(
        'public void T()', '{', '    var x = items.SingleOrDefault(',
        '        item => item.Id == wanted);', '}')
    $lambdaCall = Get-Invocation -Result $singleLambda
    Assert-Replay ($null -ne $lambdaCall -and [string]$lambdaCall.argumentNaming -ceq "p" -and [int]$lambdaCall.argumentCount -eq 1) `
        "A single unnamed lambda argument must read as one positional argument, not as a naming violation."

    # A nested call inside an argument must not be mistaken for the construct,
    # and a comma inside it must not split the outer argument list.
    $nested = Get-Constructs -Code @(
        'public void T()', '{', '    Outer(',
        '        first: Inner(a, b),', '        second: 2);', '}')
    $nestedCall = Get-Invocation -Result $nested
    Assert-Replay ($null -ne $nestedCall -and [string]$nestedCall.name -ceq "Outer" -and [int]$nestedCall.argumentCount -eq 2) `
        "A nested call must stay inside its argument: the outer call has two arguments, not three."

    # Commas, parentheses and colons inside comments and strings are text.
    $noise = Get-Constructs -Code @(
        'public void T()', '{', '    Log(',
        '        message: "a, b: c) (d",  // named: not really, this is a comment',
        '        /* block, with: punctuation */ 42);', '}')
    $noiseCall = Get-Invocation -Result $noise
    Assert-Replay ($null -ne $noiseCall -and [int]$noiseCall.argumentCount -eq 2 -and [string]$noiseCall.argumentNaming -ceq "np") `
        "Commas and colons inside comments and strings must not change the argument shape (got '$(if ($noiseCall) { "$($noiseCall.argumentCount)/$($noiseCall.argumentNaming)" } else { 'no call' })')."

    # A generic argument list is not a comparison, and its comma is not an
    # argument separator.
    $generic = Get-Constructs -Code @(
        'public void T()', '{', '    Build<Alpha, Beta>(',
        '        left: 1,', '        right: 2);', '}')
    $genericCall = Get-Invocation -Result $generic
    Assert-Replay ($null -ne $genericCall -and [int]$genericCall.argumentCount -eq 2 -and [string]$genericCall.name -ceq "Build") `
        "A generic argument list must not be read as arguments."

    # Ternaries and qualified names contain colons that are not argument names.
    $colons = Get-Constructs -Code @(
        'public void T()', '{', '    Pick(',
        '        flag ? 1 : 2,', '        global::Ns.Value);', '}')
    $colonCall = Get-Invocation -Result $colons
    Assert-Replay ($null -ne $colonCall -and [string]$colonCall.argumentNaming -ceq "pp") `
        "A conditional colon and a qualified-name colon must not read as argument names (got '$(if ($colonCall) { $colonCall.argumentNaming } else { 'no call' })')."

    # Unterminated: report it, do not guess.
    $malformed = Get-Constructs -Code @('public void T()', '{', '    Assert.AreEqual(', '        expected: 1,')
    $malformedCall = Get-Invocation -Result $malformed
    Assert-Replay ($null -ne $malformedCall -and [string]$malformedCall.status -ceq "unknown") `
        "A call that never closes must be reported unknown rather than given an argument shape."
    $unterminatedComment = Get-Constructs -Code @('public void T()', '{', '    /* never closed', '    Assert.AreEqual(', '        expected: 1);', '}')
    Assert-Replay (@($unterminatedComment.PartiallyUnderstoodFiles).Count -eq 1) `
        "A file with an unterminated comment must be reported as only partly understood."

    # Declarations: the attributes on them, and the attributes on their nearest
    # unchanged neighbours, are facts a rule can turn on.
    $declarations = Get-Constructs -Code @(
        'public class C', '{', '    [TestMethod]', '    [Owner("alice")]',
        '    public void First() { }', '', '    [TestMethod]',
        '    public void Second() { }', '}') -Changed @(7, 8)
    $second = @(@($declarations.Constructs) | Where-Object { [string]$_.kind -ceq "declaration" })
    Assert-Replay (@($second).Count -eq 1 -and [string]@($second)[0].name -ceq "Second") `
        "Only the CHANGED declaration is enumerated."
    Assert-Replay (@(@($second)[0].attributes) -ccontains "TestMethod" -and @(@($second)[0].attributes) -cnotcontains "Owner") `
        "A changed declaration must report exactly the attributes on it."
    Assert-Replay (@(@($second)[0].siblingAttributes) -ccontains "Owner") `
        "A changed declaration must report the attributes on its nearest unchanged neighbour, so precedent is a fact and not an impression."
    $frequency = @(@($declarations.Files)[0].attributeFrequency | Where-Object { [string]$_.attribute -ceq "Owner" })
    Assert-Replay (@($frequency).Count -eq 1 -and [int]@($frequency)[0].declarations -eq 1) `
        "The per-file attribute count must say how much precedent there actually is."
    $noPrecedent = Get-Constructs -Code @(
        'public class C', '{', '    [TestMethod]', '    public void First() { }',
        '', '    [TestMethod]', '    public void Second() { }', '}') -Changed @(6, 7)
    Assert-Replay (@(@($noPrecedent.Files)[0].attributeFrequency | Where-Object { [string]$_.attribute -ceq "Owner" }).Count -eq 0) `
        "A file where the attribute never appears must report no precedent for it at all."

    # Dotted attribute names are reported whole: reporting
    # System.Diagnostics.CodeAnalysis.SuppressMessage as "System" tells a reader
    # nothing and collides with anything else in that namespace.
    $dotted = Get-Constructs -Code @(
        'public class C', '{', '    [System.Diagnostics.CodeAnalysis.SuppressMessage("a", "b")]',
        '    public void First() { }', '}') -Changed @(4)
    $dottedDeclaration = @(@($dotted.Constructs) | Where-Object { [string]$_.kind -ceq "declaration" })[0]
    Assert-Replay (@($dottedDeclaration.attributes) -ccontains "System.Diagnostics.CodeAnalysis.SuppressMessage") `
        "An attribute's full dotted name must be reported, not its first segment."

    # Comment runs. A rule about what documentation says needs somewhere of its
    # own to anchor: the nearest declaration can be a hundred lines away, and a
    # comment anchored on it is a comment about the wrong thing.
    $comments = Get-Constructs -Code @(
        'public class C', '{', '    /// <summary>', '    /// Does the thing.', '    /// </summary>',
        '    public void First() { }', '', '    // a separate note', '    public void Second() { }', '}') -Changed @(3, 4, 5, 8)
    $commentRuns = @(@($comments.Constructs) | Where-Object { [string]$_.kind -ceq "comment" })
    Assert-Replay (@($commentRuns).Count -eq 2) `
        "Contiguous changed comment lines must group into one construct per run (got $(@($commentRuns).Count))."
    Assert-Replay ([int]@($commentRuns)[0].line -eq 3 -and [int]@($commentRuns)[0].endLine -eq 5) `
        "A comment run must report the first and last line it covers, so a candidate can anchor anywhere inside it."
    $codeNotComment = Get-Constructs -Code @('public void T()', '{', '    var s = "// not a comment";', '}')
    Assert-Replay (@(@($codeNotComment.Constructs) | Where-Object { [string]$_.kind -ceq "comment" }).Count -eq 0) `
        "A comment marker inside a string literal is not a comment."

    # Assignments. An immutability rule is about writing to something that
    # already exists; a declaration with an initializer is not that, and calling
    # it one would invent violations the code does not commit.
    $assignments = Get-Constructs -Code @(
        'public void T(Config c)', '{', '    var local = 1;', '    c.Value = 2;',
        '    this.field = 3;', '    map["k"] = 4;', '    if (a == b) { }', '    Func<int,int> f = x => x;', '}')
    $writes = @(@($assignments.Constructs) | Where-Object { [string]$_.kind -ceq "assignment" })
    $targets = @(@($writes) | ForEach-Object { [string]$_.name })
    Assert-Replay ($targets -ccontains "c.Value" -and $targets -ccontains "this.field") `
        "A write to an existing member must be enumerated as an assignment (got $($targets -join ','))."
    Assert-Replay ($targets -cnotcontains "local" -and $targets -cnotcontains "f") `
        "A declaration with an initializer is a declaration, not a reassignment."
    Assert-Replay (@($writes | Where-Object { [string]$_.name -cmatch '^a' }).Count -eq 0) `
        "An equality comparison must not be read as an assignment."
    $initializer = Get-Constructs -Code @(
        'public void T()', '{', '    var o = new Thing', '    {', '        Name = "x",', '        Size = 2', '    };', '}')
    $initializerWrites = @(@($initializer.Constructs) | Where-Object { [string]$_.kind -ceq "assignment" })
    Assert-Replay (@($initializerWrites).Count -eq 0) `
        "Object-initializer entries are initialization, not reassignment (got $(@($initializerWrites | ForEach-Object { $_.name }) -join ','))."

    # `if (`, `while (` and friends have a call's shape and no arguments at
    # all. A rule about how arguments are passed must not be handed one as a
    # construct it has to account for, still less as one it may anchor on.
    $control = Get-Constructs -Code @(
        'public void T(int a, int b)', '{', '    if (a > 0 &&', '        b > 0)', '    {', '        Do(',
        '            x: a);', '    }', '}')
    $controlCalls = @(@($control.Constructs) | Where-Object { [string]$_.kind -ceq "invocation" })
    Assert-Replay (@($controlCalls).Count -eq 1 -and [string]@($controlCalls)[0].name -ceq "Do") `
        "A wrapped control-flow statement must not be enumerated as a call (got $(@($controlCalls | ForEach-Object { $_.name }) -join ','))."
    Assert-Replay (@(@($control.Constructs) | Where-Object { [string]$_.name -ceq "if" }).Count -eq 0) `
        "No construct of any kind may be named after a control-flow keyword."
    $keywordPrefix = Get-Constructs -Code @('public void T()', '{', '    iffy(', '        x: 1);', '}')
    $keywordCalls = @(@($keywordPrefix.Constructs) | Where-Object { [string]$_.kind -ceq "invocation" })
    Assert-Replay (@($keywordCalls).Count -eq 1 -and [string]@($keywordCalls)[0].name -ceq "iffy") `
        "A method whose name merely starts with a keyword is still a call."

    # Attributes and neighbours must not be read across a gap the transport
    # never delivered. The file image is sparse, so a blank line there is not
    # evidence of anything - and these attributes are presented to the model as
    # facts underpinning a precedent argument.
    $sparse = [System.Collections.Generic.List[string]]::new()
    [void]$sparse.Add('    [Owner("someone")]')
    [void]$sparse.Add('    public void FarAway() { }')
    foreach ($blank in 1..40) { [void]$sparse.Add('') }
    [void]$sparse.Add('    public void Nearby() { }')
    $gapFiles = @(@{
            Path = "src/Sparse.cs"
            Lines = @($sparse.ToArray())
            ChangedLines = @(43)
            DeliveredLines = @(43)
        })
    $gapped = Get-ReviewerChangedConstructs -Files $gapFiles
    $gapDeclaration = @(@($gapped.Constructs) | Where-Object { [string]$_.kind -ceq "declaration" })
    Assert-Replay (@($gapDeclaration).Count -eq 1 -and [string]@($gapDeclaration)[0].name -ceq "Nearby") `
        "The changed declaration must still be enumerated when the rest of the file was not delivered."
    Assert-Replay (@(@($gapDeclaration)[0].attributes).Count -eq 0 -and @(@($gapDeclaration)[0].siblingAttributes).Count -eq 0) `
        "An attribute forty undelivered lines away is not this declaration's attribute, and not its neighbour's either."
    $gapSummary = @($gapped.Files)[0]
    Assert-Replay (@($gapSummary.attributeFrequency | Where-Object { [string]$_.attribute -ceq "Owner" }).Count -eq 0) `
        "The per-file attribute count must count only what the transport delivered."

    # A statement that happens to open a call has the shape of a declaration.    # Counting those inflates the declaration set, which is the denominator of
    # the precedent fact a rule reads.
    $statements = Get-Constructs -Code @(
        'public class C', '{', '    public async Task M()', '    {',
        '        await Fetch(', '            id: 1);', '        yield return Make(', '            id: 2);', '    }', '}')
    $statementDeclarations = @(@($statements.Constructs) | Where-Object { [string]$_.kind -ceq "declaration" -and @("Fetch", "Make") -ccontains [string]$_.name })
    Assert-Replay (@($statementDeclarations).Count -eq 0) `
        "`await Foo(` and `yield return Bar(` are statements, not declarations, and must not be counted as either."

    # An attribute written on the same line as the member it decorates is still
    # that member's attribute. Skipping those lines is a blind spot exactly
    # where an attribute rule is looking.
    $inline = Get-Constructs -Code @(
        'public class C', '{', '    [TestMethod] public void First() { }', '}') -Changed @(3)
    $inlineDeclaration = @(@($inline.Constructs) | Where-Object { [string]$_.kind -ceq "declaration" })
    Assert-Replay (@($inlineDeclaration).Count -eq 1 -and [string]@($inlineDeclaration)[0].name -ceq "First") `
        "A declaration with its attribute on the same line must still be enumerated."
    Assert-Replay (@(@($inlineDeclaration)[0].attributes) -ccontains "TestMethod") `
        "An attribute written inline must be reported as that declaration's attribute."

    # A raw string literal's body is prose. Scanning it as code manufactures
    # constructs out of documentation.
    $rawString = Get-Constructs -Code @(
        'public void T()', '{', '    var s = """', '    public void NotReal(', '        a: 1);', '    """;', '}')
    Assert-Replay (@($rawString.PartiallyUnderstoodFiles).Count -eq 1) `
        "A raw string literal must make the file partly understood rather than be scanned as code."

    # Masking blanks literals, so a call whose only argument is a literal looks
    # empty. Reading that as a no-argument call erases the argument a rule about
    # arguments is asking about.
    $literalOnly = Get-Constructs -Code @(
        'public void T()', '{', '    Log(', '        "a message");', '}')
    $literalCall = Get-Invocation -Result $literalOnly
    Assert-Replay ($null -ne $literalCall -and [int]$literalCall.argumentCount -eq 1 -and [string]$literalCall.argumentNaming -ceq "p") `
        "A call whose only argument is a string literal has one positional argument, not none (got $(if ($literalCall) { $literalCall.argumentCount } else { 'no call' }))."

    # A call-heavy change set must not consume the whole budget before a single
    # declaration is emitted, or an attribute rule gets no anchors at all.
    $manyCalls = [System.Collections.Generic.List[string]]::new()
    [void]$manyCalls.Add('public class C')
    [void]$manyCalls.Add('{')
    foreach ($i in 1..40) {
        [void]$manyCalls.Add("    public void M$i()")
        [void]$manyCalls.Add('    {')
        [void]$manyCalls.Add('        Do(')
        [void]$manyCalls.Add("            x: $i);")
        [void]$manyCalls.Add('    }')
    }
    [void]$manyCalls.Add('}')
    $budget = Get-Constructs -Code @($manyCalls.ToArray())
    $budgetDeclarations = @(@($budget.Constructs) | Where-Object { [string]$_.kind -ceq "declaration" })
    $budgetInvocations = @(@($budget.Constructs) | Where-Object { [string]$_.kind -ceq "invocation" })
    Assert-Replay (@($budgetDeclarations).Count -gt 0 -and @($budgetInvocations).Count -gt 0) `
        "A change set with more constructs than the budget must still carry both kinds, not only the first."
    Assert-Replay ([bool]$budget.Truncated) `
        "A construct set that hit a cap must say so, because an accounting over it is not complete."

    # Breadth before depth. If the budget goes to whichever file sorts first,
    # a rule about tests is judged against no test anchor at all on a change
    # set where the tests sort last - and the row still reads as an answer.
    $manyFiles = @(1..6 | ForEach-Object {
            $index = $_
            $code = [System.Collections.Generic.List[string]]::new()
            [void]$code.Add('public class C')
            [void]$code.Add('{')
            foreach ($n in 1..25) {
                [void]$code.Add("    public void M$n()")
                [void]$code.Add('    {')
                [void]$code.Add('        Do(')
                [void]$code.Add("            x: $n);")
                [void]$code.Add('    }')
            }
            [void]$code.Add('}')
            @{ Path = ("src/f{0}.cs" -f $index); Lines = @($code.ToArray()); ChangedLines = @(1..$code.Count) }
        })
    $spread = Get-ReviewerChangedConstructs -Files $manyFiles
    $filesReached = @(@($spread.Constructs) | ForEach-Object { [string]$_.path } | Sort-Object -Unique)
    Assert-Replay (@($filesReached).Count -eq 6) `
        "Every changed file must contribute constructs when the budget is short, not just the ones that sort first (reached $(@($filesReached).Count) of 6)."
    Assert-Replay ([bool]$spread.Truncated) `
        "A construct set that could not carry every construct must say so."

    # A declaration's parameter list has a call's shape. Reading it as a call
    # invents violations of a rule about how arguments are PASSED, and every
    # replay so far produced candidates on signatures that cross-verification
    # then threw out one at a time.
    $signature = Get-Constructs -Code @(
        'public class C', '{', '    public void Configure(', '        string first,', '        int second)',
        '    {', '        Apply(', '            first,', '            second);', '    }', '}')
    $signatureCalls = @(@($signature.Constructs) | Where-Object { [string]$_.kind -ceq "invocation" })
    Assert-Replay (@($signatureCalls).Count -eq 1 -and [string]@($signatureCalls)[0].name -ceq "Apply") `
        "A multi-line declaration signature must not be enumerated as a call (got $(@($signatureCalls | ForEach-Object { $_.name }) -join ','))."
    $signatureDeclarations = @(@($signature.Constructs) | Where-Object { [string]$_.kind -ceq "declaration" -and [string]$_.name -ceq "Configure" })
    Assert-Replay (@($signatureDeclarations).Count -eq 1) `
        "The declaration itself must still be enumerated, as a declaration."

    # Ids are a function of the change set alone, so an anchor means the same
    # thing on every run.
    $twice = Get-Constructs -Code @('public void T()', '{', '    A(', '        x: 1);', '    B(', '        y: 2);', '}')
    $again = Get-Constructs -Code @('public void T()', '{', '    A(', '        x: 1);', '    B(', '        y: 2);', '}')
    Assert-Replay ((@($twice.Constructs | ForEach-Object { $_.constructId }) -join ',') -ceq (@($again.Constructs | ForEach-Object { $_.constructId }) -join ',')) `
        "Construct ids must be deterministic for the same change set."
    # The specialist writes the largest hand-built marker this agent produces,
    # and a model that restates it while paraphrasing one sentence has emitted
    # two markers that disagree. That is a formatting slip on top of work that
    # was done, and it gets exactly the allowance a generalist pass gets - and
    # exactly the same refusal to retry a timeout or a nonzero exit.
    $reviewerText = [IO.File]::ReadAllText((Join-Path $RepoRoot "src\Agents\reviewer\Start-ReviewerAgent.ps1"))
    Assert-Replay ($reviewerText -match 'convention-specialist-marker-retry') `
        "An unusable specialist marker must be retried once and the retry recorded."
    $retryBlock = [regex]::Match($reviewerText,
        '(?s)for \(\$specialistAttempt = 1.*?\n            \}\r?\n            \$markerFailure')
    Assert-Replay ($retryBlock.Success) "The specialist launch must sit inside the retry loop."
    Assert-Replay ($retryBlock.Value -match '\$nonce = New-AgentNonce') `
        "Each specialist attempt must mint a fresh nonce, so the retry is a new request rather than a second answer to the first."
    Assert-Replay ($retryBlock.Value -match 'if \(\$processFailure\) \{ throw \$processFailure \}') `
        "A timeout or nonzero exit must still throw from inside the loop rather than be retried."
    Assert-Replay ($retryBlock.Value -match 'if \(\$forbiddenRequestedTools\.Count -gt 0\)') `
        "The forbidden-tool check must run on every attempt, not only the first."
    Assert-Replay ($retryBlock.Value -match 'convention-specialist-output-overflow') `
        "An answer over the output cap must be retried once too: it is a model talking too much, not work that was not done."
    Assert-Replay ($reviewerText -match '\$script:ReviewerConventionSpecialistMaxOutputBytes = \d+') `
        "The specialist output cap must be a named bound rather than a literal buried in a comparison."
    $overflowThrow = [regex]::Match($retryBlock.Value,
        '(?s)if \(\$specialistAttempt -ge \$script:ReviewerConventionSpecialistMarkerRetryAttempts\) \{\r?\n\s*throw "Convention specialist output exceeded')
    Assert-Replay ($overflowThrow.Success) `
        "A final over-cap answer must still fail the pass rather than loop."

    Assert-Replay ($retryBlock.Value -match '\$script:ReviewerConventionSpecialistMarkerRetryAttempts') `
        "The specialist must use its own retry budget, not the generalist's."
    Assert-Replay ($reviewerText -match '\$script:ReviewerConventionSpecialistMarkerRetryAttempts = 3') `
        "The specialist retry budget must be a named bound."
    Assert-Replay ($retryBlock.Value -notmatch '\$script:ReviewerMarkerRetryAttempts') `
        "No path in the specialist loop may fall back to the generalist retry budget."
    # The overflow retry must not run ahead of the checks that must never be
    # retried, or a run that timed out, modified a file or asked for a forbidden
    # tool while ALSO overflowing gets a quiet second chance and its evidence
    # overwritten.
    $overflowAt = $retryBlock.Value.IndexOf('convention-specialist-output-overflow')
    $failureAt = $retryBlock.Value.IndexOf('if ($processFailure) { throw $processFailure }')
    $forbiddenAt = $retryBlock.Value.IndexOf('Convention specialist requested forbidden tool(s)')
    $modifiedAt = $retryBlock.Value.IndexOf('reported modified files despite its read-only grant')
    Assert-Replay ($overflowAt -gt $failureAt -and $overflowAt -gt $forbiddenAt -and $overflowAt -gt $modifiedAt) `
        "The output-overflow retry must run after the timeout, modified-file and forbidden-tool checks, never before them."
    Assert-Replay ($retryBlock.Value -match '\$toolAudit\.requestedTools = @\(\)') `
        "Each attempt must reset the tool audit, so a failed attempt's requests are neither reported nor hidden by a quieter retry."

    # -- 11. The replay tool grant -------------------------------------------    # Extracted from the reviewer's own source and evaluated here, because the
    # claim "the model has no usable tool in replay" is otherwise a comment.
    Write-Host "11/11 replay tool grant" -ForegroundColor Cyan
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
