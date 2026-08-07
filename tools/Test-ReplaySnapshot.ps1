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
    Write-Host "1/13 shipped synthetic snapshot" -ForegroundColor Cyan
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
    Write-Host "2/13 served responses keep the live shapes" -ForegroundColor Cyan
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
    Write-Host "3/13 absent reads, writes, and closed sessions fail closed" -ForegroundColor Cyan
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
    Write-Host "4/13 tamper, stale binding, and missing resource" -ForegroundColor Cyan
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
    Write-Host "5/13 path attacks" -ForegroundColor Cyan
    foreach ($name in @("..", "..\other", "a/b", "C:\windows", "with:stream")) {
        Assert-ReplayThrows { New-AgentReplaySnapshot -ReplayRoot $fixtureRoot -SnapshotName $name } `
            "Snapshot name '$name' must be refused BY THE NAME PATTERN, not incidentally by failing to resolve." `
            -Match "must be a single path-free name"
    }
    Assert-ReplayThrows { New-AgentReplaySnapshot -ReplayRoot $fixtureRoot -SnapshotName "" } `
        "An empty snapshot name must be refused."
    # A trailing newline is not part of a name. .NET's `$` matches before a
    # final linefeed, so an exact-shape pattern anchored with `$` quietly
    # accepts one.
    Assert-ReplayThrows { New-AgentReplaySnapshot -ReplayRoot $fixtureRoot -SnapshotName "good`n" } `
        "A snapshot name with a trailing newline must be refused by the pattern." `
        -Match "must be a single path-free name"
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
    Write-Host "6/13 a snapshot may only carry reads" -ForegroundColor Cyan
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
    Write-Host "7/13 canonical form is ordinal and host-independent" -ForegroundColor Cyan
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
    Write-Host "8/13 rule-coverage accounting" -ForegroundColor Cyan
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
            [string]$NotInReach = "", [string]$Unknown = ""
        )
        # `Checked` here means "weighed against the rule", which the partition
        # splits into violating and compliant. Whatever the test names as
        # violating is removed from the compliant list so the four stay
        # disjoint, exactly as a real row must.
        $violatingIds = @(@($Violating -split ',') | Where-Object { $_ })
        $unknownIds = @(@($Unknown -split ',') | Where-Object { $_ })
        $compliantIds = @(@($Checked -split ',') | Where-Object {
                $_ -and $violatingIds -cnotcontains $_ -and $unknownIds -cnotcontains $_
            })
        return [pscustomobject][ordered]@{
            ruleRef = $Ref; ruleSourceSha256 = $Sha; ruleQuote = $Quote; status = $Status
            scope = $Scope; violatingConstructs = $Violating
            compliantConstructs = ($compliantIds -join ',')
            notInReachConstructs = $NotInReach; unknownConstructs = $Unknown
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
        [string]@($partialScope.Rows)[0].degradedReason -match "no verdict") `
        "A row that gives a verdict for only some of the anchors in its scope must degrade to unknown."
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

    # The asserted status no longer decides anything: the anchors do. A row that
    # says "violation" over a partition with nothing violating is reporting a
    # finding it did not anchor, and the wrapper reads the anchors instead - and
    # says that it had to.
    $unnamedViolation = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($unnamedViolation.Rows)[0].status -ceq "compliant" -and
        [string]@($unnamedViolation.Rows)[0].degradedReason -match "anchors decide") `
        "A row claiming a violation it anchored nowhere must take the status its own anchors give, and the disagreement must be recorded."

    $violatingWithoutViolation = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Violating "mi0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($violatingWithoutViolation.Rows)[0].status -ceq "violation" -and
        [string]@($violatingWithoutViolation.Rows)[0].degradedReason -match "anchors decide") `
        "A row calling an anchor violating while reporting itself compliant must become a violation: the anchors decide."

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

    # A rule that governs no construct kind must still say WHICH anchors it does
    # not reach - which means naming the kinds those anchors belong to. `none`
    # plus one id was a clean row that had weighed nothing.
    $outsideScope = Invoke-Coverage -WithConstructs @(
        [pscustomobject][ordered]@{ constructId = "mi0"; kind = "invocation"; path = "src/a.cs"; line = 5; endLine = 5 }
        [pscustomobject][ordered]@{ constructId = "dc0"; kind = "declaration"; path = "src/a.cs"; line = 9; endLine = 9 }
    ) -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "notApplicable" -Scope "none" -Checked "" -NotInReach "mi0,dc0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope "invocation" -Checked "mi0")
    )
    Assert-Replay ([string]@($outsideScope.Rows)[0].status -ceq "unknown") `
        "A row that declares no construct kind must degrade, however many ids it puts out of reach."
    $namedKinds = Invoke-Coverage -WithConstructs @(
        [pscustomobject][ordered]@{ constructId = "mi0"; kind = "invocation"; path = "src/a.cs"; line = 5; endLine = 5 }
        [pscustomobject][ordered]@{ constructId = "dc0"; kind = "declaration"; path = "src/a.cs"; line = 9; endLine = 9 }
    ) -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "notApplicable" -Scope "invocation,declaration" -Checked "" -NotInReach "mi0,dc0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope "invocation" -Checked "mi0")
    )
    Assert-Replay ([string]@($namedKinds.Rows)[0].status -ceq "notApplicable" -and [bool]$namedKinds.Complete) `
        "Naming the kinds and ruling their anchors out of reach is the falsifiable way to say a rule reaches nothing."
    $strayOutOfReach = Invoke-Coverage -WithConstructs @(
        [pscustomobject][ordered]@{ constructId = "mi0"; kind = "invocation"; path = "src/a.cs"; line = 5; endLine = 5 }
        [pscustomobject][ordered]@{ constructId = "dc0"; kind = "declaration"; path = "src/a.cs"; line = 9; endLine = 9 }
    ) -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope "invocation" -Checked "mi0" -NotInReach "dc0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope "invocation" -Checked "mi0")
    )
    Assert-Replay ([string]@($strayOutOfReach.Rows)[0].status -ceq "unknown") `
        "Out of reach is a verdict about an anchor the row was asked about, not a bin for kinds it said it does not govern."
    $wrongKindChecked = Invoke-Coverage -WithConstructs @(
        [pscustomobject][ordered]@{ constructId = "mi0"; kind = "invocation"; path = "src/a.cs"; line = 5; endLine = 5 }
        [pscustomobject][ordered]@{ constructId = "dc0"; kind = "declaration"; path = "src/a.cs"; line = 9; endLine = 9 }
    ) -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope "invocation" -Checked "mi0,dc0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope "invocation" -Checked "mi0")
    )
    Assert-Replay ([string]@($wrongKindChecked.Rows)[0].status -ceq "unknown") `
        "Weighing a construct against a rule whose declared scope excludes it must still degrade."
    $ghostConstruct = Invoke-Coverage -WithConstructs @(
        [pscustomobject][ordered]@{ constructId = "mi0"; kind = "invocation"; path = "src/a.cs"; line = 5; endLine = 5 }
    ) -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope "invocation" -Checked "mi0" -NotInReach "dc7"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope "invocation" -Checked "mi0")
    )
    Assert-Replay ([string]@($ghostConstruct.Rows)[0].status -ceq "unknown") `
        "A construct id the wrapper never enumerated must degrade the row wherever it appears."

    $vacuous = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope "none" -Checked ""),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($vacuous.Rows)[0].status -ceq "unknown" -and -not [bool]$vacuous.Complete) `
        "A row claiming nothing was in reach while constructs exist must degrade, not pass as compliant."

    # "Not applicable" has to be earned against the anchors. An all-empty row is
    # unfalsifiable, and `notApplicable` is exactly the word a model reaches for
    # when it wants out - so it cannot also be the word that exempts it.
    $vacuousNotApplicable = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "notApplicable" -Scope "none" -Checked ""),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($vacuousNotApplicable.Rows)[0].status -ceq "unknown" -and
        -not [bool]$vacuousNotApplicable.Complete) `
        "A row that names no anchor at all must degrade even when it calls itself notApplicable."
    # The falsifiable way to say the same thing: name them, and put them out of
    # the rule's reach.
    $earnedNotApplicable = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "notApplicable" -Scope "invocation" -Checked "" -NotInReach "mi0,mi1"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant")
    )
    Assert-Replay ([string]@($earnedNotApplicable.Rows)[0].status -ceq "notApplicable" -and [bool]$earnedNotApplicable.Complete) `
        "A rule that reaches none of its anchors may say so, provided it says which anchors it means."

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

    # The partition is the mechanism. These are its edges.
    $threeAnchors = @(
        [pscustomobject][ordered]@{ constructId = "mi0"; kind = "invocation"; path = "src/a.cs"; line = 5; endLine = 8 }
        [pscustomobject][ordered]@{ constructId = "mi1"; kind = "invocation"; path = "src/a.cs"; line = 20; endLine = 24 }
        [pscustomobject][ordered]@{ constructId = "mi2"; kind = "invocation"; path = "src/a.cs"; line = 40; endLine = 44 }
    )
    function New-PartitionRow {
        param([string]$Ref, [string]$Sha, [string]$Status, [string]$Scope = "invocation",
            [string]$Violating = "", [string]$Compliant = "", [string]$NotInReach = "", [string]$Unknown = "",
            [string]$Candidate = "")
        return [pscustomobject][ordered]@{
            ruleRef = $Ref; ruleSourceSha256 = $Sha; ruleQuote = ""; status = $Status
            scope = $Scope; violatingConstructs = $Violating; compliantConstructs = $Compliant
            notInReachConstructs = $NotInReach; unknownConstructs = $Unknown
            codeEvidence = "evidence"; siblingStatus = "checked"; siblingEvidence = "sibling"
            candidateId = $Candidate; notes = "note"
        }
    }
    $filler = (New-PartitionRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Compliant "mi0-mi2")

    # One anchor left out of all four lists.
    $silentAnchor = Invoke-Coverage -WithConstructs $threeAnchors -Rows @(
        (New-PartitionRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Compliant "mi0,mi1"), $filler)
    Assert-Replay ([string]@($silentAnchor.Rows)[0].status -ceq "unknown" -and
        [string]@($silentAnchor.Rows)[0].degradedReason -match "mi2") `
        "An anchor with no verdict at all must degrade the row and be named."

    # One anchor in two lists.
    $twoVerdicts = Invoke-Coverage -WithConstructs $threeAnchors -Rows @(
        (New-PartitionRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Compliant "mi0-mi2" -NotInReach "mi1"), $filler)
    Assert-Replay ([string]@($twoVerdicts.Rows)[0].status -ceq "unknown" -and
        [string]@($twoVerdicts.Rows)[0].degradedReason -match "more than one verdict") `
        "An anchor given two verdicts must degrade the row."

    # A verdict on something that is not an anchor.
    $ghostVerdict = Invoke-Coverage -WithConstructs $threeAnchors -Rows @(
        (New-PartitionRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Compliant "mi0-mi2" -Unknown "mi9"), $filler)
    Assert-Replay ([string]@($ghostVerdict.Rows)[0].status -ceq "unknown") `
        "A verdict on an anchor the wrapper never enumerated must degrade the row."

    # The derived status, in each direction.
    $derivedViolation = Invoke-Coverage -WithConstructs $threeAnchors -Rows @(
        (New-PartitionRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Violating "mi1" -Compliant "mi0,mi2"), $filler)
    Assert-Replay ([string]@($derivedViolation.Rows)[0].status -ceq "violation") `
        "One violating anchor makes the row a violation whatever the row called itself."
    $derivedUnknown = Invoke-Coverage -WithConstructs $threeAnchors -Rows @(
        (New-PartitionRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Violating "mi1" -Compliant "mi0" -Unknown "mi2"), $filler)
    Assert-Replay ([string]@($derivedUnknown.Rows)[0].status -ceq "unknown") `
        "An anchor the row could not decide about outranks a violation: the row does not yet know its own answer."
    $derivedNotApplicable = Invoke-Coverage -WithConstructs $threeAnchors -Rows @(
        (New-PartitionRow -Ref "rs0" -Sha ("a" * 64) -Status "notApplicable" -NotInReach "mi0-mi2"), $filler)
    Assert-Replay ([string]@($derivedNotApplicable.Rows)[0].status -ceq "notApplicable" -and [bool]$derivedNotApplicable.Complete) `
        "A rule that reaches none of its anchors may say so and still be complete."
    $derivedCompliant = Invoke-Coverage -WithConstructs $threeAnchors -Rows @(
        (New-PartitionRow -Ref "rs0" -Sha ("a" * 64) -Status "unknown" -Compliant "mi0-mi2"), $filler)
    Assert-Replay ([string]@($derivedCompliant.Rows)[0].status -ceq "compliant") `
        "A row that weighed every anchor and found none violating is compliant, whatever it called itself."

    # Narrowing is allowed; narrowing to nothing is not.
    $narrowedPartition = Invoke-Coverage -WithConstructs $threeAnchors -Rows @(
        (New-PartitionRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Violating "mi2" -NotInReach "mi0,mi1" -Candidate "x"), $filler)
    Assert-Replay ([string]@($narrowedPartition.Rows)[0].status -ceq "violation") `
        "A row may rule most anchors out of reach and still convict the one the rule does reach."

    # A row that names a violating anchor must reach the unemitted record even
    # when something else made the row unknown - otherwise one undecided anchor
    # erases a violation the row stated outright.
    $violationUnderUnknown = Invoke-Coverage -WithConstructs $threeAnchors -Rows @(
        (New-PartitionRow -Ref "rs0" -Sha ("a" * 64) -Status "unknown" -Violating "mi0" -Compliant "mi1" -Unknown "mi2"), $filler)
    Assert-Replay ([string]@($violationUnderUnknown.Rows)[0].status -ceq "unknown" -and
        @($violationUnderUnknown.UnemittedViolations).Count -eq 1) `
        "A violation the row named must be recorded even when an undecided anchor makes the row unknown."

    # An accounting where every row ruled every anchor out of reach is spelled
    # correctly and has looked at nothing. "Complete: True" is the one line a
    # reader trusts, so it must not sit on top of that.
    $everythingOutOfReach = Invoke-Coverage -WithConstructs $threeAnchors -Rows @(
        (New-PartitionRow -Ref "rs0" -Sha ("a" * 64) -Status "notApplicable" -NotInReach "mi0-mi2"),
        (New-PartitionRow -Ref "rs1" -Sha ("b" * 64) -Status "notApplicable" -NotInReach "mi0-mi2"))
    Assert-Replay ([string]@($everythingOutOfReach.Rows)[0].status -ceq "notApplicable" -and
        -not [bool]$everythingOutOfReach.Complete -and
        [int]$everythingOutOfReach.CheckedConstructCount -eq 0) `
        "A checklist whose every row weighed nothing must not report itself complete, however correct each row is."
    # A row over an empty change set is a different thing and stays complete.
    # Called directly: an empty array passed through the helper's optional
    # parameter binds as $null and falls back to the default construct set.
    $noConstructsAtAll = Resolve-ReviewerConventionSpecialistRuleCoverage -ResolvedSources $sources `
        -AcceptedCandidates @() -Constructs @() -Rows @(
        (New-PartitionRow -Ref "rs0" -Sha ("a" * 64) -Status "notApplicable" -Scope "none"),
        (New-PartitionRow -Ref "rs1" -Sha ("b" * 64) -Status "notApplicable" -Scope "none"))
    Assert-Replay ([bool]$noConstructsAtAll.Complete) `
        "With no anchors enumerated at all there is nothing to weigh, and the accounting is complete over it."

    $index = Get-ReviewerConventionSpecialistChangedFileIndex -ChangeEntries @(        [pscustomobject][ordered]@{ Path = "src/z.cs"; Role = "current" },
        [pscustomobject][ordered]@{ Path = "src/a.cs"; Role = "current" },
        [pscustomobject][ordered]@{ Path = "src/gone.cs"; Role = "original" }
    )
    Assert-Replay (@($index).Count -eq 2 -and [string]@($index)[0].path -ceq "src/a.cs" -and [string]@($index)[0].anchorId -ceq "cf0") `
        "The changed-file anchor index must be ordinal, deduplicated, and current-role only."

    # -- 9. Schema bounds ------------------------------------------------------
    Write-Host "9/13 schema bounds" -ForegroundColor Cyan
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
                status = "notApplicable"; scope = "none"; violatingConstructs = ""; compliantConstructs = ""; notInReachConstructs = ""; unknownConstructs = ""
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
    # The worst case is an ALTERNATING partition, not a contiguous one. Ranges
    # only compress runs, and a partition's verdicts interleave: measuring
    # `mi0-mi119` and calling it "every id the enumerator can produce" is
    # measuring the best case and reporting it as the bound.
    $widestIdList = 0
    foreach ($prefix in @("mi", "dc", "cm", "as")) {
        $kindIds = [string[]]@(0..($script:ReviewerConstructMaxTotal - 1) | ForEach-Object { "$prefix$_" })
        $widestIdList += (Get-ReviewerConstructIdRanges -Ids $kindIds).Length + 1
    }
    $alternating = [string[]]@(0..($script:ReviewerConstructMaxTotal - 1) |
        Where-Object { $_ % 2 -eq 0 } | ForEach-Object { "mi$_" })
    $worstOneList = (Get-ReviewerConstructIdRanges -Ids $alternating).Length
    foreach ($verdict in @("violatingConstructs", "compliantConstructs", "notInReachConstructs", "unknownConstructs")) {
        $cap = [int]$coverageSpec.Item.Fields[$verdict].MaxLength
        Assert-Replay ($widestIdList -le $cap) `
            "The '$verdict' field ($cap chars) must hold every id the enumerator can produce ($widestIdList chars)."
        Assert-Replay ($worstOneList -le $cap) `
            "The '$verdict' field ($cap chars) must hold an alternating partition of the largest construct set ($worstOneList chars) - ranges do not compress a verdict that changes every anchor."
        Assert-Replay (-not ($coverageSpec.Item.Fields[$verdict].ContainsKey("Truncate") -and
                [bool]$coverageSpec.Item.Fields[$verdict].Truncate)) `
            "An id list must never be shortened: half a verdict set is worse than none."
    }
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
    foreach ($strict in @("ruleQuote", "violatingConstructs", "compliantConstructs", "notInReachConstructs", "unknownConstructs")) {
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

    # The verifier's source-read ceiling. A number in a comment is not a bound;
    # what makes it one is that the reader's own parameter refuses anything
    # larger, and that the constant sits exactly at that refusal point.
    $verifierCeiling = 262144
    $reviewerSourceText = [IO.File]::ReadAllText((Join-Path $RepoRoot "src\Agents\reviewer\Start-ReviewerAgent.ps1"), $utf8)
    $vt = $null; $ve = $null
    $reviewerConstAst = [Management.Automation.Language.Parser]::ParseInput($reviewerSourceText, [ref]$vt, [ref]$ve)
    $constants = @{}
    foreach ($assignment in $reviewerConstAst.FindAll({
                param($c)
                if ($c -isnot [Management.Automation.Language.AssignmentStatementAst]) { return $false }
                return (([string]$c.Left.Extent.Text) -cin @('$script:ReviewerVerificationMaxSourceFileBytes', '$script:ReviewerAuthoritativeMaxTotalBytes'))
            }, $true)) {
        $constants[([string]$assignment.Left.Extent.Text)] = [int](& ([scriptblock]::Create($assignment.Right.Extent.Text)))
    }
    Assert-Replay ($constants['$script:ReviewerVerificationMaxSourceFileBytes'] -eq $verifierCeiling) `
        "The verifier source-read ceiling must be the declared $verifierCeiling bytes."
    $readerNode = $reviewerConstAst.FindAll({
            param($c)
            $c -is [Management.Automation.Language.FunctionDefinitionAst] -and $c.Name -ceq "Get-ReviewerFactSourceFile"
        }, $true) | Select-Object -First 1
    $maxBytesParam = @($readerNode.Body.ParamBlock.Parameters | Where-Object { [string]$_.Name.Extent.Text -ceq '$MaxBytes' })
    $range = @($maxBytesParam[0].Attributes | Where-Object { $_.TypeName.Name -ceq "ValidateRange" })
    $rangeMax = [int](& ([scriptblock]::Create([string]$range[0].PositionalArguments[1].Extent.Text)))
    Assert-Replay ($rangeMax -eq $verifierCeiling) `
        "The reader's own ValidateRange must clamp at the same $verifierCeiling bytes, so the constant cannot be raised alone."
    # And the authoritative-rule reads must not have been widened along with it.
    Assert-Replay ($constants['$script:ReviewerAuthoritativeMaxTotalBytes'] -le $verifierCeiling) `
        "Raising the verifier's per-file read must not widen the authoritative-rule total."

    # The decoder is where the bound is actually enforced: exactly at it, one
    # byte over it, and nothing at all.
    function New-ResourceResult {
        param([string]$Text, [string]$Uri = "/src/a.cs")
        # The wire shape is a base64 blob, exactly as the provider sends it.
        return [pscustomobject][ordered]@{
            content = @([pscustomobject][ordered]@{
                    type = "resource"
                    resource = [pscustomobject][ordered]@{
                        uri = $Uri; mimeType = "text/plain"
                        blob = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($Text))
                    }
                })
        }
    }
    $atBound = New-ResourceResult -Text ("a" * $verifierCeiling)
    $decoded = ConvertFrom-AgentMcpResourceContent -ToolResult $atBound -ExpectedUri "/src/a.cs" `
        -MaxBytes $verifierCeiling -AllowedMimeTypes @("text/plain")
    Assert-Replay ([int]$decoded.ByteLength -eq $verifierCeiling) `
        "A file of exactly the ceiling must be readable; an off-by-one here silently drops real source."
    Assert-ReplayThrows {
        ConvertFrom-AgentMcpResourceContent -ToolResult (New-ResourceResult -Text ("a" * ($verifierCeiling + 1))) `
            -ExpectedUri "/src/a.cs" -MaxBytes $verifierCeiling -AllowedMimeTypes @("text/plain")
    } "One byte over the ceiling must be refused, not truncated." -Match "decoded to 262145 bytes"
    Assert-ReplayThrows {
        ConvertFrom-AgentMcpResourceContent -ToolResult ([pscustomobject][ordered]@{ content = @() }) `
            -ExpectedUri "/src/a.cs" -MaxBytes $verifierCeiling -AllowedMimeTypes @("text/plain")
    } "A response with no content must be refused rather than read as an empty file."

    # -- 10. changed-construct enumeration ------------------------------------
    # The generic half of the calibration: what the wrapper can establish about
    # a change set WITHOUT knowing the language's testing framework, its
    # attributes, or anything about the repository it came from.
    Write-Host "10/13 changed-construct enumeration" -ForegroundColor Cyan
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
    Assert-Replay (@(@($second)[0].absentHere) -ccontains "Owner" -and @(@($second)[0].absentHere) -cnotcontains "TestMethod") `
        "A changed declaration must report which attributes the file's unchanged declarations carry and it does not."
    $frequency = @(@($declarations.Files)[0].attributeFrequency | Where-Object { [string]$_.attribute -ceq "Owner" })
    Assert-Replay (@($frequency).Count -eq 1 -and [int]@($frequency)[0].declarations -eq 1) `
        "The per-file attribute count must say how much precedent there actually is."
    $noPrecedent = Get-Constructs -Code @(
        'public class C', '{', '    [TestMethod]', '    public void First() { }',
        '', '    [TestMethod]', '    public void Second() { }', '}') -Changed @(6, 7)
    Assert-Replay (@(@($noPrecedent.Files)[0].attributeFrequency | Where-Object { [string]$_.attribute -ceq "Owner" }).Count -eq 0) `
        "A file where the attribute never appears must report no precedent for it at all."
    $noPrecedentDeclaration = @(@($noPrecedent.Constructs) | Where-Object { [string]$_.kind -ceq "declaration" })[0]
    Assert-Replay (@($noPrecedentDeclaration.absentHere) -cnotcontains "Owner") `
        "A file where nobody uses the attribute must not report it as absent HERE: there is no local precedent to be missing."

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

    # The lexical cases a rule about argument naming turns on, each with the
    # answer stated rather than implied. Synthetic code only.
    $lexCases = @(
        @{ Name = "named then positional message"; Naming = "nnp"; Args = 3; Code = @(
                'public void T()', '{', '    Assert.AreEqual(', '        expected: a,', '        actual: b,',
                '        "a message");', '}') }
        @{ Name = "every argument named"; Naming = "nnn"; Args = 3; Code = @(
                'public void T()', '{', '    Assert.AreEqual(', '        expected: a,', '        actual: b,',
                '        message: "a message");', '}') }
        @{ Name = "single positional lambda"; Naming = "p"; Args = 1; Code = @(
                'public void T()', '{', '    Assert.ThrowsException<Exception>(', '        () => Run(x));', '}') }
        @{ Name = "a named lambda whose body contains a comma"; Naming = "nn"; Args = 2; Code = @(
                'public void T()', '{', '    Register(', '        name: "x",', '        factory: () => { Build(a, b); });', '}') }
        @{ Name = "a positional lambda beside a named argument"; Naming = "np"; Args = 2; Code = @(
                'public void T()', '{', '    Register(', '        name: "x",', '        () => { Build(a, b); });', '}') }
        @{ Name = "nested call as one argument"; Naming = "pp"; Args = 2; Code = @(
                'public void T()', '{', '    Outer(', '        Inner(a, b),', '        c);', '}') }
        @{ Name = "generic argument list is not arguments"; Naming = "nn"; Args = 2; Code = @(
                'public void T()', '{', '    Build<Alpha, Beta>(', '        left: 1,', '        right: 2);', '}') }
        @{ Name = "a conditional and a string full of commas and colons"; Naming = "nn"; Args = 2; Code = @(
                'public void T()', '{', '    Log(', '        level: 1,', '        text: 2 == 2 ? "a, b: c" : "d");', '}') }
        @{ Name = "a bare conditional argument"; Naming = "np"; Args = 2; Code = @(
                'public void T()', '{', '    Log(', '        level: 1,', '        flag ? "a, b: c" : "d");', '}') }
        @{ Name = "comma inside a trailing comment"; Naming = "nn"; Args = 2; Code = @(
                'public void T()', '{', '    Log(', '        level: 1, // one, two', '        text: "x");', '}') }
        @{ Name = "single string literal argument"; Naming = "p"; Args = 1; Code = @(
                'public void T()', '{', '    Log(', '        "a message");', '}') }
    )
    foreach ($case in $lexCases) {
        $result = Get-Constructs -Code $case.Code
        $call = Get-Invocation -Result $result
        Assert-Replay ($null -ne $call -and [string]$call.status -ceq "known" -and
            [int]$call.argumentCount -eq [int]$case.Args -and [string]$call.argumentNaming -ceq [string]$case.Naming) `
            ("A multi-line call with {0} must read as {1} argument(s) naming '{2}' (got {3}/'{4}' status '{5}')." -f `
                $case.Name, $case.Args, $case.Naming,
            $(if ($call) { $call.argumentCount } else { "no call" }),
            $(if ($call) { $call.argumentNaming } else { "" }),
            $(if ($call) { $call.status } else { "" }))
    }
    # And the ones where the honest answer is "I do not know".
    foreach ($unclear in @(
            @{ Name = "a call that never closes"; Code = @('public void T()', '{', '    Assert.AreEqual(', '        expected: 1,') },
            @{ Name = "an argument list whose angle brackets never balance"; Code = @(
                    'public void T()', '{', '    Weird(', '        left: a<b,', '        right: c);', '}') })) {
        $result = Get-Constructs -Code $unclear.Code
        $call = Get-Invocation -Result $result
        Assert-Replay ($null -eq $call -or [string]$call.status -ceq "unknown") `
            "$($unclear.Name) must be reported unknown rather than given an argument shape."
    }

    # A file whose language this enumerator does not model must be reported as
    # not understood, not enumerated wrongly. It read `# a comment mentioning
    # Log(` as a call and called every PowerShell argument positional, which is
    # exactly the fact a naming rule consumes.
    $unmodelled = Get-ReviewerChangedConstructs -Files @(@{
            Path = "tools/Thing.ps1"
            Lines = @('# We call Log(', '#   "the message") and then move on.', 'Get-Thing -Name $n -Value (Compute $x,', '    $y)')
            ChangedLines = @(1, 2, 3, 4)
        })
    Assert-Replay (@($unmodelled.Constructs).Count -eq 0) `
        "A file in a language this enumerator does not model must yield no constructs (got $(@($unmodelled.Constructs).Count))."
    # The backtick is why the modelled list is short: it quotes a template
    # literal in one language, a raw string in another, and an identifier in a
    # third. A Kotlin test named in backticks was being read as a call.
    foreach ($backticked in @("src/WidgetTest.kt", "src/thing.go", "src/q.ts")) {
        Assert-Replay (-not (Test-ReviewerConstructModelledFile -Path $backticked)) `
            "'$backticked' uses the backtick for something this lexer does not model and must not be enumerated."
    }
    Assert-Replay ((Test-ReviewerConstructModelledFile -Path "src/Widget.cs") -and
        (Test-ReviewerConstructModelledFile -Path "src/Widget.java")) `
        "A language whose lexis this enumerator does model must still be enumerated."
    $strayBacktick = Get-ReviewerChangedConstructs -Files @(@{
            Path = "src/Odd.cs"; Lines = @('public void T()', '{', '    var s = `weird`;', '    Log(', '        text: 1);', '}')
            ChangedLines = @(1, 2, 3, 4, 5, 6)
        })
    Assert-Replay (@($strayBacktick.PartiallyUnderstoodFiles) -ccontains "src/Odd.cs") `
        "A backtick in a language that has no use for one means the file is not what it claims, and must be reported as not understood."
    Assert-Replay (@($unmodelled.PartiallyUnderstoodFiles) -ccontains "tools/Thing.ps1") `
        "An unmodelled file must be reported as only partly understood, which is what makes the accounting say it did not cover the change set."
    $reviewerConstructWiring = [IO.File]::ReadAllText((Join-Path $RepoRoot "src\Agents\reviewer\Start-ReviewerAgent.ps1"))
    Assert-Replay ($reviewerConstructWiring -match '\$constructsIncomplete = \(\[bool\]\$constructResult\.Truncated -or @\(\$constructResult\.PartiallyUnderstoodFiles\)\.Count -gt 0\)') `
        "A partly understood file must feed the accounting's incompleteness, or reporting it changes nothing."
    $modelled = Get-ReviewerChangedConstructs -Files @(@{
            Path = "src/Thing.cs"; Lines = @('public void T()', '{', '    Log(', '        text: 1);', '}'); ChangedLines = @(1, 2, 3, 4, 5)
        })
    Assert-Replay (@($modelled.Constructs).Count -gt 0 -and @($modelled.PartiallyUnderstoodFiles).Count -eq 0) `
        "A file in a language it does model must still be enumerated."

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

    # The verifier cuts seven lines out of a changed file to check a candidate
    # against. The bound on what it may OPEN to do that is not the bound on a
    # document: a source file larger than the document bound yielded no hunk,
    # and the verifier was then asked to confirm a finding having been shown
    # nothing - which it correctly refused, losing a real finding to a number.
    $reviewerText = [IO.File]::ReadAllText((Join-Path $RepoRoot "src\Agents\reviewer\Start-ReviewerAgent.ps1"))
    $hunkFunction = [regex]::Match($reviewerText, '(?s)function Get-ReviewerVerificationSourceHunks \{.*?\n\}')
    Assert-Replay ($hunkFunction.Success) "The verifier source-hunk builder must be findable."
    Assert-Replay ($hunkFunction.Value -match '-MaxBytes \$script:ReviewerVerificationMaxSourceFileBytes') `
        "The verifier's file read must use its own named bound, not a literal shared with the document bound."
    $verifierBound = [regex]::Match($reviewerText, '\$script:ReviewerVerificationMaxSourceFileBytes = (\d+)')
    $documentBound = [regex]::Match($reviewerText, '\$script:ReviewerAuthoritativeMaxFileBytes = (\d+)')
    Assert-Replay ($verifierBound.Success -and $documentBound.Success -and
        [int]$verifierBound.Groups[1].Value -gt [int]$documentBound.Groups[1].Value) `
        "The verifier must be able to open a source file larger than an authoritative document."
    # And it must be a bound the reader will actually accept. Setting it above
    # the reader's own ValidateRange does not widen anything - it makes EVERY
    # hunk fail, which is how this was found: one file had been unreadable, and
    # for one run all of them were.
    $readerRange = [regex]::Match($reviewerText,
        '(?s)function Get-ReviewerFactSourceFile \{.*?\[ValidateRange\(1, (\d+)\)\]\[int\]\$MaxBytes')
    Assert-Replay ($readerRange.Success) "The fact-source reader's byte range must be findable."
    Assert-Replay ([int]$verifierBound.Groups[1].Value -le [int]$readerRange.Groups[1].Value) `
        "The verifier's read bound ($($verifierBound.Groups[1].Value)) must be within what the reader accepts ($($readerRange.Groups[1].Value)), or every hunk fails instead of one."
    Assert-Replay ($hunkFunction.Value -match '\$line - 3' -and $hunkFunction.Value -match '\$line \+ 3') `
        "Raising the read bound must not widen what a model is shown: the hunk stays seven lines."

    # Enumeration runs on the mandatory path of every review, before any model.
    # It once rebuilt a delivered-line set on every line of every file, three
    # times over, and took twenty-seven seconds on one ordinary file - a stall
    # with no error and no truncation flag to show for it.
    $constructSource = [IO.File]::ReadAllText((Join-Path $RepoRoot "src\Agents\reviewer\ChangedConstructs.ps1"))
    Assert-Replay ($constructSource -match '\$index\[\$position\] = Get-ReviewerConstructDeclarationAt') `
        "The declaration index must be built by one pass over the file."
    Assert-Replay ($constructSource -notmatch 'Get-ReviewerConstructDeclarationAt -MaskedLines \$MaskedLines -Index \$scan') `
        "Nothing may recognise a line again once the index exists."
    # A caller that supplies no index must still get the signature guard, not a
    # bounds error and not a silently disabled check.
    $noIndex = Get-ReviewerChangedInvocations -Path "src/a.cs" `
        -Lines @('public void Configure(', '    string first,', '    int second)', '{', '}') `
        -ChangedLines @(1, 2, 3) `
        -MaskedLines @('public void Configure(', '    string first,', '    int second)', '{', '}') `
        -DeliveredLines @()
    Assert-Replay (@($noIndex.Constructs).Count -eq 0) `
        "Without a prebuilt index the invocation walk must recognise the signature itself, not fall over or wave it through."
    $bigLines = [System.Collections.Generic.List[string]]::new()
    [void]$bigLines.Add('public class C')
    [void]$bigLines.Add('{')
    foreach ($n in 1..800) {
        [void]$bigLines.Add('    [TestMethod]')
        [void]$bigLines.Add("    public void M$n() { }")
        [void]$bigLines.Add('')
    }
    [void]$bigLines.Add('}')
    $bigCode = @($bigLines.ToArray())
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $bigResult = Get-ReviewerChangedConstructs -Files @(@{
            Path = "src/Big.cs"; Lines = $bigCode; ChangedLines = @(4, 7, 10)
            DeliveredLines = @(1..$bigCode.Count)
        })
    $watch.Stop()
    Assert-Replay (@($bigResult.Constructs).Count -gt 0) "A large delivered file must still yield constructs."
    Assert-Replay ($watch.ElapsedMilliseconds -lt 20000) `
        "Enumerating a $($bigCode.Count)-line fully delivered file took $($watch.ElapsedMilliseconds) ms; it runs before every review and must not become a stall."

    # And the SPARSE shape, which the fully delivered case above cannot reach: a
    # long file with a three-line edit at the bottom. Every gap line used to pay
    # a full parameter bind of the whole masked array, so an edit near the end
    # of a file cost the whole file - ten seconds for one, minutes for a change
    # set. The declaration index refuses gap and blank lines before the call now.
    $sparseLines = New-Object string[] 12000
    for ($i = 0; $i -lt 12000; $i++) { $sparseLines[$i] = "" }
    $sparseLines[11996] = "public void M() {"
    $sparseLines[11997] = "    Do(x: 1);"
    $sparseLines[11998] = "}"
    $sparseWatch = [Diagnostics.Stopwatch]::StartNew()
    $sparseResult = Get-ReviewerChangedConstructs -Files @(@{
            Path = "src/Sparse.cs"; Lines = $sparseLines
            ChangedLines = @(11997, 11998, 11999); DeliveredLines = @(11997, 11998, 11999)
        })
    $sparseWatch.Stop()
    Assert-Replay (@($sparseResult.Constructs).Count -gt 0) `
        "A sparse image with a real declaration at the bottom must still yield a construct."
    Assert-Replay ($sparseWatch.ElapsedMilliseconds -lt 8000) `
        "A 12000-line sparse image with three delivered lines took $($sparseWatch.ElapsedMilliseconds) ms; the undelivered gap must not be paid for line by line."

    # Truncation must never be a way past a pattern. A field carrying both would
    # otherwise accept a string whose only violation sat past the cut.
    $patterned = @{ Type = "string"; MaxLength = 20; Truncate = $true; Pattern = '^[\x20-\x7E]+$' }
    $hiddenViolation = Test-MarkerField -Spec $patterned -Value ("ascii ascii ascii ok" + [string][char]0x0416)
    Assert-Replay (-not [bool]$hiddenViolation.Ok) `
        "A pattern must be checked against the text as it arrived, not against the shortened copy."
    $shortenable = Test-MarkerField -Spec $patterned -Value ("abcdefghijklmnopqrstuvwxyz")
    Assert-Replay ([bool]$shortenable.Ok -and ([string]$shortenable.Value).Length -le 20) `
        "A long but otherwise valid string must still be shortened rather than rejected."

    # The wrapper cuts one string itself, when it records a violation the pass
    # never emitted. That cut needs the same surrogate guard.
    $specialistText = [IO.File]::ReadAllText((Join-Path $RepoRoot "src\Agents\reviewer\ConventionSpecialist.ps1"))
    Assert-Replay ($specialistText -notmatch '\$detail\.Substring\(0, 800\)') `
        "The unemitted-violation detail must not be cut with a bare Substring."
    $shortened = Get-ReviewerConventionSpecialistShortened -Text (("a" * 799) + [string][char]0xD83D + [string][char]0xDE00) -MaxLength 800
    $strict = [System.Text.UTF8Encoding]::new($false, $true)
    $encodedDetail = $null
    try { $encodedDetail = $strict.GetBytes($shortened) } catch { $encodedDetail = $null }
    Assert-Replay ($null -ne $encodedDetail) `
        "Shortening the unemitted-violation detail must never leave half a surrogate pair behind."

    # -- 11. The replay tool grant -------------------------------------------    # Extracted from the reviewer's own source and evaluated here, because the
    # claim "the model has no usable tool in replay" is otherwise a comment.
    Write-Host "11/13 replay tool grant" -ForegroundColor Cyan
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
    $syntheticCeilings = @(
        @{ Name = "generalist"; Tools = @("read", "ado(repo_pull_request)", "ado(repo_file)") },
        @{ Name = "specialist"; Tools = @("ado(repo_pull_request)", "ado(repo_file)") },
        @{ Name = "verifier"; Tools = @("ado(repo_pull_request)", "ado(repo_file)") }
    )
    # And then the REAL ones. The synthetic pass proves the functions behave;
    # only the shipped ceilings prove the agent does. Lifted from the reviewer's
    # own source by AST so the test cannot drift from what it ships.
    $realCeilings = @()
    $realAllowCeiling = @()
    $realMandatoryDeny = @()
    foreach ($assignment in $reviewerAst.FindAll({
                param($candidate)
                if ($candidate -isnot [Management.Automation.Language.AssignmentStatementAst]) { return $false }
                $target = [string]$candidate.Left.Extent.Text
                return ($target -clike '$script:Reviewer*ToolCeiling' -or $target -ceq '$script:ReviewerMandatoryDenyTools')
            }, $true)) {
        $name = ([string]$assignment.Left.Extent.Text) -replace '^\$script:', ''
        $value = @(& ([scriptblock]::Create($assignment.Right.Extent.Text)))
        switch -CaseSensitive ($name) {
            "ReviewerAllowToolCeiling" { $realAllowCeiling = @($value) }
            "ReviewerMandatoryDenyTools" { $realMandatoryDeny = @($value) }
            default { $realCeilings += @{ Name = $name; Tools = @($value) } }
        }
    }
    Assert-Replay (@($realAllowCeiling).Count -gt 0 -and @($realCeilings).Count -ge 2) `
        "The shipped tool ceilings must be readable from the reviewer's source (found $(@($realCeilings).Count) pass ceilings)."

    foreach ($set in @(
            @{ Label = "synthetic"; Allow = @("read", "ado(repo_pull_request)", "ado(repo_file)", "bluebird"); Deny = @("edit", "create"); Passes = $syntheticCeilings },
            @{ Label = "shipped"; Allow = $realAllowCeiling; Deny = $realMandatoryDeny; Passes = $realCeilings })) {
        $script:ReviewerAllowToolCeiling = @($set.Allow)
        $script:ReviewerMandatoryDenyTools = @($set.Deny)
        $passCeilings = @($set.Passes)
        foreach ($mode in @($false, $true)) {
            $script:ReviewerReplayActive = $mode
            # Assign first, then wrap: these functions return `, @(...)` so that a
            # single-element list stays a list, and @(f x) in expression position
            # would keep that outer wrapper instead of unrolling it.
            $denyResult = Get-ReviewerEffectiveDenyTools -ConfigDeny @()
            $deny = @($denyResult)
            foreach ($pass in $passCeilings) {
                $allowResult = Get-ReviewerLaunchAllowTools -Intended ([string[]]@($pass.Tools))
                $allow = @($allowResult)
                Assert-Replay (@($allow).Count -gt 0) `
                    "The $($set.Label) $($pass.Name) grant must never be empty (an empty grant restores CLI default discovery)."
                $widened = @($allow | Where-Object { @($pass.Tools) -cnotcontains $_ })
                Assert-Replay ($widened.Count -eq 0) `
                    "The $($set.Label) $($pass.Name) grant must never exceed its own ceiling, in replay or not (got: $($widened -join ', '))."
                if ($mode) {
                    $survivors = @($allow | Where-Object { $deny -cnotcontains $_ })
                    Assert-Replay ($survivors.Count -eq 0) `
                        "In replay every tool the $($set.Label) $($pass.Name) is granted must also be denied (survived: $($survivors -join ', '))."
                }
            }
        }
    }
    # Replay interception is per-SESSION: `Open-AgentMcpSession` decides
    # live-versus-replay from its own `-ReplaySnapshot` argument, and the
    # process launch is guarded only by that parameter being absent. A seventh
    # call site added later, without the argument, would reach the network from
    # inside a replay and nothing would notice. Pin every call site.
    $sessionCalls = @($reviewerAst.FindAll({
                param($candidate)
                if ($candidate -isnot [Management.Automation.Language.CommandAst]) { return $false }
                $name = $candidate.GetCommandName()
                return ($null -ne $name -and $name -ceq "Open-AgentMcpSession")
            }, $true))
    Assert-Replay (@($sessionCalls).Count -ge 5) `
        "The reviewer must still open MCP sessions (found $(@($sessionCalls).Count)); a zero here means this check stopped looking."
    $unguarded = @(@($sessionCalls) | Where-Object {
            $text = [string]$_.Extent.Text
            $text -cnotmatch '-ReplaySnapshot\s'
        })
    Assert-Replay (@($unguarded).Count -eq 0) `
        ("Every Open-AgentMcpSession call must pass -ReplaySnapshot, or a replay reaches the network: " +
        (@(@($unguarded) | ForEach-Object { "line $($_.Extent.StartLineNumber)" }) -join ", "))

    # -- 12. `notInReach` is fail-closed ---------------------------------------
    # Out-of-reach is the one verdict that costs nothing to give, so it is the
    # one an evasive row reaches for. Every property that makes it safe gets a
    # positive case (it is genuinely usable) and an adversarial case (it cannot
    # be used to say nothing).
    Write-Host "12/13 out-of-reach is fail-closed" -ForegroundColor Cyan
    # The report-to-enumerator adapter, lifted from the reviewer by AST for the
    # same reason as the tool grant: what it ships is the only thing worth
    # asserting about.
    . (Join-Path $RepoRoot "src\Agents\reviewer\ChangedConstructs.ps1")
    foreach ($fn in @("Get-ReviewerHashValue", "Test-ReviewerConstructFileHadChangedLines", "Get-ReviewerConstructFilesFromReport", "Get-ReviewerConstructFilesFromReportSafely")) {
        $node = $reviewerAst.FindAll({
                param($candidate)
                $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -ceq $fn
            }, $true) | Select-Object -First 1
        Assert-Replay ($null -ne $node) "The reviewer must define $fn."
        if ($node) { . ([scriptblock]::Create($node.Extent.Text)) }
    }
    $bothKinds = "invocation,declaration"
    $everyId = "mi0,mi1,dc0"

    # Positive: a rule that really does not reach this change set says so
    # against every anchor, and that survives as an answer.
    $reachesNothing = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "notApplicable" -Scope $bothKinds -Checked "" -NotInReach $everyId),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $everyId)
    )
    Assert-Replay (@($reachesNothing.Rows | Where-Object { $_.ruleRef -ceq "rs0" }).status -ceq "notApplicable") `
        "A rule that puts every anchor out of reach, naming all of them, keeps its answer."
    Assert-Replay ([bool]$reachesNothing.Complete) `
        "An exact cover made of out-of-reach plus checked is still an exact cover."

    # Positive: the mixed case - some anchors weighed, the rest out of reach.
    $mixedReach = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Scope $bothKinds -Checked "mi0" -Violating "mi0" -NotInReach "mi1,dc0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $everyId)
    )
    $mixedRow = @($mixedReach.Rows | Where-Object { $_.ruleRef -ceq "rs0" })
    Assert-Replay ($mixedRow.status -ceq "violation" -and @($mixedRow.notInReachConstructs).Count -eq 2) `
        "Weighing one anchor and putting the other two out of reach is a legitimate exact cover."

    # Adversarial: omission. One anchor named nowhere at all.
    $omitted = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope $bothKinds -Checked "mi0" -NotInReach "mi1"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $everyId)
    )
    $omittedRow = @($omitted.Rows | Where-Object { $_.ruleRef -ceq "rs0" })
    Assert-Replay ($omittedRow.status -ceq "unknown" -and $omittedRow.degradedReason -clike "*dc0*") `
        "Checked plus out-of-reach must cover the declared universe exactly; the omitted anchor must be named."

    # Adversarial: the same anchor in two lists.
    $twoLists = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope $bothKinds -Checked "mi0,mi1,dc0" -NotInReach "dc0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $everyId)
    )
    Assert-Replay (@($twoLists.Rows | Where-Object { $_.ruleRef -ceq "rs0" }).status -ceq "unknown") `
        "An anchor that is both checked and out of reach has two verdicts, not one."

    # Adversarial: the same anchor twice inside ONE list. Collapsing this
    # quietly would let a short list impersonate an exact cover.
    $repeatedInList = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope $bothKinds -Checked "mi0,mi1" -NotInReach "dc0,dc0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $everyId)
    )
    $repeatedRow = @($repeatedInList.Rows | Where-Object { $_.ruleRef -ceq "rs0" })
    Assert-Replay ($repeatedRow.status -ceq "unknown" -and $repeatedRow.degradedReason -clike "*twice*") `
        "An anchor repeated inside one verdict list must be refused, not silently deduplicated."

    # Adversarial: the same repeat hidden in overlapping ranges.
    $overlapRange = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope $bothKinds -Checked "mi0-mi1,mi1" -NotInReach "dc0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $everyId)
    )
    Assert-Replay (@($overlapRange.Rows | Where-Object { $_.ruleRef -ceq "rs0" }).status -ceq "unknown") `
        "Overlapping ranges are the same repeat written differently and must be refused too."

    # Adversarial: an id that resolves to no enumerated construct.
    $ghostReach = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope $bothKinds -Checked $everyId -NotInReach "mi99"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $everyId)
    )
    Assert-Replay (@($ghostReach.Rows | Where-Object { $_.ruleRef -ceq "rs0" }).status -ceq "unknown") `
        "Every out-of-reach id must resolve to a sealed enumerated construct."

    # Adversarial: an id of a kind the row's own scope excludes. Out-of-reach
    # is a verdict about an anchor the rule was asked about; it is not a bin.
    $wrongKind = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope "declaration" -Checked "dc0" -NotInReach "mi0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $everyId)
    )
    $wrongKindRow = @($wrongKind.Rows | Where-Object { $_.ruleRef -ceq "rs0" })
    Assert-Replay ($wrongKindRow.status -ceq "unknown" -and $wrongKindRow.degradedReason -clike "*out of reach*") `
        "An out-of-reach id from a kind the declared scope never covered must be refused."

    # Adversarial: a scope the wrapper does not enumerate. Mixed WITH a real
    # kind and a complete cover of it, so the row survives every other guard
    # and only the invented-kind check can catch it.
    $inventedScope = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope "wombat,invocation" -Checked "mi0,mi1"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $everyId)
    )
    $inventedRow = @($inventedScope.Rows | Where-Object { $_.ruleRef -ceq "rs0" })
    Assert-Replay ($inventedRow.status -ceq "unknown" -and $inventedRow.degradedReason -clike "*does not enumerate*") `
        "A construct kind the wrapper does not enumerate cannot define a universe, even beside a real one."

    # Adversarial: a kind the wrapper DOES enumerate but which has no anchors
    # in this change set. The required set is empty, so the cover check, the
    # out-of-scope check and the stray check are all vacuous - and
    # `notApplicable` is exempt from the weighed-nothing guard. Only the
    # named-nothing guard stands between this and a free pass, and it is the
    # exact shape an evasive row would reach for.
    $emptyKindEscape = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "notApplicable" -Scope "comment" -Checked ""),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $everyId)
    )
    $emptyKindRow = @($emptyKindEscape.Rows | Where-Object { $_.ruleRef -ceq "rs0" })
    Assert-Replay ($emptyKindRow.status -ceq "unknown" -and $emptyKindRow.degradedReason -clike "*named no anchor*") `
        "A row scoping itself to an enumerable kind with zero anchors has named nothing falsifiable."
    Assert-Replay (-not [bool]$emptyKindEscape.Complete) `
        "That escape must also cost the accounting its completeness."

    # Adversarial: a partition larger than the anchor set. The row is degraded,
    # but what it CLAIMED has to survive into the sealed row - otherwise the
    # audit trail of a model that named violations reads as if it named none.
    # Each field stays under the per-field ceiling; only the sum exceeds it.
    $overCeiling = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "violation" -Scope $bothKinds `
                -Checked "mi0-mi15" -Violating "mi0" -NotInReach "dc0-dc3"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $everyId)
    )
    $overRow = @($overCeiling.Rows | Where-Object { $_.ruleRef -ceq "rs0" })
    Assert-Replay ($overRow.status -ceq "unknown" -and $overRow.degradedReason -clike "*verdicts over*") `
        "More verdicts than anchors must degrade the row with the counts named (got: $($overRow.degradedReason))."
    Assert-Replay (@($overRow.violatingConstructs) -ccontains "mi0") `
        "A degraded row must still record what it claimed; erasing it destroys the audit trail."

    # A field of overlapping ranges never adds a new id, so the unique-id
    # ceiling never fires and the inner loop ran in full. The ranges must be
    # NARROWER than the ceiling for that to be true, and the check runs in a
    # job with a deadline because a test whose only failure mode is a hang
    # never reports.
    $wideConstructs = @()
    for ($i = 0; $i -lt 60; $i++) {
        $wideConstructs += [pscustomobject][ordered]@{ constructId = "mi$i"; kind = "invocation"; path = "src/a.cs"; line = ($i + 1) }
    }
    for ($i = 0; $i -lt 60; $i++) {
        $wideConstructs += [pscustomobject][ordered]@{ constructId = "dc$i"; kind = "declaration"; path = "src/b.cs"; line = ($i + 1) }
    }
    $wideCover = "mi0-mi59,dc0-dc59"
    $floodJob = Start-Job -ScriptBlock {
        param($RepoRoot)
        . (Join-Path $RepoRoot "src\Agents\reviewer\ConventionSpecialist.ps1")
        # `MaxIds` as the real call site computes it: anchor count plus sixteen,
        # for a full 120-anchor table. Ranges of a hundred repeated forty times
        # never add a new id past the first pass, so the unique-id ceiling
        # cannot fire and only the work ceiling can.
        $field = ((@(1..40) | ForEach-Object { "mi0-mi99" }) -join ",")
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $refused = Expand-ReviewerConventionSpecialistConstructIds -Text $field -MaxIds 136
        $sw.Stop()
        # And the legitimate shape at the same ceiling must still be accepted.
        $legitimate = Expand-ReviewerConventionSpecialistConstructIds -Text "mi0-mi59,dc0-dc59" -MaxIds 136
        return @{ RefusedOk = [bool]$refused.Ok; LegitimateOk = [bool]$legitimate.Ok
            LegitimateCount = @($legitimate.Ids).Count; Ms = $sw.ElapsedMilliseconds
        }
    } -ArgumentList $RepoRoot
    $floodFinished = Wait-Job -Job $floodJob -Timeout 60
    $floodResult = $(if ($floodFinished) { @(Receive-Job -Job $floodJob)[0] } else { $null })
    Remove-Job -Job $floodJob -Force -ErrorAction SilentlyContinue
    Assert-Replay ($null -ne $floodResult) `
        "The work ceiling must stop a flood of overlapping ranges; without it this does not return."
    Assert-Replay ($null -ne $floodResult -and -not [bool]$floodResult.RefusedOk) `
        "A field whose ranges never add a new id must still be refused, by the work ceiling rather than the id ceiling."
    Assert-Replay ($null -ne $floodResult -and [bool]$floodResult.LegitimateOk -and [int]$floodResult.LegitimateCount -eq 120) `
        "And at the same ceiling a legitimate full cover of the table must still be accepted."

    $overlapFlood = Invoke-Coverage -WithConstructs $wideConstructs -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope $bothKinds `
                -Checked ((@(1..40) | ForEach-Object { "mi0-mi59" }) -join ",")),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $wideCover)
    )
    Assert-Replay (@($overlapFlood.Rows | Where-Object { $_.ruleRef -ceq "rs0" }).status -ceq "unknown") `
        "A flood of overlapping ranges must be refused, not expanded."
    # And the legitimate shape it must NOT refuse: a full exact cover of the
    # same wide table, written as two ranges.
    $wideLegit = Invoke-Coverage -WithConstructs $wideConstructs -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope $bothKinds -Checked $wideCover),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $wideCover)
    )
    Assert-Replay (@($wideLegit.Rows | Where-Object { $_.ruleRef -ceq "rs0" }).status -ceq "compliant" -and [bool]$wideLegit.Complete) `
        "The work ceiling must not refuse a legitimate exact cover of a full construct table."

    # Capitalised ids and refs reach this code because the marker validates its
    # patterns case-insensitively. Folding them costs nothing and saves a row.
    $capitalIds = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "RS0" -Sha ("a" * 64) -Status "compliant" -Scope "Invocation,Declaration" -Checked "MI0,MI1,DC0"),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $everyId)
    )
    Assert-Replay (@($capitalIds.Rows | Where-Object { $_.ruleRef -ceq "rs0" }).status -ceq "compliant" -and
        @($capitalIds.Unknown).Count -eq 0) `
        "A capitalised ruleRef and capitalised construct ids must resolve, not silently degrade a correct row."

    # The marker validates its patterns case-insensitively, so a capital letter
    # reaches this function. Folding it costs nothing and saves a correct row.
    $capitalScope = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "compliant" -Scope "Invocation,Declaration" -Checked $everyId),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "compliant" -Scope $bothKinds -Checked $everyId)
    )
    Assert-Replay (@($capitalScope.Rows | Where-Object { $_.ruleRef -ceq "rs0" }).status -ceq "compliant") `
        "A capitalised scope must resolve to the same universe rather than silently degrading a correct row."

    # Adversarial: the whole checklist out of reach. Every row is individually
    # legal and the pass has weighed nothing, so it is not complete.
    $allOutOfReach = Invoke-Coverage -Rows @(
        (New-CoverageRow -Ref "rs0" -Sha ("a" * 64) -Status "notApplicable" -Scope $bothKinds -Checked "" -NotInReach $everyId),
        (New-CoverageRow -Ref "rs1" -Sha ("b" * 64) -Status "notApplicable" -Scope $bothKinds -Checked "" -NotInReach $everyId)
    )
    Assert-Replay (-not [bool]$allOutOfReach.Complete -and [int]$allOutOfReach.CheckedConstructCount -eq 0) `
        "An accounting where every rule reaches nothing has weighed nothing and is not complete."

    # A file the transport never delivered contributes no anchors, so no row
    # owes a verdict for it and every row is an exact cover of a change set
    # with a hole in it. The shipped coverage floor is 60%, so this is the
    # normal case, not a corner.
    $reportShape = [pscustomobject][ordered]@{
        Files = @(
            [pscustomobject][ordered]@{
                Path = "/src/a.cs"
                Slices = @([pscustomobject][ordered]@{ StartLine = 1; EndLine = 4; Text = "class A {`nvoid M() {`nDo(`nx: 1);" })
                SiblingSlices = @()
                RawSpans = @([pscustomobject][ordered]@{ Start = 3; End = 4 })
            },
            [pscustomobject][ordered]@{
                Path = "/src/b.cs"
                Slices = @()
                SiblingSlices = @()
                RawSpans = @([pscustomobject][ordered]@{ Start = 10; End = 40 })
            })
    }
    $selection = Get-ReviewerConstructFilesFromReport -Report $reportShape
    Assert-Replay (@($selection.UndeliveredPaths) -ccontains "src/b.cs") `
        "A changed file with no delivered slice must be reported as one the enumerator never saw."
    $withHole = Get-ReviewerConstructFilesFromReportSafely -Report $reportShape
    Assert-Replay (@($withHole.PartiallyUnderstoodFiles) -ccontains "src/b.cs") `
        "That hole must reach the same signal an unlexable file uses, or the accounting will call itself complete over less code than the pull request changed."

    # A hunk that runs past the delivered image is not a reason to count to two
    # billion. This is the mandatory path of every review, and a hang is not an
    # exception the caller's try/catch can catch - so the check runs in a job
    # with a deadline, because a test that can only fail by hanging never
    # reports.
    $runawayScript = {
        param($RepoRoot)
        $source = [IO.File]::ReadAllText((Join-Path $RepoRoot "src\Agents\reviewer\Start-ReviewerAgent.ps1"))
        $t = $null; $e = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$t, [ref]$e)
        foreach ($fn in @("Get-ReviewerHashValue", "Test-ReviewerConstructFileHadChangedLines", "Get-ReviewerConstructFilesFromReport")) {
            $node = $ast.FindAll({ param($c) $c -is [Management.Automation.Language.FunctionDefinitionAst] -and $c.Name -ceq $fn }, $true) | Select-Object -First 1
            . ([scriptblock]::Create($node.Extent.Text))
        }
        $report = [pscustomobject][ordered]@{
            Files = @([pscustomobject][ordered]@{
                    Path = "/src/a.cs"
                    Slices = @([pscustomobject][ordered]@{ StartLine = 1; EndLine = 3; Text = "a`nb`nc" })
                    SiblingSlices = @()
                    RawSpans = @([pscustomobject][ordered]@{ Start = 1; End = 2147483647 })
                    RawRequestedSpanCount = 1
                })
        }
        $result = Get-ReviewerConstructFilesFromReport -Report $report
        return @($result.UndeliveredPaths)
    }
    $runawayJob = Start-Job -ScriptBlock $runawayScript -ArgumentList $RepoRoot
    $finished = Wait-Job -Job $runawayJob -Timeout 60
    $runawayPaths = $(if ($finished) { @(Receive-Job -Job $runawayJob) } else { @() })
    Remove-Job -Job $runawayJob -Force -ErrorAction SilentlyContinue
    Assert-Replay ($null -ne $finished) `
        "An unbounded hunk span must be clamped to the delivered image; without the clamp this never returns."
    Assert-Replay ($runawayPaths -ccontains "src/a.cs") `
        "A hunk reaching past what was delivered leaves the enumeration short, and that must be recorded."

    # A file the transport dropped BEFORE slicing carries no spans at all - too
    # large, unreadable, past the file cap - so gating on `RawSpans` missed
    # exactly the files nobody read.
    $preSliceOmission = [pscustomobject][ordered]@{
        Files = @(
            [pscustomobject][ordered]@{
                Path = "/src/a.cs"
                Slices = @([pscustomobject][ordered]@{ StartLine = 1; EndLine = 4; Text = "class A {`nvoid M() {`nDo(`nx: 1);" })
                SiblingSlices = @()
                RawSpans = @([pscustomobject][ordered]@{ Start = 3; End = 4 })
                RawRequestedSpanCount = 1
            },
            [pscustomobject][ordered]@{
                Path = "/src/toobig.cs"
                Slices = @(); SiblingSlices = @(); RawSpans = @(); RawRequestedSpanCount = 1
            })
    }
    $preSliceResult = Get-ReviewerConstructFilesFromReport -Report $preSliceOmission
    Assert-Replay (@($preSliceResult.UndeliveredPaths) -ccontains "src/toobig.cs") `
        "A file omitted before slicing has no RawSpans, and must still be reported as one the enumerator never saw."

    # -- 13. Repeated runs of one frozen input --------------------------------
    Write-Host "13/13 cross-run reconciliation" -ForegroundColor Cyan
    . (Join-Path $RepoRoot "src\Agents\reviewer\RunReconciliation.ps1")

    function New-ReconRun {
        param(
            [string]$Nonce, [object[]]$Rows, [object[]]$Candidates = @(),
            [string]$SourceCommit = "c" * 40, [string]$Promotable = "false",
            [object[]]$Constructs = $null, [string]$Status = "ok",
            [string]$SnapshotId = "s", [string]$ManifestDigest = ("7" * 64),
            [string]$Complete = "true", [string[]]$Missing = @(),
            [string]$ConstructsIncomplete = "false", [int]$Checked = 1
        )
        # Built with the field names PRODUCTION writes (ConventionSpecialist.ps1
        # `Constructs = ...`). A fixture in the reconciler's own vocabulary
        # would validate the reconciler against itself.
        $set = $(if ($null -eq $Constructs) {
                @([pscustomobject][ordered]@{
                        constructId = "mi0"; kind = "invocation"; path = "src/a.cs"
                        line = 12; endLine = 14; name = "AreEqual"; argumentNaming = "nnp"
                    })
            }
            else { $Constructs })
        return [pscustomobject][ordered]@{
            kind = $script:ReviewerConventionSpecialistArtifactKind
            artifactVersion = $script:ReviewerConventionSpecialistArtifactVersion
            status = $(if ($Status -ceq "ok") { "complete" } else { $Status }); prId = 42; sourceCommit = $SourceCommit; organization = "o"; project = "p"
            repositoryId = "r"; model = "m"; configSha256 = ("1" * 64); scriptSha256 = ("2" * 64)
            specialistLibrarySha256 = ("3" * 64); promptSha256 = ("4" * 64)
            conventionPlanSha256 = ("5" * 64); factPlanSha256 = ("6" * 64)
            candidates = @($Candidates)
            ruleCoverage = [pscustomobject][ordered]@{
                complete = [bool]::Parse($Complete); rows = @($Rows); changedConstructs = @($set)
                missing = @($Missing); duplicates = @(); unknown = @(); unaccountedCandidates = @()
                constructsIncomplete = [bool]::Parse($ConstructsIncomplete)
                enumeratedConstructCount = @($set).Count; checkedConstructCount = $Checked
            }
            replay = [pscustomobject][ordered]@{
                snapshotId = $SnapshotId; manifestDigest = $ManifestDigest; replayNonce = $Nonce
                promotable = [bool]::Parse($Promotable)
            }
        }
    }
    function New-ReconRow {
        param(
            [string]$Source = "core/rule-a", [string]$Status = "violation",
            [string[]]$Violating = @("mi0"), [string[]]$Compliant = @(), [string]$Sha = ("9" * 64),
            [string[]]$NotInReach = @(), [string[]]$Unknown = @(), [string]$Ref = "rs0"
        )
        return [pscustomobject][ordered]@{
            ruleRef = $Ref; ruleSourceId = $Source; ruleSourceSha256 = $Sha; status = $Status
            violatingConstructs = @($Violating); compliantConstructs = @($Compliant)
            notInReachConstructs = @($NotInReach); unknownConstructs = @($Unknown)
            candidateId = ""; degradedReason = ""
        }
    }
    function New-ReconCandidate {
        param(
            [string]$Source = "core/rule-a", [string]$Path = "/src/a.cs", [int]$Line = 12,
            [string]$Id = "c1", [string]$Severity = "suggestion", [string]$Comment = "text"
        )
        return [pscustomobject][ordered]@{
            candidateId = $Id; ruleSourceId = $Source; filePath = $Path; line = $Line
            anchorKind = "changedFile"; severity = $Severity; comment = $Comment
        }
    }

    # Agreement survives, and the anchors it agreed on come through.
    $agree = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate -Id "c9")))
    )
    Assert-Replay ([bool]$agree.reconciled -and [int]$agree.stableRowCount -eq 1) `
        "Two runs that read a rule the same way must reconcile to that reading."
    Assert-Replay (@($agree.rows)[0].reconciledStatus -ceq "violation" -and @(@($agree.rows)[0].violatingConstructs) -ccontains "mi0") `
        "A stable row keeps its status and its anchors."
    Assert-Replay (@($agree.candidates)[0].disposition -ceq "agreed") `
        "A candidate at the same rule, file and line in both runs is agreed even though its id differs."
    Assert-Replay (-not [bool]$agree.promotable) "A reconciliation is never promotable."

    # Disagreement on the word collapses to unknown - never to the interesting
    # reading, and never to the first run.
    $statusSplit = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Status "violation"))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Status "compliant" -Violating @() -Compliant @("mi0"))))
    )
    Assert-Replay (@($statusSplit.rows)[0].reconciledStatus -ceq "unknown" -and -not [bool]@($statusSplit.rows)[0].stable) `
        "Two runs reading one rule differently must collapse to unknown."
    Assert-Replay (@(@($statusSplit.rows)[0].rawStatuses) -ccontains "violation" -and @(@($statusSplit.rows)[0].rawStatuses) -ccontains "compliant") `
        "Both raw readings must stay visible in the reconciliation."
    Assert-Replay (@(@($statusSplit.rows)[0].violatingConstructs).Count -eq 0) `
        "An unstable row must not carry forward the anchors of the run that happened to find something."

    # Same word, different anchors, is still disagreement.
    $anchorSplit = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Violating @("mi0")))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Violating @("mi1"))))
    )
    Assert-Replay (@($anchorSplit.rows)[0].reconciledStatus -ceq "unknown") `
        "Agreeing on 'violation' while naming different anchors is two findings, not one."

    # Ordering is not disagreement.
    $reordered = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Violating @("mi0", "mi1")))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Violating @("mi1", "mi0"))))
    )
    Assert-Replay ([bool]@($reordered.rows)[0].stable) "The order a model lists anchors in is not a difference."

    # A rule one run never accounted for.
    $absentRule = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow), (New-ReconRow -Source "core/rule-b" -Ref "rs1"))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)))
    )
    Assert-Replay (@(@($absentRule.rows) | Where-Object { $_.ruleRef -ceq "rs1" }).reconciledStatus -ceq "unknown") `
        "A rule only one run accounted for is unknown, not that run's answer."

    # A candidate only one run proposed is withheld.
    $candidateSplit = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)))
    )
    Assert-Replay (@($candidateSplit.candidates)[0].disposition -ceq "withheldRunDisagreement") `
        "A comment only one run proposed must be withheld, not promoted by the run that found it."

    # A different line is a different candidate, so both are withheld.
    $lineSplit = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate -Line 12))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate -Line 13)))
    )
    Assert-Replay (@(@($lineSplit.candidates) | Where-Object { $_.disposition -ceq "agreed" }).Count -eq 0) `
        "Two runs pointing at neighbouring lines have not agreed on a comment."

    # Every pairing of disagreeing readings must collapse, and none of them may
    # leave a candidate eligible. Written out one by one rather than trusting a
    # single representative case, because each takes a different route through
    # the comparison: two named statuses, a named status against a degraded
    # one, a row that is simply absent.
    foreach ($pair in @(
            @{ Name = "violation and compliant"; A = @{ S = "violation"; V = @("mi0"); C = @() }; B = @{ S = "compliant"; V = @(); C = @("mi0") } },
            @{ Name = "violation and unknown"; A = @{ S = "violation"; V = @("mi0"); C = @() }; B = @{ S = "unknown"; V = @(); C = @() } },
            @{ Name = "compliant and unknown"; A = @{ S = "compliant"; V = @(); C = @("mi0") }; B = @{ S = "unknown"; V = @(); C = @() } },
            @{ Name = "violation and notApplicable"; A = @{ S = "violation"; V = @("mi0"); C = @() }; B = @{ S = "notApplicable"; V = @(); C = @() } })) {
        # Both orders. A comparison that resolves differently depending on which
        # run the operator happened to list first is not a reconciliation, it is
        # a coin toss with extra steps.
        foreach ($order in @(@("A", "B"), @("B", "A"))) {
            $first = $pair[$order[0]]
            $second = $pair[$order[1]]
            $result = Resolve-ReviewerRunReconciliation -Manifests @(
                (New-ReconRun -Nonce "n1" -Candidates @((New-ReconCandidate)) `
                        -Rows @((New-ReconRow -Status $first.S -Violating $first.V -Compliant $first.C))),
                (New-ReconRun -Nonce "n2" `
                        -Rows @((New-ReconRow -Status $second.S -Violating $second.V -Compliant $second.C)))
            )
            $label = "$($pair.Name) [$($order -join '/')]"
            Assert-Replay (@($result.rows)[0].reconciledStatus -ceq "unknown" -and -not [bool]@($result.rows)[0].stable) `
                "$label must collapse to unknown."
            Assert-Replay (@(@($result.rows)[0].violatingConstructs).Count -eq 0) `
                "$label must not carry forward the anchors of whichever run found something."
            Assert-Replay (@(@($result.candidates) | Where-Object { $_.disposition -ceq "agreed" }).Count -eq 0) `
                "$label must leave no candidate eligible."
            Assert-Replay (@(@($result.rows)[0].rawStatuses) -ccontains $first.S -and
                @(@($result.rows)[0].rawStatuses) -ccontains $second.S) `
                "$label must disclose both raw readings."
        }
    }

    # The two shapes that are not a disagreement between named statuses at all:
    # a row one run never wrote, and a run that fell over.
    $absentAndNamed = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Status "violation"), (New-ReconRow -Ref "rs1" -Source "core/rule-b"))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Status "violation"))))
    Assert-Replay (@(@($absentAndNamed.rows) | Where-Object { $_.ruleRef -ceq "rs1" }).reconciledStatus -ceq "unknown") `
        "A rule one run never wrote a row for cannot take the other run's answer."
    $reversedAbsent = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Status "violation"))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Status "violation"), (New-ReconRow -Ref "rs1" -Source "core/rule-b"))))
    Assert-Replay (@(@($reversedAbsent.rows) | Where-Object { $_.ruleRef -ceq "rs1" }).reconciledStatus -ceq "unknown") `
        "Nor when it is the FIRST run missing the row - the reference must not become whichever run happened to have it."
    $degradedPair = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Status "violation")) -Candidates @((New-ReconCandidate))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Status "violation")) -Candidates @((New-ReconCandidate)) -Status "degraded"))
    Assert-Replay (-not [bool]$degradedPair.reconciled -and
        @(@($degradedPair.candidates) | Where-Object { $_.disposition -ceq "agreed" }).Count -eq 0) `
        "A degraded run beside a clean one leaves nothing eligible, however well the two appear to agree."

    # Three runs, dissenter first and dissenter last. Nothing may promote the
    # two that matched, in either direction.
    foreach ($order in @(@("violation", "violation", "compliant"), @("compliant", "violation", "violation"))) {
        $manifests = @()
        $nonce = 0
        foreach ($status in $order) {
            $nonce++
            $manifests += (New-ReconRun -Nonce "n$nonce" -Rows @((New-ReconRow -Status $status `
                            -Violating $(if ($status -ceq "violation") { @("mi0") } else { @() }) `
                            -Compliant $(if ($status -ceq "violation") { @() } else { @("mi0") }))))
        }
        $threeWay = Resolve-ReviewerRunReconciliation -Manifests $manifests
        Assert-Replay (@($threeWay.rows)[0].reconciledStatus -ceq "unknown") `
            "Two of three agreeing is not a result, whichever position the dissenter is in ($($order -join ','))."
    }

    # Order independence, proved by hash rather than by inspection. The same
    # sealed runs listed the other way round must produce the same outcome
    # byte for byte, or "which run you list first" is a lever.
    $forward = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Violating @("mi0"))) -Candidates @((New-ReconCandidate))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Violating @("mi1")))))
    $backward = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Violating @("mi1")))),
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Violating @("mi0"))) -Candidates @((New-ReconCandidate))))
    Assert-Replay ([string]$forward.reconciliationSha256 -ceq [string]$backward.reconciliationSha256) `
        "Reversing the run order must not change the reconciliation digest."
    Assert-Replay ([string]$forward.reconciliationSha256 -cmatch '^[0-9a-f]{64}$') `
        "The reconciliation must carry a reproducible digest of its own outcome."
    $settledPair = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Violating @("mi0")))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Violating @("mi0")))))
    Assert-Replay ([string]$forward.reconciliationSha256 -cne [string]$settledPair.reconciliationSha256) `
        "A different outcome must produce a different digest."

    # The mechanism has to be able to say yes: an anchor every run calls
    # violating, in a rule they all call violating, survives.
    Assert-Replay (@($settledPair.rows)[0].reconciledStatus -ceq "violation" -and
        [bool]@($settledPair.rows)[0].stable -and
        @(@($settledPair.rows)[0].violatingConstructs) -ccontains "mi0") `
        "An anchor every run calls violating must normalize to violation."

    # Per-ANCHOR verdicts, which is the level a reader can act on. "The
    # violating anchors differ" says two runs disagreed; it does not say which
    # call they disagreed about.
    $perAnchor = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Violating @("mi0") -Compliant @("mi1")))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Violating @("mi0") -Compliant @()))))
    $anchorRows = @(@($perAnchor.rows)[0].anchors)
    $anchorMi0 = @($anchorRows | Where-Object { $_.constructId -ceq "mi0" })
    $anchorMi1 = @($anchorRows | Where-Object { $_.constructId -ceq "mi1" })
    Assert-Replay ($anchorMi0.reconciledVerdict -ceq "violation" -and [bool]$anchorMi0.stable) `
        "An anchor every run read the same way keeps that verdict."
    Assert-Replay ($anchorMi1.reconciledVerdict -ceq "unknown" -and -not [bool]$anchorMi1.stable) `
        "An anchor one run never accounted for is unknown, not the other run's answer."
    Assert-Replay (@($anchorMi1.perRunVerdicts) -ccontains "unaccounted") `
        "The per-run verdicts must show which run left the anchor unaccounted."
    Assert-Replay (@($perAnchor.rows)[0].reconciledStatus -ceq "unknown") `
        "One unsettled anchor makes the whole rule unknown, however the runs worded it."

    # Candidate-anchor variation: same rule, same file, a different line. Two
    # proposals, neither agreed.
    $anchorVariation = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate -Line 478))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate -Line 479))))
    Assert-Replay (@($anchorVariation.candidates).Count -eq 2 -and
        @(@($anchorVariation.candidates) | Where-Object { $_.disposition -ceq "agreed" }).Count -eq 0) `
        "Candidates at different lines of the same rule are two proposals, neither agreed."

    # The very same run object submitted twice is one observation in two hats.
    $duplicateRun = New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate))
    $duplicated = Resolve-ReviewerRunReconciliation -Manifests @($duplicateRun, $duplicateRun)
    Assert-Replay (-not [bool]$duplicated.reconciled -and
        @(@($duplicated.candidates) | Where-Object { $_.disposition -ceq "agreed" }).Count -eq 0) `
        "The same run twice must not reconcile, and must leave nothing eligible."

    # Mixed schema: a construct table describing the same call differently.
    $mixedSchema = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Constructs @(
                [pscustomobject][ordered]@{
                    constructId = "mi0"; kind = "invocation"; path = "src/a.cs"
                    line = 12; endLine = 14; name = "AreEqual"; argumentNaming = "nnn"
                })))
    Assert-Replay (-not [bool]$mixedSchema.reconciled) `
        "A construct table describing the same call differently is a different question."

    # Two candidates in ONE run sharing an anchor key. `prMetadata` candidates
    # are all forced to file "" line 0, so any two under one rule collide
    # exactly - and a set would drop the second, leaving it neither agreed nor
    # withheld while the runs read as fully agreeing.
    $extraCandidate = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @(
                (New-ReconCandidate -Id "c1"), (New-ReconCandidate -Id "c2" -Comment "a second, more serious claim"))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate -Id "c1")))
    )
    Assert-Replay (@(@($extraCandidate.candidates) | Where-Object { $_.disposition -ceq "agreed" }).Count -eq 0) `
        "A run that proposed an extra comment at the same anchor has not agreed with one that did not."
    Assert-Replay (@(@($extraCandidate.candidates)[0].perRunCounts) -ccontains 2) `
        "The per-run counts must show that one run proposed two comments there."

    # The claim itself, not just its location. Two runs pointing at one line and
    # saying different things about it have not agreed on a comment.
    $textSplit = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate -Comment "Rename the argument"))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate -Comment "This will fail at run time")))
    )
    Assert-Replay (@($textSplit.candidates)[0].disposition -ceq "withheldTextDisagreement") `
        "Two runs proposing different text at one anchor have not agreed on a comment."
    $severitySplit = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate -Severity "suggestion"))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate -Severity "important")))
    )
    Assert-Replay (@($severitySplit.candidates)[0].disposition -ceq "withheldSeverityDisagreement") `
        "Severity is a materially different claim; disagreeing about it is disagreement."

    # A pass where every rule ruled every anchor out of reach is clean row by
    # row and has looked at nothing. Two of those agree perfectly about nothing.
    $weighedNothing = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Status "notApplicable" -Violating @() -NotInReach @("mi0"))) -Checked 0),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Status "notApplicable" -Violating @() -NotInReach @("mi0"))) -Checked 0)
    )
    Assert-Replay (-not [bool]$weighedNothing.reconciled -and @($weighedNothing.problems) -clike "*weighed none of its*") `
        "Two passes that weighed no anchor at all have agreed about nothing, and the report must say so."

    # The status comparison earns its keep only when the partition is IDENTICAL
    # and the statuses differ - which is exactly what a wrapper-degraded row
    # looks like beside a clean one.
    $degradedVsClean = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Status "unknown" -Violating @("mi0")))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Status "violation" -Violating @("mi0"))))
    )
    Assert-Replay (@($degradedVsClean.rows)[0].reconciledStatus -ceq "unknown" -and
        -not [bool]@($degradedVsClean.rows)[0].stable) `
        "One run degrading a row the other trusted is disagreement, even though both name the same anchor."

    # A file path differing only in case is not the same file to this
    # comparison, and must not be treated as one just because a dictionary
    # happened to fold it.
    $caseSplit = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate -Path "/src/Widget.cs"))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate -Path "/src/widget.cs")))
    )
    Assert-Replay (@($caseSplit.candidates).Count -eq 2 -and
        @(@($caseSplit.candidates) | Where-Object { $_.disposition -ceq "agreed" }).Count -eq 0) `
        "Two candidates whose paths differ only in case are two candidates, and neither is agreed."
    $caseSplitPaths = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(@($caseSplit.candidates) | ForEach-Object { [string]$_.filePath }), [StringComparer]::Ordinal)
    Assert-Replay ($caseSplitPaths.Count -eq 2) `
        "Each must keep its own path; folding them prints one run's comment beside the other's file."

    # Every identity the binding covers, one at a time. A run that differs in
    # ANY of them is not a repetition, and the refusal must not depend on which
    # field happened to change.
    foreach ($identity in @(
            @{ Name = "schema version"; Apply = { param($m) $m.artifactVersion = 99 } },
            @{ Name = "artifact kind"; Apply = { param($m) $m.kind = "something-else" } },
            @{ Name = "model"; Apply = { param($m) $m.model = "a-different-model" } },
            @{ Name = "script build"; Apply = { param($m) $m.scriptSha256 = ("e" * 64) } },
            @{ Name = "specialist library"; Apply = { param($m) $m.specialistLibrarySha256 = ("e" * 64) } },
            @{ Name = "prompt"; Apply = { param($m) $m.promptSha256 = ("e" * 64) } },
            @{ Name = "convention plan"; Apply = { param($m) $m.conventionPlanSha256 = ("e" * 64) } },
            @{ Name = "fact plan"; Apply = { param($m) $m.factPlanSha256 = ("e" * 64) } },
            @{ Name = "config"; Apply = { param($m) $m.configSha256 = ("e" * 64) } },
            @{ Name = "repository"; Apply = { param($m) $m.repositoryId = "another-repo" } },
            @{ Name = "pull request"; Apply = { param($m) $m.prId = 99 } })) {
        $altered = New-ReconRun -Nonce "n2" -Rows @((New-ReconRow))
        & $identity.Apply $altered
        $mixed = Resolve-ReviewerRunReconciliation -Manifests @(
            (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate))), $altered)
        Assert-Replay (-not [bool]$mixed.reconciled) `
            "Runs differing in $($identity.Name) are not repetitions of one question."
        Assert-Replay (@($mixed.rows)[0].reconciledStatus -ceq "unknown" -and
            @(@($mixed.candidates) | Where-Object { $_.disposition -ceq "agreed" }).Count -eq 0) `
            "A $($identity.Name) mismatch must leave nothing stable and nothing eligible."
    }

    # An incomplete construct set, and a rule-source identity that moved under a
    # stable ref, are the two identity mismatches that live inside the coverage
    # rather than beside it.
    $ruleMoved = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Sha ("1" * 64)))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Sha ("2" * 64)))))
    Assert-Replay (@($ruleMoved.rows)[0].reconciledStatus -ceq "unknown") `
        "The same ref citing two different rule digests is two different questions."

    # Delivery powerlessness. The reconciliation is evaluation output: it must
    # carry no authorization of any kind, and its own kind must not be readable
    # as a specialist preview - which is the only artifact promotion reads.
    $powerless = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate))))
    Assert-Replay (-not [bool]$powerless.promotable) "A reconciliation is never promotable."
    $authorizationFields = @("authorization", "deliveryAuthorization", "writesRequested",
        "eligible", "postable", "vote", "threadId", "commentId", "promote")
    $leaked = @(@($authorizationFields) | Where-Object { $null -ne $powerless.PSObject.Properties[$_] })
    Assert-Replay (@($leaked).Count -eq 0) `
        "A reconciliation must carry no authorization field whatsoever (found: $($leaked -join ', '))."
    Assert-Replay ([string]$powerless.kind -ceq $script:ReviewerRunReconciliationKind -and
        [string]$powerless.kind -cne $script:ReviewerConventionSpecialistArtifactKind) `
        "A reconciliation must not wear the kind that promotion reads."
    # Even a fully agreed candidate is only ever `agreed` - never a word that
    # any delivery path looks for.
    $dispositions = @(@($powerless.candidates) | ForEach-Object { [string]$_.disposition })
    Assert-Replay (@(@($dispositions) | Where-Object { $_ -cin @("eligible", "approved", "postable", "promoted") }).Count -eq 0) `
        "An agreed candidate must not be labelled with any word a delivery path could act on."

    # Digest tampering: editing the outcome must change the digest, and the
    # digest must be a pure function of the outcome rather than of when or where
    # it was computed.
    $again = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate))))
    Assert-Replay ([string]$powerless.reconciliationSha256 -ceq [string]$again.reconciliationSha256) `
        "The same runs reconciled twice must produce the same digest."
    $tamperedRows = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Violating @("mi0")))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Violating @("mi0")))))
    Assert-Replay ([string]$tamperedRows.reconciliationSha256 -cne [string]$powerless.reconciliationSha256) `
        "A different reconciled outcome must produce a different digest."

    # Order independence at a size where positional labels can collide: with ten
    # runs "run 1" is a prefix of "run 10", and a group written in input order
    # says something different when the same runs are listed the other way.
    $tenRuns = @()
    for ($i = 1; $i -le 10; $i++) {
        $tenRuns += (New-ReconRun -Nonce "nonce$i" -Rows @((New-ReconRow -Status $(if ($i % 3 -eq 0) { "compliant" } else { "violation" }) `
                        -Violating $(if ($i % 3 -eq 0) { @() } else { @("mi0") }) `
                        -Compliant $(if ($i % 3 -eq 0) { @("mi0") } else { @() }))) `
                -Candidates @((New-ReconCandidate -Line (10 + ($i % 2)))) `
                -SourceCommit $(if ($i -eq 7) { "d" * 40 } else { "c" * 40 }))
    }
    $tenForward = Resolve-ReviewerRunReconciliation -Manifests $tenRuns -RequiredRunCount 10
    $tenReversed = Resolve-ReviewerRunReconciliation -Manifests @($tenRuns[9..0]) -RequiredRunCount 10
    $shuffleOrder = @(4, 9, 1, 7, 2, 10, 3, 6, 8, 5)
    $tenShuffled = Resolve-ReviewerRunReconciliation -RequiredRunCount 10 `
        -Manifests @(@($shuffleOrder) | ForEach-Object { $tenRuns[$_ - 1] })
    Assert-Replay ([string]$tenForward.reconciliationSha256 -ceq [string]$tenReversed.reconciliationSha256) `
        "Ten runs reversed must produce the same reconciliation digest."
    Assert-Replay ([string]$tenForward.reconciliationSha256 -ceq [string]$tenShuffled.reconciliationSha256) `
        "Ten runs shuffled must produce the same reconciliation digest."
    Assert-Replay (-not [bool]$tenForward.reconciled -and
        @(@($tenForward.rows) | Where-Object { [bool]$_.stable }).Count -eq 0 -and
        @(@($tenForward.candidates) | Where-Object { $_.disposition -ceq "agreed" }).Count -eq 0) `
        "Ten runs spanning two bindings must leave nothing stable and nothing eligible."

    # With eleven runs "run 1" is a prefix of "run 10" and "run 11". The digest
    # maps positions to nonces by counting DOWN for exactly that reason, and
    # nothing tested it - so an ascending rewrite would corrupt the two-digit
    # runs into the one-digit run's nonce and nobody would notice.
    $elevenRuns = @()
    for ($i = 1; $i -le 11; $i++) {
        $elevenRuns += (New-ReconRun -Nonce "nonce$i" -Rows @((New-ReconRow)) `
                -Status $(if ($i -ge 9) { "degraded" } else { "complete" }))
    }
    $eleven = Resolve-ReviewerRunReconciliation -Manifests $elevenRuns -RequiredRunCount 11
    $elevenReversed = Resolve-ReviewerRunReconciliation -Manifests @($elevenRuns[10..0]) -RequiredRunCount 11
    Assert-Replay ([string]$eleven.reconciliationSha256 -ceq [string]$elevenReversed.reconciliationSha256) `
        "Eleven runs reversed must produce the same digest; a two-digit run must not collapse into a one-digit one."
    $degradedProblems = @(@($eleven.problems) | Where-Object { $_ -clike "*finished degraded*" })
    Assert-Replay (@($degradedProblems).Count -eq 3) `
        "Each degraded run must be named separately (got $(@($degradedProblems).Count))."
    $namedRuns = @(@($degradedProblems) | ForEach-Object { ($_ -split ' ')[1] })
    $distinctNamed = [System.Collections.Generic.HashSet[string]]::new([string[]]@($namedRuns), [StringComparer]::Ordinal)
    Assert-Replay ($distinctNamed.Count -eq 3) `
        "Runs 9, 10 and 11 must be three distinct runs, not one run named three times."

    # Five guards that mutation testing found uncovered. Each of these fails if
    # the corresponding production guard is reverted, which is the only reason
    # a test earns its place.

    # 1. A run filing one anchor under two verdicts is not a reading.
    $conflictedRow = New-ReconRow -Violating @("mi0") -Compliant @("mi0")
    $conflicted = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @($conflictedRow)),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Violating @("mi0")))))
    $conflictedAnchor = @(@(@($conflicted.rows)[0].anchors) | Where-Object { $_.constructId -ceq "mi0" })
    Assert-Replay (@($conflictedAnchor[0].perRunVerdicts) -ccontains "conflicted" -and
        [string]$conflictedAnchor[0].reconciledVerdict -ceq "unknown") `
        "A run that files one anchor under two verdicts must be recorded as conflicted, not silently reduced to the first."

    # 2. A run with a full binding but no replay identity is not a replay run.
    $noReplayIdentity1 = New-ReconRun -Nonce "n1" -Rows @((New-ReconRow))
    $noReplayIdentity1.replay.snapshotId = ""
    $noReplayIdentity1.replay.manifestDigest = ""
    $noReplayIdentity2 = New-ReconRun -Nonce "n2" -Rows @((New-ReconRow))
    $noReplayIdentity2.replay.snapshotId = ""
    $noReplayIdentity2.replay.manifestDigest = ""
    $noIdentity = Resolve-ReviewerRunReconciliation -Manifests @($noReplayIdentity1, $noReplayIdentity2)
    Assert-Replay (-not [bool]$noIdentity.reconciled -and
        @(@($noIdentity.problems) | Where-Object { $_ -clike "*replay identity*" }).Count -gt 0) `
        "Two runs with no snapshot identity must not bind equal just because their nothings match."

    # 3. Every run saying `compliant` while every run lists an anchor violating
    #    is a contradiction the anchors must win, and the row must degrade.
    $wordVersusAnchors = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Status "compliant" -Violating @("mi0")))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Status "compliant" -Violating @("mi0")))))
    Assert-Replay (@($wordVersusAnchors.rows)[0].reconciledStatus -ceq "unknown" -and
        -not [bool]@($wordVersusAnchors.rows)[0].stable) `
        "A word every run agreed on that contradicts the anchors they also agreed on must degrade, not be taken at face value."
    Assert-Replay (@(@($wordVersusAnchors.rows)[0].disagreements | Where-Object { $_ -clike "*but the reconciled anchors say*" }).Count -gt 0) `
        "And the contradiction must be stated."

    # 4. A refused comparison must clear the anchors it had agreed on, not just
    #    the row's headline.
    $refusedButAgreeing = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Violating @("mi0")))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Violating @("mi0"))) -SourceCommit ("d" * 40)))
    Assert-Replay (@(@($refusedButAgreeing.rows)[0].violatingConstructs).Count -eq 0 -and
        @(@($refusedButAgreeing.rows)[0].notInReachConstructs).Count -eq 0) `
        "A refused comparison must carry no violating or out-of-reach anchors forward."
    Assert-Replay (@(@(@($refusedButAgreeing.rows)[0].anchors) | Where-Object { [bool]$_.stable }).Count -eq 0 -and
        @(@(@($refusedButAgreeing.rows)[0].anchors) | Where-Object { [string]$_.reconciledVerdict -cne "unknown" }).Count -eq 0) `
        "And every per-anchor verdict must be unknown; a refusal that leaves settled anchors reads as settled."
    $refusedReport = Format-ReviewerRunReconciliationReport -Reconciliation $refusedButAgreeing
    Assert-Replay ($refusedReport -clike "*none settled, because this is not a reconciliation*") `
        "The report must not print a settled count under a refusal."

    # 5. The same comment proposed twice by one run and once by another is a
    #    count disagreement, with nothing else differing.
    $countOnly = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @(
                (New-ReconCandidate -Id "c1"), (New-ReconCandidate -Id "c2"))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate -Id "c1"))))
    Assert-Replay (@($countOnly.candidates)[0].disposition -ceq "withheldCountDisagreement") `
        "Identical text and severity proposed twice against once is still a disagreement about how many comments to make."
    Assert-Replay (@(@($countOnly.candidates)[0].perRunCounts) -ccontains 2 -and
        @(@($countOnly.candidates)[0].perRunCounts) -ccontains 1) `
        "The per-run counts must show the two and the one."

    # One run is not a reconciliation, however clean it looks.
    $single = Resolve-ReviewerRunReconciliation -Manifests @((New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate))))
    Assert-Replay (-not [bool]$single.reconciled -and @($single.rows)[0].reconciledStatus -ceq "unknown") `
        "A single run cannot present any status as stable."
    Assert-Replay (@($single.candidates)[0].disposition -ceq "withheldUnreconciled") `
        "A single run's candidate is unreconciled, not agreed."

    # The same run submitted twice is one observation wearing two hats.
    $sameNonce = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow))),
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)))
    )
    Assert-Replay (-not [bool]$sameNonce.reconciled -and @($sameNonce.problems) -clike "*reuses the nonce*") `
        "A repeated nonce means one run counted twice and must not reconcile."

    # Different inputs are not repeated runs.
    $differentInput = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -SourceCommit ("d" * 40))
    )
    Assert-Replay (-not [bool]$differentInput.reconciled -and @($differentInput.rows)[0].reconciledStatus -ceq "unknown") `
        "Runs of different input must be refused rather than compared row by row."
    Assert-Replay (@(@($differentInput.problems) | Where-Object { $_ -clike "*2 different inputs*" }).Count -gt 0) `
        "The refusal must name the groups, not blame whichever run was listed first."
    # And it must say the same thing whichever order they are listed in.
    $differentReversed = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -SourceCommit ("d" * 40)),
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)))
    )
    Assert-Replay ([string]$differentInput.reconciliationSha256 -ceq [string]$differentReversed.reconciliationSha256) `
        "A mixed-input refusal must not depend on the order the runs were listed in."

    # A construct table that shifted underneath the ids is a different question.
    $shiftedConstructs = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Constructs @(
                [pscustomobject][ordered]@{
                    constructId = "mi0"; kind = "invocation"; path = "src/a.cs"
                    line = 99; endLine = 101; name = "AreEqual"; argumentNaming = "nnp"
                }))
    )
    Assert-Replay (-not [bool]$shiftedConstructs.reconciled) `
        "The same anchor id at a different line is not the same anchor."

    # The binding must read the table PRODUCTION writes. A hand-picked field
    # list here is a second copy of a schema that lives elsewhere, and the day
    # they drift the binding silently stops binding - everything still
    # reconciles, and nothing fails.
    $realConstructs = @(Get-ReviewerChangedConstructs -Files @(@{
                Path = "src/a.cs"
                Lines = @("class A {", "    void M() {", "        Do(", "            x: 1);", "    }", "}")
                ChangedLines = @(3, 4)
                DeliveredLines = @(1, 2, 3, 4, 5, 6)
            })).Constructs
    Assert-Replay (@($realConstructs).Count -gt 0) "The enumerator must produce a construct for this fixture."
    $projected = @(@($realConstructs) | ForEach-Object {
            [pscustomobject][ordered]@{
                constructId = [string]$_.constructId; kind = [string]$_.kind; path = [string]$_.path
                line = [int]$_.line; endLine = [int]$_.endLine; name = [string]$_.name
                argumentNaming = [string]$_.argumentNaming
            }
        })
    $realBinding = Get-ReviewerRunReconciliationBinding -Manifest (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Constructs $projected)
    $movedProjection = @(@($projected) | ForEach-Object {
            [pscustomobject][ordered]@{
                constructId = [string]$_.constructId; kind = [string]$_.kind; path = [string]$_.path
                line = ([int]$_.line + 500); endLine = ([int]$_.endLine + 500); name = [string]$_.name
                argumentNaming = [string]$_.argumentNaming
            }
        })
    $movedBinding = Get-ReviewerRunReconciliationBinding -Manifest (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Constructs $movedProjection)
    Assert-Replay ([string]$realBinding.Sha256 -cne [string]$movedBinding.Sha256) `
        "Moving a real enumerated construct must change the binding; if it does not, the binding is reading field names nobody writes."
    Assert-Replay (@($realBinding.Missing).Count -eq 0) "A complete run manifest must have no missing binding fields."

    # A manifest with no binding at all would otherwise compare equal to another
    # empty one - the one way an empty artifact reconciles with anything.
    $emptyBinding = Resolve-ReviewerRunReconciliation -Manifests @(
        ([pscustomobject][ordered]@{ status = "ok"; replay = [pscustomobject][ordered]@{ replayNonce = "n1"; promotable = $false } }),
        ([pscustomobject][ordered]@{ status = "ok"; replay = [pscustomobject][ordered]@{ replayNonce = "n2"; promotable = $false } })
    )
    Assert-Replay (-not [bool]$emptyBinding.reconciled -and @($emptyBinding.problems) -clike "*missing binding fields*") `
        "Two manifests with no binding must not reconcile just because their nothings match."

    # Two different recordings of the same commit are two different questions.
    $differentSnapshot = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -SnapshotId "snapshot-a" -ManifestDigest ("a" * 64)),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -SnapshotId "snapshot-b" -ManifestDigest ("b" * 64))
    )
    Assert-Replay (-not [bool]$differentSnapshot.reconciled) `
        "Runs of two different snapshots are not repetitions of one frozen input."

    # An accounting with a HOLE in it - a rule no row covered - is not two runs
    # agreeing, because an absence in both looks exactly like concurrence.
    # A row the wrapper degraded is different: it arrives as `unknown` and
    # reconciles normally, so honest degradation must NOT collapse the rest.
    $holedRuns = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Missing @("core/rule-b")),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Missing @("core/rule-b"))
    )
    Assert-Replay (-not [bool]$holedRuns.reconciled -and @($holedRuns.problems) -clike "*core/rule-b*") `
        "A rule neither run wrote a row for is a hole, and the hole must be named."
    $degradedRows = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Complete "false"),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Complete "false")
    )
    Assert-Replay ([bool]$degradedRows.reconciled -and [bool]@($degradedRows.rows)[0].stable) `
        "A run whose accounting was incomplete only because a row degraded must still reconcile the rows that did not."
    $shortTable = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -ConstructsIncomplete "true"),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -ConstructsIncomplete "true")
    )
    Assert-Replay (-not [bool]$shortTable.reconciled -and @($shortTable.problems) -clike "*incomplete construct table*") `
        "Agreement over a short anchor table is agreement about a subset nobody chose."

    # A row with no status at all: two blanks compare equal and would reconcile
    # to a stable empty string.
    $blankStatus = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Status ""))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Status "")))
    )
    Assert-Replay (@($blankStatus.rows)[0].reconciledStatus -ceq "unknown" -and -not [bool]@($blankStatus.rows)[0].stable) `
        "A rule neither run gave a status is unknown, not a stable blank."

    # The candidate key is joined from model-authored text. `ruleSourceId` is
    # schema-allowed any printable ASCII, so a separator the fields CAN contain
    # lets one candidate impersonate another. Asserted on the key itself,
    # because a fixture that merely produces two different keys would pass
    # under a broken separator too.
    $honestKey = Get-ReviewerRunReconciliationCandidateKey -Candidate (New-ReconCandidate -Source "core/rule-a" -Path "/src/a.cs" -Line 12)
    $forgedIdentity = Get-ReviewerRunReconciliationCandidateKey -Candidate (New-ReconCandidate `
            -Source "core/rule-a|changedFile|src/a.cs|12" -Path "" -Line 0)
    Assert-Replay ([string]$honestKey.Key -cne [string]$forgedIdentity.Key) `
        "A rule id built to look like a whole key must not collide with the real one."
    Assert-Replay ([string]$honestKey.RuleSourceId -ceq "core/rule-a" -and [string]$honestKey.FilePath -ceq "src/a.cs") `
        "The key's parts must be carried, not recovered by splitting the key back apart."
    $forgedKey = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Candidates @(
                (New-ReconCandidate -Source "core/rule-a|changedFile|src/a.cs|12" -Path "" -Line 0)))
    )
    Assert-Replay (@(@($forgedKey.candidates) | Where-Object { $_.disposition -ceq "agreed" }).Count -eq 0) `
        "A rule id carrying the key separator must not let one candidate impersonate another."
    $forgedReport = Format-ReviewerRunReconciliationReport -Reconciliation $forgedKey
    Assert-Replay ($forgedReport -cnotlike "*] src/a.cs:12 rule core/rule-a;*rule core/rule-a;*") `
        "The report must not name a file and line the candidate never claimed."

    # A promotable claim inside a replay artifact taints the whole comparison.
    $promotableRun = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Promotable "true")
    )
    Assert-Replay (-not [bool]$promotableRun.reconciled -and @($promotableRun.problems) -clike "*promotable*") `
        "A replay artifact claiming to be promotable must not be reconciled."

    # Same slot, different rule. Refs line up positionally, and the binding
    # makes that safe - but only if the position still means the same rule.
    $slotDrift = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Source "core/rule-a"))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Source "core/rule-z")))
    )
    Assert-Replay (@($slotDrift.rows)[0].reconciledStatus -ceq "unknown" -and
        @(@($slotDrift.rows)[0].disagreements) -clike "*different rules in this slot*") `
        "Two runs whose rs0 is about different rules have not agreed about either."

    # One source legitimately transported under two refs is not a duplicate.
    $twoRefsOneSource = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Ref "rs0"), (New-ReconRow -Ref "rs1"))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Ref "rs0"), (New-ReconRow -Ref "rs1")))
    )
    Assert-Replay ([bool]$twoRefsOneSource.reconciled -and [int]$twoRefsOneSource.stableRowCount -eq 2) `
        "The same rule transported under two refs is two rows, not a phantom duplicate."

    # A degraded pass is not half a reconciliation, and the success status the
    # reviewer actually writes is `complete` - not `ok`.
    $degradedRun = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)) -Status "degraded")
    )
    Assert-Replay (-not [bool]$degradedRun.reconciled -and @($degradedRun.problems) -clike "*degraded*") `
        "A run that did not finish cleanly cannot be half of a reconciliation."

    # Three runs, one dissenter: still unknown. No majority vote.
    $majority = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow -Status "violation"))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow -Status "violation"))),
        (New-ReconRun -Nonce "n3" -Rows @((New-ReconRow -Status "compliant" -Violating @() -Compliant @("mi0"))))
    ) -RequiredRunCount 2
    Assert-Replay (@($majority.rows)[0].reconciledStatus -ceq "unknown") `
        "Two runs out of three is not a result; there is no majority vote."

    # An operator asking for more runs than were supplied gets nothing stable.
    $tooFew = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "n1" -Rows @((New-ReconRow))),
        (New-ReconRun -Nonce "n2" -Rows @((New-ReconRow)))
    ) -RequiredRunCount 3
    Assert-Replay (-not [bool]$tooFew.reconciled -and @($tooFew.rows)[0].reconciledStatus -ceq "unknown") `
        "Fewer runs than the operator required cannot produce a stable status."

    # The disagreement has to be legible, not just counted.
    $report = Format-ReviewerRunReconciliationReport -Reconciliation $statusSplit
    Assert-Replay ($report -clike "*violation*" -and $report -clike "*compliant*" -and $report -clike "*never promotable*") `
        "The report must show both readings and label itself unpromotable."

    # End to end through the operator tool, including the key domain. A replay
    # artifact is sealed under a derived key exactly so it cannot verify against
    # the promotion path; the reconciler must read that domain and no other, or
    # a live-run artifact could be laundered through it.
    $reconDir = Join-Path $sandbox "recon"
    [void](New-Item -ItemType Directory -Path $reconDir -Force)
    $keyFile = Join-Path $reconDir "artifact-signing.key"
    $masterKey = [byte[]]::new(32)
    for ($i = 0; $i -lt 32; $i++) { $masterKey[$i] = [byte]($i + 1) }
    # The reviewer's own key file is a "<format>:<base64>" line, not raw bytes.
    # Writing raw bytes here would have hidden a reader that could not read the
    # only files it will ever be pointed at.
    [IO.File]::WriteAllText($keyFile, "raw:" + [Convert]::ToBase64String($masterKey))
    $replayHmac = [System.Security.Cryptography.HMACSHA256]::new($masterKey)
    try { $derivedKey = $replayHmac.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes("devpilot.reviewer.replay.artifact.v1")) }
    finally { $replayHmac.Dispose() }

    $sealedPaths = @()
    foreach ($pair in @(@("run1", "n1"), @("run2", "n2"))) {
        $manifest = New-ReconRun -Nonce $pair[1] -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate))
        $manifest | Add-Member -NotePropertyName kind -NotePropertyValue $script:ReviewerConventionSpecialistArtifactKind -Force
        $manifest | Add-Member -NotePropertyName artifactVersion `
            -NotePropertyValue $script:ReviewerConventionSpecialistArtifactVersion -Force
        $sealedPaths += Save-ReviewerConventionSpecialistPreview -Directory $reconDir -BaseName $pair[0] `
            -Manifest $manifest -MasterKey $derivedKey
    }
    $toolPath = Join-Path $RepoRoot "tools\Compare-ReviewerReplayRuns.ps1"
    $toolOutput = & $toolPath -ArtifactPath $sealedPaths -KeyPath $keyFile -OutputDirectory $reconDir 2>&1
    Assert-Replay ($LASTEXITCODE -eq 0 -and (($toolOutput -join "`n") -clike "*Reconciled: True*")) `
        "The reconciler must read two sealed replay artifacts and reconcile them."
    Assert-Replay (@(Get-ChildItem -LiteralPath $reconDir -Filter "reconciliation-*.json").Count -eq 1) `
        "The reconciler must seal its own artifact beside the report."
    $sealedRecon = @(Get-ChildItem -LiteralPath $reconDir -Filter "reconciliation-*.json")[0].FullName
    Assert-ReplayThrows { Read-ReviewerConventionSpecialistPreview -Path $sealedRecon -MasterKey $masterKey } `
        "The reconciliation artifact must not verify under the raw promotion key." -Match "signature verification failed"

    # The predeclared run set, end to end. A declaration that names a count can
    # still be filled with whichever runs looked best; one that names the
    # artifacts cannot.
    $declPath = & $toolPath -DeclareRunSet -SnapshotName "s" `
        -SnapshotManifestDigest ("7" * 64) -PlannedRunCount 2 `
        -KeyPath $keyFile -OutputDirectory $reconDir 2>&1 | Select-Object -Last 1
    Assert-Replay (Test-Path -LiteralPath ([string]$declPath)) "Declaring a run set must seal a declaration."
    $countOutput = & $toolPath -ArtifactPath $sealedPaths -KeyPath $keyFile `
        -RunSetPath ([string]$declPath) -RunSetKeyPath $keyFile 2>&1
    Assert-Replay ($LASTEXITCODE -eq 0 -and (($countOutput -join "`n") -clike "*Predeclared set*")) `
        "A declaration must be consumable, and must say so in the report."
    $shortSet = ""
    try { & $toolPath -ArtifactPath @($sealedPaths[0]) -KeyPath $keyFile -RunSetPath ([string]$declPath) -RunSetKeyPath $keyFile | Out-Null }
    catch { $shortSet = [string]$_.Exception.Message }
    Assert-Replay ($shortSet -clike "*is not a qualification*") `
        "A set trimmed below what was declared must be refused, not reconciled."

    # And the stronger form: the declaration names the exact artifacts.
    $runShas = @(@($sealedPaths) | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant() })
    $namedPath = & $toolPath -DeclareRunSet -SnapshotName "s" `
        -SnapshotManifestDigest ("7" * 64) -ExpectedRunSha256 $runShas `
        -KeyPath $keyFile -OutputDirectory $reconDir 2>&1 | Select-Object -Last 1
    $namedOutput = & $toolPath -ArtifactPath $sealedPaths -KeyPath $keyFile `
        -RunSetPath ([string]$namedPath) -RunSetKeyPath $keyFile 2>&1
    Assert-Replay ($LASTEXITCODE -eq 0 -and (($namedOutput -join "`n") -clike "*named these exact artifacts*")) `
        "A declaration naming exact artifacts must accept exactly those artifacts."
    # A third run, never declared, cannot be added.
    $thirdManifest = New-ReconRun -Nonce "n9" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate))
    $thirdManifest | Add-Member -NotePropertyName kind -NotePropertyValue $script:ReviewerConventionSpecialistArtifactKind -Force
    $thirdManifest | Add-Member -NotePropertyName artifactVersion `
        -NotePropertyValue $script:ReviewerConventionSpecialistArtifactVersion -Force
    $thirdPath = Save-ReviewerConventionSpecialistPreview -Directory $reconDir -BaseName "run3" `
        -Manifest $thirdManifest -MasterKey $derivedKey
    $topUp = ""
    try {
        & $toolPath -ArtifactPath @($sealedPaths[0], $thirdPath) -KeyPath $keyFile `
            -RunSetPath ([string]$namedPath) -RunSetKeyPath $keyFile | Out-Null
    }
    catch { $topUp = [string]$_.Exception.Message }
    Assert-Replay ($topUp -clike "*not those*") `
        "Swapping in a run the declaration never named must be refused."
    # The same artifact listed twice is not two runs.
    $doubled = ""
    try {
        & $toolPath -ArtifactPath @($sealedPaths[0], $sealedPaths[0]) -KeyPath $keyFile `
            -RunSetPath ([string]$namedPath) -RunSetKeyPath $keyFile | Out-Null
    }
    catch { $doubled = [string]$_.Exception.Message }
    Assert-Replay ($doubled -clike "*not those*" -or $doubled -clike "*more than once*") `
        "The same artifact twice must be refused against a named declaration."

    # The committed schema is the contract. A schema nobody checks against the
    # code it describes is a document, not a contract.
    $schemaPath = Join-Path $RepoRoot "src\Agents\reviewer\schemas\reviewer.run-reconciliation.v1.json"
    Assert-Replay (Test-Path -LiteralPath $schemaPath) "The reconciliation schema must be committed."
    $schema = [IO.File]::ReadAllText($schemaPath, $utf8) | ConvertFrom-Json -Depth 20
    $schemaKinds = @($schema.definitions.runSetDeclaration.properties.kind.const,
        $schema.definitions.reconciliation.properties.kind.const)
    Assert-Replay ($schemaKinds -ccontains $script:ReviewerRunReconciliationSetKind -and
        $schemaKinds -ccontains $script:ReviewerRunReconciliationKind) `
        "The schema's kinds must be the ones the code actually writes."
    $sampleRecon = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "s1" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate))),
        (New-ReconRun -Nonce "s2" -Rows @((New-ReconRow)) -Candidates @((New-ReconCandidate))))
    $schemaRequired = @($schema.definitions.reconciliation.required)
    $absentFromCode = @(@($schemaRequired) | Where-Object { $null -eq $sampleRecon.PSObject.Properties[$_] })
    Assert-Replay (@($absentFromCode).Count -eq 0) `
        "Every field the schema requires must be present on a real reconciliation (missing: $($absentFromCode -join ', '))."
    $schemaKnown = @($schema.definitions.reconciliation.properties.PSObject.Properties.Name)
    $absentFromSchema = @(@($sampleRecon.PSObject.Properties.Name) | Where-Object { $schemaKnown -cnotcontains $_ })
    Assert-Replay (@($absentFromSchema).Count -eq 0) `
        "Every field a real reconciliation emits must be described by the schema (undescribed: $($absentFromSchema -join ', '))."
    $anchorVerdictEnum = @($schema.definitions.anchorOutcome.properties.reconciledVerdict.enum)
    foreach ($verdict in @("violation", "compliant", "notInReach", "unknown")) {
        Assert-Replay ($anchorVerdictEnum -ccontains $verdict) `
            "The schema's anchor verdicts must include '$verdict', which the reconciler emits."
    }
    $dispositionEnum = @($schema.definitions.candidateOutcome.properties.disposition.enum)
    foreach ($disposition in @("agreed", "withheldRunDisagreement", "withheldCountDisagreement",
            "withheldSeverityDisagreement", "withheldTextDisagreement", "withheldUnreconciled")) {
        Assert-Replay ($dispositionEnum -ccontains $disposition) `
            "The schema must describe the '$disposition' disposition the reconciler can emit."
    }

    # WIRING PROOF. "Evaluation only" is a claim until something feeds the
    # reconciliation to the paths that actually deliver and watches them refuse
    # it. Three of them: the promotion readers, the gate, and the eligible-set
    # the preview draws from.
    $wiringDir = Join-Path $sandbox "wiring"
    [void](New-Item -ItemType Directory -Path $wiringDir -Force)
    $wiringSet = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "w1" -Rows @((New-ReconRow -Violating @("mi0"))) -Candidates @((New-ReconCandidate -Line 12))),
        (New-ReconRun -Nonce "w2" -Rows @((New-ReconRow -Violating @("mi0"))) -Candidates @(
                (New-ReconCandidate -Line 12), (New-ReconCandidate -Line 99 -Id "c2"))))
    # One candidate both runs proposed, one only the second did.
    $agreedOnes = @(@($wiringSet.candidates) | Where-Object { $_.disposition -ceq "agreed" })
    $withheldOnes = @(@($wiringSet.candidates) | Where-Object { $_.disposition -cne "agreed" })
    Assert-Replay (@($agreedOnes).Count -eq 1 -and [string]@($agreedOnes)[0].line -ceq "12") `
        "The candidate both runs proposed must be the agreed one."
    Assert-Replay (@($withheldOnes).Count -eq 1 -and [string]@($withheldOnes)[0].line -ceq "99") `
        "The candidate only one run proposed must be withheld, and must still appear so a reader can see it was dropped."

    # Seal it and hand it to the promotion reader, which is the ONLY reader any
    # delivery path uses.
    $wiringSealed = Save-ReviewerConventionSpecialistPreview -Directory $wiringDir -BaseName "wiring" `
        -Manifest ([pscustomobject][ordered]@{
            kind = $script:ReviewerRunReconciliationKind
            artifactVersion = $script:ReviewerRunReconciliationVersion
            status = "ok"; reconciliation = $wiringSet; promotable = $false
            createdAt = [DateTime]::UtcNow.ToString("o")
        }) -MasterKey $derivedKey
    Assert-ReplayThrows { Read-ReviewerConventionSpecialistPreview -Path $wiringSealed -MasterKey $masterKey } `
        "The promotion reader must refuse a reconciliation sealed in the replay domain." -Match "signature verification failed"
    Assert-ReplayThrows { Read-ReviewerConventionSpecialistPreview -Path $wiringSealed -MasterKey $derivedKey } `
        "Even under the replay key it must be refused, because its kind is not a specialist preview." -Match "kind or version is invalid"

    # And the shape itself carries nothing a delivery path could act on. The
    # eligible set a preview draws from is `candidates[].candidateId`; a
    # reconciliation has no such field, and its dispositions are not words any
    # gate matches.
    foreach ($candidate in @($wiringSet.candidates)) {
        Assert-Replay ($null -eq $candidate.PSObject.Properties["candidateId"]) `
            "A reconciled candidate must not carry the id a delivery path resolves."
        Assert-Replay (@("agreed", "withheldRunDisagreement", "withheldCountDisagreement",
                "withheldSeverityDisagreement", "withheldTextDisagreement", "withheldUnreconciled") -ccontains [string]$candidate.disposition) `
            "A reconciled candidate's disposition must come from the closed evaluation set."
    }
    # A refused reconciliation empties everything, so a disagreement cannot even
    # be read as a proposal.
    $refusedWiring = Resolve-ReviewerRunReconciliation -Manifests @(
        (New-ReconRun -Nonce "w3" -Rows @((New-ReconRow -Violating @("mi0"))) -Candidates @((New-ReconCandidate))),
        (New-ReconRun -Nonce "w4" -Rows @((New-ReconRow -Violating @("mi0"))) -Candidates @((New-ReconCandidate)) -Status "degraded"))
    Assert-Replay (-not [bool]$refusedWiring.reconciled -and
        @(@($refusedWiring.candidates) | Where-Object { $_.disposition -ceq "agreed" }).Count -eq 0 -and
        [int]$refusedWiring.agreedCandidateCount -eq 0 -and
        @(@($refusedWiring.rows) | Where-Object { [bool]$_.stable }).Count -eq 0) `
        "A refused reconciliation must leave no stable row, no agreed candidate, and a zero agreed count."

    # Four guards that mutation testing found load-bearing and untested. Each
    # is the enforcement behind a claim this whole layer makes.

    # (a) The key domain IS the non-promotion enforcement. If it stops
    #     diverging, every replay artifact becomes promotable.
    $keyFn = $reviewerAst.FindAll({
            param($c)
            $c -is [Management.Automation.Language.FunctionDefinitionAst] -and $c.Name -ceq "Get-ReviewerRunArtifactKey"
        }, $true) | Select-Object -First 1
    Assert-Replay ($null -ne $keyFn) "The reviewer must define Get-ReviewerRunArtifactKey."
    . ([scriptblock]::Create($keyFn.Extent.Text))
    $domainKeyPath = Join-Path $reconDir "domain-signing.key"
    [IO.File]::WriteAllText($domainKeyPath, "raw:" + [Convert]::ToBase64String($masterKey))
    function Get-ReviewerArtifactSigningKey { param([string]$KeyPath) return , $masterKey }
    $script:ReviewerUtf8 = [Text.UTF8Encoding]::new($false)
    $script:ReviewerReplayActive = $false
    $liveKeyBytes = Get-ReviewerRunArtifactKey -KeyPath $domainKeyPath
    $script:ReviewerReplayActive = $true
    $replayKeyBytes = Get-ReviewerRunArtifactKey -KeyPath $domainKeyPath
    $script:ReviewerReplayActive = $false
    Assert-Replay ([Convert]::ToBase64String($liveKeyBytes) -cne [Convert]::ToBase64String($replayKeyBytes)) `
        "In replay the artifact key must be a DERIVED key; if it stops diverging every replay artifact becomes promotable."
    Assert-Replay ([Convert]::ToBase64String($liveKeyBytes) -ceq [Convert]::ToBase64String($masterKey)) `
        "Outside replay it must remain the raw master key, or nothing a live run seals can ever be promoted."
    $expectedDerived = $null
    $domainHmac = [System.Security.Cryptography.HMACSHA256]::new($masterKey)
    try { $expectedDerived = $domainHmac.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes("devpilot.reviewer.replay.artifact.v1")) }
    finally { $domainHmac.Dispose() }
    Assert-Replay ([Convert]::ToBase64String($replayKeyBytes) -ceq [Convert]::ToBase64String($expectedDerived)) `
        "The derived key must be HMAC-SHA256 of the master over the documented replay label."

    # (b) The promotion path's own refusal of anything carrying a `replay`
    #     property - defence in depth behind the seal.
    $promoteSource = [string]$reviewerSource
    $replayLabelGuard = @($reviewerAst.FindAll({
                param($c)
                $c -is [Management.Automation.Language.FunctionDefinitionAst] -and $c.Name -ceq "Invoke-ReviewerPromotion"
            }, $true))
    Assert-Replay (@($replayLabelGuard).Count -eq 1) "The reviewer must define exactly one promotion entry point."
    Assert-Replay ([string]$replayLabelGuard[0].Extent.Text -clike "*'replay'*" -or
        [string]$replayLabelGuard[0].Extent.Text -clike '*"replay"*') `
        "The promotion path must refuse an artifact carrying a replay label, not rely on the seal alone."

    # (c) The state directory is redirected BEFORE anything is created, which is
    #     what keeps a replay out of the files a live run reads.
    Assert-Replay ($promoteSource -clike '*Join-Path (Join-Path $StateDir "replay") $script:ReviewerReplaySnapshot.SnapshotId*') `
        "In replay the state directory must be re-rooted under replay/<snapshotId>."
    $redirectLine = ($promoteSource -split "`n" | Select-String -Pattern 'Join-Path \(Join-Path \$StateDir "replay"\)' | Select-Object -First 1).LineNumber
    $createLine = ($promoteSource -split "`n" | Select-String -Pattern 'New-Item -ItemType Directory -Force -Path \$StateDir' | Select-Object -First 1).LineNumber
    Assert-Replay ($redirectLine -lt $createLine) `
        "The redirect must happen before the state directory is created, or a replay leaves a directory in the live tree."

    # (d) A replay delivery authorization is PreviewOnly at every pass count.
    #     Asserted structurally rather than by execution, because the function
    #     returns a class this harness does not load - and the property that
    #     matters is that the replay branch returns FIRST, before any pass-count
    #     logic can reach a different kind.
    $authFn = $reviewerAst.FindAll({
            param($c)
            $c -is [Management.Automation.Language.FunctionDefinitionAst] -and $c.Name -ceq "New-ReviewerDeliveryAuthorization"
        }, $true) | Select-Object -First 1
    Assert-Replay ($null -ne $authFn) "The reviewer must define New-ReviewerDeliveryAuthorization."
    $authText = [string]$authFn.Extent.Text
    $replayBranch = $authText.IndexOf('if ($ReplayPreviewOnly)', [StringComparison]::Ordinal)
    Assert-Replay ($replayBranch -ge 0) "The authorization producer must have an explicit replay branch."
    $afterBranch = $authText.Substring($replayBranch)
    $firstReturn = $afterBranch.IndexOf("return", [StringComparison]::Ordinal)
    $firstKind = $afterBranch.IndexOf("ReviewerDeliveryAuthorizationKind]::", [StringComparison]::Ordinal)
    Assert-Replay ($firstReturn -ge 0 -and $firstKind -gt $firstReturn -and
        $afterBranch.Substring($firstKind, 60) -clike "*PreviewOnly*") `
        "The replay branch must return PreviewOnly, and must do so before any other kind is reachable."
    $otherKinds = @([regex]::Matches($authText.Substring(0, $replayBranch), 'ReviewerDeliveryAuthorizationKind\]::(\w+)') |
        ForEach-Object { $_.Groups[1].Value })
    Assert-Replay (@($otherKinds).Count -eq 0) `
        "Nothing may mint an authorization kind before the replay branch is considered (found: $($otherKinds -join ', '))."

    # A live-run artifact, sealed under the raw key, is not a replay run.
    $liveManifest = New-ReconRun -Nonce "n3" -Rows @((New-ReconRow))
    $liveManifest.PSObject.Properties.Remove("replay")
    $liveManifest | Add-Member -NotePropertyName kind -NotePropertyValue $script:ReviewerConventionSpecialistArtifactKind -Force
    $liveManifest | Add-Member -NotePropertyName artifactVersion `
        -NotePropertyValue $script:ReviewerConventionSpecialistArtifactVersion -Force
    $livePath = Save-ReviewerConventionSpecialistPreview -Directory $reconDir -BaseName "live" `
        -Manifest $liveManifest -MasterKey $masterKey
    $liveRefusal = ""
    try {
        & $toolPath -ArtifactPath @($sealedPaths[0], $livePath) -KeyPath $keyFile | Out-Null
    }
    catch { $liveRefusal = [string]$_.Exception.Message }
    Assert-Replay ($liveRefusal -clike "*signature verification failed*") `
        "A live-run artifact sealed under the promotion key must be refused by the seal, not by an editable field."

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
